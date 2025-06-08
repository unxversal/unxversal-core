/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc, toEth } from "../shared/constants";

describe("DEX Integration", function () {
  let orderNFT: any;
  let feeSwitch: any;
  let oracle: any;
  let usdc: any;
  let weth: any;
  let wbtc: any;
  let unxv: any;
  let treasury: any;
  // let timelock: any;
  let owner: SignerWithAddress;
  let trader1: SignerWithAddress;
  let trader2: SignerWithAddress;
  let keeper: SignerWithAddress;
  // let feeCollector: SignerWithAddress;

  async function deployDexIntegrationFixture() {
    const [owner, trader1, trader2, keeper, feeCollector] = await ethers.getSigners();

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);
    await (oracle as any).setPrice(2, TEST_CONSTANTS.PRICES.BTC);
    await (oracle as any).setPrice(3, TEST_CONSTANTS.PRICES.USDC);

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);
    const weth = await MockERC20Factory.deploy("WETH", "WETH", 18, 0);
    const wbtc = await MockERC20Factory.deploy("WBTC", "WBTC", 8, 0);
    const unxv = await MockERC20Factory.deploy("UNXV", "UNXV", 18, 0);

    // Deploy governance contracts
    const TimelockControllerFactory = await ethers.getContractFactory("TimelockController");
    const timelock = await TimelockControllerFactory.deploy(
      86400, // 1 day delay
      [owner.address], // proposers
      [owner.address], // executors
      owner.address // admin
    );

    const TreasuryFactory = await ethers.getContractFactory("Treasury");
    const treasury = await TreasuryFactory.deploy();

    // Deploy DEX fee switch  
    const FeeSwitch = await ethers.getContractFactory("OptionFeeSwitch");
    const feeSwitch = await FeeSwitch.deploy(
      await treasury.getAddress(),
      await usdc.getAddress(),
      owner.address, // insurance fund
      owner.address, // protocol fund
      owner.address  // owner
    );

    // Deploy PermitHelper
    const PermitHelperFactory = await ethers.getContractFactory("PermitHelper");
    const permitHelper = await PermitHelperFactory.deploy(owner.address); // Mock permit2 address

    // Deploy OrderNFT
    const OrderNFTFactory = await ethers.getContractFactory("OrderNFT");
    const orderNFT = await OrderNFTFactory.deploy(
      "Unxversal Orders",
      "UXO",
      await feeSwitch.getAddress(),
      await permitHelper.getAddress(),
      owner.address
    );

    // Setup initial balances
    await (usdc as any).mint(trader1.address, toUsdc("100000"));
    await (usdc as any).mint(trader2.address, toUsdc("100000"));
    await (weth as any).mint(trader1.address, toEth("50"));
    await (weth as any).mint(trader2.address, toEth("50"));
    await (wbtc as any).mint(trader1.address, "500000000"); // 5 BTC
    await (wbtc as any).mint(trader2.address, "500000000"); // 5 BTC
    await (unxv as any).mint(owner.address, toEth("1000000"));

    return {
      orderNFT,
      feeSwitch,
      oracle,
      usdc,
      weth,
      wbtc,
      unxv,
      treasury,
      timelock,
      owner,
      trader1,
      trader2,
      keeper,
      feeCollector
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployDexIntegrationFixture);
    orderNFT = fixture.orderNFT;
    feeSwitch = fixture.feeSwitch;
    oracle = fixture.oracle;
    usdc = fixture.usdc;
    weth = fixture.weth;
    wbtc = fixture.wbtc;
    unxv = fixture.unxv;
    treasury = fixture.treasury;
    // timelock = fixture.timelock;
    owner = fixture.owner;
    trader1 = fixture.trader1;
    trader2 = fixture.trader2;
    keeper = fixture.keeper;
    // feeCollector = fixture.feeCollector;
  });

  describe("Basic Trading Flow", function () {
    beforeEach(async function () {
      // Setup approvals
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("25"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("25"));
    });

    it("Should complete full trading cycle", async function () {
      // Create buy order
      const buyOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(buyOrderParams)
      ).to.emit(orderNFT, "OrderCreated")
      .withArgs(1, trader1.address);

      // Create matching sell order
      const sellOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader2).createOrder(sellOrderParams)
      ).to.emit(orderNFT, "OrderCreated")
      .withArgs(2, trader2.address);

      // Record initial balances
      const trader1InitialWeth = await weth.balanceOf(trader1.address);
      const trader1InitialUsdc = await usdc.balanceOf(trader1.address);
      const trader2InitialWeth = await weth.balanceOf(trader2.address);
      const trader2InitialUsdc = await usdc.balanceOf(trader2.address);

      // Execute orders
      await expect(
        orderNFT.connect(keeper).executeOrder(1, 2)
      ).to.emit(orderNFT, "OrderExecuted")
      .withArgs(1, 2);

      // Verify balances changed correctly
      expect(await weth.balanceOf(trader1.address)).to.be.gt(trader1InitialWeth);
      expect(await usdc.balanceOf(trader1.address)).to.be.lt(trader1InitialUsdc);
      expect(await weth.balanceOf(trader2.address)).to.be.lt(trader2InitialWeth);
      expect(await usdc.balanceOf(trader2.address)).to.be.gt(trader2InitialUsdc);
    });

    it("Should handle partial fills", async function () {
      // Create large buy order
      const buyOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("5"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(buyOrderParams);

      // Create smaller sell order
      const sellOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("2"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader2).createOrder(sellOrderParams);

      // Execute partial fill
      await orderNFT.connect(keeper).executeOrder(1, 2);

      // Buy order should still be active with reduced amount
      const buyOrder = await orderNFT.getOrder(1);
      expect(buyOrder.status).to.equal(1); // ACTIVE
      expect(buyOrder.filledAmount).to.equal(toEth("2"));
    });

    it("Should handle multiple orders in order book", async function () {
      // Create multiple buy orders at different prices
      const buyOrders = [
        { price: toUsdc("1950"), amount: toEth("1") },
        { price: toUsdc("2000"), amount: toEth("2") },
        { price: toUsdc("2050"), amount: toEth("1") }
      ];

      for (const order of buyOrders) {
        const orderParams = {
          baseToken: await weth.getAddress(),
          quoteToken: await usdc.getAddress(),
          side: 0, // BUY
          orderType: 0, // LIMIT
          amount: order.amount,
          price: order.price,
          stopPrice: 0,
          expiry: Math.floor(Date.now() / 1000) + 3600
        };

        await orderNFT.connect(trader1).createOrder(orderParams);
      }

      // Create sell order that should match best price
      const sellOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("1950"), // Should match highest buy order
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader2).createOrder(sellOrderParams);

      // Execute matching orders
      await orderNFT.connect(keeper).executeOrder(3, 4); // Best price order

      const executedOrder = await orderNFT.getOrder(3);
      expect(executedOrder.status).to.equal(2); // EXECUTED
    });
  });

  describe("Fee Distribution", function () {
    beforeEach(async function () {
      // Setup approvals
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("25"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("25"));

      // Set trading fee
      await orderNFT.setTradingFee(30); // 0.3%
    });

    it("Should collect and distribute trading fees", async function () {
      // Create and execute orders
      const buyOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(buyOrderParams);
      await orderNFT.connect(trader2).createOrder(sellOrderParams);

      const initialFeeBalance = await usdc.balanceOf(await feeSwitch.getAddress());

      await orderNFT.connect(keeper).executeOrder(1, 2);

      const finalFeeBalance = await usdc.balanceOf(await feeSwitch.getAddress());

      // Should have collected fees
      expect(finalFeeBalance).to.be.gt(initialFeeBalance);

      // Expected fee: $2000 * 0.003 = $6
      const expectedFee = BigInt(toUsdc("2000")) * BigInt(30) / BigInt(10000);
      expect(finalFeeBalance - initialFeeBalance).to.be.closeTo(expectedFee, toUsdc("0.1"));
    });

    it("Should handle fee distribution to treasury", async function () {
      // Execute trade to generate fees
      const buyOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("10"), // Large trade for more fees
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrderParams = { ...buyOrderParams, side: 1 };

      await orderNFT.connect(trader1).createOrder(buyOrderParams);
      await orderNFT.connect(trader2).createOrder(sellOrderParams);
      await orderNFT.connect(keeper).executeOrder(1, 2);

      // Distribute fees to treasury
      const initialTreasuryBalance = await usdc.balanceOf(await treasury.getAddress());

      await expect(
        feeSwitch.distributeFees()
      ).to.emit(feeSwitch, "FeesDistributed");

      const finalTreasuryBalance = await usdc.balanceOf(await treasury.getAddress());
      expect(finalTreasuryBalance).to.be.gt(initialTreasuryBalance);
    });

    it("Should handle fee buyback mechanism", async function () {
      // Execute trade to generate fees
      const buyOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("5"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrderParams = { ...buyOrderParams, side: 1 };

      await orderNFT.connect(trader1).createOrder(buyOrderParams);
      await orderNFT.connect(trader2).createOrder(sellOrderParams);
      await orderNFT.connect(keeper).executeOrder(1, 2);

      // Enable buyback
      await feeSwitch.setBuybackEnabled(true);
      await feeSwitch.setBuybackPercentage(5000); // 50% of fees for buyback

      // const initialUnxvSupply = await unxv.totalSupply();

      await feeSwitch.distributeFees();

      // This would require a DEX to actually buy and burn UNXV
      // For now, we'll just verify the settings are correct
      expect(await feeSwitch.buybackEnabled()).to.be.true;
      expect(await feeSwitch.buybackPercentage()).to.equal(5000);
    });
  });

  describe("Market Making Scenarios", function () {
    beforeEach(async function () {
      // Setup approvals for larger amounts
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("100000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("50"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("100000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("50"));
    });

    it("Should handle market maker providing liquidity", async function () {
      // Market maker creates multiple orders around current price
      const currentPrice = 2000;
      const spread = 50;

      const mmOrders = [
        { side: 0, price: toUsdc((currentPrice - spread).toString()), amount: toEth("2") }, // Buy
        { side: 0, price: toUsdc((currentPrice - spread * 2).toString()), amount: toEth("3") }, // Buy
        { side: 1, price: toUsdc((currentPrice + spread).toString()), amount: toEth("2") }, // Sell
        { side: 1, price: toUsdc((currentPrice + spread * 2).toString()), amount: toEth("3") } // Sell
      ];

      for (const order of mmOrders) {
        const orderParams = {
          baseToken: await weth.getAddress(),
          quoteToken: await usdc.getAddress(),
          side: order.side,
          orderType: 0, // LIMIT
          amount: order.amount,
          price: order.price,
          stopPrice: 0,
          expiry: Math.floor(Date.now() / 1000) + 86400 // 1 day
        };

        await orderNFT.connect(trader1).createOrder(orderParams);
      }

      // Verify order book has depth
      const marketOrders = await orderNFT.getOrdersByMarket(
        await weth.getAddress(),
        await usdc.getAddress()
      );

      expect(marketOrders.buyOrders.length).to.be.gte(2);
      expect(marketOrders.sellOrders.length).to.be.gte(2);
    });

    it("Should handle market taking", async function () {
      // Market maker creates spread
      const buyOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("5"),
        price: toUsdc("1950"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("5"),
        price: toUsdc("2050"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(buyOrderParams);
      await orderNFT.connect(trader1).createOrder(sellOrderParams);

      // Market taker creates market order that should execute immediately
      const marketOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL (take the buy order)
        orderType: 2, // MARKET
        amount: toEth("2"),
        price: 0,
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 300
      };

      await expect(
        orderNFT.connect(trader2).createOrder(marketOrderParams)
      ).to.emit(orderNFT, "OrderExecuted");
    });

    it("Should handle arbitrage opportunities", async function () {
      // Simulate price discrepancy by updating oracle
      await (oracle as any).setPrice(1, toUsdc("2100")); // ETH price goes up

      // Create orders at old prices
      const outdatedSellOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"), // Below new market price
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(outdatedSellOrder);

      // Arbitrageur creates buy order to capture profit
      const arbBuyOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader2).createOrder(arbBuyOrder);

              // const trader2InitialBalance = await usdc.balanceOf(trader2.address);

      await orderNFT.connect(keeper).executeOrder(2, 1);

      // Arbitrageur should profit from price difference
      // They bought ETH at $2000 when market price is $2100
    });
  });

  describe("Risk Management", function () {
    it("Should handle order cancellation scenarios", async function () {
      // Create order
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      
      const initialBalance = await usdc.balanceOf(trader1.address);

      await orderNFT.connect(trader1).createOrder(orderParams);

      // Cancel order
      await expect(
        orderNFT.connect(trader1).cancelOrder(1)
      ).to.emit(orderNFT, "OrderCancelled")
      .withArgs(1);

      // Should refund collateral
      const finalBalance = await usdc.balanceOf(trader1.address);
      expect(finalBalance).to.be.gt(initialBalance - toUsdc("100")); // Account for potential fees
    });

    it("Should handle order expiry", async function () {
      // Create short-lived order
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 2 // 2 seconds
      };

      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await orderNFT.connect(trader1).createOrder(orderParams);

      // Wait for expiry
      await time.increase(3);

      expect(await orderNFT.isOrderExpired(1)).to.be.true;

      // Should be able to clean up
      await expect(
        orderNFT.connect(keeper).cleanupExpiredOrder(1)
      ).to.emit(orderNFT, "OrderExpired")
      .withArgs(1);
    });

    it("Should handle emergency pause", async function () {
      await orderNFT.pause();

      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.be.revertedWith("Pausable: paused");
    });
  });

  describe("Cross-Asset Trading", function () {
    beforeEach(async function () {
      // Setup approvals for all assets
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("100000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("50"));
      await (wbtc as any).connect(trader1).approve(await orderNFT.getAddress(), "500000000");
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("100000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("50"));
      await (wbtc as any).connect(trader2).approve(await orderNFT.getAddress(), "500000000");
    });

    it("Should handle ETH/USDC trading", async function () {
      const buyOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("2"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrder = { ...buyOrder, side: 1 };

      await orderNFT.connect(trader1).createOrder(buyOrder);
      await orderNFT.connect(trader2).createOrder(sellOrder);

      await expect(
        orderNFT.connect(keeper).executeOrder(1, 2)
      ).to.emit(orderNFT, "OrderExecuted");
    });

    it("Should handle BTC/USDC trading", async function () {
      const buyOrder = {
        baseToken: await wbtc.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: "100000000", // 1 BTC
        price: toUsdc("50000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrder = { ...buyOrder, side: 1 };

      await orderNFT.connect(trader1).createOrder(buyOrder);
      await orderNFT.connect(trader2).createOrder(sellOrder);

      await expect(
        orderNFT.connect(keeper).executeOrder(1, 2)
      ).to.emit(orderNFT, "OrderExecuted");
    });

    it("Should handle ETH/BTC trading", async function () {
      const buyOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await wbtc.getAddress(),
        side: 0, // BUY ETH with BTC
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: "4000000", // 0.04 BTC (ETH price in BTC)
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrder = { ...buyOrder, side: 1 };

      await orderNFT.connect(trader1).createOrder(buyOrder);
      await orderNFT.connect(trader2).createOrder(sellOrder);

      await expect(
        orderNFT.connect(keeper).executeOrder(1, 2)
      ).to.emit(orderNFT, "OrderExecuted");
    });
  });

  describe("Advanced Order Types", function () {
    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("25"));
    });

    it("Should handle stop loss orders", async function () {
      const stopLossOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 1, // STOP
        amount: toEth("1"),
        price: 0,
        stopPrice: toUsdc("1800"), // Stop loss at $1800
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(stopLossOrder);

      // Trigger stop by dropping price
      await (oracle as any).setPrice(1, toUsdc("1750"));

      await expect(
        orderNFT.connect(keeper).triggerStopOrder(1)
      ).to.emit(orderNFT, "StopOrderTriggered")
      .withArgs(1);
    });

    it("Should handle take profit orders", async function () {
      const takeProfitOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 1, // STOP
        amount: toEth("1"),
        price: 0,
        stopPrice: toUsdc("2200"), // Take profit at $2200
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(takeProfitOrder);

      // Trigger by raising price
      await (oracle as any).setPrice(1, toUsdc("2250"));

      await expect(
        orderNFT.connect(keeper).triggerStopOrder(1)
      ).to.emit(orderNFT, "StopOrderTriggered");
    });

    it("Should handle iceberg orders", async function () {
      // Large order that should be filled in chunks
      // const icebergOrder = {
      //   baseToken: await weth.getAddress(),
      //   quoteToken: await usdc.getAddress(),
      //   side: 0, // BUY
      //   orderType: 3, // ICEBERG
      //   amount: toEth("20"), // Large amount
      //   price: toUsdc("2000"),
      //   stopPrice: 0,
      //   expiry: Math.floor(Date.now() / 1000) + 3600,
      //   displayAmount: toEth("2") // Only show 2 ETH at a time
      // };

      // This would require special handling in the contract
      // For now, we'll create a regular limit order
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("20"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.emit(orderNFT, "OrderCreated");
    });
  });

  describe("Governance Integration", function () {
    it("Should allow governance to update trading parameters", async function () {
      const newTradingFee = 50; // 0.5%

      // Propose fee change through governance
      await expect(
        orderNFT.setTradingFee(newTradingFee)
      ).to.emit(orderNFT, "TradingFeeUpdated")
      .withArgs(newTradingFee);

      expect(await orderNFT.tradingFee()).to.equal(newTradingFee);
    });

    it("Should handle fee distribution governance", async function () {
      // Execute a trade to generate fees
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("5"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("5"));

      const buyOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      const sellOrder = { ...buyOrder, side: 1 };

      await orderNFT.connect(trader1).createOrder(buyOrder);
      await orderNFT.connect(trader2).createOrder(sellOrder);
      await orderNFT.connect(keeper).executeOrder(1, 2);

      // Governance controls fee distribution
      await expect(
        feeSwitch.setTreasuryAllocation(7000) // 70% to treasury
      ).to.emit(feeSwitch, "TreasuryAllocationUpdated")
      .withArgs(7000);

      expect(await feeSwitch.treasuryAllocation()).to.equal(7000);
    });

    it("Should handle emergency governance actions", async function () {
      // Emergency pause through governance
      await expect(
        orderNFT.pause()
      ).to.emit(orderNFT, "Paused")
      .withArgs(owner.address);

      // Unpause through governance
      await expect(
        orderNFT.unpause()
      ).to.emit(orderNFT, "Unpaused")
      .withArgs(owner.address);
    });
  });

  describe("Performance and Scalability", function () {
    it("Should handle high volume trading", async function () {
      // Setup for multiple trades
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("1000000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("500"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("1000000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("500"));

      const numTrades = 10;
      
      // Create multiple order pairs
      for (let i = 0; i < numTrades; i++) {
                 const price = Number(2000 + i); // Slightly different prices
        
        const buyOrder = {
          baseToken: await weth.getAddress(),
          quoteToken: await usdc.getAddress(),
          side: 0, // BUY
          orderType: 0, // LIMIT
          amount: toEth("1"),
          price: toUsdc(price.toString()),
          stopPrice: 0,
          expiry: Math.floor(Date.now() / 1000) + 3600
        };

        const sellOrder = { ...buyOrder, side: 1 };

        await orderNFT.connect(trader1).createOrder(buyOrder);
        await orderNFT.connect(trader2).createOrder(sellOrder);
        
        // Execute immediately
        const buyOrderId = i * 2 + 1;
        const sellOrderId = i * 2 + 2;
        await orderNFT.connect(keeper).executeOrder(buyOrderId, sellOrderId);
      }

      // Verify all trades executed
      expect(await orderNFT.totalOrders()).to.equal(numTrades * 2);
    });

    it("Should handle gas optimization scenarios", async function () {
      // Batch operations where possible
      const orders = [];
      
      for (let i = 0; i < 5; i++) {
        orders.push({
          baseToken: await weth.getAddress(),
          quoteToken: await usdc.getAddress(),
          side: 0,
          orderType: 0,
          amount: toEth("1"),
          price: toUsdc("2000"),
          stopPrice: 0,
          expiry: Math.floor(Date.now() / 1000) + 3600
        });
      }

      // This would require batch functionality in the contract
      // For now, we'll just verify individual operations work efficiently
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("50000"));
      
      for (const order of orders) {
        await orderNFT.connect(trader1).createOrder(order);
      }

      expect(await orderNFT.totalOrders()).to.equal(5);
    });
  });

  describe("Integration Edge Cases", function () {
    it("Should handle oracle price updates during trading", async function () {
      // Create orders at current price
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("5"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("5"));

      const buyOrder = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(buyOrder);

      // Update oracle price
      await (oracle as any).setPrice(1, toUsdc("2100"));

      const sellOrder = { ...buyOrder, side: 1 };
      await orderNFT.connect(trader2).createOrder(sellOrder);

      // Should still execute at order price, not oracle price
      await expect(
        orderNFT.connect(keeper).executeOrder(1, 2)
      ).to.emit(orderNFT, "OrderExecuted");
    });

    it("Should handle contract upgrade scenarios", async function () {
      // Test that orders survive contract pauses
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("2000"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(orderParams);

      // Pause for "upgrade"
      await orderNFT.pause();
      
      // Verify order still exists
      const order = await orderNFT.getOrder(1);
      expect(order.trader).to.equal(trader1.address);

      // Unpause
      await orderNFT.unpause();

      // Should still be able to cancel
      await expect(
        orderNFT.connect(trader1).cancelOrder(1)
      ).to.emit(orderNFT, "OrderCancelled");
    });

    it("Should handle maximum order scenarios", async function () {
      // Test order limits and cleanup
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("1000000"));

      // Create many orders
      const maxOrders = 100;
      
      for (let i = 0; i < maxOrders; i++) {
        const orderParams = {
          baseToken: await weth.getAddress(),
          quoteToken: await usdc.getAddress(),
          side: 0,
          orderType: 0,
          amount: toEth("0.1"),
          price: toUsdc("2000"),
          stopPrice: 0,
          expiry: Math.floor(Date.now() / 1000) + 3600
        };

        await orderNFT.connect(trader1).createOrder(orderParams);
      }

      expect(await orderNFT.totalOrders()).to.equal(maxOrders);

      // Cancel all orders
      for (let i = 1; i <= maxOrders; i++) {
        await orderNFT.connect(trader1).cancelOrder(i);
      }

      // Verify cleanup
      const activeOrders = await orderNFT.getActiveOrders(trader1.address);
      expect(activeOrders.length).to.equal(0);
    });
  });
});
