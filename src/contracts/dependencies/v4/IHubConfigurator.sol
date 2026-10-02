// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IHubConfigurator {
  function updateSpokeAddCap(address hub, uint256 assetId, address spoke, uint256 addCap) external;

  function updateSpokeDrawCap(
    address hub,
    uint256 assetId,
    address spoke,
    uint256 drawCap
  ) external;

  function updateSpokeCaps(
    address hub,
    uint256 assetId,
    address spoke,
    uint256 addCap,
    uint256 drawCap
  ) external;

  function updateInterestRateData(address hub, uint256 assetId, bytes calldata irData) external;
}
