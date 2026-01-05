// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ResupplyCrvUSDFlashEnter, IResupplyPair} from "../src/targets/resupply/ResupplyCrvUSDFlashEnter.sol";
import {console} from "forge-std/console.sol";
import {ResupplyHelpers} from "./ResupplyHelpers.sol";

contract ResupplyCrvUSDFlashEnterScript is FlashAccountDeployerScript, ResupplyHelpers {
    ResupplyCrvUSDFlashEnter public targetImpl;

    function setUp() public {
        setupFlashAccount();

        // TODO: we use this pattern a lot. how do we clean it up?
        address enterAddr = config.get("resupply_crvUSD_flash_enter").toAddress();
        bytes32 expectedEnterCodeHash = keccak256(type(ResupplyCrvUSDFlashEnter).runtimeCode);
        if (enterAddr.codehash != expectedEnterCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            bytes32 salt = bytes32(0);

            vm.broadcast();
            targetImpl = new ResupplyCrvUSDFlashEnter{salt: salt}();

            config.set("resupply_crvUSD_flash_enter", address(targetImpl));
        } else {
            targetImpl = ResupplyCrvUSDFlashEnter(enterAddr);
        }
    }

    function bestRedeemMarket(IResupplyPair market, uint256 amount)
        public
        returns (IResupplyPair bestMarket, uint256 bestReturn, uint256 bestFeePct)
    {
        // TODO: include all the markets! is there an onchain registry?
        address[7] memory candidates = [
            // 0x3b037329Ff77B5863e6a3c844AD2a7506ABe5706,  // deprecated
            // 0x08064A8eEecf71203449228f3eaC65E462009fdF,  // deprecated
            0xC5184cccf85b81EDdc661330acB3E41bd89F34A1,
            0x27AB448a75d548ECfF73f8b4F36fCc9496768797,
            0x39Ea8e7f44E9303A7441b1E1a4F5731F1028505C,
            0x22B12110f1479d5D6Fd53D0dA35482371fEB3c7e,
            0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D,
            0xCF1deb0570c2f7dEe8C07A7e5FA2bd4b2B96520D,
            0x4A7c64932d1ef0b4a2d430ea10184e3B87095E33
        ];

        address user = msg.sender;

        // Query user's staked RSUP share onchain (outside loop since constant for all markets)
        uint256 userStakedRsup = GOV_STAKER.balanceOf(user);
        emit log_named_decimal_uint("userStakedRsup", userStakedRsup, 18);

        uint256 totalStakedRsup = GOV_STAKER.totalSupply();
        emit log_named_decimal_uint("totalStakedRsup", totalStakedRsup, 18);

        uint256 ltvPrecision = market.LTV_PRECISION();
        emit log_named_decimal_uint("user staking %", userStakedRsup * ltvPrecision / totalStakedRsup, 5);

        for (uint256 i; i < candidates.length; i++) {
            IResupplyPair candidate = IResupplyPair(candidates[i]);

            try REDEMPTION_HANDLER.previewRedeem(address(candidate), amount) returns (
                uint256 returnedUnderlying, uint256, uint256 feePct
            ) {
                console.log("on", address(candidate));
                emit log_named_decimal_uint("- fee %", feePct, 16);
                emit log_named_decimal_uint("- returnedUnderlying", returnedUnderlying, 18);

                // TODO: i'm not positive about this. i think we should do amount * feePct / 1e18
                uint256 grossFee = amount - returnedUnderlying;

                uint256 otherFeeCalc = amount * feePct / 1e18;
                emit log_named_decimal_uint("- otherFeeCalc %", otherFeeCalc, 16);

                // Borrower rebate (80% of fee, pro-rata by debt)
                uint256 userBorrowerRebate = 0;
                uint256 userShares = candidate.userBorrowShares(user);
                emit log_named_decimal_uint("- userShares", userShares, 18);

                if (userShares > 0) {
                    // TODO: continue here so that we don't ever redeem ourselves?

                    (, uint128 totalBorrowShares) = candidate.totalBorrow();
                    emit log_named_decimal_uint("- totalBorrowShares", totalBorrowShares, 18);

                    // TODO: log our percent ownership?

                    uint256 borrowerPool = grossFee * 80 / 100;
                    userBorrowerRebate = borrowerPool * userShares / totalBorrowShares;
                }

                // Protocol rebate (20% of fee, pro-rata by staked RSUP)
                uint256 userProtocolRebate = 0;
                if (userStakedRsup > 0 && totalStakedRsup > 0) {
                    uint256 protocolPool = grossFee * 20 / 100;
                    userProtocolRebate = protocolPool * userStakedRsup / totalStakedRsup;
                }

                uint256 effectiveReturn = returnedUnderlying + userBorrowerRebate + userProtocolRebate;

                emit log_named_decimal_uint("- userBorrowerRebate", userBorrowerRebate, 18);
                emit log_named_decimal_uint("- userProtocolRebate", userProtocolRebate, 18);
                emit log_named_decimal_uint("- effectiveReturn", effectiveReturn, 18);

                if (effectiveReturn > bestReturn) {
                    bestFeePct = feePct;
                    bestReturn = effectiveReturn;
                    bestMarket = candidate;
                }
            } catch {
                console.log("unable to redeem against", address(candidate));
            }
        }

        console.log("best redeem market:", address(bestMarket), bestMarket.name());
    }

    /// @dev Env vars:
    /// - MARKET: One of the CURVELEND markets on <https://github.com/resupplyfi/resupply/blob/main/deployment/contracts.json>
    /// - SLIPPAGE_BPS: Slippage buffer in basis points (default: 3 = 0.03%)
    /// - more to come. things are mostly hard coded right now
    ///
    /// TODO: some env vars:
    /// - ADDITIONAL_CRVUSD_BPS for adding more collateral to a pair
    /// - LEVERAGE_BPS
    /// - GOAL_HEALTH_BPS
    /// - MIN_HEALTH_BPS
    /// - MAX_FEE_PCT (1e18 scaled?)
    function run() public {
        uint256 slippageBps = vm.envOr("SLIPPAGE_BPS", uint256(3));

        // TODO: take a percentage of the crvusd
        uint256 additionalCrvUsd = CRVUSD.balanceOf(msg.sender);
        emit log_named_decimal_uint("additionalCrvUsd", additionalCrvUsd, 18);

        IResupplyPair market = IResupplyPair(vm.envAddress("MARKET"));

        // we add interest here so any calculations later are correct
        // this is NOT broadcast because this will also happen inside the actual broadcast transaction
        // TODO: i am pretty sure that interest is updated before the exchange rate. seems like thats backwards to me though
        market.addInterest(false);
        market.updateExchangeRate();

        pairInfo(market, msg.sender, "BEFORE");

        // TODO: don't hard code. these should be arguments
        // NOTE: loopMultiplier is NOT the same as what I expected as "traditional" financial leverage (total assets / equity).
        // It multiplies the "leverageable base" (borrowing headroom + new deposit) and ADDS that to existing collateral.
        // Example: 13x loopMultiplier on 4,681 base with 74,462 existing = 74,462 + (4,681 * 13) = 135,315 final collateral
        // This matches the Resupply web UI behavior. True leverage ratio will be higher than loopMultiplier.
        uint256 loopMultiplierBps = 16e4;
        emit log_named_decimal_uint("loopMultiplier", loopMultiplierBps, 4);

        // TODO: maybe we should look at how much a redemption saves us compared to

        // Safety buffer on health. 1.006e4 = 100.6% = 0.6% buffer, matches web UI behavior.
        // This reduces effective LTV from 95% to ~94.4% for headroom calculation.
        // TODO: i don't love this name. also, feels like it should just be 1e4 + this in our code
        uint256 healthBufferBps = 60;
        // uint256 healthBufferBps = 100;

        // TODO: get current borrow and collateral
        uint256 collateralShares = market.userCollateralBalance(msg.sender);

        IERC4626 collateral = IERC4626(market.collateral());

        // TODO: i'm still not convinced this is right. i feel like we should have an oracle price on this. crvUSD is often above $1
        uint256 currentCollateralValue = collateral.convertToAssets(collateralShares);
        emit log_named_decimal_uint("currentCollateralValue", currentCollateralValue, 18);

        // get existing borrows
        uint256 currentBorrowShares = market.userBorrowShares(msg.sender);

        // TODO: not sure about this rounding (which scares me some)
        // TODO: i'm still not convinced this is right. i feel like we should have an oracle price on this too. reUSD is often under $1. should we look at reUSD to crvUSD and crvUSD to USDC?
        uint256 currentBorrowAmount = market.toBorrowAmount(currentBorrowShares, true, false);
        emit log_named_decimal_uint("currentBorrowAmount", currentBorrowAmount, 18);

        // TODO: i'm still not convinced this is right. shouldn't the oracle prices be included in here?
        uint256 currentPrincipleAmount = currentCollateralValue - currentBorrowAmount;
        emit log_named_decimal_uint("currentPrincipleAmount", currentPrincipleAmount, 18);

        uint256 goalPrincipleAmount = currentPrincipleAmount + additionalCrvUsd;
        emit log_named_decimal_uint("goalPrincipleAmount", goalPrincipleAmount, 18);

        // Calculate borrowing headroom at maxLTV with safety buffer
        uint256 maxLTV = market.maxLTV();
        uint256 ltvPrecision = market.LTV_PRECISION();
        // Apply healthBufferBps buffer: effectiveLTV = maxLTV / (1e4 + healthBufferBps)
        uint256 maxSafeBorrowForCurrent = currentCollateralValue * maxLTV / ltvPrecision * 1e4 / (1e4 + healthBufferBps);

        // this is not how i did the math the first time around
        // but its how the resupply UI seems to do it. i want to be consistent with them
        uint256 headroom = maxSafeBorrowForCurrent - currentBorrowAmount;
        emit log_named_decimal_uint("headroom", headroom, 18);

        // Leverageable base = headroom + new deposit (matches web UI)
        uint256 leverageableBase = headroom + additionalCrvUsd;
        emit log_named_decimal_uint("leverageableBase", leverageableBase, 18);

        // Additional collateral = base * loopMultiplier, then add to existing
        uint256 additionalCollateral = leverageableBase * loopMultiplierBps / 1e4;
        uint256 goalLeveragedCollateral = currentCollateralValue + additionalCollateral;
        emit log_named_decimal_uint("goalLeveragedCollateral", goalLeveragedCollateral, 18);

        uint256 newCollateral = goalLeveragedCollateral - currentCollateralValue;
        emit log_named_decimal_uint("newCollateral", newCollateral, 18);

        // this is the amount we would flash if we didn't have any slippage on the trade
        uint256 flashAmount = newCollateral - additionalCrvUsd;
        emit log_named_decimal_uint("perfect flashAmount", flashAmount, 18);

        // AI REASONING: The web UI calculates newBorrow as leverageableBase * (loopMultiplier - 1).
        // This makes intuitive sense: if you're levering up by 13x, you put up 1x of your own capital
        // and borrow 12x. The total position (13x) = your capital (1x) + borrowed (12x).
        //
        // Previously we calculated maxSafeBorrow based on the goal collateral's LTV capacity, then
        // subtracted current borrow. That approach borrows MORE than needed because it calculates
        // "what CAN we borrow at the target collateral" rather than "what do we NEED to borrow
        // to achieve the target collateral."
        //
        // The (loopMultiplier - 1) approach directly answers: "how much do we need to borrow and
        // swap to collateral to achieve loopMultiplier times our leverageable base?"
        uint256 newBorrow = leverageableBase * (loopMultiplierBps - 1e4) / 1e4;
        emit log_named_decimal_uint("newBorrow", newBorrow, 18);

        // Sanity check: total borrow should stay within safe LTV bounds
        uint256 totalBorrow = currentBorrowAmount + newBorrow;
        uint256 maxSafeBorrow = goalLeveragedCollateral * maxLTV / ltvPrecision * 1e4 / (1e4 + healthBufferBps);
        emit log_named_decimal_uint("maxSafeBorrow", maxSafeBorrow, 18);
        if (totalBorrow > maxSafeBorrow) {
            revert("newBorrow would exceed maxSafeBorrow");
        }

        if (totalBorrow < 1000e18) {
            revert("borrows have to be atleast 1k reUSD");
        }

        // TODO: we could put slippage on the redeemFee instead of using minPrinciple
        (IResupplyPair redeemMarket, uint256 crvusdFromRedeem, uint256 redeemFee) = bestRedeemMarket(market, newBorrow);

        uint256 redeemCost = newBorrow - crvusdFromRedeem;
        emit log_named_decimal_uint("redeemCost", redeemCost, 18);

        uint256 expectedPrinciple = currentPrincipleAmount + additionalCrvUsd - redeemCost;
        emit log_named_decimal_uint("expectedPrinciple", expectedPrinciple, 18);

        // Apply slippage buffer to protect against execution slippage
        uint256 minPrinciple = expectedPrinciple * (1e4 - slippageBps) / 1e4;
        emit log_named_decimal_uint("minPrinciple", minPrinciple, 18);

        // we don't pass flashAmount because it's calculated based on the newBorrow. minPrinciple protects us from slippage
        bytes memory targetData =
            abi.encodeCall(targetImpl.flashLoan, (additionalCrvUsd, newBorrow, minPrinciple, market, redeemMarket));

        // TODO: What safety checks should

        vm.broadcast();
        senderFlashAccount.transientExecute(address(targetImpl), targetData);

        pairInfo(market, msg.sender, "AFTER");
    }
}
