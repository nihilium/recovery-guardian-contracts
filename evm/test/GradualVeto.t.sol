// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { GradualVeto } from "../src/GradualVeto.sol";
import { GradualVetoHarness } from "./GradualVetoHarness.sol";

/// @dev The §15 conformance suite for the state machine. The negative cases carry the weight here:
///      what matters is not that the happy path works, but that nothing else does.
contract GradualVetoTest is Test {
    GradualVetoHarness internal veto;

    address internal pauser;
    address internal aborter;
    address internal g1;
    address internal g2;

    uint64 internal constant TIMELOCK = 100;
    uint64 internal constant CEILING = 50;

    function setUp() public {
        pauser = makeAddr("pauseAuthority");
        aborter = makeAddr("abortAuthority");
        g1 = makeAddr("guardian1");
        g2 = makeAddr("guardian2");
        veto = new GradualVetoHarness(_config());
        vm.warp(1_000);
    }

    function _config() internal view returns (GradualVeto.Config memory config) {
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

    // -----------------------------------------------------------------------------------
    // Happy path
    // -----------------------------------------------------------------------------------

    function test_maturesAfterExactlyTimelockSeconds() public {
        veto.start();
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.INITIATED));

        vm.warp(block.timestamp + TIMELOCK - 1);
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.INITIATED), "matured one block early");

        vm.warp(block.timestamp + 1);
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.EXECUTABLE));

        veto.execute();
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.EXECUTED));
    }

    /// @dev "Stop the clock", not "reset the clock". If a pause reset accrued time, a pause-holder
    ///      could delay a recovery forever in ceiling-sized increments without ever breaching it.
    function test_pausePreservesAccruedTime() public {
        veto.start();
        vm.warp(block.timestamp + 60);

        vm.prank(pauser);
        veto.pause();
        vm.warp(block.timestamp + 30);
        assertEq(veto.projected().accruedSeconds, 60, "clock ran while paused");

        veto.resume();
        vm.warp(block.timestamp + 40);
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.EXECUTABLE));
    }

    // -----------------------------------------------------------------------------------
    // §15: EXECUTED requires a matured timelock
    // -----------------------------------------------------------------------------------

    function test_executeRevertsBeforeMaturity() public {
        veto.start();
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        veto.execute();
    }

    function test_executeRevertsWhilePaused() public {
        veto.start();
        veto.pause();
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        veto.execute();
    }

    function test_executeRevertsAfterAbort() public {
        veto.start();
        veto.abort();
        vm.warp(block.timestamp + 10 * TIMELOCK);
        vm.expectRevert(GradualVeto.NotExecutable.selector);
        veto.execute();
    }

    /// @dev The load-bearing claim: an aborted recovery stays aborted no matter how much time passes.
    function testFuzz_abortedNeverBecomesExecutable(uint32 elapsed) public {
        veto.start();
        veto.abort();
        vm.warp(block.timestamp + uint256(elapsed));
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.ABORTED));
    }

    // -----------------------------------------------------------------------------------
    // §15: pause only from INITIATED
    // -----------------------------------------------------------------------------------

    function test_pauseRevertsFromExecutable() public {
        veto.start();
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(GradualVeto.NotInitiated.selector);
        veto.pause();
    }

    function test_pauseRevertsWhenAlreadyPaused() public {
        veto.start();
        veto.pause();
        vm.expectRevert(GradualVeto.NotInitiated.selector);
        veto.pause();
    }

    function test_pauseRevertsAfterAbort() public {
        veto.start();
        veto.abort();
        vm.expectRevert(GradualVeto.AlreadyTerminal.selector);
        veto.pause();
    }

    // -----------------------------------------------------------------------------------
    // §15: resume only from PAUSED
    // -----------------------------------------------------------------------------------

    function test_resumeRevertsFromInitiated() public {
        veto.start();
        vm.expectRevert(GradualVeto.NotPaused.selector);
        veto.resume();
    }

    function test_resumeRevertsFromExecutable() public {
        veto.start();
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(GradualVeto.NotPaused.selector);
        veto.resume();
    }

    // -----------------------------------------------------------------------------------
    // §15: pauseCeiling auto-resumes without a resume signature
    // -----------------------------------------------------------------------------------

    function test_autoResumesAtCeilingWithNoResumeCall() public {
        veto.start();
        veto.pause();

        vm.warp(block.timestamp + CEILING - 1);
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.PAUSED));

        vm.warp(block.timestamp + 1);
        // Nobody called resume(). The ceiling alone must lift it, or a pause-holder could freeze
        // the account permanently.
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.INITIATED));
    }

    function test_ceilingRemainderAccruesTowardTimelock() public {
        veto.start();
        veto.pause();
        vm.warp(block.timestamp + CEILING + TIMELOCK);
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.EXECUTABLE));
    }

    /// @dev A permanent freeze is the pause-holder's abuse mode; this proves it is bounded even
    ///      against a holder who re-pauses at the first opportunity, forever.
    function test_repeatedPausingStillMatures() public {
        veto.start();
        for (uint256 i = 0; i < TIMELOCK; i++) {
            if (veto.state() == GradualVeto.State.EXECUTABLE) break;
            vm.prank(pauser);
            veto.pause();
            vm.warp(block.timestamp + CEILING + 1);
        }
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.EXECUTABLE));
    }

    /// @dev Projection must not depend on how often anyone pokes the contract.
    function testFuzz_projectionIsIndependentOfObservationFrequency(uint16 total) public {
        vm.assume(total > 0 && total < 5_000);

        GradualVetoHarness a = new GradualVetoHarness(_config());
        GradualVetoHarness b = new GradualVetoHarness(_config());
        a.start();
        b.start();
        a.pause();
        b.pause();

        vm.warp(block.timestamp + total);
        GradualVeto.State oneJump = a.state();

        // Same elapsed time, observed in many small steps.
        vm.warp(block.timestamp - total);
        for (uint256 i = 0; i < total; i++) {
            vm.warp(block.timestamp + 1);
            b.state();
        }
        assertEq(uint8(b.state()), uint8(oneJump));
    }

    // -----------------------------------------------------------------------------------
    // §15: abort from any non-terminal, irreversible
    // -----------------------------------------------------------------------------------

    function test_abortsFromInitiated() public {
        veto.start();
        veto.abort();
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.ABORTED));
    }

    function test_abortsFromPaused() public {
        veto.start();
        veto.pause();
        veto.abort();
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.ABORTED));
    }

    function test_abortsFromExecutable() public {
        veto.start();
        vm.warp(block.timestamp + TIMELOCK);
        veto.abort();
        assertEq(uint8(veto.state()), uint8(GradualVeto.State.ABORTED));
    }

    function test_abortIsIrreversible() public {
        veto.start();
        veto.abort();
        vm.expectRevert(GradualVeto.AlreadyTerminal.selector);
        veto.abort();
    }

    function test_cannotAbortAnExecutedRecovery() public {
        veto.start();
        vm.warp(block.timestamp + TIMELOCK);
        veto.execute();
        vm.expectRevert(GradualVeto.AlreadyTerminal.selector);
        veto.abort();
    }

    // -----------------------------------------------------------------------------------
    // §6.1 config validation, on-chain
    // -----------------------------------------------------------------------------------

    function test_rejectsPauserWhoAlsoHoldsAbort() public {
        GradualVeto.Config memory config = _config();
        config.abortAuthority = pauser;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "pause and abort held by one party")
        );
        veto.validateConfig(config);
    }

    function test_rejectsPauserInsideResumeQuorum() public {
        GradualVeto.Config memory config = _config();
        config.resumeMembers[0] = pauser;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "pause and resume held by one party")
        );
        veto.validateConfig(config);
    }

    function test_rejectsAborterInsideResumeQuorum() public {
        GradualVeto.Config memory config = _config();
        config.resumeMembers[1] = aborter;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "resume and abort held by one party")
        );
        veto.validateConfig(config);
    }

    function test_rejectsDuplicateQuorumMember() public {
        GradualVeto.Config memory config = _config();
        config.resumeMembers[1] = g1;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "resumeQuorum contains a duplicate")
        );
        veto.validateConfig(config);
    }

    function test_rejectsZeroPauseCeiling() public {
        GradualVeto.Config memory config = _config();
        config.pauseCeilingSeconds = 0;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "pauseCeilingSeconds is zero")
        );
        veto.validateConfig(config);
    }

    function test_rejectsZeroTimelock() public {
        GradualVeto.Config memory config = _config();
        config.timelockSeconds = 0;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "timelockSeconds is zero")
        );
        veto.validateConfig(config);
    }

    function test_rejectsThresholdAboveMembership() public {
        GradualVeto.Config memory config = _config();
        config.resumeThreshold = 3;
        vm.expectRevert(
            abi.encodeWithSelector(GradualVeto.InvalidConfig.selector, "resumeThreshold exceeds membership")
        );
        veto.validateConfig(config);
    }
}
