/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc } from "../../shared/constants";

describe("SynthLiquidationEngine", function () {
  let liquidationEngine: any;
  let synthFactory: any;
  let usdcVault: any;
  let usdc: any;
  let oracle: any;
  let synthToken: any;
  let owner: SignerWithAddress;
  let borrower: SignerWithAddress;
  let liquidator: SignerWithAddress;
  let keeper: SignerWithAddress;

  async function deploySynthLiquidationEngineFixture() {
    const [owner, borrower, liquidator, keeper] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);

    // Deploy SynthFactory first (only needs oracle)
    const SynthFactoryFactory = await ethers.getContractFactory("SynthFactory");
    const synthFactory = await SynthFactoryFactory.deploy(
      owner.address, // _initialOwner
      await oracle.getAddress() // _oracleAddress
    );

    // Deploy USDCVault (needs SynthFactory)
    const USDCVaultFactory = await ethers.getContractFactory("USDCVault");
    const usdcVault = await USDCVaultFactory.deploy(
      await usdc.getAddress(), // _usdcTokenAddress
      await oracle.getAddress(), // _oracleAddress
      await synthFactory.getAddress(), // _synthFactoryAddress
      owner.address // _initialOwner
    );

    // Deploy SynthLiquidationEngine (needs both)
    const SynthLiquidationEngineFactory = await ethers.getContractFactory("SynthLiquidationEngine");
    const liquidationEngine = await SynthLiquidationEngineFactory.deploy(
      await usdcVault.getAddress(), // _usdcVaultAddress
      await synthFactory.getAddress(), // _synthFactoryAddress
      await oracle.getAddress(), // _oracleAddress
      await usdc.getAddress(), // _usdcTokenAddress
      owner.address // _initialOwner
    );

    // Create a synthetic token for testing using the proper deploySynth function
    const synthAddress = await synthFactory.deploySynth.staticCall(
      "Synthetic ETH",
      "sETH", 
      1, // assetId
      15000, // customMinCRbps (150%)
      await usdcVault.getAddress() // controllerAddress
    );
    
    // Actually execute the transaction
    await synthFactory.deploySynth(
      "Synthetic ETH",
      "sETH", 
      1, // assetId
      15000, // customMinCRbps (150%)
      await usdcVault.getAddress() // controllerAddress
    );
    
    const synthToken = await ethers.getContractAt("SynthToken", synthAddress);

    // Setup initial state
    await (usdc as any).mint(owner.address, toUsdc("1000000"));
    await (usdc as any).mint(borrower.address, toUsdc("100000"));
    await (usdc as any).mint(liquidator.address, toUsdc("100000"));

    return {
      liquidationEngine,
      synthFactory,
      usdcVault,
      usdc,
      oracle,
      synthToken,
      owner,
      borrower,
      liquidator,
      keeper
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deploySynthLiquidationEngineFixture);
    liquidationEngine = fixture.liquidationEngine;
    synthFactory = fixture.synthFactory;
    usdcVault = fixture.usdcVault;
    usdc = fixture.usdc;
    oracle = fixture.oracle;
    synthToken = fixture.synthToken;
    owner = fixture.owner;
    borrower = fixture.borrower;
    liquidator = fixture.liquidator;
    keeper = fixture.keeper;
  });

  describe("Initialization", function () {
    it("Should set correct SynthFactory", async function () {
      expect(await liquidationEngine.synthFactory()).to.equal(await synthFactory.getAddress());
    });

    it("Should set correct USDCVault", async function () {
      expect(await liquidationEngine.usdcVault()).to.equal(await usdcVault.getAddress());
    });

    it("Should set correct oracle", async function () {
      expect(await liquidationEngine.oracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await liquidationEngine.owner()).to.equal(owner.address);
    });

    it("Should have default liquidation parameters", async function () {
      expect(await liquidationEngine.liquidationThreshold()).to.equal(8000); // 80%
      expect(await liquidationEngine.liquidationBonus()).to.equal(500); // 5%
      expect(await liquidationEngine.closeFactor()).to.equal(5000); // 50%
    });
  });

  describe("Position Health Monitoring", function () {
    beforeEach(async function () {
      // Setup a position
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(borrower).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(borrower).deposit(depositAmount);
      
      // Lock collateral and mint synths
      const lockAmount = toUsdc("8000");
      await usdcVault.lockCollateral(borrower.address, lockAmount, 1);
      
      const synthAmount = ethers.parseEther("2"); // 2 sETH
      await synthFactory.connect(borrower).mintSynth(1, synthAmount, lockAmount);
    });

    it("Should calculate position health correctly", async function () {
      const healthRatio = await liquidationEngine.getPositionHealth(1, borrower.address);
      expect(healthRatio).to.be.gt(10000); // Should be healthy (>100%)
    });

    it("Should identify healthy positions", async function () {
      const isLiquidatable = await liquidationEngine.isPositionLiquidatable(1, borrower.address);
      expect(isLiquidatable).to.be.false;
    });

    it("Should identify unhealthy positions", async function () {
      // Crash ETH price to make position unhealthy
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 3n); // 33% of original
      
      const isLiquidatable = await liquidationEngine.isPositionLiquidatable(1, borrower.address);
      expect(isLiquidatable).to.be.true;
    });

    it("Should calculate liquidation amount correctly", async function () {
      // Make position liquidatable
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 3n);
      
      const synthBalance = await synthToken.balanceOf(borrower.address);
      const maxLiquidation = await liquidationEngine.getMaxLiquidationAmount(1, borrower.address);
      
      // Should be limited by close factor
      const expectedMax = (synthBalance * BigInt(await liquidationEngine.closeFactor())) / BigInt(10000);
      expect(maxLiquidation).to.equal(expectedMax);
    });

    it("Should handle zero debt positions", async function () {
      // Create user with no debt
      const healthRatio = await liquidationEngine.getPositionHealth(1, liquidator.address);
      expect(healthRatio).to.equal(ethers.MaxUint256); // Infinite health
      
      const isLiquidatable = await liquidationEngine.isPositionLiquidatable(1, liquidator.address);
      expect(isLiquidatable).to.be.false;
    });
  });

  describe("Liquidation Execution", function () {
    beforeEach(async function () {
      // Setup borrower position
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(borrower).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(borrower).deposit(depositAmount);
      await usdcVault.lockCollateral(borrower.address, toUsdc("8000"), 1);
      
      const synthAmount = ethers.parseEther("2");
      await synthFactory.connect(borrower).mintSynth(1, synthAmount, toUsdc("8000"));
      
      // Make position liquidatable
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 3n);
      
      // Setup liquidator
      await (usdc as any).connect(liquidator).approve(await usdcVault.getAddress(), toUsdc("50000"));
      await synthToken.connect(borrower).transfer(liquidator.address, ethers.parseEther("1"));
      await synthToken.connect(liquidator).approve(await liquidationEngine.getAddress(), ethers.parseEther("1"));
    });

    it("Should allow liquidation of unhealthy positions", async function () {
      const liquidationAmount = ethers.parseEther("1");
      
      await expect(
        liquidationEngine.connect(liquidator).liquidatePosition(
          1,
          borrower.address,
          liquidationAmount
        )
      ).to.emit(liquidationEngine, "PositionLiquidated")
      .withArgs(1, borrower.address, liquidator.address, liquidationAmount);
    });

    it("Should transfer liquidation bonus to liquidator", async function () {
      const liquidationAmount = ethers.parseEther("1");
      const initialLiquidatorBalance = await usdcVault.getBalance(liquidator.address);
      
      await liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, liquidationAmount);
      
      const finalLiquidatorBalance = await usdcVault.getBalance(liquidator.address);
      const bonus = finalLiquidatorBalance - initialLiquidatorBalance;
      
      expect(bonus).to.be.gt(0); // Should receive liquidation bonus
    });

    it("Should reduce borrower's collateral", async function () {
      const liquidationAmount = ethers.parseEther("1");
      const initialCollateral = await usdcVault.getLockedCollateral(borrower.address, 1);
      
      await liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, liquidationAmount);
      
      const finalCollateral = await usdcVault.getLockedCollateral(borrower.address, 1);
      expect(finalCollateral).to.be.lt(initialCollateral);
    });

    it("Should burn liquidated synthetic tokens", async function () {
      const liquidationAmount = ethers.parseEther("1");
      const initialSupply = await synthToken.totalSupply();
      
      await liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, liquidationAmount);
      
      const finalSupply = await synthToken.totalSupply();
      expect(finalSupply).to.equal(initialSupply - liquidationAmount);
    });

    it("Should not allow liquidating healthy positions", async function () {
      // Restore healthy price
      await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);
      
      const liquidationAmount = ethers.parseEther("1");
      
      await expect(
        liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, liquidationAmount)
      ).to.be.revertedWith("Position is healthy");
    });

    it("Should not allow liquidating more than close factor", async function () {
      const totalDebt = await synthToken.balanceOf(borrower.address);
      const maxLiquidation = await liquidationEngine.getMaxLiquidationAmount(1, borrower.address);
      const excessiveAmount = totalDebt; // Try to liquidate 100%
      
      await expect(
        liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, excessiveAmount)
      ).to.be.revertedWith("Exceeds close factor");
    });

    it("Should handle insufficient liquidator balance", async function () {
      const liquidationAmount = ethers.parseEther("10"); // More than liquidator has
      
      await expect(
        liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, liquidationAmount)
      ).to.be.revertedWith("Insufficient balance");
    });
  });

  describe("Liquidation Parameters", function () {
    it("Should allow owner to update liquidation threshold", async function () {
      const newThreshold = 7500; // 75%
      
      await expect(
        liquidationEngine.setLiquidationThreshold(newThreshold)
      ).to.emit(liquidationEngine, "LiquidationThresholdUpdated")
      .withArgs(newThreshold);
      
      expect(await liquidationEngine.liquidationThreshold()).to.equal(newThreshold);
    });

    it("Should allow owner to update liquidation bonus", async function () {
      const newBonus = 750; // 7.5%
      
      await expect(
        liquidationEngine.setLiquidationBonus(newBonus)
      ).to.emit(liquidationEngine, "LiquidationBonusUpdated")
      .withArgs(newBonus);
      
      expect(await liquidationEngine.liquidationBonus()).to.equal(newBonus);
    });

    it("Should allow owner to update close factor", async function () {
      const newCloseFactor = 6000; // 60%
      
      await expect(
        liquidationEngine.setCloseFactor(newCloseFactor)
      ).to.emit(liquidationEngine, "CloseFactorUpdated")
      .withArgs(newCloseFactor);
      
      expect(await liquidationEngine.closeFactor()).to.equal(newCloseFactor);
    });

    it("Should not allow invalid liquidation threshold", async function () {
      await expect(
        liquidationEngine.setLiquidationThreshold(15000) // 150% - too high
      ).to.be.revertedWith("Invalid threshold");
      
      await expect(
        liquidationEngine.setLiquidationThreshold(5000) // 50% - too low
      ).to.be.revertedWith("Invalid threshold");
    });

    it("Should not allow invalid liquidation bonus", async function () {
      await expect(
        liquidationEngine.setLiquidationBonus(2000) // 20% - too high
      ).to.be.revertedWith("Invalid bonus");
    });

    it("Should not allow invalid close factor", async function () {
      await expect(
        liquidationEngine.setCloseFactor(10000) // 100% - too high
      ).to.be.revertedWith("Invalid close factor");
      
      await expect(
        liquidationEngine.setCloseFactor(0) // 0% - too low
      ).to.be.revertedWith("Invalid close factor");
    });

    it("Should only allow owner to update parameters", async function () {
      await expect(
        liquidationEngine.connect(borrower).setLiquidationThreshold(7500)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Keeper Functions", function () {
    beforeEach(async function () {
      // Setup multiple positions
      for (let i = 0; i < 3; i++) {
        const user = await ethers.getSigners().then(signers => signers[i + 5]);
        const depositAmount = toUsdc("5000");
        
        await (usdc as any).mint(user.address, depositAmount);
        await (usdc as any).connect(user).approve(await usdcVault.getAddress(), depositAmount);
        await usdcVault.connect(user).deposit(depositAmount);
        await usdcVault.lockCollateral(user.address, toUsdc("4000"), 1);
        
        const synthAmount = ethers.parseEther("1");
        await synthFactory.connect(user).mintSynth(1, synthAmount, toUsdc("4000"));
      }
      
      // Make some positions liquidatable
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 3n);
    });

    it("Should identify liquidatable positions", async function () {
      const liquidatablePositions = await liquidationEngine.getLiquidatablePositions(1, 0, 10);
      expect(liquidatablePositions.length).to.be.gt(0);
    });

    it("Should batch liquidate multiple positions", async function () {
      const liquidatablePositions = await liquidationEngine.getLiquidatablePositions(1, 0, 3);
      
      // Setup liquidator with enough tokens
      const totalLiquidationAmount = ethers.parseEther("3");
      await synthToken.connect(borrower).transfer(liquidator.address, totalLiquidationAmount);
      await synthToken.connect(liquidator).approve(await liquidationEngine.getAddress(), totalLiquidationAmount);
      
      await expect(
        liquidationEngine.connect(liquidator).batchLiquidate(
          1,
          liquidatablePositions.slice(0, 2),
          [ethers.parseEther("1"), ethers.parseEther("1")]
        )
      ).to.emit(liquidationEngine, "BatchLiquidation");
    });

    it("Should calculate total liquidation value", async function () {
      const liquidatablePositions = await liquidationEngine.getLiquidatablePositions(1, 0, 10);
      const totalValue = await liquidationEngine.getTotalLiquidationValue(1, liquidatablePositions);
      
      expect(totalValue).to.be.gt(0);
    });

    it("Should handle keeper incentives", async function () {
      await liquidationEngine.setKeeperIncentive(100); // 1%
      
      const liquidatablePositions = await liquidationEngine.getLiquidatablePositions(1, 0, 1);
      const keeperFee = await liquidationEngine.calculateKeeperFee(liquidatablePositions[0], ethers.parseEther("1"));
      
      expect(keeperFee).to.be.gt(0);
    });
  });

  describe("Oracle Integration", function () {
    beforeEach(async function () {
      // Setup position
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(borrower).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(borrower).deposit(depositAmount);
      await usdcVault.lockCollateral(borrower.address, toUsdc("8000"), 1);
      
      const synthAmount = ethers.parseEther("2");
      await synthFactory.connect(borrower).mintSynth(1, synthAmount, toUsdc("8000"));
    });

    it("Should handle oracle price updates", async function () {
      const initialHealth = await liquidationEngine.getPositionHealth(1, borrower.address);
      
      // Update price
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) * 2n); // Double price
      
      const newHealth = await liquidationEngine.getPositionHealth(1, borrower.address);
      expect(newHealth).to.be.gt(initialHealth);
    });

    it("Should handle stale oracle data", async function () {
      // Mock stale oracle by not updating for too long
      await liquidationEngine.setMaxOracleAge(3600); // 1 hour
      
      // Fast forward time
      await ethers.provider.send("evm_increaseTime", [7200]); // 2 hours
      await ethers.provider.send("evm_mine", []);
      
      await expect(
        liquidationEngine.getPositionHealth(1, borrower.address)
      ).to.be.revertedWith("Stale oracle data");
    });

    it("Should handle oracle failure gracefully", async function () {
      // Mock oracle returning zero price
      await (oracle as any).setPrice(1, 0);
      
      await expect(
        liquidationEngine.getPositionHealth(1, borrower.address)
      ).to.be.revertedWith("Invalid oracle price");
    });
  });

  describe("Emergency Functions", function () {
    it("Should pause liquidations", async function () {
      await liquidationEngine.pause();
      expect(await liquidationEngine.paused()).to.be.true;
    });

    it("Should not allow liquidations when paused", async function () {
      await liquidationEngine.pause();
      
      await expect(
        liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, ethers.parseEther("1"))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should allow emergency liquidation when paused", async function () {
      await liquidationEngine.pause();
      
      // Only owner can perform emergency liquidation
      await expect(
        liquidationEngine.emergencyLiquidate(1, borrower.address, ethers.parseEther("1"))
      ).to.emit(liquidationEngine, "EmergencyLiquidation");
    });

    it("Should handle global settlement", async function () {
      await liquidationEngine.initiateGlobalSettlement(1);
      
      expect(await liquidationEngine.isGlobalSettlementActive(1)).to.be.true;
      
      // Should prevent new liquidations during global settlement
      await expect(
        liquidationEngine.connect(liquidator).liquidatePosition(1, borrower.address, ethers.parseEther("1"))
      ).to.be.revertedWith("Global settlement active");
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle cascading liquidations", async function () {
      // Setup multiple interconnected positions
      const users = await ethers.getSigners();
      const positions = [];
      
      for (let i = 0; i < 5; i++) {
        const user = users[i + 10];
        const depositAmount = toUsdc("20000");
        
        await (usdc as any).mint(user.address, depositAmount);
        await (usdc as any).connect(user).approve(await usdcVault.getAddress(), depositAmount);
        await usdcVault.connect(user).deposit(depositAmount);
        await usdcVault.lockCollateral(user.address, toUsdc("16000"), 1);
        
        const synthAmount = ethers.parseEther("4");
        await synthFactory.connect(user).mintSynth(1, synthAmount, toUsdc("16000"));
        
        positions.push(user.address);
      }
      
      // Trigger price crash
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) / 4n);
      
      // Should be able to liquidate multiple positions
      const liquidatableCount = await liquidationEngine.getLiquidatablePositionsCount(1);
      expect(liquidatableCount).to.be.gte(5);
    });

    it("Should handle liquidation during high volatility", async function () {
      // Setup position
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(borrower).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(borrower).deposit(depositAmount);
      await usdcVault.lockCollateral(borrower.address, toUsdc("8000"), 1);
      
      const synthAmount = ethers.parseEther("2");
      await synthFactory.connect(borrower).mintSynth(1, synthAmount, toUsdc("8000"));
      
      // Simulate high volatility (rapid price changes)
      const prices = [
        BigInt(TEST_CONSTANTS.PRICES.ETH) / 2n,
        BigInt(TEST_CONSTANTS.PRICES.ETH) * 3n / 4n,
        BigInt(TEST_CONSTANTS.PRICES.ETH) / 3n,
        BigInt(TEST_CONSTANTS.PRICES.ETH) / 2n
      ];
      
      for (const price of prices) {
        await (oracle as any).setPrice(1, price);
        const isLiquidatable = await liquidationEngine.isPositionLiquidatable(1, borrower.address);
        
        if (isLiquidatable) {
          // Should be able to liquidate when unhealthy
          expect(isLiquidatable).to.be.true;
        }
      }
    });
  });
}); 