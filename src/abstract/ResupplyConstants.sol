// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {RedemptionHandler} from "../interfaces/RedemptionHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract ResupplyConstants {
    IERC3156FlashLender constant CRVUSD_FLASH_LENDER = IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);
    RedemptionHandler constant REDEMPTION_HANDLER = RedemptionHandler(0x99999999A5Dc4695EF303C9EA9e4B3A19367Ed94);
}
