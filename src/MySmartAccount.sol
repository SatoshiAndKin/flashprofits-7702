// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {
    IERC20,
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ERC721Holder
} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {
    ERC1155Holder
} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

// this contract is meant to be a target for an EIP 7702 delegation
contract MySmartAccount is ERC721Holder, ERC1155Holder {
    using Address for address;
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    error NotSelfCall();
    error Reentrancy();

    // TODO: should this be for the namespace. then we add 1 to this for each new slot that we want?
    // TODO: openzeppelin has a helper for this, but i haven't learned how to use it yet
    // TODO: i wish solidity had constant functions that could do all this at compile time
    bytes32 internal constant _FALLBACK_IMPLEMENTATION_SLOT =
        keccak256(
            abi.encode(
                uint256(
                    keccak256(
                        "flashprofits.eth.foundry-7702.MySmartAccount.fallbackImplementation"
                    )
                ) - 1
            )
        ) & ~bytes32(uint256(0xff));

    // allow receiving ETH
    receive() external payable {
        // TODO: delegate-only check?
    }

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
    function transientExecute(
        address target,
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(this)) revert NotSelfCall();

        if (_FALLBACK_IMPLEMENTATION_SLOT.asAddress().tload() != address(0)) {
            revert Reentrancy();
        }

        _FALLBACK_IMPLEMENTATION_SLOT.asAddress().tstore(target);

        // TODO: should we call this.call(data), or should we delegate call?
        // i think we want call so that the targets see msg.sender as this contract
        bytes memory result = address(this).functionCall(data);

        // Clear the transient slot to allow future calls
        _FALLBACK_IMPLEMENTATION_SLOT.asAddress().tstore(address(0));

        return result;
    }

    // TODO: function that lets us add target functions to a mapping
}
