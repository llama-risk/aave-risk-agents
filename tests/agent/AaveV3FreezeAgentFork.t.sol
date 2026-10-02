// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from 'forge-std/interfaces/IERC20.sol';
import {TransparentUpgradeableProxy} from 'openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IPool, IACLManager, IPoolConfigurator} from 'aave-address-book/AaveV3.sol';
import {MiscEthereum} from 'aave-address-book/MiscEthereum.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumLido, AaveV3EthereumLidoAssets} from 'aave-address-book/AaveV3EthereumLido.sol';
import {AaveV3EthereumHorizon, AaveV3EthereumHorizonAssets} from 'aave-address-book/AaveV3EthereumHorizon.sol';
import {DataTypes} from 'aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol';
import {ReserveConfiguration} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {EModeConfiguration} from 'aave-v3-origin/src/contracts/protocol/libraries/configuration/EModeConfiguration.sol';
import {RiskOracle} from 'chaos-agents/src/contracts/dependencies/RiskOracle.sol';
import {IRiskOracle} from 'chaos-agents/src/contracts/dependencies/IRiskOracle.sol';
import {AgentHub, IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IAgentConfigurator} from 'chaos-agents/src/interfaces/IAgentHub.sol';

import {AaveV3FreezeAgent} from '../../src/contracts/agent/AaveV3FreezeAgent.sol';
import {DeployV3FreezeAgent} from '../../scripts/AaveV3FreezeAgent.s.sol';

abstract contract AaveV3FreezeAgentForkBase is Test {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  string internal constant UPDATE_TYPE = 'ReserveFreezeUpdate';
  address internal constant RISK_ORACLE_OWNER = address(20);

  IPool internal _pool;
  address internal _asset;
  IRiskOracle internal _riskOracle;
  AgentHub internal _agentHub;
  AaveV3FreezeAgent internal _agent;
  uint256 internal _agentId;

  function _forkSetUp(uint256 blockNumber, IPool pool, address aclAdmin, address asset) internal {
    vm.createSelectFork(vm.rpcUrl('mainnet'), blockNumber);
    _pool = pool;
    _asset = asset;

    address[] memory senders = new address[](1);
    senders[0] = RISK_ORACLE_OWNER;
    string[] memory updateTypes = new string[](1);
    updateTypes[0] = UPDATE_TYPE;
    vm.prank(RISK_ORACLE_OWNER);
    _riskOracle = IRiskOracle(address(new RiskOracle('RiskOracle', senders, updateTypes)));

    _agentHub = AgentHub(
      address(
        new TransparentUpgradeableProxy(
          address(new AgentHub()),
          address(this),
          abi.encodeWithSelector(AgentHub.initialize.selector, address(this))
        )
      )
    );
    _agent = new AaveV3FreezeAgent(address(_agentHub), '', address(pool));

    address[] memory markets = new address[](1);
    markets[0] = asset;
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
        minimumDelay: 0,
        updateType: UPDATE_TYPE,
        allowedMarkets: markets,
        restrictedMarkets: new address[](0),
        permissionedSenders: new address[](0)
      })
    );

    IACLManager aclManager = IACLManager(pool.ADDRESSES_PROVIDER().getACLManager());
    vm.prank(aclAdmin);
    aclManager.addRiskAdmin(address(_agent));
  }

  function _publish(uint256 level) internal returns (uint256) {
    vm.prank(RISK_ORACLE_OWNER);
    _riskOracle.publishRiskParameterUpdate(
      'referenceId',
      abi.encode(level),
      UPDATE_TYPE,
      _asset,
      'reason'
    );
    return RiskOracle(address(_riskOracle)).updateCounter();
  }

  function _execute() internal returns (bool) {
    uint256[] memory agentIds = new uint256[](1);
    agentIds[0] = _agentId;
    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _agentHub.check(agentIds);
    if (shouldRun) _agentHub.execute(actions);
    return shouldRun;
  }

  function _config() internal view returns (DataTypes.ReserveConfigurationMap memory) {
    return _pool.getConfiguration(_asset);
  }

  function _collateralEModes() internal view returns (uint8[] memory ids) {
    uint256 reserveId = _pool.getReserveData(_asset).id;
    ids = new uint8[](type(uint8).max);
    uint256 count;
    for (uint256 i = 1; i <= type(uint8).max; i++) {
      if (
        EModeConfiguration.isReserveEnabledOnBitmap(
          _pool.getEModeCategoryCollateralBitmap(uint8(i)),
          reserveId
        )
      ) ids[count++] = uint8(i);
    }
    assembly {
      mstore(ids, count)
    }
  }
}

