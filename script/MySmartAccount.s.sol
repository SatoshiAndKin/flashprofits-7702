// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {MySmartAccount} from "../src/MySmartAccount.sol";

contract MySmartAccountScript is Script {
    // TODO: whats a better name than MySmartAccount?
    MySmartAccount public account;

    function setUp() public {}

    function deploy() public {
        vm.startBroadcast();

        account = new MySmartAccount();

        vm.stopBroadcast();
    }

    // EIP-7702 delegation using Foundry cheatcodes:
    // - `vm.signDelegation(implementation, authorityPk)` produces a signed authorization
    // - `vm.attachDelegation(signed)` attaches it to the *next* broadcasted tx
    //
    // Env:
    // - IMPLEMENTATION: address
    // - AUTHORITY_PK: uint256 (dev-only; do not use real keys)
    function delegate() public {
        address implementation = vm.envAddress("IMPLEMENTATION");
        uint256 authorityPk = vm.envUint("AUTHORITY_PK");

        Vm.SignedDelegation memory signed = vm.signDelegation(
            implementation,
            authorityPk
        );

        address authority = vm.addr(authorityPk);

        vm.startBroadcast();
        vm.attachDelegation(signed);

        // Send a no-op tx to make sure the authorization is included.
        (bool ok, ) = authority.call{value: 0}("");
        require(ok, "delegate: tx failed");

        vm.stopBroadcast();
    }
}
