import type { SuiClient } from '@mysten/sui/client';
import type { OptionsCalendarDiagonalConfig, StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { OptionsClient } from '../../protocols/options/client';

export function createOptionsCalendarDiagonalKeeper(
  client: SuiClient,
  sender: string,
  exec: TxExecutor,
  cfg: StrategyConfig & { optionsCalendarDiagonal: OptionsCalendarDiagonalConfig },
): Keeper {
  const p = (cfg as any).optionsCalendarDiagonal as OptionsCalendarDiagonalConfig;
  const opt = new OptionsClient(client, p.pkg);

  async function step(): Promise<void> {
    const expireFront = BigInt(Math.floor(Date.now() / 1000) + Math.max(60, p.expireSecDeltaFront));
    const expireBack = BigInt(Math.floor(Date.now() / 1000) + Math.max(120, p.expireSecDeltaBack));
    const ratio = Math.max(0, p.ratioBP) / 10_000;
    const longQty = BigInt(Math.max(0, Math.floor(Number(p.perOrderQty) * ratio)));
    // Iterate pairs up to min length
    const n = Math.min(p.frontSeriesKeys.length, p.backSeriesKeys.length);
    for (let i = 0; i < n; i++) {
      const front = p.frontSeriesKeys[i];
      const back = p.backSeriesKeys[i];
      // Short front (sell)
      const txS = await opt.sellOrder({ marketId: p.marketId, key: front, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuoteShort, expireTs: expireFront });
      if (await devInspectOk(client, sender, txS)) await exec(txS);
      // Long back (buy)
      if (longQty > 0n) {
        const txB = await opt.buyOrder({ marketId: p.marketId, key: back, quantity: longQty, limitPremiumQuote: p.limitPremiumQuoteLong, expireTs: expireBack, premiumBudgetQuoteCoinId: p.feeVaultId, feeConfigId: p.feeConfigId, feeVaultId: p.feeVaultId, stakingPoolId: p.stakingPoolId });
        if (await devInspectOk(client, sender, txB)) await exec(txB);
      }
    }
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 45) * 1000));
}



