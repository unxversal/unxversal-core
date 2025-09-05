import type { SuiClient } from '@mysten/sui/client';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { PerpetualsClient } from '../../protocols/perpetuals/client';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

export type PerpsBasisOscConfig = {
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  dexPoolId: string;
  deepbookIndexerUrl: string;
  // thresholds in bps of mid: positive -> perp > spot
  entryBps: number;
  exitBps: number;
  qty: bigint;
  refreshSecs?: number;
};

export function createPerpsBasisOscKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: PerpsBasisOscConfig): Keeper {
  const perp = new PerpetualsClient(cfg.pkg);
  const db = buildDeepbookPublicIndexer(cfg.deepbookIndexerUrl);

  async function spotMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dexPoolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return 0n;
  }

  // For v1, approximate perp mark = oracle last price via aggregator. In production, read a real perp index/mark.
  async function perpMark(): Promise<bigint> {
    // Placeholder approximation: use spot mid as proxy
    return spotMid();
  }

  async function step(): Promise<void> {
    const s = await spotMid(); if (s <= 0n) return;
    const p = await perpMark(); if (p <= 0n) return;
    const bps = p > s ? Number(((p - s) * 10_000n) / s) : -Number(((s - p) * 10_000n) / s);
    // If perp rich vs spot beyond entryBps → short perp (mean revert expected)
    if (bps >= cfg.entryBps) {
      const tx = perp.openShort({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: cfg.qty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
      return;
    }
    // If perp cheap vs spot below -entryBps → long perp
    if (bps <= -cfg.entryBps) {
      const tx = perp.openLong({ marketId: cfg.marketId, oracleRegistryId: cfg.oracleRegistryId, aggregatorId: cfg.aggregatorId, feeConfigId: cfg.feeConfigId, feeVaultId: cfg.feeVaultId, stakingPoolId: cfg.stakingPoolId, qty: cfg.qty });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
      return;
    }
    // Optional: add close logic if within exit band (would require position tracking)
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 20) * 1000));
}



