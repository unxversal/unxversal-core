import type { SuiClient } from '@mysten/sui/client';
import type { OptionsSkewArbConfig, StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { OptionsClient } from '../../protocols/options/client';

export function createOptionsSkewArbKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig & { optionsSkewArb: OptionsSkewArbConfig }): Keeper {
  const p = (cfg as any).optionsSkewArb as OptionsSkewArbConfig;
  const opt = new OptionsClient(client, p.pkg);

  async function step(): Promise<void> {
    // v1: simple simultaneous call/put sells to target smile balance
    const expireTs = BigInt(Math.floor(Date.now() / 1000) + 300);
    const n = Math.min(p.callKeys.length, p.putKeys.length);
    for (let i = 0; i < n; i++) {
      const ck = p.callKeys[i];
      const pk = p.putKeys[i];
      const txC = await opt.sellOrder({ marketId: p.marketId, key: ck, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuoteCall, expireTs });
      if (await devInspectOk(client, sender, txC)) await exec(txC);
      const txP = await opt.sellOrder({ marketId: p.marketId, key: pk, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuotePut, expireTs });
      if (await devInspectOk(client, sender, txP)) await exec(txP);
    }
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 60) * 1000));
}



