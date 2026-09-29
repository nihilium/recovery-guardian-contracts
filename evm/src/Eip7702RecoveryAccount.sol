// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ECDSA } from "solady/utils/ECDSA.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { ERC1271 } from "solady/accounts/ERC1271.sol";
import { Receiver } from "solady/accounts/Receiver.sol";
import { GradualVeto } from "./GradualVeto.sol";

/**
 * @title Eip7702RecoveryAccount
 * @notice Identity-gated, graduated-veto recovery for a plain EOA, settled through EIP-7702.
 *
 * @dev **This is the code an EOA delegates to, not a controller watching one from outside.**
 *      EIP-7702-delegated code executes with `address(this)` bound to the delegating EOA and all
 *      storage reads/writes hitting the EOA's own storage — proxy-like semantics, at the protocol
 *      level. One implementation, deployed once, therefore gives every delegating EOA an
 *      automatically isolated copy of this contract's storage. There is no `mapping(address =>
 *      ...)` anywhere in this file; every function operates on "whichever EOA is currently running
 *      this code", i.e. `address(this)`.
 *
 *      **Why not re-point the delegation on recovery (the design this replaces).** A type-04
 *      set-code authorization is only valid if `ecrecover` over it yields the *authority EOA's own
 *      key* (EIP-7702 spec). That is a hard, unconditional protocol guarantee: no one but the EOA
 *      itself can ever produce one, for any implementation, at any time. Recovery whose completion
 *      step needs a fresh one is therefore unusable for the scenario recovery exists for — a lost
 *      key can never sign anything again. So the delegation happens exactly **once**, ideally
 *      bundled into the account's own setup while its key is still live (mirroring how
 *      `RecoveryModule` gets installed at ERC-7579 account creation). After that, recovery is
 *      nothing but an ordinary contract call that rotates a stored `owner` — the exact structural
 *      analogue of `RecoveryModule.executeRecovery`'s direct `installModule` call, adapted for an
 *      EOA that has no separate "account" to install a module onto.
 *
 *      **The confinement principle, unchanged from `RecoveryModule`.** The recovered Nihilium key
 *      *assigns* a new owner — it decides which address may operate this EOA next — but never
 *      becomes the owner, never moves value directly, and never executes an arbitrary call itself.
 *      `executeRecovery`'s only effect is `owner = intent.newOwner`; everything the new owner can
 *      actually *do* goes through `execute()`, gated by an ordinary ECDSA check against whoever
 *      `owner` currently is.
 *
 *      **Registration is Nihilium-gated and EOA-consented, both.** `register` requires two
 *      independent signatures over the same message: one from the claimed `recoveryOwner` (only the
 *      identity ceremony can mint that key) and one from the account's *current* owner (initially
 *      the EOA's own key, later whatever `owner` a completed recovery installed). Nobody can bind a
 *      `recoveryOwner` to this EOA without the EOA's own key having signed off, at registration time
 *      and at every later rotation — closing the registration front-running window a
 *      single-signature, mapping-keyed design would leave open.
 *
 *      **Scope: loss, not theft.** Recovery cannot revoke the EOA's own key — nothing on-chain can.
 *      Whoever holds that key keeps protocol-level control of this address for good: it can send
 *      transactions directly and sign a fresh 7702 authorization that points the delegation at
 *      different code. So recovery restores control of an account whose key is *lost*; if the key
 *      was *stolen*, the thief is not locked out. And re-delegating this EOA to any other
 *      implementation turns recovery off (the state here stays in storage, dormant), which only the
 *      EOA's key can do — the same key whose loss recovery exists for.
 *
 *      **Still an ordinary account.** Once delegated the EOA has code, so it has to behave like a
 *      contract wallet: it accepts ETH and safe-transferred ERC-721/1155 tokens (`Receiver`) and
 *      answers ERC-1271 (`ERC1271`, with ERC-7739 nested typed data so a post-recovery owner's
 *      signature for one account cannot be replayed on another).
 */
