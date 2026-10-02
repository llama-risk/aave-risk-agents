// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from 'forge-std/Test.sol';
import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';
import {RangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';

import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {IHubConfigurator} from '../../../src/contracts/dependencies/v4/IHubConfigurator.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {IAaveOracle} from '../../../src/contracts/dependencies/v4/IAaveOracle.sol';
import {IAssetInterestRateStrategy} from '../../../src/contracts/dependencies/v4/IAssetInterestRateStrategy.sol';
import {AaveV4ForkTestBase, AaveV4BaseFork} from './AaveV4ForkTestBase.sol';
import {AaveV4AgentHarness} from './mocks/AaveV4AgentHarness.sol';
import {AaveV4HubAgentHarness} from './mocks/AaveV4HubAgentHarness.sol';

contract BaseAaveV4Agent_BaseForkTest is AaveV4ForkTestBase('CollateralRiskUpdate') {
  address internal constant HUB = AaveV4BaseFork.EQUITIES_HUB;
  address internal constant SPOKE = AaveV4BaseFork.MAG7_SPOKE;

  AaveV4AgentHarness internal _harness;

  function _deployAgent() internal override returns (address) {
    _harness = new AaveV4AgentHarness(
      address(_agentHub),
      address(_rangeValidationModule),
      AaveV4BaseFork.SPOKE_CONFIGURATOR
    );
    return address(_harness);
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](2);
    markets[0] = _marketId(HUB, SPOKE, AaveV4BaseFork.AAPLc);
    markets[1] = _marketId(HUB, SPOKE, AaveV4BaseFork.NVDAc);
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
    _grantRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.updateCollateralRisk.selector,
      _agent
    );
  }

  function test_vendoredInterfaces_matchDeployment() public view {
    IHub hub = IHub(HUB);
    ISpoke spoke = ISpoke(SPOKE);
    uint256 assetId = hub.getAssetId(AaveV4BaseFork.AAPLc);
    uint256 reserveId = spoke.getReserveId(HUB, assetId);

    assertTrue(hub.isUnderlyingListed(AaveV4BaseFork.AAPLc));
    assertGt(hub.getAssetCount(), assetId);
    (address underlying, ) = hub.getAssetUnderlyingAndDecimals(assetId);
    assertEq(underlying, AaveV4BaseFork.AAPLc);
    assertTrue(hub.isSpokeListed(assetId, SPOKE));
    assertGt(hub.getSpokeCount(assetId), 0);
    hub.getSpokeAddress(assetId, 0);
    hub.getSpokeConfig(assetId, SPOKE);
    assertGt(hub.MAX_ALLOWED_SPOKE_CAP(), 0);

    ISpoke.Reserve memory reserve = spoke.getReserve(reserveId);
    assertEq(reserve.underlying, AaveV4BaseFork.AAPLc);
    assertEq(reserve.hub, HUB);
    assertEq(reserve.assetId, assetId);
    assertGt(spoke.getReserveCount(), reserveId);
    spoke.getReserveConfig(reserveId);
    spoke.getDynamicReserveConfig(reserveId, reserve.dynamicConfigKey);
    spoke.getLiquidationConfig();
    assertEq(spoke.ORACLE(), AaveV4BaseFork.MAG7_SPOKE_ORACLE);

    IAaveOracle oracle = IAaveOracle(spoke.ORACLE());
    assertEq(oracle.spoke(), SPOKE);
    assertEq(oracle.decimals(), 8);
    assertGt(oracle.getReservePrice(reserveId), 0);
    assertTrue(oracle.getReserveSource(reserveId) != address(0));

    IAssetInterestRateStrategy strategy = IAssetInterestRateStrategy(
      hub.getAssetConfig(assetId).irStrategy
    );
    assertEq(strategy.HUB(), HUB);
    strategy.getInterestRateData(assetId);
    strategy.getMaxDrawnRate(assetId);
    assertGt(strategy.MAX_ALLOWED_DRAWN_RATE(), 0);
    assertLt(strategy.MIN_OPTIMAL_RATIO(), strategy.MAX_OPTIMAL_RATIO());
  }

  function test_vendoredConfigurators_matchDeployment() public view {
    bytes4[4] memory hubSelectors = [
      IHubConfigurator.updateSpokeAddCap.selector,
      IHubConfigurator.updateSpokeDrawCap.selector,
      IHubConfigurator.updateSpokeCaps.selector,
      IHubConfigurator.updateInterestRateData.selector
    ];
    for (uint256 i = 0; i < hubSelectors.length; i++) {
      assertTrue(_hasSelector(AaveV4BaseFork.HUB_CONFIGURATOR, hubSelectors[i]));
    }

    bytes4[11] memory spokeSelectors = [
      ISpokeConfigurator.updatePaused.selector,
      ISpokeConfigurator.updateFrozen.selector,
      ISpokeConfigurator.updateCollateralRisk.selector,
      ISpokeConfigurator.addCollateralFactor.selector,
      ISpokeConfigurator.updateCollateralFactor.selector,
      ISpokeConfigurator.addMaxLiquidationBonus.selector,
      ISpokeConfigurator.updateMaxLiquidationBonus.selector,
      ISpokeConfigurator.addDynamicReserveConfig.selector,
      ISpokeConfigurator.updateDynamicReserveConfig.selector,
      ISpokeConfigurator.pauseReserve.selector,
      ISpokeConfigurator.freezeReserve.selector
    ];
    for (uint256 i = 0; i < spokeSelectors.length; i++) {
      assertTrue(_hasSelector(AaveV4BaseFork.SPOKE_CONFIGURATOR, spokeSelectors[i]));
    }
  }

  function test_resolvers() public view {
    (bool ok, uint256 assetId, uint256 reserveId) = _harness.reserveId(
      HUB,
      SPOKE,
      AaveV4BaseFork.AAPLc
    );
    assertTrue(ok);
    assertEq(assetId, IHub(HUB).getAssetId(AaveV4BaseFork.AAPLc));
    assertEq(reserveId, ISpoke(SPOKE).getReserveId(HUB, assetId));

    (ok, assetId) = _harness.assetId(HUB, AaveV4BaseFork.USDC);
    assertTrue(ok);
    assertEq(assetId, IHub(HUB).getAssetId(AaveV4BaseFork.USDC));

    (ok, ) = _harness.assetId(HUB, address(0xdead));
    assertFalse(ok);
    (ok, , ) = _harness.reserveId(HUB, address(0xdead), AaveV4BaseFork.AAPLc);
    assertFalse(ok);
    (ok, , ) = _harness.reserveId(SPOKE, SPOKE, AaveV4BaseFork.AAPLc);
    assertFalse(ok);
    (ok, , ) = _harness.reserveId(HUB, address(0), AaveV4BaseFork.AAPLc);
    assertFalse(ok);
  }

  function test_spokeAssetId_nonReserveSpokes() public view {
    uint256 usdcId = IHub(HUB).getAssetId(AaveV4BaseFork.USDC);
    address[2] memory spokes = [
      AaveV4BaseFork.USDC_TOKENIZATION_SPOKE,
      AaveV4BaseFork.TREASURY_SPOKE
    ];
    for (uint256 i = 0; i < spokes.length; i++) {
      (bool ok, uint256 assetId) = _harness.spokeAssetId(HUB, spokes[i], AaveV4BaseFork.USDC);
      assertTrue(ok);
      assertEq(assetId, usdcId);
      (ok, , ) = _harness.reserveId(HUB, spokes[i], AaveV4BaseFork.USDC);
      assertFalse(ok);
    }
    assertGt(IHub(HUB).getSpokeConfig(usdcId, AaveV4BaseFork.USDC_TOKENIZATION_SPOKE).addCap, 0);
    (bool listed, ) = _harness.spokeAssetId(HUB, SPOKE, address(0xdead));
    assertFalse(listed);
  }

  function test_canCallConfigurator() public view {
    assertTrue(_harness.canCallConfigurator(ISpokeConfigurator.updateCollateralRisk.selector));
    assertFalse(_harness.canCallConfigurator(bytes4(0xdeadbeef)));
  }

  function test_configuratorCanCall() public {
    bytes4[3] memory spokeSelectors = [
      ISpoke.updateReserveConfig.selector,
      ISpoke.addDynamicReserveConfig.selector,
      ISpoke.updateDynamicReserveConfig.selector
    ];
    for (uint256 i = 0; i < spokeSelectors.length; i++) {
      assertTrue(_harness.configuratorCanCall(SPOKE, spokeSelectors[i]));
    }
    assertFalse(_harness.configuratorCanCall(SPOKE, bytes4(0xdeadbeef)));
    assertFalse(_harness.configuratorCanCall(HUB, IHub.updateSpokeConfig.selector));

    AaveV4AgentHarness hubHarness = new AaveV4AgentHarness(
      address(_agentHub),
      address(_rangeValidationModule),
      AaveV4BaseFork.HUB_CONFIGURATOR
    );
    assertTrue(hubHarness.configuratorCanCall(HUB, IHub.updateSpokeConfig.selector));
    assertTrue(hubHarness.configuratorCanCall(HUB, IHub.setInterestRateData.selector));

    _closeTarget(SPOKE);
    for (uint256 i = 0; i < spokeSelectors.length; i++) {
      assertFalse(_harness.configuratorCanCall(SPOKE, spokeSelectors[i]));
    }
  }

  function test_readers_matchDeployment() public view {
    for (uint256 i = 0; i < 2; i++) {
      uint256 reserveId = _reserveIdOf(i == 0 ? AaveV4BaseFork.AAPLc : AaveV4BaseFork.NVDAc);
      (bool ok, ISpoke.ReserveConfig memory config) = _harness.reserveConfig(SPOKE, reserveId);
      assertTrue(ok);
      assertEq(abi.encode(config), abi.encode(ISpoke(SPOKE).getReserveConfig(reserveId)));

      uint32 key;
      ISpoke.DynamicReserveConfig memory dynamicConfig;
      (ok, key, dynamicConfig) = _harness.latestDynamicReserveConfig(SPOKE, reserveId);
      assertTrue(ok);
      assertEq(key, ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey);
      assertEq(
        abi.encode(dynamicConfig),
        abi.encode(ISpoke(SPOKE).getDynamicReserveConfig(reserveId, key))
      );
    }
    (bool unknown, ) = _harness.reserveConfig(SPOKE, type(uint256).max);
    assertFalse(unknown);
    (unknown, ) = _harness.dynamicConfigKey(SPOKE, type(uint256).max);
    assertFalse(unknown);
  }

  function test_grantRole_revertsOnUnmappedSelector() public {
    vm.expectRevert(bytes('selector not mapped'));
    this.grantRole(AaveV4BaseFork.SPOKE_CONFIGURATOR, bytes4(0xdeadbeef), address(1));
  }

  function grantRole(address target, bytes4 selector, address account) external {
    _grantRole(target, selector, account);
  }

  function test_checkAndExecute() public {
    uint256 reserveId = _reserveIdOf(AaveV4BaseFork.AAPLc);
    uint256 current = ISpoke(SPOKE).getReserveConfig(reserveId).collateralRisk;
    _publish(HUB, SPOKE, AaveV4BaseFork.AAPLc, abi.encode(current + 3_00));

    assertTrue(_checkAndExecute());
    assertEq(ISpoke(SPOKE).getReserveConfig(reserveId).collateralRisk, current + 3_00);
  }

  function test_check_rejectsOutOfRangeAndNoop() public {
    uint256 current = ISpoke(SPOKE)
      .getReserveConfig(_reserveIdOf(AaveV4BaseFork.AAPLc))
      .collateralRisk;
    _publish(HUB, SPOKE, AaveV4BaseFork.AAPLc, abi.encode(current + 5_01));
    _publish(
      HUB,
      SPOKE,
      AaveV4BaseFork.NVDAc,
      abi.encode(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AaveV4BaseFork.NVDAc)).collateralRisk)
    );
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_execute_badMarketDoesNotBlockBatch() public {
    address unlistedMarket = _marketId(HUB, SPOKE, address(0xdead));
    _agentHub.addAllowedMarket(_agentId, unlistedMarket);
    _publish(HUB, SPOKE, address(0xdead), abi.encode(uint256(1_00)));

    address mismatchedMarket = _marketId(HUB, SPOKE, AaveV4BaseFork.NVDAc);
    _publishRaw(
      mismatchedMarket,
      abi.encode(HUB, SPOKE, AaveV4BaseFork.AAPLc, abi.encode(uint256(1_00)))
    );

    uint256 reserveId = _reserveIdOf(AaveV4BaseFork.AAPLc);
    uint256 current = ISpoke(SPOKE).getReserveConfig(reserveId).collateralRisk;
    _publish(HUB, SPOKE, AaveV4BaseFork.AAPLc, abi.encode(current + 1_00));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _marketId(HUB, SPOKE, AaveV4BaseFork.AAPLc));

    address[] memory markets = new address[](3);
    markets[0] = unlistedMarket;
    markets[1] = mismatchedMarket;
    markets[2] = actions[0].markets[0];
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertEq(ISpoke(SPOKE).getReserveConfig(reserveId).collateralRisk, current + 1_00);
  }

  function test_check_skipsAfterRoleRevoked() public {
    uint256 current = ISpoke(SPOKE)
      .getReserveConfig(_reserveIdOf(AaveV4BaseFork.AAPLc))
      .collateralRisk;
    _publish(HUB, SPOKE, AaveV4BaseFork.AAPLc, abi.encode(current + 1_00));
    _revokeRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.updateCollateralRisk.selector,
      _agent
    );

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function _reserveIdOf(address asset) internal view returns (uint256) {
    return ISpoke(SPOKE).getReserveId(HUB, IHub(HUB).getAssetId(asset));
  }
}

