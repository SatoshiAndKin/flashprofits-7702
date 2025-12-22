// SPDX-License-Identifier: UNLICENSED
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
import {DelegateCallOnly} from "../abstract/DelegateCallOnly.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

// TODO: make this work specifically to the crvUSD markets. then make it more generic in the next version. don't get ahead of myself.
contract ResupplyCrvUSDFlashMigrate is DelegateCallOnly {
    using TransientSlot for *;

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER =
        IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);

    // probably unnecessary safety. but i want to be extra secure.
    // TODO: i want to use openzeppelin's helper, but it isn't constant
    bytes32 internal constant _IN_FLASHLOAN_SLOT =
        keccak256(
            abi.encode(
                uint256(
                    keccak256(
                        "flashprofits.eth.foundry-7702.ResupplyCrvUSDFlashMigrate.fallbackImplementation"
                    )
                ) - 1
            )
        ) & ~bytes32(uint256(0xff));

    struct CallbackData {
        address sourceMarket;
        address targetMarket;
        uint256 amount;
    }

    function flashLoan(
        address sourceMarket,
        address targetMarket,
        uint256 amount_bps
    ) external onlyDelegateCall {
        // TODO: more open auth is an option for the future. keep it locked down for now
        require(msg.sender == address(this), "unauthorized");

        // TODO: wrong. this shouldn't be balanceOf. this should be a query against the sourceMarket
        uint256 amount = Math.mulDiv(
            IERC20(sourceMarket).balanceOf(sourceMarket),
            amount_bps,
            10_000
        );

        CallbackData memory data = CallbackData({
            sourceMarket: sourceMarket,
            targetMarket: targetMarket,
            amount: amount
        });

        // this is probably overkill security. but better safe than sorry.
        _IN_FLASHLOAN_SLOT.asBoolean().tstore(true);

        CRVUSD_FLASH_LENDER.flashLoan(
            IERC3156FlashBorrower(address(this)),
            address(CRVUSD),
            amount,
            abi.encode(data)
        );
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external onlyDelegateCall returns (bytes32) {
        require(
            msg.sender == address(CRVUSD_FLASH_LENDER),
            "unauthorized flash loan callback"
        );

        CallbackData memory flashData = abi.decode(data, (CallbackData));

        // TODO: we need to actually do things here!

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
