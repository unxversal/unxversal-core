/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc } from "../../shared/constants";

describe("USDCVault", function () {
  let usdcVault: any;
  let usdc: any;
  let synthFactory: any;
  let yieldStrategy: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let treasury: SignerWithAddress;
  let liquidator: SignerWithAddress;

  async function deployUSDCVaultFixture() {
    const [owner, user1, user2, treasury, liquidator] = await ethers.getSigners();

    // Deploy mock USDC
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);

    // Deploy mock yield strategy (could be Compound, Aave, etc.)
    const yieldStrategy = await MockERC20Factory.deploy("Strategy Token", "ST", 18, 0);

    // Deploy mock oracle 
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);

    // Deploy SynthFactory first (needed by USDCVault)
    const SynthFactoryFactory = await ethers.getContractFactory("SynthFactory");
    const synthFactory = await SynthFactoryFactory.deploy(
      owner.address, // _initialOwner
      await oracle.getAddress() // _oracleAddress
    );

    // Deploy USDCVault
    const USDCVaultFactory = await ethers.getContractFactory("USDCVault");
    const usdcVault = await USDCVaultFactory.deploy(
      await usdc.getAddress(), // _usdcTokenAddress
      await oracle.getAddress(), // _oracleAddress
      await synthFactory.getAddress(), // _synthFactoryAddress
      owner.address // _initialOwner
    );

    // Setup initial state
    await (usdc as any).mint(owner.address, toUsdc("1000000"));
    await (usdc as any).mint(user1.address, toUsdc("100000"));
    await (usdc as any).mint(user2.address, toUsdc("100000"));
    await (usdc as any).mint(liquidator.address, toUsdc("50000"));

    return {
      usdcVault,
      usdc,
      synthFactory,
      yieldStrategy,
      owner,
      user1,
      user2,
      treasury,
      liquidator
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployUSDCVaultFixture);
    usdcVault = fixture.usdcVault;
    usdc = fixture.usdc;
    synthFactory = fixture.synthFactory;
    yieldStrategy = fixture.yieldStrategy;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
    treasury = fixture.treasury;
    liquidator = fixture.liquidator;
  });

  describe("Initialization", function () {
    it("Should set correct USDC token", async function () {
      expect(await usdcVault.usdc()).to.equal(await usdc.getAddress());
    });

    it("Should set correct treasury", async function () {
      expect(await usdcVault.treasury()).to.equal(treasury.address);
    });

    it("Should set correct owner", async function () {
      expect(await usdcVault.owner()).to.equal(owner.address);
    });

    it("Should have zero total assets initially", async function () {
      expect(await usdcVault.totalAssets()).to.equal(0);
    });

    it("Should have zero total debt initially", async function () {
      expect(await usdcVault.totalDebt()).to.equal(0);
    });
  });

  describe("Deposit and Withdrawal", function () {
    it("Should allow users to deposit USDC", async function () {
      const depositAmount = toUsdc("1000");
      
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      
      await expect(
        usdcVault.connect(user1).deposit(depositAmount)
      ).to.emit(usdcVault, "Deposit")
      .withArgs(user1.address, depositAmount);
      
      expect(await usdcVault.getBalance(user1.address)).to.equal(depositAmount);
      expect(await usdcVault.totalAssets()).to.equal(depositAmount);
    });

    it("Should transfer USDC to vault on deposit", async function () {
      const depositAmount = toUsdc("1000");
      const initialBalance = await usdc.balanceOf(user1.address);
      
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
      
      expect(await usdc.balanceOf(user1.address)).to.equal(initialBalance - depositAmount);
      expect(await usdc.balanceOf(await usdcVault.getAddress())).to.equal(depositAmount);
    });

    it("Should allow users to withdraw USDC", async function () {
      // First deposit
      const depositAmount = toUsdc("1000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
      
      // Then withdraw
      const withdrawAmount = toUsdc("500");
      
      await expect(
        usdcVault.connect(user1).withdraw(withdrawAmount)
      ).to.emit(usdcVault, "Withdrawal")
      .withArgs(user1.address, withdrawAmount);
      
      expect(await usdcVault.getBalance(user1.address)).to.equal(toUsdc("500"));
      expect(await usdcVault.totalAssets()).to.equal(toUsdc("500"));
    });

    it("Should not allow withdrawing more than balance", async function () {
      const depositAmount = toUsdc("1000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
      
      await expect(
        usdcVault.connect(user1).withdraw(toUsdc("1500"))
      ).to.be.revertedWith("Insufficient balance");
    });

    it("Should handle multiple users deposits", async function () {
      const deposit1 = toUsdc("1000");
      const deposit2 = toUsdc("2000");
      
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), deposit1);
      await (usdc as any).connect(user2).approve(await usdcVault.getAddress(), deposit2);
      
      await usdcVault.connect(user1).deposit(deposit1);
      await usdcVault.connect(user2).deposit(deposit2);
      
      expect(await usdcVault.getBalance(user1.address)).to.equal(deposit1);
      expect(await usdcVault.getBalance(user2.address)).to.equal(deposit2);
      expect(await usdcVault.totalAssets()).to.equal(deposit1 + deposit2);
    });

    it("Should not allow zero deposits", async function () {
      await expect(
        usdcVault.connect(user1).deposit(0)
      ).to.be.revertedWith("Invalid amount");
    });
  });

  describe("Collateral Management", function () {
    beforeEach(async function () {
      // Setup deposits
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
    });

    it("Should lock collateral for synthetic minting", async function () {
      const lockAmount = toUsdc("5000");
      
      await expect(
        usdcVault.lockCollateral(user1.address, lockAmount, 1) // Asset ID 1
      ).to.emit(usdcVault, "CollateralLocked")
      .withArgs(user1.address, 1, lockAmount);
      
      expect(await usdcVault.getLockedCollateral(user1.address, 1)).to.equal(lockAmount);
      expect(await usdcVault.getAvailableBalance(user1.address)).to.equal(toUsdc("5000"));
    });

    it("Should not allow locking more than available balance", async function () {
      const lockAmount = toUsdc("15000"); // More than deposited
      
      await expect(
        usdcVault.lockCollateral(user1.address, lockAmount, 1)
      ).to.be.revertedWith("Insufficient available balance");
    });

    it("Should unlock collateral when burning synthetics", async function () {
      // First lock
      const lockAmount = toUsdc("5000");
      await usdcVault.lockCollateral(user1.address, lockAmount, 1);
      
      // Then unlock
      const unlockAmount = toUsdc("2000");
      
      await expect(
        usdcVault.unlockCollateral(user1.address, unlockAmount, 1)
      ).to.emit(usdcVault, "CollateralUnlocked")
      .withArgs(user1.address, 1, unlockAmount);
      
      expect(await usdcVault.getLockedCollateral(user1.address, 1)).to.equal(toUsdc("3000"));
      expect(await usdcVault.getAvailableBalance(user1.address)).to.equal(toUsdc("7000"));
    });

    it("Should not allow unlocking more than locked amount", async function () {
      const lockAmount = toUsdc("5000");
      await usdcVault.lockCollateral(user1.address, lockAmount, 1);
      
      await expect(
        usdcVault.unlockCollateral(user1.address, toUsdc("6000"), 1)
      ).to.be.revertedWith("Insufficient locked collateral");
    });

    it("Should handle multiple asset collateral locks", async function () {
      const lockAmount1 = toUsdc("3000");
      const lockAmount2 = toUsdc("2000");
      
      await usdcVault.lockCollateral(user1.address, lockAmount1, 1); // sETH
      await usdcVault.lockCollateral(user1.address, lockAmount2, 2); // sBTC
      
      expect(await usdcVault.getLockedCollateral(user1.address, 1)).to.equal(lockAmount1);
      expect(await usdcVault.getLockedCollateral(user1.address, 2)).to.equal(lockAmount2);
      expect(await usdcVault.getAvailableBalance(user1.address)).to.equal(toUsdc("5000"));
    });
  });

  describe("Liquidation Support", function () {
    beforeEach(async function () {
      // Setup user with locked collateral
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
      await usdcVault.lockCollateral(user1.address, toUsdc("8000"), 1);
    });

    it("Should seize collateral during liquidation", async function () {
      const seizeAmount = toUsdc("4000");
      const liquidationBonus = 500; // 5%
      
      await expect(
        usdcVault.seizeCollateral(
          user1.address,
          liquidator.address,
          seizeAmount,
          1,
          liquidationBonus
        )
      ).to.emit(usdcVault, "CollateralSeized")
      .withArgs(user1.address, liquidator.address, 1, seizeAmount);
      
      // User's locked collateral should decrease
      expect(await usdcVault.getLockedCollateral(user1.address, 1)).to.equal(toUsdc("4000"));
      
      // Liquidator should receive bonus
      const bonusAmount = (BigInt(seizeAmount) * BigInt(liquidationBonus)) / BigInt(10000);
      expect(await usdcVault.getBalance(liquidator.address)).to.equal(seizeAmount + bonusAmount);
    });

    it("Should not allow seizing more than locked collateral", async function () {
      const seizeAmount = toUsdc("10000"); // More than locked
      
      await expect(
        usdcVault.seizeCollateral(user1.address, liquidator.address, seizeAmount, 1, 500)
      ).to.be.revertedWith("Insufficient locked collateral");
    });

    it("Should handle partial liquidations", async function () {
      const initialLocked = toUsdc("8000");
      const seizeAmount = toUsdc("2000");
      
      await usdcVault.seizeCollateral(user1.address, liquidator.address, seizeAmount, 1, 500);
      
      expect(await usdcVault.getLockedCollateral(user1.address, 1)).to.equal(initialLocked - seizeAmount);
      expect(await usdcVault.getBalance(user1.address)).to.equal(toUsdc("2000")); // Available balance
    });
  });

  describe("Yield Strategy Integration", function () {
    beforeEach(async function () {
      // Setup vault with deposits
      const totalDeposits = toUsdc("100000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), totalDeposits);
      await usdcVault.connect(user1).deposit(totalDeposits);
    });

    it("Should deploy idle funds to yield strategy", async function () {
      const deployAmount = toUsdc("50000");
      
      await expect(
        usdcVault.deployToStrategy(await yieldStrategy.getAddress(), deployAmount)
      ).to.emit(usdcVault, "StrategyDeployment")
      .withArgs(await yieldStrategy.getAddress(), deployAmount);
      
      expect(await usdcVault.getStrategyBalance(await yieldStrategy.getAddress())).to.equal(deployAmount);
    });

    it("Should withdraw from yield strategy when needed", async function () {
      // First deploy
      const deployAmount = toUsdc("50000");
      await usdcVault.deployToStrategy(await yieldStrategy.getAddress(), deployAmount);
      
      // Mock strategy returns (simulate yield earned)
      const yieldEarned = toUsdc("2500"); // 5% yield
      await (usdc as any).mint(await yieldStrategy.getAddress(), yieldEarned);
      
      // Withdraw from strategy
      const withdrawAmount = toUsdc("25000");
      
      await expect(
        usdcVault.withdrawFromStrategy(await yieldStrategy.getAddress(), withdrawAmount)
      ).to.emit(usdcVault, "StrategyWithdrawal");
      
      expect(await usdcVault.getStrategyBalance(await yieldStrategy.getAddress())).to.equal(deployAmount - withdrawAmount);
    });

    it("Should calculate total vault value including strategy yields", async function () {
      const deployAmount = toUsdc("50000");
      await usdcVault.deployToStrategy(await yieldStrategy.getAddress(), deployAmount);
      
      // Simulate yield generation
      const yieldEarned = toUsdc("5000");
      await (usdc as any).mint(await yieldStrategy.getAddress(), yieldEarned);
      
      const totalValue = await usdcVault.getTotalValue();
      expect(totalValue).to.be.gt(toUsdc("100000")); // Should include yield
    });

    it("Should only allow owner to manage strategies", async function () {
      await expect(
        usdcVault.connect(user1).deployToStrategy(await yieldStrategy.getAddress(), toUsdc("1000"))
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Fee Management", function () {
    beforeEach(async function () {
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
    });

    it("Should charge management fees", async function () {
      const managementFee = 200; // 2% annually
      await usdcVault.setManagementFee(managementFee);
      
      // Simulate one year passage
      await time.increase(TEST_CONSTANTS.TIME.YEAR);
      
      await expect(
        usdcVault.collectManagementFees()
      ).to.emit(usdcVault, "FeesCollected");
      
      const treasuryBalance = await usdcVault.getBalance(treasury.address);
      expect(treasuryBalance).to.be.gt(0);
    });

    it("Should charge performance fees on yields", async function () {
      const performanceFee = 1000; // 10%
      await usdcVault.setPerformanceFee(performanceFee);
      
      // Deploy to strategy and simulate yield
      const deployAmount = toUsdc("5000");
      await usdcVault.deployToStrategy(await yieldStrategy.getAddress(), deployAmount);
      
      const yieldEarned = toUsdc("1000");
      await (usdc as any).mint(await yieldStrategy.getAddress(), yieldEarned);
      
      await expect(
        usdcVault.collectPerformanceFees()
      ).to.emit(usdcVault, "PerformanceFeesCollected");
      
      const expectedFee = (BigInt(yieldEarned) * BigInt(performanceFee)) / BigInt(10000);
      const treasuryBalance = await usdcVault.getBalance(treasury.address);
      expect(treasuryBalance).to.equal(expectedFee);
    });

    it("Should set fee parameters within limits", async function () {
      const validManagementFee = 500; // 5%
      const validPerformanceFee = 2000; // 20%
      
      await usdcVault.setManagementFee(validManagementFee);
      await usdcVault.setPerformanceFee(validPerformanceFee);
      
      expect(await usdcVault.managementFee()).to.equal(validManagementFee);
      expect(await usdcVault.performanceFee()).to.equal(validPerformanceFee);
    });

    it("Should not allow excessive fees", async function () {
      await expect(
        usdcVault.setManagementFee(1000) // 10% - too high
      ).to.be.revertedWith("Fee too high");
      
      await expect(
        usdcVault.setPerformanceFee(5000) // 50% - too high
      ).to.be.revertedWith("Fee too high");
    });
  });

  describe("Emergency Functions", function () {
    beforeEach(async function () {
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
    });

    it("Should pause vault operations", async function () {
      await usdcVault.pause();
      expect(await usdcVault.paused()).to.be.true;
    });

    it("Should not allow deposits when paused", async function () {
      await usdcVault.pause();
      
      await expect(
        usdcVault.connect(user2).deposit(toUsdc("1000"))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should allow emergency withdrawals when paused", async function () {
      await usdcVault.pause();
      
      // Emergency withdrawal should still work
      await expect(
        usdcVault.connect(user1).emergencyWithdraw()
      ).to.emit(usdcVault, "EmergencyWithdrawal");
      
      expect(await usdcVault.getBalance(user1.address)).to.equal(0);
    });

    it("Should allow owner to recover stuck tokens", async function () {
      // Simulate stuck tokens (different from USDC)
      const MockTokenFactory = await ethers.getContractFactory("MockERC20");
      const stuckToken = await MockTokenFactory.deploy("Stuck", "STUCK", 18, 0);
      await (stuckToken as any).mint(await usdcVault.getAddress(), ethers.parseEther("1000"));
      
      const initialBalance = await stuckToken.balanceOf(owner.address);
      
      await usdcVault.recoverToken(await stuckToken.getAddress(), ethers.parseEther("1000"));
      
      expect(await stuckToken.balanceOf(owner.address)).to.equal(
        initialBalance + ethers.parseEther("1000")
      );
    });

    it("Should not allow recovering USDC (main asset)", async function () {
      await expect(
        usdcVault.recoverToken(await usdc.getAddress(), toUsdc("1000"))
      ).to.be.revertedWith("Cannot recover main asset");
    });
  });

  describe("Accounting and Reporting", function () {
    beforeEach(async function () {
      // Setup complex scenario
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), toUsdc("10000"));
      await (usdc as any).connect(user2).approve(await usdcVault.getAddress(), toUsdc("5000"));
      
      await usdcVault.connect(user1).deposit(toUsdc("10000"));
      await usdcVault.connect(user2).deposit(toUsdc("5000"));
      
      await usdcVault.lockCollateral(user1.address, toUsdc("8000"), 1);
      await usdcVault.lockCollateral(user2.address, toUsdc("3000"), 2);
    });

    it("Should calculate utilization ratio", async function () {
      const totalDeposits = toUsdc("15000");
      const totalLocked = toUsdc("11000");
      
      const utilizationRatio = await usdcVault.getUtilizationRatio();
      const expectedRatio = (BigInt(totalLocked) * BigInt(10000)) / BigInt(totalDeposits); // In BPS
      
      expect(utilizationRatio).to.equal(expectedRatio);
    });

    it("Should track user positions", async function () {
      const user1Position = await usdcVault.getUserPosition(user1.address);
      
      expect(user1Position.deposited).to.equal(toUsdc("10000"));
      expect(user1Position.available).to.equal(toUsdc("2000"));
      expect(user1Position.totalLocked).to.equal(toUsdc("8000"));
    });

    it("Should generate vault summary", async function () {
      const summary = await usdcVault.getVaultSummary();
      
      expect(summary.totalAssets).to.equal(toUsdc("15000"));
      expect(summary.totalLocked).to.equal(toUsdc("11000"));
      expect(summary.availableLiquidity).to.equal(toUsdc("4000"));
      expect(summary.totalUsers).to.equal(2);
    });

    it("Should handle vault health calculations", async function () {
      const healthRatio = await usdcVault.getVaultHealth();
      expect(healthRatio).to.be.gt(0);
      
      // Should be healthy with current utilization
      const isHealthy = await usdcVault.isVaultHealthy();
      expect(isHealthy).to.be.true;
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle full synthetic asset lifecycle", async function () {
      // User deposits
      const depositAmount = toUsdc("10000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
      
      // Lock collateral for minting
      const lockAmount = toUsdc("6000");
      await usdcVault.lockCollateral(user1.address, lockAmount, 1);
      
      // Simulate partial burn (unlock some collateral)
      const unlockAmount = toUsdc("2000");
      await usdcVault.unlockCollateral(user1.address, unlockAmount, 1);
      
      // Final state check
      expect(await usdcVault.getLockedCollateral(user1.address, 1)).to.equal(toUsdc("4000"));
      expect(await usdcVault.getAvailableBalance(user1.address)).to.equal(toUsdc("6000"));
    });

    it("Should handle yield generation and fee collection", async function () {
      // Setup vault
      const depositAmount = toUsdc("50000");
      await (usdc as any).connect(user1).approve(await usdcVault.getAddress(), depositAmount);
      await usdcVault.connect(user1).deposit(depositAmount);
      
      // Deploy to yield strategy
      const deployAmount = toUsdc("30000");
      await usdcVault.deployToStrategy(await yieldStrategy.getAddress(), deployAmount);
      
      // Simulate yield and fee collection
      const yieldEarned = toUsdc("3000");
      await (usdc as any).mint(await yieldStrategy.getAddress(), yieldEarned);
      
      await usdcVault.setPerformanceFee(1000); // 10%
      await usdcVault.collectPerformanceFees();
      
      const totalValue = await usdcVault.getTotalValue();
      expect(totalValue).to.be.gt(depositAmount);
    });
  });
}); 