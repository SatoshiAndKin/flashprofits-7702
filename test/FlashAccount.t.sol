// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {FlashAccount} from "../src/FlashAccount.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

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
        uint256 initialBalance = alice.balance;
        uint256 sendAmount = 0.5 ether;

        vm.resetGasMetering();
        (bool success,) = payable(alice).call{value: sendAmount}("");
        vm.pauseGasMetering();

        require(success);
        assertEq(alice.balance, initialBalance + sendAmount);
    }

    function test_transientExecute_fromAccount() public {
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        vm.prank(alice);
        vm.resetGasMetering();
        bytes memory result = FlashAccount(payable(alice)).transientExecute(address(target), callData);
        vm.pauseGasMetering();

        assertEq(abi.decode(result, (uint256)), 42);
    }

    function test_transientExecute_revertsForUnauthorizedCaller() public {
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();

        vm.resetGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    function test_fallback_returnsWhenNoImplementation() public {
        bytes memory callData = abi.encodeWithSignature("nonExistentFunction()");

        vm.resetGasMetering();
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
        address worker = makeAddr("worker");

        vm.prank(alice);
        vm.resetGasMetering();
        FlashAccount(payable(alice)).addWorker(worker);
        vm.pauseGasMetering();

        assertTrue(FlashAccount(payable(alice)).workers(worker));
    }

    function test_addWorker_revertsForNonOwner() public {
        address worker = makeAddr("worker");
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resetGasMetering();
        FlashAccount(payable(alice)).addWorker(worker);
    }

    function test_addWorker_workerCannotAddOtherWorkers() public {
        address worker1 = makeAddr("worker1");
        address worker2 = makeAddr("worker2");

        // Owner adds worker1
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker1);

        // Worker1 tries to add worker2 - should fail
        vm.prank(worker1);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resetGasMetering();
        FlashAccount(payable(alice)).addWorker(worker2);
    }

    function test_removeWorker_fromOwner() public {
        address worker = makeAddr("worker");

        // Add worker first
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);
        assertTrue(FlashAccount(payable(alice)).workers(worker));

        vm.prank(alice);
        FlashAccount(payable(alice)).removeWorker(worker);

        assertFalse(FlashAccount(payable(alice)).workers(worker));
    }

    function test_removeWorker_workerCanRemoveSelf() public {
        address worker = makeAddr("worker");

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Worker removes themselves
        vm.prank(worker);
        FlashAccount(payable(alice)).removeWorker(worker);

        assertFalse(FlashAccount(payable(alice)).workers(worker));
    }

    function test_removeWorker_workerCannotRemoveOtherWorkers() public {
        address worker1 = makeAddr("worker1");
        address worker2 = makeAddr("worker2");

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker1);
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker2);

        // Worker1 tries to remove worker2 - should fail
        vm.prank(worker1);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resetGasMetering();
        FlashAccount(payable(alice)).removeWorker(worker2);
    }

    function test_removeWorker_nonWorkerCannotRemoveAnyone() public {
        address worker = makeAddr("worker");
        address attacker = makeAddr("attacker");

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Attacker tries to remove worker - should fail
        vm.prank(attacker);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resetGasMetering();
        FlashAccount(payable(alice)).removeWorker(worker);
    }

    // =========================================================================
    // Worker transientExecute Authorization Tests
    // =========================================================================

    function test_transientExecute_fromWorker() public {
        address worker = makeAddr("worker");
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Worker can call transientExecute
        vm.prank(worker);
        vm.resetGasMetering();
        bytes memory result = FlashAccount(payable(alice)).transientExecute(address(target), callData);
        vm.pauseGasMetering();

        assertEq(abi.decode(result, (uint256)), 42);
    }

    function test_transientExecute_fromWorker_withArgs() public {
        address worker = makeAddr("worker");
        bytes memory callData = abi.encodeCall(MockTarget.echo, (12345));

        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        vm.prank(worker);
        vm.resetGasMetering();
        bytes memory result = FlashAccount(payable(alice)).transientExecute(address(target), callData);
        vm.pauseGasMetering();

        assertEq(abi.decode(result, (uint256)), 12345);
    }

    function test_transientExecute_revertsForRemovedWorker() public {
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
        vm.resetGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    function test_transientExecute_revertsForNonWorkerAddress() public {
        address worker = makeAddr("worker");
        address randomAddress = makeAddr("random");
        bytes memory callData = abi.encodeCall(MockTarget.getValue, ());

        // Add a worker (not randomAddress)
        vm.prank(alice);
        FlashAccount(payable(alice)).addWorker(worker);

        // Random address cannot call even though a worker exists
        vm.prank(randomAddress);
        vm.expectRevert(FlashAccount.Unauthorized.selector);
        vm.resetGasMetering();
        FlashAccount(payable(alice)).transientExecute(address(target), callData);
    }

    function test_workers_returnsFalseForNonWorker() public {
        address nonWorker = makeAddr("nonWorker");

        vm.resetGasMetering();
        bool isWorker = FlashAccount(payable(alice)).workers(nonWorker);
        vm.pauseGasMetering();

        assertFalse(isWorker);
    }

    // =========================================================================
    // supportsInterface Tests
    // =========================================================================

    function test_supportsInterface_IERC165() public {
        bytes4 interfaceId = type(IERC165).interfaceId;

        vm.resetGasMetering();
        bool supported = FlashAccount(payable(alice)).supportsInterface(interfaceId);
        vm.pauseGasMetering();

        assertTrue(supported);
    }

    function test_supportsInterface_IERC721Receiver() public {
        // NOTE: ERC721Holder implements IERC721Receiver but does NOT advertise it via ERC165
        // This is OpenZeppelin's design - ERC721Holder doesn't inherit ERC165
        bytes4 interfaceId = type(IERC721Receiver).interfaceId;

        vm.resetGasMetering();
        bool supported = FlashAccount(payable(alice)).supportsInterface(interfaceId);
        vm.pauseGasMetering();

        assertFalse(supported);
    }

    function test_supportsInterface_IERC1155Receiver() public {
        bytes4 interfaceId = type(IERC1155Receiver).interfaceId;

        vm.resetGasMetering();
        bool supported = FlashAccount(payable(alice)).supportsInterface(interfaceId);
        vm.pauseGasMetering();

        assertTrue(supported);
    }

    function test_supportsInterface_unknownInterface() public {
        bytes4 unknownInterfaceId = bytes4(0xdeadbeef);

        vm.resetGasMetering();
        bool supported = FlashAccount(payable(alice)).supportsInterface(unknownInterfaceId);
        vm.pauseGasMetering();

        assertFalse(supported);
    }
}
