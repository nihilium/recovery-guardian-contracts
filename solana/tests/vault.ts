import * as anchor from "@coral-xyz/anchor";
import {
    ComputeBudgetProgram, Keypair, LAMPORTS_PER_SOL, PublicKey, SystemProgram,
    SYSVAR_INSTRUCTIONS_PUBKEY, Transaction,
} from "@solana/web3.js";
import { assert, expect } from "chai";
import { signAll } from "../bindings/ed25519";
import {
    ed25519ForgeryAcrossInstructions, SINGLE_SIGNATURE_MESSAGE_OFFSET,
} from "./ed25519-forgery";
import { Intent, VetoConfig, digestsFor, vetoFingerprint } from "../bindings/digest";
import nacl from "tweetnacl";

/**
 * End-to-end tests against a local validator.
 *
 * The timelock and ceiling are seconds rather than the days a real config would use: there is no
 * `vm.warp` on Solana, so time has to actually pass. The clock arithmetic itself is covered
 * exhaustively and instantly by the Rust differential replay in `crates/gradual-veto`; what these
 * tests are for is everything *around* it — the signature checks, the authority checks, the account
 * plumbing and the confinement property.
 */

const TIMELOCK = 4;
const CEILING = 3;

const sleep = (seconds: number) => new Promise((r) => setTimeout(r, seconds * 1000 + 500));

