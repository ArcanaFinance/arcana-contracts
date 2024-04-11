// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

interface IUniswapV2Pair {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function decimals() external pure returns (uint8);

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function totalSupply() external view returns (uint256);
}
