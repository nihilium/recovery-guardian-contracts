// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { GradualVeto } from "../src/GradualVeto.sol";

/// @dev Exposes the library over real storage so the state machine can be exercised on its own,
///      without the module's authorization layer in the way. Keeping the two separable is what lets
///      a failure say *which* of the two is wrong.
contract GradualVetoHarness {
    using GradualVeto for GradualVeto.Config;

    GradualVeto.Config internal config;
    GradualVeto.Attempt internal attempt;

    constructor(GradualVeto.Config memory initial) {
        GradualVeto.validate(initial);
        config.pauseAuthority = initial.pauseAuthority;
        config.abortAuthority = initial.abortAuthority;
        config.resumeMembers = initial.resumeMembers;
        config.resumeThreshold = initial.resumeThreshold;
        config.timelockSeconds = initial.timelockSeconds;
        config.pauseCeilingSeconds = initial.pauseCeilingSeconds;
    }

    function start() external {
        GradualVeto.start(attempt);
    }

    function pause() external {
        config.pause(attempt);
    }

    function resume() external {
        config.resume(attempt);
    }

    function abort() external {
        config.abort(attempt);
    }

    function execute() external {
        config.execute(attempt);
    }

    function state() external view returns (GradualVeto.State) {
        return config.project(attempt).state;
    }

    function projected() external view returns (GradualVeto.Attempt memory) {
        return config.project(attempt);
    }

    function raw() external view returns (GradualVeto.Attempt memory) {
        return attempt;
    }

    function validateConfig(GradualVeto.Config memory candidate) external pure {
        GradualVeto.validate(candidate);
    }
}
