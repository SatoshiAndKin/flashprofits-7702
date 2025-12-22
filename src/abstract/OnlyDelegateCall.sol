// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

abstract contract OnlyDelegateCall {
    address immutable ORIGINAL;

    error NotDelegateCall();

    constructor() {
        ORIGINAL = address(this);
    }

    modifier onlyDelegateCall() {
        _onlyDelegateCall();
        _;
    }

    function _onlyDelegateCall() private view {
        require(address(this) != ORIGINAL, NotDelegateCall());
    }
}
