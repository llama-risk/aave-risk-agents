// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IHub} from '../../../../src/contracts/dependencies/v4/IHub.sol';
import {HubMock} from './AaveV4Mocks.sol';

contract AuthorityHubMock is HubMock {
  address public authority;

  function setAuthority(address authority_) external {
    authority = authority_;
  }
}

contract RatesHubMock is AuthorityHubMock {
  mapping(uint256 => address) internal _irStrategies;

  function setIrStrategy(uint256 assetId, address irStrategy) external {
    _irStrategies[assetId] = irStrategy;
  }

  function getAssetConfig(uint256 assetId) external view returns (IHub.AssetConfig memory config) {
    config.irStrategy = _irStrategies[assetId];
  }
}

contract DirtyAssetConfigHubMock is AuthorityHubMock {
  function getAssetConfig(uint256) external pure returns (uint256, uint256, uint256, uint256) {
    return (0, 0, type(uint256).max, 0);
  }
}

contract InterestRateStrategyMock {
  uint256 public MIN_OPTIMAL_RATIO = 1_00;
  uint256 public MAX_OPTIMAL_RATIO = 99_00;
  uint256 public MAX_ALLOWED_DRAWN_RATE = 1000_00;

  mapping(uint256 => uint256[4]) internal _rates;

  function setBounds(uint256 minOptimal, uint256 maxOptimal, uint256 maxDrawnRate) external {
    MIN_OPTIMAL_RATIO = minOptimal;
    MAX_OPTIMAL_RATIO = maxOptimal;
    MAX_ALLOWED_DRAWN_RATE = maxDrawnRate;
  }

  function setInterestRateData(uint256 assetId, uint256[4] calldata rates) external {
    _rates[assetId] = rates;
  }

  function getInterestRateData(uint256 assetId) external view returns (uint256[4] memory) {
    return _rates[assetId];
  }
}

contract NoBoundsStrategyMock {
  function getInterestRateData(uint256) external pure returns (uint256[4] memory rates) {
    rates = [uint256(80_00), 0, 4_00, 60_00];
  }
}
