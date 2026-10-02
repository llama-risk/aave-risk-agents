// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {Ownable} from 'openzeppelin-contracts/contracts/access/Ownable.sol';

import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';
import {IB20OracleRegistry} from '../../dependencies/b20/IB20OracleRegistry.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../dependencies/v4/ISpokeConfigurator.sol';

/**
 * @title AaveV4PauseAgent
 * @author LlamaRisk
 * @notice Pauses Aave v4 spoke reserves and never unpauses them. The update value is
 *         abi.encode(uint256(1)). Anyone can poke a market with poke enabled to pause its
 *         reserve while the issuer oracle registry reports the asset paused.
 */
contract AaveV4PauseAgent is BaseAaveV4Agent {
  IB20OracleRegistry public immutable ISSUER_REGISTRY;

  uint256 public hubAgentId;
  bool public isHubAgentIdSet;
  mapping(address market => bool) public isPokeEnabled;

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
  error HubAgentIdAlreadySet();
  error HubAgentIdNotSet();
  error NotRegisteredAgent(uint256 agentId);
  error IssuerRegistryNotSet();
  error InvalidMarket();
  error PokeDisabled(address market);
  error AgentDisabled();
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

  /// @notice Sets the AgentHub id of this agent once. Only the AgentHub owner can call it.
  function setHubAgentId(uint256 agentId) external {
    require(msg.sender == Ownable(AGENT_HUB).owner(), OnlyAgentHubOwner(msg.sender));
    require(!isHubAgentIdSet, HubAgentIdAlreadySet());
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

    (bool listed, , uint256 reserveId) = _reserveId(hub, spoke, asset);
    require(listed, ReserveNotListed(market));
    require(!ISpoke(spoke).getReserveConfig(reserveId).paused, ReserveAlreadyPaused(market));

    (, bool issuerPaused) = ISSUER_REGISTRY.getOracleParams(asset);
    require(issuerPaused, IssuerNotPaused(asset));

    ISpokeConfigurator(CONFIGURATOR).pauseReserve(spoke, reserveId);
    emit Poked(market, reserveId, msg.sender);
  }

  function _configuratorSelector() internal pure override returns (bytes4) {
    return ISpokeConfigurator.pauseReserve.selector;
  }

  function _validateUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, uint256 pause) = _decodeUint(value, 1);
    if (!ok || pause != 1) return false;

    (bool listed, , uint256 reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    if (!listed) return false;

    return !ISpoke(market.spoke).getReserveConfig(reserveId).paused;
  }

  function _injectUpdate(
    uint256,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata,
    Market memory market,
    bytes calldata
  ) internal override {
    (, , uint256 reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    ISpokeConfigurator(CONFIGURATOR).pauseReserve(market.spoke, reserveId);
  }
}
