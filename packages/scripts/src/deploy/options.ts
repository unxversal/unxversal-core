import type { DeployConfig } from './types.js';
import { DERIVATIVE_SYMBOLS, POLICIES, MAINNET_DERIVATIVE_TYPE_TAGS, TESTNET_DERIVATIVE_TYPE_TAGS, DERIVATIVE_PERP_FUT_SPECS } from './markets.js';
import { buildAllOptionSeriesForFeeds } from '../utils/series.js';

export async function buildMainnetOptions(): Promise<NonNullable<DeployConfig['options']>> {
  const seriesBySymbol = await buildAllOptionSeriesForFeeds(DERIVATIVE_SYMBOLS, POLICIES);
  const listed = Object.entries(seriesBySymbol).map(([symbol, series]) => {
    const cfg = MAINNET_DERIVATIVE_TYPE_TAGS[symbol];
    if (!cfg) throw new Error(`No type configuration found for symbol: ${symbol}`);
    return {
      base: cfg.base,
      quote: cfg.quote,
      tickSize: cfg.tickSize,
      lotSize: cfg.lotSize,
      minSize: cfg.minSize,
      baseDecimals: cfg.baseDecimals,
      quoteDecimals: cfg.quoteDecimals,
      series,
    } as const;
  });
  // Add cash-settled options for perps/futures-only symbols using USDC/USDC with cap = max(strike, strike band high).
  // We reuse generated series (by policy) but mark cashSettled and set cap1e6 conservatively at 2x spot (bandHigh), 
  // and for calls, enforce cap during on-chain series creation.
  const cashSymbols = Object.keys(DERIVATIVE_PERP_FUT_SPECS).filter((s) => !MAINNET_DERIVATIVE_TYPE_TAGS[s]);
  for (const symbol of cashSymbols) {
    const series = seriesBySymbol[symbol];
    if (!series || series.length === 0) continue;
    const usdc = MAINNET_DERIVATIVE_TYPE_TAGS['SUI/USDC']?.quote || '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC';
    const tickSize = 10_000; // $0.01 premium tick
    const lotSize = 1;
    const minSize = 1;
    // Cap: 2x strike ceiling by series construction (bandHigh). Use strike * 2 for calls; ignored for puts by contract.
    const withCash = series.map((s) => ({ ...s, cashSettled: true, cap1e6: s.isCall ? s.strike1e6 * 2 : s.strike1e6 }));
    listed.push({
      base: usdc,
      quote: usdc,
      tickSize,
      lotSize,
      minSize,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: withCash,
    } as any);
  }
  return listed;
}

export async function buildTestnetOptions(): Promise<NonNullable<DeployConfig['options']>> {
  const seriesBySymbol = await buildAllOptionSeriesForFeeds(DERIVATIVE_SYMBOLS, POLICIES);
  const listed = Object.entries(seriesBySymbol).map(([symbol, series]) => {
    const cfg = TESTNET_DERIVATIVE_TYPE_TAGS[symbol];
    if (!cfg) throw new Error(`No type configuration found for symbol: ${symbol}`);
    return {
      base: cfg.base,
      quote: cfg.quote,
      tickSize: cfg.tickSize,
      lotSize: cfg.lotSize,
      minSize: cfg.minSize,
      baseDecimals: cfg.baseDecimals,
      quoteDecimals: cfg.quoteDecimals,
      series,
    } as const;
  });
  const cashSymbols = Object.keys(DERIVATIVE_PERP_FUT_SPECS).filter((s) => !TESTNET_DERIVATIVE_TYPE_TAGS[s]);
  for (const symbol of cashSymbols) {
    const series = seriesBySymbol[symbol];
    if (!series || series.length === 0) continue;
    const usdc = TESTNET_DERIVATIVE_TYPE_TAGS['SUI/USDC']?.quote || '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC';
    const tickSize = 10_000;
    const lotSize = 1;
    const minSize = 1;
    const withCash = series.map((s) => ({ ...s, cashSettled: true, cap1e6: s.isCall ? s.strike1e6 * 2 : s.strike1e6 }));
    listed.push({
      base: usdc,
      quote: usdc,
      tickSize,
      lotSize,
      minSize,
      baseDecimals: 6,
      quoteDecimals: 6,
      series: withCash,
    } as any);
  }
  return listed;
}