// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

interface ILiquidityGauge {
    function deposit(uint256 _amount) external;

    function withdraw(uint256 _amount) external;

    function balanceOf(address _userAddress) external returns (uint256);
}
