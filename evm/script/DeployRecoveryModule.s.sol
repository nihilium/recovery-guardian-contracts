// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { RecoveryModule } from "../src/RecoveryModule.sol";

/**
 * @title DeployRecoveryModule
 * @notice Deploys the singleton `RecoveryModule` deterministically via CREATE2.
 *
 * @dev **Why CREATE2 and not a plain `new`.** The module is a singleton with no constructor
 *      arguments and no admin: every account on a chain shares one instance, and nothing about it
 *      is per-deployer. A deterministic address means the same salt yields the same address on
 *      every chain, so the SDK can ship one address per version rather than a per-chain table, and
 *      anyone can recompute it from the source to check that the deployed code is what they think
 *      it is. `forge script` routes a salted `new` through the canonical CREATE2 factory at
 *      `CREATE2_FACTORY` (0x4e59…4956C), which is predeployed on Sepolia and mainnet.
 *
 *      Determinism is only as stable as the initcode: a compiler version, optimizer setting or any
 *      source change moves the address. That is the point — a changed module is a different
 *      address, never a silent replacement of the one accounts already trust.
 *
 *      **Idempotent.** If the predicted address already holds code the script broadcasts nothing
 *      and reports the existing deployment. Re-running is safe and is the intended way to confirm
 *      a deployment.
 *
 *      **No constructor arguments, deliberately.** The module has no owner, no upgrade path and no
 *      configuration; everything per-account arrives through `onInstall`. There is nothing to get
 *      wrong here, which is why this script has no parameters beyond the salt.
 */
