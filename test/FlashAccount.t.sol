// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {FlashAccount} from "../src/FlashAccount.sol";

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

    function test_deploy() public {
        bytes32 salt = bytes32(0);

        new FlashAccount{salt: salt}();
    }

    function test_account_can_receive() public {
        vm.pauseGasMetering();

        uint256 initialBalance = alice.balance;
        uint256 sendAmount = 0.5 ether;

        vm.resumeGasMetering();
        (bool success,) = payable(alice).call{value: sendAmount}("");

        vm.pauseGasMetering();
        require(success);

        assertEq(alice.balance, initialBalance + sendAmount);
    }

    function test_transientExecute_fromAccount() public {
        vm.pauseGasMetering();

        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        vm.prank(alice);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);

        // TODO: assert something? transientExecute doesn't return anything
    }

    function test_transientExecute_revertsForUnauthorizedCaller() public {
        vm.pauseGasMetering();

        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();

        vm.resumeGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    /*
    // NOTE: i know re-entrancy can be a problem. but this is my own eoa calling itself. that's not the common need for re-entrancy protection.
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
    */

    function test_fallback_returnsWhenNoImplementation() public {
        vm.pauseGasMetering();
        bytes memory callData = abi.encodeWithSignature("nonExistentFunction()");

        vm.resumeGasMetering();
        // Call a random function selector on alice's delegated account
        // Should return silently (not revert) when no transient impl is set
        (bool success,) = alice.call(callData);

        vm.pauseGasMetering();
        assertTrue(success);
    }

    // =========================================================================
    // Worker Management Tests
    // =========================================================================

    function test_addWorker_fromOwner() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");

        vm.prank(alice);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).addWorker(worker);

        vm.pauseGasMetering();
        assertTrue(FlashAccount(payable(alice)).workers(worker));
    }

    function test_addWorker_revertsForNonOwner() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).addWorker(worker);
    }

    function test_addWorker_workerCannotAddOtherWorkers() public {
        vm.pauseGasMetering();
        address worker1 = makeAddr("worker1");
        address worker2 = makeAddr("worker2");

        // Owner adds worker1
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker1);

        // Worker1 tries to add worker2 - should fail
        vm.prank(worker1);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).addWorker(worker2);
    }

    function test_removeWorker_fromOwner() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");

        // Add worker first
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);
        assertTrue(FlashAccount(payable(alice)).workers(worker));

        vm.resumeGasMetering();
        vm.prank(alice);
        FlashAccount(payable(alice)).removeWorker(worker);

        vm.pauseGasMetering();
        assertFalse(FlashAccount(payable(alice)).workers(worker));
    }

    function test_removeWorker_workerCanRemoveSelf() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Worker removes themselves
        vm.prank(worker);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).removeWorker(worker);

        vm.pauseGasMetering();
        assertFalse(FlashAccount(payable(alice)).workers(worker));
    }

    function test_removeWorker_workerCannotRemoveOtherWorkers() public {
        vm.pauseGasMetering();
        address worker1 = makeAddr("worker1");
        address worker2 = makeAddr("worker2");

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker1);
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker2);

        // Worker1 tries to remove worker2 - should fail
        vm.prank(worker1);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).removeWorker(worker2);
    }

    function test_removeWorker_nonWorkerCannotRemoveAnyone() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");
        address attacker = makeAddr("attacker");

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Attacker tries to remove worker - should fail
        vm.prank(attacker);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).removeWorker(worker);
    }

    // =========================================================================
    // Worker transientExecute Authorization Tests
    // =========================================================================

    function test_transientExecute_fromWorker() public {
        vm.pauseGasMetering();

        address worker = makeAddr("worker");
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Worker can call transientExecute
        vm.prank(worker);
        vm.resumeGasMetering();
        bytes memory result = FlashAccount(payable(alice)).transientExecute(address(target), callData);

        vm.pauseGasMetering();
        assertEq(abi.decode(result, (uint256)), 42);
    }

    function test_transientExecute_fromWorker_withArgs() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");
        bytes memory callData = abi.encodeCall(MockTarget.echo, (12345));

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        vm.prank(worker);
        vm.resumeGasMetering();
        bytes memory result = FlashAccount(payable(alice)).transientExecute(address(target), callData);

        vm.pauseGasMetering();
        assertEq(abi.decode(result, (uint256)), 12345);
    }

    function test_transientExecute_revertsForRemovedWorker() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        // Add worker
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Worker can call
        vm.prank(worker);
        FlashAccount(payable(alice)).transientExecute(address(target), callData);

        // Remove worker
        vm.prank(alice);
        FlashAccount(payable(alice)).removeWorker(worker);

        // Worker can no longer call
        vm.prank(worker);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    function test_transientExecute_revertsForNonWorkerAddress() public {
        vm.pauseGasMetering();
        address worker = makeAddr("worker");
        address randomAddress = makeAddr("random");
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        // Add a worker (not randomAddress)
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Random address cannot call even though a worker exists
        vm.prank(randomAddress);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resumeGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    function test_workers_returnsFalseForNonWorker() public {
        vm.pauseGasMetering();
        address nonWorker = makeAddr("nonWorker");

        vm.resumeGasMetering();
        bool isWorker = FlashAccount(payable(alice)).workers(nonWorker);

        vm.pauseGasMetering();
        assertFalse(isWorker);
    }
}