contract BaseAaveV4Agent_EthereumForkTest is Test {
  uint256 internal constant BLOCK = 26100000;
  address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
  address internal constant PRIME_HUB = 0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931;
  address internal constant BLUECHIP_SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;
  address internal constant SPOKE_CONFIGURATOR = 0x9BFFf48BFb5A7AE70c348d4d4cb97E8DEFa5389a;
  address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

  AaveV4AgentHarness internal _harness;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('mainnet'), BLOCK);
    _harness = new AaveV4AgentHarness(
      address(this),
      address(new RangeValidationModule()),
      SPOKE_CONFIGURATOR
    );
  }

  function test_sameUnderlyingOnTwoHubs() public view {
    (bool coreOk, uint256 coreAssetId, uint256 coreReserveId) = _harness.reserveId(
      CORE_HUB,
      BLUECHIP_SPOKE,
      USDC
    );
    (bool primeOk, uint256 primeAssetId, uint256 primeReserveId) = _harness.reserveId(
      PRIME_HUB,
      BLUECHIP_SPOKE,
      USDC
    );
    assertTrue(coreOk && primeOk);
    assertTrue(coreReserveId != primeReserveId);
    assertEq(ISpoke(BLUECHIP_SPOKE).getReserve(coreReserveId).hub, CORE_HUB);
    assertEq(ISpoke(BLUECHIP_SPOKE).getReserve(primeReserveId).hub, PRIME_HUB);
    assertEq(ISpoke(BLUECHIP_SPOKE).getReserve(coreReserveId).assetId, coreAssetId);
    assertEq(ISpoke(BLUECHIP_SPOKE).getReserve(primeReserveId).assetId, primeAssetId);
    assertTrue(
      _harness.marketId(CORE_HUB, BLUECHIP_SPOKE, USDC) !=
        _harness.marketId(PRIME_HUB, BLUECHIP_SPOKE, USDC)
    );
  }
}

