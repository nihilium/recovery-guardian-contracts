// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC7579ExecutorBase } from "modulekit/module-bases/ERC7579ExecutorBase.sol";
import { IERC7579Account } from "modulekit/accounts/common/interfaces/IERC7579Account.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";
import { GradualVeto } from "./GradualVeto.sol";

/**
 * @title RecoveryModule
 * @notice ERC-7579 executor implementing identity-gated, graduated-veto account recovery (spec
 * §8).
 *
 * @dev **Why an executor and not a validator.** Registering the recovery key as a validator would
 *      let it authorize *any* user operation, which throws away confinement: whoever extracts the
 *      raw key drains the account. As an executor, the recovery key's signature authorizes exactly
 *      one thing — a committed validator rotation on a committed account, after a matured
 * timelock,
 *      subject to the veto. That is what makes §15's "raw-rk extraction still yields only the
 *      committed, vetoable rotation" true rather than aspirational.
 *
 *      **What execution can do.** `executeRecovery` performs one call, which this contract
 *      constructs: `installModule(TYPE_VALIDATOR, …)` on the recovering account. The intent
 * chooses
 *      the validator and its init data, never the call shape and never the target. There is no path
 *      through this module that moves a token or makes an arbitrary call.
 *
 *      **What it deliberately does not do.** It does not uninstall the superseded validator.
 *      Removing a module from an ERC-7579 sentinel list needs the caller to supply the correct
 *      predecessor pointer, and getting that wrong bricks the list. Recovery's scope is loss, not
 *      theft (§1): the superseded key is gone, not hostile. Removing it is a follow-up the
 * recovered
 *      owner performs deliberately, not something bundled into the recovery transaction.
 */
