import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const { PRIVATE_KEY, RPC_URL, ETHERSCAN_API_KEY } = process.env;

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    ...(RPC_URL && PRIVATE_KEY
      ? {
          testnet: {
            url: RPC_URL,
            accounts: [PRIVATE_KEY],
          },
        }
      : {}),
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY || "",
  },
};

export default config;
