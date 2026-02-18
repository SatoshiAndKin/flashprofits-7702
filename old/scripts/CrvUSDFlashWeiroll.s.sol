// SPDX-License-Identifier: MIT or Apache-2.0
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {FlashAccount} from "../src/FlashAccount.sol";
import {FlashAccountDeployerScript} from "./FlashAccount.s.sol";
import {CrvUSDFlashWeiroll} from "../src/flash_borrowers/CrvUSDFlashWeiroll.s.sol";

/// @dev common pieces for any script that uses a FlashAccount
abstract contract CrvUSDFlashWeirollDeployerScript is FlashAccountDeployerScript {
    CrvUSDFlashWeiroll public crvUSDFlashWeirollImpl;

    /// @dev be sure to call `_loadConfig("./deployments.toml", true);` first
    function deployCrvUSDFlashTarget() public {
        // TODO: should this have "target_" as a prefix?
        address targetAddr = config.get("crvUSD_flash_weiroll").toAddress();
        bytes32 expectedCodeHash = keccak256(type(CrvUSDFlashWeiroll).runtimeCode);
        if (targetAddr.codehash != expectedCodeHash) {
            // deploy is needed!

            // TODO: calculate (and cache) a salt that gets a cool address!
            bytes32 salt = bytes32(0);

            vm.broadcast();
            crvUSDFlashWeirollImpl = new CrvUSDFlashWeiroll{salt: salt}();

            config.set("crvUSD_flash_weiroll", address(flashAccountImpl));
        } else {
            crvUSDFlashWeirollImpl = CrvUSDFlashWeiroll(payable(config.get("flash_account").toAddress()));
        }
    }

    function setupCrvUSDFlashWeirollTarget() public {
        _loadConfig("./deployments.toml", true);

        setupFlashAccount();
        deployCrvUSDFlashTarget();
    }
}

contract CrvUSDFlashWeirollScript is CrvUSDFlashWeirollDeployerScript {
    /// @notice Script setup hook (unused).
    function setUp() public {
        _loadConfig("./deployments.toml", true);
    }

    /// @notice the default `run` script deploys the contract
    function run() public {
        deployCrvUSDFlashTarget();
    }

    /// @notice DEVELOPMENT-ONLY delegate to the contract (deploying only if necessary)
    function delegate() public {
        deployFlashAccount();
        delegateFlashAccount();

        deployCrvUSDFlashTarget();
    }
}
