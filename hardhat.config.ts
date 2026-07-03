import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "dotenv/config";

// Chain config per the Ritual dApp deploy skill (ritual-dapp-deploy).
// Ritual Chain — Chain ID 1979, native RITUAL, EIP-1559 only.
const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      // viaIR: the 30-field LLM precompile request tuple overflows the legacy
      // stack-based codegen ("stack too deep"); the IR pipeline handles it.
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    ritual: {
      url: process.env.RITUAL_RPC_URL || "https://rpc.ritualfoundation.org",
      chainId: 1979,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
};

export default config;
