//! Identity-gated, graduated-veto recovery for a program-owned Solana vault (spec §8).
//!
//! The structural analogue of `evm/src/Eip7702RecoveryAccount.sol`: a stored `owner` that a
//! completed recovery rotates, with everything the owner can actually *do* going through a separate
//! instruction gated on whoever `owner` currently is.
//!
//! **Why a vault rather than a module over an existing wallet.** A Solana keypair's address *is*
//! its ed25519 public key, and there is no EIP-7702 analogue — no way to attach code to a keypair
//! address after the fact. A lost key means a permanently lost address, and no program can change
//! that. So recovery here protects assets held in a program-owned account from the start, and
//! cannot be retrofitted. See `../../README.md`.
//!
//! **Confinement, unchanged from `RecoveryModule`.** The recovered Nihilium key *assigns* a new
//! owner — it decides who may operate this vault next — but never becomes the owner, never moves
//! value, and never makes an arbitrary call. `execute_recovery`'s only effect is
//! `vault.owner = intent.new_owner` plus the epoch and nonce bump; it moves no lamports and makes
//! no CPI. That is what makes §15's "raw-rk extraction still yields only the committed, vetoable
//! rotation" true rather than aspirational, and `tests/` asserts it rather than trusting it.
//!
//! **Submission is permissionless where the authority is a signature.** `initiate_recovery`,
//! `resume` and `execute_recovery` authenticate detached ed25519 signatures rather than the
//! transaction's signers, so a relayer can broadcast for a user who has lost their device and has
//! no funded account to pay fees from. Solana separates the fee payer from the signers, so this
//! costs nothing — but the *authority* still has to be the signature, and the detached form is what
//! lets an intent be signed once, offline, and submitted by someone else.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::program::invoke_signed;
use anchor_lang::solana_program::system_instruction;
use anchor_lang::solana_program::sysvar::instructions::ID as INSTRUCTIONS_SYSVAR_ID;
use nihilium_recovery_common::digest::{intent_digest, registration_digest, resume_digest};
use nihilium_recovery_common::verify::verify_detached;

pub mod state;
use state::{AttemptAccount, VetoConfigAccount, Vault};

declare_id!("DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG");

/// Seed for the vault's state account.
pub const VAULT_SEED: &[u8] = b"vault";
/// Seed for the system-owned account that actually holds lamports.
pub const SOL_SEED: &[u8] = b"sol";

#[program]
pub mod nihilium_recovery_vault {
    use super::*;

