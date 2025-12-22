// SPDX-License-Identifier: UNLICENSED
// TODO: i can think of like 4 different ways to arrange this contract. just make it work, then make it right later.
// because i want to have dynamic amounts for migrations, its easier to have flashLoan and onFlashLoan in the same contract
pragma solidity ^0.8.30;

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
        IERC20 underlying = IERC20(_sourceMarket.underlying());
        require(
            address(collateral) == address(CRVUSD),
            "unexpected collateral"
        );
        require(address(underlying) == address(REUSD), "unexpected underlying");

        // the source and target markets have to match!
        require(address(collateral) == _targetMarket.collateral());
        require(address(underlying) == _targetMarket.underlying());

        // calculate flash loan size
        uint256 amount = Math.mulDiv(
            _sourceMarket.userCollateralBalance(address(this)),
            _amountBps,
            10_000
        );

        // TODO: encoding is more gas efficient to do off-chain, but it's really a pain in the butt to call these functions if we do that
        bytes memory data = abi.encode(
            CallbackData({targetMarket: _targetMarket})
        );

        // initiate flash loan. the rest happens in `onFlashLoan` after they send us tokens
        CRVUSD_FLASH_LENDER.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(CRVUSD),
            amount,
            data
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
        uint256 /*fee*/,
        bytes calldata data
    ) external virtual onlyDelegateCall returns (bytes32) {
        // we don't accept any flash loan unless we are expecting one
        // sourceMarket is only set during a flash loan entrypoint
        ResupplyPair sourceMarket = ResupplyPair(
            _SOURCE_MARKET_SLOT.asAddress().tload()
        );
        require(address(sourceMarket) != address(0), "no source market");

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

        migrate(sourceMarket, flashData.targetMarket, amount);

        // since we are using the crvUSD flash lender, it is always fee free
        // we need to approve them taking the funds back
        // theres not really a point in checking our balance because they will revert if we don't have enough
        if (IERC20(token).allowance(address(this), msg.sender) < amount) {
            IERC20(token).forceApprove(msg.sender, amount);
        }

        return ERC3156_FLASH_LOAN_SUCCESS;
    }

    // TODO: what do we want to do here? we have `crvUsdAmount` of crvUSD to use
    function migrate(
        ResupplyPair sourceMarket,
        ResupplyPair targetMarket,
        uint256 crvUsdAmount
    ) private {
        // TODO: we have these in constants already. this check is probably overkill
        IERC20 collateral = IERC20(sourceMarket.collateral());
        IERC20 underlying = IERC20(sourceMarket.underlying());

        // we need to know how much reUSD we currently have borrowed on sourceMarket
        uint256 sourceBorrowShares = sourceMarket.userBorrowShares(
            address(this)
        );

        uint256 sourceCollateral = sourceMarket.userCollateralBalance(
            address(this)
        );

        // we might not be taking 100% of the position
        uint256 migratingBorrowShares = Math.mulDiv(
            sourceBorrowShares,
            crvUsdAmount,
            sourceCollateral
        );

        uint256 targetBorrowAmount = sourceMarket.toBorrowAmount(
            migratingBorrowShares,
            // we round down because we don't want to take too much
            // TODO: need to think more about rounding though
            false,
            // we have `true` to make sure interest is updated
            true
        );

        // first, open a new loan using the flash loaned crvUSD as collateral
        approveIfNecessary(collateral, address(targetMarket), crvUsdAmount);
        // this returns shares, but i don't think we really care about the share count. maybe we should check it for slippage protection?
        targetMarket.borrow(targetBorrowAmount, crvUsdAmount, address(this));

        // now we have reUSD. repay the source loan
        approveIfNecessary(
            underlying,
            address(sourceMarket),
            targetBorrowAmount
        );
        sourceMarket.repay(migratingBorrowShares, address(this));

        // finally, remove the crvUSD collateral from the sourceMarket. this will be used to repay the flash loan
        sourceMarket.removeCollateral(crvUsdAmount, address(this));

        // TODO: make sure we have a good headroom on solvency
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
