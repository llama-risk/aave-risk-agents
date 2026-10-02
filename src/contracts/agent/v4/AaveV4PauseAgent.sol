// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';

import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';
import {IBoundedPriceAdapter} from '../../dependencies/adapters/IBoundedPriceAdapter.sol';
import {IB20OracleRegistry} from '../../dependencies/b20/IB20OracleRegistry.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../dependencies/v4/ISpokeConfigurator.sol';

/**
 * @title AaveV4PauseAgent
 * @author LlamaRisk
 * @notice Pauses Aave v4 spoke reserves and never unpauses them. The update value is
 *         abi.encode(uint256(1)). Anyone can poke a market to pause its reserve while the
 *         issuer oracle registry reports the asset paused (if issuer poke is enabled for the
 *         market) or while the price adapter set for the market reports isBreached(). Poke
 *         follows the AgentHub market gating, and updates published before the agent's last
 *         pause of a market are invalid.
 */
contract AaveV4PauseAgent is BaseAaveV4Agent {
  IB20OracleRegistry public immutable ISSUER_REGISTRY;

  uint256 public hubAgentId;
  bool public isHubAgentIdSet;
  mapping(address market => bool) public isIssuerPokeEnabled;
  mapping(address market => address) public priceAdapter;
  mapping(address market => uint256) public lastPausedAt;

  event HubAgentIdSet(uint256 indexed agentId);
  event IssuerPokeEnabledSet(
    address indexed market,
    address hub,
    address spoke,
    address asset,
    bool enabled
  );
  event PriceAdapterSet(
    address indexed market,
    address hub,
    address spoke,
    address asset,
    address adapter
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

  /// @notice Sets the price adapter whose isBreached() triggers poke for a market. Zero unsets it.
  /// @dev Only the AgentHub owner or the agent admin can call it.
  function setPriceAdapter(address hub, address spoke, address asset, address adapter) external {
    address market = _checkMarketAdmin(hub, spoke, asset);
    if (adapter != address(0)) {
      (bool ok, uint256 breached) = _staticcallWord(
        adapter,
        abi.encodeCall(IBoundedPriceAdapter.isBreached, ())
      );
      require(ok && breached <= 1, InvalidPriceAdapter(adapter));
    }

    priceAdapter[market] = adapter;
    emit PriceAdapterSet(market, hub, spoke, asset, adapter);
  }

  /// @notice Pauses the reserve of (hub, spoke, asset) if the issuer registry reports the asset
  ///         paused or the price adapter of the market reports a breach.
  function poke(address hub, address spoke, address asset) external {
    address market = marketId(hub, spoke, asset);
    address adapter = priceAdapter[market];
    bool issuerPokeEnabled = isIssuerPokeEnabled[market];
    require(issuerPokeEnabled || adapter != address(0), PokeDisabled(market));
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
    bool adapterBreached = adapter != address(0) && _isAdapterBreached(adapter);
    require(issuerPaused || adapterBreached, PokeConditionNotMet(market));

    lastPausedAt[market] = block.timestamp;
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
    if (!ok || pause != 1 || update.timestamp <= lastPausedAt[update.market]) return false;
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
    lastPausedAt[update.market] = block.timestamp;
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

  function _isAdapterBreached(address adapter) internal view returns (bool) {
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
