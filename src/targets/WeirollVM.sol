// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {VM} from "weiroll-foundry/VM.sol";

contract WeirollVM is VM {
    error NotDelegateCall();

    // TODO: this delegate pattern works, but we should compare gas to doing `msg.sender == address(this)`
    address immutable ORIGINAL;

    constructor() {
        ORIGINAL = address(this);
    }

    function execute(bytes32[] memory commands, bytes[] memory state) external payable {
        if (address(this) == ORIGINAL) {
            revert NotDelegateCall();
        }

        _execute(commands, state);
    }
}
