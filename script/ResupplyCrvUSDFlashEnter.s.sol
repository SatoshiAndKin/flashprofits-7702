// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ResupplyCrvUSDFlashEnter, ResupplyConstants, IResupplyPair} from "../src/targets/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ResupplyCrvUSDFlashEnterScript is FlashAccountDeployerScript, ResupplyConstants {
    ResupplyCrvUSDFlashEnter public targetImpl;

    IResupplyPair internal constant SDOLA_MARKET = IResupplyPair(0x27AB448a75d548ECfF73f8b4F36fCc9496768797);
    IResupplyPair internal constant WBTC_MARKET = IResupplyPair(0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D);
    uint256 internal constant REDEEM_PROBE_CRVUSD = 100_000e18;

    function setUp() public {
        setupFlashAccount();

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

    function bestRedeemMarket(IResupplyPair market, uint256 amount) public view returns (IResupplyPair bestMarket) {
        bestMarket = market;
        uint256 bestReturn;

        // TODO: include all the markets! is there an onchain registry?
        address[7] memory candidates = [
            0xC5184cccf85b81EDdc661330acB3E41bd89F34A1,
            0x27AB448a75d548ECfF73f8b4F36fCc9496768797,
            0x39Ea8e7f44E9303A7441b1E1a4F5731F1028505C,
            // 0x3b037329Ff77B5863e6a3c844AD2a7506ABe5706,  // deprecated
            // 0x08064A8eEecf71203449228f3eaC65E462009fdF,  // deprecated
            0x22B12110f1479d5D6Fd53D0dA35482371fEB3c7e,
            0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D,
            0xCF1deb0570c2f7dEe8C07A7e5FA2bd4b2B96520D,
            0x4A7c64932d1ef0b4a2d430ea10184e3B87095E33
        ];

        for (uint256 i; i < candidates.length; i++) {
            address candidate = candidates[i];

            try REDEMPTION_HANDLER.previewRedeem(candidate, amount) returns (
                uint256 returnedUnderlying, uint256, uint256 fee
            ) {
                console2.log("on", candidate);
                console2.log("- fee", fee);
                console2.log("- returnedUnderlying", returnedUnderlying);

                if (returnedUnderlying > bestReturn) {
                    bestReturn = returnedUnderlying;
                    bestMarket = IResupplyPair(candidate);
                }
            } catch {
                console2.log("unable to redeem against", candidate);
            }
        }

        console2.log("best market:", address(bestMarket));
    }

    /// @dev Env vars:
    /// - MARKET: One of the CURVELEND markets on <https://github.com/resupplyfi/resupply/blob/main/deployment/contracts.json>
    /// - more to come. things are mostly hard coded right now
    ///
    /// TODO: some env vars:
    /// - ADDITIONAL_CRVUSD_BPS for adding more collateral to a pair
    /// - LEVERAGE_BPS
    /// - GOAL_HEALTH_BPS
    /// - MIN_HEALTH_BPS
    /// - MAX_FEE_PCT (1e18 scaled?)
    function run() public {
        // TODO: take a percentage? a total?
        uint256 additionalCrvUsd = CRVUSD.balanceOf(msg.sender);

        IResupplyPair market = IResupplyPair(vm.envAddress("MARKET"));

        // TODO: don't hard code. these should be arguments
        // TODO: i feel like leverage and health are more related than I think. we want the max leverage that
        uint256 leverageBps = 13e4;
        uint256 goalHealthBps = 1.03e4;
        // TODO: this should probably have tighter slippage protection!
        uint256 minHealthBps = 1.01e4;

        // TODO: what are the units on this? i think 1e18 == 100%
        uint256 maxFeePct = 0.01e18;

        // TODO: this is not right. need to look at the current borrow
        uint256 expectedNewBorrow = Math.mulDiv(additionalCrvUsd, leverageBps, 1e4);
        // TODO: log with decimals
        console2.log("expectedNewBorrow:", expectedNewBorrow);

        IResupplyPair redeemMarket = bestRedeemMarket(market, expectedNewBorrow);

        bytes memory targetData = abi.encodeCall(
            targetImpl.flashLoan,
            (additionalCrvUsd, goalHealthBps, leverageBps, maxFeePct, minHealthBps, market, redeemMarket)
        );

        vm.broadcast();
        senderFlashAccount.transientExecute(address(targetImpl), targetData);
    }
}
