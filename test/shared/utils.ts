/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { BaseContract, ContractTransactionResponse } from "ethers";
import { TEST_CONSTANTS } from "./constants";

// Type alias for contracts returned by ethers
type DeployedContract = BaseContract & { deploymentTransaction(): ContractTransactionResponse };

// Mock ERC20 contract for testing
export class MockERC20 {
  static async deploy(
    name: string,
    symbol: string,
    decimals: number = 18,
    initialSupply: string = TEST_CONSTANTS.TOKENS.INITIAL_SUPPLY
  ): Promise<DeployedContract> {
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    return await MockERC20Factory.deploy(name, symbol, decimals, initialSupply);
  }
}

// Mock Oracle for testing
export class MockOracle {
  static async deploy(): Promise<DeployedContract> {
    const MockOracleFactory = await ethers.getContractFactory("MockOracle");
    return await MockOracleFactory.deploy();
  }

  static async setPrice(oracle: DeployedContract, assetId: number, price: string): Promise<void> {
    await (oracle as any).setPrice(assetId, price);
  }
}

// Time manipulation utilities
export const timeUtils = {
  async increaseTime(seconds: number): Promise<void> {
    await ethers.provider.send("evm_increaseTime", [seconds]);
    await ethers.provider.send("evm_mine", []);
  },

  async setNextBlockTimestamp(timestamp: number): Promise<void> {
    await ethers.provider.send("evm_setNextBlockTimestamp", [timestamp]);
  },

  async getBlockTimestamp(): Promise<number> {
    const block = await ethers.provider.getBlock("latest");
    return block?.timestamp || 0;
  },

  async mineBlocks(blocks: number): Promise<void> {
    for (let i = 0; i < blocks; i++) {
      await ethers.provider.send("evm_mine", []);
    }
  }
};

// Assertion helpers
export const assertionUtils = {
  async expectRevert(
    promise: Promise<any>,
    expectedError?: string
  ): Promise<void> {
    try {
      await promise;
      expect.fail("Expected transaction to revert");
    } catch (error: any) {
      if (expectedError) {
        expect(error.message).to.include(expectedError);
      }
    }
  },

  async expectEvent(
    tx: any,
    eventName: string,
    expectedArgs?: any[]
  ): Promise<void> {
    const receipt = await tx.wait();
    const event = receipt.events?.find((e: any) => e.event === eventName);
    expect(event).to.not.be.undefined;
    
    if (expectedArgs) {
      expectedArgs.forEach((arg, index) => {
        expect(event.args[index]).to.equal(arg);
      });
    }
  },

  expectBigNumberEqual(actual: any, expected: any, tolerance?: bigint): void {
    if (tolerance) {
      const diff = actual > expected ? actual - expected : expected - actual;
      expect(diff).to.be.lte(tolerance);
    } else {
      expect(actual).to.equal(expected);
    }
  }
};

// User management utilities
export const userUtils = {
  async getSigners(count: number = 10): Promise<SignerWithAddress[]> {
    const signers = await ethers.getSigners();
    return signers.slice(0, count);
  },

  async fundWithTokens(
    token: DeployedContract,
    users: SignerWithAddress[],
    amount: string
  ): Promise<void> {
    for (const user of users) {
      await (token as any).transfer(user.address, amount);
    }
  },

  async approveTokens(
    token: DeployedContract,
    user: SignerWithAddress,
    spender: string,
    amount: string
  ): Promise<void> {
    await (token as any).connect(user).approve(spender, amount);
  }
};

// Contract deployment utilities
export const deploymentUtils = {
  async deployWithProxy(
    contractName: string,
    args: unknown[] = []
  ): Promise<DeployedContract> {
    const Factory = await ethers.getContractFactory(contractName);
    return await Factory.deploy(...args);
  },

  async deployMockTokens(): Promise<{
    usdc: DeployedContract;
    weth: DeployedContract;
    wbtc: DeployedContract;
    unxv: DeployedContract;
  }> {
    const usdc = await MockERC20.deploy("USD Coin", "USDC", 6);
    const weth = await MockERC20.deploy("Wrapped Ethereum", "WETH", 18);
    const wbtc = await MockERC20.deploy("Wrapped Bitcoin", "WBTC", 8);
    const unxv = await MockERC20.deploy("Unxversal Token", "UNXV", 18);

    return { usdc, weth, wbtc, unxv };
  }
};

