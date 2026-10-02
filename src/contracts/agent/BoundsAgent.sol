// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {BaseAgent} from 'chaos-agents/src/contracts/agent/BaseAgent.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {ShortStrings, ShortString} from 'openzeppelin-contracts/contracts/utils/ShortStrings.sol';
import {Strings} from 'openzeppelin-contracts/contracts/utils/Strings.sol';

import {IACLManager, IBoundedRatioAdapter} from '../dependencies/IBoundedRatioAdapter.sol';

/**
 * @title BoundsAgent
 * @author LlamaRisk
 * @notice Agent that sets the lower bound of bounded ratio adapters. The update market is the
 *         adapter and the update value is abi.encode(uint256 lowerBound, uint256 expiration).
 *         The lower bound must not exceed the adapter getLowerBoundLimit and moves within the range
 *         validation config from the active lower bound, or from the ratio when no lower bound is
 *         active or the active one is above the ratio.
 */
contract BoundsAgent is BaseAgent {
  using Strings for string;
  using ShortStrings for *;

  string public constant LOWER_BOUND_RANGE_TYPE = 'RatioLowerBound';

  IRangeValidationModule public immutable RANGE_VALIDATION_MODULE;
  ShortString public immutable UPDATE_TYPE;
  uint48 public immutable MAX_LOWER_BOUND_DURATION;

  error InvalidZeroAddress();
  error InvalidMaxLowerBoundDuration();
  error InvalidUpdate();

  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateTypeSuffix,
    uint48 maxLowerBoundDuration
  ) BaseAgent(agentHub) {
    require(agentHub != address(0) && rangeValidationModule != address(0), InvalidZeroAddress());
    require(maxLowerBoundDuration != 0, InvalidMaxLowerBoundDuration());
    RANGE_VALIDATION_MODULE = IRangeValidationModule(rangeValidationModule);
    UPDATE_TYPE = string.concat('RatioLowerBoundUpdate', updateTypeSuffix).toShortString();
    MAX_LOWER_BOUND_DURATION = maxLowerBoundDuration;
  }

  /// @inheritdoc BaseAgent
  function validate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update
  ) external view override returns (bool) {
    (bool valid, , ) = _checkUpdate(agentId, update);
    return valid;
  }

  /// @inheritdoc BaseAgent
  function getMarkets(uint256) external pure override returns (address[] memory) {
    return new address[](0);
  }

  /// @notice Returns the update type of the agent.
  function getUpdateType() external view returns (string memory) {
    return UPDATE_TYPE.toString();
  }

  function _processUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal override {
    (bool valid, uint104 lowerBound, uint48 expiration) = _checkUpdate(agentId, update);
    require(valid, InvalidUpdate());
    IBoundedRatioAdapter(update.market).setLowerBound(lowerBound, expiration);
  }

  function _checkUpdate(
    uint256 agentId,
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal view returns (bool, uint104, uint48) {
    bytes calldata data = update.newValue;
    if (data.length != 64 || !update.updateType.equal(UPDATE_TYPE.toString())) {
      return (false, 0, 0);
    }
    uint256 lowerBound = uint256(bytes32(data[0:32]));
    uint256 expiration = uint256(bytes32(data[32:64]));
    if (
      lowerBound == 0 ||
      lowerBound > type(uint104).max ||
      expiration <= block.timestamp ||
      expiration > block.timestamp + MAX_LOWER_BOUND_DURATION ||
      !_checkAdapter(agentId, update.market, lowerBound, expiration)
    ) {
      return (false, 0, 0);
    }
    return (true, uint104(lowerBound), uint48(expiration));
  }

  function _checkAdapter(
    uint256 agentId,
    address adapter,
    uint256 lowerBound,
    uint256 expiration
  ) internal view returns (bool) {
    (bool ok, uint256 value, ) = _read(
      adapter,
      abi.encodeCall(IBoundedRatioAdapter.MAXIMUM_LOWER_BOUND_DURATION, ()),
      0x20
    );
    if (!ok || expiration - block.timestamp > value) return false;

    (ok, value, ) = _read(
      adapter,
      abi.encodeCall(IBoundedRatioAdapter.getLowerBoundLimit, ()),
      0x20
    );
    if (!ok || lowerBound > value) return false;

    uint256 storedLowerBound;
    uint256 storedExpiration;
    (ok, storedLowerBound, storedExpiration) = _read(
      adapter,
      abi.encodeCall(IBoundedRatioAdapter.getLowerBound, ()),
      0x40
    );
    if (
      !ok ||
      (lowerBound == storedLowerBound && expiration == storedExpiration) ||
      !_isRiskOrPoolAdmin(adapter)
    ) {
      return false;
    }
    value = _stepFrom(_getRatio(adapter), value, storedLowerBound, storedExpiration);

    return
      RANGE_VALIDATION_MODULE.validate(
        AGENT_HUB,
        agentId,
        adapter,
        IRangeValidationModule.RangeValidationInput({
          from: value,
          to: lowerBound,
          updateType: LOWER_BOUND_RANGE_TYPE
        })
      );
  }

  /// @dev without a valid ratio the step starts at the stored lower bound, or the adapter limit if none is stored
  function _stepFrom(
    uint256 ratio,
    uint256 limit,
    uint256 storedLowerBound,
    uint256 storedExpiration
  ) internal view returns (uint256) {
    if (ratio == 0) return storedLowerBound == 0 ? limit : storedLowerBound;
    uint256 activeLowerBound = block.timestamp < storedExpiration ? storedLowerBound : 0;
    return activeLowerBound == 0 || activeLowerBound > ratio ? ratio : activeLowerBound;
  }

  function _getRatio(address adapter) internal view returns (uint256) {
    (bool ok, uint256 ratio, ) = _read(
      adapter,
      abi.encodeCall(IBoundedRatioAdapter.getRatio, ()),
      0x20
    );
    return ok && ratio >> 255 == 0 ? ratio : 0;
  }

  function _isRiskOrPoolAdmin(address adapter) internal view returns (bool) {
    (bool ok, uint256 word, ) = _read(
      adapter,
      abi.encodeCall(IBoundedRatioAdapter.ACL_MANAGER, ()),
      0x20
    );
    if (!ok || word >> 160 != 0) return false;

    address aclManager = address(uint160(word));
    (ok, word, ) = _read(
      aclManager,
      abi.encodeCall(IACLManager.isRiskAdmin, (address(this))),
      0x20
    );
    if (ok && word == 1) return true;
    (ok, word, ) = _read(
      aclManager,
      abi.encodeCall(IACLManager.isPoolAdmin, (address(this))),
      0x20
    );
    return ok && word == 1;
  }

  function _read(
    address target,
    bytes memory data,
    uint256 size
  ) private view returns (bool ok, uint256 first, uint256 second) {
    assembly ('memory-safe') {
      ok := staticcall(gas(), target, add(data, 0x20), mload(data), 0x00, size)
      ok := and(ok, eq(returndatasize(), size))
      first := mul(mload(0x00), ok)
      second := mul(mload(0x20), and(ok, eq(size, 0x40)))
    }
  }
}
