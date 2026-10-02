// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';
import {IAgentConfigurator, IAgentHub} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {BaseAaveV4Agent} from '../../../src/contracts/agent/v4/BaseAaveV4Agent.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {IHubConfigurator} from '../../../src/contracts/dependencies/v4/IHubConfigurator.sol';
import {AaveV4AgentHarness} from './mocks/AaveV4AgentHarness.sol';
import {AaveV4HubAgentHarness} from './mocks/AaveV4HubAgentHarness.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {HubMock, RevertingHubMock, ShortReturnHubMock, LongReturnHubMock, DirtyBoolHubMock, RawReturnMock, SpokeMock, AccessManagerMock, ConfiguratorMock, HubConfiguratorMock, SpokeConfiguratorMock} from './mocks/AaveV4Mocks.sol';

contract BaseAaveV4Agent_Test is BaseAgentTest('CollateralRiskUpdate') {
  RangeValidationModule internal _rangeValidationModule;
  AccessManagerMock internal _accessManager;
  SpokeConfiguratorMock internal _configurator;
  HubMock internal _hub;
  SpokeMock internal _spoke;
  AaveV4AgentHarness internal _harness;

  address internal constant ASSET = address(0xA55E7);
  address internal constant OTHER_ASSET = address(0xB0B);
  uint256 internal constant ASSET_ID = 3;
  uint256 internal constant RESERVE_ID = 5;
  uint24 internal constant CURRENT_RISK = 10_00;
  bytes4 internal constant SELECTOR = ISpokeConfigurator.updateCollateralRisk.selector;

  address internal _market;

  function _deployAgent() internal override returns (address) {
    _rangeValidationModule = new RangeValidationModule();
    _accessManager = new AccessManagerMock();
    _configurator = new SpokeConfiguratorMock(address(_accessManager));
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
    _allow(address(_harness), address(_configurator), SELECTOR, true, 0);
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

  function test_constructor_revertsOnZeroRangeValidationModule() public {
    vm.expectRevert(BaseAaveV4Agent.InvalidZeroAddress.selector);
    new AaveV4AgentHarness(address(_agentHub), address(0), address(_configurator));
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

  function test_decode_dirtyPadding(uint8 index, uint8 dirt) public view {
    vm.assume(dirt != 0);
    bytes memory data = abi.encode(address(_hub), address(_spoke), ASSET, hex'01');
    assertEq(data.length, 192);
    data[161 + (index % 31)] = bytes1(dirt);
    (bool ok, , ) = _harness.decodeUpdate(_update(_market, data));
    assertFalse(ok);
  }

  function test_decodeUint(uint256 value, uint256 max) public view {
    (bool ok, uint256 decoded) = _harness.decodeUint(abi.encode(value), max);
    assertEq(ok, value <= max);
    assertEq(decoded, value <= max ? value : 0);
  }

  function test_decodeUint_badLength(bytes memory value) public view {
    vm.assume(value.length != 32);
    (bool ok, ) = _harness.decodeUint(value, type(uint256).max);
    assertFalse(ok);
  }

  function test_canCallConfigurator() public {
    assertTrue(_harness.canCallConfigurator(SELECTOR));
    assertFalse(_harness.canCallConfigurator(bytes4(0xdeadbeef)));

    _allow(address(_harness), address(_configurator), SELECTOR, true, 1);
    assertFalse(_harness.canCallConfigurator(SELECTOR));
    _allow(address(_harness), address(_configurator), SELECTOR, false, 0);
    assertFalse(_harness.canCallConfigurator(SELECTOR));
  }

  function test_canCallConfigurator_badAuthority() public {
    address[4] memory authorities = [
      address(new RevertingHubMock()),
      address(new ShortReturnHubMock()),
      address(new DirtyBoolHubMock()),
      address(0xC0DE)
    ];
    for (uint256 i = 0; i < authorities.length; i++) {
      AaveV4AgentHarness harness = new AaveV4AgentHarness(
        address(_agentHub),
        address(_rangeValidationModule),
        address(new SpokeConfiguratorMock(authorities[i]))
      );
      assertFalse(harness.canCallConfigurator(SELECTOR));
    }
    AaveV4AgentHarness noAuthority = new AaveV4AgentHarness(
      address(_agentHub),
      address(_rangeValidationModule),
      address(_spoke)
    );
    assertFalse(noAuthority.canCallConfigurator(SELECTOR));
  }

  function test_configuratorCanCall() public {
    address target = address(new ConfiguratorMock(address(_accessManager)));
    bytes4 selector = ISpoke.updateReserveConfig.selector;
    assertFalse(_harness.configuratorCanCall(target, selector));

    _allow(address(_configurator), target, selector, true, 0);
    assertTrue(_harness.configuratorCanCall(target, selector));
    assertFalse(_harness.configuratorCanCall(target, ISpoke.addDynamicReserveConfig.selector));
    assertFalse(_harness.canCallImmediately(address(_harness), target, selector));

    _allow(address(_configurator), target, selector, true, 1);
    assertFalse(_harness.configuratorCanCall(target, selector));
    _allow(address(_configurator), target, selector, false, 0);
    assertFalse(_harness.configuratorCanCall(target, selector));
  }

  function test_configuratorCanCall_agentPermissionIsSeparate() public {
    address target = address(new ConfiguratorMock(address(_accessManager)));
    bytes4 selector = ISpoke.updateReserveConfig.selector;
    _allow(address(_harness), target, selector, true, 0);
    assertTrue(_harness.canCallImmediately(address(_harness), target, selector));
    assertFalse(_harness.configuratorCanCall(target, selector));
    assertTrue(_harness.canCallConfigurator(SELECTOR));
  }

  function test_configuratorCanCall_badAuthority() public {
    RawReturnMock dirtyAuthority = new RawReturnMock();
    dirtyAuthority.setReturn(
      abi.encode((uint256(1) << 160) | uint160(address(_accessManager))),
      false
    );
    RawReturnMock badCanCall = new RawReturnMock();
    badCanCall.setReturn(abi.encode(uint256(2), uint256(0)), false);
    RawReturnMock longCanCall = new RawReturnMock();
    longCanCall.setReturn(abi.encode(uint256(1), uint256(0), uint256(0)), false);

    address[6] memory authorities = [
      address(new RevertingHubMock()),
      address(new ShortReturnHubMock()),
      address(new DirtyBoolHubMock()),
      address(new LongReturnHubMock()),
      address(badCanCall),
      address(longCanCall)
    ];
    for (uint256 i = 0; i < authorities.length; i++) {
      address target = address(new ConfiguratorMock(authorities[i]));
      assertFalse(_harness.configuratorCanCall(target, SELECTOR));
    }
    assertFalse(_harness.configuratorCanCall(address(new ConfiguratorMock(address(0))), SELECTOR));
    assertFalse(
      _harness.configuratorCanCall(address(new ConfiguratorMock(address(0xC0DE))), SELECTOR)
    );
    assertFalse(_harness.configuratorCanCall(address(dirtyAuthority), SELECTOR));
    assertFalse(_harness.configuratorCanCall(address(_spoke), SELECTOR));
    assertFalse(_harness.configuratorCanCall(address(0xC0DE), SELECTOR));
  }

  function test_staticcallWords(uint8 count, uint8 returned, uint256 seed) public {
    count = uint8(bound(count, 1, 12));
    returned = uint8(bound(returned, 0, 12));
    uint256[] memory data = new uint256[](returned);
    for (uint256 i = 0; i < returned; i++) data[i] = uint256(keccak256(abi.encode(seed, i)));
    RawReturnMock target = new RawReturnMock();
    target.setReturn(abi.encodePacked(data), false);

    (bool ok, uint256[] memory words) = _harness.staticcallWords(address(target), '', count);
    assertEq(ok, count == returned);
    assertEq(words.length, count);
    for (uint256 i = 0; i < count; i++) assertEq(words[i], ok ? data[i] : 0);

    target.setReturn(abi.encodePacked(data), true);
    (ok, words) = _harness.staticcallWords(address(target), '', count);
    assertFalse(ok);
    for (uint256 i = 0; i < count; i++) assertEq(words[i], 0);

    (ok, ) = _harness.staticcallWords(address(0xC0DE), '', count);
    assertFalse(ok);
  }

  function test_staticcallWord() public {
    RawReturnMock target = new RawReturnMock();
    target.setReturn(abi.encode(uint256(7)), false);
    (bool ok, uint256 word) = _harness.staticcallWord(address(target), '');
    assertTrue(ok);
    assertEq(word, 7);

    target.setReturn(abi.encode(uint256(7), uint256(8)), false);
    (ok, word) = _harness.staticcallWord(address(target), '');
    assertFalse(ok);
    assertEq(word, 0);

    target.setReturn(abi.encode(uint256(7)), true);
    (ok, word) = _harness.staticcallWord(address(target), '');
    assertFalse(ok);
    assertEq(word, 0);
  }

  function test_reserveConfig() public {
    ISpoke.ReserveConfig memory config = ISpoke.ReserveConfig({
      collateralRisk: 12_34,
      paused: true,
      frozen: false,
      borrowable: true,
      receiveSharesEnabled: true
    });
    _spoke.setReserveConfig(RESERVE_ID, config);
    (bool ok, ISpoke.ReserveConfig memory read) = _harness.reserveConfig(
      address(_spoke),
      RESERVE_ID
    );
    assertTrue(ok);
    assertEq(abi.encode(read), abi.encode(config));

    (ok, ) = _harness.reserveConfig(address(new RevertingHubMock()), RESERVE_ID);
    assertFalse(ok);
    (ok, ) = _harness.reserveConfig(address(_hub), RESERVE_ID);
    assertFalse(ok);
  }

  function test_reserveConfig_rawWords(uint256[5] memory words) public {
    for (uint256 i = 0; i < 5; i++) {
      if (words[i] % 4 != 0)
        words[i] = i == 0 ? words[i] % (uint256(type(uint24).max) + 2) : words[i] % 3;
    }
    RawReturnMock spoke = new RawReturnMock();
    spoke.setReturn(abi.encode(words), false);
    (bool ok, ISpoke.ReserveConfig memory read) = _harness.reserveConfig(address(spoke), 0);

    bool valid = words[0] <= type(uint24).max;
    for (uint256 i = 1; i < 5; i++) valid = valid && words[i] <= 1;
    assertEq(ok, valid);
    if (valid) {
      assertEq(read.collateralRisk, words[0]);
      assertEq(read.paused, words[1] == 1);
      assertEq(read.frozen, words[2] == 1);
      assertEq(read.borrowable, words[3] == 1);
      assertEq(read.receiveSharesEnabled, words[4] == 1);
    }
  }

  function test_dynamicReserveConfig() public {
    ISpoke.DynamicReserveConfig memory config = ISpoke.DynamicReserveConfig({
      collateralFactor: 75_00,
      maxLiquidationBonus: 105_00,
      liquidationFee: 10_00
    });
    _spoke.setDynamicConfigKey(RESERVE_ID, 4);
    _spoke.setDynamicReserveConfig(RESERVE_ID, 4, config);

    (bool ok, uint32 key) = _harness.dynamicConfigKey(address(_spoke), RESERVE_ID);
    assertTrue(ok);
    assertEq(key, 4);

    ISpoke.DynamicReserveConfig memory read;
    (ok, read) = _harness.dynamicReserveConfig(address(_spoke), RESERVE_ID, 4);
    assertTrue(ok);
    assertEq(abi.encode(read), abi.encode(config));

    (ok, key, read) = _harness.latestDynamicReserveConfig(address(_spoke), RESERVE_ID);
    assertTrue(ok);
    assertEq(key, 4);
    assertEq(abi.encode(read), abi.encode(config));

    address reverting = address(new RevertingHubMock());
    (ok, ) = _harness.dynamicConfigKey(reverting, RESERVE_ID);
    assertFalse(ok);
    (ok, ) = _harness.dynamicReserveConfig(reverting, RESERVE_ID, 4);
    assertFalse(ok);
    (ok, , ) = _harness.latestDynamicReserveConfig(reverting, RESERVE_ID);
    assertFalse(ok);
  }

  function test_dynamicConfigKey_rawWords(uint256 key) public {
    RawReturnMock spoke = new RawReturnMock();
    uint256[7] memory words;
    words[6] = key % 2 == 0 ? key % (uint256(type(uint32).max) + 2) : key;
    spoke.setReturn(abi.encode(words), false);
    (bool ok, uint32 read) = _harness.dynamicConfigKey(address(spoke), 0);
    assertEq(ok, words[6] <= type(uint32).max);
    assertEq(read, ok ? words[6] : 0);

    (ok, , ) = _harness.latestDynamicReserveConfig(address(spoke), 0);
    assertFalse(ok);
  }

  function test_dynamicReserveConfig_rawWords(uint256[3] memory words) public {
    uint256[3] memory maxes = [
      uint256(type(uint16).max),
      uint256(type(uint32).max),
      uint256(type(uint16).max)
    ];
    for (uint256 i = 0; i < 3; i++) {
      if (words[i] % 4 != 0) words[i] = words[i] % (maxes[i] + 2);
    }
    RawReturnMock spoke = new RawReturnMock();
    spoke.setReturn(abi.encode(words), false);
    (bool ok, ISpoke.DynamicReserveConfig memory read) = _harness.dynamicReserveConfig(
      address(spoke),
      0,
      0
    );
    bool valid = words[0] <= maxes[0] && words[1] <= maxes[1] && words[2] <= maxes[2];
    assertEq(ok, valid);
    if (valid) {
      assertEq(read.collateralFactor, words[0]);
      assertEq(read.maxLiquidationBonus, words[1]);
      assertEq(read.liquidationFee, words[2]);
    }
  }

  function test_contains(address[] memory list, address item, uint256 index) public view {
    bool expected;
    for (uint256 i = 0; i < list.length; i++) expected = expected || list[i] == item;
    assertEq(_harness.contains(list, item), expected);
    if (list.length != 0) {
      list[index % list.length] = item;
      assertTrue(_harness.contains(list, item));
    }
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

  function test_spokeAssetId() public {
    address spoke = address(new SpokeMock());
    (bool ok, uint256 assetId) = _harness.spokeAssetId(address(_hub), spoke, ASSET);
    assertFalse(ok);

    _hub.listSpoke(ASSET_ID, spoke);
    (ok, assetId) = _harness.spokeAssetId(address(_hub), spoke, ASSET);
    assertTrue(ok);
    assertEq(assetId, ASSET_ID);
    (ok, , ) = _harness.reserveId(address(_hub), spoke, ASSET);
    assertFalse(ok);

    (ok, ) = _harness.spokeAssetId(address(_hub), spoke, OTHER_ASSET);
    assertFalse(ok);
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

  function test_validate_hubLevelMarketOnSpokeAgent() public {
    _hub.listSpoke(ASSET_ID, address(0));
    address market = _harness.marketId(address(_hub), address(0), ASSET);
    bytes memory data = abi.encode(address(_hub), address(0), ASSET, abi.encode(11_00));
    assertFalse(_harness.validate(_agentId, _agentContext, _update(market, data)));
  }

  function test_validate_cannotCallConfigurator() public {
    IRiskOracle.RiskParameterUpdate memory update = _update(_market, _payload(11_00));
    _allow(address(_harness), address(_configurator), SELECTOR, false, 0);
    assertFalse(_harness.validate(_agentId, _agentContext, update));
    _allow(address(_harness), address(_configurator), SELECTOR, true, 1 days);
    assertFalse(_harness.validate(_agentId, _agentContext, update));
  }

  function test_check_unauthorizedAgentDoesNotBlockOtherAgent() public {
    AaveV4AgentHarness other = new AaveV4AgentHarness(
      address(_agentHub),
      address(_rangeValidationModule),
      address(_configurator)
    );
    _allow(address(other), address(_configurator), SELECTOR, true, 0);
    uint256 otherId = _register(address(other), _market);
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      otherId,
      'CollateralRisk',
      IRangeValidationModule.RangeConfig({
        maxIncrease: 5_00,
        maxDecrease: 5_00,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
    _publish(_market, _payload(12_00));
    _allow(address(_harness), address(_configurator), SELECTOR, false, 0);

    uint256[] memory agentIds = new uint256[](2);
    agentIds[0] = _agentId;
    agentIds[1] = otherId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    assertTrue(shouldRun);
    assertEq(actions.length, 1);
    assertEq(actions[0].agentId, otherId);
    _agentHub.execute(actions);
    assertEq(_configurator.calls(), 1);
  }

  function test_hubLevel_checkAndExecute() public {
    HubConfiguratorMock configurator = new HubConfiguratorMock(address(_accessManager));
    AaveV4HubAgentHarness hubAgent = new AaveV4HubAgentHarness(
      address(_agentHub),
      address(_rangeValidationModule),
      _updateType,
      address(configurator)
    );
    _allow(
      address(hubAgent),
      address(configurator),
      IHubConfigurator.updateInterestRateData.selector,
      true,
      0
    );
    address hubMarket = hubAgent.marketId(address(_hub), address(0), ASSET);
    address spokeMarket = hubAgent.marketId(address(_hub), address(_spoke), ASSET);
    uint256 hubAgentId = _register(address(hubAgent), hubMarket);
    _agentHub.addAllowedMarket(hubAgentId, spokeMarket);

    bytes memory irData = abi.encode(uint256(80_00), uint256(1), uint256(2), uint256(3));
    _publish(hubMarket, abi.encode(address(_hub), address(0), ASSET, irData));
    _publish(spokeMarket, abi.encode(address(_hub), address(_spoke), ASSET, irData));

    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = hubAgentId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], hubMarket);

    _agentHub.execute(actions);
    assertEq(configurator.calls(), 1);
    assertEq(configurator.lastHub(), address(_hub));
    assertEq(configurator.lastAssetId(), ASSET_ID);
    assertEq(configurator.lastIrData(), irData);
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

  function _allow(
    address caller,
    address target,
    bytes4 selector,
    bool allowed,
    uint32 delay
  ) internal {
    _accessManager.setCanCall(caller, target, selector, allowed, delay);
  }

  function _register(address agent, address market) internal returns (uint256) {
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
          allowedMarkets: _addressToArray(market),
          restrictedMarkets: new address[](0),
          permissionedSenders: new address[](0)
        })
      );
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