    /// Create an empty vault. The creator becomes the first owner.
    ///
    /// `creator` and `vault_id` are the PDA seeds and are fixed forever; `owner` moves. Keeping
    /// them apart is what lets a recovery rotate the owner without moving the vault's address,
    /// which the SDK's key derivation requires: the address is `accountId`, a KDF input that must
    /// be reproducible at recovery time.
    pub fn create_vault(ctx: Context<CreateVault>, vault_id: [u8; 16]) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        vault.creator = ctx.accounts.creator.key();
        vault.vault_id = vault_id;
        vault.owner = ctx.accounts.creator.key();
        vault.recovery_owner = Pubkey::default();
        vault.epoch = 0;
        vault.nonce = 0;
        vault.attempt_seq = 0;
        vault.config_nonce = 0;
        vault.attempt = AttemptAccount::default();
        vault.intent_digest = [0u8; 32];
        vault.registered = false;
        vault.bump = ctx.bumps.vault;
        vault.sol_bump = ctx.bumps.vault_sol;
        vault.veto = VetoConfigAccount {
            pause_authority: Pubkey::default(),
            abort_authority: Pubkey::default(),
            resume_members: vec![],
            resume_threshold: 0,
            timelock_seconds: 0,
            pause_ceiling_seconds: 0,
        };
        emit!(VaultCreated { vault: vault.key(), creator: vault.creator, owner: vault.owner });
        Ok(())
    }

    /// Bind a recovery key and a veto configuration to this vault, or replace the ones it has.
    ///
    /// **Two independent signatures, both required**, following `Eip7702RecoveryAccount.register`:
    /// the current `owner` signs the transaction, and the claimed `recovery_owner` signs
    /// `registration_digest` detached. Only the identity ceremony can mint the recovery key, and
    /// only the owner can consent to it being installed. A single-signature version would leave a
    /// front-running window in which anyone binds their own recovery key to a freshly created
    /// vault.
    ///
    /// **Re-callable, deliberately.** A recovery key is not fixed for the life of a vault. The
    /// Nihilium setup behind it can change; a completed recovery exposes the key it derived; a
    /// cohort can be retired. A vault that could never be repointed would, in any of those cases,
    /// be left with a recovery key nobody should trust and no way to replace it — which is not a
    /// degraded recovery but the absence of one. `config_nonce` makes each registration a distinct,
    /// once-spendable signature so an old one cannot be replayed to revert a rotation.
    ///
    /// **Refused while a recovery is in flight**, and this is the interesting part. Rotating the
    /// key does *not* stop an attempt the old key already opened: `execute_recovery` checks the
    /// committed intent digest, and the recovery key's signature was verified back at
    /// `initiate_recovery` and is never re-checked. So a rotation performed *because* the old key
    /// was compromised would leave the attacker's in-flight attempt running while the owner
    /// reasonably believed they had just stopped it. Refusing here makes that impossible to get
    /// wrong: killing an attempt is `abort`'s job, and it is a different authority on purpose.
    pub fn register(
        ctx: Context<Register>,
        recovery_owner: Pubkey,
        veto: VetoConfigAccount,
        config_nonce: u64,
        ed25519_index: u8,
    ) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require_keys_eq!(ctx.accounts.owner.key(), vault.owner, RecoveryError::NotOwner);
        require!(recovery_owner != Pubkey::default(), RecoveryError::ZeroRecoveryOwner);
        require!(config_nonce == vault.config_nonce, RecoveryError::WrongConfigNonce);

        // An attempt the *old* key opened survives a rotation, so the rotation must not be able to
        // happen while one is open. See this function's doc comment.
        let now = Clock::get()?.unix_timestamp;
        let projected = gradual_veto::project(&vault.veto.to_veto(), vault.attempt.to_veto(), now);
        require!(
            projected.state == gradual_veto::State::None
                || gradual_veto::is_terminal(projected.state),
            RecoveryError::AttemptInFlight
        );

        // The §6.1 independence invariant, enforced on-chain rather than trusted from the client,
        // and re-enforced on every rotation: a replacement config is as capable of violating it as
        // the first one was.
        gradual_veto::validate(&veto.to_veto()).map_err(map_veto_error)?;
        // The recovery key must hold no veto role. As pause authority or a resume member it could
        // both open an attempt and release it; as abort authority it could silence the one party
        // meant to stop it. Unlike the condition surface, its address is right here to check.
        require!(
            recovery_owner != veto.pause_authority
                && recovery_owner != veto.abort_authority
                && !veto.resume_members.contains(&recovery_owner),
            RecoveryError::RecoveryOwnerHoldsVetoRole
        );
        // Deliberately **not** checked here: whether a veto authority is also `vault.owner`.
        //
        // The natural abort authority is the account's own active key. The case abort exists for is
        // "someone opened a recovery while I still have access", and the obvious party to stop that
        // is whoever currently holds the key. Refusing it would force every owner to provision a
        // second key in advance or have no way to abort at all.
        //
        // It grants nothing, which is why §6.1 is not offended: that invariant keeps a veto holder
        // from gaining power by being named, and an owner already moves funds through
        // `execute_transfer` and already authorises rotations. A separate offline abort key is a
        // stronger setup -- it survives losing the owner key -- but that is the holder's tradeoff
        // to make, not this program's to impose.

        let digest = registration_digest(
            &crate::ID,
            &vault.key(),
            &vault.owner,
            &recovery_owner,
            &veto.fingerprint(),
            config_nonce,
        );
        verify_detached(
            &ctx.accounts.instructions.to_account_info(),
            ed25519_index,
            &[(recovery_owner, digest)],
        )?;

        let replaced = vault.registered;
        let previous = vault.recovery_owner;
        vault.recovery_owner = recovery_owner;
        vault.veto = veto;
        vault.registered = true;
        vault.config_nonce = vault.config_nonce.saturating_add(1);

        if replaced {
            emit!(RecoveryKeyRotated {
                vault: vault.key(),
                previous,
                recovery_owner,
                config_nonce: vault.config_nonce,
            });
        } else {
            emit!(RecoveryRegistered {
                vault: vault.key(),
                recovery_owner,
                epoch: vault.epoch,
            });
        }
        Ok(())
    }

    /// Start a recovery. Permissionless to *submit* — the authority is the detached signature.
    pub fn initiate_recovery(
        ctx: Context<InitiateRecovery>,
        intent: Intent,
        ed25519_index: u8,
    ) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require!(vault.registered, RecoveryError::NotRegistered);
        require!(intent.new_owner != Pubkey::default(), RecoveryError::ZeroNewOwner);

        let now = Clock::get()?.unix_timestamp;
        require!(intent.expiry > now, RecoveryError::IntentExpired);
        require!(intent.epoch == vault.epoch, RecoveryError::WrongEpoch);
        require!(intent.nonce == vault.nonce, RecoveryError::WrongNonce);

        // One attempt at a time. Without this a recovery key could open many concurrent attempts
        // and force the veto holders to catch every one of them.
        let projected = gradual_veto::project(&vault.veto.to_veto(), vault.attempt.to_veto(), now);
        require!(
            projected.state == gradual_veto::State::None || gradual_veto::is_terminal(projected.state),
            RecoveryError::AttemptInFlight
        );

        let digest = intent_digest(
            &crate::ID,
            &vault.key(),
            intent.epoch,
            intent.nonce,
            &intent.new_owner,
            &intent.new_owner_config,
            intent.expiry,
        );
        verify_detached(
            &ctx.accounts.instructions.to_account_info(),
            ed25519_index,
            &[(vault.recovery_owner, digest)],
        )?;

        let mut attempt = gradual_veto::Attempt::default();
        gradual_veto::start(&mut attempt, now);
        vault.attempt = AttemptAccount::from_veto(attempt);
        vault.intent_digest = digest;
        vault.attempt_seq = vault.attempt_seq.saturating_add(1);

        emit!(RecoveryInitiated { vault: vault.key(), intent_digest: digest, epoch: vault.epoch });
        Ok(())
    }

    /// INITIATED -> PAUSED, by the pause authority only (§15).
    pub fn pause(ctx: Context<PauseRecovery>) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require!(vault.registered, RecoveryError::NotRegistered);
        require_keys_eq!(
            ctx.accounts.pause_authority.key(),
            vault.veto.pause_authority,
            RecoveryError::NotPauseAuthority
        );
        apply(vault, gradual_veto::pause)?;
        // Every pause moves the resume digest, so a resume endorsement lifts exactly one pause:
        // signatures from an earlier resume are public and must not undo this one.
        vault.attempt_seq = vault.attempt_seq.saturating_add(1);
        emit!(RecoveryPaused { vault: vault.key(), intent_digest: vault.intent_digest });
        Ok(())
    }

    /// PAUSED -> INITIATED, by a threshold of the resume quorum only (§15).
    ///
    /// Plurality is the defence against premature release, so the threshold is counted over
    /// *distinct* members — a repeated signer is rejected rather than counted twice.
    ///
    /// `signers` drives both halves: it is checked for distinctness and membership here, and it is
    /// the order the precompile's entries must appear in. One argument, one order, so the client
    /// cannot get the two out of step.
    pub fn resume(ctx: Context<ResumeRecovery>, signers: Vec<Pubkey>, ed25519_index: u8) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require!(vault.registered, RecoveryError::NotRegistered);

        let veto = vault.veto.to_veto();
        require!(
            signers.len() >= usize::from(vault.veto.resume_threshold),
            RecoveryError::BelowResumeThreshold
        );
        for (i, signer) in signers.iter().enumerate() {
            require!(
                gradual_veto::is_resume_member(&veto, &signer.to_bytes()),
                RecoveryError::NotResumeQuorum
            );
            require!(
                !signers[..i].contains(signer),
                RecoveryError::DuplicateResumeSigner
            );
        }

        let digest = resume_digest(&crate::ID, &vault.key(), &vault.intent_digest, vault.attempt_seq);
        let expected: Vec<(Pubkey, [u8; 32])> = signers.iter().map(|s| (*s, digest)).collect();
        verify_detached(
            &ctx.accounts.instructions.to_account_info(),
            ed25519_index,
            &expected,
        )?;

        apply(vault, gradual_veto::resume)?;
        emit!(RecoveryResumed { vault: vault.key(), intent_digest: vault.intent_digest });
        Ok(())
    }

    /// Any non-terminal -> ABORTED, by the abort authority only (§15). Irreversible.
    ///
    /// The anti-rogue-Nihilium backstop (§7). It must work when everything else has failed, so it
    /// takes no proof, no quorum and no cooperation — one signature from a key the owner keeps
    /// offline.
    pub fn abort(ctx: Context<AbortRecovery>) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require!(vault.registered, RecoveryError::NotRegistered);
        require_keys_eq!(
            ctx.accounts.abort_authority.key(),
            vault.veto.abort_authority,
            RecoveryError::NotAbortAuthority
        );
        apply(vault, gradual_veto::abort)?;
        // Spend the aborted intent's nonce. Its signature is in a public transaction, and without
        // this anyone could resubmit it and reopen the attempt until it expired.
        vault.nonce = vault.nonce.saturating_add(1);
        emit!(RecoveryAborted { vault: vault.key(), intent_digest: vault.intent_digest });
        Ok(())
    }

    /// EXECUTABLE -> EXECUTED: rotate the owner and bump the epoch.
    ///
    /// The epoch bump is what invalidates every prior-epoch intent, in the same transaction as the
    /// rotation. Permissionless to submit for the same reason as `initiate_recovery`: the authority
    /// came from the signature checked at initiation, and the timelock and veto have governed
    /// everything since.
    ///
    /// The intent is re-supplied and re-hashed rather than stored: `new_owner_config` is unbounded,
    /// and storing it would force an arbitrary cap into the account layout.
    pub fn execute_recovery(ctx: Context<ExecuteRecovery>, intent: Intent) -> Result<()> {
        let vault = &mut ctx.accounts.vault;
        require!(vault.registered, RecoveryError::NotRegistered);

        let digest = intent_digest(
            &crate::ID,
            &vault.key(),
            intent.epoch,
            intent.nonce,
            &intent.new_owner,
            &intent.new_owner_config,
            intent.expiry,
        );
        // Must be the intent this attempt was opened for, not merely a valid-looking one.
        require!(digest == vault.intent_digest, RecoveryError::UnknownIntent);
        require!(intent.epoch == vault.epoch, RecoveryError::WrongEpoch);

        apply(vault, gradual_veto::execute)?;

        vault.owner = intent.new_owner;
        vault.epoch = vault.epoch.saturating_add(1);
        vault.nonce = vault.nonce.saturating_add(1);

        emit!(RecoveryExecuted {
            vault: vault.key(),
            intent_digest: digest,
            new_owner: intent.new_owner,
            new_epoch: vault.epoch,
        });
        Ok(())
    }

    /// Move lamports out of the vault. **The only instruction that can move value**, and it
    /// requires the current owner.
    ///
    /// Deliberately not reachable by the recovery key, the pause authority, the abort authority or
    /// the resume quorum. That is the confinement property stated in this module's header, and the
    /// reason a recovery rotates `owner` rather than acting on the owner's behalf.
    pub fn execute_transfer(ctx: Context<ExecuteTransfer>, amount: u64) -> Result<()> {
        let vault = &ctx.accounts.vault;
        require_keys_eq!(ctx.accounts.owner.key(), vault.owner, RecoveryError::NotOwner);

        let vault_key = vault.key();
        let seeds: &[&[u8]] = &[SOL_SEED, vault_key.as_ref(), &[vault.sol_bump]];
        invoke_signed(
            &system_instruction::transfer(
                &ctx.accounts.vault_sol.key(),
                &ctx.accounts.destination.key(),
                amount,
            ),
            &[
                ctx.accounts.vault_sol.to_account_info(),
                ctx.accounts.destination.to_account_info(),
                ctx.accounts.system_program.to_account_info(),
            ],
            &[seeds],
        )?;
        Ok(())
    }

    /// The effective state right now, with the clock projected forward — auto-resume included.
    ///
    /// A paused attempt past its ceiling really is INITIATED again whether or not anyone has poked
    /// the program, so a caller must be able to learn that without sending a transaction that
    /// changes anything. Simulate this instruction to read it.
    pub fn projected_state(ctx: Context<ProjectedState>) -> Result<u8> {
        let vault = &ctx.accounts.vault;
        let now = Clock::get()?.unix_timestamp;
        let projected = gradual_veto::project(&vault.veto.to_veto(), vault.attempt.to_veto(), now);
        Ok(projected.state.ordinal())
    }
}

