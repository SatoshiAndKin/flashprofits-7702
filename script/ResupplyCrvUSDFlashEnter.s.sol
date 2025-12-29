// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {
    ResupplyCrvUSDFlashEnter
} from "../src/transients/ResupplyCrvUSDFlashEnter.sol";
import {FlashAccount} from "../src/FlashAccount.sol";
import {ResupplyPair} from "../src/interfaces/ResupplyPair.sol";

contract ResupplyCrvUSDFlashEnterScript is Script, Config {
    ResupplyCrvUSDFlashEnter public enter;

    function setUp() public {}

    function deploy() public {
        _loadConfig("./deployments.toml", true);

        vm.startBroadcast();
        enter = new ResupplyCrvUSDFlashEnter();
        vm.stopBroadcast();

        config.set("resupply_crvUSD_flash_enter", address(enter));
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
        address enterImpl = config.get("resupply_crvUSD_flash_enter");

        // TODO: this is wrong. instead of environment variables, i think we should use function arguments
        ResupplyPair market = ResupplyPair(vm.envAddress("MARKET"));

        // TODO: this should be a constant
        address curvePool = vm.envAddress("CURVE_POOL");
        int128 curveI = int128(int256(vm.envUint("CURVE_I")));
        int128 curveJ = int128(int256(vm.envUint("CURVE_J")));
        uint256 flashAmount = vm.envUint("FLASH_AMOUNT");
        uint256 maxFeePct = vm.envUint("MAX_FEE_PCT");
        uint256 minReusdOut = vm.envUint("MIN_REUSD_OUT");
        uint256 minCrvUsdRedeemed = vm.envUint("MIN_CRVUSD_REDEEMED");

        // TODO: these function args need more thought
        bytes memory data = abi.encodeCall(
            ResupplyCrvUSDFlashEnter.flashLoan,
            (
                market,
                curvePool,
                curveI,
                curveJ,
                flashAmount,
                maxFeePct,
                minReusdOut,
                minCrvUsdRedeemed
            )
        );

        vm.startBroadcast();
        FlashAccount(msg.sender).transientExecute(enterImpl, data);
        vm.stopBroadcast();
    }
}
