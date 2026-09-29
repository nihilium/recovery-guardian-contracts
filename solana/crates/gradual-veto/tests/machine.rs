//! What the shared trace fixture cannot cover, tested directly.
//!
//! The generator records only *legal* transitions, because an illegal one reverts on-chain and
//! returns `ok: false` in TypeScript — not comparable shapes. So each implementation tests its own
//! rejections, and this is that file for the Rust side. It also pins the properties the §6 design
//! rests on, which a trace replay can demonstrate but not *name*.

use gradual_veto::{
    abort, execute, is_resume_member, pause, project, resume, settle, start, validate, Attempt,
    Config, State, VetoError, MAX_RESUME_MEMBERS,
};

const T0: i64 = 1_700_000_000;
const TIMELOCK: u64 = 100;
const CEILING: u64 = 50;

fn config() -> Config {
    Config {
        pause_authority: [0xb1; 32],
        abort_authority: [0xb2; 32],
        resume_members: vec![[0xa1; 32], [0xa2; 32]],
        resume_threshold: 2,
        timelock_seconds: TIMELOCK,
        pause_ceiling_seconds: CEILING,
    }
}

fn initiated() -> Attempt {
    let mut attempt = Attempt::default();
    start(&mut attempt, T0);
    attempt
}

// --- The invariant the whole design rests on --------------------------------------------------

/// **No authority named in `Config` can reach `Executed`.**
///
/// The crate header claims this and the claim is what makes the file worth reading alone, so it is
/// asserted rather than trusted: pause, resume and abort are applied in every order from every
/// non-terminal state, and none of them ever yields `Executed`.
#[test]
fn no_veto_action_can_reach_executed() {
    let config = config();

    for start_state in [State::Initiated, State::Paused, State::Executable] {
        for first in 0..3 {
            for second in 0..3 {
                let mut attempt = initiated();
                if start_state == State::Paused {
                    pause(&config, &mut attempt, T0).unwrap();
                } else if start_state == State::Executable {
                    attempt = project(&config, attempt, T0 + TIMELOCK as i64);
                    assert_eq!(attempt.state, State::Executable);
                }

                for action in [first, second] {
                    let _ = match action {
                        0 => pause(&config, &mut attempt, T0),
                        1 => resume(&config, &mut attempt, T0),
                        _ => abort(&config, &mut attempt, T0),
                    };
                    assert_ne!(
                        attempt.state,
                        State::Executed,
                        "a veto action reached EXECUTED from {start_state:?}",
                    );
                }
            }
        }
    }
}

/// The identity gate is not modelled here, but the timelock half is: `execute` is reachable only
/// from `Executable`, which only time produces.
#[test]
fn execute_is_refused_from_every_state_but_executable() {
    let config = config();

    let mut fresh = Attempt::default();
    assert_eq!(
        execute(&config, &mut fresh, T0),
        Err(VetoError::NotExecutable)
    );

    let mut attempt = initiated();
    assert_eq!(
        execute(&config, &mut attempt, T0),
        Err(VetoError::NotExecutable)
    );

    pause(&config, &mut attempt, T0).unwrap();
    assert_eq!(
        execute(&config, &mut attempt, T0),
        Err(VetoError::NotExecutable)
    );

    let mut aborted = initiated();
    abort(&config, &mut aborted, T0).unwrap();
    assert_eq!(
        execute(&config, &mut aborted, T0),
        Err(VetoError::NotExecutable)
    );
}

// --- Rejections -------------------------------------------------------------------------------

/// §15: "pause: INITIATED -> PAUSED only". Notably **not** from EXECUTABLE — once the timelock has
/// matured the window for slowing things down has closed, and only abort remains.
#[test]
fn pause_is_refused_once_the_timelock_has_matured() {
    let config = config();
    let mut attempt = initiated();
    attempt = project(&config, attempt, T0 + TIMELOCK as i64);

    assert_eq!(attempt.state, State::Executable);
    assert_eq!(
        pause(&config, &mut attempt, T0 + TIMELOCK as i64),
        Err(VetoError::NotInitiated),
    );
    assert_eq!(attempt.state, State::Executable, "a refused pause mutated");
}

