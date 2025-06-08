/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
/* eslint-disable @typescript-eslint/no-unused-vars */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc, toEth } from "../../shared/constants";

describe("OptionNFT", function () {
  let optionNFT: any;
  let collateralVault: any;
  let usdc: any;
  let weth: any;
  let oracle: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  async function deployOptionNFTFixture() {
    const [owner, user1, user2] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USD Coin", "USDC", 6, toUsdc("1000000"));
    const weth = await MockERC20Factory.deploy("Wrapped Ethereum", "WETH", 18, toEth("10000"));

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await oracle.setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
    await oracle.setPrice(3, TEST_CONSTANTS.PRICES.USDC); // USDC

    // Deploy collateral vault
    const CollateralVaultFactory = await ethers.getContractFactory("CollateralVault");
    const collateralVault = await CollateralVaultFactory.deploy(
      await usdc.getAddress(),
      await oracle.getAddress(),
      owner.address
    );

    // Deploy option NFT
    const OptionNFTFactory = await ethers.getContractFactory("OptionNFT");
    const optionNFT = await OptionNFTFactory.deploy(
      await collateralVault.getAddress(),
      await oracle.getAddress(),
      "Unxversal Options",
      "UXO",
      owner.address
    );

    // Setup vault connection
    await collateralVault.setOptionNFT(await optionNFT.getAddress());

    // Fund users
    await usdc.transfer(user1.address, toUsdc("10000"));
    await usdc.transfer(user2.address, toUsdc("10000"));
    await weth.transfer(user1.address, toEth("10"));
    await weth.transfer(user2.address, toEth("10"));

    return {
      optionNFT,
      collateralVault,
      usdc,
      weth,
      oracle,
      owner,
      user1,
      user2
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployOptionNFTFixture);
    optionNFT = fixture.optionNFT;
    collateralVault = fixture.collateralVault;
    usdc = fixture.usdc;
    weth = fixture.weth;
    oracle = fixture.oracle;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
  });

  describe("Deployment", function () {
    it("Should set correct collateral vault", async function () {
      expect(await optionNFT.collateralVault()).to.equal(await collateralVault.getAddress());
    });

    it("Should set correct oracle", async function () {
      expect(await optionNFT.oracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct NFT metadata", async function () {
      expect(await optionNFT.name()).to.equal("Unxversal Options");
      expect(await optionNFT.symbol()).to.equal("UXO");
    });

    it("Should set owner correctly", async function () {
      expect(await optionNFT.owner()).to.equal(owner.address);
    });
  });

  describe("Create Call Option", function () {
    const strikePrice = TEST_CONSTANTS.OPTIONS.DEFAULT_STRIKE_PRICE; // $2000
    const premium = TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM; // $100
    let expiryTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;
      
      // Approve USDC for premium
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
    });

    it("Should create call option successfully", async function () {
      await expect(
        optionNFT.connect(user1).createCallOption(
          await weth.getAddress(), // underlying
          await usdc.getAddress(), // quote
          strikePrice,
          expiryTime,
          premium
        )
      ).to.emit(optionNFT, "OptionCreated");

      expect(await optionNFT.balanceOf(user1.address)).to.equal(1);
      expect(await optionNFT.ownerOf(1)).to.equal(user1.address);
    });

    it("Should store option data correctly", async function () {
      await optionNFT.connect(user1).createCallOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        premium
      );

      const option = await optionNFT.options(1);
      expect(option.underlying).to.equal(await weth.getAddress());
      expect(option.quote).to.equal(await usdc.getAddress());
      expect(option.strikePrice).to.equal(strikePrice);
      expect(option.expiry).to.equal(expiryTime);
      expect(option.premium).to.equal(premium);
      expect(option.isCall).to.be.true;
      expect(option.isExercised).to.be.false;
    });

    it("Should revert with zero strike price", async function () {
      await expect(
        optionNFT.connect(user1).createCallOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          0,
          expiryTime,
          premium
        )
      ).to.be.revertedWith("OptionNFT: Zero strike price");
    });

    it("Should revert with past expiry", async function () {
      const pastExpiry = (await time.latest()) - 1000;
      
      await expect(
        optionNFT.connect(user1).createCallOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          strikePrice,
          pastExpiry,
          premium
        )
      ).to.be.revertedWith("OptionNFT: Invalid expiry");
    });

    it("Should revert with zero premium", async function () {
      await expect(
        optionNFT.connect(user1).createCallOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          strikePrice,
          expiryTime,
          0
        )
      ).to.be.revertedWith("OptionNFT: Zero premium");
    });

    it("Should lock premium in collateral vault", async function () {
      const initialVaultBalance = await usdc.balanceOf(await collateralVault.getAddress());
      
      await optionNFT.connect(user1).createCallOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        premium
      );

      expect(await usdc.balanceOf(await collateralVault.getAddress())).to.equal(
        initialVaultBalance + BigInt(premium)
      );
    });
  });

  describe("Create Put Option", function () {
    const strikePrice = TEST_CONSTANTS.OPTIONS.DEFAULT_STRIKE_PRICE;
    const premium = TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM;
    let expiryTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;
      
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
    });

    it("Should create put option successfully", async function () {
      await expect(
        optionNFT.connect(user1).createPutOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          strikePrice,
          expiryTime,
          premium
        )
      ).to.emit(optionNFT, "OptionCreated");

      const option = await optionNFT.options(1);
      expect(option.isCall).to.be.false;
    });

    it("Should handle different underlying assets", async function () {
      await optionNFT.connect(user1).createPutOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        premium
      );

      const option = await optionNFT.options(1);
      expect(option.underlying).to.equal(await weth.getAddress());
      expect(option.quote).to.equal(await usdc.getAddress());
    });
  });

  describe("Exercise Call Option", function () {
    const strikePrice = ethers.parseEther("1500"); // $1500 strike (ITM when ETH = $2000)
    const premium = TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM;
    let expiryTime: number;
    let optionId: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;
      
      // Create call option
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).createCallOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        premium
      );
      optionId = 1;

      // User needs USDC to exercise (pay strike price)
      const exerciseAmount = toUsdc("1500"); // $1500 in USDC
      await usdc.connect(user1).approve(await optionNFT.getAddress(), exerciseAmount);

      // Vault needs WETH to deliver
      await weth.connect(owner).transfer(await collateralVault.getAddress(), toEth("1"));
    });

    it("Should exercise ITM call option successfully", async function () {
      const initialWethBalance = await weth.balanceOf(user1.address);
      const initialUsdcBalance = await usdc.balanceOf(user1.address);

      await expect(optionNFT.connect(user1).exerciseOption(optionId))
        .to.emit(optionNFT, "OptionExercised")
        .withArgs(optionId, user1.address);

      // User should receive WETH and pay USDC
      expect(await weth.balanceOf(user1.address)).to.be.gt(initialWethBalance);
      expect(await usdc.balanceOf(user1.address)).to.be.lt(initialUsdcBalance);

      // Option should be marked as exercised
      const option = await optionNFT.options(optionId);
      expect(option.isExercised).to.be.true;
    });

    it("Should revert exercise of expired option", async function () {
      // Fast forward past expiry
      await time.increaseTo(expiryTime + 1);

      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Option expired");
    });

    it("Should revert exercise by non-owner", async function () {
      await expect(
        optionNFT.connect(user2).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Not option owner");
    });

    it("Should revert double exercise", async function () {
      await optionNFT.connect(user1).exerciseOption(optionId);

      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Already exercised");
    });

    it("Should revert exercise if OTM", async function () {
      // Set ETH price below strike (OTM)
      await oracle.setPrice(1, ethers.parseEther("1000")); // $1000 < $1500 strike

      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Option out of money");
    });
  });

  describe("Exercise Put Option", function () {
    const strikePrice = ethers.parseEther("2500"); // $2500 strike (ITM when ETH = $2000)
    const premium = TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM;
    let expiryTime: number;
    let optionId: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;
      
      // Create put option
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).createPutOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        premium
      );
      optionId = 1;

      // User needs WETH to exercise (sell to put)
      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));

      // Vault needs USDC to pay
      await usdc.connect(owner).transfer(await collateralVault.getAddress(), toUsdc("2500"));
    });

    it("Should exercise ITM put option successfully", async function () {
      const initialWethBalance = await weth.balanceOf(user1.address);
      const initialUsdcBalance = await usdc.balanceOf(user1.address);

      await expect(optionNFT.connect(user1).exerciseOption(optionId))
        .to.emit(optionNFT, "OptionExercised");

      // User should pay WETH and receive USDC
      expect(await weth.balanceOf(user1.address)).to.be.lt(initialWethBalance);
      expect(await usdc.balanceOf(user1.address)).to.be.gt(initialUsdcBalance);
    });

    it("Should revert exercise if OTM", async function () {
      // Set ETH price above strike (OTM for put)
      await oracle.setPrice(1, ethers.parseEther("3000")); // $3000 > $2500 strike

      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Option out of money");
    });
  });

  describe("Option Transfer", function () {
    const strikePrice = TEST_CONSTANTS.OPTIONS.DEFAULT_STRIKE_PRICE;
    const premium = TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM;
    let expiryTime: number;
    let optionId: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;
      
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).createCallOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        premium
      );
      optionId = 1;
    });

    it("Should allow option transfer", async function () {
      await optionNFT.connect(user1).transferFrom(user1.address, user2.address, optionId);

      expect(await optionNFT.ownerOf(optionId)).to.equal(user2.address);
      expect(await optionNFT.balanceOf(user1.address)).to.equal(0);
      expect(await optionNFT.balanceOf(user2.address)).to.equal(1);
    });

    it("Should allow new owner to exercise", async function () {
      // Transfer option
      await optionNFT.connect(user1).transferFrom(user1.address, user2.address, optionId);

      // Setup for exercise
      await usdc.connect(user2).approve(await optionNFT.getAddress(), toUsdc("2000"));
      await weth.connect(owner).transfer(await collateralVault.getAddress(), toEth("1"));

      // New owner should be able to exercise
      await expect(optionNFT.connect(user2).exerciseOption(optionId))
        .to.emit(optionNFT, "OptionExercised");
    });

    it("Should prevent old owner from exercising after transfer", async function () {
      await optionNFT.connect(user1).transferFrom(user1.address, user2.address, optionId);

      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Not option owner");
    });
  });

  describe("Option Valuation", function () {
    const strikePrice = TEST_CONSTANTS.OPTIONS.DEFAULT_STRIKE_PRICE;
    const premium = TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM;
    let expiryTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;
    });

    it("Should calculate intrinsic value for ITM call", async function () {
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).createCallOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("1500"), // $1500 strike
        expiryTime,
        premium
      );

      const intrinsicValue = await optionNFT.getIntrinsicValue(1);
      
      // ETH at $2000, strike at $1500, so intrinsic = $500
      const expectedValue = ethers.parseEther("500");
      expect(intrinsicValue).to.equal(expectedValue);
    });

    it("Should return zero intrinsic value for OTM call", async function () {
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).createCallOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("2500"), // $2500 strike
        expiryTime,
        premium
      );

      const intrinsicValue = await optionNFT.getIntrinsicValue(1);
      expect(intrinsicValue).to.equal(0);
    });

    it("Should calculate intrinsic value for ITM put", async function () {
      await usdc.connect(user1).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).createPutOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("2500"), // $2500 strike
        expiryTime,
        premium
      );

      const intrinsicValue = await optionNFT.getIntrinsicValue(1);
      
      // ETH at $2000, strike at $2500, so intrinsic = $500
      const expectedValue = ethers.parseEther("500");
      expect(intrinsicValue).to.equal(expectedValue);
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to pause contract", async function () {
      await optionNFT.pause();
      expect(await optionNFT.paused()).to.be.true;

      const currentTime = await time.latest();
      const expiryTime = currentTime + TEST_CONSTANTS.OPTIONS.DEFAULT_EXPIRY_DAYS * 24 * 60 * 60;

      await expect(
        optionNFT.connect(user1).createCallOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          TEST_CONSTANTS.OPTIONS.DEFAULT_STRIKE_PRICE,
          expiryTime,
          TEST_CONSTANTS.OPTIONS.DEFAULT_PREMIUM
        )
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should not allow non-owner to pause", async function () {
      await expect(
        optionNFT.connect(user1).pause()
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should allow owner to set fee parameters", async function () {
      const newFee = 50; // 0.5%
      
      await expect(optionNFT.setExerciseFee(newFee))
        .to.emit(optionNFT, "ExerciseFeeUpdated")
        .withArgs(newFee);
    });
  });
}); 