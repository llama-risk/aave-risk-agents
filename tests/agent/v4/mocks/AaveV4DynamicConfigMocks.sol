// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ISpoke} from '../../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ConfiguratorMock} from './AaveV4Mocks.sol';

contract DynamicConfigSpokeMock {
  address public authority;
  mapping(address => mapping(uint256 => uint256)) internal _reserveIds;
  mapping(address => mapping(uint256 => bool)) internal _listed;
  mapping(uint256 => ISpoke.Reserve) internal _reserves;
  mapping(uint256 => bool) internal _frozen;
  mapping(uint256 => mapping(uint32 => ISpoke.DynamicReserveConfig)) internal _configs;

  error InvalidCollateralFactorAndMaxLiquidationBonus();
  error InvalidCollateralFactor();
  error DynamicConfigKeyUninitialized();
  error MaximumDynamicConfigKeyReached();

  constructor(address authority_) {
    authority = authority_;
  }

  function addReserve(
    address hub,
    uint256 assetId,
    uint256 reserveId,
    ISpoke.DynamicReserveConfig memory config
  ) external {
    _listed[hub][assetId] = true;
    _reserveIds[hub][assetId] = reserveId;
    _reserves[reserveId].hub = hub;
    _reserves[reserveId].assetId = uint16(assetId);
    _configs[reserveId][0] = config;
  }

  function setFrozen(uint256 reserveId, bool frozen) external {
    _frozen[reserveId] = frozen;
  }

  function setKey(
    uint256 reserveId,
    uint32 key,
    ISpoke.DynamicReserveConfig memory config
  ) external {
    _configs[reserveId][key] = config;
    if (key > _reserves[reserveId].dynamicConfigKey) _reserves[reserveId].dynamicConfigKey = key;
  }

  function getReserveId(address hub, uint256 assetId) external view returns (uint256) {
    require(_listed[hub][assetId], 'ReserveNotListed');
    return _reserveIds[hub][assetId];
  }

  function getReserve(uint256 reserveId) external view returns (ISpoke.Reserve memory) {
    return _reserves[reserveId];
  }

  function getReserveConfig(uint256 reserveId) external view returns (ISpoke.ReserveConfig memory) {
    return
      ISpoke.ReserveConfig({
        collateralRisk: 0,
        paused: false,
        frozen: _frozen[reserveId],
        borrowable: true,
        receiveSharesEnabled: true
      });
  }

  function getDynamicReserveConfig(
    uint256 reserveId,
    uint32 key
  ) external view returns (ISpoke.DynamicReserveConfig memory) {
    return _configs[reserveId][key];
  }

  function addDynamicReserveConfig(
    uint256 reserveId,
    ISpoke.DynamicReserveConfig memory config
  ) public returns (uint32) {
    uint32 key = _reserves[reserveId].dynamicConfigKey;
    require(key < type(uint32).max, MaximumDynamicConfigKeyReached());
    _validate(config);
    _reserves[reserveId].dynamicConfigKey = ++key;
    _configs[reserveId][key] = config;
    return key;
  }

  function updateDynamicReserveConfig(
    uint256 reserveId,
    uint32 key,
    ISpoke.DynamicReserveConfig memory config
  ) public {
    require(_configs[reserveId][key].maxLiquidationBonus > 0, DynamicConfigKeyUninitialized());
    require(config.collateralFactor > 0, InvalidCollateralFactor());
    _validate(config);
    _configs[reserveId][key] = config;
  }

  function _validate(ISpoke.DynamicReserveConfig memory config) internal pure {
    uint256 product = uint256(config.maxLiquidationBonus) * config.collateralFactor;
    require(
      config.collateralFactor < 100_00 &&
        config.maxLiquidationBonus >= 100_00 &&
        (product + 100_00 - 1) / 100_00 < 100_00,
      InvalidCollateralFactorAndMaxLiquidationBonus()
    );
  }
}

contract DynamicConfigSpokeConfiguratorMock is ConfiguratorMock {
  uint256 public calls;

  constructor(address authority_) ConfiguratorMock(authority_) {}

  function addCollateralFactor(
    address spoke,
    uint256 reserveId,
    uint16 collateralFactor
  ) external returns (uint32) {
    calls++;
    DynamicConfigSpokeMock target = DynamicConfigSpokeMock(spoke);
    ISpoke.DynamicReserveConfig memory config = target.getDynamicReserveConfig(
      reserveId,
      target.getReserve(reserveId).dynamicConfigKey
    );
    config.collateralFactor = collateralFactor;
    return target.addDynamicReserveConfig(reserveId, config);
  }

  function updateMaxLiquidationBonus(
    address spoke,
    uint256 reserveId,
    uint32 key,
    uint256 maxLiquidationBonus
  ) external {
    calls++;
    DynamicConfigSpokeMock target = DynamicConfigSpokeMock(spoke);
    ISpoke.DynamicReserveConfig memory config = target.getDynamicReserveConfig(reserveId, key);
    config.maxLiquidationBonus = uint32(maxLiquidationBonus);
    target.updateDynamicReserveConfig(reserveId, key, config);
  }

  function addDynamicReserveConfig(
    address spoke,
    uint256 reserveId,
    ISpoke.DynamicReserveConfig calldata config
  ) external returns (uint32) {
    calls++;
    return DynamicConfigSpokeMock(spoke).addDynamicReserveConfig(reserveId, config);
  }
}
