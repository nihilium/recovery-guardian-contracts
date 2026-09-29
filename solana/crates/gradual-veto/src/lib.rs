//! The graduated-veto state machine (spec §6.3), ported from `evm/src/GradualVeto.sol`.
//!
//! The invariant this crate exists to enforce: **no authority named in [`Config`] can reach
//! [`State::Executed`]**. Pause, resume and abort only speed, slow or stop the clock. Reaching
//! `Executed` requires a matured timelock and a valid identity-gate proof, and neither is a veto
//! key. Every function below is written so that property is checkable by reading this file alone.
//!
//! The chain has no "tick", so time is applied lazily: [`project`] replays the clock from the last
//! checkpoint to `now` and is the exact analogue of `advance` in the TypeScript veto package.
//!
//! **The clock is wall-clock seconds, not slots.** A timelock is a human interval — the time a
//! hijacked recovery has to be noticed and paused — and a slot or block count only approximates
//! that at a rate that differs per chain. The EVM side moved off block heights in v2.0.0 for
//! exactly this reason, and Solana's `Clock::unix_timestamp` is already the right unit, so the
//! arithmetic ports with no change of meaning.
//!
//! Be honest about that clock, though: Solana's `unix_timestamp` is derived from validator votes
//! and has historically drifted from real time by more than the seconds an Ethereum proposer can
//! shift it. Against a timelock measured in days that is still immaterial, and it is the only unit
//! under which this implementation and the TypeScript oracle mean the same thing — which is what
//! `tests/differential.rs` checks.
//!
//! **This crate is not the oracle.** `packages/veto/src/machine.ts` in the SDK repo is, and
//! `tests/differential.rs` replays traces it generated. Two independent derivations of a security
//! state machine is two chances to get it subtly different, and the difference would only show up
//! as a live account behaving unexpectedly.
//!
//! No Solana types appear here on purpose — see this crate's `Cargo.toml`.

#![deny(clippy::arithmetic_side_effects)]

/// A 32-byte account address. `solana_program::Pubkey` is a newtype over exactly this, so the
/// programs convert for free and this crate keeps no Solana dependency.
pub type Address = [u8; 32];

/// The state of one recovery attempt.
///
/// Discriminants are pinned and must stay pinned: they are the ordinals the shared trace fixture's
/// `finals` are written in, and the ones `bindings/index.ts` re-exports for the SDK. They match
/// `GradualVeto.State` in the Solidity library exactly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum State {
    /// No attempt. Distinguishes "never initiated" from a real state; the TypeScript oracle has no
    /// such member because an absent attempt is represented there by the absence of an object.
    None = 0,
    Initiated = 1,
    Paused = 2,
    Executable = 3,
    Executed = 4,
    Aborted = 5,
}

impl State {
    pub fn from_ordinal(ordinal: u8) -> Option<Self> {
        match ordinal {
            0 => Some(State::None),
            1 => Some(State::Initiated),
            2 => Some(State::Paused),
            3 => Some(State::Executable),
            4 => Some(State::Executed),
            5 => Some(State::Aborted),
            _ => None,
        }
    }

    pub fn ordinal(self) -> u8 {
        self as u8
    }
}

/// Most resume-quorum members a config may name.
///
/// This cap has no counterpart in the Solidity library, and it is not arbitrary. A resume is
/// authorised by *detached* ed25519 signatures carried in an `Ed25519SigVerify` instruction, and a
/// Solana transaction is capped at 1232 bytes. All members sign the same 32-byte digest, so one
/// copy of the message serves every signer and each additional signer costs 14 bytes of offsets +
/// 64 of signature + 32 of public key = 110. Past roughly eight members a resume transaction stops
/// fitting, and a config that cannot be resumed is a config whose pause cannot be lifted.
///
/// Refusing it here, at registration, is the whole point: the alternative is discovering it at the
/// moment someone needs to lift a pause.
pub const MAX_RESUME_MEMBERS: usize = 8;

/// The veto configuration. One-to-one with `GradualVeto.Config`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub pause_authority: Address,
    pub abort_authority: Address,
    pub resume_members: Vec<Address>,
    pub resume_threshold: u8,
    pub timelock_seconds: u64,
    pub pause_ceiling_seconds: u64,
}

/// One attempt's clock. One-to-one with `GradualVeto.Attempt`, except that `checkpoint_time` is an
/// `i64` because that is what Solana's clock is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Attempt {
    pub state: State,
    /// Seconds accrued toward `timelock_seconds`, as of `checkpoint_time`.
    pub accrued_seconds: u64,
    /// Seconds spent in the current pause, as of `checkpoint_time`.
    pub paused_seconds: u64,
    /// The unix second `accrued_seconds` / `paused_seconds` were last brought up to date at.
    pub checkpoint_time: i64,
}

