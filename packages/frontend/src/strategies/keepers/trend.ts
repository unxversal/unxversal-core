import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

function ema(arr: number[], n: number): number {
  if (arr.length === 0) return 0;
  const k = 2 / (n + 1);
  let e = arr[0];
  for (let i = 1; i < arr.length; i++) e = arr[i] * k + e * (1 - k);
  return e;
}

export function createTrendKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.trend!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function step(): Promise<void> {
    const now = Date.now();
    const trades = await db.trades(cfg.dex.poolId, { start_time: now - 15 * 60_000, end_time: now, limit: 500 });
    const px: number[] = trades.map((t: any) => Number(t.price));
    if (px.length < Math.max(p.emaFast, p.emaSlow)) return;
    const eFast = ema(px, p.emaFast);
    const eSlow = ema(px, p.emaSlow);
    const uptrend = eFast > eSlow;
    const levelStep = BigInt(uptrend ? p.stepFastBps : p.stepSlowBps);
    const levels = BigInt(p.levelsPerSide);
    const notional = BigInt(p.perLevelQuoteNotional);
    const mid = BigInt(Math.floor(px[px.length - 1]));
    const tx = new Transaction();
    let cid = BigInt(Date.now());
    for (let i = 1n; i <= levels; i++) {
      const off = (mid * (i * levelStep)) / 10_000n;
      const pb = mid - off; const pa = mid + off;
      const qb = notional / (pb === 0n ? 1n : pb);
      const qa = notional / (pa === 0n ? 1n : pa);
      // In uptrend, prefer selling into strength (asks tighter via stepFastBps)
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


