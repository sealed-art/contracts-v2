import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.18",
    settings: {
      optimizer: {
        enabled: true,
        runs: 4294967,
      },
    },
  },
  networks: {
    hardhat: {
      forking: {
        url: "https://eth.llamarpc.com",
        blockNumber: 17589468
      }
    },
    fuji: {
      url: 'https://rpc.ankr.com/avalanche_fuji',
      //accounts: [process.env.PRIVATEKEY!],
      gasMultiplier: 1.5,
    },
    mainnet: {
      url: "https://eth.llamarpc.com",
      //accounts: [process.env.PRIVATEKEY!],
      gasMultiplier: 1.1,
    },
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY ?? '',
      avalancheFujiTestnet: process.env.ETHERSCAN_API_KEY ?? ''
    }
  }
};

export default config;
