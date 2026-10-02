// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IACLManager} from 'aave-v3-origin/src/contracts/interfaces/IACLManager.sol';
import {IAaveOracle as IAaveV3Oracle} from 'aave-v3-origin/src/contracts/interfaces/IAaveOracle.sol';
import {IPriceCapAdapter} from 'aave-price-feeds/interfaces/IPriceCapAdapter.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentConfigurator.sol';

import {IAaveOracle} from '../../dependencies/v4/IAaveOracle.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';

/**
 * @title BaseAaveV4AdapterAgent
 * @author LlamaRisk
 * @notice Base for agents that write the price adapter of an Aave v4 reserve. The adapter is the
 *         source of the reserve on the spoke oracle, and the hub must be one of the trusted hubs.
 *         CONFIGURATOR is the v3 ACLManager that the adapters check, and the agent must be risk
 *         admin on it. Adapters that a v3 oracle uses as the source of the asset are rejected, so
 *         only v4-only adapters are written. The adapter is the rate-limited unit: the range
 *         config is keyed by the adapter address, and the agent minimum delay applies per adapter
 *         across every market that resolves to it, with at most one write per adapter per block.
 *         The v3 oracle list must cover every v3 oracle that has a source on the CONFIGURATOR.
 */
abstract contract BaseAaveV4AdapterAgent is BaseAaveV4Agent {
  address[] internal _hubs;
  address[] internal _v3Oracles;
  mapping(address adapter => uint256) internal _lastAdapterUpdate;

  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateType,
    string memory updateTypeSuffix,
    address aclManager,
    address[] memory hubs,
    address[] memory v3Oracles
  ) BaseAaveV4Agent(agentHub, rangeValidationModule, updateType, updateTypeSuffix, aclManager) {
    require(hubs.length != 0, InvalidZeroAddress());
    for (uint256 i = 0; i < hubs.length; i++) {
      require(hubs[i] != address(0), InvalidZeroAddress());
    }
    require(v3Oracles.length != 0, InvalidZeroAddress());
    for (uint256 i = 0; i < v3Oracles.length; i++) {
      require(v3Oracles[i] != address(0), InvalidZeroAddress());
    }
    _hubs = hubs;
    _v3Oracles = v3Oracles;
  }

  /// @notice Returns the hubs whose reserves the agent can update.
  function getHubs() external view returns (address[] memory) {
    return _hubs;
  }

  /// @notice Returns the v3 oracles whose asset sources the agent never writes.
  function getV3Oracles() external view returns (address[] memory) {
    return _v3Oracles;
  }

  /// @notice Returns the timestamp of the last write by the agent to an adapter.
  function getLastAdapterUpdate(address adapter) external view returns (uint256) {
    return _lastAdapterUpdate[adapter];
  }

  function _canCallConfigurator(bytes4) internal view override returns (bool) {
    (bool ok, uint256 isAdmin) = _staticcallWord(
      CONFIGURATOR,
      abi.encodeCall(IACLManager.isRiskAdmin, (address(this)))
    );
    return ok && isAdmin == 1;
  }

  function _adapter(uint256 agentId, Market memory market) internal view returns (address) {
    if (!_contains(_hubs, market.hub)) return address(0);

    (bool ok, , uint256 reserveId) = _reserveId(market.hub, market.spoke, market.asset);
    if (!ok) return address(0);

    uint256 word;
    (ok, word) = _staticcallWord(market.spoke, abi.encodeCall(ISpoke.ORACLE, ()));
    if (!ok || word >> 160 != 0) return address(0);

    (ok, word) = _staticcallWord(
      address(uint160(word)),
      abi.encodeCall(IAaveOracle.getReserveSource, (reserveId))
    );
    if (!ok || word >> 160 != 0) return address(0);

    address adapter = address(uint160(word));
    (ok, word) = _read(adapter, IPriceCapAdapter.ACL_MANAGER.selector);
    if (
      !ok ||
      word != uint256(uint160(CONFIGURATOR)) ||
      _isV3Source(market.asset, adapter) ||
      _lastAdapterUpdate[adapter] == block.timestamp ||
      block.timestamp - _lastAdapterUpdate[adapter] <
      IAgentConfigurator(AGENT_HUB).getMinimumDelay(agentId)
    ) {
      return address(0);
    }
    return adapter;
  }

  function _writeAdapter(uint256 agentId, Market memory market) internal returns (address adapter) {
    adapter = _adapter(agentId, market);
    _lastAdapterUpdate[adapter] = block.timestamp;
  }

  function _isV3Source(address asset, address adapter) internal view returns (bool) {
    for (uint256 i = 0; i < _v3Oracles.length; i++) {
      (bool ok, uint256 source) = _staticcallWord(
        _v3Oracles[i],
        abi.encodeCall(IAaveV3Oracle.getSourceOfAsset, (asset))
      );
      if (!ok || source == uint256(uint160(adapter))) return true;
    }
    return false;
  }

  function _read(address adapter, bytes4 selector) internal view returns (bool, uint256) {
    return _staticcallWord(adapter, abi.encodeWithSelector(selector));
  }
}
