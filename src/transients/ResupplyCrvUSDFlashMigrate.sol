// SPDX-License-Identifier: UNLICENSED
// TODO: i can think of like 4 different ways to arrange this contract. just make it work, then make it right later.
// because i want to have dynamic amounts for migrations, its easier to have flashLoan and onFlashLoan in the same contract
pragma solidity ^0.8.30;

import {console} from "forge-std/console.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    SafeERC20,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IERC3156FlashBorrower,
    IERC3156FlashLender
} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {OnlyDelegateCall} from "../abstract/OnlyDelegateCall.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {ResupplyPair} from "../interfaces/ResupplyPair.sol";

// TODO: make this work specifically to the crvUSD markets. then make it more generic in the next version. don't get ahead of myself.
// TODO: i should just do weiroll. why deploy contracts that i'm only going to run a couple times?
contract ResupplyCrvUSDFlashMigrate is OnlyDelegateCall, IERC3156FlashBorrower {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER =
        IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);

    // @dev this is an address used for re-entrancy protection
    // TODO: i want to use openzeppelin's helper, but it isn't constant
    bytes32 internal constant _SOURCE_MARKET_SLOT =
        keccak256(
            abi.encode(
                uint256(
                    keccak256(
                        "flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.source_market_slot"
                    )
                ) - 1
            )
        ) & ~bytes32(uint256(0xff));

    // @dev this is a boolean used for re-entrancy protection
    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT =
        keccak256(
            abi.encode(
                uint256(
                    keccak256(
                        "flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.in_on_flashloan"
                    )
                ) - 1
            )
        ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        ResupplyPair targetMarket;
        uint256 amountBps;
    }

    function flashLoan(
        ResupplyPair _sourceMarket,
        uint256 _amountBps,
        ResupplyPair _targetMarket
    ) external onlyDelegateCall {
        // TODO: more open auth is an option for the future. keep it locked down for now
        require(msg.sender == address(this), "unauthorized");

        // given the single transaction openness of this function, a re-entrancy check is probably overkill security. but better safe than sorry.
        TransientSlot.AddressSlot sourceMarketSlot = _SOURCE_MARKET_SLOT
            .asAddress();

        // re-entrancy protection
        require(
            sourceMarketSlot.tload() == address(0),
            "flashloan: re-entrancy detected"
        );
        sourceMarketSlot.tstore(address(_sourceMarket));

        // make sure we have valid markets
        IERC20 collateral = IERC20(_sourceMarket.collateral());
        console.log("collateral:", address(collateral));

        IERC20 underlying = IERC20(_sourceMarket.underlying());
        console.log("underlying:", address(underlying));

        require(
            address(underlying) == address(CRVUSD),
            "unexpected underlying"
        );

        // the source and target market underlyings have to match!
        require(
            address(underlying) == _targetMarket.underlying(),
            "market underlying mismatch"
        );

        // accrue interest now so toBorrowAmount is accurate later
        // TODO: i think we want `true` on this.
        _sourceMarket.addInterest(false);

        uint256 exchangePrecision = _sourceMarket.EXCHANGE_PRECISION();

        (
            ,
            uint256 lastTimestamp,
            uint256 exchangeRate
        ) = _sourceMarket.exchangeRateInfo();

        // ensure exchange rate is fresh (within 1 day)
        require(
            block.timestamp - lastTimestamp < 1 days,
            "stale exchange rate"
        );

        // TODO: gas golf this. do one mulDiv
        uint256 sourceCrvUSD = Math.mulDiv(
            _sourceMarket.userCollateralBalance(address(this)),
            exchangePrecision,
            exchangeRate
        );

        // calculate flash loan size
        // TODO: this is wrong. this is the LP tokens.
        uint256 flashAmount = Math.mulDiv(sourceCrvUSD, _amountBps, 10_000);

        // TODO: encoding is more gas efficient to do off-chain, but it's really a pain in the butt to call these functions if we do that
        bytes memory data = abi.encode(
            CallbackData({targetMarket: _targetMarket, amountBps: _amountBps})
        );

        // initiate flash loan. the rest happens in `onFlashLoan` after they send us tokens
        require(
            CRVUSD_FLASH_LENDER.flashLoan(
                IERC3156FlashBorrower(address(this)),
                address(CRVUSD),
                flashAmount,
                data
            ),
            "flash loan failed"
        );

        // TODO: i don't think we want to clear the transient storage here. we only want one flashLoan per transaction
    }

    bytes32 internal constant ERC3156_FLASH_LOAN_SUCCESS =
        keccak256("ERC3156FlashBorrower.onFlashLoan");

    // TODO: a more complex flash loan would also allow frxUSD/sfrxUSD lending. KISS for now
    // TODO: there's no need for onlyDelegateCall here since we have other checks. but its best to be consistent
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external virtual onlyDelegateCall returns (bytes32) {
        // we don't accept any flash loan unless we are expecting one
        // sourceMarket is only set during a flash loan entrypoint
        ResupplyPair sourceMarket = ResupplyPair(
            _SOURCE_MARKET_SLOT.asAddress().tload()
        );
        require(address(sourceMarket) != address(0), "no source market");

        require(fee == 0, "non-zero flash loan fee");

        // second layer of re-entrancy protection
        // this is definitely overkill. but i'm scared
        require(
            !_IN_ON_FLASHLOAN_SLOT.asBoolean().tload(),
            "not in flash loan"
        );
        _IN_ON_FLASHLOAN_SLOT.asBoolean().tstore(true);

        // all flash loans for this contract should come from the crvUSD flash lender
        // TODO: open this up for frxUSD
        require(
            msg.sender == address(CRVUSD_FLASH_LENDER),
            "unauthorized flash loan callback"
        );

        // there's really no point in checking initiator, but i'm paranoid. optimize later
        require(initiator == address(this), "unauthorized initiator");

        // TODO: i keep wanting this to be something like target.functionDelegateCall(data), but dedicated contracts are better for now. its not that much boilerplate.
        CallbackData memory flashData = abi.decode(data, (CallbackData));

        migrate(
            sourceMarket,
            flashData.targetMarket,
            amount,
            flashData.amountBps
        );

        // crvUSD flash lender checks its balance, not transferFrom
        // we need to transfer the funds back directly
        IERC20(token).safeTransfer(msg.sender, amount);

        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    // TODO: what do we want to do here? we have `crvUsdAmount` of crvUSD to use
    function migrate(
        ResupplyPair sourceMarket,
        ResupplyPair targetMarket,
        uint256 crvUsdAmount,
        uint256 amountBps
    ) private {
        // capture collateral balance BEFORE any operations
        uint256 sourceCollateralBefore = sourceMarket.userCollateralBalance(
            address(this)
        );
        uint256 migratingCollateral = Math.mulDiv(
            sourceCollateralBefore,
            amountBps,
            10_000
        );

        // we need to know how much reUSD we currently have borrowed on sourceMarket
        uint256 sourceBorrowShares = sourceMarket.userBorrowShares(
            address(this)
        );

        // we might not be taking 100% of the position
        uint256 migratingBorrowShares = Math.mulDiv(
            sourceBorrowShares,
            amountBps,
            10_000
        );

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
        sourceMarket.removeCollateral(migratingCollateral, address(this));

        console.log("this", address(this));

        require(
            CRVUSD.balanceOf(address(this)) >= crvUsdAmount,
            "insufficient crvUSD"
        );
        console.log(
            "crvUSD balance after migrate:",
            CRVUSD.balanceOf(address(this))
        );

        // verify solvency on target market with 5% headroom
        uint256 finalBorrowShares = targetMarket.userBorrowShares(
            address(this)
        );
        uint256 finalBorrowAmount = targetMarket.toBorrowAmount(
            finalBorrowShares,
            true,
            false
        );
        uint256 finalCollateral = targetMarket.userCollateralBalance(
            address(this)
        );
        (, , uint256 targetExchangeRate) = targetMarket.exchangeRateInfo();
        uint256 targetExchangePrecision = targetMarket.EXCHANGE_PRECISION();
        uint256 ltvPrecision = targetMarket.LTV_PRECISION();
        uint256 maxLTV = targetMarket.maxLTV();

        // collateralValue = collateral * exchangePrecision / exchangeRate
        uint256 collateralValue = Math.mulDiv(
            finalCollateral,
            targetExchangePrecision,
            targetExchangeRate
        );
        // currentLTV = borrowAmount * ltvPrecision / collateralValue
        uint256 currentLTV = Math.mulDiv(
            finalBorrowAmount,
            ltvPrecision,
            collateralValue
        );
        // require 5% headroom: currentLTV <= maxLTV * 95 / 100
        require(
            currentLTV <= Math.mulDiv(maxLTV, 95, 100),
            "insufficient solvency headroom"
        );
    }

    function approveIfNecessary(
        IERC20 token,
        address spender,
        uint256 amount
    ) internal {
        if (token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, amount);
        }
    }
}
