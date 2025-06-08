/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc, toEth } from "../../shared/constants";

describe("LendRiskController", function () {
  let riskController: any;
  let oracle: any;
  let usdc: any;
  let weth: any;
  let wbtc: any;
  let owner: SignerWithAddress;
  let admin: SignerWithAddress;
  let user: SignerWithAddress;

  async function deployRiskControllerFixture() {
    const [owner, admin, user] = await ethers.getSigners();

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    
    // Set initial prices
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
    await (oracle as any).setPrice(2, TEST_CONSTANTS.PRICES.BTC); // BTC
    await (oracle as any).setPrice(3, TEST_CONSTANTS.PRICES.USDC); // USDC

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);
    const weth = await MockERC20Factory.deploy("WETH", "WETH", 18, 0);
    const wbtc = await MockERC20Factory.deploy("WBTC", "WBTC", 8, 0);

    // Deploy LendRiskController
    const RiskControllerFactory = await ethers.getContractFactory("LendRiskController");
    const riskController = await RiskControllerFactory.deploy(
      await oracle.getAddress(),
      owner.address,
      "500", // Default liquidation incentive
      toUsdc("100") // Min liquidation amount
    );

    // Setup token configurations
    await (riskController as any).addMarket(
      await usdc.getAddress(),
      3, // Oracle asset ID for USDC
      8000, // 80% collateral factor
      9000, // 90% liquidation threshold
      200, // 2% liquidation bonus
      10000, // 100% borrow cap
      10000 // 100% supply cap
    );

    await (riskController as any).addMarket(
      await weth.getAddress(),
      1, // Oracle asset ID for ETH
      7500, // 75% collateral factor
      8500, // 85% liquidation threshold
      500, // 5% liquidation bonus
      8000, // 80% borrow cap
      9000 // 90% supply cap
    );

    await (riskController as any).addMarket(
      await wbtc.getAddress(),
      2, // Oracle asset ID for BTC
      7000, // 70% collateral factor
      8000, // 80% liquidation threshold
      800, // 8% liquidation bonus
      7000, // 70% borrow cap
      8500 // 85% supply cap
    );

    return {
      riskController,
      oracle,
      usdc,
      weth,
      wbtc,
      owner,
      admin,
      user
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployRiskControllerFixture);
    riskController = fixture.riskController;
    oracle = fixture.oracle;
    usdc = fixture.usdc;
    weth = fixture.weth;
    wbtc = fixture.wbtc;
    owner = fixture.owner;
    admin = fixture.admin;
    user = fixture.user;
  });

  describe("Initialization", function () {
    it("Should set correct oracle", async function () {
      expect(await riskController.oracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await riskController.owner()).to.equal(owner.address);
    });

    it("Should have default parameters", async function () {
      expect(await riskController.defaultLiquidationIncentive()).to.equal(500); // 5%
      expect(await riskController.minLiquidationAmount()).to.equal(toUsdc("100"));
    });
  });

  describe("Market Management", function () {
    it("Should add new market", async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20Factory.deploy("NEW", "NEW", 18, 0);

      await expect(
        riskController.addMarket(
          await newToken.getAddress(),
          4, // New oracle asset ID
          6000, // 60% collateral factor
          7500, // 75% liquidation threshold
          300, // 3% liquidation bonus
          5000, // 50% borrow cap
          7000 // 70% supply cap
        )
      ).to.emit(riskController, "MarketAdded")
      .withArgs(await newToken.getAddress());

      const market = await riskController.markets(await newToken.getAddress());
      expect(market.isListed).to.be.true;
      expect(market.collateralFactor).to.equal(6000);
      expect(market.liquidationThreshold).to.equal(7500);
    });

    it("Should update market parameters", async function () {
      const newCollateralFactor = 8500;
      const newLiquidationThreshold = 9500;
      const newLiquidationBonus = 300;

      await expect(
        riskController.updateMarketParameters(
          await usdc.getAddress(),
          newCollateralFactor,
          newLiquidationThreshold,
          newLiquidationBonus
        )
      ).to.emit(riskController, "MarketParametersUpdated")
      .withArgs(await usdc.getAddress(), newCollateralFactor, newLiquidationThreshold, newLiquidationBonus);

      const market = await riskController.markets(await usdc.getAddress());
      expect(market.collateralFactor).to.equal(newCollateralFactor);
      expect(market.liquidationThreshold).to.equal(newLiquidationThreshold);
      expect(market.liquidationBonus).to.equal(newLiquidationBonus);
    });

    it("Should set borrow caps", async function () {
      const newBorrowCap = 5000; // 50%

      await expect(
        riskController.setBorrowCap(await usdc.getAddress(), newBorrowCap)
      ).to.emit(riskController, "BorrowCapUpdated")
      .withArgs(await usdc.getAddress(), newBorrowCap);

      const market = await riskController.markets(await usdc.getAddress());
      expect(market.borrowCap).to.equal(newBorrowCap);
    });

    it("Should set supply caps", async function () {
      const newSupplyCap = 8000; // 80%

      await expect(
        riskController.setSupplyCap(await usdc.getAddress(), newSupplyCap)
      ).to.emit(riskController, "SupplyCapUpdated")
      .withArgs(await usdc.getAddress(), newSupplyCap);

      const market = await riskController.markets(await usdc.getAddress());
      expect(market.supplyCap).to.equal(newSupplyCap);
    });

    it("Should not allow non-owner to add markets", async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20Factory.deploy("NEW", "NEW", 18, 0);

      await expect(
        riskController.connect(user).addMarket(
          await newToken.getAddress(),
          4, 6000, 7500, 300, 5000, 7000
        )
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should validate market parameters", async function () {
      const MockERC20Factory = await ethers.getContractFactory("MockERC20");
      const newToken = await MockERC20Factory.deploy("NEW", "NEW", 18, 0);

      // Collateral factor > liquidation threshold
      await expect(
        riskController.addMarket(
          await newToken.getAddress(),
          4, 9000, 8000, 300, 5000, 7000
        )
      ).to.be.revertedWith("Invalid parameters");
    });
  });

  describe("Collateral Calculations", function () {
    it("Should calculate account liquidity correctly", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("10000") },
        { asset: await weth.getAddress(), amount: toEth("5") }
      ];
      const borrows = [
        { asset: await usdc.getAddress(), amount: toUsdc("5000") }
      ];

      const liquidity = await riskController.getAccountLiquidity(account, supplies, borrows);
      
      expect(liquidity.liquidity).to.be.gt(0);
      expect(liquidity.shortfall).to.equal(0);
    });

    it("Should detect shortfall when over-borrowed", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("1000") }
      ];
      const borrows = [
        { asset: await weth.getAddress(), amount: toEth("1") } // $2000 borrow vs $1000 supply
      ];

      const liquidity = await riskController.getAccountLiquidity(account, supplies, borrows);
      
      expect(liquidity.liquidity).to.equal(0);
      expect(liquidity.shortfall).to.be.gt(0);
    });

    it("Should calculate weighted collateral value", async function () {
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("10000") }, // $10,000 * 80% = $8,000
        { asset: await weth.getAddress(), amount: toEth("2") }       // $4,000 * 75% = $3,000
      ];

      const totalCollateral = await riskController.calculateWeightedCollateral(supplies);
      
      // Should be approximately $11,000 (8000 + 3000)
      expect(totalCollateral).to.be.closeTo(toUsdc("11000"), toUsdc("100"));
    });

    it("Should calculate total borrow value", async function () {
      const borrows = [
        { asset: await usdc.getAddress(), amount: toUsdc("5000") }, // $5,000
        { asset: await weth.getAddress(), amount: toEth("1") }      // $2,000
      ];

      const totalBorrow = await riskController.calculateTotalBorrowValue(borrows);
      
      // Should be approximately $7,000
      expect(totalBorrow).to.be.closeTo(toUsdc("7000"), toUsdc("100"));
    });

    it("Should handle price changes", async function () {
      const supplies = [
        { asset: await weth.getAddress(), amount: toEth("1") }
      ];

      const initialCollateral = await riskController.calculateWeightedCollateral(supplies);
      
             // Double ETH price
       await (oracle as any).setPrice(1, Number(TEST_CONSTANTS.PRICES.ETH) * 2);
      
      const newCollateral = await riskController.calculateWeightedCollateral(supplies);
      
      expect(newCollateral).to.be.gt(initialCollateral);
    });
  });

  describe("Liquidation Logic", function () {
    it("Should determine if account is liquidatable", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("1000") }
      ];
      const borrows = [
        { asset: await weth.getAddress(), amount: toEth("1") } // Over-borrowed
      ];

      const canLiquidate = await riskController.canLiquidate(account, supplies, borrows);
      expect(canLiquidate).to.be.true;
    });

    it("Should calculate liquidation amount", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("1000") }
      ];
      const borrows = [
        { asset: await weth.getAddress(), amount: toEth("1") }
      ];

      const liquidationAmount = await riskController.calculateLiquidationAmount(
        account,
        supplies,
        borrows,
        await weth.getAddress()
      );

      expect(liquidationAmount).to.be.gt(0);
      expect(liquidationAmount).to.be.lte(toEth("0.5")); // Max 50% of borrow
    });

    it("Should calculate liquidation bonus", async function () {
      const repayAmount = toEth("0.5");
      const repayAsset = await weth.getAddress();
      const collateralAsset = await usdc.getAddress();

      const bonus = await riskController.calculateLiquidationBonus(
        repayAmount,
        repayAsset,
        collateralAsset
      );

      expect(bonus).to.be.gt(0);
    });

    it("Should get liquidation parameters", async function () {
      const asset = await usdc.getAddress();
      const params = await riskController.getLiquidationParameters(asset);

      expect(params.threshold).to.equal(9000); // 90%
      expect(params.bonus).to.equal(200); // 2%
      expect(params.minAmount).to.equal(toUsdc("100"));
    });

    it("Should not liquidate healthy accounts", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("10000") }
      ];
      const borrows = [
        { asset: await weth.getAddress(), amount: toEth("2") } // Healthy ratio
      ];

      const canLiquidate = await riskController.canLiquidate(account, supplies, borrows);
      expect(canLiquidate).to.be.false;
    });
  });

  describe("Interest Rate Models", function () {
    it("Should calculate supply rate", async function () {
      const asset = await usdc.getAddress();
      const totalSupply = toUsdc("1000000");
      const totalBorrow = toUsdc("500000");
      const reserveFactor = 1000; // 10%

      const supplyRate = await riskController.getSupplyRate(
        asset,
        totalSupply,
        totalBorrow,
        reserveFactor
      );

      expect(supplyRate).to.be.gt(0);
    });

    it("Should calculate borrow rate", async function () {
      const asset = await usdc.getAddress();
      const totalSupply = toUsdc("1000000");
      const totalBorrow = toUsdc("500000");

      const borrowRate = await riskController.getBorrowRate(
        asset,
        totalSupply,
        totalBorrow
      );

      expect(borrowRate).to.be.gt(0);
    });

    it("Should handle utilization rate changes", async function () {
      const asset = await usdc.getAddress();
      const totalSupply = toUsdc("1000000");
      
      // Low utilization
      const lowBorrow = toUsdc("100000");
      const lowRate = await riskController.getBorrowRate(asset, totalSupply, lowBorrow);
      
      // High utilization
      const highBorrow = toUsdc("900000");
      const highRate = await riskController.getBorrowRate(asset, totalSupply, highBorrow);

      expect(highRate).to.be.gt(lowRate);
    });

    it("Should update interest rate model", async function () {
      const asset = await usdc.getAddress();
      const newModel = {
        baseRate: 200, // 2%
        multiplier: 1000, // 10%
        jumpMultiplier: 5000, // 50%
        kink: 8000 // 80%
      };

      await expect(
        riskController.updateInterestRateModel(asset, newModel)
      ).to.emit(riskController, "InterestRateModelUpdated")
      .withArgs(asset);

      const model = await riskController.interestRateModels(asset);
      expect(model.baseRate).to.equal(newModel.baseRate);
      expect(model.multiplier).to.equal(newModel.multiplier);
    });
  });

  describe("Risk Assessment", function () {
    it("Should assess portfolio risk", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("10000") },
        { asset: await weth.getAddress(), amount: toEth("5") },
        { asset: await wbtc.getAddress(), amount: "100000000" } // 1 BTC
      ];
      const borrows = [
        { asset: await usdc.getAddress(), amount: toUsdc("20000") }
      ];

      const risk = await riskController.assessPortfolioRisk(account, supplies, borrows);
      
      expect(risk.healthFactor).to.be.gt(0);
      expect(risk.riskLevel).to.be.oneOf([0, 1, 2, 3]); // LOW, MEDIUM, HIGH, CRITICAL
    });

    it("Should calculate health factor", async function () {
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("10000") }
      ];
      const borrows = [
        { asset: await usdc.getAddress(), amount: toUsdc("5000") }
      ];

      const healthFactor = await riskController.calculateHealthFactor(supplies, borrows);
      
      // Health factor should be > 1 for safe position
      expect(healthFactor).to.be.gt(1e18); // 1.0 in 18 decimals
    });

    it("Should detect concentration risk", async function () {
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("100000") } // 100% USDC
      ];

      const concentrationRisk = await riskController.calculateConcentrationRisk(supplies);
      
      expect(concentrationRisk).to.be.gt(0);
    });

    it("Should calculate volatility risk", async function () {
      const supplies = [
        { asset: await wbtc.getAddress(), amount: "100000000" } // 1 BTC (high volatility)
      ];

      const volatilityRisk = await riskController.calculateVolatilityRisk(supplies);
      
      expect(volatilityRisk).to.be.gt(0);
    });
  });

  describe("Emergency Controls", function () {
    it("Should pause markets", async function () {
      const asset = await usdc.getAddress();

      await expect(
        riskController.pauseMarket(asset)
      ).to.emit(riskController, "MarketPaused")
      .withArgs(asset);

      const market = await riskController.markets(asset);
      expect(market.isPaused).to.be.true;
    });

    it("Should unpause markets", async function () {
      const asset = await usdc.getAddress();
      
      await riskController.pauseMarket(asset);
      
      await expect(
        riskController.unpauseMarket(asset)
      ).to.emit(riskController, "MarketUnpaused")
      .withArgs(asset);

      const market = await riskController.markets(asset);
      expect(market.isPaused).to.be.false;
    });

    it("Should reject operations on paused markets", async function () {
      const asset = await usdc.getAddress();
      await riskController.pauseMarket(asset);

      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("1000") }
      ];
      const borrows: any[] = [];

      await expect(
        riskController.getAccountLiquidity(user.address, supplies, borrows)
      ).to.be.revertedWith("Market paused");
    });

    it("Should set emergency parameters", async function () {
      const asset = await usdc.getAddress();
      const emergencyLiquidationThreshold = 5000; // 50%

      await riskController.setEmergencyLiquidationThreshold(asset, emergencyLiquidationThreshold);

      const market = await riskController.markets(asset);
      expect(market.emergencyLiquidationThreshold).to.equal(emergencyLiquidationThreshold);
    });
  });

  describe("Oracle Integration", function () {
    it("Should get asset prices from oracle", async function () {
      const ethPrice = await riskController.getAssetPrice(await weth.getAddress());
      const btcPrice = await riskController.getAssetPrice(await wbtc.getAddress());
      const usdcPrice = await riskController.getAssetPrice(await usdc.getAddress());

      expect(ethPrice).to.equal(TEST_CONSTANTS.PRICES.ETH);
      expect(btcPrice).to.equal(TEST_CONSTANTS.PRICES.BTC);
      expect(usdcPrice).to.equal(TEST_CONSTANTS.PRICES.USDC);
    });

    it("Should handle oracle failures gracefully", async function () {
      // Simulate oracle failure by setting price to 0
      await (oracle as any).setPrice(1, 0);

      await expect(
        riskController.getAssetPrice(await weth.getAddress())
      ).to.be.revertedWith("Invalid oracle price");
    });

    it("Should validate price freshness", async function () {
      const stalePriceThreshold = 3600; // 1 hour
      await riskController.setStalePriceThreshold(stalePriceThreshold);

      // This would require a more complex oracle mock to test properly
      // For now, we'll just verify the threshold is set
      expect(await riskController.stalePriceThreshold()).to.equal(stalePriceThreshold);
    });
  });

  describe("Complex Scenarios", function () {
    it("Should handle multi-asset liquidation", async function () {
      const account = user.address;
      const supplies = [
        { asset: await usdc.getAddress(), amount: toUsdc("5000") },
        { asset: await weth.getAddress(), amount: toEth("1") }
      ];
      const borrows = [
        { asset: await wbtc.getAddress(), amount: "20000000" } // 0.2 BTC
      ];

      const liquidationInfo = await riskController.getLiquidationInfo(
        account,
        supplies,
        borrows
      );

      expect(liquidationInfo.canLiquidate).to.be.true;
      expect(liquidationInfo.maxRepayAmount).to.be.gt(0);
      expect(liquidationInfo.collateralSeized).to.be.gt(0);
    });

    it("Should handle edge case: dust amounts", async function () {
      const supplies = [
        { asset: await usdc.getAddress(), amount: "1" } // 1 wei
      ];
      const borrows = [
        { asset: await weth.getAddress(), amount: "1" } // 1 wei
      ];

      const liquidity = await riskController.getAccountLiquidity(user.address, supplies, borrows);
      
      // Should handle dust amounts without reverting
      expect(liquidity.liquidity).to.be.gte(0);
      expect(liquidity.shortfall).to.be.gte(0);
    });

    it("Should handle maximum utilization", async function () {
      const asset = await usdc.getAddress();
      const totalSupply = toUsdc("1000000");
      const totalBorrow = toUsdc("999999"); // 99.9999% utilization

      const borrowRate = await riskController.getBorrowRate(asset, totalSupply, totalBorrow);
      
      // Should be very high but not infinite
      expect(borrowRate).to.be.gt(0);
      expect(borrowRate).to.be.lt(ethers.MaxUint256);
    });

    it("Should handle price volatility scenarios", async function () {
      const supplies = [
        { asset: await weth.getAddress(), amount: toEth("10") }
      ];
      const borrows = [
        { asset: await usdc.getAddress(), amount: toUsdc("15000") }
      ];

      // Initial state - healthy
      let liquidity = await riskController.getAccountLiquidity(user.address, supplies, borrows);
      expect(liquidity.shortfall).to.equal(0);

             // Crash ETH price by 50%
       await (oracle as any).setPrice(1, Number(TEST_CONSTANTS.PRICES.ETH) / 2);

      // Should now be liquidatable
      liquidity = await riskController.getAccountLiquidity(user.address, supplies, borrows);
      expect(liquidity.shortfall).to.be.gt(0);
    });
  });

  describe("Governance Functions", function () {
    it("Should update global parameters", async function () {
      const newLiquidationIncentive = 1000; // 10%
      const newMinLiquidationAmount = toUsdc("50");

      await riskController.updateGlobalParameters(
        newLiquidationIncentive,
        newMinLiquidationAmount
      );

      expect(await riskController.defaultLiquidationIncentive()).to.equal(newLiquidationIncentive);
      expect(await riskController.minLiquidationAmount()).to.equal(newMinLiquidationAmount);
    });

    it("Should transfer ownership", async function () {
      await expect(
        riskController.transferOwnership(admin.address)
      ).to.emit(riskController, "OwnershipTransferred")
      .withArgs(owner.address, admin.address);

      expect(await riskController.owner()).to.equal(admin.address);
    });

    it("Should only allow owner to perform admin functions", async function () {
      await expect(
        riskController.connect(user).updateGlobalParameters(1000, toUsdc("50"))
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });
}); 