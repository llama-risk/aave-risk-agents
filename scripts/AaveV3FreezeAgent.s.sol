// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EthereumScript} from 'solidity-utils/contracts/utils/ScriptUtils.sol';
import {MiscEthereum} from 'aave-address-book/MiscEthereum.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV3EthereumLido} from 'aave-address-book/AaveV3EthereumLido.sol';
import {AaveV3EthereumHorizon} from 'aave-address-book/AaveV3EthereumHorizon.sol';

import {AaveV3FreezeAgent} from '../src/contracts/agent/AaveV3FreezeAgent.sol';

library DeployV3FreezeAgent {
  function deploy(
    address agentHub,
    string memory updateTypeSuffix,
    address pool
  ) internal returns (address) {
    return address(new AaveV3FreezeAgent(agentHub, updateTypeSuffix, pool));
  }
}

// make deploy-ledger contract=scripts/AaveV3FreezeAgent.s.sol:DeployV3FreezeAgentEthereum chain=mainnet
contract DeployV3FreezeAgentEthereum is EthereumScript {
  function run() external broadcast {
    DeployV3FreezeAgent.deploy(MiscEthereum.AGENT_HUB, '_Core', address(AaveV3Ethereum.POOL));
    DeployV3FreezeAgent.deploy(MiscEthereum.AGENT_HUB, '_Prime', address(AaveV3EthereumLido.POOL));
    DeployV3FreezeAgent.deploy(
      MiscEthereum.AGENT_HUB,
      '_Horizon',
      address(AaveV3EthereumHorizon.POOL)
    );
  }
}
