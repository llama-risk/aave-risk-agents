// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IAssetInterestRateStrategy {
  struct InterestRateData {
    uint16 optimalUsageRatio;
    uint32 baseDrawnRate;
    uint32 rateGrowthBeforeOptimal;
    uint32 rateGrowthAfterOptimal;
  }

  function getInterestRateData(uint256 assetId) external view returns (InterestRateData memory);

  function getMaxDrawnRate(uint256 assetId) external view returns (uint256);

  function MAX_ALLOWED_DRAWN_RATE() external view returns (uint256);

  function MIN_OPTIMAL_RATIO() external view returns (uint256);

  function MAX_OPTIMAL_RATIO() external view returns (uint256);

  function HUB() external view returns (address);
}
