/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS, toUsdc } from "../../shared/constants";

describe("SynthAdmin", function () {
  let synthAdmin: any;
  let synthFactory: any;
  let usdc: any;
  let oracle: any;
  let owner: SignerWithAddress;
  let admin: SignerWithAddress;
  let user1: SignerWithAddress;
  let treasury: SignerWithAddress;

  async function deploySynthAdminFixture() {
    const [owner, admin, user1, treasury] = await ethers.getSigners();

    // Deploy mock USDC and oracle
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const usdc = await MockERC20Factory.deploy("USDC", "USDC", 6, 0);

    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracleFactory.deploy();

    // Deploy SynthFactory
    const SynthFactoryFactory = await ethers.getContractFactory("SynthFactory");
    const synthFactory = await SynthFactoryFactory.deploy(
      await usdc.getAddress(),
      await oracle.getAddress(),
      treasury.address
    );

    // Deploy SynthAdmin
    const SynthAdminFactory = await ethers.getContractFactory("SynthAdmin");
    const synthAdmin = await SynthAdminFactory.deploy(
      await synthFactory.getAddress(),
      owner.address
    );

    return {
      synthAdmin,
      synthFactory,
      usdc,
      oracle,
      owner,
      admin,
      user1,
      treasury
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deploySynthAdminFixture);
    synthAdmin = fixture.synthAdmin;
    synthFactory = fixture.synthFactory;
    usdc = fixture.usdc;
    oracle = fixture.oracle;
    owner = fixture.owner;
    admin = fixture.admin;
    user1 = fixture.user1;
    treasury = fixture.treasury;
  });

  describe("Initialization", function () {
    it("Should set correct SynthFactory", async function () {
      expect(await synthAdmin.synthFactory()).to.equal(await synthFactory.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await synthAdmin.owner()).to.equal(owner.address);
    });

    it("Should have default admin parameters", async function () {
      expect(await synthAdmin.defaultCollateralRatio()).to.equal(15000); // 150%
      expect(await synthAdmin.defaultLiquidationThreshold()).to.equal(11000); // 110%
      expect(await synthAdmin.globalDebtCeiling()).to.equal(ethers.parseEther("1000000000")); // 1B
    });
  });

  describe("Synthetic Asset Administration", function () {
    it("Should create new synthetic asset", async function () {
      await expect(
        synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000)
      ).to.emit(synthAdmin, "SynthAssetCreated")
      .withArgs(1, "sETH");
    });

    it("Should set asset parameters", async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      const newCollateralRatio = 16000; // 160%
      await expect(
        synthAdmin.setAssetCollateralRatio(1, newCollateralRatio)
      ).to.emit(synthAdmin, "CollateralRatioUpdated")
      .withArgs(1, newCollateralRatio);
      
      expect(await synthAdmin.getAssetCollateralRatio(1)).to.equal(newCollateralRatio);
    });

    it("Should set liquidation threshold", async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      const newThreshold = 12000; // 120%
      await expect(
        synthAdmin.setAssetLiquidationThreshold(1, newThreshold)
      ).to.emit(synthAdmin, "LiquidationThresholdUpdated")
      .withArgs(1, newThreshold);
      
      expect(await synthAdmin.getAssetLiquidationThreshold(1)).to.equal(newThreshold);
    });

    it("Should pause synthetic asset", async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      await expect(
        synthAdmin.pauseAsset(1)
      ).to.emit(synthAdmin, "AssetPaused")
      .withArgs(1);
      
      expect(await synthAdmin.isAssetPaused(1)).to.be.true;
    });

    it("Should unpause synthetic asset", async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      await synthAdmin.pauseAsset(1);
      
      await expect(
        synthAdmin.unpauseAsset(1)
      ).to.emit(synthAdmin, "AssetUnpaused")
      .withArgs(1);
      
      expect(await synthAdmin.isAssetPaused(1)).to.be.false;
    });

    it("Should only allow owner to manage assets", async function () {
      await expect(
        synthAdmin.connect(user1).createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Global Parameters", function () {
    it("Should set global debt ceiling", async function () {
      const newCeiling = ethers.parseEther("2000000000"); // 2B
      
      await expect(
        synthAdmin.setGlobalDebtCeiling(newCeiling)
      ).to.emit(synthAdmin, "GlobalDebtCeilingUpdated")
      .withArgs(newCeiling);
      
      expect(await synthAdmin.globalDebtCeiling()).to.equal(newCeiling);
    });

    it("Should set minimum collateral ratio", async function () {
      const minRatio = 12000; // 120%
      
      await expect(
        synthAdmin.setMinimumCollateralRatio(minRatio)
      ).to.emit(synthAdmin, "MinimumCollateralRatioUpdated")
      .withArgs(minRatio);
      
      expect(await synthAdmin.minimumCollateralRatio()).to.equal(minRatio);
    });

    it("Should set maximum assets per user", async function () {
      const maxAssets = 10;
      
      await expect(
        synthAdmin.setMaxAssetsPerUser(maxAssets)
      ).to.emit(synthAdmin, "MaxAssetsPerUserUpdated")
      .withArgs(maxAssets);
      
      expect(await synthAdmin.maxAssetsPerUser()).to.equal(maxAssets);
    });

    it("Should validate parameter ranges", async function () {
      // Invalid collateral ratio (too low)
      await expect(
        synthAdmin.setMinimumCollateralRatio(5000)
      ).to.be.revertedWith("Invalid ratio");
      
      // Invalid debt ceiling (zero)
      await expect(
        synthAdmin.setGlobalDebtCeiling(0)
      ).to.be.revertedWith("Invalid ceiling");
    });
  });

  describe("Fee Management", function () {
    it("Should set minting fee", async function () {
      const mintingFee = 100; // 1%
      
      await expect(
        synthAdmin.setMintingFee(mintingFee)
      ).to.emit(synthAdmin, "MintingFeeUpdated")
      .withArgs(mintingFee);
      
      expect(await synthAdmin.mintingFee()).to.equal(mintingFee);
    });

    it("Should set burning fee", async function () {
      const burningFee = 50; // 0.5%
      
      await expect(
        synthAdmin.setBurningFee(burningFee)
      ).to.emit(synthAdmin, "BurningFeeUpdated")
      .withArgs(burningFee);
      
      expect(await synthAdmin.burningFee()).to.equal(burningFee);
    });

    it("Should set liquidation fee", async function () {
      const liquidationFee = 200; // 2%
      
      await expect(
        synthAdmin.setLiquidationFee(liquidationFee)
      ).to.emit(synthAdmin, "LiquidationFeeUpdated")
      .withArgs(liquidationFee);
      
      expect(await synthAdmin.liquidationFee()).to.equal(liquidationFee);
    });

    it("Should not allow excessive fees", async function () {
      // Fee too high (>10%)
      await expect(
        synthAdmin.setMintingFee(1500)
      ).to.be.revertedWith("Fee too high");
      
      await expect(
        synthAdmin.setBurningFee(1500)
      ).to.be.revertedWith("Fee too high");
    });

    it("Should update fee recipient", async function () {
      await expect(
        synthAdmin.setFeeRecipient(treasury.address)
      ).to.emit(synthAdmin, "FeeRecipientUpdated")
      .withArgs(treasury.address);
      
      expect(await synthAdmin.feeRecipient()).to.equal(treasury.address);
    });
  });

  describe("Access Control", function () {
    it("Should grant admin role", async function () {
      const adminRole = await synthAdmin.ADMIN_ROLE();
      
      await synthAdmin.grantRole(adminRole, admin.address);
      expect(await synthAdmin.hasRole(adminRole, admin.address)).to.be.true;
    });

    it("Should allow admin to manage parameters", async function () {
      const adminRole = await synthAdmin.ADMIN_ROLE();
      await synthAdmin.grantRole(adminRole, admin.address);
      
      await expect(
        synthAdmin.connect(admin).setMintingFee(150)
      ).to.emit(synthAdmin, "MintingFeeUpdated");
    });

    it("Should allow admin to pause assets", async function () {
      const adminRole = await synthAdmin.ADMIN_ROLE();
      await synthAdmin.grantRole(adminRole, admin.address);
      
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      await expect(
        synthAdmin.connect(admin).pauseAsset(1)
      ).to.emit(synthAdmin, "AssetPaused");
    });

    it("Should revoke admin role", async function () {
      const adminRole = await synthAdmin.ADMIN_ROLE();
      await synthAdmin.grantRole(adminRole, admin.address);
      await synthAdmin.revokeRole(adminRole, admin.address);
      
      expect(await synthAdmin.hasRole(adminRole, admin.address)).to.be.false;
    });

    it("Should not allow non-admin to change parameters", async function () {
      await expect(
        synthAdmin.connect(user1).setMintingFee(150)
      ).to.be.revertedWith("AccessControl: account");
    });
  });

  describe("Asset Monitoring", function () {
    beforeEach(async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      await synthAdmin.createSynthAsset("Synthetic BTC", "sBTC", 2, 16000, 12000);
    });

    it("Should list all synthetic assets", async function () {
      const assets = await synthAdmin.getAllAssets();
      expect(assets.length).to.equal(2);
      expect(assets[0]).to.equal(1);
      expect(assets[1]).to.equal(2);
    });

    it("Should get asset information", async function () {
      const assetInfo = await synthAdmin.getAssetInfo(1);
      expect(assetInfo.assetId).to.equal(1);
      expect(assetInfo.collateralRatio).to.equal(15000);
      expect(assetInfo.liquidationThreshold).to.equal(11000);
      expect(assetInfo.isPaused).to.be.false;
    });

    it("Should track total debt", async function () {
      const totalDebt = await synthAdmin.getTotalDebt();
      expect(totalDebt).to.equal(0); // No minted synths yet
    });

    it("Should calculate system health", async function () {
      const systemHealth = await synthAdmin.getSystemHealth();
      expect(systemHealth.totalAssets).to.equal(2);
      expect(systemHealth.totalDebt).to.equal(0);
      expect(systemHealth.globalUtilization).to.equal(0);
    });

    it("Should check if asset exists", async function () {
      expect(await synthAdmin.assetExists(1)).to.be.true;
      expect(await synthAdmin.assetExists(3)).to.be.false;
    });
  });

  describe("Emergency Functions", function () {
    beforeEach(async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
    });

    it("Should pause all operations", async function () {
      await synthAdmin.pauseAll();
      expect(await synthAdmin.paused()).to.be.true;
    });

    it("Should not allow asset operations when paused", async function () {
      await synthAdmin.pauseAll();
      
      await expect(
        synthAdmin.createSynthAsset("Synthetic BTC", "sBTC", 2, 16000, 12000)
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should unpause all operations", async function () {
      await synthAdmin.pauseAll();
      await synthAdmin.unpauseAll();
      expect(await synthAdmin.paused()).to.be.false;
    });

    it("Should trigger emergency shutdown", async function () {
      await expect(
        synthAdmin.emergencyShutdown()
      ).to.emit(synthAdmin, "EmergencyShutdown");
      
      expect(await synthAdmin.isShutdown()).to.be.true;
    });

    it("Should not allow operations during shutdown", async function () {
      await synthAdmin.emergencyShutdown();
      
      await expect(
        synthAdmin.setMintingFee(100)
      ).to.be.revertedWith("System shutdown");
    });

    it("Should allow only owner to trigger shutdown", async function () {
      await expect(
        synthAdmin.connect(user1).emergencyShutdown()
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle asset lifecycle", async function () {
      // Create asset
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      // Update parameters
      await synthAdmin.setAssetCollateralRatio(1, 16000);
      await synthAdmin.setAssetLiquidationThreshold(1, 12000);
      
      // Pause and unpause
      await synthAdmin.pauseAsset(1);
      expect(await synthAdmin.isAssetPaused(1)).to.be.true;
      
      await synthAdmin.unpauseAsset(1);
      expect(await synthAdmin.isAssetPaused(1)).to.be.false;
      
      // Verify final state
      const assetInfo = await synthAdmin.getAssetInfo(1);
      expect(assetInfo.collateralRatio).to.equal(16000);
      expect(assetInfo.liquidationThreshold).to.equal(12000);
    });

    it("Should manage multiple assets", async function () {
      // Create multiple assets
      const assets = [
        { name: "Synthetic ETH", symbol: "sETH", id: 1, cr: 15000, lt: 11000 },
        { name: "Synthetic BTC", symbol: "sBTC", id: 2, cr: 16000, lt: 12000 },
        { name: "Synthetic LINK", symbol: "sLINK", id: 3, cr: 18000, lt: 13000 }
      ];
      
      for (const asset of assets) {
        await synthAdmin.createSynthAsset(asset.name, asset.symbol, asset.id, asset.cr, asset.lt);
      }
      
      // Verify all assets created
      const allAssets = await synthAdmin.getAllAssets();
      expect(allAssets.length).to.equal(3);
      
      // Batch update fees
      await synthAdmin.setMintingFee(100);
      await synthAdmin.setBurningFee(50);
      
      // Verify fees applied to all assets
      expect(await synthAdmin.mintingFee()).to.equal(100);
      expect(await synthAdmin.burningFee()).to.equal(50);
    });

    it("Should handle admin role transitions", async function () {
      const adminRole = await synthAdmin.ADMIN_ROLE();
      
      // Grant admin role to new admin
      await synthAdmin.grantRole(adminRole, admin.address);
      
      // New admin creates asset
      await synthAdmin.connect(admin).createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      // Owner revokes role
      await synthAdmin.revokeRole(adminRole, admin.address);
      
      // Ex-admin can no longer manage
      await expect(
        synthAdmin.connect(admin).pauseAsset(1)
      ).to.be.revertedWith("AccessControl: account");
      
      // Owner can still manage
      await synthAdmin.pauseAsset(1);
      expect(await synthAdmin.isAssetPaused(1)).to.be.true;
    });
  });

  describe("Parameter Validation", function () {
    it("Should validate collateral ratios", async function () {
      await expect(
        synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 9000, 11000) // CR < LT
      ).to.be.revertedWith("Invalid parameters");
      
      await expect(
        synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 50000, 11000) // CR too high
      ).to.be.revertedWith("Invalid parameters");
    });

    it("Should validate liquidation thresholds", async function () {
      await expect(
        synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 5000) // LT too low
      ).to.be.revertedWith("Invalid parameters");
      
      await expect(
        synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 20000) // LT too high
      ).to.be.revertedWith("Invalid parameters");
    });

    it("Should prevent duplicate asset IDs", async function () {
      await synthAdmin.createSynthAsset("Synthetic ETH", "sETH", 1, 15000, 11000);
      
      await expect(
        synthAdmin.createSynthAsset("Another ETH", "aETH", 1, 16000, 12000)
      ).to.be.revertedWith("Asset already exists");
    });

    it("Should validate asset symbols", async function () {
      await expect(
        synthAdmin.createSynthAsset("Synthetic ETH", "", 1, 15000, 11000) // Empty symbol
      ).to.be.revertedWith("Invalid symbol");
      
      await expect(
        synthAdmin.createSynthAsset("", "sETH", 1, 15000, 11000) // Empty name
      ).to.be.revertedWith("Invalid name");
    });
  });
}); 