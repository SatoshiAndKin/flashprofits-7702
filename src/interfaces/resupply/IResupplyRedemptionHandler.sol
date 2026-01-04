// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

interface IResupplyRedemptionHandler {
    function previewRedeem(address _pair, uint256 _amount)
        external
        view
        returns (uint256 _returnedUnderlying, uint256 _returnedCollateral, uint256 _feePct);

    /// @notice Redeem stablecoins for collateral from a pair
    /// @param _pair The address of the pair to redeem from
    /// @param _amount The amount of stablecoins to redeem
    /// @param _maxFeePct The maximum fee pct (in 1e18) that the caller will accept
    /// @param _receiver The address that will receive the withdrawn collateral
    /// @param _redeemToUnderlying Whether to unwrap the collateral to the underlying asset
    /// @return _ amount received of either collateral shares or underlying, depending on `_redeemToUnderlying`
    function redeemFromPair (
        address _pair,
        uint256 _amount,
        uint256 _maxFeePct,
        address _receiver,
        bool _redeemToUnderlying
    ) external returns(uint256);
}
