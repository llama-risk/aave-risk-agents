// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';

import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';
import {IB20OracleRegistry} from '../../dependencies/b20/IB20OracleRegistry.sol';
import {IAccessManaged} from '../../dependencies/v4/IAccessManaged.sol';
import {IAccessManager} from '../../dependencies/v4/IAccessManager.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../dependencies/v4/ISpokeConfigurator.sol';

/**
 * @title AaveV4PauseAgent
 * @author LlamaRisk
 * @notice Pauses Aave v4 spoke reserves and never unpauses them. The update value is
 *         abi.encode(uint256(1)). Anyone can poke a market with poke enabled to pause its
 *         reserve while the issuer oracle registry reports the asset paused. Poke follows the
 *         AgentHub market gating, and updates published before the agent's last pause of a
 *         market are invalid.
 */
contract AaveV4PauseAgent is BaseAaveV4Agent {
  IB20OracleRegistry public immutable ISSUER_REGISTRY;

  uint256 public hubAgentId;
  bool public isHubAgentIdSet;
  mapping(address market => bool) public isPokeEnabled;
  mapping(address market => uint256) public lastPausedAt;

  event HubAgentIdSet(uint256 indexed agentId);
  event PokeEnabledSet(
    address indexed market,
    address hub,
    address spoke,
    address asset,
    bool enabled
  );
  event Poked(address indexed market, uint256 reserveId, address indexed caller);

  error OnlyAgentHubOwner(address caller);
  error OnlyAgentHubOwnerOrAgentAdmin(address caller);
  error HubAgentIdNotSet();
  error NotRegisteredAgent(uint256 agentId);
  error IssuerRegistryNotSet();
  error InvalidMarket();
  error PokeDisabled(address market);
  error AgentDisabled();
  error MarketNotAllowed(address market);
  error ReserveNotListed(address market);
  error ReserveAlreadyPaused(address market);
  error IssuerNotPaused(address asset);

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

  /// @notice Enables or disables poke for a market. Only the AgentHub owner or the agent admin can call it.
  function setPokeEnabled(address hub, address spoke, address asset, bool enabled) external {
    require(isHubAgentIdSet, HubAgentIdNotSet());
    require(
      msg.sender == Ownable(AGENT_HUB).owner() ||
        msg.sender == IAgentHub(AGENT_HUB).getAgentAdmin(hubAgentId),
      OnlyAgentHubOwnerOrAgentAdmin(msg.sender)
    );
    require(!enabled || address(ISSUER_REGISTRY) != address(0), IssuerRegistryNotSet());
    require(hub != address(0) && spoke != address(0) && asset != address(0), InvalidMarket());

    address market = marketId(hub, spoke, asset);
    isPokeEnabled[market] = enabled;
    emit PokeEnabledSet(market, hub, spoke, asset, enabled);
  }

  /// @notice Pauses the reserve of (hub, spoke, asset) if the issuer oracle registry reports the asset paused.
  function poke(address hub, address spoke, address asset) external {
    address market = marketId(hub, spoke, asset);
    require(isPokeEnabled[market], PokeDisabled(market));
    require(
      IAgentHub(AGENT_HUB).getAgentAddress(hubAgentId) == address(this) &&
        IAgentHub(AGENT_HUB).isAgentEnabled(hubAgentId),
      AgentDisabled()
    );
    require(_isHubMarket(market), MarketNotAllowed(market));

    (bool listed, , uint256 reserveId) = _reserveId(hub, spoke, asset);
    require(listed, ReserveNotListed(market));
    require(!ISpoke(spoke).getReserveConfig(reserveId).paused, ReserveAlreadyPaused(market));

    (, bool issuerPaused) = ISSUER_REGISTRY.getOracleParams(asset);
    require(issuerPaused, IssuerNotPaused(asset));

    lastPausedAt[market] = block.timestamp;
    ISpokeConfigurator(CONFIGURATOR).pauseReserve(spoke, reserveId);
    emit Poked(market, reserveId, msg.sender);
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
    if (!_spokeAcceptsConfigurator(market.spoke)) return false;

    (bool listed, , uint256 reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    if (!listed) return false;

    return !ISpoke(market.spoke).getReserveConfig(reserveId).paused;
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

  function _isHubMarket(address market) internal view returns (bool) {
    IAgentHub agentHub = IAgentHub(AGENT_HUB);
    return
      !agentHub.isMarketsFromAgentEnabled(hubAgentId) &&
      _contains(agentHub.getAllowedMarkets(hubAgentId), market) &&
      !_contains(agentHub.getRestrictedMarkets(hubAgentId), market);
  }

  function _spokeAcceptsConfigurator(address spoke) internal view returns (bool) {
    (bool ok, bytes memory data) = spoke.staticcall(abi.encodeCall(IAccessManaged.authority, ()));
    if (!ok || data.length != 32) return false;
    uint256 authority = abi.decode(data, (uint256));
    if (authority >> 160 != 0) return false;

    (ok, data) = address(uint160(authority)).staticcall(
      abi.encodeCall(
        IAccessManager.canCall,
        (CONFIGURATOR, spoke, ISpoke.updateReserveConfig.selector)
      )
    );
    if (!ok || data.length != 64) return false;
    (uint256 allowed, uint256 delay) = abi.decode(data, (uint256, uint256));
    return allowed == 1 && delay == 0;
  }

  function _contains(address[] memory markets, address market) internal pure returns (bool) {
    for (uint256 i = 0; i < markets.length; i++) {
      if (markets[i] == market) return true;
    }
    return false;
  }
}
