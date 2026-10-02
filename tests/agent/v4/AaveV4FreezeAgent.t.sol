// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {AaveV4FreezeAgent} from '../../../src/contracts/agent/v4/AaveV4FreezeAgent.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {HubMock, AccessManagerMock} from './mocks/AaveV4Mocks.sol';
import {FreezeSpokeMock, FreezeSpokeConfiguratorMock} from './mocks/AaveV4FreezeMocks.sol';

contract AaveV4FreezeAgent_Test is BaseAgentTest('FreezeUpdate_MAG7') {
  RangeValidationModule internal _rangeValidationModule;
  AccessManagerMock internal _accessManager;
  FreezeSpokeConfiguratorMock internal _configurator;
  HubMock internal _hub;
  FreezeSpokeMock internal _spoke;
  AaveV4FreezeAgent internal _freezeAgent;

  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant RESERVE_ID = 5;
  uint32 internal constant KEY = 7;
  bytes4 internal constant ADD_CF = ISpokeConfigurator.addCollateralFactor.selector;
  bytes4 internal constant FREEZE = ISpokeConfigurator.freezeReserve.selector;
  bytes4 internal constant SPOKE_ADD = ISpoke.addDynamicReserveConfig.selector;
  bytes4 internal constant SPOKE_UPDATE = ISpoke.updateReserveConfig.selector;

  address internal _market;

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _accessManager = new AccessManagerMock();
    _configurator = new FreezeSpokeConfiguratorMock(address(_accessManager));
    _hub = new HubMock();
    _spoke = new FreezeSpokeMock();

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listSpoke(ASSET_ID, address(_spoke));
    _spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(70_00, 105_00, 10_00));
    _spoke.setAuthority(address(_accessManager));
    _accessManager.setCanCall(address(_configurator), address(_spoke), SPOKE_ADD, true, 0);
    _accessManager.setCanCall(address(_configurator), address(_spoke), SPOKE_UPDATE, true, 0);

    _freezeAgent = new AaveV4FreezeAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '_MAG7',
      address(_configurator)
    );
    _market = _freezeAgent.marketId(address(_hub), address(_spoke), ASSET);
    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), ADD_CF, true, 0);
    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), FREEZE, true, 0);
    return address(_freezeAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.minimumDelay = 0;
    config.allowedMarkets = _addressToArray(_market);
    return config;
  }

  function test_getters() public view {
    assertEq(_freezeAgent.getUpdateType(), 'FreezeUpdate_MAG7');
    assertEq(_freezeAgent.CONFIGURATOR(), address(_configurator));
    assertEq(_freezeAgent.LEVEL_LTV0(), 1);
    assertEq(_freezeAgent.LEVEL_FREEZE(), 2);
  }

  function test_validate_levels() public view {
    assertTrue(_validate(1));
    assertTrue(_validate(2));
  }

  function test_validate_invalidLevel(uint256 level) public view {
    vm.assume(level == 0 || level > 2);
    assertFalse(_validate(level));
  }

  function test_validate_badValue() public view {
    bytes[3] memory values = [
      bytes(''),
      abi.encode(uint8(1), uint8(1)),
      abi.encodePacked(uint8(1))
    ];
    for (uint256 i = 0; i < values.length; i++) {
      assertFalse(
        _freezeAgent.validate(
          _agentId,
          _agentContext,
          _update(_market, abi.encode(address(_hub), address(_spoke), ASSET, values[i]))
        )
      );
    }
  }

  function test_validate_unlistedOrMismatchedMarket() public view {
    address other = _freezeAgent.marketId(address(_hub), address(_spoke), OTHER_ASSET);
    assertFalse(
      _freezeAgent.validate(
        _agentId,
        _agentContext,
        _update(other, abi.encode(address(_hub), address(_spoke), OTHER_ASSET, abi.encode(1)))
      )
    );
    assertFalse(_freezeAgent.validate(_agentId, _agentContext, _update(other, _payload(1))));
  }

  function test_validate_reserveNotOnSpoke() public {
    FreezeSpokeMock otherSpoke = new FreezeSpokeMock();
    _hub.listSpoke(ASSET_ID, address(otherSpoke));
    address market = _freezeAgent.marketId(address(_hub), address(otherSpoke), ASSET);
    assertFalse(
      _freezeAgent.validate(
        _agentId,
        _agentContext,
        _update(market, abi.encode(address(_hub), address(otherSpoke), ASSET, abi.encode(2)))
      )
    );
  }

  function test_validate_hubLevelMarket() public view {
    address market = _freezeAgent.marketId(address(_hub), address(0), ASSET);
    assertFalse(
      _freezeAgent.validate(
        _agentId,
        _agentContext,
        _update(market, abi.encode(address(_hub), address(0), ASSET, abi.encode(2)))
      )
    );
  }

  function test_validate_escalatesOnly() public {
    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(0, 105_00, 10_00));
    assertFalse(_validate(1));
    assertTrue(_validate(2));

    _spoke.setFrozen(RESERVE_ID, true);
    assertFalse(_validate(1));
    assertFalse(_validate(2));

    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(70_00, 105_00, 10_00));
    assertTrue(_validate(1));
    assertTrue(_validate(2));
  }

  function test_validate_addPathChecks() public {
    _spoke.setDynamicConfig(RESERVE_ID, type(uint32).max, _config(70_00, 105_00, 10_00));
    assertFalse(_validate(1));
    assertFalse(_validate(2));

    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(70_00, 100_00 - 1, 10_00));
    assertFalse(_validate(1));

    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(70_00, 105_00, 100_00 + 1));
    assertFalse(_validate(1));

    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(70_00, 100_00, 100_00));
    assertTrue(_validate(1));
  }

  function test_validate_addPathChecksSkippedWhenCollateralFactorIsZero() public {
    _spoke.setDynamicConfig(RESERVE_ID, type(uint32).max, _config(0, 0, 0));
    assertFalse(_validate(1));
    assertTrue(_validate(2));
  }

  function test_validate_roles() public {
    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), FREEZE, false, 0);
    assertTrue(_validate(1));
    assertFalse(_validate(2));

    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), FREEZE, true, 1);
    assertFalse(_validate(2));

    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), FREEZE, true, 0);
    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), ADD_CF, false, 0);
    assertFalse(_validate(1));
    assertFalse(_validate(2));

    _accessManager.setCanCall(address(_freezeAgent), address(_configurator), ADD_CF, true, 1);
    assertFalse(_validate(1));
  }

  function test_validate_configuratorSpokeRoles() public {
    _accessManager.setCanCall(address(_configurator), address(_spoke), SPOKE_UPDATE, false, 0);
    assertTrue(_validate(1));
    assertFalse(_validate(2));

    _accessManager.setCanCall(address(_configurator), address(_spoke), SPOKE_UPDATE, true, 1);
    assertFalse(_validate(2));

    _accessManager.setCanCall(address(_configurator), address(_spoke), SPOKE_UPDATE, true, 0);
    _accessManager.setCanCall(address(_configurator), address(_spoke), SPOKE_ADD, false, 0);
    assertFalse(_validate(1));
    assertFalse(_validate(2));

    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(0, 105_00, 10_00));
    assertTrue(_validate(2));
  }

  function test_validate_spokeAuthority() public {
    AccessManagerMock other = new AccessManagerMock();
    _spoke.setAuthority(address(other));
    assertFalse(_validate(1));
    assertFalse(_validate(2));

    other.setCanCall(address(_configurator), address(_spoke), SPOKE_ADD, true, 0);
    other.setCanCall(address(_configurator), address(_spoke), SPOKE_UPDATE, true, 0);
    assertTrue(_validate(2));

    _spoke.setAuthority(address(0));
    assertFalse(_validate(1));
    _spoke.setAuthority(address(0xdead));
    assertFalse(_validate(1));
  }

  function test_validate_spokeReadsFailClosed() public {
    vm.mockCallRevert(address(_spoke), abi.encodeCall(ISpoke.getReserve, (RESERVE_ID)), 'reverted');
    assertFalse(_validate(1));
    vm.clearMockedCalls();

    vm.mockCall(
      address(_spoke),
      abi.encodeCall(ISpoke.getDynamicReserveConfig, (RESERVE_ID, KEY)),
      abi.encode(uint256(1) << 16, 105_00, 10_00)
    );
    assertFalse(_validate(1));
    vm.clearMockedCalls();

    vm.mockCall(
      address(_spoke),
      abi.encodeCall(ISpoke.getReserveConfig, (RESERVE_ID)),
      abi.encode(0, false, 2, false, false)
    );
    assertFalse(_validate(2));
    vm.clearMockedCalls();
    assertTrue(_validate(2));
  }

  function test_inject_ltv0() public {
    _inject(1);
    ISpoke.DynamicReserveConfig memory latest = _latest();
    assertEq(_spoke.getReserve(RESERVE_ID).dynamicConfigKey, KEY + 1);
    assertEq(latest.collateralFactor, 0);
    assertEq(latest.maxLiquidationBonus, 105_00);
    assertEq(latest.liquidationFee, 10_00);
    assertFalse(_spoke.getReserveConfig(RESERVE_ID).frozen);
    assertEq(_spoke.getDynamicReserveConfig(RESERVE_ID, KEY).collateralFactor, 70_00);
    assertEq(_configurator.addCalls(), 1);
    assertEq(_configurator.freezeCalls(), 0);
  }

  function test_inject_freeze() public {
    _inject(2);
    assertEq(_spoke.getReserve(RESERVE_ID).dynamicConfigKey, KEY + 1);
    assertEq(_latest().collateralFactor, 0);
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).frozen);
    assertEq(_configurator.addCalls(), 1);
    assertEq(_configurator.freezeCalls(), 1);
  }

  function test_inject_freezeAfterLtv0() public {
    _inject(1);
    _inject(2);
    assertEq(_spoke.getReserve(RESERVE_ID).dynamicConfigKey, KEY + 1);
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).frozen);
    assertEq(_configurator.addCalls(), 1);
    assertEq(_configurator.freezeCalls(), 1);
  }

  function test_inject_ltv0OnFrozenReserve() public {
    _spoke.setFrozen(RESERVE_ID, true);
    _inject(2);
    assertEq(_latest().collateralFactor, 0);
    assertEq(_configurator.addCalls(), 1);
    assertEq(_configurator.freezeCalls(), 0);
  }

  function test_inject_revertsWhenNoop() public {
    _inject(2);
    for (uint256 level = 1; level <= 2; level++) {
      IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(level));
      vm.prank(address(_agentHub));
      vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
      _freezeAgent.inject(_agentId, _agentContext, update);
    }
  }

  function test_checkAndExecute_escalation() public {
    _publish(_market, _payload(1));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_latest().collateralFactor, 0);
    assertFalse(_spoke.getReserveConfig(RESERVE_ID).frozen);

    _publish(_market, _payload(1));
    assertFalse(_checkAndPerformAutomation(_agentId));

    _publish(_market, _payload(2));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).frozen);
    assertEq(_spoke.getReserve(RESERVE_ID).dynamicConfigKey, KEY + 1);

    _publish(_market, _payload(1));
    assertFalse(_checkAndPerformAutomation(_agentId));
    _publish(_market, _payload(2));
    assertFalse(_checkAndPerformAutomation(_agentId));
  }

  function test_fuzz_monotonic(uint16 collateralFactor, bool frozen, uint256 level) public {
    collateralFactor = uint16(bound(collateralFactor, 0, 95_00));
    level = bound(level, 0, 3);
    _spoke.setDynamicConfig(RESERVE_ID, KEY, _config(collateralFactor, 105_00, 10_00));
    _spoke.setFrozen(RESERVE_ID, frozen);

    bool expected = level == 1
      ? collateralFactor != 0
      : level == 2 && (collateralFactor != 0 || !frozen);
    assertEq(_validate(level), expected);
    if (!expected) return;

    _inject(level);
    assertEq(_latest().collateralFactor, 0);
    assertEq(_spoke.getReserveConfig(RESERVE_ID).frozen, frozen || level == 2);
    assertEq(_spoke.getReserve(RESERVE_ID).dynamicConfigKey, collateralFactor == 0 ? KEY : KEY + 1);
    assertFalse(_validate(1));
    assertEq(_validate(2), level == 1 && !frozen);
  }

  function _validate(uint256 level) internal view returns (bool) {
    return _freezeAgent.validate(_agentId, _agentContext, _update(_market, _payload(level)));
  }

  function _inject(uint256 level) internal {
    vm.prank(address(_agentHub));
    _freezeAgent.inject(_agentId, _agentContext, _update(_market, _payload(level)));
  }

  function _latest() internal view returns (ISpoke.DynamicReserveConfig memory) {
    return
      _spoke.getDynamicReserveConfig(RESERVE_ID, _spoke.getReserve(RESERVE_ID).dynamicConfigKey);
  }

  function _config(
    uint16 collateralFactor,
    uint32 maxLiquidationBonus,
    uint16 liquidationFee
  ) internal pure returns (ISpoke.DynamicReserveConfig memory) {
    return
      ISpoke.DynamicReserveConfig({
        collateralFactor: collateralFactor,
        maxLiquidationBonus: maxLiquidationBonus,
        liquidationFee: liquidationFee
      });
  }

  function _payload(uint256 level) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(_spoke), ASSET, abi.encode(level));
  }

  function _update(
    address market,
    bytes memory newValue
  ) internal view returns (IRiskOracle.RiskParameterUpdate memory update) {
    update.timestamp = block.timestamp;
    update.newValue = newValue;
    update.updateType = _updateType;
    update.updateId = 1;
    update.market = market;
  }

  function _publish(address market, bytes memory newValue) internal {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('ref', newValue, _updateType, market, '');
  }
}
