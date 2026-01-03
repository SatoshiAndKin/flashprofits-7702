// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ResupplyCrvUSDFlashMigrate} from "../src/targets/ResupplyCrvUSDFlashMigrate.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";
import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";

contract ResupplyCrvUSDFlashMigrateScript is FlashAccountDeployerScript, Test {
    ResupplyCrvUSDFlashMigrate public targetImpl;

    /// @notice Deploys a new ResupplyCrvUSDFlashMigrate implementation.
    function setUp() public {
        _loadConfig("./deployments.toml", true);

        address targetImplAddr = config.get("resupply_crvUSD_flash_migrate").toAddress();
        bytes32 expectedCodeHash = keccak256(type(ResupplyCrvUSDFlashMigrate).runtimeCode);
        if (targetImplAddr.codehash != expectedCodeHash) {
            // a deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            vm.broadcast();
            targetImpl = new ResupplyCrvUSDFlashMigrate();

            config.set("resupply_crvUSD_flash_migrate", address(targetImpl));
        } else {
            targetImpl = ResupplyCrvUSDFlashMigrate(payable(targetImplAddr));
        }
    }

    function deploy() public {
        // nothing to do here since the setup already does the deployment if necessary
    }

    /// @notice Executes a migration by calling FlashAccount.transientExecute on `msg.sender`.
    /// @dev Requires env vars:
    /// - SOURCE_MARKET, TARGET_MARKET: ResupplyPair addresses
    /// - AMOUNT_BPS: basis points to migrate (10_000 = 100%)
    /// TODO: i think AMOUNT_BPS actually needs to be COLLLATERAL_AMOUNT_BPSand BORROW_AMOUNT_BPS
    function run() public {
        deployFlashAccount();

        ResupplyPair sourceMarket = ResupplyPair(vm.envAddress("SOURCE_MARKET"));
        ResupplyPair targetMarket = ResupplyPair(vm.envAddress("TARGET_MARKET"));
        uint256 amountBps = vm.envUint("AMOUNT_BPS");

        assertLe(amountBps, 10_000);

        bytes memory targetData =
            abi.encodeCall(targetImpl.flashLoan, (sourceMarket, amountBps, targetMarket));

        vm.broadcast();
        senderFlashAccount.transientExecute(address(targetImpl), targetData);
    }
}
