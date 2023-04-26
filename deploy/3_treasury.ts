import { ChainId, registry } from '@angleprotocol/sdk';
import { DeployFunction } from 'hardhat-deploy/types';
import yargs from 'yargs';

import { AgTokenSideChainMultiBridge, AgTokenSideChainMultiBridge__factory, Treasury__factory } from '../typechain';
import { deployProxy } from './helpers';

const argv = yargs.env('').boolean('ci').parseSync();

const func: DeployFunction = async ({ deployments, ethers, network }) => {
  const { deploy } = deployments;
  const { deployer } = await ethers.getNamedSigners();
  let proxyAdmin: string;
  let coreBorrow: string;
  const stableName = 'EUR';
  const agTokenName = `ag${stableName}`;

  const agTokenAddress = (await deployments.get(`AgToken_${stableName}`)).address;

  if (!network.live || network.config.chainId == 1) {
    // If we're in mainnet fork, we're using the `ProxyAdmin` address from mainnet
    proxyAdmin = registry(ChainId.MAINNET)?.ProxyAdmin!;
    coreBorrow = registry(ChainId.MAINNET)?.CoreBorrow!;
  } else {
    proxyAdmin = registry(network.config.chainId as ChainId)?.ProxyAdmin!;
    coreBorrow = registry(network.config.chainId as ChainId)?.CoreBorrow!;
    proxyAdmin = '0x9a5b060Bd7b8f86c4C0D720a17367729670AfB19';
    coreBorrow = '0x3E399AE5B4D8bc0021e53b51c8BCdD66DD62c03b';
  }

  let treasuryImplementation: string;
  try {
    treasuryImplementation = (await deployments.get('Treasury_Implementation')).address;
  } catch {
    console.log('Now deploying Treasury implementation');
    await deploy('Treasury_Implementation', {
      contract: 'Treasury',
      from: deployer.address,
      args: [],
      log: !argv.ci,
    });
    treasuryImplementation = (await deployments.get('Treasury_Implementation')).address;
  }

  const treasuryInterface = Treasury__factory.createInterface();
  const dataTreasury = new ethers.Contract(treasuryImplementation, treasuryInterface).interface.encodeFunctionData(
    'initialize',
    [coreBorrow, agTokenAddress],
  );

  const treasury = await deployProxy(`Treasury_${stableName}`, treasuryImplementation, proxyAdmin, dataTreasury);

  console.log('');

  console.log('Initializing the agToken contract now that we have the treasury address');
  const agToken = new ethers.Contract(
    agTokenAddress,
    AgTokenSideChainMultiBridge__factory.createInterface(),
    deployer,
  ) as AgTokenSideChainMultiBridge;
  await (await agToken.connect(deployer).initialize(agTokenName, agTokenName, treasury)).wait();
  console.log('Success: agToken successfully initialized');
};

func.tags = ['treasury'];
// func.dependencies = ['agTokenImplementation'];
export default func;
