/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc } from "../../shared/constants";

describe("SynthFactory", function () {
  let synthFactory: any;
  let usdc: any;
  let oracle: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let treasury: SignerWithAddress;

  async function deploySynthFactoryFixture() {
    const [owner, user1, user2, treasury] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);
    await (oracle as any).setPrice(2, TEST_CONSTANTS.PRICES.BTC);

    // Deploy SynthFactory
    const SynthFactoryFactory = await ethers.getContractFactory("SynthFactory");
    const synthFactory = await SynthFactoryFactory.deploy(
      owner.address, // _initialOwner
      await oracle.getAddress() // _oracleAddress
    );

    // Setup initial state
    await (usdc as any).mint(owner.address, toUsdc("1000000"));
    await (usdc as any).mint(user1.address, toUsdc("100000"));
    await (usdc as any).mint(user2.address, toUsdc("100000"));

    return {
      synthFactory,
      usdc,
      oracle,
      owner,
      user1,
      user2,
      treasury
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deploySynthFactoryFixture);
    synthFactory = fixture.synthFactory;
    usdc = fixture.usdc;
    oracle = fixture.oracle;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
    treasury = fixture.treasury;
  });

  describe("Initialization", function () {
    it("Should set correct oracle address", async function () {
      expect(await synthFactory.oracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await synthFactory.owner()).to.equal(owner.address);
    });
  });

  describe("Synthetic Asset Creation", function () {
    it("Should deploy new synthetic asset", async function () {
      await expect(
        synthFactory.deploySynth(
          "Synthetic ETH", 
          "sETH", 
          1, // assetId
          15000, // customMinCRbps (150%)
          owner.address // controllerAddress
        )
      ).to.emit(synthFactory, "SynthDeployedAndConfigured");
    });

    it("Should track deployed synths", async function () {
      await synthFactory.deploySynth("Synthetic ETH", "sETH", 1, 15000, owner.address);
      await synthFactory.deploySynth("Synthetic BTC", "sBTC", 2, 16000, owner.address);
      
      const synthCount = await synthFactory.getDeployedSynthsCount();
      expect(synthCount).to.equal(2);
      
      const firstSynth = await synthFactory.getDeployedSynthAddressAtIndex(0);
      const secondSynth = await synthFactory.getDeployedSynthAddressAtIndex(1);
      expect(firstSynth).to.not.equal(ethers.ZeroAddress);
      expect(secondSynth).to.not.equal(ethers.ZeroAddress);
    });

    it("Should not allow duplicate asset IDs", async function () {
      await synthFactory.deploySynth("Synthetic ETH", "sETH", 1, 15000, owner.address);
      
      await expect(
        synthFactory.deploySynth("Another ETH", "aETH", 1, 16000, owner.address)
      ).to.be.revertedWith("SF: AssetId already registered");
    });

    it("Should only allow owner to deploy synths", async function () {
      await expect(
        synthFactory.connect(user1).deploySynth("Synthetic ETH", "sETH", 1, 15000, owner.address)
      ).to.be.revertedWithCustomError(synthFactory, "OwnableUnauthorizedAccount");
    });
  });

  describe("Configuration Management", function () {
    let synthAddress: string;

    beforeEach(async function () {
      const tx = await synthFactory.deploySynth("Synthetic ETH", "sETH", 1, 15000, owner.address);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "SynthDeployedAndConfigured");
      synthAddress = event.args[0];
    });

    it("Should get synth by asset ID", async function () {
      expect(await synthFactory.getSynthAddressByAssetId(1)).to.equal(synthAddress);
    });

    it("Should check if synth is registered", async function () {
      expect(await synthFactory.isSynthRegistered(synthAddress)).to.be.true;
      expect(await synthFactory.isSynthRegistered(ethers.ZeroAddress)).to.be.false;
    });

    it("Should set custom minimum CR", async function () {
      const newCR = 17000; // 170%
      
      await expect(
        synthFactory.setSynthCustomMinCR(synthAddress, newCR)
      ).to.emit(synthFactory, "SynthCustomMinCRSet")
      .withArgs(synthAddress, newCR);
      
      const config = await synthFactory.getSynthConfig(synthAddress);
      expect(config.customMinCRbps).to.equal(newCR);
    });

    it("Should set oracle address", async function () {
      const newOracle = await ethers.getContractFactory("MockOracle");
      const oracleInstance = await newOracle.deploy();
      
      await expect(
        synthFactory.setOracle(await oracleInstance.getAddress())
      ).to.emit(synthFactory, "OracleSet")
      .withArgs(await oracleInstance.getAddress());
      
      expect(await synthFactory.oracle()).to.equal(await oracleInstance.getAddress());
    });
  });

  describe("Emergency Functions", function () {
    it("Should pause factory", async function () {
      await synthFactory.pause();
      expect(await synthFactory.paused()).to.be.true;
    });

    it("Should not allow operations when paused", async function () {
      await synthFactory.pause();
      
      await expect(
        synthFactory.deploySynth("Synthetic ETH", "sETH", 1, 15000, owner.address)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should unpause factory", async function () {
      await synthFactory.pause();
      await synthFactory.unpause();
      expect(await synthFactory.paused()).to.be.false;
    });
  });
}); 