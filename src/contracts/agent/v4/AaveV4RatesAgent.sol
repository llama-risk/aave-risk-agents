// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';

import {IAssetInterestRateStrategy} from '../../dependencies/v4/IAssetInterestRateStrategy.sol';
import {IHub} from '../../dependencies/v4/IHub.sol';
import {IHubConfigurator} from '../../dependencies/v4/IHubConfigurator.sol';
import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';

/**
 * @title AaveV4RatesAgent
 * @author LlamaRisk
 * @notice Agent that updates the interest rate data of an Aave v4 hub asset through the HubConfigurator.
 *         The market is the market id of (hub, address(0), asset). The value is
 *         abi.encode(optimalUsageRatio, baseDrawnRate, rateGrowthBeforeOptimal, rateGrowthAfterOptimal)
 *         in bps, the same encoding as the v3 rates agent.
 */
contract AaveV4RatesAgent is BaseAaveV4Agent {
  /**
   * @param agentHub the address of the agentHub which will use this agent contract
   * @param rangeValidationModule the address of range validation module used to store range config and to validate ranges
   * @param updateTypeSuffix the updateType suffix to append, useful for networks with several instances
   * @param hubConfigurator the address of the Aave v4 HubConfigurator
   */
  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateTypeSuffix,
    address hubConfigurator
  )
    BaseAaveV4Agent(
      agentHub,
      rangeValidationModule,
      'RateStrategyUpdate',
      updateTypeSuffix,
      hubConfigurator
    )
  {}

  function _isHubLevel() internal pure override returns (bool) {
    return true;
  }

  function _configuratorSelector() internal pure override returns (bytes4) {
    return IHubConfigurator.updateInterestRateData.selector;
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, uint256[4] memory current, uint256[4] memory next) = _rates(market, value);
    if (
      !ok ||
      (current[0] == next[0] &&
        current[1] == next[1] &&
        current[2] == next[2] &&
        current[3] == next[3])
    ) {
      return false;
    }

    IRangeValidationModule.RangeValidationInput[]
      memory input = new IRangeValidationModule.RangeValidationInput[](4);
    input[0] = IRangeValidationModule.RangeValidationInput({
      from: current[0],
      to: next[0],
      updateType: 'OptimalUsageRatio'
    });
    input[1] = IRangeValidationModule.RangeValidationInput({
      from: current[1],
      to: next[1],
      updateType: 'BaseVariableBorrowRate'
    });
    input[2] = IRangeValidationModule.RangeValidationInput({
      from: current[2],
      to: next[2],
      updateType: 'VariableRateSlope1'
    });
    input[3] = IRangeValidationModule.RangeValidationInput({
      from: current[3],
      to: next[3],
      updateType: 'VariableRateSlope2'
    });

    return RANGE_VALIDATION_MODULE.validate(AGENT_HUB, agentId, update.market, input);
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal override {
    (, uint256 assetId) = _assetId(market.hub, market.asset);
    IHubConfigurator(CONFIGURATOR).updateInterestRateData(market.hub, assetId, value);
  }

  function _rates(
    Market memory market,
    bytes calldata value
  ) internal view returns (bool, uint256[4] memory current, uint256[4] memory next) {
    (bool ok, uint256 assetId) = _assetId(market.hub, market.asset);
    if (!ok || !_configuratorCanCall(market.hub, IHub.setInterestRateData.selector))
      return (false, current, next);

    (ok, next) = _decodeRates(value);
    if (!ok) return (false, current, next);

    uint256[] memory words;
    (ok, words) = _staticcallWords(market.hub, abi.encodeCall(IHub.getAssetConfig, (assetId)), 4);
    address strategy = address(uint160(words[2]));
    if (!ok || words[2] >> 160 != 0 || !_withinStrategyBounds(strategy, next)) {
      return (false, current, next);
    }

    (ok, words) = _staticcallWords(
      strategy,
      abi.encodeCall(IAssetInterestRateStrategy.getInterestRateData, (assetId)),
      4
    );
    if (!ok) return (false, current, next);
    current = [words[0], words[1], words[2], words[3]];
    return (true, current, next);
  }

  function _decodeRates(
    bytes calldata value
  ) internal pure returns (bool, uint256[4] memory rates) {
    if (value.length != 128) return (false, rates);
    rates = abi.decode(value, (uint256[4]));
    if (
      rates[0] > type(uint16).max ||
      rates[1] > type(uint32).max ||
      rates[2] > type(uint32).max ||
      rates[3] > type(uint32).max
    ) return (false, rates);
    return (true, rates);
  }

  function _withinStrategyBounds(
    address strategy,
    uint256[4] memory rates
  ) internal view returns (bool) {
    (bool ok, uint256 bound) = _staticcallWord(
      strategy,
      abi.encodeCall(IAssetInterestRateStrategy.MIN_OPTIMAL_RATIO, ())
    );
    if (!ok || rates[0] < bound || rates[0] == 0) return false;

    (ok, bound) = _staticcallWord(
      strategy,
      abi.encodeCall(IAssetInterestRateStrategy.MAX_OPTIMAL_RATIO, ())
    );
    if (!ok || rates[0] > bound) return false;

    (ok, bound) = _staticcallWord(
      strategy,
      abi.encodeCall(IAssetInterestRateStrategy.MAX_ALLOWED_DRAWN_RATE, ())
    );
    uint256 maxDrawnRate = rates[1] + rates[2] + rates[3];
    return ok && maxDrawnRate <= bound && maxDrawnRate <= type(uint32).max;
  }
}
