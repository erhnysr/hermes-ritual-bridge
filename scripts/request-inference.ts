import { ethers, network } from "hardhat";

// Ends-to-end LLM inference against a deployed HermesRitualLLM:
//   1. Discover a live TEE executor with LLM capability.
//   2. Ensure the contract's RitualWallet balance covers the async fee escrow.
//   3. Submit a prompt and read the settled response back from storage.
//
// Usage: CONSUMER_ADDRESS=0x... npm run request -- --network ritual

const TEE_SERVICE_REGISTRY = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";
const RITUAL_WALLET = "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948";
const CAPABILITY_LLM = 1; // Capability.LLM per ritual-dapp-llm

const WALLET_ABI = [
  "function deposit(uint256 lockDuration) payable",
  "function balanceOf(address user) view returns (uint256)",
];

// Minimal registry ABI — getServicesByCapability returns registered TEE nodes.
const REGISTRY_ABI = [
  "function getServicesByCapability(uint8 capability, bool checkValidity) view returns (tuple(tuple(address paymentAddress, address teeAddress, uint8 teeType, bytes publicKey, string endpoint, bytes32 certPubKeyHash, uint8 capability) node, bool isValid, bytes32 workloadId)[])",
];

async function findExecutor(): Promise<string> {
  const override = process.env.EXECUTOR_ADDRESS;
  if (override && override.length > 0) {
    console.log(`Using EXECUTOR_ADDRESS override: ${override}`);
    return ethers.getAddress(override);
  }

  const registry = new ethers.Contract(
    TEE_SERVICE_REGISTRY,
    REGISTRY_ABI,
    ethers.provider
  );
  const services = await registry.getServicesByCapability(CAPABILITY_LLM, true);
  const valid = services.filter((s: any) => s.isValid);
  if (valid.length === 0) {
    throw new Error(
      "No valid LLM executors registered on the TEEServiceRegistry. " +
        "Set EXECUTOR_ADDRESS in .env to a known executor, or try again later."
    );
  }
  const executor: string = valid[0].node.teeAddress;
  console.log(`Found ${valid.length} valid LLM executor(s); using ${executor}`);
  return executor;
}

async function main() {
  const consumerAddress = process.env.CONSUMER_ADDRESS;
  if (!consumerAddress) {
    throw new Error(
      "Set CONSUMER_ADDRESS in .env (deploy first with scripts/deploy.ts)."
    );
  }
  const prompt = process.env.PROMPT || "In one sentence, what is Ritual Chain?";

  const [signer] = await ethers.getSigners();
  console.log(`Network: ${network.name}`);
  console.log(`Signer:  ${signer.address}`);

  const consumer = await ethers.getContractAt(
    "HermesRitualLLM",
    consumerAddress,
    signer
  );
  const executor = await findExecutor();

  // Fees for the LLM precompile are charged against the RitualWallet balance of
  // the transaction SIGNER (the EOA below), even though the contract is what
  // calls 0x0802 — the chain recovers the signer from the original tx. So fund
  // the signer, not the contract. Worst-case escrow for GLM-4.7-FP8 is
  // ~0.31 RITUAL per in-flight call — keep >=0.4 with headroom.
  const wallet = new ethers.Contract(RITUAL_WALLET, WALLET_ABI, signer);
  const balance = await wallet.balanceOf(signer.address);
  console.log(`\nSigner RitualWallet balance: ${ethers.formatEther(balance)} RITUAL`);
  if (balance < ethers.parseEther("0.4")) {
    const topUp = ethers.parseEther("0.5");
    console.log(
      `Depositing ${ethers.formatEther(topUp)} RITUAL for the signer (lock 100000 blocks)...`
    );
    const depositTx = await wallet.deposit(100000n, { value: topUp });
    await depositTx.wait();
    const newBalance = await wallet.balanceOf(signer.address);
    console.log(`New signer balance: ${ethers.formatEther(newBalance)} RITUAL`);
  }

  console.log(`\nPrompt: ${prompt}`);
  const tx = await consumer.ask(executor, prompt, { gasLimit: 5_000_000n });
  console.log(`ask() tx: ${tx.hash}`);
  await tx.wait();

  // The short-running async settlement injects the result into the same tx
  // (fulfilled replay), so it is already persisted by the time the tx is mined.
  const id = (await consumer.inferenceCount()) - 1n;
  const inf = await consumer.inferences(id);

  console.log(`\n--- Inference #${id} ---`);
  console.log(`requester:    ${inf.requester}`);
  console.log(`completed:    ${inf.completed}`);
  console.log(`hasError:     ${inf.hasError}`);
  if (inf.hasError) {
    console.log(`errorMessage: ${inf.errorMessage}`);
  }
  console.log(`finishReason: ${inf.finishReason}`);
  console.log(`content:\n${inf.content}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
