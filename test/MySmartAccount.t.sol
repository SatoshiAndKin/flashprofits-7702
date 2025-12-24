// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MySmartAccount} from "../src/MySmartAccount.sol";

contract MockTarget {
    function getValue() external pure returns (uint256) {
        return 42;
    }

    function echo(uint256 x) external pure returns (uint256) {
        return x;
    }
}

contract MySmartAccountTest is Test {
    MySmartAccount internal implementation;
    MockTarget internal target;

    address internal alice;
    uint256 internal alicePk;

    function setUp() public {
        implementation = new MySmartAccount();
        target = new MockTarget();

        (alice, alicePk) = makeAddrAndKey("alice");
        vm.deal(alice, 1 ether);

        // Delegate alice's EOA to the MySmartAccount implementation
        vm.signAndAttachDelegation(address(implementation), alicePk);
        vm.prank(alice);
        (bool success, ) = alice.call("");
        require(success);
    }

    function test_account_can_receive() public {
        uint256 initialBalance = alice.balance;
        uint256 sendAmount = 0.5 ether;

        payable(alice).transfer(sendAmount);

        assertEq(alice.balance, initialBalance + sendAmount);
    }

    function test_transientExecute_fromAccount() public {
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        vm.prank(alice);
        bytes memory result = MySmartAccount(payable(alice)).transientExecute(
            address(target),
            callData
        );

        uint256 value = abi.decode(result, (uint256));
        assertEq(value, 42);
    }

    function test_transientExecute_revertsForUnauthorizedCaller() public {
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        MySmartAccount(payable(alice)).transientExecute(
            address(target),
            callData
        );
    }
}
