// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {PendlePriceCapAdapter, IPendlePriceCapAdapter} from 'aave-price-feeds/contracts/PendlePriceCapAdapter.sol';
import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {AaveV4DiscountRateAgent} from '../../../src/contracts/agent/v4/AaveV4DiscountRateAgent.sol';
import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {HubMock} from './mocks/AaveV4Mocks.sol';
import {OracleSpokeMock, AaveOracleMock, ACLManagerMock, FeedMock, PrincipalTokenMock, V3OracleMock} from './mocks/AaveV4AdapterMocks.sol';

contract AaveV4DiscountRateAgent_Test is BaseAgentTest('PendleDiscountRateUpdate') {
  uint256 internal constant START = 1750000000;
  address internal constant ASSET = address(0xA55E7);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant RESERVE_ID = 5;
  uint64 internal constant DISCOUNT_RATE = 0.2e18;
  uint64 internal constant MAX_DISCOUNT_RATE = 5e18;
  uint256 internal constant MAX_CHANGE = 0.01e18;

  RangeValidationModule internal _rangeValidationModule;
  ACLManagerMock internal _aclManager;
  HubMock internal _hub;
  OracleSpokeMock internal _spoke;
  AaveOracleMock internal _oracle;
  PendlePriceCapAdapter internal _pendle;
  AaveV4DiscountRateAgent internal _discountAgent;
  address internal _market;

  function setUp() public override {
    vm.warp(START);
    super.setUp();
    vm.warp(START);
  }

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _aclManager = new ACLManagerMock();
    _hub = new HubMock();
    _spoke = new OracleSpokeMock();
    _oracle = new AaveOracleMock();

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listSpoke(ASSET_ID, address(_spoke));
    _spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    _spoke.setOracle(address(_oracle));

    _pendle = _deployPendle(address(_aclManager));
    _oracle.setReserveSource(RESERVE_ID, address(_pendle));

    _discountAgent = new AaveV4DiscountRateAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_aclManager),
      _addressToArray(address(_hub)),
      _addressToArray(address(new V3OracleMock()))
    );
    _aclManager.setRiskAdmin(address(_discountAgent), true);
    _market = _discountAgent.marketId(address(_hub), address(_spoke), ASSET);
    return address(_discountAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.allowedMarkets = _addressToArray(_market);
    return config;
  }

  function _postSetup() internal override {
    _setRange(MAX_CHANGE);
  }

  function test_getters() public view {
    assertEq(_discountAgent.getUpdateType(), 'PendleDiscountRateUpdate');
    assertEq(_discountAgent.CONFIGURATOR(), address(_aclManager));
    assertEq(_discountAgent.getMarkets(_agentId).length, 0);
  }

  function test_constructor_revertsOnZeroAclManager() public {
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4DiscountRateAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(0),
      _addressToArray(address(_hub)),
      new address[](0)
    );
  }

  function test_constructor_revertsOnEmptyV3Oracles() public {
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4DiscountRateAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_aclManager),
      _addressToArray(address(_hub)),
      new address[](0)
    );
  }

  function test_checkAndExecute() public {
    _publish(_market, _payload(DISCOUNT_RATE + MAX_CHANGE));

    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_pendle.discountRatePerYear(), DISCOUNT_RATE + MAX_CHANGE);
  }

  function test_validate_range(uint64 change) public view {
    change = uint64(bound(change, 1, DISCOUNT_RATE - 1));
    bool inRange = change <= MAX_CHANGE;
    assertEq(_validate(DISCOUNT_RATE + change), inRange);
    assertEq(_validate(DISCOUNT_RATE - change), inRange);
  }

  function test_validate_zeroOrUnchanged() public {
    _setRange(DISCOUNT_RATE);
    assertFalse(_validate(0));
    assertFalse(_validate(DISCOUNT_RATE));
  }

  function test_validate_aboveMax() public {
    _setRange(type(uint64).max);
    assertTrue(_validate(MAX_DISCOUNT_RATE / 10));
    assertFalse(_validate(uint256(MAX_DISCOUNT_RATE) + 1));
    assertFalse(_validate(uint256(type(uint64).max) + 1));
  }

  function test_validate_discountReaches100Percent() public {
    _setRange(type(uint64).max);
    uint256 timeToMaturity = _pendle.MATURITY() - block.timestamp;
    uint256 limit = (_pendle.PERCENTAGE_FACTOR() * _pendle.SECONDS_PER_YEAR()) / timeToMaturity;
    assertLt(limit, MAX_DISCOUNT_RATE);
    assertTrue(_validate(limit - 1));
    assertFalse(_validate(limit + 1));
  }

  function test_validate_afterMaturity() public {
    vm.warp(_pendle.MATURITY());
    assertTrue(_validate(DISCOUNT_RATE + 1));
    vm.warp(_pendle.MATURITY() + 1);
    assertFalse(_validate(DISCOUNT_RATE + 1));
  }

  function test_validate_badValue() public view {
    assertFalse(_discountAgent.validate(_agentId, '', _update(_market, _wrap(hex'01'))));
    assertFalse(
      _discountAgent.validate(
        _agentId,
        '',
        _update(_market, _wrap(abi.encode(DISCOUNT_RATE + 1, uint256(0))))
      )
    );
  }

  function test_validate_accessFromAclManager() public {
    _aclManager.setRiskAdmin(address(_discountAgent), false);
    assertFalse(_validate(DISCOUNT_RATE + 1));

    _aclManager.setPoolAdmin(address(_discountAgent), true);
    assertFalse(_validate(DISCOUNT_RATE + 1));
  }

  function test_execute_adapterCooldownAndRangeKey() public {
    _rangeValidationModule.setRangeConfigByMarket(
      address(_agentHub),
      _agentId,
      address(_pendle),
      _updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: uint120(MAX_CHANGE * 2),
        maxDecrease: uint120(MAX_CHANGE * 2),
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
    _publish(_market, _payload(DISCOUNT_RATE + MAX_CHANGE * 2));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_pendle.discountRatePerYear(), DISCOUNT_RATE + MAX_CHANGE * 2);
    assertEq(_discountAgent.getLastAdapterUpdate(address(_pendle)), block.timestamp);

    vm.warp(block.timestamp + 1 days - 1);
    assertFalse(_validate(DISCOUNT_RATE));
    vm.warp(block.timestamp + 1);
    assertTrue(_validate(DISCOUNT_RATE));
  }

  function test_validate_badSource() public {
    _oracle.setReserveSource(RESERVE_ID, address(_deployPendle(address(new ACLManagerMock()))));
    assertFalse(_validate(DISCOUNT_RATE + 1));

    _oracle.setReserveSource(RESERVE_ID, address(new FeedMock(1e8, 8)));
    assertFalse(_validate(DISCOUNT_RATE + 1));

    _oracle.setReserveSource(RESERVE_ID, address(0));
    assertFalse(_validate(DISCOUNT_RATE + 1));

    _oracle.setReserveSource(RESERVE_ID, address(_pendle));
    vm.mockCall(
      address(_pendle),
      abi.encodeCall(IPendlePriceCapAdapter.MATURITY, ()),
      abi.encode(uint256(type(uint64).max) + 1)
    );
    assertFalse(_validate(DISCOUNT_RATE + 1));

    vm.mockCall(
      address(_pendle),
      abi.encodeCall(IPendlePriceCapAdapter.SECONDS_PER_YEAR, ()),
      abi.encode(uint256(0))
    );
    assertFalse(_validate(DISCOUNT_RATE + 1));
  }

  function test_inject_revertsWhenInvalid() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(DISCOUNT_RATE));
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _discountAgent.inject(_agentId, '', update);
  }

  function test_fuzz_validateMatchesAdapter(uint64 discountRate, uint32 elapsed) public {
    vm.warp(block.timestamp + bound(elapsed, 0, 130 days));
    _setRange(type(uint64).max);
    discountRate = uint64(bound(discountRate, 0, uint256(MAX_DISCOUNT_RATE) * 2));

    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(discountRate));
    bool valid = _discountAgent.validate(_agentId, '', update);

    uint256 state = vm.snapshotState();
    vm.prank(address(_discountAgent));
    (bool accepted, ) = address(_pendle).call(
      abi.encodeCall(IPendlePriceCapAdapter.setDiscountRatePerYear, (discountRate))
    );
    vm.revertToState(state);
    assertEq(valid, accepted && discountRate != DISCOUNT_RATE);
    if (!valid) return;

    vm.prank(address(_agentHub));
    _discountAgent.inject(_agentId, '', update);
    assertEq(_pendle.discountRatePerYear(), discountRate);
  }

  function _deployPendle(address aclManager) internal returns (PendlePriceCapAdapter) {
    return
      new PendlePriceCapAdapter(
        IPendlePriceCapAdapter.PendlePriceCapAdapterParams({
          assetToUsdAggregator: address(new FeedMock(1e8, 8)),
          pendlePrincipalToken: address(new PrincipalTokenMock(block.timestamp + 120 days)),
          maxDiscountRatePerYear: MAX_DISCOUNT_RATE,
          discountRatePerYear: DISCOUNT_RATE,
          aclManager: aclManager,
          description: 'PT Adapter'
        })
      );
  }

  function _setRange(uint256 maxChange) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      _updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: uint120(maxChange),
        maxDecrease: uint120(maxChange),
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function _validate(uint256 discountRate) internal view returns (bool) {
    return _discountAgent.validate(_agentId, '', _update(_market, _payload(discountRate)));
  }

  function _wrap(bytes memory value) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(_spoke), ASSET, value);
  }

  function _payload(uint256 discountRate) internal view returns (bytes memory) {
    return _wrap(abi.encode(discountRate));
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
