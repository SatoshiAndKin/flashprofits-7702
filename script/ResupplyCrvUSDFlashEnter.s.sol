// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ResupplyCrvUSDFlashEnter, ResupplyConstants, IResupplyPair} from "../src/targets/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";
import {console} from "forge-std/console.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";

contract ResupplyCrvUSDFlashEnterScript is FlashAccountDeployerScript, ResupplyConstants, StdAssertions {
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

    function bestRedeemMarket(IResupplyPair market, uint256 amount) public view returns (IResupplyPair bestMarket) {
        bestMarket = market;
        uint256 bestReturn;

        // TODO: include all the markets! is there an onchain registry?
        address[3] memory candidates = [
            0xC5184cccf85b81EDdc661330acB3E41bd89F34A1,
            0x27AB448a75d548ECfF73f8b4F36fCc9496768797,
            0x39Ea8e7f44E9303A7441b1E1a4F5731F1028505C
            // 0x3b037329Ff77B5863e6a3c844AD2a7506ABe5706,  // deprecated
            // 0x08064A8eEecf71203449228f3eaC65E462009fdF,  // deprecated
            // comment the rest out just to make dev faster. REMOVE BEFORE FLIGHT!
            // 0x22B12110f1479d5D6Fd53D0dA35482371fEB3c7e,
            // 0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D,
            // 0xCF1deb0570c2f7dEe8C07A7e5FA2bd4b2B96520D,
            // 0x4A7c64932d1ef0b4a2d430ea10184e3B87095E33
        ];

        for (uint256 i; i < candidates.length; i++) {
            address candidate = candidates[i];

            try REDEMPTION_HANDLER.previewRedeem(candidate, amount) returns (
                uint256 returnedUnderlying, uint256, uint256 fee
            ) {
                console.log("on", candidate);
                console.log("- fee", fee);
                console.log("- returnedUnderlying", returnedUnderlying);

                if (returnedUnderlying > bestReturn) {
                    bestReturn = returnedUnderlying;
                    bestMarket = IResupplyPair(candidate);
                }
            } catch {
                console.log("unable to redeem against", candidate);
            }
        }

        console.log("best market:", address(bestMarket));
    }

    /// @dev Env vars:
    /// - MARKET: One of the CURVELEND markets on <https://github.com/resupplyfi/resupply/blob/main/deployment/contracts.json>
    /// - more to come. things are mostly hard coded right now
    ///
    /// TODO: some env vars:
    /// - ADDITIONAL_CRVUSD_BPS for adding more collateral to a pair
    /// - LEVERAGE_BPS
    /// - GOAL_HEALTH_BPS
    /// - MIN_HEALTH_BPS
    /// - MAX_FEE_PCT (1e18 scaled?)
    function run() public {
        // TODO: take a percentage? a total?
        uint256 additionalCrvUsd = CRVUSD.balanceOf(msg.sender);
        emit log_named_decimal_uint("additionalCrvUsd", additionalCrvUsd, 18);

        IResupplyPair market = IResupplyPair(vm.envAddress("MARKET"));

        // TODO: don't hard code. these should be arguments
        // TODO: i feel like leverage and health are more related than I think. we want the max leverage that
        // TODO: i think we always want max leverage because it keeps being positive to borrow. but i think we need something smartr on this. calculate the maximum possible borrow
        uint256 leverageBps = 13e4;
        // TODO: this goal healh is getting essentially overwritten by the slippage on redemption. need to think about this more
        // TODO: we are ending up at 1.0199e4. thats slipping more than i expected
        uint256 goalHealthBps = 1.03e4;
        // TODO: this should probably have tighter slippage protection!
        uint256 minHealthBps = 1.01e4;

        // TODO: what are the units on this? i think 1e18 == 100%
        // TODO: i think we should do our own checks somewhere else. but maybe using this is a good idea. get the expected feePct when finding the best market. use it as slippage
        uint256 maxFeePct = 0.01e18;

        // TODO: get current borrow and collateral
        uint256 collateralShares = market.userCollateralBalance(msg.sender);

        IERC4626 collateral = IERC4626(market.collateral());

        uint256 currentCollateralValue = collateral.convertToAssets(collateralShares);
        emit log_named_decimal_uint("currentCollateralValue", currentCollateralValue, 18);

        // get existing borrows
        uint256 currentBorrowShares = market.userBorrowShares(msg.sender);

        // TODO: not sure about this rounding (which scares me some)
        uint256 currentBorrowAmount = market.toBorrowAmount(currentBorrowShares, true, false);
        emit log_named_decimal_uint("currentBorrowAmount", currentBorrowAmount, 18);

        // TODO: log leverage level. how can we find the maximum possible?
        uint256 currentPrincipleAmount = currentCollateralValue - currentBorrowAmount;
        emit log_named_decimal_uint("currentPrincipleAmount", currentPrincipleAmount, 18);

        uint256 goalPrincipleAmount = currentPrincipleAmount + additionalCrvUsd;
        emit log_named_decimal_uint("goalPrincipleAmount", goalPrincipleAmount, 18);

        // depending on slippage, we might not be able to get to this level
        // TODO: should we include the redemption price here maybe? instead of further down?
        uint256 goalLeveragedCollateral = goalPrincipleAmount * leverageBps / 1e4;
        emit log_named_decimal_uint("goalLeveragedCollateral", goalLeveragedCollateral, 18);

        uint256 newCollateral = goalLeveragedCollateral - currentCollateralValue;
        emit log_named_decimal_uint("newCollateral", newCollateral, 18);

        uint256 flashAmount = newCollateral - additionalCrvUsd;
        emit log_named_decimal_uint("flashAmount", flashAmount, 18);

        uint256 maxSafeBorrow = goalLeveragedCollateral * market.maxLTV() / market.LTV_PRECISION() * 1e4 / minHealthBps;
        emit log_named_decimal_uint("maxSafeBorrow", maxSafeBorrow, 18);

        if (maxSafeBorrow < 1000e18) {
            revert("borrows have to be atleast 1k reUSD");
        }

        // TODO: is maxSafeBorrow the right value here?
        // TODO: i think this needs to include the redemption price for slippage too! but i don't know. feels weird
        // TODO: without doing a lot of queries, i'm not sure how to find the perfect amount of newBorrow that will give us flashAmount
        uint256 newBorrow = maxSafeBorrow - currentBorrowAmount * 1e4 / 9900;
        emit log_named_decimal_uint("newBorrow", newBorrow, 18);

        IResupplyPair redeemMarket = bestRedeemMarket(market, newBorrow);

        // .03% slippage. we should take this as an agument. its stables, so it should be low!
        uint256 minPrinciple = goalPrincipleAmount * 9997 / 1e4;
        emit log_named_decimal_uint("minPrinciple", minPrinciple, 18);

        // TODO: refactor the flash loan target to take these args. these keeps more calculations on chain
        // TODO: should we pass minFlashAmount or minPrinciple?
        // we don't pass flashAmount because it's calculated based on the newBorrow
        bytes memory targetData =
            abi.encodeCall(targetImpl.flashLoan, (additionalCrvUsd, newBorrow, minPrinciple, market, redeemMarket));

        vm.broadcast();
        senderFlashAccount.transientExecute(address(targetImpl), targetData);

        // TODO: print stats about the market
    }
}
