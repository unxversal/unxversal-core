export type PriceSource = 'mid' | 'oracle' | 'twap';

export type StaticRangeConfig = {
  priceSource: PriceSource;
  bandBps: number;              // ± band in bps
  levelsPerSide: number;        // number of ticks per side
  stepBps: number;              // spacing between ticks
  perLevelQuoteNotional: number;// quote units per level
  recenterDriftBps: number;     // recenter when drift exceeds this
  refreshSecs: number;          // keeper refresh cadence
};

export type StrategyConfig = {
  kind: 'static-range' | 'amm-overlay' | 'vol-adaptive' | 'inventory-skew' | 'pairing' | 'trend' | 'oracle-anchored' | 'time-regime' | 'delta-hedged-maker' | 'covered-calls' | 'cash-secured-puts' | 'options-vol-seller' | 'options-calendar-diagonal';
  dex: {
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
    feeConfigId: string;
    feeVaultId: string;
    deepbookIndexerUrl: string;
  };
  staticRange: StaticRangeConfig;
  ammOverlay?: {
    bandBps: number;
    levelsPerSide: number;
    stepBps: number;
    baseGeometricFactor: number; // e.g., 1.05
    perLevelQuoteNotional: number;
    refreshSecs: number;
  };
  timeRegime?: {
    // Selects a regime by local time-of-day seconds in [0, 86400)
    // The first matching window is applied.
    regimes: Array<{
      startSeconds: number;      // inclusive, 0-86399
      endSeconds: number;        // exclusive, 1-86400
      bandBps: number;
      stepBps: number;
      levelsPerSide: number;
      perLevelQuoteNotional: number;
    }>;
    refreshSecs: number;
  };
  volAdaptive?: {
    k: number;                 // band = k*sigma
    minBandBps: number;
    maxBandBps: number;
    stepBps: number;
    perLevelQuoteNotional: number;
    lookbackMinutes: number;
    refreshSecs: number;
  };
  inventorySkew?: {
    targetPctBase: number;     // 0-100
    slopeBpsPerPct: number;    // shift center per pct deviation
    maxShiftBps: number;
    bandBps: number;
    levelsPerSide: number;
    stepBps: number;
    perLevelQuoteNotional: number;
    refreshSecs: number;
  };
  pairing?: {
    takeProfitBps: number;     // TP offset
    maxConcurrent: number;
    refreshSecs: number;
  };
  trend?: {
    emaFast: number;           // periods
    emaSlow: number;
    bandBps: number;
    stepFastBps: number;       // tighter asks in uptrend / bids in downtrend
    stepSlowBps: number;
    perLevelQuoteNotional: number;
    levelsPerSide: number;
    refreshSecs: number;
  };
  oracleAnchored?: {
    maxDeviationBps: number;   // pause/widen if |mid-oracle| too large
    bandBps: number;
    stepBps: number;
    perLevelQuoteNotional: number;
    levelsPerSide: number;
    refreshSecs: number;
  };
  deltaHedgedMaker?: {
    // Spot maker ladder params
    bandBps: number;
    levelsPerSide: number;
    stepBps: number;
    perLevelQuoteNotional: number;
    refreshSecs: number;
    // Perps hedge wiring
    perps: {
      pkg: string;
      marketId: string;
      oracleRegistryId: string;
      aggregatorId: string;
      feeConfigId: string;
      feeVaultId: string;
      stakingPoolId: string;
      // hedge when |delta| > toleranceQty
      toleranceQty: number;
      // max hedge per action to avoid bursts
      maxHedgeQtyPerAction: number;
    };
  };
};

export type OptionsBaseConfig = {
  pkg: string;
  marketId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
};

export type CoveredCallsConfig = OptionsBaseConfig & {
  // sell call series keys and notional per key (quote premium target per order)
  callSeriesKeys: bigint[];
  perOrderQty: bigint;
  limitPremiumQuote: bigint;
  expireSecDelta: number; // seconds from now
  refreshSecs: number;
};

export type CashSecuredPutsConfig = OptionsBaseConfig & {
  putSeriesKeys: bigint[];
  perOrderQty: bigint;
  limitPremiumQuote: bigint;
  expireSecDelta: number;
  refreshSecs: number;
};

export type OptionsVolSellerConfig = OptionsBaseConfig & {
  seriesKeys: bigint[];       // ATM or target delta keys
  perOrderQty: bigint;
  limitPremiumQuote: bigint;
  expireSecDelta: number;
  refreshSecs: number;
  // Perps delta hedge wiring reused from deltaHedgedMaker if needed later
};

export type OptionsCalendarDiagonalConfig = OptionsBaseConfig & {
  frontSeriesKeys: bigint[];  // short leg
  backSeriesKeys: bigint[];   // long leg
  ratioBP: number;            // e.g., 10000 for 1:1, 5000 for 1:0.5
  perOrderQty: bigint;        // base units for short leg; long leg = qty * ratio
  limitPremiumQuoteShort: bigint;
  limitPremiumQuoteLong: bigint;
  expireSecDeltaFront: number;
  expireSecDeltaBack: number;
  refreshSecs: number;
};

export type OptionsGammaScalperConfig = OptionsBaseConfig & {
  seriesKeys: bigint[];
  perOrderQty: bigint;
  limitPremiumQuoteBuy: bigint;   // buy options to acquire gamma
  limitPremiumQuoteSell: bigint;  // take-profit seller for scalps
  expireSecDelta: number;
  refreshSecs: number;
};

export type OptionsSkewArbConfig = OptionsBaseConfig & {
  callKeys: bigint[];
  putKeys: bigint[];
  perOrderQty: bigint;
  limitPremiumQuoteCall: bigint;
  limitPremiumQuotePut: bigint;
  refreshSecs: number;
};


