// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Vm} from 'forge-std/Vm.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumEtherFi, AaveV3EthereumEtherFiAssets} from 'aave-address-book/AaveV3EthereumEtherFi.sol';
import {AaveV3EthereumLido} from 'aave-address-book/AaveV3EthereumLido.sol';
import {IPriceCapAdapter} from 'aave-price-feeds/interfaces/IPriceCapAdapter.sol';
import {IPendlePriceCapAdapter} from 'aave-price-feeds/interfaces/IPendlePriceCapAdapter.sol';
import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';

import {AaveV4CapoAgent} from '../../../src/contracts/agent/v4/AaveV4CapoAgent.sol';
import {AaveV4DiscountRateAgent} from '../../../src/contracts/agent/v4/AaveV4DiscountRateAgent.sol';
import {IAaveOracle} from '../../../src/contracts/dependencies/v4/IAaveOracle.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {AaveV4ForkTestBase} from './AaveV4ForkTestBase.sol';

library AaveV4EthereumFork {
  uint256 internal constant BLOCK = 26000000;
  address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
  address internal constant PLUS_HUB = 0x06002e9c4412CB7814a791eA3666D905871E536A;
  address internal constant PRIME_HUB = 0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931;
  address internal constant GLOBAL_DOLLAR_HUB = 0x62d63197660c080236193CA60b70E49A08E90368;
  address internal constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
  address internal constant LIDO_ESPOKE = 0xe1900480ac69f0B296841Cd01cC37546d92F35Cd;
  address internal constant KELP_ESPOKE = 0x3131FE68C4722e726fe6B2819ED68e514395B9a4;
  address internal constant USDG_MAPLE_ESPOKE = 0x774b9655413c34809c1f1b16b654465A89EBE989;
  address internal constant USDG_PENDLE_SPOKE = 0x956d8e0A89cfa3744428C4641b5a53B56167a7f9;
  address internal constant ETHENA_CORRELATED_SPOKE = 0x58131E79531caB1d52301228d1f7b842F26B9649;
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address internal constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant rsETH = 0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7;
  address internal constant syrupUSDG = 0x87b65C4aAFFA76881f9E96F3e7ED945ddFC3Cd7A;
  address internal constant PT_USDG_24SEP2026 = 0xc1906aeCf868749a2DeE203F59b904c0cf212140;
  address internal constant PT_USDe_7MAY2026 = 0xAeBf0Bb9f57E89260d57f31AF34eB58657d96Ce0;
  address internal constant wstETH_CAPO = 0xe1D97bF61901B075E9626c8A2340a7De385861Ef;
  address internal constant rsETH_CAPO = 0x7292C95A5f6A501a9c4B34f6393e221F2A0139c3;
  address internal constant syrupUSDG_CAPO = 0x5A6FcB0ebc018b6FD94Fc5f5A9F0948d0D40f040;
  address internal constant PT_USDG_24SEP2026_ADAPTER = 0x89F6Eb404AbF19FE817426dD2E2E0F14D1a5712e;
  address internal constant PT_USDe_7MAY2026_ADAPTER = 0x0a72df02CE3E4185b6CEDf561f0AE651E9BeE235;
}

contract FakeV4 {
  address internal immutable SOURCE;

  constructor(address source) {
    SOURCE = source;
  }

  function isUnderlyingListed(address) external pure returns (bool) {
    return true;
  }

  function getAssetId(address) external pure returns (uint256) {
    return 0;
  }

  function isSpokeListed(uint256, address) external pure returns (bool) {
    return true;
  }

  function getReserveId(address, uint256) external pure returns (uint256) {
    return 0;
  }

  function ORACLE() external view returns (address) {
    return address(this);
  }

  function getReserveSource(uint256) external view returns (address) {
    return SOURCE;
  }
}

