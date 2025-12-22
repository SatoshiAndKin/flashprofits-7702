// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {
    ResupplyCrvUSDFlashMigrate
} from "../src/transients/ResupplyCrvUSDFlashMigrate.sol";

contract ResupplyCrvUSDFlashMigrateScript is Script {
    ResupplyCrvUSDFlashMigrate public migrate;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        migrate = new ResupplyCrvUSDFlashMigrate();

        vm.stopBroadcast();
    }
}
