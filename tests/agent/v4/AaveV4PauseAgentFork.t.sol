// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';

import {AaveV4PauseAgent} from '../../../src/contracts/agent/v4/AaveV4PauseAgent.sol';
import {IB20OracleRegistry} from '../../../src/contracts/dependencies/b20/IB20OracleRegistry.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {ISpoke} from '../../../src/contracts/dependencies/v4/ISpoke.sol';
import {ISpokeConfigurator} from '../../../src/contracts/dependencies/v4/ISpokeConfigurator.sol';
import {AaveV4ForkTestBase, AaveV4BaseFork} from './AaveV4ForkTestBase.sol';
import {B20TokenMock, BoundedPriceAdapterMock} from './mocks/AaveV4PauseMocks.sol';

interface IB20OracleRegistryAdmin {
  function PAUSER_ROLE() external view returns (bytes32);

  function hasRole(bytes32 role, address account) external view returns (bool);

  function setOraclePaused(address token, bool paused) external;
}

interface ISpokeSupply {
  function supply(uint256 reserveId, uint256 amount, address onBehalfOf) external;

  function liquidationCall(
    uint256 collateralReserveId,
    uint256 debtReserveId,
    address user,
    uint256 debtToCover,
    bool receiveShares
  ) external;
}

contract AaveV4PauseAgent_BaseForkTest is AaveV4ForkTestBase('ReservePause') {
  address internal constant HUB = AaveV4BaseFork.EQUITIES_HUB;
  address internal constant SPOKE = AaveV4BaseFork.MAG7_SPOKE;
  address internal constant AAPLc = AaveV4BaseFork.AAPLc;
  address internal constant NVDAc = AaveV4BaseFork.NVDAc;
  address internal constant ISSUER_REGISTRY = 0x3f3E8cf41cdd3b1D118c16471aB0113DfDDd5CaD;
  address internal constant ISSUER_PAUSER = 0x38467bE00970af18076fd08F6b4Cf38Ba91572B1;

  AaveV4PauseAgent internal _pauseAgent;

  function _deployAgent() internal override returns (address) {
    _pauseAgent = new AaveV4PauseAgent(
      address(_agentHub),
      address(_rangeValidationModule),
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISSUER_REGISTRY
    );
    return address(_pauseAgent);
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](2);
    markets[0] = _marketId(HUB, SPOKE, AAPLc);
    markets[1] = _marketId(HUB, SPOKE, NVDAc);
  }

  function _postSetup() internal override {
    _grantRole(AaveV4BaseFork.SPOKE_CONFIGURATOR, ISpokeConfigurator.pauseReserve.selector, _agent);
    _pauseAgent.setHubAgentId(_agentId);
  }

  function test_checkAndExecute_pausesReserve() public {
    uint256 reserveId = _reserveIdOf(AAPLc);
    assertFalse(ISpoke(SPOKE).getReserveConfig(reserveId).paused);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    assertTrue(_checkAndExecute());

    ISpoke.ReserveConfig memory config = ISpoke(SPOKE).getReserveConfig(reserveId);
    assertTrue(config.paused);
    assertFalse(config.frozen);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(NVDAc)).paused);

    address user = makeAddr('user');
    vm.setEvmVersion('cancun');
    vm.prank(user);
    vm.expectRevert(bytes4(keccak256('ReservePaused()')));
    ISpokeSupply(SPOKE).supply(reserveId, 1, user);

    vm.warp(block.timestamp + 2 days);
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_execute_badMarketDoesNotBlockBatch() public {
    address unlistedMarket = _marketId(HUB, SPOKE, address(0xdead));
    _agentHub.addAllowedMarket(_agentId, unlistedMarket);
    _publish(HUB, SPOKE, address(0xdead), abi.encode(uint256(1)));
    _publish(HUB, SPOKE, NVDAc, abi.encode(uint256(0)));
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 1);

    address[] memory markets = new address[](3);
    markets[0] = unlistedMarket;
    markets[1] = _marketId(HUB, SPOKE, NVDAc);
    markets[2] = _marketId(HUB, SPOKE, AAPLc);
    actions[0].markets = markets;
    _agentHub.execute(actions);

    assertTrue(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AAPLc)).paused);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(NVDAc)).paused);
  }

  function test_check_skipsAfterRoleRevoked() public {
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    _revokeRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.pauseReserve.selector,
      _agent
    );
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_issuerRegistry_abi() public {
    IB20OracleRegistryAdmin registry = IB20OracleRegistryAdmin(ISSUER_REGISTRY);
    assertTrue(registry.hasRole(registry.PAUSER_ROLE(), ISSUER_PAUSER));
    _etchB20(AAPLc);

    (uint256 multiplier, bool paused) = IB20OracleRegistry(ISSUER_REGISTRY).getOracleParams(AAPLc);
    assertEq(multiplier, 1e18);
    assertFalse(paused);

    vm.prank(ISSUER_PAUSER);
    registry.setOraclePaused(AAPLc, true);
    (, paused) = IB20OracleRegistry(ISSUER_REGISTRY).getOracleParams(AAPLc);
    assertTrue(paused);
  }

  function test_poke_pausesOnIssuerFlag() public {
    _etchB20(AAPLc);
    _pauseAgent.setIssuerPokeEnabled(HUB, SPOKE, AAPLc, true);

    vm.expectRevert(
      abi.encodeWithSelector(
        AaveV4PauseAgent.PokeConditionNotMet.selector,
        _marketId(HUB, SPOKE, AAPLc)
      )
    );
    _pauseAgent.poke(HUB, SPOKE, AAPLc);

    vm.prank(ISSUER_PAUSER);
    IB20OracleRegistryAdmin(ISSUER_REGISTRY).setOraclePaused(AAPLc, true);

    vm.prank(makeAddr('anyone'));
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
    assertTrue(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AAPLc)).paused);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(NVDAc)).paused);

    vm.expectRevert(
      abi.encodeWithSelector(
        AaveV4PauseAgent.ReserveAlreadyPaused.selector,
        _marketId(HUB, SPOKE, AAPLc)
      )
    );
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
  }

  function test_poke_disabledByDefault() public {
    _etchB20(AAPLc);
    vm.prank(ISSUER_PAUSER);
    IB20OracleRegistryAdmin(ISSUER_REGISTRY).setOraclePaused(AAPLc, true);

    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.PokeDisabled.selector, _marketId(HUB, SPOKE, AAPLc))
    );
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
  }

  function test_poke_revertsWithoutRole() public {
    _etchB20(AAPLc);
    _pauseAgent.setIssuerPokeEnabled(HUB, SPOKE, AAPLc, true);
    vm.prank(ISSUER_PAUSER);
    IB20OracleRegistryAdmin(ISSUER_REGISTRY).setOraclePaused(AAPLc, true);
    _revokeRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.pauseReserve.selector,
      _agent
    );

    vm.expectRevert();
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AAPLc)).paused);
  }

  function test_liquidation_blockedWhilePaused() public {
    uint256 aapl = _reserveIdOf(AAPLc);
    uint256 nvda = _reserveIdOf(NVDAc);
    address user = makeAddr('user');
    vm.setEvmVersion('cancun');

    vm.expectRevert(bytes4(keccak256('ReserveNotSupplied()')));
    ISpokeSupply(SPOKE).liquidationCall(aapl, nvda, user, 1, false);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    assertTrue(_checkAndExecute());

    vm.expectRevert(bytes4(keccak256('ReservePaused()')));
    ISpokeSupply(SPOKE).liquidationCall(aapl, nvda, user, 1, false);
    vm.expectRevert(bytes4(keccak256('ReservePaused()')));
    ISpokeSupply(SPOKE).liquidationCall(nvda, aapl, user, 1, false);
  }

  function test_staleUpdateDoesNotRepauseAfterGovernanceUnpause() public {
    uint256 reserveId = _reserveIdOf(AAPLc);
    _etchB20(AAPLc);
    _pauseAgent.setIssuerPokeEnabled(HUB, SPOKE, AAPLc, true);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    vm.warp(block.timestamp + 1 hours);
    vm.prank(ISSUER_PAUSER);
    IB20OracleRegistryAdmin(ISSUER_REGISTRY).setOraclePaused(AAPLc, true);
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
    assertTrue(ISpoke(SPOKE).getReserveConfig(reserveId).paused);

    vm.prank(ISSUER_PAUSER);
    IB20OracleRegistryAdmin(ISSUER_REGISTRY).setOraclePaused(AAPLc, false);
    address governance = makeAddr('governance');
    _grantRole(
      AaveV4BaseFork.SPOKE_CONFIGURATOR,
      ISpokeConfigurator.updatePaused.selector,
      governance
    );
    vm.prank(governance);
    ISpokeConfigurator(AaveV4BaseFork.SPOKE_CONFIGURATOR).updatePaused(SPOKE, reserveId, false);

    vm.warp(block.timestamp + 12 hours);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
    assertFalse(ISpoke(SPOKE).getReserveConfig(reserveId).paused);
  }

  function test_poke_followsHubAllowedMarkets() public {
    _etchB20(AAPLc);
    _pauseAgent.setIssuerPokeEnabled(HUB, SPOKE, AAPLc, true);
    vm.prank(ISSUER_PAUSER);
    IB20OracleRegistryAdmin(ISSUER_REGISTRY).setOraclePaused(AAPLc, true);
    address market = _marketId(HUB, SPOKE, AAPLc);
    _agentHub.removeAllowedMarket(_agentId, market);

    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.MarketNotAllowed.selector, market));
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AAPLc)).paused);
  }

  function test_check_skipsWhenSpokeClosed() public {
    _closeTarget(SPOKE);

    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    _publish(HUB, SPOKE, NVDAc, abi.encode(uint256(1)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_poke_pausesOnAdapterBreach() public {
    uint256 aapl = _reserveIdOf(AAPLc);
    uint256 nvda = _reserveIdOf(NVDAc);
    address market = _marketId(HUB, SPOKE, AAPLc);
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    _pauseAgent.setPriceAdapter(HUB, SPOKE, AAPLc, address(adapter));
    assertFalse(_pauseAgent.isIssuerPokeEnabled(market));

    vm.expectRevert(abi.encodeWithSelector(AaveV4PauseAgent.PokeConditionNotMet.selector, market));
    _pauseAgent.poke(HUB, SPOKE, AAPLc);

    adapter.setBreached(true);
    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(market, aapl, makeAddr('anyone'), false, true);
    vm.prank(makeAddr('anyone'));
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
    assertTrue(ISpoke(SPOKE).getReserveConfig(aapl).paused);
    assertFalse(ISpoke(SPOKE).getReserveConfig(nvda).paused);

    address user = makeAddr('user');
    vm.setEvmVersion('cancun');
    vm.expectRevert(bytes4(keccak256('ReservePaused()')));
    ISpokeSupply(SPOKE).liquidationCall(aapl, nvda, user, 1, false);

    vm.warp(block.timestamp + 2 days);
    _publish(HUB, SPOKE, AAPLc, abi.encode(uint256(1)));
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_poke_adapterBreachSkipsUnsetMarkets() public {
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _pauseAgent.setPriceAdapter(HUB, SPOKE, AAPLc, address(adapter));

    vm.expectRevert(
      abi.encodeWithSelector(AaveV4PauseAgent.PokeDisabled.selector, _marketId(HUB, SPOKE, NVDAc))
    );
    _pauseAgent.poke(HUB, SPOKE, NVDAc);
    assertFalse(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(NVDAc)).paused);
  }

  function test_poke_adapterBreachWithIssuerFlagEnabled() public {
    _etchB20(AAPLc);
    _pauseAgent.setIssuerPokeEnabled(HUB, SPOKE, AAPLc, true);
    BoundedPriceAdapterMock adapter = new BoundedPriceAdapterMock();
    adapter.setBreached(true);
    _pauseAgent.setPriceAdapter(HUB, SPOKE, AAPLc, address(adapter));

    vm.expectEmit(address(_pauseAgent));
    emit AaveV4PauseAgent.Poked(
      _marketId(HUB, SPOKE, AAPLc),
      _reserveIdOf(AAPLc),
      address(this),
      false,
      true
    );
    _pauseAgent.poke(HUB, SPOKE, AAPLc);
    assertTrue(ISpoke(SPOKE).getReserveConfig(_reserveIdOf(AAPLc)).paused);
  }

  function _etchB20(address token) internal {
    // B20 tokens are Base precompiles that a local fork cannot execute.
    vm.etch(token, address(new B20TokenMock()).code);
  }

  function _reserveIdOf(address asset) internal view returns (uint256) {
    return ISpoke(SPOKE).getReserveId(HUB, IHub(HUB).getAssetId(asset));
  }
}
