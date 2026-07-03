import { expect } from "chai";
import { ethers } from "hardhat";

describe("HermesRitualBridge", () => {
  it("emits Locked with an incrementing nonce", async () => {
    const [, user] = await ethers.getSigners();
    const Bridge = await ethers.getContractFactory("HermesRitualBridge");
    const bridge = await Bridge.deploy();
    await bridge.waitForDeployment();

    const recipient = ethers.toUtf8Bytes("ritual-recipient");
    const amount = ethers.parseEther("1");

    await expect(bridge.connect(user).lock(1337, recipient, { value: amount }))
      .to.emit(bridge, "Locked")
      .withArgs(user.address, 1337, ethers.hexlify(recipient), amount, 0);

    expect(await bridge.nonce()).to.equal(1);
  });

  it("reverts on zero amount", async () => {
    const Bridge = await ethers.getContractFactory("HermesRitualBridge");
    const bridge = await Bridge.deploy();
    await bridge.waitForDeployment();

    await expect(
      bridge.lock(1337, ethers.toUtf8Bytes("x"), { value: 0 })
    ).to.be.revertedWith("zero amount");
  });
});
