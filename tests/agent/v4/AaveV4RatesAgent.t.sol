// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator, IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {AaveV4RatesAgent} from '../../../src/contracts/agent/v4/AaveV4RatesAgent.sol';
import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {IHubConfigurator} from '../../../src/contracts/dependencies/v4/IHubConfigurator.sol';
import {AccessManagerMock, HubConfiguratorMock, RevertingHubMock, ShortReturnHubMock} from './mocks/AaveV4Mocks.sol';
import {RatesHubMock, DirtyAssetConfigHubMock, InterestRateStrategyMock, NoBoundsStrategyMock} from './mocks/AaveV4RatesMocks.sol';

contract AaveV4RatesAgent_Test is BaseAgentTest('RateStrategyUpdate') {
  RangeValidationModule internal _rangeValidationModule;
  AccessManagerMock internal _accessManager;
  HubConfiguratorMock internal _configurator;
  RatesHubMock internal _hub;
  InterestRateStrategyMock internal _strategy;
  AaveV4RatesAgent internal _ratesAgent;

  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  address internal constant SPOKE = address(0x5B0CE);
  uint256 internal constant ASSET_ID = 3;
  bytes4 internal constant SELECTOR = IHubConfigurator.updateInterestRateData.selector;

  address internal _market;

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _accessManager = new AccessManagerMock();
    _configurator = new HubConfiguratorMock(address(_accessManager));
    _hub = new RatesHubMock();
    _strategy = new InterestRateStrategyMock();

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.setIrStrategy(ASSET_ID, address(_strategy));
    _strategy.setInterestRateData(ASSET_ID, [uint256(80_00), 0, 4_00, 60_00]);

    _ratesAgent = new AaveV4RatesAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_configurator)
    );
    _market = _ratesAgent.marketId(address(_hub), address(0), ASSET);
    _accessManager.setCanCall(address(_ratesAgent), address(_configurator), SELECTOR, true, 0);
    return address(_ratesAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.allowedMarkets = _addressToArray(_market);
    return config;
  }

  function _postSetup() internal override {
    _setRange('OptimalUsageRatio', 3_00);
    _setRange('BaseVariableBorrowRate', 50);
    _setRange('VariableRateSlope1', 1_00);
    _setRange('VariableRateSlope2', 20_00);
  }

  function test_getters() public {
    assertEq(_ratesAgent.getUpdateType(), 'RateStrategyUpdate');
    assertEq(_ratesAgent.CONFIGURATOR(), address(_configurator));
    assertEq(address(_ratesAgent.RANGE_VALIDATION_MODULE()), address(_rangeValidationModule));
    assertEq(_ratesAgent.getMarkets(_agentId).length, 0);

    AaveV4RatesAgent suffixed = new AaveV4RatesAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '_Core',
      address(_configurator)
    );
    assertEq(suffixed.getUpdateType(), 'RateStrategyUpdate_Core');
  }

  function test_constructor_revertsOnZeroAddress() public {
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4RatesAgent(address(_agentHub), address(_rangeValidationModule), '', address(0));
  }

  function test_validate_valid() public view {
    assertTrue(_validate(_rates(83_00, 50, 5_00, 80_00)));
    assertTrue(_validate(_rates(77_00, 0, 3_00, 40_00)));
  }

  function test_validate_noop() public view {
    assertFalse(_validate(_rates(80_00, 0, 4_00, 60_00)));
  }

  function test_validate_outOfRange() public view {
    assertFalse(_validate(_rates(83_01, 0, 4_00, 60_00)));
    assertFalse(_validate(_rates(80_00, 51, 4_00, 60_00)));
    assertFalse(_validate(_rates(80_00, 0, 2_99, 60_00)));
    assertFalse(_validate(_rates(80_00, 0, 4_00, 80_01)));
  }

  function test_validate_strategyBounds() public {
    _setRange('OptimalUsageRatio', 100_00);
    _setRange('BaseVariableBorrowRate', 1000_00);
    _setRange('VariableRateSlope1', 1000_00);
    _setRange('VariableRateSlope2', 1000_00);

    assertTrue(_validate(_rates(99_00, 0, 4_00, 60_00)));
    assertTrue(_validate(_rates(1_00, 0, 4_00, 60_00)));
    assertTrue(_validate(_rates(80_00, 100_00, 300_00, 600_00)));
    assertFalse(_validate(_rates(99_01, 0, 4_00, 60_00)));
    assertFalse(_validate(_rates(99, 0, 4_00, 60_00)));
    assertFalse(_validate(_rates(0, 0, 4_00, 60_00)));
    assertFalse(_validate(_rates(80_00, 100_01, 300_00, 600_00)));

    _strategy.setBounds(0, 99_00, 1000_00);
    assertFalse(_validate(_rates(0, 0, 4_00, 60_00)));
  }

  function test_validate_typeBounds() public {
    _strategy.setBounds(0, type(uint256).max, type(uint256).max);
    _setRange('OptimalUsageRatio', type(uint120).max);
    _setRange('BaseVariableBorrowRate', type(uint120).max);
    _setRange('VariableRateSlope1', type(uint120).max);
    _setRange('VariableRateSlope2', type(uint120).max);

    assertTrue(_validate(_rates(type(uint16).max, 0, 4_00, 60_00)));
    assertFalse(_validate(_rates(uint256(type(uint16).max) + 1, 0, 4_00, 60_00)));
    assertFalse(_validate(_rates(80_00, uint256(type(uint32).max) + 1, 0, 0)));
    assertFalse(_validate(_rates(80_00, 0, uint256(type(uint32).max) + 1, 0)));
    assertFalse(_validate(_rates(80_00, 0, 0, uint256(type(uint32).max) + 1)));
    assertTrue(_validate(_rates(80_00, type(uint32).max, 0, 0)));
    assertFalse(_validate(_rates(80_00, type(uint32).max, 1, 0)));
    assertFalse(_validate(_rates(80_00, type(uint256).max, type(uint256).max, 1)));
  }

  function test_validate_badPayloadLength() public view {
    assertFalse(_validate(abi.encode(uint256(83_00), uint256(0), uint256(4_00))));
    assertFalse(
      _validate(abi.encode(uint256(83_00), uint256(0), uint256(4_00), uint256(60_00), 1))
    );
    assertFalse(_validate(''));
  }

  function test_validate_spokeLevelMarket() public view {
    address market = _ratesAgent.marketId(address(_hub), SPOKE, ASSET);
    bytes memory data = abi.encode(address(_hub), SPOKE, ASSET, _rates(83_00, 0, 4_00, 60_00));
    assertFalse(_ratesAgent.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_marketMismatch() public view {
    bytes memory data = abi.encode(
      address(_hub),
      address(0),
      OTHER_ASSET,
      _rates(83_00, 0, 4_00, 60_00)
    );
    assertFalse(_ratesAgent.validate(_agentId, _agentContext, _update(_market, data)));
  }

  function test_validate_unlistedAsset() public view {
    address market = _ratesAgent.marketId(address(_hub), address(0), OTHER_ASSET);
    bytes memory data = abi.encode(
      address(_hub),
      address(0),
      OTHER_ASSET,
      _rates(83_00, 0, 4_00, 60_00)
    );
    assertFalse(_ratesAgent.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_wrongUpdateType() public view {
    IRiskOracle.RiskParameterUpdate memory update = _update(
      _market,
      _payload(_rates(83_00, 0, 4_00, 60_00))
    );
    update.updateType = 'RateStrategyUpdate_Core';
    assertFalse(_ratesAgent.validate(_agentId, _agentContext, update));
  }

  function test_validate_badStrategy() public {
    bytes memory rates = _rates(83_00, 0, 4_00, 60_00);
    address[5] memory strategies = [
      address(0),
      address(0xC0DE),
      address(new RevertingHubMock()),
      address(new ShortReturnHubMock()),
      address(new NoBoundsStrategyMock())
    ];
    for (uint256 i = 0; i < strategies.length; i++) {
      _hub.setIrStrategy(ASSET_ID, strategies[i]);
      assertFalse(_validate(rates));
    }
  }

  function test_validate_badHub() public {
    address[3] memory hubs = [
      address(new RevertingHubMock()),
      address(new ShortReturnHubMock()),
      address(new DirtyAssetConfigHubMock())
    ];
    DirtyAssetConfigHubMock(hubs[2]).listAsset(ASSET, ASSET_ID);
    for (uint256 i = 0; i < hubs.length; i++) {
      address market = _ratesAgent.marketId(hubs[i], address(0), ASSET);
      bytes memory data = abi.encode(hubs[i], address(0), ASSET, _rates(83_00, 0, 4_00, 60_00));
      assertFalse(_ratesAgent.validate(_agentId, _agentContext, _update(market, data)));
    }
  }

  function test_validate_cannotCallConfigurator() public {
    bytes memory rates = _rates(83_00, 0, 4_00, 60_00);
    _accessManager.setCanCall(address(_ratesAgent), address(_configurator), SELECTOR, true, 1);
    assertFalse(_validate(rates));
    _accessManager.setCanCall(address(_ratesAgent), address(_configurator), SELECTOR, false, 0);
    assertFalse(_validate(rates));
  }

  function test_validate_neverReverts(uint256 a, uint256 b, uint256 c, uint256 d) public view {
    _ratesAgent.validate(_agentId, _agentContext, _update(_market, _payload(_rates(a, b, c, d))));
  }

  function test_inject() public {
    bytes memory rates = _rates(83_00, 50, 5_00, 80_00);
    vm.prank(address(_agentHub));
    _ratesAgent.inject(_agentId, _agentContext, _update(_market, _payload(rates)));
    assertEq(_configurator.calls(), 1);
    assertEq(_configurator.lastHub(), address(_hub));
    assertEq(_configurator.lastAssetId(), ASSET_ID);
    assertEq(_configurator.lastIrData(), rates);
  }

  function test_inject_revertsWhenInvalid() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(
      _market,
      _payload(_rates(99_01, 0, 4_00, 60_00))
    );
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _ratesAgent.inject(_agentId, _agentContext, update);
  }

  function test_checkAndExecute() public {
    bytes memory rates = _rates(83_00, 50, 5_00, 80_00);
    _publish(_market, _payload(rates));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_configurator.calls(), 1);
    assertEq(_configurator.lastIrData(), rates);
  }

  function test_checkAndExecute_skipsBadMarkets() public {
    address unlisted = _ratesAgent.marketId(address(_hub), address(0), OTHER_ASSET);
    _agentHub.addAllowedMarket(_agentId, unlisted);
    _publish(
      unlisted,
      abi.encode(address(_hub), address(0), OTHER_ASSET, _rates(83_00, 0, 4_00, 60_00))
    );
    _publish(_market, _payload(_rates(83_00, 0, 4_00, 60_00)));

    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = _agentId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _market);

    address[] memory markets = new address[](2);
    markets[0] = unlisted;
    markets[1] = _market;
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertEq(_configurator.calls(), 1);
  }

  function _setRange(string memory label, uint120 maxChange) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      label,
      IRangeValidationModule.RangeConfig({
        maxIncrease: maxChange,
        maxDecrease: maxChange,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function _rates(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bytes memory) {
    return abi.encode(a, b, c, d);
  }

  function _payload(bytes memory rates) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(0), ASSET, rates);
  }

  function _validate(bytes memory rates) internal view returns (bool) {
    return _ratesAgent.validate(_agentId, _agentContext, _update(_market, _payload(rates)));
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
