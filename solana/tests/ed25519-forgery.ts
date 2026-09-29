import { Ed25519Program, TransactionInstruction } from "@solana/web3.js";

/**
 * The forgery the program's cross-instruction check exists to stop.
 *
 * The precompile reads the signed message from `messageInstructionIndex`, but a program doing its
 * own introspection reads from the instruction it was handed. Point those at two different places
 * and they disagree about what was signed — so a signature the key holder produced over *anything*
 * can be presented as a signature over the digest the program expects:
 *
 *   - the precompile verifies `signature` against the bytes in the **other** instruction, and passes
 *   - the program reads `decoyMessage` from **this** instruction, sees the digest it wanted, and,
 *     without the check, accepts
 *
 * Any previously published signature by the recovery key would then authorise any recovery. The
 * check that every offset references the instruction under inspection is what closes it.
 */
export function ed25519ForgeryAcrossInstructions(args: {
    publicKey: Uint8Array;
    /** A real signature, over the bytes the *other* instruction carries. */
    signature: Uint8Array;
    /** What this instruction will appear to carry, at the same offset. */
    decoyMessage: Uint8Array;
    messageInstructionIndex: number;
    messageOffset: number;
}): TransactionInstruction {
    const HEADER = 2;
    const OFFSETS = 14;
    const CURRENT = 0xffff;
    const publicKeyOffset = HEADER + OFFSETS;
    const signatureOffset = publicKeyOffset + 32;

    const size = Math.max(
        signatureOffset + 64,
        args.messageOffset + args.decoyMessage.length,
    );
    const data = Buffer.alloc(size);
    data.writeUInt8(1, 0);
    data.writeUInt8(0, 1);
    data.writeUInt16LE(signatureOffset, HEADER);
    data.writeUInt16LE(CURRENT, HEADER + 2);
    data.writeUInt16LE(publicKeyOffset, HEADER + 4);
    data.writeUInt16LE(CURRENT, HEADER + 6);
    data.writeUInt16LE(args.messageOffset, HEADER + 8);
    data.writeUInt16LE(args.decoyMessage.length, HEADER + 10);
    data.writeUInt16LE(args.messageInstructionIndex, HEADER + 12);
    Buffer.from(args.publicKey).copy(data, publicKeyOffset);
    Buffer.from(args.signature).copy(data, signatureOffset);
    // The decoy sits where the program will look, while the precompile looks elsewhere.
    Buffer.from(args.decoyMessage).copy(data, args.messageOffset);

    return new TransactionInstruction({ keys: [], programId: Ed25519Program.programId, data });
}

/** Where `signAll` puts the message for a single-signature instruction: 2 + 14 + 32 + 64. */
export const SINGLE_SIGNATURE_MESSAGE_OFFSET = 112;
