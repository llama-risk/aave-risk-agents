// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator, IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {AaveV4CapAgent} from '../../../src/contracts/agent/v4/AaveV4CapAgent.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {IHubConfigurator} from '../../../src/contracts/dependencies/v4/IHubConfigurator.sol';
import {AccessManagerMock, RevertingHubMock} from './mocks/AaveV4Mocks.sol';
import {CapHubMock, CapConfiguratorMock} from './mocks/AaveV4CapMocks.sol';

abstract contract AaveV4CapAgent_TestBase is BaseAgentTest {
  RangeValidationModule internal _rangeValidationModule;
  AccessManagerMock internal _accessManager;
  CapConfiguratorMock internal _configurator;
  CapHubMock internal _hub;
  AaveV4CapAgent internal _capAgent;

  address internal constant SPOKE = address(0x5B0CE);
  address internal constant OTHER_SPOKE = address(0x5B0CF);
  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  uint256 internal constant ASSET_ID = 3;
  uint40 internal constant CURRENT_CAP = 1_000_000;
  uint40 internal constant OTHER_CAP = 2_000_000;
  uint40 internal constant MAX_CAP = type(uint40).max;

  AaveV4CapAgent.CapKind internal _kind;
  address internal _market;

  constructor(AaveV4CapAgent.CapKind kind, string memory updateType) BaseAgentTest(updateType) {
    _kind = kind;
  }

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _accessManager = new AccessManagerMock();
    _configurator = new CapConfiguratorMock(address(_accessManager));
    _hub = new CapHubMock();
    _hub.setAuthority(address(_accessManager));

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listSpoke(ASSET_ID, SPOKE);
    _setCurrentCap(CURRENT_CAP);

    _capAgent = new AaveV4CapAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      _kind,
      '',
      address(_configurator)
    );
    _market = _capAgent.marketId(address(_hub), SPOKE, ASSET);
    _allow(_selector(), true, 0);
    _allowHub(true, 0);
    return address(_capAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.allowedMarkets = _addressToArray(_market);
    return config;
  }

  function _postSetup() internal override {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      _updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: 50_00,
        maxDecrease: 20_00,
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );
  }

  function test_constructor() public view {
    assertEq(_capAgent.getUpdateType(), _updateType);
    assertEq(uint8(_capAgent.KIND()), uint8(_kind));
    assertEq(_capAgent.CONFIGURATOR(), address(_configurator));
    assertEq(_capAgent.MAX_CAP(), MAX_CAP);
    assertEq(_capAgent.getMarkets(_agentId).length, 0);
  }

  function test_constructor_suffix() public {
    AaveV4CapAgent agent = new AaveV4CapAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      _kind,
      '_Base',
      address(_configurator)
    );
    assertEq(agent.getUpdateType(), string.concat(_updateType, '_Base'));
  }

  function test_validate_increaseAndDecrease() public view {
    assertTrue(_validate(1_500_000));
    assertTrue(_validate(800_000));
    assertTrue(_validate(CURRENT_CAP + 1));
  }

  function test_validate_outOfRange() public view {
    assertFalse(_validate(1_500_001));
    assertFalse(_validate(799_999));
  }

  function test_validate_noop() public view {
    assertFalse(_validate(CURRENT_CAP));
  }

  function test_validate_newCapZero() public view {
    assertFalse(_validate(0));
  }

  function test_validate_newCapAtOrAboveMax() public {
    _setCurrentCap(MAX_CAP - 1);
    _setWideRange();
    assertTrue(_validate(MAX_CAP - 2));
    assertFalse(_validate(MAX_CAP));
    assertFalse(_validate(uint256(MAX_CAP) + 1));
    assertFalse(_validate(type(uint256).max));
  }

  function test_validate_currentCapBlocked() public {
    _setCurrentCap(0);
    _setWideRange();
    assertFalse(_validate(1));
    assertFalse(_validate(CURRENT_CAP));
  }

  function test_validate_currentCapUncapped() public {
    _setCurrentCap(MAX_CAP);
    _setWideRange();
    assertFalse(_validate(MAX_CAP - 1));
    assertFalse(_validate(CURRENT_CAP));
  }

  function test_validate_readsOwnCapKind() public {
    _hub.setCaps(ASSET_ID, SPOKE, CURRENT_CAP, OTHER_CAP);
    if (_kind == AaveV4CapAgent.CapKind.ADD) {
      assertTrue(_validate(1_200_000));
      assertFalse(_validate(2_400_000));
    } else {
      assertFalse(_validate(1_200_000));
      assertTrue(_validate(2_400_000));
    }
  }

  function test_validate_otherCapKindBlocked() public {
    _setCaps(CURRENT_CAP, 0);
    assertTrue(_validate(1_200_000));
  }

  function test_validate_spokeNotListed() public view {
    address market = _capAgent.marketId(address(_hub), OTHER_SPOKE, ASSET);
    bytes memory data = abi.encode(address(_hub), OTHER_SPOKE, ASSET, abi.encode(1_200_000));
    assertFalse(_capAgent.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_assetNotListed() public view {
    address market = _capAgent.marketId(address(_hub), SPOKE, OTHER_ASSET);
    bytes memory data = abi.encode(address(_hub), SPOKE, OTHER_ASSET, abi.encode(1_200_000));
    assertFalse(_capAgent.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_hubLevelMarket() public {
    _hub.listSpoke(ASSET_ID, address(0));
    _hub.setCaps(ASSET_ID, address(0), CURRENT_CAP, CURRENT_CAP);
    address market = _capAgent.marketId(address(_hub), address(0), ASSET);
    bytes memory data = abi.encode(address(_hub), address(0), ASSET, abi.encode(1_200_000));
    assertFalse(_capAgent.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_marketMismatch() public view {
    address market = _capAgent.marketId(address(_hub), OTHER_SPOKE, ASSET);
    assertFalse(_capAgent.validate(_agentId, _agentContext, _update(market, _payload(1_200_000))));
  }

  function test_validate_badValue() public view {
    bytes[3] memory values = [
      bytes(''),
      abi.encodePacked(uint128(1_200_000)),
      abi.encode(uint256(1_200_000), uint256(0))
    ];
    for (uint256 i = 0; i < values.length; i++) {
      bytes memory data = abi.encode(address(_hub), SPOKE, ASSET, values[i]);
      assertFalse(_capAgent.validate(_agentId, _agentContext, _update(_market, data)));
    }
  }

  function test_validate_wrongUpdateType() public view {
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(1_200_000));
    update.updateType = _kind == AaveV4CapAgent.CapKind.ADD
      ? 'SpokeDrawCapUpdate'
      : 'SpokeAddCapUpdate';
    assertFalse(_capAgent.validate(_agentId, _agentContext, update));
  }

  function test_validate_cannotCallConfigurator() public {
    _allow(_selector(), false, 0);
    _allow(_otherSelector(), true, 0);
    assertFalse(_validate(1_200_000));

    _allow(_selector(), true, 1);
    assertFalse(_validate(1_200_000));
  }

  function test_validate_configuratorCannotWriteHub() public {
    _allowHub(false, 0);
    assertFalse(_validate(1_200_000));

    _allowHub(true, 1);
    assertFalse(_validate(1_200_000));

    _allowHub(true, 0);
    assertTrue(_validate(1_200_000));
  }

  function test_validate_hubAuthorityMissing() public {
    _hub.setAuthority(address(0));
    assertFalse(_validate(1_200_000));

    _hub.setAuthority(address(new RevertingHubMock()));
    assertFalse(_validate(1_200_000));

    _hub.setAuthority(address(_accessManager));
    assertTrue(_validate(1_200_000));
  }

  function test_inject_revertsWhenHubClosed() public {
    _allowHub(false, 0);
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(1_200_000));
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _capAgent.inject(_agentId, _agentContext, update);
  }

  function test_checkAndExecute_closedHubDoesNotBlockBatch() public {
    CapHubMock closedHub = new CapHubMock();
    closedHub.setAuthority(address(_accessManager));
    closedHub.listAsset(ASSET, ASSET_ID);
    closedHub.listSpoke(ASSET_ID, SPOKE);
    closedHub.setCaps(ASSET_ID, SPOKE, CURRENT_CAP, CURRENT_CAP);
    address closed = _capAgent.marketId(address(closedHub), SPOKE, ASSET);
    _agentHub.addAllowedMarket(_agentId, closed);
    _publish(closed, abi.encode(address(closedHub), SPOKE, ASSET, abi.encode(1_200_000)));
    _publish(_market, _payload(1_200_000));

    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = _agentId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _market);

    address[] memory markets = new address[](2);
    markets[0] = closed;
    markets[1] = _market;
    actions[0].markets = markets;
    _agentHub.execute(actions);
    _assertWrite(1_200_000);
  }

  function test_validate_spokeConfigReverts() public {
    _hub.setRevertConfig(true);
    assertFalse(_validate(1_200_000));
  }

  function test_validate_spokeConfigBadReturn() public {
    bytes[4] memory raws = [
      abi.encode(uint256(CURRENT_CAP), uint256(CURRENT_CAP)),
      abi.encode(CURRENT_CAP, CURRENT_CAP, 0, true, false, 0),
      abi.encode(uint256(MAX_CAP) + 1, uint256(MAX_CAP) + 1, 0, true, false),
      abi.encode(uint256(1) << 255, uint256(1) << 255, 0, true, false)
    ];
    for (uint256 i = 0; i < raws.length; i++) {
      _hub.setRawConfig(raws[i]);
      assertFalse(_validate(1_200_000));
    }
    _hub.setRawConfig(abi.encode(CURRENT_CAP, CURRENT_CAP, 0, true, false));
    assertTrue(_validate(1_200_000));
  }

  function test_validate_revertingHub() public {
    address hub = address(new RevertingHubMock());
    address market = _capAgent.marketId(hub, SPOKE, ASSET);
    bytes memory data = abi.encode(hub, SPOKE, ASSET, abi.encode(1_200_000));
    assertFalse(_capAgent.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_fuzz(uint40 currentCap, uint256 newCap) public {
    _setCurrentCap(currentCap);
    bool expected = currentCap != 0 &&
      currentCap != MAX_CAP &&
      newCap != 0 &&
      newCap < MAX_CAP &&
      newCap != currentCap &&
      (
        newCap > currentCap
          ? newCap - currentCap <= (uint256(currentCap) * 50_00) / 100_00
          : currentCap - newCap <= (uint256(currentCap) * 20_00) / 100_00
      );
    assertEq(_validate(newCap), expected);
  }

  function test_inject() public {
    vm.prank(address(_agentHub));
    _capAgent.inject(_agentId, _agentContext, _update(_market, _payload(1_200_000)));
    _assertWrite(1_200_000);
  }

  function test_inject_revertsWhenInvalid() public {
    uint256[4] memory caps = [uint256(0), CURRENT_CAP, 1_500_001, MAX_CAP];
    for (uint256 i = 0; i < caps.length; i++) {
      IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(caps[i]));
      vm.prank(address(_agentHub));
      vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
      _capAgent.inject(_agentId, _agentContext, update);
    }
  }

  function test_inject_revertsWhenBlocked() public {
    _setCurrentCap(0);
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(1_200_000));
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _capAgent.inject(_agentId, _agentContext, update);
  }

  function test_checkAndExecute() public {
    _publish(_market, _payload(1_200_000));
    assertTrue(_checkAndPerformAutomation(_agentId));
    _assertWrite(1_200_000);
  }

  function test_checkAndExecute_badMarketDoesNotBlockBatch() public {
    address unlisted = _capAgent.marketId(address(_hub), OTHER_SPOKE, ASSET);
    _agentHub.addAllowedMarket(_agentId, unlisted);
    _publish(unlisted, abi.encode(address(_hub), OTHER_SPOKE, ASSET, abi.encode(1_200_000)));
    _publish(_market, _payload(1_200_000));

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
    _assertWrite(1_200_000);
  }

  function test_check_skipsBlockedAndUncapped() public {
    _hub.listSpoke(ASSET_ID, OTHER_SPOKE);
    _hub.setCaps(ASSET_ID, OTHER_SPOKE, MAX_CAP, MAX_CAP);
    address uncapped = _capAgent.marketId(address(_hub), OTHER_SPOKE, ASSET);
    _agentHub.addAllowedMarket(_agentId, uncapped);
    _publish(uncapped, abi.encode(address(_hub), OTHER_SPOKE, ASSET, abi.encode(1_200_000)));
    _setCurrentCap(0);
    _publish(_market, _payload(1_200_000));

    assertFalse(_checkAndPerformAutomation(_agentId));
  }

  function _validate(uint256 newCap) internal view returns (bool) {
    return _capAgent.validate(_agentId, _agentContext, _update(_market, _payload(newCap)));
  }

  function _assertWrite(uint256 newCap) internal view {
    assertEq(_configurator.lastHub(), address(_hub));
    assertEq(_configurator.lastAssetId(), ASSET_ID);
    assertEq(_configurator.lastSpoke(), SPOKE);
    assertEq(_configurator.lastCap(), newCap);
    bool add = _kind == AaveV4CapAgent.CapKind.ADD;
    assertEq(_configurator.addCapCalls(), add ? 1 : 0);
    assertEq(_configurator.drawCapCalls(), add ? 0 : 1);
  }

  function _setCurrentCap(uint40 cap) internal {
    _setCaps(cap, cap);
  }

  function _setCaps(uint40 own, uint40 other) internal {
    if (_kind == AaveV4CapAgent.CapKind.ADD) {
      _hub.setCaps(ASSET_ID, SPOKE, own, other);
    } else {
      _hub.setCaps(ASSET_ID, SPOKE, other, own);
    }
  }

  function _setWideRange() internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      _updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: type(uint120).max,
        maxDecrease: type(uint120).max,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function _selector() internal view returns (bytes4) {
    return
      _kind == AaveV4CapAgent.CapKind.ADD
        ? IHubConfigurator.updateSpokeAddCap.selector
        : IHubConfigurator.updateSpokeDrawCap.selector;
  }

  function _otherSelector() internal view returns (bytes4) {
    return
      _kind == AaveV4CapAgent.CapKind.ADD
        ? IHubConfigurator.updateSpokeDrawCap.selector
        : IHubConfigurator.updateSpokeAddCap.selector;
  }

  function _allow(bytes4 selector, bool allowed, uint32 delay) internal {
    _accessManager.setCanCall(address(_capAgent), address(_configurator), selector, allowed, delay);
  }

  function _allowHub(bool allowed, uint32 delay) internal {
    _accessManager.setCanCall(
      address(_configurator),
      address(_hub),
      IHub.updateSpokeConfig.selector,
      allowed,
      delay
    );
  }

  function _payload(uint256 value) internal view returns (bytes memory) {
    return abi.encode(address(_hub), SPOKE, ASSET, abi.encode(value));
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

contract AaveV4CapAgent_AddCapTest is
  AaveV4CapAgent_TestBase(AaveV4CapAgent.CapKind.ADD, 'SpokeAddCapUpdate')
{}

contract AaveV4CapAgent_DrawCapTest is
  AaveV4CapAgent_TestBase(AaveV4CapAgent.CapKind.DRAW, 'SpokeDrawCapUpdate')
{}
