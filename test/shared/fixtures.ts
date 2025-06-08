/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { TEST_CONSTANTS, toUsdc, toEth } from "./constants";

// Base fixture that all other fixtures extend
export async function baseFixture() {
  const [owner, user1, user2, user3, liquidator, treasury, insurance, protocol] = await ethers.getSigners();
  
  // Deploy mock tokens
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  
  const usdc = await MockERC20Factory.deploy("USD Coin", "USDC", 6, toUsdc("1000000"));
  const weth = await MockERC20Factory.deploy("Wrapped Ethereum", "WETH", 18, toEth("10000"));
  const wbtc = await MockERC20Factory.deploy("Wrapped Bitcoin", "WBTC", 8, "100000000000");
  const unxv = await MockERC20Factory.deploy("Unxversal Token", "UNXV", 18, TEST_CONSTANTS.TOKENS.INITIAL_SUPPLY);

  // Deploy mock oracle
  const MockOracleFactory = await ethers.getContractFactory("MockOracle");
  const oracle = await MockOracleFactory.deploy();

  // Set initial prices
  await (oracle as any).setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
  await (oracle as any).setPrice(2, TEST_CONSTANTS.PRICES.BTC); // BTC
  await (oracle as any).setPrice(3, TEST_CONSTANTS.PRICES.USDC); // USDC
  await (oracle as any).setPrice(4, TEST_CONSTANTS.PRICES.LINK); // LINK

  return {
    owner,
    users: { user1, user2, user3, liquidator, treasury, insurance, protocol },
    tokens: { usdc, weth, wbtc, unxv },
    oracle
  };
}

// DAO-specific fixture
export async function daoFixture() {
  const base = await loadFixture(baseFixture);
  
  // Deploy UNXV token (governance token)
  const UNXVFactory = await ethers.getContractFactory("UNXV");
  const unxvToken = await UNXVFactory.deploy(base.owner.address);

  // Deploy VeUNXV (voting escrow)
  const VeUNXVFactory = await ethers.getContractFactory("VeUNXV");
  const veUNXV = await VeUNXVFactory.deploy(await unxvToken.getAddress());

  // Deploy Timelock Controller
  const TimelockFactory = await ethers.getContractFactory("TimelockController");
  const timelock = await TimelockFactory.deploy(
    TEST_CONSTANTS.GOVERNANCE.TIMELOCK_DELAY,
    [base.owner.address], // proposers
    [base.owner.address], // executors
    base.owner.address    // admin
  );

  // Deploy Unxversal Governor
  const GovernorFactory = await ethers.getContractFactory("UnxversalGovernor");
  const governor = await GovernorFactory.deploy(
    await unxvToken.getAddress(),
    await veUNXV.getAddress(),
    await timelock.getAddress(),
    TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD,
    TEST_CONSTANTS.GOVERNANCE.PROPOSAL_THRESHOLD,
    TEST_CONSTANTS.GOVERNANCE.QUORUM
  );

  // Deploy Gauge Controller
  const GaugeControllerFactory = await ethers.getContractFactory("GaugeController");
  const gaugeController = await GaugeControllerFactory.deploy(
    await unxvToken.getAddress(),
    await veUNXV.getAddress(),
    base.owner.address
  );

  // Deploy Treasury
  const TreasuryFactory = await ethers.getContractFactory("Treasury");
  const treasury = await TreasuryFactory.deploy();

  // Deploy Guardian Pause
  const GuardianPauseFactory = await ethers.getContractFactory("GuardianPause");
  const guardianPause = await GuardianPauseFactory.deploy(
    [base.users.user1.address, base.users.user2.address, base.users.user3.address], // guardians
    3, // required signatures
    TEST_CONSTANTS.TIME.WEEK // max pause duration
  );

  return {
    ...base,
    dao: {
      unxvToken,
      veUNXV,
      timelock,
      governor,
      gaugeController,
      treasury,
      guardianPause
    }
  };
}

