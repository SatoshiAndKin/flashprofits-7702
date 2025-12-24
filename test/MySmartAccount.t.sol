// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {FlashAccount} from "../src/MySmartAccount.sol";

contract MockTarget {
    function getValue() external pure returns (uint256) {
        return 42;
    }

    function echo(uint256 x) external pure returns (uint256) {
        return x;
    }
}

contract ReentrantTarget {
    address public target;
    bytes public callData;

    function setReentrantCall(address _target, bytes calldata _data) external {
        target = _target;
        callData = _data;
    }

    function attack() external {
        FlashAccount(payable(msg.sender)).transientExecute(target, callData);
    }
}

contract FlashAccountTest is Test {
    FlashAccount internal implementation;
    MockTarget internal target;

    address internal alice;
    uint256 internal alicePk;

    function setUp() public {
        implementation = new FlashAccount();
        target = new MockTarget();

        (alice, alicePk) = makeAddrAndKey("alice");
        vm.deal(alice, 1 ether);

        // Delegate alice's EOA to the FlashAccount implementation
        vm.signAndAttachDelegation(address(implementation), alicePk);
        vm.prank(alice);
        (bool success,) = alice.call("");
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
        bytes memory result = FlashAccount(payable(alice)).transientExecute(address(target), callData);

        uint256 value = abi.decode(result, (uint256));
        assertEq(value, 42);
    }

    function test_transientExecute_revertsForUnauthorizedCaller() public {
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    function test_transientExecute_preventsReentrancy() public {
        ReentrantTarget reentrant = new ReentrantTarget();

        // Setup: reentrant contract will try to call transientExecute again
        bytes memory innerCall = abi.encodeCall(MockTarget.getValue, ());
        reentrant.setReentrantCall(address(target), innerCall);

        // Outer call triggers attack() which tries to reenter transientExecute
        bytes memory outerCall = abi.encodeCall(ReentrantTarget.attack, ());

        vm.prank(alice);
        vm.expectRevert(FlashAccount.Reentrancy.selector);
        FlashAccount(payable(alice)).transientExecute(address(reentrant), outerCall);
    }

    function test_fallback_returnsWhenNoImplementation() public {
        // Call a random function selector on alice's delegated account
        // Should return silently (not revert) when no transient impl is set
        (bool success,) = alice.call(abi.encodeWithSignature("nonExistentFunction()"));
        assertTrue(success);
    }
}
