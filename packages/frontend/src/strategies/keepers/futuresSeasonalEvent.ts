import type { SuiClient } from '@mysten/sui/client';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { FuturesClient } from '../../protocols/futures/client';

export type FuturesSeasonalEventConfig = {
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  schedule: Array<{ startMs: number; endMs: number; bias: 'long' | 'short'; qty: bigint }>; // seasonal/event windows
  refreshSecs?: number;
};

export function createFuturesSeasonalEventKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: FuturesSeasonalEventConfig): Keeper {
  const fut = new FuturesClient(cfg.pkg);

  async function step(): Promise<void> {
    const now = Date.now();
    const win = cfg.schedule.find((w) => now >= w.startMs && now <= w.endMs);
    if (!win) return;
    if (win.bias === 'long') {
      const tx = fut.openLong({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: win.qty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    } else {
      const tx = fut.openShort({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: win.qty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 60) * 1000));
}



