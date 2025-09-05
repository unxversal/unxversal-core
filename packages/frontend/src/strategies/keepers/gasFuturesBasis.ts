import type { SuiClient } from '@mysten/sui/client';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { Transaction } from '@mysten/sui/transactions';

export type GasFuturesBasisConfig = {
  pkg: string;
  marketId: string;
  feeVaultId: string;
  // a proxy for realized near-term gas price to compare against
  realizedGasOracleUrl: string; // REST endpoint returning { price: number }
  entryBps: number;
  qty: bigint;
  refreshSecs?: number;
};

async function fetchJson<T>(url: string): Promise<T> { const r = await fetch(url); if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json() as Promise<T>; }

export function createGasFuturesBasisKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: GasFuturesBasisConfig): Keeper {
  async function gasFuturesMark(): Promise<number> {
    // v1: require caller to supply mark via oracle URL if available; else 0
    // In production, query on-chain or indexer for mark.
    try {
      const j = await fetchJson<{ price: number }>(cfg.realizedGasOracleUrl);
      return j.price ?? 0;
    } catch { return 0; }
  }

  async function step(): Promise<void> {
    const spot = await gasFuturesMark(); if (spot <= 0) return;
    const fut = spot; // v1 proxy equality; replace with real futures mark
    const bps = fut > spot ? ((fut - spot) * 10_000) / spot : -((spot - fut) * 10_000) / spot;
    const tx = new Transaction();
    if (bps >= cfg.entryBps) {
      tx.moveCall({ target: `${cfg.pkg}::gas_futures::open_short`, arguments: [tx.object(cfg.marketId), tx.pure.u64(cfg.qty), tx.object(cfg.feeVaultId), tx.object('0x6'), tx.object('0x6')] });
    } else if (bps <= -cfg.entryBps) {
      tx.moveCall({ target: `${cfg.pkg}::gas_futures::open_long`, arguments: [tx.object(cfg.marketId), tx.pure.u64(cfg.qty), tx.object(cfg.feeVaultId), tx.object('0x6'), tx.object('0x6')] });
    } else {
      return;
    }
    if ((tx as any).blockData?.commands?.length) {
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 45) * 1000));
}



