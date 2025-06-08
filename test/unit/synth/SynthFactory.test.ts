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
      await usdc.getAddress(),
      await oracle.getAddress(),
      treasury.address
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
    it("Should set correct USDC address", async function () {
      expect(await synthFactory.usdc()).to.equal(await usdc.getAddress());
    });

    it("Should set correct oracle address", async function () {
      expect(await synthFactory.oracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct treasury address", async function () {
      expect(await synthFactory.treasury()).to.equal(treasury.address);
    });

    it("Should set correct owner", async function () {
      expect(await synthFactory.owner()).to.equal(owner.address);
    });
  });

  describe("Synthetic Asset Creation", function () {
    it("Should create new synthetic asset", async function () {
      await expect(
        synthFactory.createSynth("Synthetic ETH", "sETH", 1) // Asset ID 1 for ETH
      ).to.emit(synthFactory, "SynthCreated");
    });

    it("Should deploy SynthToken contract", async function () {
      const tx = await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      
      const synthAddress = event.args[0];
      expect(synthAddress).to.not.equal(ethers.ZeroAddress);
      
      // Verify it's a valid contract
      const synthContract = await ethers.getContractAt("SynthToken", synthAddress);
      expect(await synthContract.name()).to.equal("Synthetic ETH");
      expect(await synthContract.symbol()).to.equal("sETH");
    });

    it("Should track created synths", async function () {
      await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      await synthFactory.createSynth("Synthetic BTC", "sBTC", 2);
      
      const synthCount = await synthFactory.getSynthCount();
      expect(synthCount).to.equal(2);
      
      const synthsList = await synthFactory.getAllSynths();
      expect(synthsList.length).to.equal(2);
    });

    it("Should not allow duplicate asset IDs", async function () {
      await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      
      await expect(
        synthFactory.createSynth("Another ETH", "aETH", 1)
      ).to.be.revertedWith("Asset already exists");
    });

    it("Should only allow owner to create synths", async function () {
      await expect(
        synthFactory.connect(user1).createSynth("Synthetic ETH", "sETH", 1)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Synthetic Asset Management", function () {
    let sethAddress: string;
    let sbtcAddress: string;

    beforeEach(async function () {
      // Create test synths
      let tx = await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      let receipt = await tx.wait();
      let event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      sethAddress = event.args[0];

      tx = await synthFactory.createSynth("Synthetic BTC", "sBTC", 2);
      receipt = await tx.wait();
      event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      sbtcAddress = event.args[0];
    });

    it("Should get synth by asset ID", async function () {
      expect(await synthFactory.getSynth(1)).to.equal(sethAddress);
      expect(await synthFactory.getSynth(2)).to.equal(sbtcAddress);
    });

    it("Should check if synth exists", async function () {
      expect(await synthFactory.synthExists(1)).to.be.true;
      expect(await synthFactory.synthExists(2)).to.be.true;
      expect(await synthFactory.synthExists(3)).to.be.false;
    });

    it("Should pause synth", async function () {
      await expect(
        synthFactory.pauseSynth(1)
      ).to.emit(synthFactory, "SynthPaused")
      .withArgs(1, sethAddress);
      
      const synthContract = await ethers.getContractAt("SynthToken", sethAddress);
      expect(await synthContract.paused()).to.be.true;
    });

    it("Should unpause synth", async function () {
      await synthFactory.pauseSynth(1);
      
      await expect(
        synthFactory.unpauseSynth(1)
      ).to.emit(synthFactory, "SynthUnpaused")
      .withArgs(1, sethAddress);
      
      const synthContract = await ethers.getContractAt("SynthToken", sethAddress);
      expect(await synthContract.paused()).to.be.false;
    });

    it("Should only allow owner to pause/unpause", async function () {
      await expect(
        synthFactory.connect(user1).pauseSynth(1)
      ).to.be.revertedWith("Ownable: caller is not the owner");
      
      await expect(
        synthFactory.connect(user1).unpauseSynth(1)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Collateral Management", function () {
    let sethAddress: string;

    beforeEach(async function () {
      const tx = await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      sethAddress = event.args[0];
    });

    it("Should set collateral ratio", async function () {
      const newRatio = 15000; // 150%
      
      await expect(
        synthFactory.setCollateralRatio(1, newRatio)
      ).to.emit(synthFactory, "CollateralRatioUpdated")
      .withArgs(1, newRatio);
      
      expect(await synthFactory.getCollateralRatio(1)).to.equal(newRatio);
    });

    it("Should not allow invalid collateral ratios", async function () {
      await expect(
        synthFactory.setCollateralRatio(1, 5000) // 50% - too low
      ).to.be.revertedWith("Invalid collateral ratio");
      
      await expect(
        synthFactory.setCollateralRatio(1, 50000) // 500% - too high
      ).to.be.revertedWith("Invalid collateral ratio");
    });

    it("Should set liquidation threshold", async function () {
      const newThreshold = 11000; // 110%
      
      await expect(
        synthFactory.setLiquidationThreshold(1, newThreshold)
      ).to.emit(synthFactory, "LiquidationThresholdUpdated")
      .withArgs(1, newThreshold);
      
      expect(await synthFactory.getLiquidationThreshold(1)).to.equal(newThreshold);
    });

    it("Should calculate collateral requirements", async function () {
      const synthAmount = ethers.parseEther("1"); // 1 sETH
      const ethPrice = TEST_CONSTANTS.PRICES.ETH;
      const collateralRatio = await synthFactory.getCollateralRatio(1);
      
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      
      // Should require collateral based on ratio
      const expectedCollateral = (BigInt(synthAmount) * BigInt(ethPrice) * BigInt(collateralRatio)) / BigInt(10000) / BigInt(1e12); // Convert to USDC decimals
      expect(requiredCollateral).to.equal(expectedCollateral);
    });
  });

  describe("Minting and Burning", function () {
    let sethAddress: string;

    beforeEach(async function () {
      const tx = await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      sethAddress = event.args[0];
      
      // Approve USDC spending
      await (usdc as any).connect(user1).approve(await synthFactory.getAddress(), toUsdc("50000"));
    });

    it("Should mint synthetic assets", async function () {
      const synthAmount = ethers.parseEther("1");
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      
      await expect(
        synthFactory.connect(user1).mintSynth(1, synthAmount, requiredCollateral)
      ).to.emit(synthFactory, "SynthMinted")
      .withArgs(1, user1.address, synthAmount);
      
      const synthContract = await ethers.getContractAt("SynthToken", sethAddress);
      expect(await synthContract.balanceOf(user1.address)).to.equal(synthAmount);
    });

    it("Should lock collateral when minting", async function () {
      const synthAmount = ethers.parseEther("1");
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      
      const initialBalance = await usdc.balanceOf(user1.address);
      
      await synthFactory.connect(user1).mintSynth(1, synthAmount, requiredCollateral);
      
      expect(await usdc.balanceOf(user1.address)).to.equal(initialBalance - requiredCollateral);
      expect(await synthFactory.getCollateralBalance(1, user1.address)).to.equal(requiredCollateral);
    });

    it("Should not allow minting with insufficient collateral", async function () {
      const synthAmount = ethers.parseEther("1");
      const insufficientCollateral = toUsdc("1000"); // Too little
      
      await expect(
        synthFactory.connect(user1).mintSynth(1, synthAmount, insufficientCollateral)
      ).to.be.revertedWith("Insufficient collateral");
    });

    it("Should burn synthetic assets", async function () {
      // First mint
      const synthAmount = ethers.parseEther("1");
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      await synthFactory.connect(user1).mintSynth(1, synthAmount, requiredCollateral);
      
      // Then burn
      const burnAmount = ethers.parseEther("0.5");
      const synthContract = await ethers.getContractAt("SynthToken", sethAddress);
      await synthContract.connect(user1).approve(await synthFactory.getAddress(), burnAmount);
      
      await expect(
        synthFactory.connect(user1).burnSynth(1, burnAmount)
      ).to.emit(synthFactory, "SynthBurned")
      .withArgs(1, user1.address, burnAmount);
      
      expect(await synthContract.balanceOf(user1.address)).to.equal(synthAmount - burnAmount);
    });

    it("Should release proportional collateral when burning", async function () {
      // Mint
      const synthAmount = ethers.parseEther("1");
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      await synthFactory.connect(user1).mintSynth(1, synthAmount, requiredCollateral);
      
      // Burn half
      const burnAmount = ethers.parseEther("0.5");
      const synthContract = await ethers.getContractAt("SynthToken", sethAddress);
      await synthContract.connect(user1).approve(await synthFactory.getAddress(), burnAmount);
      
      const initialUsdcBalance = await usdc.balanceOf(user1.address);
      
      await synthFactory.connect(user1).burnSynth(1, burnAmount);
      
      // Should receive half the collateral back
      const expectedReturn = requiredCollateral / 2n;
      expect(await usdc.balanceOf(user1.address)).to.equal(initialUsdcBalance + expectedReturn);
    });
  });

  describe("Liquidation Support", function () {
    let sethAddress: string;

    beforeEach(async function () {
      const tx = await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      sethAddress = event.args[0];
      
      // Setup position
      await (usdc as any).connect(user1).approve(await synthFactory.getAddress(), toUsdc("50000"));
      const synthAmount = ethers.parseEther("1");
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      await synthFactory.connect(user1).mintSynth(1, synthAmount, requiredCollateral);
    });

    it("Should calculate position health", async function () {
      const healthRatio = await synthFactory.getPositionHealth(1, user1.address);
      expect(healthRatio).to.be.gt(10000); // Should be healthy (>100%)
    });

    it("Should identify undercollateralized positions", async function () {
      // Simulate price drop
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 2n); // 50% price drop
      
      const isLiquidatable = await synthFactory.isPositionLiquidatable(1, user1.address);
      expect(isLiquidatable).to.be.true;
    });

    it("Should allow liquidation of underwater positions", async function () {
      // Create underwater position
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 2n);
      
      // Setup liquidator
      await (usdc as any).connect(user2).approve(await synthFactory.getAddress(), toUsdc("10000"));
      const synthContract = await ethers.getContractAt("SynthToken", sethAddress);
      await synthContract.connect(user1).transfer(user2.address, ethers.parseEther("0.5"));
      await synthContract.connect(user2).approve(await synthFactory.getAddress(), ethers.parseEther("0.5"));
      
      await expect(
        synthFactory.connect(user2).liquidatePosition(1, user1.address, ethers.parseEther("0.5"))
      ).to.emit(synthFactory, "PositionLiquidated");
    });
  });

  describe("Fee Management", function () {
    it("Should set minting fee", async function () {
      const newFee = 100; // 1%
      
      await expect(
        synthFactory.setMintingFee(newFee)
      ).to.emit(synthFactory, "MintingFeeUpdated")
      .withArgs(newFee);
      
      expect(await synthFactory.mintingFee()).to.equal(newFee);
    });

    it("Should set burning fee", async function () {
      const newFee = 50; // 0.5%
      
      await expect(
        synthFactory.setBurningFee(newFee)
      ).to.emit(synthFactory, "BurningFeeUpdated")
      .withArgs(newFee);
      
      expect(await synthFactory.burningFee()).to.equal(newFee);
    });

    it("Should collect fees to treasury", async function () {
      // Set fees
      await synthFactory.setMintingFee(100); // 1%
      
      // Create synth and mint
      const tx = await synthFactory.createSynth("Synthetic ETH", "sETH", 1);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "SynthCreated");
      const sethAddress = event.args[0];
      
      await (usdc as any).connect(user1).approve(await synthFactory.getAddress(), toUsdc("50000"));
      const synthAmount = ethers.parseEther("1");
      const requiredCollateral = await synthFactory.calculateRequiredCollateral(1, synthAmount);
      
      const initialTreasuryBalance = await usdc.balanceOf(treasury.address);
      
      await synthFactory.connect(user1).mintSynth(1, synthAmount, requiredCollateral);
      
      // Check fee collection
      const fee = (requiredCollateral * 100n) / 10000n; // 1%
      expect(await usdc.balanceOf(treasury.address)).to.equal(initialTreasuryBalance + fee);
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
        synthFactory.createSynth("Synthetic ETH", "sETH", 1)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should unpause factory", async function () {
      await synthFactory.pause();
      await synthFactory.unpause();
      expect(await synthFactory.paused()).to.be.false;
    });
  });
}); 