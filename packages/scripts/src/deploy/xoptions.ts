import type { DeployConfig } from './types.js';
import { X_ASSET_SETS } from './xassets.js';
import { X_REF_PRICES_1E6, X_POLICIES } from './xprices.js';
import { generateExpiriesMs, generateStrikeGrid1e6 } from '../utils/series.js';

const USDC_MAINNET_TYPE = '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC' as const;
const USDC_TESTNET_TYPE = USDC_MAINNET_TYPE;

const TICK_SIZE = 10_000; // $0.01 premium tick
const LOT_SIZE = 1;       // one unit per contract for synthetic amounts
const MIN_SIZE = 1;

// Build one options market that holds many synthetic series. We place one market grouping
// for privateCos, and one for gasPerps. Underlying is the synthetic symbol string.
function strikesFor(underlying: string): readonly number[] {
  const ref = X_REF_PRICES_1E6[underlying] ?? 1_000_000; // default $1
  const refHuman = ref / 1_000_000;
  const pol = X_POLICIES[underlying] || {};
  const bandLow = pol.bandLow ?? 0.5;
  const bandHigh = pol.bandHigh ?? 2.0;
  const stepAbs = pol.stepAbs;
  const stepPct = pol.stepPct ?? 0.1; // 10% default for synthetics
  const min = Math.max(0.000001, refHuman * bandLow);
  const max = refHuman * bandHigh;
  const step = stepAbs !== undefined ? stepAbs : Math.max(0.005, stepPct * refHuman);
  return generateStrikeGrid1e6(min, max, step);
}

function buildSeries(underlyings: readonly string[], expiries: number[]) {
  const series: Array<{ expiryMs: number; strike1e6: number; isCall: boolean; underlying: string; initialMark1e6: number }>= [];
  for (const u of underlyings) {
    for (const expiryMs of expiries) {
      const ks = strikesFor(u);
      for (const k of ks) {
        series.push({ expiryMs, strike1e6: k, isCall: true, underlying: u, initialMark1e6: 1_000_000 });
        series.push({ expiryMs, strike1e6: k, isCall: false, underlying: u, initialMark1e6: 1_000_000 });
      }
    }
  }
  return series;
}

export function buildMainnetXOptions(): NonNullable<DeployConfig['xoptions']> {
  const expiries = generateExpiriesMs({ cadence: 'monthly', years: 1, expiryHourUtc: 0, monthlyDay: 1 });
  return [
    {
      base: USDC_MAINNET_TYPE,
      quote: USDC_MAINNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.privateCos, expiries),
    },
    {
      base: USDC_MAINNET_TYPE,
      quote: USDC_MAINNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.gasPerps, expiries),
    },
  ];
}

export function buildTestnetXOptions(): NonNullable<DeployConfig['xoptions']> {
  // Small grid for strikes around $1.00
  const expiries = generateExpiriesMs({ cadence: 'monthly', years: 1, expiryHourUtc: 0, monthlyDay: 1 });

  return [
    {
      base: USDC_TESTNET_TYPE,
      quote: USDC_TESTNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.privateCos, expiries),
    },
    {
      base: USDC_TESTNET_TYPE,
      quote: USDC_TESTNET_TYPE,
      tickSize: TICK_SIZE,
      lotSize: LOT_SIZE,
      minSize: MIN_SIZE,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: buildSeries(X_ASSET_SETS.gasPerps, expiries),
    },
  ];
}


