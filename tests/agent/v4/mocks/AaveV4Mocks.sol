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

contract SpokeMock {
  mapping(address => mapping(uint256 => uint256)) internal _reserveIds;
  mapping(address => mapping(uint256 => bool)) internal _reserves;
  mapping(uint256 => ISpoke.ReserveConfig) internal _configs;

  function addReserve(address hub, uint256 assetId, uint256 reserveId) external {
    _reserves[hub][assetId] = true;
    _reserveIds[hub][assetId] = reserveId;
  }

  function setCollateralRisk(uint256 reserveId, uint24 collateralRisk) external {
    _configs[reserveId].collateralRisk = collateralRisk;
  }

  function getReserveId(address hub, uint256 assetId) external view returns (uint256) {
    require(_reserves[hub][assetId], 'ReserveNotListed');
    return _reserveIds[hub][assetId];
  }

  function getReserveConfig(uint256 reserveId) external view returns (ISpoke.ReserveConfig memory) {
    return _configs[reserveId];
  }
}

contract SpokeConfiguratorMock {
  address public lastSpoke;
  uint256 public lastReserveId;
  uint256 public lastCollateralRisk;
  uint256 public calls;

  function updateCollateralRisk(address spoke, uint256 reserveId, uint256 collateralRisk) external {
    lastSpoke = spoke;
    lastReserveId = reserveId;
    lastCollateralRisk = collateralRisk;
    calls++;
  }
}
