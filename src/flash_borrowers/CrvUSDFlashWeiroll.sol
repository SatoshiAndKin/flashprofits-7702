// SPDX-License-Identifier: UNLICENSED
// under construction. i think this will probably change a lot
pragma solidity ^0.8.30;

import {IERC3156FlashBorrower, IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VM} from "weiroll-foundry/VM.sol";

// TODO: we could make this generic for any 3156 lender. but crvusd isn't perfectly on spec. and its also always 0 fee
contract CrvUSDFlashWeiroll is IERC3156FlashBorrower, VM {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error FlashLoanFailed();
    error AlreadyInFlashLoan();
    error AlreadyInOnFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedLender();

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER = IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);

    struct CallbackData {
        bytes32[] commands;
        bytes[] state;
    }

    // TODO: do we really need these re-entrancy guards? better safe than sorry
    bytes32 internal constant _IN_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.CrvUSDFlashWeiroll.in_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    bytes32 internal constant _IN_ON_FLASHLOAN_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.CrvUSDFlashWeiroll.in_on_flashloan")) - 1)
    ) & ~bytes32(uint256(0xff));

    /// TODO: flash amount should be calculated from weiroll i think
    /// TODO: should we use subplans?
    function flashloan(bytes32[] calldata commands, bytes[] memory state) public virtual {
        address self = address(this);

        require(msg.sender == self);

        // re-entrancy protection
        TransientSlot.BooleanSlot in_flashloan = _IN_FLASHLOAN_SLOT.asBoolean();
        if (in_flashloan.tload()) revert AlreadyInFlashLoan();
        in_flashloan.tstore(true);

        // theres no fee, so we just always borrow the max amount
        // TODO: gas golf leaving 1 wei behind
        uint256 maxLoan = CRVUSD_FLASH_LENDER.maxFlashLoan(address(CRVUSD));

        // TODO: what should we encode? the commands and state? anything else?
        // TODO: this should probably be encoded offchain
        bytes memory data = abi.encode(CallbackData({commands: commands, state: state}));

        // TODO: always flash loan the FULL amount. that might make things simpler
        if (!CRVUSD_FLASH_LENDER.flashLoan(IERC3156FlashBorrower(self), address(CRVUSD), maxLoan, data)) {
            // TODO: i think this is impossible. i think it actually reverts instead of returns false
            revert FlashLoanFailed();
        }

        // end the re-entrancy protection
        in_flashloan.tstore(false);
    }

    bytes32 internal constant ERC3156_FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    function onFlashLoan(
        address initiator,
        address,
        /*token*/
        uint256,
        /*flashAmount*/
        uint256,
        /*fee*/
        bytes calldata data
    )
        external
        returns (bytes32)
    {
        // re-entrancy protection for onFlashLoan. probably overkill, but better safe than sorry
        TransientSlot.BooleanSlot in_on_flashloan = _IN_ON_FLASHLOAN_SLOT.asBoolean();
        if (in_on_flashloan.tload()) revert AlreadyInOnFlashLoan();
        in_on_flashloan.tstore(true);

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

        CallbackData memory d = abi.decode(data, (CallbackData));

        // TODO: i think we will save gas if we instead delegatecall to an existing contract
        // even though this contract will be optimized for our use, it will cost a lot to deploy. gas golf the difference
        _execute(d.commands, d.state);

        // end the re-entrancy protection
        in_on_flashloan.tstore(false);

        return ERC3156_FLASH_LOAN_SUCCESS;
    }
}
