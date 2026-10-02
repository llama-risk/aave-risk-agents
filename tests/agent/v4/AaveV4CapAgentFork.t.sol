// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IAgentHub} from 'chaos-agents/src/contracts/AgentHub.sol';
import {IRangeValidationModule} from 'chaos-agents/src/interfaces/IRangeValidationModule.sol';

import {AaveV4CapAgent} from '../../../src/contracts/agent/v4/AaveV4CapAgent.sol';
import {IHub} from '../../../src/contracts/dependencies/v4/IHub.sol';
import {IHubConfigurator} from '../../../src/contracts/dependencies/v4/IHubConfigurator.sol';
import {AaveV4ForkTestBase, AaveV4BaseFork} from './AaveV4ForkTestBase.sol';

library AaveV4EthereumFork {
  uint256 internal constant BLOCK = 26100000;
  address internal constant ACCESS_MANAGER = 0x08aE3BE30958cDd1847ec58fFfd4C451a87fDF01;
  address internal constant HUB_CONFIGURATOR = 0x1F0753480bB03EaA00863224602267B7E0525C3d;
  address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;
  address internal constant PRIME_HUB = 0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931;
  address internal constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
  address internal constant BLUECHIP_SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;
  address internal constant FOREX_SPOKE = 0xD8B93635b8C6d0fF98CbE90b5988E3F2d1Cd9da1;
  address internal constant TREASURY_SPOKE = 0xB9B0b8616f6Bf6841972a52058132BE08d723155;
  address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
}

abstract contract AaveV4CapAgentForkTestBase is AaveV4ForkTestBase {
  AaveV4CapAgent.CapKind internal _kind;

  constructor(
    AaveV4CapAgent.CapKind kind,
    string memory updateType
  ) AaveV4ForkTestBase(updateType) {
    _kind = kind;
  }

  function _hubConfigurator() internal view virtual returns (address);

  function _deployAgent() internal override returns (address) {
    return
      address(
        new AaveV4CapAgent(
          address(_agentHub),
          address(_rangeValidationModule),
          _kind,
          '',
          _hubConfigurator()
        )
      );
  }

  function _postSetup() internal override {
    _rangeValidationModule.setDefaultRangeConfig(
      address(_agentHub),
      _agentId,
      _updateType,
      IRangeValidationModule.RangeConfig({
        maxIncrease: 25_00,
        maxDecrease: 25_00,
        isIncreaseRelative: true,
        isDecreaseRelative: true
      })
    );
    _grantRole(_hubConfigurator(), _selector(), _agent);
  }

  function _selector() internal view returns (bytes4) {
    return
      _kind == AaveV4CapAgent.CapKind.ADD
        ? IHubConfigurator.updateSpokeAddCap.selector
        : IHubConfigurator.updateSpokeDrawCap.selector;
  }

  function _config(
    address hub,
    address spoke,
    address asset
  ) internal view returns (IHub.SpokeConfig memory) {
    return IHub(hub).getSpokeConfig(IHub(hub).getAssetId(asset), spoke);
  }

  function _cap(address hub, address spoke, address asset) internal view returns (uint256) {
    IHub.SpokeConfig memory config = _config(hub, spoke, asset);
    return _kind == AaveV4CapAgent.CapKind.ADD ? config.addCap : config.drawCap;
  }

  function _publishCap(address hub, address spoke, address asset, uint256 cap) internal {
    _publish(hub, spoke, asset, abi.encode(cap));
  }

  function _assertOnlyCapChanged(
    IHub.SpokeConfig memory before,
    IHub.SpokeConfig memory current,
    uint256 newCap
  ) internal view {
    if (_kind == AaveV4CapAgent.CapKind.ADD) {
      assertEq(current.addCap, newCap);
      assertEq(current.drawCap, before.drawCap);
    } else {
      assertEq(current.addCap, before.addCap);
      assertEq(current.drawCap, newCap);
    }
    assertEq(current.riskPremiumThreshold, before.riskPremiumThreshold);
    assertEq(current.active, before.active);
    assertEq(current.halted, before.halted);
  }

  function _assertUnchanged(
    IHub.SpokeConfig memory before,
    IHub.SpokeConfig memory current
  ) internal pure {
    assertEq(abi.encode(current), abi.encode(before));
  }
}

