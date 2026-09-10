// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ModeCode } from "modulekit/accounts/common/lib/ModeLib.sol";
import { ExecutionLib } from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";

/**
 * @dev A recording ERC-7579 account, only as capable as these tests need.
 *
 * Its job is to answer one question precisely: *what exactly can the recovery module make an account
 * do?* Every execution routed through it is recorded, so the confinement claim — "there is no path
 * through this module that moves a token or makes an arbitrary call" — is checked against what the
 * account was actually asked to do, rather than inferred from reading the module.
 */
contract MockERC7579Account {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    Call[] public calls;
    address[] public installedValidators;
    bytes[] public installedInitData;

    /// @dev Set to make installModule revert, to check the module surfaces a failed rotation.
    bool public installShouldRevert;

    error InstallFailed();

    function setInstallShouldRevert(bool value) external {
        installShouldRevert = value;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 index) external view returns (address, uint256, bytes memory) {
        Call storage call = calls[index];
        return (call.target, call.value, call.data);
    }

    function validatorCount() external view returns (uint256) {
        return installedValidators.length;
    }

    function executeFromExecutor(ModeCode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData)
    {
        (address target, uint256 value, bytes calldata data) =
            ExecutionLib.decodeSingle(executionCalldata);
        calls.push(Call({ target: target, value: value, data: data }));

        // Self-calls are the account acting on itself, which is how installModule arrives.
        if (target == address(this)) {
            (bool ok, bytes memory result) = address(this).call(data);
            if (!ok) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }

        returnData = new bytes[](1);
        returnData[0] = "";
    }

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external {
        if (installShouldRevert) revert InstallFailed();
        if (moduleTypeId == 1) {
            installedValidators.push(module);
            installedInitData.push(initData);
        }
    }
}