/// Run one veto transition against the stored attempt, settling the clock first.
fn apply(
    vault: &mut Account<Vault>,
    transition: fn(
        &gradual_veto::Config,
        &mut gradual_veto::Attempt,
        i64,
    ) -> core::result::Result<(), gradual_veto::VetoError>,
) -> Result<()> {
    let now = Clock::get()?.unix_timestamp;
    let config = vault.veto.to_veto();
    let mut attempt = vault.attempt.to_veto();
    require!(attempt.state != gradual_veto::State::None, RecoveryError::NoAttempt);
    transition(&config, &mut attempt, now).map_err(map_veto_error)?;
    vault.attempt = AttemptAccount::from_veto(attempt);
    Ok(())
}

/// The recovery this vault has committed to. One-to-one with `RecoveryModule.Intent`.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct Intent {
    pub new_owner: Pubkey,
    /// Chain-native encoding of the owner configuration to install. Opaque to this program.
    pub new_owner_config: Vec<u8>,
    pub epoch: u64,
    pub nonce: u64,
    /// Unix seconds after which this intent may no longer open a recovery.
    pub expiry: i64,
}

// --- Accounts -------------------------------------------------------------------------------

#[derive(Accounts)]
#[instruction(vault_id: [u8; 16])]
pub struct CreateVault<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    pub creator: Signer<'info>,
    #[account(
        init,
        payer = payer,
        space = 8 + Vault::INIT_SPACE,
        seeds = [VAULT_SEED, creator.key().as_ref(), vault_id.as_ref()],
        bump,
    )]
    pub vault: Account<'info, Vault>,
    /// CHECK: a system-owned PDA that only ever holds lamports. Derived here so its bump can be
    /// stored; never written to by this program except through a signed system transfer.
    #[account(seeds = [SOL_SEED, vault.key().as_ref()], bump)]
    pub vault_sol: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

