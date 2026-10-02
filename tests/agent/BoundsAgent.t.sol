// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IACLManager} from 'aave-address-book/AaveV3.sol';
import {IPriceCapAdapter} from 'aave-price-feeds/interfaces/IPriceCapAdapter.sol';
import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentHub, IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {BoundsAgent} from '../../src/contracts/agent/BoundsAgent.sol';
import {IBoundedRatioAdapter} from './mocks/IBoundedRatioAdapterG.sol';
import {BoundedRatioAdapterMock, MockRatioProvider, MockACLManager, MalformedAdapter} from './mocks/BoundsAgentMocks.sol';

contract BoundsAgent_Test is BaseAgentTest('RatioLowerBoundUpdate') {
  uint48 internal constant AGENT_MAX_DURATION = 2 days;
  uint48 internal constant ADAPTER_MAX_DURATION = 3 days;
  uint256 internal constant RATIO = 1.15e18;
  uint256 internal constant SEED_LOWER_BOUND = 1e18;

  RangeValidationModule internal _rangeValidationModule;
  MockACLManager internal _aclManager;
  MockRatioProvider internal _ratioProvider;
  BoundedRatioAdapterMock internal _adapter;

  function setUp() public override {
    super.setUp();
    vm.warp(1750000000);

    _aclManager = new MockACLManager();
    _aclManager.setRiskAdmin(address(_agent), true);
    _aclManager.setRiskAdmin(address(this), true);

    _ratioProvider = new MockRatioProvider(int256(RATIO));
    _adapter = _deployAdapter(_ratioProvider);
    _adapter.setLowerBound(uint104(SEED_LOWER_BOUND), uint48(block.timestamp + 1 days));
    _agentHub.addAllowedMarket(_agentId, address(_adapter));

    _setDefaultRange(5_00);
  }

  function _setDefaultRange(uint120 maxChange) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      'RatioLowerBound',
      IRangeValidationModule.RangeConfig({
        maxIncrease: maxChange,
        maxDecrease: maxChange,
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal pure override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    return config;
  }

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    return
      address(
        new BoundsAgent(address(_agentHub), address(_rangeValidationModule), '', AGENT_MAX_DURATION)
      );
  }

  function _deployAdapter(MockRatioProvider provider) internal returns (BoundedRatioAdapterMock) {
    return
      new BoundedRatioAdapterMock(
        IBoundedRatioAdapter.BoundedRatioAdapterParams({
          aclManager: IACLManager(address(_aclManager)),
          baseAggregatorAddress: address(0),
          ratioProviderAddress: address(provider),
          pairDescription: 'Bounded ratio',
          ratioDecimals: 18,
          minimumSnapshotDelay: 7 days,
          maximumLowerBoundDuration: ADAPTER_MAX_DURATION,
          priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
            snapshotRatio: uint104(RATIO),
            snapshotTimestamp: uint48(block.timestamp - 7 days),
            maxYearlyRatioGrowthPercent: 10_00
          })
        })
      );
  }

  function _update(
    address market,
    bytes memory value
  ) internal returns (IRiskOracle.RiskParameterUpdate memory) {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('referenceId', value, _updateType, market, '');
    return _riskOracle.getLatestUpdateByParameterAndMarket(_updateType, market);
  }

  function _update(
    uint256 lowerBound,
    uint256 expiration
  ) internal returns (IRiskOracle.RiskParameterUpdate memory) {
    return _update(address(_adapter), abi.encode(lowerBound, expiration));
  }

  function _validate(uint256 lowerBound, uint256 expiration) internal returns (bool) {
    return _agent.validate(_agentId, _agentContext, _update(lowerBound, expiration));
  }

  function _assertLowerBound(uint256 lowerBound, uint256 expiration) internal view {
    (uint256 storedLowerBound, uint256 storedExpiration) = _adapter.getLowerBound();
    assertEq(storedLowerBound, lowerBound);
    assertEq(storedExpiration, expiration);
  }

  function test_constructor_revertsOnZeroAddress() public {
    vm.expectRevert(BoundsAgent.InvalidZeroAddress.selector);
    new BoundsAgent(address(0), address(_rangeValidationModule), '', AGENT_MAX_DURATION);

    vm.expectRevert(BoundsAgent.InvalidZeroAddress.selector);
    new BoundsAgent(address(_agentHub), address(0), '', AGENT_MAX_DURATION);
  }

  function test_constructor_revertsOnZeroDuration() public {
    vm.expectRevert(BoundsAgent.InvalidMaxLowerBoundDuration.selector);
    new BoundsAgent(address(_agentHub), address(_rangeValidationModule), '', 0);
  }

  function test_getters() public view {
    BoundsAgent agent = BoundsAgent(address(_agent));
    assertEq(agent.getUpdateType(), 'RatioLowerBoundUpdate');
    assertEq(agent.getMarkets(_agentId).length, 0);
    assertEq(agent.MAX_LOWER_BOUND_DURATION(), AGENT_MAX_DURATION);
  }

  function test_injectionFromHub() public {
    uint256 lowerBound = 1.04e18;
    uint256 expiration = block.timestamp + 1 days;
    _update(lowerBound, expiration);

    assertTrue(_checkAndPerformAutomation(_agentId));
    _assertLowerBound(lowerBound, expiration);
    assertEq(_adapter.getActiveLowerBound(), lowerBound);
  }

  function test_injection_refreshesExpiration() public {
    uint256 expiration = block.timestamp + 2 days;
    _update(SEED_LOWER_BOUND, expiration);

    assertTrue(_checkAndPerformAutomation(_agentId));
    _assertLowerBound(SEED_LOWER_BOUND, expiration);
  }

  function test_validate_noOp() public {
    (uint256 lowerBound, uint256 expiration) = _adapter.getLowerBound();
    assertFalse(_validate(lowerBound, expiration));
  }

  function test_validate_wrongLength() public {
    assertFalse(
      _agent.validate(_agentId, _agentContext, _update(address(_adapter), abi.encode(1.04e18)))
    );
    assertFalse(
      _agent.validate(
        _agentId,
        _agentContext,
        _update(address(_adapter), abi.encode(1.04e18, block.timestamp + 1 days, 0))
      )
    );
    assertFalse(
      _agent.validate(
        _agentId,
        _agentContext,
        _update(address(_adapter), abi.encodePacked(uint104(1.04e18), uint48(block.timestamp)))
      )
    );
  }

  function test_validate_wrongUpdateType() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(1.04e18, block.timestamp + 1 days);
    assertTrue(_agent.validate(_agentId, _agentContext, update));

    update.updateType = 'RatioLowerBoundUpdate_Other';
    assertFalse(_agent.validate(_agentId, _agentContext, update));
  }

  function test_validate_zeroLowerBound() public {
    assertFalse(_validate(0, block.timestamp + 1 days));
  }

  function test_validate_lowerBoundAboveUint104() public {
    assertFalse(_validate(uint256(type(uint104).max) + 1, block.timestamp + 1 days));
  }

  function test_validate_expirationNotInFuture() public {
    assertFalse(_validate(1.04e18, block.timestamp));
    assertFalse(_validate(1.04e18, block.timestamp - 1));
    assertTrue(_validate(1.04e18, block.timestamp + 1));
  }

  function test_validate_expirationAboveAgentWindow() public {
    assertTrue(_validate(1.04e18, block.timestamp + AGENT_MAX_DURATION));
    assertFalse(_validate(1.04e18, block.timestamp + AGENT_MAX_DURATION + 1));
    assertFalse(_validate(1.04e18, type(uint256).max));
  }

  function test_validate_expirationAboveAdapterWindow() public {
    BoundsAgent agent = new BoundsAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      10 days
    );
    _aclManager.setRiskAdmin(address(agent), true);

    IRiskOracle.RiskParameterUpdate memory update = _update(
      1.04e18,
      block.timestamp + ADAPTER_MAX_DURATION
    );
    assertTrue(agent.validate(_agentId, _agentContext, update));

    update = _update(1.04e18, block.timestamp + ADAPTER_MAX_DURATION + 1);
    assertFalse(agent.validate(_agentId, _agentContext, update));
  }

  function test_validate_lowerBoundNotBelowMaxRatio() public {
    _setDefaultRange(50_00);
    _ratioProvider.setAnswer(2e18);
    uint256 maxRatio = _adapter.getMaxRatio();

    assertFalse(_validate(maxRatio, block.timestamp + 1 days));
    assertTrue(_validate(maxRatio - 1, block.timestamp + 1 days));
  }

  function test_validate_lowerBoundAboveRatio() public {
    _ratioProvider.setAnswer(1.03e18);

    assertFalse(_validate(1.03e18 + 1, block.timestamp + 1 days));
    assertTrue(_validate(1.03e18, block.timestamp + 1 days));
  }

  function test_validate_invalidRatioUsesStoredLowerBound() public {
    _ratioProvider.setReverts(true);
    _assertInvalidRatioUsesStoredLowerBound();

    _ratioProvider.setReverts(false);
    _ratioProvider.setAnswer(0);
    _assertInvalidRatioUsesStoredLowerBound();

    _ratioProvider.setAnswer(-1);
    _assertInvalidRatioUsesStoredLowerBound();
  }

  function _assertInvalidRatioUsesStoredLowerBound() internal {
    assertFalse(_validate(SEED_LOWER_BOUND + 1, block.timestamp + 1 days));
    assertTrue(_validate(SEED_LOWER_BOUND, block.timestamp + 2 days));
    assertTrue(_validate(0.96e18, block.timestamp + 1 days));
  }

  function test_injection_restoresPriceAfterExpiry() public {
    _ratioProvider.setReverts(true);
    vm.warp(block.timestamp + 1 days);
    assertEq(_adapter.latestAnswer(), 0);

    _update(SEED_LOWER_BOUND, block.timestamp + 1 days);
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_adapter.latestAnswer(), int256(SEED_LOWER_BOUND / 1e10));
  }

  function test_validate_stepInRange(uint256 change) public {
    change = bound(change, 0, 5_00);
    uint256 expiration = block.timestamp + 1 days + 1;
    assertTrue(_validate((SEED_LOWER_BOUND * (100_00 + change)) / 100_00, expiration));
    assertTrue(_validate((SEED_LOWER_BOUND * (100_00 - change)) / 100_00, expiration + 1));
  }

  function test_validate_stepOutOfRange(uint256 change) public {
    change = bound(change, 5_01, 10_00);
    uint256 expiration = block.timestamp + 1 days;
    assertFalse(_validate((SEED_LOWER_BOUND * (100_00 + change)) / 100_00, expiration));
    assertFalse(_validate((SEED_LOWER_BOUND * (100_00 - change)) / 100_00, expiration));
  }

  function test_validate_firstLowerBoundStepsFromRatio() public {
    BoundedRatioAdapterMock adapter = _deployAdapter(_ratioProvider);
    _agentHub.addAllowedMarket(_agentId, address(adapter));

    bytes memory value = abi.encode(1.1e18, block.timestamp + 1 days);
    assertTrue(_agent.validate(_agentId, _agentContext, _update(address(adapter), value)));
    value = abi.encode(1.09e18, block.timestamp + 1 days);
    assertFalse(_agent.validate(_agentId, _agentContext, _update(address(adapter), value)));
  }

  function test_injection_expiredLowerBoundFollowsRatioDrop() public {
    _ratioProvider.setAnswer(0.9e18);
    vm.warp(block.timestamp + 1 days);
    assertEq(_adapter.getActiveLowerBound(), 0);

    assertFalse(_validate(0.85e18, block.timestamp + 1 days));
    _update(0.89e18, block.timestamp + 1 days);
    assertTrue(_checkAndPerformAutomation(_agentId));
    _assertLowerBound(0.89e18, block.timestamp + 1 days);
  }

  function test_injection_activeLowerBoundAboveRatioFollowsRatio() public {
    _ratioProvider.setAnswer(0.8e18);
    assertTrue(_adapter.isFloored());

    assertFalse(_validate(0.75e18, block.timestamp + 1 days));
    assertTrue(_validate(0.78e18, block.timestamp + 1 days));
    _update(0.8e18, block.timestamp + 1 hours);
    assertTrue(_checkAndPerformAutomation(_agentId));
    _assertLowerBound(0.8e18, block.timestamp + 1 hours);
    assertFalse(_adapter.isFloored());
  }

  function testFuzz_validate_ratioAcceptedWithoutLowerBoundBelowIt(
    uint256 ratio,
    bool expired
  ) public {
    ratio = bound(ratio, 1, RATIO);
    if (!expired) ratio = bound(ratio, 1, SEED_LOWER_BOUND - 1);
    _ratioProvider.setAnswer(int256(ratio));
    if (expired) vm.warp(block.timestamp + 1 days);

    assertTrue(_validate(ratio, block.timestamp + 1 hours));
  }

  function test_validate_agentWithoutRole() public {
    _aclManager.setRiskAdmin(address(_agent), false);
    assertFalse(_validate(1.04e18, block.timestamp + 1 days));

    _aclManager.setPoolAdmin(address(_agent), true);
    assertTrue(_validate(1.04e18, block.timestamp + 1 days));
  }

  function test_validate_marketNotAdapter() public {
    bytes memory value = abi.encode(1.04e18, block.timestamp + 1 days);
    address[4] memory markets = [
      makeAddr('eoa'),
      address(_aclManager),
      address(new MalformedAdapter()),
      address(_ratioProvider)
    ];
    for (uint256 i = 0; i < markets.length; i++) {
      assertFalse(_agent.validate(_agentId, _agentContext, _update(markets[i], value)));
    }
  }

  function test_inject_revertsOnInvalidUpdate() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(1.2e18, block.timestamp + 1 days);

    vm.prank(address(_agentHub));
    vm.expectRevert(BoundsAgent.InvalidUpdate.selector);
    _agent.inject(_agentId, _agentContext, update);
  }

  function test_execute_invalidMarketDoesNotBlockBatch() public {
    MockRatioProvider brokenProvider = new MockRatioProvider(int256(RATIO));
    BoundedRatioAdapterMock brokenAdapter = _deployAdapter(brokenProvider);
    _agentHub.addAllowedMarket(_agentId, address(brokenAdapter));

    _update(address(brokenAdapter), abi.encode(1.1e18, block.timestamp + 1 days));
    _update(1.04e18, block.timestamp + 1 days);
    brokenProvider.setReverts(true);

    address[] memory markets = new address[](2);
    markets[0] = address(brokenAdapter);
    markets[1] = address(_adapter);
    IAgentHub.ActionData[] memory actions = new IAgentHub.ActionData[](1);
    actions[0] = IAgentHub.ActionData({agentId: _agentId, markets: markets});
    _agentHub.execute(actions);

    _assertLowerBound(1.04e18, block.timestamp + 1 days);
    (uint256 brokenLowerBound, ) = brokenAdapter.getLowerBound();
    assertEq(brokenLowerBound, 0);
  }

  function testFuzz_validateMatchesAdapter(
    uint256 lowerBound,
    uint256 expiration,
    int256 ratio
  ) public {
    lowerBound = bound(lowerBound, 0, 1.3e18);
    expiration = bound(expiration, block.timestamp - 1, block.timestamp + 4 days);
    ratio = bound(ratio, -1, 1.3e18);
    _ratioProvider.setAnswer(ratio);

    IRiskOracle.RiskParameterUpdate memory update = _update(lowerBound, expiration);
    bool valid = _agent.validate(_agentId, _agentContext, update);

    vm.prank(address(_agentHub));
    if (!valid) vm.expectRevert(BoundsAgent.InvalidUpdate.selector);
    _agent.inject(_agentId, _agentContext, update);
    if (valid) _assertLowerBound(lowerBound, expiration);
  }
}