#[test]
fn double_pause_and_double_resume_are_refused() {
    let config = config();
    let mut attempt = initiated();

    assert_eq!(
        resume(&config, &mut attempt, T0),
        Err(VetoError::NotPaused),
        "resume from INITIATED",
    );
    pause(&config, &mut attempt, T0).unwrap();
    assert_eq!(
        pause(&config, &mut attempt, T0),
        Err(VetoError::NotInitiated),
        "pause from PAUSED",
    );
}

/// Terminality is reported separately from "wrong state" on purpose: "this recovery is already
/// over" is an actionable answer for a watchtower, whereas "not initiated" sends it looking for a
/// race that never happened.
#[test]
fn terminal_states_report_terminality_rather_than_wrong_state() {
    let config = config();

    for terminal in ["aborted", "executed"] {
        let mut attempt = initiated();
        if terminal == "aborted" {
            abort(&config, &mut attempt, T0).unwrap();
        } else {
            attempt = project(&config, attempt, T0 + TIMELOCK as i64);
            execute(&config, &mut attempt, T0 + TIMELOCK as i64).unwrap();
        }
        let now = T0 + TIMELOCK as i64;

        assert_eq!(
            pause(&config, &mut attempt, now),
            Err(VetoError::AlreadyTerminal),
            "{terminal}",
        );
        assert_eq!(
            resume(&config, &mut attempt, now),
            Err(VetoError::AlreadyTerminal),
            "{terminal}",
        );
        assert_eq!(
            abort(&config, &mut attempt, now),
            Err(VetoError::AlreadyTerminal),
            "{terminal}",
        );
    }
}

/// An attempt that never existed is not the same as one that ended, and `abort` says so.
#[test]
fn aborting_a_nonexistent_attempt_is_not_terminal() {
    let config = config();
    let mut none = Attempt::default();
    assert_eq!(none.state, State::None);
    assert_eq!(abort(&config, &mut none, T0), Err(VetoError::NotInitiated));
}

// --- The clock --------------------------------------------------------------------------------

/// §15's "no permanent lockout": the ceiling auto-resumes with **no resume signature involved**,
/// and without anyone poking the program. This is the property `project`-by-value exists for.
#[test]
fn a_pause_auto_resumes_at_the_ceiling_with_nobody_acting() {
    let config = config();
    let mut attempt = initiated();
    pause(&config, &mut attempt, T0).unwrap();

    // One second short: still frozen.
    let held = project(&config, attempt, T0 + CEILING as i64 - 1);
    assert_eq!(held.state, State::Paused);
    assert_eq!(held.accrued_seconds, 0, "accrual must stay frozen");

    // At the ceiling: initiated again, no signature, no transaction.
    let released = project(&config, attempt, T0 + CEILING as i64);
    assert_eq!(released.state, State::Initiated);
    assert_eq!(released.paused_seconds, 0);
}

/// "The clock stopped, it did not reset." A pause that reset accrual would let a pause-holder
/// extend a recovery indefinitely in ceiling-sized increments without ever exceeding the ceiling.
#[test]
fn a_pause_freezes_accrual_rather_than_resetting_it() {
    let config = config();
    let mut attempt = initiated();

    attempt = project(&config, attempt, T0 + 40);
    assert_eq!(attempt.accrued_seconds, 40);

    pause(&config, &mut attempt, T0 + 40).unwrap();
    attempt = project(&config, attempt, T0 + 60); // 20s paused
    assert_eq!(attempt.accrued_seconds, 40, "accrual moved while paused");

    resume(&config, &mut attempt, T0 + 60).unwrap();
    assert_eq!(attempt.accrued_seconds, 40, "resume reset the clock");

    // 60 more seconds finishes the remaining 60 of the timelock, not a fresh 100.
    attempt = project(&config, attempt, T0 + 120);
    assert_eq!(attempt.state, State::Executable);
}

