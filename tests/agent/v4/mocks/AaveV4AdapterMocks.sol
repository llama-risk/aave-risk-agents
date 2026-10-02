// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {SpokeMock} from './AaveV4Mocks.sol';

contract OracleSpokeMock is SpokeMock {
  address public ORACLE;

  function setOracle(address oracle) external {
    ORACLE = oracle;
  }
}

contract AaveOracleMock {
  mapping(uint256 => address) internal _sources;

  function setReserveSource(uint256 reserveId, address source) external {
    _sources[reserveId] = source;
  }

  function getReserveSource(uint256 reserveId) external view returns (address) {
    return _sources[reserveId];
  }
}

contract ACLManagerMock {
  mapping(address => bool) public isRiskAdmin;
  mapping(address => bool) public isPoolAdmin;

  function setRiskAdmin(address account, bool enabled) external {
    isRiskAdmin[account] = enabled;
  }

  function setPoolAdmin(address account, bool enabled) external {
    isPoolAdmin[account] = enabled;
  }
}

contract FeedMock {
  int256 public latestAnswer;
  uint8 public decimals;

  constructor(int256 answer, uint8 decimals_) {
    latestAnswer = answer;
    decimals = decimals_;
  }
}

contract PrincipalTokenMock {
  uint256 public expiry;

  constructor(uint256 expiry_) {
    expiry = expiry_;
  }
}