// Lending-specific fixture
export async function lendingFixture() {
  const base = await loadFixture(baseFixture);

  // Deploy interest rate model
  const InterestModelFactory = await ethers.getContractFactory("PiecewiseLinearInterestRateModel");
  const interestModel = await InterestModelFactory.deploy(
    200,   // baseRatePerYear (2%)
    1000,  // multiplierPerYear (10%)
    8000,  // kinkUtilizationRate (80%)
    5000,  // jumpMultiplierPerYear (50%)
    base.owner.address
  );

  // Deploy core pool
  const CorePoolFactory = await ethers.getContractFactory("CorePool");
  const corePool = await CorePoolFactory.deploy(
    base.owner.address,
    base.users.treasury.address,
    base.owner.address
  );

  // Deploy risk controller
  const RiskControllerFactory = await ethers.getContractFactory("LendRiskController");
  const riskController = await RiskControllerFactory.deploy(
    await corePool.getAddress(),
    await base.oracle.getAddress(),
    ethers.ZeroAddress, // no synth factory for now
    base.owner.address
  );

  // Deploy liquidation engine
  const LiquidationEngineFactory = await ethers.getContractFactory("LendLiquidationEngine");
  const liquidationEngine = await LiquidationEngineFactory.deploy(
    await corePool.getAddress(),
    await riskController.getAddress(),
    await base.oracle.getAddress(),
    base.owner.address
  );

  // Deploy uTokens
  const UTokenFactory = await ethers.getContractFactory("uToken");
  const uUSDC = await UTokenFactory.deploy(
    await base.tokens.usdc.getAddress(),
    await corePool.getAddress(),
    "Unxversal USDC",
    "uUSDC",
    base.owner.address
  );

  const uWETH = await UTokenFactory.deploy(
    await base.tokens.weth.getAddress(),
    await corePool.getAddress(),
    "Unxversal WETH",
    "uWETH",
    base.owner.address
  );

  // Deploy lending admin
  const LendAdminFactory = await ethers.getContractFactory("LendAdmin");
  const lendAdmin = await LendAdminFactory.deploy(
    base.owner.address,
    await corePool.getAddress(),
    await riskController.getAddress(),
    await base.oracle.getAddress()
  );

  return {
    ...base,
    lending: {
      corePool,
      riskController,
      liquidationEngine,
      interestModel,
      uTokens: { uUSDC, uWETH },
      lendAdmin
    }
  };
}

// Perps-specific fixture
export async function perpsFixture() {
  const base = await loadFixture(baseFixture);

  // Deploy perp clearing house
  const ClearingHouseFactory = await ethers.getContractFactory("PerpClearingHouse");
  const clearingHouse = await ClearingHouseFactory.deploy(
    await base.tokens.usdc.getAddress(),
    await base.oracle.getAddress(),
    base.owner.address
  );

  // Deploy perp liquidation engine
  const PerpLiquidationEngineFactory = await ethers.getContractFactory("PerpLiquidationEngine");
  const perpLiquidationEngine = await PerpLiquidationEngineFactory.deploy(
    await clearingHouse.getAddress(),
    base.owner.address
  );

  // Deploy perps admin
  const PerpsAdminFactory = await ethers.getContractFactory("PerpsAdmin");
  const perpsAdmin = await PerpsAdminFactory.deploy(
    base.owner.address,
    await clearingHouse.getAddress(),
    await perpLiquidationEngine.getAddress(),
    await base.oracle.getAddress()
  );

  return {
    ...base,
    perps: {
      clearingHouse,
      perpLiquidationEngine,
      perpsAdmin
    }
  };
}

