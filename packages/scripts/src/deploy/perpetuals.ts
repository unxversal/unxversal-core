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
      contractSize: contractSizeForSymbol(sym),
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
      contractSize: contractSizeForSymbol(sym),
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

// Contract size = round(10_000_000 / spot_usd) => ~ $10 notional per contract
// Timestamp (America/Los_Angeles): 2025-09-13
function contractSizeForSymbol(symbol: string): number {
  switch (symbol) {
    // === Majors ===
    case 'BTC/USDC': return 90;          // rounded
    case 'ETH/USDC': return 2_000;       // rounded
    case 'SOL/USDC': return 50_000;      // rounded

    // === L1s / High caps ===
    case 'WBNB/USDC': return 20_000;     // rounded
    case 'SUI/USDC':  return 3_000_000;  // rounded
    case 'MATIC/USDC':return 40_000_000; // rounded
    case 'APT/USDC':  return 3_000_000;  // rounded
    case 'CELO/USDC': return 40_000_000; // rounded
    case 'GLMR/USDC': return 200_000_000;// rounded

    // === Popular alts ===
    case 'XRP/USDC':  return 4_000_000;  // rounded
    case 'LINK/USDC': return 500_000;    // rounded
    case 'LTC/USDC':  return 100_000;    // rounded
    case 'AAVE/USDC': return 40_000;     // rounded

    // === Long-tail / ambiguous tickers (fallbacks) ===
    case 'DEEP/USDC': return 10_000_000;
    case 'IKA/USDC':  return 50_000_000;
    case 'NS/USDC':   return 10_000_000;
    case 'SEND/USDC': return 100_000_000;
    case 'WAL/USDC':  return 10_000_000;

    // === The rest (kept approximations unless specified) ===
    case 'HYPE/USDC':    return 1_000_000_000;
    case 'PUMP/USDC':    return 1_000_000_000;
    case 'ENA/USDC':     return 20_000_000;
    case 'WLD/USDC':     return 5_000_000;
    case 'DOGE/USDC':    return 100_000_000;
    case 'WLFI/USDC':    return 10_000_000;
    case 'LAUNCHCOIN/USDC': return 100_000_000;
    case 'ARB/USDC':     return 10_000_000;
    case 'KAITO/USDC':   return 20_000_000;
    case 'IP/USDC':      return 10_000_000;
    case 'MNT/USDC':     return 20_000_000;
    case 'UNI/USDC':     return 2_000_000;
    case 'PYTH/USDC':    return 20_000_000;
    case 'TIA/USDC':     return 2_000_000;
    case 'TAO/USDC':     return 20_000;
    case 'NEAR/USDC':    return 2_000_000;
    case 'TRX/USDC':     return 100_000_000;
    case 'XLM/USDC':     return 100_000_000;
    case 'DOT/USDC':     return 2_000_000;
    case 'XMR/USDC':     return 100_000;
    case 'ICP/USDC':     return 1_000_000;
    case 'FIL/USDC':     return 2_000_000;
    case 'OP/USDC':      return 5_000_000;
    case 'INJ/USDC':     return 400_000;
    case 'PAXG/USDC':    return 5_000;
    case 'LDO/USDC':     return 5_000_000;
    case 'CAKE/USDC':    return 5_000_000;
    case 'RENDER/USDC':  return 1_500_000; // RNDR
    case 'XAUt/USDC':    return 5_000;
    case 'IMX/USDC':     return 5_000_000;
    case 'PI/USDC':      return 10_000_000;
    default: return 10_000_000;             // safe default for ~$1 assets
  }
}