abstract contract AaveV4AdapterAgentForkTestBase is AaveV4ForkTestBase {
  function _createFork() internal override {
    vm.createSelectFork(vm.rpcUrl('mainnet'), AaveV4EthereumFork.BLOCK);
  }

  function _hubs() internal pure returns (address[] memory hubs) {
    hubs = new address[](4);
    hubs[0] = AaveV4EthereumFork.CORE_HUB;
    hubs[1] = AaveV4EthereumFork.PLUS_HUB;
    hubs[2] = AaveV4EthereumFork.PRIME_HUB;
    hubs[3] = AaveV4EthereumFork.GLOBAL_DOLLAR_HUB;
  }

  function _v3Oracles() internal pure returns (address[] memory oracles) {
    oracles = new address[](3);
    oracles[0] = address(AaveV3Ethereum.ORACLE);
    oracles[1] = address(AaveV3EthereumLido.ORACLE);
    oracles[2] = address(AaveV3EthereumEtherFi.ORACLE);
  }

  function _detachFromV3(address asset) internal {
    address[] memory oracles = _v3Oracles();
    for (uint256 i = 0; i < oracles.length; i++) {
      vm.mockCall(
        oracles[i],
        abi.encodeWithSignature('getSourceOfAsset(address)', asset),
        abi.encode(address(0))
      );
    }
  }

  function _setRiskAdmin(address account, bool enabled) internal {
    vm.startPrank(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER.getACLAdmin());
    if (enabled) {
      AaveV3Ethereum.ACL_MANAGER.addRiskAdmin(account);
    } else {
      AaveV3Ethereum.ACL_MANAGER.removeRiskAdmin(account);
    }
    vm.stopPrank();
    assertEq(AaveV3Ethereum.ACL_MANAGER.isRiskAdmin(account), enabled);
  }

  function _source(address hub, address spoke, address asset) internal view returns (address) {
    return IAaveOracle(ISpoke(spoke).ORACLE()).getReserveSource(_reserveIdOf(hub, spoke, asset));
  }

  function _price(address hub, address spoke, address asset) internal view returns (uint256) {
    return IAaveOracle(ISpoke(spoke).ORACLE()).getReservePrice(_reserveIdOf(hub, spoke, asset));
  }

  function _reserveIdOf(address hub, address spoke, address asset) internal view returns (uint256) {
    return ISpoke(spoke).getReserveId(hub, IHub(hub).getAssetId(asset));
  }
}