// Options-specific fixture
export async function optionsFixture() {
  const base = await loadFixture(baseFixture);

  // Deploy collateral vault
  const CollateralVaultFactory = await ethers.getContractFactory("CollateralVault");
  const collateralVault = await CollateralVaultFactory.deploy(
    await base.tokens.usdc.getAddress(),
    await base.oracle.getAddress(),
    base.owner.address
  );

  // Deploy option NFT
  const OptionNFTFactory = await ethers.getContractFactory("OptionNFT");
  const optionNFT = await OptionNFTFactory.deploy(
    await collateralVault.getAddress(),
    await base.oracle.getAddress(),
    "Unxversal Options",
    "UXO",
    base.owner.address
  );

  // Deploy option fee switch
  const OptionFeeSwitchFactory = await ethers.getContractFactory("OptionFeeSwitch");
  const optionFeeSwitch = await OptionFeeSwitchFactory.deploy(
    base.users.treasury.address,
    await base.tokens.usdc.getAddress(),
    base.users.insurance.address,
    base.users.protocol.address,
    base.owner.address
  );

  // Deploy options admin
  const OptionsAdminFactory = await ethers.getContractFactory("OptionsAdmin");
  const optionsAdmin = await OptionsAdminFactory.deploy(
    base.owner.address,
    await optionNFT.getAddress(),
    await collateralVault.getAddress(),
    await optionFeeSwitch.getAddress(),
    await base.oracle.getAddress()
  );

  return {
    ...base,
    options: {
      collateralVault,
      optionNFT,
      optionFeeSwitch,
      optionsAdmin
    }
  };
}

// Synth-specific fixture
export async function synthFixture() {
  const base = await loadFixture(baseFixture);

  // Deploy synth factory
  const SynthFactoryFactory = await ethers.getContractFactory("SynthFactory");
  const synthFactory = await SynthFactoryFactory.deploy(base.owner.address);

  // Deploy USDC vault
  const USDCVaultFactory = await ethers.getContractFactory("USDCVault");
  const usdcVault = await USDCVaultFactory.deploy(
    await base.tokens.usdc.getAddress(),
    await synthFactory.getAddress(),
    await base.oracle.getAddress(),
    base.owner.address
  );

  // Deploy synth liquidation engine
  const SynthLiquidationEngineFactory = await ethers.getContractFactory("SynthLiquidationEngine");
  const synthLiquidationEngine = await SynthLiquidationEngineFactory.deploy(
    await usdcVault.getAddress(),
    await base.oracle.getAddress(),
    base.owner.address
  );

  // Deploy synth admin
  const SynthAdminFactory = await ethers.getContractFactory("SynthAdmin");
  const synthAdmin = await SynthAdminFactory.deploy(
    base.owner.address,
    await synthFactory.getAddress(),
    await usdcVault.getAddress(),
    await synthLiquidationEngine.getAddress(),
    await base.oracle.getAddress()
  );

  return {
    ...base,
    synth: {
      synthFactory,
      usdcVault,
      synthLiquidationEngine,
      synthAdmin
    }
  };
}

// DEX-specific fixture
export async function dexFixture() {
  const base = await loadFixture(baseFixture);

  // Deploy DEX fee switch
  const DexFeeSwitchFactory = await ethers.getContractFactory("DexFeeSwitch");
  const dexFeeSwitch = await DexFeeSwitchFactory.deploy(
    await base.tokens.usdc.getAddress(),
    base.users.treasury.address,
    base.users.insurance.address,
    base.users.protocol.address,
    base.owner.address
  );

  // Deploy Order NFT
  const OrderNFTFactory = await ethers.getContractFactory("OrderNFT");
  const orderNFT = await OrderNFTFactory.deploy(
    await dexFeeSwitch.getAddress(),
    "Unxversal Orders",
    "UXOrders",
    base.owner.address
  );

  return {
    ...base,
    dex: {
      dexFeeSwitch,
      orderNFT
    }
  };
}

// Full protocol fixture that includes all modules
export async function fullProtocolFixture() {
  const dao = await loadFixture(daoFixture);
  const lending = await loadFixture(lendingFixture);
  const perps = await loadFixture(perpsFixture);
  const options = await loadFixture(optionsFixture);
  const synth = await loadFixture(synthFixture);
  const dex = await loadFixture(dexFixture);

  return {
    ...dao,
    ...lending,
    ...perps,
    ...options,
    ...synth,
    ...dex
  };
} 