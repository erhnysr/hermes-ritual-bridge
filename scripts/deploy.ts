import { ethers } from "hardhat";

async function main() {
  const Bridge = await ethers.getContractFactory("HermesRitualBridge");
  const bridge = await Bridge.deploy();
  await bridge.waitForDeployment();

  console.log(`HermesRitualBridge deployed to: ${await bridge.getAddress()}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
