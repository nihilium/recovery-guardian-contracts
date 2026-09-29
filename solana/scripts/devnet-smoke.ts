/**
 * A live smoke test against a deployed program.
 *
 * Exercises the path a localnet suite cannot prove: that the *deployed* binary, built with that
 * cluster's tag, accepts signatures a client built with the matching tag — and that the two agree
 * about what was signed. Everything else is covered hermetically; this is here because a cluster
 * mismatch is invisible until it is live.
 *
 *     npx ts-node scripts/devnet-smoke.ts        (needs PRIVATE_KEY in .env)
 *
 * Deliberately stops before the timelock matures: waiting it out would prove nothing the localnet
 * suite has not already proven, and would leave a vault mid-recovery on a shared cluster.
 */
import * as anchor from "@coral-xyz/anchor";
import {
    Connection, Keypair, LAMPORTS_PER_SOL, PublicKey, SystemProgram,
    SYSVAR_INSTRUCTIONS_PUBKEY,
} from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { signAll } from "../bindings/ed25519";
import { digestsFor, vetoFingerprint, VetoConfig, Intent } from "../bindings/digest";
import { vaultAddress, vaultSolAddress } from "../bindings/index";

const CLUSTER = "devnet" as const;
const RPC = "https://api.devnet.solana.com";
const PROGRAM_ID = new PublicKey("DaLebS3k5gD1k42uGU6LPnSP9qTNwYxaKqLQBb7BqgkG");

function deployerKeypair(): Keypair {
    const line = readFileSync(`${__dirname}/../.env`, "utf8")
        .split("\n").find((l) => l.startsWith("PRIVATE_KEY="));
    if (!line) throw new Error("PRIVATE_KEY is not set in .env");
    const raw = line.slice("PRIVATE_KEY=".length).trim().replace(/^"|"$/g, "");
    const bs58 = require("bs58");
    return Keypair.fromSecretKey((bs58.default || bs58).decode(raw));
}

