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
  switchboard: {
    aggregatorIds: string[];            // Switchboard Aggregator object IDs to update each cycle
  };
  options: {
    markets: string[];                  // Options market object ids
    seriesByMarket: Record<string, string[]>; // map marketId -> array of series keys (u128 as string)
    sweepMax: number;                   // max orders to sweep per tx
  };
  perps: {
    markets: string[];                  // Perp market object ids
    fundingDelta1e6?: number;           // optional funding delta per contract in 1e6 scale
    longsPay?: boolean;                 // whether longs pay shorts; default true
  };
  futures: {
    markets: string[];                  // Linear futures market ids
    aggregatorByMarket: Record<string, string>; // marketId -> aggregatorId
  };
  gasFutures: {
    markets: string[];                  // Gas futures market ids
  };
  lending?: {
    feeVaultId: string;                 // unxversal::fees::FeeVault id (where reserves are swept)
    defaultSweepAmount?: number;        // default u64 amount to sweep per pool if pool.sweepAmount absent
    pools: Array<{
      poolId: string;                   // unxversal::lending::LendingPool<T> id
      asset: TypeTag;                   // type tag for T (e.g., 'SUI' or '::unxv::UNXV')
      sweepAmount?: number;             // optional override per-pool amount (u64 units of T)
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
  switchboard: {
    aggregatorIds: [],
  },
  options: {
    markets: [],
    seriesByMarket: {},
    sweepMax: 50,
  },
  perps: {
    markets: [],
    fundingDelta1e6: undefined,
    longsPay: true,
  },
  futures: {
    markets: [],
    aggregatorByMarket: {},
  },
  gasFutures: {
    markets: [],
  },
  lending: {
    feeVaultId: '',
    defaultSweepAmount: 0,
    pools: [],
  },
  cron: {
    sleepMs: 20_000,
  },
};
