// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {ResupplyCrvUSDFlashEnter, ResupplyConstants, ResupplyPair} from "../src/transients/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccount} from "../src/FlashAccount.sol";

contract ResupplyCrvUSDFlashEnterScript is Script, Config, ResupplyConstants {
    ResupplyCrvUSDFlashEnter public enterImpl;

    function setUp() public {
        _loadConfig("./deployments.toml", true);

        if (config.exists("resupply_crvUSD_flash_enter")) {
            enterImpl = ResupplyCrvUSDFlashEnter(config.get("resupply_crvUSD_flash_enter").toAddress());
        } else {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            vm.broadcast();
            enterImpl = new ResupplyCrvUSDFlashEnter();

            config.set("resupply_crvUSD_flash_enter", address(enterImpl));
        }
    }

    /// @dev Env vars:
    /// - MARKET: One of the CURVELEND markets on <https://github.com/resupplyfi/resupply/blob/main/deployment/contracts.json>
    /// - more to come. things are mostly hard coded right now
    function run() public {
        // TODO: take a percentage? a total?
        uint256 initialCrvUsdAmount = CRVUSD.balanceOf(msg.sender);

        ResupplyPair market = ResupplyPair(vm.envAddress("MARKET"));

        // TODO: don't hard code. these should be arguments
        // TODO: i feel like leverage and health are more related than I think. we want the max leverage that 
        uint256 leverageBps = 12.5e4;
        uint256 goalHealthBps = 1.04e4;
        // TODO: this should probably have tighter slippage protection!
        uint256 minHealthBps = 1.03e4;

        bytes memory data = abi.encodeCall(
            enterImpl.flashLoan,
            (
                initialCrvUsdAmount,
                market,
                leverageBps,
                goalHealthBps,
                minHealthBps
            )
        );

        vm.broadcast();
        FlashAccount(payable(msg.sender)).transientExecute(address(enterImpl), data);
    }
}
