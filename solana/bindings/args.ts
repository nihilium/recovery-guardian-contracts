import { PublicKey } from "@solana/web3.js";

/**
 * Named arguments for the instructions Anchor's generated type cannot check.
 *
 * **Why this file exists.** `Program<NihiliumRecoveryVault>` checks instruction names, account
 * names, and argument arity and types — but only for instructions whose arguments are all
 * primitives or arrays. An argument of a `defined` struct type collapses the whole tuple to `any`,
 * so `register`, `initiate_recovery` and `execute_recovery` get **no argument checking at all**,
 * not even arity. Those are the three that matter most:
 *
 * ```ts
 * program.methods.register(recoveryOwner);                    // compiles. 1 of 4 arguments.
 * program.methods.register(owner, veto, 0, new BN(0));        // compiles. u64 and u8 transposed.
 * ```
 *
 * Passing the arguments by name makes both impossible, and the spread hands Anchor the positional
 * tuple it wants:
 *
 * ```ts
 * program.methods.register(...registerArgs({
 *     recoveryOwner, veto, configNonce: new BN(0), ed25519Index: 0,
 * }))
 * ```
 *
 * **Generic over the big-number type** rather than importing `BN`, so this package keeps no Anchor
 * or bn.js dependency. Pass `BN` values and `Big` infers as `BN`; the field order below is the only
 * thing that has to match the program, and it is checked by `onchain/solana/tests/`.
 */

/** `VetoConfigAccount`, as the instruction takes it. `Big` is `BN` in practice. */
export interface VetoConfigArg<Big = unknown> {
    pauseAuthority: PublicKey;
    abortAuthority: PublicKey;
    /** At most `MAX_RESUME_MEMBERS`; registration refuses more. */
    resumeMembers: PublicKey[];
    resumeThreshold: number;
    timelockSeconds: Big;
    pauseCeilingSeconds: Big;
}

/** `Intent`, as the instruction takes it. */
export interface IntentArg<Big = unknown> {
    newOwner: PublicKey;
    /** Chain-native owner configuration. Opaque to the program; hashed into the intent digest. */
    newOwnerConfig: Uint8Array;
    epoch: Big;
    nonce: Big;
    /** Unix seconds. */
    expiry: Big;
}

/**
 * `register(recovery_owner, veto, config_nonce, ed25519_index)`.
 *
 * `configNonce` must equal the vault's current `config_nonce`, and `ed25519Index` is the position
 * of the `Ed25519SigVerify` instruction in the transaction — not a signature count, and not the
 * signer's index. Getting those two the wrong way round is the transposition this exists to stop.
 */
export function registerArgs<Big>(args: {
    recoveryOwner: PublicKey;
    veto: VetoConfigArg<Big>;
    configNonce: Big;
    ed25519Index: number;
}): [PublicKey, VetoConfigArg<Big>, Big, number] {
    return [args.recoveryOwner, args.veto, args.configNonce, args.ed25519Index];
}

/** `initiate_recovery(intent, ed25519_index)`. */
export function initiateRecoveryArgs<Big>(args: {
    intent: IntentArg<Big>;
    ed25519Index: number;
}): [IntentArg<Big>, number] {
    return [args.intent, args.ed25519Index];
}

/** `execute_recovery(intent)`. The intent must be the one the attempt was opened for. */
export function executeRecoveryArgs<Big>(args: {
    intent: IntentArg<Big>;
}): [IntentArg<Big>] {
    return [args.intent];
}
