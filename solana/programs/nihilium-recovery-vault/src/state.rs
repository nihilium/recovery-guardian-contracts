use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hashv;
use gradual_veto::MAX_RESUME_MEMBERS;

/// The veto configuration, as the account stores it.
///
/// Mirrors `gradual_veto::Config` with `Pubkey` in place of `[u8; 32]`. The state machine crate
/// keeps no Solana dependency so it stays testable without a validator, so the conversion happens
/// here — at the one boundary, rather than being smeared across the instruction handlers.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, InitSpace, Debug)]
pub struct VetoConfigAccount {
    pub pause_authority: Pubkey,
    pub abort_authority: Pubkey,
    #[max_len(MAX_RESUME_MEMBERS)]
    pub resume_members: Vec<Pubkey>,
    pub resume_threshold: u8,
    pub timelock_seconds: u64,
    pub pause_ceiling_seconds: u64,
}

impl VetoConfigAccount {
    pub fn to_veto(&self) -> gradual_veto::Config {
        gradual_veto::Config {
            pause_authority: self.pause_authority.to_bytes(),
            abort_authority: self.abort_authority.to_bytes(),
            resume_members: self.resume_members.iter().map(|m| m.to_bytes()).collect(),
            resume_threshold: self.resume_threshold,
            timelock_seconds: self.timelock_seconds,
            pause_ceiling_seconds: self.pause_ceiling_seconds,
        }
    }

    /// A commitment to the whole configuration, folded into the registration digest.
    ///
    /// Without it the recovery owner would be signing "I accept being this vault's recovery key"
    /// while the veto authorities — the parties who can pause, resume and abort their recovery —
    /// were chosen entirely by whoever submitted the transaction.
    pub fn fingerprint(&self) -> [u8; 32] {
        let mut parts: Vec<Vec<u8>> = vec![
            self.pause_authority.to_bytes().to_vec(),
            self.abort_authority.to_bytes().to_vec(),
            // Length-prefixed: a 2-member quorum must not fingerprint like a 1-member quorum whose
            // single key happens to be the concatenation.
            (self.resume_members.len() as u32).to_le_bytes().to_vec(),
        ];
        for member in &self.resume_members {
            parts.push(member.to_bytes().to_vec());
        }
        parts.push(vec![self.resume_threshold]);
        parts.push(self.timelock_seconds.to_le_bytes().to_vec());
        parts.push(self.pause_ceiling_seconds.to_le_bytes().to_vec());

        let refs: Vec<&[u8]> = parts.iter().map(Vec::as_slice).collect();
        hashv(&refs).to_bytes()
    }
}

/// One attempt's clock, as the account stores it.
///
/// `state` is the ordinal rather than the enum so the layout is fixed and the IDL is readable; the
/// ordinals are pinned by `gradual_veto`'s own tests and shared with the Solidity enum.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, InitSpace, Debug, Default)]
pub struct AttemptAccount {
    pub state: u8,
    pub accrued_seconds: u64,
    pub paused_seconds: u64,
    pub checkpoint_time: i64,
}

impl AttemptAccount {
    pub fn to_veto(self) -> gradual_veto::Attempt {
        gradual_veto::Attempt {
            state: gradual_veto::State::from_ordinal(self.state).unwrap_or(gradual_veto::State::None),
            accrued_seconds: self.accrued_seconds,
            paused_seconds: self.paused_seconds,
            checkpoint_time: self.checkpoint_time,
        }
    }

    pub fn from_veto(attempt: gradual_veto::Attempt) -> Self {
        Self {
            state: attempt.state.ordinal(),
            accrued_seconds: attempt.accrued_seconds,
            paused_seconds: attempt.paused_seconds,
            checkpoint_time: attempt.checkpoint_time,
        }
    }
}

/// A vault, its recovery configuration, and its one in-flight attempt.
///
/// **The attempt is a field here, not a separate PDA.** It is fixed-size, so embedding it makes
/// "one attempt at a time" structural rather than checked, costs no extra rent, and avoids
/// `init_if_needed` — which is a reinitialization footgun and would be the only way to reopen a
/// per-attempt account.
///
/// `epoch`, `nonce` and `attempt_seq` live beside the attempt but are **never cleared with it**.
/// They are replay-protection state: zeroing them when an attempt ends would make every previously
/// signed intent and every banked resume endorsement valid again. `RecoveryModule` keeps the same
/// separation across `onUninstall`, and for the same reason.
#[account]
#[derive(InitSpace, Debug)]
pub struct Vault {
    /// Immutable, and in the PDA seeds. Distinct from `owner` on purpose: the seeds must not move
    /// when a recovery rotates the owner, or the vault's address would change and every seal
    /// derived against it would be orphaned — `accountId` is a KDF input in the SDK.
    pub creator: Pubkey,
    pub vault_id: [u8; 16],
    /// Rotated by a completed recovery. The only key that can move value.
    pub owner: Pubkey,
    /// `rk_pk`. An ed25519 recovery key *is* a Solana address, so this is the derived key itself
    /// rather than a hash or an address derived from one.
    pub recovery_owner: Pubkey,
    /// Bumped on every completed recovery, invalidating every prior-epoch intent.
    pub epoch: u64,
    pub nonce: u64,
    /// Bumped on every `initiate_recovery`, folded into the resume digest.
    pub attempt_seq: u64,
    /// Bumped on every `register`, folded into the registration digest.
    ///
    /// Registration is re-callable — a recovery key is rotated, not fixed for life — so a
    /// registration signature must be spendable exactly once. Without this counter the digest for
    /// (owner, recovery_owner, veto) is constant, and an old signature could be replayed to revert
    /// a rotation: back to a key the owner had just decided to stop trusting, which is the one
    /// direction that must never be possible. `RecoveryModule`'s `attempt_seq` guards resume
    /// endorsements the same way.
    pub config_nonce: u64,
    pub veto: VetoConfigAccount,
    pub attempt: AttemptAccount,
    /// The intent this attempt was opened for. Zero when no attempt is open.
    pub intent_digest: [u8; 32],
    /// False until `register` has bound a recovery key and a veto configuration.
    pub registered: bool,
    pub bump: u8,
    /// Bump for the lamport-holding PDA, so `execute_transfer` can sign for it.
    pub sol_bump: u8,
}
