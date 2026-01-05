// SPDX-License-Identifier: UNLICENSED
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
