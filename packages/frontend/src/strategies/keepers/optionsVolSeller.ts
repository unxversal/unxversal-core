import type { SuiClient } from '@mysten/sui/client';
import type { OptionsVolSellerConfig, StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { OptionsClient } from '../../protocols/options/client';

export function createOptionsVolSellerKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig & { optionsVolSeller: OptionsVolSellerConfig }): Keeper {
  const p = (cfg as any).optionsVolSeller as OptionsVolSellerConfig;
  const opt = new OptionsClient(client, p.pkg);

  async function step(): Promise<void> {
    const expireTs = BigInt(Math.floor(Date.now() / 1000) + Math.max(60, p.expireSecDelta));
    for (const key of p.seriesKeys) {
      const tx = await opt.sellOrder({ marketId: p.marketId, key, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuote, expireTs, baseCollateralCoinId: undefined, quoteCollateralCoinId: undefined });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 30) * 1000));
}



