// SPDX-License-Identifier: UNLICENSED
// TODO: i can think of like 4 different ways to arrange this contract. just make it work, then make it right later.
// because i want to have dynamic amounts for migrations, its easier to have flashLoan and onFlashLoan in the same contract
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {OnlyDelegateCall} from "../abstract/OnlyDelegateCall.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ResupplyPair} from "../interfaces/ResupplyPair.sol";

// TODO: make this work specifically to the crvUSD markets. then make it more generic in the next version. don't get ahead of myself.
// TODO: i should just do weiroll. why deploy contracts that i'm only going to run a couple times?
contract ResupplyCrvUSDFlashMigrate is OnlyDelegateCall, IERC3156FlashBorrower {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER = IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);

    error Unauthorized();
    error ReentrancyDetected();
    error UnexpectedUnderlying();
    error MarketUnderlyingMismatch();
    error FlashLoanFailed();
    error NoSourceMarket();
    error NonZeroFlashLoanFee();
    error NotInFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedInitiator();

    // @dev this is an address used for re-entrancy protection
    // TODO: i want to use openzeppelin's helper, but it isn't constant
    bytes32 internal constant _SOURCE_MARKET_SLOT = keccak256(
        abi.encode(
            uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.source_market_slot")) - 1
        )
    ) & ~bytes32(uint256(0xff));

    // @dev this is a boolean used for re-entrancy protection
    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.in_on_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        ResupplyPair targetMarket;
        uint256 amountBps;
    }

    /// @notice Entry point to migrate a Resupply position from one market to another using a crvUSD flash loan.
    /// @dev Must be executed via `delegatecall` (see {OnlyDelegateCall}) and is intended to be invoked through
    /// {FlashAccount.transientExecute} so that `msg.sender == address(this)`.
    ///
    /// Preconditions / validation:
    /// - Caller must be `address(this)` (locked down; prevents arbitrary third parties from migrating).
    /// - `_sourceMarket.underlying()` must be crvUSD and must match `_targetMarket.underlying()`.
    /// - Reentrancy is prevented using a transient storage guard.
    ///
    /// What it does:
    /// 1. Accrues interest on the source market.
    /// 2. Computes a flash-loan amount as a bps fraction of the user’s collateral value.
    /// 3. Initiates an ERC-3156 flash loan; continuation occurs in {onFlashLoan}.
    ///
    /// @param _sourceMarket Market to migrate *from*.
    /// @param _amountBps Portion of the position to migrate in basis points (10_000 = 100%).
    /// @param _targetMarket Market to migrate *to*.
    function flashLoan(ResupplyPair _sourceMarket, uint256 _amountBps, ResupplyPair _targetMarket)
        external
        onlyDelegateCall
    {
        address self = address(this);

        // TODO: more open auth is an option for the future. keep it locked down for now
        if (msg.sender != self) revert Unauthorized();

        // given the single transaction openness of this function, a re-entrancy check is probably overkill security. but better safe than sorry.
        TransientSlot.AddressSlot sourceMarketSlot = _SOURCE_MARKET_SLOT.asAddress();

        // re-entrancy protection
        if (sourceMarketSlot.tload() != address(0)) revert ReentrancyDetected();
        sourceMarketSlot.tstore(address(_sourceMarket));

        // make sure we have valid markets
        IERC4626 collateral = IERC4626(_sourceMarket.collateral());
        IERC20 underlying = IERC20(_sourceMarket.underlying());

        if (address(underlying) != address(CRVUSD)) revert UnexpectedUnderlying();

        // the source and target market underlyings have to match!
        if (address(underlying) != _targetMarket.underlying()) {
            revert MarketUnderlyingMismatch();
        }

        // accrue interest now so toBorrowAmount is accurate later
        // param is _returnAccounting, false since we don't need the return values
        _sourceMarket.addInterest(false);

        // calculate flash loan size using ERC4626 convertToAssets for accurate pricing
        uint256 userCollateralShares = _sourceMarket.userCollateralBalance(self);
        uint256 collateralValue = collateral.convertToAssets(userCollateralShares);
        uint256 flashAmount = Math.mulDiv(collateralValue, _amountBps, 10_000);

        // TODO: encoding is more gas efficient to do off-chain, but it's really a pain in the butt to call these functions if we do that
        bytes memory data = abi.encode(CallbackData({targetMarket: _targetMarket, amountBps: _amountBps}));

        // initiate flash loan. the rest happens in `onFlashLoan` after they send us tokens
        if (!CRVUSD_FLASH_LENDER.flashLoan(IERC3156FlashBorrower(self), address(CRVUSD), flashAmount, data)) {
            revert FlashLoanFailed();
        }

        // clear transient storage to allow subsequent migrations in the same tx
        sourceMarketSlot.tstore(address(0));
    }

    bytes32 internal constant ERC3156_FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // TODO: a more complex flash loan would also allow frxUSD/sfrxUSD lending. KISS for now
    // TODO: there's no need for onlyDelegateCall here since we have other checks. but its best to be consistent
    /// @notice ERC-3156 flash loan callback.
    /// @dev Must be executed via `delegatecall` (see {OnlyDelegateCall}). Validates that:
    /// - We are currently inside an expected flash-loan flow (transient guard set).
    /// - The lender is the hard-coded crvUSD flash lender.
    /// - `initiator == address(this)`.
    ///
    /// Decodes the callback payload and calls {migrate}.
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        virtual
        onlyDelegateCall
        returns (bytes32)
    {
        // we don't accept any flash loan unless we are expecting one
        // sourceMarket is only set during a flash loan entrypoint
        ResupplyPair sourceMarket = ResupplyPair(_SOURCE_MARKET_SLOT.asAddress().tload());
        if (address(sourceMarket) == address(0)) revert NoSourceMarket();

        if (fee != 0) revert NonZeroFlashLoanFee();

        // second layer of re-entrancy protection
        // this is definitely overkill. but i'm scared
        if (_IN_ON_FLASHLOAN_SLOT.asBoolean().tload()) revert NotInFlashLoan();
        _IN_ON_FLASHLOAN_SLOT.asBoolean().tstore(true);

        // all flash loans for this contract should come from the crvUSD flash lender
        // TODO: open this up for frxUSD
        if (msg.sender != address(CRVUSD_FLASH_LENDER)) {
            revert UnauthorizedFlashLoanCallback();
        }

        // there's really no point in checking initiator, but i'm paranoid. optimize later
        if (initiator != address(this)) revert UnauthorizedInitiator();

        // TODO: i keep wanting this to be something like target.functionDelegateCall(data), but dedicated contracts are better for now. its not that much boilerplate.
        CallbackData memory flashData = abi.decode(data, (CallbackData));

        migrate(sourceMarket, flashData.targetMarket, amount, flashData.amountBps);

        // clear transient storage to allow subsequent flash loans
        _IN_ON_FLASHLOAN_SLOT.asBoolean().tstore(false);

        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    /// @dev Migrate position from sourceMarket to targetMarket using flash loaned crvUSD
    function migrate(ResupplyPair sourceMarket, ResupplyPair targetMarket, uint256 crvUsdAmount, uint256 amountBps)
        private
    {
        // capture collateral balance BEFORE any operations
        uint256 sourceCollateralBefore = sourceMarket.userCollateralBalance(address(this));
        uint256 migratingCollateral = Math.mulDiv(sourceCollateralBefore, amountBps, 10_000);

        // we need to know how much reUSD we currently have borrowed on sourceMarket
        uint256 sourceBorrowShares = sourceMarket.userBorrowShares(address(this));

        // we might not be taking 100% of the position
        uint256 migratingBorrowShares = Math.mulDiv(sourceBorrowShares, amountBps, 10_000);

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
        sourceMarket.removeCollateral(migratingCollateral, address(CRVUSD_FLASH_LENDER));

        // console.log("this", address(this));

        // require(
        //     CRVUSD.balanceOf(address(this)) >= crvUsdAmount,
        //     "insufficient crvUSD"
        // );
        // console.log(
        //     "crvUSD balance after migrate:",
        //     CRVUSD.balanceOf(address(this))
        // );
    }

    /// @notice Force-approves `spender` for `amount` if the current allowance is insufficient.
    /// @dev Uses OZ SafeERC20.forceApprove to safely handle tokens that require allowance resets.
    function approveIfNecessary(IERC20 token, address spender, uint256 amount) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, amount);
        }
    }
}