// Math utilities for calculations
export const mathUtils = {
  calculateInterest(
    principal: bigint,
    rate: bigint,
    time: bigint,
    precision: bigint = BigInt(1e18)
  ): bigint {
    return (principal * rate * time) / precision;
  },

  calculateCollateralValue(
    amount: bigint,
    price: bigint,
    collateralFactor: number,
    decimals: number = 18
  ): bigint {
    const value = (amount * price) / BigInt(10 ** decimals);
    return (value * BigInt(collateralFactor)) / BigInt(TEST_CONSTANTS.FEES.BPS_DENOMINATOR);
  },

  calculateLiquidationBonus(
    debtValue: bigint,
    bonusBps: number
  ): bigint {
    return (debtValue * BigInt(bonusBps)) / BigInt(TEST_CONSTANTS.FEES.BPS_DENOMINATOR);
  },

  calculateExchangeRate(
    cash: bigint,
    borrows: bigint,
    reserves: bigint,
    totalSupply: bigint
  ): bigint {
    if (totalSupply === 0n) {
      return BigInt(TEST_CONSTANTS.LENDING.INITIAL_EXCHANGE_RATE);
    }
    const totalValue = cash + borrows - reserves;
    return (totalValue * BigInt(1e18)) / totalSupply;
  }
};

// Gas reporting utilities
export const gasUtils = {
  async measureGas(tx: ContractTransactionResponse): Promise<bigint> {
    const receipt = await tx.wait();
    return BigInt(receipt?.gasUsed.toString() || "0");
  },

  async measureGasForFunction(
    contract: DeployedContract,
    functionName: string,
    args: unknown[]
  ): Promise<bigint> {
    const tx = await (contract as any)[functionName](...args);
    return await this.measureGas(tx);
  }
};

// Snapshot utilities for test isolation
export const snapshotUtils = {
  async takeSnapshot(): Promise<string> {
    return await ethers.provider.send("evm_snapshot", []);
  },

  async restoreSnapshot(snapshotId: string): Promise<void> {
    await ethers.provider.send("evm_revert", [snapshotId]);
  }
};

// Protocol state utilities
export const protocolUtils = {
  async getUserPositions(
    corePool: DeployedContract,
    user: string
  ): Promise<{
    suppliedAssets: string[];
    borrowedAssets: string[];
    totalCollateralUsd: bigint;
    totalBorrowUsd: bigint;
  }> {
    const suppliedAssets = await (corePool as any).getAssetsUserSupplied(user);
    const borrowedAssets = await (corePool as any).getAssetsUserBorrowed(user);
    const [totalCollateralUsd, totalBorrowUsd] = await (corePool as any).getAccountLiquidityValues(user);

    return {
      suppliedAssets,
      borrowedAssets,
      totalCollateralUsd,
      totalBorrowUsd
    };
  },

  async getMarketState(
    corePool: DeployedContract,
    asset: string
  ): Promise<{
    totalSupply: bigint;
    totalBorrows: bigint;
    totalReserves: bigint;
    exchangeRate: bigint;
    utilizationRate: bigint;
  }> {
    const uToken = await (corePool as any).getUTokenForUnderlying(asset);
    const totalSupply = await (corePool as any).totalSupply(uToken);
    const totalBorrows = await (corePool as any).totalBorrowsCurrent(asset);
    const totalReserves = await (corePool as any).totalReserves(asset);
    const exchangeRate = await (corePool as any).exchangeRateCurrent(asset);
    
    const cash = totalSupply - totalBorrows + totalReserves;
    const utilizationRate = totalBorrows > 0 ? (totalBorrows * BigInt(1e18)) / (cash + totalBorrows) : 0n;

    return {
      totalSupply,
      totalBorrows,
      totalReserves,
      exchangeRate,
      utilizationRate
    };
  }
};

// Random data generation for property-based testing
export const randomUtils = {
  randomBigInt(min: bigint, max: bigint): bigint {
    const range = max - min;
    const randomBytes = ethers.randomBytes(32);
    const randomBigInt = ethers.toBigInt(randomBytes);
    return min + (randomBigInt % range);
  },

  randomAddress(): string {
    return ethers.Wallet.createRandom().address;
  },

  randomTokenAmount(decimals: number = 18): bigint {
    return this.randomBigInt(BigInt(1), BigInt(10) ** BigInt(decimals + 3));
  }
}; 