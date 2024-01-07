import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const {deployments, getNamedAccounts} = hre;

  const {deployer} = await getNamedAccounts();
  const sealedPool = await deployments.get('SealedPool');

  await deployments.deploy('MintAuctions', {
    from: deployer,
    log: true,
    autoMine: true,
    args: [deployer, deployer, deployer, sealedPool.address]
});
};
module.exports = func;
func.tags = ['MintAuctions'];
func.dependencies = ['SealedPool'];
