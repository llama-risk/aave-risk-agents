// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

type ReserveFlags is uint8;

interface ISpoke {
  struct Reserve {
    address underlying;
    address hub;
    uint16 assetId;
    uint8 decimals;
    uint24 collateralRisk;
    ReserveFlags flags;
    uint32 dynamicConfigKey;
  }

  struct ReserveConfig {
    uint24 collateralRisk;
    bool paused;
    bool frozen;
    bool borrowable;
    bool receiveSharesEnabled;
  }

  struct DynamicReserveConfig {
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    uint16 liquidationFee;
  }

  struct LiquidationConfig {
    uint128 targetHealthFactor;
    uint64 healthFactorForMaxBonus;
    uint16 liquidationBonusFactor;
  }

  function addDynamicReserveConfig(
    uint256 reserveId,
    DynamicReserveConfig calldata dynamicConfig
  ) external returns (uint32 dynamicConfigKey);

  function updateDynamicReserveConfig(
    uint256 reserveId,
    uint32 dynamicConfigKey,
    DynamicReserveConfig calldata dynamicConfig
  ) external;

  function getReserveCount() external view returns (uint256);

  function getReserveId(address hub, uint256 assetId) external view returns (uint256);

  function getReserve(uint256 reserveId) external view returns (Reserve memory);

  function getReserveConfig(uint256 reserveId) external view returns (ReserveConfig memory);

  function getDynamicReserveConfig(
    uint256 reserveId,
    uint32 dynamicConfigKey
  ) external view returns (DynamicReserveConfig memory);

  function getLiquidationConfig() external view returns (LiquidationConfig memory);

  function ORACLE() external view returns (address);

  function updateReserveConfig(uint256 reserveId, ReserveConfig calldata params) external;

  function addDynamicReserveConfig(
    uint256 reserveId,
    DynamicReserveConfig calldata dynamicConfig
  ) external returns (uint32 dynamicConfigKey);

  function updateDynamicReserveConfig(
    uint256 reserveId,
    uint32 dynamicConfigKey,
    DynamicReserveConfig calldata dynamicConfig
  ) external;
}
