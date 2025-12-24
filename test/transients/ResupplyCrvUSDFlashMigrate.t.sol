// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {
    ResupplyCrvUSDFlashMigrate
} from "../../src/transients/ResupplyCrvUSDFlashMigrate.sol";
import {OnlyDelegateCall} from "../../src/abstract/OnlyDelegateCall.sol";
import {ResupplyPair} from "../../src/interfaces/ResupplyPair.sol";

contract ResupplyCrvUSDFlashMigrateTest is Test {
    ResupplyCrvUSDFlashMigrate internal migrate;

    function setUp() public {
        migrate = new ResupplyCrvUSDFlashMigrate();
    }

    function test_flashLoan_enforcesOnlyDelegateCall() public {
        vm.expectRevert(OnlyDelegateCall.NotDelegateCall.selector);
        migrate.flashLoan(ResupplyPair(address(0)), 10_000, ResupplyPair(address(0)));
    }

    function test_onFlashLoan_enforcesOnlyDelegateCall() public {
        vm.expectRevert(OnlyDelegateCall.NotDelegateCall.selector);
        migrate.onFlashLoan(address(0), address(0), 0, 0, "");
    }
}