contract AaveV4CapoAgent_EthereumForkTest is AaveV4AdapterAgentForkTestBase {
  address internal constant HUB = AaveV4EthereumFork.CORE_HUB;
  address internal constant MAIN_SPOKE = AaveV4EthereumFork.MAIN_SPOKE;
  address internal constant LIDO_ESPOKE = AaveV4EthereumFork.LIDO_ESPOKE;
  address internal constant wstETH = AaveV4EthereumFork.wstETH;
  IPriceCapAdapter internal constant wstETH_CAPO = IPriceCapAdapter(AaveV4EthereumFork.wstETH_CAPO);
  IPriceCapAdapter internal constant syrupUSDG_CAPO =
    IPriceCapAdapter(AaveV4EthereumFork.syrupUSDG_CAPO);

  constructor() AaveV4ForkTestBase('CapoPriceCapUpdate') {}

  function _deployAgent() internal override returns (address) {
    return
      address(
        new AaveV4CapoAgent(
          address(_agentHub),
          address(_rangeValidationModule),
          '',
          address(AaveV3Ethereum.ACL_MANAGER),
          _hubs(),
          _v3Oracles()
        )
      );
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](4);
    markets[0] = _marketId(HUB, MAIN_SPOKE, wstETH);
    markets[1] = _marketId(HUB, LIDO_ESPOKE, wstETH);
    markets[2] = _marketId(
      AaveV4EthereumFork.GLOBAL_DOLLAR_HUB,
      AaveV4EthereumFork.USDG_MAPLE_ESPOKE,
      AaveV4EthereumFork.syrupUSDG
    );
    markets[3] = _marketId(HUB, MAIN_SPOKE, AaveV4EthereumFork.WETH);
  }

  function _postSetup() internal override {
    _setRange('CapoSnapshotRatio', 5_00);
    _setRange('CapoMaxYearlyGrowthRatePercent', 10_00);
    _setRiskAdmin(_agent, true);
    _detachFromV3(wstETH);
  }

  function test_spokeOracleSources() public view {
    assertEq(_source(HUB, MAIN_SPOKE, wstETH), address(wstETH_CAPO));
    assertEq(_source(HUB, LIDO_ESPOKE, wstETH), address(wstETH_CAPO));
    assertEq(
      _source(
        AaveV4EthereumFork.GLOBAL_DOLLAR_HUB,
        AaveV4EthereumFork.USDG_MAPLE_ESPOKE,
        AaveV4EthereumFork.syrupUSDG
      ),
      address(syrupUSDG_CAPO)
    );
    assertEq(address(wstETH_CAPO.ACL_MANAGER()), address(AaveV3Ethereum.ACL_MANAGER));
    assertEq(address(syrupUSDG_CAPO.ACL_MANAGER()), address(AaveV3Ethereum.ACL_MANAGER));
  }

  function test_checkAndExecute_wstETH() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(wstETH_CAPO, 1_00);
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(params));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    _agentHub.execute(actions);

    _assertParams(wstETH_CAPO, params);
    assertGt(_price(HUB, MAIN_SPOKE, wstETH), 0);
    assertGt(_price(HUB, LIDO_ESPOKE, wstETH), 0);
  }

  function test_execute_sharedAdapterWrittenOnce() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(wstETH_CAPO, 1_00);
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(params));
    _publish(HUB, LIDO_ESPOKE, wstETH, abi.encode(params));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 2);

    vm.recordLogs();
    _agentHub.execute(actions);
    _assertParams(wstETH_CAPO, params);
    assertEq(_countLogs(address(wstETH_CAPO)), 1);
  }

  function test_execute_sharedAdapterStepsOncePerDelay() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(wstETH_CAPO, 4_90);
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(params));
    assertTrue(_checkAndExecute());
    _assertParams(wstETH_CAPO, params);

    vm.warp(block.timestamp + 1);
    IPriceCapAdapter.PriceCapUpdateParams memory next = _nextParams(wstETH_CAPO, 4_90);
    _publish(HUB, LIDO_ESPOKE, wstETH, abi.encode(next));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);

    vm.warp(block.timestamp + 1 days - 1);
    next = _nextParams(wstETH_CAPO, 4_90);
    _publish(HUB, LIDO_ESPOKE, wstETH, abi.encode(next));
    assertTrue(_checkAndExecute());
    _assertParams(wstETH_CAPO, next);
  }

  function test_execute_sharedAdapterDifferentParamsInOneBatch() public {
    IPriceCapAdapter.PriceCapUpdateParams memory first = _nextParams(wstETH_CAPO, 4_90);
    first.snapshotTimestamp -= 1;
    IPriceCapAdapter.PriceCapUpdateParams memory second = _nextParams(wstETH_CAPO, 4_90);
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(first));
    _publish(HUB, LIDO_ESPOKE, wstETH, abi.encode(second));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 2);
    _agentHub.execute(actions);
    _assertParams(wstETH_CAPO, first);
  }

  function test_check_rejectsV3SharedAdapter() public {
    vm.clearMockedCalls();
    assertEq(AaveV3Ethereum.ORACLE.getSourceOfAsset(wstETH), address(wstETH_CAPO));
    assertEq(AaveV3EthereumLido.ORACLE.getSourceOfAsset(wstETH), address(wstETH_CAPO));
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(_nextParams(wstETH_CAPO, 1_00)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_rejectsEtherFiOnlyAdapter() public {
    address weETH = AaveV3EthereumEtherFiAssets.weETH_UNDERLYING;
    IPriceCapAdapter etherFiCapo = IPriceCapAdapter(
      AaveV3EthereumEtherFi.ORACLE.getSourceOfAsset(weETH)
    );
    assertEq(address(etherFiCapo.ACL_MANAGER()), address(AaveV3Ethereum.ACL_MANAGER));
    assertTrue(AaveV3Ethereum.ORACLE.getSourceOfAsset(weETH) != address(etherFiCapo));
    vm.mockCall(
      ISpoke(MAIN_SPOKE).ORACLE(),
      abi.encodeCall(IAaveOracle.getReserveSource, (_reserveIdOf(HUB, MAIN_SPOKE, weETH))),
      abi.encode(address(etherFiCapo))
    );
    _agentHub.addAllowedMarket(_agentId, _marketId(HUB, MAIN_SPOKE, weETH));
    _publish(HUB, MAIN_SPOKE, weETH, abi.encode(_nextParams(etherFiCapo, 1_00)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);

    vm.mockCall(
      address(AaveV3EthereumEtherFi.ORACLE),
      abi.encodeWithSignature('getSourceOfAsset(address)', weETH),
      abi.encode(address(0))
    );
    (shouldRun, ) = _check();
    assertTrue(shouldRun);
  }

  function test_check_rejectsUntrustedHub() public {
    IPriceCapAdapter rethCapo = IPriceCapAdapter(
      AaveV3Ethereum.ORACLE.getSourceOfAsset(AaveV3EthereumAssets.rETH_UNDERLYING)
    );
    assertEq(address(rethCapo.ACL_MANAGER()), address(AaveV3Ethereum.ACL_MANAGER));
    address fake = address(new FakeV4(address(rethCapo)));
    _agentHub.addAllowedMarket(_agentId, _marketId(fake, fake, address(1)));
    _publish(fake, fake, address(1), abi.encode(_nextParams(rethCapo, 1_00)));

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_validate_rejectsSnapshotMayOverflowSoon() public {
    IPriceCapAdapter rsethCapo = IPriceCapAdapter(AaveV4EthereumFork.rsETH_CAPO);
    assertEq(
      _source(HUB, AaveV4EthereumFork.KELP_ESPOKE, AaveV4EthereumFork.rsETH),
      address(rsethCapo)
    );
    _detachFromV3(AaveV4EthereumFork.rsETH);
    _setAbsoluteRange('CapoSnapshotRatio');
    _setAbsoluteRange('CapoMaxYearlyGrowthRatePercent');

    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(rsethCapo, 0);
    params.snapshotRatio = 2.028e31;
    params.maxYearlyRatioGrowthPercent = 25_71;
    assertFalse(_validateRsEth(params));

    vm.prank(_agent);
    vm.expectRevert(
      abi.encodeWithSignature(
        'SnapshotMayOverflowSoon(uint104,uint16)',
        params.snapshotRatio,
        params.maxYearlyRatioGrowthPercent
      )
    );
    rsethCapo.setCapParameters(params);

    params.snapshotRatio = 1e30;
    assertTrue(_validateRsEth(params));
  }

  function test_fuzz_validateMatchesLegacyRsEthCapo(
    uint104 snapshotRatio,
    uint48 snapshotTimestamp,
    uint16 maxGrowth
  ) public {
    IPriceCapAdapter rsethCapo = IPriceCapAdapter(AaveV4EthereumFork.rsETH_CAPO);
    _detachFromV3(AaveV4EthereumFork.rsETH);
    _setAbsoluteRange('CapoSnapshotRatio');
    _setAbsoluteRange('CapoMaxYearlyGrowthRatePercent');

    IPriceCapAdapter.PriceCapUpdateParams memory params = IPriceCapAdapter.PriceCapUpdateParams({
      snapshotRatio: snapshotRatio,
      snapshotTimestamp: uint48(
        bound(snapshotTimestamp, rsethCapo.getSnapshotTimestamp() - 1, block.timestamp)
      ),
      maxYearlyRatioGrowthPercent: maxGrowth
    });
    bool valid = _validateRsEth(params);

    vm.prank(_agent);
    (bool accepted, ) = address(rsethCapo).call(
      abi.encodeCall(IPriceCapAdapter.setCapParameters, (params))
    );
    assertEq(valid, accepted);
  }

  function test_checkAndExecute_syrupUSDG() public {
    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(syrupUSDG_CAPO, 50);
    _publish(
      AaveV4EthereumFork.GLOBAL_DOLLAR_HUB,
      AaveV4EthereumFork.USDG_MAPLE_ESPOKE,
      AaveV4EthereumFork.syrupUSDG,
      abi.encode(params)
    );

    assertTrue(_checkAndExecute());
    _assertParams(syrupUSDG_CAPO, params);
    assertGt(
      _price(
        AaveV4EthereumFork.GLOBAL_DOLLAR_HUB,
        AaveV4EthereumFork.USDG_MAPLE_ESPOKE,
        AaveV4EthereumFork.syrupUSDG
      ),
      0
    );
  }

  function test_check_rejectsSnapshotOutsideAdapterWindow() public {
    vm.warp(
      syrupUSDG_CAPO.getSnapshotTimestamp() + syrupUSDG_CAPO.MAXIMUM_SNAPSHOT_TERM() + 10 days
    );
    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(syrupUSDG_CAPO, 0);
    params.snapshotTimestamp = uint48(block.timestamp - syrupUSDG_CAPO.MAXIMUM_SNAPSHOT_TERM() - 1);
    assertGt(params.snapshotTimestamp, syrupUSDG_CAPO.getSnapshotTimestamp());
    _publish(
      AaveV4EthereumFork.GLOBAL_DOLLAR_HUB,
      AaveV4EthereumFork.USDG_MAPLE_ESPOKE,
      AaveV4EthereumFork.syrupUSDG,
      abi.encode(params)
    );

    params = _nextParams(wstETH_CAPO, 0);
    params.snapshotTimestamp += 1;
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(params));

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_rejectsOutOfRange() public {
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(_nextParams(wstETH_CAPO, 5_01)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_skipsWithoutRiskAdmin() public {
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(_nextParams(wstETH_CAPO, 1_00)));
    _setRiskAdmin(_agent, false);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_execute_badMarketDoesNotBlockBatch() public {
    address wethMarket = _marketId(HUB, MAIN_SPOKE, AaveV4EthereumFork.WETH);
    _publish(HUB, MAIN_SPOKE, AaveV4EthereumFork.WETH, abi.encode(_nextParams(wstETH_CAPO, 0)));
    address unlistedMarket = _marketId(HUB, MAIN_SPOKE, address(0xdead));
    _agentHub.addAllowedMarket(_agentId, unlistedMarket);
    _publish(HUB, MAIN_SPOKE, address(0xdead), abi.encode(_nextParams(wstETH_CAPO, 0)));

    IPriceCapAdapter.PriceCapUpdateParams memory params = _nextParams(wstETH_CAPO, 1_00);
    _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(params));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);

    address[] memory markets = new address[](3);
    markets[0] = wethMarket;
    markets[1] = unlistedMarket;
    markets[2] = actions[0].markets[0];
    actions[0].markets = markets;
    _agentHub.execute(actions);
    _assertParams(wstETH_CAPO, params);
  }

  function test_fuzz_validateMatchesLegacyCapo(
    uint104 snapshotRatio,
    uint48 snapshotTimestamp,
    uint16 maxGrowth
  ) public {
    _setRange('CapoSnapshotRatio', 100_00);
    _setRange('CapoMaxYearlyGrowthRatePercent', 100_00);
    (bool hasTerm, ) = address(wstETH_CAPO).staticcall(
      abi.encodeCall(IPriceCapAdapter.MAXIMUM_SNAPSHOT_TERM, ())
    );
    assertFalse(hasTerm);

    IPriceCapAdapter.PriceCapUpdateParams memory params = IPriceCapAdapter.PriceCapUpdateParams({
      snapshotRatio: uint104(bound(snapshotRatio, 0, wstETH_CAPO.getSnapshotRatio() * 2)),
      snapshotTimestamp: uint48(
        bound(snapshotTimestamp, wstETH_CAPO.getSnapshotTimestamp() - 1, block.timestamp)
      ),
      maxYearlyRatioGrowthPercent: uint16(
        bound(maxGrowth, 0, wstETH_CAPO.getMaxYearlyGrowthRatePercent() * 2)
      )
    });
    bool valid = AaveV4CapoAgent(_agent).validate(
      _agentId,
      '',
      _publish(HUB, MAIN_SPOKE, wstETH, abi.encode(params))
    );

    vm.prank(_agent);
    (bool accepted, ) = address(wstETH_CAPO).call(
      abi.encodeCall(IPriceCapAdapter.setCapParameters, (params))
    );
    assertEq(valid, accepted);
  }

  function _nextParams(
    IPriceCapAdapter capo,
    uint256 ratioChangeBps
  ) internal view returns (IPriceCapAdapter.PriceCapUpdateParams memory) {
    return
      IPriceCapAdapter.PriceCapUpdateParams({
        snapshotRatio: uint104((capo.getSnapshotRatio() * (100_00 + ratioChangeBps)) / 100_00),
        snapshotTimestamp: uint48(block.timestamp - capo.MINIMUM_SNAPSHOT_DELAY()),
        maxYearlyRatioGrowthPercent: uint16(capo.getMaxYearlyGrowthRatePercent())
      });
  }

  function _assertParams(
    IPriceCapAdapter capo,
    IPriceCapAdapter.PriceCapUpdateParams memory params
  ) internal view {
    assertEq(capo.getSnapshotRatio(), params.snapshotRatio);
    assertEq(capo.getSnapshotTimestamp(), params.snapshotTimestamp);
    assertEq(capo.getMaxYearlyGrowthRatePercent(), params.maxYearlyRatioGrowthPercent);
  }

  function _countLogs(address emitter) internal returns (uint256 count) {
    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].emitter == emitter) count++;
    }
  }

  function _validateRsEth(
    IPriceCapAdapter.PriceCapUpdateParams memory params
  ) internal returns (bool) {
    return
      AaveV4CapoAgent(_agent).validate(
        _agentId,
        '',
        _publish(HUB, AaveV4EthereumFork.KELP_ESPOKE, AaveV4EthereumFork.rsETH, abi.encode(params))
      );
  }

  function _setAbsoluteRange(string memory updateType) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: type(uint120).max,
        maxDecrease: type(uint120).max,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function _setRange(string memory updateType, uint120 maxChange) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: maxChange,
        maxDecrease: maxChange,
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );
  }
}

