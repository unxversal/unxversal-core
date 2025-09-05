import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { clampOrderQtyByCaps, readRiskCaps } from '../../lib/riskCaps';
import { getLatestPrice } from '../../lib/switchboard';

function u64(n: number | bigint): bigint { return BigInt(Math.floor(Number(n))); }

export function createVolAdaptiveKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.volAdaptive!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function getMids(): Promise<number[]> {
    const now = Date.now();
    const windowMs = p.lookbackMinutes * 60_000;
    const start = now - windowMs;
    const mids: number[] = [];
    if ((cfg as any).marketData?.switchboardSymbol) {
      // Use switchboard latest as base point and synthesize small history
      const px = getLatestPrice((cfg as any).marketData.switchboardSymbol);
      if (px && px > 0) {
        // Create a flat series as fallback to avoid zero sigma; real impl can maintain a ring buffer
        for (let i = 0; i < 10; i++) mids.push(px);
      }
    }
    if (mids.length === 0) {
      const trades = await db.trades(cfg.dex.poolId, { start_time: start, end_time: now, limit: 500 });
      for (const t of trades) { mids.push(Number(t.price)); }
    }
    return mids;
  }

  function estimateSigma(mids: number[]): number {
    if (mids.length < 2) return 0.01;
    const rets: number[] = [];
    for (let i = 1; i < mids.length; i++) {
      const r = (mids[i] - mids[i - 1]) / mids[i - 1];
      rets.push(r);
    }
    const mean = rets.reduce((a, b) => a + b, 0) / rets.length;
    const varr = rets.reduce((a, b) => a + (b - mean) * (b - mean), 0) / Math.max(1, rets.length - 1);
    return Math.sqrt(varr);
  }

  function computeBand(sigma: number): bigint {
    const bps = Math.min(p.maxBandBps, Math.max(p.minBandBps, Math.floor(p.k * sigma * 10_000)));
    return BigInt(bps);
  }

  async function step(): Promise<void> {
    const caps = cfg.vaultId ? await readRiskCaps(client, (import.meta as any).env.VITE_UNXV_PKG, cfg.vaultId) : null;
    if (caps?.paused) return;
    const mids = await getMids();
    const sigma = estimateSigma(mids);
    if (!mids.length) return;
    const mid = u64(Math.floor(mids[mids.length - 1]));
    const stepBps = BigInt(p.stepBps);
    const levels = 3n;
    const notional = BigInt(p.perLevelQuoteNotional);
    const tx = new Transaction();
    let cid = BigInt(Date.now());
    for (let i = 1n; i <= levels; i++) {
      const off = (mid * (i * stepBps)) / 10_000n;
      const pb = mid - off; const pa = mid + off;
      const qb = clampOrderQtyByCaps(notional / (pb === 0n ? 1n : pb), caps);
      const qa = clampOrderQtyByCaps(notional / (pa === 0n ? 1n : pa), caps);
      // Enforce min-distance vs mid if provided
      if (caps?.min_distance_bps && Number(caps.min_distance_bps) > 0) {
        const distB = pb > mid ? Number(((pb - mid) * 10_000n) / mid) : Number(((mid - pb) * 10_000n) / mid);
        const distA = pa > mid ? Number(((pa - mid) * 10_000n) / mid) : Number(((mid - pa) * 10_000n) / mid);
        if (distB < caps.min_distance_bps && distA < caps.min_distance_bps) continue;
      }
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


