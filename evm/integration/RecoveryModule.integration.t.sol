// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import {
    RhinestoneModuleKit,
    ModuleKitHelpers,
    AccountInstance
} from "modulekit/ModuleKit.sol";
import { MockValidator } from "modulekit/Mocks.sol";
import { HelperBase } from "modulekit/test/helpers/HelperBase.sol";
import { GradualVeto } from "../src/GradualVeto.sol";
import { RecoveryModule } from "../src/RecoveryModule.sol";

/**
 * @title RecoveryModuleIntegrationTest
 * @notice The recovery lifecycle against real ERC-7579 accounts rather than the recording mock.
 *
 * @dev The mock in `MockERC7579Account.sol` answers what the module *asks* an account to do; this
 *      suite answers whether real accounts *let it*. Their `installModule` is restricted to the
 *      entry point or the account itself, they check `isModuleType` on the new validator, and each
 *      encodes validator init data its own way — none of which the mock models. The rotation only
 *      works if `executeFromExecutor` turning into a self-call to `installModule` passes all of
 *      that on every account type.
 *
 *      ModuleKit picks the account from `ACCOUNT_TYPE` (DEFAULT, SAFE, KERNEL, NEXUS);
 *      `npm run test:accounts` runs this suite once per type, under the `integration` profile.
 */
contract RecoveryModuleIntegrationTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    uint256 internal constant TYPE_VALIDATOR = 1;
    uint256 internal constant TYPE_EXECUTOR = 2;
    uint64 internal constant TIMELOCK = 100;
    uint64 internal constant CEILING = 50;

    AccountInstance internal instance;
    RecoveryModule internal module;
    MockValidator internal newValidator;

    uint256 internal recoveryKey;
    address internal recoveryOwner;
    address internal pauser;
    address internal aborter;
    uint256 internal g1Key;
    address internal g1;
    uint256 internal g2Key;
    address internal g2;

    function setUp() public {
        instance = makeAccountInstance("recovery-integration");
        module = new RecoveryModule();
        newValidator = new MockValidator();

        (recoveryOwner, recoveryKey) = makeAddrAndKey("recoveryOwner");
        pauser = makeAddr("pauseAuthority");
        aborter = makeAddr("abortAuthority");
        (g1, g1Key) = makeAddrAndKey("guardian1");
        (g2, g2Key) = makeAddrAndKey("guardian2");

        vm.warp(1_700_000_000);
        instance.installModule(TYPE_EXECUTOR, address(module), abi.encode(recoveryOwner, _veto()));
    }

    function _veto() internal view returns (GradualVeto.Config memory config) {
        address[] memory members = new address[](2);
        members[0] = g1;
        members[1] = g2;
        config = GradualVeto.Config({
            pauseAuthority: pauser,
            abortAuthority: aborter,
            resumeMembers: members,
            resumeThreshold: 2,
            timelockSeconds: TIMELOCK,
            pauseCeilingSeconds: CEILING
        });
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Validator init data in whatever shape this account type's `installModule` expects.
    function _intent(uint256 nonce) internal returns (RecoveryModule.Intent memory) {
        bytes memory initData = HelperBase(instance.accountHelper).getInstallModuleData(
            instance, TYPE_VALIDATOR, address(newValidator), ""
        );
        return RecoveryModule.Intent({
            account: instance.account,
            epoch: 0,
            nonce: nonce,
            newValidator: address(newValidator),
            newValidatorInitData: initData,
            expiry: uint48(block.timestamp + 1 days)
        });
    }

    function _initiate(RecoveryModule.Intent memory intent) internal {
        module.initiateRecovery(intent, _sign(recoveryKey, module.hashIntent(intent)));
    }

    function test_installRegistersTheAccountAsAnExecutor() public {
        assertTrue(instance.isModuleInstalled(TYPE_EXECUTOR, address(module)));
        assertTrue(module.isInitialized(instance.account));
    }

    function test_recoveryInstallsTheCommittedValidatorOnARealAccount() public {
        RecoveryModule.Intent memory intent = _intent(0);
        _initiate(intent);
        assertFalse(instance.isModuleInstalled(TYPE_VALIDATOR, address(newValidator)));

        vm.warp(block.timestamp + TIMELOCK);
        module.executeRecovery(intent);

        assertTrue(instance.isModuleInstalled(TYPE_VALIDATOR, address(newValidator)));
        (, uint256 epoch, uint256 nonce,) = module.configOf(instance.account);
        assertEq(epoch, 1);
        assertEq(nonce, 1);
    }

    function test_pauseAndFreshResumeThenRecoveryCompletes() public {
        RecoveryModule.Intent memory intent = _intent(0);
        _initiate(intent);
        vm.prank(pauser);
        module.pause(instance.account);

        bytes32 digest = module.resumeDigest(instance.account, module.hashIntent(intent));
        address[] memory signers = new address[](2);
        signers[0] = g1;
        signers[1] = g2;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(g2Key, digest);
        module.resume(instance.account, signers, signatures);

        vm.warp(block.timestamp + TIMELOCK);
        module.executeRecovery(intent);
        assertTrue(instance.isModuleInstalled(TYPE_VALIDATOR, address(newValidator)));
    }

    function test_anAbortedRecoveryNeverTouchesTheAccount() public {
        RecoveryModule.Intent memory intent = _intent(0);
        _initiate(intent);
        vm.prank(aborter);
        module.abort(instance.account);

        vm.warp(block.timestamp + 10 * TIMELOCK);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        module.executeRecovery(intent);
        assertFalse(instance.isModuleInstalled(TYPE_VALIDATOR, address(newValidator)));
    }

    /// @dev The account's own uninstall path must reach `onUninstall`, or a later reinstall would
    ///      revert AlreadyInstalled and the attempt would outlive the module.
    function test_uninstallingThroughTheAccountClearsTheAttempt() public {
        _initiate(_intent(0));
        instance.uninstallModule(TYPE_EXECUTOR, address(module), "");

        assertFalse(module.isInitialized(instance.account));
        assertEq(uint8(module.stateOf(instance.account)), uint8(GradualVeto.State.NONE));
    }
}
