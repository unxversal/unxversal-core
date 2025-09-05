import type { SuiClient } from '@mysten/sui/client';
import type { Transaction } from '@mysten/sui/transactions';
import type { Keeper, TxExecutor } from '../protocols/common';
import type { StrategyConfig } from './config';
import { createStaticRangeKeeper } from './staticRange';
import { createAmmOverlayKeeper } from './keepers/ammOverlay';
import { createVolAdaptiveKeeper } from './keepers/volAdaptive';
import { createInventorySkewKeeper } from './keepers/inventorySkew';
import { createPairingKeeper } from './keepers/pairing';
import { createTrendKeeper } from './keepers/trend';
import { createOracleAnchoredKeeper } from './keepers/oracleAnchored';
import { createTimeRegimeKeeper } from './keepers/timeRegime';
import { createDeltaHedgedMakerKeeper } from './keepers/deltaHedgedMaker';
import { createOptionsSweepKeeper } from './keepers/optionsSweep';
import { createOptionsVolSellerKeeper } from './keepers/optionsVolSeller';
import { createCoveredCallsKeeper } from './keepers/coveredCalls';
import { createCashSecuredPutsKeeper } from './keepers/cashSecuredPuts';
import { createOptionsCalendarDiagonalKeeper } from './keepers/optionsCalendarDiagonal';
import { createOptionsGammaScalperKeeper } from './keepers/optionsGammaScalper';
import { createOptionsSkewArbKeeper } from './keepers/optionsSkewArb';
import { createPerpsAutoKeeper } from './keepers/perpsFundingAndLiq';
import { createPerpsBasisOscKeeper } from './keepers/perpsBasisOsc';
import { createPerpsTrendMakerKeeper } from './keepers/perpsTrendMaker';
import { createPerpsCashCarryKeeper } from './keepers/perpsCashCarry';
import { createFuturesBasisMRKeeper } from './keepers/futuresBasisMR';
import { createFuturesTermRollKeeper } from './keepers/futuresTermRoll';
import { createFuturesSeasonalEventKeeper } from './keepers/futuresSeasonalEvent';
import { createGasFuturesBasisKeeper } from './keepers/gasFuturesBasis';

export function buildKeeperFromStrategy(
  client: SuiClient,
  sender: string,
  exec: TxExecutor,
  cfg: StrategyConfig,
): Keeper | null {
  switch (cfg.kind) {
    case 'static-range':
      return createStaticRangeKeeper(client, sender, exec, cfg);
    case 'amm-overlay':
      return createAmmOverlayKeeper(client, sender, exec, cfg);
    case 'vol-adaptive':
      return createVolAdaptiveKeeper(client, sender, exec, cfg);
    case 'inventory-skew':
      return createInventorySkewKeeper(client, sender, exec, cfg);
    case 'pairing':
      return createPairingKeeper(client, sender, exec, cfg);
    case 'trend':
      return createTrendKeeper(client, sender, exec, cfg);
    case 'oracle-anchored':
      return createOracleAnchoredKeeper(client, sender, exec, cfg);
    case 'time-regime':
      return createTimeRegimeKeeper(client, sender, exec, cfg);
    case 'delta-hedged-maker':
      return createDeltaHedgedMakerKeeper(client, sender, exec, cfg);

    // Options
    case 'options-sweep':
      return createOptionsSweepKeeper(client, sender, exec, cfg.optionsSweep!);
    case 'options-vol-seller':
      return createOptionsVolSellerKeeper(client, sender, exec, { optionsVolSeller: cfg.optionsVolSeller! } as any);
    case 'covered-calls':
      return createCoveredCallsKeeper(client, sender, exec, { coveredCalls: (cfg as any).coveredCalls } as any);
    case 'cash-secured-puts':
      return createCashSecuredPutsKeeper(client, sender, exec, { cashSecuredPuts: (cfg as any).cashSecuredPuts } as any);
    case 'options-calendar-diagonal':
      return createOptionsCalendarDiagonalKeeper(client, sender, exec, { optionsCalendarDiagonal: cfg.optionsCalendarDiagonal! } as any);

    // Perpetuals
    case 'perps-auto':
      return createPerpsAutoKeeper(client, sender, exec, (cfg as any).perpsAuto);
    case 'perps-basis-osc':
      return createPerpsBasisOscKeeper(client, sender, exec, (cfg as any).perpsBasisOsc);
    case 'perps-trend':
      return createPerpsTrendMakerKeeper(client, sender, exec, (cfg as any).perpsTrend);
    case 'perps-cash-carry':
      return createPerpsCashCarryKeeper(client, sender, exec, (cfg as any).perpsCashCarry);

    // Futures
    case 'futures-basis-mr':
      return createFuturesBasisMRKeeper(client, sender, exec, (cfg as any).futuresBasisMR);
    case 'futures-term-roll':
      return createFuturesTermRollKeeper(client, sender, exec, (cfg as any).futuresTermRoll);
    case 'futures-seasonal':
      return createFuturesSeasonalEventKeeper(client, sender, exec, (cfg as any).futuresSeasonal);

    // Gas Futures
    case 'gas-futures-basis':
      return createGasFuturesBasisKeeper(client, sender, exec, (cfg as any).gasFuturesBasis);
    default:
      return null;
  }
}