/// Every instruction that reads a detached signature takes the instructions sysvar, address-checked
/// so a caller cannot substitute an account of their own shaping.
#[derive(Accounts)]
pub struct Register<'info> {
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    pub owner: Signer<'info>,
    /// CHECK: address-checked against the instructions sysvar.
    #[account(address = INSTRUCTIONS_SYSVAR_ID)]
    pub instructions: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct InitiateRecovery<'info> {
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    /// CHECK: address-checked against the instructions sysvar.
    #[account(address = INSTRUCTIONS_SYSVAR_ID)]
    pub instructions: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct PauseRecovery<'info> {
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    pub pause_authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct ResumeRecovery<'info> {
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    /// CHECK: address-checked against the instructions sysvar.
    #[account(address = INSTRUCTIONS_SYSVAR_ID)]
    pub instructions: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct AbortRecovery<'info> {
    #[account(mut)]
    pub vault: Account<'info, Vault>,
    pub abort_authority: Signer<'info>,
}

#[derive(Accounts)]
pub struct ExecuteRecovery<'info> {
    #[account(mut)]
    pub vault: Account<'info, Vault>,
}

#[derive(Accounts)]
pub struct ExecuteTransfer<'info> {
    pub vault: Account<'info, Vault>,
    pub owner: Signer<'info>,
    /// CHECK: the lamport-holding PDA, verified by seeds.
    #[account(mut, seeds = [SOL_SEED, vault.key().as_ref()], bump = vault.sol_bump)]
    pub vault_sol: UncheckedAccount<'info>,
    /// CHECK: wherever the owner is sending funds.
    #[account(mut)]
    pub destination: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ProjectedState<'info> {
    pub vault: Account<'info, Vault>,
}

