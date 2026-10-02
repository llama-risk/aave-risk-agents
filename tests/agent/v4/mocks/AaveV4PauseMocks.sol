// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ConfiguratorMock, SpokeMock} from './AaveV4Mocks.sol';

contract PausableSpokeMock is SpokeMock {
  address public authority;

  function setAuthority(address authority_) external {
    authority = authority_;
  }

  function setPaused(uint256 reserveId, bool paused) external {
    _configs[reserveId].paused = paused;
  }
}

contract PauseSpokeConfiguratorMock is ConfiguratorMock {
  uint256 public calls;

  constructor(address authority_) ConfiguratorMock(authority_) {}

  function pauseReserve(address spoke, uint256 reserveId) external {
    PausableSpokeMock(spoke).setPaused(reserveId, true);
    calls++;
  }
}

contract B20OracleRegistryMock {
  mapping(address => bool) public paused;
  mapping(address => bool) public listed;

  function setOraclePaused(address token, bool isPaused) external {
    listed[token] = true;
    paused[token] = isPaused;
  }

  function getOracleParams(address token) external view returns (uint256, bool) {
    require(listed[token], 'not listed');
    return (1e18, paused[token]);
  }
}

contract B20TokenMock {
  function multiplier() external pure returns (uint256) {
    return 1e18;
  }
}