abstract contract AaveV4CapAgentBaseForkTest is AaveV4CapAgentForkTestBase {
  constructor(
    AaveV4CapAgent.CapKind kind,
    string memory updateType
  ) AaveV4CapAgentForkTestBase(kind, updateType) {}

  address internal constant HUB = AaveV4BaseFork.EQUITIES_HUB;
  address internal constant MAG7 = AaveV4BaseFork.MAG7_SPOKE;
  address internal constant TREASURY = AaveV4BaseFork.TREASURY_SPOKE;
  address internal constant TOKENIZATION = AaveV4BaseFork.USDC_TOKENIZATION_SPOKE;
  address internal constant AAPL = AaveV4BaseFork.AAPLc;
  address internal constant USDC = AaveV4BaseFork.USDC;

  function _hubConfigurator() internal pure override returns (address) {
    return AaveV4BaseFork.HUB_CONFIGURATOR;
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](4);
    markets[0] = _marketId(HUB, MAG7, AAPL);
    markets[1] = _marketId(HUB, MAG7, USDC);
    markets[2] = _marketId(HUB, TREASURY, USDC);
    markets[3] = _marketId(HUB, TOKENIZATION, USDC);
  }

  function test_rejectsZeroAndMax() public {
    _publishCap(HUB, MAG7, USDC, 0);
    _publishCap(HUB, TOKENIZATION, USDC, type(uint40).max);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_updatesOneSpokeOnly() public {
    uint256 current = _cap(HUB, MAG7, USDC);
    assertGt(current, 0);
    uint256 newCap = (current * 120) / 100;
    IHub.SpokeConfig memory mag7Before = _config(HUB, MAG7, USDC);
    IHub.SpokeConfig memory tokenizationBefore = _config(HUB, TOKENIZATION, USDC);
    IHub.SpokeConfig memory treasuryBefore = _config(HUB, TREASURY, USDC);

    _publishCap(HUB, MAG7, USDC, newCap);
    assertTrue(_checkAndExecute());

    _assertOnlyCapChanged(mag7Before, _config(HUB, MAG7, USDC), newCap);
    _assertUnchanged(tokenizationBefore, _config(HUB, TOKENIZATION, USDC));
    _assertUnchanged(treasuryBefore, _config(HUB, TREASURY, USDC));
  }

  function test_rejectsOutOfRange() public {
    uint256 current = _cap(HUB, MAG7, USDC);
    _publishCap(HUB, MAG7, USDC, (current * 126) / 100);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }
}

contract AaveV4CapAgent_AddCap_BaseForkTest is
  AaveV4CapAgentBaseForkTest(AaveV4CapAgent.CapKind.ADD, 'SpokeAddCapUpdate')
{
  function test_skipsUncappedTreasurySpoke() public {
    assertEq(_cap(HUB, TREASURY, USDC), type(uint40).max);
    _publishCap(HUB, TREASURY, USDC, 1_000_000);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_increasesEquityAddCap() public {
    IHub.SpokeConfig memory before = _config(HUB, MAG7, AAPL);
    assertEq(before.addCap, 15_000);
    _publishCap(HUB, MAG7, AAPL, 18_000);
    assertTrue(_checkAndExecute());
    _assertOnlyCapChanged(before, _config(HUB, MAG7, AAPL), 18_000);
  }

  function test_batchSkipsUncapped() public {
    _publishCap(HUB, TREASURY, USDC, 1_000_000);
    _publishCap(HUB, MAG7, AAPL, 16_000);
    _publishCap(HUB, TOKENIZATION, USDC, 1_100_000);

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 2);

    address[] memory markets = new address[](3);
    markets[0] = _marketId(HUB, TREASURY, USDC);
    markets[1] = actions[0].markets[0];
    markets[2] = actions[0].markets[1];
    actions[0].markets = markets;
    _agentHub.execute(actions);

    assertEq(_cap(HUB, MAG7, AAPL), 16_000);
    assertEq(_cap(HUB, TOKENIZATION, USDC), 1_100_000);
    assertEq(_cap(HUB, TREASURY, USDC), type(uint40).max);
  }
}

