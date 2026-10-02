// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {TestnetProcedures} from 'aave-v3-origin/tests/utils/TestnetProcedures.sol';
import {IPool} from 'aave-v3-origin/src/contracts/interfaces/IPool.sol';
import {DataTypes} from 'aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {EModeConfiguration} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/EModeConfiguration.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {BaseAgentTest, IAgentConfigurator} from 'chaos-agents/tests/agent/BaseAgentTest.sol';

import {AaveV3FreezeAgent, BaseAaveAgent} from '../../src/contracts/agent/AaveV3FreezeAgent.sol';

contract AaveV3FreezeAgent_Test is BaseAgentTest('ReserveFreezeUpdate'), TestnetProcedures {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  AaveV3FreezeAgent internal _freezeAgent;
  uint256 internal _updateCount;

  function setUp() public override {
    initTestEnvironment();
    super.setUp();
  }

  function _customiseAgentConfig(
    IAgentConfigurator.AgentRegistrationInput memory config
  ) internal view override returns (IAgentConfigurator.AgentRegistrationInput memory) {
    address[] memory markets = new address[](3);
    markets[0] = address(weth);
    markets[1] = address(usdx);
    markets[2] = address(wbtc);
    config.isMarketsFromAgentEnabled = false;
    config.allowedMarkets = markets;
    config.minimumDelay = 0;
    config.expirationPeriod = 1 hours;
    return config;
  }

  function _deployAgent() internal override returns (address) {
    _freezeAgent = new AaveV3FreezeAgent(address(_agentHub), '', address(contracts.poolProxy));
    return address(_freezeAgent);
  }

  function _postSetup() internal override {
    vm.startPrank(poolAdmin);
    contracts.aclManager.addRiskAdmin(address(_agent));
    _setEMode(1, address(weth), true);
    _setEMode(2, address(weth), true);
    _setEMode(3, address(weth), false);
    vm.stopPrank();
  }

  function test_constructor() public view {
    assertEq(address(_freezeAgent.POOL()), address(contracts.poolProxy));
    assertEq(address(_freezeAgent.POOL_CONFIGURATOR()), address(contracts.poolConfiguratorProxy));
    assertEq(address(_freezeAgent.RANGE_VALIDATION_MODULE()), address(0));
    assertEq(_freezeAgent.getUpdateType(), 'ReserveFreezeUpdate');
    assertEq(_freezeAgent.getLevel(address(weth)), 0);
  }

  function test_validate_invalidLevel() public {
    _publish(address(weth), abi.encode(uint256(0)));
    _publish(address(weth), abi.encode(uint256(3)));
    _publish(address(weth), abi.encode(type(uint256).max));
    for (uint256 i = 1; i <= 3; i++) {
      assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(i)));
    }
  }

  function test_validate_invalidLength() public {
    _publish(address(weth), '');
    _publish(address(weth), abi.encodePacked(uint256(1), uint8(0)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
  }

  function test_validate_packedLevel() public {
    _publish(address(weth), abi.encodePacked(uint8(1)));
    assertTrue(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
  }

  function test_validate_unlistedMarket() public {
    _publish(address(0xdead), abi.encode(uint256(1)));
    _publish(address(0xdead), abi.encode(uint256(2)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
  }

  function test_validate_escalation() public {
    _publish(address(weth), abi.encode(uint256(1)));
    _publish(address(weth), abi.encode(uint256(2)));
    assertTrue(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
    assertTrue(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
  }

  function test_injection_ltv0() public {
    uint256 ltv = _config(address(weth)).getLtv();
    uint256 lt = _config(address(weth)).getLiquidationThreshold();
    assertGt(ltv, 0);

    _publish(address(weth), abi.encode(uint256(1)));
    assertTrue(_checkAndPerformAutomation(_agentId));

    DataTypes.ReserveConfigurationMap memory config = _config(address(weth));
    assertEq(config.getLtv(), 0);
    assertEq(config.getLiquidationThreshold(), lt);
    assertFalse(config.getFrozen());
    assertEq(contracts.poolConfiguratorProxy.getPendingLtv(address(weth)), ltv);
    assertTrue(_isLtvzeroInEMode(1, address(weth)));
    assertTrue(_isLtvzeroInEMode(2, address(weth)));
    assertFalse(_isLtvzeroInEMode(3, address(weth)));
    assertEq(_freezeAgent.getLevel(address(weth)), 1);
  }

  function test_injection_freeze() public {
    _publish(address(weth), abi.encode(uint256(2)));
    assertTrue(_checkAndPerformAutomation(_agentId));

    DataTypes.ReserveConfigurationMap memory config = _config(address(weth));
    assertTrue(config.getFrozen());
    assertEq(config.getLtv(), 0);
    assertTrue(_isLtvzeroInEMode(1, address(weth)));
    assertTrue(_isLtvzeroInEMode(2, address(weth)));
    assertEq(_freezeAgent.getLevel(address(weth)), 2);
  }

  function test_injection_ltv0ThenFreeze() public {
    _publish(address(weth), abi.encode(uint256(1)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    _publish(address(weth), abi.encode(uint256(2)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertTrue(_config(address(weth)).getFrozen());
    assertEq(_freezeAgent.getLevel(address(weth)), 2);
  }

  function test_validate_noDeescalation() public {
    _publish(address(weth), abi.encode(uint256(2)));
    assertTrue(_checkAndPerformAutomation(_agentId));

    _publish(address(weth), abi.encode(uint256(1)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
    _publish(address(weth), abi.encode(uint256(2)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(3)));
    assertFalse(_checkAndPerformAutomation(_agentId));
  }

  function test_validate_ltv0AlreadyApplied() public {
    _publish(address(weth), abi.encode(uint256(1)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    _publish(address(weth), abi.encode(uint256(1)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
  }

  function test_injection_ltv0CompletesPartialState() public {
    vm.prank(poolAdmin);
    contracts.poolConfiguratorProxy.setReserveLtvzero(address(weth), true);
    assertEq(_freezeAgent.getLevel(address(weth)), 0);

    _publish(address(weth), abi.encode(uint256(1)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertTrue(_isLtvzeroInEMode(1, address(weth)));
    assertTrue(_isLtvzeroInEMode(2, address(weth)));
    assertEq(_freezeAgent.getLevel(address(weth)), 1);
  }

  function test_validate_ltv0NoCollateral() public {
    vm.prank(poolAdmin);
    contracts.poolConfiguratorProxy.setReserveLtvzero(address(usdx), true);
    assertEq(_freezeAgent.getLevel(address(usdx)), 1);

    _publish(address(usdx), abi.encode(uint256(1)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
    _publish(address(usdx), abi.encode(uint256(2)));
    assertTrue(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
  }

  function test_validate_frozenByOthers() public {
    vm.prank(poolAdmin);
    contracts.poolConfiguratorProxy.setReserveFreeze(address(weth), true);

    _publish(address(weth), abi.encode(uint256(1)));
    _publish(address(weth), abi.encode(uint256(2)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
  }

  function test_validate_ltv0UnsupportedPool() public {
    vm.mockCallRevert(
      address(contracts.poolProxy),
      abi.encodeWithSelector(IPool.getEModeCategoryLtvzeroBitmap.selector),
      ''
    );
    _publish(address(weth), abi.encode(uint256(1)));
    _publish(address(weth), abi.encode(uint256(2)));
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(1)));
    assertTrue(_agent.validate(_agentId, '', _riskOracle.getUpdateById(2)));
    assertEq(_freezeAgent.getLevel(address(weth)), 0);
  }

  function test_inject_revertsOnInvalidUpdate() public {
    _publish(address(weth), abi.encode(uint256(3)));
    IRiskOracle.RiskParameterUpdate memory update = _riskOracle.getUpdateById(1);

    vm.prank(address(_agentHub));
    vm.expectRevert(AaveV3FreezeAgent.InvalidUpdate.selector);
    _agent.inject(_agentId, '', update);
  }

  function test_inject_revertsWhenStateChanged() public {
    _publish(address(weth), abi.encode(uint256(1)));
    IRiskOracle.RiskParameterUpdate memory update = _riskOracle.getUpdateById(1);

    vm.prank(poolAdmin);
    contracts.poolConfiguratorProxy.setReserveFreeze(address(weth), true);

    vm.prank(address(_agentHub));
    vm.expectRevert(AaveV3FreezeAgent.InvalidUpdate.selector);
    _agent.inject(_agentId, '', update);
  }

  function test_injection_skipsInvalidMarketInBatch() public {
    vm.prank(poolAdmin);
    contracts.poolConfiguratorProxy.setReserveFreeze(address(usdx), true);

    _publish(address(usdx), abi.encode(uint256(2)));
    _publish(address(weth), abi.encode(uint256(2)));
    assertTrue(_checkAndPerformAutomation(_agentId));
    assertTrue(_config(address(weth)).getFrozen());
  }

  function test_invalidUpdateTypeOnAgentContract() public {
    address agentWithInvalidUpdateType = address(
      new AaveV3FreezeAgent(address(_agentHub), 'wrong', address(contracts.poolProxy))
    );
    vm.etch(address(_agent), agentWithInvalidUpdateType.code);

    _publish(address(weth), abi.encode(uint256(1)));
    vm.expectRevert(abi.encodeWithSelector(BaseAaveAgent.InvalidUpdateType.selector, _updateType));
    _checkAndPerformAutomation(_agentId);
  }

  function test_gas_allEModes() public {
    vm.startPrank(poolAdmin);
    for (uint256 i = 4; i <= type(uint8).max; i++) {
      _setEMode(uint8(i), address(weth), true);
    }
    vm.stopPrank();

    _publish(address(weth), abi.encode(uint256(1)));
    uint256 gasBefore = gasleft();
    assertTrue(_checkAndPerformAutomation(_agentId));
    uint256 ltv0Gas = gasBefore - gasleft();
    for (uint256 i = 1; i <= type(uint8).max; i++) {
      assertEq(_isLtvzeroInEMode(uint8(i), address(weth)), i != 3);
    }

    _publish(address(weth), abi.encode(uint256(2)));
    gasBefore = gasleft();
    assertTrue(_checkAndPerformAutomation(_agentId));
    uint256 freezeGas = gasBefore - gasleft();

    emit log_named_uint('ltv0 gas', ltv0Gas);
    emit log_named_uint('freeze gas', freezeGas);
    assertLt(ltv0Gas, 15_000_000);
    assertLt(freezeGas, 15_000_000);
  }

  function testFuzz_levelNeverDecreases(uint8[4] memory levels) public {
    uint256 maxLevel;
    for (uint256 i = 0; i < levels.length; i++) {
      uint256 level = levels[i] % 4;
      uint256 before = _freezeAgent.getLevel(address(weth));
      _publish(address(weth), abi.encode(level));
      bool valid = _agent.validate(_agentId, '', _riskOracle.getUpdateById(_updateCount));
      assertEq(valid, level > before && level <= 2);
      _checkAndPerformAutomation(_agentId);
      uint256 current = _freezeAgent.getLevel(address(weth));
      assertGe(current, before);
      if (valid) maxLevel = level;
      assertEq(current, maxLevel);
    }
  }

  function _publish(address market, bytes memory value) internal {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate('referenceId', value, _updateType, market, 'reason');
    _updateCount++;
  }

  function _setEMode(uint8 id, address asset, bool collateral) internal {
    contracts.poolConfiguratorProxy.setEModeCategory(id, 80_00, 85_00, 105_00, 'eMode', false);
    if (collateral) {
      contracts.poolConfiguratorProxy.setAssetCollateralInEMode(asset, id, true);
    } else {
      contracts.poolConfiguratorProxy.setAssetBorrowableInEMode(asset, id, true);
    }
  }

  function _config(address asset) internal view returns (DataTypes.ReserveConfigurationMap memory) {
    return contracts.poolProxy.getConfiguration(asset);
  }

  function _isLtvzeroInEMode(uint8 id, address asset) internal view returns (bool) {
    return
      EModeConfiguration.isReserveEnabledOnBitmap(
        contracts.poolProxy.getEModeCategoryLtvzeroBitmap(id),
        contracts.poolProxy.getReserveData(asset).id
      );
  }
}
