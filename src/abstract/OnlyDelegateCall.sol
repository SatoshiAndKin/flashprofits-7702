// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

abstract contract OnlyDelegateCall {
    address immutable ORIGINAL;

    error NotDelegateCall();

    /// @notice Captures the original deployment address.
    /// @dev When this code is executed via `delegatecall`, `address(this)` will differ from ORIGINAL.
    constructor() {
        ORIGINAL = address(this);
    }

    /// @notice Restricts execution to contexts where this code is running via `delegatecall`.
    /// @dev Reverts with {NotDelegateCall} when called directly on the deployed implementation.
    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall() private view {
        if (address(this) == ORIGINAL) revert NotDelegateCall();
    }
}
