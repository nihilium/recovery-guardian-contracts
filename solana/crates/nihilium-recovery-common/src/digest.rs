//! What a signature commits to.
//!
//! The EVM module signs an EIP-712 digest, which binds the account, the epoch, the nonce, the
//! committed rotation and the expiry so an intent cannot be replayed onto another account, another
//! epoch, or after it has gone stale. These are the same commitments, built by hand because Solana
//! has no EIP-712 and no in-program chain id.
//!
//! **Every field is fixed-width or pre-hashed**, so the concatenation is unambiguous and no two
//! distinct inputs can produce the same preimage by shifting a boundary. That is the same rule
//! `buildInfo` follows in the SDK's `kdf.ts`, for the same reason: `accountId="ab", vaultId="c"`
//! and `accountId="a", vaultId="bc"` must not hash alike. The one variable-length field,
//! `new_owner_config`, is hashed before it is folded in — exactly how EIP-712 treats `bytes`.
//!
//! The domain strings are length-prefixed even though they are compile-time constants. They cannot
//! actually collide today; the prefix is there so that adding a third digest later cannot create a
//! collision by being a prefix of an existing one.

use crate::cluster::CLUSTER_TAG;
use anchor_lang::prelude::*;
use anchor_lang::solana_program::hash::hashv;

/// Domain for the signature that binds a recovery key to a vault.
pub const DOMAIN_REGISTER: &[u8] = b"nihilium-recovery-solana-register-v1";
/// Domain for the signature that opens a recovery.
pub const DOMAIN_INTENT: &[u8] = b"nihilium-recovery-solana-intent-v1";
/// Domain for the signature a resume-quorum member gives.
pub const DOMAIN_RESUME: &[u8] = b"nihilium-recovery-solana-resume-v1";

/// `u32le(len) ‖ bytes`, matching the SDK's length-prefixing discipline.
fn length_prefixed(value: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4usize.saturating_add(value.len()));
    out.extend_from_slice(&(value.len() as u32).to_le_bytes());
    out.extend_from_slice(value);
    out
}

/// What the claimed recovery owner signs to accept being bound to this vault.
///
/// `register` requires this *and* the current owner's transaction signature, following
/// `Eip7702RecoveryAccount.register`'s reasoning: only the identity ceremony can mint the recovery
/// key, and only the owner can consent to it being installed. A single-signature registration
/// leaves a front-running window in which someone else binds their own recovery key to a vault the
/// moment it is created.
///
/// **Registration is re-callable, so this digest is spent once.** A recovery key is not fixed for
/// the life of a vault: the Nihilium cohort behind it can change, a recovery exposes the key it was
/// derived from, and a vault whose only recovery key is one nobody trusts any more has no recovery
/// at all. `config_nonce` is what makes each rotation a distinct signature — see the field's own
/// comment for the replay it prevents.
///
/// `veto_fingerprint` is folded in so the recovery owner is signing the *veto configuration too* —
/// otherwise a vault could be registered with the agreed recovery key under veto authorities the
/// signer never saw.
pub fn registration_digest(
    program_id: &Pubkey,
    vault: &Pubkey,
    owner: &Pubkey,
    recovery_owner: &Pubkey,
    veto_fingerprint: &[u8; 32],
    config_nonce: u64,
) -> [u8; 32] {
    hashv(&[
        &length_prefixed(DOMAIN_REGISTER),
        &CLUSTER_TAG,
        program_id.as_ref(),
        vault.as_ref(),
        owner.as_ref(),
        recovery_owner.as_ref(),
        veto_fingerprint,
        &config_nonce.to_le_bytes(),
    ])
    .to_bytes()
}

/// What the recovery key signs to open a recovery.
///
/// One-to-one with `RecoveryModule.hashIntent`: binding every field is what stops an intent being
/// replayed onto another account, another epoch, or after it has gone stale.
#[allow(clippy::too_many_arguments)]
pub fn intent_digest(
    program_id: &Pubkey,
    vault: &Pubkey,
    epoch: u64,
    nonce: u64,
    new_owner: &Pubkey,
    new_owner_config: &[u8],
    expiry: i64,
) -> [u8; 32] {
    let config_hash = hashv(&[new_owner_config]).to_bytes();
    hashv(&[
        &length_prefixed(DOMAIN_INTENT),
        &CLUSTER_TAG,
        program_id.as_ref(),
        vault.as_ref(),
        &epoch.to_le_bytes(),
        &nonce.to_le_bytes(),
        new_owner.as_ref(),
        &config_hash,
        &expiry.to_le_bytes(),
    ])
    .to_bytes()
}

