import type { NetworkName } from '../config.js';
import type { FuturesMarketSpec, Interval } from './series.js';
import { generateFuturesMarkets, generateGasFuturesMarkets } from './series.js';
import { buildAllOptionSeriesForFeeds, type Series, type Policy } from '../utils/series.js';

// Address like 0x + hex (we keep it loose for sanity)
export type SuiAddress = `0x${string}`;

// Basic (no strict check on identifiers or generics)
export type SuiTypeTag =
  `${SuiAddress}::${string}::${string}` |               // e.g. 0x2::sui::SUI
  `${SuiAddress}::${string}::${string}<${string}>`;     // e.g. 0x2::coin::Coin<0x2::sui::SUI>

/**
 * List of supported derivative symbols for which options series and policies are generated.
 * These should match the keys in the POLICIES object in utils/series.ts.
 */
const DERIVATIVE_SYMBOLS: string[] = [
  'BTC/USDC',
  'ETH/USDC',
  'SOL/USDC',
  'WBNB/USDC',
  'SUI/USDC',
  'MATIC/USDC',
  'APT/USDC',
  'CELO/USDC',
  'GLMR/USDC',
  'DEEP/USDC',
  'IKA/USDC',
  'NS/USDC',
  'SEND/USDC',
  'WAL/USDC',
];

