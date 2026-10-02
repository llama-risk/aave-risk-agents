// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';

import {AaveV4DynamicConfigAgent} from '../../../src/contracts/agent/v4/AaveV4DynamicConfigAgent.sol';
import {IAccessManaged} from '../../../src/contracts/dependencies/v4/IAccessManaged.sol';
import {IAccessManager} from '../../../src/contracts/dependencies/v4/IAccessManager.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {AaveV4ForkTestBase, AaveV4BaseFork, IAccessManagerLike} from './AaveV4ForkTestBase.sol';

abstract contract AaveV4DynamicConfigAgentForkTestBase is AaveV4ForkTestBase {
  address internal constant HUB = AaveV4BaseFork.EQUITIES_HUB;
  address internal constant SPOKE = AaveV4BaseFork.MAG7_SPOKE;
  address internal constant CONFIGURATOR = AaveV4BaseFork.SPOKE_CONFIGURATOR;
  address internal constant AAPL = AaveV4BaseFork.AAPLc;
  address internal constant NVDA = AaveV4BaseFork.NVDAc;
  address internal constant USDC = AaveV4BaseFork.USDC;

  AaveV4DynamicConfigAgent.Mode internal _mode;
  AaveV4DynamicConfigAgent internal _dynamicAgent;

  constructor(
    string memory updateType,
    AaveV4DynamicConfigAgent.Mode mode
  ) AaveV4ForkTestBase(updateType) {
    _mode = mode;
  }

  function _deployAgent() internal override returns (address) {
    _dynamicAgent = new AaveV4DynamicConfigAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      CONFIGURATOR,
      _mode,
      '',
      8
    );
    return address(_dynamicAgent);
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](3);
    markets[0] = _marketId(HUB, SPOKE, AAPL);
    markets[1] = _marketId(HUB, SPOKE, NVDA);
    markets[2] = _marketId(HUB, SPOKE, USDC);
  }

  function _postSetup() internal override {
    _setRange('CollateralFactor', 1_00, 2_00);
    _setRange('MaxLiquidationBonus', 2_00, 1_00);
    address[3] memory assets = [AAPL, NVDA, USDC];
    for (uint256 i = 0; i < assets.length; i++) {
      _dynamicAgent.setBand(HUB, SPOKE, assets[i], AaveV4DynamicConfigAgent.Field.CF, 50_00, 85_00);
      _dynamicAgent.setBand(
        HUB,
        SPOKE,
        assets[i],
        AaveV4DynamicConfigAgent.Field.LB,
        101_00,
        112_00
      );
    }
    _grantRole(CONFIGURATOR, _agentSelector(), _agent);
  }

  function test_configuratorFunctionsMatchDeployment() public {
    bytes4[4] memory selectors = [
      ISpokeConfigurator.updateMaxLiquidationBonus.selector,
      ISpokeConfigurator.addCollateralFactor.selector,
      ISpokeConfigurator.addDynamicReserveConfig.selector,
      ISpokeConfigurator.updateFrozen.selector
    ];
    for (uint256 i = 0; i < selectors.length; i++) {
      assertTrue(_hasSelector(CONFIGURATOR, selectors[i]));
      _mappedRole(IAccessManagerLike(_accessManager()), CONFIGURATOR, selectors[i]);
    }

    address authority = IAccessManaged(SPOKE).authority();
    assertEq(authority, AaveV4BaseFork.ACCESS_MANAGER);
    bytes4[2] memory spokeSelectors = [
      ISpoke.updateDynamicReserveConfig.selector,
      ISpoke.addDynamicReserveConfig.selector
    ];
    for (uint256 i = 0; i < spokeSelectors.length; i++) {
      (bool allowed, uint32 delay) = IAccessManager(authority).canCall(
        CONFIGURATOR,
        SPOKE,
        spokeSelectors[i]
      );
      assertTrue(allowed);
      assertEq(delay, 0);
    }
  }

  function test_check_refusesFrozenReserve() public {
    _publish(HUB, SPOKE, AAPL, _validValue(AAPL));
    _assertShouldRun(true);
    _grantRole(CONFIGURATOR, ISpokeConfigurator.updateFrozen.selector, address(this));
    ISpokeConfigurator(CONFIGURATOR).updateFrozen(SPOKE, _reserveIdOf(AAPL), true);

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_refusesCfZeroLatestKey() public {
    _publish(HUB, SPOKE, AAPL, _validValue(AAPL));
    _assertShouldRun(true);
    _grantRole(CONFIGURATOR, ISpokeConfigurator.addCollateralFactor.selector, address(this));
    ISpokeConfigurator(CONFIGURATOR).addCollateralFactor(SPOKE, _reserveIdOf(AAPL), 0);

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_refusesNonCollateralReserve() public {
    assertEq(_latest(USDC).collateralFactor, 0);
    bytes memory value = _mode == AaveV4DynamicConfigAgent.Mode.PT
      ? abi.encode(uint256(60_00), uint256(106_00))
      : abi.encode(uint256(_mode == AaveV4DynamicConfigAgent.Mode.CF_ADD ? 60_00 : 106_00));
    _publish(HUB, SPOKE, USDC, value);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_check_refusesAfterRoleRevoked() public {
    _publish(HUB, SPOKE, AAPL, _validValue(AAPL));
    _assertShouldRun(true);
    _revokeRole(CONFIGURATOR, _agentSelector(), _agent);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_execute_badMarketDoesNotBlockBatch() public {
    address unlisted = _marketId(HUB, SPOKE, address(0xdead));
    _agentHub.addAllowedMarket(_agentId, unlisted);
    _publish(HUB, SPOKE, address(0xdead), _validValue(AAPL));
    _publish(HUB, SPOKE, AAPL, _validValue(AAPL));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    address[] memory markets = new address[](2);
    markets[0] = unlisted;
    markets[1] = _marketId(HUB, SPOKE, AAPL);
    actions[0].markets = markets;
    _agentHub.execute(actions);
    assertTrue(_lastInjected(AAPL));
  }

  function _validValue(address asset) internal view virtual returns (bytes memory);

  function _assertShouldRun(bool expected) internal view {
    (bool shouldRun, ) = _check();
    assertEq(shouldRun, expected);
  }

  function _agentSelector() internal view returns (bytes4) {
    if (_mode == AaveV4DynamicConfigAgent.Mode.LB_IN_PLACE) {
      return ISpokeConfigurator.updateMaxLiquidationBonus.selector;
    }
    if (_mode == AaveV4DynamicConfigAgent.Mode.CF_ADD) {
      return ISpokeConfigurator.addCollateralFactor.selector;
    }
    return ISpokeConfigurator.addDynamicReserveConfig.selector;
  }

  function _setRange(string memory rangeType, uint120 maxIncrease, uint120 maxDecrease) internal {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      rangeType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: maxIncrease,
        maxDecrease: maxDecrease,
        isIncreaseRelative: false,
        isDecreaseRelative: false
      })
    );
  }

  function _lastInjected(address asset) internal view returns (bool) {
    return _agentHub.getLastInjectedUpdate(_agentId, _marketId(HUB, SPOKE, asset)).id != 0;
  }

  function _reserveIdOf(address asset) internal view returns (uint256) {
    return ISpoke(SPOKE).getReserveId(HUB, IHub(HUB).getAssetId(asset));
  }

  function _lastKey(address asset) internal view returns (uint32) {
    return ISpoke(SPOKE).getReserve(_reserveIdOf(asset)).dynamicConfigKey;
  }

  function _key(
    address asset,
    uint32 key
  ) internal view returns (ISpoke.DynamicReserveConfig memory) {
    return ISpoke(SPOKE).getDynamicReserveConfig(_reserveIdOf(asset), key);
  }

  function _latest(address asset) internal view returns (ISpoke.DynamicReserveConfig memory) {
    return _key(asset, _lastKey(asset));
  }
}

