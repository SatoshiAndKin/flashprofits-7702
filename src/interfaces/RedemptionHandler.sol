// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface RedemptionHandler {
    function previewRedeem(address _pair, uint256 _amount)
        external
        view
        returns (uint256 _returnedUnderlying, uint256 _returnedCollateral, uint256 _fee);

    function redeemFromPair(
        address _pair,
        uint256 _amount,
        uint256 _maxFeePct,
        address _receiver,
        bool _redeemToUnderlying
    ) external returns (uint256);
}