const POLICIES: Record<string, Policy> = {
  // Majors
  'BTC/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 500, cadence: 'weekly', years: 2 },
  'ETH/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 25,  cadence: 'weekly', years: 2 },

  // L1s / high caps
  'SOL/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.5, cadence: 'weekly', years: 2 },
  'WBNB/USDC': { bandLow: 0.6, bandHigh: 1.8, stepAbs: 1,   cadence: 'weekly', years: 2 },
  'SUI/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.01, cadence: 'weekly', years: 2 },
  'MATIC/USDC':{ bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.02, cadence: 'weekly', years: 2 },
  'APT/USDC':  { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.05, cadence: 'weekly', years: 2 },
  'CELO/USDC': { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.02, cadence: 'weekly', years: 2 },
  'GLMR/USDC': { bandLow: 0.5, bandHigh: 2.0, stepAbs: 0.02, cadence: 'weekly', years: 2 },

  // Long tail / ecosystem
  'DEEP/USDC': { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'IKA/USDC':  { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'NS/USDC':   { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'SEND/USDC': { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },
  'WAL/USDC':  { bandLow: 0.4, bandHigh: 2.5, stepPct: 0.02, cadence: 'weekly', years: 2 },

};

/**
 * Mapping of derivative symbols to their base and quote type tags.
 * Used for options, futures, and other derivative markets.
 */
const DERIVATIVE_TYPE_TAGS: Record<string, {
  base: SuiTypeTag;
  quote: SuiTypeTag;
  tickSize: number;   // Minimum price increment (USD 1e6 scale)
  lotSize: number;    // Contract size in base asset units (integer in baseDecimals)
  minSize: number;    // Minimum order size (usually = lotSize)
  baseDecimals: number;
  quoteDecimals: number;
}> = {
  // -----------------
  // Majors
  // -----------------
  'BTC/USDC': {
    base: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,             // $0.01
    lotSize: 10_000_000,            // 0.1 BTC (~$10k notional)
    minSize: 10_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'ETH/USDC': {
    base: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,             // $0.01
    lotSize: 200_000_000,          // 2 ETH (~$10k notional)
    minSize: 200_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },

  // -----------------
  // L1s / High Caps
  // -----------------
  'SOL/USDC': {
    base: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,             // $0.01
    lotSize: 4_000_000_000,        // 4 SOL (~$10k notional)
    minSize: 4_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
    'WBNB/USDC': {
    base: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 1_000_000_000,        // 10 BNB (~$10k notional)
    minSize: 1_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'SUI/USDC': {
    base: '0x2::sui::SUI',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 2_000_000_000_000,       // 2,000 SUI (~$10k notional)
    minSize: 2_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
    'MATIC/USDC': {
    base: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 3_000_000_000_000,    // 30,000 MATIC (~$10k notional)
    minSize: 3_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'APT/USDC': {
    base: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 2_000_000_000_000,    // 2,000 APT (~$10k notional)
    minSize: 2_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'CELO/USDC': {
    base: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 3_000_000_000_000,    // 30,000 CELO (~$10k notional)
    minSize: 3_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },
  'GLMR/USDC': {
    base: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 14_000_000_000_000,   // 140,000 GLMR (~$10k notional)
    minSize: 14_000_000_000_000,
    baseDecimals: 8,
    quoteDecimals: 6,
  },

  // -----------------
  // Long-Tail / Ecosystem
  // -----------------
  'DEEP/USDC': {
    base: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,       // 10,000 DEEP (~$10k notional)
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
    'IKA/USDC': {
    base: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 20_000_000_000_000,  // 20,000 IKA (~$10k notional)
    minSize: 20_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
  'NS/USDC': {
    base: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,       // 1,000 NS (~$10k notional)
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
  'SEND/USDC': {
    base: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f::send::SEND',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000,       // 10,000 SEND (~$10k notional)
    minSize: 10_000_000_000,
    baseDecimals: 6,
    quoteDecimals: 6,
  },
    'WAL/USDC': {
    base: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL',
    quote: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
    tickSize: 10_000,
    lotSize: 10_000_000_000_000,   // 10,000 WAL (~$10k notional)
    minSize: 10_000_000_000_000,
    baseDecimals: 9,
    quoteDecimals: 6,
  },
};

const optionsSeries: Record<string, Series[]> = await buildAllOptionSeriesForFeeds(DERIVATIVE_SYMBOLS, POLICIES)


type Tier = 'A'|'B'|'C'|'D';

const FUTURES_TIERS: Record<string, Tier> = {
  'BTC/USDC': 'A',
  'ETH/USDC': 'A',
  'SOL/USDC': 'A',
  'WBNB/USDC': 'A',
  'SUI/USDC': 'A',
  'MATIC/USDC': 'A',
  'APT/USDC': 'B',
  'CELO/USDC': 'C',
  'GLMR/USDC': 'C',
  'DEEP/USDC': 'C',
  'IKA/USDC': 'C',
  'NS/USDC': 'C',
  'SEND/USDC': 'C',
  'WAL/USDC': 'C',
};

const TIER_PARAMS: Record<Tier, Pick<FuturesMarketSpec,
  'initialMarginBps' | 'maintenanceMarginBps' | 'liquidationFeeBps' | 'keeperIncentiveBps' |
  'accountMaxNotional1e6' | 'marketMaxNotional1e6' | 'accountShareOfOiBps' | 'liqTargetBufferBps'
>> = {
  A: {
    initialMarginBps: 500,                // Initial margin requirement in basis points (5%)
    maintenanceMarginBps: 300,            // Maintenance margin requirement in basis points (3%)
    liquidationFeeBps: 50,                // Liquidation fee in basis points (0.5%)
    keeperIncentiveBps: 5000,             // Keeper incentive in basis points (50%)
    accountMaxNotional1e6: '50_000_000_000_000',   // Max notional per account (1e6 scale, e.g. $50M)
    marketMaxNotional1e6: '5_000_000_000_000_000',   // Max notional per market (1e6 scale, e.g. $5B)
    accountShareOfOiBps: 500,              // Max % of open interest per account in basis points (5%)
    liqTargetBufferBps: 500,              // Liquidation target buffer in basis points (5%)
  },
  B: {
    initialMarginBps: 600,                // Initial margin requirement in basis points (6%)
    maintenanceMarginBps: 400,            // Maintenance margin requirement in basis points (4%)
    liquidationFeeBps: 50,                // Liquidation fee in basis points (0.5%)
    keeperIncentiveBps: 5000,             // Keeper incentive in basis points (10%)
    accountMaxNotional1e6: '20_000_000_000_000',   // Max notional per account (1e6 scale, e.g. $20M)
    marketMaxNotional1e6: '1_000_000_000_000_000',   // Max notional per market (1e6 scale, e.g. $1000M)
    accountShareOfOiBps: 600,              // Max % of open interest per account in basis points (6%)
    liqTargetBufferBps: 500,              // Liquidation target buffer in basis points (5%)
  },
  C: {
    initialMarginBps: 800,                // Initial margin requirement in basis points (8%)
    maintenanceMarginBps: 500,            // Maintenance margin requirement in basis points (5%)
    liquidationFeeBps: 100,                // Liquidation fee in basis points (0.75%)
    keeperIncentiveBps: 5000,             // Keeper incentive in basis points (10%)
    accountMaxNotional1e6: '5_000_000_000_000',    // Max notional per account (1e6 scale, e.g. $5M)
    marketMaxNotional1e6: '500_000_000_000_000',    // Max notional per market (1e6 scale, e.g. $500M)
    accountShareOfOiBps: 800,              // Max % of open interest per account in basis points (8%)
    liqTargetBufferBps: 500,              // Liquidation target buffer in basis points (5%)
  },
  D: {
    initialMarginBps: 1200,               // Initial margin requirement in basis points (12%)
    maintenanceMarginBps: 800,            // Maintenance margin requirement in basis points (8%)
    liquidationFeeBps: 100,               // Liquidation fee in basis points (1%)
    keeperIncentiveBps: 5000,             // Keeper incentive in basis points (10%)
    accountMaxNotional1e6: '1_000_000_000_000',    // Max notional per account (1e6 scale, e.g. $1M)
    marketMaxNotional1e6: '10_000_000_000_000',    // Max notional per market (1e6 scale, e.g. $10M)
    accountShareOfOiBps: 1000,             // Max % of open interest per account in basis points (10%)
    liqTargetBufferBps: 500,              // Liquidation target buffer in basis points (5%)
  },
};

// Helper to assemble per-symbol futures markets using your schedule builder.
function buildFuturesForSymbol(symbol: string, years: number, interval: Interval, opts?: {
  weeklyOn?: number; monthlyOnDay?: number; maxMarkets?: number; expiryHourUTC?: number;
}) {
  const cfg = DERIVATIVE_TYPE_TAGS[symbol];
  if (!cfg) throw new Error(`Missing DERIVATIVE_TYPE_TAGS for ${symbol}`);

  const tier = FUTURES_TIERS[symbol];
  const risk = TIER_PARAMS[tier];

  return generateFuturesMarkets({
    baseSymbol: symbol,
    collat: cfg.quote,                   // quote coin as collateral (USDC)
    contractSize: cfg.lotSize,          // 1 contract = 1 lot of base
    initialMarginBps: risk.initialMarginBps,
    maintenanceMarginBps: risk.maintenanceMarginBps,
    liquidationFeeBps: risk.liquidationFeeBps,
    keeperIncentiveBps: risk.keeperIncentiveBps,
    tickSize: cfg.tickSize,
    lotSize: cfg.lotSize,
    minSize: cfg.minSize,
    years,
    interval,
    expiryHourUTC: opts?.expiryHourUTC ?? 0,
    weeklyOn: opts?.weeklyOn,
    monthlyOnDay: opts?.monthlyOnDay,
    maxMarkets: opts?.maxMarkets,
    // Risk caps — leave tiered IM to Move defaults; these are coarse caps:
    accountMaxNotional1e6: risk.accountMaxNotional1e6,
    marketMaxNotional1e6: risk.marketMaxNotional1e6,
    accountShareOfOiBps: risk.accountShareOfOiBps,
    liqTargetBufferBps: risk.liqTargetBufferBps,
    // Optional: keep these undefined unless you want to override on-chain defaults
    // tierThresholds1e6: [...],
    // tierImBps: [...],
  });
}

// Build sets:
// - BTC/ETH: weekly Fridays for ~6 months (max 26)
// - Others: monthly on day 1 for ~12 months

const fut_biweekly = [
  'BTC/USDC',
  'ETH/USDC',
  'SUI/USDC',
  'MATIC/USDC',
  'SOL/USDC',
].flatMap(sym => buildFuturesForSymbol(sym, 1, 'biweekly',   { weeklyOn: 5, maxMarkets: 26, expiryHourUTC: 0 }));

const fut_monthly = [
  'APT/USDC',
  'CELO/USDC',
  'GLMR/USDC',
  'DEEP/USDC',
  'IKA/USDC',
  'NS/USDC',
  'SEND/USDC',
  'WAL/USDC',
].flatMap(sym => buildFuturesForSymbol(sym, 1, 'monthly', { monthlyOnDay: 1, maxMarkets: 12, expiryHourUTC: 0 }));

const gasSet = generateGasFuturesMarkets({
  collat: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',

  // Choose contractSize so: per-contract notional (MIST) = price_1e6 × contractSize / 1_000_000
  // If reference gas price ≈ 1,000 MIST, set contractSize = 1_000_000 ⇒ ~1,000 MIST per contract.
  contractSize: 1_000_000,

  initialMarginBps: 1000,
  maintenanceMarginBps: 600,
  liquidationFeeBps: 100,
  keeperIncentiveBps: 5000,

  // 1-price-tick = 1 MIST (gas price is integral MIST)
  tickSize: 1,

  // Let users trade single contracts
  lotSize: 1,
  minSize: 1,

  years: 1,
  interval: 'weekly',
  weeklyOn: 5,       // Fridays
  expiryHourUTC: 0,
  maxMarkets: 6,

  // Extra safety buffer above IM during liquidation
  liqTargetBufferBps: 100,
});

export type DeployConfig = {
  network: NetworkName;
  pkgId: string;
  adminRegistryId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  usduFaucetId?: string;
  oracleRegistryId?: string;
  additionalAdmins?: string[];
  feeParams?: {
    dexFeeBps: number;
    unxvDiscountBps: number;
    preferDeepBackend: boolean;
    stakersShareBps: number;
    treasuryShareBps: number;
    burnShareBps: number;
    treasury: string;
  };
  /** Optional: configure staking tiers (thresholds/discount bps) */
  feeTiers?: {
    t1: number; b1: number;
    t2: number; b2: number;
    t3: number; b3: number;
    t4: number; b4: number;
    t5: number; b5: number;
    t6: number; b6: number;
  };
  /** Optional: set lending fee and collateral bonus caps */
  lendingParams?: { borrowFeeBps: number; collateralBonusMaxBps: number };
  /** Optional: set UNXV amount charged for permissionless pool creation */
  poolCreationFeeUnxv?: number;
  tradeFees?: {
    dex?: { takerBps: number; makerBps: number };
    futures?: { takerBps: number; makerBps: number };
    gasFutures?: { takerBps: number; makerBps: number };
  };
  oracleFeeds?: Array<{ symbol: string; priceId: string }>;
  oracleMaxAgeSec?: number;
  usdu?: { perAddressLimit?: number; paused?: boolean };
  /**
   * Initialize dual-asset lending markets (Collateral → Debt)
   */
  lendingMarkets?: Array<{
    marketId?: string;
    collat: SuiTypeTag;
    debt: SuiTypeTag;
    symbol: string;
    baseRateBps: number;
    multiplierBps: number;
    jumpMultiplierBps: number;
    kinkUtilBps: number;
    reserveFactorBps: number;
    collateralFactorBps: number;
    liquidationThresholdBps: number;
    liquidationBonusBps: number;
  }>;
  options?: Array<{
    marketId?: string;
    base: SuiTypeTag;
    quote: SuiTypeTag;
    tickSize: number;
    lotSize: number;
    minSize: number;
    baseDecimals: number;
    quoteDecimals: number;
    series: Array<{ expiryMs: number; strike1e6: number; isCall: boolean; symbol: string }>;
  }>;
  futures?: Array<{
    marketId?: string;
    collat: SuiTypeTag;
    symbol: string;
    expiryMs: number;
    contractSize: number;
    initialMarginBps: number;
    maintenanceMarginBps: number;
    liquidationFeeBps: number;
    keeperIncentiveBps?: number;
    // Orderbook params (required by on-chain init)
    tickSize: number;
    lotSize: number;
    minSize: number;
    // New risk controls
    accountMaxNotional1e6?: string; // use string to avoid JS precision issues
    marketMaxNotional1e6?: string;
    accountShareOfOiBps?: number;
    // Tiered IM
    tierThresholds1e6?: number[];
    tierImBps?: number[];
    // Optional admin knobs
    closeOnly?: boolean;
    maxDeviationBps?: number;
    pnlFeeShareBps?: number;
    liqTargetBufferBps?: number;
    imbalanceParams?: { surchargeMaxBps: number; thresholdBps: number };
  }>;
  gasFutures?: Array<{
    marketId?: string;
    collat: SuiTypeTag;
    expiryMs: number;
    contractSize: number;
    initialMarginBps: number;
    maintenanceMarginBps: number;
    liquidationFeeBps: number;
    keeperIncentiveBps?: number;
    // Orderbook params (required by on-chain init)
    tickSize: number;
    lotSize: number;
    minSize: number;
    // New risk controls
    accountMaxNotional1e6?: string;
    marketMaxNotional1e6?: string;
    accountShareOfOiBps?: number;
    tierThresholds1e6?: number[];
    tierImBps?: number[];
    // Optional admin knobs
    closeOnly?: boolean;
    maxDeviationBps?: number;
    pnlFeeShareBps?: number;
    liqTargetBufferBps?: number;
    imbalanceParams?: { surchargeMaxBps: number; thresholdBps: number };
  }>;
  perpetuals?: Array<{
    marketId?: string;
    collat: SuiTypeTag;
    symbol: string;
    contractSize: number;
    fundingIntervalMs: number;
    initialMarginBps: number;
    maintenanceMarginBps: number;
    liquidationFeeBps: number;
    keeperIncentiveBps?: number;
    // Orderbook params (required by on-chain init)
    tickSize: number;
    lotSize: number;
    minSize: number;
    // New risk controls (optional future parity)
    accountMaxNotional1e6?: string;
    marketMaxNotional1e6?: string;
    accountShareOfOiBps?: number;
    tierThresholds1e6?: number[];
    tierImBps?: number[];
  }>;
  dexPools?: Array<{
    registryId: string;
    base: SuiTypeTag;
    quote: SuiTypeTag;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    unxvFeeCoinId: string;
    tickSize: number; lotSize: number; minSize: number;
  }>;
  vaults?: Array<{
    asset: SuiTypeTag;
    caps?: { maxOrderSizeBase?: number; maxInventoryTiltBps?: number; minDistanceBps?: number; paused?: boolean };
  }>;
};

export const deployConfig: DeployConfig = {
  network: 'testnet',
  pkgId: '',
  adminRegistryId: '',
  feeConfigId: '',
  feeVaultId: '',
  stakingPoolId: '',
  usduFaucetId: '',
  oracleRegistryId: '',
  additionalAdmins: [
    "0x24945081376e008971b437092ebd3de139bb478fc9501c1101fed02f3a2f4fb0",
    "0x283d357de0dd9478563cf440227100f381cea0bbc8d84110c6d2a55483b509a2"
  ],
  feeParams: undefined,
  feeTiers: undefined,
  lendingParams: undefined,
  poolCreationFeeUnxv: undefined,
  tradeFees: undefined,
  oracleFeeds: [
    { symbol: 'SUI/USDC', priceId: '0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744' },
    { symbol: 'DEEP/USDC', priceId: '0x29bdd5248234e33bd93d3b81100b5fa32eaa5997843847e2c2cb16d7c6d9f7ff' },
    { symbol: 'ETH/USDC', priceId: '0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace' },
    { symbol: 'BTC/USDC', priceId: '0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43' },
    { symbol: 'SOL/USDC', priceId: '0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d' },
    { symbol: 'GLMR/USDC', priceId: '0x309d39a65343d45824f63dc6caa75dbf864834f48cfaa6deb122c62239e06474' },
    { symbol: 'MATIC/USDC', priceId: '0xffd11c5a1cfd42f80afb2df4d9f264c15f956d68153335374ec10722edd70472' },
    { symbol: 'APT/USDC', priceId: '0x03ae4db29ed4ae33d323568895aa00337e658e348b37509f5372ae51f0af00d5' },
    { symbol: 'CELO/USDC', priceId: '0x7d669ddcdd23d9ef1fa9a9cc022ba055ec900e91c4cb960f3c20429d4447a411' },
    { symbol: 'IKA/USDC', priceId: '0x2b529621fa6e2c8429f623ba705572aa64175d7768365ef829df6a12c9f365f4' },
    { symbol: 'NS/USDC', priceId: '0xbb5ff26e47a3a6cc7ec2fce1db996c2a145300edc5acaabe43bf9ff7c5dd5d32' },
    { symbol: 'SEND/USDC', priceId: '0x7d19b607c945f7edf3a444289c86f7b58dcd8b18df82deadf925074807c99b59' },
    { symbol: 'WAL/USDC', priceId: '0xeba0732395fae9dec4bae12e52760b35fc1c5671e2da8b449c9af4efe5d54341' },
    { symbol: 'USDT/USDC', priceId: '0x2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b' },
    { symbol: 'WBNB/USDC', priceId: '0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f' },
  ],
  oracleMaxAgeSec: 5,
  usdu: undefined,
  lendingMarkets: [
    // Blue-chip assets
    {
      symbol: 'SUI/USDC',
      collat: '0x2::sui::SUI',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'DEEP/USDC',
      collat: '0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'suiETH/USDC',
      collat: '0xd0e89b2af5e4910726fbcd8b8dd37bb79b29e5f83f7491bca830e94f7f226d29::eth::ETH',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'suiBTC/USDC',
      collat: '0xaafb102dd0902f5055cadecd687fb5b71ca82ef0e0285d90afde828ec58ca96b::btc::BTC',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WBTC/USDC',
      collat: '0x027792d9fed7f9844eb4839566001bb6f6cb4804f66aa2da6fe1ee242d896881::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WETH/USDC',
      collat: '0xaf8cd5edc19c4512f4259f0bee101a40d41ebed738ade5874359610ef8eeced5::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WAVAX/USDC',
      collat: '0x1e8b532cca6569cab9f9b9ebc73f8c13885012ade714729aa3b450e0339ac766::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WBNB/USDC',
      collat: '0xb848cce11ef3a8f62eccea6eb5b35a12c4c2b1ee1af7755d02d7bd6218e8226f::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WGLMR/USDC',
      collat: '0x66f87084e49c38f76502d17f87d17f943f183bb94117561eb573e075fdc5ff75::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WMATIC/USDC',
      collat: '0xdbe380b13a6d0f5cdedd58de8f04625263f113b3f9db32b3e1983f49e2841676::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WSOL/USDC',
      collat: '0xb7844e289a8410e50fb3ca48d69eb9cf29e27d223ef90353fe1bd8e27ff8f3f8::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'XBTC/USDC',
      collat: '0x876a4b7bce8aeaef60464c11f4026903e9afacab79b9b142686158aa86560b50::xbtc::XBTC',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'APT/USDC',
      collat: '0x3a5143bb1196e3bcdfab6203d1683ae29edd26294fc8bfeafe4aaa9d2704df37::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'CELO/USDC',
      collat: '0xa198f3be41cda8c07b3bf3fee02263526e535d682499806979a111e88a5a8d0f::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'IKA/USDC',
      collat: '0x7262fb2f7a3a14c888c438a3cd9b912469a58cf60f367352c46584262e8299aa::ika::IKA',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'NS/USDC',
      collat: '0x5145494a5f5100e645e4b0aa950fa6b68f614e8c59e17bc5ded3495123a79178::ns::NS',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'SEND/USDC',
      collat: '0x4e9d6f1c3d3f6b8e2c1c3f4e5d6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f::send::SEND',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    {
      symbol: 'WAL/USDC',
      collat: '0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 1000,
      jumpMultiplierBps: 4500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 7000,
      liquidationThresholdBps: 8500,
      liquidationBonusBps: 4000,
    },
    // Stablecoins
    {
      symbol: 'Wrapped USDT/USDC',
      collat: '0xc060006111016b8a020ad5b33834984a437aaa7d3c74c18e09a95d48aceab08c::coin::COIN',
      debt: '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC',
      baseRateBps: 50,
      multiplierBps: 800,
      jumpMultiplierBps: 3500,
      kinkUtilBps: 8000,
      reserveFactorBps: 2000,
      collateralFactorBps: 8500,
      liquidationThresholdBps: 9200,
      liquidationBonusBps: 4000,
    },
  ],
  options: Object.entries(optionsSeries).map(([symbol, series]) => {
    const config = DERIVATIVE_TYPE_TAGS[symbol];
    if (!config) {
      throw new Error(`No type configuration found for symbol: ${symbol}`);
    }

    return {
      base: config.base,
      quote: config.quote,
      tickSize: config.tickSize,
      lotSize: config.lotSize,
      minSize: config.minSize,
      baseDecimals: config.baseDecimals,
      quoteDecimals: config.quoteDecimals,
      series,
    };
  }),
  futures: [
    ...fut_biweekly,
    ...fut_monthly,
  ],
  gasFutures: [
    ...gasSet,
  ],
  perpetuals: [],
  dexPools: [],
  vaults: [],
};
