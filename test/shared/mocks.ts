// Mock contract utilities for testing
/* eslint-disable @typescript-eslint/no-explicit-any */
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS } from "./constants";

export async function deployMockERC20(
  name: string,
  symbol: string,
  decimals: number = 18,
  initialSupply: string = TEST_CONSTANTS.TOKENS.INITIAL_SUPPLY
) {
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  return await MockERC20Factory.deploy(name, symbol, decimals, initialSupply);
}

export async function deployMockOracle() {
  const MockOracleFactory = await ethers.getContractFactory("MockOracle");
  return await MockOracleFactory.deploy();
}

export async function setupMockPrices(oracle: any) {
  await oracle.setPrice(1, TEST_CONSTANTS.PRICES.ETH); // ETH
  await oracle.setPrice(2, TEST_CONSTANTS.PRICES.BTC); // BTC  
  await oracle.setPrice(3, TEST_CONSTANTS.PRICES.USDC); // USDC
  await oracle.setPrice(4, TEST_CONSTANTS.PRICES.LINK); // LINK
}

export async function fundUsers(
  token: any,
  users: SignerWithAddress[],
  amount: string
) {
  for (const user of users) {
    await token.transfer(user.address, amount);
  }
}

export async function approveTokens(
  token: any,
  user: SignerWithAddress,
  spender: string,
  amount: string
) {
  await token.connect(user).approve(spender, amount);
} 