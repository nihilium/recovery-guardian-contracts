/**
 * The entire surface `@nihilium-recovery/settlement-evm` is allowed to import from this package:
 * generated ABIs, an address book, and the enum ordinals the contracts use.
 *
 * Nothing here reaches into Solidity source, and nothing in Solidity reaches into TypeScript. That
 * is the whole point of the boundary — the contracts remain independently auditable, and a Solidity
 * change reaches the SDK only through a regenerated artifact.
 */

export { recoveryModuleAbi, gradualVetoAbi } from "./abi.generated.js";

/**
 * `GradualVeto.State` ordinals, as encoded on-chain.
 *
 * `NONE` has no counterpart in the TypeScript `VetoState` union: an attempt that does not exist is
 * represented there by the absence of a record rather than by a state. `toVetoState` is what bridges
 * the two, and it deliberately refuses to invent a state for `NONE`.
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

/** ERC-7579 module type ids. The recovery module is an executor, never a validator (see §8). */
export const ModuleType = {
    VALIDATOR: 1,
    EXECUTOR: 2,
    FALLBACK: 3,
    HOOK: 4,
} as const;

/**
 * Deployed addresses per chain id. Empty entries are chains the module is not deployed on yet;
 * an absent entry is not the same as the zero address, and callers must treat it as "not deployed".
 */
export const recoveryModuleAddresses: Record<number, string> = {
    // Anvil / local: deployed per-run, so no fixed address. Run `npm run deploy:anvil`.
    //
    // The address is the SAME on every chain, and that is the point of CREATE2 from a fixed salt:
    // one initcode hash (0x5104f032…) and one salt keccak256("nihilium-recovery-module-v2") give
    // one address everywhere, so this table records *where it is deployed*, not what it is called
    // there. Both entries below have been checked to hold byte-identical code.
    //
    // v2.0.0 — the veto clock counts wall-clock seconds rather than block heights.
    // Sepolia,      deployed 2026-09-09, block 11668779,  Etherscan-verified.
    11155111: "0x55c469aBe9D19db9f88ef023af759FF540B3bCD8",
    // Arbitrum One, deployed 2026-09-09, L2 block 503406623, Arbiscan-verified.
    42161: "0x55c469aBe9D19db9f88ef023af759FF540B3bCD8",
};

/**
 * Superseded deployments, kept because they are still on-chain and always will be.
 *
 * The module has no upgrade path by design, so "v2" is a *different contract at a different
 * address*, not a replacement. An account that installed v1 keeps running v1 with a block-counted
 * veto until its owner installs v2 and the old module is uninstalled. Anything reading a live
 * account's installed module needs to be able to recognise these, which is why they are recorded
 * rather than deleted.
 */
export const legacyRecoveryModuleAddresses: Record<string, Record<number, string>> = {
    // v1.0.0 — veto clock counted block heights. Superseded 2026-09-09.
    "1.0.0": {
        11155111: "0x00339522A395f0d0838Ad5cf979fAdc8B9c6269B",
        42161: "0x00339522A395f0d0838Ad5cf979fAdc8B9c6269B",
    },
};

export function recoveryModuleAddress(chainId: number): string {
    const address = recoveryModuleAddresses[chainId];
    if (!address) {
        throw new Error(
            `RecoveryModule is not deployed on chain ${chainId}. Deploy it with ` +
            `script/DeployRecoveryModule.s.sol and add the address to recoveryModuleAddresses.`,
        );
    }
    return address;
}
