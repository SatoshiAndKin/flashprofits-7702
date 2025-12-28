// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {OnlyDelegateCall} from "../abstract/OnlyDelegateCall.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ResupplyPair} from "../interfaces/ResupplyPair.sol";
import {RedemptionHandler} from "../interfaces/RedemptionHandler.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract ResupplyCrvUSDFlashEnter is OnlyDelegateCall, IERC3156FlashBorrower {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER = IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);
    RedemptionHandler constant REDEMPTION_HANDLER = RedemptionHandler(0x99999999A5Dc4695EF303C9EA9e4B3A19367Ed94);

    error Unauthorized();
    error UnexpectedUnderlying();
    error FlashLoanFailed();
    error AlreadyInFlashLoan();
    error AlreadyInOnFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedLender();
    error SlippageTooHigh();

    bytes32 internal constant _IN_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashEnter.in_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashEnter.in_on_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        ResupplyPair market;
        address curvePool;
        int128 curveI;
        int128 curveJ;
        uint256 flashAmount;
        uint256 maxFeePct;
        uint256 minReusdOut;
        uint256 minCrvUsdRedeemed;
    }

    /// @notice Enter a position by flash loaning crvUSD, swapping to reUSD on Curve, redeeming to crvUSD, and depositing.
    /// @dev Intended for FlashAccount.transientExecute (delegatecall).
    function flashLoan(
        ResupplyPair market,
        address curvePool,
        int128 curveI,
        int128 curveJ,
        uint256 flashAmount,
        uint256 maxFeePct,
        uint256 minReusdOut,
        uint256 minCrvUsdRedeemed
    ) external onlyDelegateCall {
        TransientSlot.BooleanSlot in_flashloan = _IN_FLASHLOAN_SLOT.asBoolean();
        if (in_flashloan.tload()) revert AlreadyInFlashLoan();
        in_flashloan.tstore(true);

        address self = address(this);
        if (msg.sender != self) revert Unauthorized();

        if (market.underlying() != address(CRVUSD)) revert UnexpectedUnderlying();

        bytes memory data = abi.encode(
            CallbackData({
                market: market,
                curvePool: curvePool,
                curveI: curveI,
                curveJ: curveJ,
                flashAmount: flashAmount,
                maxFeePct: maxFeePct,
                minReusdOut: minReusdOut,
                minCrvUsdRedeemed: minCrvUsdRedeemed
            })
        );

        if (!CRVUSD_FLASH_LENDER.flashLoan(IERC3156FlashBorrower(self), address(CRVUSD), flashAmount, data)) {
            revert FlashLoanFailed();
        }

        in_flashloan.tstore(false);
    }

    bytes32 internal constant ERC3156_FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function onFlashLoan(address, address, uint256 amount, uint256, bytes calldata data) external returns (bytes32) {
        if (!_IN_FLASHLOAN_SLOT.asBoolean().tload()) revert UnauthorizedFlashLoanCallback();
        if (msg.sender != address(CRVUSD_FLASH_LENDER)) revert UnauthorizedLender();

        TransientSlot.BooleanSlot in_on_flashloan = _IN_ON_FLASHLOAN_SLOT.asBoolean();
        if (in_on_flashloan.tload()) revert AlreadyInOnFlashLoan();
        in_on_flashloan.tstore(true);

        CallbackData memory d = abi.decode(data, (CallbackData));
        _enter(d, amount);

        in_on_flashloan.tstore(false);
        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    function _enter(CallbackData memory d, uint256 crvUsdIn) private {
        // 1) swap crvUSD -> reUSD on Curve
        approveIfNecessary(CRVUSD, d.curvePool, crvUsdIn);
        uint256 reusdOut = ICurvePool(d.curvePool).exchange(d.curveI, d.curveJ, crvUsdIn, d.minReusdOut);
        if (reusdOut < d.minReusdOut) revert SlippageTooHigh();

        // 2) redeem reUSD -> crvUSD using RedemptionHandler
        approveIfNecessary(REUSD, address(REDEMPTION_HANDLER), reusdOut);
        uint256 crvUsdRedeemed =
            REDEMPTION_HANDLER.redeemFromPair(address(d.market), reusdOut, d.maxFeePct, address(this), true);
        if (crvUsdRedeemed < d.minCrvUsdRedeemed) revert SlippageTooHigh();

        // 3) deposit crvUSD into the market as collateral (mint/borrow not handled here)
        // Use all crvUSD we have (redeemed + any leftover) minus the flash loan principal, leaving principal for repayment.
        uint256 crvBal = CRVUSD.balanceOf(address(this));
        uint256 depositAmount = crvBal > d.flashAmount ? (crvBal - d.flashAmount) : 0;

        if (depositAmount > 0) {
            approveIfNecessary(CRVUSD, address(d.market), depositAmount);
            d.market.addCollateral(depositAmount, address(this));
        }

        // Repayment: lender will pull `amount` (fee assumed 0 like migrate) from this contract via allowance.
        approveIfNecessary(CRVUSD, address(CRVUSD_FLASH_LENDER), d.flashAmount);

        // Optional sanity: ensure we can repay principal.
        if (CRVUSD.balanceOf(address(this)) < d.flashAmount) revert SlippageTooHigh();
    }

    function approveIfNecessary(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, amount);
        }
    }
}
