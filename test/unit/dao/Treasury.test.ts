/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { toUsdc } from "../../shared/constants";

describe("Treasury", function () {
  let treasury: any;
  let usdc: any;
  let weth: any;
  let owner: SignerWithAddress;
  let governance: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  async function deployTreasuryFixture() {
    const [owner, governance, user1, user2] = await ethers.getSigners();

    // Deploy mock tokens
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);
    const weth = await MockERC20Factory.deploy("WETH", "WETH", 18, 0);

    // Deploy Treasury
    const TreasuryFactory = await ethers.getContractFactory("Treasury");
    const treasury = await TreasuryFactory.deploy();

    // Setup initial state
    await (usdc as any).mint(owner.address, toUsdc("1000000"));
    await (weth as any).mint(owner.address, ethers.parseEther("1000"));
    
    // Transfer ownership to the deployer for tests
    await treasury.transferOwnership(owner.address);

    return {
      treasury,
      usdc,
      weth,
      owner,
      governance,
      user1,
      user2
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployTreasuryFixture);
    treasury = fixture.treasury;
    usdc = fixture.usdc;
    weth = fixture.weth;
    owner = fixture.owner;
    governance = fixture.governance;
    user1 = fixture.user1;
    user2 = fixture.user2;
  });

  describe("Initialization", function () {
    it("Should set the correct owner", async function () {
      expect(await treasury.owner()).to.equal(owner.address);
    });

    it("Should have zero balance initially", async function () {
      expect(await treasury.getAccruedFees(await usdc.getAddress())).to.equal(0);
    });
  });

  describe("Token Management", function () {
    it("Should whitelist tokens", async function () {
      await treasury.setTokenWhitelist(await weth.getAddress(), true);
      expect(await treasury.whitelistedTokens(await weth.getAddress())).to.be.true;
    });

    it("Should remove tokens from whitelist", async function () {
      await treasury.setTokenWhitelist(await weth.getAddress(), true);
      await treasury.setTokenWhitelist(await weth.getAddress(), false);
      expect(await treasury.whitelistedTokens(await weth.getAddress())).to.be.false;
    });

    it("Should only allow owner to whitelist tokens", async function () {
      await expect(
        treasury.connect(user1).setTokenWhitelist(await weth.getAddress(), true)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should emit WhitelistUpdated event", async function () {
      await expect(treasury.setTokenWhitelist(await weth.getAddress(), true))
        .to.emit(treasury, "WhitelistUpdated")
        .withArgs(await weth.getAddress(), true);
    });
  });

  describe("Fee Collection", function () {
    beforeEach(async function () {
      await treasury.setTokenWhitelist(await usdc.getAddress(), true);
      await (usdc as any).approve(await treasury.getAddress(), toUsdc("1000"));
    });

    it("Should receive USDC fees", async function () {
      const amount = toUsdc("1000");
      
      // The depositFee function requires the caller to transfer tokens.
      // We will use the owner account which has tokens.
      await (usdc as any).connect(owner).approve(await treasury.getAddress(), amount);
      await treasury.connect(owner).depositFee(await usdc.getAddress(), amount);
      
      expect(await treasury.getAccruedFees(await usdc.getAddress())).to.equal(amount);
    });

    it("Should track multiple token balances", async function () {
      const usdcAmount = toUsdc("1000");
      const wethAmount = ethers.parseEther("1");

      await treasury.setTokenWhitelist(await weth.getAddress(), true);

      await (usdc as any).connect(owner).approve(await treasury.getAddress(), usdcAmount);
      await treasury.connect(owner).depositFee(await usdc.getAddress(), usdcAmount);

      await (weth as any).connect(owner).approve(await treasury.getAddress(), wethAmount);
      await treasury.connect(owner).depositFee(await weth.getAddress(), wethAmount);
      
      expect(await treasury.getAccruedFees(await usdc.getAddress())).to.equal(usdcAmount);
      expect(await treasury.getAccruedFees(await weth.getAddress())).to.equal(wethAmount);
    });
  });

  describe("Withdrawals", function () {
    beforeEach(async function () {
        await treasury.setTokenWhitelist(await usdc.getAddress(), true);
        const usdcAmount = toUsdc("10000");
        await (usdc as any).connect(owner).approve(await treasury.getAddress(), usdcAmount);
        await treasury.connect(owner).depositFee(await usdc.getAddress(), usdcAmount);

        const ethAmount = ethers.parseEther("1");
        await owner.sendTransaction({
          to: await treasury.getAddress(),
          value: ethAmount
        });
    });

    it("Should allow owner to withdraw tokens", async function () {
      const amount = toUsdc("1000");
      const initialBalance = await usdc.balanceOf(owner.address);
      
      await treasury.sweepToken(await usdc.getAddress(), owner.address, amount);
      
      const finalBalance = await usdc.balanceOf(owner.address);
      expect(finalBalance).to.equal(initialBalance + amount);
    });

    it("Should allow owner to withdraw ETH", async function () {
      const withdrawAmount = ethers.parseEther("0.5");
      const initialBalance = await ethers.provider.getBalance(user1.address);
      
      await treasury.sweepNative(user1.address, withdrawAmount);
      
      expect(await ethers.provider.getBalance(user1.address)).to.equal(
        initialBalance + withdrawAmount
      );
    });

    it("Should only allow owner to withdraw", async function () {
      await expect(
        treasury.connect(user1).sweepToken(await usdc.getAddress(), user1.address, toUsdc("100"))
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Should not allow withdrawing more than balance", async function () {
      await expect(
        treasury.sweepToken(await usdc.getAddress(), owner.address, toUsdc("20000"))
      ).to.be.revertedWith("Insufficient balance");
    });

    it("Should emit AssetSwept event", async function () {
      const amount = toUsdc("1000");
      await expect(treasury.sweepToken(await usdc.getAddress(), owner.address, amount))
        .to.emit(treasury, "AssetSwept")
        .withArgs(await usdc.getAddress(), owner.address, amount);
    });
  });

  describe("Governance Integration", function () {
    it("Should transfer ownership to governance", async function () {
      await treasury.transferOwnership(governance.address);
      expect(await treasury.owner()).to.equal(governance.address);
    });

    it("Should allow governance to manage treasury", async function () {
      await treasury.transferOwnership(governance.address);
      
      await treasury.connect(governance).setTokenWhitelist(await weth.getAddress(), true);
      expect(await treasury.whitelistedTokens(await weth.getAddress())).to.be.true;
    });
  });

  describe("Emergency Functions", function () {
    it("Should not have pause/unpause functions", async function () {
      expect(treasury.pause).to.be.undefined;
      expect(treasury.unpause).to.be.undefined;
    });
  });

  describe("Fee Distribution Scenarios", function () {
    it("Should handle large volume fee collection", async function () {
        await treasury.setTokenWhitelist(await usdc.getAddress(), true);
        
        const dailyFees = toUsdc("10000");
        for (let i = 0; i < 7; i++) {
          await (usdc as any).connect(owner).approve(await treasury.getAddress(), dailyFees);
          await treasury.connect(owner).depositFee(await usdc.getAddress(), dailyFees);
        }
        
        expect(await treasury.getAccruedFees(await usdc.getAddress())).to.equal(toUsdc("70000"));
    });

    it("Should support DAO revenue distribution", async function () {
        const totalDeposit = toUsdc("100000");
        await treasury.setTokenWhitelist(await usdc.getAddress(), true);
        await (usdc as any).connect(owner).approve(await treasury.getAddress(), totalDeposit);
        await treasury.connect(owner).depositFee(await usdc.getAddress(), totalDeposit);
        
        const stakingReward = toUsdc("20000");
        const developmentFund = toUsdc("30000");
        const buybackAmount = toUsdc("50000");
        
        await treasury.sweepToken(await usdc.getAddress(), user1.address, stakingReward);
        await treasury.sweepToken(await usdc.getAddress(), user2.address, developmentFund);
        await treasury.sweepToken(await usdc.getAddress(), governance.address, buybackAmount);
        
        expect(await usdc.balanceOf(user1.address)).to.equal(stakingReward);
        expect(await usdc.balanceOf(user2.address)).to.equal(developmentFund);
        expect(await usdc.balanceOf(governance.address)).to.equal(buybackAmount);
    });
  });
}); 