/// The remainder of a long advance carries over, so one big step equals many small ones. This is
/// the arithmetic the trace fixture is really testing, pinned here by name.
#[test]
fn a_long_advance_carries_its_remainder_past_the_ceiling() {
    let config = config();
    let mut attempt = initiated();
    pause(&config, &mut attempt, T0).unwrap();

    // 50 to burn the ceiling, then 100 of timelock: exactly matured, in one step.
    let one_step = project(&config, attempt, T0 + (CEILING + TIMELOCK) as i64);
    assert_eq!(one_step.state, State::Executable);

    let mut many_steps = attempt;
    for i in 1..=(CEILING + TIMELOCK) {
        many_steps = project(&config, many_steps, T0 + i as i64);
    }
    assert_eq!(many_steps.state, one_step.state);
    assert_eq!(many_steps.accrued_seconds, one_step.accrued_seconds);
}

/// Solana's `unix_timestamp` is not guaranteed monotonic across forks. The Solidity version reverts
/// on the underflow; freezing an attempt is worse than ignoring the step, so this treats a
/// backwards clock as no time having passed — and must not hand back the skipped seconds later.
#[test]
fn a_backwards_clock_neither_matures_nor_underflows() {
    let config = config();
    let mut attempt = initiated();
    attempt = project(&config, attempt, T0 + 30);
    assert_eq!(attempt.accrued_seconds, 30);

    let rewound = project(&config, attempt, T0 - 10_000);
    assert_eq!(rewound.state, State::Initiated);
    assert_eq!(rewound.accrued_seconds, 30, "a rewind changed accrual");
    assert_eq!(
        rewound.checkpoint_time,
        T0 + 30,
        "the checkpoint moved backwards, which would grant the skipped seconds twice",
    );

    // And time resuming from the real clock still only credits what actually elapsed.
    let forward = project(&config, rewound, T0 + 40);
    assert_eq!(forward.accrued_seconds, 40);
}

/// Time does nothing once executable: it waits for execute or abort.
#[test]
fn an_executable_attempt_ignores_further_time() {
    let config = config();
    let mut attempt = initiated();
    settle(&config, &mut attempt, T0 + TIMELOCK as i64);
    assert_eq!(attempt.state, State::Executable);

    let much_later = project(&config, attempt, T0 + 10_000_000);
    assert_eq!(much_later, attempt, "an executable attempt drifted");
}

// --- Config validation ------------------------------------------------------------------------

#[test]
fn validate_accepts_a_well_formed_config() {
    assert_eq!(validate(&config()), Ok(()));
}

#[test]
fn validate_enforces_the_independence_invariant() {
    let cases: Vec<(&str, Config, VetoError)> = vec![
        (
            "pause and abort held by one party",
            Config {
                abort_authority: [0xb1; 32],
                ..config()
            },
            VetoError::PauseAndAbortHeldByOneParty,
        ),
        (
            "a resume member is also the pause authority",
            Config {
                resume_members: vec![[0xb1; 32], [0xa2; 32]],
                ..config()
            },
            VetoError::PauseAndResumeHeldByOneParty,
        ),
        (
            "a resume member is also the abort authority",
            Config {
                resume_members: vec![[0xa1; 32], [0xb2; 32]],
                ..config()
            },
            VetoError::ResumeAndAbortHeldByOneParty,
        ),
        (
            // A "2-of-3" whose members are A, A, B is really 1-of-2.
            "a duplicated member inflates the apparent threshold",
            Config {
                resume_members: vec![[0xa1; 32], [0xa1; 32], [0xa3; 32]],
                ..config()
            },
            VetoError::ResumeQuorumContainsDuplicate,
        ),
    ];

    for (name, config, expected) in cases {
        assert_eq!(validate(&config), Err(expected), "{name}");
    }
}

