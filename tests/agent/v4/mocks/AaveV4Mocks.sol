// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {ISpoke} from '../../../../src/contracts/dependencies/v4/ISpoke.sol';

contract HubMock {
  mapping(address => uint256) internal _assetIds;
  mapping(address => bool) internal _listed;
  mapping(uint256 => mapping(address => bool)) internal _spokes;

  function listAsset(address underlying, uint256 assetId) external {
    _listed[underlying] = true;
    _assetIds[underlying] = assetId;
  }

  function listSpoke(uint256 assetId, address spoke) external {
    _spokes[assetId][spoke] = true;
  }

  function isUnderlyingListed(address underlying) external view returns (bool) {
    return _listed[underlying];
  }

  function getAssetId(address underlying) external view returns (uint256) {
    require(_listed[underlying], 'AssetNotListed');
    return _assetIds[underlying];
  }

  function isSpokeListed(uint256 assetId, address spoke) external view returns (bool) {
    return _spokes[assetId][spoke];
  }
}

contract RevertingHubMock {
  fallback() external {
    revert('reverted');
  }
}

contract ShortReturnHubMock {
  fallback() external {
    assembly {
      mstore(0x00, 1)
      return(0x00, 0x10)
    }
  }
}

contract LongReturnHubMock {
  fallback() external {
    assembly {
      mstore(0x00, 1)
      mstore(0x20, 1)
      return(0x00, 0x40)
    }
  }
}

contract DirtyBoolHubMock {
  fallback() external {
    assembly {
      mstore(0x00, 2)
      return(0x00, 0x20)
    }
  }
}

contract RawReturnMock {
  bytes internal _data;
  bool internal _revert;

  function setReturn(bytes memory data, bool shouldRevert) external {
    _data = data;
    _revert = shouldRevert;
  }

  fallback() external {
    bytes memory data = _data;
    bool shouldRevert = _revert;
    assembly {
      if shouldRevert {
        revert(add(data, 0x20), mload(data))
      }
      return(add(data, 0x20), mload(data))
    }
  }
}

contract SpokeMock {
  mapping(address => mapping(uint256 => uint256)) internal _reserveIds;
  mapping(address => mapping(uint256 => bool)) internal _reserves;
  mapping(uint256 => ISpoke.ReserveConfig) internal _configs;
  mapping(uint256 => ISpoke.Reserve) internal _reserveData;
  mapping(uint256 => mapping(uint32 => ISpoke.DynamicReserveConfig)) internal _dynamicConfigs;

  function addReserve(address hub, uint256 assetId, uint256 reserveId) external {
    _reserves[hub][assetId] = true;
    _reserveIds[hub][assetId] = reserveId;
  }

  function setCollateralRisk(uint256 reserveId, uint24 collateralRisk) external {
    _configs[reserveId].collateralRisk = collateralRisk;
  }

  function setReserveConfig(uint256 reserveId, ISpoke.ReserveConfig memory config) external {
    _configs[reserveId] = config;
  }

  function setDynamicConfigKey(uint256 reserveId, uint32 key) external {
    _reserveData[reserveId].dynamicConfigKey = key;
  }

  function setDynamicReserveConfig(
    uint256 reserveId,
    uint32 key,
    ISpoke.DynamicReserveConfig memory config
  ) external {
    _dynamicConfigs[reserveId][key] = config;
  }

  function getReserve(uint256 reserveId) external view returns (ISpoke.Reserve memory) {
    return _reserveData[reserveId];
  }

  function getDynamicReserveConfig(
    uint256 reserveId,
    uint32 key
  ) external view returns (ISpoke.DynamicReserveConfig memory) {
    return _dynamicConfigs[reserveId][key];
  }

  function getReserveId(address hub, uint256 assetId) external view returns (uint256) {
    require(_reserves[hub][assetId], 'ReserveNotListed');
    return _reserveIds[hub][assetId];
  }

  function getReserveConfig(uint256 reserveId) external view returns (ISpoke.ReserveConfig memory) {
    return _configs[reserveId];
  }
}

contract AccessManagerMock {
  mapping(bytes32 => uint256) internal _permissions;

  function setCanCall(
    address caller,
    address target,
    bytes4 selector,
    bool allowed,
    uint32 delay
  ) external {
    _permissions[keccak256(abi.encode(caller, target, selector))] =
      (allowed ? 1 : 0) |
      (uint256(delay) << 1);
  }

  function canCall(
    address caller,
    address target,
    bytes4 selector
  ) external view returns (bool, uint32) {
    uint256 permission = _permissions[keccak256(abi.encode(caller, target, selector))];
    return (permission & 1 == 1, uint32(permission >> 1));
  }
}

contract ConfiguratorMock {
  address public authority;

  constructor(address authority_) {
    authority = authority_;
  }
}

contract HubConfiguratorMock is ConfiguratorMock {
  address public lastHub;
  uint256 public lastAssetId;
  bytes public lastIrData;
  uint256 public calls;

  constructor(address authority_) ConfiguratorMock(authority_) {}

  function updateInterestRateData(address hub, uint256 assetId, bytes calldata irData) external {
    lastHub = hub;
    lastAssetId = assetId;
    lastIrData = irData;
    calls++;
  }
}

contract SpokeConfiguratorMock is ConfiguratorMock {
  address public lastSpoke;
  uint256 public lastReserveId;
  uint256 public lastCollateralRisk;
  uint256 public calls;

  constructor(address authority_) ConfiguratorMock(authority_) {}

  function updateCollateralRisk(address spoke, uint256 reserveId, uint256 collateralRisk) external {
    lastSpoke = spoke;
    lastReserveId = reserveId;
    lastCollateralRisk = collateralRisk;
    calls++;
  }
}
