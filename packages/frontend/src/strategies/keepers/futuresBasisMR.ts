import type { SuiClient } from '@mysten/sui/client';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { FuturesClient } from '../../protocols/futures/client';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

export type FuturesBasisMRConfig = {
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  dexPoolId: string;
  deepbookIndexerUrl: string;
  entryBps: number;
  qty: bigint;
  refreshSecs?: number;
};

export function createFuturesBasisMRKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: FuturesBasisMRConfig): Keeper {
  const fut = new FuturesClient(cfg.pkg);
  const db = buildDeepbookPublicIndexer(cfg.deepbookIndexerUrl);

  async function spotMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dexPoolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return 0n;
  }

  // v1 proxy: spot mid as futures fair; production should use cost-of-carry inputs
  async function futuresMark(): Promise<bigint> { return spotMid(); }

  async function step(): Promise<void> {
    const s = await spotMid(); if (s <= 0n) return;
    const f = await futuresMark(); if (f <= 0n) return;
    const bps = f > s ? Number(((f - s) * 10_000n) / s) : -Number(((s - f) * 10_000n) / s);
    if (bps >= cfg.entryBps) {
      const tx = fut.openShort({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: cfg.qty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
      return;
    }
    if (bps <= -cfg.entryBps) {
      const tx = fut.openLong({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: cfg.qty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
      return;
    }
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 30) * 1000));
}



