import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;

    const { deployer } = await getNamedAccounts();

    await deploy('SealedEditions', {
        from: deployer,
        log: true,
        autoMine: true,
        args: ["0xcA2A693A03b49bBc3A25AE7cCc3c36335235Eeac"]
    });
};
module.exports = func;
func.tags = ['SealedEditions'];
