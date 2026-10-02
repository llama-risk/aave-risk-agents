// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IPoolConfigurator} from 'aave-v3-origin/src/contracts/interfaces/IPoolConfigurator.sol';
import {ReserveConfiguration, DataTypes} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {EModeConfiguration} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/EModeConfiguration.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';

import {BaseAaveAgent, BaseAgent} from './BaseAaveAgent.sol';

/**
 * @title AaveV3FreezeAgent
 * @author LlamaRisk
 * @notice Agent contract to be used by the agentHub to escalate a reserve to LTV0 (level 1)
 *         or to a full freeze (level 2) on the Aave protocol. The level only goes up.
 */
contract AaveV3FreezeAgent is BaseAaveAgent {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  uint256 public constant LEVEL_NONE = 0;
  uint256 public constant LEVEL_LTV0 = 1;
  uint256 public constant LEVEL_FREEZE = 2;

  IPoolConfigurator public immutable POOL_CONFIGURATOR;

  /**
   * @notice The update did not pass validation at injection time
   */
  error InvalidUpdate();

  /**
   * @param agentHub the address of the agentHub which will use this agent contract
   * @param updateTypeSuffix the updateType suffix to append, useful for networks where we have multiple instances, ex. Core and Prime on mainnet.
   * @param pool the address of aave pool
   */
  constructor(
    address agentHub,
    string memory updateTypeSuffix,
    address pool
  ) BaseAaveAgent(agentHub, address(0), 'ReserveFreezeUpdate', updateTypeSuffix, pool) {
    POOL_CONFIGURATOR = IPoolConfigurator(POOL.ADDRESSES_PROVIDER().getPoolConfigurator());
  }

  /**
   * @notice method to get the current level of a reserve as read from the pool
   * @param asset the address of the reserve
   * @return the current level: 0 none, 1 no LTV-bearing collateral path (whatever set it), 2 frozen
   */
  function getLevel(address asset) external view returns (uint256) {
    return _currentLevel(POOL.getReserveData(asset));
  }

  /// @inheritdoc BaseAaveAgent
  function _validateUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal view override returns (bool) {
    uint256 level = _interpret(update.newValue);
    if (level != LEVEL_LTV0 && level != LEVEL_FREEZE) return false;

    DataTypes.ReserveDataLegacy memory reserve = POOL.getReserveData(update.market);
    if (reserve.aTokenAddress == address(0)) return false;

    if (level == LEVEL_FREEZE) return !reserve.configuration.getFrozen();
    return _supportsLtvzero() && _currentLevel(reserve) == LEVEL_NONE;
  }

  /// @inheritdoc BaseAgent
  function _processUpdate(
    uint256 agentId,
    bytes calldata agentContext,
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal override {
    require(_validateUpdate(agentId, agentContext, update), InvalidUpdate());

    if (_interpret(update.newValue) == LEVEL_FREEZE) {
      POOL_CONFIGURATOR.setReserveFreeze(update.market, true);
      return;
    }

    DataTypes.ReserveDataLegacy memory reserve = POOL.getReserveData(update.market);
    if (reserve.configuration.getLtv() != 0) {
      POOL_CONFIGURATOR.setReserveLtvzero(update.market, true);
    }
    for (uint256 i = 1; i <= type(uint8).max; i++) {
      if (_isMissingEModeLtvzero(uint8(i), reserve.id)) {
        POOL_CONFIGURATOR.setAssetLtvzeroInEMode(update.market, uint8(i), true);
      }
    }
  }

  function _currentLevel(
    DataTypes.ReserveDataLegacy memory reserve
  ) internal view returns (uint256) {
    if (reserve.aTokenAddress == address(0)) return LEVEL_NONE;
    if (reserve.configuration.getFrozen()) return LEVEL_FREEZE;
    if (reserve.configuration.getLtv() != 0 || !_supportsLtvzero()) return LEVEL_NONE;
    for (uint256 i = 1; i <= type(uint8).max; i++) {
      if (_isMissingEModeLtvzero(uint8(i), reserve.id)) return LEVEL_NONE;
    }
    return LEVEL_LTV0;
  }

  function _isMissingEModeLtvzero(
    uint8 categoryId,
    uint256 reserveId
  ) internal view returns (bool) {
    return
      EModeConfiguration.isReserveEnabledOnBitmap(
        POOL.getEModeCategoryCollateralBitmap(categoryId),
        reserveId
      ) &&
      !EModeConfiguration.isReserveEnabledOnBitmap(
        POOL.getEModeCategoryLtvzeroBitmap(categoryId),
        reserveId
      );
  }

  // Pools before v3.7 have no LTV0 functions, so level 1 is unavailable there.
  function _supportsLtvzero() internal view returns (bool) {
    try POOL.getEModeCategoryLtvzeroBitmap(1) returns (uint128) {
      return true;
    } catch {
      return false;
    }
  }

  /**
   * @notice method to interpret the level from risk oracle
   * @param valueInBytes bytes encoded level passed from the risk oracle
   * @return the decoded level, or 0 if the value does not fit in 32 bytes
   */
  function _interpret(bytes calldata valueInBytes) internal pure returns (uint256) {
    if (valueInBytes.length == 0 || valueInBytes.length > 32) return LEVEL_NONE;
    return _decodeToUint(valueInBytes);
  }
}
