// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.13;

import {console} from "forge-std/Console.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IResupplyPair} from "../src/interfaces/resupply/IResupplyPair.sol";
import {ResupplyConstants} from "../src/targets/resupply/ResupplyConstants.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";

// import {IResupplyOracle} from "../src/interfaces/resupply/IResupplyOracle.sol";

// TODO: part of me wants this to be a library, but i want constants
abstract contract ResupplyHelpers is ResupplyConstants, StdAssertions {
    struct PairInfo {
        uint256 borrowAmount;
        uint256 collateralAmount;
        uint256 ltv;
        uint256 maxLTV;
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
                emit log_named_decimal_uint("- grossFee", grossFee, 18);

                // this is NOT the right way to use feePct
                // uint256 otherFeeCalc = amount * feePct / 1e18;
                // emit log_named_decimal_uint("- otherFeeCalc %", otherFeeCalc, 16);

                // Borrower rebate (80% of fee, pro-rata by debt)
                uint256 userBorrowerRebate = 0;
                uint256 userShares = candidate.userBorrowShares(user);
                emit log_named_decimal_uint("- userShares", userShares, 18);

                if (userShares > 0) {
                    // continue here so that we don't ever redeem ourselves
                    // TODO: i still can't decide if this is the best choice. but i think avoiding reducing our own income is key
                    // TODO: if we are in this pool and its the best pool, migrate out before redeeming
                    continue;

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

                // redeeming ourselves is actually a negative
                // TODO: think more about how to value the rebate? it is good to get some money back. but it hurts our income
                uint256 effectiveReturn = returnedUnderlying + userProtocolRebate + userBorrowerRebate;
                // uint256 effectiveReturn = returnedUnderlying + userProtocolRebate - userBorrowerRebate;
                // uint256 effectiveReturn = returnedUnderlying + userProtocolRebate;

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

    function pairInfo(IResupplyPair _pair, address _account, string memory label)
        internal
        returns (PairInfo memory result)
    {
        console.log("--- CHECKING ", label, "---");

        result.maxLTV = _pair.maxLTV();

        //get borrow shares/amount
        uint256 userBorrowShares = _pair.userBorrowShares(_account);
        result.borrowAmount = _pair.toBorrowAmount(userBorrowShares, true, true);

        emit log_named_decimal_uint("borrowAmount (reUSD)", result.borrowAmount, 18);

        uint256 ltvPrecision = _pair.LTV_PRECISION();

        IERC4626 collateralVault = IERC4626(_pair.collateral());

        /*
        //get collateral
        // NOTE: this is in vault shares, not underlying amount
        // result.collateralAmount = _pair.userCollateralBalance(_account);

        //get exchange rate
        uint256 exchangePrecision = _pair.EXCHANGE_PRECISION();
        // TODO: the oracle just gets the price of 1e18. i don't love that.
        (address oracle,,) = _pair.exchangeRateInfo();
        uint256 exchangeRate = IResupplyOracle(oracle).getPrices(collateralVault);
        //convert price of collateral as debt is priced in terms of collateral amount (inverse)
        exchangeRate = 1e36 / exchangeRate;
        // TODO: how should we print exchangeRate?
        emit log_named_decimal_uint("exchangeRate", exchangeRate, 18);

        result.ltv =
            ((result.borrowAmount * exchangeRate * ltvPrecision) / exchangePrecision) / result.collateralAmount;
        */

        // TODO: does oracle price just convert shares, or is there a USD conversion in here too?
        result.collateralAmount = collateralVault.convertToAssets(_pair.userCollateralBalance(_account));

        // TODO: for now its always crvUSD, but soon we will also support frxUSD
        emit log_named_decimal_uint("collateralAmount (crvUSD)", result.collateralAmount, 18);

        result.ltv = result.borrowAmount * ltvPrecision / result.collateralAmount;

        emit log_named_decimal_uint("LTV %", result.ltv, 3);
        emit log_named_decimal_uint("Max LTV %", result.maxLTV, 3);

        uint256 health = result.maxLTV * ltvPrecision / result.ltv;
        emit log_named_decimal_uint("Collateral Ratio %", health, 3);

        // how much crvUSD is needed to repay the reUSD borrow?
        // TODO: we should check both redemption and exchange paths
        // the exchange takes scrvusd, not crvusd. so we need an extra step here
        uint256 scrvUSDNeeded =
            CURVE_REUSD_SCRVUSD.get_dx(CURVE_SCRVUSD_COIN_ID, CURVE_REUSD_COIN_ID, result.borrowAmount);
        emit log_named_decimal_uint("scrvUSDNeeded to repay borrow", scrvUSDNeeded, 18);

        uint256 crvUSDNeeded = ResupplyConstants.SCRVUSD.previewRedeem(scrvUSDNeeded);
        emit log_named_decimal_uint("crvUSDNeeded to repay borrow", crvUSDNeeded, 18);

        uint256 crvUSDExit = result.collateralAmount - crvUSDNeeded;
        emit log_named_decimal_uint("estimated exit value (crvUSD)", crvUSDExit, 18);

        // TODO: now what? now we want to show the leverage?
        // TODO: i'm still not sure when to use looping and when to use leverage
        emit log_named_decimal_uint("true leverage?", result.collateralAmount * ltvPrecision / crvUSDExit, 5);

        console.log("--- END CHECKING ", label, "---");
    }

    function isSolvent(PairInfo memory x) internal pure returns (bool) {
        return x.ltv <= x.maxLTV;
    }
}
