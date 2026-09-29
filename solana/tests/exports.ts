import { expect } from "chai";
import * as bindings from "../bindings/index";
import idlJson from "../bindings/idl.generated.json";

/**
 * What a consumer of this package can actually reach.
 *
 * The package exports PDAs, digests and the ed25519 packer, and for a while exported no IDL at all
 * — which left every instruction unreachable, because `new Program(idl, provider)` needs one. Shape
 * tests like these are the cheap way to notice that a surface is missing a piece, since everything
 * else here goes through internal relative imports that keep working regardless.
 */
describe("package exports", () => {

    it("hands out everything the integration path needs", () => {
        for (const name of [
            "vaultAddress", "vaultSolAddress",
            "digestsFor", "clusterTag", "vetoFingerprint",
            "signAll", "ed25519MultiSignatureInstruction",
            "recoveryVaultIdl",
            "registerArgs", "initiateRecoveryArgs", "executeRecoveryArgs",
            "VetoStateOrdinal", "MAX_RESUME_MEMBERS", "recoveryVaultProgramIds",
            "VAULT_SEED", "SOL_SEED",
        ]) {
            expect(bindings, name).to.have.property(name);
        }
    });

    it("exports the IDL as a value, because Program() reads it at runtime", () => {
        expect(bindings.recoveryVaultIdl.address).to.be.a("string");
        expect(bindings.recoveryVaultIdl.instructions.map((i) => i.name)).to.include.members([
            "create_vault", "register", "initiate_recovery",
            "pause", "resume", "abort", "execute_recovery", "execute_transfer",
        ]);
    });

    it("exports the same IDL the program was built from", () => {
        // Guards the re-export against pointing at a stale or hand-edited copy.
        expect(bindings.recoveryVaultIdl.address).to.equal((idlJson as { address: string }).address);
    });

    it("agrees with the address book about the deployed program", () => {
        expect(bindings.recoveryVaultProgramIds.devnet).to.equal(bindings.recoveryVaultIdl.address);
    });
});
