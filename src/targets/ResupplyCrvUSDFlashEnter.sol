// SPDX-License-Identifier: UNLICENSED
/*
v1 is a contract that uses redemptions

v2 is a contract that uses redemptions OR trades. whichever is better at the moment. to save gas, we should compare the current price to slippage before doing a get_dx.

v3 is a contract that uses the optimal combination of redemptions and trades

TODO: Math.mulDiv is probably overkill, but maybe we should use it
*/
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ResupplyConstants} from "../abstract/ResupplyConstants.sol";
import {IResupplyPair} from "../interfaces/resupply/IResupplyPair.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

contract ResupplyCrvUSDFlashEnter is IERC3156FlashBorrower, ResupplyConstants {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error Unauthorized();
    error UnexpectedUnderlying();
    error FlashLoanFailed();
    error AlreadyInFlashLoan();
    error AlreadyInOnFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedLender();
    error SlippageTooHigh();
    error HealthCheckFailed(uint256 finalHealthBps, uint256 minHealthBps);

    bytes32 internal constant _IN_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashEnter.in_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashEnter.in_on_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        // extra crv usd to include. this can make up for trade slippage and price impact
        uint256 additionalCrvUsd;
        uint256 newBorrowAmount;
        uint256 maxFeePct;
        IResupplyPair market;
        IResupplyPair redeemMarket;
    }

    /// @notice Enter a position by flash loaning crvUSD, swapping to reUSD on Curve, redeeming to crvUSD, and depositing.
    /// @dev Intended for FlashAccount.transientExecute (delegatecall).
    /// TODO: i want the maximum leverage that makes profit. but for now we will just take user input. we also want to be careful of bad debt in the curvelend markets!
    /// TODO: part of this should be calculated off-chain and then passed into this function. that should save a lot of gas. but its more complex and not worth doing yet
    function flashLoan(
        uint256 additionalCrvUsd,
        uint256 goalHealthBps,
        uint256 leverageBps,
        uint256 maxFeePct,
        uint256 minHealthBps,
        IResupplyPair market,
        IResupplyPair redeemMarket
    ) external {
        // TODO: goalHealthBps for calculating borrow size and minHealthBps to handle slippage and price impact!
        // TODO: goal health is assuming 1:1 peg right now. which we don't want. we need to recreate the isSolvent logic!

        // checking msg.sender == self means we don't need `onlyDelegateCall`
        address self = address(this);
        if (msg.sender != self) revert Unauthorized();

        // verify market
        // TODO: remove this in production. the contract will revert if a bad market is given
        if (market.underlying() != address(CRVUSD)) {
            revert UnexpectedUnderlying();
        }

        // re-entrancy protection
        TransientSlot.BooleanSlot in_flashloan = _IN_FLASHLOAN_SLOT.asBoolean();
        if (in_flashloan.tload()) revert AlreadyInFlashLoan();
        in_flashloan.tstore(true);

        // probably unnecessary safety check. don't allow closer than 1%. i think bad debt on curve lend can lead to a liquidation here. need to
        require(minHealthBps >= 1.01e4, "bad min health");

        // ensures any view calculations are correct. we might not need this depending on the rest of this function
        market.addInterest(false);

        // get existing deposits
        uint256 collateralShares = market.userCollateralBalance(address(this));

        IERC4626 collateral = IERC4626(market.collateral());

        uint256 collateralValue = collateral.convertToAssets(collateralShares);

        uint256 principleAmount = collateralValue + additionalCrvUsd;

        uint256 expectedDeposit = principleAmount * leverageBps / 1e4;

        uint256 flashAmount = expectedDeposit - principleAmount;

        // get existing borrows
        uint256 currentBorrowShares = market.userBorrowShares(address(this));

        // TODO: not sure about this rounding (which scares me some)
        uint256 currentBorrowAmount = market.toBorrowAmount(currentBorrowShares, true, false);

        uint256 maxLtv = market.maxLTV();
        uint256 ltvPrecision = market.LTV_PRECISION();

        uint256 goalBorrowAmount = (expectedDeposit * 1e4 * maxLtv) / goalHealthBps / ltvPrecision;

        uint256 newBorrowAmount = goalBorrowAmount - currentBorrowAmount;

        bytes memory data = abi.encode(
            CallbackData({
                market: market,
                additionalCrvUsd: additionalCrvUsd,
                newBorrowAmount: newBorrowAmount,
                maxFeePct: maxFeePct,
                redeemMarket: redeemMarket
            })
        );

        if (!CRVUSD_FLASH_LENDER.flashLoan(IERC3156FlashBorrower(self), address(CRVUSD), flashAmount, data)) {
            // TODO: i think this is impossible. i think it actually reverts instead of returns false
            revert FlashLoanFailed();
        }

        // safety check on the health
        uint256 finalBorrowShares = market.userBorrowShares(address(this));
        uint256 finalBorrowAmount = market.toBorrowAmount(finalBorrowShares, true, false);
        uint256 finalCollateralShares = market.userCollateralBalance(address(this));
        uint256 finalCollateralAssets = collateral.convertToAssets(finalCollateralShares);

        // shift 1e4 to turn it into BPS
        uint256 finalHealthBps = (finalCollateralAssets * 1e4 * maxLtv) / finalBorrowAmount / ltvPrecision;

        if (finalHealthBps < minHealthBps) {
            revert HealthCheckFailed(finalHealthBps, minHealthBps);
        }

        // end the re-entrancy protection
        in_flashloan.tstore(false);
    }

    bytes32 internal constant ERC3156_FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function onFlashLoan(
        address initiator,
        address,
        /*token*/
        uint256 flashAmount,
        uint256,
        bytes calldata data
    )
        external
        returns (bytes32)
    {
        if (!_IN_FLASHLOAN_SLOT.asBoolean().tload()) {
            // TODO: this re-entrancy protection isn't strictly necessary. the flash lender isn't upgradable so it should be fine to just check the initiator
            revert UnauthorizedFlashLoanCallback();
        }
        if (msg.sender != address(CRVUSD_FLASH_LENDER)) {
            revert UnauthorizedLender();
        }
        if (initiator != address(this)) {
            // TODO: since we trust crvusd flash lender to not lie about this, we could simplify all these checks, but i feel safer this way.
            revert UnauthorizedFlashLoanCallback();
        }

        // theres no point in checking that the token is crvUSD. the lender is hard coded and only lends crvUSD

        // re-entrancy protection for onFlashLoan. probably overkill, but better safe than sorry
        TransientSlot.BooleanSlot in_on_flashloan = _IN_ON_FLASHLOAN_SLOT.asBoolean();
        if (in_on_flashloan.tload()) revert AlreadyInOnFlashLoan();
        in_on_flashloan.tstore(true);

        // do the actual flash loan logic
        // TODO: I wish we could keep this as calldata. that is premature optimization though
        CallbackData memory d = abi.decode(data, (CallbackData));
        _enter(d, flashAmount);

        // end the re-entrancy protection
        in_on_flashloan.tstore(false);

        // return a magic value
        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    /// TODO: I wish there was a way to mark this as inline.
    function _enter(CallbackData memory d, uint256 flashAmount) private {
        // 1. deposit flashAmount + d.additionalCrvUsd into the market and borrow reUSD
        uint256 depositAmount = flashAmount + d.additionalCrvUsd;
        approveIfNecessary(CRVUSD, address(d.market), depositAmount);
        d.market.borrow(d.newBorrowAmount, depositAmount, address(this));

        // 2. redeem reUSD for crvUSD via the redemption handler
        approveIfNecessary(REUSD, address(REDEMPTION_HANDLER), d.newBorrowAmount);
        uint256 redeemed = REDEMPTION_HANDLER.redeemFromPair(
            address(d.redeemMarket), d.newBorrowAmount, d.maxFeePct, address(this), true
        );

        // TODO: log with decimal points
        // emit log_named_decimal_uint("redeemed", redeemed, 18);
        // emit log_named_decimal_uint("crvusd balance:", CRVUSD.balanceOf(address(this)), 18);
        // emit log_named_decimal_uint("flash amount:", flashAmount, 18);

        // TODO: this require isn't strictly necessary, but it gives us a prettier error
        require(flashAmount <= redeemed, "insufficient funds for flash repayment");

        // 3. transfer crvUsdIn to the market to repay the flash loan
        CRVUSD.safeTransfer(address(CRVUSD_FLASH_LENDER), flashAmount);

        // 4. deposit any excess crvUSD into the market as collateral
        // TODO: or should we just keep the crvUSD in our account?
        if (redeemed > flashAmount) {
            d.market.addCollateral(redeemed - flashAmount, address(this));
        }
    }

    function approveIfNecessary(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            // TODO: max approvals here are VERY tempting. but hacks are scary. don't do it! accept the gas costs!
            // TODO: gas golf adding 1 to this
            token.forceApprove(spender, amount);
        }
    }
}
