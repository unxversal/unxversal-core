import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { CoveredCallsConfig, StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { OptionsClient } from '../../protocols/options/client';

export function createCoveredCallsKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig & { coveredCalls: CoveredCallsConfig }): Keeper {
  const p = cfg.coveredCalls;
  const opt = new OptionsClient(client, p.pkg);

  async function step(): Promise<void> {
    const expireTs = BigInt(Math.floor(Date.now() / 1000) + Math.max(60, p.expireSecDelta));
    for (const key of p.callSeriesKeys) {
      const tx = await opt.sellOrder({ marketId: p.marketId, key, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuote, expireTs, baseCollateralCoinId: undefined, quoteCollateralCoinId: undefined });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 30) * 1000));
}



