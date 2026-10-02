// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';

import {BaseAaveV4Agent} from '../../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {ISpoke} from '../../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';

contract AaveV4AgentHarness is BaseAaveV4Agent {
  uint256 public constant MAX_COLLATERAL_RISK = 1000_00;

  constructor(
    address agentHub,
    address rangeValidationModule,
    address configurator
  ) BaseAaveV4Agent(agentHub, rangeValidationModule, 'CollateralRiskUpdate', '', configurator) {}

  function decodeUpdate(
    IRiskOracle.RiskParameterUpdate calldata update
  ) external pure returns (bool, Market memory, bytes memory) {
    return _decodeUpdate(update);
  }

  function assetId(address hub, address asset) external view returns (bool, uint256) {
    return _assetId(hub, asset);
  }

  function reserveId(
    address hub,
    address spoke,
    address asset
  ) external view returns (bool, uint256, uint256) {
    return _reserveId(hub, spoke, asset);
  }

  function spokeAssetId(
    address hub,
    address spoke,
    address asset
  ) external view returns (bool, uint256) {
    return _spokeAssetId(hub, spoke, asset);
  }

  function decodeUint(bytes calldata value, uint256 max) external pure returns (bool, uint256) {
    return _decodeUint(value, max);
  }

  function canCallConfigurator(bytes4 selector) external view returns (bool) {
    return _canCallConfigurator(selector);
  }

  function configuratorCanCall(address target, bytes4 selector) external view returns (bool) {
    return _configuratorCanCall(target, selector);
  }

  function canCallImmediately(
    address caller,
    address target,
    bytes4 selector
  ) external view returns (bool) {
    return _canCallImmediately(caller, target, selector);
  }

  function reserveConfig(
    address spoke,
    uint256 id
  ) external view returns (bool, ISpoke.ReserveConfig memory) {
    return _reserveConfig(spoke, id);
  }

  function dynamicConfigKey(address spoke, uint256 id) external view returns (bool, uint32) {
    return _dynamicConfigKey(spoke, id);
  }

  function dynamicReserveConfig(
    address spoke,
    uint256 id,
    uint32 key
  ) external view returns (bool, ISpoke.DynamicReserveConfig memory) {
    return _dynamicReserveConfig(spoke, id, key);
  }

  function latestDynamicReserveConfig(
    address spoke,
    uint256 id
  ) external view returns (bool, uint32, ISpoke.DynamicReserveConfig memory) {
    return _latestDynamicReserveConfig(spoke, id);
  }

  function staticcallWord(address target, bytes memory data) external view returns (bool, uint256) {
    return _staticcallWord(target, data);
  }

  function staticcallWords(
    address target,
    bytes memory data,
    uint256 count
  ) external view returns (bool, uint256[] memory) {
    return _staticcallWords(target, data, count);
  }

  function contains(address[] memory list, address item) external pure returns (bool) {
    return _contains(list, item);
  }

  function _configuratorSelector() internal pure override returns (bytes4) {
    return ISpokeConfigurator.updateCollateralRisk.selector;
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, uint256 newRisk) = _decodeUint(value, MAX_COLLATERAL_RISK);
    if (!ok) return false;

    (bool listed, , uint256 id) = _reserveId(market.hub, market.spoke, market.asset);
    if (!listed) return false;

    uint256 currentRisk = ISpoke(market.spoke).getReserveConfig(id).collateralRisk;
    if (currentRisk == newRisk) return false;

    return
      RANGE_VALIDATION_MODULE.validate(
        AGENT_HUB,
        agentId,
        update.market,
        IRangeValidationModule.RangeValidationInput({
          from: currentRisk,
          to: newRisk,
          updateType: 'CollateralRisk'
        })
      );
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal override {
    (, , uint256 id) = _reserveId(market.hub, market.spoke, market.asset);
    ISpokeConfigurator(CONFIGURATOR).updateCollateralRisk(
      market.spoke,
      id,
      abi.decode(value, (uint256))
    );
  }
}
