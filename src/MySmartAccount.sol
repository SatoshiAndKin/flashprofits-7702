// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title FlashAccount
/// @notice Minimal EIP-7702 delegation target that lets a delegated EOA run a single call path where
/// `msg.sender == address(this)` by temporarily routing `fallback()` to a transient implementation.
/// @dev This contract is meant to be executed as EOA code via EIP-7702 delegation (or `vm.etch` in tests).
contract FlashAccount is ERC721Holder, ERC1155Holder {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error NotSelfCall();
    error Reentrancy();

    // TODO: should this be for the namespace. then we add 1 to this for each new slot that we want?
    // TODO: openzeppelin has a helper for this, but i haven't learned how to use it yet
    // TODO: i wish solidity had constant functions that could do all this at compile time
    bytes32 internal constant _FALLBACK_IMPLEMENTATION_SLOT = keccak256(
        abi.encode(uint256(keccak256("flashprofits.eth.foundry-7702.FlashAccount.fallbackImplementation")) - 1)
    ) & ~bytes32(uint256(0xff));

    /// @notice Allows the delegated EOA/account to receive ETH.
    /// @dev Intentionally does not perform any authorization checks.
    receive() external payable {}

    /// @notice Delegates unknown calls to the transient implementation set by {transientExecute}.
    /// @dev If no transient implementation is set, this returns without reverting, making the account
    /// behave like an EOA for unknown selectors.
    fallback() external payable {
        address impl = _FALLBACK_IMPLEMENTATION_SLOT.asAddress().tload();

        // TODO: revert or return? this makes it act like an EOA
        if (impl == address(0)) {
            return;
        }

        // TODO: double check this. it lets us return data even though this function has no return type
        // this is some old cargo culting. its worked for me before.
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    // only allow calls from the smart account itself!
    // we can make more advanced auth for bots and keeper-like services later
    // with `delegateCall` you can do literally anything. delegate call to a weiroll or multicall contract and do complex things
    // we don't need `call` because we can just do that from the EOA directly. if we need more, we can make a different contract
    /// @notice Executes a call from the account itself, using a transient fallback implementation.
    /// @dev Expected usage: an external caller (EOA) triggers a call on the delegated account such that
    /// `msg.sender == address(this)` when this function runs (i.e. via EIP-7702 delegation).
    ///
    /// Flow:
    /// 1. Enforce `msg.sender == address(this)` (locked down by design).
    /// 2. Set a transient slot so {fallback} delegatecalls into `target`.
    /// 3. Perform `address(this).call(data)` via OZ Address.functionCall (so the *target* sees
    ///    `msg.sender == address(this)` and storage writes happen on this account).
    /// 4. Clear the transient slot.
    ///
    /// Reentrancy:
    /// - Reentrancy is prevented by requiring the transient implementation slot to be empty.
    /// - Any nested call back into {transientExecute} (directly or via {fallback}) reverts.
    ///
    /// @param target The contract whose code should be executed via `delegatecall` from {fallback}.
    /// @param data Calldata to send to `address(this)`; typically encodes a call to a function that only
    /// exists on `target`.
    /// @return Result bytes returned by the delegated execution.
    function transientExecute(address target, bytes calldata data) external returns (bytes memory) {
        address self = address(this);
        if (msg.sender != self) revert NotSelfCall();

        TransientSlot.AddressSlot implSlot = _FALLBACK_IMPLEMENTATION_SLOT.asAddress();

        if (implSlot.tload() != address(0)) {
            revert Reentrancy();
        }

        implSlot.tstore(target);

        // TODO: should we call this.call(data), or should we delegate call?
        // i think we want call so that the targets see msg.sender as this contract
        bytes memory result = self.functionCall(data);

        // Clear the transient slot to allow future calls
        implSlot.tstore(address(0));

        return result;
    }

    // TODO: function that lets us add target functions to a mapping
}
