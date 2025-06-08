/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
/* eslint-disable @typescript-eslint/no-unused-vars */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc, toEth } from "../shared/constants";

describe("Lending Liquidation Integration", function () {
  let corePool: any;
  let riskController: any;
  let liquidationEngine: any;
  let usdc: any;
  let weth: any;
  let oracle: any;
  let borrower: SignerWithAddress;
  let liquidator: SignerWithAddress;
  let supplier: SignerWithAddress;

  async function deployLendingLiquidationFixture() {
    const [owner, borrower, liquidator, supplier] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USD Coin", "USDC", 6, toUsdc("1000000"));
    const weth = await MockERC20Factory.deploy("Wrapped Ethereum", "WETH", 18, toEth("10000"));

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
    await (oracle as any).setPrice(3, TEST_CONSTANTS.PRICES.USDC); // USDC

    // Deploy interest rate model
    const InterestModelFactory = await ethers.getContractFactory("PiecewiseLinearInterestRateModel");
    const interestModel = await InterestModelFactory.deploy(
      200, 1000, 8000, 5000, owner.address
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

    // Deploy liquidation engine
    const LiquidationEngineFactory = await ethers.getContractFactory("LendLiquidationEngine");
    const liquidationEngine = await LiquidationEngineFactory.deploy(
      await corePool.getAddress(),
      await riskController.getAddress(),
      await oracle.getAddress(),
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
    await corePool.setLiquidationEngine(await liquidationEngine.getAddress());
    
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
      true,
      7500, // 75% collateral factor
      8000, // 80% liquidation threshold
      500,  // 5% liquidation bonus
      3     // USDC oracle ID
    );

    await riskController.listMarket(
      await weth.getAddress(),
      await uWETH.getAddress(),
      true,
      7500, // 75% collateral factor
      8000, // 80% liquidation threshold
      500,  // 5% liquidation bonus
      1     // ETH oracle ID
    );

    // Setup liquidation engine
    await liquidationEngine.setCloseFactor(5000); // 50%

    // Fund users
    await (usdc as any).transfer(supplier.address, toUsdc("100000"));
    await (usdc as any).transfer(liquidator.address, toUsdc("50000"));
    await (weth as any).transfer(borrower.address, toEth("100"));

    return {
      corePool,
      riskController,
      liquidationEngine,
      usdc,
      weth,
      oracle,
      borrower,
      liquidator,
      supplier
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployLendingLiquidationFixture);
    corePool = fixture.corePool;
    riskController = fixture.riskController;
    liquidationEngine = fixture.liquidationEngine;
    usdc = fixture.usdc;
    weth = fixture.weth;
    oracle = fixture.oracle;
    borrower = fixture.borrower;
    liquidator = fixture.liquidator;
    supplier = fixture.supplier;
  });

  describe("Complete Liquidation Flow", function () {
    const supplyAmount = toEth("10"); // 10 ETH as collateral
    const borrowAmount = toUsdc("8000"); // $8,000 USDC borrowed (safe initially)
    const liquidityAmount = toUsdc("50000"); // USDC liquidity

    beforeEach(async function () {
      // 1. Supplier provides USDC liquidity
      await usdc.connect(supplier).approve(await corePool.getAddress(), liquidityAmount);
      await corePool.connect(supplier).supply(await usdc.getAddress(), liquidityAmount);

      // 2. Borrower supplies ETH collateral
      await weth.connect(borrower).approve(await corePool.getAddress(), supplyAmount);
      await corePool.connect(borrower).supply(await weth.getAddress(), supplyAmount);

      // 3. Borrower borrows USDC
      await corePool.connect(borrower).borrow(await usdc.getAddress(), borrowAmount);
    });

    it("Should complete successful liquidation when position becomes underwater", async function () {
      // Verify initial healthy position
      expect(await riskController.isAccountLiquidatable(borrower.address)).to.be.false;

      // Crash ETH price to make position liquidatable (drop from $2000 to $1200)
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 60n) / 100n; // 60% of original
      await (oracle as any).setPrice(1, newEthPrice);

      // Verify position is now liquidatable
      expect(await riskController.isAccountLiquidatable(borrower.address)).to.be.true;

      // Prepare liquidator
      const liquidationAmount = toUsdc("4000"); // 50% of debt (close factor)
      await usdc.connect(liquidator).approve(await corePool.getAddress(), liquidationAmount);

      // Get initial balances
      const initialLiquidatorUsdc = await usdc.balanceOf(liquidator.address);
      const initialLiquidatorWeth = await weth.balanceOf(liquidator.address);
      const initialBorrowerDebt = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());

      // Execute liquidation
      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(), // debt asset to repay
          await weth.getAddress(), // collateral asset to seize
          liquidationAmount
        )
      ).to.emit(liquidationEngine, "LiquidationCall");

      // Verify liquidator paid USDC and received WETH
      expect(await usdc.balanceOf(liquidator.address)).to.equal(
        initialLiquidatorUsdc - BigInt(liquidationAmount)
      );
      expect(await weth.balanceOf(liquidator.address)).to.be.gt(initialLiquidatorWeth);

      // Verify borrower's debt was reduced
      const finalBorrowerDebt = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());
      expect(finalBorrowerDebt).to.be.lt(initialBorrowerDebt);

      // Verify liquidation bonus was applied (liquidator gets more value than they paid)
      const liquidatorWethReceived = (await weth.balanceOf(liquidator.address)) - initialLiquidatorWeth;
      const wethValueReceived = (liquidatorWethReceived * newEthPrice) / BigInt(1e18);
      const usdcValuePaid = BigInt(liquidationAmount) * BigInt(1e12); // Convert USDC to 18 decimals
      
      expect(wethValueReceived).to.be.gt(usdcValuePaid); // Liquidator profits from bonus
    });

    it("Should prevent liquidation of healthy positions", async function () {
      // Verify position is healthy
      expect(await riskController.isAccountLiquidatable(borrower.address)).to.be.false;

      // Attempt liquidation
      const liquidationAmount = toUsdc("1000");
      await usdc.connect(liquidator).approve(await corePool.getAddress(), liquidationAmount);

      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          liquidationAmount
        )
      ).to.be.revertedWith("LLE: Account not liquidatable");
    });

    it("Should respect close factor limits", async function () {
      // Make position liquidatable
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 60n) / 100n;
      await oracle.setPrice(1, newEthPrice);

      // Try to liquidate more than close factor allows (>50%)
      const totalDebt = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());
      const excessiveLiquidationAmount = (totalDebt * 60n) / 100n; // 60% of debt

      await usdc.connect(liquidator).approve(await corePool.getAddress(), excessiveLiquidationAmount);

      // Should only liquidate up to close factor limit
      const tx = await liquidationEngine.connect(liquidator).liquidate(
        borrower.address,
        await usdc.getAddress(),
        await weth.getAddress(),
        excessiveLiquidationAmount
      );

      const receipt = await tx.wait();
      const liquidationEvent = receipt.events?.find((e: any) => e.event === "LiquidationCall");
      
      // Should have liquidated exactly 50% (close factor)
      const actualLiquidatedAmount = liquidationEvent?.args?.amountDebtRepaid;
      const expectedMaxLiquidation = (totalDebt * 50n) / 100n; // 50% close factor
      
      expect(actualLiquidatedAmount).to.be.lte(expectedMaxLiquidation);
    });

    it("Should handle partial liquidations correctly", async function () {
      // Make position liquidatable
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 60n) / 100n;
      await oracle.setPrice(1, newEthPrice);

      // Perform multiple partial liquidations
      const partialAmount = toUsdc("1000");
      await usdc.connect(liquidator).approve(await corePool.getAddress(), BigInt(partialAmount) * 3n);

      const initialDebt = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());

      // First liquidation
      await liquidationEngine.connect(liquidator).liquidate(
        borrower.address,
        await usdc.getAddress(),
        await weth.getAddress(),
        partialAmount
      );

      const debtAfterFirst = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());
      expect(debtAfterFirst).to.be.lt(initialDebt);

      // Second liquidation (if still liquidatable)
      if (await riskController.isAccountLiquidatable(borrower.address)) {
        await liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          partialAmount
        );

        const debtAfterSecond = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());
        expect(debtAfterSecond).to.be.lt(debtAfterFirst);
      }
    });

    it("Should handle liquidation with accrued interest", async function () {
      // Accrue interest over time
      await time.increase(TEST_CONSTANTS.TIME.YEAR);
      await corePool.accrueInterest(await usdc.getAddress());

      // Get debt with interest
      const debtWithInterest = await corePool.getUserBorrowBalance(borrower.address, await usdc.getAddress());
      expect(debtWithInterest).to.be.gt(borrowAmount);

      // Make position liquidatable
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 50n) / 100n; // Even lower price
      await oracle.setPrice(1, newEthPrice);

      // Liquidate with interest included
      const liquidationAmount = toUsdc("5000");
      await usdc.connect(liquidator).approve(await corePool.getAddress(), liquidationAmount);

      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          liquidationAmount
        )
      ).to.emit(liquidationEngine, "LiquidationCall");
    });

    it("Should revert liquidation with insufficient collateral", async function () {
      // Make position liquidatable
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 60n) / 100n;
      await oracle.setPrice(1, newEthPrice);

      // Try to liquidate more collateral than available
      const massiveLiquidationAmount = toUsdc("50000");
      await usdc.connect(liquidator).approve(await corePool.getAddress(), massiveLiquidationAmount);

      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          massiveLiquidationAmount
        )
      ).to.be.revertedWith("CorePool: Insufficient collateral");
    });

    it("Should handle liquidation when borrower has multiple assets", async function () {
      // Borrower supplies additional USDC collateral
      await usdc.connect(borrower).approve(await corePool.getAddress(), toUsdc("5000"));
      await corePool.connect(borrower).supply(await usdc.getAddress(), toUsdc("5000"));

      // Borrow additional amount against USDC
      await corePool.connect(borrower).borrow(await weth.getAddress(), toEth("1"));

      // Make position liquidatable
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 50n) / 100n;
      await oracle.setPrice(1, newEthPrice);

      expect(await riskController.isAccountLiquidatable(borrower.address)).to.be.true;

      // Liquidate USDC debt, seize ETH collateral
      const liquidationAmount = toUsdc("2000");
      await usdc.connect(liquidator).approve(await corePool.getAddress(), liquidationAmount);

      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(), // repay USDC debt
          await weth.getAddress(), // seize ETH collateral
          liquidationAmount
        )
      ).to.emit(liquidationEngine, "LiquidationCall");
    });
  });

  describe("Liquidation Edge Cases", function () {
    it("Should handle liquidation when market is paused", async function () {
      // Setup liquidatable position
      await weth.connect(borrower).approve(await corePool.getAddress(), toEth("5"));
      await corePool.connect(borrower).supply(await weth.getAddress(), toEth("5"));

      await usdc.connect(supplier).approve(await corePool.getAddress(), toUsdc("50000"));
      await corePool.connect(supplier).supply(await usdc.getAddress(), toUsdc("50000"));

      await corePool.connect(borrower).borrow(await usdc.getAddress(), toUsdc("4000"));

      // Make liquidatable
      await oracle.setPrice(1, (BigInt(TEST_CONSTANTS.PRICES.ETH) * 50n) / 100n);

      // Pause CorePool
      await corePool.pause();

      // Liquidation should fail when pool is paused
      await usdc.connect(liquidator).approve(await corePool.getAddress(), toUsdc("2000"));
      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          toUsdc("2000")
        )
      ).to.be.revertedWith("Pausable: paused");

      // Unpause and liquidation should work
      await corePool.unpause();
      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          toUsdc("2000")
        )
      ).to.emit(liquidationEngine, "LiquidationCall");
    });

    it("Should handle liquidation with zero debt", async function () {
      // Try to liquidate account with no debt
      await usdc.connect(liquidator).approve(await corePool.getAddress(), toUsdc("1000"));
      
      await expect(
        liquidationEngine.connect(liquidator).liquidate(
          borrower.address,
          await usdc.getAddress(),
          await weth.getAddress(),
          toUsdc("1000")
        )
      ).to.be.revertedWith("LLE: Borrower has no debt for this asset");
    });

    it("Should calculate liquidation bonus correctly", async function () {
      // Setup and liquidate
      await weth.connect(borrower).approve(await corePool.getAddress(), toEth("5"));
      await corePool.connect(borrower).supply(await weth.getAddress(), toEth("5"));

      await usdc.connect(supplier).approve(await corePool.getAddress(), toUsdc("50000"));
      await corePool.connect(supplier).supply(await usdc.getAddress(), toUsdc("50000"));

      await corePool.connect(borrower).borrow(await usdc.getAddress(), toUsdc("4000"));

      // Make liquidatable
      const newEthPrice = (BigInt(TEST_CONSTANTS.PRICES.ETH) * 60n) / 100n;
      await oracle.setPrice(1, newEthPrice);

      const liquidationAmount = toUsdc("2000");
      await usdc.connect(liquidator).approve(await corePool.getAddress(), liquidationAmount);

      const initialWethBalance = await weth.balanceOf(liquidator.address);

      const tx = await liquidationEngine.connect(liquidator).liquidate(
        borrower.address,
        await usdc.getAddress(),
        await weth.getAddress(),
        liquidationAmount
      );

      const receipt = await tx.wait();
      const liquidationEvent = receipt.events?.find((e: any) => e.event === "LiquidationCall");

      // Verify bonus calculation
      const debtRepaidUsd = liquidationEvent?.args?.debtRepaidUsdValue;
      const collateralSeizedUsd = liquidationEvent?.args?.collateralSeizedUsdValue;
      
      // Collateral seized should be debt + 5% bonus
      const expectedBonus = (debtRepaidUsd * 5n) / 100n; // 5% bonus
      expect(collateralSeizedUsd).to.equal(debtRepaidUsd + expectedBonus);
    });
  });
}); 