contract Eip7702RecoveryAccount is ERC1271, Receiver {
    using GradualVeto for GradualVeto.Config;
    using GradualVeto for GradualVeto.Attempt;

    struct Intent {
        uint256 epoch;
        uint256 nonce;
        /// @dev The address `executeRecovery` will install as `owner`. Never the recovery key
        ///      itself — see the confinement principle above.
        address newOwner;
        uint48 expiry;
    }

    struct RegisterMessage {
        /// @dev The EVM address of `rk_pk`. This contract never holds the key, only its address.
        address recoveryOwner;
        GradualVeto.Config veto;
        uint256 nonce;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    struct Attempt {
        bytes32 intentHash;
        /// @dev Bumped on every `initiateRecovery` *and every `pause`*, folded into `resumeDigest`,
        ///      so a resume endorsement lifts exactly one pause. Never cleared.
        uint256 attemptSeq;
        GradualVeto.Attempt veto;
    }

    /// @custom:storage-location erc7201:nihilium.recovery.eip7702
    struct Layout {
        bool registered;
        /// @dev Whoever may currently drive `execute()`. Zero means "defaults to the EOA itself" —
        ///      see `_currentOwner()` — rather than requiring an explicit bootstrap write.
        address owner;
        address recoveryOwner;
        /// @dev Bumped on every completed recovery, which invalidates every prior-epoch intent.
        uint256 epoch;
        /// @dev Bumped on every completed *and every aborted* recovery. Spending the nonce on abort
        ///      is what makes abort final for that intent: its signature is public calldata, and
        ///      without the bump anyone could resubmit it and reopen the attempt until it expired.
        uint256 nonce;
        /// @dev Replay protection for `register`, independent of `epoch`/`nonce`: registration and
        ///      recovery are different signed actions and must not share a counter.
        uint256 configNonce;
        /// @dev Replay protection for `execute`, independent of both of the above: day-to-day
        ///      operation is a third, separate signed action.
        uint256 execNonce;
        GradualVeto.Config veto;
        Attempt attempt;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("nihilium.recovery.eip7702")) - 1)) &
    ///      ~bytes32(uint256(0xff)) — the ERC-7201 namespaced slot for this layout. Verified with
    ///      `cast index-erc7201 "nihilium.recovery.eip7702"`. Namespaced (not sequential slot 0, 1,
    ///      2…) because an EOA may hold a different 7702 delegation at a different point in its
    ///      life; a fixed offset from slot 0 would risk collision with whatever else it ever points
    ///      at, past or future.
    bytes32 private constant LAYOUT_SLOT =
        0xb8e1e21db727b01c04dcc5c771d2299259c9ff3784186ff887f854d1d6e35d00;

    function _layout() private pure returns (Layout storage l) {
        bytes32 slot = LAYOUT_SLOT;
        assembly {
            l.slot := slot
        }
    }

    bytes32 private constant INTENT_TYPEHASH =
        keccak256("Intent(uint256 epoch,uint256 nonce,address newOwner,uint48 expiry)");
    bytes32 private constant VETO_CONFIG_TYPEHASH = keccak256(
        "VetoConfig(address pauseAuthority,address abortAuthority,address[] resumeMembers,uint8 resumeThreshold,uint64 timelockSeconds,uint64 pauseCeilingSeconds)"
    );
    bytes32 private constant REGISTER_TYPEHASH = keccak256(
        "Register(address recoveryOwner,VetoConfig veto,uint256 nonce)"
        "VetoConfig(address pauseAuthority,address abortAuthority,address[] resumeMembers,uint8 resumeThreshold,uint64 timelockSeconds,uint64 pauseCeilingSeconds)"
    );
    bytes32 private constant CALL_TYPEHASH =
        keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant EXECUTE_TYPEHASH = keccak256(
        "Execute(Call[] calls,uint256 execNonce,uint48 expiry)"
        "Call(address target,uint256 value,bytes data)"
    );
    /// @dev The field keeps its 1.0.0 name, but since 2.0.0 `attemptSeq` also moves on every pause
    ///      — see `Attempt.attemptSeq`.
    bytes32 private constant RESUME_TYPEHASH =
        keccak256("Resume(bytes32 intentHash,uint256 attemptSeq)");

    event Registered(address indexed recoveryOwner, uint256 epoch);
    event RecoveryConfigUpdated(address indexed recoveryOwner, uint256 epoch);
    event RecoveryInitiated(bytes32 indexed intentHash, uint256 epoch);
    event RecoveryPaused(bytes32 indexed intentHash);
    event RecoveryResumed(bytes32 indexed intentHash);
    event RecoveryAborted(bytes32 indexed intentHash);
    event RecoveryExecuted(bytes32 indexed intentHash, uint256 newEpoch, address newOwner);
    event Executed(uint256 indexed execNonce, uint256 callCount);

    error NotRegistered();
    error WrongConfigNonce(uint256 expected, uint256 supplied);
    error AttemptInFlight();
    error NoAttempt();
    error UnknownIntent();
    error BadSignature();
    error IntentExpired();
    error WrongEpoch(uint256 expected, uint256 supplied);
    error WrongNonce(uint256 expected, uint256 supplied);
    error NotPauseAuthority();
    error NotAbortAuthority();
    error NotResumeQuorum();
    error DuplicateResumeSigner(address signer);
    error ZeroOwner();
    error ZeroRecoveryOwner();
    error ExecutionExpired();
    error CallReverted(uint256 index, bytes returndata);

    // ---------------------------------------------------------------------------------------
    // Registration — Nihilium-gated AND EOA-consented
    // ---------------------------------------------------------------------------------------

    /**
     * @notice Bind (or rotate) a recovery owner and veto config for this EOA.
     * @param reg A signed message committing the recovery owner it names, the veto config, and a
     *        registration nonce.
     * @param recoveryOwnerSignature `reg.recoveryOwner`'s signature over `hashRegister(reg)` — only
     *        the identity ceremony can mint this key, so the recovery owner is never one an
     *        attacker picks.
     * @param ownerSignature The *current* owner's signature over the same digest —
     *        `_currentOwner()`, which is this EOA's own key before any recovery has ever completed,
     *        or whatever a completed recovery installed afterward. This is what makes registration
     *        (and rotation) impossible to front-run: no one but whoever already controls this EOA
     *        can ever produce a valid second signature, regardless of who submits the transaction or
     *        when.
     * @dev Submission is permissionless, as with initiation: the authority is in the signatures, not
     *      the sender. Re-callable by design — there is no one-way "already registered" lock, only
     *      the requirement that every call, including the first, carry the current owner's consent.
     *
     *      **Refused while a recovery is in flight.** Rotating the key does *not* stop an attempt the
     *      old key already opened: `executeRecovery` checks the committed intent hash, and the
     *      recovery key's signature was verified back at `initiateRecovery` and is never re-checked.
     *      So a rotation performed *because* the old key was compromised would leave the attacker's
     *      attempt running while the owner believed they had just stopped it — and the new veto
     *      config would silently re-time it (a shorter timelock makes it executable at once; one
     *      shorter than the time already accrued makes every veto call revert). Killing an attempt
     *      is `abort`'s job, and it is a different authority on purpose.
     */
    function register(
        RegisterMessage calldata reg,
        bytes calldata recoveryOwnerSignature,
        bytes calldata ownerSignature
    ) external {
        Layout storage l = _layout();
        if (reg.nonce != l.configNonce) revert WrongConfigNonce(l.configNonce, reg.nonce);
        if (reg.recoveryOwner == address(0)) revert ZeroRecoveryOwner();
        if (
            l.attempt.veto.state != GradualVeto.State.NONE
                && !GradualVeto.isTerminal(l.veto.project(l.attempt.veto).state)
        ) {
            revert AttemptInFlight();
        }
        GradualVeto.validate(reg.veto);
        GradualVeto.validateRecoveryOwner(reg.veto, reg.recoveryOwner);

        bytes32 digest = hashRegister(reg);
        if (ECDSA.recoverCalldata(digest, recoveryOwnerSignature) != reg.recoveryOwner) {
            revert BadSignature();
        }
        if (!_isOwnerSignature(digest, ownerSignature)) revert BadSignature();

        l.configNonce += 1;
        bool wasRegistered = l.registered;

        l.registered = true;
        l.recoveryOwner = reg.recoveryOwner;
        l.veto.pauseAuthority = reg.veto.pauseAuthority;
        l.veto.abortAuthority = reg.veto.abortAuthority;
        l.veto.resumeMembers = reg.veto.resumeMembers;
        l.veto.resumeThreshold = reg.veto.resumeThreshold;
        l.veto.timelockSeconds = reg.veto.timelockSeconds;
        l.veto.pauseCeilingSeconds = reg.veto.pauseCeilingSeconds;

        if (wasRegistered) {
            emit RecoveryConfigUpdated(reg.recoveryOwner, l.epoch);
        } else {
            emit Registered(reg.recoveryOwner, l.epoch);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Recovery lifecycle
    // ---------------------------------------------------------------------------------------

    /**
     * @notice Start a recovery. Permissionless to *submit* — the authority is the Nihilium key's
     *         signature, not the sender, so a relayer can broadcast on behalf of a user who has
     *         lost their device.
     * @param intent The rotation the recovery will commit to: install `newOwner`.
     * @param signature The recovered key's EIP-712 signature over `hashIntent(intent)`.
     */
    function initiateRecovery(Intent calldata intent, bytes calldata signature) external {
        Layout storage l = _layout();
        if (!l.registered) revert NotRegistered();
        if (intent.newOwner == address(0)) revert ZeroOwner();
        if (intent.expiry <= block.timestamp) revert IntentExpired();
        if (intent.epoch != l.epoch) revert WrongEpoch(l.epoch, intent.epoch);
        if (intent.nonce != l.nonce) revert WrongNonce(l.nonce, intent.nonce);

        // One attempt at a time: a recovery key could not open many concurrent attempts and force
        // the veto holders to catch every one of them.
        if (
            l.attempt.veto.state != GradualVeto.State.NONE
                && !GradualVeto.isTerminal(l.veto.project(l.attempt.veto).state)
        ) {
            revert AttemptInFlight();
        }

        bytes32 intentHash = hashIntent(intent);
        if (ECDSA.recoverCalldata(intentHash, signature) != l.recoveryOwner) {
            revert BadSignature();
        }

        l.attempt.intentHash = intentHash;
        l.attempt.attemptSeq += 1;
        l.attempt.veto.start();
        emit RecoveryInitiated(intentHash, l.epoch);
    }

    /// @notice INITIATED -> PAUSED, by the pause authority only. Invalidates every resume signature
    ///         collected so far: lifting this pause takes fresh endorsements.
    function pause() external {
        Layout storage l = _requireRegistered();
        if (msg.sender != l.veto.pauseAuthority) revert NotPauseAuthority();
        _requireAttempt(l);
        l.veto.pause(l.attempt.veto);
        l.attempt.attemptSeq += 1;
        emit RecoveryPaused(l.attempt.intentHash);
    }

    /**
     * @notice PAUSED -> INITIATED, by a threshold of the resume quorum only.
     * @param signers Quorum members endorsing the resume, each of which must have signed
     *        `resumeDigest(intentHash)`. Distinct members only, so one cannot be counted twice.
     */
    function resume(address[] calldata signers, bytes[] calldata signatures) external {
        Layout storage l = _requireRegistered();
        _requireAttempt(l);

        if (signers.length != signatures.length) revert NotResumeQuorum();
        if (signers.length < l.veto.resumeThreshold) revert NotResumeQuorum();

        bytes32 digest = resumeDigest(l.attempt.intentHash);
        uint256 counted;
        for (uint256 i = 0; i < signers.length; i++) {
            address signer = signers[i];
            if (!l.veto.isResumeMember(signer)) revert NotResumeQuorum();
            for (uint256 j = 0; j < i; j++) {
                if (signers[j] == signer) revert DuplicateResumeSigner(signer);
            }
            if (ECDSA.recoverCalldata(digest, signatures[i]) != signer) revert BadSignature();
            counted++;
        }
        if (counted < l.veto.resumeThreshold) revert NotResumeQuorum();

        l.veto.resume(l.attempt.veto);
        emit RecoveryResumed(l.attempt.intentHash);
    }

    /// @notice Any non-terminal -> ABORTED, by the abort authority only. Irreversible.
    function abort() external {
        Layout storage l = _requireRegistered();
        if (msg.sender != l.veto.abortAuthority) revert NotAbortAuthority();
        _requireAttempt(l);
        l.veto.abort(l.attempt.veto);
        // Spend the aborted intent's nonce, so its public signature cannot reopen the attempt.
        l.nonce += 1;
        emit RecoveryAborted(l.attempt.intentHash);
    }

    /**
     * @notice EXECUTABLE -> EXECUTED: install the committed owner and bump the epoch.
     * @dev Unlike the design this replaces, this is the *entire* completion of a recovery — there is
     *      no further step, no second signature from this EOA, ever. The epoch bump invalidates
     *      every prior-epoch intent atomically, in the same transaction as the rotation.
     *      Permissionless to submit for the same reason as `initiateRecovery`.
     */
    function executeRecovery(Intent calldata intent) external {
        Layout storage l = _requireRegistered();
        _requireAttempt(l);

        // The intent must be the one this attempt was opened for, not merely a valid-looking one.
        if (hashIntent(intent) != l.attempt.intentHash) revert UnknownIntent();
        if (intent.epoch != l.epoch) revert WrongEpoch(l.epoch, intent.epoch);

        l.veto.execute(l.attempt.veto);

        l.epoch += 1;
        l.nonce += 1;
        l.owner = intent.newOwner;

        emit RecoveryExecuted(l.attempt.intentHash, l.epoch, intent.newOwner);
    }

    // ---------------------------------------------------------------------------------------
    // Execution — what makes a recovered owner's control real, not just a stored address
    // ---------------------------------------------------------------------------------------

    /**
     * @notice Run a batch of calls as this EOA, authorized by the current owner's signature.
     * @dev Gated by `_currentOwner()`, so it works identically before and after a recovery: before,
     *      it's a redundant-but-harmless capability (the EOA can already transact directly with its
     *      own live key); after, it's how the new owner operates the account — the only way, as
     *      long as the original key really is lost (see "Scope" above). That is the point of
     *      recovery producing usable control rather than an inert stored address. The owner may be
     *      a contract (a Safe, say): its approval is checked through ERC-1271.
     *
     *      Deliberately minimal: no target/selector allowlist, no plugin system. This exists to make
     *      recovery meaningful, not to be a general smart-account framework.
     */
    function execute(Call[] calldata calls, uint48 expiry, bytes calldata signature)
        external
        payable
        returns (bytes[] memory results)
    {
        Layout storage l = _layout();
        if (block.timestamp > expiry) revert ExecutionExpired();

        bytes32 digest = hashExecute(calls, expiry);
        if (!_isOwnerSignature(digest, signature)) revert BadSignature();

        uint256 execNonce = l.execNonce;
        l.execNonce = execNonce + 1;

        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{ value: calls[i].value }(calls[i].data);
            if (!ok) revert CallReverted(i, ret);
            results[i] = ret;
        }
        emit Executed(execNonce, calls.length);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice The effective state right now, with the clock projected forward.
    function stateOf() external view returns (GradualVeto.State) {
        Layout storage l = _layout();
        if (l.attempt.veto.state == GradualVeto.State.NONE) return GradualVeto.State.NONE;
        return l.veto.project(l.attempt.veto).state;
    }

    function attemptOf()
        external
        view
        returns (bytes32 intentHash, uint256 attemptSeq, GradualVeto.Attempt memory veto)
    {
        Layout storage l = _layout();
        return (l.attempt.intentHash, l.attempt.attemptSeq, l.veto.project(l.attempt.veto));
    }

    function configOf()
        external
        view
        returns (
            address currentOwner,
            address recoveryOwner,
            uint256 epoch,
            uint256 nonce,
            uint256 configNonce,
            uint256 execNonce,
            GradualVeto.Config memory veto
        )
    {
        Layout storage l = _layout();
        return (_currentOwner(), l.recoveryOwner, l.epoch, l.nonce, l.configNonce, l.execNonce, l.veto);
    }

    function isRegistered() external view returns (bool) {
        return _layout().registered;
    }

    /// @notice Whoever may currently drive `execute()` — this EOA itself until the first completed
    ///         recovery, whatever address the most recent one installed after that.
    function owner() external view returns (address) {
        return _currentOwner();
    }

    function name() external pure returns (string memory) {
        return "Nihilium7702RecoveryAccount";
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    function hashIntent(Intent calldata intent) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(INTENT_TYPEHASH, intent.epoch, intent.nonce, intent.newOwner, intent.expiry)
        );
        return _hashTypedData(structHash);
    }

    function hashRegister(RegisterMessage calldata reg) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(REGISTER_TYPEHASH, reg.recoveryOwner, _hashVetoConfig(reg.veto), reg.nonce)
        );
        return _hashTypedData(structHash);
    }

    function hashExecute(Call[] calldata calls, uint48 expiry) public view returns (bytes32) {
        uint256 n = calls.length;
        bytes32[] memory callHashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            callHashes[i] = keccak256(
                abi.encode(CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data))
            );
        }
        // EIP-712 array-of-structs rule: keccak256 of the concatenated struct hashes.
        bytes32 callsHash = keccak256(abi.encodePacked(callHashes));
        bytes32 structHash =
            keccak256(abi.encode(EXECUTE_TYPEHASH, callsHash, _layout().execNonce, expiry));
        return _hashTypedData(structHash);
    }

    /// @notice What a resume-quorum member signs. Bound to one pause via `attemptSeq`, which is
    ///         bumped on every `initiateRecovery` and every `pause` — so an endorsement cannot be
    ///         replayed onto a later pause of the same attempt, nor onto a later attempt. Sign it
    ///         after the pause it is meant to lift, reading the digest from this view.
    function resumeDigest(bytes32 intentHash) public view returns (bytes32) {
        uint256 attemptSeq = _layout().attempt.attemptSeq;
        return _hashTypedData(keccak256(abi.encode(RESUME_TYPEHASH, intentHash, attemptSeq)));
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev Whoever may currently sign as this account. Zero (the pre-recovery default, and never
    ///      explicitly written until a recovery happens) reads as `address(this)` — the EOA's own
    ///      key — rather than requiring a bootstrap write to make the very first `register()` call
    ///      possible.
    function _currentOwner() internal view returns (address) {
        address o = _layout().owner;
        return o == address(0) ? address(this) : o;
    }

    /// @dev Whether `signature` is the current owner's approval of `hash`. ECDSA first, so an owner
    ///      that is itself a 7702-delegated EOA (which has code) still signs with its key; ERC-1271
    ///      for a contract owner such as a Safe. Never ERC-1271 against `address(this)`: that would
    ///      call back into this account's own `isValidSignature` and recurse. Non-reverting, since
    ///      `isValidSignature` must answer rather than throw.
    function _isOwnerSignature(bytes32 hash, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        address currentOwner = _currentOwner();
        if (ECDSA.tryRecoverCalldata(hash, signature) == currentOwner) return true;
        if (currentOwner == address(this)) return false;
        return SignatureCheckerLib.isValidSignatureNowCalldata(currentOwner, hash, signature);
    }

    /// @dev The EIP-712 domain: `Nihilium7702RecoveryAccount` / `2.0.0`, on this chain, with this
    ///      EOA as `verifyingContract`. Solady's `EIP712` caches the separator against the address
    ///      that ran the constructor — this implementation's own — and rebuilds it whenever
    ///      `address(this)` differs, which under 7702 is every call. So each delegating EOA gets its
    ///      *own* domain, as it must: a separator cached for the implementation would verify every
    ///      EOA's signatures against the wrong domain.
    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name_, string memory version_)
    {
        return ("Nihilium7702RecoveryAccount", "2.0.0");
    }

    /// @dev ERC-1271 answers for whoever may currently operate this account.
    function _erc1271Signer() internal view override returns (address) {
        return _currentOwner();
    }

    function _erc1271IsValidSignatureNowCalldata(bytes32 hash, bytes calldata signature)
        internal
        view
        override
        returns (bool)
    {
        return _isOwnerSignature(hash, signature);
    }

    /// @dev Before any recovery the owner is this EOA's own key, and a plain signature over `hash`
    ///      is exactly what that key produced before delegation — so it is accepted as-is, and
    ///      delegating does not break the EOA's existing permits and logins. After a recovery the
    ///      owner is a different key that may own other accounts too, so only the ERC-7739 nested
    ///      forms (which bind this account) are accepted.
    function _erc1271IsValidSignature(bytes32 hash, bytes calldata signature)
        internal
        view
        override
        returns (bool)
    {
        if (
            _currentOwner() == address(this)
                && ECDSA.tryRecoverCalldata(hash, signature) == address(this)
        ) return true;
        return super._erc1271IsValidSignature(hash, signature);
    }

    /// @dev The EIP-712 hash of the veto config as a nested `VetoConfig` struct, so `Register`
    ///      commits every field a signer's wallet can render — unlike hashing to an opaque bytes32,
    ///      this lets pauseAuthority/abortAuthority/resumeMembers/resumeThreshold actually be seen
    ///      before signing.
    function _hashVetoConfig(GradualVeto.Config calldata veto) internal pure returns (bytes32) {
        uint256 n = veto.resumeMembers.length;
        bytes32[] memory encoded = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            encoded[i] = bytes32(uint256(uint160(veto.resumeMembers[i])));
        }
        // EIP-712 array-of-atomic-values rule: keccak256 of the concatenated 32-byte-padded
        // encoding of each element — NOT abi.encodePacked(address[]), which packs each address to
        // 20 bytes and would silently produce a different, non-standard hash.
        bytes32 membersHash = keccak256(abi.encodePacked(encoded));
        return keccak256(
            abi.encode(
                VETO_CONFIG_TYPEHASH,
                veto.pauseAuthority,
                veto.abortAuthority,
                membersHash,
                veto.resumeThreshold,
                veto.timelockSeconds,
                veto.pauseCeilingSeconds
            )
        );
    }

    function _requireRegistered() internal view returns (Layout storage l) {
        l = _layout();
        if (!l.registered) revert NotRegistered();
    }

    function _requireAttempt(Layout storage l) internal view {
        if (l.attempt.veto.state == GradualVeto.State.NONE) revert NoAttempt();
    }
}