contract RecoveryModule is ERC7579ExecutorBase {
    using GradualVeto for GradualVeto.Config;
    using GradualVeto for GradualVeto.Attempt;

    uint256 internal constant MODULE_TYPE_EXECUTOR = 2;
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;

    /// @notice What the recovery key signs. Binding every field is what stops an intent being
    ///         replayed onto another account, another epoch, or after it has gone stale.
    struct Intent {
        address account;
        uint256 epoch;
        uint256 nonce;
        address newValidator;
        bytes newValidatorInitData;
        uint48 expiry;
    }

    struct AccountConfig {
        bool installed;
        /// @dev The EVM address of `rk_pk`. The module never holds the key, only its address.
        address recoveryOwner;
        /// @dev Bumped on every completed recovery, which invalidates every prior-epoch intent.
        uint256 epoch;
        uint256 nonce;
        GradualVeto.Config veto;
    }

    struct Attempt {
        bytes32 intentHash;
        GradualVeto.Attempt veto;
    }

    mapping(address account => AccountConfig) internal _configs;
    mapping(address account => Attempt) internal _attempts;

    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "Intent(address account,uint256 epoch,uint256 nonce,address newValidator,bytes newValidatorInitData,uint48 expiry)"
    );
    bytes32 private constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    event RecoveryRegistered(address indexed account, address indexed recoveryOwner, uint256 epoch);
    event RecoveryInitiated(address indexed account, bytes32 indexed intentHash, uint256 epoch);
    event RecoveryPaused(address indexed account, bytes32 indexed intentHash);
    event RecoveryResumed(address indexed account, bytes32 indexed intentHash);
    event RecoveryAborted(address indexed account, bytes32 indexed intentHash);
    event RecoveryExecuted(address indexed account, bytes32 indexed intentHash, uint256 newEpoch);

    error NotInstalled(address account);
    error AlreadyInstalled(address account);
    error AttemptInFlight(address account);
    error NoAttempt(address account);
    error UnknownIntent();
    error BadSignature();
    error IntentExpired();
    error WrongEpoch(uint256 expected, uint256 supplied);
    error WrongNonce(uint256 expected, uint256 supplied);
    error WrongAccount();
    error NotPauseAuthority();
    error NotAbortAuthority();
    error NotResumeQuorum();
    error DuplicateResumeSigner(address signer);
    error ZeroValidator();

    // ---------------------------------------------------------------------------------------
    // Installation
    // ---------------------------------------------------------------------------------------

    /// @param data abi.encode(address recoveryOwner, GradualVeto.Config veto)
    function onInstall(bytes calldata data) external override {
        if (_configs[msg.sender].installed) revert AlreadyInstalled(msg.sender);

        (address recoveryOwner, GradualVeto.Config memory veto) =
            abi.decode(data, (address, GradualVeto.Config));
        if (recoveryOwner == address(0)) revert BadSignature();
        GradualVeto.validate(veto);

        AccountConfig storage config = _configs[msg.sender];
        config.installed = true;
        config.recoveryOwner = recoveryOwner;
        config.veto.pauseAuthority = veto.pauseAuthority;
        config.veto.abortAuthority = veto.abortAuthority;
        config.veto.resumeMembers = veto.resumeMembers;
        config.veto.resumeThreshold = veto.resumeThreshold;
        config.veto.timelockSeconds = veto.timelockSeconds;
        config.veto.pauseCeilingSeconds = veto.pauseCeilingSeconds;

        emit RecoveryRegistered(msg.sender, recoveryOwner, config.epoch);
    }

    /**
     * @dev Uninstalling clears the config and any in-flight attempt. The epoch is deliberately NOT
     *      reset: it is replay-protection state, and zeroing it on uninstall would make every
     *      previously-signed intent valid again the moment the module was reinstalled.
     */
    function onUninstall(bytes calldata) external override {
        AccountConfig storage config = _configs[msg.sender];
        if (!config.installed) revert NotInstalled(msg.sender);
        config.installed = false;
        config.recoveryOwner = address(0);
        delete config.veto;
        delete _attempts[msg.sender];
    }

    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == MODULE_TYPE_EXECUTOR;
    }

    function isInitialized(address account) external view override returns (bool) {
        return _configs[account].installed;
    }

    function name() external pure returns (string memory) {
        return "NihiliumRecoveryModule";
    }

    function version() external pure returns (string memory) {
        return "2.0.0";
    }

    // ---------------------------------------------------------------------------------------
    // Recovery lifecycle
    // ---------------------------------------------------------------------------------------

    /**
     * @notice Start a recovery. Permissionless to *submit* — the authority is the signature, not
     * the
     *         sender, so a relayer or watchtower can broadcast on behalf of a user who has lost
     * their
     *         device and has no funded account to pay gas from.
     */
    function initiateRecovery(Intent calldata intent, bytes calldata signature) external {
        AccountConfig storage config = _configs[intent.account];
        if (!config.installed) revert NotInstalled(intent.account);
        if (intent.newValidator == address(0)) revert ZeroValidator();
        if (intent.expiry <= block.timestamp) revert IntentExpired();
        if (intent.epoch != config.epoch) revert WrongEpoch(config.epoch, intent.epoch);
        if (intent.nonce != config.nonce) revert WrongNonce(config.nonce, intent.nonce);

        Attempt storage attempt = _attempts[intent.account];
        // One attempt at a time. Without this, a recovery key could open many concurrent attempts
        // and force the veto holders to catch every one of them.
        if (
            attempt.veto.state != GradualVeto.State.NONE
                && !GradualVeto.isTerminal(config.veto.project(attempt.veto).state)
        ) {
            revert AttemptInFlight(intent.account);
        }

        bytes32 intentHash = hashIntent(intent);
        if (ECDSA.recoverCalldata(intentHash, signature) != config.recoveryOwner) {
            revert BadSignature();
        }

        attempt.intentHash = intentHash;
        GradualVeto.start(attempt.veto);
        emit RecoveryInitiated(intent.account, intentHash, config.epoch);
    }

    /// @notice INITIATED -> PAUSED, by the pause authority only (§15).
    function pause(address account) external {
        AccountConfig storage config = _requireInstalled(account);
        if (msg.sender != config.veto.pauseAuthority) revert NotPauseAuthority();
        Attempt storage attempt = _requireAttempt(account);
        config.veto.pause(attempt.veto);
        emit RecoveryPaused(account, attempt.intentHash);
    }

    /**
     * @notice PAUSED -> INITIATED, by a threshold of the resume quorum only (§15).
     * @param signers Quorum members endorsing the resume, each of which must have signed
     *        `resumeDigest(account)`. Plurality is the defence against premature release, so the
     *        threshold is checked against *distinct* members — a repeated signer is rejected
     * rather
     *        than counted twice.
     */
    function resume(address account, address[] calldata signers, bytes[] calldata signatures)
        external
    {
        AccountConfig storage config = _requireInstalled(account);
        Attempt storage attempt = _requireAttempt(account);

        if (signers.length != signatures.length) revert NotResumeQuorum();
        if (signers.length < config.veto.resumeThreshold) revert NotResumeQuorum();

        bytes32 digest = resumeDigest(account, attempt.intentHash);
        uint256 counted;
        for (uint256 i = 0; i < signers.length; i++) {
            address signer = signers[i];
            if (!config.veto.isResumeMember(signer)) revert NotResumeQuorum();
            for (uint256 j = 0; j < i; j++) {
                if (signers[j] == signer) revert DuplicateResumeSigner(signer);
            }
            if (ECDSA.recoverCalldata(digest, signatures[i]) != signer) revert BadSignature();
            counted++;
        }
        if (counted < config.veto.resumeThreshold) revert NotResumeQuorum();

        config.veto.resume(attempt.veto);
        emit RecoveryResumed(account, attempt.intentHash);
    }

    /**
     * @notice Any non-terminal -> ABORTED, by the abort authority only (§15). Irreversible.
     * @dev This is the anti-rogue-Nihilium backstop (§7). It must work even when everything else
     * has
     *      failed, so it takes no proof, no quorum and no cooperation — one signature from a key
     * the
     *      owner keeps offline.
     */
    function abort(address account) external {
        AccountConfig storage config = _requireInstalled(account);
        if (msg.sender != config.veto.abortAuthority) revert NotAbortAuthority();
        Attempt storage attempt = _requireAttempt(account);
        config.veto.abort(attempt.veto);
        emit RecoveryAborted(account, attempt.intentHash);
    }

    /**
     * @notice EXECUTABLE -> EXECUTED: install the committed validator and bump the epoch.
     * @dev The epoch bump is what invalidates every prior-epoch intent atomically, in the same
     *      transaction as the rotation. Permissionless to submit for the same reason as
     *      `initiateRecovery`: the authority came from the signature checked at initiation, and the
     *      timelock and veto have governed everything since.
     */
    function executeRecovery(Intent calldata intent) external {
        AccountConfig storage config = _requireInstalled(intent.account);
        Attempt storage attempt = _requireAttempt(intent.account);

        // The intent must be the one this attempt was opened for, not merely a valid-looking one.
        if (hashIntent(intent) != attempt.intentHash) revert UnknownIntent();
        if (intent.epoch != config.epoch) revert WrongEpoch(config.epoch, intent.epoch);

        config.veto.execute(attempt.veto);

        config.epoch += 1;
        config.nonce += 1;

        // The only call this module can make. Shape and target are fixed here; the intent chose
        // only which validator and with what init data.
        _execute(
            intent.account,
            intent.account,
            0,
            abi.encodeCall(
                IERC7579Account.installModule,
                (MODULE_TYPE_VALIDATOR, intent.newValidator, intent.newValidatorInitData)
            )
        );

        emit RecoveryExecuted(intent.account, attempt.intentHash, config.epoch);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice The effective state right now, with the clock projected forward (auto-resume
    /// included).
    function stateOf(address account) external view returns (GradualVeto.State) {
        Attempt storage attempt = _attempts[account];
        if (attempt.veto.state == GradualVeto.State.NONE) return GradualVeto.State.NONE;
        return _configs[account].veto.project(attempt.veto).state;
    }

    function attemptOf(address account)
        external
        view
        returns (bytes32, GradualVeto.Attempt memory)
    {
        Attempt storage attempt = _attempts[account];
        return (attempt.intentHash, _configs[account].veto.project(attempt.veto));
    }

    function configOf(address account)
        external
        view
        returns (
            address recoveryOwner,
            uint256 epoch,
            uint256 nonce,
            GradualVeto.Config memory veto
        )
    {
        AccountConfig storage config = _configs[account];
        return (config.recoveryOwner, config.epoch, config.nonce, config.veto);
    }

    function hashIntent(Intent calldata intent) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.account,
                intent.epoch,
                intent.nonce,
                intent.newValidator,
                keccak256(intent.newValidatorInitData),
                intent.expiry
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @notice What a resume-quorum member signs. Bound to the attempt, so an endorsement of one
    ///         recovery cannot be replayed onto a later one.
    function resumeDigest(address account, bytes32 intentHash) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        keccak256("Resume(address account,bytes32 intentHash)"), account, intentHash
                    )
                )
            )
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("NihiliumRecoveryModule"),
                keccak256("2.0.0"),
                block.chainid,
                address(this)
            )
        );
    }

    function _requireInstalled(address account)
        internal
        view
        returns (AccountConfig storage config)
    {
        config = _configs[account];
        if (!config.installed) revert NotInstalled(account);
    }

    function _requireAttempt(address account) internal view returns (Attempt storage attempt) {
        attempt = _attempts[account];
        if (attempt.veto.state == GradualVeto.State.NONE) revert NoAttempt(account);
    }
}
