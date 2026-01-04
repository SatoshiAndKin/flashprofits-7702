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
import {IResupplyPair} from "../../interfaces/resupply/IResupplyPair.sol";
import {ResupplyConstants} from "./ResupplyConstants.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {console} from "forge-std/console.sol";

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
    error HealthCheckFailed(uint256 principleAmount, uint256 minPrincipleAmount);
    error InsufficientFunds(uint256 have, uint256 totalNeeded, uint256 missing);

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
        IResupplyPair market;
        IResupplyPair redeemMarket;
        bool shouldRedeem;
    }

    /// @notice Enter a position by flash loaning crvUSD, swapping to reUSD on Curve, redeeming to crvUSD, and depositing.
    /// @dev Intended for FlashAccount.transientExecute (delegatecall).
    function flashLoan(
        uint256 additionalCrvUsd,
        uint256 newBorrowAmount,
        uint256 minPrinciple,
        IResupplyPair market,
        IResupplyPair redeemMarket
    ) external {
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

        // ensures any view calculations are correct. we might not need this depending on the rest of this function
        market.addInterest(false);

        // TODO: slippage check on the flashAmount? i think our other health checks are sufficient
        // TODO: i can't decide if we should calculate this on or off chain. do it here first, then compare gas changes
        // TODO: actually check this!
        bool shouldRedeem = true;

        (uint256 flashAmount,,) = REDEMPTION_HANDLER.previewRedeem(address(redeemMarket), newBorrowAmount);

        bytes memory data = abi.encode(
            CallbackData({
                market: market,
                additionalCrvUsd: additionalCrvUsd,
                newBorrowAmount: newBorrowAmount,
                redeemMarket: redeemMarket,
                shouldRedeem: shouldRedeem
            })
        );

        if (!CRVUSD_FLASH_LENDER.flashLoan(IERC3156FlashBorrower(self), address(CRVUSD), flashAmount, data)) {
            // TODO: i think this is impossible. i think it actually reverts instead of returns false
            revert FlashLoanFailed();
        }

        // safety check on the health
        uint256 finalBorrowShares = market.userBorrowShares(address(this));
        uint256 finalBorrowAmount = market.toBorrowAmount(finalBorrowShares, true, false);
        console.log("finalBorrowAmount:", finalBorrowAmount);

        uint256 finalCollateralShares = market.userCollateralBalance(address(this));

        IERC4626 collateral = IERC4626(market.collateral());

        // TODO: some code uses the "oracle" from `IResupplyPair(_pair).exchangeRateInfo();`, but this was recommended to me
        uint256 finalCollateralAmount = collateral.convertToAssets(finalCollateralShares);
        console.log("finalCollateralAmount:", finalCollateralAmount);

        console.log("minPrinciple:", minPrinciple);

        uint256 finalPrinciple = finalCollateralAmount - finalBorrowAmount;
        console.log("finalPrinciple:", finalPrinciple);

        if (finalPrinciple < minPrinciple) {
            revert HealthCheckFailed(finalPrinciple, minPrinciple);
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
            // this re-entrancy protection isn't strictly necessary
            // the flash lender isn't upgradable so it should be fine to just check the initiator
            // but we are intentionally keeping paranoid levels of security
            revert UnauthorizedFlashLoanCallback();
        }
        if (msg.sender != address(CRVUSD_FLASH_LENDER)) {
            revert UnauthorizedLender();
        }
        if (initiator != address(this)) {
            // this initiator protection isn't strictly necessary
            // we trust crvusd flash lender to not lie about this, we could simplify all these checks, but i feel safer this way.
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
        console.log("crvusd balance:", CRVUSD.balanceOf(address(this)));

        // 1. deposit flashAmount + d.additionalCrvUsd into the market and borrow reUSD
        uint256 depositAmount = flashAmount + d.additionalCrvUsd;
        approveIfNecessary(CRVUSD, address(d.market), depositAmount);
        d.market.borrow(d.newBorrowAmount, depositAmount, address(this));

        // 2. redeem reUSD for crvUSD via the redemption handler
        // TODO: we might want to split this across multiple markets!
        // TODO: we might want to trade instead of redeem!
        if (d.shouldRedeem) {
            approveIfNecessary(REUSD, address(REDEMPTION_HANDLER), d.newBorrowAmount);

            // TODO: what should the maxFeePct be?
            uint256 redeemed = REDEMPTION_HANDLER.redeemFromPair(
                address(d.redeemMarket), d.newBorrowAmount, 0.01e18, address(this), true
            );

            // we have this IMPORTANT check to keep us from using more than our alloted amount of crvUSD
            if (flashAmount > redeemed) {
                revert InsufficientFunds(redeemed, flashAmount, flashAmount - redeemed);
            }
        } else {
            // if we shouldn't redeem, we should exchange
            revert("wip");
        }

        // 3. transfer crvUsdIn to the market to repay the flash loan
        // this amount should be exact
        CRVUSD.safeTransfer(address(CRVUSD_FLASH_LENDER), flashAmount);
    }

    function approveIfNecessary(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            // TODO: max approvals here are VERY tempting. but hacks are scary. don't do it! accept the gas costs!
            // TODO: gas golf adding 1 to this
            token.forceApprove(spender, amount);
        }
    }
}
