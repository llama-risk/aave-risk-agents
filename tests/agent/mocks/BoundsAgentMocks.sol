// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {BoundedRatioAdapterBase, IChainlinkAggregator} from './BoundedRatioAdapterBaseG.sol';

contract BoundedRatioAdapterMock is BoundedRatioAdapterBase {
  constructor(BoundedRatioAdapterParams memory params) BoundedRatioAdapterBase(params) {}

  function getRatio() public view override returns (int256) {
    return IChainlinkAggregator(RATIO_PROVIDER).latestAnswer();
  }

  function _getRatioUpdatedAt() internal view override returns (uint256) {
    return IChainlinkAggregator(RATIO_PROVIDER).latestTimestamp();
  }
}

contract MockRatioProvider {
  int256 public answer;
  bool public reverts;

  constructor(int256 initialAnswer) {
    answer = initialAnswer;
  }

  function setAnswer(int256 newAnswer) external {
    answer = newAnswer;
  }

  function setReverts(bool newReverts) external {
    reverts = newReverts;
  }

  function decimals() external pure returns (uint8) {
    return 18;
  }

  function latestAnswer() external view returns (int256) {
    require(!reverts);
    return answer;
  }

  function latestTimestamp() external view returns (uint256) {
    return block.timestamp;
  }
}

contract MockACLManager {
  mapping(address => bool) public isRiskAdmin;
  mapping(address => bool) public isPoolAdmin;

  function setRiskAdmin(address admin, bool enabled) external {
    isRiskAdmin[admin] = enabled;
  }

  function setPoolAdmin(address admin, bool enabled) external {
    isPoolAdmin[admin] = enabled;
  }
}

contract MalformedAdapter {
  fallback() external {
    assembly {
      mstore(0, 1)
      return(0, 0x60)
    }
  }
}
