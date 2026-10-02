// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ISpoke} from '../../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ConfiguratorMock, SpokeMock} from './AaveV4Mocks.sol';

contract FreezeSpokeMock is SpokeMock {
  address public authority;

  function setDynamicConfig(
    uint256 reserveId,
    uint32 key,
    ISpoke.DynamicReserveConfig memory config
  ) external {
    _reserveData[reserveId].dynamicConfigKey = key;
    _dynamicConfigs[reserveId][key] = config;
  }

  function setAuthority(address authority_) external {
    authority = authority_;
  }

  function setFrozen(uint256 reserveId, bool frozen) external {
    _configs[reserveId].frozen = frozen;
  }

  function addDynamicReserveConfig(
    uint256 reserveId,
    ISpoke.DynamicReserveConfig memory config
  ) external returns (uint32) {
    uint32 key = _reserveData[reserveId].dynamicConfigKey;
    require(key < type(uint32).max, 'MaximumDynamicConfigKeyReached');
    require(
      config.collateralFactor < 100_00 &&
        config.maxLiquidationBonus >= 100_00 &&
        (uint256(config.maxLiquidationBonus) * config.collateralFactor + 100_00 - 1) / 100_00 <
        100_00,
      'InvalidCollateralFactorAndMaxLiquidationBonus'
    );
    require(config.liquidationFee <= 100_00, 'InvalidLiquidationFee');
    _reserveData[reserveId].dynamicConfigKey = ++key;
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
