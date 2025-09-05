import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

function u64(n: number | bigint): bigint { return BigInt(Math.floor(Number(n))); }

export function createInventorySkewKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.inventorySkew!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function getMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dex.poolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return u64(0);
  }

  function computeCenterShiftBps(inventoryPctBase: number): bigint {
    const diff = inventoryPctBase - p.targetPctBase; // + means too base-heavy
    const shift = Math.max(-p.maxShiftBps, Math.min(p.maxShiftBps, Math.floor(diff * p.slopeBpsPerPct)));
    return BigInt(shift);
  }

  async function step(): Promise<void> {
    const mid = await getMid(); if (mid === 0n) return;
    const invPctBase = 50; // TODO: read from on-chain vault inventory; placeholder equal split
    const shiftBps = computeCenterShiftBps(invPctBase);
    const center = mid - (mid * shiftBps) / 10_000n;
    const levels = BigInt(p.levelsPerSide);
    const stepBps = BigInt(p.stepBps);
    const notional = BigInt(p.perLevelQuoteNotional);
    const tx = new Transaction();
    let cid = BigInt(Date.now());
    for (let i = 1n; i <= levels; i++) {
      const off = (center * (i * stepBps)) / 10_000n;
      const pb = center - off; const pa = center + off;
      const qb = notional / (pb === 0n ? 1n : pb);
      const qa = notional / (pa === 0n ? 1n : pa);
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, arguments: [
        tx.object(cfg.dex.poolId), tx.object(cfg.dex.balanceManagerId), tx.object(cfg.dex.tradeProofId), tx.object(cfg.dex.feeConfigId), tx.object(cfg.dex.feeVaultId),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(pb), tx.pure.u64(qb), tx.pure.bool(true), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+120)), tx.object('0x6')
      ]});
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, arguments: [
        tx.object(cfg.dex.poolId), tx.object(cfg.dex.balanceManagerId), tx.object(cfg.dex.tradeProofId), tx.object(cfg.dex.feeConfigId), tx.object(cfg.dex.feeVaultId),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(pa), tx.pure.u64(qa), tx.pure.bool(false), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+120)), tx.object('0x6')
      ]});
    }
    if (await devInspectOk(client, sender, tx)) await exec(tx);
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 10) * 1000));
}


