/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc, toEth } from "../../shared/constants";

describe("OrderNFT", function () {
  let orderNFT: any;
  let usdc: any;
  let weth: any;
  let oracle: any;
  let feeSwitch: any;
  let owner: SignerWithAddress;
  let trader1: SignerWithAddress;
  let trader2: SignerWithAddress;
  let keeper: SignerWithAddress;

  async function deployOrderNFTFixture() {
    const [owner, trader1, trader2, keeper] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);
    const weth = await MockERC20Factory.deploy("WETH", "WETH", 18, 0);

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();
    await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);
    await (oracle as any).setPrice(3, TEST_CONSTANTS.PRICES.USDC);

    // Deploy mock fee switch
    const feeSwitch = await MockERC20Factory.deploy("FeeSwitch", "FS", 18, 0);

    // Deploy OrderNFT
    const OrderNFTFactory = await ethers.getContractFactory("OrderNFT");
    const orderNFT = await OrderNFTFactory.deploy(
      "Unxversal Orders",
      "UXO",
      await oracle.getAddress(),
      await feeSwitch.getAddress(),
      owner.address
    );

    // Setup initial state
    await (usdc as any).mint(trader1.address, toUsdc("100000"));
    await (usdc as any).mint(trader2.address, toUsdc("100000"));
    await (weth as any).mint(trader1.address, toEth("100"));
    await (weth as any).mint(trader2.address, toEth("100"));

    return {
      orderNFT,
      usdc,
      weth,
      oracle,
      feeSwitch,
      owner,
      trader1,
      trader2,
      keeper
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployOrderNFTFixture);
    orderNFT = fixture.orderNFT;
    usdc = fixture.usdc;
    weth = fixture.weth;
    oracle = fixture.oracle;
    feeSwitch = fixture.feeSwitch;
    owner = fixture.owner;
    trader1 = fixture.trader1;
    trader2 = fixture.trader2;
    keeper = fixture.keeper;
  });

  describe("Initialization", function () {
    it("Should set correct name and symbol", async function () {
      expect(await orderNFT.name()).to.equal("Unxversal Orders");
      expect(await orderNFT.symbol()).to.equal("UXO");
    });

    it("Should set correct oracle", async function () {
      expect(await orderNFT.oracle()).to.equal(await oracle.getAddress());
    });

    it("Should set correct fee switch", async function () {
      expect(await orderNFT.feeSwitch()).to.equal(await feeSwitch.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await orderNFT.owner()).to.equal(owner.address);
    });
  });

  describe("Order Creation", function () {
    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("10"));
    });

    it("Should create limit buy order", async function () {
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("1900"), // Below market
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.emit(orderNFT, "OrderCreated");

      const order = await orderNFT.getOrder(1);
      expect(order.trader).to.equal(trader1.address);
      expect(order.baseToken).to.equal(await weth.getAddress());
      expect(order.amount).to.equal(toEth("1"));
    });

    it("Should create limit sell order", async function () {
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2100"), // Above market
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.emit(orderNFT, "OrderCreated")
      .withArgs(1, trader1.address);

      expect(await orderNFT.ownerOf(1)).to.equal(trader1.address);
    });

    it("Should create stop loss order", async function () {
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 1, // STOP
        amount: toEth("1"),
        price: 0,
        stopPrice: toUsdc("1800"), // Stop loss
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.emit(orderNFT, "OrderCreated");

      const order = await orderNFT.getOrder(1);
      expect(order.orderType).to.equal(1); // STOP
      expect(order.stopPrice).to.equal(toUsdc("1800"));
    });

    it("Should create market order", async function () {
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 2, // MARKET
        amount: toEth("1"),
        price: 0,
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 300 // 5 minutes
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.emit(orderNFT, "OrderCreated");

      const order = await orderNFT.getOrder(1);
      expect(order.orderType).to.equal(2); // MARKET
    });

    it("Should lock collateral for orders", async function () {
      const initialBalance = await usdc.balanceOf(trader1.address);
      
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(orderParams);

             // Should lock USDC for buy order
       // const expectedLocked = BigInt(toEth("1")) * BigInt(toUsdc("1900")) / BigInt(1e18);
       expect(await usdc.balanceOf(trader1.address)).to.be.lt(initialBalance);
    });

    it("Should validate order parameters", async function () {
      const invalidOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: 0, // Invalid amount
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(invalidOrderParams)
      ).to.be.revertedWith("Invalid amount");
    });

    it("Should not allow expired orders", async function () {
      const expiredOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) - 3600 // Past expiry
      };

      await expect(
        orderNFT.connect(trader1).createOrder(expiredOrderParams)
      ).to.be.revertedWith("Order expired");
    });
  });

  describe("Order Execution", function () {
    let buyOrderId: number;
    let sellOrderId: number;

    beforeEach(async function () {
      // Setup approvals
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("10"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("10"));

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

      await orderNFT.connect(trader1).createOrder(buyOrderParams);
      buyOrderId = 1;

      // Create sell order
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

      await orderNFT.connect(trader2).createOrder(sellOrderParams);
      sellOrderId = 2;
    });

    it("Should execute matching orders", async function () {
      await expect(
        orderNFT.connect(keeper).executeOrder(buyOrderId, sellOrderId)
      ).to.emit(orderNFT, "OrderExecuted")
      .withArgs(buyOrderId, sellOrderId);

      const buyOrder = await orderNFT.getOrder(buyOrderId);
      const sellOrder = await orderNFT.getOrder(sellOrderId);
      
      expect(buyOrder.status).to.equal(2); // EXECUTED
      expect(sellOrder.status).to.equal(2); // EXECUTED
    });

    it("Should transfer assets correctly", async function () {
      const trader1InitialWETH = await weth.balanceOf(trader1.address);
      const trader2InitialUSDC = await usdc.balanceOf(trader2.address);

      await orderNFT.connect(keeper).executeOrder(buyOrderId, sellOrderId);

      // Trader1 should receive WETH
      expect(await weth.balanceOf(trader1.address)).to.be.gt(trader1InitialWETH);
      
      // Trader2 should receive USDC
      expect(await usdc.balanceOf(trader2.address)).to.be.gt(trader2InitialUSDC);
    });

    it("Should charge trading fees", async function () {
      const feeRate = 30; // 0.3%
      await orderNFT.setTradingFee(feeRate);

      const initialFeeBalance = await usdc.balanceOf(await feeSwitch.getAddress());

      await orderNFT.connect(keeper).executeOrder(buyOrderId, sellOrderId);

      const finalFeeBalance = await usdc.balanceOf(await feeSwitch.getAddress());
      expect(finalFeeBalance).to.be.gt(initialFeeBalance);
    });

    it("Should not execute non-matching orders", async function () {
      // Create non-matching order (different price)
      const nonMatchingOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("2500"), // Much higher price
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader2).createOrder(nonMatchingOrderParams);
      const nonMatchingOrderId = 3;

      await expect(
        orderNFT.connect(keeper).executeOrder(buyOrderId, nonMatchingOrderId)
      ).to.be.revertedWith("Orders don't match");
    });

    it("Should execute market orders immediately", async function () {
      const marketOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 2, // MARKET
        amount: toEth("1"),
        price: 0,
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 300
      };

      await expect(
        orderNFT.connect(trader1).createOrder(marketOrderParams)
      ).to.emit(orderNFT, "OrderExecuted");
    });
  });

  describe("Order Cancellation", function () {
    let orderId: number;

    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));

      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(orderParams);
      orderId = 1;
    });

    it("Should allow order creator to cancel", async function () {
      await expect(
        orderNFT.connect(trader1).cancelOrder(orderId)
      ).to.emit(orderNFT, "OrderCancelled")
      .withArgs(orderId);

      const order = await orderNFT.getOrder(orderId);
      expect(order.status).to.equal(3); // CANCELLED
    });

    it("Should refund collateral on cancellation", async function () {
      const initialBalance = await usdc.balanceOf(trader1.address);
      
      await orderNFT.connect(trader1).cancelOrder(orderId);
      
      const finalBalance = await usdc.balanceOf(trader1.address);
      expect(finalBalance).to.be.gt(initialBalance);
    });

    it("Should not allow non-owner to cancel", async function () {
      await expect(
        orderNFT.connect(trader2).cancelOrder(orderId)
      ).to.be.revertedWith("Not order owner");
    });

    it("Should not cancel already executed orders", async function () {
      // First create matching sell order and execute
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("10"));
      
      const sellOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader2).createOrder(sellOrderParams);
      await orderNFT.connect(keeper).executeOrder(orderId, 2);

      await expect(
        orderNFT.connect(trader1).cancelOrder(orderId)
      ).to.be.revertedWith("Order not active");
    });
  });

  describe("NFT Functionality", function () {
    let orderId: number;

    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));

      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0, // BUY
        orderType: 0, // LIMIT
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(orderParams);
      orderId = 1;
    });

    it("Should mint NFT to order creator", async function () {
      expect(await orderNFT.ownerOf(orderId)).to.equal(trader1.address);
      expect(await orderNFT.balanceOf(trader1.address)).to.equal(1);
    });

    it("Should allow NFT transfer", async function () {
      await orderNFT.connect(trader1).transferFrom(trader1.address, trader2.address, orderId);
      
      expect(await orderNFT.ownerOf(orderId)).to.equal(trader2.address);
      expect(await orderNFT.balanceOf(trader2.address)).to.equal(1);
      expect(await orderNFT.balanceOf(trader1.address)).to.equal(0);
    });

    it("Should update order ownership after NFT transfer", async function () {
      await orderNFT.connect(trader1).transferFrom(trader1.address, trader2.address, orderId);
      
      // New owner should be able to cancel
      await expect(
        orderNFT.connect(trader2).cancelOrder(orderId)
      ).to.emit(orderNFT, "OrderCancelled");
    });

    it("Should provide token URI", async function () {
      const tokenURI = await orderNFT.tokenURI(orderId);
      expect(tokenURI).to.be.a('string');
      expect(tokenURI.length).to.be.gt(0);
    });

    it("Should not transfer non-existent token", async function () {
      await expect(
        orderNFT.connect(trader1).transferFrom(trader1.address, trader2.address, 999)
      ).to.be.revertedWith("ERC721: invalid token ID");
    });
  });

  describe("Order Management", function () {
    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("50"));
    });

    it("Should track total orders", async function () {
      expect(await orderNFT.totalOrders()).to.equal(0);

      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(orderParams);
      await orderNFT.connect(trader1).createOrder(orderParams);
      await orderNFT.connect(trader1).createOrder(orderParams);

      expect(await orderNFT.totalOrders()).to.equal(3);
    });

    it("Should get active orders for trader", async function () {
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(orderParams);
      await orderNFT.connect(trader1).createOrder(orderParams);

      const activeOrders = await orderNFT.getActiveOrders(trader1.address);
      expect(activeOrders.length).to.equal(2);
    });

    it("Should handle order expiry", async function () {
      const shortExpiryOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 1 // 1 second
      };

      await orderNFT.connect(trader1).createOrder(shortExpiryOrderParams);
      
      // Fast forward time
      await time.increase(2);
      
      expect(await orderNFT.isOrderExpired(1)).to.be.true;
      
      // Should be able to clean up expired order
      await expect(
        orderNFT.connect(keeper).cleanupExpiredOrder(1)
      ).to.emit(orderNFT, "OrderExpired");
    });

    it("Should get orders by market", async function () {
      const ethUsdcOrders = await orderNFT.getOrdersByMarket(
        await weth.getAddress(),
        await usdc.getAddress()
      );
      
      expect(ethUsdcOrders.buyOrders).to.be.an('array');
      expect(ethUsdcOrders.sellOrders).to.be.an('array');
    });
  });

  describe("Admin Functions", function () {
    it("Should set trading fee", async function () {
      const newFee = 50; // 0.5%
      
      await expect(
        orderNFT.setTradingFee(newFee)
      ).to.emit(orderNFT, "TradingFeeUpdated")
      .withArgs(newFee);
      
      expect(await orderNFT.tradingFee()).to.equal(newFee);
    });

    it("Should set maximum order duration", async function () {
      const maxDuration = 7 * 24 * 3600; // 7 days
      
      await orderNFT.setMaxOrderDuration(maxDuration);
      expect(await orderNFT.maxOrderDuration()).to.equal(maxDuration);
    });

    it("Should pause contract", async function () {
      await orderNFT.pause();
      expect(await orderNFT.paused()).to.be.true;
    });

    it("Should not allow order creation when paused", async function () {
      await orderNFT.pause();
      
      const orderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 0,
        orderType: 0,
        amount: toEth("1"),
        price: toUsdc("1900"),
        stopPrice: 0,
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await expect(
        orderNFT.connect(trader1).createOrder(orderParams)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should only allow owner to update parameters", async function () {
      await expect(
        orderNFT.connect(trader1).setTradingFee(100)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle complex trading workflow", async function () {
      // Setup approvals
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("10"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("10"));

      // Create multiple orders
      const orders = [
        { side: 0, price: toUsdc("1900"), trader: trader1 }, // Buy at 1900
        { side: 0, price: toUsdc("1950"), trader: trader1 }, // Buy at 1950
        { side: 1, price: toUsdc("2050"), trader: trader2 }, // Sell at 2050
        { side: 1, price: toUsdc("2000"), trader: trader2 }  // Sell at 2000
      ];

      for (const order of orders) {
        const orderParams = {
          baseToken: await weth.getAddress(),
          quoteToken: await usdc.getAddress(),
          side: order.side,
          orderType: 0,
          amount: toEth("1"),
          price: order.price,
          stopPrice: 0,
          expiry: Math.floor(Date.now() / 1000) + 3600
        };

        await orderNFT.connect(order.trader).createOrder(orderParams);
      }

      // Execute matching orders (buy at 1950, sell at 2000)
      await orderNFT.connect(keeper).executeOrder(2, 4);

      // Verify order book state
      const activeOrders = await orderNFT.getTotalActiveOrders();
      expect(activeOrders).to.equal(2); // 2 orders remain unmatched
    });

    it("Should handle stop loss triggering", async function () {
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("10"));

      // Create stop loss order
      const stopOrderParams = {
        baseToken: await weth.getAddress(),
        quoteToken: await usdc.getAddress(),
        side: 1, // SELL
        orderType: 1, // STOP
        amount: toEth("1"),
        price: 0,
        stopPrice: toUsdc("1800"), // Stop at $1800
        expiry: Math.floor(Date.now() / 1000) + 3600
      };

      await orderNFT.connect(trader1).createOrder(stopOrderParams);

      // Trigger stop by changing price
      await (oracle as any).setPrice(1, toUsdc("1750")); // Price drops to $1750

      // Keeper should be able to trigger stop order
      await expect(
        orderNFT.connect(keeper).triggerStopOrder(1)
      ).to.emit(orderNFT, "StopOrderTriggered");
    });
  });
});
