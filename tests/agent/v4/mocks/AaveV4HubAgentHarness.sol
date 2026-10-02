// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';

import {BaseAaveV4Agent} from '../../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {IHubConfigurator} from '../../../../src/contracts/dependencies/v4/IHubConfigurator.sol';

contract AaveV4HubAgentHarness is BaseAaveV4Agent {
  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateType,
    address configurator
  ) BaseAaveV4Agent(agentHub, rangeValidationModule, updateType, '', configurator) {}

  function _isHubLevel() internal pure override returns (bool) {
    return true;
  }

  function _configuratorSelector() internal pure override returns (bytes4) {
    return IHubConfigurator.updateInterestRateData.selector;
  }

  function _validateUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    if (value.length != 128) return false;
    (bool ok, ) = _assetId(market.hub, market.asset);
    return ok;
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal override {
    (, uint256 id) = _assetId(market.hub, market.asset);
    IHubConfigurator(CONFIGURATOR).updateInterestRateData(market.hub, id, value);
  }
}
