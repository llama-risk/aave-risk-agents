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

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    if (market.spoke == address(0) || value.length != 32) return false;
    uint256 newRisk = abi.decode(value, (uint256));
    if (newRisk > MAX_COLLATERAL_RISK) return false;

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
