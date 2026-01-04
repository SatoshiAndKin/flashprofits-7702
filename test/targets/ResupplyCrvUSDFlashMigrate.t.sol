// SPDX-License-Identifier: UNLICENSED
//
// Larger tests are in fork.t.sol
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ResupplyCrvUSDFlashMigrate} from "../../src/targets/resupply/ResupplyCrvUSDFlashMigrate.sol";
import {IResupplyPair} from "../../src/interfaces/resupply/IResupplyPair.sol";

contract ResupplyCrvUSDFlashMigrateTest is Test {
    ResupplyCrvUSDFlashMigrate internal migrate;

    function setUp() public {
        migrate = new ResupplyCrvUSDFlashMigrate();
    }

    function test_deploy() public {
        bytes32 salt = bytes32(0);

        new ResupplyCrvUSDFlashMigrate{salt: salt}();
    }

    function test_flashLoan_enforcesOnlyDelegateCall() public {
        vm.expectRevert(ResupplyCrvUSDFlashMigrate.Unauthorized.selector);
        migrate.flashLoan(IResupplyPair(address(0)), 10_000, IResupplyPair(address(0)));
    }

    // @dev Without the delegatecall-only gate, direct calls should fail because no flash loan is in progress.
    function test_onFlashLoan_noLongerEnforcesOnlyDelegateCall() public {
        vm.expectRevert(ResupplyCrvUSDFlashMigrate.UnauthorizedFlashLoanCallback.selector);
        migrate.onFlashLoan(address(0), address(0), 0, 0, "");
    }
}
