// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IB20OracleRegistry {
  function getOracleParams(address token) external view returns (uint256 multiplier, bool paused);
}
