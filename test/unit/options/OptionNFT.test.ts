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

    // Deploy collateral vault (needs to be after OptionNFT, but OptionNFT needs vault address)
    // Deploy with placeholder address first, then set the correct address
    const CollateralVaultFactory = await ethers.getContractFactory("CollateralVault");
    const collateralVault = await CollateralVaultFactory.deploy(
      owner.address, // _owner
      owner.address // _optionNFT (placeholder, will be updated)
    );

    // Deploy option NFT
    const OptionNFTFactory = await ethers.getContractFactory("OptionNFT");
    const optionNFT = await OptionNFTFactory.deploy(
      "Unxversal Options", // name
      "UXO", // symbol
      await oracle.getAddress(), // _oracle
      await collateralVault.getAddress(), // _collateralVault
      owner.address, // _treasuryAddress (using owner as treasury for tests)
      owner.address // _owner
    );

    // Setup vault connection with correct OptionNFT address
    await collateralVault.setOptionNFTContract(await optionNFT.getAddress());

    // Setup asset oracles (required for the contract to work)
    await optionNFT.setAssetOracle(await weth.getAddress(), 1); // ETH oracle ID
    await optionNFT.setAssetOracle(await usdc.getAddress(), 3); // USDC oracle ID

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

  describe("Write Call Option", function () {
    const strikePrice = ethers.parseEther("2000"); // $2000
    const premium = ethers.parseEther("100"); // $100
    let expiryTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + (7 * 24 * 60 * 60); // 7 days
      
      // User needs WETH as collateral for call option
      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));
    });

    it("Should write call option successfully", async function () {
      await expect(
        optionNFT.connect(user1).writeOption(
          await weth.getAddress(), // underlying
          await usdc.getAddress(), // quote
          strikePrice,
          expiryTime,
          0, // OptionType.Call
          premium
        )
      ).to.emit(optionNFT, "OptionWritten");

      expect(await optionNFT.balanceOf(user1.address)).to.equal(1);
      expect(await optionNFT.ownerOf(1)).to.equal(user1.address);
    });

    it("Should store option data correctly", async function () {
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        0, // OptionType.Call
        premium
      );

      const option = await optionNFT.options(1);
      expect(option.underlying).to.equal(await weth.getAddress());
      expect(option.quote).to.equal(await usdc.getAddress());
      expect(option.strikePrice).to.equal(strikePrice);
      expect(option.expiry).to.equal(expiryTime);
      expect(option.premium).to.equal(premium);
      expect(option.optionType).to.equal(0); // Call
      expect(option.state).to.equal(0); // Active
    });

    it("Should revert with zero strike price", async function () {
      await expect(
        optionNFT.connect(user1).writeOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          0,
          expiryTime,
          0, // OptionType.Call
          premium
        )
      ).to.be.revertedWith("OptionNFT: Zero strike");
    });

    it("Should revert with zero premium", async function () {
      await expect(
        optionNFT.connect(user1).writeOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          strikePrice,
          expiryTime,
          0, // OptionType.Call
          0 // zero premium
        )
      ).to.be.revertedWith("OptionNFT: Zero premium");
    });

    it("Should lock collateral properly", async function () {
      const initialVaultBalance = await weth.balanceOf(await collateralVault.getAddress());
      
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        0, // OptionType.Call
        premium
      );

      // For call option, should lock 1 WETH as collateral
      const expectedCollateral = await optionNFT.getRequiredCollateral(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        0 // Call
      );
      
      expect(await weth.balanceOf(await collateralVault.getAddress())).to.equal(
        initialVaultBalance + expectedCollateral
      );
    });
  });

  describe("Write Put Option", function () {
    const strikePrice = ethers.parseEther("2000");
    const premium = ethers.parseEther("100");
    let expiryTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + (7 * 24 * 60 * 60);
      
      // User needs USDC as collateral for put option
      const requiredCollateral = await optionNFT.getRequiredCollateral(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        1 // Put
      );
      await usdc.connect(user1).approve(await optionNFT.getAddress(), requiredCollateral);
    });

    it("Should write put option successfully", async function () {
      await expect(
        optionNFT.connect(user1).writeOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          strikePrice,
          expiryTime,
          1, // OptionType.Put
          premium
        )
      ).to.emit(optionNFT, "OptionWritten");

      const option = await optionNFT.options(1);
      expect(option.optionType).to.equal(1); // Put
    });
  });

  describe("Exercise Option", function () {
    const strikePrice = ethers.parseEther("1500"); // $1500 strike (ITM when ETH = $2000)
    const premium = ethers.parseEther("100");
    let expiryTime: number;
    let optionId: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + (7 * 24 * 60 * 60);
      
      // User1 writes call option (needs WETH collateral)
      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        0, // OptionType.Call
        premium
      );
      optionId = 1;

      // User2 buys the option
      await usdc.connect(user2).approve(await optionNFT.getAddress(), premium);
      await optionNFT.connect(user1).buyOption(optionId);
    });

    it("Should buy option successfully", async function () {
      // This test checks the buyOption function 
      expect(await optionNFT.ownerOf(optionId)).to.equal(user2.address);
    });

    it("Should exercise ITM option successfully", async function () {
      // Option should be ITM (ETH at $2000, strike at $1500)
      expect(await optionNFT.isInTheMoney(optionId)).to.be.true;

      // User2 (option holder) exercises
      await expect(optionNFT.connect(user2).exerciseOption(optionId))
        .to.emit(optionNFT, "OptionExercised");

      // Option should be burned after exercise
      await expect(optionNFT.ownerOf(optionId)).to.be.reverted;
    });

    it("Should revert exercise of expired option", async function () {
      // Fast forward past expiry
      await time.increaseTo(expiryTime + 1);

      await expect(
        optionNFT.connect(user2).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Option expired");
    });

    it("Should revert exercise by non-owner", async function () {
      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Not owner");
    });

    it("Should revert exercise if OTM", async function () {
      // Set ETH price below strike (OTM)
      await oracle.setPrice(1, ethers.parseEther("1000")); // $1000 < $1500 strike

      await expect(
        optionNFT.connect(user2).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Not in the money");
    });
  });

  describe("Option Transfer", function () {
    const strikePrice = ethers.parseEther("2000");
    const premium = ethers.parseEther("100");
    let expiryTime: number;
    let optionId: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + (7 * 24 * 60 * 60);
      
      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        strikePrice,
        expiryTime,
        0, // OptionType.Call
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

      // Set price to make option ITM
      await oracle.setPrice(1, ethers.parseEther("2500")); // $2500 > $2000 strike

      // New owner should be able to exercise
      await expect(optionNFT.connect(user2).exerciseOption(optionId))
        .to.emit(optionNFT, "OptionExercised");
    });

    it("Should prevent old owner from exercising after transfer", async function () {
      await optionNFT.connect(user1).transferFrom(user1.address, user2.address, optionId);

      await expect(
        optionNFT.connect(user1).exerciseOption(optionId)
      ).to.be.revertedWith("OptionNFT: Not owner");
    });
  });

  describe("Option Valuation", function () {
    const strikePrice = ethers.parseEther("2000");
    const premium = ethers.parseEther("100");
    let expiryTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      expiryTime = currentTime + (7 * 24 * 60 * 60);
    });

    it("Should calculate exercise value for ITM call", async function () {
      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("1500"), // $1500 strike
        expiryTime,
        0, // OptionType.Call
        premium
      );

      const exerciseValue = await optionNFT.getExerciseValue(1);
      
      // ETH at $2000, strike at $1500, so value = $500
      const expectedValue = ethers.parseEther("500");
      expect(exerciseValue).to.equal(expectedValue);
    });

    it("Should return zero exercise value for OTM call", async function () {
      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("2500"), // $2500 strike
        expiryTime,
        0, // OptionType.Call
        premium
      );

      const exerciseValue = await optionNFT.getExerciseValue(1);
      expect(exerciseValue).to.equal(0);
    });

    it("Should calculate exercise value for ITM put", async function () {
      const requiredCollateral = await optionNFT.getRequiredCollateral(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("2500"),
        1 // Put
      );
      await usdc.connect(user1).approve(await optionNFT.getAddress(), requiredCollateral);
      await optionNFT.connect(user1).writeOption(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseEther("2500"), // $2500 strike
        expiryTime,
        1, // OptionType.Put
        premium
      );

      const exerciseValue = await optionNFT.getExerciseValue(1);
      
      // ETH at $2000, strike at $2500, so value = $500
      const expectedValue = ethers.parseEther("500");
      expect(exerciseValue).to.equal(expectedValue);
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to pause contract", async function () {
      await optionNFT.pause();
      expect(await optionNFT.paused()).to.be.true;

      const currentTime = await time.latest();
      const expiryTime = currentTime + (7 * 24 * 60 * 60);

      await weth.connect(user1).approve(await optionNFT.getAddress(), toEth("1"));
      await expect(
        optionNFT.connect(user1).writeOption(
          await weth.getAddress(),
          await usdc.getAddress(),
          ethers.parseEther("2000"),
          expiryTime,
          0, // OptionType.Call
          ethers.parseEther("100")
        )
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should not allow non-owner to pause", async function () {
      await expect(
        optionNFT.connect(user1).pause()
      ).to.be.revertedWithCustomError(optionNFT, "OwnableUnauthorizedAccount");
    });

    it("Should allow owner to set fee parameters", async function () {
      const newFee = 50; // 0.5%
      
      await expect(optionNFT.setExerciseFeeBps(newFee))
        .to.emit(optionNFT, "ExerciseFeeSet")
        .withArgs(newFee);
    });
  });
}); 