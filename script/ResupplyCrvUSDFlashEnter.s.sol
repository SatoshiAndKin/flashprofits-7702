// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ResupplyCrvUSDFlashEnter, ResupplyConstants, ResupplyPair} from "../src/targets/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";

contract ResupplyCrvUSDFlashEnterScript is FlashAccountDeployerScript, ResupplyConstants {
    ResupplyCrvUSDFlashEnter public targetImpl;

    function setUp() public {
        _loadConfig("./deployments.toml", true);

        deployFlashAccount();

        // TODO: we use this pattern a lot. how do we clean it up?
        address enterAddr = config.get("resupply_crvUSD_flash_enter").toAddress();
        bytes32 expectedEnterCodeHash = keccak256(type(ResupplyCrvUSDFlashEnter).runtimeCode);
        if (enterAddr.codehash != expectedEnterCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            bytes32 salt = bytes32(0);

            vm.broadcast();
            targetImpl = new ResupplyCrvUSDFlashEnter{salt: salt}();

            config.set("resupply_crvUSD_flash_enter", address(targetImpl));
        } else {
            targetImpl = ResupplyCrvUSDFlashEnter(enterAddr);
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
        uint256 leverageBps = 13e4;
        uint256 goalHealthBps = 1.03e4;
        // TODO: this should probably have tighter slippage protection!
        uint256 minHealthBps = 1.02e4;

        // TODO: what are the units on this? i think 1e18 == 100%
        uint256 maxFeePct = 0.01e18;

        // TODO: find the best market to redeem
        ResupplyPair redeemMarket = market;

        bytes memory targetData = abi.encodeCall(
            targetImpl.flashLoan,
            (additionalCrvUsd, goalHealthBps, leverageBps, maxFeePct, minHealthBps, market, redeemMarket)
        );

        vm.broadcast();
        senderFlashAccount.transientExecute(address(targetImpl), targetData);
    }
}
