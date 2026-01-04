// SPDX-License-Identifier: UNLICENSED
// TODO: i can think of like 4 different ways to arrange this contract. just make it work, then make it right later.
// because i want to have dynamic amounts for migrations, its easier to have flashLoan and onFlashLoan in the same contract
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IResupplyPair} from "../../interfaces/resupply/IResupplyPair.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ResupplyConstants} from "./ResupplyConstants.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

// TODO: make this work specifically to the crvUSD markets. then make it more generic in the next version. don't get ahead of myself.
// TODO: i should just do weiroll. why deploy contracts that i'm only going to run a couple times?
contract ResupplyCrvUSDFlashMigrate is IERC3156FlashBorrower, ResupplyConstants {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error Unauthorized();
    error UnexpectedUnderlying();
    error MarketUnderlyingMismatch();
    error FlashLoanFailed();
    error NoSourceMarket();
    error AlreadyInFlashLoan();
    error AlreadyInOnFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedInitiator();
    error UnauthorizedLender();

    // @dev Boolean slot (stored via transient storage) derived using EIP-1967-style `keccak256("...") - 1`,
    // with low-byte masking for alignment/namespacing.
    bytes32 internal constant _IN_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.in_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    // @dev Boolean slot (stored via transient storage) derived using EIP-1967-style `keccak256("...") - 1`,
    // with low-byte masking for alignment/namespacing.
    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.in_on_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        IResupplyPair sourceMarket;
        IResupplyPair targetMarket;
        uint256 migrateBorrowBps;
        uint256 migrateCollateralBps;
        uint256 sourceCollateralShares;
    }

    /// @notice Migrates a Resupply position from `_sourceMarket` to `_targetMarket` using a crvUSD flash loan.
    /// @dev Meant to be called by {FlashAccount.fallback} via {FlashAccount.transientExecute} (delegatecall).
    function flashLoan(
        IResupplyPair _sourceMarket,
        uint256 _migrateBorrowBps,
        uint256 _migrateCollateralBps,
        IResupplyPair _targetMarket
    ) external {
        // re-entrancy protection
        TransientSlot.BooleanSlot in_flashloan = _IN_FLASHLOAN_SLOT.asBoolean();
        if (in_flashloan.tload()) {
            revert AlreadyInFlashLoan();
        }
        in_flashloan.tstore(true);

        // cache self to save some gas (honestly surprised this works)
        address self = address(this);

        // TODO: more open auth is an option for the future. keep it locked down for now
        if (msg.sender != self) revert Unauthorized();

        // make sure we have valid markets
        IERC4626 collateral = IERC4626(_sourceMarket.collateral());
        IERC20 underlying = IERC20(_sourceMarket.underlying());

        if (address(underlying) != address(CRVUSD)) {
            revert UnexpectedUnderlying();
        }

        // the source and target market underlyings have to match!
        if (address(underlying) != _targetMarket.underlying()) {
            revert MarketUnderlyingMismatch();
        }

        // accrue interest now so toBorrowAmount is accurate later
        // param _returnAccounting is false since we don't need the return values
        _sourceMarket.addInterest(false);

        // calculate flash loan size using ERC4626 convertToAssets for accurate pricing
        uint256 userCollateralShares = _sourceMarket.userCollateralBalance(self);
        uint256 collateralValue = collateral.convertToAssets(userCollateralShares);
        uint256 flashAmount = Math.mulDiv(collateralValue, _migrateCollateralBps, 10_000);

        // TODO: encoding is more gas efficient to do off-chain, but it's really a pain in the butt to call these functions if we do that
        bytes memory data = abi.encode(
            CallbackData({
                sourceMarket: _sourceMarket,
                targetMarket: _targetMarket,
                migrateCollateralBps: _migrateCollateralBps,
                migrateBorrowBps: _migrateBorrowBps,
                sourceCollateralShares: userCollateralShares
            })
        );

        // initiate flash loan. the rest happens in `onFlashLoan` after they send us tokens
        if (!CRVUSD_FLASH_LENDER.flashLoan(IERC3156FlashBorrower(self), address(CRVUSD), flashAmount, data)) {
            revert FlashLoanFailed();
        }

        // clear transient storage to allow subsequent flash loans
        in_flashloan.tstore(false);
    }

    bytes32 internal constant ERC3156_FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // TODO: a more complex flash loan would also allow frxUSD/sfrxUSD lending. KISS for now
    // TODO: there's no need for onlyDelegateCall here since we have other checks. but its best to be consistent
    /// @notice ERC-3156 flash loan callback that continues {flashLoan}.
    function onFlashLoan(
        address,
        /*initiator*/
        address,
        /*token*/
        uint256 amount,
        uint256,
        /*fee*/
        bytes calldata data
    )
        external
        virtual
        returns (bytes32)
    {
        // If the transient isn't set, msg.sender did NOT start the flashLoan! This is an attack!
        if (!_IN_FLASHLOAN_SLOT.asBoolean().tload()) {
            revert UnauthorizedFlashLoanCallback();
        }

        // Reject calls from anyone but the flash lender; only the designated lender may call this callback.
        if (msg.sender != address(CRVUSD_FLASH_LENDER)) {
            revert UnauthorizedLender();
        }

        // second layer of re-entrancy protection
        // this is probably overkill. but i'm scared
        TransientSlot.BooleanSlot in_on_flashloan = _IN_ON_FLASHLOAN_SLOT.asBoolean();
        if (in_on_flashloan.tload()) {
            revert AlreadyInOnFlashLoan();
        }
        in_on_flashloan.tstore(true);

        // This is overkill to check
        // if (data.length == 0) revert NoSourceMarket();

        // This lender always lends CRVUSD. no need to check token.
        // if (token != address(CRVUSD)) revert UnexpectedFlashLoanToken();

        // This lender always charges a 0 fee; skip the check to save gas.
        // if (fee != 0) revert NonZeroFlashLoanFee();

        // // there's really no point in checking initiator, but i'm paranoid. optimize later
        // if (initiator != address(this)) revert UnauthorizedInitiator();

        // TODO: i keep wanting this to be something like target.functionDelegateCall(data), but dedicated contracts are better for now. its not that much boilerplate.
        CallbackData memory flashData = abi.decode(data, (CallbackData));

        migrate(
            flashData.sourceMarket,
            flashData.targetMarket,
            amount,
            flashData.migrateBorrowBps,
            flashData.migrateCollateralBps,
            flashData.sourceCollateralShares
        );

        // clear transient storage to allow subsequent flash loans
        in_on_flashloan.tstore(false);

        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    /// @dev Migrate position from sourceMarket to targetMarket using flash loaned crvUSD
    /// TODO: we might not want to migrate evenly. we might want to migrate more crvUSD or more reUSD
    function migrate(
        IResupplyPair sourceMarket,
        IResupplyPair targetMarket,
        uint256 crvUsdAmount,
        uint256 migrateBorrowBps,
        uint256 migrateCollateralBps,
        uint256 sourceCollateralShares
    ) private {
        // take a configurable amount of the collateral
        uint256 migratingCollateralShares = Math.mulDiv(sourceCollateralShares, migrateCollateralBps, 10_000);

        // we need to know how much reUSD we currently have borrowed on sourceMarket
        uint256 sourceBorrowShares = sourceMarket.userBorrowShares(address(this));

        // take a configurable amount of the borrow
        uint256 migratingBorrowShares = Math.mulDiv(sourceBorrowShares, migrateBorrowBps, 10_000);

        uint256 targetBorrowAmount = sourceMarket.toBorrowAmount(
            migratingBorrowShares,
            // round up to ensure we borrow enough to repay
            true,
            // interest already accrued in flashLoan(), no need to update again
            false
        );

        // first, open a new loan using the flash loaned crvUSD as collateral
        approveIfNecessary(CRVUSD, address(targetMarket), crvUsdAmount);
        targetMarket.borrow(targetBorrowAmount, crvUsdAmount, address(this));

        // now we have reUSD. repay the source loan with SHARES (not amount)
        // approve max to handle any interest accrual between borrow and repay
        approveIfNecessary(REUSD, address(sourceMarket), type(uint256).max);
        sourceMarket.repay(migratingBorrowShares, address(this));

        // finally, remove the collateral from sourceMarket to repay the flash loan
        sourceMarket.removeCollateral(migratingCollateralShares, address(CRVUSD_FLASH_LENDER));

        // console.log("this", address(this));

        // require(
        //     CRVUSD.balanceOf(address(this)) >= crvUsdAmount,
        //     "insufficient crvUSD"
        // );
        // console.log(
        //     "crvUSD balance after migrate:",
        //     CRVUSD.balanceOf(address(this))
        // );

        // TODO: check one or more of: ltv/health/minimumPrinciple
    }

    /// @notice Force-approves `spender` for `amount` if the current allowance is insufficient.
    /// @dev Uses OZ SafeERC20.forceApprove to safely handle tokens that require allowance resets.
    function approveIfNecessary(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, amount);
        }
    }
}
