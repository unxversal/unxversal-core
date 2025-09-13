import type { DeployConfig } from './types.js';
import { X_ASSET_SETS } from './xassets.js';

const USDC_MAINNET_TYPE = '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC' as const;
const USDC_TESTNET_TYPE = USDC_MAINNET_TYPE;

const TICK_SIZE = 10_000; // $0.01 premium tick
const LOT_SIZE = 1;       // one unit per contract for synthetic amounts
const MIN_SIZE = 1;

// Build one options market that holds many synthetic series. We place one market grouping
// for privateCos, and one for gasPerps. Underlying is the synthetic symbol string.
function buildSeries(underlyings: readonly string[], strikes1e6: number[], expiries: number[]) {
  const series: Array<{ expiryMs: number; strike1e6: number; isCall: boolean; underlying: string; initialMark1e6: number }>= [];
  for (const u of underlyings) {
    for (const expiryMs of expiries) {
      for (const k of strikes1e6) {
        series.push({ expiryMs, strike1e6: k, isCall: true, underlying: u, initialMark1e6: 1_000_000 });
        series.push({ expiryMs, strike1e6: k, isCall: false, underlying: u, initialMark1e6: 1_000_000 });
      }
    }
  }
  return series;
}

export function buildMainnetXOptions(): NonNullable<DeployConfig['xoptions']> {
  const strikes = [500_000, 1_000_000, 2_000_000];
  const now = Date.now();
  const oneMonth = 30 * 24 * 60 * 60 * 1000;
  const expiries = [1, 2, 3].map((n) => now + n * oneMonth);
  return [
    {
      base: USDC_MAINNET_TYPE,
      quote: USDC_MAINNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.privateCos, strikes, expiries),
    },
    {
      base: USDC_MAINNET_TYPE,
      quote: USDC_MAINNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.gasPerps, strikes, expiries),
    },
  ];
}

export function buildTestnetXOptions(): NonNullable<DeployConfig['xoptions']> {
  // Small grid for strikes around $1.00
  const strikes = [500_000, 1_000_000, 2_000_000];
  // 3 monthly expiries
  const now = Date.now();
  const oneMonth = 30 * 24 * 60 * 60 * 1000;
  const expiries = [1, 2, 3].map((n) => now + n * oneMonth);

  return [
    {
      base: USDC_TESTNET_TYPE,
      quote: USDC_TESTNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.privateCos, strikes, expiries),
    },
    {
      base: USDC_TESTNET_TYPE,
      quote: USDC_TESTNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.gasPerps, strikes, expiries),
    },
  ];
}


