// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IPendlePriceCapAdapter} from 'aave-price-feeds/interfaces/IPendlePriceCapAdapter.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';

import {BaseAaveV4AdapterAgent} from './BaseAaveV4AdapterAgent.sol';

/**
 * @title AaveV4DiscountRateAgent
 * @author LlamaRisk
 * @notice Updates the yearly discount rate of the Pendle PT adapter of an Aave v4 reserve.
 *         The value is abi.encode(uint256 discountRatePerYear).
 */
contract AaveV4DiscountRateAgent is BaseAaveV4AdapterAgent {
  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateTypeSuffix,
    address aclManager
  )
    BaseAaveV4AdapterAgent(
      agentHub,
      rangeValidationModule,
      'PendleDiscountRateUpdate',
      updateTypeSuffix,
      aclManager
    )
  {}

  function _configuratorSelector() internal pure override returns (bytes4) {
    return IPendlePriceCapAdapter.setDiscountRatePerYear.selector;
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, uint256 discountRate) = _decodeUint(value, type(uint64).max);
    if (!ok || discountRate == 0) return false;

    address adapter = _adapter(market);
    if (adapter == address(0)) return false;

    uint256 currentDiscountRate;
    (ok, currentDiscountRate) = _read(adapter, IPendlePriceCapAdapter.discountRatePerYear.selector);
    if (!ok || currentDiscountRate == discountRate || !_isValidRate(adapter, discountRate)) {
      return false;
    }

    return
      RANGE_VALIDATION_MODULE.validate(
        AGENT_HUB,
        agentId,
        update.market,
        IRangeValidationModule.RangeValidationInput({
          from: currentDiscountRate,
          to: discountRate,
          updateType: update.updateType
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
    IPendlePriceCapAdapter(_adapter(market)).setDiscountRatePerYear(abi.decode(value, (uint64)));
  }

  function _isValidRate(address adapter, uint256 discountRate) internal view returns (bool) {
    (bool ok, uint256 maxDiscountRate) = _read(
      adapter,
      IPendlePriceCapAdapter.MAX_DISCOUNT_RATE_PER_YEAR.selector
    );
    if (!ok || discountRate > maxDiscountRate) return false;

    uint256 maturity;
    (ok, maturity) = _read(adapter, IPendlePriceCapAdapter.MATURITY.selector);
    if (!ok || maturity < block.timestamp || maturity > type(uint64).max) return false;

    uint256 percentageFactor;
    uint256 secondsPerYear;
    (ok, percentageFactor) = _read(adapter, IPendlePriceCapAdapter.PERCENTAGE_FACTOR.selector);
    if (!ok) return false;
    (ok, secondsPerYear) = _read(adapter, IPendlePriceCapAdapter.SECONDS_PER_YEAR.selector);
    if (!ok || secondsPerYear == 0) return false;

    return ((maturity - block.timestamp) * discountRate) / secondsPerYear < percentageFactor;
  }
}
