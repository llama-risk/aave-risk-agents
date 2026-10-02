// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ISpoke} from '../../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ConfiguratorMock, SpokeMock} from './AaveV4Mocks.sol';

contract FreezeSpokeMock is SpokeMock {
  address public authority;
  mapping(uint256 => uint32) internal _latestKeys;
  mapping(uint256 => mapping(uint32 => ISpoke.DynamicReserveConfig)) internal _dynamicConfigs;

  function setDynamicConfig(
    uint256 reserveId,
    uint32 key,
    ISpoke.DynamicReserveConfig memory config
  ) external {
    _latestKeys[reserveId] = key;
    _dynamicConfigs[reserveId][key] = config;
  }

  function setAuthority(address authority_) external {
    authority = authority_;
  }

  function setFrozen(uint256 reserveId, bool frozen) external {
    _configs[reserveId].frozen = frozen;
  }

  function getReserve(uint256 reserveId) external view returns (ISpoke.Reserve memory reserve) {
    reserve.dynamicConfigKey = _latestKeys[reserveId];
  }

  function getDynamicReserveConfig(
    uint256 reserveId,
    uint32 key
  ) external view returns (ISpoke.DynamicReserveConfig memory) {
    return _dynamicConfigs[reserveId][key];
  }

  function addDynamicReserveConfig(
    uint256 reserveId,
    ISpoke.DynamicReserveConfig memory config
  ) external returns (uint32) {
    uint32 key = _latestKeys[reserveId];
    require(key < type(uint32).max, 'MaximumDynamicConfigKeyReached');
    require(
      config.collateralFactor < 100_00 &&
        config.maxLiquidationBonus >= 100_00 &&
        (uint256(config.maxLiquidationBonus) * config.collateralFactor + 100_00 - 1) / 100_00 <
        100_00,
      'InvalidCollateralFactorAndMaxLiquidationBonus'
    );
    require(config.liquidationFee <= 100_00, 'InvalidLiquidationFee');
    _latestKeys[reserveId] = ++key;
    _dynamicConfigs[reserveId][key] = config;
    return key;
  }
}

contract FreezeSpokeConfiguratorMock is ConfiguratorMock {
  uint256 public addCalls;
  uint256 public freezeCalls;

  constructor(address authority_) ConfiguratorMock(authority_) {}

  function addCollateralFactor(
    address spoke,
    uint256 reserveId,
    uint16 collateralFactor
  ) external returns (uint32) {
    FreezeSpokeMock target = FreezeSpokeMock(spoke);
    ISpoke.DynamicReserveConfig memory config = target.getDynamicReserveConfig(
      reserveId,
      target.getReserve(reserveId).dynamicConfigKey
    );
    config.collateralFactor = collateralFactor;
    addCalls++;
    return target.addDynamicReserveConfig(reserveId, config);
  }

  function freezeReserve(address spoke, uint256 reserveId) external {
    freezeCalls++;
    FreezeSpokeMock(spoke).setFrozen(reserveId, true);
  }
}
