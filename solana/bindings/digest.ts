import { sha256 as nobleSha256 } from "@noble/hashes/sha2";
import { PublicKey } from "@solana/web3.js";

/**
 * The client half of `crates/nihilium-recovery-common/src/digest.rs`.
 *
 * Deliberately written out rather than derived from the IDL: these are what a signature commits
 * to, so a client that computed them from the same source as the program would not be an
 * independent check at all. If the two ever disagree, every test that signs anything fails.
 */

/**
 * Which deployment a signature is valid on. Must match `cluster.rs`.
 *
 * **Deliberately has no default.** The program bakes exactly one tag in at build time and refuses
 * to compile with none or with two; a client that guessed would produce signatures the program
 * silently rejects, or — far worse if the tags ever matched — signatures valid on a cluster the
 * owner never agreed to. So the choice is made once, explicitly, by `digestsFor`.
 */
export type ClusterName = "localnet" | "devnet" | "mainnet-beta";

export function clusterTag(cluster: ClusterName): Buffer {
    const name = `nihilium-cluster:${cluster}`;
    if (name.length > 32) throw new Error(`cluster tag "${name}" exceeds 32 bytes`);
    return Buffer.concat([Buffer.from(name), Buffer.alloc(32 - name.length)]);
}

const DOMAIN_REGISTER = "nihilium-recovery-solana-register-v1";
const DOMAIN_INTENT = "nihilium-recovery-solana-intent-v1";
const DOMAIN_RESUME = "nihilium-recovery-solana-resume-v1";

function lengthPrefixed(value: string): Buffer {
    const bytes = Buffer.from(value);
    const length = Buffer.alloc(4);
    length.writeUInt32LE(bytes.length);
    return Buffer.concat([length, bytes]);
}

/**
 * Deliberately `@noble/hashes` rather than `node:crypto`.
 *
 * These digests are computed wherever a signature is made — including in a browser wallet — so the
 * one hash this package needs must not drag in a Node built-in. `@noble/hashes` is isomorphic and is
 * already what the SDK hashes with everywhere else.
 */
function sha256(parts: Buffer[]): Buffer {
    const hash = nobleSha256.create();
    for (const part of parts) hash.update(part);
    return Buffer.from(hash.digest());
}

function u64(value: number | bigint): Buffer {
    const out = Buffer.alloc(8);
    out.writeBigUInt64LE(BigInt(value));
    return out;
}

function i64(value: number | bigint): Buffer {
    const out = Buffer.alloc(8);
    out.writeBigInt64LE(BigInt(value));
    return out;
}

export interface VetoConfig {
    pauseAuthority: PublicKey;
    abortAuthority: PublicKey;
    resumeMembers: PublicKey[];
    resumeThreshold: number;
    timelockSeconds: number;
    pauseCeilingSeconds: number;
}

export function vetoFingerprint(veto: VetoConfig): Buffer {
    const count = Buffer.alloc(4);
    count.writeUInt32LE(veto.resumeMembers.length);
    return sha256([
        veto.pauseAuthority.toBuffer(),
        veto.abortAuthority.toBuffer(),
        count,
        ...veto.resumeMembers.map((m) => m.toBuffer()),
        Buffer.from([veto.resumeThreshold]),
        u64(veto.timelockSeconds),
        u64(veto.pauseCeilingSeconds),
    ]);
}

function registrationDigestWith(
    tag: Buffer,
    programId: PublicKey,
    vault: PublicKey,
    owner: PublicKey,
    recoveryOwner: PublicKey,
    fingerprint: Buffer,
    configNonce: number | bigint,
): Buffer {
    return sha256([
        lengthPrefixed(DOMAIN_REGISTER),
        tag,
        programId.toBuffer(),
        vault.toBuffer(),
        owner.toBuffer(),
        recoveryOwner.toBuffer(),
        fingerprint,
        u64(configNonce),
    ]);
}

export interface Intent {
    newOwner: PublicKey;
    newOwnerConfig: Buffer;
    epoch: number;
    nonce: number;
    expiry: number;
}

function intentDigestWith(
    tag: Buffer,
    programId: PublicKey,
    vault: PublicKey,
    intent: Intent,
): Buffer {
    return sha256([
        lengthPrefixed(DOMAIN_INTENT),
        tag,
        programId.toBuffer(),
        vault.toBuffer(),
        u64(intent.epoch),
        u64(intent.nonce),
        intent.newOwner.toBuffer(),
        sha256([intent.newOwnerConfig]),
        i64(intent.expiry),
    ]);
}

function resumeDigestWith(
    tag: Buffer,
    programId: PublicKey,
    vault: PublicKey,
    intentDigestBytes: Buffer,
    attemptSeq: number,
): Buffer {
    return sha256([
        lengthPrefixed(DOMAIN_RESUME),
        tag,
        programId.toBuffer(),
        vault.toBuffer(),
        intentDigestBytes,
        u64(attemptSeq),
    ]);
}

/**
 * The three digest builders, bound to one cluster.
 *
 * Bind this once, from the same value the program was built with, and pass it around. The
 * alternative — a cluster argument on every call — is one that eventually gets defaulted.
 */
export function digestsFor(cluster: ClusterName) {
    const tag = clusterTag(cluster);
    return {
        cluster,
        tag,
        registrationDigest: (
            programId: PublicKey, vault: PublicKey, owner: PublicKey,
            recoveryOwner: PublicKey, fingerprint: Buffer, configNonce: number | bigint,
        ) => registrationDigestWith(
            tag, programId, vault, owner, recoveryOwner, fingerprint, configNonce,
        ),
        intentDigest: (programId: PublicKey, vault: PublicKey, intent: Intent) =>
            intentDigestWith(tag, programId, vault, intent),
        resumeDigest: (
            programId: PublicKey, vault: PublicKey, intentDigestBytes: Buffer, attemptSeq: number,
        ) => resumeDigestWith(tag, programId, vault, intentDigestBytes, attemptSeq),
    };
}
