// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {
    ResupplyCrvUSDFlashMigrate
} from "../src/transients/ResupplyCrvUSDFlashMigrate.sol";
import {MySmartAccount} from "../src/MySmartAccount.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";

/// @notice Fork testing script for migrating between ResupplyPair markets
/// @dev Uses vm.prank to simulate execution from a specific address
contract ForkMigrateScript is Script {
    // User address to prank
    address constant USER = 0x5668EAd1eDB8E2a4d724C8fb9cB5fFEabEB422dc;

    // Source market: crvUSD/wbtc
    ResupplyPair constant SOURCE_MARKET =
        ResupplyPair(0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D);

    // Target market: crvUSD/sDOLA
    ResupplyPair constant TARGET_MARKET =
        ResupplyPair(0x27AB448a75d548ECfF73f8b4F36fCc9496768797);

    // Migration implementation (deployed by this script)
    ResupplyCrvUSDFlashMigrate public migrateImpl;

    function run() public {
        console2.log("=== Fork Migration Test ===");
        console2.log("USER:", USER);
        console2.log("SOURCE_MARKET:", address(SOURCE_MARKET));
        console2.log("TARGET_MARKET:", address(TARGET_MARKET));

        // Log initial state
        console2.log("\n--- Before Migration ---");
        logPositions();

        // Deploy the migration implementation
        migrateImpl = new ResupplyCrvUSDFlashMigrate();
        console2.log(
            "\nDeployed ResupplyCrvUSDFlashMigrate:",
            address(migrateImpl)
        );

        // Deploy MySmartAccount implementation
        MySmartAccount accountImpl = new MySmartAccount();
        console2.log("Deployed MySmartAccount:", address(accountImpl));

        // Set the user's code to the MySmartAccount implementation (simulates EIP-7702)
        // TODO: use the actual
        vm.etch(USER, address(accountImpl).code);
        console2.log("Etched MySmartAccount code to USER");

        // Build the migration calldata
        bytes memory migrateData = abi.encodeCall(
            ResupplyCrvUSDFlashMigrate.flashLoan,
            (SOURCE_MARKET, 10_000, TARGET_MARKET) // 10_000 bps = 100%
        );

        // Prank as user and execute the migration
        console2.log("\nExecuting migration via transientExecute...");
        vm.prank(USER);
        MySmartAccount(payable(USER)).transientExecute(
            address(migrateImpl),
            migrateData
        );

        // Log final state
        console2.log("\n--- After Migration ---");
        logPositions();

        console2.log("\n=== Migration Complete ===");
    }

    function logPositions() internal {
        uint256 sourceBorrowShares = SOURCE_MARKET.userBorrowShares(USER);
        uint256 sourceBorrowAmount = SOURCE_MARKET.toBorrowAmount(
            sourceBorrowShares,
            false,
            true
        );
        uint256 sourceCollateral = SOURCE_MARKET.userCollateralBalance(USER);

        uint256 targetBorrowShares = TARGET_MARKET.userBorrowShares(USER);
        uint256 targetBorrowAmount = TARGET_MARKET.toBorrowAmount(
            targetBorrowShares,
            false,
            true
        );
        uint256 targetCollateral = TARGET_MARKET.userCollateralBalance(USER);

        console2.log("SOURCE (crvUSD/wbtc):");
        console2.log("  collateral:", sourceCollateral);
        console2.log("  borrowShares:", sourceBorrowShares);
        console2.log("  borrowAmount:", sourceBorrowAmount);

        console2.log("TARGET (crvUSD/sDOLA):");
        console2.log("  collateral:", targetCollateral);
        console2.log("  borrowShares:", targetBorrowShares);
        console2.log("  borrowAmount:", targetBorrowAmount);
    }
}