// --- Events ---------------------------------------------------------------------------------

#[event]
pub struct VaultCreated {
    pub vault: Pubkey,
    pub creator: Pubkey,
    pub owner: Pubkey,
}

#[event]
pub struct RecoveryRegistered {
    pub vault: Pubkey,
    pub recovery_owner: Pubkey,
    pub epoch: u64,
}

/// A recovery key replaced, rather than installed for the first time.
///
/// Distinct from `RecoveryRegistered` because a watchtower must be able to tell "this vault just
/// got its protection" from "this vault's protection changed underneath the watch it registered" —
/// the second is what `WatchObservation.integrity` reports, and conflating them would make every
/// new vault look like a tampered one.
#[event]
pub struct RecoveryKeyRotated {
    pub vault: Pubkey,
    pub previous: Pubkey,
    pub recovery_owner: Pubkey,
    pub config_nonce: u64,
}

#[event]
pub struct RecoveryInitiated {
    pub vault: Pubkey,
    pub intent_digest: [u8; 32],
    pub epoch: u64,
}

#[event]
pub struct RecoveryPaused {
    pub vault: Pubkey,
    pub intent_digest: [u8; 32],
}

#[event]
pub struct RecoveryResumed {
    pub vault: Pubkey,
    pub intent_digest: [u8; 32],
}

