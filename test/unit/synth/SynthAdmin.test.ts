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
  let usdcVault: any;
  let synthLiquidationEngine: any;
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

    // Deploy SynthFactory first
    const SynthFactoryFactory = await ethers.getContractFactory("SynthFactory");
    const synthFactory = await SynthFactoryFactory.deploy(
      owner.address, // _initialOwner
      await oracle.getAddress() // _oracleAddress
    );

    // Deploy USDCVault
    const USDCVaultFactory = await ethers.getContractFactory("USDCVault");
    const usdcVault = await USDCVaultFactory.deploy(
      await usdc.getAddress(), // _usdcTokenAddress
      await oracle.getAddress(), // _oracleAddress
      await synthFactory.getAddress(), // _synthFactoryAddress
      owner.address // _initialOwner
    );

    // Deploy SynthLiquidationEngine
    const SynthLiquidationEngineFactory = await ethers.getContractFactory("SynthLiquidationEngine");
    const synthLiquidationEngine = await SynthLiquidationEngineFactory.deploy(
      await usdcVault.getAddress(), // _usdcVaultAddress
      await synthFactory.getAddress(), // _synthFactoryAddress
      await oracle.getAddress(), // _oracleAddress
      await usdc.getAddress(), // _usdcTokenAddress
      owner.address // _initialOwner
    );

    // Deploy SynthAdmin with all required parameters
    const SynthAdminFactory = await ethers.getContractFactory("SynthAdmin");
    const synthAdmin = await SynthAdminFactory.deploy(
      owner.address, // _initialOwner
      await usdcVault.getAddress(), // _usdcVault
      await synthFactory.getAddress(), // _synthFactory
      await synthLiquidationEngine.getAddress(), // _synthLiquidationEngine
      await oracle.getAddress() // _oracleRelayer
    );

    return {
      synthAdmin,
      synthFactory,
      usdcVault,
      synthLiquidationEngine,
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
    usdcVault = fixture.usdcVault;
    synthLiquidationEngine = fixture.synthLiquidationEngine;
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

    it("Should set correct USDCVault", async function () {
      expect(await synthAdmin.usdcVault()).to.equal(await usdcVault.getAddress());
    });

    it("Should set correct SynthLiquidationEngine", async function () {
      expect(await synthAdmin.synthLiquidationEngine()).to.equal(await synthLiquidationEngine.getAddress());
    });

    it("Should set correct oracle", async function () {
      expect(await synthAdmin.oracleRelayer()).to.equal(await oracle.getAddress());
    });

    it("Should set correct owner", async function () {
      expect(await synthAdmin.owner()).to.equal(owner.address);
    });
  });

  describe("Protocol Management", function () {
    it("Should pause synth protocol", async function () {
      await expect(
        synthAdmin.pauseSynthProtocol()
      ).to.not.be.reverted;
    });

    it("Should unpause synth protocol", async function () {
      await synthAdmin.pauseSynthProtocol();
      await expect(
        synthAdmin.unpauseSynthProtocol()
      ).to.not.be.reverted;
    });

    it("Should sweep vault surplus", async function () {
      await expect(
        synthAdmin.sweepVaultSurplusToTreasury()
      ).to.not.be.reverted;
    });

    it("Should only allow owner to manage protocol", async function () {
      await expect(
        synthAdmin.connect(user1).pauseSynthProtocol()
      ).to.be.revertedWithCustomError(synthAdmin, "OwnableUnauthorizedAccount");
    });
  });

  describe("Vault Parameter Management", function () {
    it("Should configure vault parameters", async function () {
      await expect(
        synthAdmin.configureVaultParameters(
          15000, // minCRbps
          50, // mintFeeBps
          50, // burnFeeBps
          treasury.address, // feeRecipient
          treasury.address, // treasury
          toUsdc("100000") // surplusThreshold
        )
      ).to.not.be.reverted;
    });

    it("Should set vault oracle", async function () {
      await expect(
        synthAdmin.setVaultOracle(await oracle.getAddress())
      ).to.not.be.reverted;
    });

    it("Should set vault liquidation engine", async function () {
      await expect(
        synthAdmin.setVaultLiquidationEngine(await synthLiquidationEngine.getAddress())
      ).to.not.be.reverted;
    });
  });

  describe("Factory Management", function () {
    it("Should add synth to factory", async function () {
      await expect(
        synthAdmin.addSynthToFactory(
          "Synthetic ETH",
          "sETH",
          1, // assetId
          15000, // customMinCRbps
          await usdcVault.getAddress() // controllerAddress
        )
      ).to.emit(synthFactory, "SynthDeployedAndConfigured");
    });

    it("Should set factory oracle", async function () {
      await expect(
        synthAdmin.setFactoryOracle(await oracle.getAddress())
      ).to.not.be.reverted;
    });
  });

  describe("Liquidation Engine Management", function () {
    it("Should configure liquidation engine parameters", async function () {
      await expect(
        synthAdmin.configureLiquidationEngineParams(
          1000, // penaltyBps (10%)
          5000, // rewardShareBps (50%)
          5000 // maxPortionBps (50%)
        )
      ).to.not.be.reverted;
    });

    it("Should set liquidation engine oracle", async function () {
      await expect(
        synthAdmin.setLiquidationEngineOracle(await oracle.getAddress())
      ).to.not.be.reverted;
    });
  });
}); 