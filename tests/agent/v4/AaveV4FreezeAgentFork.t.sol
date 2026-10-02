// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';

import {AaveV4FreezeAgent} from '../../../src/contracts/agent/v4/AaveV4FreezeAgent.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {IAaveOracle} from '../../../src/contracts/dependencies/v4/IAaveOracle.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {AaveV4ForkTestBase, AaveV4BaseFork} from './AaveV4ForkTestBase.sol';

interface ISpokeActions {
  struct UserAccountData {
    uint256 riskPremium;
    uint256 avgCollateralFactor;
    uint256 healthFactor;
    uint256 totalCollateralValue;
    uint256 totalDebtValueRay;
    uint256 activeCollateralCount;
    uint256 borrowCount;
  }

  struct UserPosition {
    uint120 drawnShares;
    uint120 premiumShares;
    int200 premiumOffsetRay;
    uint120 suppliedShares;
    uint32 dynamicConfigKey;
  }

  error ReserveFrozen();
  error HealthFactorBelowThreshold();
  error CannotReceiveShares();

  function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external;

  function borrow(uint256 reserveId, uint256 amount, address onBehalfOf) external;

  function liquidationCall(
    uint256 collateralReserveId,
    uint256 debtReserveId,
    address user,
    uint256 debtToCover,
    bool receiveShares
  ) external;

  function getUserAccountData(address user) external view returns (UserAccountData memory);

  function getUserPosition(
    uint256 reserveId,
    address user
  ) external view returns (UserPosition memory);
}