async function main() {
    const payer = deployerKeypair();
    const connection = new Connection(RPC, "confirmed");
    const provider = new anchor.AnchorProvider(
        connection, new anchor.Wallet(payer), { commitment: "confirmed" },
    );
    anchor.setProvider(provider);

    const idl = JSON.parse(
        readFileSync(`${__dirname}/../target/idl/nihilium_recovery_vault.json`, "utf8"),
    );
    const program = new anchor.Program(idl, provider) as any;
    const { registrationDigest, intentDigest } = digestsFor(CLUSTER);

    console.log(`program  ${PROGRAM_ID.toBase58()}`);
    console.log(`payer    ${payer.publicKey.toBase58()}`);
    console.log(`balance  ${(await connection.getBalance(payer.publicKey)) / LAMPORTS_PER_SOL} SOL`);

    // The payer is the creator and first owner; every other role is ephemeral.
    const recoveryOwner = Keypair.generate();
    const pauseAuthority = Keypair.generate();
    const abortAuthority = Keypair.generate();
    const g1 = Keypair.generate();
    const g2 = Keypair.generate();

    const vaultId = Buffer.alloc(16);
    vaultId.write("smoke-" + Date.now().toString(36));
    const [vault] = vaultAddress(PROGRAM_ID, payer.publicKey, vaultId);
    const [vaultSol] = vaultSolAddress(PROGRAM_ID, vault);
    console.log(`vault    ${vault.toBase58()}`);

    console.log("\n1. create_vault");
    await program.methods.createVault([...vaultId])
        .accounts({
            payer: payer.publicKey, creator: payer.publicKey, vault, vaultSol,
            systemProgram: SystemProgram.programId,
        }).rpc();

    const veto: VetoConfig = {
        pauseAuthority: pauseAuthority.publicKey,
        abortAuthority: abortAuthority.publicKey,
        resumeMembers: [g1.publicKey, g2.publicKey],
        resumeThreshold: 2,
        timelockSeconds: 86_400,
        pauseCeilingSeconds: 3_600,
    };

    console.log("2. register  (owner signs the tx; recovery key signs detached)");
    await program.methods.register(recoveryOwner.publicKey, {
        pauseAuthority: veto.pauseAuthority,
        abortAuthority: veto.abortAuthority,
        resumeMembers: veto.resumeMembers,
        resumeThreshold: veto.resumeThreshold,
        timelockSeconds: new anchor.BN(veto.timelockSeconds),
        pauseCeilingSeconds: new anchor.BN(veto.pauseCeilingSeconds),
    }, new anchor.BN(0), 0)
        .accounts({ vault, owner: payer.publicKey, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
        .preInstructions([signAll([recoveryOwner], registrationDigest(
            PROGRAM_ID, vault, payer.publicKey, recoveryOwner.publicKey, vetoFingerprint(veto), 0,
        ))])
        .rpc();

    console.log("3. initiate_recovery  (detached signature by the recovery key, relayer pays)");
    const account = await program.account.vault.fetch(vault);
    const intent: Intent = {
        newOwner: Keypair.generate().publicKey,
        newOwnerConfig: Buffer.from("devnet-smoke"),
        epoch: account.epoch.toNumber(),
        nonce: account.nonce.toNumber(),
        expiry: Math.floor(Date.now() / 1000) + 3600,
    };
    await program.methods.initiateRecovery({
        newOwner: intent.newOwner,
        newOwnerConfig: intent.newOwnerConfig,
        epoch: new anchor.BN(intent.epoch),
        nonce: new anchor.BN(intent.nonce),
        expiry: new anchor.BN(intent.expiry),
    }, 0)
        .accounts({ vault, instructions: SYSVAR_INSTRUCTIONS_PUBKEY })
        .preInstructions([signAll([recoveryOwner], intentDigest(PROGRAM_ID, vault, intent))])
        .rpc();

    console.log("4. pause  (pause authority signs)");
    // Funded from the payer rather than the faucet: devnet airdrops are rate-limited and fail
    // often enough that depending on one would make this script flaky for no reason.
    const fund = new anchor.web3.Transaction().add(SystemProgram.transfer({
        fromPubkey: payer.publicKey,
        toPubkey: pauseAuthority.publicKey,
        lamports: LAMPORTS_PER_SOL / 100,
    }));
    await provider.sendAndConfirm(fund, []);
    await program.methods.pause()
        .accounts({ vault, pauseAuthority: pauseAuthority.publicKey })
        .signers([pauseAuthority]).rpc();

    const after = await program.account.vault.fetch(vault);
    console.log(`\nstored attempt state = ${after.attempt.state}  (2 = PAUSED)`);
    console.log(`attempt_seq          = ${after.attemptSeq.toNumber()}`);
    console.log(`epoch                = ${after.epoch.toNumber()}`);

    console.log("\n5. a signature built for the WRONG cluster must be refused");
    const wrong = digestsFor("mainnet-beta");
    const vaultId2 = Buffer.alloc(16);
    vaultId2.write("wrong-" + Date.now().toString(36));
    const [vault2] = vaultAddress(PROGRAM_ID, payer.publicKey, vaultId2);
    const [vaultSol2] = vaultSolAddress(PROGRAM_ID, vault2);
    await program.methods.createVault([...vaultId2])
        .accounts({
            payer: payer.publicKey, creator: payer.publicKey, vault: vault2, vaultSol: vaultSol2,
            systemProgram: SystemProgram.programId,
        }).rpc();
    try {
        await program.methods.register(recoveryOwner.publicKey, {
            pauseAuthority: veto.pauseAuthority,
            abortAuthority: veto.abortAuthority,
            resumeMembers: veto.resumeMembers,
            resumeThreshold: veto.resumeThreshold,
            timelockSeconds: new anchor.BN(veto.timelockSeconds),
            pauseCeilingSeconds: new anchor.BN(veto.pauseCeilingSeconds),
        }, new anchor.BN(0), 0)
            .accounts({
                vault: vault2, owner: payer.publicKey, instructions: SYSVAR_INSTRUCTIONS_PUBKEY,
            })
            .preInstructions([signAll([recoveryOwner], wrong.registrationDigest(
                PROGRAM_ID, vault2, payer.publicKey, recoveryOwner.publicKey,
                vetoFingerprint(veto), 0,
            ))])
            .rpc();
        throw new Error("FAIL: a mainnet-tagged signature was accepted by the devnet deployment");
    } catch (e: any) {
        if (!/MessageMismatch/.test(e.toString())) throw e;
        console.log("   refused: MessageMismatch — the cluster tag is doing its job");
    }

    console.log("\nsmoke test passed");
}

main().catch((e) => { console.error(e); process.exit(1); });
