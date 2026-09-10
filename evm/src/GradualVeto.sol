// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title GradualVeto
 * @notice The graduated-veto state machine (spec §6.3), as a pure library over a storage struct.
 *
 * @dev The invariant this library exists to enforce: **no authority named in `Config` can reach
 *      `EXECUTED`**. Pause, resume and abort only speed, slow or stop the clock. Reaching `EXECUTED`
 *      requires a matured timelock and a valid identity-gate proof, and neither is a veto key.
 *      Every function below is written so that property is checkable by reading this file alone.
 *
 *      The chain has no "tick", so time is applied lazily: `project` replays the clock from the last
 *      checkpoint to `block.timestamp` and is the exact analogue of the `advance` function in the
 *      TypeScript veto package.
 *
 *      **The clock is wall-clock seconds, not blocks.** A timelock is a human interval — the time a
 *      hijacked recovery has to be noticed and paused — and a block count only approximates that at
 *      a rate that differs per chain, so one config meant roughly a fortnight on Ethereum and a few
 *      days on a 2-second-block L2. On Arbitrum it was worse than imprecise: `block.number` there is
 *      the *L1* height, not the chain's own. `RecoveryModule` already timestamps intent expiry, so
 *      this also removes a second, disagreeing clock from the same contract.
 *
 *      Timestamps are proposer-influenced by a few seconds. Against a timelock measured in days that
 *      is immaterial, and it buys a parameter that means the same thing on every chain.
 *
 *      That machine is the oracle; this one is checked against it by
 *      `test/VetoDifferential.t.sol`, which replays traces the oracle generated. Two independent
 *      derivations of a security state machine is two chances to get it subtly different.
 */
