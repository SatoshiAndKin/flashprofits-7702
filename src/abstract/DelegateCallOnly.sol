// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

abstract contract DelegateCallOnly {
    address immutable ORIGINAL;

    error NotDelegateCall();

    constructor() {
        ORIGINAL = address(this);
    }

    modifier onlyDelegateCall() {
        require(address(this) != ORIGINAL, NotDelegateCall());
        _;
    }
}
