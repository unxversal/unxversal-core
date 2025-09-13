import type { DeployConfig } from './types.js';
import { X_ASSET_SETS } from './xassets.js';

// Testnet USDC type tag (used as collateral)
const USDC_TESTNET_TYPE = '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC' as const;

// Default risk params for synthetic assets (conservative)
const X_IM_BPS = 800;
const X_MM_BPS = 500;
const X_LIQ_BPS = 100;
const X_KEEPER_BPS = 2000;

// Default contract sizing and orderbook params
const CONTRACT_SIZE = 1_000_000; // 1e6 quote units per contract
const TICK_SIZE = 10_000;        // $0.01
const LOT_SIZE = 1;              // 1 contract
const MIN_SIZE = 1;              // 1 contract

function mapSymbolsToXPerps(symbols: readonly string[]) {
  return symbols.map((symbol) => ({
    collat: USDC_TESTNET_TYPE,
    symbol,
    contractSize: CONTRACT_SIZE,
    fundingIntervalMs: 3_600_000,
    initialMarginBps: X_IM_BPS,
    maintenanceMarginBps: X_MM_BPS,
    liquidationFeeBps: X_LIQ_BPS,
    keeperIncentiveBps: X_KEEPER_BPS,
    tickSize: TICK_SIZE,
    lotSize: LOT_SIZE,
    minSize: MIN_SIZE,
    // EMA bootstrap (synthetic index starts at $1.00 by default)
    initialMark1e6: 1_000_000,
    // Leave EMA params to on-chain defaults unless overridden in config
  } as const));
}

export function buildMainnetXPerps(): NonNullable<DeployConfig['xperps']> {
  // Keep mainnet empty by default; configure explicitly when ready
  return [
    ...mapSymbolsToXPerps(X_ASSET_SETS.privateCos),
    ...mapSymbolsToXPerps(X_ASSET_SETS.gasPerps),
  ];
}

export function buildTestnetXPerps(): NonNullable<DeployConfig['xperps']> {
  return [
    ...mapSymbolsToXPerps(X_ASSET_SETS.privateCos),
    ...mapSymbolsToXPerps(X_ASSET_SETS.gasPerps),
  ];
}


