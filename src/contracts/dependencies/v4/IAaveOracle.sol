// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IAaveOracle {
  function spoke() external view returns (address);

  function decimals() external view returns (uint8);

  function getReservePrice(uint256 reserveId) external view returns (uint256);

  function getReserveSource(uint256 reserveId) external view returns (address);
}
