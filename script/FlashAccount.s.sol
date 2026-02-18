// SPDX-License-Identifier: MIT or Apache-2.0
// Deploy the flash account contract. Other scripts will use the account.
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {FlashAccount} from "../src/FlashAccount.sol";

/// @dev common pieces for any script that uses a FlashAccount
abstract contract FlashAccountDeployerScript is Script, Config {
    FlashAccount public flashAccountImpl;
    FlashAccount public senderFlashAccount;

    /// @dev be sure to call `_loadConfig("./deployments.toml", true);` first
    function deployFlashAccount() public {
        address flashAccountAddr = config.get("flash_account").toAddress();
        bytes32 expectedCodeHash = keccak256(type(FlashAccount).runtimeCode);
        if (flashAccountAddr.codehash != expectedCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            // NOTE: deploying with a salt costs more gas!
            bytes32 salt = bytes32(0);

            vm.broadcast();
            flashAccountImpl = new FlashAccount{salt: salt}();

            config.set("flash_account", address(flashAccountImpl));
        } else {
            flashAccountImpl = FlashAccount(payable(config.get("flash_account").toAddress()));
        }
    }

    /// TODO: prod needs a more complex design
    function delegateFlashAccount() public {
        /// on a forked network, we can check the sender's code and do vm.etch
        bytes32 expectedCodeHash = keccak256(type(FlashAccount).runtimeCode);
        if (msg.sender.codehash != expectedCodeHash) {
            // TODO: this should error in production
            vm.etch(msg.sender, address(flashAccountImpl).code);
        }

        // this isn't really necessary, but it saves some typing
        senderFlashAccount = FlashAccount(payable(msg.sender));
    }

    function setupFlashAccount() public {
        _loadConfig("./deployments.toml", true);

        deployFlashAccount();
        delegateFlashAccount();
    }
}

contract FlashAccountScript is FlashAccountDeployerScript {
    /// @notice Script setup hook (unused).
    function setUp() public {
        _loadConfig("./deployments.toml", true);
    }

    /// @notice the default `run` script deploys the contract
    function run() public {
        deployFlashAccount();
    }

    /// @notice DEVELOPMENT-ONLY delegate to the contract (deploying only if necessary)
    function delegate() public {
        deployFlashAccount();
        delegateFlashAccount();
    }
}
