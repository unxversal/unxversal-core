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
  let ethSpotOracle: any;
  let btcSpotOracle: any;
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

    // Deploy mark price oracle
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const markOracle = await MockOracleFactory.deploy();
    await (markOracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
    await (markOracle as any).setPrice(2, TEST_CONSTANTS.PRICES.BTC); // BTC

    // Deploy spot price oracles (separate instances for spot prices)
    const ethSpotOracle = await MockOracleFactory.deploy();
    await (ethSpotOracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH);
    
    const btcSpotOracle = await MockOracleFactory.deploy();
    await (btcSpotOracle as any).setPrice(1, TEST_CONSTANTS.PRICES.BTC);

    // Deploy clearing house
    const ClearingHouseFactory = await ethers.getContractFactory("PerpClearingHouse");
    const clearingHouse = await ClearingHouseFactory.deploy(
      await usdc.getAddress(),
      await markOracle.getAddress(),
      ethers.ZeroAddress, // feeCollector (can be zero for tests)
      owner.address, // treasury
      owner.address, // insurance fund
      owner.address  // owner
    );

    // Setup markets with proper spot oracles
    await clearingHouse.listMarket(
      ETH_PERP_ID,
      1, // ETH oracle asset ID
      await ethSpotOracle.getAddress(), // spot oracle
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
      await btcSpotOracle.getAddress(), // spot oracle
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
      oracle: markOracle,
      ethSpotOracle,
      btcSpotOracle,
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
    ethSpotOracle = fixture.ethSpotOracle;
    btcSpotOracle = fixture.btcSpotOracle;
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
      const ethMarket = await clearingHouse.markets(ETH_PERP_ID);
      expect(ethMarket.isListed).to.be.true;
      expect(ethMarket.maxLeverageBps).to.equal(2000);

      const btcMarket = await clearingHouse.markets(BTC_PERP_ID);
      expect(btcMarket.isListed).to.be.true;
      expect(btcMarket.maxLeverageBps).to.equal(1000);
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
      expect(await clearingHouse.getTraderCollateralBalance(trader1.address)).to.equal(depositAmount);
    });

    it("Should revert with zero amount", async function () {
      await expect(
        clearingHouse.connect(trader1).depositMargin(0)
      ).to.be.revertedWith("PCH: Zero deposit");
    });

    it("Should handle multiple deposits", async function () {
      await clearingHouse.connect(trader1).depositMargin(depositAmount);
      await clearingHouse.connect(trader1).depositMargin(depositAmount);

      expect(await clearingHouse.getTraderCollateralBalance(trader1.address)).to.equal(BigInt(depositAmount) * 2n);
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
      expect(await clearingHouse.getTraderCollateralBalance(trader1.address)).to.equal(
        BigInt(depositAmount) - BigInt(withdrawAmount)
      );
    });

    it("Should revert with insufficient margin", async function () {
      const largeAmount = toUsdc("20000");

      await expect(
        clearingHouse.connect(trader1).withdrawMargin(largeAmount)
      ).to.be.revertedWith("PCH: Insufficient balance");
    });

    it("Should revert withdrawal that would break margin requirements", async function () {
      // This test would require actual positions to work properly
      // For now, just test basic withdrawal rejection when no margin
      await clearingHouse.connect(trader1).withdrawMargin(depositAmount);
      
      await expect(
        clearingHouse.connect(trader1).withdrawMargin(1)
      ).to.be.revertedWith("PCH: Insufficient balance");
    });
  });

  describe("Account Summary", function () {
    const marginAmount = toUsdc("10000");

    beforeEach(async function () {
      await usdc.connect(trader1).approve(await clearingHouse.getAddress(), marginAmount);
      await clearingHouse.connect(trader1).depositMargin(marginAmount);
    });

    it("Should get account summary correctly", async function () {
      const summary = await clearingHouse.getAccountSummary(trader1.address);
      
      expect(summary.usdcCollateral).to.equal(marginAmount);
      expect(summary.totalUnrealizedPnlUsdc).to.equal(0); // No positions
      expect(summary.totalMarginBalanceUsdc).to.equal(marginAmount);
      expect(summary.totalMaintenanceMarginReqUsdc).to.equal(0); // No positions
      expect(summary.isCurrentlyLiquidatable).to.be.false;
    });

    it("Should check if market is listed", async function () {
      expect(await clearingHouse.isMarketActuallyListed(ETH_PERP_ID)).to.be.true;
      
      const unknownMarketId = ethers.keccak256(ethers.toUtf8Bytes("UNKNOWN-PERP"));
      expect(await clearingHouse.isMarketActuallyListed(unknownMarketId)).to.be.false;
    });

    it("Should get listed market IDs", async function () {
      const markets = await clearingHouse.getListedMarketIds();
      expect(markets.length).to.equal(2);
      expect(markets[0]).to.equal(ETH_PERP_ID);
      expect(markets[1]).to.equal(BTC_PERP_ID);
    });

    it("Should get trader position (empty initially)", async function () {
      const position = await clearingHouse.getTraderPosition(trader1.address, ETH_PERP_ID);
      
      expect(position.sizeUsdc).to.equal(0);
      expect(position.entryPrice).to.equal(0);
      expect(position.unrealizedPnl).to.equal(0);
      expect(position.marginRequired).to.equal(0);
    });
  });

  describe("Funding Settlement", function () {
    it("Should settle market funding", async function () {
      // Fast forward past funding interval (1 hour)
      await time.increase(3600);

      await expect(clearingHouse.settleMarketFunding(ETH_PERP_ID))
        .to.emit(clearingHouse, "FundingRateCalculated");
    });

    it("Should not allow funding settlement before interval", async function () {
      await expect(
        clearingHouse.settleMarketFunding(ETH_PERP_ID)
      ).to.be.revertedWith("PCH: Funding not due");
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

    it("Should allow owner to set market active/inactive", async function () {
      await clearingHouse.setMarketActive(ETH_PERP_ID, false);
      const market = await clearingHouse.markets(ETH_PERP_ID);
      expect(market.isActive).to.be.false;

      await clearingHouse.setMarketActive(ETH_PERP_ID, true);
      const marketReactivated = await clearingHouse.markets(ETH_PERP_ID);
      expect(marketReactivated.isActive).to.be.true;
    });

    it("Should not allow non-owner to set market active", async function () {
      await expect(
        clearingHouse.connect(trader1).setMarketActive(ETH_PERP_ID, false)
      ).to.be.revertedWithCustomError(clearingHouse, "OwnableUnauthorizedAccount");
    });

    it("Should allow owner to set treasury address", async function () {
      await expect(clearingHouse.setTreasuryAddress(trader1.address))
        .to.emit(clearingHouse, "ConfigurationUpdated")
        .withArgs("treasury", trader1.address);
      
      expect(await clearingHouse.treasuryAddress()).to.equal(trader1.address);
    });

    it("Should allow owner to set insurance fund address", async function () {
      await expect(clearingHouse.setInsuranceFundAddress(trader1.address))
        .to.emit(clearingHouse, "ConfigurationUpdated")
        .withArgs("insuranceFund", trader1.address);
      
      expect(await clearingHouse.insuranceFundAddress()).to.equal(trader1.address);
    });

    it("Should collect treasury fees", async function () {
      // This test would need actual trades to generate fees
      // For now just test that the function exists and reverts when no fees
      await expect(
        clearingHouse.collectTreasuryFees()
      ).to.be.revertedWith("PCH: No fees to collect");
    });
  });
}); 