#[event]
pub struct RecoveryAborted {
    pub vault: Pubkey,
    pub intent_digest: [u8; 32],
}

#[event]
pub struct RecoveryExecuted {
    pub vault: Pubkey,
    pub intent_digest: [u8; 32],
    pub new_owner: Pubkey,
    pub new_epoch: u64,
}

// --- Errors ---------------------------------------------------------------------------------

fn map_veto_error(error: gradual_veto::VetoError) -> Error {
    use gradual_veto::VetoError as V;
    match error {
        V::NotInitiated => RecoveryError::NotInitiated.into(),
        V::NotPaused => RecoveryError::NotPaused.into(),
        V::NotExecutable => RecoveryError::NotExecutable.into(),
        V::AlreadyTerminal => RecoveryError::AlreadyTerminal.into(),
        V::PauseBudgetExhausted => RecoveryError::PauseBudgetExhausted.into(),
        V::PauseAuthorityIsZero => RecoveryError::PauseAuthorityIsZero.into(),
        V::AbortAuthorityIsZero => RecoveryError::AbortAuthorityIsZero.into(),
        V::ResumeQuorumIsEmpty => RecoveryError::ResumeQuorumIsEmpty.into(),
        V::ResumeThresholdIsZero => RecoveryError::ResumeThresholdIsZero.into(),
        V::ResumeThresholdExceedsMembership => RecoveryError::ResumeThresholdExceedsMembership.into(),
        V::TimelockIsZero => RecoveryError::TimelockIsZero.into(),
        V::PauseCeilingIsZero => RecoveryError::PauseCeilingIsZero.into(),
        V::PauseAndAbortHeldByOneParty => RecoveryError::PauseAndAbortHeldByOneParty.into(),
        V::PauseAndResumeHeldByOneParty => RecoveryError::PauseAndResumeHeldByOneParty.into(),
        V::ResumeAndAbortHeldByOneParty => RecoveryError::ResumeAndAbortHeldByOneParty.into(),
        V::ResumeQuorumContainsZeroAddress => RecoveryError::ResumeQuorumContainsZeroAddress.into(),
        V::ResumeQuorumContainsDuplicate => RecoveryError::ResumeQuorumContainsDuplicate.into(),
        V::TooManyResumeMembers => RecoveryError::TooManyResumeMembers.into(),
    }
}