contract AaveV4FreezeAgent_BaseForkTest is AaveV4ForkTestBase('FreezeUpdate_MAG7') {
  address internal constant HUB = AaveV4BaseFork.EQUITIES_HUB;
  address internal constant SPOKE = AaveV4BaseFork.MAG7_SPOKE;
  address internal constant AAPLc = AaveV4BaseFork.AAPLc;
  address internal constant USDC = AaveV4BaseFork.USDC;
  address internal constant BORROWER = 0x4eD83dC70c9692bf9CD63a4a90a26Fe83b10DE2B;

  AaveV4FreezeAgent internal _freezeAgent;
  address internal _liquidator = makeAddr('liquidator');

  function _deployAgent() internal override returns (address) {
    _freezeAgent = new AaveV4FreezeAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      '_MAG7',
      AaveV4BaseFork.SPOKE_CONFIGURATOR
    );
    return address(_freezeAgent);
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](3);
    markets[0] = _marketId(HUB, SPOKE, AAPLc);
    markets[1] = _marketId(HUB, SPOKE, AaveV4BaseFork.NVDAc);
    markets[2] = _marketId(HUB, SPOKE, USDC);
  }

  function _postSetup() internal override {
    vm.setEvmVersion('cancun');
    _agentHub.setMinimumDelay(_agentId, 0);
    _grantRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.addCollateralFactor.selector,
      _agent
    );
    _grantRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.freezeReserve.selector,
      _agent
    );
  }

  function test_ltv0_addsZeroCollateralFactorKey() public {
    uint256 reserveId = _reserveIdOf(AAPLc);
    uint32 key = ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey;
    ISpoke.DynamicReserveConfig memory before = ISpoke(SPOKE).getDynamicReserveConfig(
      reserveId,
      key
    );
    assertGt(before.collateralFactor, 0);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    assertTrue(_checkAndExecute());

    assertEq(ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey, key + 1);
    ISpoke.DynamicReserveConfig memory latest = ISpoke(SPOKE).getDynamicReserveConfig(
      reserveId,
      key + 1
    );
    assertEq(latest.collateralFactor, 0);
    assertEq(latest.maxLiquidationBonus, before.maxLiquidationBonus);
    assertEq(latest.liquidationFee, before.liquidationFee);
    assertEq(
      ISpoke(SPOKE).getDynamicReserveConfig(reserveId, key).collateralFactor,
      before.collateralFactor
    );
    assertFalse(ISpoke(SPOKE).getReserveConfig(reserveId).frozen);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_ltv0_blocksNewBorrowsAndKeepsLiquidations() public {
    uint256 reserveId = _reserveIdOf(AAPLc);
    uint256 usdcReserveId = _reserveIdOf(USDC);
    ISpokeActions spoke = ISpokeActions(SPOKE);
    uint256 healthFactor = spoke.getUserAccountData(BORROWER).healthFactor;
    assertGt(healthFactor, 1e18);

    uint256 snapshot = vm.snapshotState();
    vm.prank(BORROWER);
    spoke.borrow(usdcReserveId, 1e6, BORROWER);
    vm.revertToState(snapshot);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    assertTrue(_checkAndExecute());

    assertEq(spoke.getUserAccountData(BORROWER).healthFactor, healthFactor);
    assertEq(spoke.getUserPosition(reserveId, BORROWER).dynamicConfigKey, 0);

    vm.prank(BORROWER);
    vm.expectRevert(ISpokeActions.HealthFactorBelowThreshold.selector);
    spoke.borrow(usdcReserveId, 1e6, BORROWER);

    _liquidate(reserveId, usdcReserveId, true);
  }

  function test_freeze_setsFrozenAndKeepsLiquidations() public {
    uint256 reserveId = _reserveIdOf(AAPLc);
    uint256 usdcReserveId = _reserveIdOf(USDC);
    uint32 key = ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey;

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(2)));
    assertTrue(_checkAndExecute());

    assertTrue(ISpoke(SPOKE).getReserveConfig(reserveId).frozen);
    assertEq(ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey, key + 1);
    assertEq(ISpoke(SPOKE).getDynamicReserveConfig(reserveId, key + 1).collateralFactor, 0);

    vm.prank(BORROWER);
    vm.expectRevert(ISpokeActions.ReserveFrozen.selector);
    ISpokeActions(SPOKE).supply(reserveId, 1, BORROWER);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(2)));
    (shouldRun, ) = _check();
    assertFalse(shouldRun);

    _liquidate(reserveId, usdcReserveId, false);
  }

  function test_ltv0ThenFreeze_addsOneKey() public {
    uint256 reserveId = _reserveIdOf(AAPLc);
    uint32 key = ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey;

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    assertTrue(_checkAndExecute());
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(2)));
    assertTrue(_checkAndExecute());

    assertTrue(ISpoke(SPOKE).getReserveConfig(reserveId).frozen);
    assertEq(ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey, key + 1);
  }

  function test_zeroCollateralFactorReserve_freezeOnly() public {
    uint256 reserveId = _reserveIdOf(USDC);
    uint32 key = ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey;
    assertEq(ISpoke(SPOKE).getDynamicReserveConfig(reserveId, key).collateralFactor, 0);

    IAgentHub.ActionData[] memory actions;
    bool shouldRun;
    _publish(HUB, SPOKE, USDC, abi.encode(uint256(1)));
    (shouldRun, ) = _check();
    assertFalse(shouldRun);

    _publish(HUB, SPOKE, USDC, abi.encode(uint256(2)));
    (shouldRun, actions) = _check();
    assertTrue(shouldRun);
    _agentHub.execute(actions);
    assertTrue(ISpoke(SPOKE).getReserveConfig(reserveId).frozen);
    assertEq(ISpoke(SPOKE).getReserve(reserveId).dynamicConfigKey, key);
  }

  function test_batch_skipsInvalidMarket() public {
    _publish(HUB, SPOKE, USDC, abi.encode(uint256(1)));
    _publish(HUB, SPOKE, AaveV4BaseFork.NVDAc, abi.encode(uint256(3)));
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(2)));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);
    assertEq(actions[0].markets[0], _marketId(HUB, SPOKE, AAPLc));

    actions[0].markets = _allowedMarkets();
    _agentHub.execute(actions);
    assertTrue(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AAPLc)).frozen);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(USDC)).frozen);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AaveV4BaseFork.NVDAc)).frozen);
  }

  function test_validate_falseWithoutRole() public {
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(2)));
    _revokeRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.freezeReserve.selector,
      _agent
    );
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_validate_falseForReserveNotOnSpoke() public {
    address spoke = AaveV4BaseFork.USDC_TOKENIZATION_SPOKE;
    address market = _marketId(HUB, spoke, AAPLc);
    _agentHub.addAllowedMarket(_agentId, market);
    _publish(HUB, spoke, AAPLc, abi.encode(uint256(2)));

    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
    assertFalse(
      _freezeAgent.validate(
        _agentId,
        '',
        _riskOracle.getLatestUpdateByParameterAndMarket(_updateType, market)
      )
    );
  }

  function test_agent_callsOnlyEscalationSelectors() public view {
    assertTrue(_hasSelector(_agent, ISpokeConfigurator.addCollateralFactor.selector));
    assertTrue(_hasSelector(_agent, ISpokeConfigurator.freezeReserve.selector));
    bytes4[7] memory forbidden = [
      ISpokeConfigurator.updateFrozen.selector,
      ISpokeConfigurator.updatePaused.selector,
      ISpokeConfigurator.updateCollateralFactor.selector,
      ISpokeConfigurator.addDynamicReserveConfig.selector,
      ISpokeConfigurator.updateDynamicReserveConfig.selector,
      ISpokeConfigurator.addMaxLiquidationBonus.selector,
      ISpokeConfigurator.updateMaxLiquidationBonus.selector
    ];
    for (uint256 i = 0; i < forbidden.length; i++) {
      assertFalse(_hasSelector(_agent, forbidden[i]));
    }
  }

  function _liquidate(
    uint256 collateralReserveId,
    uint256 debtReserveId,
    bool receiveShares
  ) internal {
    address oracle = ISpoke(SPOKE).ORACLE();
    uint256 price = IAaveOracle(oracle).getReservePrice(collateralReserveId);
    vm.mockCall(
      oracle,
      abi.encodeCall(IAaveOracle.getReservePrice, (collateralReserveId)),
      abi.encode(price / 2)
    );
    assertLt(ISpokeActions(SPOKE).getUserAccountData(BORROWER).healthFactor, 1e18);

    uint256 debtBefore = ISpokeActions(SPOKE).getUserAccountData(BORROWER).totalDebtValueRay;
    deal(USDC, _liquidator, 100e6);
    vm.startPrank(_liquidator);
    IERC20(USDC).approve(SPOKE, type(uint256).max);
    if (!receiveShares) {
      vm.expectRevert(ISpokeActions.CannotReceiveShares.selector);
      ISpokeActions(SPOKE).liquidationCall(
        collateralReserveId,
        debtReserveId,
        BORROWER,
        100e6,
        true
      );
      vm.mockCall(AAPLc, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));
    }
    ISpokeActions(SPOKE).liquidationCall(
      collateralReserveId,
      debtReserveId,
      BORROWER,
      100e6,
      receiveShares
    );
    vm.stopPrank();
    assertLt(ISpokeActions(SPOKE).getUserAccountData(BORROWER).totalDebtValueRay, debtBefore);
  }

  function _reserveIdOf(address asset) internal view returns (uint256) {
    return ISpoke(SPOKE).getReserveId(HUB, IHub(HUB).getAssetId(asset));
  }
}
