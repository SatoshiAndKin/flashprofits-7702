// SPDX-License-Identifier: UNLICENSED
// TODO: these should probably be immutables instead of constants, but this is easier. we only care about ETH network here
// TODO: i kind of want to move this into src/targets/resupply/
pragma solidity ^0.8.4;

import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IResupplyRedemptionHandler} from "../interfaces/resupply/IResupplyRedemptionHandler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";

abstract contract ResupplyConstants {
    ICurvePool internal constant CURVE_REUSD_SCRVUSD = ICurvePool(0xc522A6606BBA746d7960404F22a3DB936B6F4F50);
    uint8 internal constant CURVE_REUSD_COIN_ID = 0;
    uint8 internal constant CURVE_SCRVUSD_COIN_ID = 1;

    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);

    IERC3156FlashLender constant CRVUSD_FLASH_LENDER = IERC3156FlashLender(0x26dE7861e213A5351F6ED767d00e0839930e9eE1);

    IERC4626 internal constant SCRVUSD = IERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);

    IResupplyRedemptionHandler constant REDEMPTION_HANDLER =
        IResupplyRedemptionHandler(0x99999999A5Dc4695EF303C9EA9e4B3A19367Ed94);
}

