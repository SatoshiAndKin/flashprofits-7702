// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ResupplyCrvUSDFlashMigrate} from "../../src/transients/ResupplyCrvUSDFlashMigrate.sol";

contract ResupplyCrvUSDFlashMigrateTest is Test {
    ResupplyCrvUSDFlashMigrate internal migrate;

    function setUp() public {
        migrate = new ResupplyCrvUSDFlashMigrate();
    }

    function test_flashLoan_enforcesOnlyDelegateCall() public {
        revert("under construction");
    }

    function test_onFlashLoan_enforcesOnlyDelegateCall() public {
        revert("under construction");
    }

    function test_migrate_movesPositionFromSourceToTarget() public {
        revert("under construction");
    }
}
