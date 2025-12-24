// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {FlashAccount} from "../src/MySmartAccount.sol";

contract FlashAccountScript is Script {
    FlashAccount public account;

    /// @notice Script setup hook (unused).
    function setUp() public {}

    /// @notice Deploys a new FlashAccount implementation.
    /// @dev This is an implementation contract intended to be used as an EIP-7702 delegation target.
    function deploy() public {
        vm.startBroadcast();

        account = new FlashAccount();

        vm.stopBroadcast();
    }

    // EIP-7702 delegation using Foundry cheatcodes:
    // - `vm.signDelegation(implementation, authorityPk)` produces a signed authorization
    // - `vm.attachDelegation(signed)` attaches it to the *next* broadcasted tx
    //
    // Env:
    // - IMPLEMENTATION: address
    // - AUTHORITY_PK: uint256 (dev-only; do not use real keys)
    /// @notice Attaches an EIP-7702 delegation authorization using Foundry cheatcodes.
    /// @dev This is for development only (requires access to an authority private key).
    function delegate() public {
        address implementation = vm.envAddress("IMPLEMENTATION");
        uint256 authorityPk = vm.envUint("AUTHORITY_PK");

        Vm.SignedDelegation memory signed = vm.signDelegation(implementation, authorityPk);

        address authority = vm.addr(authorityPk);

        vm.startBroadcast();
        vm.attachDelegation(signed);

        // Send a no-op tx to make sure the authorization is included.
        (bool ok,) = authority.call{value: 0}("");
        require(ok, "delegate: tx failed");

        vm.stopBroadcast();
    }
}
