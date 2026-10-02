// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';

import {BaseAaveV4Agent} from './BaseAaveV4Agent.sol';
import {IHub} from '../../dependencies/v4/IHub.sol';
import {IHubConfigurator} from '../../dependencies/v4/IHubConfigurator.sol';

/**
 * @title AaveV4CapAgent
 * @author LlamaRisk
 * @notice Updates the add cap or the draw cap of a spoke on an Aave v4 hub asset. The cap kind is
 *         fixed at deployment. Caps at 0 (blocked) or at the hub maximum (uncapped) are left as
 *         they are, and the agent never sets either value.
 */
contract AaveV4CapAgent is BaseAaveV4Agent {
  enum CapKind {
    ADD,
    DRAW
  }

  uint256 public constant MAX_CAP = type(uint40).max;

  CapKind public immutable KIND;

  constructor(
    address agentHub,
    address rangeValidationModule,
    CapKind kind,
    string memory updateTypeSuffix,
    address hubConfigurator
  )
    BaseAaveV4Agent(
      agentHub,
      rangeValidationModule,
      kind == CapKind.ADD ? 'SpokeAddCapUpdate' : 'SpokeDrawCapUpdate',
      updateTypeSuffix,
      hubConfigurator
    )
  {
    KIND = kind;
  }

  function _configuratorSelector() internal view override returns (bytes4) {
    return
      KIND == CapKind.ADD
        ? IHubConfigurator.updateSpokeAddCap.selector
        : IHubConfigurator.updateSpokeDrawCap.selector;
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view override returns (bool) {
    (bool ok, uint256 newCap) = _decodeUint(value, MAX_CAP - 1);
    if (!ok || newCap == 0) return false;

    uint256 assetId;
    (ok, assetId) = _spokeAssetId(market.hub, market.spoke, market.asset);
    if (!ok) return false;

    uint256 currentCap;
    (ok, currentCap) = _currentCap(market.hub, assetId, market.spoke);
    if (!ok || currentCap == 0 || currentCap == MAX_CAP || currentCap == newCap) return false;
    if (!_configuratorCanCall(market.hub, IHub.updateSpokeConfig.selector)) return false;

    return
      RANGE_VALIDATION_MODULE.validate(
        AGENT_HUB,
        agentId,
        update.market,
        IRangeValidationModule.RangeValidationInput({
          from: currentCap,
          to: newCap,
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
    (, uint256 assetId) = _spokeAssetId(market.hub, market.spoke, market.asset);
    uint256 newCap = abi.decode(value, (uint256));
    if (KIND == CapKind.ADD) {
      IHubConfigurator(CONFIGURATOR).updateSpokeAddCap(market.hub, assetId, market.spoke, newCap);
    } else {
      IHubConfigurator(CONFIGURATOR).updateSpokeDrawCap(market.hub, assetId, market.spoke, newCap);
    }
  }

  function _currentCap(
    address hub,
    uint256 assetId,
    address spoke
  ) internal view returns (bool, uint256) {
    (bool ok, uint256[] memory words) = _staticcallWords(
      hub,
      abi.encodeCall(IHub.getSpokeConfig, (assetId, spoke)),
      5
    );
    if (!ok) return (false, 0);

    uint256 cap = KIND == CapKind.ADD ? words[0] : words[1];
    if (cap > MAX_CAP) return (false, 0);
    return (true, cap);
  }
}
