// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Config} from "forge-std/Config.sol";
import {ResupplyCrvUSDFlashEnter} from "../src/transients/ResupplyCrvUSDFlashEnter.sol";
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
        address enterImpl = config.get("resupply_crvUSD_flash_enter").toAddress();
        uint256 initialCrvUsdAmount = vm.envUint("INITIAL_CRVUSD_AMOUNT");

        // TODO: this is wrong. instead of environment variables, i think we should use function arguments
        ResupplyPair market = ResupplyPair(vm.envAddress("MARKET"));

        // TODO: don't hard code. these should be arguments
        // TODO: i feel like leverage and health are more related than I think. we want the max leverage that 
        uint256 leverageBps = 12.5e4;
        uint256 goalHealthBps = 1.04e4;
        // TODO: this should probably have tighter slippage protection!
        uint256 minHealthBps = 1.03e4;

        // TODO: these function args need more thought
        bytes memory data = abi.encodeCall(
            ResupplyCrvUSDFlashEnter.flashLoan,
            (
                initialCrvUsdAmount,
                market,
                leverageBps,
                goalHealthBps,
                minHealthBps
            )
        );

        vm.startBroadcast();
        FlashAccount(payable(msg.sender)).transientExecute(enterImpl, data);
        vm.stopBroadcast();
    }
}
