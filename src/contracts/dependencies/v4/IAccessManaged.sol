// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAccessManaged {
  function authority() external view returns (address);
}