abstract contract AaveV3FreezeAgentV37ForkBase is AaveV3FreezeAgentForkBase {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  IPool internal immutable POOL;
  address internal immutable ACL_ADMIN;
  IPoolConfigurator internal immutable CONFIGURATOR;
  address internal immutable ASSET;
  uint256 internal immutable MIN_EMODES;

  constructor(
    IPool pool,
    address aclAdmin,
    IPoolConfigurator configurator,
    address asset,
    uint256 minEModes
  ) {
    POOL = pool;
    ACL_ADMIN = aclAdmin;
    CONFIGURATOR = configurator;
    ASSET = asset;
    MIN_EMODES = minEModes;
  }

  function setUp() public {
    _forkSetUp(26100000, POOL, ACL_ADMIN, ASSET);
  }

  function test_fork_configurator() public view {
    assertEq(address(_agent.POOL_CONFIGURATOR()), address(CONFIGURATOR));
  }

  function test_fork_ltv0ThenFreeze() public {
    uint8[] memory eModes = _collateralEModes();
    assertGe(eModes.length, MIN_EMODES);
    uint256 ltv = _config().getLtv();
    uint256 lt = _config().getLiquidationThreshold();
    uint256 lb = _config().getLiquidationBonus();
    uint256 pendingLtv = CONFIGURATOR.getPendingLtv(_asset);
    assertEq(_agent.getLevel(_asset), 0);

    _publish(1);
    uint256 gasBefore = gasleft();
    assertTrue(_execute());
    emit log_named_uint('ltv0 gas', gasBefore - gasleft());

    assertEq(_config().getLtv(), 0);
    assertEq(_config().getLiquidationThreshold(), lt);
    assertEq(_config().getLiquidationBonus(), lb);
    assertFalse(_config().getFrozen());
    assertEq(CONFIGURATOR.getPendingLtv(_asset), ltv == 0 ? pendingLtv : ltv);
    _assertEModesLtvzero(eModes);
    assertEq(_agent.getLevel(_asset), 1);

    _publish(1);
    assertFalse(_execute());

    _publish(2);
    gasBefore = gasleft();
    assertTrue(_execute());
    emit log_named_uint('freeze gas', gasBefore - gasleft());

    assertTrue(_config().getFrozen());
    assertEq(_config().getLiquidationThreshold(), lt);
    assertEq(_agent.getLevel(_asset), 2);

    _publish(1);
    assertFalse(_execute());
    _publish(2);
    assertFalse(_execute());
  }

  function test_fork_freeze() public {
    uint8[] memory eModes = _collateralEModes();
    _publish(2);
    uint256 gasBefore = gasleft();
    assertTrue(_execute());
    emit log_named_uint('freeze gas', gasBefore - gasleft());

    assertTrue(_config().getFrozen());
    assertEq(_config().getLtv(), 0);
    _assertEModesLtvzero(eModes);
    assertEq(_agent.getLevel(_asset), 2);
  }

  function test_fork_blocksNewBorrowPower() public {
    address user = makeAddr('user');
    deal(_asset, user, 10 ether);
    vm.startPrank(user);
    _pool.setUserEMode(_collateralEModes()[0]);
    (bool ok, ) = _asset.call(
      abi.encodeWithSignature('approve(address,uint256)', address(_pool), 10 ether)
    );
    assertTrue(ok);
    _pool.supply(_asset, 10 ether, user, 0);
    vm.stopPrank();

    (, , uint256 borrowsBefore, , , ) = _pool.getUserAccountData(user);
    assertGt(borrowsBefore, 0);

    _publish(1);
    assertTrue(_execute());

    (, , uint256 borrowsAfter, , , ) = _pool.getUserAccountData(user);
    assertEq(borrowsAfter, 0);
  }

  function _assertEModesLtvzero(uint8[] memory eModes) internal view {
    uint256 reserveId = _pool.getReserveData(_asset).id;
    for (uint256 i = 0; i < eModes.length; i++) {
      assertTrue(
        EModeConfiguration.isReserveEnabledOnBitmap(
          _pool.getEModeCategoryLtvzeroBitmap(eModes[i]),
          reserveId
        )
      );
    }
  }
}

