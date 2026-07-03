import { expect } from "chai";
import { ethers } from "hardhat";

const abi = ethers.AbiCoder.defaultAbiCoder();

// Re-encode a CompletionData blob exactly as documented in the ritual-dapp-llm
// skill so we can assert the on-chain decoder pulls the right fields back out.
function encodeCompletionData(content: string, finishReason: string): string {
  const messageData = abi.encode(
    ["string", "string", "string", "uint256", "bytes[]"],
    ["assistant", content, "", 0, []]
  );
  const choice = abi.encode(
    ["uint256", "string", "bytes"],
    [0, finishReason, messageData]
  );
  const usageData = abi.encode(
    ["uint256", "uint256", "uint256"],
    [30, 220, 250]
  );
  return abi.encode(
    [
      "string",
      "string",
      "uint256",
      "string",
      "string",
      "string",
      "uint256",
      "bytes[]",
      "bytes",
    ],
    [
      "chatcmpl-1",
      "chat.completion",
      1700000000,
      "zai-org/GLM-4.7-FP8",
      "fp",
      "auto",
      1,
      [choice],
      usageData,
    ]
  );
}

describe("HermesRitualLLM", () => {
  async function deploy() {
    const Factory = await ethers.getContractFactory("HermesRitualLLM");
    const c = await Factory.deploy();
    await c.waitForDeployment();
    return c;
  }

  it("pins the correct Ritual system addresses and model", async () => {
    const c = await deploy();
    expect(await c.LLM_PRECOMPILE()).to.equal(
      "0x0000000000000000000000000000000000000802"
    );
    expect(await c.RITUAL_WALLET()).to.equal(
      "0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948"
    );
    expect(await c.MODEL()).to.equal("zai-org/GLM-4.7-FP8");
  });

  it("uses safe defaults for the async request", async () => {
    const c = await deploy();
    expect(await c.ttl()).to.equal(300n);
    expect(await c.maxCompletionTokens()).to.equal(4096n);
    expect(await c.temperature()).to.equal(700n);
  });

  it("wraps a plain prompt into valid OpenAI messages JSON", async () => {
    const c = await deploy();
    const out = await c.previewMessages("Hello Ritual");
    expect(out).to.equal('[{"role":"user","content":"Hello Ritual"}]');
    expect(() => JSON.parse(out)).to.not.throw();
  });

  it("JSON-escapes quotes, backslashes and control chars", async () => {
    const c = await deploy();
    const tricky = 'say "hi"\n\tback\\slash';
    const out = await c.previewMessages(tricky);
    const parsed = JSON.parse(out);
    expect(parsed[0].role).to.equal("user");
    expect(parsed[0].content).to.equal(tricky);
  });

  it("decodes assistant content and finish reason from CompletionData", async () => {
    const c = await deploy();
    const blob = encodeCompletionData("The answer is 42.", "stop");
    const [content, finishReason] = await c.decodeCompletion(blob);
    expect(content).to.equal("The answer is 42.");
    expect(finishReason).to.equal("stop");
  });

  it("returns empty strings when there are no choices", async () => {
    const c = await deploy();
    const empty = abi.encode(
      [
        "string",
        "string",
        "uint256",
        "string",
        "string",
        "string",
        "uint256",
        "bytes[]",
        "bytes",
      ],
      ["", "", 0, "", "", "", 0, [], "0x"]
    );
    const [content, finishReason] = await c.decodeCompletion(empty);
    expect(content).to.equal("");
    expect(finishReason).to.equal("");
  });

  it("rejects inference with a zero executor", async () => {
    const c = await deploy();
    await expect(
      c.ask(ethers.ZeroAddress, "hi")
    ).to.be.revertedWithCustomError(c, "EmptyExecutor");
  });

  it("restricts admin setters to the owner", async () => {
    const c = await deploy();
    const [, stranger] = await ethers.getSigners();
    // .connect() returns the untyped BaseContract in ethers v6; cast back.
    await expect(
      (c.connect(stranger) as typeof c).setTtl(120)
    ).to.be.revertedWithCustomError(c, "NotOwner");
  });

  it("enforces parameter floors on setters", async () => {
    const c = await deploy();
    await expect(c.setTtl(30)).to.be.revertedWith("ttl too low");
    await expect(c.setMaxCompletionTokens(1000)).to.be.revertedWith(
      "below GLM reasoning floor"
    );
    await c.setTtl(500);
    expect(await c.ttl()).to.equal(500n);
  });
});
