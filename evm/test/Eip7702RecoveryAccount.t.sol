// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { GradualVeto } from "../src/GradualVeto.sol";
import { Eip7702RecoveryAccount } from "../src/Eip7702RecoveryAccount.sol";

/**
 * @title Eip7702RecoveryAccountTest
 * @notice Behavioural tests for the 7702 recovery account implementation.
 *
 * @dev Mirrors `RecoveryModule.t.sol` in structure and assertion style, adapted to this contract
 *      being the code an EOA delegates to (rather than an external module installed on a separate
 *      smart account). Delegation is real, not faked: `vm.signAndAttachDelegation` signs a genuine
 *      type-04 authorization and Foundry actually routes subsequent calls to the EOA's address
 *      through the implementation's bytecode, against the EOA's own storage — confirmed working
 *      under this project's `evm_version = "cancun"` by a standalone smoke test before this suite
 *      was written.
 *
 *      A fresh EOA is minted per test (seeded with a per-test counter) so no test's delegation or
 *      recovery state can bleed into another's, matching the isolation discipline the pre-redesign
 *      suite already used.
 */
contract Eip7702RecoveryAccountTest is Test {
    Eip7702RecoveryAccount internal impl;

    /// @dev The recovering EOA and its own signing key.
    address internal eoa;
    uint256 internal eoaKey;

    /// @dev Per-test counter; seeds a fresh EOA address each test.
    uint256 internal _testIndex;

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

    address internal newOwner = address(0xBEEF);
    uint64 internal constant TIMELOCK = 100;
    uint64 internal constant CEILING = 50;

    function setUp() public {
        impl = new Eip7702RecoveryAccount();

        _testIndex += 1;
        (eoa, eoaKey) = makeAddrAndKey(string(abi.encodePacked("eoa", vm.toString(_testIndex))));
        vm.signAndAttachDelegation(address(impl), eoaKey);

        (recoveryOwner, recoveryKey) = makeAddrAndKey("recoveryOwner");
        (pauser, pauserKey) = makeAddrAndKey("pauseAuthority");
        (aborter, aborterKey) = makeAddrAndKey("abortAuthority");
        (g1, g1Key) = makeAddrAndKey("guardian1");
        (g2, g2Key) = makeAddrAndKey("guardian2");
        (g3, g3Key) = makeAddrAndKey("guardian3");

        vm.warp(1000);
        vm.warp(1_700_000_000);

        _register(recoveryOwner, eoaKey, 0);
    }

    function _acc() internal view returns (Eip7702RecoveryAccount) {
        return Eip7702RecoveryAccount(payable(eoa));
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
        returns (Eip7702RecoveryAccount.Intent memory)
    {
        return Eip7702RecoveryAccount.Intent({
            epoch: epoch,
            nonce: nonce,
            newOwner: newOwner,
            expiry: uint48(block.timestamp + 1 days)
        });
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Registers/rotates using the EOA's own key (`ownerKey`) for the owner-consent signature
    ///      — the caller picks which key so tests can exercise a post-recovery rotate (signed by the
    ///      new owner) as well as the initial bootstrap (signed by the EOA itself).
    function _register(address owner_, uint256 ownerKey, uint256 configNonce) internal {
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: owner_,
            veto: _veto(),
            nonce: configNonce
        });
        bytes32 digest = _acc().hashRegister(reg);
        _acc().register(reg, _sign(recoveryKey, digest), _sign(ownerKey, digest));
    }

    function _initiate() internal returns (Eip7702RecoveryAccount.Intent memory intent) {
        intent = _intent(0, 0);
        _acc().initiateRecovery(intent, _sign(recoveryKey, _acc().hashIntent(intent)));
    }

    function _resumeSigs()
        internal
        view
        returns (address[] memory signers, bytes[] memory signatures)
    {
        (bytes32 intentHash,,) = _acc().attemptOf();
        bytes32 digest = _acc().resumeDigest(intentHash);
        signers = new address[](2);
        signers[0] = g1;
        signers[1] = g2;
        signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(g2Key, digest);
    }

    // -----------------------------------------------------------------------------------
    // Registration — Nihilium-gated AND EOA-consented
    // -----------------------------------------------------------------------------------

    function test_registerBindsTheRecoveryOwnerAndVeto() public view {
        (address currentOwner, address boundRecoveryOwner, uint256 epoch, uint256 nonce,,,) =
            _acc().configOf();
        assertEq(currentOwner, eoa, "owner defaults to the EOA itself before any recovery");
        assertEq(boundRecoveryOwner, recoveryOwner);
        assertEq(epoch, 0);
        assertEq(nonce, 0);
        assertTrue(_acc().isRegistered());
    }

    /// @dev The recovery owner is bound by the Nihilium key's signature, not chosen by the caller.
    function test_registerRequiresTheRecoveryKeysSignature() public {
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: address(0x1234),
            veto: _veto(),
            nonce: 1
        });
        bytes32 digest = _acc().hashRegister(reg);
        // Correct owner-consent signature, but the recovery-owner signature is from the wrong key.
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().register(reg, _sign(g1Key, digest), _sign(eoaKey, digest));
    }

    /// @dev The other half of dual-signature registration: a valid recovery-owner signature is not
    ///      enough on its own. This is the direct regression test for the front-running finding —
    ///      an attacker who can produce any self-signed claim still cannot register someone else's
    ///      EOA without that EOA's own key.
    function test_registrationCannotBeFrontRunWithoutTheEoasOwnSignature() public {
        (address attacker, uint256 attackerKey) = makeAddrAndKey("attacker");
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: attacker,
            veto: _veto(),
            nonce: 1
        });
        bytes32 digest = _acc().hashRegister(reg);
        // Attacker signs as their own recoveryOwner claim, and forges an "ownerSignature" with
        // their own key rather than the real EOA's — must be rejected.
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().register(reg, _sign(attackerKey, digest), _sign(attackerKey, digest));
    }

    function test_registerRejectsAnInvalidVetoConfig() public {
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: recoveryOwner,
            veto: GradualVeto.Config({
                pauseAuthority: pauser,
                abortAuthority: pauser, // §6.1 violation
                resumeMembers: new address[](1),
                resumeThreshold: 1,
                timelockSeconds: TIMELOCK,
                pauseCeilingSeconds: CEILING
            }),
            nonce: 1
        });
        reg.veto.resumeMembers[0] = g1;
        bytes32 digest = _acc().hashRegister(reg);
        vm.expectRevert(
            abi.encodeWithSelector(
                GradualVeto.InvalidConfig.selector, "pause and abort held by one party"
            )
        );
        _acc().register(reg, _sign(recoveryKey, digest), _sign(eoaKey, digest));
    }

    function test_registerRejectsAStaleConfigNonce() public {
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: recoveryOwner,
            veto: _veto(),
            nonce: 0 // setUp already consumed nonce 0
        });
        bytes32 digest = _acc().hashRegister(reg);
        vm.expectRevert(
            abi.encodeWithSelector(Eip7702RecoveryAccount.WrongConfigNonce.selector, 1, 0)
        );
        _acc().register(reg, _sign(recoveryKey, digest), _sign(eoaKey, digest));
    }

    /// @dev Registration is re-callable by design — rotating guardians/recoveryOwner while the key
    ///      is live is a normal operation, not blocked by a one-way "already registered" lock.
    function test_registerCanBeRotatedByTheCurrentOwner() public {
        (address newRecoveryOwner, uint256 newRecoveryKey) = makeAddrAndKey("newRecoveryOwner");
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: newRecoveryOwner,
            veto: _veto(),
            nonce: 1
        });
        bytes32 digest = _acc().hashRegister(reg);
        // The NEW recoveryOwner's own key signs the recoveryOwner-consent half; the EOA's (still
        // current, pre-recovery) key signs the owner-consent half.
        _acc().register(reg, _sign(newRecoveryKey, digest), _sign(eoaKey, digest));

        (, address boundRecoveryOwner,,,,,) = _acc().configOf();
        assertEq(boundRecoveryOwner, newRecoveryOwner);
    }

    /// @dev After a completed recovery, only the *new* owner's key can rotate registration — the
    ///      original EOA key is no longer the current owner and must be rejected.
    function test_rotateAfterRecoveryRequiresTheNewOwnersSignature() public {
        Eip7702RecoveryAccount.Intent memory intent = _initiate();
        vm.warp(block.timestamp + TIMELOCK);
        _acc().executeRecovery(intent);

        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: recoveryOwner,
            veto: _veto(),
            nonce: 1
        });
        bytes32 digest = _acc().hashRegister(reg);
        // Signed with the stale, pre-recovery EOA key rather than `newOwner`'s.
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().register(reg, _sign(recoveryKey, digest), _sign(eoaKey, digest));
    }

    // -----------------------------------------------------------------------------------
    // Initiation: the identity gate
    // -----------------------------------------------------------------------------------

    function test_initiateRequiresTheRecoveryKeysSignature() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        bytes memory wrongSig = _sign(g1Key, _acc().hashIntent(intent));
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().initiateRecovery(intent, wrongSig);
    }

    /// @dev Submission is permissionless on purpose: a user who has lost their device has no funded
    ///      account to broadcast from, so a relayer must be able to carry the signed intent.
    function test_anyoneMaySubmitAValidlySignedIntent() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        vm.prank(makeAddr("randomRelayer"));
        _acc().initiateRecovery(intent, _sign(recoveryKey, _acc().hashIntent(intent)));
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.INITIATED));
    }

    function test_initiateRejectsAnUnregisteredEoa() public {
        (address freshEoa, uint256 freshKey) = makeAddrAndKey("unregistered");
        vm.signAndAttachDelegation(address(impl), freshKey);
        Eip7702RecoveryAccount freshAcc = Eip7702RecoveryAccount(payable(freshEoa));

        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        bytes memory sig = _sign(recoveryKey, freshAcc.hashIntent(intent));
        vm.expectRevert(Eip7702RecoveryAccount.NotRegistered.selector);
        freshAcc.initiateRecovery(intent, sig);
    }

    function test_initiateRejectsAnExpiredIntent() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        bytes memory sig = _sign(recoveryKey, _acc().hashIntent(intent));
        vm.warp(uint256(intent.expiry) + 1);
        vm.expectRevert(Eip7702RecoveryAccount.IntentExpired.selector);
        _acc().initiateRecovery(intent, sig);
    }

    function test_initiateRejectsTheWrongEpoch() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(7, 0);
        bytes memory sig = _sign(recoveryKey, _acc().hashIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(Eip7702RecoveryAccount.WrongEpoch.selector, 0, 7));
        _acc().initiateRecovery(intent, sig);
    }

    function test_initiateRejectsTheWrongNonce() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 5);
        bytes memory sig = _sign(recoveryKey, _acc().hashIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(Eip7702RecoveryAccount.WrongNonce.selector, 0, 5));
        _acc().initiateRecovery(intent, sig);
    }

    function test_initiateRejectsZeroOwner() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        intent.newOwner = address(0);
        bytes memory sig = _sign(recoveryKey, _acc().hashIntent(intent));
        vm.expectRevert(Eip7702RecoveryAccount.ZeroOwner.selector);
        _acc().initiateRecovery(intent, sig);
    }

    function test_onlyOneAttemptAtATime() public {
        _initiate();
        Eip7702RecoveryAccount.Intent memory second = _intent(0, 0);
        bytes memory sig = _sign(recoveryKey, _acc().hashIntent(second));
        vm.expectRevert(Eip7702RecoveryAccount.AttemptInFlight.selector);
        _acc().initiateRecovery(second, sig);
    }

    function test_aNewAttemptIsAllowedAfterAnAbort() public {
        _initiate();
        vm.prank(aborter);
        _acc().abort();

        Eip7702RecoveryAccount.Intent memory second = _intent(0, 0);
        _acc().initiateRecovery(second, _sign(recoveryKey, _acc().hashIntent(second)));
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.INITIATED));
    }

    // -----------------------------------------------------------------------------------
    // §15: authorization of each veto capability
    // -----------------------------------------------------------------------------------

    function test_onlyPauseAuthorityMayPause() public {
        _initiate();
        address[4] memory strangers = [recoveryOwner, aborter, g1, makeAddr("stranger")];
        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(Eip7702RecoveryAccount.NotPauseAuthority.selector);
            _acc().pause();
        }
        vm.prank(pauser);
        _acc().pause();
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.PAUSED));
    }

    function test_onlyAbortAuthorityMayAbort() public {
        _initiate();
        address[4] memory strangers = [recoveryOwner, pauser, g1, makeAddr("stranger")];
        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(Eip7702RecoveryAccount.NotAbortAuthority.selector);
            _acc().abort();
        }
        vm.prank(aborter);
        _acc().abort();
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.ABORTED));
    }

    function test_resumeNeedsAThresholdOfDistinctQuorumMembers() public {
        _initiate();
        vm.prank(pauser);
        _acc().pause();

        (address[] memory signers, bytes[] memory signatures) = _resumeSigs();
        _acc().resume(signers, signatures);
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.INITIATED));
    }

    function test_resumeRejectsBelowThreshold() public {
        _initiate();
        vm.prank(pauser);
        _acc().pause();

        (bytes32 intentHash,,) = _acc().attemptOf();
        address[] memory signers = new address[](1);
        signers[0] = g1;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(g1Key, _acc().resumeDigest(intentHash));

        vm.expectRevert(Eip7702RecoveryAccount.NotResumeQuorum.selector);
        _acc().resume(signers, signatures);
    }

    /// @dev Plurality is the only defence against premature release, so one guardian signing twice
    ///      must not be able to impersonate a quorum.
    function test_resumeRejectsTheSameGuardianTwice() public {
        _initiate();
        vm.prank(pauser);
        _acc().pause();

        (bytes32 intentHash,,) = _acc().attemptOf();
        bytes32 digest = _acc().resumeDigest(intentHash);
        address[] memory signers = new address[](2);
        signers[0] = g1;
        signers[1] = g1;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(g1Key, digest);

        vm.expectRevert(
            abi.encodeWithSelector(Eip7702RecoveryAccount.DuplicateResumeSigner.selector, g1)
        );
        _acc().resume(signers, signatures);
    }

    function test_resumeRejectsANonMember() public {
        _initiate();
        vm.prank(pauser);
        _acc().pause();

        (address stranger, uint256 strangerKey) = makeAddrAndKey("stranger");
        (bytes32 intentHash,,) = _acc().attemptOf();
        bytes32 digest = _acc().resumeDigest(intentHash);
        address[] memory signers = new address[](2);
        signers[0] = g1;
        signers[1] = stranger;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(g1Key, digest);
        signatures[1] = _sign(strangerKey, digest);

        vm.expectRevert(Eip7702RecoveryAccount.NotResumeQuorum.selector);
        _acc().resume(signers, signatures);
    }

    /// @dev The direct fix for the resume-replay finding: an endorsement of one attempt must not be
    ///      valid for a later attempt that happens to share the same intent fields (and hence the
    ///      same intentHash) after an abort and reinitiate — the actual colliding case, not a
    ///      sidestepped one.
    function test_resumeSignatureDoesNotReplayOntoALaterAttemptWithIdenticalIntent() public {
        _initiate();
        vm.prank(pauser);
        _acc().pause();
        (address[] memory signers, bytes[] memory signatures) = _resumeSigs();

        vm.prank(aborter);
        _acc().abort();
        // Byte-identical intent fields — the actual colliding case, not a mutated one.
        Eip7702RecoveryAccount.Intent memory second = _intent(0, 0);
        _acc().initiateRecovery(second, _sign(recoveryKey, _acc().hashIntent(second)));
        vm.prank(pauser);
        _acc().pause();

        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().resume(signers, signatures);
    }

    /// @dev Direct proof of the mechanism: resumeDigest for the *same* intentHash changes across
    ///      attempts, because attemptSeq — not intentHash alone — is what it's bound to.
    function test_resumeDigestChangesAcrossAttemptsSharingTheSameIntentHash() public {
        Eip7702RecoveryAccount.Intent memory intent = _initiate();
        bytes32 intentHash = _acc().hashIntent(intent);
        bytes32 firstDigest = _acc().resumeDigest(intentHash);

        vm.prank(aborter);
        _acc().abort();
        _acc().initiateRecovery(intent, _sign(recoveryKey, intentHash));
        bytes32 secondDigest = _acc().resumeDigest(intentHash);

        assertTrue(firstDigest != secondDigest, "resumeDigest must differ across attempts");
    }

    // -----------------------------------------------------------------------------------
    // Confinement: what executeRecovery can actually do
    // -----------------------------------------------------------------------------------

    function test_executeRevertsBeforeTheTimelockMatures() public {
        Eip7702RecoveryAccount.Intent memory intent = _initiate();
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        _acc().executeRecovery(intent);
    }

    /// @dev Even with the raw recovery key, executeRecovery can only ever install the specific
    ///      `newOwner` committed and vetted through initiation — never a substituted one.
    function test_executeRejectsAnIntentOtherThanTheOneInitiated() public {
        _initiate();
        vm.warp(block.timestamp + TIMELOCK);

        Eip7702RecoveryAccount.Intent memory swapped = _intent(0, 0);
        swapped.newOwner = address(0xDEAD);
        vm.expectRevert(Eip7702RecoveryAccount.UnknownIntent.selector);
        _acc().executeRecovery(swapped);
    }

    function test_executeBumpsTheEpochAndInvalidatesPriorIntents() public {
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        _acc().initiateRecovery(intent, _sign(recoveryKey, _acc().hashIntent(intent)));
        vm.warp(block.timestamp + TIMELOCK);
        _acc().executeRecovery(intent);

        (,, uint256 epoch, uint256 nonce,,,) = _acc().configOf();
        assertEq(epoch, 1);
        assertEq(nonce, 1);

        bytes memory sig = _sign(recoveryKey, _acc().hashIntent(intent));
        vm.expectRevert(abi.encodeWithSelector(Eip7702RecoveryAccount.WrongEpoch.selector, 1, 0));
        _acc().initiateRecovery(intent, sig);
    }

    function test_executeCannotRunTwice() public {
        Eip7702RecoveryAccount.Intent memory intent = _initiate();
        vm.warp(block.timestamp + TIMELOCK);
        _acc().executeRecovery(intent);
        // The epoch bump (not a terminal-veto-state check) is what rejects the replay here — same
        // as RecoveryModule.sol's identical test, and consistent with removing the redundant early
        // veto-projection check (finding G): the epoch check now runs before GradualVeto.execute()
        // would get a chance to report NotExecutable.
        vm.expectRevert(abi.encodeWithSelector(Eip7702RecoveryAccount.WrongEpoch.selector, 1, 0));
        _acc().executeRecovery(intent);
    }

    /// @dev Auto-resume must reach execution too: a pause that lapses is a recovery that proceeds.
    function test_recoveryCompletesAfterAPauseLapsesAtTheCeiling() public {
        Eip7702RecoveryAccount.Intent memory intent = _initiate();
        vm.prank(pauser);
        _acc().pause();
        vm.warp(block.timestamp + CEILING + TIMELOCK);
        _acc().executeRecovery(intent);
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.EXECUTED));
        assertEq(_acc().owner(), newOwner);
    }

    /**
     * @dev The §15 killer demo: gate satisfied -> initiated -> paused on deviation ->
     *      guardian-bounded resume -> owner hard-abort -> the EOA is never recovered away.
     */
    function test_killerDemo_pauseResumeAbortNeverExecutes() public {
        _initiate();

        vm.prank(pauser);
        _acc().pause();
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.PAUSED));

        (address[] memory signers, bytes[] memory signatures) = _resumeSigs();
        _acc().resume(signers, signatures);
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.INITIATED));

        vm.prank(aborter);
        _acc().abort();

        vm.warp(block.timestamp + 1000 * TIMELOCK);
        assertEq(uint8(_acc().stateOf()), uint8(GradualVeto.State.ABORTED));
        assertEq(_acc().owner(), eoa, "the EOA must never have been recovered away");
    }

    // -----------------------------------------------------------------------------------
    // The headline fix: recovery is usable with no further EOA signature, ever
    // -----------------------------------------------------------------------------------

    /**
     * @dev The direct proof the fatal design flaw is actually fixed, not just argued away: after
     *      executeRecovery, in the very same transaction, the new owner already controls the
     *      account via `execute()` — no second type-04 transaction, no further signature from the
     *      (by-definition lost) original EOA key, ever again.
     */
    function test_recoveryIsUsableImmediatelyWithNoFurtherEoaSignature() public {
        (address recoveredOwner, uint256 recoveredKey) = makeAddrAndKey("headlineRecoveredOwner");
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        intent.newOwner = recoveredOwner;
        _acc().initiateRecovery(intent, _sign(recoveryKey, _acc().hashIntent(intent)));
        vm.warp(block.timestamp + TIMELOCK);

        // executeRecovery is the ENTIRE completion of the recovery — no finalize step, no second
        // type-04 transaction, nothing further required from the (by-definition lost) EOA key.
        _acc().executeRecovery(intent);
        assertEq(_acc().owner(), recoveredOwner, "owner() must already reflect the recovery");

        // And it's immediately usable: the new owner drives the account in this same test, with
        // no further action from the original EOA at all.
        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](1);
        calls[0] = Eip7702RecoveryAccount.Call({ target: address(0xCAFE), value: 0, data: "" });
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = _acc().hashExecute(calls, expiry);
        _acc().execute(calls, expiry, _sign(recoveredKey, digest));
    }

    // -----------------------------------------------------------------------------------
    // execute() — day-to-day operation, and what makes recovery meaningful
    // -----------------------------------------------------------------------------------

    function test_executePreRecovery_theEoasOwnKeyCanDrive() public {
        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](1);
        calls[0] = Eip7702RecoveryAccount.Call({ target: address(0xCAFE), value: 0, data: "" });
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = _acc().hashExecute(calls, expiry);
        _acc().execute(calls, expiry, _sign(eoaKey, digest));
    }

    function test_executePostRecovery_onlyTheNewOwnersKeyCanDrive() public {
        (address recoveredOwner, uint256 recoveredKey) = makeAddrAndKey("recoveredOwner");
        Eip7702RecoveryAccount.Intent memory intent = _intent(0, 0);
        intent.newOwner = recoveredOwner;
        _acc().initiateRecovery(intent, _sign(recoveryKey, _acc().hashIntent(intent)));
        vm.warp(block.timestamp + TIMELOCK);
        _acc().executeRecovery(intent);

        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](1);
        calls[0] = Eip7702RecoveryAccount.Call({ target: address(0xCAFE), value: 0, data: "" });
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = _acc().hashExecute(calls, expiry);

        // Neither the stale EOA key, nor the recovery key, nor an arbitrary relayer key may drive
        // execution after recovery — only the newly installed owner's key.
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().execute(calls, expiry, _sign(eoaKey, digest));
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().execute(calls, expiry, _sign(recoveryKey, digest));

        _acc().execute(calls, expiry, _sign(recoveredKey, digest));
    }

    function test_executeRejectsAnExpiredSignature() public {
        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](0);
        uint48 expiry = uint48(block.timestamp);
        bytes32 digest = _acc().hashExecute(calls, expiry);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Eip7702RecoveryAccount.ExecutionExpired.selector);
        _acc().execute(calls, expiry, _sign(eoaKey, digest));
    }

    function test_executeRejectsAReplayedSignature() public {
        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](0);
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = _acc().hashExecute(calls, expiry);
        bytes memory sig = _sign(eoaKey, digest);
        _acc().execute(calls, expiry, sig);
        // execNonce has advanced, so hashExecute (and hence the digest this signature was for) no
        // longer matches what the contract expects — replaying the exact same call reverts.
        vm.expectRevert(Eip7702RecoveryAccount.BadSignature.selector);
        _acc().execute(calls, expiry, sig);
    }

    function test_executeRevertsAtomicallyIfOneCallFails() public {
        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](2);
        calls[0] = Eip7702RecoveryAccount.Call({ target: address(0xCAFE), value: 0, data: "" });
        // A call to this test contract with bad calldata reverts (no matching function).
        calls[1] = Eip7702RecoveryAccount.Call({
            target: address(this),
            value: 0,
            data: abi.encodeWithSignature("thisFunctionDoesNotExist()")
        });
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = _acc().hashExecute(calls, expiry);
        vm.expectRevert(
            abi.encodeWithSelector(Eip7702RecoveryAccount.CallReverted.selector, 1, "")
        );
        _acc().execute(calls, expiry, _sign(eoaKey, digest));
    }

    function test_executeBatchesMultipleCallsAtomically() public {
        Eip7702RecoveryAccount.Call[] memory calls = new Eip7702RecoveryAccount.Call[](2);
        calls[0] = Eip7702RecoveryAccount.Call({ target: address(0xCAFE), value: 0, data: "" });
        calls[1] = Eip7702RecoveryAccount.Call({ target: address(0xBEEF), value: 0, data: "" });
        uint48 expiry = uint48(block.timestamp + 1 hours);
        bytes32 digest = _acc().hashExecute(calls, expiry);
        bytes[] memory results = _acc().execute(calls, expiry, _sign(eoaKey, digest));
        assertEq(results.length, 2);
    }

    // -----------------------------------------------------------------------------------
    // EIP-712 nested-struct encoding — a hand-rederived cross-check
    // -----------------------------------------------------------------------------------

    /**
     * @dev `hashRegister`'s `VetoConfig` nested-struct encoding is the easiest place in this file
     *      to get subtly wrong (nested-type ordering in the typehash string, or the array-of-
     *      atomic-values hashing rule) with no compiler error to catch it — a mistake here would
     *      only surface as a wallet computing a different digest than the contract expects. This
     *      test rederives the same digest via a second, independent code path — hand-written
     *      directly against the EIP-712 spec text rather than calling any of the contract's own
     *      `_hashVetoConfig`/`hashRegister` internals — and asserts they match. (This is not a
     *      substitute for cross-checking against a real off-chain EIP-712 library, e.g. viem's
     *      `TypedDataEncoder`, before this is ever used against a production wallet — no such
     *      library was available in this repo to check against here.)
     */
    function test_hashRegisterMatchesAnIndependentlyRederivedDigest() public view {
        GradualVeto.Config memory veto = _veto();
        Eip7702RecoveryAccount.RegisterMessage memory reg = Eip7702RecoveryAccount.RegisterMessage({
            recoveryOwner: recoveryOwner,
            veto: veto,
            nonce: 1
        });

        // -- Hand-rederived, independent of the contract's own hashing helpers --
        bytes32 vetoConfigTypehash = keccak256(
            "VetoConfig(address pauseAuthority,address abortAuthority,address[] resumeMembers,uint8 resumeThreshold,uint64 timelockSeconds,uint64 pauseCeilingSeconds)"
        );
        bytes32[] memory memberWords = new bytes32[](veto.resumeMembers.length);
        for (uint256 i = 0; i < veto.resumeMembers.length; i++) {
            memberWords[i] = bytes32(uint256(uint160(veto.resumeMembers[i])));
        }
        bytes32 resumeMembersHash = keccak256(abi.encodePacked(memberWords));
        bytes32 vetoStructHash = keccak256(
            abi.encode(
                vetoConfigTypehash,
                veto.pauseAuthority,
                veto.abortAuthority,
                resumeMembersHash,
                veto.resumeThreshold,
                veto.timelockSeconds,
                veto.pauseCeilingSeconds
            )
        );

        bytes32 registerTypehash = keccak256(
            "Register(address recoveryOwner,VetoConfig veto,uint256 nonce)VetoConfig(address pauseAuthority,address abortAuthority,address[] resumeMembers,uint8 resumeThreshold,uint64 timelockSeconds,uint64 pauseCeilingSeconds)"
        );
        bytes32 registerStructHash =
            keccak256(abi.encode(registerTypehash, reg.recoveryOwner, vetoStructHash, reg.nonce));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Nihilium7702RecoveryAccount"),
                keccak256("1.0.0"),
                block.chainid,
                eoa
            )
        );
        bytes32 expected =
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, registerStructHash));

        assertEq(_acc().hashRegister(reg), expected);
    }
}
