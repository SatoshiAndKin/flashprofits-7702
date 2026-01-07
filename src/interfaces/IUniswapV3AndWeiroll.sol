// SPDX-License-Identifier: UNLICENSED
// deployed on mainnet at 0x88Ff46920558447148687B69DAb3d8B1c160f5Cd
pragma solidity ^0.8.4;

interface UniswapV3Helper {
    error ExecutionFailed(uint256 command_index, address target, string message);
    error T();

    function execute(bytes32[] memory commands, bytes[] memory state) external payable returns (bytes[] memory);
    function getLPAmount0(address pool, int24 minTick, int24 maxTick, uint256 maxToken0Amount, uint256 maxToken1Amount)
        external
        view
        returns (uint256 amount0);
    function getLPAmount1(address pool, int24 minTick, int24 maxTick, uint256 maxToken0Amount, uint256 maxToken1Amount)
        external
        view
        returns (uint256 amount1);
    function getLPAmounts(
        uint160 sqrtRatioX96,
        int24 minTick,
        int24 maxTick,
        uint256 maxToken0Amount,
        uint256 maxToken1Amount
    ) external pure returns (uint256, uint256);
    function getLPAmounts(address pool, int24 minTick, int24 maxTick, uint256 maxToken0Amount, uint256 maxToken1Amount)
        external
        view
        returns (uint256, uint256);
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160);
}
