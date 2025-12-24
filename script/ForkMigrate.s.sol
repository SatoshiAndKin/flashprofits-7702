// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

// Forge events for decimal formatting
event log_named_decimal_uint(string key, uint256 val, uint256 decimals);
import {ResupplyCrvUSDFlashMigrate} from "../src/transients/ResupplyCrvUSDFlashMigrate.sol";
import {FlashAccount} from "../src/MySmartAccount.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ICurveLendingVault is IERC4626 {
    function lend_apr() external view returns (uint256);
    function borrow_apr() external view returns (uint256);
}

interface IResupplyRegistry {
    function rewardHandler() external view returns (address);
    function getAddress(string memory key) external view returns (address);
}

interface IRewardHandler {
    function pairEmissions() external view returns (address);
}

interface ISimpleRewardStreamer {
    function rewardRate() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function rewardToken() external view returns (address);
}

interface IConvexBooster {
    function poolInfo(uint256 pid)
        external
        view
        returns (address lptoken, address token, address gauge, address crvRewards, address stash, bool shutdown);
}

interface IBaseRewardPool {
    function rewardRate() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 idx) external view returns (address);
}

interface IVirtualBalanceRewardPool {
    function rewardRate() external view returns (uint256);
    function rewardToken() external view returns (address);
}

interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
}

interface ICurvePool {
    function price_oracle() external view returns (uint256);
}

interface IReUSDOracle {
    function price() external view returns (uint256);
}

// Price oracle addresses
address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
address constant CHAINLINK_CRV_ETH = 0x8a12Be339B0cD1829b91Adc01977caa5E9ac121e;
address constant CHAINLINK_CVX_ETH = 0xC9CbF687f43176B302F03f5e58470b77D07c61c6;
address constant RSUP_ETH_POOL = 0xEe351f12EAE8C2B8B9d1B9BFd3c5dd565234578d;
address constant RESUPPLY_REGISTRY = 0x10101010E0C3171D894B71B3400668aF311e7D94;

