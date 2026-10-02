// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from 'forge-std/Test.sol';
import {TransparentUpgradeableProxy} from 'openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {RiskOracle} from 'chaos-agents/src/contracts/dependencies/RiskOracle.sol';
import {AgentHub, IAgentHub, IRiskOracle} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {RangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';

interface IAccessManagerLike {
  function getTargetFunctionRole(address target, bytes4 selector) external view returns (uint64);

  function getRoleAdmin(uint64 roleId) external view returns (uint64);

  function getRoleGrantDelay(uint64 roleId) external view returns (uint32);

  function getRoleMember(uint64 roleId, uint256 index) external view returns (address);

  function hasRole(uint64 roleId, address account) external view returns (bool, uint32);

  function grantRole(uint64 roleId, address account, uint32 executionDelay) external;

  function revokeRole(uint64 roleId, address account) external;
}

library AaveV4BaseFork {
  uint256 internal constant BLOCK = 52044276;
  address internal constant ACCESS_MANAGER = 0x4010C94698EDE9d895814502B6EB122D764a1Cc6;
  address internal constant HUB_CONFIGURATOR = 0x2Cd40DFF9f2F74e8765dA148102b6668A5e9778A;
  address internal constant SPOKE_CONFIGURATOR = 0x0191B1Aa743c6B3C545119B5D56a0577D7f3a57F;
  address internal constant EQUITIES_HUB = 0xa4d5947Eb727A052bae69C593FfC84247EC9864E;
  address internal constant MAG7_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
  address internal constant MAG7_SPOKE_ORACLE = 0xaBaf048fD7675Ea34a84332371ffd5D55E322A47;
  address internal constant TREASURY_SPOKE = 0x5F8d0102F5B51Fae6DE9d2F2561bda63Fb5Db674;
  address internal constant AAPLc = 0xb200000000000000000000C2e324d24d7eEcd1fb;
  address internal constant NVDAc = 0xb20000000000000000000078ee7ce2fE4908108C;
  address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
}

abstract contract AaveV4ForkTestBase is Test {
  AgentHub internal _agentHub;
  IRiskOracle internal _riskOracle;
  RangeValidationModule internal _rangeValidationModule;

  address internal _riskOracleOwner = makeAddr('riskOracleOwner');
  address internal _agent;
  uint256 internal _agentId;
  string internal _updateType;

  constructor(string memory updateType) {
    _updateType = updateType;
  }

  function _deployAgent() internal virtual returns (address);

  function _allowedMarkets() internal view virtual returns (address[] memory);

  function _postSetup() internal virtual {}

  function _createFork() internal virtual {
    vm.createSelectFork(vm.rpcUrl('base'), AaveV4BaseFork.BLOCK);
  }

  function _accessManager() internal view virtual returns (address) {
    return AaveV4BaseFork.ACCESS_MANAGER;
  }

  function setUp() public virtual {
    _createFork();

    address[] memory senders = new address[](1);
    senders[0] = _riskOracleOwner;
    string[] memory updateTypes = new string[](1);
    updateTypes[0] = _updateType;
    vm.prank(_riskOracleOwner);
    _riskOracle = IRiskOracle(address(new RiskOracle('RiskOracle', senders, updateTypes)));

    _agentHub = AgentHub(
      address(
        new TransparentUpgradeableProxy(
          address(new AgentHub()),
          address(this),
          abi.encodeWithSelector(AgentHub.initialize.selector, address(this))
        )
      )
    );
    _rangeValidationModule = new RangeValidationModule();
    _agent = _deployAgent();

    _agentId = _agentHub.registerAgent(
      IAgentConfigurator.AgentRegistrationInput({
        agentAddress: _agent,
        riskOracle: address(_riskOracle),
        admin: address(this),
        agentContext: '',
        isAgentEnabled: true,
        isAgentPermissioned: false,
        isMarketsFromAgentEnabled: false,
        expirationPeriod: 1 days,
        minimumDelay: 1 days,
        updateType: _updateType,
        allowedMarkets: _allowedMarkets(),
        restrictedMarkets: new address[](0),
        permissionedSenders: new address[](0)
      })
    );
    _postSetup();
  }

  function _marketId(address hub, address spoke, address asset) internal pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encode(hub, spoke, asset)))));
  }

  function _publish(
    address hub,
    address spoke,
    address asset,
    bytes memory value
  ) internal returns (IRiskOracle.RiskParameterUpdate memory) {
    return _publishRaw(_marketId(hub, spoke, asset), abi.encode(hub, spoke, asset, value));
  }

  function _publishRaw(
    address market,
    bytes memory newValue
  ) internal returns (IRiskOracle.RiskParameterUpdate memory) {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('ref', newValue, _updateType, market, '');
    return _riskOracle.getLatestUpdateByParameterAndMarket(_updateType, market);
  }

  function _grantRole(address target, bytes4 selector, address account) internal returns (uint64) {
    IAccessManagerLike accessManager = IAccessManagerLike(_accessManager());
    uint64 roleId = accessManager.getTargetFunctionRole(target, selector);
    address admin = accessManager.getRoleMember(accessManager.getRoleAdmin(roleId), 0);

    vm.prank(admin);
    accessManager.grantRole(roleId, account, 0);
    vm.warp(block.timestamp + accessManager.getRoleGrantDelay(roleId));

    (bool isMember, uint32 executionDelay) = accessManager.hasRole(roleId, account);
    assertTrue(isMember);
    assertEq(executionDelay, 0);
    return roleId;
  }

  function _revokeRole(address target, bytes4 selector, address account) internal {
    IAccessManagerLike accessManager = IAccessManagerLike(_accessManager());
    uint64 roleId = accessManager.getTargetFunctionRole(target, selector);
    vm.prank(accessManager.getRoleMember(accessManager.getRoleAdmin(roleId), 0));
    accessManager.revokeRole(roleId, account);
  }

  function _check() internal view returns (bool, IAgentHub.ActionData[] memory) {
    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = _agentId;
    return _agentHub.check(agentIds);
  }

  function _checkAndExecute() internal returns (bool) {
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    if (shouldRun) _agentHub.execute(actions);
    return shouldRun;
  }

  function _hasSelector(address target, bytes4 selector) internal view returns (bool) {
    bytes memory code = target.code;
    if (code.length < 5) return false;
    for (uint256 i = 0; i < code.length - 4; i++) {
      if (
        code[i] == 0x63 &&
        bytes4(bytes.concat(code[i + 1], code[i + 2], code[i + 3], code[i + 4])) == selector
      ) return true;
    }
    return false;
  }
}
