import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { readRiskCaps } from '../../lib/riskCaps';

export type OptionsSweepConfig = {
  pkg: string;
  marketId: string;
  seriesKeys: bigint[];
  sweepMax?: number;
  refreshSecs?: number;
};

export function createOptionsSweepKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: OptionsSweepConfig): Keeper {
  const interval = Math.max(1000, (cfg.refreshSecs ?? 15) * 1000);
  async function step(): Promise<void> {
    const caps = (cfg as any).vaultId ? await readRiskCaps(client, (import.meta as any).env.VITE_UNXV_PKG, (cfg as any).vaultId) : null;
    if (caps?.paused) return;
    for (const key of cfg.seriesKeys) {
      const tx = new Transaction();
      tx.moveCall({ target: `${cfg.pkg}::options::sweep_expired_orders`, arguments: [tx.object(cfg.marketId), tx.pure.u128(key), tx.pure.u64(cfg.sweepMax ?? 50), tx.object('0x6')] });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }
  return makeLoop(step, interval);
}