/// So `Attempt::default()` is the no-attempt value, which is what a freshly created account holds.
impl Default for State {
    fn default() -> Self {
        State::None
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VetoError {
    NotInitiated,
    NotPaused,
    NotExecutable,
    AlreadyTerminal,
    PauseAuthorityIsZero,
    AbortAuthorityIsZero,
    ResumeQuorumIsEmpty,
    ResumeThresholdIsZero,
    ResumeThresholdExceedsMembership,
    TimelockIsZero,
    PauseCeilingIsZero,
    PauseAndAbortHeldByOneParty,
    PauseAndResumeHeldByOneParty,
    ResumeAndAbortHeldByOneParty,
    ResumeQuorumContainsZeroAddress,
    ResumeQuorumContainsDuplicate,
    TooManyResumeMembers,
}

pub fn is_terminal(state: State) -> bool {
    matches!(state, State::Executed | State::Aborted)
}

pub fn is_resume_member(config: &Config, candidate: &Address) -> bool {
    config.resume_members.iter().any(|member| member == candidate)
}

/// The effective attempt at `now`, with the clock replayed forward.
///
/// Takes the attempt **by value** and returns it, so a read-only caller can learn the true state
/// without sending a transaction — a paused attempt that has passed its ceiling really is
/// `Initiated` again, whether or not anyone has poked the program. Anything else would make the
/// auto-resume depend on someone paying to notice it, which is exactly the permanent-lockout
/// failure it exists to prevent.
pub fn project(config: &Config, mut attempt: Attempt, now: i64) -> Attempt {
    if attempt.state == State::None
        || is_terminal(attempt.state)
        || attempt.state == State::Executable
    {
        return attempt;
    }

    // The Solidity version subtracts two `uint64`s and reverts on underflow if the clock ever ran
    // backwards. Solana's `unix_timestamp` is not guaranteed monotonic across forks, and a revert
    // here would freeze an attempt rather than protect it, so a backwards clock is treated as no
    // time having passed. The checkpoint is never moved backwards either: doing so would silently
    // grant the skipped seconds again on the next call.
    let elapsed = now.saturating_sub(attempt.checkpoint_time);
    let mut remaining: u64 = if elapsed > 0 { elapsed as u64 } else { 0 };
    if now > attempt.checkpoint_time {
        attempt.checkpoint_time = now;
    }

    while remaining > 0 {
        match attempt.state {
            State::Paused => {
                let until_ceiling = config
                    .pause_ceiling_seconds
                    .saturating_sub(attempt.paused_seconds);
                if remaining < until_ceiling {
                    attempt.paused_seconds = attempt.paused_seconds.saturating_add(remaining);
                    return attempt;
                }
                // Ceiling reached: auto-resume, with no resume signature involved (§15). The
                // remaining seconds then accrue toward the timelock below, so one long advance
                // behaves the same as many short ones.
                attempt.state = State::Initiated;
                attempt.paused_seconds = 0;
                remaining = remaining.saturating_sub(until_ceiling);
            }
            State::Initiated => {
                let until_mature = config
                    .timelock_seconds
                    .saturating_sub(attempt.accrued_seconds);
                if remaining < until_mature {
                    attempt.accrued_seconds = attempt.accrued_seconds.saturating_add(remaining);
                    return attempt;
                }
                attempt.state = State::Executable;
                attempt.accrued_seconds = config.timelock_seconds;
                // Time no longer changes anything once executable: it waits for execute or abort.
                // Leftover seconds are deliberately discarded, matching both other implementations.
                return attempt;
            }
            _ => return attempt,
        }
    }
    attempt
}

/// Bring an attempt up to date with the projected clock.
pub fn settle(config: &Config, attempt: &mut Attempt, now: i64) {
    *attempt = project(config, *attempt, now);
}

pub fn start(attempt: &mut Attempt, now: i64) {
    attempt.state = State::Initiated;
    attempt.accrued_seconds = 0;
    attempt.paused_seconds = 0;
    attempt.checkpoint_time = now;
}

/// `Initiated` -> `Paused`. Deliberately **not** legal from `Executable`: once the timelock has
/// matured the window for slowing things down has closed, and only abort remains (§15).
pub fn pause(config: &Config, attempt: &mut Attempt, now: i64) -> Result<(), VetoError> {
    settle(config, attempt, now);
    // Terminality is reported separately from "wrong state": "this recovery is already over" is an
    // actionable answer for a watchtower, whereas "not initiated" sends it looking for a race that
    // never happened.
    if is_terminal(attempt.state) {
        return Err(VetoError::AlreadyTerminal);
    }
    if attempt.state != State::Initiated {
        return Err(VetoError::NotInitiated);
    }
    attempt.state = State::Paused;
    attempt.paused_seconds = 0;
    Ok(())
}

/// `Paused` -> `Initiated`. The accrued timelock is preserved: the clock stopped, it did not reset.
pub fn resume(config: &Config, attempt: &mut Attempt, now: i64) -> Result<(), VetoError> {
    settle(config, attempt, now);
    if is_terminal(attempt.state) {
        return Err(VetoError::AlreadyTerminal);
    }
    if attempt.state != State::Paused {
        return Err(VetoError::NotPaused);
    }
    attempt.state = State::Initiated;
    attempt.paused_seconds = 0;
    Ok(())
}

/// Any non-terminal -> `Aborted`. Irreversible.
pub fn abort(config: &Config, attempt: &mut Attempt, now: i64) -> Result<(), VetoError> {
    settle(config, attempt, now);
    if attempt.state == State::None {
        return Err(VetoError::NotInitiated);
    }
    if is_terminal(attempt.state) {
        return Err(VetoError::AlreadyTerminal);
    }
    attempt.state = State::Aborted;
    Ok(())
}

/// `Executable` -> `Executed`. The only transition that can move value, and the only one no veto
/// authority can drive.
pub fn execute(config: &Config, attempt: &mut Attempt, now: i64) -> Result<(), VetoError> {
    settle(config, attempt, now);
    if attempt.state != State::Executable {
        return Err(VetoError::NotExecutable);
    }
    attempt.state = State::Executed;
    Ok(())
}

/// The §6.1 independence invariant, enforced on-chain rather than trusted from the client.
///
/// The SDK validates this too, but a config only the client checked is a config an attacker can
/// simply not check. "A resume key wieldable by whoever can forge the condition turns the pause
/// into theater" — so the chain has to refuse it as well.
///
/// What cannot be checked here: whether the abort key is genuinely bare (§7), and whether the
/// resume quorum is disjoint from the identity-condition surface. Neither fact exists on-chain.
/// Those stay client-side in `validateVetoConfig`, and that asymmetry is real rather than an
/// oversight.
pub fn validate(config: &Config) -> Result<(), VetoError> {
    const ZERO: Address = [0u8; 32];

    if config.pause_authority == ZERO {
        return Err(VetoError::PauseAuthorityIsZero);
    }
    if config.abort_authority == ZERO {
        return Err(VetoError::AbortAuthorityIsZero);
    }
    if config.resume_members.is_empty() {
        return Err(VetoError::ResumeQuorumIsEmpty);
    }
    if config.resume_members.len() > MAX_RESUME_MEMBERS {
        return Err(VetoError::TooManyResumeMembers);
    }
    if config.resume_threshold == 0 {
        return Err(VetoError::ResumeThresholdIsZero);
    }
    if usize::from(config.resume_threshold) > config.resume_members.len() {
        return Err(VetoError::ResumeThresholdExceedsMembership);
    }
    if config.timelock_seconds == 0 {
        return Err(VetoError::TimelockIsZero);
    }
    // Without a positive ceiling a pause never auto-resumes, and the pause-holder's bounded
    // "freeze" becomes an unbounded one.
    if config.pause_ceiling_seconds == 0 {
        return Err(VetoError::PauseCeilingIsZero);
    }
    if config.abort_authority == config.pause_authority {
        return Err(VetoError::PauseAndAbortHeldByOneParty);
    }

    for (i, member) in config.resume_members.iter().enumerate() {
        if *member == ZERO {
            return Err(VetoError::ResumeQuorumContainsZeroAddress);
        }
        if *member == config.pause_authority {
            return Err(VetoError::PauseAndResumeHeldByOneParty);
        }
        if *member == config.abort_authority {
            return Err(VetoError::ResumeAndAbortHeldByOneParty);
        }
        // A duplicated member inflates the apparent threshold: a "2-of-3" whose members are
        // A, A, B is really 1-of-2.
        if config.resume_members[i.saturating_add(1)..].contains(member) {
            return Err(VetoError::ResumeQuorumContainsDuplicate);
        }
    }
    Ok(())
}
