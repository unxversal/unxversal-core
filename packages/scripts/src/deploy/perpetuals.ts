import type { DeployConfig, Tier } from './types.js';
import { DERIVATIVE_SYMBOLS, FUTURES_TIERS, TIER_PARAMS, MAINNET_DERIVATIVE_TYPE_TAGS, TESTNET_DERIVATIVE_TYPE_TAGS } from './markets.js';

const DEFAULT_PERP_TIER_THRESHOLDS_1E6 = [
  1_000_000_000_000,
  5_000_000_000_000,
  25_000_000_000_000,
  100_000_000_000_000,
  250_000_000_000_000,
];
const DEFAULT_PERP_TIER_IM_BPS = [250, 300, 500, 800, 1200];

const FUNDING_BY_TIER_MS: Record<Tier, number> = {
  A: 3_600_000,
  B: 7_200_000,
  C: 28_800_000,
  D: 28_800_000,
};

export function buildMainnetPerpetuals(): NonNullable<DeployConfig['perpetuals']> {
  return DERIVATIVE_SYMBOLS.map((sym) => {
    const t = FUTURES_TIERS[sym];
    const cfg = MAINNET_DERIVATIVE_TYPE_TAGS[sym];
    const risk = TIER_PARAMS[t];
    return {
      collat: cfg.quote,
      symbol: sym,
      contractSize: cfg.lotSize,
      fundingIntervalMs: FUNDING_BY_TIER_MS[t],
      initialMarginBps: risk.initialMarginBps,
      maintenanceMarginBps: risk.maintenanceMarginBps,
      liquidationFeeBps: risk.liquidationFeeBps,
      keeperIncentiveBps: risk.keeperIncentiveBps,
      tickSize: cfg.tickSize,
      lotSize: 1,
      minSize: 1,
      accountMaxNotional1e6: risk.accountMaxNotional1e6,
      marketMaxNotional1e6: risk.marketMaxNotional1e6,
      accountShareOfOiBps: risk.accountShareOfOiBps,
      tierThresholds1e6: DEFAULT_PERP_TIER_THRESHOLDS_1E6,
      tierImBps: DEFAULT_PERP_TIER_IM_BPS,
    } as const;
  });
}

export function buildTestnetPerpetuals(): NonNullable<DeployConfig['perpetuals']> {
  return DERIVATIVE_SYMBOLS.map((sym) => {
    const t = FUTURES_TIERS[sym];
    const cfg = TESTNET_DERIVATIVE_TYPE_TAGS[sym];
    const risk = TIER_PARAMS[t];
    return {
      collat: cfg.quote,
      symbol: sym,
      contractSize: cfg.lotSize,
      fundingIntervalMs: FUNDING_BY_TIER_MS[t],
      initialMarginBps: risk.initialMarginBps,
      maintenanceMarginBps: risk.maintenanceMarginBps,
      liquidationFeeBps: risk.liquidationFeeBps,
      keeperIncentiveBps: risk.keeperIncentiveBps,
      tickSize: cfg.tickSize,
      lotSize: 1,
      minSize: 1,
      accountMaxNotional1e6: risk.accountMaxNotional1e6,
      marketMaxNotional1e6: risk.marketMaxNotional1e6,
      accountShareOfOiBps: risk.accountShareOfOiBps,
      tierThresholds1e6: DEFAULT_PERP_TIER_THRESHOLDS_1E6,
      tierImBps: DEFAULT_PERP_TIER_IM_BPS,
    } as const;
  });
}