// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ResupplyCrvUSDFlashMigrate} from "../../src/targets/resupply/ResupplyCrvUSDFlashMigrate.sol";
import {FlashAccount} from "../../src/FlashAccount.sol";
import {IResupplyPair} from "../../src/interfaces/resupply/IResupplyPair.sol";

/// @notice Fork tests for ResupplyCrvUSDFlashMigrate
/// @dev Run with: forge test --fork-url <RPC_URL> --match-contract ResupplyCrvUSDFlashMigrateForkTest -vvv
contract ResupplyCrvUSDFlashMigrateForkTest is Test {
    uint256 internal constant FORK_BLOCK = 24_080_804;
    // Tokens
    IERC20 constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant REUSD = IERC20(0x57aB1E0003F623289CD798B1824Be09a793e4Bec);

    // Markets
    IResupplyPair constant SDOLA_MARKET = IResupplyPair(0x27AB448a75d548ECfF73f8b4F36fCc9496768797);
    IResupplyPair constant WBTC_MARKET = IResupplyPair(0x2d8ecd48b58e53972dBC54d8d0414002B41Abc9D);

    // Test account
    address alice;

    // Contracts
    ResupplyCrvUSDFlashMigrate migrateImpl;
    FlashAccount accountImpl;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);

        // Create Alice with a fresh address
        alice = makeAddr("alice");

        // Deploy implementations
        migrateImpl = new ResupplyCrvUSDFlashMigrate();
        accountImpl = new FlashAccount();

        // Give Alice the smart account code (simulates EIP-7702)
        vm.etch(alice, address(accountImpl).code);

        // Deal Alice some crvUSD
        deal(address(CRVUSD), alice, 100_000e18);
    }

    function test_migrate_fromWbtcToSdola() public {
        // Setup: Alice deposits crvUSD into WBTC market and borrows
        uint256 depositAmount = 50_000e18;
        uint256 borrowAmount = 40_000e18;

        _depositAndBorrow(alice, WBTC_MARKET, depositAmount, borrowAmount);

        // Verify Alice has a position
        uint256 collateralBefore = WBTC_MARKET.userCollateralBalance(alice);
        uint256 borrowSharesBefore = WBTC_MARKET.userBorrowShares(alice);
        assertGt(collateralBefore, 0, "should have collateral");
        assertGt(borrowSharesBefore, 0, "should have borrow shares");

        // Execute migration
        bytes memory migrateData = abi.encodeCall(
            ResupplyCrvUSDFlashMigrate.flashLoan,
            (WBTC_MARKET, 10_000, SDOLA_MARKET) // 100%
        );

        vm.prank(alice);
        FlashAccount(payable(alice)).transientExecute(address(migrateImpl), migrateData);

        // Verify WBTC market position is closed
        uint256 collateralAfterSource = WBTC_MARKET.userCollateralBalance(alice);
        uint256 borrowSharesAfterSource = WBTC_MARKET.userBorrowShares(alice);
        assertEq(collateralAfterSource, 0, "should have no collateral in source");
        assertEq(borrowSharesAfterSource, 0, "should have no borrow in source");

        // Verify sDOLA market position is open
        uint256 collateralAfterTarget = SDOLA_MARKET.userCollateralBalance(alice);
        uint256 borrowSharesAfterTarget = SDOLA_MARKET.userBorrowShares(alice);
        assertGt(collateralAfterTarget, 0, "should have collateral in target");
        assertGt(borrowSharesAfterTarget, 0, "should have borrow in target");

        console.log("Migration successful!");
        console.log("Target collateral:", collateralAfterTarget);
        console.log("Target borrow shares:", borrowSharesAfterTarget);

        // TODO: assert that we have the same amount of collateral value and borrow value after migrating
    }

    function test_migrate_partialPosition() public {
        // Setup: Alice deposits and borrows
        uint256 depositAmount = 50_000e18;
        uint256 borrowAmount = 40_000e18;

        _depositAndBorrow(alice, WBTC_MARKET, depositAmount, borrowAmount);

        uint256 collateralBefore = WBTC_MARKET.userCollateralBalance(alice);
        uint256 borrowSharesBefore = WBTC_MARKET.userBorrowShares(alice);

        // Migrate 50%
        bytes memory migrateData = abi.encodeCall(
            ResupplyCrvUSDFlashMigrate.flashLoan,
            (WBTC_MARKET, 5_000, SDOLA_MARKET) // 50%
        );

        vm.prank(alice);
        FlashAccount(payable(alice)).transientExecute(address(migrateImpl), migrateData);

        // Verify ~50% remains in source
        uint256 collateralAfterSource = WBTC_MARKET.userCollateralBalance(alice);
        uint256 borrowSharesAfterSource = WBTC_MARKET.userBorrowShares(alice);

        // Allow 1% tolerance for rounding
        // TODO: this tolerance is way too big!
        assertApproxEqRel(collateralAfterSource, collateralBefore / 2, 0.01e18, "~50% collateral should remain");
        assertApproxEqRel(borrowSharesAfterSource, borrowSharesBefore / 2, 0.01e18, "~50% borrow should remain");

        // Verify position exists in target
        assertGt(SDOLA_MARKET.userCollateralBalance(alice), 0, "should have collateral in target");
        assertGt(SDOLA_MARKET.userBorrowShares(alice), 0, "should have borrow in target");

        // TODO: assert that we have the same sum of collateral value and borrow values after migrating
    }

    function test_migrate_multipleMigrations() public {
        // Setup: Alice deposits and borrows
        uint256 depositAmount = 50_000e18;
        uint256 borrowAmount = 40_000e18;

        _depositAndBorrow(alice, WBTC_MARKET, depositAmount, borrowAmount);

        // First migration: 50%
        bytes memory migrateData1 =
            abi.encodeCall(ResupplyCrvUSDFlashMigrate.flashLoan, (WBTC_MARKET, 5_000, SDOLA_MARKET));
        vm.prank(alice);
        FlashAccount(payable(alice)).transientExecute(address(migrateImpl), migrateData1);

        uint256 targetCollateralAfter1 = SDOLA_MARKET.userCollateralBalance(alice);

        // Second migration: remaining 100% of what's left (which is 50% of original)
        bytes memory migrateData2 =
            abi.encodeCall(ResupplyCrvUSDFlashMigrate.flashLoan, (WBTC_MARKET, 10_000, SDOLA_MARKET));
        vm.prank(alice);
        FlashAccount(payable(alice)).transientExecute(address(migrateImpl), migrateData2);

        // Verify source is empty
        assertEq(WBTC_MARKET.userCollateralBalance(alice), 0, "source should be empty");
        assertEq(WBTC_MARKET.userBorrowShares(alice), 0, "source borrow should be empty");

        // Verify target has more collateral after second migration
        uint256 targetCollateralAfter2 = SDOLA_MARKET.userCollateralBalance(alice);
        assertGt(targetCollateralAfter2, targetCollateralAfter1, "target should have more collateral");

        // TODO: assert that we have the same sum of collateral value and borrow values after migrating
    }

    function test_migrate_revertsWithoutPosition() public {
        // Alice has no position, migration should fail or be a no-op
        bytes memory migrateData =
            abi.encodeCall(ResupplyCrvUSDFlashMigrate.flashLoan, (WBTC_MARKET, 10_000, SDOLA_MARKET));

        // This should revert because there's nothing to migrate
        vm.prank(alice);
        // TODO: expect a specific revert reason?
        vm.expectRevert();
        FlashAccount(payable(alice)).transientExecute(address(migrateImpl), migrateData);
    }

    /// @dev Helper to deposit crvUSD and borrow reUSD
    function _depositAndBorrow(address user, IResupplyPair market, uint256 crvUsdAmount, uint256 borrowAmount)
        internal
    {
        // Get the collateral vault (Curve lending vault)
        IERC4626 vault = IERC4626(market.collateral());

        vm.startPrank(user);

        // Deposit crvUSD into vault to get shares
        CRVUSD.approve(address(vault), crvUsdAmount);
        uint256 shares = vault.deposit(crvUsdAmount, user);

        // addCollateralVault takes shares and transfers them to market
        IERC20(address(vault)).approve(address(market), shares);
        market.addCollateralVault(shares, user);

        // Borrow reUSD
        market.borrow(borrowAmount, 0, user);

        vm.stopPrank();

        console.log("Deposited and borrowed:");
        console.log("  Collateral:", market.userCollateralBalance(user));
        console.log("  Borrow shares:", market.userBorrowShares(user));
    }
}