contract AaveV4DynamicConfigAgentLB_BaseForkTest is
  AaveV4DynamicConfigAgentForkTestBase(
    'MaxLiquidationBonusUpdate',
    AaveV4DynamicConfigAgent.Mode.LB_IN_PLACE
  )
{
  function test_lb_raiseThenLower() public {
    uint32 current = _latest(AAPL).maxLiquidationBonus;
    _publish(HUB, SPOKE, AAPL, abi.encode(uint256(current + 1_50)));
    assertTrue(_checkAndExecute());
    assertEq(_latest(AAPL).maxLiquidationBonus, current + 1_50);
    assertEq(_lastKey(AAPL), 0);

    vm.warp(block.timestamp + 1 days);
    _publish(HUB, SPOKE, AAPL, abi.encode(uint256(current + 50)));
    assertTrue(_checkAndExecute());
    assertEq(_latest(AAPL).maxLiquidationBonus, current + 50);
  }

  function test_lb_updatesEveryLiveKeyAndSkipsCfZero() public {
    uint256 reserveId = _reserveIdOf(AAPL);
    ISpoke.DynamicReserveConfig memory base = _latest(AAPL);
    _grantRole(CONFIGURATOR, ISpokeConfigurator.addCollateralFactor.selector, address(this));
    ISpokeConfigurator(CONFIGURATOR).addCollateralFactor(SPOKE, reserveId, 0);
    ISpokeConfigurator(CONFIGURATOR).addCollateralFactor(
      SPOKE,
      reserveId,
      base.collateralFactor - 1_00
    );
    assertEq(_lastKey(AAPL), 2);

    uint256 lb = base.maxLiquidationBonus + 1_00;
    _publish(HUB, SPOKE, AAPL, abi.encode(lb));
    assertTrue(_checkAndExecute());

    assertEq(_key(AAPL, 0).maxLiquidationBonus, lb);
    assertEq(_key(AAPL, 1).maxLiquidationBonus, base.maxLiquidationBonus);
    assertEq(_key(AAPL, 1).collateralFactor, 0);
    assertEq(_key(AAPL, 2).maxLiquidationBonus, lb);
    assertEq(_key(AAPL, 0).collateralFactor, base.collateralFactor);
    assertEq(_key(AAPL, 0).liquidationFee, base.liquidationFee);
  }

  function test_lb_minLiveKeyLeavesOlderKeys() public {
    uint256 reserveId = _reserveIdOf(AAPL);
    ISpoke.DynamicReserveConfig memory base = _latest(AAPL);
    _grantRole(CONFIGURATOR, ISpokeConfigurator.addCollateralFactor.selector, address(this));
    ISpokeConfigurator(CONFIGURATOR).addCollateralFactor(
      SPOKE,
      reserveId,
      base.collateralFactor - 50
    );
    _dynamicAgent.setMinLiveKey(_agentId, HUB, SPOKE, AAPL, 1);

    uint256 lb = base.maxLiquidationBonus + 1_00;
    _publish(HUB, SPOKE, AAPL, abi.encode(lb));
    assertTrue(_checkAndExecute());
    assertEq(_key(AAPL, 0).maxLiquidationBonus, base.maxLiquidationBonus);
    assertEq(_key(AAPL, 1).maxLiquidationBonus, lb);
  }

  function test_lb_rejectsBandRangeAndNoop() public {
    uint32 current = _latest(AAPL).maxLiquidationBonus;
    _publish(HUB, SPOKE, AAPL, abi.encode(uint256(current + 2_01)));
    _publish(HUB, SPOKE, NVDA, abi.encode(uint256(_latest(NVDA).maxLiquidationBonus)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);

    _dynamicAgent.setBand(HUB, SPOKE, AAPL, AaveV4DynamicConfigAgent.Field.LB, 101_00, current);
    vm.warp(block.timestamp + 1);
    _publish(HUB, SPOKE, AAPL, abi.encode(uint256(current + 1_00)));
    (shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function _validValue(address asset) internal view override returns (bytes memory) {
    return abi.encode(uint256(_latest(asset).maxLiquidationBonus + 1_00));
  }
}

contract AaveV4DynamicConfigAgentCF_BaseForkTest is
  AaveV4DynamicConfigAgentForkTestBase(
    'CollateralFactorUpdate',
    AaveV4DynamicConfigAgent.Mode.CF_ADD
  )
{
  function test_cf_addsKeyAndKeepsOldKey() public {
    ISpoke.DynamicReserveConfig memory base = _latest(AAPL);
    uint256 cf = base.collateralFactor - 2_00;
    _publish(HUB, SPOKE, AAPL, abi.encode(cf));
    assertTrue(_checkAndExecute());

    assertEq(_lastKey(AAPL), 1);
    assertEq(_key(AAPL, 0).collateralFactor, base.collateralFactor);
    assertEq(_key(AAPL, 1).collateralFactor, cf);
    assertEq(_key(AAPL, 1).maxLiquidationBonus, base.maxLiquidationBonus);
    assertEq(_key(AAPL, 1).liquidationFee, base.liquidationFee);
  }

  function test_cf_rejectsBandAndRange() public {
    ISpoke.DynamicReserveConfig memory base = _latest(AAPL);
    _publish(HUB, SPOKE, AAPL, abi.encode(uint256(base.collateralFactor - 2_01)));
    _publish(HUB, SPOKE, NVDA, abi.encode(uint256(85_01)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function _validValue(address asset) internal view override returns (bytes memory) {
    return abi.encode(uint256(_latest(asset).collateralFactor - 1_00));
  }
}

contract AaveV4DynamicConfigAgentPT_BaseForkTest is
  AaveV4DynamicConfigAgentForkTestBase('PtDynamicConfigUpdate', AaveV4DynamicConfigAgent.Mode.PT)
{
  function test_pt_addsKeyWithBothFields() public {
    ISpoke.DynamicReserveConfig memory base = _latest(NVDA);
    uint256 cf = base.collateralFactor + 1_00;
    uint256 lb = base.maxLiquidationBonus + 50;
    _publish(HUB, SPOKE, NVDA, abi.encode(cf, lb));
    assertTrue(_checkAndExecute());

    assertEq(_lastKey(NVDA), 1);
    assertEq(_key(NVDA, 0).collateralFactor, base.collateralFactor);
    assertEq(_key(NVDA, 0).maxLiquidationBonus, base.maxLiquidationBonus);
    assertEq(_key(NVDA, 1).collateralFactor, cf);
    assertEq(_key(NVDA, 1).maxLiquidationBonus, lb);
    assertEq(_key(NVDA, 1).liquidationFee, base.liquidationFee);
  }

  function _validValue(address asset) internal view override returns (bytes memory) {
    ISpoke.DynamicReserveConfig memory base = _latest(asset);
    return abi.encode(uint256(base.collateralFactor - 1_00), uint256(base.maxLiquidationBonus));
  }
}