#[error_code]
pub enum RecoveryError {
    #[msg("registration nonce does not match; this signature was minted for a different rotation")]
    WrongConfigNonce,
    #[msg("this vault has no recovery key bound to it yet")]
    NotRegistered,
    #[msg("signer is not this vault's owner")]
    NotOwner,
    #[msg("the recovery owner cannot be the zero address")]
    ZeroRecoveryOwner,
    #[msg("the new owner cannot be the zero address")]
    ZeroNewOwner,
    #[msg("this intent has expired")]
    IntentExpired,
    #[msg("this intent is for a different recovery epoch")]
    WrongEpoch,
    #[msg("this intent is for a different nonce")]
    WrongNonce,
    #[msg("a recovery attempt is already in flight for this vault")]
    AttemptInFlight,
    #[msg("this vault has no recovery attempt")]
    NoAttempt,
    #[msg("this is not the intent the in-flight attempt was opened for")]
    UnknownIntent,
    #[msg("signer is not the pause authority")]
    NotPauseAuthority,
    #[msg("signer is not the abort authority")]
    NotAbortAuthority,
    #[msg("a named signer is not a member of the resume quorum")]
    NotResumeQuorum,
    #[msg("fewer distinct endorsements than the resume threshold")]
    BelowResumeThreshold,
    #[msg("a resume signer was named twice; plurality is counted over distinct members")]
    DuplicateResumeSigner,
    #[msg("pause is only legal from INITIATED")]
    NotInitiated,
    #[msg("resume is only legal from PAUSED")]
    NotPaused,
    #[msg("execute is only legal once the timelock has matured")]
    NotExecutable,
    #[msg("this recovery is already over")]
    AlreadyTerminal,
    #[msg("pauseAuthority is zero")]
    PauseAuthorityIsZero,
    #[msg("abortAuthority is zero")]
    AbortAuthorityIsZero,
    #[msg("resume quorum is empty")]
    ResumeQuorumIsEmpty,
    #[msg("resume threshold is zero")]
    ResumeThresholdIsZero,
    #[msg("resume threshold exceeds membership")]
    ResumeThresholdExceedsMembership,
    #[msg("timelockSeconds is zero")]
    TimelockIsZero,
    #[msg("pauseCeilingSeconds is zero, so no pause would ever be possible")]
    PauseCeilingIsZero,
    #[msg("pause and abort held by one party")]
    PauseAndAbortHeldByOneParty,
    #[msg("pause and resume held by one party")]
    PauseAndResumeHeldByOneParty,
    #[msg("resume and abort held by one party")]
    ResumeAndAbortHeldByOneParty,
    #[msg("resume quorum contains the zero address")]
    ResumeQuorumContainsZeroAddress,
    #[msg("resume quorum contains a duplicate")]
    ResumeQuorumContainsDuplicate,
    #[msg("resume quorum is larger than a resume transaction can carry")]
    TooManyResumeMembers,
    // Appended, never inserted: Anchor numbers error codes by position, and clients match on them.
    #[msg("this attempt's pause budget (pauseCeilingSeconds) is spent")]
    PauseBudgetExhausted,
    #[msg("the recovery owner cannot also hold a veto role")]
    RecoveryOwnerHoldsVetoRole,
}
