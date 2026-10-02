// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IACLManager} from 'aave-v3-origin/src/contracts/interfaces/IACLManager.sol';
import {IPriceCapAdapter} from 'aave-price-feeds/interfaces/IPriceCapAdapter.sol';

import {IAaveOracle} from '../../dependencies/v4/IAaveOracle.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';
import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';

/**
 * @title BaseAaveV4AdapterAgent
 * @author LlamaRisk
 * @notice Base for agents that write the price adapter of an Aave v4 reserve. The adapter is the
 *         source of the reserve on the spoke oracle. CONFIGURATOR is the v3 ACLManager that the
 *         adapters check. Updates are valid only while the agent is risk or pool admin on it and
 *         the adapter checks the same ACLManager.
 */
abstract contract BaseAaveV4AdapterAgent is BaseAaveV4Agent {
  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateType,
    string memory updateTypeSuffix,
    address aclManager
  ) BaseAaveV4Agent(agentHub, rangeValidationModule, updateType, updateTypeSuffix, aclManager) {}

  function _canCallConfigurator(bytes4) internal view override returns (bool) {
    (bool ok, uint256 isAdmin) = _staticcallWord(
      CONFIGURATOR,
      abi.encodeCall(IACLManager.isRiskAdmin, (address(this)))
    );
    if (ok && isAdmin == 1) return true;
    (ok, isAdmin) = _staticcallWord(
      CONFIGURATOR,
      abi.encodeCall(IACLManager.isPoolAdmin, (address(this)))
    );
    return ok && isAdmin == 1;
  }

  function _adapter(Market memory market) internal view returns (address) {
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
    if (!ok || word != uint256(uint160(CONFIGURATOR))) return address(0);
    return adapter;
  }

  function _read(address adapter, bytes4 selector) internal view returns (bool, uint256) {
    return _staticcallWord(adapter, abi.encodeWithSelector(selector));
  }
}
