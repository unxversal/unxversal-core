import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const pkg = require('../package.json');
export const version = pkg.version as string;
export const env = {
  NODE_ENV: process.env.NODE_ENV ?? 'development',
};

export type NetworkName = 'mainnet' | 'testnet';
export type TypeTag = string;

export type AppConfig = {
  network: NetworkName;
  pkgId: string;                        // Unxversal package id (0x...)
  adminRegistryId: string;              // unxversal::admin::AdminRegistry id
  oracleRegistryId: string;             // unxversal::oracle::OracleRegistry id
  pyth: {
    stateId: string;                    // Pyth state object id
    wormholeStateId: string;            // Wormhole state object id (for Pyth)
  };
  options: {
    markets: string[];                  // Options market object ids
    seriesByMarket: Record<string, string[]>; // map marketId -> array of series keys (u128 as string)
    sweepMax: number;                   // max orders to sweep per tx
  };
  perps: {
    markets: string[];                  // Perp market object ids
    priceIdByMarket: Record<string, string>; // marketId -> Pyth price feed id (0x...)
    fundingDelta1e6?: number;           // optional funding delta per contract in 1e6 scale
    longsPay?: boolean;                 // whether longs pay shorts; default true
  };
  futures: {
    markets: string[];                  // Linear futures market ids
    priceIdByMarket: Record<string, string>; // marketId -> Pyth price feed id (0x...)
    expiryMsByMarket?: Record<string, number>; // marketId -> expiry ms (0 = perpetual)
  };
  gasFutures: {
    markets: string[];                  // Gas futures market ids
  };
  lending?: {
    feeVaultId: string;                 // unxversal::fees::FeeVault id
    defaultSweepAmount?: number;        // default u64 amount to sweep per market reserves
    markets: Array<{
      marketId: string;                 // unxversal::lending::LendingMarket<Collat,Debt> id
      collat: TypeTag;                  // Collateral type tag
      debt: TypeTag;                    // Debt type tag
      sweepAmount?: number;             // optional override per-market amount (u64 units of Debt)
    }>;
  };
  cron: {
    sleepMs: number;                    // interval between cycles
  };
};

// Project configuration (non-secret). Adjust per environment.
export const config: AppConfig = {
  network: 'testnet',
  pkgId: '',
  adminRegistryId: '',
  oracleRegistryId: '',
  pyth: {
    stateId: '0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c',
    wormholeStateId: '0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790',
  },
  options: {
    markets: [],
    seriesByMarket: {},
    sweepMax: 50,
  },
  perps: {
    markets: [],
    priceIdByMarket: {},
    fundingDelta1e6: undefined,
    longsPay: true,
  },
  futures: {
    markets: [],
    priceIdByMarket: {},
    expiryMsByMarket: {},
  },
  gasFutures: {
    markets: [],
  },
  lending: {
    feeVaultId: '',
    defaultSweepAmount: 0,
    markets: [],
  },
  cron: {
    sleepMs: 1_000,
  },
};
