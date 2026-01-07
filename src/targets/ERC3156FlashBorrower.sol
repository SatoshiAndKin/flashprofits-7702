// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ERC3156 flash borrowing smart contract (for use with EIP 7702 delegations).
contract ERC3156FlashBorrower is IERC3156FlashBorrower {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error FlashLoanFailed();
    error AlreadyInFlashLoan();
    error AlreadyInOnFlashLoan();
    error UnauthorizedFlashLoanCallback();
    error UnauthorizedLender();

    // TODO: need tests to make sure this packs correctly
    enum RepayMode {
        Approve,
        Transfer,
        Noop
    }

    // @dev Address slot (stored via transient storage) derived using EIP-1967-style `keccak256("...") - 1`,
    // with low-byte masking for alignment/namespacing.
    bytes32 internal constant _TSLOT_LENDER = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ERC3156FlashBorrower.lender")) - 1)
    ) & ~bytes32(uint256(0xff));

    // @dev Address slot (stored via transient storage) derived using EIP-1967-style `keccak256("...") - 1`,
    // with low-byte masking for alignment/namespacing.
    bytes32 internal constant _TSLOT_TARGET_DATA = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.ERC3156FlashBorrower.targetData")) - 1)
    ) & ~bytes32(uint256(0xff));

    bytes32 internal constant _ON_FLASH_LOAN_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Delegate-only function to initiate a flash loan with an ERC3156FlashLender
    /// @dev ERC3156FlashLender requires repayLender to be False (following the official spec)
    /// @dev Bentobox works if you set repayLender to True (not following the spec)
    function flashloan(
        IERC3156FlashLender lender,
        address token,
        address onFlashloanTarget,
        address target,
        RepayMode repayMode,
        bytes calldata targetSelectorAndData
    ) external payable {
        // TODO: use OZ's transient library here
        bytes32 tslotLender = _TSLOT_LENDER;
        bytes32 tslotTargetData = _TSLOT_TARGET_DATA;

        // TODO: if tslotLender is non-zero, throw reentrancy error

        // back the target address with repayment settings
        // repayLender is the least significant bit of the 21st byte
        bytes32 packedTargetData = bytes32(uint256(uint160(target))) | bytes32(uint256(repayMode)) << 160;

        assembly {
            tstore(tslotLender, lender)
            tstore(tslotTargetData, packedTargetData)
        }

        // always flash loaning the maximum amount simplifies things. but i think it might also sometimes cost us 1 more transfer event
        // the simplicity makes it worthwhile
        uint256 flashAmount = lender.maxFlashLoan(token);

        // an ERC3156FlashLender will transfer us tokens and then call our "onFlashLoan" function
        // returns True on success, and reverts on failure
        require(lender.flashLoan(this, token, flashAmount, targetSelectorAndData), "flashLoan failed");
    }

    /**
     * @dev Receive a flash loan.
     * @param initiator The initiator of the loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param fee The additional amount of tokens to repay.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan"
     */
    /// @dev we do not have a choice about this function's name. It comes from ERC3156
    /// @dev check the lender. for most, you MUST approve the flash borrower to pull the borrowed amounts + fees!
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata targetSelectorAndData
    ) external returns (bytes32) {
        // we could get by with just the tstore checks, but lets be extra careful and check the initiator
        require(initiator == address(this), "unexpected initiator");

        address lender;
        bytes32 packedTargetData;

        {
            bytes32 tslotLender = _TSLOT_LENDER;
            bytes32 tslotTargetData = _TSLOT_TARGET_DATA;

            assembly {
                lender := tload(tslotLender)
                packedTargetData := tload(tslotTargetData)
            }
        }

        // TODO: re-entrancy check here?

        // this security check is probably not necessary, but thats how security checks always feel
        require(msg.sender == lender, "unexpected lender");

        // unpack packedTargetData
        address target = address(uint160(uint256(packedTargetData)));
        RepayMode repayMode = RepayMode((uint256(packedTargetData) >> 160) & 0xFF);

        // do anything with the flash loaned tokens
        // TODO: i really dislike nested bytes encodings. but i dont see another way to pass token, amount, fee through. maybe something with weiroll?
        // i don't love nested encoded bytes, but we want these contracts to be generic (we already have a specific one that works)
        target.functionDelegateCall(targetSelectorAndData);

        // depending on the lender, this needs to approve `amount + fee` or it needs to the transfer.
        // TODO: does solidity have a switch
        if (repayMode == RepayMode.Approve) {
            // approve if necessary
            // this conforms with the official spec
            // TODO: gas golf caching amount + fee
            if (IERC20(token).allowance(address(this), lender) < amount + fee) {
                // infinite approvals are scary.
                // TODO: gas golf adding 1 wei to this
                IERC20(token).forceApprove(lender, amount + fee);
            }
        } else if (repayMode == RepayMode.Transfer) {
            // transfer tokens to the lender
            // this isn't the ERC3156 spec, but it is what Curve and Bentobox require
            IERC20(token).safeTransfer(lender, amount + fee);
        } else {
            // don't do anything.
            // common cases:
            // - the value was already transfered by one of the commands in the the delegate call above
            //   - this is probably uncommon because they don't know the exact flash loan amount. i wish there was a good way to inject that somewhere
            // - there is already sufficient approvals
        }

        return _ON_FLASH_LOAN_SUCCESS;
    }
}
