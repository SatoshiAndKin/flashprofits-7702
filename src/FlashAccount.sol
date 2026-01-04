// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title FlashAccount
/// @notice Minimal EIP-7702 delegation target that lets a delegated EOA temporarily route `fallback()` to any target contract.
/// @dev This contract is meant to be executed as EOA code via EIP-7702 delegation (or `vm.etch` in tests).
contract FlashAccount is ERC721Holder, ERC1155Holder {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error NotSelfCall();
    error Reentrancy();

    // @dev Address slot (stored via transient storage) derived using EIP-1967-style `keccak256("...") - 1`,
    // with low-byte masking for alignment/namespacing.
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

        // Intentionally return to behave like an EOA for unknown selectors when no transient target is set.
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

    /// @notice Executes a call from the account itself, using a transient fallback implementation.
    /// @dev This only allow calls from the smart account itself!
    /// we can make more advanced auth for bots and keeper-like services later
    /// with `delegateCall` you can do literally anything. delegate call to a weiroll or multicall contract and do complex things
    /// we don't need `call` because we can just do that from the EOA directly. if we need more, we can make a different contract
    /// @dev Use by having {FlashAccount.fallback} route to `target` for one call, then calling this with
    /// `data` that encodes a function that exists on `target`.
    function transientExecute(address target, bytes calldata data) external returns (bytes memory) {
        address self = address(this);

        // checking both origin and sender is paranoid
        // i can imagine designs that have an approved "worker" for some contracts. This MVP is intentionally locked down
        // part of me wants to check tx.origin too, but that's breaking all my tests
        // NOTE: if we change auth to allow other workers, we also need to change this call to a delegatecall (which uses a tiny amount more gas)
        if (msg.sender != address(this)) revert NotSelfCall();

        TransientSlot.AddressSlot implSlot = _FALLBACK_IMPLEMENTATION_SLOT.asAddress();

        // it might be interesting to allow recursive transientExecutes, but I don't think its really necessary.
        if (implSlot.tload() != address(0)) {
            revert Reentrancy();
        }

        implSlot.tstore(target);

        // TODO: but that only matters if we change the auth
        bytes memory result = self.functionDelegateCall(data);

        // Clear the transient slot to allow future calls
        implSlot.tstore(address(0));

        return result;
    }

    // TODO: function that lets us add target functions to a mapping. let us opt into accounts calling arbitrary things. sexy but dangerous
}
