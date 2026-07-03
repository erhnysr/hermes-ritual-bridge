import { ethers, network } from "hardhat";

// Deploys HermesRitualLLM to Ritual Chain (Chain ID 1979).
// Usage: npm run deploy -- --network ritual
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Network:  ${network.name}`);
  console.log(`Deployer: ${deployer.address}`);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Balance:  ${ethers.formatEther(balance)} RITUAL`);

  const Factory = await ethers.getContractFactory("HermesRitualLLM");
  const consumer = await Factory.deploy();
  await consumer.waitForDeployment();

  const address = await consumer.getAddress();
  console.log(`\nHermesRitualLLM deployed to: ${address}`);
  console.log(`\nNext steps:`);
  console.log(`  1. Add CONSUMER_ADDRESS=${address} to your .env`);
  console.log(`  2. Fund fees + run inference: npm run request -- --network ritual`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
