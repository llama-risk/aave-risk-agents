// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {AaveV4PauseAgent} from '../../../src/contracts/agent/v4/AaveV4PauseAgent.sol';
import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {HubMock, AccessManagerMock, RawReturnMock} from './mocks/AaveV4Mocks.sol';
import {PausableSpokeMock, PauseSpokeConfiguratorMock, B20OracleRegistryMock, BoundedPriceAdapterMock} from './mocks/AaveV4PauseMocks.sol';

contract AaveV4PauseAgent_Test is BaseAgentTest('ReservePause') {
  AccessManagerMock internal _accessManager;
  PauseSpokeConfiguratorMock internal _configurator;
  HubMock internal _hub;
  PausableSpokeMock internal _spoke;
  B20OracleRegistryMock internal _registry;
  AaveV4PauseAgent internal _pauseAgent;

  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant OTHER_ASSET_ID = 4;
  uint256 internal constant RESERVE_ID = 5;
  uint256 internal constant OTHER_RESERVE_ID = 6;
  bytes4 internal constant SELECTOR = ISpokeConfigurator.pauseReserve.selector;

  address internal _admin = makeAddr('agentAdmin');
  address internal _market;
  address internal _otherMarket;

  function _deployAgent() internal override returns (address) {
    _accessManager = new AccessManagerMock();
    _configurator = new PauseSpokeConfiguratorMock(address(_accessManager));
    _hub = new HubMock();
    _spoke = new PausableSpokeMock();
    _spoke.setAuthority(address(_accessManager));
    _accessManager.setCanCall(
      address(_configurator),
      address(_spoke),
      ISpoke.updateReserveConfig.selector,
      true,
      0
    );
    _registry = new B20OracleRegistryMock();

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listAsset(OTHER_ASSET, OTHER_ASSET_ID);
    _hub.listSpoke(ASSET_ID, address(_spoke));
    _hub.listSpoke(OTHER_ASSET_ID, address(_spoke));
    _spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    _spoke.addReserve(address(_hub), OTHER_ASSET_ID, OTHER_RESERVE_ID);
    _registry.setOraclePaused(ASSET, false);

    _pauseAgent = new AaveV4PauseAgent(
      address(_agentHub),
      address(new RangeValidationModule()),
      address(_configurator),
      address(_registry)
    );
    _market = _pauseAgent.marketId(address(_hub), address(_spoke), ASSET);
    _otherMarket = _pauseAgent.marketId(address(_hub), address(_spoke), OTHER_ASSET);
    _accessManager.setCanCall(address(_pauseAgent), address(_configurator), SELECTOR, true, 0);
    return address(_pauseAgent);
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    config.isMarketsFromAgentEnabled = false;
    config.admin = _admin;
    config.allowedMarkets = new address[](2);
    config.allowedMarkets[0] = _market;
    config.allowedMarkets[1] = _otherMarket;
    return config;
  }

  function _postSetup() internal override {
    _pauseAgent.setHubAgentId(_agentId);
  }

  function test_getters() public view {
    assertEq(_pauseAgent.getUpdateType(), 'ReservePause');
    assertEq(_pauseAgent.CONFIGURATOR(), address(_configurator));
    assertEq(address(_pauseAgent.ISSUER_REGISTRY()), address(_registry));
    assertEq(_pauseAgent.hubAgentId(), _agentId);
    assertTrue(_pauseAgent.isHubAgentIdSet());
    assertFalse(_pauseAgent.isIssuerPokeEnabled(_market));
  }

  function test_noUnpauseSelector() public view {
    bytes memory code = address(_pauseAgent).code;
    bytes4[2] memory forbidden = [
      ISpokeConfigurator.updatePaused.selector,
      ISpokeConfigurator.updateFrozen.selector
    ];
    bool hasPause;
    for (uint256 i = 0; i < code.length - 4; i++) {
      if (code[i] != 0x63) continue;
      bytes4 word = bytes4(bytes.concat(code[i + 1], code[i + 2], code[i + 3], code[i + 4]));
      assertTrue(word != forbidden[0] && word != forbidden[1]);
      if (word == SELECTOR) hasPause = true;
    }
    assertTrue(hasPause);
  }

  function test_validate() public view {
    assertTrue(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_validate_rejectsNonPauseValue(uint256 value) public view {
    vm.assume(value != 1);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(value))));
  }

  function test_validate_rejectsBadValueLength() public view {
    assertFalse(_validate(_market, _payload(ASSET, abi.encodePacked(uint8(1)))));
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1), uint256(1)))));
    assertFalse(_validate(_market, _payload(ASSET, '')));
  }

  function test_validate_rejectsPausedReserve() public {
    _spoke.setPaused(RESERVE_ID, true);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_validate_rejectsUnlistedAsset() public view {
    address asset = address(0xdead);
    address market = _pauseAgent.marketId(address(_hub), address(_spoke), asset);
    assertFalse(_validate(market, _payload(asset, abi.encode(uint256(1)))));
  }

  function test_validate_rejectsHubLevelMarket() public view {
    address market = _pauseAgent.marketId(address(_hub), address(0), ASSET);
    assertFalse(
      _validate(market, abi.encode(address(_hub), address(0), ASSET, abi.encode(uint256(1))))
    );
  }

  function test_validate_rejectsMarketMismatch() public view {
    assertFalse(_validate(_otherMarket, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_validate_rejectsWithoutRole() public {
    _accessManager.setCanCall(address(_pauseAgent), address(_configurator), SELECTOR, false, 0);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_validate_rejectsDelayedRole() public {
    _accessManager.setCanCall(address(_pauseAgent), address(_configurator), SELECTOR, true, 1);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_validate_rejectsWrongUpdateType() public view {
    IRiskOracle.RiskParameterUpdate memory update = _update(
      _market,
      _payload(ASSET, abi.encode(uint256(1)))
    );
    update.updateType = 'ReserveFreeze';
    assertFalse(_pauseAgent.validate(_agentId, _agentContext, update));
  }

  function test_checkAndExecute_pausesReserve() public {
    _publish(_market, _payload(ASSET, abi.encode(uint256(1))));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
    assertFalse(_spoke.getReserveConfig(OTHER_RESERVE_ID).paused);
    assertEq(_configurator.calls(), 1);

    vm.warp(block.timestamp + 2 days);
    _publish(_market, _payload(ASSET, abi.encode(uint256(1))));
    assertFalse(_checkAndPerformAutomation(_agentId));
    assertEq(_configurator.calls(), 1);
  }

  function test_check_skipsUnpauseRequest() public {
    _spoke.setPaused(RESERVE_ID, true);
    _publish(_market, _payload(ASSET, abi.encode(uint256(0))));
    assertFalse(_checkAndPerformAutomation(_agentId));
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_inject_revertsOnInvalidUpdate() public {
    _spoke.setPaused(RESERVE_ID, true);
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _pauseAgent.inject(
      _agentId,
      _agentContext,
      _update(_market, _payload(ASSET, abi.encode(uint256(1))))
    );
  }

  function test_validate_rejectsWhenSpokeRejectsConfigurator() public {
    bytes4 selector = ISpoke.updateReserveConfig.selector;
    _accessManager.setCanCall(address(_configurator), address(_spoke), selector, false, 0);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));

    _accessManager.setCanCall(address(_configurator), address(_spoke), selector, true, 1);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));

    _accessManager.setCanCall(address(_configurator), address(_spoke), selector, true, 0);
    _spoke.setAuthority(address(0));
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_check_skipsWhenSpokeRejectsConfigurator() public {
    _accessManager.setCanCall(
      address(_configurator),
      address(_spoke),
      ISpoke.updateReserveConfig.selector,
      false,
      0
    );
    _publish(_market, _payload(ASSET, abi.encode(uint256(1))));
    assertFalse(_checkAndPerformAutomation(_agentId));
  }

  function test_validate_rejectsUpdateNotNewerThanLastPause() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertEq(_pauseAgent.lastPausedAt(_market), block.timestamp);

    _spoke.setPaused(RESERVE_ID, false);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
    assertTrue(_validate(_otherMarket, _payload(OTHER_ASSET, abi.encode(uint256(1)))));

    vm.warp(block.timestamp + 1);
    assertTrue(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_execute_staleUpdateDoesNotRepauseAfterUnpause() public {
    _publish(_market, _payload(ASSET, abi.encode(uint256(1))));
    vm.warp(block.timestamp + 1 hours);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertFalse(_checkAndPerformAutomation(_agentId));

    _registry.setOraclePaused(ASSET, false);
    _spoke.setPaused(RESERVE_ID, false);
    vm.warp(block.timestamp + 12 hours);
    assertFalse(_checkAndPerformAutomation(_agentId));
    assertFalse(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_inject_recordsLastPausedAt() public {
    _publish(_market, _payload(ASSET, abi.encode(uint256(1))));
    vm.warp(block.timestamp + 1);
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_pauseAgent.lastPausedAt(_market), block.timestamp);
    assertEq(_pauseAgent.lastPausedAt(_otherMarket), 0);
  }

  function test_setHubAgentId_repointsToNewRegistration() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);

    IAgentConfigurator.AgentRegistrationInput memory registration = _registration(
      address(_pauseAgent)
    );
    registration.allowedMarkets = new address[](1);
    registration.allowedMarkets[0] = _market;
    uint256 newId = _agentHub.registerAgent(registration);
    vm.prank(_admin);
    _agentHub.setAgentEnabled(_agentId, false);

    vm.expectRevert(AaveV4PauseAgent.AgentDisabled.selector);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.HubAgentIdSet(newId);
    _pauseAgent.setHubAgentId(newId);
    assertEq(_pauseAgent.hubAgentId(), newId);

    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_setHubAgentId_onlyAgentHubOwner(address caller) public {
    vm.assume(caller != address(this));
    AaveV4PauseAgent agent = _newAgent(address(_registry));
    vm.prank(caller);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.OnlyAgentHubOwner.selector, caller));
    agent.setHubAgentId(_agentId);
  }

  function test_setHubAgentId_revertsForOtherAgent() public {
    AaveV4PauseAgent agent = _newAgent(address(_registry));
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.NotRegisteredAgent.selector, _agentId));
    agent.setHubAgentId(_agentId);
  }

  function test_setIssuerPokeEnabled_revertsBeforeHubAgentId() public {
    AaveV4PauseAgent agent = _newAgent(address(_registry));
    vm.expectRevert(AaveV4PauseAgent.HubAgentIdNotSet.selector);
    agent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
  }

  function test_setIssuerPokeEnabled_ownerAndAdmin() public {
    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.IssuerPokeEnabledSet(
      _market,
      address(_hub),
      address(_spoke),
      ASSET,
      true
    );
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    assertTrue(_pauseAgent.isIssuerPokeEnabled(_market));

    vm.prank(_admin);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, false);
    assertFalse(_pauseAgent.isIssuerPokeEnabled(_market));
  }

  function test_setIssuerPokeEnabled_followsAgentAdmin() public {
    address newAdmin = makeAddr('newAdmin');
    _agentHub.setAgentAdmin(_agentId, newAdmin);

    vm.prank(_admin);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.OnlyAgentHubOwnerOrAgentAdmin.selector, _admin)
    );
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);

    vm.prank(newAdmin);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    assertTrue(_pauseAgent.isIssuerPokeEnabled(_market));
  }

  function test_setIssuerPokeEnabled_onlyOwnerOrAdmin(address caller) public {
    vm.assume(caller != address(this) && caller != _admin);
    vm.prank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.OnlyAgentHubOwnerOrAgentAdmin.selector, caller)
    );
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
  }

  function test_setIssuerPokeEnabled_revertsOnZeroAddress() public {
    vm.expectRevert(AaveV4PauseAgent.InvalidMarket.selector);
    _pauseAgent.setIssuerPokeEnabled(address(0), address(_spoke), ASSET, true);
    vm.expectRevert(AaveV4PauseAgent.InvalidMarket.selector);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(0), ASSET, true);
    vm.expectRevert(AaveV4PauseAgent.InvalidMarket.selector);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), address(0), true);
  }

  function test_setIssuerPokeEnabled_withoutRegistry() public {
    AaveV4PauseAgent agent = _newAgent(address(0));
    uint256 agentId = _agentHub.registerAgent(_registration(address(agent)));
    agent.setHubAgentId(agentId);

    vm.expectRevert(AaveV4PauseAgent.IssuerRegistryNotSet.selector);
    agent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    agent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, false);
  }

  function test_poke(address caller) public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);

    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(_market, RESERVE_ID, caller, true, false);
    vm.prank(caller);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
    assertFalse(_spoke.getReserveConfig(OTHER_RESERVE_ID).paused);

    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.ReserveAlreadyPaused.selector, _market)
    );
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_revertsWhenDisabled() public {
    _registry.setOraclePaused(ASSET, true);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeDisabled.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeDisabled.selector, _otherMarket));
    _pauseAgent.poke(address(_hub), address(_spoke), OTHER_ASSET);
  }

  function test_poke_revertsWhenAgentDisabled() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);
    vm.prank(_admin);
    _agentHub.setAgentEnabled(_agentId, false);

    vm.expectRevert(AaveV4PauseAgent.AgentDisabled.selector);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_revertsWhenAgentReplaced() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);
    _agentHub.setAgentAddress(_agentId, address(_newAgent(address(_registry))));

    vm.expectRevert(AaveV4PauseAgent.AgentDisabled.selector);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_revertsWhenMarketNotAllowed() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);
    _agentHub.removeAllowedMarket(_agentId, _market);

    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.MarketNotAllowed.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    _agentHub.addAllowedMarket(_agentId, _market);
    _agentHub.addRestrictedMarket(_agentId, _market);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.MarketNotAllowed.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    _agentHub.removeRestrictedMarket(_agentId, _market);
    _agentHub.setMarketsFromAgentEnabled(_agentId, true);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.MarketNotAllowed.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    _agentHub.setMarketsFromAgentEnabled(_agentId, false);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_poke_revertsWhenIssuerNotPaused() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_revertsWhenRegistryReverts() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), OTHER_ASSET, true);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, _otherMarket)
    );
    _pauseAgent.poke(address(_hub), address(_spoke), OTHER_ASSET);
  }

  function test_poke_revertsForUnlistedReserve() public {
    address asset = address(0xdead);
    address market = _pauseAgent.marketId(address(_hub), address(_spoke), asset);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), asset, true);
    _agentHub.addAllowedMarket(_agentId, market);
    _registry.setOraclePaused(asset, true);

    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.ReserveNotListed.selector, market));
    _pauseAgent.poke(address(_hub), address(_spoke), asset);
  }

  function test_setPriceAdapter_ownerAndAdmin() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.PriceAdapterSet(
      _market,
      address(_hub),
      address(_spoke),
      ASSET,
      address(adapter)
    );
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(adapter));
    assertEq(_pauseAgent.priceAdapter(_market), address(adapter));
    assertEq(_pauseAgent.priceAdapter(_otherMarket), address(0));

    vm.prank(_admin);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(0));
    assertEq(_pauseAgent.priceAdapter(_market), address(0));
  }

  function test_setPriceAdapter_onlyOwnerOrAdmin(address caller) public {
    vm.assume(caller != address(this) && caller != _admin);
    address adapter = address(new BoundedPriceAdapterMock());
    vm.prank(caller);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.OnlyAgentHubOwnerOrAgentAdmin.selector, caller)
    );
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, adapter);
  }

  function test_setPriceAdapter_revertsBeforeHubAgentId() public {
    AaveV4PauseAgent agent = _newAgent(address(_registry));
    address adapter = address(new BoundedPriceAdapterMock());
    vm.expectRevert(AaveV4PauseAgent.HubAgentIdNotSet.selector);
    agent.setPriceAdapter(address(_hub), address(_spoke), ASSET, adapter);
  }

  function test_setPriceAdapter_revertsOnZeroMarket() public {
    address adapter = address(new BoundedPriceAdapterMock());
    vm.expectRevert(AaveV4PauseAgent.InvalidMarket.selector);
    _pauseAgent.setPriceAdapter(address(_hub), address(0), ASSET, adapter);
  }

  function test_setPriceAdapter_revertsOnInvalidAdapter() public {
    address eoa = makeAddr('eoa');
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.InvalidPriceAdapter.selector, eoa));
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, eoa);

    RawReturnMock raw = new RawReturnMock();
    raw.setReturn(abi.encode(uint256(2)), false);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.InvalidPriceAdapter.selector, address(raw))
    );
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(raw));

    raw.setReturn(abi.encode(true, true), false);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.InvalidPriceAdapter.selector, address(raw))
    );
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(raw));

    raw.setReturn(abi.encode(false), true);
    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.InvalidPriceAdapter.selector, address(raw))
    );
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(raw));
  }

  function test_poke_pausesOnAdapterBreach(address caller) public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(adapter));

    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    adapter.setBreached(true);
    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(_market, RESERVE_ID, caller, false, true);
    vm.prank(caller);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
    assertFalse(_spoke.getReserveConfig(OTHER_RESERVE_ID).paused);
    assertEq(_pauseAgent.lastPausedAt(_market), block.timestamp);
    assertFalse(_pauseAgent.isIssuerPokeEnabled(_market));

    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.ReserveAlreadyPaused.selector, _market)
    );
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_adapterIgnoresIssuerFlagWhenIssuerPokeDisabled() public {
    _registry.setOraclePaused(ASSET, true);
    _pauseAgent.setPriceAdapter(
      address(_hub),
      address(_spoke),
      ASSET,
      address(new BoundedPriceAdapterMock())
    );
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_bothTriggers() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _registry.setOraclePaused(ASSET, true);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(adapter));

    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(_market, RESERVE_ID, address(this), true, true);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_poke_adapterBreachWhenRegistryReverts() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), OTHER_ASSET, true);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), OTHER_ASSET, address(adapter));

    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(_otherMarket, OTHER_RESERVE_ID, address(this), false, true);
    _pauseAgent.poke(address(_hub), address(_spoke), OTHER_ASSET);
    assertTrue(_spoke.getReserveConfig(OTHER_RESERVE_ID).paused);
  }

  function test_poke_issuerFlagWhenAdapterFails() public {
    RawReturnMock raw = new RawReturnMock();
    raw.setReturn(abi.encode(false), false);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(raw));
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);

    raw.setReturn(abi.encode(true), true);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    raw.setReturn(abi.encode(uint256(2)), false);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    _registry.setOraclePaused(ASSET, true);
    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(_market, RESERVE_ID, address(this), true, false);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertTrue(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_poke_adapterUnsetDisablesPoke() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(adapter));
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(0));

    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeDisabled.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
  }

  function test_poke_adapterBreachFollowsHubGating() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(adapter));

    _agentHub.addRestrictedMarket(_agentId, _market);
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.MarketNotAllowed.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    _agentHub.removeRestrictedMarket(_agentId, _market);

    vm.prank(_admin);
    _agentHub.setAgentEnabled(_agentId, false);
    vm.expectRevert(AaveV4PauseAgent.AgentDisabled.selector);
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertFalse(_spoke.getReserveConfig(RESERVE_ID).paused);
  }

  function test_poke_adapterBreachBlocksStaleUpdate() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _pauseAgent.setPriceAdapter(address(_hub), address(_spoke), ASSET, address(adapter));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);

    _spoke.setPaused(RESERVE_ID, false);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
    vm.warp(block.timestamp + 1);
    assertTrue(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function test_poke_revertsOnInvalidReserveConfig() public {
    _pauseAgent.setIssuerPokeEnabled(address(_hub), address(_spoke), ASSET, true);
    _registry.setOraclePaused(ASSET, true);
    _spoke.setReserveConfig(
      RESERVE_ID,
      ISpoke.ReserveConfig({
        collateralRisk: 0,
        paused: false,
        frozen: false,
        borrowable: true,
        receiveSharesEnabled: true
      })
    );
    vm.mockCall(
      address(_spoke),
      abi.encodeCall(ISpoke.getReserveConfig, (RESERVE_ID)),
      abi.encode(uint256(0), uint256(2), uint256(0), uint256(1), uint256(1))
    );
    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.ReserveNotListed.selector, _market));
    _pauseAgent.poke(address(_hub), address(_spoke), ASSET);
    assertFalse(_validate(_market, _payload(ASSET, abi.encode(uint256(1)))));
  }

  function _newAgent(address registry) internal returns (AaveV4PauseAgent) {
    return
      new AaveV4PauseAgent(
        address(_agentHub),
        address(new RangeValidationModule()),
        address(_configurator),
        registry
      );
  }

  function _registration(
    address agent
  ) internal view returns (IAgentConfigurator.AgentRegistrationInput memory) {
    return
      IAgentConfigurator.AgentRegistrationInput({
        agentAddress: agent,
        riskOracle: address(_riskOracle),
        admin: _admin,
        agentContext: '',
        isAgentEnabled: true,
        isAgentPermissioned: false,
        isMarketsFromAgentEnabled: false,
        expirationPeriod: 1 days,
        minimumDelay: 1 days,
        updateType: _updateType,
        allowedMarkets: new address[](0),
        restrictedMarkets: new address[](0),
        permissionedSenders: new address[](0)
      });
  }

  function _validate(address market, bytes memory newValue) internal view returns (bool) {
    return _pauseAgent.validate(_agentId, _agentContext, _update(market, newValue));
  }

  function _payload(address asset, bytes memory value) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(_spoke), asset, value);
  }

  function _update(
    address market,
    bytes memory newValue
  ) internal view returns (IRiskOracle.RiskParameterUpdate memory update) {
    update.timestamp = block.timestamp;
    update.newValue = newValue;
    update.updateType = 'ReservePause';
    update.updateId = 1;
    update.market = market;
  }

  function _publish(address market, bytes memory newValue) internal {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('ref', newValue, _updateType, market, '');
  }
}
