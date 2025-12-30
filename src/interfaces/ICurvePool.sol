// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

/// @dev this is just part of the contract
interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}
