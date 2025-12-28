// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {ResupplyCrvUSDFlashEnter} from "../src/transients/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccount} from "../src/FlashAccount.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";

contract ResupplyCrvUSDFlashEnterScript is Script {
    ResupplyCrvUSDFlashEnter public enter;

    function setUp() public {}

    function deploy() public {
        vm.startBroadcast();
        enter = new ResupplyCrvUSDFlashEnter();
        vm.stopBroadcast();
    }

    /// @dev Env vars:
    /// - ACCOUNT: delegated EOA address
    /// - ENTER_IMPL: deployed ResupplyCrvUSDFlashEnter implementation
    /// - MARKET: ResupplyPair address (crvUSD underlying)
    /// - CURVE_POOL: pool address for crvUSD->reUSD
    /// - CURVE_I, CURVE_J: int128 indexes for exchange(i,j)
    /// - FLASH_AMOUNT: crvUSD amount to flash loan
    /// - MAX_FEE_PCT: max redemption fee pct (handler PRECISION)
    /// - MIN_REUSD_OUT: min reUSD from Curve swap
    /// - MIN_CRVUSD_REDEEMED: min crvUSD returned from redemption
    function flashLoan() public {
        address account = vm.envAddress("ACCOUNT");
        address enterImpl = vm.envAddress("ENTER_IMPL");
        ResupplyPair market = ResupplyPair(vm.envAddress("MARKET"));
        address curvePool = vm.envAddress("CURVE_POOL");
        int128 curveI = int128(int256(vm.envUint("CURVE_I")));
        int128 curveJ = int128(int256(vm.envUint("CURVE_J")));
        uint256 flashAmount = vm.envUint("FLASH_AMOUNT");
        uint256 maxFeePct = vm.envUint("MAX_FEE_PCT");
        uint256 minReusdOut = vm.envUint("MIN_REUSD_OUT");
        uint256 minCrvUsdRedeemed = vm.envUint("MIN_CRVUSD_REDEEMED");

        bytes memory data = abi.encodeCall(
            ResupplyCrvUSDFlashEnter.flashLoan,
            (market, curvePool, curveI, curveJ, flashAmount, maxFeePct, minReusdOut, minCrvUsdRedeemed)
        );

        vm.startBroadcast();
        FlashAccount(payable(account)).transientExecute(enterImpl, data);
        vm.stopBroadcast();
    }
}
