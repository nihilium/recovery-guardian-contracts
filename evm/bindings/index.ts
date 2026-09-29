/**
 * The entire surface `@nihilium/recovery-settlement-evm` is allowed to import from this package:
 * generated ABIs, an address book, and the enum ordinals the contracts use.
 *
 * Nothing here reaches into Solidity source, and nothing in Solidity reaches into TypeScript. That
 * is the whole point of the boundary — the contracts remain independently auditable, and a Solidity
 * change reaches the SDK only through a regenerated artifact.
 */

export {
    recoveryModuleAbi,
    gradualVetoAbi,
    eip7702RecoveryAccountAbi,
} from "./abi.generated.js";

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
 * Deployed addresses per chain id. An absent entry is not the same as the zero address, and callers
 * must treat it as "not deployed".
 *
 * **One address per version, not one address everywhere.** CREATE2 from a fixed salt gives the same
 * address on every chain holding the *same* version — it does not survive a version bump, because a
 * changed initcode and a changed salt each move it on their own. So this table mixes versions, and
 * `recoveryModuleVersions` below says which one a chain runs. Read that before assuming two chains
 * behave alike.
 */
export const recoveryModuleAddresses: Record<number, string> = {
    // Anvil / local: deployed per-run, so no fixed address. Run `npm run deploy:anvil`.
    //
    // v2.0.0 — salt keccak256("nihilium-recovery-module-v2"), initcode 0x5104f032…
    // Both entries below have been checked to hold byte-identical code.
    // Sepolia,          deployed 2026-09-09, block 11668779,     Etherscan-verified.
    11155111: "0x55c469aBe9D19db9f88ef023af759FF540B3bCD8",
    // Arbitrum One,     deployed 2026-09-09, L2 block 503406623, Arbiscan-verified.
    42161: "0x55c469aBe9D19db9f88ef023af759FF540B3bCD8",
    //
    // v3.0.0 — salt keccak256("nihilium-recovery-module-v3"), initcode 0x135cfa1e…
    // Arbitrum Sepolia, deployed 2026-09-28, L2 block 11800972.
    421614: "0xb1e4b94804a0E770A8c84C2BD62B2Ee6F93AD4E9",
};

/**
 * Which version each chain in `recoveryModuleAddresses` runs.
 *
 * Kept beside the address rather than left implicit, because the difference decides whether a
 * signature can be replayed. v3 binds the EIP-712 `Resume` struct to a per-account `attemptSeq`
 * counter, so a resume signature cannot be reused against a later attempt on the same account; on
 * a v2 chain it can. Anything that signs or validates a resume has to know which of the two it is
 * talking to.
 */
export const recoveryModuleVersions: Record<number, string> = {
    11155111: "2.0.0",
    42161: "2.0.0",
    421614: "3.0.0",
};

/**
 * `Eip7702RecoveryAccount` deployments, per chain id.
 *
 * Its own table rather than a row in the module's: this is a different contract with its own
 * version line and its own salt, not another version of the same thing. An EOA delegates to one of
 * these addresses with a 7702 authorization, so the address is what a delegation commits to and it
 * cannot be swapped underneath one.
 */
