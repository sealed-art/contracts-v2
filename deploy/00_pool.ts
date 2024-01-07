import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;

    const { deployer } = await getNamedAccounts();

    console.log("dep", deployer)
    await deploy('SealedPool', {
        from: deployer,
        log: true,
        autoMine: true,
        args: [deployer]
    });
};
module.exports = func;
func.tags = ['SealedPool'];
