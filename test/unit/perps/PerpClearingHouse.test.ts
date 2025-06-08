/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
/* eslint-disable @typescript-eslint/no-unused-vars */
/* eslint-disable @typescript-eslint/no-unused-vars */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc } from "../../shared/constants";

describe("PerpClearingHouse", function () {
  let clearingHouse: any;
  let usdc: any;
  let oracle: any;
  let owner: SignerWithAddress;
  let trader1: SignerWithAddress;
  let trader2: SignerWithAddress;
  let liquidator: SignerWithAddress;

  const ETH_PERP_ID = ethers.keccak256(ethers.toUtf8Bytes("ETH-PERP"));
  const BTC_PERP_ID = ethers.keccak256(ethers.toUtf8Bytes("BTC-PERP"));

  async function deployClearingHouseFixture() {
    const [owner, trader1, trader2, liquidator] = await ethers.getSigners();

    // Deploy USDC
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USD Coin", "USDC", 6, toUsdc("1000000"));

    // Deploy oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
    await (oracle as any).setPrice(2, TEST_CONSTANTS.PRICES.BTC); // BTC

    // Deploy clearing house
    const ClearingHouseFactory = await ethers.getContractFactory("PerpClearingHouse");
    const clearingHouse = await ClearingHouseFactory.deploy(
      await usdc.getAddress(),
      await oracle.getAddress(),
      owner.address,
      owner.address,
      owner.address,
      owner.address
    );

    // Setup markets
    await clearingHouse.listMarket(
      ETH_PERP_ID,
      1, // ETH oracle asset ID
      ethers.ZeroAddress, // spot oracle (using mark price oracle for now)
      2000, // 20x max leverage
      500,  // 5% IMR
      100,  // 1% liquidation fee
      30,   // 0.3% taker fee
      10,   // 0.1% maker fee
      3600, // 1 hour funding interval
      75,   // 0.75% max funding rate
      1000, // 10% funding protocol fee
      toUsdc("10") // $10 min position size
    );

    await clearingHouse.listMarket(
      BTC_PERP_ID,
      2, // BTC oracle asset ID
      ethers.ZeroAddress,
      1000, // 10x max leverage
      1000, // 10% IMR
      150,  // 1.5% liquidation fee
      30,   // 0.3% taker fee
      10,   // 0.1% maker fee
      3600, // 1 hour funding interval
      75,   // 0.75% max funding rate
      1000, // 10% funding protocol fee
      toUsdc("50") // $50 min position size
    );

    // Fund traders
    await (usdc as any).transfer(trader1.address, toUsdc("100000"));
    await (usdc as any).transfer(trader2.address, toUsdc("100000"));
    await (usdc as any).transfer(liquidator.address, toUsdc("50000"));

    return {
      clearingHouse,
      usdc,
      oracle,
      owner,
      trader1,
      trader2,
      liquidator
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployClearingHouseFixture);
    clearingHouse = fixture.clearingHouse;
    usdc = fixture.usdc;
    oracle = fixture.oracle;
    owner = fixture.owner;
    trader1 = fixture.trader1;
    trader2 = fixture.trader2;
    liquidator = fixture.liquidator;
  });

  describe("Deployment", function () {
    it("Should set correct USDC address", async function () {
      expect(await clearingHouse.usdcToken()).to.equal(await usdc.getAddress());
    });

    it("Should set correct oracle address", async function () {
      expect(await clearingHouse.markPriceOracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await clearingHouse.owner()).to.equal(owner.address);
    });

    it("Should list markets correctly", async function () {
      const ethMarket = await clearingHouse.perpMarkets(ETH_PERP_ID);
      expect(ethMarket.isListed).to.be.true;
      expect(ethMarket.maxLeverage).to.equal(2000);

      const btcMarket = await clearingHouse.perpMarkets(BTC_PERP_ID);
      expect(btcMarket.isListed).to.be.true;
      expect(btcMarket.maxLeverage).to.equal(1000);
    });
  });

  describe("Deposit Margin", function () {
    const depositAmount = toUsdc("10000");

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), depositAmount);
    });

    it("Should deposit margin successfully", async function () {
      const initialBalance = await usdc.balanceOf(trader1.address);

      await expect(clearingHouse.connect(trader1).depositMargin(depositAmount))
        .to.emit(clearingHouse, "MarginDeposited")
        .withArgs(trader1.address, depositAmount);

      expect(await usdc.balanceOf(trader1.address)).to.equal(initialBalance - BigInt(depositAmount));
      expect(await clearingHouse.getMarginBalance(trader1.address)).to.equal(depositAmount);
    });

    it("Should revert with zero amount", async function () {
      await expect(
        clearingHouse.connect(trader1).depositMargin(0)
      ).to.be.revertedWith("PerpClearingHouse: Cannot deposit 0");
    });

    it("Should handle multiple deposits", async function () {
      await clearingHouse.connect(trader1).depositMargin(depositAmount);
      await clearingHouse.connect(trader1).depositMargin(depositAmount);

      expect(await clearingHouse.getMarginBalance(trader1.address)).to.equal(BigInt(depositAmount) * 2n);
    });
  });

  describe("Withdraw Margin", function () {
    const depositAmount = toUsdc("10000");
    const withdrawAmount = toUsdc("5000");

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), depositAmount);
      await clearingHouse.connect(trader1).depositMargin(depositAmount);
    });

    it("Should withdraw margin successfully", async function () {
      const initialBalance = await usdc.balanceOf(trader1.address);

      await expect(clearingHouse.connect(trader1).withdrawMargin(withdrawAmount))
        .to.emit(clearingHouse, "MarginWithdrawn")
        .withArgs(trader1.address, withdrawAmount);

      expect(await usdc.balanceOf(trader1.address)).to.equal(initialBalance + BigInt(withdrawAmount));
      expect(await clearingHouse.getMarginBalance(trader1.address)).to.equal(
        BigInt(depositAmount) - BigInt(withdrawAmount)
      );
    });

    it("Should revert with insufficient margin", async function () {
      const largeAmount = toUsdc("20000");

      await expect(
        clearingHouse.connect(trader1).withdrawMargin(largeAmount)
      ).to.be.revertedWith("PerpClearingHouse: Insufficient margin");
    });

    it("Should revert withdrawal that would break margin requirements", async function () {
      // Open a position first
      await clearingHouse.connect(trader1).openPosition(
        ETH_PERP_ID,
        true, // long
        toUsdc("5000"), // $5000 position size
        0 // no specific price limit
      );

      // Try to withdraw too much margin
      await expect(
        clearingHouse.connect(trader1).withdrawMargin(toUsdc("9000"))
      ).to.be.revertedWith("PerpClearingHouse: Would break margin requirements");
    });
  });

  describe("Open Position", function () {
    const marginAmount = toUsdc("10000");
    const positionSize = toUsdc("5000");

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), marginAmount);
      await clearingHouse.connect(trader1).depositMargin(marginAmount);
    });

    it("Should open long position successfully", async function () {
      await expect(
        clearingHouse.connect(trader1).openPosition(
          ETH_PERP_ID,
          true, // long
          positionSize,
          0
        )
      ).to.emit(clearingHouse, "PositionOpened");

      const position = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);
      expect(position.size).to.be.gt(0); // Should have positive size for long
      expect(position.isLong).to.be.true;
    });

    it("Should open short position successfully", async function () {
      await expect(
        clearingHouse.connect(trader1).openPosition(
          ETH_PERP_ID,
          false, // short
          positionSize,
          0
        )
      ).to.emit(clearingHouse, "PositionOpened");

      const position = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);
      expect(position.size).to.be.lt(0); // Should have negative size for short
      expect(position.isLong).to.be.false;
    });

    it("Should revert with insufficient margin", async function () {
      const largePositionSize = toUsdc("100000"); // Much larger than margin allows

      await expect(
        clearingHouse.connect(trader1).openPosition(
          ETH_PERP_ID,
          true,
          largePositionSize,
          0
        )
      ).to.be.revertedWith("PerpClearingHouse: Insufficient margin");
    });

    it("Should revert with unlisted market", async function () {
      const unknownMarketId = ethers.keccak256(ethers.toUtf8Bytes("UNKNOWN-PERP"));

      await expect(
        clearingHouse.connect(trader1).openPosition(
          unknownMarketId,
          true,
          positionSize,
          0
        )
      ).to.be.revertedWith("PerpClearingHouse: Market not listed");
    });

    it("Should respect minimum position size", async function () {
      const tinyPosition = toUsdc("1"); // Below $10 minimum

      await expect(
        clearingHouse.connect(trader1).openPosition(
          ETH_PERP_ID,
          true,
          tinyPosition,
          0
        )
      ).to.be.revertedWith("PerpClearingHouse: Position too small");
    });

    it("Should charge trading fees", async function () {
      const initialMargin = await clearingHouse.getMarginBalance(trader1.address);

      await clearingHouse.connect(trader1).openPosition(
        ETH_PERP_ID,
        true,
        positionSize,
        0
      );

      const finalMargin = await clearingHouse.getMarginBalance(trader1.address);
      expect(finalMargin).to.be.lt(initialMargin); // Margin reduced by fees
    });
  });

  describe("Close Position", function () {
    const marginAmount = toUsdc("10000");
    const positionSize = toUsdc("5000");

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), marginAmount);
      await clearingHouse.connect(trader1).depositMargin(marginAmount);
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0);
    });

    it("Should close position successfully", async function () {
      await expect(
        clearingHouse.connect(trader1).closePosition(ETH_PERP_ID, 0)
      ).to.emit(clearingHouse, "PositionClosed");

      const position = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);
      expect(position.size).to.equal(0);
    });

    it("Should realize PnL on position close", async function () {
      // Change price to create PnL
      await (oracle as any).setPrice(1, BigInt(TEST_CONSTANTS.PRICES.ETH) * 110n / 100n); // 10% price increase

      const initialMargin = await clearingHouse.getMarginBalance(trader1.address);

      await clearingHouse.connect(trader1).closePosition(ETH_PERP_ID, 0);

      const finalMargin = await clearingHouse.getMarginBalance(trader1.address);
      expect(finalMargin).to.be.gt(initialMargin); // Should have profit from long position
    });

    it("Should revert closing non-existent position", async function () {
      await expect(
        clearingHouse.connect(trader2).closePosition(ETH_PERP_ID, 0)
      ).to.be.revertedWith("PerpClearingHouse: No position to close");
    });
  });

  describe("Position Management", function () {
    const marginAmount = toUsdc("10000");
    const positionSize = toUsdc("5000");

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), marginAmount);
      await clearingHouse.connect(trader1).depositMargin(marginAmount);
    });

    it("Should allow increasing position size", async function () {
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0);
      const initialPosition = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);

      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0);
      const finalPosition = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);

      expect(Math.abs(Number(finalPosition.size))).to.be.gt(Math.abs(Number(initialPosition.size)));
    });

    it("Should allow reducing position size", async function () {
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0);
      
      // Open opposite direction to reduce
      const reduceSize = toUsdc("2000");
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, false, reduceSize, 0);

      const position = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);
      expect(Math.abs(Number(position.size))).to.be.lt(Number(positionSize));
    });

    it("Should flip position direction", async function () {
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0);
      
      // Open larger opposite position
      const flipSize = toUsdc("8000");
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, false, flipSize, 0);

      const position = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);
      expect(position.isLong).to.be.false; // Should have flipped to short
    });
  });

  describe("Liquidation", function () {
    const marginAmount = toUsdc("2000"); // Smaller margin for easier liquidation
    const positionSize = toUsdc("10000"); // Large position relative to margin

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), marginAmount);
      await clearingHouse.connect(trader1).depositMargin(marginAmount);
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0);

      // Fund liquidator
      await usdc.connect(liquidator).approve(await clearingHouse.getAddress(), toUsdc("50000"));
      await clearingHouse.connect(liquidator).depositMargin(toUsdc("20000"));
    });

    it("Should liquidate underwater position", async function () {
      // Crash price to make position liquidatable
      await oracle.setPrice(1, TEST_CONSTANTS.PRICES.ETH * 80n / 100n); // 20% price drop

      // Check if position is liquidatable
      const isLiquidatable = await clearingHouse.isPositionLiquidatable(trader1.address, ETH_PERP_ID);
      expect(isLiquidatable).to.be.true;

      // Execute liquidation
      await expect(
        clearingHouse.connect(liquidator).liquidatePosition(trader1.address, ETH_PERP_ID)
      ).to.emit(clearingHouse, "PositionLiquidated");

      // Position should be closed
      const position = await clearingHouse.getPosition(trader1.address, ETH_PERP_ID);
      expect(position.size).to.equal(0);
    });

    it("Should prevent liquidation of healthy positions", async function () {
      const isLiquidatable = await clearingHouse.isPositionLiquidatable(trader1.address, ETH_PERP_ID);
      expect(isLiquidatable).to.be.false;

      await expect(
        clearingHouse.connect(liquidator).liquidatePosition(trader1.address, ETH_PERP_ID)
      ).to.be.revertedWith("PerpClearingHouse: Position not liquidatable");
    });

    it("Should reward liquidator", async function () {
      // Make position liquidatable
      await oracle.setPrice(1, TEST_CONSTANTS.PRICES.ETH * 80n / 100n);

      const initialLiquidatorMargin = await clearingHouse.getMarginBalance(liquidator.address);

      await clearingHouse.connect(liquidator).liquidatePosition(trader1.address, ETH_PERP_ID);

      const finalLiquidatorMargin = await clearingHouse.getMarginBalance(liquidator.address);
      expect(finalLiquidatorMargin).to.be.gt(initialLiquidatorMargin); // Liquidator gets reward
    });
  });

  describe("Funding Payments", function () {
    const marginAmount = toUsdc("10000");
    const positionSize = toUsdc("5000");

    beforeEach(async function () {
      // Setup two traders with opposite positions
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), marginAmount);
      await usdc.connect(trader2).approve(await clearingHouse.getAddress(), marginAmount);
      
      await clearingHouse.connect(trader1).depositMargin(marginAmount);
      await clearingHouse.connect(trader2).depositMargin(marginAmount);
      
      await clearingHouse.connect(trader1).openPosition(ETH_PERP_ID, true, positionSize, 0); // Long
      await clearingHouse.connect(trader2).openPosition(ETH_PERP_ID, false, positionSize, 0); // Short
    });

    it("Should calculate funding payments", async function () {
      // Fast forward past funding interval
      await time.increase(3600); // 1 hour

      const fundingRate = await clearingHouse.getCurrentFundingRate(ETH_PERP_ID);
      expect(fundingRate).to.not.equal(0); // Should have some funding rate
    });

    it("Should apply funding payments", async function () {
      const initialMargin1 = await clearingHouse.getMarginBalance(trader1.address);
      const initialMargin2 = await clearingHouse.getMarginBalance(trader2.address);

      // Fast forward and update funding
      await time.increase(3600);
      await clearingHouse.updateFunding(ETH_PERP_ID);

      const finalMargin1 = await clearingHouse.getMarginBalance(trader1.address);
      const finalMargin2 = await clearingHouse.getMarginBalance(trader2.address);

      // One trader should pay funding, the other should receive
      const change1 = finalMargin1 - initialMargin1;
      const change2 = finalMargin2 - initialMargin2;
      
      expect(change1 + change2).to.be.lt(0); // Protocol takes a cut
    });
  });

  describe("Admin Functions", function () {
    it("Should allow owner to pause trading", async function () {
      await clearingHouse.pause();
      expect(await clearingHouse.paused()).to.be.true;

      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), toUsdc("1000"));
      
      await expect(
        clearingHouse.connect(trader1).depositMargin(toUsdc("1000"))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should allow owner to update market parameters", async function () {
      const newMaxLeverage = 1500; // 15x

      await expect(
        clearingHouse.updateMarketParameters(
          ETH_PERP_ID,
          newMaxLeverage,
          600, // 6% IMR
          120  // 1.2% liquidation fee
        )
      ).to.emit(clearingHouse, "MarketParametersUpdated");

      const market = await clearingHouse.perpMarkets(ETH_PERP_ID);
      expect(market.maxLeverage).to.equal(newMaxLeverage);
    });

    it("Should not allow non-owner to update parameters", async function () {
      await expect(
        clearingHouse.connect(trader1).updateMarketParameters(ETH_PERP_ID, 1500, 600, 120)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should allow owner to set insurance fund", async function () {
      await expect(clearingHouse.setInsuranceFundAddress(trader1.address))
        .to.emit(clearingHouse, "InsuranceFundUpdated")
        .withArgs(trader1.address);
    });
  });
}); 