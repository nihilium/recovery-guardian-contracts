/**
 * The entire surface `@nihilium/recovery-settlement-solana` is allowed to import from this package:
 * the generated IDL, an address book, the PDA derivations, and the client half of what a signature
 * commits to.
 *
 * Nothing here reaches into Rust source, and nothing in Rust reaches into TypeScript. That is the
 * whole point of the boundary — the programs remain independently auditable, and a Rust change
 * reaches the SDK only through a regenerated artifact. `evm/bindings/index.ts` keeps the same rule.
 *
 * The digest builders and the ed25519 packer are here rather than in the SDK because they are the
 * counterpart of program code: get either wrong and every signature is rejected, or worse, accepted
 * for the wrong reason. Keeping them beside the program is what lets one commit change both.
 */

import { PublicKey } from "@solana/web3.js";

export {
    ed25519MultiSignatureInstruction,
    signAll,
} from "./ed25519";

export { clusterTag, digestsFor, vetoFingerprint } from "./digest";
export type { ClusterName, Intent, VetoConfig } from "./digest";

/**
 * The generated IDL, as a value, and the type that goes with it.
 *
 * The EVM sibling exports `recoveryModuleAbi` from a generated `.ts`; Anchor generates `.json` for
 * the value and a separate `.ts` for the type, so this re-exports both. Consumers need the value at
 * runtime — `new Program(idl, provider)` reads `idl.address` — and the type to get anything back
 * from `program.methods`.
 *
 * **Use the type.** Without it every instruction is `Program<Idl>` and `program.methods.register(…)`
 * takes `any[]`, which is exactly where a wrong argument order becomes a silent encoding bug rather
 * than a compile error. `register` alone takes a pubkey, a config struct, a `u64` and a `u8`; three
 * of those four are plausible in the wrong place.
 *
 * ```ts
 * import { recoveryVaultIdl, type NihiliumRecoveryVault } from "@nihilium/recovery-onchain-solana";
 * const program = new Program<NihiliumRecoveryVault>(recoveryVaultIdl, provider);
 * ```
 *
 * `recoveryVaultIdl.address` is the address of the build this IDL came from.
 * `recoveryVaultProgramIds` stays the address book — prefer it when you know the cluster.
 */
import idlJson from "./idl.generated.json";
import type { NihiliumRecoveryVault } from "./idl.generated.js";

export const recoveryVaultIdl = idlJson as NihiliumRecoveryVault;
export type { NihiliumRecoveryVault };

/**
 * Named arguments for `register`, `initiate_recovery` and `execute_recovery`.
 *
 * Anchor's generated type cannot check those three — a `defined` struct argument collapses the
 * whole tuple to `any`, so neither their types nor their *arity* is enforced. See `args.ts`.
 */
export {
    executeRecoveryArgs,
    initiateRecoveryArgs,
    registerArgs,
} from "./args";
export type { IntentArg, VetoConfigArg } from "./args";

/**
 * `gradual_veto::State` ordinals, as stored on-chain.
 *
 * Identical to `evm/bindings/index.ts`'s and to the Solidity enum's, because all three are pinned
 * to the same trace fixture. `NONE` has no counterpart in the TypeScript `VetoState` union: an
 * attempt that does not exist is represented there by the absence of a record rather than a state.
 */
export const VetoStateOrdinal = {
    NONE: 0,
    INITIATED: 1,
    PAUSED: 2,
    EXECUTABLE: 3,
    EXECUTED: 4,
    ABORTED: 5,
} as const;

export type VetoStateOrdinal = (typeof VetoStateOrdinal)[keyof typeof VetoStateOrdinal];

/**
 * Most resume-quorum members a vault may name.
 *
 * Mirrors `gradual_veto::MAX_RESUME_MEMBERS`, and exists for a reason with no EVM counterpart: a
 * resume carries k detached signatures inside a 1232-byte transaction. A wallet offering more
 * guardians than this would build configurations whose pause could never be lifted.
 */
export const MAX_RESUME_MEMBERS = 8;

/**
 * Deployed program ids per cluster. An absent entry means "not deployed", which is not the same as
 * the default address and must not be treated as one.
 *
 * **Unlike EVM, this is not derivable from the source.** A Solana program id is a keypair, so
 * CREATE2's "anyone can recompute the address from the code" property does not port. The substitute
 * is a `solana-verify` reproducible build, whose hash is recorded per deployment alongside the id.
 */
export const recoveryVaultProgramIds: Record<string, string> = {
    // Localnet is deployed per-run from target/deploy, so it has no fixed address.
    //
    // A program id here says nothing about what is deployed at it -- see deployments/README.md.
    // Check the binary's cluster tag matches the cluster you are talking to before trusting one.
    devnet: "DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG",
    // "mainnet-beta": not deployed. It must be immutable (upgrade authority None) before it is.
};

export const VAULT_SEED = Buffer.from("vault");
export const SOL_SEED = Buffer.from("sol");

/**
 * The vault's address.
 *
 * Seeded by `creator` and `vaultId` and **never by `owner`**: a recovery rotates the owner, and if
 * the owner were in the seeds the vault's address would move with it. The SDK derives recovery keys
 * against this address (`accountId` is a KDF input), so an address that moved would orphan every
 * seal made before the recovery.
 */
export function vaultAddress(
    programId: PublicKey,
    creator: PublicKey,
    vaultId: Uint8Array,
): [PublicKey, number] {
    return PublicKey.findProgramAddressSync(
        [VAULT_SEED, creator.toBuffer(), Buffer.from(vaultId)],
        programId,
    );
}

/** The system-owned account that actually holds the vault's lamports. */
export function vaultSolAddress(programId: PublicKey, vault: PublicKey): [PublicKey, number] {
    return PublicKey.findProgramAddressSync([SOL_SEED, vault.toBuffer()], programId);
}
