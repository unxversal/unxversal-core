// Shared types for deploy-time configuration

import type { NetworkName } from '../config.js';

// Address like 0x + hex (we keep it loose for sanity)
export type SuiAddress = `0x${string}`;

// Basic (no strict check on identifiers or generics)
export type SuiTypeTag =
  `${SuiAddress}::${string}::${string}` |
  `${SuiAddress}::${string}::${string}<${string}>`;

export type Tier = 'A' | 'B' | 'C' | 'D';

export type RiskParams = {
  initialMarginBps: number;
  maintenanceMarginBps: number;
  liquidationFeeBps: number;
  keeperIncentiveBps: number;
  accountMaxNotional1e6: string;
  marketMaxNotional1e6: string;
  accountShareOfOiBps: number;
  liqTargetBufferBps: number;
};

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
    adminRegistryId?: string;   // defaults to global adminRegistryId
    tickSize: number; lotSize: number; minSize: number;
  }>;
  vaults?: Array<{
    asset: SuiTypeTag;
    caps?: { maxOrderSizeBase?: number; maxInventoryTiltBps?: number; minDistanceBps?: number; paused?: boolean };
  }>;
};


