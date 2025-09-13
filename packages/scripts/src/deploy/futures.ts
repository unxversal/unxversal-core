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
    // Downscaled contract size to target ~$10 notional per contract (approximate)
    contractSize: contractSizeForSymbol(symbol),
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
    // Downscaled contract size to target ~$10 notional per contract (approximate)
    contractSize: contractSizeForSymbol(symbol),
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

// Contract size = round(10_000_000 / spot_usd) => ~ $10 notional per contract
// Timestamp (America/Los_Angeles): 2025-09-13
function contractSizeForSymbol(symbol: string): number {
  switch (symbol) {
    // === Majors ===
    case 'BTC/USDC': return 90;
    case 'ETH/USDC': return 2_000;
    case 'SOL/USDC': return 50_000;

    // === L1s / High caps ===
    case 'WBNB/USDC': return 20_000;
    case 'SUI/USDC':  return 3_000_000;
    case 'MATIC/USDC':return 40_000_000;
    case 'APT/USDC':  return 3_000_000;
    case 'CELO/USDC': return 40_000_000;
    case 'GLMR/USDC': return 200_000_000;

    // === Popular alts ===
    case 'XRP/USDC':  return 4_000_000;
    case 'LINK/USDC': return 500_000;
    case 'LTC/USDC':  return 100_000;
    case 'AAVE/USDC': return 40_000;

    // === Long-tail / ambiguous tickers (fallbacks) ===
    case 'DEEP/USDC': return 10_000_000;
    case 'IKA/USDC':  return 50_000_000;
    case 'NS/USDC':   return 10_000_000;
    case 'SEND/USDC': return 100_000_000;
    case 'WAL/USDC':  return 10_000_000;

    // === The rest ===
    case 'HYPE/USDC': return 1_000_000_000;
    case 'PUMP/USDC': return 1_000_000_000;
    case 'ENA/USDC': return 20_000_000;
    case 'WLD/USDC': return 5_000_000;
    case 'DOGE/USDC': return 100_000_000;
    case 'WLFI/USDC': return 10_000_000;
    case 'LAUNCHCOIN/USDC': return 100_000_000;
    case 'ARB/USDC': return 10_000_000;
    case 'KAITO/USDC': return 20_000_000;
    case 'IP/USDC': return 10_000_000;
    case 'MNT/USDC': return 20_000_000;
    case 'UNI/USDC': return 2_000_000;
    case 'PYTH/USDC': return 20_000_000;
    case 'TIA/USDC': return 2_000_000;
    case 'TAO/USDC': return 20_000;
    case 'NEAR/USDC': return 2_000_000;
    case 'TRX/USDC': return 100_000_000;
    case 'XLM/USDC': return 100_000_000;
    case 'DOT/USDC': return 2_000_000;
    case 'XMR/USDC': return 100_000;
    case 'ICP/USDC': return 1_000_000;
    case 'FIL/USDC': return 2_000_000;
    case 'OP/USDC': return 5_000_000;
    case 'INJ/USDC': return 400_000;
    case 'PAXG/USDC': return 5_000;
    case 'LDO/USDC': return 5_000_000;
    case 'CAKE/USDC': return 5_000_000;
    case 'RENDER/USDC': return 1_500_000;
    case 'XAUt/USDC': return 5_000;
    case 'IMX/USDC': return 5_000_000;
    case 'PI/USDC': return 10_000_000;
    default: return 10_000_000;
  }
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