contract BaseAaveV4Agent_HubLevelBaseForkTest is AaveV4ForkTestBase('RateUpdate') {
  address internal constant HUB = AaveV4BaseFork.EQUITIES_HUB;
  address internal constant USDC = AaveV4BaseFork.USDC;

  function _deployAgent() internal override returns (address) {
    return
      address(
        new AaveV4HubAgentHarness(
          address(_agentHub),
          address(_rangeValidationModule),
          'RateUpdate',
          AaveV4BaseFork.HUB_CONFIGURATOR
        )
      );
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](2);
    markets[0] = _marketId(HUB, address(0), USDC);
    markets[1] = _marketId(HUB, AaveV4BaseFork.MAG7_SPOKE, USDC);
  }

  function _postSetup() internal override {
    _grantRole(
      AaveV4BaseFork.HUB_CONFIGURATOR,
      IHubConfigurator.updateInterestRateData.selector,
      _agent
    );
  }

  function test_checkAndExecute() public {
    uint256 assetId = IHub(HUB).getAssetId(USDC);
    IAssetInterestRateStrategy strategy = IAssetInterestRateStrategy(
      IHub(HUB).getAssetConfig(assetId).irStrategy
    );
    IAssetInterestRateStrategy.InterestRateData memory data = strategy.getInterestRateData(assetId);
    data.baseDrawnRate += 1;
    _publish(HUB, address(0), USDC, abi.encode(data));
    _publish(HUB, AaveV4BaseFork.MAG7_SPOKE, USDC, abi.encode(data));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _marketId(HUB, address(0), USDC));

    _agentHub.execute(actions);
    assertEq(abi.encode(strategy.getInterestRateData(assetId)), abi.encode(data));
  }
}
