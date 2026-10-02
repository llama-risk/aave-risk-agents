// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from 'forge-std/Test.sol';
import {TransparentUpgradeableProxy} from 'openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {AaveV3Base, AaveV3BaseAssets} from 'aave-address-book/AaveV3Base.sol';
import {ChainlinkBase} from 'aave-address-book/ChainlinkBase.sol';
import {IPriceCapAdapter} from 'aave-price-feeds/interfaces/IPriceCapAdapter.sol';
import {IChainlinkAggregator} from 'aave-price-feeds/interfaces/IChainlinkAggregator.sol';
import {RiskOracle} from 'chaos-agents/src/contracts/dependencies/RiskOracle.sol';
import {AgentHub, IAgentHub, IRiskOracle} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';
import {RangeValidationModule, IRangeValidationModule} from 'chaos-agents/src/contracts/modules/RangeValidationModule.sol';

import {BoundsAgent} from '../../src/contracts/agent/BoundsAgent.sol';
import {IBoundedRatioAdapter} from './mocks/IBoundedRatioAdapterG.sol';
import {BoundedRatioAdapterMock} from './mocks/BoundsAgentMocks.sol';

contract BoundsAgentFork_Test is Test {
  string internal constant UPDATE_TYPE = 'RatioLowerBoundUpdate';
  address internal constant RATIO_PROVIDER = ChainlinkBase.AAVE_SVR_WEETH__EETH_Exchange_Rate;

  AgentHub internal _agentHub;
  IRiskOracle internal _riskOracle;
  RangeValidationModule internal _rangeValidationModule;
  BoundsAgent internal _agent;
  BoundedRatioAdapterMock internal _adapter;
  uint256 internal _agentId;
  uint256 internal _ratio;

  address internal _riskOracleOwner = makeAddr('riskOracleOwner');
  address internal _seeder = makeAddr('seeder');

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('base'), 52044276);

    address[] memory senders = new address[](1);
    senders[0] = _riskOracleOwner;
    string[] memory updateTypes = new string[](1);
    updateTypes[0] = UPDATE_TYPE;
    vm.prank(_riskOracleOwner);
    _riskOracle = IRiskOracle(address(new RiskOracle('RiskOracle', senders, updateTypes)));

    _agentHub = AgentHub(
      address(
        new TransparentUpgradeableProxy(
          address(new AgentHub()),
          address(this),
          abi.encodeCall(AgentHub.initialize, (address(this)))
        )
      )
    );
    _rangeValidationModule = new RangeValidationModule();
    _agent = new BoundsAgent(address(_agentHub), address(_rangeValidationModule), '', 2 days);

    _ratio = uint256(IChainlinkAggregator(RATIO_PROVIDER).latestAnswer());
    _adapter = new BoundedRatioAdapterMock(
      IBoundedRatioAdapter.BoundedRatioAdapterParams({
        aclManager: AaveV3Base.ACL_MANAGER,
        baseAggregatorAddress: ChainlinkBase.AAVE_SVR_ETH__USD,
        ratioProviderAddress: RATIO_PROVIDER,
        pairDescription: 'weETH / eETH / USD Bounded',
        ratioDecimals: IChainlinkAggregator(RATIO_PROVIDER).decimals(),
        minimumSnapshotDelay: 7 days,
        maximumLowerBoundDuration: 3 days,
        priceCapParams: IPriceCapAdapter.PriceCapUpdateParams({
          snapshotRatio: uint104(_ratio),
          snapshotTimestamp: uint48(block.timestamp - 7 days),
          maxYearlyRatioGrowthPercent: 8_75
        })
      })
    );

    address[] memory markets = new address[](1);
    markets[0] = address(_adapter);
    _agentId = _agentHub.registerAgent(
      IAgentConfigurator.AgentRegistrationInput({
        agentAddress: address(_agent),
        riskOracle: address(_riskOracle),
        admin: address(this),
        agentContext: '',
        isAgentEnabled: true,
        isAgentPermissioned: false,
        isMarketsFromAgentEnabled: false,
        expirationPeriod: 1 hours,
        minimumDelay: 1 hours,
        updateType: UPDATE_TYPE,
        allowedMarkets: markets,
        restrictedMarkets: new address[](0),
        permissionedSenders: new address[](0)
      })
    );
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      _agent.LOWER_BOUND_RANGE_TYPE(),
      IRangeValidationModule.RangeConfig({
        maxIncrease: 1_00,
        maxDecrease: 1_00,
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );

    address[] memory assets = new address[](1);
    assets[0] = AaveV3BaseAssets.weETH_UNDERLYING;
    address[] memory sources = new address[](1);
    sources[0] = address(_adapter);
    vm.startPrank(AaveV3Base.ACL_ADMIN);
    AaveV3Base.ACL_MANAGER.addRiskAdmin(address(_agent));
    AaveV3Base.ACL_MANAGER.addRiskAdmin(_seeder);
    AaveV3Base.ORACLE.setAssetSources(assets, sources);
    vm.stopPrank();

    vm.prank(_seeder);
    _adapter.setLowerBound(uint104((_ratio * 99_00) / 100_00), uint48(block.timestamp + 1 days));
  }

  function _publish(uint256 lowerBound, uint256 expiration) internal {
    vm.prank(_riskOracleOwner);
    _riskOracle.publishRiskParameterUpdate(
      'referenceId',
      abi.encode(lowerBound, expiration),
      UPDATE_TYPE,
      address(_adapter),
      ''
    );
  }

  function _run() internal returns (bool) {
    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = _agentId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    if (shouldRun) _agentHub.execute(actions);
    return shouldRun;
  }

  function test_fork_lowerBoundFloorsAaveOraclePrice() public {
    uint256 lowerBound = (_ratio * 99_50) / 100_00;
    uint256 expiration = block.timestamp + 1 days;
    _publish(lowerBound, expiration);
    assertTrue(_run());

    (uint256 storedLowerBound, uint256 storedExpiration) = _adapter.getLowerBound();
    assertEq(storedLowerBound, lowerBound);
    assertEq(storedExpiration, expiration);

    uint256 price = AaveV3Base.ORACLE.getAssetPrice(AaveV3BaseAssets.weETH_UNDERLYING);
    vm.mockCall(
      RATIO_PROVIDER,
      abi.encodeCall(IChainlinkAggregator.latestAnswer, ()),
      abi.encode(int256(_ratio / 2))
    );
    uint256 flooredPrice = AaveV3Base.ORACLE.getAssetPrice(AaveV3BaseAssets.weETH_UNDERLYING);
    assertTrue(_adapter.isFloored());
    assertApproxEqRel(flooredPrice, (price * 99_50) / 100_00, 0.0001e18);
  }

  function test_fork_restoresPriceAfterRatioFailure() public {
    (uint256 seededLowerBound, ) = _adapter.getLowerBound();
    vm.warp(block.timestamp + 1 days);
    vm.mockCallRevert(RATIO_PROVIDER, abi.encodeCall(IChainlinkAggregator.latestAnswer, ()), '');
    assertEq(_adapter.latestAnswer(), 0);

    assertFalse(_agent.validate(_agentId, '', _latest(seededLowerBound + 1)));
    _publish(seededLowerBound, block.timestamp + 1 days);
    assertTrue(_run());
    assertEq(_adapter.getBoundedRatio(), seededLowerBound);
    assertGt(AaveV3Base.ORACLE.getAssetPrice(AaveV3BaseAssets.weETH_UNDERLYING), 0);
  }

  function test_fork_lostRoleSkipsUpdate() public {
    vm.prank(AaveV3Base.ACL_ADMIN);
    AaveV3Base.ACL_MANAGER.removeRiskAdmin(address(_agent));

    _publish((_ratio * 99_50) / 100_00, block.timestamp + 1 days);
    assertFalse(_run());
  }

  function _latest(uint256 lowerBound) internal returns (IRiskOracle.RiskParameterUpdate memory) {
    _publish(lowerBound, block.timestamp + 1 days);
    return _riskOracle.getLatestUpdateByParameterAndMarket(UPDATE_TYPE, address(_adapter));
  }
}
