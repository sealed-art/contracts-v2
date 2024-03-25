import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
    const { deployments, getNamedAccounts } = hre;
    const { deploy } = deployments;

    const { deployer } = await getNamedAccounts();
    const SealedPoolDeployment = await deployments.get('SealedPool');

    await deploy('Auctions', {
        from: deployer,
        log: true,
        autoMine: true,
        args: [
            "0xcA2A693A03b49bBc3A25AE7cCc3c36335235Eeac",
            "0xE4FA009d01B2cd9c9B0F81fd3e45095EF0F1005C",
            "0xcA2A693A03b49bBc3A25AE7cCc3c36335235Eeac",
            SealedPoolDeployment.address
        ]
    });
};
module.exports = func;
func.tags = ['Auctions'];
func.dependencies = ["SealedPool"]
