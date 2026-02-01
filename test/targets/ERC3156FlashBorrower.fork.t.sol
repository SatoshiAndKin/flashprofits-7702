// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import {FlashAccount} from "src/FlashAccount.sol";
import {ERC3156FlashBorrower, IERC3156FlashLender} from "src/targets/ERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {IWeirollVM} from "src/interfaces/IWeirollVM.sol";

// import {console} from "forge-std/console.sol";

contract ERC3156FlashBorrowerForkTest is Test {
    address alice;
    uint256 alicePk;

    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant CRVUSD_FLASH_LENDER = 0x26dE7861e213A5351F6ED767d00e0839930e9eE1;

    // wavey's mainnet deploy
    address constant WEIROLL_VM = 0x88Ff46920558447148687B69DAb3d8B1c160f5Cd;

    ERC3156FlashBorrower flashBorrowerImpl;
    FlashAccount accountImpl;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), vm.envOr("FORK_BLOCK", uint256(24_080_804)));

        (alice, alicePk) = makeAddrAndKey("alice");

        // Deploy implementations
        flashBorrowerImpl = new ERC3156FlashBorrower();
        accountImpl = new FlashAccount();

        // Create Alice with a fresh address via 7702 delegation
        Vm.SignedDelegation memory signedDelegation = vm.signDelegation(address(accountImpl), alicePk);
        vm.attachDelegation(signedDelegation);
    }

    function test_deploy() public {
        new ERC3156FlashBorrower();
    }

    function test_deploy2() public {
        bytes32 salt = bytes32(0);

        new ERC3156FlashBorrower{salt: salt}();
    }

    // basic test that flash borrows from crvusd and does nothing (measures gas overhead)
    function test_crvusd_flashloan_weiroll_noop() public {
        vm.pauseGasMetering();

        IERC3156FlashLender crvUSDFlashLender = IERC3156FlashLender(CRVUSD_FLASH_LENDER);

        // empty weiroll commands - do nothing
        bytes32[] memory commands = new bytes32[](0);
        bytes[] memory state = new bytes[](0);

        bytes memory weirollData = abi.encodeCall(IWeirollVM.execute, (commands, state));

        bytes memory flashloanData = abi.encodeCall(
            flashBorrowerImpl.flashloan,
            (
                crvUSDFlashLender,
                CRVUSD,
                WEIROLL_VM, // target - the contract to delegatecall inside of onFlashLoan
                ERC3156FlashBorrower.RepayMode.Transfer,
                weirollData
            )
        );

        vm.prank(alice);

        // we only want the gas for transientExecute. Is this the best way to get it? i need to read the docs about snapshotting gas more
        vm.resumeGasMetering();

        FlashAccount(payable(alice)).transientExecute(address(flashBorrowerImpl), flashloanData);

        vm.pauseGasMetering();

        // verify alice ended up with no crvUSD (all returned)
        assertEq(IERC20(CRVUSD).balanceOf(alice), 0, "alice should have no crvUSD");
    }
}
