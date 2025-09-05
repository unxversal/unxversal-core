import type { StrategyConfig } from '../config';
import type { BuilderBlocks } from './types';

export function compileBlocksToConfig(blocks: BuilderBlocks, base: Omit<StrategyConfig, 'kind' | 'staticRange'> & { kind?: StrategyConfig['kind'] }): StrategyConfig {
  const bandBps = blocks.ladder.bandPolicy.kind === 'fixed'
    ? blocks.ladder.bandPolicy.bps
    : Math.max(blocks.ladder.bandPolicy.minBps, Math.min(blocks.ladder.bandPolicy.maxBps, Math.floor(blocks.ladder.bandPolicy.k * 100))); // placeholder mapping for sigma

  const cfg: StrategyConfig = {
    kind: base.kind ?? 'static-range',
    dex: base.dex,
    vaultId: base.vaultId,
    staticRange: {
      priceSource: blocks.price.source,
      bandBps,
      levelsPerSide: blocks.ladder.levelsPerSide,
      stepBps: blocks.ladder.stepBps,
      perLevelQuoteNotional: blocks.ladder.sizePolicy.kind === 'equal_notional' ? blocks.ladder.sizePolicy.perLevelQuote : 0,
      recenterDriftBps: blocks.recenter?.driftBps ?? 0,
      refreshSecs: blocks.exec.refreshSecs,
    },
    ammOverlay: undefined,
    volAdaptive: blocks.vol && blocks.ladder.bandPolicy.kind === 'sigma' ? {
      k: blocks.ladder.bandPolicy.k,
      minBandBps: blocks.ladder.bandPolicy.minBps,
      maxBandBps: blocks.ladder.bandPolicy.maxBps,
      stepBps: blocks.ladder.stepBps,
      perLevelQuoteNotional: blocks.ladder.sizePolicy.kind === 'equal_notional' ? blocks.ladder.sizePolicy.perLevelQuote : 0,
      lookbackMinutes: blocks.vol.lookbackMins,
      refreshSecs: blocks.exec.refreshSecs,
    } : undefined,
    inventorySkew: blocks.skew ? {
      targetPctBase: blocks.skew.targetPctBase,
      slopeBpsPerPct: blocks.skew.slopeBpsPerPct,
      maxShiftBps: blocks.skew.maxShiftBps,
      bandBps,
      levelsPerSide: blocks.ladder.levelsPerSide,
      stepBps: blocks.ladder.stepBps,
      perLevelQuoteNotional: blocks.ladder.sizePolicy.kind === 'equal_notional' ? blocks.ladder.sizePolicy.perLevelQuote : 0,
      refreshSecs: blocks.exec.refreshSecs,
    } : undefined,
    pairing: undefined,
    trend: undefined,
    oracleAnchored: undefined,
  };
  return cfg;
}


