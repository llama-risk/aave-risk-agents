// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBoundedRatioAdapter {
  function setLowerBound(uint104 lowerBound, uint48 expiration) external;

  function ACL_MANAGER() external view returns (address);

  function MAXIMUM_LOWER_BOUND_DURATION() external view returns (uint48);

  function getRatio() external view returns (int256);

  function getLowerBound() external view returns (uint256 lowerBound, uint256 expiration);

  function getLowerBoundLimit() external view returns (uint256);
}

interface IACLManager {
  function isRiskAdmin(address admin) external view returns (bool);

  function isPoolAdmin(address admin) external view returns (bool);
}
