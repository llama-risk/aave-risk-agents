// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {IAccessManaged} from '../../../src/contracts/dependencies/v4/IAccessManaged.sol';
import {IAccessManager} from '../../../src/contracts/dependencies/v4/IAccessManager.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {AaveV4DynamicConfigAgent} from '../../../src/contracts/agent/v4/AaveV4DynamicConfigAgent.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {HubMock, AccessManagerMock} from './mocks/AaveV4Mocks.sol';
import {DynamicConfigSpokeMock, DynamicConfigSpokeConfiguratorMock} from './mocks/AaveV4DynamicConfigMocks.sol';

abstract contract AaveV4DynamicConfigAgentTestBase is BaseAgentTest {
  AaveV4DynamicConfigAgent.Mode internal _mode;
  RangeValidationModule internal _rangeValidationModule;
  AccessManagerMock internal _accessManager;
  DynamicConfigSpokeConfiguratorMock internal _configurator;
  HubMock internal _hub;
  DynamicConfigSpokeMock internal _spoke;
  AaveV4DynamicConfigAgent internal _dynamicAgent;
  address internal _market;

  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  address internal constant ADMIN = address(0xAD);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant RESERVE_ID = 5;
  uint16 internal constant CF = 78_00;
  uint32 internal constant LB = 105_50;
  uint16 internal constant FEE = 10_00;
  uint256 internal constant MAX_KEYS = 4;

  constructor(
    string memory updateType,
    AaveV4DynamicConfigAgent.Mode mode
  ) BaseAgentTest(updateType) {
    _mode = mode;
  }

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _accessManager = new AccessManagerMock();
    _configurator = new DynamicConfigSpokeConfiguratorMock(address(_accessManager));
    _hub = new HubMock();
    _spoke = new DynamicConfigSpokeMock(address(_accessManager));

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listSpoke(ASSET_ID, address(_spoke));
    _spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID, _config(CF, LB));

    _dynamicAgent = _newAgent(MAX_KEYS);
    _market = _dynamicAgent.marketId(address(_hub), address(_spoke), ASSET);
    _accessManager.setCanCall(
      address(_configurator),
      address(_spoke),
      ISpoke.updateDynamicReserveConfig.selector,
      true,
      0
    );
    _accessManager.setCanCall(
      address(_configurator),
      address(_spoke),
      ISpoke.addDynamicReserveConfig.selector,
      true,
      0
    );
    return address(_dynamicAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.allowedMarkets = _addressToArray(_market);
    return config;
  }

  function _postSetup() internal override {
    _setRanges(_agentId);
    _dynamicAgent.setBand(
      address(_hub),
      address(_spoke),
      ASSET,
      AaveV4DynamicConfigAgent.Field.CF,
      50_00,
      85_00
    );
    _dynamicAgent.setBand(
      address(_hub),
      address(_spoke),
      ASSET,
      AaveV4DynamicConfigAgent.Field.LB,
      101_00,
      115_00
    );
  }

  function test_constructor() public {
    assertEq(uint8(_dynamicAgent.MODE()), uint8(_mode));
    assertEq(_dynamicAgent.MAX_KEYS_PER_UPDATE(), MAX_KEYS);
    assertEq(_dynamicAgent.getUpdateType(), _updateType);

    uint256 limit = _dynamicAgent.MAX_KEYS_LIMIT();
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidMaxKeys.selector);
    _newAgent(0);
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidMaxKeys.selector);
    _newAgent(limit + 1);
  }

  function test_configuratorSelector() public {
    _allowAgent(address(_dynamicAgent), false);
    assertFalse(_validate(_validValue()));
    _allowAgent(address(_dynamicAgent), true);
    assertTrue(_validate(_validValue()));
  }

  function test_setBand() public {
    vm.expectEmit(address(_dynamicAgent));
    emit AaveV4DynamicConfigAgent.BandSet(_market, AaveV4DynamicConfigAgent.Field.CF, 60_00, 80_00);
    _setBand(AaveV4DynamicConfigAgent.Field.CF, 60_00, 80_00);
    (uint32 min, uint32 max) = _dynamicAgent.bands(_market, AaveV4DynamicConfigAgent.Field.CF);
    assertEq(min, 60_00);
    assertEq(max, 80_00);

    _setBand(AaveV4DynamicConfigAgent.Field.LB, 100_00, type(uint32).max);
  }

  function test_setBand_onlyHubOwner(address caller) public {
    vm.assume(caller != address(this));
    vm.prank(caller);
    vm.expectRevert(abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, caller));
    _setBand(AaveV4DynamicConfigAgent.Field.CF, 60_00, 80_00);
  }

  function test_setBand_invalid() public {
    _expectInvalidBand(AaveV4DynamicConfigAgent.Field.CF, 0, 80_00);
    _expectInvalidBand(AaveV4DynamicConfigAgent.Field.CF, 60_00, 100_00);
    _expectInvalidBand(AaveV4DynamicConfigAgent.Field.CF, 80_00, 60_00);
    _expectInvalidBand(AaveV4DynamicConfigAgent.Field.LB, 99_99, 110_00);
    _expectInvalidBand(AaveV4DynamicConfigAgent.Field.LB, 110_00, 105_00);
  }

  function test_tightenBand() public {
    _agentHub.setAgentAdmin(_agentId, ADMIN);
    vm.prank(ADMIN);
    _tightenBand(_agentId, AaveV4DynamicConfigAgent.Field.LB, 102_00, 110_00);
    (uint32 min, uint32 max) = _dynamicAgent.bands(_market, AaveV4DynamicConfigAgent.Field.LB);
    assertEq(min, 102_00);
    assertEq(max, 110_00);

    vm.prank(ADMIN);
    _tightenBand(_agentId, AaveV4DynamicConfigAgent.Field.LB, 102_00, 102_00);
  }

  function test_tightenBand_cannotWiden() public {
    _agentHub.setAgentAdmin(_agentId, ADMIN);
    vm.startPrank(ADMIN);
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidBand.selector);
    _tightenBand(_agentId, AaveV4DynamicConfigAgent.Field.CF, 49_99, 85_00);
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidBand.selector);
    _tightenBand(_agentId, AaveV4DynamicConfigAgent.Field.CF, 50_00, 85_01);
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidBand.selector);
    _tightenBand(_agentId, AaveV4DynamicConfigAgent.Field.CF, 70_00, 60_00);
    vm.stopPrank();
  }

  function test_tightenBand_unsetBand() public {
    _agentHub.addAllowedMarket(
      _agentId,
      _dynamicAgent.marketId(address(_hub), address(_spoke), OTHER_ASSET)
    );
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidBand.selector);
    _dynamicAgent.tightenBand(
      _agentId,
      address(_hub),
      address(_spoke),
      OTHER_ASSET,
      AaveV4DynamicConfigAgent.Field.CF,
      0,
      0
    );
  }

  function test_tightenBand_onlyAgentAdmin() public {
    _agentHub.setAgentAdmin(_agentId, ADMIN);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, address(this))
    );
    _tightenBand(_agentId, AaveV4DynamicConfigAgent.Field.LB, 102_00, 110_00);

    uint256 otherAgentId = _registerOther(address(0xDEAD));
    _agentHub.setAgentAdmin(otherAgentId, ADMIN);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, ADMIN));
    _tightenBand(otherAgentId, AaveV4DynamicConfigAgent.Field.LB, 102_00, 110_00);
  }

  function test_tightenBand_marketNotAllowedForAgentId() public {
    uint256 otherAgentId = _registerOther(address(_dynamicAgent));
    _agentHub.removeAllowedMarket(otherAgentId, _market);
    _agentHub.setAgentAdmin(otherAgentId, ADMIN);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, ADMIN));
    _tightenBand(otherAgentId, AaveV4DynamicConfigAgent.Field.LB, 101_00, 101_00);
  }

  function test_tightenBand_disabledAgentId() public {
    uint256 otherAgentId = _registerOther(address(_dynamicAgent));
    _agentHub.setAgentEnabled(otherAgentId, false);
    _agentHub.setAgentAdmin(otherAgentId, ADMIN);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, ADMIN));
    _tightenBand(otherAgentId, AaveV4DynamicConfigAgent.Field.LB, 101_00, 101_00);

    _agentHub.setAgentEnabled(otherAgentId, true);
    vm.prank(ADMIN);
    _tightenBand(otherAgentId, AaveV4DynamicConfigAgent.Field.LB, 101_00, 101_00);
  }

  function test_setMinLiveKey() public {
    _spoke.setKey(RESERVE_ID, 2, _config(CF, LB));
    vm.expectEmit(address(_dynamicAgent));
    emit AaveV4DynamicConfigAgent.MinLiveKeySet(_market, 2);
    _setMinLiveKey(_agentId, 2);
    assertEq(_dynamicAgent.minLiveKey(_market), 2);

    _setMinLiveKey(_agentId, 1);
    assertEq(_dynamicAgent.minLiveKey(_market), 1);

    _agentHub.setAgentAdmin(_agentId, ADMIN);
    vm.prank(ADMIN);
    _setMinLiveKey(_agentId, 2);
    assertEq(_dynamicAgent.minLiveKey(_market), 2);
  }

  function test_setMinLiveKey_adminCannotLower() public {
    _spoke.setKey(RESERVE_ID, 2, _config(CF, LB));
    _setMinLiveKey(_agentId, 2);
    _agentHub.setAgentAdmin(_agentId, ADMIN);
    vm.prank(ADMIN);
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidKey.selector);
    _setMinLiveKey(_agentId, 1);
  }

  function test_setMinLiveKey_marketNotAllowedForAgentId() public {
    _spoke.setKey(RESERVE_ID, 1, _config(CF, LB));
    uint256 otherAgentId = _registerOther(address(_dynamicAgent));
    _agentHub.removeAllowedMarket(otherAgentId, _market);
    _agentHub.setAgentAdmin(otherAgentId, ADMIN);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, ADMIN));
    _setMinLiveKey(otherAgentId, 1);
  }

  function test_setMinLiveKey_unauthorized(address caller) public {
    vm.assume(caller != address(this));
    vm.prank(caller);
    vm.expectRevert(abi.encodeWithSelector(AaveV4DynamicConfigAgent.Unauthorized.selector, caller));
    _setMinLiveKey(_agentId, 0);
  }

  function test_setMinLiveKey_invalidKey() public {
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidKey.selector);
    _setMinLiveKey(_agentId, 1);

    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidKey.selector);
    _dynamicAgent.setMinLiveKey(_agentId, address(_hub), address(_spoke), OTHER_ASSET, 0);
  }

  function test_validate_valid() public view {
    assertTrue(_validate(_validValue()));
  }

  function test_validate_frozen() public {
    _spoke.setFrozen(RESERVE_ID, true);
    assertFalse(_validate(_validValue()));
  }

  function test_validate_latestKeyCfZero() public {
    _spoke.setKey(RESERVE_ID, 1, _config(0, LB));
    assertFalse(_validate(_validValue()));
  }

  function test_validate_spokeRejectsConfigurator() public {
    _accessManager.setCanCall(
      address(_configurator),
      address(_spoke),
      _spokeSelector(),
      true,
      1 hours
    );
    assertFalse(_validate(_validValue()));
    _accessManager.setCanCall(address(_configurator), address(_spoke), _spokeSelector(), false, 0);
    assertFalse(_validate(_validValue()));
  }

  function test_validate_spokeAuthorityMalformed() public {
    bytes memory authorityCall = abi.encodeCall(IAccessManaged.authority, ());
    vm.mockCall(address(_spoke), authorityCall, hex'01');
    assertFalse(_validate(_validValue()));
    vm.mockCall(address(_spoke), authorityCall, abi.encode(type(uint256).max));
    assertFalse(_validate(_validValue()));
    vm.mockCall(address(_spoke), authorityCall, abi.encode(address(0xBEEF)));
    assertFalse(_validate(_validValue()));
    vm.clearMockedCalls();

    bytes memory canCall = abi.encodeCall(
      IAccessManager.canCall,
      (address(_configurator), address(_spoke), _spokeSelector())
    );
    vm.mockCall(address(_accessManager), canCall, abi.encode(true));
    assertFalse(_validate(_validValue()));
    vm.mockCall(address(_accessManager), canCall, abi.encode(uint256(2), uint256(0)));
    assertFalse(_validate(_validValue()));
    vm.clearMockedCalls();
    assertTrue(_validate(_validValue()));
  }

  function test_validate_unlistedAsset() public view {
    address market = _dynamicAgent.marketId(address(_hub), address(_spoke), OTHER_ASSET);
    assertFalse(
      _dynamicAgent.validate(
        _agentId,
        _agentContext,
        _update(market, abi.encode(address(_hub), address(_spoke), OTHER_ASSET, _validValue()))
      )
    );
  }

  function test_validate_marketMismatch() public view {
    assertFalse(
      _dynamicAgent.validate(
        _agentId,
        _agentContext,
        _update(address(0x1234), _payload(_validValue()))
      )
    );
  }

  function test_validate_unsetBand() public {
    AaveV4DynamicConfigAgent agent = _newAgent(MAX_KEYS);
    _allowAgent(address(agent), true);
    assertFalse(agent.validate(_agentId, _agentContext, _update(_market, _payload(_validValue()))));
  }

  function test_checkAndExecute() public {
    _publish(_validValue());
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_configurator.calls(), _expectedCalls());
  }

  function test_inject_revertsWhenInvalid() public {
    _spoke.setFrozen(RESERVE_ID, true);
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(_validValue()));
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _dynamicAgent.inject(_agentId, _agentContext, update);
  }

  function _validValue() internal pure virtual returns (bytes memory);

  function _expectedCalls() internal pure virtual returns (uint256) {
    return 1;
  }

  function _spokeSelector() internal view returns (bytes4) {
    return
      _mode == AaveV4DynamicConfigAgent.Mode.LB_IN_PLACE
        ? ISpoke.updateDynamicReserveConfig.selector
        : ISpoke.addDynamicReserveConfig.selector;
  }

  function _agentSelector() internal view returns (bytes4) {
    if (_mode == AaveV4DynamicConfigAgent.Mode.LB_IN_PLACE) {
      return ISpokeConfigurator.updateMaxLiquidationBonus.selector;
    }
    if (_mode == AaveV4DynamicConfigAgent.Mode.CF_ADD) {
      return ISpokeConfigurator.addCollateralFactor.selector;
    }
    return ISpokeConfigurator.addDynamicReserveConfig.selector;
  }

  function _newAgent(uint256 maxKeys) internal returns (AaveV4DynamicConfigAgent agent) {
    agent = new AaveV4DynamicConfigAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      address(_configurator),
      _mode,
      '',
      maxKeys
    );
    _allowAgent(address(agent), true);
  }

  function _allowAgent(address agent, bool allowed) internal {
    _accessManager.setCanCall(agent, address(_configurator), _agentSelector(), allowed, 0);
  }

  function _setRanges(uint256 agentId) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      agentId,
      'CollateralFactor',
      IRangeValidationModule.RangeConfig({
        maxIncrease: 2_00,
        maxDecrease: 1_00,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      agentId,
      'MaxLiquidationBonus',
      IRangeValidationModule.RangeConfig({
        maxIncrease: 2_00,
        maxDecrease: 1_00,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function _registerOther(address agent) internal returns (uint256) {
    return
      _agentHub.registerAgent(
        IAgentConfigurator.AgentRegistrationInput({
          agentAddress: agent,
          riskOracle: address(_riskOracle),
          admin: address(this),
          agentContext: '',
          isAgentEnabled: true,
          isAgentPermissioned: false,
          isMarketsFromAgentEnabled: false,
          expirationPeriod: 1 days,
          minimumDelay: 1 days,
          updateType: _updateType,
          allowedMarkets: _addressToArray(_market),
          restrictedMarkets: new address[](0),
          permissionedSenders: new address[](0)
        })
      );
  }

  function _setBand(AaveV4DynamicConfigAgent.Field field, uint32 min, uint32 max) internal {
    _dynamicAgent.setBand(address(_hub), address(_spoke), ASSET, field, min, max);
  }

  function _tightenBand(
    uint256 agentId,
    AaveV4DynamicConfigAgent.Field field,
    uint32 min,
    uint32 max
  ) internal {
    _dynamicAgent.tightenBand(agentId, address(_hub), address(_spoke), ASSET, field, min, max);
  }

  function _setMinLiveKey(uint256 agentId, uint32 key) internal {
    _dynamicAgent.setMinLiveKey(agentId, address(_hub), address(_spoke), ASSET, key);
  }

  function _expectInvalidBand(
    AaveV4DynamicConfigAgent.Field field,
    uint32 min,
    uint32 max
  ) internal {
    vm.expectRevert(AaveV4DynamicConfigAgent.InvalidBand.selector);
    _setBand(field, min, max);
  }

  function _config(
    uint16 cf,
    uint32 lb
  ) internal pure returns (ISpoke.DynamicReserveConfig memory) {
    return
      ISpoke.DynamicReserveConfig({
        collateralFactor: cf,
        maxLiquidationBonus: lb,
        liquidationFee: FEE
      });
  }

  function _key(uint32 key) internal view returns (ISpoke.DynamicReserveConfig memory) {
    return _spoke.getDynamicReserveConfig(RESERVE_ID, key);
  }

  function _lastKey() internal view returns (uint32) {
    return _spoke.getReserve(RESERVE_ID).dynamicConfigKey;
  }

  function _payload(bytes memory value) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(_spoke), ASSET, value);
  }

  function _validate(bytes memory value) internal view returns (bool) {
    return _dynamicAgent.validate(_agentId, _agentContext, _update(_market, _payload(value)));
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

  function _publish(bytes memory value) internal {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('ref', _payload(value), _updateType, _market, '');
  }
}

contract AaveV4DynamicConfigAgentLB_Test is
  AaveV4DynamicConfigAgentTestBase(
    'MaxLiquidationBonusUpdate',
    AaveV4DynamicConfigAgent.Mode.LB_IN_PLACE
  )
{
  function test_lb_updatesLiveKeysInPlace() public {
    _spoke.setKey(RESERVE_ID, 1, _config(0, LB));
    _spoke.setKey(RESERVE_ID, 2, _config(70_00, 105_00));
    _spoke.setKey(RESERVE_ID, 3, _config(CF, LB));

    _publish(abi.encode(uint256(107_00)));
    vm.expectEmit(address(_dynamicAgent));
    uint32[] memory keys = new uint32[](3);
    keys[1] = 2;
    keys[2] = 3;
    emit AaveV4DynamicConfigAgent.MaxLiquidationBonusUpdated(_market, RESERVE_ID, keys, 107_00);
    assertTrue(_checkAndPerformAutomation(_agentId));

    assertEq(_lastKey(), 3);
    assertEq(_key(0).maxLiquidationBonus, 107_00);
    assertEq(_key(1).maxLiquidationBonus, LB);
    assertEq(_key(2).maxLiquidationBonus, 107_00);
    assertEq(_key(3).maxLiquidationBonus, 107_00);
    assertEq(_key(0).collateralFactor, CF);
    assertEq(_key(2).collateralFactor, 70_00);
    assertEq(_key(0).liquidationFee, FEE);
    assertEq(_configurator.calls(), 3);
  }

  function test_lb_skipsKeysAlreadyAtValue() public {
    _spoke.setKey(RESERVE_ID, 1, _config(CF, 106_00));
    _publish(abi.encode(uint256(106_00)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_configurator.calls(), 1);
    assertEq(_key(0).maxLiquidationBonus, 106_00);
  }

  function test_lb_lowerThenRaise() public {
    _publish(abi.encode(uint256(104_50)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_key(0).maxLiquidationBonus, 104_50);

    vm.warp(block.timestamp + 1 days);
    _publish(abi.encode(uint256(106_50)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_key(0).maxLiquidationBonus, 106_50);
  }

  function test_lb_noop() public view {
    assertFalse(_validate(abi.encode(uint256(LB))));
  }

  function test_lb_outOfBand() public {
    _setBand(AaveV4DynamicConfigAgent.Field.LB, 101_00, 105_00);
    assertFalse(_validate(abi.encode(uint256(106_00))));
    assertTrue(_validate(abi.encode(uint256(105_00))));
  }

  function test_lb_outOfRange() public view {
    assertFalse(_validate(abi.encode(uint256(LB + 2_01))));
    assertFalse(_validate(abi.encode(uint256(LB - 1_01))));
    assertTrue(_validate(abi.encode(uint256(LB + 2_00))));
    assertTrue(_validate(abi.encode(uint256(LB - 1_00))));
  }

  function test_lb_rangeCheckedAgainstLatestKey() public {
    _spoke.setKey(RESERVE_ID, 1, _config(CF, 103_00));
    assertFalse(_validate(abi.encode(uint256(105_01))));
    assertFalse(_validate(abi.encode(uint256(101_99))));
    assertTrue(_validate(abi.encode(uint256(105_00))));
    assertTrue(_validate(abi.encode(uint256(102_00))));
  }

  function test_lb_divergentKeysDoNotStall() public {
    _spoke.setKey(RESERVE_ID, 1, _config(CF, 110_00));
    _publish(abi.encode(uint256(111_00)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_key(0).maxLiquidationBonus, 111_00);
    assertEq(_key(1).maxLiquidationBonus, 111_00);
  }

  function test_lb_latestAtTargetAlignsOlderKeys() public {
    _spoke.setKey(RESERVE_ID, 1, _config(CF, 110_00));
    _publish(abi.encode(uint256(110_00)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_configurator.calls(), 1);
    assertEq(_key(0).maxLiquidationBonus, 110_00);
  }

  function test_lb_unsafeOnAnyKey() public {
    _spoke.setKey(RESERVE_ID, 1, _config(94_00, LB));
    assertFalse(_validate(abi.encode(uint256(107_00))));
    assertTrue(_validate(abi.encode(uint256(106_00))));
  }

  function test_lb_boundaryOfProtocolInvariant() public {
    _setBand(AaveV4DynamicConfigAgent.Field.LB, 100_00, 115_00);
    _spoke.setKey(RESERVE_ID, 1, _config(99_00, 100_00));
    _setMinLiveKey(_agentId, 1);
    assertTrue(_validate(abi.encode(uint256(101_00))));
    _spoke.setKey(RESERVE_ID, 2, _config(99_00, 101_00));
    assertFalse(_validate(abi.encode(uint256(101_02))));
  }

  function test_lb_maxKeysPerUpdate() public {
    for (uint32 key = 1; key <= MAX_KEYS; key++) {
      _spoke.setKey(RESERVE_ID, key, _config(CF, LB));
    }
    assertFalse(_validate(abi.encode(uint256(106_00))));

    _setMinLiveKey(_agentId, 1);
    assertTrue(_validate(abi.encode(uint256(106_00))));

    _publish(abi.encode(uint256(106_00)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_key(0).maxLiquidationBonus, LB);
    for (uint32 key = 1; key <= MAX_KEYS; key++) {
      assertEq(_key(key).maxLiquidationBonus, 106_00);
    }
  }

  function test_lb_badPayload() public view {
    assertFalse(_validate(abi.encode(uint256(type(uint32).max) + 1)));
    assertFalse(_validate(abi.encode(uint256(106_00), uint256(0))));
    assertFalse(_validate(bytes('')));
  }

  function test_lb_gasAtKeyLimit() public {
    uint256 maxKeys = _dynamicAgent.MAX_KEYS_LIMIT();
    AaveV4DynamicConfigAgent agent = _newAgent(maxKeys);
    _agentHub.setAgentAddress(_agentId, address(agent));
    _setRanges(_agentId);
    agent.setBand(
      address(_hub),
      address(_spoke),
      ASSET,
      AaveV4DynamicConfigAgent.Field.LB,
      101_00,
      115_00
    );
    for (uint32 key = 1; key < maxKeys; key++) {
      _spoke.setKey(RESERVE_ID, key, _config(CF, LB));
    }

    _publish(abi.encode(uint256(107_00)));
    uint256 gasBefore = gasleft();
    assertTrue(_checkAndPerformAutomation(_agentId));
    uint256 gasUsed = gasBefore - gasleft();
    assertLt(gasUsed, 5_000_000);
    assertEq(_configurator.calls(), maxKeys);
    assertEq(_key(uint32(maxKeys - 1)).maxLiquidationBonus, 107_00);
  }

  function _validValue() internal pure override returns (bytes memory) {
    return abi.encode(uint256(106_00));
  }
}

contract AaveV4DynamicConfigAgentCF_Test is
  AaveV4DynamicConfigAgentTestBase('CollateralFactorUpdate', AaveV4DynamicConfigAgent.Mode.CF_ADD)
{
  function test_cf_addsKey() public {
    _publish(abi.encode(uint256(80_00)));
    vm.expectEmit(address(_dynamicAgent));
    emit AaveV4DynamicConfigAgent.DynamicConfigAdded(_market, RESERVE_ID, 1, 80_00, LB);
    assertTrue(_checkAndPerformAutomation(_agentId));

    assertEq(_lastKey(), 1);
    assertEq(_key(0).collateralFactor, CF);
    assertEq(_key(1).collateralFactor, 80_00);
    assertEq(_key(1).maxLiquidationBonus, LB);
    assertEq(_key(1).liquidationFee, FEE);
  }

  function test_cf_decreaseAddsKeyAndKeepsOldKey() public {
    _publish(abi.encode(uint256(77_00)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_lastKey(), 1);
    assertEq(_key(0).collateralFactor, CF);
    assertEq(_key(1).collateralFactor, 77_00);
  }

  function test_cf_noop() public view {
    assertFalse(_validate(abi.encode(uint256(CF))));
  }

  function test_cf_outOfBand() public {
    _setBand(AaveV4DynamicConfigAgent.Field.CF, 50_00, 79_00);
    assertFalse(_validate(abi.encode(uint256(79_01))));
    assertTrue(_validate(abi.encode(uint256(79_00))));
    assertFalse(_validate(abi.encode(uint256(0))));
  }

  function test_cf_outOfRange() public view {
    assertFalse(_validate(abi.encode(uint256(CF + 2_01))));
    assertFalse(_validate(abi.encode(uint256(CF - 1_01))));
    assertTrue(_validate(abi.encode(uint256(CF - 1_00))));
  }

  function test_cf_unsafeWithLatestBonus() public {
    _spoke.setKey(RESERVE_ID, 1, _config(82_00, 120_00));
    assertFalse(_validate(abi.encode(uint256(84_00))));
    assertTrue(_validate(abi.encode(uint256(83_00))));
  }

  function test_cf_keySpaceExhausted() public {
    _spoke.setKey(RESERVE_ID, type(uint32).max, _config(CF, LB));
    assertFalse(_validate(_validValue()));
  }

  function test_cf_badPayload() public view {
    assertFalse(_validate(abi.encode(uint256(type(uint16).max) + 1)));
    assertFalse(_validate(abi.encode(uint256(79_00), uint256(LB))));
  }

  function _validValue() internal pure override returns (bytes memory) {
    return abi.encode(uint256(79_00));
  }
}

contract AaveV4DynamicConfigAgentPT_Test is
  AaveV4DynamicConfigAgentTestBase('PtDynamicConfigUpdate', AaveV4DynamicConfigAgent.Mode.PT)
{
  function test_pt_addsKeyWithBothFields() public {
    _publish(abi.encode(uint256(79_00), uint256(106_00)));
    vm.expectEmit(address(_dynamicAgent));
    emit AaveV4DynamicConfigAgent.DynamicConfigAdded(_market, RESERVE_ID, 1, 79_00, 106_00);
    assertTrue(_checkAndPerformAutomation(_agentId));

    assertEq(_lastKey(), 1);
    assertEq(_key(0).collateralFactor, CF);
    assertEq(_key(0).maxLiquidationBonus, LB);
    assertEq(_key(1).collateralFactor, 79_00);
    assertEq(_key(1).maxLiquidationBonus, 106_00);
    assertEq(_key(1).liquidationFee, FEE);
  }

  function test_pt_singleFieldChange() public view {
    assertTrue(_validate(abi.encode(uint256(CF), uint256(106_00))));
    assertTrue(_validate(abi.encode(uint256(79_00), uint256(LB))));
  }

  function test_pt_noop() public view {
    assertFalse(_validate(abi.encode(uint256(CF), uint256(LB))));
  }

  function test_pt_outOfBand() public view {
    assertFalse(_validate(abi.encode(uint256(CF), uint256(100_99))));
    assertFalse(_validate(abi.encode(uint256(49_99), uint256(LB))));
  }

  function test_pt_outOfRange() public view {
    assertFalse(_validate(abi.encode(uint256(CF + 2_01), uint256(LB))));
    assertFalse(_validate(abi.encode(uint256(CF), uint256(LB + 2_01))));
    assertFalse(_validate(abi.encode(uint256(CF), uint256(LB - 1_01))));
  }

  function test_pt_unsafePair() public {
    _setBand(AaveV4DynamicConfigAgent.Field.LB, 101_00, 120_00);
    _spoke.setKey(RESERVE_ID, 1, _config(84_00, 117_00));
    assertFalse(_validate(abi.encode(uint256(85_00), uint256(118_00))));
    assertTrue(_validate(abi.encode(uint256(85_00), uint256(117_50))));
  }

  function test_pt_keySpaceExhausted() public {
    _spoke.setKey(RESERVE_ID, type(uint32).max, _config(CF, LB));
    assertFalse(_validate(_validValue()));
  }

  function test_pt_badPayload() public view {
    assertFalse(_validate(abi.encode(uint256(79_00))));
    assertFalse(_validate(abi.encode(uint256(79_00), uint256(106_00), uint256(0))));
    assertFalse(_validate(abi.encode(uint256(type(uint16).max) + 1, uint256(106_00))));
    assertFalse(_validate(abi.encode(uint256(79_00), uint256(type(uint32).max) + 1)));
  }

  function _validValue() internal pure override returns (bytes memory) {
    return abi.encode(uint256(79_00), uint256(106_00));
  }
}
