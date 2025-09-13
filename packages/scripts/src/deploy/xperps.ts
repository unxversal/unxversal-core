import { DERIVATIVE_SYMBOLS, FUTURES_TIERS, TIER_PARAMS, MAINNET_DERIVATIVE_TYPE_TAGS, TESTNET_DERIVATIVE_TYPE_TAGS, DERIVATIVE_PERP_FUT_SPECS } from './markets.js';

type XPerpSpec = {
  collat: string;
  symbol: string;
  contractSize: number;
  fundingIntervalMs: number;
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps: number;
  tickSize: number;
  lotSize: number;
  minSize: number;
  accountMaxNotional1e6?: string;
  marketMaxNotional1e6?: string;
  accountShareOfOiBps?: number;
  tierThresholds1e6?: number[];
  tierImBps?: number[];
  // Synthetic-specific
  initialMark1e6: number;
  ema?: { alphaNum?: number; alphaDen?: number; alphaLongNum?: number; alphaLongDen?: number; capMultipleBps?: number; markGateBps?: number };
};

const DEFAULT_PERP_TIER_THRESHOLDS_1E6 = [
  1_000_000_000_000,
  5_000_000_000_000,
  25_000_000_000_000,
  100_000_000_000_000,
  250_000_000_000_000,
];
const DEFAULT_PERP_TIER_IM_BPS = [250, 300, 500, 800, 1200];

const FUNDING_BY_TIER_MS: Record<'A'|'B'|'C'|'D', number> = {
  A: 3_600_000,
  B: 7_200_000,
  C: 28_800_000,
  D: 28_800_000,
};

export function buildMainnetXPerps(opts?: {
  initialMarks1e6?: Record<string, number>;
  ema?: XPerpSpec['ema'];
}): XPerpSpec[] {
  const out: XPerpSpec[] = [];
  for (const sym of DERIVATIVE_SYMBOLS) {
    const type = MAINNET_DERIVATIVE_TYPE_TAGS[sym];
    if (!type) continue;
    const tier = FUTURES_TIERS[sym];
    const risk = TIER_PARAMS[tier];
    const spec = DERIVATIVE_PERP_FUT_SPECS[sym] ?? { contractSize: 1_000_000, tickSize: 10_000, lotSize: 1, minSize: 1 };
    out.push({
      collat: type.quote,
      symbol: sym,
      contractSize: spec.contractSize,
      fundingIntervalMs: FUNDING_BY_TIER_MS[tier],
      initialMarginBps: risk.initialMarginBps,
      maintenanceMarginBps: risk.maintenanceMarginBps,
      liquidationFeeBps: risk.liquidationFeeBps,
      keeperIncentiveBps: risk.keeperIncentiveBps,
      tickSize: spec.tickSize,
      lotSize: spec.lotSize,
      minSize: spec.minSize,
      accountMaxNotional1e6: risk.accountMaxNotional1e6,
      marketMaxNotional1e6: risk.marketMaxNotional1e6,
      accountShareOfOiBps: risk.accountShareOfOiBps,
      tierThresholds1e6: DEFAULT_PERP_TIER_THRESHOLDS_1E6,
      tierImBps: DEFAULT_PERP_TIER_IM_BPS,
      initialMark1e6: opts?.initialMarks1e6?.[sym] ?? 1_000_000, // default $1.000000 bootstrap
      ema: opts?.ema,
    });
  }
  return out;
}

export function buildTestnetXPerps(opts?: {
  initialMarks1e6?: Record<string, number>;
  ema?: XPerpSpec['ema'];
}): XPerpSpec[] {
  const out: XPerpSpec[] = [];
  for (const sym of DERIVATIVE_SYMBOLS) {
    const type = TESTNET_DERIVATIVE_TYPE_TAGS[sym];
    if (!type) continue;
    const tier = FUTURES_TIERS[sym];
    const risk = TIER_PARAMS[tier];
    const spec = DERIVATIVE_PERP_FUT_SPECS[sym] ?? { contractSize: 1_000_000, tickSize: 10_000, lotSize: 1, minSize: 1 };
    out.push({
      collat: type.quote,
      symbol: sym,
      contractSize: spec.contractSize,
      fundingIntervalMs: FUNDING_BY_TIER_MS[tier],
      initialMarginBps: risk.initialMarginBps,
      maintenanceMarginBps: risk.maintenanceMarginBps,
      liquidationFeeBps: risk.liquidationFeeBps,
      keeperIncentiveBps: risk.keeperIncentiveBps,
      tickSize: spec.tickSize,
      lotSize: spec.lotSize,
      minSize: spec.minSize,
      accountMaxNotional1e6: risk.accountMaxNotional1e6,
      marketMaxNotional1e6: risk.marketMaxNotional1e6,
      accountShareOfOiBps: risk.accountShareOfOiBps,
      tierThresholds1e6: DEFAULT_PERP_TIER_THRESHOLDS_1E6,
      tierImBps: DEFAULT_PERP_TIER_IM_BPS,
      initialMark1e6: opts?.initialMarks1e6?.[sym] ?? 1_000_000,
      ema: opts?.ema,
    });
  }
  return out;
}


