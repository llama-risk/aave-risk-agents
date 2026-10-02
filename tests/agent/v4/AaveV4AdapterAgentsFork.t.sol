// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Vm} from 'forge-std/Vm.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
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
  address internal constant GLOBAL_DOLLAR_HUB = 0x62d63197660c080236193CA60b70E49A08E90368;
  address internal constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
  address internal constant LIDO_ESPOKE = 0xe1900480ac69f0B296841Cd01cC37546d92F35Cd;
  address internal constant USDG_MAPLE_ESPOKE = 0x774b9655413c34809c1f1b16b654465A89EBE989;
  address internal constant USDG_PENDLE_SPOKE = 0x956d8e0A89cfa3744428C4641b5a53B56167a7f9;
  address internal constant ETHENA_CORRELATED_SPOKE = 0x58131E79531caB1d52301228d1f7b842F26B9649;
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address internal constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant syrupUSDG = 0x87b65C4aAFFA76881f9E96F3e7ED945ddFC3Cd7A;
  address internal constant PT_USDG_24SEP2026 = 0xc1906aeCf868749a2DeE203F59b904c0cf212140;
  address internal constant PT_USDe_7MAY2026 = 0xAeBf0Bb9f57E89260d57f31AF34eB58657d96Ce0;
  address internal constant wstETH_CAPO = 0xe1D97bF61901B075E9626c8A2340a7De385861Ef;
  address internal constant syrupUSDG_CAPO = 0x5A6FcB0ebc018b6FD94Fc5f5A9F0948d0D40f040;
  address internal constant PT_USDG_24SEP2026_ADAPTER = 0x89F6Eb404AbF19FE817426dD2E2E0F14D1a5712e;
  address internal constant PT_USDe_7MAY2026_ADAPTER = 0x0a72df02CE3E4185b6CEDf561f0AE651E9BeE235;
}

abstract contract AaveV4AdapterAgentForkTestBase is AaveV4ForkTestBase {
  function _createFork() internal override {
    vm.createSelectFork(vm.rpcUrl('mainnet'), AaveV4EthereumFork.BLOCK);
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
          address(AaveV3Ethereum.ACL_MANAGER)
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
          address(AaveV3Ethereum.ACL_MANAGER)
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
