import type { DeployConfig } from './types.js';
import { DERIVATIVE_SYMBOLS, POLICIES, MAINNET_DERIVATIVE_TYPE_TAGS, TESTNET_DERIVATIVE_TYPE_TAGS } from './markets.js';
import { buildAllOptionSeriesForFeeds } from '../utils/series.js';

// Synthetic xoptions use EMA pseudo-spot; deploy inputs mirror options.ts

export async function buildMainnetXOptions(): Promise<NonNullable<DeployConfig['options']>> {
  const seriesBySymbol = await buildAllOptionSeriesForFeeds(DERIVATIVE_SYMBOLS, POLICIES);
  return Object.entries(seriesBySymbol).map(([symbol, series]) => {
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
}

export async function buildTestnetXOptions(): Promise<NonNullable<DeployConfig['options']>> {
  const seriesBySymbol = await buildAllOptionSeriesForFeeds(DERIVATIVE_SYMBOLS, POLICIES);
  return Object.entries(seriesBySymbol).map(([symbol, series]) => {
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
}


