// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MySmartAccount} from "../src/MySmartAccount.sol";

contract MySmartAccountTest is Test {
    MySmartAccount internal account;

    function setUp() public {
        account = new MySmartAccount();
    }

    function test_constructor_initializesExpectedState() public {
        revert("under construction");
    }

    function test_execute_executesCallFromAccount() public {
        revert("under construction");
    }

    function test_execute_revertsForUnauthorizedCaller() public {
        revert("under construction");
    }
}
