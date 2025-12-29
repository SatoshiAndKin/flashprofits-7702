// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {FlashAccount} from "../src/FlashAccount.sol";

contract FlashAccountScript is Script, Config {
    FlashAccount public flash_account;

    /// @notice Script setup hook (unused).
    function setUp() public {}

    /// @notice Deploys a new FlashAccount implementation.
    /// @dev This is an implementation contract intended to be used as an EIP-7702 delegation target.
    function deploy() public {
        _loadConfig("./deployments.toml", true);

        vm.startBroadcast();

        flash_account = new FlashAccount();

        vm.stopBroadcast();

        config.set("flash_account", address(flash_account));
    }
}
