// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ISpoke} from './ISpoke.sol';

interface ISpokeConfigurator {
  function updatePaused(address spoke, uint256 reserveId, bool paused) external;

  function updateFrozen(address spoke, uint256 reserveId, bool frozen) external;

  function updateCollateralRisk(address spoke, uint256 reserveId, uint256 collateralRisk) external;

  function addCollateralFactor(
    address spoke,
    uint256 reserveId,
    uint16 collateralFactor
  ) external returns (uint32);

  function updateCollateralFactor(
    address spoke,
    uint256 reserveId,
    uint32 dynamicConfigKey,
    uint16 collateralFactor
  ) external;

  function addMaxLiquidationBonus(
    address spoke,
    uint256 reserveId,
    uint256 maxLiquidationBonus
  ) external returns (uint32);

  function updateMaxLiquidationBonus(
    address spoke,
    uint256 reserveId,
    uint32 dynamicConfigKey,
    uint256 maxLiquidationBonus
  ) external;

  function addDynamicReserveConfig(
    address spoke,
    uint256 reserveId,
    ISpoke.DynamicReserveConfig calldata dynamicConfig
  ) external returns (uint32);

  function updateDynamicReserveConfig(
    address spoke,
    uint256 reserveId,
    uint32 dynamicConfigKey,
    ISpoke.DynamicReserveConfig calldata dynamicConfig
  ) external;

  function pauseReserve(address spoke, uint256 reserveId) external;

  function freezeReserve(address spoke, uint256 reserveId) external;
}
