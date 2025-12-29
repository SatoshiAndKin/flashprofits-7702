// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {OnlyDelegateCall} from "../abstract/OnlyDelegateCall.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ResupplyPair} from "../interfaces/ResupplyPair.sol";
import {RedemptionHandler} from "../interfaces/RedemptionHandler.sol";

/// @notice Single-tx executor for ResuplyCrvUSDOptimize plans (meant for FlashAccount.transientExecute).
contract ResupplyCrvUSDOptimize is OnlyDelegateCall, IERC3156FlashBorrower {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER = IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);
    RedemptionHandler constant REDEMPTION_HANDLER = RedemptionHandler(0x99999999A5Dc4695EF303C9EA9e4B3A19367Ed94);

    error Unauthorized();
    error UnexpectedUnderlying();
    error MarketUnderlyingMismatch();
    error FlashLoanFailed();
    error AlreadyInFlashLoan();
    error AlreadyInOnFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedLender();
    error InsufficientReusd(uint256 needed, uint256 available);

    enum Op {
        AddCollateral,
        Borrow,
        Repay,
        LeverageMore,
        RedeemAllReusdAndDeposit,
        Migrate
    }

    struct Action {
        Op op;
        ResupplyPair market;
        ResupplyPair other;
        uint256 amount;
        uint256 aux;
    }

    bytes32 internal constant _IN_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDOptimize.in_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDOptimize.in_on_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        ResupplyPair sourceMarket;
        ResupplyPair targetMarket;
        uint256 amountBps;
        uint256 sourceCollateralShares;
    }

    function execute(Action[] calldata actions) external onlyDelegateCall {
        address self = address(this);
        if (msg.sender != self) revert Unauthorized();

        for (uint256 i = 0; i < actions.length; i++) {
            Action calldata a = actions[i];

            if (a.op == Op.AddCollateral) {
                _addCollateral(a.market, a.amount);
            } else if (a.op == Op.Borrow) {
                _borrow(a.market, a.amount);
            } else if (a.op == Op.Repay) {
                _repay(a.market, a.amount);
            } else if (a.op == Op.LeverageMore) {
                _leverageMore(a.market, a.amount, a.aux);
            } else if (a.op == Op.RedeemAllReusdAndDeposit) {
                _redeemAllReusdAndDeposit(a.market, a.aux);
            } else if (a.op == Op.Migrate) {
                _migrateFlashLoan(a.market, a.amount, a.other);
            }
        }
    }

    function _addCollateral(ResupplyPair market, uint256 crvUsdAmount) internal {
        if (crvUsdAmount == 0) return;
        if (market.underlying() != address(CRVUSD)) revert UnexpectedUnderlying();
        approveIfNecessary(CRVUSD, address(market), crvUsdAmount);
        market.addCollateral(crvUsdAmount, address(this));
    }

    function _borrow(ResupplyPair market, uint256 borrowAmount) internal {
        if (borrowAmount == 0) return;
        if (market.underlying() != address(CRVUSD)) revert UnexpectedUnderlying();
        market.borrow(borrowAmount, 0, address(this));
    }

    function _repay(ResupplyPair market, uint256 repayShares) internal {
        if (repayShares == 0) return;
        uint256 needed = market.toBorrowAmount(repayShares, true, true);
        uint256 bal = REUSD.balanceOf(address(this));
        if (bal < needed) revert InsufficientReusd(needed, bal);
        approveIfNecessary(REUSD, address(market), type(uint256).max);
        market.repay(repayShares, address(this));
    }

    function _leverageMore(ResupplyPair market, uint256 borrowAmount, uint256 maxFeePct) internal {
        if (borrowAmount == 0) return;
        if (market.underlying() != address(CRVUSD)) revert UnexpectedUnderlying();

        // Borrow reUSD
        market.borrow(borrowAmount, 0, address(this));

        // Redeem reUSD -> crvUSD using RedemptionHandler
        approveIfNecessary(REUSD, address(REDEMPTION_HANDLER), borrowAmount);
        uint256 crvOut =
            REDEMPTION_HANDLER.redeemFromPair(address(market), borrowAmount, maxFeePct, address(this), true);

        // Deposit crvUSD as collateral back into the same market
        approveIfNecessary(CRVUSD, address(market), crvOut);
        market.addCollateral(crvOut, address(this));
    }

    function _redeemAllReusdAndDeposit(ResupplyPair market, uint256 maxFeePct) internal {
        uint256 reusdBal = REUSD.balanceOf(address(this));
        if (reusdBal == 0) return;
        approveIfNecessary(REUSD, address(REDEMPTION_HANDLER), reusdBal);
        uint256 crvOut = REDEMPTION_HANDLER.redeemFromPair(address(market), reusdBal, maxFeePct, address(this), true);
        _addCollateral(market, crvOut);
    }

    function _migrateFlashLoan(ResupplyPair source, uint256 amountBps, ResupplyPair target) internal {
        TransientSlot.BooleanSlot in_flashloan = _IN_FLASHLOAN_SLOT.asBoolean();
        if (in_flashloan.tload()) revert AlreadyInFlashLoan();
        in_flashloan.tstore(true);

        address self = address(this);
        if (msg.sender != self) revert Unauthorized();

        if (source.underlying() != address(CRVUSD)) revert UnexpectedUnderlying();
        if (source.underlying() != target.underlying()) revert MarketUnderlyingMismatch();

        source.addInterest(false);

        IERC4626 collateral = IERC4626(source.collateral());
        uint256 userCollateralShares = source.userCollateralBalance(self);
        uint256 collateralValue = collateral.convertToAssets(userCollateralShares);
        uint256 flashAmount = Math.mulDiv(collateralValue, amountBps, 10_000);

        bytes memory data = abi.encode(
            CallbackData({
                sourceMarket: source,
                targetMarket: target,
                amountBps: amountBps,
                sourceCollateralShares: userCollateralShares
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
        _migrate(d.sourceMarket, d.targetMarket, amount, d.amountBps, d.sourceCollateralShares);

        in_on_flashloan.tstore(false);
        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    function _migrate(
        ResupplyPair sourceMarket,
        ResupplyPair targetMarket,
        uint256 crvUsdAmount,
        uint256 amountBps,
        uint256 sourceCollateralShares
    ) private {
        uint256 migratingCollateral = Math.mulDiv(sourceCollateralShares, amountBps, 10_000);

        uint256 sourceBorrowShares = sourceMarket.userBorrowShares(address(this));
        uint256 migratingBorrowShares = Math.mulDiv(sourceBorrowShares, amountBps, 10_000);

        uint256 targetBorrowAmount = sourceMarket.toBorrowAmount(migratingBorrowShares, true, false);

        approveIfNecessary(CRVUSD, address(targetMarket), crvUsdAmount);
        targetMarket.borrow(targetBorrowAmount, crvUsdAmount, address(this));

        approveIfNecessary(REUSD, address(sourceMarket), type(uint256).max);
        sourceMarket.repay(migratingBorrowShares, address(this));

        sourceMarket.removeCollateral(migratingCollateral, address(CRVUSD_FLASH_LENDER));
    }

    function approveIfNecessary(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, amount);
        }
    }
}
