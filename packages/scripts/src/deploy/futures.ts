import { generateFuturesMarkets, type Interval } from './series.js';
import type { DeployConfig } from './types.js';
import { MAINNET_DERIVATIVE_TYPE_TAGS, FUTURES_TIERS, TIER_PARAMS, TESTNET_DERIVATIVE_TYPE_TAGS } from './markets.js';

function buildMainnetFuturesForSymbol(symbol: string, years: number, interval: Interval, opts?: {
  weeklyOn?: number; monthlyOnDay?: number; maxMarkets?: number; expiryHourUTC?: number;
}) {
  const cfg = MAINNET_DERIVATIVE_TYPE_TAGS[symbol];
  if (!cfg) throw new Error(`Missing DERIVATIVE_TYPE_TAGS for ${symbol}`);

  const tier = FUTURES_TIERS[symbol];
  const risk = TIER_PARAMS[tier];

  return generateFuturesMarkets({
    baseSymbol: symbol,
    collat: cfg.quote,
    // Futures contract size is independent from orderbook lot size; use 1e6 quote units per contract by default
    contractSize: 1_000_000,
    initialMarginBps: risk.initialMarginBps,
    maintenanceMarginBps: risk.maintenanceMarginBps,
    liquidationFeeBps: risk.liquidationFeeBps,
    keeperIncentiveBps: risk.keeperIncentiveBps,
    tickSize: cfg.tickSize,
    // Derivatives trade in contract counts; enforce lot/min = 1 contract
    lotSize: 1,
    minSize: 1,
    years,
    interval,
    expiryHourUTC: opts?.expiryHourUTC ?? 0,
    weeklyOn: opts?.weeklyOn,
    monthlyOnDay: opts?.monthlyOnDay,
    maxMarkets: opts?.maxMarkets,
    accountMaxNotional1e6: risk.accountMaxNotional1e6,
    marketMaxNotional1e6: risk.marketMaxNotional1e6,
    accountShareOfOiBps: risk.accountShareOfOiBps,
    liqTargetBufferBps: risk.liqTargetBufferBps,
  });
}

export function buildMainnetFuturesSet(): NonNullable<DeployConfig['futures']> {
  const fut_biweekly = [
    'BTC/USDC',
    'ETH/USDC',
    'SUI/USDC',
    'MATIC/USDC',
    'SOL/USDC',
  ].flatMap(sym => buildMainnetFuturesForSymbol(sym, 1, 'biweekly', { weeklyOn: 5, maxMarkets: 26, expiryHourUTC: 0 }));

  const fut_monthly = [
    'APT/USDC',
    'CELO/USDC',
    'GLMR/USDC',
    'DEEP/USDC',
    'IKA/USDC',
    'NS/USDC',
    'SEND/USDC',
    'WAL/USDC',
  ].flatMap(sym => buildMainnetFuturesForSymbol(sym, 1, 'monthly', { monthlyOnDay: 1, maxMarkets: 12, expiryHourUTC: 0 }));

  return [
    ...fut_biweekly,
    ...fut_monthly,
  ];
}

function buildTestnetFuturesForSymbol(symbol: string, years: number, interval: Interval, opts?: {
  weeklyOn?: number; monthlyOnDay?: number; maxMarkets?: number; expiryHourUTC?: number;
}) {
  const cfg = TESTNET_DERIVATIVE_TYPE_TAGS[symbol];
  if (!cfg) throw new Error(`Missing DERIVATIVE_TYPE_TAGS for ${symbol}`);

  const tier = FUTURES_TIERS[symbol];
  const risk = TIER_PARAMS[tier];

  return generateFuturesMarkets({
    baseSymbol: symbol,
    collat: cfg.quote,
    // Futures contract size independent of mapping lot size; use 1e6 quote units per contract by default
    contractSize: 1_000_000,
    initialMarginBps: risk.initialMarginBps,
    maintenanceMarginBps: risk.maintenanceMarginBps,
    liquidationFeeBps: risk.liquidationFeeBps,
    keeperIncentiveBps: risk.keeperIncentiveBps,
    tickSize: cfg.tickSize,
    // Derivatives trade in contract counts; enforce lot/min = 1 contract
    lotSize: 1,
    minSize: 1,
    years,
    interval,
    expiryHourUTC: opts?.expiryHourUTC ?? 0,
    weeklyOn: opts?.weeklyOn,
    monthlyOnDay: opts?.monthlyOnDay,
    maxMarkets: opts?.maxMarkets,
    accountMaxNotional1e6: risk.accountMaxNotional1e6,
    marketMaxNotional1e6: risk.marketMaxNotional1e6,
    accountShareOfOiBps: risk.accountShareOfOiBps,
    liqTargetBufferBps: risk.liqTargetBufferBps,
  });
}

export function buildTestnetFuturesSet(): NonNullable<DeployConfig['futures']> {
  const fut_biweekly = [
    'BTC/USDC',
    'ETH/USDC',
    'SUI/USDC',
    'MATIC/USDC',
    'SOL/USDC',
  ].flatMap(sym => buildTestnetFuturesForSymbol(sym, 1, 'biweekly', { weeklyOn: 5, maxMarkets: 26, expiryHourUTC: 0 }));

  const fut_monthly = [
    'APT/USDC',
    'CELO/USDC',
    'GLMR/USDC',
    'DEEP/USDC',
    'IKA/USDC',
    'NS/USDC',
    'SEND/USDC',
    'WAL/USDC',
  ].flatMap(sym => buildTestnetFuturesForSymbol(sym, 1, 'monthly', { monthlyOnDay: 1, maxMarkets: 12, expiryHourUTC: 0 }));

  return [
    ...fut_biweekly,
    ...fut_monthly,
  ];
}


