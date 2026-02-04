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

    error Unauthorized();
    error Reentrancy();

    /// @custom:storage-location erc7201:eth.flashprofits-7702.FlashAccount
    struct FlashAccountStorage {
        mapping(address => bool) workers;
    }

    /// @dev Storage slot for FlashAccountStorage (and also for transient storage)
    bytes32 private constant FLASH_ACCOUNT_STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("eth.flashprofits-7702.FlashAccount")) - 1)) & ~bytes32(uint256(0xff));

    /// @notice Allows the delegated EOA/account to receive ETH.
    /// @dev Intentionally does not perform any authorization checks.
    receive() external payable {}

    /// @notice Delegates unknown calls to the transient implementation set by {transientExecute}.
    /// @dev If no transient implementation is set, this returns without reverting, making the account
    /// behave like an EOA for unknown selectors.
    fallback() external payable {
        address impl;
        {
            bytes32 slot = FLASH_ACCOUNT_STORAGE_SLOT;
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
            case 0 {
                // delegatecall returns 0 on error.
                revert(0, returndatasize())
            }
            default {
                // even though the fallback function doesn't have a listed return value, we use assembly to return
                return(0, returndatasize())
            }
        }
    }

    function _getFlashAccountStorage() private pure returns (FlashAccountStorage storage $) {
        bytes32 slot = FLASH_ACCOUNT_STORAGE_SLOT;

        assembly {
            $.slot := slot
        }
    }

    function _getWorker(address _worker) private view returns (bool) {
        FlashAccountStorage storage $ = _getFlashAccountStorage();
        return $.workers[_worker];
    }

    function _setWorker(address _worker, bool _isWorker) private {
        FlashAccountStorage storage $ = _getFlashAccountStorage();
        $.workers[_worker] = _isWorker;
    }

    /// @notice Check if caller is the EOA itself (via EIP-7702 delegation)
    /// @dev When an EOA sets this contract as its code and calls a function,
    ///      msg.sender == address(this) because the EOA is calling itself
    function _isOwner() private view returns (bool) {
        return msg.sender == address(this);
    }

    /// @notice allow a worker address to have full control of this contract.
    function addWorker(address _worker) external {
        require(_isOwner(), Unauthorized());

        _setWorker(_worker, true);
    }

    /// @notice allow the owner to remove a worker. a worker can also remove itself
    /// @dev The owner (EOA) is ALWAYS allowed, even if they aren't a worker. We don't want to accidentally get locked out!
    function removeWorker(address _worker) external {
        require(_isOwner() || (msg.sender == _worker && _getWorker(msg.sender)), Unauthorized());

        _setWorker(_worker, false);
    }

    /// @notice check if an address is an approved worker.
    function workers(address _worker) external view returns (bool) {
        return _getWorker(_worker);
    }

    /// @notice Returns true if this contract supports the given interface.
    /// @dev Checks inherited interfaces first, then delegates to transient implementation if set.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        if (super.supportsInterface(interfaceId)) {
            return true;
        }

        address impl;
        {
            bytes32 slot = FLASH_ACCOUNT_STORAGE_SLOT;
            assembly {
                impl := tload(slot)
            }
        }

        if (impl == address(0)) {
            return false;
        }

        // Try calling supportsInterface on the transient implementation
        // TODO: gas golf using a try block
        (bool success, bytes memory result) =
            impl.staticcall(abi.encodeWithSelector(this.supportsInterface.selector, interfaceId));

        if (success && result.length > 0) {
            return abi.decode(result, (bool));
        }

        return false;
    }

    /// @notice Executes a call from the account itself, using a transient fallback implementation.
    /// @dev This only allow calls from the smart account itself or from pre-approved workers.
    function transientExecute(address target, bytes calldata targetSelectorAndData) external returns (bytes memory) {
        require(_isOwner() || _getWorker(msg.sender), Unauthorized());

        bytes32 slot = FLASH_ACCOUNT_STORAGE_SLOT;
        assembly {
            tstore(slot, target)
        }

        bytes memory result = address(this).functionCall(targetSelectorAndData);

        // Clear the transient slot
        assembly {
            tstore(slot, 0)
        }

        return result;
    }
}
