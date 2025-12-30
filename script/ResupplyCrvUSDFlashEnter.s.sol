// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {
    ResupplyCrvUSDFlashEnter,
    ResupplyConstants,
    ResupplyPair
} from "../src/transients/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccount} from "../src/FlashAccount.sol";

contract ResupplyCrvUSDFlashEnterScript is Script, Config, ResupplyConstants {
    ResupplyCrvUSDFlashEnter public enterImpl;
    FlashAccount public flashAccountImpl;

    function setUp() public {
        _loadConfig("./deployments.toml", true);

        address flashAccountAddr = config.get("flash_account").toAddress();
        bytes32 expectedFlashAccountCodeHash = keccak256(type(FlashAccount).runtimeCode);
        if (flashAccountAddr.codehash != expectedFlashAccountCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            vm.broadcast();
            flashAccountImpl = new FlashAccount();

            config.set("flash_account", address(flashAccountImpl));
        } else {
            flashAccountImpl = FlashAccount(payable(config.get("flash_account").toAddress()));
        }

        // TODO: on a forked network, we can check the sender's code and do vm.etch. prod needs a more complex design
        if (msg.sender.codehash != expectedFlashAccountCodeHash) {
            vm.etch(msg.sender, address(flashAccountImpl).code);
        }

        address enterAddr = config.get("resupply_crvUSD_flash_enter").toAddress();
        bytes32 expectedEnterCodeHash = keccak256(type(ResupplyCrvUSDFlashEnter).runtimeCode);
        if (enterAddr.codehash != expectedEnterCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            vm.broadcast();
            enterImpl = new ResupplyCrvUSDFlashEnter();

            config.set("resupply_crvUSD_flash_enter", address(enterImpl));
        } else {
            enterImpl = ResupplyCrvUSDFlashEnter(enterAddr);
        }
    }

    /// @dev Env vars:
    /// - MARKET: One of the CURVELEND markets on <https://github.com/resupplyfi/resupply/blob/main/deployment/contracts.json>
    /// - more to come. things are mostly hard coded right now
    function run() public {
        // TODO: take a percentage? a total?
        uint256 additionalCrvUsd = CRVUSD.balanceOf(msg.sender);

        ResupplyPair market = ResupplyPair(vm.envAddress("MARKET"));

        // TODO: don't hard code. these should be arguments
        // TODO: i feel like leverage and health are more related than I think. we want the max leverage that
        uint256 leverageBps = 12.5e4;
        uint256 goalHealthBps = 1.04e4;
        // TODO: this should probably have tighter slippage protection!
        uint256 minHealthBps = 1.03e4;

        // TODO: what are the units on this?
        uint256 maxFeePct = 1e18;

        // TODO: find the best market to redeem
        ResupplyPair redeemMarket = market;

        bytes memory data = abi.encodeCall(
            enterImpl.flashLoan,
            (additionalCrvUsd, goalHealthBps, leverageBps, maxFeePct, minHealthBps, market, redeemMarket)
        );

        vm.broadcast();
        FlashAccount(payable(msg.sender)).transientExecute(address(enterImpl), data);
    }
}