contract AaveV4DiscountRateAgent_EthereumForkTest is AaveV4AdapterAgentForkTestBase {
  address internal constant HUB = AaveV4EthereumFork.GLOBAL_DOLLAR_HUB;
  address internal constant SPOKE = AaveV4EthereumFork.USDG_PENDLE_SPOKE;
  address internal constant PT = AaveV4EthereumFork.PT_USDG_24SEP2026;
  IPendlePriceCapAdapter internal constant ADAPTER =
    IPendlePriceCapAdapter(AaveV4EthereumFork.PT_USDG_24SEP2026_ADAPTER);
  uint120 internal constant MAX_CHANGE = 0.01e18;

  constructor() AaveV4ForkTestBase('PendleDiscountRateUpdate') {}

  function _deployAgent() internal override returns (address) {
    return
      address(
        new AaveV4DiscountRateAgent(
          address(_agentHub),
          address(_rangeValidationModule),
          '',
          address(AaveV3Ethereum.ACL_MANAGER),
          _hubs(),
          _v3Oracles()
        )
      );
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](2);
    markets[0] = _marketId(HUB, SPOKE, PT);
    markets[1] = _marketId(
      AaveV4EthereumFork.PLUS_HUB,
      AaveV4EthereumFork.ETHENA_CORRELATED_SPOKE,
      AaveV4EthereumFork.PT_USDe_7MAY2026
    );
  }

  function _postSetup() internal override {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      _updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: MAX_CHANGE,
        maxDecrease: MAX_CHANGE,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
    _setRiskAdmin(_agent, true);
  }

  function test_spokeOracleSources() public view {
    assertEq(_source(HUB, SPOKE, PT), address(ADAPTER));
    assertEq(
      _source(
        AaveV4EthereumFork.PLUS_HUB,
        AaveV4EthereumFork.ETHENA_CORRELATED_SPOKE,
        AaveV4EthereumFork.PT_USDe_7MAY2026
      ),
      AaveV4EthereumFork.PT_USDe_7MAY2026_ADAPTER
    );
    assertEq(address(ADAPTER.ACL_MANAGER()), address(AaveV3Ethereum.ACL_MANAGER));
    assertGt(ADAPTER.MATURITY(), block.timestamp);
    assertLt(
      IPendlePriceCapAdapter(AaveV4EthereumFork.PT_USDe_7MAY2026_ADAPTER).MATURITY(),
      block.timestamp
    );
  }

  function test_checkAndExecute() public {
    uint256 discountRate = ADAPTER.discountRatePerYear() + MAX_CHANGE / 2;
    uint256 priceBefore = _price(HUB, SPOKE, PT);
    _publish(HUB, SPOKE, PT, abi.encode(discountRate));

    assertTrue(_checkAndExecute());
    assertEq(ADAPTER.discountRatePerYear(), discountRate);
    uint256 priceAfter = _price(HUB, SPOKE, PT);
    assertGt(priceAfter, 0);
    assertLt(priceAfter, priceBefore);
  }

  function test_fuzz_validateMatchesLiveAdapter(uint64 discountRate, uint32 elapsed) public {
    vm.warp(block.timestamp + bound(elapsed, 0, 400 days));
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
    uint256 currentRate = ADAPTER.discountRatePerYear();
    discountRate = uint64(
      bound(discountRate, 0, uint256(ADAPTER.MAX_DISCOUNT_RATE_PER_YEAR()) * 3)
    );

    bool valid = AaveV4DiscountRateAgent(_agent).validate(
      _agentId,
      '',
      _publish(HUB, SPOKE, PT, abi.encode(uint256(discountRate)))
    );

    vm.prank(_agent);
    (bool accepted, ) = address(ADAPTER).call(
      abi.encodeCall(IPendlePriceCapAdapter.setDiscountRatePerYear, (discountRate))
    );
    assertEq(valid, accepted && discountRate != currentRate);
  }

  function test_check_rejectsOutOfRangeAndAboveMax() public {
    _publish(HUB, SPOKE, PT, abi.encode(ADAPTER.discountRatePerYear() + MAX_CHANGE + 1));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);

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
    _publish(HUB, SPOKE, PT, abi.encode(uint256(ADAPTER.MAX_DISCOUNT_RATE_PER_YEAR()) + 1));
    (shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_skipsWithoutRiskAdmin() public {
    _publish(HUB, SPOKE, PT, abi.encode(ADAPTER.discountRatePerYear() + 1));
    _setRiskAdmin(_agent, false);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_rejectsAfterMaturity() public {
    vm.warp(ADAPTER.MATURITY() + 1);
    _publish(HUB, SPOKE, PT, abi.encode(ADAPTER.discountRatePerYear() + 1));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_execute_expiredPtDoesNotBlockBatch() public {
    address expiredMarket = _marketId(
      AaveV4EthereumFork.PLUS_HUB,
      AaveV4EthereumFork.ETHENA_CORRELATED_SPOKE,
      AaveV4EthereumFork.PT_USDe_7MAY2026
    );
    _publish(
      AaveV4EthereumFork.PLUS_HUB,
      AaveV4EthereumFork.ETHENA_CORRELATED_SPOKE,
      AaveV4EthereumFork.PT_USDe_7MAY2026,
      abi.encode(uint256(0.04e18))
    );
    uint256 discountRate = ADAPTER.discountRatePerYear() - 1;
    _publish(HUB, SPOKE, PT, abi.encode(discountRate));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);

    address[] memory markets = new address[](2);
    markets[0] = expiredMarket;
    markets[1] = actions[0].markets[0];
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertEq(ADAPTER.discountRatePerYear(), discountRate);
  }
}
