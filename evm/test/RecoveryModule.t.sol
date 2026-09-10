// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { GradualVeto } from "../src/GradualVeto.sol";
import { RecoveryModule } from "../src/RecoveryModule.sol";
import { MockERC7579Account } from "./MockERC7579Account.sol";

contract RecoveryModuleTest is Test {
    RecoveryModule internal module;
    MockERC7579Account internal account;

    uint256 internal recoveryKey;
    address internal recoveryOwner;
    uint256 internal pauserKey;
    address internal pauser;
    uint256 internal aborterKey;
    address internal aborter;
    uint256 internal g1Key;
    address internal g1;
    uint256 internal g2Key;
    address internal g2;
    uint256 internal g3Key;
    address internal g3;

    address internal newValidator = address(0xBEEF);
    uint64 internal constant TIMELOCK = 100;
    uint64 internal constant CEILING = 50;

    function setUp() public {
        module = new RecoveryModule();
        account = new MockERC7579Account();

        (recoveryOwner, recoveryKey) = makeAddrAndKey("recoveryOwner");
        (pauser, pauserKey) = makeAddrAndKey("pauseAuthority");
        (aborter, aborterKey) = makeAddrAndKey("abortAuthority");
        (g1, g1Key) = makeAddrAndKey("guardian1");
        (g2, g2Key) = makeAddrAndKey("guardian2");
        (g3, g3Key) = makeAddrAndKey("guardian3");

        vm.warp(1_000);
        vm.warp(1_700_000_000);

        vm.prank(address(account));
        module.onInstall(abi.encode(recoveryOwner, _veto()));
    }

    function _veto() internal view returns (GradualVeto.Config memory config) {
        address[] memory members = new address[](3);
        members[0] = g1;
        members[1] = g2;
        members[2] = g3;
        config = GradualVeto.Config({
            pauseAuthority: pauser,
            abortAuthority: aborter,
            resumeMembers: members,
            resumeThreshold: 2,
            timelockSeconds: TIMELOCK,
            pauseCeilingSeconds: CEILING
        });
    }

    function _intent(uint256 epoch, uint256 nonce)
        internal
        view
        returns (RecoveryModule.Intent memory)
    {
        return RecoveryModule.Intent({
            account: address(account),
            epoch: epoch,
            nonce: nonce,
            newValidator: newValidator,
            newValidatorInitData: hex"c0ffee",
            expiry: uint48(block.timestamp + 1 days)
        });
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _initiate() internal returns (RecoveryModule.Intent memory intent) {
        intent = _intent(0, 0);
        module.initiateRecovery(intent, _sign(recoveryKey, module.hashIntent(intent)));
    }

    function _resumeSigs()
        internal
        view
        returns (address[] memory signers, bytes[] memory signatures)
    {
        (bytes32 intentHash,) = module.attemptOf(address(account));
        bytes32 digest = module.resumeDigest(address(account), intentHash);
        signers = new address[](2);
        signers[0] = g1;
        signers[1] = g2;
        signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(g2Key, digest);
    }

    // -----------------------------------------------------------------------------------
    // Installation
    // -----------------------------------------------------------------------------------

    function test_installRecordsOwnerAndVeto() public view {
        (address owner, uint256 epoch, uint256 nonce,) = module.configOf(address(account));
        assertEq(owner, recoveryOwner);
        assertEq(epoch, 0);
        assertEq(nonce, 0);
        assertTrue(module.isInitialized(address(account)));
    }

    function test_installRejectsAnInvalidVetoConfig() public {
        MockERC7579Account other = new MockERC7579Account();
        GradualVeto.Config memory bad = _veto();
        bad.abortAuthority = pauser; // §6.1 violation, refused on-chain and not only client-side.
        vm.prank(address(other));
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "pause and abort held by one party")
        );
        module.onInstall(abi.encode(recoveryOwner, bad));
    }

    function test_isModuleTypeIsExecutorOnly() public view {
        assertTrue(module.isModuleType(2), "must be an executor");
        // Registering as a validator would let the recovery key authorize arbitrary user operations,
        // which is exactly the confinement this design gives up nothing to keep.
        assertFalse(module.isModuleType(1), "must not be a validator");
    }

    /// @dev Epoch is replay-protection state. Resetting it on uninstall would revive every intent
    ///      the account had ever signed.
    function test_uninstallDoesNotResetTheEpoch() public {
        _executeFullRecovery();
        (, uint256 epochBefore,,) = module.configOf(address(account));

        vm.prank(address(account));
        module.onUninstall("");
        vm.prank(address(account));
        module.onInstall(abi.encode(recoveryOwner, _veto()));

        (, uint256 epochAfter,,) = module.configOf(address(account));
        assertEq(epochAfter, epochBefore, "epoch must survive an uninstall/reinstall cycle");
    }

    // -----------------------------------------------------------------------------------
    // Initiation: the identity gate
    // -----------------------------------------------------------------------------------

    function test_initiateRequiresTheRecoveryKeysSignature() public {
        RecoveryModule.Intent memory intent = _intent(0, 0);
        bytes memory wrongSig = _sign(g1Key, module.hashIntent(intent));
        vm.expectRevert(RecoveryModule.BadSignature.selector);
        module.initiateRecovery(intent, wrongSig);
    }

    /// @dev Submission is permissionless on purpose: a user who has lost their device has no funded
    ///      account to broadcast from, so a relayer must be able to carry the signed intent.
    function test_anyoneMaySubmitAValidlySignedIntent() public {
        RecoveryModule.Intent memory intent = _intent(0, 0);
        vm.prank(makeAddr("randomRelayer"));
        module.initiateRecovery(intent, _sign(recoveryKey, module.hashIntent(intent)));
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.INITIATED));
    }

    function test_initiateRejectsAnExpiredIntent() public {
        RecoveryModule.Intent memory intent = _intent(0, 0);
        bytes memory sig = _sign(recoveryKey, module.hashIntent(intent));
        vm.warp(uint256(intent.expiry) + 1);
        vm.expectRevert(RecoveryModule.IntentExpired.selector);
        module.initiateRecovery(intent, sig);
    }

    function test_initiateRejectsTheWrongEpoch() public {
        RecoveryModule.Intent memory intent = _intent(7, 0);
        bytes memory sig = _sign(recoveryKey, module.hashIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(RecoveryModule.WrongEpoch.selector, 0, 7));
        module.initiateRecovery(intent, sig);
    }

    function test_initiateRejectsAnIntentForAnotherAccount() public {
        MockERC7579Account other = new MockERC7579Account();
        RecoveryModule.Intent memory intent = _intent(0, 0);
        intent.account = address(other);
        // The signature is over the *other* account, which has no config on this module install.
        bytes memory sig = _sign(recoveryKey, module.hashIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(RecoveryModule.NotInstalled.selector, address(other)));
        module.initiateRecovery(intent, sig);
    }

    function test_onlyOneAttemptAtATime() public {
        _initiate();
        RecoveryModule.Intent memory second = _intent(0, 0);
        bytes memory sig = _sign(recoveryKey, module.hashIntent(second));
        vm.expectRevert(abi.encodeWithSelector(RecoveryModule.AttemptInFlight.selector, address(account)));
        module.initiateRecovery(second, sig);
    }

    function test_aNewAttemptIsAllowedAfterAnAbort() public {
        _initiate();
        vm.prank(aborter);
        module.abort(address(account));

        RecoveryModule.Intent memory second = _intent(0, 0);
        module.initiateRecovery(second, _sign(recoveryKey, module.hashIntent(second)));
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.INITIATED));
    }

    // -----------------------------------------------------------------------------------
    // §15: authorization of each veto capability
    // -----------------------------------------------------------------------------------

    function test_onlyPauseAuthorityMayPause() public {
        _initiate();
        for (uint256 i = 0; i < 4; i++) {
            address caller = [recoveryOwner, aborter, g1, makeAddr("stranger")][i];
            vm.prank(caller);
            vm.expectRevert(RecoveryModule.NotPauseAuthority.selector);
            module.pause(address(account));
        }
        vm.prank(pauser);
        module.pause(address(account));
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.PAUSED));
    }

    function test_onlyAbortAuthorityMayAbort() public {
        _initiate();
        for (uint256 i = 0; i < 4; i++) {
            address caller = [recoveryOwner, pauser, g1, makeAddr("stranger")][i];
            vm.prank(caller);
            vm.expectRevert(RecoveryModule.NotAbortAuthority.selector);
            module.abort(address(account));
        }
        vm.prank(aborter);
        module.abort(address(account));
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.ABORTED));
    }

    function test_resumeNeedsAThresholdOfDistinctQuorumMembers() public {
        _initiate();
        vm.prank(pauser);
        module.pause(address(account));

        (address[] memory signers, bytes[] memory signatures) = _resumeSigs();
        module.resume(address(account), signers, signatures);
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.INITIATED));
    }

    function test_resumeRejectsBelowThreshold() public {
        _initiate();
        vm.prank(pauser);
        module.pause(address(account));

        (bytes32 intentHash,) = module.attemptOf(address(account));
        address[] memory signers = new address[](1);
        signers[0] = g1;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(g1Key, module.resumeDigest(address(account), intentHash));

        vm.expectRevert(RecoveryModule.NotResumeQuorum.selector);
        module.resume(address(account), signers, signatures);
    }

    /// @dev Plurality is the only defence against premature release, so one guardian signing twice
    ///      must not be able to impersonate a quorum.
    function test_resumeRejectsTheSameGuardianTwice() public {
        _initiate();
        vm.prank(pauser);
        module.pause(address(account));

        (bytes32 intentHash,) = module.attemptOf(address(account));
        bytes32 digest = module.resumeDigest(address(account), intentHash);
        address[] memory signers = new address[](2);
        signers[0] = g1;
        signers[1] = g1;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(g1Key, digest);

        vm.expectRevert(abi.encodeWithSelector(RecoveryModule.DuplicateResumeSigner.selector, g1));
        module.resume(address(account), signers, signatures);
    }

    function test_resumeRejectsANonMember() public {
        _initiate();
        vm.prank(pauser);
        module.pause(address(account));

        (address stranger, uint256 strangerKey) = makeAddrAndKey("stranger");
        (bytes32 intentHash,) = module.attemptOf(address(account));
        bytes32 digest = module.resumeDigest(address(account), intentHash);
        address[] memory signers = new address[](2);
        signers[0] = g1;
        signers[1] = stranger;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(strangerKey, digest);

        vm.expectRevert(RecoveryModule.NotResumeQuorum.selector);
        module.resume(address(account), signers, signatures);
    }

    /// @dev A guardian endorsement is bound to the attempt, so it cannot be banked and replayed
    ///      against a later recovery the guardian never saw.
    function test_resumeSignatureDoesNotReplayOntoALaterAttempt() public {
        _initiate();
        vm.prank(pauser);
        module.pause(address(account));
        (address[] memory signers, bytes[] memory signatures) = _resumeSigs();

        vm.prank(aborter);
        module.abort(address(account));
        RecoveryModule.Intent memory second = _intent(0, 0);
        // A different intent hash, because the first attempt's hash is bound into the digest.
        second.newValidatorInitData = hex"beef";
        module.initiateRecovery(second, _sign(recoveryKey, module.hashIntent(second)));
        vm.prank(pauser);
        module.pause(address(account));

        vm.expectRevert(RecoveryModule.BadSignature.selector);
        module.resume(address(account), signers, signatures);
    }

    // -----------------------------------------------------------------------------------
    // §15: confinement — what execution can actually do
    // -----------------------------------------------------------------------------------

    /**
     * @dev The headline claim: "raw-rk extraction still yields only the committed, vetoable
     *      rotation". Here the attacker is handed the recovery key outright and still cannot make
     *      the account do anything except install the validator committed at initiation.
     */
    function test_confinement_executionOnlyEverInstallsTheCommittedValidator() public {
        RecoveryModule.Intent memory intent = _executeFullRecovery();

        assertEq(account.callCount(), 1, "recovery must produce exactly one call");
        (address target, uint256 value, bytes memory data) = account.getCall(0);
        assertEq(target, address(account), "the only call must be to the account itself");
        assertEq(value, 0, "recovery must never move value");
        assertEq(
            data,
            abi.encodeCall(MockERC7579Account.installModule, (1, intent.newValidator, intent.newValidatorInitData)),
            "the only call must be the committed validator install"
        );
        assertEq(account.validatorCount(), 1);
        assertEq(account.installedValidators(0), newValidator);
    }

    function test_executeRejectsAnIntentOtherThanTheOneInitiated() public {
        _initiate();
        vm.warp(block.timestamp + TIMELOCK);

        RecoveryModule.Intent memory swapped = _intent(0, 0);
        swapped.newValidator = address(0xDEAD); // the substitution confinement must refuse
        vm.expectRevert(RecoveryModule.UnknownIntent.selector);
        module.executeRecovery(swapped);
    }

    function test_executeRevertsBeforeTheTimelockMatures() public {
        RecoveryModule.Intent memory intent = _initiate();
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        module.executeRecovery(intent);
    }

    function test_executeRevertsAfterAbort() public {
        RecoveryModule.Intent memory intent = _initiate();
        vm.prank(aborter);
        module.abort(address(account));
        vm.warp(block.timestamp + 10 * TIMELOCK);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        module.executeRecovery(intent);
        assertEq(account.callCount(), 0, "an aborted recovery must touch the account not at all");
    }

    function test_executeRevertsWhilePaused() public {
        RecoveryModule.Intent memory intent = _initiate();
        vm.prank(pauser);
        module.pause(address(account));
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        module.executeRecovery(intent);
    }

    function test_executeBumpsTheEpochAndInvalidatesPriorIntents() public {
        RecoveryModule.Intent memory intent = _executeFullRecovery();
        (, uint256 epoch, uint256 nonce,) = module.configOf(address(account));
        assertEq(epoch, 1);
        assertEq(nonce, 1);

        // The very same signed intent, replayed. The epoch bump must make it worthless.
        bytes memory sig = _sign(recoveryKey, module.hashIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(RecoveryModule.WrongEpoch.selector, 1, 0));
        module.initiateRecovery(intent, sig);
    }

    /// @dev The epoch bump catches the replay before the state machine does; EXECUTED being
    ///      terminal is the second line of defence behind it. Either way the account is untouched.
    function test_executeCannotRunTwice() public {
        RecoveryModule.Intent memory intent = _executeFullRecovery();
        vm.expectRevert(abi.encodeWithSelector(RecoveryModule.WrongEpoch.selector, 1, 0));
        module.executeRecovery(intent);
        assertEq(account.callCount(), 1, "a second execute must not reach the account");
    }

    function test_surfacesAFailedInstallRatherThanReportingSuccess() public {
        RecoveryModule.Intent memory intent = _initiate();
        vm.warp(block.timestamp + TIMELOCK);
        account.setInstallShouldRevert(true);
        vm.expectRevert(MockERC7579Account.InstallFailed.selector);
        module.executeRecovery(intent);
    }

    /// @dev Auto-resume must reach execution too: a pause that lapses is a recovery that proceeds.
    function test_recoveryCompletesAfterAPauseLapsesAtTheCeiling() public {
        RecoveryModule.Intent memory intent = _initiate();
        vm.prank(pauser);
        module.pause(address(account));
        vm.warp(block.timestamp + CEILING + TIMELOCK);
        module.executeRecovery(intent);
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.EXECUTED));
    }

    /**
     * @dev The §15 killer demo, on-chain: gate satisfied -> initiated -> paused on deviation ->
     *      guardian-bounded resume -> owner hard-abort -> the recovery never executes.
     */
    function test_killerDemo_pauseResumeAbortNeverExecutes() public {
        RecoveryModule.Intent memory intent = _initiate();

        vm.prank(pauser);
        module.pause(address(account));
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.PAUSED));

        (address[] memory signers, bytes[] memory signatures) = _resumeSigs();
        module.resume(address(account), signers, signatures);
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.INITIATED));

        vm.prank(aborter);
        module.abort(address(account));

        vm.warp(block.timestamp + 1_000 * TIMELOCK);
        assertEq(uint8(module.stateOf(address(account))), uint8(GradualVeto.State.ABORTED));
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        module.executeRecovery(intent);
        assertEq(account.callCount(), 0, "the account must never have been touched");
    }

    function _executeFullRecovery() internal returns (RecoveryModule.Intent memory intent) {
        intent = _intent(0, 0);
        module.initiateRecovery(intent, _sign(recoveryKey, module.hashIntent(intent)));
        vm.warp(block.timestamp + TIMELOCK);
        module.executeRecovery(intent);
    }
}
