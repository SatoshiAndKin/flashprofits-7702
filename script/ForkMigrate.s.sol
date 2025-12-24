// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {
    ResupplyCrvUSDFlashMigrate
} from "../src/transients/ResupplyCrvUSDFlashMigrate.sol";
import {MySmartAccount} from "../src/MySmartAccount.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICurveLendingVault is IERC4626 {
    function lend_apr() external view returns (uint256);
    function borrow_apr() external view returns (uint256);
}

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
        uint256 gasBefore = gasleft();
        vm.prank(USER);
        MySmartAccount(payable(USER)).transientExecute(
            address(migrateImpl),
            migrateData
        );
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used:", gasUsed);

        // Log final state
        console2.log("\n--- After Migration ---");
        logPositions();

        console2.log("\n=== Migration Complete ===");
    }

    function logPositions() internal {
        logMarketPosition("SOURCE (crvUSD/wbtc)", SOURCE_MARKET);
        logMarketPosition("TARGET (crvUSD/sDOLA)", TARGET_MARKET);
    }

    function logMarketPosition(string memory name, ResupplyPair market) internal {
        uint256 borrowShares = market.userBorrowShares(USER);
        uint256 borrowAmount = market.toBorrowAmount(borrowShares, false, true);
        uint256 collateral = market.userCollateralBalance(USER);

        // Collateral is a Curve lending vault (ERC4626 with lend_apr)
        ICurveLendingVault collateralVault = ICurveLendingVault(market.collateral());
        uint256 collateralValueCrvUSD = collateral > 0 
            ? collateralVault.convertToAssets(collateral)
            : 0;

        // Get lending APR from vault (1e18 based, convert to bps)
        uint256 lendAPR = collateralVault.lend_apr();
        uint256 lendAPRBps = lendAPR / 1e14; // 1e18 -> bps (divide by 1e14)

        // Get borrow rate: ratePerSec from currentRateInfo
        (, uint64 ratePerSec, ) = market.currentRateInfo();
        uint256 ratePrecision = market.RATE_PRECISION();
        // APR (in basis points) = ratePerSec * seconds_per_year * 10000 / ratePrecision
        // seconds_per_year = 365.25 * 24 * 60 * 60 = 31557600
        uint256 borrowAPRBps = (uint256(ratePerSec) * 31557600 * 10000) / ratePrecision;

        console2.log(name);
        console2.log("  collateral (LP shares):", collateral);
        console2.log("  collateral (crvUSD):", collateralValueCrvUSD);
        console2.log("  borrowShares:", borrowShares);
        console2.log("  borrowAmount (reUSD):", borrowAmount);
        console2.log("  lend APR bps:", lendAPRBps);
        console2.log("  borrow APR bps:", borrowAPRBps);

        // Calculate net APR (lend yield - borrow cost)
        if (collateralValueCrvUSD > 0 && borrowAmount > 0) {
            // Annual lend income = collateralValueCrvUSD * lendAPRBps / 10000
            uint256 annualLendIncome = (collateralValueCrvUSD * lendAPRBps) / 10000;
            // Annual borrow cost = borrowAmount * borrowAPRBps / 10000
            uint256 annualBorrowCost = (borrowAmount * borrowAPRBps) / 10000;
            
            console2.log("  annual lend income:", annualLendIncome);
            console2.log("  annual borrow cost:", annualBorrowCost);
            
            // Net APR on collateral = (lendIncome - borrowCost) / collateralValue * 10000
            if (annualLendIncome > annualBorrowCost) {
                uint256 netProfitBps = ((annualLendIncome - annualBorrowCost) * 10000) / collateralValueCrvUSD;
                console2.log("  NET APR bps (profit):", netProfitBps);
            } else {
                uint256 netLossBps = ((annualBorrowCost - annualLendIncome) * 10000) / collateralValueCrvUSD;
                console2.log("  NET APR bps (LOSS):", netLossBps);
            }
        }

        // Calculate health (LTV vs maxLTV)
        if (collateral > 0 && borrowAmount > 0) {
            uint256 ltvPrecision = market.LTV_PRECISION();
            uint256 maxLTV = market.maxLTV();

            // currentLTV = borrowAmount * ltvPrecision / collateralValue
            uint256 currentLTV = (borrowAmount * ltvPrecision) / collateralValueCrvUSD;
            // health = maxLTV * 100 / currentLTV (as percentage, 100 = at max, >100 = healthy)
            uint256 healthPct = (maxLTV * 100) / currentLTV;

            console2.log("  currentLTV:", currentLTV);
            console2.log("  maxLTV:", maxLTV);
            console2.log("  health %:", healthPct);
        }
    }
}
