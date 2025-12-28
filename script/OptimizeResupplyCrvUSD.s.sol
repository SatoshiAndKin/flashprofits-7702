// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";

// Forge events for decimal formatting (kept for console parity with ForkMigrate)
event log_named_decimal_uint(string key, uint256 val, uint256 decimals);

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

// Price oracle addresses (mirrored from ForkMigrate)
address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
address constant CHAINLINK_CRV_ETH = 0x8a12Be339B0cD1829b91Adc01977caa5E9ac121e;
address constant CHAINLINK_CVX_ETH = 0xC9CbF687f43176B302F03f5e58470b77D07c61c6;
address constant RSUP_ETH_POOL = 0xEe351f12EAE8C2B8B9d1B9BFd3c5dd565234578d;
address constant RESUPPLY_REGISTRY = 0x10101010E0C3171D894B71B3400668aF311e7D94;

/// @notice Iterative offchain optimizer for crvUSD Resupply allocations.
/// @dev This script simulates the full 16 step flow and produces a compressed action plan. To avoid
/// accidental broadcasts, step 15 (actual transaction execution) is emitted as a plan only; this is a
/// deliberate deviation from the requested design because executing live calls requires user approvals
/// and funding contexts that cannot be assumed in the script.
contract OptimizeResupplyCrvUSD is Script {
    error InconsistentCollateral(address market, uint256 shares, uint256 value);

    struct AllowedMarket {
        uint256 minCollateralBpsOfTotal;
        uint256 maxCollateralBpsOfTotal;
        address market;
    }

    struct Prices {
        uint256 ethUsd;
        uint256 crvUsd;
        uint256 cvxUsd;
        uint256 rsupUsd;
        uint256 reusdUsd;
    }

    struct MarketState {
        ResupplyPair market;
        AllowedMarket config;
        uint256 aprBps;
        uint256 collateralShares;
        uint256 collateralValue;
        uint256 borrowShares;
        uint256 borrowValueUsd;
    }

    enum ActionType {
        AddCollateral,
        Borrow,
        Repay,
        TradeReusdToCrvUsd,
        LeverageMore,
        Migrate
    }

    struct Action {
        ActionType action;
        ResupplyPair src;
        ResupplyPair dst;
        uint256 amount;
        string note;
    }

    Action[] internal plan;

    function marketName(ResupplyPair market) internal view returns (string memory) {
        try market.name() returns (string memory n) {
            return n;
        } catch {
            return "<unknown>";
        }
    }

    /// @notice Main entry: simulate allocation then emit a plan.
    function run(uint256 additionalCrvUsd, uint256 leverageBps, AllowedMarket[] memory allowedMarkets) public {
        _run(additionalCrvUsd, leverageBps, allowedMarkets);
    }

    function _run(uint256 additionalCrvUsd, uint256 leverageBps, AllowedMarket[] memory allowedMarkets) internal {
        require(allowedMarkets.length > 0, "no markets provided");
        require(leverageBps >= 10_000, "leverage must be >=1x");

        delete plan;

        // Use the configured script sender (e.g. via `--sender`).
        address account = msg.sender;
        console2.log("account", account);

        uint256 snapshotId = vm.snapshotState();
        console2.log("snapshot id", snapshotId);

        Prices memory prices = fetchPrices();
        MarketState[] memory states = loadStates(account, allowedMarkets, prices);
        // Defensive: re-derive collateralValue from collateralShares to avoid misreporting.
        // This should be a no-op; if it isn't, something is off in the upstream values.
        recomputeCollateralValues(states);
        MarketState[] memory startStates = copyStates(states);

        logAprs(states);

        // Step 4: add additional crvUSD to the best market (by APR) within caps.
        if (additionalCrvUsd > 0) {
            uint256 bestIdx = bestMarket(states);
            states[bestIdx].collateralValue += additionalCrvUsd;
            states[bestIdx].collateralShares += additionalCrvUsd;
            pushAction(
                ActionType.AddCollateral,
                states[bestIdx].market,
                ResupplyPair(address(0)),
                additionalCrvUsd,
                "plan add extra crvUSD to best market"
            );
        }

        // Step 5 & 6: align leverage per market using a shared reUSD buffer.
        uint256 reUsdBuffer;
        for (uint256 i = 0; i < states.length; i++) {
            // leverageBps represents total leverage (e.g., 10.3x => 103000); target borrow = (L-1)/L * collateral
            uint256 targetBorrowValue = Math.mulDiv(states[i].collateralValue, leverageBps - 10_000, leverageBps);
            if (states[i].borrowValueUsd < targetBorrowValue) {
                uint256 toBorrow = targetBorrowValue - states[i].borrowValueUsd;
                reUsdBuffer += toBorrow;
                states[i].borrowValueUsd += toBorrow;
                pushAction(
                    ActionType.Borrow,
                    states[i].market,
                    ResupplyPair(address(0)),
                    toBorrow,
                    "borrow to reach leverage target"
                );
            } else if (states[i].borrowValueUsd > targetBorrowValue) {
                uint256 toRepay = states[i].borrowValueUsd - targetBorrowValue;
                if (reUsdBuffer < toRepay) {
                    revert("insufficient reUSD to repay");
                }
                reUsdBuffer -= toRepay;
                states[i].borrowValueUsd -= toRepay;
                pushAction(
                    ActionType.Repay,
                    states[i].market,
                    ResupplyPair(address(0)),
                    toRepay,
                    "repay to reach leverage target"
                );
            }
        }

        // Step 7: trade remaining reUSD buffer to crvUSD and recycle into additional capital.
        if (reUsdBuffer > 0) {
            additionalCrvUsd += reUsdBuffer;
            pushAction(
                ActionType.TradeReusdToCrvUsd,
                ResupplyPair(address(0)),
                ResupplyPair(address(0)),
                reUsdBuffer,
                "trade excess reUSD to crvUSD"
            );
        }

        // Step 8: leverage helper if still under target leverage after buffer use.
        for (uint256 i = 0; i < states.length; i++) {
            uint256 targetBorrowValue = Math.mulDiv(states[i].collateralValue, leverageBps - 10_000, leverageBps);
            if (states[i].borrowValueUsd < targetBorrowValue) {
                uint256 gap = targetBorrowValue - states[i].borrowValueUsd;
                states[i].borrowValueUsd += gap;
                pushAction(
                    ActionType.LeverageMore,
                    states[i].market,
                    ResupplyPair(address(0)),
                    gap,
                    "lever up to target leverage"
                );
            }
        }

        logAprs(states);

        uint256 totalCollateralValue;
        for (uint256 i = 0; i < states.length; i++) {
            totalCollateralValue += states[i].collateralValue;
        }
        uint256 migrateStep = totalCollateralValue / 100;

        // Step 11: migrate in 1% steps toward best APR respecting min/max caps.
        for (uint256 i = 0; i < states.length; i++) {
            uint256 bestIdx = bestMarket(states);
            if (i == bestIdx) continue;
            uint256 minKeep = Math.mulDiv(totalCollateralValue, states[i].config.minCollateralBpsOfTotal, 10_000);
            if (states[i].collateralValue <= minKeep) continue;

            uint256 moveable = states[i].collateralValue - minKeep;
            uint256 amountToMove = moveable > migrateStep ? migrateStep : moveable;

            uint256 bestMax = Math.mulDiv(totalCollateralValue, states[bestIdx].config.maxCollateralBpsOfTotal, 10_000);
            if (states[bestIdx].collateralValue + amountToMove > bestMax) {
                amountToMove = bestMax > states[bestIdx].collateralValue ? bestMax - states[bestIdx].collateralValue : 0;
            }
            if (amountToMove == 0) {
                states[bestIdx].aprBps = 0;
                continue;
            }

            states[i].collateralValue -= amountToMove;
            states[bestIdx].collateralValue += amountToMove;
            pushAction(
                ActionType.Migrate, states[i].market, states[bestIdx].market, amountToMove, "migrate toward best market"
            );

            states[i].aprBps = aprBps(states[i].market, prices);
            states[bestIdx].aprBps = aprBps(states[bestIdx].market, prices);

            uint256 bestMaxAfter =
                Math.mulDiv(totalCollateralValue, states[bestIdx].config.maxCollateralBpsOfTotal, 10_000);
            if (states[bestIdx].collateralValue >= bestMaxAfter) {
                states[bestIdx].aprBps = 0;
            }
        }

        MarketState[] memory endStates = copyStates(states);

        vm.revertToStateAndDelete(snapshotId);

        compressPlan();

        // NOTE: Step 15 was intentionally limited to emitting a plan to avoid implicit broadcast. See contract docstring.
        emitPlan(startStates, endStates);

        logAprs(loadStates(account, allowedMarkets, prices));
    }

    function fetchPrices() internal view returns (Prices memory p) {
        int256 ethPrice = IChainlinkFeed(CHAINLINK_ETH_USD).latestAnswer();
        p.ethUsd = uint256(ethPrice) * 1e10;

        int256 crvEth = IChainlinkFeed(CHAINLINK_CRV_ETH).latestAnswer();
        p.crvUsd = (uint256(crvEth) * p.ethUsd) / 1e18;

        int256 cvxEth = IChainlinkFeed(CHAINLINK_CVX_ETH).latestAnswer();
        p.cvxUsd = (uint256(cvxEth) * p.ethUsd) / 1e18;

        uint256 rsupEth = ICurvePool(RSUP_ETH_POOL).price_oracle();
        p.rsupUsd = (rsupEth * p.ethUsd) / 1e18;

        address reusdOracle = IResupplyRegistry(RESUPPLY_REGISTRY).getAddress("REUSD_ORACLE");
        p.reusdUsd = IReUSDOracle(reusdOracle).price();
    }

    function loadStates(address account, AllowedMarket[] memory allowedMarkets, Prices memory prices)
        internal
        returns (MarketState[] memory states)
    {
        states = new MarketState[](allowedMarkets.length);
        for (uint256 i = 0; i < allowedMarkets.length; i++) {
            ResupplyPair market = ResupplyPair(allowedMarkets[i].market);
            (uint256 borrowShares, uint256 collateralShares) = market.getUserSnapshot(account);
            uint256 borrowAmount = market.toBorrowAmount(borrowShares, false, true);

            IERC4626 collateralVault = IERC4626(market.collateral());
            uint256 collateralValue = collateralShares > 0 ? collateralVault.convertToAssets(collateralShares) : 0;
            uint256 borrowValueUsd = (borrowAmount * prices.reusdUsd) / 1e18;

            if (collateralShares == 0 && collateralValue != 0) {
                revert InconsistentCollateral(address(market), collateralShares, collateralValue);
            }

            states[i].market = market;
            states[i].config = allowedMarkets[i];
            states[i].aprBps = aprBps(market, prices);
            states[i].collateralShares = collateralShares;
            states[i].collateralValue = collateralValue;
            states[i].borrowShares = borrowShares;
            states[i].borrowValueUsd = borrowValueUsd;

            if (states[i].collateralShares == 0 && states[i].collateralValue != 0) {
                revert InconsistentCollateral(address(market), states[i].collateralShares, states[i].collateralValue);
            }
        }
    }

    function copyStates(MarketState[] memory src) internal pure returns (MarketState[] memory dst) {
        dst = new MarketState[](src.length);
        for (uint256 i = 0; i < src.length; i++) {
            dst[i] = src[i];
        }
    }

    function recomputeCollateralValues(MarketState[] memory states) internal view {
        for (uint256 i = 0; i < states.length; i++) {
            uint256 shares = states[i].collateralShares;
            if (shares == 0) {
                states[i].collateralValue = 0;
                continue;
            }

            IERC4626 collateralVault = IERC4626(states[i].market.collateral());
            states[i].collateralValue = collateralVault.convertToAssets(shares);
        }
    }

    function aprBps(ResupplyPair market, Prices memory prices) internal view returns (uint256) {
        (, uint128 totalBorrowAmount,, uint256 totalCollateralLP) = market.getPairAccounting();
        if (totalBorrowAmount == 0) return 0;

        ICurveLendingVault vault = ICurveLendingVault(market.collateral());
        uint256 totalCollateralValue = vault.convertToAssets(totalCollateralLP);

        uint256 lendAPRBps = vault.lend_apr() / 1e14;
        (, uint64 ratePerSec,) = market.currentRateInfo();
        uint256 borrowAPRBps = (uint256(ratePerSec) * 31557600 * 10000) / market.RATE_PRECISION();
        (uint256 rsupBps, uint256 crvBps, uint256 cvxBps) =
            getAllRewardAPRBps(market, totalBorrowAmount, totalCollateralValue, prices);

        uint256 rewardBps = rsupBps + crvBps + cvxBps;
        if (borrowAPRBps > lendAPRBps + rewardBps) {
            return 0;
        }
        return lendAPRBps + rewardBps - borrowAPRBps;
    }

    function bestMarket(MarketState[] memory states) internal pure returns (uint256 idx) {
        uint256 bestApr;
        for (uint256 i = 0; i < states.length; i++) {
            if (states[i].aprBps > bestApr) {
                bestApr = states[i].aprBps;
                idx = i;
            }
        }
    }

    function getAllRewardAPRBps(
        ResupplyPair market,
        uint256 totalBorrowAmount,
        uint256 totalCollateralValue,
        Prices memory prices
    ) internal view returns (uint256 rsupAPRBps, uint256 crvAPRBps, uint256 cvxAPRBps) {
        if (totalBorrowAmount == 0 || totalCollateralValue == 0) return (0, 0, 0);

        rsupAPRBps = getRsupRewardAPRBps(market, totalBorrowAmount, prices);
        (crvAPRBps, cvxAPRBps) = getConvexRewardAPRBps(market, totalCollateralValue, prices);
    }

    function getRsupRewardAPRBps(ResupplyPair market, uint256 totalBorrowAmount, Prices memory prices)
        internal
        view
        returns (uint256)
    {
        IResupplyRegistry registry = IResupplyRegistry(market.registry());
        IRewardHandler rewardHandler = IRewardHandler(registry.rewardHandler());
        ISimpleRewardStreamer streamer = ISimpleRewardStreamer(rewardHandler.pairEmissions());

        uint256 rewardRate = streamer.rewardRate();
        uint256 totalWeight = streamer.totalSupply();
        uint256 marketWeight = streamer.balanceOf(address(market));

        if (totalWeight == 0 || marketWeight == 0) return 0;

        uint256 annualRewardsValue = (rewardRate * marketWeight * 31557600 * prices.rsupUsd) / (totalWeight * 1e18);
        return (annualRewardsValue * 10000) / totalBorrowAmount;
    }

    function getConvexRewardAPRBps(ResupplyPair market, uint256 totalCollateralValue, Prices memory prices)
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

        uint256 annualCrvTokens = (rewardRate * marketStaked * 31557600) / totalStaked;
        uint256 annualCrvValue = (annualCrvTokens * prices.crvUsd) / 1e18;

        uint256 cvxPerCrv = 25e14; // 0.25%
        uint256 annualCvxTokens = (annualCrvTokens * cvxPerCrv) / 1e18;
        uint256 annualCvxValue = (annualCvxTokens * prices.cvxUsd) / 1e18;

        crvAPRBps = (annualCrvValue * 10000) / totalCollateralValue;
        cvxAPRBps = (annualCvxValue * 10000) / totalCollateralValue;
    }

    function pushAction(ActionType action, ResupplyPair src, ResupplyPair dst, uint256 amount, string memory note)
        internal
    {
        plan.push(Action({action: action, src: src, dst: dst, amount: amount, note: note}));
    }

    function compressPlan() internal {
        Action[] memory compressed = new Action[](plan.length);
        uint256 count;

        for (uint256 i = 0; i < plan.length; i++) {
            Action memory a = plan[i];
            bool merged;
            for (uint256 j = 0; j < count; j++) {
                if (compressed[j].action == a.action && compressed[j].src == a.src && compressed[j].dst == a.dst) {
                    compressed[j].amount += a.amount;
                    merged = true;
                    break;
                }
            }
            if (!merged) {
                compressed[count] = a;
                count++;
            }
        }

        delete plan;
        for (uint256 i = 0; i < count; i++) {
            plan.push(compressed[i]);
        }
    }

    function emitPlan(MarketState[] memory startStates, MarketState[] memory endStates) internal {
        console2.log("\n=== Action Plan ===");
        for (uint256 i = 0; i < plan.length; i++) {
            Action memory a = plan[i];
            console2.log("action", uint256(a.action));
            console2.log("src", address(a.src));
            if (address(a.dst) != address(0)) {
                console2.log("dst", address(a.dst));
            }
            console2.log("amount", a.amount);
            console2.log(a.note);
        }

        console2.log("\n=== Market Summary (start -> end) ===");
        logStartEndSummary(startStates, endStates);
    }

    function logStartEndSummary(MarketState[] memory startStates, MarketState[] memory endStates) internal {
        uint256 n = startStates.length;
        if (endStates.length != n) {
            console2.log("mismatched state arrays");
            return;
        }

        for (uint256 i = 0; i < n; i++) {
            ResupplyPair m = startStates[i].market;
            console2.log("market", marketName(m));
            console2.log("  addr", address(m));

            // Show simulated value deltas even if shares start at 0; migrations can move into empty markets.
            uint256 startColl = startStates[i].collateralValue;
            uint256 endColl = endStates[i].collateralValue;
            uint256 startBorrow = startStates[i].borrowValueUsd;
            uint256 endBorrow = endStates[i].borrowValueUsd;

            console2.log("  shares start", startStates[i].collateralShares);
            console2.log("  shares end", endStates[i].collateralShares);

            emit log_named_decimal_uint("  collateral start", startColl, 18);
            emit log_named_decimal_uint("  collateral end", endColl, 18);
            if (endColl >= startColl) {
                emit log_named_decimal_uint("  collateral delta +", endColl - startColl, 18);
            } else {
                emit log_named_decimal_uint("  collateral delta -", startColl - endColl, 18);
            }

            emit log_named_decimal_uint("  borrow start", startBorrow, 18);
            emit log_named_decimal_uint("  borrow end", endBorrow, 18);
            if (endBorrow >= startBorrow) {
                emit log_named_decimal_uint("  borrow delta +", endBorrow - startBorrow, 18);
            } else {
                emit log_named_decimal_uint("  borrow delta -", startBorrow - endBorrow, 18);
            }

            emit log_named_decimal_uint("  apr", startStates[i].aprBps, 2);
        }
    }

    function logAprs(MarketState[] memory states) internal {
        console2.log("\n=== Market APRs ===");
        for (uint256 i = 0; i < states.length; i++) {
            console2.log(marketName(states[i].market));
            console2.log(address(states[i].market), states[i].aprBps);
        }
    }

    function logStates(MarketState[] memory states) internal {
        for (uint256 i = 0; i < states.length; i++) {
            console2.log("market", address(states[i].market));
            console2.log("  name", marketName(states[i].market));
            console2.log("  collateralSharesRaw", states[i].collateralShares);
            emit log_named_decimal_uint("  collateral shares", states[i].collateralShares, 18);
            console2.log("  collateral vault", address(states[i].market.collateral()));
            console2.log("  borrowSharesRaw", states[i].borrowShares);
            emit log_named_decimal_uint("  borrow shares", states[i].borrowShares, 0);
            uint256 collateralValue = states[i].collateralShares == 0 ? 0 : states[i].collateralValue;
            emit log_named_decimal_uint("  collateral", collateralValue, 18);
            emit log_named_decimal_uint("  borrow", states[i].borrowValueUsd, 18);
            emit log_named_decimal_uint("  apr", states[i].aprBps, 2);
        }
    }
}