library GradualVeto {
    /// @dev `NONE` distinguishes "no attempt" from a real state; the TS oracle has no such member
    ///      because an absent attempt is represented there by the absence of an object.
    enum State {
        NONE,
        INITIATED,
        PAUSED,
        EXECUTABLE,
        EXECUTED,
        ABORTED
    }

    struct Config {
        address pauseAuthority;
        address abortAuthority;
        address[] resumeMembers;
        uint8 resumeThreshold;
        uint64 timelockSeconds;
        uint64 pauseCeilingSeconds;
    }

    struct Attempt {
        State state;
        /// @dev Seconds accrued toward `timelockSeconds`, as of `checkpointTime`.
        uint64 accruedSeconds;
        /// @dev Seconds spent in the current pause, as of `checkpointTime`.
        uint64 pausedSeconds;
        /// @dev The timestamp `accruedSeconds` / `pausedSeconds` were last brought up to date at.
        uint64 checkpointTime;
    }

    error NotInitiated();
    error NotPaused();
    error NotExecutable();
    error AlreadyTerminal();
    error InvalidConfig(string reason);

    /**
     * @notice The effective attempt at `block.timestamp`, with the clock replayed forward.
     * @dev Pure and view-safe, so a caller can read the true state without sending a transaction —
     *      a paused attempt that has passed its ceiling really is INITIATED again, whether or not
     *      anyone has poked the contract. Anything else would make the auto-resume depend on someone
     *      paying gas to notice it, which is exactly the permanent-lockout failure it prevents.
     */
    function project(Config storage config, Attempt memory attempt)
        internal
        view
        returns (Attempt memory)
    {
        if (attempt.state == State.NONE || isTerminal(attempt.state) || attempt.state == State.EXECUTABLE)
        {
            return attempt;
        }

        uint64 remaining = uint64(block.timestamp) - attempt.checkpointTime;
        attempt.checkpointTime = uint64(block.timestamp);

        while (remaining > 0) {
            if (attempt.state == State.PAUSED) {
                uint64 untilCeiling = config.pauseCeilingSeconds - attempt.pausedSeconds;
                if (remaining < untilCeiling) {
                    attempt.pausedSeconds += remaining;
                    return attempt;
                }
                // Ceiling reached: auto-resume, with no resume signature involved (§15).
                attempt.state = State.INITIATED;
                attempt.pausedSeconds = 0;
                remaining -= untilCeiling;
            } else if (attempt.state == State.INITIATED) {
                uint64 untilMature = config.timelockSeconds - attempt.accruedSeconds;
                if (remaining < untilMature) {
                    attempt.accruedSeconds += remaining;
                    return attempt;
                }
                attempt.state = State.EXECUTABLE;
                attempt.accruedSeconds = config.timelockSeconds;
                return attempt;
            } else {
                return attempt;
            }
        }
        return attempt;
    }

    /// @notice Bring storage up to date with the projected clock.
    function settle(Config storage config, Attempt storage attempt) internal {
        Attempt memory projected = project(config, attempt);
        attempt.state = projected.state;
        attempt.accruedSeconds = projected.accruedSeconds;
        attempt.pausedSeconds = projected.pausedSeconds;
        attempt.checkpointTime = projected.checkpointTime;
    }

    function start(Attempt storage attempt) internal {
        attempt.state = State.INITIATED;
        attempt.accruedSeconds = 0;
        attempt.pausedSeconds = 0;
        attempt.checkpointTime = uint64(block.timestamp);
    }

    /**
     * @notice INITIATED -> PAUSED. Deliberately NOT legal from EXECUTABLE: once the timelock has
     *         matured the window for slowing things down has closed, and only abort remains (§15).
     */
    function pause(Config storage config, Attempt storage attempt) internal {
        settle(config, attempt);
        // Terminality is reported separately from "wrong state": "this recovery is already over" is
        // an actionable answer for a watchtower, whereas "not initiated" sends it looking for a
        // race that never happened.
        if (isTerminal(attempt.state)) revert AlreadyTerminal();
        if (attempt.state != State.INITIATED) revert NotInitiated();
        attempt.state = State.PAUSED;
        attempt.pausedSeconds = 0;
    }

    /// @notice PAUSED -> INITIATED. The accrued timelock is preserved: the clock stopped, it did not reset.
    function resume(Config storage config, Attempt storage attempt) internal {
        settle(config, attempt);
        if (isTerminal(attempt.state)) revert AlreadyTerminal();
        if (attempt.state != State.PAUSED) revert NotPaused();
        attempt.state = State.INITIATED;
        attempt.pausedSeconds = 0;
    }

    /// @notice Any non-terminal -> ABORTED. Irreversible.
    function abort(Config storage config, Attempt storage attempt) internal {
        settle(config, attempt);
        if (attempt.state == State.NONE) revert NotInitiated();
        if (isTerminal(attempt.state)) revert AlreadyTerminal();
        attempt.state = State.ABORTED;
    }

    /**
     * @notice EXECUTABLE -> EXECUTED. The only transition that can move value, and the only one no
     *         veto authority can drive.
     */
    function execute(Config storage config, Attempt storage attempt) internal {
        settle(config, attempt);
        if (attempt.state != State.EXECUTABLE) revert NotExecutable();
        attempt.state = State.EXECUTED;
    }

    function isTerminal(State state) internal pure returns (bool) {
        return state == State.EXECUTED || state == State.ABORTED;
    }

    function isResumeMember(Config storage config, address candidate) internal view returns (bool) {
        uint256 length = config.resumeMembers.length;
        for (uint256 i = 0; i < length; i++) {
            if (config.resumeMembers[i] == candidate) return true;
        }
        return false;
    }

    /**
     * @notice The §6.1 independence invariant, enforced on-chain rather than trusted from the client.
     * @dev The SDK validates this too, but a config only the client checked is a config an attacker
     *      can simply not check. "A resume key wieldable by whoever can forge the condition turns the
     *      pause into theater" — so the chain has to refuse it as well.
     *
     *      What cannot be checked here: whether the abort key is genuinely bare (§7), and whether the
     *      resume quorum is disjoint from the identity-condition surface. Neither fact exists
     *      on-chain. Those stay client-side in `validateVetoConfig`, and that asymmetry is real
     *      rather than an oversight.
     */
    function validate(Config memory config) internal pure {
        if (config.pauseAuthority == address(0)) revert InvalidConfig("pauseAuthority is zero");
        if (config.abortAuthority == address(0)) revert InvalidConfig("abortAuthority is zero");
        if (config.resumeMembers.length == 0) revert InvalidConfig("resumeQuorum is empty");
        if (config.resumeThreshold == 0) revert InvalidConfig("resumeThreshold is zero");
        if (config.resumeThreshold > config.resumeMembers.length) {
            revert InvalidConfig("resumeThreshold exceeds membership");
        }
        if (config.timelockSeconds == 0) revert InvalidConfig("timelockSeconds is zero");
        // Without a positive ceiling a pause never auto-resumes, and the pause-holder's bounded
        // "freeze" becomes an unbounded one.
        if (config.pauseCeilingSeconds == 0) revert InvalidConfig("pauseCeilingSeconds is zero");

        if (config.abortAuthority == config.pauseAuthority) {
            revert InvalidConfig("pause and abort held by one party");
        }

        uint256 length = config.resumeMembers.length;
        for (uint256 i = 0; i < length; i++) {
            address member = config.resumeMembers[i];
            if (member == address(0)) revert InvalidConfig("resumeQuorum contains zero address");
            if (member == config.pauseAuthority) {
                revert InvalidConfig("pause and resume held by one party");
            }
            if (member == config.abortAuthority) {
                revert InvalidConfig("resume and abort held by one party");
            }
            // A duplicated member inflates the apparent threshold: a "2-of-3" whose members are
            // A, A, B is really 1-of-2.
            for (uint256 j = i + 1; j < length; j++) {
                if (config.resumeMembers[j] == member) {
                    revert InvalidConfig("resumeQuorum contains a duplicate");
                }
            }
        }
    }
}
