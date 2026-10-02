// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ConfiguratorMock, SpokeMock} from './AaveV4Mocks.sol';

contract PausableSpokeMock is SpokeMock {
  address public authority;
  address public ORACLE;

  function setOracle(address oracle) external {
    ORACLE = oracle;
  }

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

contract BoundedPriceAdapterMock {
  bool public isBreached;
  int256 public latestAnswer = 100e8;

  function decimals() external pure returns (uint8) {
    return 8;
  }

  function setBreached(bool breached) external {
    isBreached = breached;
  }
}

contract ReserveSourceOracleMock {
  mapping(uint256 => address) public getReserveSource;

  function setReserveSource(uint256 reserveId, address source) external {
    getReserveSource[reserveId] = source;
  }
}
