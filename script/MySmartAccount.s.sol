// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MySmartAccount} from "../src/MySmartAccount.sol";

contract MySmartAccountScript is Script {
    MySmartAccount public account;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        account = new MySmartAccount();

        vm.stopBroadcast();
    }
}
