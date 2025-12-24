// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {
    ResupplyCrvUSDFlashMigrate
} from "../src/transients/ResupplyCrvUSDFlashMigrate.sol";
import {FlashAccount} from "../src/MySmartAccount.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";

contract ResupplyCrvUSDFlashMigrateScript is Script {
    ResupplyCrvUSDFlashMigrate public migrate;

    function setUp() public {}

    function deploy() public {
        vm.startBroadcast();

        migrate = new ResupplyCrvUSDFlashMigrate();

        vm.stopBroadcast();
    }

    function flashLoan() public {
        address account = vm.envAddress("ACCOUNT");
        address migrateImpl = vm.envAddress("MIGRATE_IMPL");
        ResupplyPair sourceMarket = ResupplyPair(vm.envAddress("SOURCE_MARKET"));
        ResupplyPair targetMarket = ResupplyPair(vm.envAddress("TARGET_MARKET"));
        uint256 amountBps = vm.envUint("AMOUNT_BPS");

        bytes memory data = abi.encodeCall(
            ResupplyCrvUSDFlashMigrate.flashLoan,
            (sourceMarket, amountBps, targetMarket)
        );

        vm.startBroadcast();
        FlashAccount(payable(account)).transientExecute(migrateImpl, data);
        vm.stopBroadcast();
    }

    function status() public {
        address account = vm.envAddress("ACCOUNT");
        ResupplyPair sourceMarket = ResupplyPair(vm.envAddress("SOURCE_MARKET"));
        ResupplyPair targetMarket = ResupplyPair(vm.envAddress("TARGET_MARKET"));

        uint256 sourceBorrowShares = sourceMarket.userBorrowShares(account);
        uint256 sourceBorrowAmount = sourceMarket.toBorrowAmount(
            sourceBorrowShares,
            false,
            true
        );
        uint256 sourceCollateral = sourceMarket.userCollateralBalance(account);

        uint256 targetBorrowShares = targetMarket.userBorrowShares(account);
        uint256 targetBorrowAmount = targetMarket.toBorrowAmount(
            targetBorrowShares,
            false,
            true
        );
        uint256 targetCollateral = targetMarket.userCollateralBalance(account);

        console2.log("ACCOUNT", account);
        console2.log("SOURCE_MARKET", address(sourceMarket));
        console2.log("  collateral", sourceCollateral);
        console2.log("  borrowShares", sourceBorrowShares);
        console2.log("  borrowAmount", sourceBorrowAmount);
        console2.log("TARGET_MARKET", address(targetMarket));
        console2.log("  collateral", targetCollateral);
        console2.log("  borrowShares", targetBorrowShares);
        console2.log("  borrowAmount", targetBorrowAmount);
    }
}
