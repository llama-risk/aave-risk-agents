// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';

import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';
import {IBoundedPriceAdapter} from '../../dependencies/adapters/IBoundedPriceAdapter.sol';
import {IB20OracleRegistry} from '../../dependencies/b20/IB20OracleRegistry.sol';
import {IAaveOracle} from '../../dependencies/v4/IAaveOracle.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../dependencies/v4/ISpokeConfigurator.sol';

/**
 * @title AaveV4PauseAgent
 * @author LlamaRisk
 * @notice Pauses Aave v4 spoke reserves and never unpauses them. The update value is
 *         abi.encode(uint256(1)). Anyone can poke a market to pause its reserve while the
 *         issuer oracle registry reports the asset paused (if issuer poke is enabled for the
 *         market) or while the reserve's oracle source reports isBreached() (if adapter poke is
 *         enabled for the market). Poke follows the AgentHub market gating. Updates published at
 *         or before the agent's last pause of a market, or before an admin invalidation, are
 *         invalid.
 */
contract AaveV4PauseAgent is BaseAaveV4Agent {
  IB20OracleRegistry public immutable ISSUER_REGISTRY;

  uint256 public hubAgentId;
  bool public isHubAgentIdSet;
  mapping(address market => bool) public isIssuerPokeEnabled;
  mapping(address market => bool) public isAdapterPokeEnabled;
  mapping(address market => uint256) public updatesInvalidUntil;

  event HubAgentIdSet(uint256 indexed agentId);
  event IssuerPokeEnabledSet(
    address indexed market,
    address hub,
    address spoke,
    address asset,
    bool enabled
  );
  event AdapterPokeEnabledSet(
    address indexed market,
    address hub,
    address spoke,
    address asset,
    bool enabled
  );
  event UpdatesInvalidated(
    address indexed market,
    address hub,
    address spoke,
    address asset,
    uint256 until
  );
  event Poked(
    address indexed market,
    uint256 reserveId,
    address indexed caller,
    bool issuerPaused,
    bool adapterBreached
  );

  error OnlyAgentHubOwner(address caller);
  error OnlyAgentHubOwnerOrAgentAdmin(address caller);
  error HubAgentIdNotSet();
  error NotRegisteredAgent(uint256 agentId);
  error IssuerRegistryNotSet();
  error InvalidMarket();
  error InvalidPriceAdapter(address adapter);
  error PokeDisabled(address market);
  error AgentDisabled();
  error MarketNotAllowed(address market);
  error ReserveNotListed(address market);
  error ReserveAlreadyPaused(address market);
  error PokeConditionNotMet(address market);

  constructor(
    address agentHub,
    address rangeValidationModule,
    address configurator,
    address issuerRegistry
  ) BaseAaveV4Agent(agentHub, rangeValidationModule, 'ReservePause', '', configurator) {
    ISSUER_REGISTRY = IB20OracleRegistry(issuerRegistry);
  }

  /// @notice Sets the AgentHub id of this agent. Only the AgentHub owner can call it.
  function setHubAgentId(uint256 agentId) external {
    require(msg.sender == Ownable(AGENT_HUB).owner(), OnlyAgentHubOwner(msg.sender));
    require(
      IAgentHub(AGENT_HUB).getAgentAddress(agentId) == address(this),
      NotRegisteredAgent(agentId)
    );
    hubAgentId = agentId;
    isHubAgentIdSet = true;
    emit HubAgentIdSet(agentId);
  }

  /// @notice Enables or disables the issuer flag trigger of poke for a market.
  /// @dev Only the AgentHub owner or the agent admin can call it.
  function setIssuerPokeEnabled(address hub, address spoke, address asset, bool enabled) external {
    address market = _checkMarketAdmin(hub, spoke, asset);
    require(!enabled || address(ISSUER_REGISTRY) != address(0), IssuerRegistryNotSet());

    isIssuerPokeEnabled[market] = enabled;
    emit IssuerPokeEnabledSet(market, hub, spoke, asset, enabled);
  }

  /// @notice Enables or disables the isBreached() trigger of poke for a market. Poke reads the
  ///         live reserve source from the spoke oracle, so the trigger follows source changes.
  /// @dev Only the AgentHub owner or the agent admin can call it.
  function setAdapterPokeEnabled(address hub, address spoke, address asset, bool enabled) external {
    address market = _checkMarketAdmin(hub, spoke, asset);
    if (enabled) {
      (bool listed, , uint256 reserveId) = _reserveId(hub, spoke, asset);
      require(listed, ReserveNotListed(market));
      address source = _reserveSource(spoke, reserveId);
      (bool ok, uint256 breached) = _staticcallWord(
        source,
        abi.encodeCall(IBoundedPriceAdapter.isBreached, ())
      );
      require(source != address(0) && ok && breached <= 1, InvalidPriceAdapter(source));
    }

    isAdapterPokeEnabled[market] = enabled;
    emit AdapterPokeEnabledSet(market, hub, spoke, asset, enabled);
  }

  /// @notice Invalidates every update of a market published up to now. Run it before an unpause
  ///         so that updates published while the reserve was paused cannot pause it again.
  /// @dev Only the AgentHub owner or the agent admin can call it.
  function invalidateUpdates(address hub, address spoke, address asset) external {
    address market = _checkMarketAdmin(hub, spoke, asset);
    updatesInvalidUntil[market] = block.timestamp;
    emit UpdatesInvalidated(market, hub, spoke, asset, block.timestamp);
  }

  /// @notice Pauses the reserve of (hub, spoke, asset) if the issuer registry reports the asset
  ///         paused or the reserve's oracle source reports a breach.
  function poke(address hub, address spoke, address asset) external {
    address market = marketId(hub, spoke, asset);
    bool adapterPokeEnabled = isAdapterPokeEnabled[market];
    bool issuerPokeEnabled = isIssuerPokeEnabled[market];
    require(issuerPokeEnabled || adapterPokeEnabled, PokeDisabled(market));
    require(
      IAgentHub(AGENT_HUB).getAgentAddress(hubAgentId) == address(this) &&
        IAgentHub(AGENT_HUB).isAgentEnabled(hubAgentId),
      AgentDisabled()
    );
    require(_isHubMarket(market), MarketNotAllowed(market));

    (bool listed, , uint256 reserveId) = _reserveId(hub, spoke, asset);
    ISpoke.ReserveConfig memory config;
    if (listed) (listed, config) = _reserveConfig(spoke, reserveId);
    require(listed, ReserveNotListed(market));
    require(!config.paused, ReserveAlreadyPaused(market));

    bool issuerPaused = issuerPokeEnabled && _isIssuerPaused(asset);
    bool adapterBreached = adapterPokeEnabled &&
      _isAdapterBreached(_reserveSource(spoke, reserveId));
    require(issuerPaused || adapterBreached, PokeConditionNotMet(market));

    updatesInvalidUntil[market] = block.timestamp;
    ISpokeConfigurator(CONFIGURATOR).pauseReserve(spoke, reserveId);
    emit Poked(market, reserveId, msg.sender, issuerPaused, adapterBreached);
  }

  function _configuratorSelector() internal pure override returns (bytes4) {
    return ISpokeConfigurator.pauseReserve.selector;
  }

  function _validateUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, uint256 pause) = _decodeUint(value, 1);
    if (!ok || pause != 1 || update.timestamp <= updatesInvalidUntil[update.market]) return false;
    if (!_configuratorCanCall(market.spoke, ISpoke.updateReserveConfig.selector)) return false;

    (bool listed, , uint256 reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    if (!listed) return false;

    ISpoke.ReserveConfig memory config;
    (ok, config) = _reserveConfig(market.spoke, reserveId);
    return ok && !config.paused;
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata
  ) internal override {
    (, , uint256 reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    updatesInvalidUntil[update.market] = block.timestamp;
    ISpokeConfigurator(CONFIGURATOR).pauseReserve(market.spoke, reserveId);
  }

  function _checkMarketAdmin(
    address hub,
    address spoke,
    address asset
  ) internal view returns (address) {
    require(isHubAgentIdSet, HubAgentIdNotSet());
    require(
      msg.sender == Ownable(AGENT_HUB).owner() ||
        msg.sender == IAgentHub(AGENT_HUB).getAgentAdmin(hubAgentId),
      OnlyAgentHubOwnerOrAgentAdmin(msg.sender)
    );
    require(hub != address(0) && spoke != address(0) && asset != address(0), InvalidMarket());
    return marketId(hub, spoke, asset);
  }

  function _isIssuerPaused(address asset) internal view returns (bool) {
    (bool ok, uint256[] memory words) = _staticcallWords(
      address(ISSUER_REGISTRY),
      abi.encodeCall(IB20OracleRegistry.getOracleParams, (asset)),
      2
    );
    return ok && words[1] == 1;
  }

  function _reserveSource(address spoke, uint256 reserveId) internal view returns (address) {
    (bool ok, uint256 oracle) = _staticcallWord(spoke, abi.encodeCall(ISpoke.ORACLE, ()));
    if (!ok || oracle == 0 || oracle > type(uint160).max) return address(0);
    uint256 source;
    (ok, source) = _staticcallWord(
      address(uint160(oracle)),
      abi.encodeCall(IAaveOracle.getReserveSource, (reserveId))
    );
    if (!ok || source > type(uint160).max) return address(0);
    return address(uint160(source));
  }

  function _isAdapterBreached(address adapter) internal view returns (bool) {
    if (adapter == address(0)) return false;
    (bool ok, uint256 breached) = _staticcallWord(
      adapter,
      abi.encodeCall(IBoundedPriceAdapter.isBreached, ())
    );
    return ok && breached == 1;
  }

  function _isHubMarket(address market) internal view returns (bool) {
    IAgentHub agentHub = IAgentHub(AGENT_HUB);
    return
      !agentHub.isMarketsFromAgentEnabled(hubAgentId) &&
      _contains(agentHub.getAllowedMarkets(hubAgentId), market) &&
      !_contains(agentHub.getRestrictedMarkets(hubAgentId), market);
  }
}
