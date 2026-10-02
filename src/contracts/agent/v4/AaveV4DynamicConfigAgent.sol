// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {SafeCast} from 'openzeppelin-contracts/contracts/utils/math/SafeCast.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentConfigurator.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {IOwnable} from 'chaos-agents/src/contracts/dependencies/IOwnable.sol';

import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../dependencies/v4/ISpokeConfigurator.sol';
import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';

/**
 * @title AaveV4DynamicConfigAgent
 * @author LlamaRisk
 * @notice Writes Aave v4 dynamic reserve configs. LB_IN_PLACE sets the max liquidation bonus on
 *         the live keys of a reserve. CF_ADD adds a key with a new collateral factor. PT adds a key
 *         with a new collateral factor and max liquidation bonus. Values must stay inside a band per
 *         market set by the AgentHub owner, which the agent admin can only tighten.
 */
contract AaveV4DynamicConfigAgent is BaseAaveV4Agent {
  using SafeCast for uint256;

  enum Mode {
    LB_IN_PLACE,
    CF_ADD,
    PT
  }

  enum Field {
    CF,
    LB
  }

  struct Band {
    uint32 min;
    uint32 max;
  }

  struct Target {
    address market;
    address spoke;
    uint256 reserveId;
    uint32 lastKey;
    ISpoke.DynamicReserveConfig latest;
  }

  uint256 public constant PERCENTAGE_FACTOR = 100_00;
  uint256 public constant MAX_KEYS_LIMIT = 32;
  string internal constant CF_RANGE_TYPE = 'CollateralFactor';
  string internal constant LB_RANGE_TYPE = 'MaxLiquidationBonus';

  Mode public immutable MODE;
  uint256 public immutable MAX_KEYS_PER_UPDATE;

  mapping(address market => mapping(Field field => Band)) public bands;
  mapping(address market => uint32) public minLiveKey;

  event BandSet(address indexed market, Field indexed field, uint32 min, uint32 max);
  event MinLiveKeySet(address indexed market, uint32 key);
  event MaxLiquidationBonusUpdated(
    address indexed market,
    uint256 reserveId,
    uint32[] keys,
    uint32 maxLiquidationBonus
  );
  event DynamicConfigAdded(
    address indexed market,
    uint256 reserveId,
    uint32 key,
    uint16 collateralFactor,
    uint32 maxLiquidationBonus
  );

  error Unauthorized(address caller);
  error InvalidBand();
  error InvalidKey();
  error InvalidMaxKeys();

  constructor(
    address agentHub,
    address rangeValidationModule,
    address configurator,
    Mode mode,
    string memory updateTypeSuffix,
    uint256 maxKeysPerUpdate
  )
    BaseAaveV4Agent(
      agentHub,
      rangeValidationModule,
      _updateTypeOf(mode),
      updateTypeSuffix,
      configurator
    )
  {
    require(maxKeysPerUpdate != 0 && maxKeysPerUpdate <= MAX_KEYS_LIMIT, InvalidMaxKeys());
    MODE = mode;
    MAX_KEYS_PER_UPDATE = maxKeysPerUpdate;
  }

  /// @notice Sets the band of a field for a market. Only the AgentHub owner.
  function setBand(
    address hub,
    address spoke,
    address asset,
    Field field,
    uint32 min,
    uint32 max
  ) external {
    require(msg.sender == IOwnable(AGENT_HUB).owner(), Unauthorized(msg.sender));
    require(
      min <= max &&
        (field == Field.CF ? min != 0 && max < PERCENTAGE_FACTOR : min >= PERCENTAGE_FACTOR),
      InvalidBand()
    );
    _setBand(marketId(hub, spoke, asset), field, min, max);
  }

  /// @notice Narrows the band of a field for a market. Only the agent admin.
  function tightenBand(
    uint256 agentId,
    address hub,
    address spoke,
    address asset,
    Field field,
    uint32 min,
    uint32 max
  ) external {
    address market = marketId(hub, spoke, asset);
    require(_isAgentAdmin(agentId, msg.sender, market), Unauthorized(msg.sender));
    Band memory band = bands[market][field];
    require(band.max != 0 && min >= band.min && max <= band.max && min <= max, InvalidBand());
    _setBand(market, field, min, max);
  }

  /// @notice Sets the first dynamic config key that LB_IN_PLACE updates for a market. The agent
  ///         admin can only raise it.
  function setMinLiveKey(
    uint256 agentId,
    address hub,
    address spoke,
    address asset,
    uint32 key
  ) external {
    address market = marketId(hub, spoke, asset);
    bool isOwner = msg.sender == IOwnable(AGENT_HUB).owner();
    require(isOwner || _isAgentAdmin(agentId, msg.sender, market), Unauthorized(msg.sender));
    (bool listed, , uint256 reserveId) = _reserveId(hub, spoke, asset);
    uint32 lastKey;
    if (listed) (listed, lastKey) = _dynamicConfigKey(spoke, reserveId);
    require(listed && key <= lastKey && (isOwner || key >= minLiveKey[market]), InvalidKey());
    minLiveKey[market] = key;
    emit MinLiveKeySet(market, key);
  }

  function _configuratorSelector() internal view override returns (bytes4) {
    if (MODE == Mode.LB_IN_PLACE) return ISpokeConfigurator.updateMaxLiquidationBonus.selector;
    if (MODE == Mode.CF_ADD) return ISpokeConfigurator.addCollateralFactor.selector;
    return ISpokeConfigurator.addDynamicReserveConfig.selector;
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, Target memory target) = _target(update.market, market);
    if (!ok) return false;

    IRangeValidationModule.RangeValidationInput[] memory inputs;
    if (MODE == Mode.LB_IN_PLACE) {
      uint32[] memory keys;
      (keys, inputs) = _liveKeyUpdates(target, value);
      if (keys.length == 0) return false;
    } else {
      (ok, inputs) = _newKeyUpdate(target, value);
      if (!ok) return false;
    }
    return RANGE_VALIDATION_MODULE.validate(AGENT_HUB, agentId, update.market, inputs);
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal override {
    (, Target memory target) = _target(update.market, market);

    if (MODE == Mode.LB_IN_PLACE) {
      (uint32[] memory keys, ) = _liveKeyUpdates(target, value);
      uint256 bonus = uint256(bytes32(value));
      for (uint256 i = 0; i < keys.length; i++) {
        ISpokeConfigurator(CONFIGURATOR).updateMaxLiquidationBonus(
          target.spoke,
          target.reserveId,
          keys[i],
          bonus
        );
      }
      emit MaxLiquidationBonusUpdated(target.market, target.reserveId, keys, bonus.toUint32());
      return;
    }

    (, uint256 cf, uint256 lb) = _decodeNewKey(target, value);
    uint32 key;
    if (MODE == Mode.CF_ADD) {
      key = ISpokeConfigurator(CONFIGURATOR).addCollateralFactor(
        target.spoke,
        target.reserveId,
        cf.toUint16()
      );
    } else {
      key = ISpokeConfigurator(CONFIGURATOR).addDynamicReserveConfig(
        target.spoke,
        target.reserveId,
        ISpoke.DynamicReserveConfig({
          collateralFactor: cf.toUint16(),
          maxLiquidationBonus: lb.toUint32(),
          liquidationFee: target.latest.liquidationFee
        })
      );
    }
    emit DynamicConfigAdded(target.market, target.reserveId, key, cf.toUint16(), lb.toUint32());
  }

  function _target(
    address id,
    Market memory market
  ) internal view returns (bool, Target memory target) {
    bool listed;
    (listed, , target.reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    if (
      !listed ||
      !_configuratorCanCall(
        market.spoke,
        MODE == Mode.LB_IN_PLACE
          ? ISpoke.updateDynamicReserveConfig.selector
          : ISpoke.addDynamicReserveConfig.selector
      )
    ) {
      return (false, target);
    }

    target.market = id;
    target.spoke = market.spoke;
    bool ok;
    (ok, target.lastKey, target.latest) = _latestDynamicReserveConfig(
      market.spoke,
      target.reserveId
    );
    if (!ok || target.latest.collateralFactor == 0) return (false, target);
    ISpoke.ReserveConfig memory config;
    (ok, config) = _reserveConfig(market.spoke, target.reserveId);
    return (ok && !config.frozen, target);
  }

  function _liveKeyUpdates(
    Target memory target,
    bytes calldata value
  )
    internal
    view
    returns (uint32[] memory keys, IRangeValidationModule.RangeValidationInput[] memory inputs)
  {
    (bool ok, uint256 lb) = _decodeUint(value, type(uint32).max);
    uint256 first = minLiveKey[target.market];
    if (
      !ok ||
      !_inBand(target.market, Field.LB, lb) ||
      first > target.lastKey ||
      target.lastKey - first >= MAX_KEYS_PER_UPDATE
    ) {
      return (keys, inputs);
    }

    keys = new uint32[](target.lastKey - first + 1);
    uint256 count;
    for (uint256 key = first; key <= target.lastKey; key++) {
      (bool read, ISpoke.DynamicReserveConfig memory config) = _dynamicReserveConfig(
        target.spoke,
        target.reserveId,
        uint32(key)
      );
      if (!read) return (new uint32[](0), inputs);
      // Keys with CF 0 cannot be updated on v4 and positions bound to them cannot be liquidated.
      if (config.collateralFactor == 0 || config.maxLiquidationBonus == lb) continue;
      if (!_isSafe(config.collateralFactor, lb)) return (new uint32[](0), inputs);
      keys[count++] = uint32(key);
    }
    assembly ('memory-safe') {
      mstore(keys, count)
    }
    // One step check against the latest key, so live keys that drifted apart cannot stall updates.
    inputs = new IRangeValidationModule.RangeValidationInput[](1);
    inputs[0] = IRangeValidationModule.RangeValidationInput({
      from: target.latest.maxLiquidationBonus,
      to: lb,
      updateType: LB_RANGE_TYPE
    });
  }

  function _newKeyUpdate(
    Target memory target,
    bytes calldata value
  ) internal view returns (bool, IRangeValidationModule.RangeValidationInput[] memory inputs) {
    (bool ok, uint256 cf, uint256 lb) = _decodeNewKey(target, value);
    if (
      !ok ||
      target.lastKey == type(uint32).max ||
      (cf == target.latest.collateralFactor && lb == target.latest.maxLiquidationBonus)
    ) {
      return (false, inputs);
    }

    inputs = new IRangeValidationModule.RangeValidationInput[](MODE == Mode.PT ? 2 : 1);
    inputs[0] = IRangeValidationModule.RangeValidationInput({
      from: target.latest.collateralFactor,
      to: cf,
      updateType: CF_RANGE_TYPE
    });
    if (MODE == Mode.PT) {
      inputs[1] = IRangeValidationModule.RangeValidationInput({
        from: target.latest.maxLiquidationBonus,
        to: lb,
        updateType: LB_RANGE_TYPE
      });
    }
    return (true, inputs);
  }

  function _decodeNewKey(
    Target memory target,
    bytes calldata value
  ) internal view returns (bool, uint256 cf, uint256 lb) {
    if (MODE == Mode.CF_ADD) {
      bool ok;
      (ok, cf) = _decodeUint(value, type(uint16).max);
      lb = target.latest.maxLiquidationBonus;
      if (!ok) return (false, cf, lb);
    } else {
      if (value.length != 64) return (false, cf, lb);
      cf = uint256(bytes32(value[0:32]));
      lb = uint256(bytes32(value[32:64]));
      if (cf > type(uint16).max || lb > type(uint32).max || !_inBand(target.market, Field.LB, lb)) {
        return (false, cf, lb);
      }
    }
    return (_inBand(target.market, Field.CF, cf) && _isSafe(cf, lb), cf, lb);
  }

  function _inBand(address market, Field field, uint256 value) internal view returns (bool) {
    Band memory band = bands[market][field];
    return band.max != 0 && value >= band.min && value <= band.max;
  }

  function _isSafe(uint256 cf, uint256 lb) internal pure returns (bool) {
    return
      cf != 0 &&
      cf < PERCENTAGE_FACTOR &&
      lb >= PERCENTAGE_FACTOR &&
      lb * cf <= (PERCENTAGE_FACTOR - 1) * PERCENTAGE_FACTOR;
  }

  function _isAgentAdmin(
    uint256 agentId,
    address account,
    address market
  ) internal view returns (bool) {
    IAgentConfigurator hub = IAgentConfigurator(AGENT_HUB);
    if (
      hub.getAgentAddress(agentId) != address(this) ||
      hub.getAgentAdmin(agentId) != account ||
      !hub.isAgentEnabled(agentId)
    ) {
      return false;
    }
    return _contains(hub.getAllowedMarkets(agentId), market);
  }

  function _setBand(address market, Field field, uint32 min, uint32 max) internal {
    bands[market][field] = Band({min: min, max: max});
    emit BandSet(market, field, min, max);
  }

  function _updateTypeOf(Mode mode) internal pure returns (string memory) {
    if (mode == Mode.LB_IN_PLACE) return 'MaxLiquidationBonusUpdate';
    if (mode == Mode.CF_ADD) return 'CollateralFactorUpdate';
    return 'PtDynamicConfigUpdate';
  }
}
