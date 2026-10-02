// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {CLRatePriceCapAdapter, IPriceCapAdapter, IACLManager} from 'aave-price-feeds/contracts/CLRatePriceCapAdapter.sol';
import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {AaveV4CapoAgent} from '../../../src/contracts/agent/v4/AaveV4CapoAgent.sol';
import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {HubMock} from './mocks/AaveV4Mocks.sol';
import {OracleSpokeMock, AaveOracleMock, ACLManagerMock, FeedMock, V3OracleMock} from './mocks/AaveV4AdapterMocks.sol';

contract AaveV4CapoAgent_Test is BaseAgentTest('CapoPriceCapUpdate') {
  uint256 internal constant START = 1750000000;
  address internal constant ASSET = address(0xA55E7);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant RESERVE_ID = 5;
  uint104 internal constant SNAPSHOT_RATIO = 1.15e18;
  uint48 internal constant SNAPSHOT_TIMESTAMP = 1747408000;
  uint16 internal constant MAX_GROWTH = 9_68;

  RangeValidationModule internal _rangeValidationModule;
  ACLManagerMock internal _aclManager;
  HubMock internal _hub;
  OracleSpokeMock internal _spoke;
  AaveOracleMock internal _oracle;
  V3OracleMock internal _v3Oracle;
  CLRatePriceCapAdapter internal _capo;
  AaveV4CapoAgent internal _capoAgent;
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
    _v3Oracle = new V3OracleMock();

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listSpoke(ASSET_ID, address(_spoke));
    _spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    _spoke.setOracle(address(_oracle));

    _capo = _deployCapo(address(_aclManager));
    _oracle.setReserveSource(RESERVE_ID, address(_capo));

    _capoAgent = new AaveV4CapoAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_aclManager),
      _addressToArray(address(_hub)),
      _addressToArray(address(_v3Oracle))
    );
    _aclManager.setRiskAdmin(address(_capoAgent), true);
    _market = _capoAgent.marketId(address(_hub), address(_spoke), ASSET);
    return address(_capoAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.allowedMarkets = _addressToArray(_market);
    return config;
  }

  function _postSetup() internal override {
    _setRange('CapoSnapshotRatio', 5_00);
    _setRange('CapoMaxYearlyGrowthRatePercent', 10_00);
  }

  function test_getters() public view {
    assertEq(_capoAgent.getUpdateType(), 'CapoPriceCapUpdate');
    assertEq(_capoAgent.CONFIGURATOR(), address(_aclManager));
    assertEq(_capoAgent.getMarkets(_agentId).length, 0);
    assertEq(_capoAgent.getHubs(), _addressToArray(address(_hub)));
    assertEq(_capoAgent.getV3Oracles(), _addressToArray(address(_v3Oracle)));
    assertEq(_capoAgent.getLastAdapterUpdate(address(_capo)), 0);
  }

  function test_constructor_revertsOnZeroAddress() public {
    address[] memory hubs = _addressToArray(address(_hub));
    address[] memory none = new address[](0);
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4CapoAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(0),
      hubs,
      none
    );
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4CapoAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_aclManager),
      none,
      none
    );
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4CapoAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_aclManager),
      _addressToArray(address(0)),
      none
    );
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4CapoAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '',
      address(_aclManager),
      hubs,
      _addressToArray(address(0))
    );
  }

  function test_validate_valid() public view {
    assertTrue(_validate(_params(SNAPSHOT_RATIO + 1e16, _latestTimestamp(), MAX_GROWTH + 1)));
  }

  function test_checkAndExecute() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      SNAPSHOT_RATIO + 2e16,
      _latestTimestamp(),
      MAX_GROWTH - 50
    );
    _publish(_market, _payload(params));

    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_capo.getSnapshotRatio(), params.snapshotRatio);
    assertEq(_capo.getSnapshotTimestamp(), params.snapshotTimestamp);
    assertEq(_capo.getMaxYearlyGrowthRatePercent(), params.maxYearlyRatioGrowthPercent);
  }

  function test_validate_snapshotRatioRange(uint16 change) public view {
    change = uint16(bound(change, 0, 100_00));
    uint104 up = uint104((uint256(SNAPSHOT_RATIO) * (100_00 + change)) / 100_00);
    uint104 down = uint104((uint256(SNAPSHOT_RATIO) * (100_00 - change)) / 100_00);
    bool inRange = change <= 5_00;
    assertEq(_validate(_params(up, _latestTimestamp(), MAX_GROWTH)), inRange);
    if (down != 0) assertEq(_validate(_params(down, _latestTimestamp(), MAX_GROWTH)), inRange);
  }

  function test_validate_maxGrowthRange(uint16 change) public view {
    change = uint16(bound(change, 0, 100_00));
    vm.assume(change <= 9_00 || change >= 11_00);
    uint16 up = uint16((uint256(MAX_GROWTH) * (100_00 + change)) / 100_00);
    uint16 down = uint16((uint256(MAX_GROWTH) * (100_00 - change)) / 100_00);
    bool inRange = change <= 10_00;
    assertEq(_validate(_params(SNAPSHOT_RATIO, _latestTimestamp(), up)), inRange);
    assertEq(_validate(_params(SNAPSHOT_RATIO, _latestTimestamp(), down)), inRange);
  }

  function test_validate_snapshotTimestamp() public {
    uint48 latest = _latestTimestamp();
    assertTrue(_validate(_params(SNAPSHOT_RATIO, latest, MAX_GROWTH)));
    assertFalse(_validate(_params(SNAPSHOT_RATIO, latest + 1, MAX_GROWTH)));
    assertFalse(_validate(_params(SNAPSHOT_RATIO, uint48(block.timestamp), MAX_GROWTH)));
    assertFalse(_validate(_params(SNAPSHOT_RATIO, SNAPSHOT_TIMESTAMP, MAX_GROWTH)));
    assertFalse(_validate(_params(SNAPSHOT_RATIO, SNAPSHOT_TIMESTAMP - 1, MAX_GROWTH)));

    vm.warp(SNAPSHOT_TIMESTAMP + 200 days);
    uint48 oldest = uint48(block.timestamp - _capo.MAXIMUM_SNAPSHOT_TERM());
    assertGt(oldest, SNAPSHOT_TIMESTAMP);
    assertTrue(_validate(_params(SNAPSHOT_RATIO, oldest, MAX_GROWTH)));
    assertFalse(_validate(_params(SNAPSHOT_RATIO, oldest - 1, MAX_GROWTH)));
  }

  function test_validate_zeroSnapshotRatio() public {
    _setRange('CapoSnapshotRatio', 100_00);
    assertFalse(_validate(_params(0, _latestTimestamp(), MAX_GROWTH)));
  }

  function test_validate_adapterWithoutMaximumSnapshotTerm() public {
    vm.mockCallRevert(
      address(_capo),
      abi.encodeCall(IPriceCapAdapter.MAXIMUM_SNAPSHOT_TERM, ()),
      ''
    );
    assertTrue(_validate(_params(SNAPSHOT_RATIO, SNAPSHOT_TIMESTAMP + 1, MAX_GROWTH)));
  }

  function test_validate_badValue() public view {
    bytes memory valid = abi.encode(_params(SNAPSHOT_RATIO, _latestTimestamp(), MAX_GROWTH));
    assertTrue(_capoAgent.validate(_agentId, '', _update(_market, _wrap(valid))));

    assertFalse(
      _capoAgent.validate(_agentId, '', _update(_market, _wrap(bytes.concat(valid, bytes1(0)))))
    );
    assertFalse(_capoAgent.validate(_agentId, '', _update(_market, _wrap(abi.encode(uint256(1))))));
    assertFalse(
      _capoAgent.validate(
        _agentId,
        '',
        _update(
          _market,
          _wrap(abi.encode(uint256(type(uint104).max) + 1, _latestTimestamp(), MAX_GROWTH))
        )
      )
    );
    assertFalse(
      _capoAgent.validate(
        _agentId,
        '',
        _update(
          _market,
          _wrap(abi.encode(SNAPSHOT_RATIO, uint256(type(uint48).max) + 1, MAX_GROWTH))
        )
      )
    );
    assertFalse(
      _capoAgent.validate(
        _agentId,
        '',
        _update(
          _market,
          _wrap(abi.encode(SNAPSHOT_RATIO, _latestTimestamp(), uint256(type(uint16).max) + 1))
        )
      )
    );
  }

  function test_validate_accessFromAclManager() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      SNAPSHOT_RATIO,
      _latestTimestamp(),
      MAX_GROWTH
    );
    _aclManager.setRiskAdmin(address(_capoAgent), false);
    assertFalse(_validate(params));

    _aclManager.setPoolAdmin(address(_capoAgent), true);
    assertFalse(_validate(params));

    _aclManager.setRiskAdmin(address(_capoAgent), true);
    assertTrue(_validate(params));
  }

  function test_validate_untrustedHub() public {
    HubMock hub = new HubMock();
    hub.listAsset(ASSET, ASSET_ID);
    hub.listSpoke(ASSET_ID, address(_spoke));
    _spoke.addReserve(address(hub), ASSET_ID, RESERVE_ID);

    bytes memory payload = abi.encode(
      address(hub),
      address(_spoke),
      ASSET,
      abi.encode(_params(SNAPSHOT_RATIO, _latestTimestamp(), MAX_GROWTH))
    );
    assertFalse(
      _capoAgent.validate(
        _agentId,
        '',
        _update(_capoAgent.marketId(address(hub), address(_spoke), ASSET), payload)
      )
    );
  }

  function test_validate_v3Source() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      SNAPSHOT_RATIO,
      _latestTimestamp(),
      MAX_GROWTH
    );
    _v3Oracle.setSource(ASSET, address(0xdead));
    assertTrue(_validate(params));

    _v3Oracle.setSource(ASSET, address(_capo));
    assertFalse(_validate(params));

    _v3Oracle.setSource(ASSET, address(0));
    vm.mockCallRevert(
      address(_v3Oracle),
      abi.encodeWithSignature('getSourceOfAsset(address)', ASSET),
      ''
    );
    assertFalse(_validate(params));
  }

  function test_execute_sharedAdapterCooldown() public {
    OracleSpokeMock spoke = new OracleSpokeMock();
    spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    spoke.setOracle(address(_oracle));
    _hub.listSpoke(ASSET_ID, address(spoke));
    address market = _capoAgent.marketId(address(_hub), address(spoke), ASSET);
    _agentHub.addAllowedMarket(_agentId, market);

    _publish(_market, _payload(_params(SNAPSHOT_RATIO + 4e16, _latestTimestamp(), MAX_GROWTH)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_capoAgent.getLastAdapterUpdate(address(_capo)), block.timestamp);

    vm.warp(block.timestamp + 1);
    bytes memory payload = abi.encode(
      address(_hub),
      address(spoke),
      ASSET,
      abi.encode(_params(SNAPSHOT_RATIO + 8e16, _latestTimestamp(), MAX_GROWTH))
    );
    _publish(market, payload);
    assertFalse(_capoAgent.validate(_agentId, '', _update(market, payload)));
    (bool shouldRun, ) = _agentHub.check(_uintToArray(_agentId));
    assertFalse(shouldRun);

    vm.warp(block.timestamp + _agentHub.getMinimumDelay(_agentId) - 1);
    assertTrue(_capoAgent.validate(_agentId, '', _update(market, payload)));
  }

  function test_validate_rangeKeyedByAdapter() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      (SNAPSHOT_RATIO * 108) / 100,
      _latestTimestamp(),
      MAX_GROWTH
    );
    assertFalse(_validate(params));

    _setMarketRange(_market, 'CapoSnapshotRatio', 10_00);
    assertFalse(_validate(params));

    _setMarketRange(address(_capo), 'CapoSnapshotRatio', 10_00);
    assertTrue(_validate(params));
  }

  function test_validate_snapshotMayOverflowSoon() public {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      'CapoSnapshotRatio',
      IRangeValidationModule.RangeConfig({
        maxIncrease: type(uint120).max,
        maxDecrease: type(uint120).max,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
    uint256 limit = (uint256(type(uint104).max) * 100_00) / (100_00 + 3 * uint256(MAX_GROWTH));
    uint104 above = uint104(limit + 1e18);
    uint104 below = uint104(limit - 1e18);
    assertTrue(_validate(_params(above, _latestTimestamp(), MAX_GROWTH)));

    vm.mockCall(
      address(_capo),
      abi.encodeWithSignature('MINIMAL_RATIO_INCREASE_LIFETIME()'),
      abi.encode(3)
    );
    assertFalse(_validate(_params(above, _latestTimestamp(), MAX_GROWTH)));
    assertTrue(_validate(_params(below, _latestTimestamp(), MAX_GROWTH)));
  }

  function test_validate_adapterOnOtherAclManager() public {
    _oracle.setReserveSource(RESERVE_ID, address(_deployCapo(address(new ACLManagerMock()))));
    assertFalse(_validate(_params(SNAPSHOT_RATIO, _latestTimestamp(), MAX_GROWTH)));
  }

  function test_validate_badSource() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      SNAPSHOT_RATIO,
      _latestTimestamp(),
      MAX_GROWTH
    );
    _oracle.setReserveSource(RESERVE_ID, address(0));
    assertFalse(_validate(params));

    _oracle.setReserveSource(RESERVE_ID, address(0xdead));
    assertFalse(_validate(params));

    _oracle.setReserveSource(RESERVE_ID, address(new FeedMock(1e8, 8)));
    assertFalse(_validate(params));

    _oracle.setReserveSource(RESERVE_ID, address(_capo));
    vm.mockCallRevert(address(_capo), abi.encodeCall(IPriceCapAdapter.getSnapshotRatio, ()), '');
    assertFalse(_validate(params));
  }

  function test_validate_badSpokeOracle() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      SNAPSHOT_RATIO,
      _latestTimestamp(),
      MAX_GROWTH
    );
    _spoke.setOracle(address(0));
    assertFalse(_validate(params));

    _spoke.setOracle(address(0xdead));
    assertFalse(_validate(params));
  }

  function test_validate_unlistedMarket() public view {
    address other = address(0xB0B);
    bytes memory payload = abi.encode(
      address(_hub),
      address(_spoke),
      other,
      abi.encode(_params(SNAPSHOT_RATIO, _latestTimestamp(), MAX_GROWTH))
    );
    assertFalse(
      _capoAgent.validate(
        _agentId,
        '',
        _update(_capoAgent.marketId(address(_hub), address(_spoke), other), payload)
      )
    );
  }

  function test_inject_revertsWhenInvalid() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(
      _market,
      _payload(_params(SNAPSHOT_RATIO, SNAPSHOT_TIMESTAMP, MAX_GROWTH))
    );
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _capoAgent.inject(_agentId, '', update);
  }

  function test_fuzz_validateMatchesAdapter(
    uint104 snapshotRatio,
    uint48 snapshotTimestamp,
    uint16 maxGrowth,
    uint32 elapsed
  ) public {
    vm.warp(block.timestamp + bound(elapsed, 0, 365 days));
    _setRange('CapoSnapshotRatio', 100_00);
    _setRange('CapoMaxYearlyGrowthRatePercent', 100_00);
    snapshotRatio = uint104(bound(snapshotRatio, 0, uint256(SNAPSHOT_RATIO) * 2));
    snapshotTimestamp = uint48(
      bound(snapshotTimestamp, SNAPSHOT_TIMESTAMP - 1 days, block.timestamp + 1 days)
    );
    maxGrowth = uint16(bound(maxGrowth, 0, uint256(MAX_GROWTH) * 2));

    IPriceCapAdapter.PriceCapUpdateParams memory params = _params(
      snapshotRatio,
      snapshotTimestamp,
      maxGrowth
    );
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(params));
    bool valid = _capoAgent.validate(_agentId, '', update);

    uint256 state = vm.snapshotState();
    vm.prank(address(_capoAgent));
    (bool accepted, ) = address(_capo).call(
      abi.encodeCall(IPriceCapAdapter.setCapParameters, (params))
    );
    vm.revertToState(state);
    assertEq(valid, accepted);
    if (!valid) return;

    vm.prank(address(_agentHub));
    _capoAgent.inject(_agentId, '', update);
    assertEq(_capo.getSnapshotRatio(), snapshotRatio);
    assertEq(_capo.getSnapshotTimestamp(), snapshotTimestamp);
    assertEq(_capo.getMaxYearlyGrowthRatePercent(), maxGrowth);
  }

  function _deployCapo(address aclManager) internal returns (CLRatePriceCapAdapter) {
    return
      new CLRatePriceCapAdapter(
        IPriceCapAdapter.CapAdapterParams({
          aclManager: IACLManager(aclManager),
          baseAggregatorAddress: address(new FeedMock(2000e8, 8)),
          ratioProviderAddress: address(new FeedMock(1.16e18, 18)),
          pairDescription: 'wstETH / ETH / USD Capo',
          minimumSnapshotDelay: 7 days,
          priceCapParams: _params(SNAPSHOT_RATIO, SNAPSHOT_TIMESTAMP, MAX_GROWTH)
        })
      );
  }

  function _setRange(string memory updateType, uint256 maxChange) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: uint120(maxChange),
        maxDecrease: uint120(maxChange),
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );
  }

  function _setMarketRange(address market, string memory updateType, uint256 maxChange) internal {
    _rangeValidationModule.setRangeConfigByMarket(
      address(_agentHub),
      _agentId,
      market,
      updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: uint120(maxChange),
        maxDecrease: uint120(maxChange),
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );
  }

  function _uintToArray(uint256 input) internal pure returns (uint256[] memory output) {
    output = new uint256[](1);
    output[0] = input;
  }

  function _latestTimestamp() internal view returns (uint48) {
    return uint48(block.timestamp - _capo.MINIMUM_SNAPSHOT_DELAY());
  }

  function _params(
    uint104 snapshotRatio,
    uint48 snapshotTimestamp,
    uint16 maxGrowth
  ) internal pure returns (IPriceCapAdapter.PriceCapUpdateParams memory) {
    return
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: snapshotRatio,
        snapshotTimestamp: snapshotTimestamp,
        maxYearlyRatioGrowthPercent: maxGrowth
      });
  }

  function _validate(
    IPriceCapAdapter.PriceCapUpdateParams memory params
  ) internal view returns (bool) {
    return _capoAgent.validate(_agentId, '', _update(_market, _payload(params)));
  }

  function _wrap(bytes memory value) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(_spoke), ASSET, value);
  }

  function _payload(
    IPriceCapAdapter.PriceCapUpdateParams memory params
  ) internal view returns (bytes memory) {
    return _wrap(abi.encode(params));
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
