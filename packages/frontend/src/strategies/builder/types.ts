export type PriceSourceBlock = { type: 'price'; source: 'mid' | 'oracle' | 'twap'; twapSecs?: number };
export type VolatilityBlock = { type: 'vol'; estimator: 'stdev' | 'atr'; lookbackMins: number; capBps?: number };
export type LadderBlock = {
  type: 'ladder';
  bandPolicy: { kind: 'fixed'; bps: number } | { kind: 'sigma'; k: number; minBps: number; maxBps: number };
  levelsPerSide: number;
  stepBps: number;
  sizePolicy: { kind: 'equal_notional'; perLevelQuote: number } | { kind: 'equal_base'; perLevelBase: number };
};
export type SkewBlock = { type: 'skew'; targetPctBase: number; slopeBpsPerPct: number; maxShiftBps: number };
export type RecenterBlock = { type: 'recenter'; timeSecs?: number; driftBps?: number; breakout?: boolean };
export type RiskBlock = { type: 'risk'; maxTiltPct?: number; maxOrderSizeBase?: number; minDistanceBps?: number };
export type ExecutionBlock = { type: 'exec'; refreshSecs: number; postOnly?: boolean; cooldownMs?: number };

export type BuilderBlocks = {
  price: PriceSourceBlock;
  vol?: VolatilityBlock;
  ladder: LadderBlock;
  skew?: SkewBlock;
  recenter?: RecenterBlock;
  risk?: RiskBlock;
  exec: ExecutionBlock;
};


