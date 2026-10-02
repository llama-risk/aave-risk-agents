// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {BaseAgent} from 'chaos-agents/src/contracts/agent/BaseAgent.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {ShortStrings, ShortString} from 'openzeppelin-contracts/contracts/utils/ShortStrings.sol';
import {Strings} from 'openzeppelin-contracts/contracts/utils/Strings.sol';

import {IHub} from '../../dependencies/v4/IHub.sol';
import {ISpoke} from '../../dependencies/v4/ISpoke.sol';

/**
 * @title BaseAaveV4Agent
 * @author LlamaRisk
 * @notice Base for agents that write Aave v4 parameters through a hub or spoke configurator.
 *         The update market is the market id of (hub, spoke, asset) and the update value is
 *         abi.encode(hub, spoke, asset, value). Hub-level parameters use spoke = address(0).
 */
abstract contract BaseAaveV4Agent is BaseAgent {
  using Strings for string;
  using ShortStrings for *;

  struct Market {
    address hub;
    address spoke;
    address asset;
  }

  address public immutable CONFIGURATOR;
  IRangeValidationModule public immutable RANGE_VALIDATION_MODULE;
  ShortString public immutable UPDATE_TYPE;

  error InvalidZeroAddress();
  error InvalidUpdate();

  constructor(
    address agentHub,
    address rangeValidationModule,
    string memory updateType,
    string memory updateTypeSuffix,
    address configurator
  ) BaseAgent(agentHub) {
    require(agentHub != address(0) && configurator != address(0), InvalidZeroAddress());
    CONFIGURATOR = configurator;
    RANGE_VALIDATION_MODULE = IRangeValidationModule(rangeValidationModule);
    UPDATE_TYPE = string.concat(updateType, updateTypeSuffix).toShortString();
  }

  /// @inheritdoc BaseAgent
  function validate(
    uint256 agentId,
    bytes calldata agentContext,
    IRiskOracle.RiskParameterUpdate calldata update
  ) external view override returns (bool) {
    (bool valid, , ) = _checkUpdate(agentId, agentContext, update);
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

  /// @notice Returns the market id of a (hub, spoke, asset) triple.
  function marketId(address hub, address spoke, address asset) public pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encode(hub, spoke, asset)))));
  }

  function _processUpdate(
    uint256 agentId,
    bytes calldata agentContext,
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal override {
    (bool valid, Market memory market, bytes calldata value) = _checkUpdate(
      agentId,
      agentContext,
      update
    );
    require(valid, InvalidUpdate());
    _injectUpdate(agentId, agentContext, update, market, value);
  }

  function _checkUpdate(
    uint256 agentId,
    bytes calldata agentContext,
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal view returns (bool, Market memory market, bytes calldata value) {
    bool decoded;
    (decoded, market, value) = _decodeUpdate(update);
    if (!decoded || !update.updateType.equal(UPDATE_TYPE.toString())) {
      return (false, market, value);
    }
    return (_validateUpdate(agentId, agentContext, update, market, value), market, value);
  }

  function _decodeUpdate(
    IRiskOracle.RiskParameterUpdate calldata update
  ) internal pure returns (bool, Market memory market, bytes calldata value) {
    bytes calldata data = update.newValue;
    value = data[0:0];
    if (data.length < 160 || uint256(bytes32(data[96:128])) != 128) return (false, market, value);

    uint256 length = uint256(bytes32(data[128:160]));
    uint256 padded = data.length - 160;
    if (length > padded || padded - length > 31 || padded % 32 != 0) {
      return (false, market, value);
    }

    for (uint256 i = 0; i < 96; i += 32) {
      if (uint256(bytes32(data[i:i + 32])) >> 160 != 0) return (false, market, value);
    }
    (market.hub, market.spoke, market.asset) = abi.decode(data[0:96], (address, address, address));
    if (
      market.hub == address(0) ||
      market.asset == address(0) ||
      marketId(market.hub, market.spoke, market.asset) != update.market
    ) {
      return (false, market, value);
    }
    return (true, market, data[160:160 + length]);
  }

  function _assetId(address hub, address asset) internal view returns (bool, uint256) {
    (bool ok, uint256 listed) = _staticcallWord(
      hub,
      abi.encodeCall(IHub.isUnderlyingListed, (asset))
    );
    if (!ok || listed != 1) return (false, 0);
    return _staticcallWord(hub, abi.encodeCall(IHub.getAssetId, (asset)));
  }

  function _reserveId(
    address hub,
    address spoke,
    address asset
  ) internal view returns (bool, uint256, uint256) {
    (bool ok, uint256 assetId) = _assetId(hub, asset);
    if (!ok) return (false, 0, 0);

    uint256 listed;
    (ok, listed) = _staticcallWord(hub, abi.encodeCall(IHub.isSpokeListed, (assetId, spoke)));
    if (!ok || listed != 1) return (false, 0, 0);

    uint256 reserveId;
    (ok, reserveId) = _staticcallWord(spoke, abi.encodeCall(ISpoke.getReserveId, (hub, assetId)));
    if (!ok) return (false, 0, 0);
    return (true, assetId, reserveId);
  }

  function _validateUpdate(
    uint256 agentId,
    bytes calldata agentContext,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal view virtual returns (bool);

  function _injectUpdate(
    uint256 agentId,
    bytes calldata agentContext,
    IRiskOracle.RiskParameterUpdate calldata update,
    Market memory market,
    bytes calldata value
  ) internal virtual;

  function _staticcallWord(
    address target,
    bytes memory data
  ) private view returns (bool ok, uint256 word) {
    assembly ('memory-safe') {
      ok := staticcall(gas(), target, add(data, 0x20), mload(data), 0x00, 0x20)
      ok := and(ok, eq(returndatasize(), 0x20))
      word := mul(mload(0x00), ok)
    }
  }
}
