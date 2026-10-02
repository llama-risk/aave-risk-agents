// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';

import {AaveV4RatesAgent} from '../../../src/contracts/agent/v4/AaveV4RatesAgent.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {IHubConfigurator} from '../../../src/contracts/dependencies/v4/IHubConfigurator.sol';
import {IAssetInterestRateStrategy} from '../../../src/contracts/dependencies/v4/IAssetInterestRateStrategy.sol';
import {AaveV4ForkTestBase} from './AaveV4ForkTestBase.sol';

interface IAccessManagerAdmin {
  function getRoleMember(uint64 roleId, uint256 index) external view returns (address);

  function setTargetClosed(address target, bool closed) external;

  function setTargetFunctionRole(
    address target,
    bytes4[] calldata selectors,
    uint64 roleId
  ) external;
}

library AaveV4EthereumFork {
  uint256 internal constant BLOCK = 26100000;
  address internal constant ACCESS_MANAGER = 0x08aE3BE30958cDd1847ec58fFfd4C451a87fDF01;
  address internal constant HUB_CONFIGURATOR = 0x1F0753480bB03EaA00863224602267B7E0525C3d;
  address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
  address internal constant PRIME_HUB = 0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931;
  address internal constant BLUECHIP_SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;
  address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
}

contract AaveV4RatesAgent_EthereumForkTest is AaveV4ForkTestBase('RateStrategyUpdate') {
  address internal constant CORE_HUB = AaveV4EthereumFork.CORE_HUB;
  address internal constant PRIME_HUB = AaveV4EthereumFork.PRIME_HUB;
  address internal constant USDC = AaveV4EthereumFork.USDC;
  address internal constant WETH = AaveV4EthereumFork.WETH;

  function _createFork() internal override {
    vm.createSelectFork(vm.rpcUrl('mainnet'), AaveV4EthereumFork.BLOCK);
  }

  function _accessManager() internal pure override returns (address) {
    return AaveV4EthereumFork.ACCESS_MANAGER;
  }

  function _deployAgent() internal override returns (address) {
    return
      address(
        new AaveV4RatesAgent(
          address(_agentHub),
          address(_rangeValidationModule),
          '',
          AaveV4EthereumFork.HUB_CONFIGURATOR
        )
      );
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](3);
    markets[0] = _marketId(CORE_HUB, address(0), USDC);
    markets[1] = _marketId(CORE_HUB, address(0), WETH);
    markets[2] = _marketId(PRIME_HUB, address(0), USDC);
  }

  function _postSetup() internal override {
    _setRange('OptimalUsageRatio', 3_00);
    _setRange('BaseVariableBorrowRate', 50);
    _setRange('VariableRateSlope1', 1_00);
    _setRange('VariableRateSlope2', 20_00);
    _grantRole(
      AaveV4EthereumFork.HUB_CONFIGURATOR,
      IHubConfigurator.updateInterestRateData.selector,
      _agent
    );
  }

  function test_strategyMatchesVendoredInterface() public view {
    IAssetInterestRateStrategy strategy = _strategy(CORE_HUB, USDC);
    assertEq(strategy.HUB(), CORE_HUB);
    assertEq(strategy.MIN_OPTIMAL_RATIO(), 1_00);
    assertEq(strategy.MAX_OPTIMAL_RATIO(), 99_00);
    assertEq(strategy.MAX_ALLOWED_DRAWN_RATE(), 1000_00);
    assertGt(_current(CORE_HUB, USDC).optimalUsageRatio, 0);
  }

  function test_checkAndExecute() public {
    IAssetInterestRateStrategy.InterestRateData memory data = _current(CORE_HUB, USDC);
    data.optimalUsageRatio -= 2_00;
    data.baseDrawnRate += 50;
    data.rateGrowthBeforeOptimal += 1_00;
    data.rateGrowthAfterOptimal += 20_00;
    _publish(CORE_HUB, address(0), USDC, abi.encode(data));

    assertTrue(_checkAndExecute());
    assertEq(abi.encode(_current(CORE_HUB, USDC)), abi.encode(data));
    assertEq(
      _strategy(CORE_HUB, USDC).getMaxDrawnRate(_assetIdOf(CORE_HUB, USDC)),
      uint256(data.baseDrawnRate) + data.rateGrowthBeforeOptimal + data.rateGrowthAfterOptimal
    );
  }

  function test_execute_sameUnderlyingOnTwoHubs() public {
    IAssetInterestRateStrategy.InterestRateData memory core = _current(CORE_HUB, USDC);
    IAssetInterestRateStrategy.InterestRateData memory prime = _current(PRIME_HUB, USDC);
    IAssetInterestRateStrategy.InterestRateData memory weth = _current(CORE_HUB, WETH);
    core.rateGrowthBeforeOptimal += 25;
    prime.rateGrowthBeforeOptimal -= 25;
    weth.rateGrowthAfterOptimal += 5_00;
    _publish(CORE_HUB, address(0), USDC, abi.encode(core));
    _publish(PRIME_HUB, address(0), USDC, abi.encode(prime));
    _publish(CORE_HUB, address(0), WETH, abi.encode(weth));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 3);
    _agentHub.execute(actions);

    assertEq(abi.encode(_current(CORE_HUB, USDC)), abi.encode(core));
    assertEq(abi.encode(_current(PRIME_HUB, USDC)), abi.encode(prime));
    assertEq(abi.encode(_current(CORE_HUB, WETH)), abi.encode(weth));
  }

  function test_check_rejectsOutOfRangeAndNoop() public {
    IAssetInterestRateStrategy.InterestRateData memory data = _current(CORE_HUB, USDC);
    data.rateGrowthAfterOptimal += 20_01;
    _publish(CORE_HUB, address(0), USDC, abi.encode(data));
    _publish(CORE_HUB, address(0), WETH, abi.encode(_current(CORE_HUB, WETH)));

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_rejectsStrategyBounds() public {
    _setRange('OptimalUsageRatio', 100_00);
    _setRange('VariableRateSlope2', 1000_00);

    IAssetInterestRateStrategy.InterestRateData memory data = _current(CORE_HUB, USDC);
    data.optimalUsageRatio = 99_01;
    _publish(CORE_HUB, address(0), USDC, abi.encode(data));

    data = _current(PRIME_HUB, USDC);
    data.rateGrowthAfterOptimal =
      uint32(1000_00 + 1) -
      data.baseDrawnRate -
      data.rateGrowthBeforeOptimal;
    _publish(PRIME_HUB, address(0), USDC, abi.encode(data));

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);

    _publish(CORE_HUB, address(0), WETH, abi.encode(_withOptimal(_current(CORE_HUB, WETH), 99_00)));
    assertTrue(_checkAndExecute());
    assertEq(_current(CORE_HUB, WETH).optimalUsageRatio, 99_00);
  }

  function test_execute_badMarketsDoNotBlockBatch() public {
    address spokeMarket = _marketId(CORE_HUB, AaveV4EthereumFork.BLUECHIP_SPOKE, USDC);
    address unlistedMarket = _marketId(CORE_HUB, address(0), address(0xdead));
    _agentHub.addAllowedMarket(_agentId, spokeMarket);
    _agentHub.addAllowedMarket(_agentId, unlistedMarket);

    IAssetInterestRateStrategy.InterestRateData memory data = _current(CORE_HUB, USDC);
    data.baseDrawnRate += 25;
    _publish(CORE_HUB, AaveV4EthereumFork.BLUECHIP_SPOKE, USDC, abi.encode(data));
    _publish(CORE_HUB, address(0), address(0xdead), abi.encode(data));
    _publish(CORE_HUB, address(0), USDC, abi.encode(data));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _marketId(CORE_HUB, address(0), USDC));

    address[] memory markets = new address[](3);
    markets[0] = spokeMarket;
    markets[1] = unlistedMarket;
    markets[2] = actions[0].markets[0];
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertEq(abi.encode(_current(CORE_HUB, USDC)), abi.encode(data));
  }

  function test_check_skipsAfterRoleRevoked() public {
    IAssetInterestRateStrategy.InterestRateData memory data = _current(CORE_HUB, USDC);
    data.baseDrawnRate += 25;
    _publish(CORE_HUB, address(0), USDC, abi.encode(data));
    _revokeRole(
      AaveV4EthereumFork.HUB_CONFIGURATOR,
      IHubConfigurator.updateInterestRateData.selector,
      _agent
    );

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_execute_skipsHubWithRemappedRole() public {
    IAssetInterestRateStrategy.InterestRateData memory core = _current(CORE_HUB, USDC);
    IAssetInterestRateStrategy.InterestRateData memory prime = _current(PRIME_HUB, USDC);
    core.baseDrawnRate += 25;
    prime.baseDrawnRate += 25;
    _publish(CORE_HUB, address(0), USDC, abi.encode(core));
    _publish(PRIME_HUB, address(0), USDC, abi.encode(prime));
    bytes4[] memory selectors = new bytes4[](1);
    selectors[0] = IHub.setInterestRateData.selector;
    IAccessManagerAdmin accessManager = IAccessManagerAdmin(AaveV4EthereumFork.ACCESS_MANAGER);
    vm.prank(accessManager.getRoleMember(0, 0));
    accessManager.setTargetFunctionRole(CORE_HUB, selectors, 999);

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _marketId(PRIME_HUB, address(0), USDC));

    address[] memory markets = new address[](2);
    markets[0] = _marketId(CORE_HUB, address(0), USDC);
    markets[1] = actions[0].markets[0];
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertEq(abi.encode(_current(PRIME_HUB, USDC)), abi.encode(prime));
    assertEq(_current(CORE_HUB, USDC).baseDrawnRate, core.baseDrawnRate - 25);
  }

  function test_check_skipsClosedHub() public {
    IAssetInterestRateStrategy.InterestRateData memory data = _current(PRIME_HUB, USDC);
    data.baseDrawnRate += 25;
    _publish(PRIME_HUB, address(0), USDC, abi.encode(data));

    IAccessManagerAdmin accessManager = IAccessManagerAdmin(AaveV4EthereumFork.ACCESS_MANAGER);
    vm.prank(accessManager.getRoleMember(0, 0));
    accessManager.setTargetClosed(PRIME_HUB, true);

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
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

  function _withOptimal(
    IAssetInterestRateStrategy.InterestRateData memory data,
    uint16 optimalUsageRatio
  ) internal pure returns (IAssetInterestRateStrategy.InterestRateData memory) {
    data.optimalUsageRatio = optimalUsageRatio;
    return data;
  }

  function _assetIdOf(address hub, address asset) internal view returns (uint256) {
    return IHub(hub).getAssetId(asset);
  }

  function _strategy(
    address hub,
    address asset
  ) internal view returns (IAssetInterestRateStrategy) {
    return IAssetInterestRateStrategy(IHub(hub).getAssetConfig(_assetIdOf(hub, asset)).irStrategy);
  }

  function _current(
    address hub,
    address asset
  ) internal view returns (IAssetInterestRateStrategy.InterestRateData memory) {
    return _strategy(hub, asset).getInterestRateData(_assetIdOf(hub, asset));
  }
}