export const eip7702AccountAddresses: Record<number, string> = {
    // v1.0.0 — salt keccak256("nihilium-7702-recovery-account-v1"), initcode 0xd920e41a…
    // Arbitrum Sepolia, deployed 2026-09-28, L2 block 11800986.
    421614: "0xF5768f61C8739727cf392C8655E0a67BEb25B872",
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

/** A security finding that affects a deployed version. Ids refer to the 2026-09-28 audit. */
export interface KnownIssue {
    readonly id: string;
    readonly severity: "high" | "medium" | "low";
    readonly summary: string;
}

const RESUME_REPLAY_ACROSS_PAUSES: KnownIssue = {
    id: "H-1",
    severity: "high",
    summary:
        "Resume signatures stay valid for the whole attempt: once one resume lands, anyone can " +
        "replay it to undo every later pause immediately, leaving only abort.",
};
const RESUME_REPLAY_ACROSS_ATTEMPTS: KnownIssue = {
    id: "H-2",
    severity: "high",
    summary:
        "Resume signatures are not bound to the attempt: an endorsement also lifts a pause on a " +
        "later attempt with the same intent, including after uninstall and reinstall.",
};
const ABORTED_INTENT_REOPENABLE: KnownIssue = {
    id: "M-1",
    severity: "medium",
    summary:
        "Abort does not spend the nonce: anyone can resubmit an aborted intent's public " +
        "signature and reopen the attempt until it expires.",
};
const UNBOUNDED_PAUSE: KnownIssue = {
    id: "M-2",
    severity: "medium",
    summary:
        "pauseCeilingSeconds bounds each pause, not the total: the pause authority can re-pause " +
        "after every ceiling and hold an attempt indefinitely unless the resume quorum acts.",
};
const RECOVERY_OWNER_MAY_HOLD_VETO_ROLE: KnownIssue = {
    id: "L-3",
    severity: "low",
    summary: "The recovery key is not checked against the veto roles, so it may also hold one.",
};

/**
 * Known issues per `RecoveryModule` version. A version absent from this table, or mapped to an
 * empty list, has none known. Anything reading an account's installed module should check this and
 * prompt a migration: there is no upgrade path, so a fix only reaches an account that installs the
 * fixed version.
 *
 * v1.0.0 differs from v2.0.0 only in its clock unit (block heights) and was not separately
 * re-audited; it is listed with v2's issues because it shares the same resume and abort logic.
 */
export const recoveryModuleKnownIssues: Record<string, readonly KnownIssue[]> = {
    "1.0.0": [
        RESUME_REPLAY_ACROSS_PAUSES, RESUME_REPLAY_ACROSS_ATTEMPTS, ABORTED_INTENT_REOPENABLE,
        UNBOUNDED_PAUSE, RECOVERY_OWNER_MAY_HOLD_VETO_ROLE,
    ],
    "2.0.0": [
        RESUME_REPLAY_ACROSS_PAUSES, RESUME_REPLAY_ACROSS_ATTEMPTS, ABORTED_INTENT_REOPENABLE,
        UNBOUNDED_PAUSE, RECOVERY_OWNER_MAY_HOLD_VETO_ROLE,
    ],
    "3.0.0": [
        RESUME_REPLAY_ACROSS_PAUSES, ABORTED_INTENT_REOPENABLE, UNBOUNDED_PAUSE,
        RECOVERY_OWNER_MAY_HOLD_VETO_ROLE,
    ],
    "4.0.0": [],
};

/** Known issues per `Eip7702RecoveryAccount` version; see `recoveryModuleKnownIssues`. */
export const eip7702AccountKnownIssues: Record<string, readonly KnownIssue[]> = {
    "1.0.0": [
        RESUME_REPLAY_ACROSS_PAUSES, ABORTED_INTENT_REOPENABLE, UNBOUNDED_PAUSE,
        {
            id: "M-3",
            severity: "medium",
            summary:
                "register() does not cancel an in-flight attempt: rotating away a compromised " +
                "recovery key leaves that key's attempt running, and the new veto config re-times " +
                "it (it can become executable at once, or make abort revert).",
        },
        {
            id: "M-4",
            severity: "medium",
            summary:
                "The delegated EOA rejects plain ETH transfers and safe ERC-721/1155 transfers, " +
                "and implements no ERC-1271.",
        },
        {
            id: "L-2",
            severity: "low",
            summary: "A contract newOwner (a Safe, say) can never sign, so it cannot operate the account.",
        },
        RECOVERY_OWNER_MAY_HOLD_VETO_ROLE,
    ],
    "2.0.0": [],
};

export function recoveryModuleVersion(chainId: number): string {
    const version = recoveryModuleVersions[chainId];
    if (!version) {
        throw new Error(
            `RecoveryModule is not deployed on chain ${chainId}, so it has no version there.`,
        );
    }
    return version;
}

export function eip7702AccountAddress(chainId: number): string {
    const address = eip7702AccountAddresses[chainId];
    if (!address) {
        throw new Error(
            `Eip7702RecoveryAccount is not deployed on chain ${chainId}. Deploy it with ` +
            `script/DeployEip7702RecoveryAccount.s.sol and add the address to ` +
            `eip7702AccountAddresses.`,
        );
    }
    return address;
}

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
