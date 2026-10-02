// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IPriceCapAdapter} from 'aave-price-feeds/interfaces/IPriceCapAdapter.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';

import {BaseAaveV4AdapterAgent} from './BaseAaveV4AdapterAgent.sol';

/**
 * @title AaveV4CapoAgent
 * @author LlamaRisk
 * @notice Updates the snapshot ratio, snapshot timestamp and max yearly growth of the CAPO adapter
 *         of an Aave v4 reserve. The value is abi.encode(IPriceCapAdapter.PriceCapUpdateParams).
 */
contract AaveV4CapoAgent is BaseAaveV4AdapterAgent {
  bytes4 internal constant MINIMAL_RATIO_INCREASE_LIFETIME =
    bytes4(keccak256('MINIMAL_RATIO_INCREASE_LIFETIME()'));
  uint256 internal constant PERCENTAGE_FACTOR = 1e4;
  uint256 internal constant SECONDS_PER_YEAR = 365 days;

  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateTypeSuffix,
    address aclManager,
    address[] memory hubs,
    address[] memory v3Oracles
  )
    BaseAaveV4AdapterAgent(
      agentHub,
      rangeValidationModule,
      'CapoPriceCapUpdate',
      updateTypeSuffix,
      aclManager,
      hubs,
      v3Oracles
    )
  {}

  function _configuratorSelector() internal pure override returns (bytes4) {
    return IPriceCapAdapter.setCapParameters.selector;
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, IPriceCapAdapter.PriceCapUpdateParams memory params) = _decodeCapParams(value);
    if (!ok) return false;

    address adapter = _adapter(agentId, market);
    if (adapter == address(0) || !_isValidSnapshot(adapter, params)) return false;

    IRangeValidationModule.RangeValidationInput[] memory input;
    (ok, input) = _rangeInput(adapter, params);
    return ok && RANGE_VALIDATION_MODULE.validate(AGENT_HUB, agentId, adapter, input);
  }

  function _injectUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal override {
    (, IPriceCapAdapter.PriceCapUpdateParams memory params) = _decodeCapParams(value);
    IPriceCapAdapter(_writeAdapter(agentId, market)).setCapParameters(params);
  }

  function _rangeInput(
    address adapter,
    IPriceCapAdapter.PriceCapUpdateParams memory params
  ) internal view returns (bool, IRangeValidationModule.RangeValidationInput[] memory input) {
    (bool ok, uint256 snapshotRatio) = _read(adapter, IPriceCapAdapter.getSnapshotRatio.selector);
    if (!ok) return (false, input);
    uint256 maxYearlyGrowth;
    (ok, maxYearlyGrowth) = _read(adapter, IPriceCapAdapter.getMaxYearlyGrowthRatePercent.selector);
    if (!ok) return (false, input);

    input = new IRangeValidationModule.RangeValidationInput[](2);
    input[0] = IRangeValidationModule.RangeValidationInput({
      from: snapshotRatio,
      to: params.snapshotRatio,
      updateType: 'CapoSnapshotRatio'
    });
    input[1] = IRangeValidationModule.RangeValidationInput({
      from: maxYearlyGrowth,
      to: params.maxYearlyRatioGrowthPercent,
      updateType: 'CapoMaxYearlyGrowthRatePercent'
    });
    return (true, input);
  }

  function _isValidSnapshot(
    address adapter,
    IPriceCapAdapter.PriceCapUpdateParams memory params
  ) internal view returns (bool) {
    (bool ok, uint256 snapshotTimestamp) = _read(
      adapter,
      IPriceCapAdapter.getSnapshotTimestamp.selector
    );
    if (!ok || params.snapshotRatio == 0 || params.snapshotTimestamp <= snapshotTimestamp) {
      return false;
    }

    uint256 minimumDelay;
    (ok, minimumDelay) = _read(adapter, IPriceCapAdapter.MINIMUM_SNAPSHOT_DELAY.selector);
    if (
      !ok ||
      minimumDelay > block.timestamp ||
      params.snapshotTimestamp > block.timestamp - minimumDelay
    ) {
      return false;
    }

    // adapters deployed before MAXIMUM_SNAPSHOT_TERM existed have no maximum snapshot age
    uint256 maximumTerm;
    (ok, maximumTerm) = _read(adapter, IPriceCapAdapter.MAXIMUM_SNAPSHOT_TERM.selector);
    if (
      ok &&
      (maximumTerm > block.timestamp || params.snapshotTimestamp < block.timestamp - maximumTerm)
    ) {
      return false;
    }

    // older adapters revert with SnapshotMayOverflowSoon past this bound
    uint256 lifetime;
    (ok, lifetime) = _read(adapter, MINIMAL_RATIO_INCREASE_LIFETIME);
    if (!ok) return true;
    uint256 growthPerSecond = (uint256(params.snapshotRatio) * params.maxYearlyRatioGrowthPercent) /
      PERCENTAGE_FACTOR /
      SECONDS_PER_YEAR;
    return
      lifetime <= type(uint32).max &&
      params.snapshotRatio + growthPerSecond * SECONDS_PER_YEAR * lifetime <= type(uint104).max;
  }

  function _decodeCapParams(
    bytes calldata value
  ) internal pure returns (bool, IPriceCapAdapter.PriceCapUpdateParams memory params) {
    if (value.length != 96) return (false, params);

    uint256 snapshotRatio = uint256(bytes32(value[0:32]));
    uint256 snapshotTimestamp = uint256(bytes32(value[32:64]));
    uint256 maxYearlyGrowth = uint256(bytes32(value[64:96]));
    if (
      snapshotRatio > type(uint104).max ||
      snapshotTimestamp > type(uint48).max ||
      maxYearlyGrowth > type(uint16).max
    ) {
      return (false, params);
    }

    return (true, abi.decode(value, (IPriceCapAdapter.PriceCapUpdateParams)));
  }
}
