import type { SuiClient } from '@mysten/sui/client';
import type { OptionsGammaScalperConfig, StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { OptionsClient } from '../../protocols/options/client';

export function createOptionsGammaScalperKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig & { optionsGammaScalper: OptionsGammaScalperConfig }): Keeper {
  const p = (cfg as any).optionsGammaScalper as OptionsGammaScalperConfig;
  const opt = new OptionsClient(client, p.pkg);

  async function step(): Promise<void> {
    const expireTs = BigInt(Math.floor(Date.now() / 1000) + Math.max(60, p.expireSecDelta));
    // Acquire gamma: buy options at limitPremiumQuoteBuy
    for (const key of p.seriesKeys) {
      const txBuy = await opt.buyOrder({ marketId: p.marketId, key, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuoteBuy, expireTs, premiumBudgetQuoteCoinId: p.feeVaultId, feeConfigId: p.feeConfigId, feeVaultId: p.feeVaultId, stakingPoolId: p.stakingPoolId });
      if (await devInspectOk(client, sender, txBuy)) await exec(txBuy);
      // Post take-profit sell
      const txSell = await opt.sellOrder({ marketId: p.marketId, key, quantity: p.perOrderQty, limitPremiumQuote: p.limitPremiumQuoteSell, expireTs });
      if (await devInspectOk(client, sender, txSell)) await exec(txSell);
    }
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 45) * 1000));
}



