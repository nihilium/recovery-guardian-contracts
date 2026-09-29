// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { Eip7702RecoveryAccount } from "../src/Eip7702RecoveryAccount.sol";

/**
 * @title DeployEip7702RecoveryAccount
 * @notice Deploys the singleton `Eip7702RecoveryAccount` implementation deterministically via
 *         CREATE2.
 *
 * @dev The implementation is a singleton with no constructor arguments and no admin: the EIP-712
 *      domain separator is derived from the (constant) name/version, the chain id and
 *      `address(this)` — which, once an EOA delegates to this implementation via EIP-7702, is that
 *      EOA's own address, not this deployment's. Every per-EOA recovery state lives in the
 *      delegating EOA's own storage (see the ERC-7201 namespaced layout in the source), not here. A
 *      deterministic address means the same salt yields the same address on every chain, so the SDK
 *      can ship one address per version and every EOA that ever delegates to it delegates to the
 *      same, publicly verifiable code. `forge script` routes a salted `new` through the canonical
 *      CREATE2 factory at `CREATE2_FACTORY` (0x4e59…4956C), which is predeployed on Sepolia and
 *      mainnet.
 *
 *      **Idempotent.** If the predicted address already holds code the script broadcasts nothing
 *      and reports the existing deployment. Re-running is safe and is the intended way to confirm
 *      a deployment.
 */
contract DeployEip7702RecoveryAccount is Script {
    string internal constant DEFAULT_SALT = "nihilium-7702-recovery-account-v1";

    uint256 internal constant CHAIN_SEPOLIA = 11_155_111;
    uint256 internal constant CHAIN_ARBITRUM_SEPOLIA = 421_614;
    uint256 internal constant CHAIN_ANVIL = 31_337;
    uint256 internal constant CHAIN_ARBITRUM = 42_161;

    function run() external returns (Eip7702RecoveryAccount account) {
        _guardChain();

        bytes32 salt = keccak256(bytes(_envOr("DEPLOY_SALT", DEFAULT_SALT)));
        bytes32 initCodeHash = keccak256(type(Eip7702RecoveryAccount).creationCode);
        address predicted = vm.computeCreate2Address(salt, initCodeHash, CREATE2_FACTORY);

        console2.log("chain id       ", block.chainid);
        console2.log("salt           ", vm.toString(salt));
        console2.log("initcode hash  ", vm.toString(initCodeHash));
        console2.log("predicted      ", predicted);

        if (predicted.code.length != 0) {
            console2.log("Already deployed at the predicted address; nothing to broadcast.");
            account = Eip7702RecoveryAccount(payable(predicted));
        } else {
            require(
                CREATE2_FACTORY.code.length != 0, "CREATE2 factory is not deployed on this chain"
            );

            _startBroadcast();
            account = new Eip7702RecoveryAccount{ salt: salt }();
            vm.stopBroadcast();

            require(address(account) == predicted, "CREATE2 address mismatch");
            console2.log("Deployed       ", address(account));
        }

        _assertSane(account);
        _writeDeployment(address(account), salt, initCodeHash);
    }

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

    function _startBroadcast() internal {
        if (_isSet("PRIVATE_KEY")) {
            vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        } else {
            vm.startBroadcast();
        }
    }

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
     * @dev Cheap post-conditions on the live bytecode. Calling `isRegistered()` on the freshly
     *      deployed implementation's own (un-delegated) address reads that address's own, genuinely
     *      empty storage under the namespaced layout slot — a meaningful "no pre-existing state"
     *      check, not a stale artifact from the old per-account-mapping design.
     */
    function _assertSane(Eip7702RecoveryAccount account) internal view {
        require(
            keccak256(bytes(account.name())) == keccak256("Nihilium7702RecoveryAccount"),
            "unexpected name"
        );
        require(keccak256(bytes(account.version())) == keccak256("1.0.0"), "unexpected version");
        require(!account.isRegistered(), "unexpected pre-existing state");
    }

    /**
     * @dev Written under its own subdirectory, distinct from `deployments/<chainid>.json`
     *      (`DeployRecoveryModule.s.sol`'s path) — this is a different contract, not a new version
     *      of `RecoveryModule`, and the two must never share a file: both scripts use a 2-argument
     *      `vm.writeJson` that overwrites the whole file rather than merging keys, so sharing a path
     *      would silently destroy whichever record was written first.
     */
    function _writeDeployment(address account, bytes32 salt, bytes32 initCodeHash) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console2.log("Dry run: no deployment file written.");
            return;
        }
        if (block.chainid == CHAIN_ANVIL) {
            console2.log("Local chain: no deployment file written.");
            return;
        }

        string memory dir = "deployments/eip7702-recovery-account";
        if (!vm.exists(dir)) vm.createDir(dir, true);

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "recoveryAccount", account);
        vm.serializeBytes32(json, "salt", salt);
        vm.serializeBytes32(json, "initCodeHash", initCodeHash);
        vm.serializeString(json, "version", Eip7702RecoveryAccount(payable(account)).version());
        string memory out = vm.serializeUint(json, "deployedAtBlock", block.number);

        string memory path = string.concat(dir, "/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console2.log("Wrote          ", path);
    }
}
