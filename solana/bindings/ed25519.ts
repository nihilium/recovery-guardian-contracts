import { Ed25519Program, TransactionInstruction } from "@solana/web3.js";
import nacl from "tweetnacl";

/**
 * Build one ed25519 precompile instruction carrying several signatures.
 *
 * `@solana/web3.js` only offers `Ed25519Program.createInstructionWithPrivateKey`, which produces a
 * single-signature instruction. A k-of-n resume needs k signatures that the program can verify as
 * one unit — it checks `num_signatures == expected.len()` exactly, so k separate instructions would
 * not do, and would cost more bytes besides.
 *
 * **Identical messages are stored once and shared**, which is what keeps a resume inside Solana's
 * 1232-byte transaction limit: every quorum member signs the same 32-byte digest, so each extra
 * signer costs 14 bytes of offsets + 64 of signature + 32 of public key = 110, rather than 142.
 * That is the arithmetic behind `MAX_RESUME_MEMBERS`.
 *
 * Every offset references this instruction (`0xFFFF`), which is what the program requires: it will
 * not vouch for bytes living in an instruction it has not read.
 *
 * Layout, little-endian throughout:
 *
 *     0: num_signatures (u8)          1: padding (u8)
 *     2: per signature, 14 bytes: sig_off, sig_ix, pk_off, pk_ix, msg_off, msg_size, msg_ix
 */
export function ed25519MultiSignatureInstruction(
    entries: Array<{ publicKey: Uint8Array; signature: Uint8Array; message: Uint8Array }>,
): TransactionInstruction {
    const HEADER = 2;
    const OFFSETS = 14;
    const CURRENT = 0xffff;

    const body: number[] = [];
    const bodyStart = HEADER + entries.length * OFFSETS;
    const messageOffsets = new Map<string, number>();

    const offsets = entries.map((entry) => {
        const publicKeyOffset = bodyStart + body.length;
        body.push(...entry.publicKey);
        const signatureOffset = bodyStart + body.length;
        body.push(...entry.signature);

        const key = Buffer.from(entry.message).toString("hex");
        let messageOffset = messageOffsets.get(key);
        if (messageOffset === undefined) {
            messageOffset = bodyStart + body.length;
            messageOffsets.set(key, messageOffset);
            body.push(...entry.message);
        }
        return { publicKeyOffset, signatureOffset, messageOffset, messageSize: entry.message.length };
    });

    const data = Buffer.alloc(bodyStart + body.length);
    data.writeUInt8(entries.length, 0);
    data.writeUInt8(0, 1);
    offsets.forEach((o, i) => {
        let at = HEADER + i * OFFSETS;
        data.writeUInt16LE(o.signatureOffset, at);
        data.writeUInt16LE(CURRENT, at + 2);
        data.writeUInt16LE(o.publicKeyOffset, at + 4);
        data.writeUInt16LE(CURRENT, at + 6);
        data.writeUInt16LE(o.messageOffset, at + 8);
        data.writeUInt16LE(o.messageSize, at + 10);
        data.writeUInt16LE(CURRENT, at + 12);
    });
    Buffer.from(body).copy(data, bodyStart);

    return new TransactionInstruction({
        keys: [],
        programId: Ed25519Program.programId,
        data,
    });
}

/** Sign `message` with each keypair and pack the results into one precompile instruction. */
export function signAll(
    signers: Array<{ publicKey: { toBytes(): Uint8Array }; secretKey: Uint8Array }>,
    message: Uint8Array,
): TransactionInstruction {
    return ed25519MultiSignatureInstruction(
        signers.map((signer) => ({
            publicKey: signer.publicKey.toBytes(),
            signature: nacl.sign.detached(message, signer.secretKey),
            message,
        })),
    );
}
