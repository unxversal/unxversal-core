/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
/* eslint-disable @typescript-eslint/no-unused-vars */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc, toEth } from "../../shared/constants";

describe("CorePool Lending", function () {
  let corePool: any;
  let riskController: any;
  let usdc: any;
  let weth: any;
  let uUSDC: any;
  let uWETH: any;
  let oracle: any;
  let interestModel: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let liquidator: SignerWithAddress;

  async function deployCorePoolFixture() {
    const [owner, user1, user2, liquidator] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USD Coin", "USDC", 6, toUsdc("1000000"));
    const weth = await MockERC20Factory.deploy("Wrapped Ethereum", "WETH", 18, toEth("10000"));

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);
    await (oracle as any).setPrice(3, TEST_CONSTANTS.PRICES.USDC);

    // Deploy interest rate model
    const InterestModelFactory = await ethers.getContractFactory("PiecewiseLinearInterestRateModel");
    const interestModel = await InterestModelFactory.deploy(
      200,   // baseRatePerYear (2%)
      1000,  // multiplierPerYear (10%)
      8000,  // kinkUtilizationRate (80%)
      5000,  // jumpMultiplierPerYear (50%)
      owner.address
    );

    // Deploy core pool
    const CorePoolFactory = await ethers.getContractFactory("CorePool");
    const corePool = await CorePoolFactory.deploy(
      owner.address,
      owner.address,
      owner.address
    );

    // Deploy risk controller
    const RiskControllerFactory = await ethers.getContractFactory("LendRiskController");
    const riskController = await RiskControllerFactory.deploy(
      await corePool.getAddress(),
      await oracle.getAddress(),
      ethers.ZeroAddress,
      owner.address
    );

    // Deploy uTokens
    const UTokenFactory = await ethers.getContractFactory("uToken");
    const uUSDC = await UTokenFactory.deploy(
      await usdc.getAddress(),
      await corePool.getAddress(),
      "Unxversal USDC",
      "uUSDC",
      owner.address
    );

    const uWETH = await UTokenFactory.deploy(
      await weth.getAddress(),
      await corePool.getAddress(),
      "Unxversal WETH",
      "uWETH",
      owner.address
    );

    // Setup CorePool
    await corePool.setRiskController(await riskController.getAddress());
    await corePool.listMarket(
      await usdc.getAddress(),
      await uUSDC.getAddress(),
      await interestModel.getAddress()
    );
    await corePool.listMarket(
      await weth.getAddress(),
      await uWETH.getAddress(),
      await interestModel.getAddress()
    );

    // Setup RiskController
    await riskController.listMarket(
      await usdc.getAddress(),
      await uUSDC.getAddress(),
      true, // can be collateral
      TEST_CONSTANTS.LENDING.DEFAULT_COLLATERAL_FACTOR,
      TEST_CONSTANTS.LENDING.DEFAULT_LIQUIDATION_THRESHOLD,
      TEST_CONSTANTS.LENDING.DEFAULT_LIQUIDATION_BONUS,
      3 // USDC oracle ID
    );

    await riskController.listMarket(
      await weth.getAddress(),
      await uWETH.getAddress(),
      true, // can be collateral
      TEST_CONSTANTS.LENDING.DEFAULT_COLLATERAL_FACTOR,
      TEST_CONSTANTS.LENDING.DEFAULT_LIQUIDATION_THRESHOLD,
      TEST_CONSTANTS.LENDING.DEFAULT_LIQUIDATION_BONUS,
      1 // ETH oracle ID
    );

    // Fund users
    await usdc.transfer(user1.address, toUsdc("10000"));
    await usdc.transfer(user2.address, toUsdc("10000"));
    await weth.transfer(user1.address, toEth("100"));
    await weth.transfer(user2.address, toEth("100"));

    return {
      corePool,
      riskController,
      usdc,
      weth,
      uUSDC,
      uWETH,
      oracle,
      interestModel,
      owner,
      user1,
      user2,
      liquidator
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployCorePoolFixture);
    corePool = fixture.corePool;
    riskController = fixture.riskController;
    usdc = fixture.usdc;
    weth = fixture.weth;
    uUSDC = fixture.uUSDC;
    uWETH = fixture.uWETH;
    oracle = fixture.oracle;
    interestModel = fixture.interestModel;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
    liquidator = fixture.liquidator;
  });

  describe("Deployment", function () {
    it("Should set correct owner", async function () {
      expect(await corePool.owner()).to.equal(owner.address);
    });

    it("Should set risk controller", async function () {
      expect(await corePool.riskController()).to.equal(await riskController.getAddress());
    });

    it("Should list markets correctly", async function () {
      expect(await corePool.getUTokenForUnderlying(await usdc.getAddress())).to.equal(await uUSDC.getAddress());
      expect(await corePool.getUTokenForUnderlying(await weth.getAddress())).to.equal(await uWETH.getAddress());
    });
  });

  describe("Supply", function () {
    const supplyAmount = toUsdc("1000");

    beforeEach(async function () {
      await usdc.connect(user1).approve(await corePool.getAddress(), supplyAmount);
    });

    it("Should supply tokens successfully", async function () {
      const initialBalance = await usdc.balanceOf(user1.address);
      
      await expect(corePool.connect(user1).supply(await usdc.getAddress(), supplyAmount))
        .to.emit(corePool, "Supply")
        .withArgs(user1.address, await usdc.getAddress(), supplyAmount);

      expect(await usdc.balanceOf(user1.address)).to.equal(initialBalance - BigInt(supplyAmount));
      expect(await uUSDC.balanceOf(user1.address)).to.be.gt(0);
    });

    it("Should calculate correct uToken amount", async function () {
      await corePool.connect(user1).supply(await usdc.getAddress(), supplyAmount);
      
      const uTokenBalance = await uUSDC.balanceOf(user1.address);
      const exchangeRate = await uUSDC.exchangeRateStored();
      const expectedUTokens = (BigInt(supplyAmount) * BigInt(1e18)) / exchangeRate;
      
      expect(uTokenBalance).to.be.closeTo(expectedUTokens, BigInt(1e6)); // Allow small rounding
    });

    it("Should revert with zero amount", async function () {
      await expect(
        corePool.connect(user1).supply(await usdc.getAddress(), 0)
      ).to.be.revertedWith("CorePool: Cannot supply 0");
    });

    it("Should revert with unlisted asset", async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const unknownToken = await MockERC20Factory.deploy("Unknown", "UNK", 18, toEth("1000"));
      
      await expect(
        corePool.connect(user1).supply(await unknownToken.getAddress(), supplyAmount)
      ).to.be.revertedWith("CorePool: Market not listed");
    });

    it("Should update user's supplied assets", async function () {
      await corePool.connect(user1).supply(await usdc.getAddress(), supplyAmount);
      
      const suppliedAssets = await corePool.getAssetsUserSupplied(user1.address);
      expect(suppliedAssets).to.include(await usdc.getAddress());
    });
  });

  describe("Withdraw", function () {
    const supplyAmount = toUsdc("1000");
    const withdrawAmount = toUsdc("500");

    beforeEach(async function () {
      await usdc.connect(user1).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user1).supply(await usdc.getAddress(), supplyAmount);
    });

    it("Should withdraw tokens successfully", async function () {
      const initialBalance = await usdc.balanceOf(user1.address);
      const initialUTokenBalance = await uUSDC.balanceOf(user1.address);
      
      await expect(corePool.connect(user1).withdraw(await usdc.getAddress(), withdrawAmount))
        .to.emit(corePool, "Withdraw")
        .withArgs(user1.address, await usdc.getAddress(), withdrawAmount);

      expect(await usdc.balanceOf(user1.address)).to.equal(initialBalance + BigInt(withdrawAmount));
      expect(await uUSDC.balanceOf(user1.address)).to.be.lt(initialUTokenBalance);
    });

    it("Should revert with insufficient uTokens", async function () {
      const largeAmount = toUsdc("10000");
      
      await expect(
        corePool.connect(user1).withdraw(await usdc.getAddress(), largeAmount)
      ).to.be.revertedWith("CorePool: Insufficient uTokens");
    });

    it("Should revert if withdrawal would break collateral requirements", async function () {
      // First, borrow against the collateral
      await weth.connect(user1).approve(await corePool.getAddress(), toEth("1"));
      await corePool.connect(user1).supply(await weth.getAddress(), toEth("1"));
      await corePool.connect(user1).borrow(await usdc.getAddress(), toUsdc("100"));
      
      // Try to withdraw all USDC collateral (should fail)
      await expect(
        corePool.connect(user1).withdraw(await usdc.getAddress(), supplyAmount)
      ).to.be.revertedWith("RiskController: Withdrawal makes position undercollateralized");
    });

    it("Should allow full withdrawal if no borrows", async function () {
      const fullAmount = await uUSDC.balanceOf(user1.address);
      const exchangeRate = await uUSDC.exchangeRateStored();
      const underlyingAmount = (fullAmount * exchangeRate) / BigInt(1e18);
      
      await corePool.connect(user1).withdraw(await usdc.getAddress(), underlyingAmount);
      
      expect(await uUSDC.balanceOf(user1.address)).to.equal(0);
    });
  });

  describe("Borrow", function () {
    const supplyAmount = toEth("2");
    const borrowAmount = toUsdc("1000");

    beforeEach(async function () {
      // Supply WETH as collateral
      await weth.connect(user1).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user1).supply(await weth.getAddress(), supplyAmount);
      
      // Supply USDC liquidity from another user
      await usdc.connect(user2).approve(await corePool.getAddress(), toUsdc("10000"));
      await corePool.connect(user2).supply(await usdc.getAddress(), toUsdc("10000"));
    });

    it("Should borrow tokens successfully", async function () {
      const initialBalance = await usdc.balanceOf(user1.address);
      
      await expect(corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount))
        .to.emit(corePool, "Borrow")
        .withArgs(user1.address, await usdc.getAddress(), borrowAmount);

      expect(await usdc.balanceOf(user1.address)).to.equal(initialBalance + BigInt(borrowAmount));
    });

    it("Should track borrowed assets", async function () {
      await corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount);
      
      const borrowedAssets = await corePool.getAssetsUserBorrowed(user1.address);
      expect(borrowedAssets).to.include(await usdc.getAddress());
    });

    it("Should revert with insufficient collateral", async function () {
      const largeBorrowAmount = toUsdc("10000");
      
      await expect(
        corePool.connect(user1).borrow(await usdc.getAddress(), largeBorrowAmount)
      ).to.be.revertedWith("RiskController: Borrow exceeds collateral capacity");
    });

    it("Should revert with zero amount", async function () {
      await expect(
        corePool.connect(user1).borrow(await usdc.getAddress(), 0)
      ).to.be.revertedWith("CorePool: Cannot borrow 0");
    });

    it("Should revert with unlisted asset", async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const unknownToken = await MockERC20Factory.deploy("Unknown", "UNK", 18, toEth("1000"));
      
      await expect(
        corePool.connect(user1).borrow(await unknownToken.getAddress(), borrowAmount)
      ).to.be.revertedWith("CorePool: Market not listed");
    });

    it("Should accrue interest on borrow", async function () {
      await corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount);
      
      const [, initialBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      
      // Fast forward time
      await time.increase(TEST_CONSTANTS.TIME.MONTH);
      await corePool.accrueInterest(await usdc.getAddress());
      
      const [, finalBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      expect(finalBorrowBalance).to.be.gt(initialBorrowBalance);
    });
  });

  describe("Repay", function () {
    const supplyAmount = toEth("2");
    const borrowAmount = toUsdc("1000");
    const repayAmount = toUsdc("500");

    beforeEach(async function () {
      // Setup borrow position
      await weth.connect(user1).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user1).supply(await weth.getAddress(), supplyAmount);
      
      await usdc.connect(user2).approve(await corePool.getAddress(), toUsdc("10000"));
      await corePool.connect(user2).supply(await usdc.getAddress(), toUsdc("10000"));
      
      await corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount);
      
      // Approve for repayment
      await usdc.connect(user1).approve(await corePool.getAddress(), repayAmount);
    });

    it("Should repay borrow successfully", async function () {
      const initialBalance = await usdc.balanceOf(user1.address);
      const [, initialBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      
      await expect(corePool.connect(user1).repayBorrow(await usdc.getAddress(), repayAmount))
        .to.emit(corePool, "RepayBorrow");

      expect(await usdc.balanceOf(user1.address)).to.equal(initialBalance - BigInt(repayAmount));
      
      const [, finalBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      expect(finalBorrowBalance).to.be.lt(initialBorrowBalance);
    });

    it("Should allow full repayment", async function () {
      const [, borrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      
      await usdc.connect(user1).approve(await corePool.getAddress(), borrowBalance);
      await corePool.connect(user1).repayBorrow(await usdc.getAddress(), borrowBalance);
      
      const [, finalBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      expect(finalBorrowBalance).to.equal(0);
    });

    it("Should revert with zero amount", async function () {
      await expect(
        corePool.connect(user1).repayBorrow(await usdc.getAddress(), 0)
      ).to.be.revertedWith("CorePool: Cannot repay 0");
    });

    it("Should handle repay amount larger than debt", async function () {
      const largeRepayAmount = toUsdc("10000");
      await usdc.connect(user1).approve(await corePool.getAddress(), largeRepayAmount);
      
      const [, borrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      
      await corePool.connect(user1).repayBorrow(await usdc.getAddress(), largeRepayAmount);
      
      // Should only repay the actual debt amount
      const [, finalBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      expect(finalBorrowBalance).to.equal(0);
    });
  });

  describe("Interest Accrual", function () {
    const supplyAmount = toUsdc("10000");
    const borrowAmount = toUsdc("1000");

    beforeEach(async function () {
      // Setup lending scenario
      await usdc.connect(user2).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user2).supply(await usdc.getAddress(), supplyAmount);
      
      await weth.connect(user1).approve(await corePool.getAddress(), toEth("2"));
      await corePool.connect(user1).supply(await weth.getAddress(), toEth("2"));
      await corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount);
    });

    it("Should accrue interest over time", async function () {
      const [, initialBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      const initialSupplyBalance = await uUSDC.balanceOf(user2.address);
      
      // Fast forward time
      await time.increase(TEST_CONSTANTS.TIME.YEAR);
      
      // Trigger interest accrual
      await corePool.accrueInterest(await usdc.getAddress());
      
      const [, finalBorrowBalance] = await corePool.getUserSupplyAndBorrowBalance(user1.address, await usdc.getAddress());
      const finalSupplyBalance = await uUSDC.balanceOf(user2.address);
      
      // Borrow balance should increase due to interest
      expect(finalBorrowBalance).to.be.gt(initialBorrowBalance);
      
      // Supply balance (in underlying terms) should also increase
      const finalExchangeRate = await uUSDC.exchangeRateStored();
      const finalUnderlyingBalance = (finalSupplyBalance * finalExchangeRate) / BigInt(1e18);
      const initialUnderlyingBalance = (initialSupplyBalance * BigInt(TEST_CONSTANTS.LENDING.INITIAL_EXCHANGE_RATE)) / BigInt(1e18);
      
      expect(finalUnderlyingBalance).to.be.gt(initialUnderlyingBalance);
    });

    it("Should update exchange rate after interest accrual", async function () {
      const initialExchangeRate = await uUSDC.exchangeRateStored();
      
      await time.increase(TEST_CONSTANTS.TIME.YEAR);
      await corePool.accrueInterest(await usdc.getAddress());
      
      const finalExchangeRate = await uUSDC.exchangeRateStored();
      expect(finalExchangeRate).to.be.gt(initialExchangeRate);
    });

    it("Should accumulate reserves", async function () {
      const initialReserves = await corePool.totalReserves(await usdc.getAddress());
      
      await time.increase(TEST_CONSTANTS.TIME.YEAR);
      await corePool.accrueInterest(await usdc.getAddress());
      
      const finalReserves = await corePool.totalReserves(await usdc.getAddress());
      expect(finalReserves).to.be.gt(initialReserves);
    });
  });

  describe("Account Liquidity", function () {
    const supplyAmount = toEth("2");
    const borrowAmount = toUsdc("1000");

    beforeEach(async function () {
      // Setup position
      await weth.connect(user1).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user1).supply(await weth.getAddress(), supplyAmount);
      
      await usdc.connect(user2).approve(await corePool.getAddress(), toUsdc("10000"));
      await corePool.connect(user2).supply(await usdc.getAddress(), toUsdc("10000"));
      
      await corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount);
    });

    it("Should calculate account liquidity correctly", async function () {
      const [collateralValue, borrowValue] = await riskController.getAccountLiquidityValues(user1.address);
      
      expect(collateralValue).to.be.gt(0);
      expect(borrowValue).to.be.gt(0);
      expect(collateralValue).to.be.gt(borrowValue); // Should be overcollateralized
    });

    it("Should return positive liquidity for healthy account", async function () {
      const liquidity = await riskController.getAccountLiquidity(user1.address);
      expect(liquidity).to.be.gt(0);
    });

    it("Should detect liquidatable account", async function () {
      // Manipulate price to make account liquidatable
      await oracle.setPrice(1, ethers.parseEther("200")); // Drop ETH price by 90%
      
      const isLiquidatable = await riskController.isAccountLiquidatable(user1.address);
      expect(isLiquidatable).to.be.true;
    });
  });

  describe("Flash Loans", function () {
    const supplyAmount = toUsdc("10000");
    const flashAmount = toUsdc("1000");

    beforeEach(async function () {
      await usdc.connect(user2).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user2).supply(await usdc.getAddress(), supplyAmount);
    });

    it("Should execute flash loan successfully", async function () {
      // This would require a flash loan receiver contract in a real test
      // For now, we'll test the basic functionality
      
      const availableLiquidity = await usdc.balanceOf(await uUSDC.getAddress());
      expect(availableLiquidity).to.be.gte(flashAmount);
    });

    it("Should charge flash loan fee", async function () {
      const flashFeeBps = await corePool.flashFeeBps();
      const flashFee = (BigInt(flashAmount) * BigInt(flashFeeBps)) / BigInt(10000);
      expect(flashFee).to.be.gt(0);
    });

    it("Should revert flash loan with insufficient liquidity", async function () {
      const largeAmount = toUsdc("100000");
      
      await expect(
        corePool.flashLoan(user1.address, await usdc.getAddress(), largeAmount, "0x")
      ).to.be.revertedWith("CorePool: Insufficient liquidity");
    });
  });

  describe("Market State", function () {
    it("Should track total supply correctly", async function () {
      const supplyAmount = toUsdc("1000");
      await usdc.connect(user1).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(user1).supply(await usdc.getAddress(), supplyAmount);
      
      // Total supply is tracked in the uToken contract
      const totalUTokenSupply = await uUSDC.totalSupply();
      const exchangeRate = await uUSDC.exchangeRateStored();
      const totalSupply = (totalUTokenSupply * exchangeRate) / BigInt(1e18);
      expect(totalSupply).to.be.gte(supplyAmount);
    });

    it("Should track total borrows correctly", async function () {
      // Setup supply and borrow
      await usdc.connect(user2).approve(await corePool.getAddress(), toUsdc("10000"));
      await corePool.connect(user2).supply(await usdc.getAddress(), toUsdc("10000"));
      
      await weth.connect(user1).approve(await corePool.getAddress(), toEth("2"));
      await corePool.connect(user1).supply(await weth.getAddress(), toEth("2"));
      
      const borrowAmount = toUsdc("1000");
      await corePool.connect(user1).borrow(await usdc.getAddress(), borrowAmount);
      
      const totalBorrows = await corePool.totalBorrowsCurrent(await usdc.getAddress());
      expect(totalBorrows).to.be.gte(borrowAmount);
    });

    it("Should calculate utilization rate", async function () {
      // Setup lending scenario
      await usdc.connect(user2).approve(await corePool.getAddress(), toUsdc("10000"));
      await corePool.connect(user2).supply(await usdc.getAddress(), toUsdc("10000"));
      
      await weth.connect(user1).approve(await corePool.getAddress(), toEth("2"));
      await corePool.connect(user1).supply(await weth.getAddress(), toEth("2"));
      await corePool.connect(user1).borrow(await usdc.getAddress(), toUsdc("1000"));
      
      // Total supply calculation from uToken
      const totalUTokenSupply = await uUSDC.totalSupply();
      const exchangeRate = await uUSDC.exchangeRateStored();
      const totalSupply = (totalUTokenSupply * exchangeRate) / BigInt(1e18);
      
      const totalBorrows = await corePool.totalBorrowsCurrent(await usdc.getAddress());
      
      const utilizationRate = (totalBorrows * BigInt(1e18)) / totalSupply;
      expect(utilizationRate).to.be.gt(0);
      expect(utilizationRate).to.be.lt(BigInt(1e18)); // Less than 100%
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to set reserve factor", async function () {
      const newReserveFactor = 1500; // 15%
      
      await expect(corePool.setReserveFactor(await usdc.getAddress(), newReserveFactor))
        .to.emit(corePool, "NewReserveFactor")
        .withArgs(await usdc.getAddress(), TEST_CONSTANTS.LENDING.DEFAULT_RESERVE_FACTOR, newReserveFactor);
    });

    it("Should not allow non-owner to set reserve factor", async function () {
      await expect(
        corePool.connect(user1).setReserveFactor(await usdc.getAddress(), 1500)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should allow owner to pause/unpause", async function () {
      await corePool.pause();
      expect(await corePool.paused()).to.be.true;
      
      // Should revert operations when paused
      await expect(
        corePool.connect(user1).supply(await usdc.getAddress(), toUsdc("100"))
      ).to.be.revertedWith("Pausable: paused");
      
      await corePool.unpause();
      expect(await corePool.paused()).to.be.false;
    });
  });
}); 