#[test]
fn validate_rejects_configs_that_could_never_be_satisfied_or_lifted() {
    let cases: Vec<(&str, Config, VetoError)> = vec![
        (
            "zero pause authority",
            Config {
                pause_authority: [0; 32],
                ..config()
            },
            VetoError::PauseAuthorityIsZero,
        ),
        (
            "zero abort authority",
            Config {
                abort_authority: [0; 32],
                ..config()
            },
            VetoError::AbortAuthorityIsZero,
        ),
        (
            "empty quorum",
            Config {
                resume_members: vec![],
                ..config()
            },
            VetoError::ResumeQuorumIsEmpty,
        ),
        (
            "zero threshold",
            Config {
                resume_threshold: 0,
                ..config()
            },
            VetoError::ResumeThresholdIsZero,
        ),
        (
            "threshold beyond membership can never be met",
            Config {
                resume_threshold: 3,
                ..config()
            },
            VetoError::ResumeThresholdExceedsMembership,
        ),
        (
            "zero timelock leaves no window to notice a hijack",
            Config {
                timelock_seconds: 0,
                ..config()
            },
            VetoError::TimelockIsZero,
        ),
        (
            // Without a positive ceiling a pause never auto-resumes, and the pause-holder's
            // bounded freeze becomes an unbounded one.
            "zero ceiling makes the freeze unbounded",
            Config {
                pause_ceiling_seconds: 0,
                ..config()
            },
            VetoError::PauseCeilingIsZero,
        ),
        (
            "a zero-address member is not a guardian",
            Config {
                resume_members: vec![[0xa1; 32], [0; 32]],
                ..config()
            },
            VetoError::ResumeQuorumContainsZeroAddress,
        ),
    ];

    for (name, config, expected) in cases {
        assert_eq!(validate(&config), Err(expected), "{name}");
    }
}

/// The cap exists because a resume is authorised by detached ed25519 signatures inside a 1232-byte
/// transaction. A quorum too large to fit is a pause that can never be lifted, so it is refused at
/// registration rather than discovered at the moment someone needs to lift one.
#[test]
fn validate_caps_the_quorum_at_what_a_resume_transaction_can_carry() {
    let members: Vec<[u8; 32]> = (0..=MAX_RESUME_MEMBERS)
        .map(|i| [0x10 + i as u8; 32])
        .collect();
    assert_eq!(members.len(), MAX_RESUME_MEMBERS + 1);

    let too_many = Config {
        resume_members: members.clone(),
        resume_threshold: 2,
        ..config()
    };
    assert_eq!(validate(&too_many), Err(VetoError::TooManyResumeMembers));

    let at_the_cap = Config {
        resume_members: members[..MAX_RESUME_MEMBERS].to_vec(),
        resume_threshold: 2,
        ..config()
    };
    assert_eq!(validate(&at_the_cap), Ok(()));
}

#[test]
fn membership_is_by_value_not_by_position() {
    let config = config();
    assert!(is_resume_member(&config, &[0xa1; 32]));
    assert!(is_resume_member(&config, &[0xa2; 32]));
    assert!(!is_resume_member(&config, &[0xb1; 32]));
    assert!(!is_resume_member(&config, &[0; 32]));
}

// --- The owner may hold a veto role ------------------------------------------------------------

/// `validate` deliberately knows nothing about an owner, and must stay that way.
///
/// The natural abort authority is the account's own active key: the case abort exists for is
/// "someone opened a recovery while I still have access", and the obvious party to stop that is
/// whoever holds the key. Forcing a second key to be provisioned in advance would leave an owner
/// who did not with no way to abort at all.
///
/// §6.1 is not offended, because it keeps a veto holder from *gaining* power by being named. An
/// owner already moves funds and already authorises rotations, so naming them grants nothing. A
/// separate offline abort key is a stronger setup — it survives losing the owner key — but that is
/// the holder's tradeoff, not a rule.
///
/// Pinned as an acceptance so the refusal is not reinstated: it was, briefly, and it was wrong.
#[test]
fn a_config_naming_any_key_twice_across_roles_is_not_this_crates_business() {
    // Every role filled by keys that a caller might equally have used as the account's own. The
    // config is valid because nothing here can, or should, know which key signs for the account.
    let config = Config {
        pause_authority: [0x01; 32],
        abort_authority: [0x02; 32],
        resume_members: vec![[0x03; 32], [0x04; 32]],
        resume_threshold: 2,
        timelock_seconds: 100,
        pause_ceiling_seconds: 50,
    };
    assert_eq!(validate(&config), Ok(()));
}