contract AaveV4CapAgent_DrawCap_BaseForkTest is
  AaveV4CapAgentBaseForkTest(AaveV4CapAgent.CapKind.DRAW, 'SpokeDrawCapUpdate')
{
  function test_skipsBlockedEquityDrawCap() public {
    assertEq(_cap(HUB, MAG7, AAPL), 0);
    _publishCap(HUB, MAG7, AAPL, 100);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_decreasesUsdcDrawCap() public {
    IHub.SpokeConfig memory before = _config(HUB, MAG7, USDC);
    assertEq(before.drawCap, 21_000_000);
    _publishCap(HUB, MAG7, USDC, 18_000_000);
    assertTrue(_checkAndExecute());
    _assertOnlyCapChanged(before, _config(HUB, MAG7, USDC), 18_000_000);
  }
}

abstract contract AaveV4CapAgentEthereumForkTest is AaveV4CapAgentForkTestBase {
  constructor(
    AaveV4CapAgent.CapKind kind,
    string memory updateType
  ) AaveV4CapAgentForkTestBase(kind, updateType) {}

  address internal constant CORE = AaveV4EthereumFork.CORE_HUB;
  address internal constant PRIME = AaveV4EthereumFork.PRIME_HUB;
  address internal constant MAIN = AaveV4EthereumFork.MAIN_SPOKE;
  address internal constant BLUECHIP = AaveV4EthereumFork.BLUECHIP_SPOKE;
  address internal constant FOREX = AaveV4EthereumFork.FOREX_SPOKE;
  address internal constant USDC = AaveV4EthereumFork.USDC;

  function _createFork() internal override {
    vm.createSelectFork(vm.rpcUrl('mainnet'), AaveV4EthereumFork.BLOCK);
  }

  function _accessManager() internal pure override returns (address) {
    return AaveV4EthereumFork.ACCESS_MANAGER;
  }

  function _hubConfigurator() internal pure override returns (address) {
    return AaveV4EthereumFork.HUB_CONFIGURATOR;
  }

  function _allowedMarkets() internal pure override returns (address[] memory markets) {
    markets = new address[](4);
    markets[0] = _marketId(CORE, MAIN, USDC);
    markets[1] = _marketId(CORE, BLUECHIP, USDC);
    markets[2] = _marketId(CORE, FOREX, USDC);
    markets[3] = _marketId(PRIME, BLUECHIP, USDC);
  }

  function test_updatesOneSpokeAndHubOnly() public {
    uint256 current = _cap(CORE, FOREX, USDC);
    assertGt(current, 0);
    uint256 newCap = (current * 110) / 100;
    IHub.SpokeConfig memory forexBefore = _config(CORE, FOREX, USDC);
    IHub.SpokeConfig memory mainBefore = _config(CORE, MAIN, USDC);
    IHub.SpokeConfig memory bluechipBefore = _config(CORE, BLUECHIP, USDC);
    IHub.SpokeConfig memory primeBefore = _config(PRIME, BLUECHIP, USDC);

    _publishCap(CORE, FOREX, USDC, newCap);
    assertTrue(_checkAndExecute());

    _assertOnlyCapChanged(forexBefore, _config(CORE, FOREX, USDC), newCap);
    _assertUnchanged(mainBefore, _config(CORE, MAIN, USDC));
    _assertUnchanged(bluechipBefore, _config(CORE, BLUECHIP, USDC));
    _assertUnchanged(primeBefore, _config(PRIME, BLUECHIP, USDC));
  }

  function test_rejectsMismatchedMarket() public {
    _publishRaw(
      _marketId(PRIME, BLUECHIP, USDC),
      abi.encode(CORE, FOREX, USDC, abi.encode((_cap(CORE, FOREX, USDC) * 110) / 100))
    );
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }

  function test_skipsAfterRoleRevoked() public {
    _publishCap(CORE, FOREX, USDC, (_cap(CORE, FOREX, USDC) * 110) / 100);
    _revokeRole(_hubConfigurator(), _selector(), _agent);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }
}

contract AaveV4CapAgent_AddCap_EthereumForkTest is
  AaveV4CapAgentEthereumForkTest(AaveV4CapAgent.CapKind.ADD, 'SpokeAddCapUpdate')
{
  function test_skipsBlockedAddCap() public {
    assertEq(_cap(CORE, BLUECHIP, USDC), 0);
    _publishCap(CORE, BLUECHIP, USDC, 1_000_000);
    (bool shouldRun, ) = _check();
    assertFalse(shouldRun);
  }
}

contract AaveV4CapAgent_DrawCap_EthereumForkTest is
  AaveV4CapAgentEthereumForkTest(AaveV4CapAgent.CapKind.DRAW, 'SpokeDrawCapUpdate')
{
  function test_batchUpdatesSeveralSpokes() public {
    uint256 mainCap = (_cap(CORE, MAIN, USDC) * 110) / 100;
    uint256 bluechipCap = (_cap(CORE, BLUECHIP, USDC) * 90) / 100;
    _publishCap(CORE, MAIN, USDC, mainCap);
    _publishCap(CORE, BLUECHIP, USDC, bluechipCap);

    (bool shouldRun, IAgentHub.ActionData[] memory actions) = _check();
    assertTrue(shouldRun);
    assertEq(actions[0].markets.length, 2);
    _agentHub.execute(actions);

    assertEq(_cap(CORE, MAIN, USDC), mainCap);
    assertEq(_cap(CORE, BLUECHIP, USDC), bluechipCap);
  }
}