contract AaveV3FreezeAgentCoreWeETHFork_Test is
  AaveV3FreezeAgentV37ForkBase(
    AaveV3Ethereum.POOL,
    AaveV3Ethereum.ACL_ADMIN,
    AaveV3Ethereum.POOL_CONFIGURATOR,
    AaveV3EthereumAssets.weETH_UNDERLYING,
    2
  )
{}

contract AaveV3FreezeAgentCoreSUSDeFork_Test is
  AaveV3FreezeAgentV37ForkBase(
    AaveV3Ethereum.POOL,
    AaveV3Ethereum.ACL_ADMIN,
    AaveV3Ethereum.POOL_CONFIGURATOR,
    AaveV3EthereumAssets.sUSDe_UNDERLYING,
    2
  )
{}

contract AaveV3FreezeAgentPrimeWstETHFork_Test is
  AaveV3FreezeAgentV37ForkBase(
    AaveV3EthereumLido.POOL,
    AaveV3EthereumLido.ACL_ADMIN,
    AaveV3EthereumLido.POOL_CONFIGURATOR,
    AaveV3EthereumLidoAssets.wstETH_UNDERLYING,
    1
  )
{}

contract AaveV3FreezeAgentHorizonFork_Test is AaveV3FreezeAgentForkBase {
  using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

  address internal constant USTB_SUPPLIER = 0x81286ac163aD542A9a9C9e4C42F181B003443A22;

  function setUp() public {
    _forkSetUp(
      26100000,
      AaveV3EthereumHorizon.POOL,
      AaveV3EthereumHorizon.ACL_ADMIN,
      AaveV3EthereumHorizonAssets.USTB_UNDERLYING
    );
  }

  function test_fork_configurator() public view {
    assertEq(address(_agent.POOL_CONFIGURATOR()), address(AaveV3EthereumHorizon.POOL_CONFIGURATOR));
  }

  function test_fork_ltv0Unsupported() public {
    uint256 id = _publish(1);
    assertFalse(_agent.validate(_agentId, '', _riskOracle.getUpdateById(id)));
    assertFalse(_execute());
    assertEq(_agent.getLevel(_asset), 0);
  }

  function test_fork_freeze() public {
    uint256 lt = _config().getLiquidationThreshold();
    _publish(2);
    assertTrue(_execute());

    assertTrue(_config().getFrozen());
    assertEq(_config().getLtv(), 0);
    assertEq(_config().getLiquidationThreshold(), lt);
    assertEq(_agent.getLevel(_asset), 2);

    _publish(2);
    assertFalse(_execute());
  }

  function test_fork_freezeBlocksEModeBorrowPower() public {
    uint8[] memory eModes = _collateralEModes();
    assertGt(eModes.length, 0);
    address user = USTB_SUPPLIER;
    assertGt(IERC20(AaveV3EthereumHorizonAssets.USTB_A_TOKEN).balanceOf(user), 0);
    vm.prank(user);
    _pool.setUserEMode(eModes[0]);

    (, , uint256 borrowsBefore, , , ) = _pool.getUserAccountData(user);
    assertGt(borrowsBefore, 0);

    _publish(2);
    assertTrue(_execute());

    (, , uint256 borrowsAfter, , , ) = _pool.getUserAccountData(user);
    assertEq(borrowsAfter, 0);
  }
}

contract AaveV3FreezeAgentDeployFork_Test is Test {
  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('mainnet'), 26100000);
  }

  function test_fork_deployScript() public {
    _check('_Core', address(AaveV3Ethereum.POOL), address(AaveV3Ethereum.POOL_CONFIGURATOR));
    _check(
      '_Prime',
      address(AaveV3EthereumLido.POOL),
      address(AaveV3EthereumLido.POOL_CONFIGURATOR)
    );
    _check(
      '_Horizon',
      address(AaveV3EthereumHorizon.POOL),
      address(AaveV3EthereumHorizon.POOL_CONFIGURATOR)
    );
  }

  function _check(string memory suffix, address pool, address configurator) internal {
    AaveV3FreezeAgent agent = AaveV3FreezeAgent(
      DeployV3FreezeAgent.deploy(MiscEthereum.AGENT_HUB, suffix, pool)
    );
    assertEq(agent.getUpdateType(), string.concat('ReserveFreezeUpdate', suffix));
    assertEq(address(agent.POOL()), pool);
    assertEq(address(agent.POOL_CONFIGURATOR()), configurator);
  }
}
