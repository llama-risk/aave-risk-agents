// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';

import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../dependencies/v4/ISpokeConfigurator.sol';
import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';

/**
 * @title AaveV4FreezeAgent
 * @author LlamaRisk
 * @notice Agent that escalates an Aave v4 spoke reserve to LTV0 or freeze. The update value is
 *         abi.encode(uint256 level): 1 adds a dynamic config key with collateral factor 0, and
 *         2 also sets the reserve frozen flag. Updates only escalate the current state; undo is
 *         out of scope for the agent.
 */
contract AaveV4FreezeAgent is BaseAaveV4Agent {
  uint256 public constant LEVEL_LTV0 = 1;
  uint256 public constant LEVEL_FREEZE = 2;

  uint256 internal constant PERCENTAGE_FACTOR = 100_00;

  struct Actions {
    uint256 reserveId;
    bool addZeroCollateralFactor;
    bool freeze;
  }

  /**
   * @param agentHub the address of the agentHub which will use this agent contract
   * @param rangeValidationModule the address of the range validation module
   * @param updateTypeSuffix the updateType suffix to append, to tell instances apart
   * @param spokeConfigurator the address of the v4 SpokeConfigurator
   */
  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateTypeSuffix,
    address spokeConfigurator
  )
    BaseAaveV4Agent(
      agentHub,
      rangeValidationModule,
      'FreezeUpdate',
      updateTypeSuffix,
      spokeConfigurator
    )
  {}

  function _configuratorSelector() internal pure override returns (bytes4) {
    return ISpokeConfigurator.addCollateralFactor.selector;
  }

  function _validateUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool valid) {
    (valid, ) = _actions(market, value);
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal override {
    (, Actions memory actions) = _actions(market, value);
    if (actions.addZeroCollateralFactor) {
      ISpokeConfigurator(CONFIGURATOR).addCollateralFactor(market.spoke, actions.reserveId, 0);
    }
    if (actions.freeze) {
      ISpokeConfigurator(CONFIGURATOR).freezeReserve(market.spoke, actions.reserveId);
    }
  }

  function _actions(
    Market memory market,
    bytes calldata value
  ) internal view returns (bool, Actions memory actions) {
    (bool ok, uint256 level) = _decodeUint(value, LEVEL_FREEZE);
    if (!ok || level == 0) return (false, actions);

    (ok, , actions.reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    if (!ok) return (false, actions);

    uint32 latestKey;
    ISpoke.DynamicReserveConfig memory latest;
    (ok, latestKey, latest) = _latestDynamicReserveConfig(market.spoke, actions.reserveId);
    if (!ok) return (false, actions);

    ISpoke.ReserveConfig memory config;
    (ok, config) = _reserveConfig(market.spoke, actions.reserveId);
    if (!ok) return (false, actions);

    actions.addZeroCollateralFactor = latest.collateralFactor != 0;
    actions.freeze = level == LEVEL_FREEZE && !config.frozen;
    if (!actions.addZeroCollateralFactor && !actions.freeze) return (false, actions);

    // addCollateralFactor copies the latest key, so the copy must pass the spoke add checks.
    if (
      actions.addZeroCollateralFactor &&
      (latestKey == type(uint32).max ||
        latest.maxLiquidationBonus < PERCENTAGE_FACTOR ||
        latest.liquidationFee > PERCENTAGE_FACTOR)
    ) return (false, actions);

    if (
      actions.addZeroCollateralFactor &&
      !_configuratorCanCall(market.spoke, ISpoke.addDynamicReserveConfig.selector)
    ) return (false, actions);

    if (
      actions.freeze &&
      (!_canCallConfigurator(ISpokeConfigurator.freezeReserve.selector) ||
        !_configuratorCanCall(market.spoke, ISpoke.updateReserveConfig.selector))
    ) return (false, actions);
    return (true, actions);
  }
}
