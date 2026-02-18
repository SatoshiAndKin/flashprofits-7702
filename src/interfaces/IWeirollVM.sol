// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.4;

interface IWeirollVM {
    error ExecutionFailed(uint256 command_index, address target, string message);

    function execute(bytes32[] memory commands, bytes[] memory state) external payable returns (bytes[] memory);
}
