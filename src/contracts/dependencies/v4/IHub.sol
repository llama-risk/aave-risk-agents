// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IHub {
  struct AssetConfig {
    address feeReceiver;
    uint16 liquidityFee;
    address irStrategy;
    address reinvestmentController;
  }

  struct SpokeConfig {
    uint40 addCap;
    uint40 drawCap;
    uint24 riskPremiumThreshold;
    bool active;
    bool halted;
  }

  function isUnderlyingListed(address underlying) external view returns (bool);

  function getAssetId(address underlying) external view returns (uint256);

  function getAssetCount() external view returns (uint256);

  function getAssetUnderlyingAndDecimals(uint256 assetId) external view returns (address, uint8);

  function getAssetConfig(uint256 assetId) external view returns (AssetConfig memory);

  function getSpokeCount(uint256 assetId) external view returns (uint256);

  function isSpokeListed(uint256 assetId, address spoke) external view returns (bool);

  function getSpokeAddress(uint256 assetId, uint256 index) external view returns (address);

  function getSpokeConfig(
    uint256 assetId,
    address spoke
  ) external view returns (SpokeConfig memory);

  function MAX_ALLOWED_SPOKE_CAP() external view returns (uint40);
}