/// @notice Fork testing script for migrating between ResupplyPair markets
/// @dev Uses vm.prank to simulate execution from a specific address
contract ForkMigrateScript is Script {
    // User address to prank
    address constant USER = 0x5668EAd1eDB8E2a4d724C8fb9cB5fFEabEB422dc;

    // Source markets to migrate FROM
    ResupplyPair constant SOURCE_MARKET_WBTC = ResupplyPair(0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D);
    ResupplyPair constant SOURCE_MARKET_WSTETH = ResupplyPair(0x4A7c64932d1ef0b4a2d430ea10184e3B87095E33);

    // Target market to migrate TO: crvUSD/sDOLA
    ResupplyPair constant TARGET_MARKET = ResupplyPair(0x27AB448a75d548ECfF73f8b4F36fCc9496768797);

    // Migration implementation (deployed by this script)
    ResupplyCrvUSDFlashMigrate public migrateImpl;

    // Cached prices (18 decimals, USD)
    struct Prices {
        uint256 ethUsd;
        uint256 crvUsd;
        uint256 cvxUsd;
        uint256 rsupUsd;
        uint256 reusdUsd;
    }
    Prices prices;

    /// @notice Fetches current spot prices used for APR/position reporting.
    /// @dev Reads from Chainlink and onchain oracles on a mainnet fork.
    function fetchPrices() internal {
        // ETH/USD from Chainlink (8 decimals -> 18)
        int256 ethPrice = IChainlinkFeed(CHAINLINK_ETH_USD).latestAnswer();
        prices.ethUsd = uint256(ethPrice) * 1e10;

        // CRV/ETH from Chainlink (18 decimals) -> CRV/USD
        int256 crvEth = IChainlinkFeed(CHAINLINK_CRV_ETH).latestAnswer();
        prices.crvUsd = (uint256(crvEth) * prices.ethUsd) / 1e18;

        // CVX/ETH from Chainlink (18 decimals) -> CVX/USD
        int256 cvxEth = IChainlinkFeed(CHAINLINK_CVX_ETH).latestAnswer();
        prices.cvxUsd = (uint256(cvxEth) * prices.ethUsd) / 1e18;

        // RSUP/ETH from Curve pool (18 decimals) -> RSUP/USD
        uint256 rsupEth = ICurvePool(RSUP_ETH_POOL).price_oracle();
        prices.rsupUsd = (rsupEth * prices.ethUsd) / 1e18;

        // reUSD price from Resupply oracle (18 decimals, in crvUSD terms)
        address reusdOracle = IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("REUSD_ORACLE");
        prices.reusdUsd = IReUSDOracle(reusdOracle).price();

        // Log prices
        console2.log("=== Prices ===");
        emit log_named_decimal_uint("ETH/USD", prices.ethUsd, 18);
        emit log_named_decimal_uint("CRV/USD", prices.crvUsd, 18);
        emit log_named_decimal_uint("CVX/USD", prices.cvxUsd, 18);
        emit log_named_decimal_uint("RSUP/USD", prices.rsupUsd, 18);
        emit log_named_decimal_uint("reUSD/USD", prices.reusdUsd, 18);
    }

    /// @notice Runs a full forked migration demo for `USER`.
    /// @dev This script pranks `USER`, deploys fresh implementations, etches FlashAccount bytecode onto
    /// USER (to simulate EIP-7702), then executes migrations and logs before/after positions.
    function run() public {
        console2.log("=== Fork Migration Test ===");
        console2.log("USER:", USER);
        console2.log("SOURCE_MARKET_WBTC:", address(SOURCE_MARKET_WBTC));
        console2.log("SOURCE_MARKET_WSTETH:", address(SOURCE_MARKET_WSTETH));
        console2.log("TARGET_MARKET:", address(TARGET_MARKET));

        // Fetch current prices
        fetchPrices();

        // Log initial state
        console2.log("\n--- Before Migration ---");
        logPositions();

        // Deploy the migration implementation
        migrateImpl = new ResupplyCrvUSDFlashMigrate();
        console2.log("\nDeployed ResupplyCrvUSDFlashMigrate:", address(migrateImpl));

        // Deploy FlashAccount implementation
        FlashAccount accountImpl = new FlashAccount();
        console2.log("Deployed FlashAccount:", address(accountImpl));

        // Set the user's code to the FlashAccount implementation (simulates EIP-7702)
        vm.etch(USER, address(accountImpl).code);
        console2.log("Etched FlashAccount code to USER");

        // Migrate from WBTC market to sDOLA
        console2.log("\n--- Migrating WBTC market -> sDOLA ---");
        executeMigration(SOURCE_MARKET_WBTC, TARGET_MARKET);

        // Migrate from WSTETH market to sDOLA
        console2.log("\n--- Migrating WSTETH market -> sDOLA ---");
        executeMigration(SOURCE_MARKET_WSTETH, TARGET_MARKET);

        // Log final state
        console2.log("\n--- After Migration ---");
        logPositions();

        console2.log("\n=== Migration Complete ===");
    }

    /// @notice Executes a single migration from `source` to `target` for `USER` if a position exists.
    /// @dev Uses FlashAccount.transientExecute to run the migration implementation.
    function executeMigration(ResupplyPair source, ResupplyPair target) internal {
        // Check if user has position in source market
        uint256 borrowShares = source.userBorrowShares(USER);
        if (borrowShares == 0) {
            console2.log("No position in source market, skipping");
            return;
        }

        bytes memory migrateData = abi.encodeCall(
            ResupplyCrvUSDFlashMigrate.flashLoan,
            (source, 10_000, target) // 10_000 bps = 100%
        );

        uint256 gasBefore = gasleft();
        vm.prank(USER);
        FlashAccount(payable(USER)).transientExecute(address(migrateImpl), migrateData);
        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used:", gasUsed);
    }

    /// @notice Logs positions for source/target markets for `USER`.
    function logPositions() internal {
        logMarketPosition("SOURCE (crvUSD/wbtc)", SOURCE_MARKET_WBTC);
        logMarketPosition("SOURCE (crvUSD/wstETH)", SOURCE_MARKET_WSTETH);
        logMarketPosition("TARGET (crvUSD/sDOLA)", TARGET_MARKET);
    }

    /// @notice Logs collateral, borrow, reward APRs and derived net APR for `USER` in a given market.
    /// @dev This is view-ish, but uses console logs and emits to format output.
    function logMarketPosition(string memory name, ResupplyPair market) internal {
        console2.log(name);

        uint256 borrowShares = market.userBorrowShares(USER);
        uint256 borrowAmount = market.toBorrowAmount(borrowShares, false, true);
        uint256 collateral = market.userCollateralBalance(USER);

        ICurveLendingVault collateralVault = ICurveLendingVault(market.collateral());
        uint256 collateralValue = collateral > 0 ? collateralVault.convertToAssets(collateral) : 0;

        // Convert borrow to USD value using reUSD price
        uint256 borrowValueUsd = (borrowAmount * prices.reusdUsd) / 1e18;

        emit log_named_decimal_uint("  collateral (crvUSD)", collateralValue, 18);
        emit log_named_decimal_uint("  borrow (reUSD)", borrowAmount, 18);
        emit log_named_decimal_uint("  borrow value (USD)", borrowValueUsd, 18);

        // Get APRs (in bps, show as % with 2 decimals)
        uint256 lendAPRBps = collateralVault.lend_apr() / 1e14;
        (, uint64 ratePerSec,) = market.currentRateInfo();
        uint256 borrowAPRBps = (uint256(ratePerSec) * 31557600 * 10000) / market.RATE_PRECISION();
        (uint256 rsupBps, uint256 crvBps, uint256 cvxBps) = getAllRewardAPRBps(market);

        emit log_named_decimal_uint("  lend APR %", lendAPRBps, 2);
        emit log_named_decimal_uint("  borrow APR %", borrowAPRBps, 2);
        emit log_named_decimal_uint("  RSUP reward %", rsupBps, 2);
        emit log_named_decimal_uint("  CRV reward %", crvBps, 2);
        emit log_named_decimal_uint("  CVX reward %", cvxBps, 2);
        emit log_named_decimal_uint("  total reward %", rsupBps + crvBps + cvxBps, 2);

        // Calculate net APR on equity (using USD values)
        if (collateralValue > borrowValueUsd && borrowAmount > 0) {
            // Equity in USD = collateral (crvUSD ~ $1) - borrow value in USD
            uint256 equityUsd = collateralValue - borrowValueUsd;
            uint256 totalRewardBps = rsupBps + crvBps + cvxBps;

            // Income is on collateral (crvUSD), cost is on borrow (reUSD converted to USD)
            uint256 annualLend = (collateralValue * lendAPRBps) / 10000;
            uint256 annualReward = (borrowValueUsd * totalRewardBps) / 10000;
            uint256 annualCost = (borrowValueUsd * borrowAPRBps) / 10000;
            uint256 totalIncome = annualLend + annualReward;

            emit log_named_decimal_uint("  equity (USD)", equityUsd, 18);
            emit log_named_decimal_uint("  annual income", totalIncome, 18);
            emit log_named_decimal_uint("  annual cost", annualCost, 18);

            if (totalIncome >= annualCost) {
                uint256 netAPR = ((totalIncome - annualCost) * 10000) / equityUsd;
                emit log_named_decimal_uint("  NET APR on equity %", netAPR, 2);
            } else {
                uint256 netAPR = ((annualCost - totalIncome) * 10000) / equityUsd;
                emit log_named_decimal_uint("  NET APR on equity % (LOSS)", netAPR, 2);
            }

            // Health - LTV using USD values
            uint256 currentLTV = (borrowValueUsd * market.LTV_PRECISION()) / collateralValue;
            uint256 maxLTV = market.maxLTV();
            emit log_named_decimal_uint("  current LTV %", currentLTV, 3);
            emit log_named_decimal_uint("  max LTV %", maxLTV, 3);
        }
    }

    /// @notice Computes reward APRs (RSUP, CRV, CVX) for a market in basis points.
    /// @dev This is a rough approximation for reporting purposes.
    function getAllRewardAPRBps(ResupplyPair market)
        internal
        view
        returns (uint256 rsupAPRBps, uint256 crvAPRBps, uint256 cvxAPRBps)
    {
        // Get market totals
        (, uint128 totalBorrowAmount,, uint256 totalCollateralLP) = market.getPairAccounting();
        if (totalBorrowAmount == 0) return (0, 0, 0);

        // Convert collateral LP to crvUSD value
        ICurveLendingVault vault = ICurveLendingVault(market.collateral());
        uint256 totalCollateralValue = vault.convertToAssets(totalCollateralLP);

        // 1. RSUP rewards based on borrow (distributed by borrow weight)
        rsupAPRBps = getRsupRewardAPRBps(market, totalBorrowAmount);

        // 2. CRV + CVX rewards based on collateral (staked in Convex)
        (crvAPRBps, cvxAPRBps) = getConvexRewardAPRBps(market, totalCollateralValue);
    }

    /// @notice Computes RSUP reward APR (bps) based on borrow-weighted emissions.
    function getRsupRewardAPRBps(ResupplyPair market, uint256 totalBorrowAmount) internal view returns (uint256) {
        IResupplyRegistry registry = IResupplyRegistry(market.registry());
        IRewardHandler rewardHandler = IRewardHandler(registry.rewardHandler());
        ISimpleRewardStreamer streamer = ISimpleRewardStreamer(rewardHandler.pairEmissions());

        uint256 rewardRate = streamer.rewardRate();
        uint256 totalWeight = streamer.totalSupply();
        uint256 marketWeight = streamer.balanceOf(address(market));

        if (totalWeight == 0 || marketWeight == 0) return 0;

        // Annual RSUP value = rewardRate * marketShare * secondsPerYear * rsupPrice
        uint256 annualRewardsValue = (rewardRate * marketWeight * 31557600 * prices.rsupUsd) / (totalWeight * 1e18);

        return (annualRewardsValue * 10000) / totalBorrowAmount;
    }

    /// @notice Computes CRV and CVX reward APRs (bps) for collateral staked on Convex.
    function getConvexRewardAPRBps(ResupplyPair market, uint256 totalCollateralValue)
        internal
        view
        returns (uint256 crvAPRBps, uint256 cvxAPRBps)
    {
        uint256 pid = market.convexPid();
        if (pid == 0 || totalCollateralValue == 0) return (0, 0);

        IConvexBooster booster = IConvexBooster(market.convexBooster());
        (,,, address crvRewardsAddr,,) = booster.poolInfo(pid);
        IBaseRewardPool crvRewards = IBaseRewardPool(crvRewardsAddr);

        uint256 rewardRate = crvRewards.rewardRate();
        uint256 totalStaked = crvRewards.totalSupply();
        uint256 marketStaked = crvRewards.balanceOf(address(market));

        if (totalStaked == 0 || marketStaked == 0) return (0, 0);

        // Market's share of CRV rewards per year
        uint256 annualCrvTokens = (rewardRate * marketStaked * 31557600) / totalStaked;
        uint256 annualCrvValue = (annualCrvTokens * prices.crvUsd) / 1e18;

        // CVX minted proportional to CRV (diminishing, ~0.15% at current supply)
        uint256 cvxPerCrv = 25e14; // 0.0025e18 = 0.25%
        uint256 annualCvxTokens = (annualCrvTokens * cvxPerCrv) / 1e18;
        uint256 annualCvxValue = (annualCvxTokens * prices.cvxUsd) / 1e18;

        // APR on collateral value (CRV/CVX rewards are earned on staked collateral)
        crvAPRBps = (annualCrvValue * 10000) / totalCollateralValue;
        cvxAPRBps = (annualCvxValue * 10000) / totalCollateralValue;
    }
}
