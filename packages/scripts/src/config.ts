import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const pkg = require('../package.json');
export const version = pkg.version as string;
export const env = {
  NODE_ENV: process.env.NODE_ENV ?? 'development',
};

export type NetworkName = 'mainnet' | 'testnet';

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
  };
  gasFutures: {
    markets: string[];                  // Gas futures market ids
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
  },
  gasFutures: {
    markets: [],
  },
  cron: {
    sleepMs: 60_000,
  },
};
