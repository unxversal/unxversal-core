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
  let unxv: any;
  let oracle: any;
  let dexFeeSwitch: any;
  let permitHelper: any;
  let owner: SignerWithAddress;
  let trader1: SignerWithAddress;
  let trader2: SignerWithAddress;
  let keeper: SignerWithAddress;

  async function deployOrderNFTFixture() {
    const [owner, trader1, trader2, keeper] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, toUsdc("1000000"));
    const weth = await MockERC20Factory.deploy("WETH", "WETH", 18, toEth("10000"));
    const unxv = await MockERC20Factory.deploy("UNXV", "UNXV", 18, toEth("1000000"));

    // Deploy mock oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();

    // Deploy mock DexFeeSwitch
    const DexFeeSwitchFactory = await ethers.getContractFactory("DexFeeSwitch");
    const dexFeeSwitch = await DexFeeSwitchFactory.deploy(
      await usdc.getAddress(),
      await unxv.getAddress(),
      await oracle.getAddress(),
      owner.address
    );

    // Deploy PermitHelper with a mock permit2 address
    const PermitHelperFactory = await ethers.getContractFactory("PermitHelper");
    const permitHelper = await PermitHelperFactory.deploy(owner.address); // Using owner as mock permit2

    // Deploy OrderNFT
    const OrderNFTFactory = await ethers.getContractFactory("OrderNFT");
    const orderNFT = await OrderNFTFactory.deploy(
      "Unxversal Orders",
      "UXO",
      await dexFeeSwitch.getAddress(),
      await permitHelper.getAddress(),
      owner.address
    );

    // Setup initial state
    await usdc.mint(trader1.address, toUsdc("100000"));
    await usdc.mint(trader2.address, toUsdc("100000"));
    await weth.mint(trader1.address, toEth("100"));
    await weth.mint(trader2.address, toEth("100"));

    return {
      orderNFT,
      usdc,
      weth,
      unxv,
      oracle,
      dexFeeSwitch,
      permitHelper,
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
    unxv = fixture.unxv;
    oracle = fixture.oracle;
    dexFeeSwitch = fixture.dexFeeSwitch;
    permitHelper = fixture.permitHelper;
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

    it("Should set correct dex fee switch", async function () {
      expect(await orderNFT.dexFeeSwitch()).to.equal(await dexFeeSwitch.getAddress());
    });

    it("Should set correct permit helper", async function () {
      expect(await orderNFT.permitHelper()).to.equal(await permitHelper.getAddress());
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
      const currentTime = Math.floor(Date.now() / 1000);
      
      await expect(
        orderNFT.connect(trader1).createOrder(
          await usdc.getAddress(), // sellToken (selling USDC to buy WETH)
          await weth.getAddress(), // buyToken
          toEth("1900"), // price (1900 USDC per WETH, scaled by 1e18)
          toUsdc("1900"), // amount (selling 1900 USDC)
          currentTime + 3600, // expiry
          6, // sellDecimals (USDC has 6 decimals)
          30 // feeBps (0.3%)
        )
      ).to.emit(orderNFT, "OrderCreated");

      const order = await orderNFT.getOrder(1);
      expect(order.maker).to.equal(trader1.address);
      expect(order.sellToken).to.equal(await usdc.getAddress());
      expect(order.buyToken).to.equal(await weth.getAddress());
      expect(order.amountRemaining).to.equal(toUsdc("1900"));
    });

    it("Should create limit sell order", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      
      await expect(
        orderNFT.connect(trader1).createOrder(
          await weth.getAddress(), // sellToken (selling WETH)
          await usdc.getAddress(), // buyToken (buying USDC)
          toUsdc("2100"), // price (2100 USDC per WETH, scaled by 1e18)
          toEth("1"), // amount (selling 1 WETH)
          currentTime + 3600, // expiry
          18, // sellDecimals (WETH has 18 decimals)
          30 // feeBps (0.3%)
        )
      ).to.emit(orderNFT, "OrderCreated")
      .withArgs(1, trader1.address, await weth.getAddress(), await usdc.getAddress(), toUsdc("2100"), toEth("1"), currentTime + 3600, 18, 30);

      expect(await orderNFT.ownerOf(1)).to.equal(trader1.address);
    });

    it("Should create TWAP order", async function () {
      await expect(
        orderNFT.connect(trader1).createTWAPOrder(
          await weth.getAddress(), // sellToken
          await usdc.getAddress(), // buyToken
          toEth("10"), // totalAmount
          toEth("1"), // amountPerPeriod
          3600, // period (1 hour)
          toUsdc("1800") // minPrice
        )
      ).to.emit(orderNFT, "TWAPOrderCreated");

      const twapOrder = await orderNFT.getTWAPOrder(1);
      expect(twapOrder.totalAmount).to.equal(toEth("10"));
      expect(twapOrder.amountPerPeriod).to.equal(toEth("1"));
      expect(twapOrder.period).to.equal(3600);
    });

    it("Should lock collateral for orders", async function () {
      const initialBalance = await usdc.balanceOf(trader1.address);
      const currentTime = Math.floor(Date.now() / 1000);
      
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(), // sellToken
        await weth.getAddress(), // buyToken
        toEth("1900"), // price
        toUsdc("1900"), // amount
        currentTime + 3600, // expiry
        6, // sellDecimals
        30 // feeBps
      );

      // Should lock USDC for the order
      expect(await usdc.balanceOf(trader1.address)).to.be.lt(initialBalance);
    });

    it("Should validate order parameters", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      
      await expect(
        orderNFT.connect(trader1).createOrder(
          await weth.getAddress(),
          await usdc.getAddress(),
          toUsdc("1900"),
          0, // Invalid amount
          currentTime + 3600,
          18,
          30
        )
      ).to.be.revertedWith("OrderNFT: zero amount");
    });

    it("Should not allow expired orders", async function () {
      const pastTime = Math.floor(Date.now() / 1000) - 3600;
      
      await expect(
        orderNFT.connect(trader1).createOrder(
          await weth.getAddress(),
          await usdc.getAddress(),
          toUsdc("1900"),
          toEth("1"),
          pastTime, // Past expiry
          18,
          30
        )
      ).to.be.revertedWith("OrderNFT: expiry past");
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

      const currentTime = Math.floor(Date.now() / 1000);

      // Create buy order (trader1 selling USDC to buy WETH)
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(), // sellToken
        await weth.getAddress(), // buyToken
        toEth("2000"), // price
        toUsdc("2000"), // amount
        currentTime + 3600, // expiry
        6, // sellDecimals
        30 // feeBps
      );
      buyOrderId = 1;

      // Create sell order (trader2 selling WETH to buy USDC)
      await orderNFT.connect(trader2).createOrder(
        await weth.getAddress(), // sellToken
        await usdc.getAddress(), // buyToken
        toUsdc("2000"), // price
        toEth("1"), // amount
        currentTime + 3600, // expiry
        18, // sellDecimals
        30 // feeBps
      );
      sellOrderId = 2;
    });

    it("Should execute matching orders", async function () {
      // The sell order (sellOrderId=2) is selling WETH for USDC
      // So the keeper needs USDC to buy the WETH
      await usdc.mint(keeper.address, toUsdc("10000"));
      await usdc.connect(keeper).approve(await orderNFT.getAddress(), toUsdc("10000"));

      const fillParams = {
        minAmountOut: 0,
        maxGasPrice: ethers.parseUnits("100", "gwei"),
        deadline: Math.floor(Date.now() / 1000) + 3600,
        minFillAmount: 0,
        relayer: ethers.ZeroAddress
      };

      await expect(
        orderNFT.connect(keeper).fillOrders(
          [sellOrderId], // tokenIds
          [toEth("1")], // fillAmounts
          fillParams
        )
      ).to.emit(orderNFT, "OrderFilled");
    });
  });

  describe("Order Cancellation", function () {
    let orderId: number;

    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));

      const currentTime = Math.floor(Date.now() / 1000);
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(),
        await weth.getAddress(),
        toEth("1900"),
        toUsdc("1900"),
        currentTime + 3600,
        6,
        30
      );
      orderId = 1;
    });

    it("Should allow order creator to cancel", async function () {
      await expect(
        orderNFT.connect(trader1).cancelOrders([orderId])
      ).to.emit(orderNFT, "OrderCancelled")
      .withArgs(orderId, trader1.address, toUsdc("1900"));
    });

    it("Should refund collateral on cancellation", async function () {
      const initialBalance = await usdc.balanceOf(trader1.address);
      
      await orderNFT.connect(trader1).cancelOrders([orderId]);
      
      const finalBalance = await usdc.balanceOf(trader1.address);
      expect(finalBalance).to.be.gt(initialBalance);
    });

    it("Should not allow non-owner to cancel", async function () {
      await expect(
        orderNFT.connect(trader2).cancelOrders([orderId])
      ).to.be.revertedWith("OrderNFT: not owner");
    });
  });

  describe("NFT Functionality", function () {
    let orderId: number;

    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));

      const currentTime = Math.floor(Date.now() / 1000);
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(),
        await weth.getAddress(),
        toEth("1900"),
        toUsdc("1900"),
        currentTime + 3600,
        6,
        30
      );
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
      
      // Check that NFT ownership changed
      expect(await orderNFT.ownerOf(orderId)).to.equal(trader2.address);
      
      // The order maker remains the same, but NFT owner changed
      const order = await orderNFT.getOrder(orderId);
      expect(order.maker).to.equal(trader1.address); // Original maker
      
      // New NFT owner cannot cancel because they're not the original maker
      // The contract requires both NFT ownership AND being the original maker
      await expect(
        orderNFT.connect(trader2).cancelOrders([orderId])
      ).to.not.emit(orderNFT, "OrderCancelled");
      
      // Original maker can still cancel even though they don't own the NFT anymore
      // This will fail because the contract checks ownerOf(tokenId) == msg.sender first
      await expect(
        orderNFT.connect(trader1).cancelOrders([orderId])
      ).to.be.revertedWith("OrderNFT: not owner");
    });

    it("Should provide token URI", async function () {
      const tokenURI = await orderNFT.tokenURI(orderId);
      expect(tokenURI).to.be.a('string');
      expect(tokenURI.length).to.be.gt(0);
    });

    it("Should not transfer non-existent token", async function () {
      await expect(
        orderNFT.connect(trader1).transferFrom(trader1.address, trader2.address, 999)
      ).to.be.revertedWithCustomError(orderNFT, "ERC721NonexistentToken");
    });
  });

  describe("Order Management", function () {
    beforeEach(async function () {
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("50000"));
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("50"));
    });

    it("Should track order state", async function () {
      const currentTime = Math.floor(Date.now() / 1000);
      
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(),
        await weth.getAddress(),
        toEth("1900"),
        toUsdc("1900"),
        currentTime + 3600,
        6,
        30
      );

      const order = await orderNFT.getOrder(1);
      expect(order.maker).to.equal(trader1.address);
      expect(order.sellToken).to.equal(await usdc.getAddress());
      expect(order.buyToken).to.equal(await weth.getAddress());
      expect(order.amountRemaining).to.equal(toUsdc("1900"));
    });

    it("Should handle order expiry", async function () {
      // Get current block timestamp
      const currentBlock = await ethers.provider.getBlock('latest');
      const currentTime = currentBlock!.timestamp;
      const shortExpiry = currentTime + 2; // 2 seconds from current block
      
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(),
        await weth.getAddress(),
        toEth("1900"),
        toUsdc("1900"),
        shortExpiry,
        6,
        30
      );

      // Wait for expiry
      await time.increase(3);

      const fillParams = {
        minAmountOut: 0,
        maxGasPrice: ethers.parseUnits("100", "gwei"),
        deadline: currentTime + 3600,
        minFillAmount: 0,
        relayer: ethers.ZeroAddress
      };

      // Should not be able to fill expired order
      await expect(
        orderNFT.connect(keeper).fillOrders([1], [toUsdc("100")], fillParams)
      ).to.be.revertedWith("OrderNFT: expired");
    });
  });

  describe("Admin Functions", function () {
    it("Should have correct owner", async function () {
      expect(await orderNFT.owner()).to.equal(owner.address);
    });

    it("Should allow owner to transfer ownership", async function () {
      await orderNFT.connect(owner).transferOwnership(trader1.address);
      expect(await orderNFT.owner()).to.equal(trader1.address);
    });

    it("Should not allow non-owner to transfer ownership", async function () {
      await expect(
        orderNFT.connect(trader1).transferOwnership(trader2.address)
      ).to.be.revertedWithCustomError(orderNFT, "OwnableUnauthorizedAccount");
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle complex trading workflow", async function () {
      // Setup approvals
      await (usdc as any).connect(trader1).approve(await orderNFT.getAddress(), toUsdc("10000"));
      await (weth as any).connect(trader2).approve(await orderNFT.getAddress(), toEth("10"));
      await (usdc as any).connect(trader2).approve(await orderNFT.getAddress(), toUsdc("10000"));

      // Mint tokens for keeper and approve
      await usdc.mint(keeper.address, toUsdc("10000"));
      await usdc.connect(keeper).approve(await orderNFT.getAddress(), toUsdc("10000"));

      const currentTime = Math.floor(Date.now() / 1000);

      // Create multiple orders
      await orderNFT.connect(trader1).createOrder(
        await usdc.getAddress(),
        await weth.getAddress(),
        toEth("1900"),
        toUsdc("1900"),
        currentTime + 3600,
        6,
        30
      );

      await orderNFT.connect(trader2).createOrder(
        await weth.getAddress(),
        await usdc.getAddress(),
        toUsdc("2000"),
        toEth("1"),
        currentTime + 3600,
        18,
        30
      );

      // Execute orders
      const fillParams = {
        minAmountOut: 0,
        maxGasPrice: ethers.parseUnits("100", "gwei"),
        deadline: currentTime + 3600,
        minFillAmount: 0,
        relayer: ethers.ZeroAddress
      };

      await expect(
        orderNFT.connect(keeper).fillOrders([2], [toEth("1")], fillParams)
      ).to.emit(orderNFT, "OrderFilled");
    });

    it("Should handle TWAP order execution", async function () {
      await (weth as any).connect(trader1).approve(await orderNFT.getAddress(), toEth("10"));

      await orderNFT.connect(trader1).createTWAPOrder(
        await weth.getAddress(),
        await usdc.getAddress(),
        toEth("10"),
        toEth("1"),
        3600, // 1 hour period
        toUsdc("1800")
      );

      // Fast forward time
      await time.increase(3601);

      // Execute TWAP order
      await expect(
        orderNFT.connect(keeper).executeTWAPOrder(1)
      ).to.emit(orderNFT, "TWAPOrderExecuted");
    });
  });
});
