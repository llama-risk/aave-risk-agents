// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IHub} from '../../../../src/contracts/dependencies/v4/IHub.sol';
import {ConfiguratorMock, HubMock} from './AaveV4Mocks.sol';

contract CapHubMock is HubMock {
  mapping(uint256 => mapping(address => IHub.SpokeConfig)) internal _configs;
  bytes internal _rawConfig;
  bool internal _revertConfig;

  function setCaps(uint256 assetId, address spoke, uint40 addCap, uint40 drawCap) external {
    _configs[assetId][spoke].addCap = addCap;
    _configs[assetId][spoke].drawCap = drawCap;
    _configs[assetId][spoke].active = true;
  }

  function setRawConfig(bytes calldata rawConfig) external {
    _rawConfig = rawConfig;
  }

  function setRevertConfig(bool revertConfig) external {
    _revertConfig = revertConfig;
  }

  function getSpokeConfig(
    uint256 assetId,
    address spoke
  ) external view returns (IHub.SpokeConfig memory) {
    require(!_revertConfig, 'reverted');
    bytes memory raw = _rawConfig;
    if (raw.length != 0) {
      assembly {
        return(add(raw, 0x20), mload(raw))
      }
    }
    return _configs[assetId][spoke];
  }
}

contract CapConfiguratorMock is ConfiguratorMock {
  address public lastHub;
  uint256 public lastAssetId;
  address public lastSpoke;
  uint256 public lastCap;
  uint256 public addCapCalls;
  uint256 public drawCapCalls;

  constructor(address authority_) ConfiguratorMock(authority_) {}

  function updateSpokeAddCap(address hub, uint256 assetId, address spoke, uint256 addCap) external {
    _record(hub, assetId, spoke, addCap);
    addCapCalls++;
  }

  function updateSpokeDrawCap(
    address hub,
    uint256 assetId,
    address spoke,
    uint256 drawCap
  ) external {
    _record(hub, assetId, spoke, drawCap);
    drawCapCalls++;
  }

  function _record(address hub, uint256 assetId, address spoke, uint256 cap) internal {
    lastHub = hub;
    lastAssetId = assetId;
    lastSpoke = spoke;
    lastCap = cap;
  }
}
