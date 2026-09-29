//! Detached ed25519 signature verification, by instruction introspection.
//!
//! This is the part with no EVM counterpart, and the one place a subtle bug is fatal.
//!
//! On EVM, `ecrecover` is a function: hand it a digest and a signature and it returns *who signed*,
//! which the caller compares against the key it expects. **Solana's ed25519 precompile is not a
//! function and cannot be called.** It is a separate instruction in the same transaction that fails
//! the transaction if any signature it was handed is invalid, and this program reads it back
//! afterwards through the instructions sysvar.
//!
//! The consequence is the whole of this module: *the precompile verifies whatever it was asked to
//! verify*. A program that merely confirms "a valid ed25519 instruction is present" accepts an
//! attacker's own key signing an attacker's own message — the signature is perfectly valid, it
//! simply says nothing about this vault. Security here is entirely the program re-deriving what
//! **must** have been signed and asserting that the precompile was asked exactly that, for exactly
//! the expected signers, and for nothing else.
//!
//! ## Instruction data layout
//!
//! ```text
//! offset 0  : num_signatures (u8)
//! offset 1  : padding        (u8)
//! offset 2  : Ed25519SignatureOffsets[num_signatures], 14 bytes each, little-endian:
//!               0: signature_offset             (u16)
//!               2: signature_instruction_index  (u16)
//!               4: public_key_offset            (u16)
//!               6: public_key_instruction_index (u16)
//!               8: message_data_offset          (u16)
//!              10: message_data_size            (u16)
//!              12: message_instruction_index    (u16)
//! ```
//!
//! An instruction index of `u16::MAX` means "this instruction".
//!
//! ## Why signature malleability does not matter here
//!
//! Nothing in this module keys off signature *bytes*. The binding is `(public key, message)`
//! equality against values the program derived itself, so a second valid encoding of the same
//! signature authorises exactly what the first one did and nothing more. There is no nonce, no
//! signature-hash index, and no replay surface built on signature identity.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::ed25519_program;
use anchor_lang::solana_program::sysvar::instructions::load_instruction_at_checked;

/// Bytes per `Ed25519SignatureOffsets` entry.
const OFFSETS_LEN: usize = 14;
/// Where the offsets array starts, after `num_signatures` and its padding byte.
const HEADER_LEN: usize = 2;
const SIGNATURE_LEN: usize = 64;
const PUBKEY_LEN: usize = 32;
/// Every digest this program signs is a 32-byte hash. Pinning the size means a caller cannot point
/// the precompile at a longer message whose first 32 bytes happen to match.
pub const MESSAGE_LEN: usize = 32;

#[error_code]
pub enum VerifyError {
    #[msg("the instruction referenced is not the ed25519 precompile")]
    NotEd25519Program,
    #[msg("the ed25519 instruction verifies a different number of signatures than required")]
    WrongSignatureCount,
    #[msg("the ed25519 instruction is truncated")]
    MalformedInstruction,
    #[msg("an ed25519 offset points outside the instruction that carries it")]
    OffsetOutOfBounds,
    #[msg("an ed25519 offset references a different instruction, which this program cannot vouch for")]
    ForeignInstructionReference,
    #[msg("the signed message is not a 32-byte digest")]
    WrongMessageLength,
    #[msg("a signature is over a different message than the one this program derived")]
    MessageMismatch,
    #[msg("a signature is by a different key than the one required here")]
    SignerMismatch,
}

/// Read `data[offset .. offset + len]`, or fail rather than panic.
///
/// Every slice in this module goes through here. A bounds check that is merely *usually* present is
/// how this pattern turns into a panic on attacker-chosen input.
fn checked_slice(data: &[u8], offset: usize, len: usize) -> Result<&[u8]> {
    let end = offset.checked_add(len).ok_or(VerifyError::OffsetOutOfBounds)?;
    data.get(offset..end)
        .ok_or_else(|| error!(VerifyError::OffsetOutOfBounds))
}

fn read_u16(data: &[u8], at: usize) -> Result<u16> {
    let bytes = checked_slice(data, at, 2)?;
    Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
}

/// Assert that the ed25519 instruction at `ix_index` verified exactly `expected`, in that order.
///
/// `expected` pairs each required signer with the digest it must have signed. Order is positional
/// and the caller is responsible for it: for a resume the caller passes the quorum members in the
/// same order the client built the precompile instruction, having already checked that they are
/// distinct members. That check does not belong here — this module knows about signatures, not
/// about quorums.
pub fn verify_detached(
    instructions_sysvar: &AccountInfo,
    ix_index: u8,
    expected: &[(Pubkey, [u8; 32])],
) -> Result<()> {
    let ix = load_instruction_at_checked(usize::from(ix_index), instructions_sysvar)?;
    require_keys_eq!(ix.program_id, ed25519_program::ID, VerifyError::NotEd25519Program);

    let data = ix.data.as_slice();
    let declared = *data.first().ok_or_else(|| error!(VerifyError::MalformedInstruction))?;

    // Exact, not "at least". Too few would leave a required signer unverified; too many would let
    // an extra signature ride along unchecked, which for a k-of-n resume is the difference between
    // k members endorsing and one member endorsing k times under different keys.
    require!(
        usize::from(declared) == expected.len(),
        VerifyError::WrongSignatureCount
    );

    for (slot, (signer, digest)) in expected.iter().enumerate() {
        let base = HEADER_LEN
            .checked_add(slot.checked_mul(OFFSETS_LEN).ok_or(VerifyError::MalformedInstruction)?)
            .ok_or(VerifyError::MalformedInstruction)?;
        // Fail before reading rather than after: a truncated offsets array is attacker-shaped.
        require!(
            data.len() >= base.saturating_add(OFFSETS_LEN),
            VerifyError::MalformedInstruction
        );

        let signature_offset = read_u16(data, base)?;
        let signature_ix = read_u16(data, base.saturating_add(2))?;
        let public_key_offset = read_u16(data, base.saturating_add(4))?;
        let public_key_ix = read_u16(data, base.saturating_add(6))?;
        let message_offset = read_u16(data, base.saturating_add(8))?;
        let message_size = read_u16(data, base.saturating_add(10))?;
        let message_ix = read_u16(data, base.saturating_add(12))?;

        // Everything must live inside *this* instruction's data.
        //
        // The precompile will happily take its signature from one instruction, its key from
        // another and its message from a third. Allowing that would mean this program vouching for
        // bytes it has not read, and reasoning about cross-instruction offsets is exactly where
        // this pattern goes wrong in the wild. Confining all three to the instruction under
        // inspection removes the entire class.
        for referenced in [signature_ix, public_key_ix, message_ix] {
            require!(
                referenced == u16::MAX || referenced == u16::from(ix_index),
                VerifyError::ForeignInstructionReference
            );
        }

        require!(
            usize::from(message_size) == MESSAGE_LEN,
            VerifyError::WrongMessageLength
        );

        let signed_key = checked_slice(data, usize::from(public_key_offset), PUBKEY_LEN)?;
        let signed_message = checked_slice(data, usize::from(message_offset), MESSAGE_LEN)?;
        // Bounds-checked though never compared: a signature pointing off the end of the
        // instruction is malformed, and saying so beats letting the precompile's own error surface
        // as something unrelated.
        let _ = checked_slice(data, usize::from(signature_offset), SIGNATURE_LEN)?;

        require!(signed_message == digest, VerifyError::MessageMismatch);
        require!(signed_key == signer.as_ref(), VerifyError::SignerMismatch);
    }

    Ok(())
}