/// What a resume-quorum member signs.
///
/// Bound to one pause via `attempt_seq`, which is bumped on every `initiate_recovery` and every
/// `pause` — so an endorsement cannot be replayed onto a later pause of the same attempt, nor onto
/// a later attempt. Sign it after the pause it is meant to lift. That counter lives
/// on the vault rather than on the attempt precisely so that clearing an attempt cannot resurrect
/// a banked signature; `RecoveryModule` keeps it in `AccountConfig` for the same reason.
pub fn resume_digest(
    program_id: &Pubkey,
    vault: &Pubkey,
    intent_digest: &[u8; 32],
    attempt_seq: u64,
) -> [u8; 32] {
    hashv(&[
        &length_prefixed(DOMAIN_RESUME),
        &CLUSTER_TAG,
        program_id.as_ref(),
        vault.as_ref(),
        intent_digest,
        &attempt_seq.to_le_bytes(),
    ])
    .to_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(b: u8) -> Pubkey {
        Pubkey::new_from_array([b; 32])
    }

    /// The whole point of binding every field: change any one and the signature stops applying.
    #[test]
    fn every_intent_field_changes_the_digest() {
        let base = intent_digest(&key(1), &key(2), 3, 4, &key(5), b"cfg", 6);

        let variants = [
            ("program id", intent_digest(&key(9), &key(2), 3, 4, &key(5), b"cfg", 6)),
            ("vault", intent_digest(&key(1), &key(9), 3, 4, &key(5), b"cfg", 6)),
            ("epoch", intent_digest(&key(1), &key(2), 9, 4, &key(5), b"cfg", 6)),
            ("nonce", intent_digest(&key(1), &key(2), 3, 9, &key(5), b"cfg", 6)),
            ("new owner", intent_digest(&key(1), &key(2), 3, 4, &key(9), b"cfg", 6)),
            ("owner config", intent_digest(&key(1), &key(2), 3, 4, &key(5), b"other", 6)),
            ("expiry", intent_digest(&key(1), &key(2), 3, 4, &key(5), b"cfg", 9)),
        ];
        for (field, digest) in variants {
            assert_ne!(base, digest, "{field} does not affect the intent digest");
        }
    }

    /// An epoch of 0x...01 with a nonce of 0x...00 must not hash like the reverse. Fixed-width
    /// encoding is what rules this out, and it is the kind of bug that only shows up as a
    /// cross-epoch replay years later.
    #[test]
    fn adjacent_fixed_width_fields_cannot_be_transposed() {
        let a = intent_digest(&key(1), &key(2), 1, 0, &key(5), b"", 0);
        let b = intent_digest(&key(1), &key(2), 0, 1, &key(5), b"", 0);
        assert_ne!(a, b);
    }

    /// `new_owner_config` is the one variable-length input. Pre-hashing it means a longer config
    /// cannot shift the boundary with the field that follows.
    #[test]
    fn a_variable_length_config_cannot_shift_the_expiry_boundary() {
        let a = intent_digest(&key(1), &key(2), 0, 0, &key(5), b"AB", 0);
        let b = intent_digest(&key(1), &key(2), 0, 0, &key(5), b"A", 0);
        assert_ne!(a, b);
    }

    /// The three digests must never collide, or a registration signature could be replayed as an
    /// intent. Distinct domain strings are what guarantees it.
    #[test]
    fn the_three_domains_are_disjoint() {
        let fingerprint = [7u8; 32];
        let reg = registration_digest(&key(1), &key(2), &key(3), &key(4), &fingerprint, 0);
        let intent = intent_digest(&key(1), &key(2), 0, 0, &key(4), b"", 0);
        let resume = resume_digest(&key(1), &key(2), &intent, 0);

        assert_ne!(reg, intent);
        assert_ne!(reg, resume);
        assert_ne!(intent, resume);
    }

    /// The attempt binding: the same intent, endorsed for a different attempt, is a different
    /// signature. Without this an endorsement banked before an abort would apply after it.
    #[test]
    fn a_resume_endorsement_is_bound_to_one_attempt() {
        let intent = [3u8; 32];
        assert_ne!(
            resume_digest(&key(1), &key(2), &intent, 7),
            resume_digest(&key(1), &key(2), &intent, 8),
        );
    }
}
