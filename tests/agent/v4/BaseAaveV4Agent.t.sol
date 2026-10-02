// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator, IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {AaveV4AgentHarness} from './mocks/AaveV4AgentHarness.sol';
import {HubMock, RevertingHubMock, ShortReturnHubMock, LongReturnHubMock, DirtyBoolHubMock, SpokeMock, SpokeConfiguratorMock} from './mocks/AaveV4Mocks.sol';

contract BaseAaveV4Agent_Test is BaseAgentTest('CollateralRiskUpdate') {
  RangeValidationModule internal _rangeValidationModule;
  SpokeConfiguratorMock internal _configurator;
  HubMock internal _hub;
  SpokeMock internal _spoke;
  AaveV4AgentHarness internal _harness;

  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant RESERVE_ID = 5;
  uint24 internal constant CURRENT_RISK = 10_00;

  address internal _market;

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _configurator = new SpokeConfiguratorMock();
    _hub = new HubMock();
    _spoke = new SpokeMock();

    _hub.listAsset(ASSET, ASSET_ID);
    _hub.listSpoke(ASSET_ID, address(_spoke));
    _spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    _spoke.setCollateralRisk(RESERVE_ID, CURRENT_RISK);

    _harness = new AaveV4AgentHarness(
      address(_agentHub),
      address(_rangeValidationModule),
      address(_configurator)
    );
    _market = _harness.marketId(address(_hub), address(_spoke), ASSET);
    return address(_harness);
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
      'CollateralRisk',
      IRangeValidationModule.RangeConfig({
        maxIncrease: 5_00,
        maxDecrease: 5_00,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function test_constructor_revertsOnZeroAgentHub() public {
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4AgentHarness(address(0), address(_rangeValidationModule), address(_configurator));
  }

  function test_constructor_revertsOnZeroConfigurator() public {
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4AgentHarness(address(_agentHub), address(_rangeValidationModule), address(0));
  }

  function test_getters() public view {
    assertEq(_harness.getUpdateType(), 'CollateralRiskUpdate');
    assertEq(_harness.CONFIGURATOR(), address(_configurator));
    assertEq(address(_harness.RANGE_VALIDATION_MODULE()), address(_rangeValidationModule));
    assertEq(_harness.getMarkets(_agentId).length, 0);
  }

  function test_marketId(address hub, address spoke, address asset) public view {
    assertEq(
      _harness.marketId(hub, spoke, asset),
      address(uint160(uint256(keccak256(abi.encode(hub, spoke, asset)))))
    );
  }

  function test_decode_valid(
    address hub,
    address spoke,
    address asset,
    bytes memory value
  ) public view {
    vm.assume(hub != address(0) && asset != address(0));
    IRiskOracle.RiskParameterUpdate memory update = _update(
      _harness.marketId(hub, spoke, asset),
      abi.encode(hub, spoke, asset, value)
    );
    (bool ok, BaseAaveV4Agent.Market memory market, bytes memory decoded) = _harness.decodeUpdate(
      update
    );
    assertTrue(ok);
    assertEq(market.hub, hub);
    assertEq(market.spoke, spoke);
    assertEq(market.asset, asset);
    assertEq(decoded, value);
  }

  function test_decode_hubLevelMarket() public view {
    (bool ok, BaseAaveV4Agent.Market memory market, ) = _harness.decodeUpdate(
      _update(
        _harness.marketId(address(_hub), address(0), ASSET),
        abi.encode(address(_hub), address(0), ASSET, abi.encode(1))
      )
    );
    assertTrue(ok);
    assertEq(market.spoke, address(0));
  }

  function test_decode_marketMismatch(address market) public view {
    vm.assume(market != _market);
    (bool ok, , ) = _harness.decodeUpdate(_update(market, _payload(uint256(11_00))));
    assertFalse(ok);
  }

  function test_decode_zeroHubOrAsset() public view {
    (bool ok, , ) = _harness.decodeUpdate(
      _update(
        _harness.marketId(address(0), address(_spoke), ASSET),
        abi.encode(address(0), address(_spoke), ASSET, abi.encode(1))
      )
    );
    assertFalse(ok);
    (ok, , ) = _harness.decodeUpdate(
      _update(
        _harness.marketId(address(_hub), address(_spoke), address(0)),
        abi.encode(address(_hub), address(_spoke), address(0), abi.encode(1))
      )
    );
    assertFalse(ok);
  }

  function test_decode_shortData(uint8 length) public view {
    vm.assume(length < 160);
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, new bytes(length)));
    assertFalse(ok);
  }

  function test_decode_nonCanonicalOffset(uint256 offset) public view {
    vm.assume(offset != 128);
    bytes memory data = _payload(uint256(11_00));
    assembly {
      mstore(add(data, 0x80), offset)
    }
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, data));
    assertFalse(ok);
  }

  function test_decode_trailingBytes(uint8 extra) public view {
    vm.assume(extra != 0);
    bytes memory data = abi.encodePacked(_payload(uint256(11_00)), new bytes(extra));
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, data));
    assertFalse(ok);
  }

  function test_decode_truncatedValue() public view {
    bytes memory data = _payload(uint256(11_00));
    assembly {
      mstore(data, sub(mload(data), 1))
    }
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, data));
    assertFalse(ok);
  }

  function test_decode_lengthOverflow(uint256 length) public view {
    vm.assume(length > 32);
    bytes memory data = _payload(uint256(11_00));
    assembly {
      mstore(add(data, 0xa0), length)
    }
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, data));
    assertFalse(ok);
  }

  function test_decode_dirtyAddressBits(uint8 word, uint96 dirt) public view {
    vm.assume(dirt != 0);
    bytes memory data = _payload(uint256(11_00));
    uint256 offset = 0x20 + 0x20 * (word % 3);
    assembly {
      let slot := add(data, offset)
      mstore(slot, or(mload(slot), shl(160, dirt)))
    }
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, data));
    assertFalse(ok);
  }

  function test_assetId() public view {
    (bool ok, uint256 assetId) = _harness.assetId(address(_hub), ASSET);
    assertTrue(ok);
    assertEq(assetId, ASSET_ID);

    (ok, assetId) = _harness.assetId(address(_hub), OTHER_ASSET);
    assertFalse(ok);
    assertEq(assetId, 0);
  }

  function test_assetId_badHubs() public {
    address[5] memory hubs = [
      address(new RevertingHubMock()),
      address(new ShortReturnHubMock()),
      address(new LongReturnHubMock()),
      address(new DirtyBoolHubMock()),
      address(0xC0DE)
    ];
    for (uint256 i = 0; i < hubs.length; i++) {
      (bool ok, uint256 assetId) = _harness.assetId(hubs[i], ASSET);
      assertFalse(ok);
      assertEq(assetId, 0);
      (ok, , ) = _harness.reserveId(hubs[i], address(_spoke), ASSET);
      assertFalse(ok);
    }
  }

  function test_reserveId() public view {
    (bool ok, uint256 assetId, uint256 reserveId) = _harness.reserveId(
      address(_hub),
      address(_spoke),
      ASSET
    );
    assertTrue(ok);
    assertEq(assetId, ASSET_ID);
    assertEq(reserveId, RESERVE_ID);
  }

  function test_reserveId_spokeNotListedOnHub() public {
    SpokeMock spoke = new SpokeMock();
    spoke.addReserve(address(_hub), ASSET_ID, RESERVE_ID);
    (bool ok, , ) = _harness.reserveId(address(_hub), address(spoke), ASSET);
    assertFalse(ok);
  }

  function test_reserveId_reserveNotOnSpoke() public {
    SpokeMock spoke = new SpokeMock();
    _hub.listSpoke(ASSET_ID, address(spoke));
    (bool ok, , ) = _harness.reserveId(address(_hub), address(spoke), ASSET);
    assertFalse(ok);
  }

  function test_reserveId_badSpoke() public {
    address[3] memory spokes = [
      address(new RevertingHubMock()),
      address(new ShortReturnHubMock()),
      address(0xC0DE)
    ];
    for (uint256 i = 0; i < spokes.length; i++) {
      _hub.listSpoke(ASSET_ID, spokes[i]);
      (bool ok, , ) = _harness.reserveId(address(_hub), spokes[i], ASSET);
      assertFalse(ok);
    }
  }

  function test_validate_valid() public view {
    assertTrue(_harness.validate(_agentId, _agentContext, _update(_market, _payload(11_00))));
  }

  function test_validate_wrongUpdateType() public view {
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(11_00));
    update.updateType = 'CollateralRiskUpdateX';
    assertFalse(_harness.validate(_agentId, _agentContext, update));
  }

  function test_validate_unlistedAsset() public view {
    address market = _harness.marketId(address(_hub), address(_spoke), OTHER_ASSET);
    bytes memory data = abi.encode(address(_hub), address(_spoke), OTHER_ASSET, abi.encode(11_00));
    assertFalse(_harness.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_revertingHub() public {
    address hub = address(new RevertingHubMock());
    address market = _harness.marketId(hub, address(_spoke), ASSET);
    bytes memory data = abi.encode(hub, address(_spoke), ASSET, abi.encode(11_00));
    assertFalse(_harness.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_badPayload() public view {
    assertFalse(_harness.validate(_agentId, _agentContext, _update(_market, '')));
    assertFalse(_harness.validate(_agentId, _agentContext, _update(_market, abi.encode(11_00))));
  }

  function test_validate_outOfRangeOrNoop() public view {
    assertFalse(_harness.validate(_agentId, _agentContext, _update(_market, _payload(16_00))));
    assertFalse(
      _harness.validate(_agentId, _agentContext, _update(_market, _payload(CURRENT_RISK)))
    );
  }

  function test_inject() public {
    vm.prank(address(_agentHub));
    _harness.inject(_agentId, _agentContext, _update(_market, _payload(12_00)));
    assertEq(_configurator.calls(), 1);
    assertEq(_configurator.lastSpoke(), address(_spoke));
    assertEq(_configurator.lastReserveId(), RESERVE_ID);
    assertEq(_configurator.lastCollateralRisk(), 12_00);
  }

  function test_inject_revertsWhenInvalid() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(16_00));
    vm.prank(address(_agentHub));
    vm.expectRevert(BaseAaveV4Agent.InvalidUpdate.selector);
    _harness.inject(_agentId, _agentContext, update);
  }

  function test_checkAndExecute() public {
    _publish(_market, _payload(12_00));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertEq(_configurator.calls(), 1);
    assertEq(_configurator.lastCollateralRisk(), 12_00);
  }

  function test_checkAndExecute_skipsBadMarket() public {
    address badMarket = _harness.marketId(address(_hub), address(_spoke), OTHER_ASSET);
    _agentHub.addAllowedMarket(_agentId, badMarket);
    _publish(
      badMarket,
      abi.encode(address(_hub), address(_spoke), OTHER_ASSET, abi.encode(uint256(12_00)))
    );
    _publish(_market, _payload(12_00));

    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = _agentId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _market);

    address[] memory markets = new address[](2);
    markets[0] = badMarket;
    markets[1] = _market;
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertEq(_configurator.calls(), 1);
  }

  function test_checkAndExecute_mismatchedMarket() public {
    address otherMarket = _harness.marketId(address(_hub), address(_spoke), OTHER_ASSET);
    _agentHub.addAllowedMarket(_agentId, otherMarket);
    _publish(otherMarket, _payload(12_00));
    assertFalse(_checkAndPerformAutomation(_agentId));
  }

  function _payload(uint256 value) internal view returns (bytes memory) {
    return abi.encode(address(_hub), address(_spoke), ASSET, abi.encode(value));
  }

  function _update(
    address market,
    bytes memory newValue
  ) internal view returns (IRiskOracle.RiskParameterUpdate memory update) {
    update.timestamp = block.timestamp;
    update.newValue = newValue;
    update.updateType = 'CollateralRiskUpdate';
    update.updateId = 1;
    update.market = market;
  }

  function _publish(address market, bytes memory newValue) internal {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('ref', newValue, _updateType, market, '');
  }
}
