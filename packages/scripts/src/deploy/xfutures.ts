import type { DeployConfig } from './types.js';
import { X_ASSET_SETS } from './xassets.js';
import { generateExpiriesMs } from '../utils/series.js';

const USDC_MAINNET_TYPE = '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC' as const;
const USDC_TESTNET_TYPE = USDC_MAINNET_TYPE;

const X_IM_BPS = 1000;
const X_MM_BPS = 500;
const X_LIQ_BPS = 100;
const X_KEEPER_BPS = 2000;

const CONTRACT_SIZE = 1_000_000;
const TICK_SIZE = 10_000;
const LOT_SIZE = 1;
const MIN_SIZE = 1;

function mapSymbolsToXFutureSeries(symbols: readonly string[], expiries: number[]): NonNullable<DeployConfig['xfutures']> {
  const out: NonNullable<DeployConfig['xfutures']> = [];
  for (const symbol of symbols) {
    for (const expiryMs of expiries) {
      out.push({
        collat: USDC_TESTNET_TYPE,
        symbol,
        expiryMs,
        contractSize: CONTRACT_SIZE,
        initialMarginBps: X_IM_BPS,
        maintenanceMarginBps: X_MM_BPS,
        liquidationFeeBps: X_LIQ_BPS,
        keeperIncentiveBps: X_KEEPER_BPS,
        tickSize: TICK_SIZE,
        lotSize: LOT_SIZE,
        minSize: MIN_SIZE,
        initialMark1e6: 1_000_000,
      } as const);
    }
  }
  return out;
}

export function buildMainnetXFutureSeries(): NonNullable<DeployConfig['xfutures']> {
  const expiries = generateExpiriesMs({ cadence: 'monthly', years: 1, expiryHourUtc: 0, monthlyDay: 1 });
  return [
    // Use same sets on mainnet; adjust externally via modular config if needed
    ...mapSymbolsToXFutureSeries(X_ASSET_SETS.privateCos, expiries).map((m) => ({ ...m, collat: USDC_MAINNET_TYPE })),
    ...mapSymbolsToXFutureSeries(X_ASSET_SETS.gasPerps, expiries).map((m) => ({ ...m, collat: USDC_MAINNET_TYPE })),
  ];
}

export function buildTestnetXFutureSeries(): NonNullable<DeployConfig['xfutures']> {
  const expiries = generateExpiriesMs({ cadence: 'monthly', years: 1, expiryHourUtc: 0, monthlyDay: 1 });
  return [
    ...mapSymbolsToXFutureSeries(X_ASSET_SETS.privateCos, expiries),
    ...mapSymbolsToXFutureSeries(X_ASSET_SETS.gasPerps, expiries),
  ];
}


