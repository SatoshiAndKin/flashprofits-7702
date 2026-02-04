// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {LowLevelCall, Address, Errors} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @title FlashAccount
/// @notice Minimal EIP-7702 delegation target that lets a delegated EOA temporarily route `fallback()` to any target contract.
/// @dev This contract is meant to be executed as EOA code via EIP-7702 delegation (or `vm.etch` in tests).
contract FlashAccount is ERC721Holder, ERC1155Holder {
    using Address for address;
    using SafeERC20 for IERC20;

    error NotSelfCall();
    error Reentrancy();

    // @dev Address slot (stored via transient storage) derived using EIP-1967-style `keccak256("...") - 1`,
    // with low-byte masking for alignment/namespacing.
    // TODO: i think theres supposed to be a natspec comment on this for block explorers to read
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
        address impl;
        {
            bytes32 slot = _FALLBACK_IMPLEMENTATION_SLOT;
            assembly {
                impl := tload(slot)
            }
        }

        // Intentionally return to behave like an EOA for unknown selectors when no transient target is set.
        if (impl == address(0)) {
            return;
        }

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
    function transientExecute(address target, bytes calldata targetSelectorAndData) external {
        // checking both tx.origin and msg.sender is paranoid
        // i can imagine designs that have an approved "worker" for some contracts. This MVP is intentionally locked down
        // part of me wants to check tx.origin too, but that's breaking all my tests
        // NOTE: if we change auth to allow other workers, we also need to change this call to a delegatecall (which uses a tiny amount more gas)
        if (msg.sender != address(this)) revert NotSelfCall();

        bytes32 slot = _FALLBACK_IMPLEMENTATION_SLOT;
        assembly {
            tstore(slot, target)
        }

        // we don't actually care about returning from this. it just costs gas that we don't use
        bool success = LowLevelCall.delegatecallNoReturn(target, targetSelectorAndData);
        if (success) {
            // it worked! yey
        } else if (LowLevelCall.returnDataSize() > 0) {
            LowLevelCall.bubbleRevert();
        } else {
            revert Errors.FailedCall();
        }

        // Clear the transient slot
        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice Returns true if this contract supports the given interface.
    /// @dev Checks inherited interfaces first, then delegates to transient implementation if set.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        if (super.supportsInterface(interfaceId)) {
            return true;
        }

        address impl;
        {
            bytes32 slot = _FALLBACK_IMPLEMENTATION_SLOT;
            assembly {
                impl := tload(slot)
            }
        }

        if (impl == address(0)) {
            return false;
        }

        // Try calling supportsInterface on the transient implementation
        (bool success, bytes memory result) = impl.staticcall(
            abi.encodeWithSelector(this.supportsInterface.selector, interfaceId)
        );

        if (success && result.length > 0) {
            return abi.decode(result, (bool));
        }

        return false;
    }
}