describe("nihilium-recovery-vault", () => {
    // Bound explicitly: these run against a localnet build, and the tag is what separates it from
    // a devnet or mainnet deployment of the same source.
    const { registrationDigest, intentDigest, resumeDigest } = digestsFor("localnet");

    anchor.setProvider(anchor.AnchorProvider.env());
    const provider = anchor.getProvider() as anchor.AnchorProvider;
    // Untyped on purpose: the generated IDL types make Anchor's builder recurse past TypeScript's
    // instantiation limit, and what these tests assert is on-chain behaviour rather than types.
    const program = anchor.workspace.nihiliumRecoveryVault as any;
    const programId = program.programId;

    /** `VetoConfig` in the shape Anchor wants: u64 fields as BN. */
    const vetoArgOf = (veto: VetoConfig) => ({
        pauseAuthority: veto.pauseAuthority,
        abortAuthority: veto.abortAuthority,
        resumeMembers: veto.resumeMembers,
        resumeThreshold: veto.resumeThreshold,
        timelockSeconds: new anchor.BN(veto.timelockSeconds),
        pauseCeilingSeconds: new anchor.BN(veto.pauseCeilingSeconds),
    });

    const intentArg = (intent: Intent) => ({
        newOwner: intent.newOwner,
        newOwnerConfig: intent.newOwnerConfig,
        epoch: new anchor.BN(intent.epoch),
        nonce: new anchor.BN(intent.nonce),
        expiry: new anchor.BN(intent.expiry),
    });

    /** A fresh, registered vault with a known recovery key and veto quorum. */
    async function freshVault(overrides: { timelock?: number; ceiling?: number } = {}) {
        const creator = Keypair.generate();
        const recoveryOwner = Keypair.generate();
        const pauseAuthority = Keypair.generate();
        const abortAuthority = Keypair.generate();
        const g1 = Keypair.generate();
        const g2 = Keypair.generate();
        const vaultId = Buffer.alloc(16);
        vaultId.write("vault-" + Math.random().toString(36).slice(2, 10));

        for (const who of [creator, pauseAuthority, abortAuthority]) {
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(who.publicKey, LAMPORTS_PER_SOL),
            );
        }

        const [vault] = PublicKey.findProgramAddressSync(
            [Buffer.from("vault"), creator.publicKey.toBuffer(), vaultId], programId,
        );
        const [vaultSol] = PublicKey.findProgramAddressSync(
            [Buffer.from("sol"), vault.toBuffer()], programId,
        );

        await program.methods.createVault([...vaultId])
            .accounts({
                payer: provider.wallet.publicKey,
                creator: creator.publicKey,
                vault,
                vaultSol,
                systemProgram: SystemProgram.programId,
            })
            .signers([creator])
            .rpc();

        const veto: VetoConfig = {
            pauseAuthority: pauseAuthority.publicKey,
            abortAuthority: abortAuthority.publicKey,
            resumeMembers: [g1.publicKey, g2.publicKey],
            resumeThreshold: 2,
            timelockSeconds: overrides.timelock ?? TIMELOCK,
            pauseCeilingSeconds: overrides.ceiling ?? CEILING,
        };
        const vetoArg = vetoArgOf(veto);

        const digest = registrationDigest(
            programId, vault, creator.publicKey, recoveryOwner.publicKey, vetoFingerprint(veto), 0,
        );
        await program.methods
            .register(recoveryOwner.publicKey, vetoArg, new anchor.BN(0), 0)
            .accounts({ vault, owner: creator.publicKey, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
            .preInstructions([signAll([recoveryOwner], digest)])
            .signers([creator])
            .rpc();

        return {
            creator, recoveryOwner, pauseAuthority, abortAuthority, g1, g2,
            vaultId, vault, vaultSol, veto,
        };
    }

    /** Open a recovery against `ctx`, returning the intent and its digest. */
    async function initiate(ctx: any, newOwner?: PublicKey) {
        const account = await program.account.vault.fetch(ctx.vault);
        const intent: Intent = {
            newOwner: newOwner ?? Keypair.generate().publicKey,
            newOwnerConfig: Buffer.from("owner-config"),
            epoch: account.epoch.toNumber(),
            nonce: account.nonce.toNumber(),
            expiry: Math.floor(Date.now() / 1000) + 3600,
        };
        const digest = intentDigest(programId, ctx.vault, intent);
        const arg = intentArg(intent);
        await program.methods.initiateRecovery(arg, 0)
            .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
            .preInstructions([signAll([ctx.recoveryOwner], digest)])
            .rpc();
        return { intent, arg, digest };
    }

    const stateOf = async (vault: PublicKey) =>
        (await program.account.vault.fetch(vault)).attempt.state;

    // 0 = NONE, 1 = INITIATED, 2 = PAUSED, 3 = EXECUTABLE, 4 = EXECUTED, 5 = ABORTED

    describe("setup", () => {
        it("creates a vault whose address does not depend on the owner", async () => {
            const ctx = await freshVault();
            const account = await program.account.vault.fetch(ctx.vault);

            expect(account.creator.toBase58()).to.equal(ctx.creator.publicKey.toBase58());
            expect(account.owner.toBase58()).to.equal(ctx.creator.publicKey.toBase58());
            expect(account.registered).to.equal(true);
            expect(account.epoch.toNumber()).to.equal(0);
            // The seeds are creator + vault_id, never owner: a recovery must not move the address,
            // because the SDK derives keys against it.
            const [expected] = PublicKey.findProgramAddressSync(
                [Buffer.from("vault"), ctx.creator.publicKey.toBuffer(), ctx.vaultId], programId,
            );
            expect(expected.toBase58()).to.equal(ctx.vault.toBase58());
        });

        it("rotates the recovery key, which is the whole reason registration re-opens", async () => {
            // A recovery key is not fixed for the life of a vault. The Nihilium setup behind it can
            // change, and a completed recovery exposes the key it derived -- a vault that could
            // never be repointed would be left with a key nobody should trust and no way to replace
            // it, which is the absence of a recovery rather than a degraded one.
            const ctx = await freshVault();
            const replacement = Keypair.generate();

            const before = await program.account.vault.fetch(ctx.vault);
            expect(before.configNonce.toNumber()).to.equal(1);

            await program.methods.register(
                replacement.publicKey, vetoArgOf(ctx.veto), before.configNonce, 0,
            )
                .accounts({
                    vault: ctx.vault, owner: ctx.creator.publicKey,
                    instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                })
                .preInstructions([signAll([replacement], registrationDigest(
                    programId, ctx.vault, ctx.creator.publicKey, replacement.publicKey,
                    vetoFingerprint(ctx.veto), before.configNonce.toNumber(),
                ))])
                .signers([ctx.creator]).rpc();

            const after = await program.account.vault.fetch(ctx.vault);
            expect(after.recoveryOwner.toBase58()).to.equal(replacement.publicKey.toBase58());
            expect(after.configNonce.toNumber()).to.equal(2);

            // And the superseded key can no longer open a recovery.
            const intent: Intent = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("owner-config"),
                epoch: after.epoch.toNumber(),
                nonce: after.nonce.toNumber(),
                expiry: Math.floor(Date.now() / 1000) + 3600,
            };
            try {
                await program.methods.initiateRecovery(intentArg(intent), 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([ctx.recoveryOwner],
                        intentDigest(programId, ctx.vault, intent))])
                    .rpc();
                assert.fail("the superseded recovery key still opened a recovery");
            } catch (e: any) {
                expect(e.toString()).to.match(/SignerMismatch/);
            }
        });

        it("refuses a registration signature replayed from an earlier rotation", async () => {
            // Without the nonce the digest for (owner, recovery_owner, veto) is constant, so an old
            // signature could be replayed to revert a rotation -- putting back the very key the
            // owner had just decided to stop trusting. That is the one direction this must never go.
            const ctx = await freshVault();
            const stale = registrationDigest(
                programId, ctx.vault, ctx.creator.publicKey, ctx.recoveryOwner.publicKey,
                vetoFingerprint(ctx.veto), 0,
            );
            const replacement = Keypair.generate();
            const before = await program.account.vault.fetch(ctx.vault);
            await program.methods.register(
                replacement.publicKey, vetoArgOf(ctx.veto), before.configNonce, 0,
            )
                .accounts({
                    vault: ctx.vault, owner: ctx.creator.publicKey,
                    instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                })
                .preInstructions([signAll([replacement], registrationDigest(
                    programId, ctx.vault, ctx.creator.publicKey, replacement.publicKey,
                    vetoFingerprint(ctx.veto), before.configNonce.toNumber(),
                ))])
                .signers([ctx.creator]).rpc();

            // Replay the original registration verbatim, nonce and all.
            try {
                await program.methods.register(
                    ctx.recoveryOwner.publicKey, vetoArgOf(ctx.veto), new anchor.BN(0), 0,
                )
                    .accounts({
                        vault: ctx.vault, owner: ctx.creator.publicKey,
                        instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                    })
                    .preInstructions([signAll([ctx.recoveryOwner], stale)])
                    .signers([ctx.creator]).rpc();
                assert.fail("a rotation was reverted by replaying an old registration");
            } catch (e: any) {
                expect(e.toString()).to.match(/WrongConfigNonce/);
            }
        });

        it("refuses to rotate while a recovery is in flight", async () => {
            // The trap this closes: rotating the key does NOT stop an attempt the old key already
            // opened, because execute_recovery checks the committed intent digest and never
            // re-checks the signature. A rotation done *because* the old key was compromised would
            // otherwise leave the attacker's attempt running while the owner believed they had just
            // stopped it. Killing an attempt is abort's job, and abort is a different authority.
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            await initiate(ctx);

            const replacement = Keypair.generate();
            const before = await program.account.vault.fetch(ctx.vault);
            try {
                await program.methods.register(
                    replacement.publicKey, vetoArgOf(ctx.veto), before.configNonce, 0,
                )
                    .accounts({
                        vault: ctx.vault, owner: ctx.creator.publicKey,
                        instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                    })
                    .preInstructions([signAll([replacement], registrationDigest(
                        programId, ctx.vault, ctx.creator.publicKey, replacement.publicKey,
                        vetoFingerprint(ctx.veto), before.configNonce.toNumber(),
                    ))])
                    .signers([ctx.creator]).rpc();
                assert.fail("rotated the recovery key with an attempt in flight");
            } catch (e: any) {
                expect(e.toString()).to.match(/AttemptInFlight/);
            }

            // Abort first, then the rotation goes through.
            await program.methods.abort()
                .accounts({ vault: ctx.vault, abortAuthority: ctx.abortAuthority.publicKey })
                .signers([ctx.abortAuthority]).rpc();
            await program.methods.register(
                replacement.publicKey, vetoArgOf(ctx.veto), before.configNonce, 0,
            )
                .accounts({
                    vault: ctx.vault, owner: ctx.creator.publicKey,
                    instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                })
                .preInstructions([signAll([replacement], registrationDigest(
                    programId, ctx.vault, ctx.creator.publicKey, replacement.publicKey,
                    vetoFingerprint(ctx.veto), before.configNonce.toNumber(),
                ))])
                .signers([ctx.creator]).rpc();
            expect((await program.account.vault.fetch(ctx.vault)).recoveryOwner.toBase58())
                .to.equal(replacement.publicKey.toBase58());
        });

        it("lets the recovered owner replace the guardian that recovery just exposed", async () => {
            // The post-recovery hygiene path, and the answer to "can the guardian be replaced once
            // it is burnt?". `recover()` assembles the recovery key client-side, so completing one
            // exposes it -- and execute_recovery leaves `recovery_owner` pointing at that exposed
            // key while bumping the epoch. An exposed key can still sign a valid intent at the new
            // epoch, so the vault would be left permanently defended by the timelock alone.
            //
            // It works because execute_recovery makes the recovered party the owner, and the owner
            // is exactly who register requires. No veto key is involved at any point.
            const ctx = await freshVault();
            const newOwner = Keypair.generate();
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(newOwner.publicKey, LAMPORTS_PER_SOL),
            );

            const { arg } = await initiate(ctx, newOwner.publicKey);
            await sleep(TIMELOCK);
            await program.methods.executeRecovery(arg).accounts({ vault: ctx.vault }).rpc();

            const recovered = await program.account.vault.fetch(ctx.vault);
            expect(recovered.owner.toBase58()).to.equal(newOwner.publicKey.toBase58());
            // Still pointing at the exposed key: the rotation is a separate, deliberate act.
            expect(recovered.recoveryOwner.toBase58())
                .to.equal(ctx.recoveryOwner.publicKey.toBase58());

            const freshGuardian = Keypair.generate();
            await program.methods.register(
                freshGuardian.publicKey, vetoArgOf(ctx.veto), recovered.configNonce, 0,
            )
                .accounts({
                    vault: ctx.vault, owner: newOwner.publicKey,
                    instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                })
                .preInstructions([signAll([freshGuardian], registrationDigest(
                    programId, ctx.vault, newOwner.publicKey, freshGuardian.publicKey,
                    vetoFingerprint(ctx.veto), recovered.configNonce.toNumber(),
                ))])
                .signers([newOwner]).rpc();

            const after = await program.account.vault.fetch(ctx.vault);
            expect(after.recoveryOwner.toBase58()).to.equal(freshGuardian.publicKey.toBase58());
        });

        it("refuses a rotation driven by a veto key rather than the owner", async () => {
            // No authority named in the veto config may reach EXECUTED (§6.1). A pause or abort key
            // that could install a guardian would install one it controls and recover to itself,
            // which is that invariant defeated through the side door. So they are refused here for
            // the same reason a stranger is: they are not the owner.
            const ctx = await freshVault();
            const replacement = Keypair.generate();
            const before = await program.account.vault.fetch(ctx.vault);

            for (const [name, veto] of [
                ["the pause authority", ctx.pauseAuthority],
                ["the abort authority", ctx.abortAuthority],
                ["a resume quorum member", ctx.g1],
            ] as const) {
                await provider.connection.confirmTransaction(
                    await provider.connection.requestAirdrop(veto.publicKey, LAMPORTS_PER_SOL),
                ).catch(() => undefined);
                try {
                    await program.methods.register(
                        replacement.publicKey, vetoArgOf(ctx.veto), before.configNonce, 0,
                    )
                        .accounts({
                            vault: ctx.vault, owner: veto.publicKey,
                            instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                        })
                        .preInstructions([signAll([replacement], registrationDigest(
                            programId, ctx.vault, veto.publicKey, replacement.publicKey,
                            vetoFingerprint(ctx.veto), before.configNonce.toNumber(),
                        ))])
                        .signers([veto]).rpc();
                    assert.fail(`${name} rotated the recovery guardian`);
                } catch (e: any) {
                    expect(e.toString(), name).to.match(/NotOwner/);
                }
            }
            expect((await program.account.vault.fetch(ctx.vault)).recoveryOwner.toBase58())
                .to.equal(ctx.recoveryOwner.publicKey.toBase58());
        });

        it("permits the active key as the abort authority, which is the natural default", async () => {
            // The case abort exists for is "someone opened a recovery while I still have access",
            // and the obvious party to stop that is whoever currently holds the key. Requiring a
            // separate key provisioned in advance would leave an owner who did not provision one
            // with no way to abort at all.
            //
            // §6.1 is not offended: it keeps a veto holder from *gaining* power by being named, and
            // the owner already moves funds through execute_transfer and already authorises
            // rotations. Naming them grants nothing that was not already theirs.
            const ctx = await freshVault();
            const replacement = Keypair.generate();
            const before = await program.account.vault.fetch(ctx.vault);
            const ownerAborts = { ...ctx.veto, abortAuthority: ctx.creator.publicKey };

            await program.methods.register(
                replacement.publicKey, vetoArgOf(ownerAborts), before.configNonce, 0,
            )
                .accounts({
                    vault: ctx.vault, owner: ctx.creator.publicKey,
                    instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                })
                .preInstructions([signAll([replacement], registrationDigest(
                    programId, ctx.vault, ctx.creator.publicKey, replacement.publicKey,
                    vetoFingerprint(ownerAborts), before.configNonce.toNumber(),
                ))])
                .signers([ctx.creator]).rpc();

            const after = await program.account.vault.fetch(ctx.vault);
            expect(after.veto.abortAuthority.toBase58())
                .to.equal(ctx.creator.publicKey.toBase58());
        });

        it("lets the active key actually abort a recovery it did not start", async () => {
            // The end-to-end version of the same point, and the scenario that motivates it: a
            // recovery is opened against a vault whose owner never lost anything, and the owner
            // stops it with the key they already hold.
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            const replacement = Keypair.generate();
            const before = await program.account.vault.fetch(ctx.vault);
            const ownerAborts = { ...ctx.veto, abortAuthority: ctx.creator.publicKey };
            await program.methods.register(
                replacement.publicKey, vetoArgOf(ownerAborts), before.configNonce, 0,
            )
                .accounts({
                    vault: ctx.vault, owner: ctx.creator.publicKey,
                    instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                })
                .preInstructions([signAll([replacement], registrationDigest(
                    programId, ctx.vault, ctx.creator.publicKey, replacement.publicKey,
                    vetoFingerprint(ownerAborts), before.configNonce.toNumber(),
                ))])
                .signers([ctx.creator]).rpc();

            // Someone opens a recovery using the guardian key.
            const account = await program.account.vault.fetch(ctx.vault);
            const intent: Intent = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("hostile"),
                epoch: account.epoch.toNumber(),
                nonce: account.nonce.toNumber(),
                expiry: Math.floor(Date.now() / 1000) + 3600,
            };
            await program.methods.initiateRecovery(intentArg(intent), 0)
                .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                .preInstructions([signAll([replacement],
                    intentDigest(programId, ctx.vault, intent))])
                .rpc();
            expect(await stateOf(ctx.vault)).to.equal(1);

            // The owner, who never lost anything, stops it with the key they already have.
            await program.methods.abort()
                .accounts({ vault: ctx.vault, abortAuthority: ctx.creator.publicKey })
                .signers([ctx.creator]).rpc();
            expect(await stateOf(ctx.vault)).to.equal(5);
        });

        it("refuses a rotation the owner did not sign", async () => {
            const ctx = await freshVault();
            const replacement = Keypair.generate();
            const stranger = Keypair.generate();
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(stranger.publicKey, LAMPORTS_PER_SOL),
            );
            const before = await program.account.vault.fetch(ctx.vault);
            try {
                await program.methods.register(
                    replacement.publicKey, vetoArgOf(ctx.veto), before.configNonce, 0,
                )
                    .accounts({
                        vault: ctx.vault, owner: stranger.publicKey,
                        instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                    })
                    .preInstructions([signAll([replacement], registrationDigest(
                        programId, ctx.vault, stranger.publicKey, replacement.publicKey,
                        vetoFingerprint(ctx.veto), before.configNonce.toNumber(),
                    ))])
                    .signers([stranger]).rpc();
                assert.fail("a stranger rotated the recovery key");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotOwner/);
            }
        });

        it("refuses a veto config the independence invariant forbids", async () => {
            const creator = Keypair.generate();
            const recoveryOwner = Keypair.generate();
            const shared = Keypair.generate();
            const vaultId = Buffer.alloc(16);
            vaultId.write("bad-" + Math.random().toString(36).slice(2, 10));
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(creator.publicKey, LAMPORTS_PER_SOL),
            );
            const [vault] = PublicKey.findProgramAddressSync(
                [Buffer.from("vault"), creator.publicKey.toBuffer(), vaultId], programId,
            );
            const [vaultSol] = PublicKey.findProgramAddressSync(
                [Buffer.from("sol"), vault.toBuffer()], programId,
            );
            await program.methods.createVault([...vaultId])
                .accounts({
                    payer: provider.wallet.publicKey, creator: creator.publicKey, vault, vaultSol,
                    systemProgram: SystemProgram.programId,
                })
                .signers([creator]).rpc();

            // One party holding both pause and abort: §6.1 forbids it, and the chain has to refuse
            // it too -- a config only the client checked is one an attacker can simply not check.
            const veto: VetoConfig = {
                pauseAuthority: shared.publicKey,
                abortAuthority: shared.publicKey,
                resumeMembers: [Keypair.generate().publicKey, Keypair.generate().publicKey],
                resumeThreshold: 2,
                timelockSeconds: TIMELOCK,
                pauseCeilingSeconds: CEILING,
            };
            const digest = registrationDigest(
                programId, vault, creator.publicKey, recoveryOwner.publicKey,
                vetoFingerprint(veto), 0,
            );
            try {
                await program.methods.register(
                    recoveryOwner.publicKey, vetoArgOf(veto), new anchor.BN(0), 0,
                )
                    .accounts({
                        vault, owner: creator.publicKey,
                        instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
                    })
                    .preInstructions([signAll([recoveryOwner], digest)])
                    .signers([creator]).rpc();
                assert.fail("an invalid veto config was accepted");
            } catch (e: any) {
                expect(e.toString()).to.match(/PauseAndAbortHeldByOneParty/);
            }
        });
    });

    describe("the recovery lifecycle", () => {
        it("rotates the owner after the timelock matures, and bumps the epoch", async () => {
            const ctx = await freshVault();
            const newOwner = Keypair.generate().publicKey;
            const { arg } = await initiate(ctx, newOwner);
            expect(await stateOf(ctx.vault)).to.equal(1);

            await sleep(TIMELOCK);
            await program.methods.executeRecovery(arg).accounts({ vault: ctx.vault }).rpc();

            const account = await program.account.vault.fetch(ctx.vault);
            expect(account.owner.toBase58()).to.equal(newOwner.toBase58());
            expect(account.epoch.toNumber()).to.equal(1);
            expect(account.nonce.toNumber()).to.equal(1);
            expect(account.attempt.state).to.equal(4);
        });

        it("refuses to execute before the timelock matures", async () => {
            const ctx = await freshVault();
            const { arg } = await initiate(ctx);
            try {
                await program.methods.executeRecovery(arg).accounts({ vault: ctx.vault }).rpc();
                assert.fail("executed before maturity");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotExecutable/);
            }
        });

        it("refuses a second concurrent attempt", async () => {
            const ctx = await freshVault();
            await initiate(ctx);
            try {
                await initiate(ctx);
                assert.fail("a second concurrent attempt was accepted");
            } catch (e: any) {
                expect(e.toString()).to.match(/AttemptInFlight/);
            }
        });

        it("refuses an intent that is not the one the attempt was opened for", async () => {
            const ctx = await freshVault();
            await initiate(ctx);
            const account = await program.account.vault.fetch(ctx.vault);
            const other = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("owner-config"),
                epoch: new anchor.BN(account.epoch.toNumber()),
                nonce: new anchor.BN(account.nonce.toNumber()),
                expiry: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
            };
            await sleep(TIMELOCK);
            try {
                await program.methods.executeRecovery(other).accounts({ vault: ctx.vault }).rpc();
                assert.fail("a substituted intent was executed");
            } catch (e: any) {
                expect(e.toString()).to.match(/UnknownIntent/);
            }
        });
    });

    describe("the graduated veto", () => {
        it("pauses, then resumes on a full quorum", async () => {
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            const { digest } = await initiate(ctx);

            await program.methods.pause()
                .accounts({ vault: ctx.vault, pauseAuthority: ctx.pauseAuthority.publicKey })
                .signers([ctx.pauseAuthority]).rpc();
            expect(await stateOf(ctx.vault)).to.equal(2);

            const account = await program.account.vault.fetch(ctx.vault);
            const rd = resumeDigest(programId, ctx.vault, digest, account.attemptSeq.toNumber());
            await program.methods.resume([ctx.g1.publicKey, ctx.g2.publicKey], 0)
                .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                .preInstructions([signAll([ctx.g1, ctx.g2], rd)])
                .rpc();
            expect(await stateOf(ctx.vault)).to.equal(1);
        });

        it("auto-resumes at the ceiling with nobody acting, and no signature", async () => {
            // §15's no-permanent-lockout. The pause holder's abuse ceiling is a bounded freeze,
            // and it lifts whether or not anyone pays to notice.
            const ctx = await freshVault({ timelock: 30, ceiling: 2 });
            await initiate(ctx);
            await program.methods.pause()
                .accounts({ vault: ctx.vault, pauseAuthority: ctx.pauseAuthority.publicKey })
                .signers([ctx.pauseAuthority]).rpc();
            expect(await stateOf(ctx.vault)).to.equal(2);

            await sleep(2);
            // Stored state still says PAUSED -- nobody has poked the program.
            expect(await stateOf(ctx.vault)).to.equal(2);
            // The projection says otherwise, and the projection is the truth.
            const projected = await program.methods.projectedState()
                .accounts({ vault: ctx.vault }).view();
            expect(projected).to.equal(1);
        });

        it("refuses a resume below the threshold, and one signer counted twice", async () => {
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            const { digest } = await initiate(ctx);
            await program.methods.pause()
                .accounts({ vault: ctx.vault, pauseAuthority: ctx.pauseAuthority.publicKey })
                .signers([ctx.pauseAuthority]).rpc();
            const account = await program.account.vault.fetch(ctx.vault);
            const rd = resumeDigest(programId, ctx.vault, digest, account.attemptSeq.toNumber());

            try {
                await program.methods.resume([ctx.g1.publicKey], 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([ctx.g1], rd)]).rpc();
                assert.fail("resumed below threshold");
            } catch (e: any) {
                expect(e.toString()).to.match(/BelowResumeThreshold/);
            }

            // Plurality is the defence, so a repeated signer is rejected rather than counted twice.
            try {
                await program.methods.resume([ctx.g1.publicKey, ctx.g1.publicKey], 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([ctx.g1, ctx.g1], rd)]).rpc();
                assert.fail("a duplicate signer was counted twice");
            } catch (e: any) {
                expect(e.toString()).to.match(/DuplicateResumeSigner/);
            }
        });

        it("refuses a resume endorsed by a non-member", async () => {
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            const { digest } = await initiate(ctx);
            await program.methods.pause()
                .accounts({ vault: ctx.vault, pauseAuthority: ctx.pauseAuthority.publicKey })
                .signers([ctx.pauseAuthority]).rpc();
            const account = await program.account.vault.fetch(ctx.vault);
            const rd = resumeDigest(programId, ctx.vault, digest, account.attemptSeq.toNumber());
            const outsider = Keypair.generate();

            try {
                await program.methods.resume([ctx.g1.publicKey, outsider.publicKey], 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([ctx.g1, outsider], rd)]).rpc();
                assert.fail("a non-member endorsement was counted");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotResumeQuorum/);
            }
        });

        it("refuses pause from anyone but the pause authority", async () => {
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            await initiate(ctx);
            try {
                await program.methods.pause()
                    .accounts({ vault: ctx.vault, pauseAuthority: ctx.abortAuthority.publicKey })
                    .signers([ctx.abortAuthority]).rpc();
                assert.fail("the abort authority paused");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotPauseAuthority/);
            }
        });

        it("aborts irreversibly, and abort is the backstop that needs no quorum", async () => {
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            const { arg } = await initiate(ctx);
            await program.methods.abort()
                .accounts({ vault: ctx.vault, abortAuthority: ctx.abortAuthority.publicKey })
                .signers([ctx.abortAuthority]).rpc();
            expect(await stateOf(ctx.vault)).to.equal(5);

            try {
                await program.methods.executeRecovery(arg).accounts({ vault: ctx.vault }).rpc();
                assert.fail("executed an aborted recovery");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotExecutable/);
            }
        });

        it("refuses pause once the timelock has matured", async () => {
            // §15: once matured, the window for slowing things down has closed and only abort
            // remains.
            const ctx = await freshVault();
            await initiate(ctx);
            await sleep(TIMELOCK);
            try {
                await program.methods.pause()
                    .accounts({ vault: ctx.vault, pauseAuthority: ctx.pauseAuthority.publicKey })
                    .signers([ctx.pauseAuthority]).rpc();
                assert.fail("paused a matured recovery");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotInitiated/);
            }
        });
    });

    describe("confinement", () => {
        it("gives the recovery key the rotation and nothing else", async () => {
            // The property the whole design rests on: whoever extracts the raw recovery key gets
            // the committed, vetoable rotation -- never the funds.
            const ctx = await freshVault();
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(ctx.vaultSol, LAMPORTS_PER_SOL),
            );
            const thief = Keypair.generate();

            for (const [name, signer] of [
                ["the recovery key", ctx.recoveryOwner],
                ["the pause authority", ctx.pauseAuthority],
                ["the abort authority", ctx.abortAuthority],
                ["a resume quorum member", ctx.g1],
            ] as const) {
                try {
                    await program.methods.executeTransfer(new anchor.BN(1000))
                        .accounts({
                            vault: ctx.vault, owner: signer.publicKey, vaultSol: ctx.vaultSol,
                            destination: thief.publicKey, systemProgram: SystemProgram.programId,
                        })
                        .signers([signer]).rpc();
                    assert.fail(`${name} moved funds`);
                } catch (e: any) {
                    expect(e.toString(), name).to.match(/NotOwner/);
                }
            }
            expect(await provider.connection.getBalance(thief.publicKey)).to.equal(0);
        });

        it("lets the owner move funds, and the recovered owner after a rotation", async () => {
            const ctx = await freshVault();
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(ctx.vaultSol, LAMPORTS_PER_SOL),
            );
            // Pre-funded so it is already rent-exempt: the runtime rejects any transfer that would
            // leave the destination below the rent-exempt minimum, which has nothing to do with
            // this program but would otherwise be mistaken for it.
            const destination = Keypair.generate();
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(destination.publicKey, LAMPORTS_PER_SOL),
            );
            const opening = await provider.connection.getBalance(destination.publicKey);

            await program.methods.executeTransfer(new anchor.BN(1000))
                .accounts({
                    vault: ctx.vault, owner: ctx.creator.publicKey, vaultSol: ctx.vaultSol,
                    destination: destination.publicKey, systemProgram: SystemProgram.programId,
                })
                .signers([ctx.creator]).rpc();
            expect(await provider.connection.getBalance(destination.publicKey))
                .to.equal(opening + 1000);

            // Recover to a new owner, and check the capability moved with it.
            const newOwner = Keypair.generate();
            await provider.connection.confirmTransaction(
                await provider.connection.requestAirdrop(newOwner.publicKey, LAMPORTS_PER_SOL),
            );
            const { arg } = await initiate(ctx, newOwner.publicKey);
            await sleep(TIMELOCK);
            await program.methods.executeRecovery(arg).accounts({ vault: ctx.vault }).rpc();

            await program.methods.executeTransfer(new anchor.BN(2000))
                .accounts({
                    vault: ctx.vault, owner: newOwner.publicKey, vaultSol: ctx.vaultSol,
                    destination: destination.publicKey, systemProgram: SystemProgram.programId,
                })
                .signers([newOwner]).rpc();
            expect(await provider.connection.getBalance(destination.publicKey))
                .to.equal(opening + 3000);

            // And the superseded owner has lost it.
            try {
                await program.methods.executeTransfer(new anchor.BN(1000))
                    .accounts({
                        vault: ctx.vault, owner: ctx.creator.publicKey, vaultSol: ctx.vaultSol,
                        destination: destination.publicKey, systemProgram: SystemProgram.programId,
                    })
                    .signers([ctx.creator]).rpc();
                assert.fail("the superseded owner still moved funds");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotOwner/);
            }
        });
    });

    describe("ed25519 introspection", () => {
        /**
         * These are the tests that matter most, and every one of them is a *valid* signature. The
         * precompile verifies whatever it was asked to verify, so "a valid ed25519 instruction is
         * present" proves nothing on its own -- the program has to re-derive what must have been
         * signed and insist the precompile was asked exactly that.
         */
        async function initiateWith(ctx: any, preIx: any, index = 0) {
            const account = await program.account.vault.fetch(ctx.vault);
            const arg = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("owner-config"),
                epoch: new anchor.BN(account.epoch.toNumber()),
                nonce: new anchor.BN(account.nonce.toNumber()),
                expiry: new anchor.BN(Math.floor(Date.now() / 1000) + 3600),
            };
            return program.methods.initiateRecovery(arg, index)
                .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                .preInstructions([preIx])
                .rpc();
        }

        it("refuses a valid signature over a different message", async () => {
            const ctx = await freshVault();
            const wrong = Buffer.alloc(32, 7);
            try {
                await initiateWith(ctx, signAll([ctx.recoveryOwner], wrong));
                assert.fail("a signature over another message was accepted");
            } catch (e: any) {
                expect(e.toString()).to.match(/MessageMismatch/);
            }
        });

        it("refuses a valid signature by a different key", async () => {
            // The attack this whole module exists to stop: an attacker signs the *correct* digest
            // with their own key. The signature is valid; it just is not the recovery key's.
            const ctx = await freshVault();
            const impostor = Keypair.generate();
            const account = await program.account.vault.fetch(ctx.vault);
            const intent: Intent = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("owner-config"),
                epoch: account.epoch.toNumber(),
                nonce: account.nonce.toNumber(),
                expiry: Math.floor(Date.now() / 1000) + 3600,
            };
            const digest = intentDigest(programId, ctx.vault, intent);
            try {
                await program.methods.initiateRecovery({
                    newOwner: intent.newOwner,
                    newOwnerConfig: intent.newOwnerConfig,
                    epoch: new anchor.BN(intent.epoch),
                    nonce: new anchor.BN(intent.nonce),
                    expiry: new anchor.BN(intent.expiry),
                }, 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([impostor], digest)])
                    .rpc();
                assert.fail("an impostor's valid signature was accepted");
            } catch (e: any) {
                expect(e.toString()).to.match(/SignerMismatch/);
            }
        });

        it("refuses an extra unverified signature riding along", async () => {
            const ctx = await freshVault();
            const account = await program.account.vault.fetch(ctx.vault);
            const intent: Intent = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("owner-config"),
                epoch: account.epoch.toNumber(),
                nonce: account.nonce.toNumber(),
                expiry: Math.floor(Date.now() / 1000) + 3600,
            };
            const digest = intentDigest(programId, ctx.vault, intent);
            const extra = Keypair.generate();
            try {
                await program.methods.initiateRecovery({
                    newOwner: intent.newOwner,
                    newOwnerConfig: intent.newOwnerConfig,
                    epoch: new anchor.BN(intent.epoch),
                    nonce: new anchor.BN(intent.nonce),
                    expiry: new anchor.BN(intent.expiry),
                }, 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([ctx.recoveryOwner, extra], digest)])
                    .rpc();
                assert.fail("an extra signature rode along");
            } catch (e: any) {
                expect(e.toString()).to.match(/WrongSignatureCount/);
            }
        });

        it("refuses an instruction that is not the ed25519 precompile", async () => {
            const ctx = await freshVault();
            try {
                await initiateWith(
                    ctx,
                    ComputeBudgetProgram.setComputeUnitLimit({ units: 400_000 }),
                );
                assert.fail("a non-precompile instruction was accepted as a signature");
            } catch (e: any) {
                expect(e.toString()).to.match(/NotEd25519Program/);
            }
        });

        it("refuses a forgery that splits the message across two instructions", async () => {
            // The sharpest attack on this design, and the reason the cross-instruction check is not
            // merely tidiness.
            //
            // The precompile reads the signed message from whichever instruction the offsets name;
            // a program doing its own introspection reads from the instruction it was handed. Point
            // those at two different places and they disagree about what was signed. Here the
            // recovery key has signed some unrelated 32 bytes -- imagine any signature it ever
            // published -- and that signature is presented as authorising *this* recovery:
            //
            //   - the precompile verifies against instruction 1, which really does carry the bytes
            //     that were signed, and passes
            //   - the program reads the same offset in instruction 0, which has been stuffed with
            //     the digest it expects
            //
            // Without the check both halves are satisfied and any past signature authorises any
            // recovery. With it, the mismatch is refused before either is believed.
            const ctx = await freshVault();
            const account = await program.account.vault.fetch(ctx.vault);
            const intent: Intent = {
                newOwner: Keypair.generate().publicKey,
                newOwnerConfig: Buffer.from("owner-config"),
                epoch: account.epoch.toNumber(),
                nonce: account.nonce.toNumber(),
                expiry: Math.floor(Date.now() / 1000) + 3600,
            };
            const digest = intentDigest(programId, ctx.vault, intent);

            // Something else entirely that the recovery key once signed.
            const unrelated = Buffer.alloc(32, 0x5a);
            const carrier = signAll([ctx.recoveryOwner], unrelated);
            const forged = ed25519ForgeryAcrossInstructions({
                publicKey: ctx.recoveryOwner.publicKey.toBytes(),
                signature: nacl.sign.detached(unrelated, ctx.recoveryOwner.secretKey),
                decoyMessage: digest,
                messageInstructionIndex: 1,
                messageOffset: SINGLE_SIGNATURE_MESSAGE_OFFSET,
            });

            try {
                await program.methods.initiateRecovery({
                    newOwner: intent.newOwner,
                    newOwnerConfig: intent.newOwnerConfig,
                    epoch: new anchor.BN(intent.epoch),
                    nonce: new anchor.BN(intent.nonce),
                    expiry: new anchor.BN(intent.expiry),
                }, 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([forged, carrier])
                    .rpc();
                assert.fail("a signature over unrelated bytes authorised a recovery");
            } catch (e: any) {
                // Named explicitly. Anything looser would also pass if the precompile had been the
                // one to reject, which is what made an earlier version of this test vacuous.
                expect(e.toString()).to.match(/ForeignInstructionReference/);
            }
            // And the vault is untouched.
            expect((await program.account.vault.fetch(ctx.vault)).attempt.state).to.equal(0);
        });

        it("refuses a resume endorsement banked for an earlier attempt", async () => {
            // attempt_seq is what stops an endorsement of one attempt applying to the next, after
            // an abort and reinitiate that happens to reuse the same intent fields.
            const ctx = await freshVault({ timelock: 30, ceiling: 30 });
            const first = await initiate(ctx);
            const before = await program.account.vault.fetch(ctx.vault);
            const staleDigest = resumeDigest(
                programId, ctx.vault, first.digest, before.attemptSeq.toNumber(),
            );

            await program.methods.abort()
                .accounts({ vault: ctx.vault, abortAuthority: ctx.abortAuthority.publicKey })
                .signers([ctx.abortAuthority]).rpc();
            const second = await initiate(ctx);
            await program.methods.pause()
                .accounts({ vault: ctx.vault, pauseAuthority: ctx.pauseAuthority.publicKey })
                .signers([ctx.pauseAuthority]).rpc();

            try {
                await program.methods.resume([ctx.g1.publicKey, ctx.g2.publicKey], 0)
                    .accounts({ vault: ctx.vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
                    .preInstructions([signAll([ctx.g1, ctx.g2], staleDigest)])
                    .rpc();
                assert.fail("a banked endorsement was replayed onto a later attempt");
            } catch (e: any) {
                expect(e.toString()).to.match(/MessageMismatch/);
            }
            void second;
        });
    });
});