contract DeployRecoveryModule is Script {
    /// @dev Human-readable so the salt is auditable; hashed to bytes32 below.
    /**
     * @dev Bumped to v2 alongside `version() = 2.0.0`: the veto clock moved from block heights to
     *      wall-clock seconds, which changes both the semantics of `GradualVeto.Config` and the
     *      `onInstall` encoding. A changed initcode already yields a changed address, so this is
     * not
     *      what separates the two deployments — but leaving a version-tagged salt reading `v1`
     * while
     *      shipping breaking v2 semantics would make the address derivation lie about what it is.
     */
    string internal constant DEFAULT_SALT = "nihilium-recovery-module-v2";

    uint256 internal constant CHAIN_SEPOLIA = 11_155_111;
    uint256 internal constant CHAIN_ARBITRUM_SEPOLIA = 421_614;
    uint256 internal constant CHAIN_ANVIL = 31_337;

    /// @dev Arbitrum One. A mainnet, so deliberately NOT on the allowlist — see `_guardChain`.
    uint256 internal constant CHAIN_ARBITRUM = 42_161;

    function run() external returns (RecoveryModule module) {
        _guardChain();

        bytes32 salt = keccak256(bytes(_envOr("DEPLOY_SALT", DEFAULT_SALT)));
        bytes32 initCodeHash = keccak256(type(RecoveryModule).creationCode);
        address predicted = vm.computeCreate2Address(salt, initCodeHash, CREATE2_FACTORY);

        console2.log("chain id       ", block.chainid);
        console2.log("salt           ", vm.toString(salt));
        console2.log("initcode hash  ", vm.toString(initCodeHash));
        console2.log("predicted      ", predicted);

        if (predicted.code.length != 0) {
            console2.log("Already deployed at the predicted address; nothing to broadcast.");
            module = RecoveryModule(predicted);
        } else {
            require(
                CREATE2_FACTORY.code.length != 0, "CREATE2 factory is not deployed on this chain"
            );

            _startBroadcast();
            module = new RecoveryModule{ salt: salt }();
            vm.stopBroadcast();

            require(address(module) == predicted, "CREATE2 address mismatch");
            console2.log("Deployed       ", address(module));
        }

        _assertSane(module);
        _writeDeployment(address(module), salt, initCodeHash);
    }

    /**
     * @dev Refuses to run against a chain nobody meant to target. The cost of a wrong `--rpc-url`
     *      is deploying to mainnet with a funded key, so the default is a short allowlist and
     *      widening it has to be deliberate.
     *
     *      The allowlist holds only chains where a mistake is free: Ethereum Sepolia, Arbitrum
     *      Sepolia, and a local node. **Arbitrum One is deliberately absent even though the module
     *      is meant to run there** — it is a mainnet, and the whole value of this guard is that
     *      reaching a mainnet takes a second, explicit act (`ALLOW_ANY_CHAIN=true`). Adding it here
     *      would spend the guard on the exact case it exists for.
     */
    function _guardChain() internal {
        if (_isSet("ALLOW_ANY_CHAIN") && vm.envBool("ALLOW_ANY_CHAIN")) {
            if (block.chainid == CHAIN_ARBITRUM) {
                console2.log("*** Arbitrum One (42161) is a MAINNET. This spends real funds. ***");
            }
            return;
        }
        require(
            block.chainid == CHAIN_SEPOLIA || block.chainid == CHAIN_ARBITRUM_SEPOLIA
                || block.chainid == CHAIN_ANVIL,
            "Refusing to deploy: chain is not a supported testnet (Ethereum Sepolia, Arbitrum Sepolia, Anvil). Set ALLOW_ANY_CHAIN=true to override."
        );
    }

    /**
     * @dev Two ways to sign, and the safer one is the default. With no `PRIVATE_KEY` in the
     *      environment the broadcaster comes from the command line — `--account` (an encrypted
     *      keystore), `--ledger`, or `--private-key` — so the key never has to sit in a file. The
     *      `PRIVATE_KEY` path exists for CI and throwaway testnet keys.
     */
    function _startBroadcast() internal {
        if (_isSet("PRIVATE_KEY")) {
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        } else {
            vm.startBroadcast();
        }
    }

    /**
     * @dev `vm.envOr` returns the *value* of a variable that is present but empty, and every entry
     *      in `.env.example` is present-but-empty by design. An unfilled `DEPLOY_SALT=` would then
     *      hash the empty string and deploy to a different address than the documented default —
     *      silently, since nothing about the run looks wrong. Treat empty as unset.
     */
    function _isSet(string memory key) internal view returns (bool) {
        return bytes(vm.envOr(key, string(""))).length != 0;
    }

    function _envOr(string memory key, string memory fallbackValue)
        internal
        view
        returns (string memory)
    {
        string memory value = vm.envOr(key, string(""));
        return bytes(value).length == 0 ? fallbackValue : value;
    }

    /**
     * @dev Cheap post-conditions on the live bytecode. These cannot fail if the right contract was
     *      deployed, which is exactly why they are worth asserting: they catch a stale artifact, a
     *      wrong salt pointing at somebody else's contract, or a botched verification long before
     *      an account installs the thing.
     */
    function _assertSane(RecoveryModule module) internal view {
        require(module.isModuleType(2), "not an ERC-7579 executor");
        require(!module.isModuleType(1), "must not claim to be a validator");
        require(
            keccak256(bytes(module.name())) == keccak256("NihiliumRecoveryModule"),
            "unexpected name"
        );
        require(!module.isInitialized(address(0)), "unexpected pre-existing state");
    }

    /**
     * @dev Records the deployment under `deployments/<chainid>.json`. Only written on a real
     *      broadcast: a dry run that left a file behind would be indistinguishable from a
     *      deployment that actually happened.
     *
     *      `deployedAtBlock` is `block.number` as the chain reports it. On Arbitrum that is the
     *      *L1* block, not the L2 height an explorer indexes — a Nitro quirk this script cannot
     *      work around, because `ArbSys` is a node-level precompile and `forge script` runs against
     *      forked state in its own EVM. Locate an Arbitrum deployment by address or tx hash, not by
     *      this number; see deployments/README.md.
     */
    function _writeDeployment(address module, bytes32 salt, bytes32 initCodeHash) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("Dry run: no deployment file written.");
            return;
        }
        // A local chain's addresses die with the node; recording them would be committing noise.
        if (block.chainid == CHAIN_ANVIL) {
            console2.log("Local chain: no deployment file written.");
            return;
        }

        string memory dir = "deployments";
        if (!vm.exists(dir)) vm.createDir(dir, true);

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "recoveryModule", module);
        vm.serializeBytes32(json, "salt", salt);
        vm.serializeBytes32(json, "initCodeHash", initCodeHash);
        vm.serializeString(json, "version", RecoveryModule(module).version());
        string memory out = vm.serializeUint(json, "deployedAtBlock", block.number);

        string memory path = string.concat(dir, "/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("Wrote          ", path);
    }
}
