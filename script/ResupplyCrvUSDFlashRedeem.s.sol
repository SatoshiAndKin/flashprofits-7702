// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// if reUSD is under the redemption price, we should flash crvUSD (or similar), trade it to reUSD, redeem
// we should only redeem markets that we are not a part of. redeeming against our own market reduces our income
// how do we calculate optimal amounts on this? seems like we just need to make the cycle and then throw a bunch of steps at it. but maybe there is a formula?

import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
// import {ResupplyCrvUSDFlashRedeem, IResupplyPair} from "../src/targets/resupply/ResupplyCrvUSDFlashRedeem.sol";
import {ResupplyHelpers} from "./ResupplyHelpers.sol";
import {CrvUSDFlashWeiroll} from "../src/targets/CrvUSDFlashWeiroll.sol";
import {console} from "forge-std/console.sol";

contract ResupplyCrvUSDFlashRedeemScript is FlashAccountDeployerScript, ResupplyHelpers {
    CrvUSDFlashWeiroll public targetImpl;

    function setUp() public {
        setupFlashAccount();

        // TODO: we use this pattern a lot. how do we clean it up?
        address targetAddr = config.get("target_crvUSD_flash_weiroll").toAddress();
        bytes32 expectedEnterCodeHash = keccak256(type(CrvUSDFlashWeiroll).runtimeCode);
        if (targetAddr.codehash != expectedEnterCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            bytes32 salt = bytes32(0);

            vm.broadcast();
            targetImpl = new CrvUSDFlashWeiroll{salt: salt}();

            config.set("target_crvUSD_flash_weiroll", address(targetImpl));
        } else {
            targetImpl = CrvUSDFlashWeiroll(targetAddr);
        }
    }

    function run() public {
        /*
        // TODO: i think maybe doing the plan building in a forge script isn't an expected design
        1. we flash borrow crvusd
        2. we trade crvUSD to reUSD
        3. we redeem reUSD against some market that we aren't in
        4. repay flash loan
        */

        // TODO: make a real weiroll plan here
        bytes32[] calldata commands;
        bytes[] memory state;

        bytes memory targetData = abi.encodeCall(targetImpl.flashLoan, (commands, state));

        // TODO: What safety checks should

        vm.broadcast();
        senderFlashAccount.transientExecute(address(targetImpl), targetData);

        revert("wip");
    }
}
