// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {DelegateOnly} from "../abstract/DelegateOnly.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {CurvePoolYfiUpyfi} from "../interfaces/CurvePoolYfiUpyfi.sol";

/// @title Constants for UpYfiBuyTarget
abstract contract BuyDiscountedUpYfiConstants {
    IERC20 internal constant UPYFI = IERC20(0x95710BDE45C8D384A976Cc58Cc7a7e489576b098);
    IERC20 internal constant YFI = IERC20(0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e);
    CurvePoolYfiUpyfi internal constant CURVE_POOL_YFI_UPYFI =
        CurvePoolYfiUpyfi(0x13120b7599DdF33782c748A847cc1d3c96387Ecd);

    /// @dev Pool indices
    int128 internal constant YFI_INDEX = 0;
    int128 internal constant UPYFI_INDEX = 1;

    /// @dev upYFI wraps YFI at 1:69,420 ratio
    uint256 internal constant UPYFI_TO_YFI_RATIO = 69_420;
}

/// @title Helper contract for trading discounted upYFI
/// @dev Deploy this on a fork network or using state overrides
contract BuyDiscountedUpYfiHelper is BuyDiscountedUpYfiConstants {
    /// @notice Check if upYFI is trading at a discount. If so, return calldata to trade it
    /// @param slippage_bps Slippage tolerance in basis points (e.g., 50 = 0.5%)
    /// @param yfi_amount Amount of YFI to check the exchange rate for
    /// @return to Target address for the transaction
    /// @return data Calldata for the transaction
    function poll(uint256 yfi_amount, uint256 slippage_bps) external view returns (address to, bytes memory data) {
        if (yfi_amount == 0) {
            yfi_amount = YFI.balanceOf(msg.sender);
        }

        // TODO: what minimum trade amount?
        require(yfi_amount > 0, "no YFI");

        // Calculate expected upYFI output from Curve
        uint256 expected_upyfi = CurvePoolYfiUpyfi(CURVE_POOL_YFI_UPYFI).get_dy(YFI_INDEX, UPYFI_INDEX, yfi_amount);

        // Calculate minimum output with slippage
        uint256 min_upyfi_out = Math.mulDiv(expected_upyfi, 10000 - slippage_bps, 10000);

        // Calculate theoretical upYFI amount based on 1:69,420 ratio
        // TODO: better name for this variable. this is the deposit/redemption_rate
        uint256 theoretical_upyfi = yfi_amount * UPYFI_TO_YFI_RATIO;

        // upYFI is discounted if we get MORE upYFI than the theoretical ratio
        // TODO: have a minimum_discount_bps
        require(min_upyfi_out > theoretical_upyfi, "no discount");

        // Calculate discount percentage in basis points
        // discount = ((expected - theoretical) / theoretical) * 10000
        uint256 discount_percent_bps = Math.mulDiv(expected_upyfi - theoretical_upyfi, 10000, theoretical_upyfi);
        console.log("discount_percent_bps:", discount_percent_bps);

        // TODO: pause for a user confirmation here?

        // TODO: some cool 7702 thing maybe makes sense here, but EOAs are simpler for now. lets get some scripts working before we worry about optimizing for my old address with veCRV
        uint256 allowance = YFI.allowance(msg.sender, address(CURVE_POOL_YFI_UPYFI));
        if (allowance < yfi_amount) {
            to = address(YFI);
            data = abi.encodeCall(IERC20.approve, (address(CURVE_POOL_YFI_UPYFI), type(uint256).max));
        } else {
            to = address(CURVE_POOL_YFI_UPYFI);
            // NOTE: Cannot use abi.encodeCall here because exchange() is overloaded
            data = abi.encodeWithSignature(
                "exchange(int128,int128,uint256,uint256)", YFI_INDEX, UPYFI_INDEX, yfi_amount, min_upyfi_out
            );
        }
    }
}

/// @title dummy contract. All the real logic is in BuyDiscountedUpYfiHelper and the accompanying script
contract BuyDiscountedUpYfiTarget {
    constructor() {
        revert("not needed. everything is in the off-chain helper and polling script!");
    }
}