import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

function u64(n: number | bigint): bigint { return BigInt(Math.floor(Number(n))); }

export function createAmmOverlayKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.ammOverlay!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function getMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dex.poolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return u64(0);
  }

  function ladder(mid: bigint): { bids: Array<{ price: bigint; qty: bigint }>; asks: Array<{ price: bigint; qty: bigint }> } {
    const bids: Array<{ price: bigint; qty: bigint }> = [];
    const asks: Array<{ price: bigint; qty: bigint }> = [];
    const levels = BigInt(p.levelsPerSide);
    const step = BigInt(p.stepBps);
    const notional = BigInt(p.perLevelQuoteNotional);
    const g = p.baseGeometricFactor;
    for (let i = 1n; i <= levels; i++) {
      const off = (mid * (i * step)) / 10_000n;
      const pb = mid - off; const pa = mid + off;
      const weight = BigInt(Math.floor(g ** Number(i) * 1e6)) ;
      const baseQtyB = (notional * weight) / (pb === 0n ? 1n : pb) / 1_000_000n;
      const baseQtyA = (notional * weight) / (pa === 0n ? 1n : pa) / 1_000_000n;
      bids.push({ price: pb, qty: baseQtyB });
      asks.push({ price: pa, qty: baseQtyA });
    }
    return { bids, asks };
  }

  async function step(): Promise<void> {
    const mid = await getMid();
    if (mid === 0n) return;
    const { bids, asks } = ladder(mid);
    const tx = new Transaction();
    let cid = BigInt(Date.now());
    const argsCommon = [cfg.dex.poolId, cfg.dex.balanceManagerId, cfg.dex.tradeProofId, cfg.dex.feeConfigId, cfg.dex.feeVaultId] as const;
    for (const b of bids.slice(0, 2)) {
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, arguments: [
        tx.object(argsCommon[0]), tx.object(argsCommon[1]), tx.object(argsCommon[2]), tx.object(argsCommon[3]), tx.object(argsCommon[4]),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(b.price), tx.pure.u64(b.qty), tx.pure.bool(true), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+120)), tx.object('0x6')
      ]});
    }
    for (const a of asks.slice(0, 2)) {
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, arguments: [
        tx.object(argsCommon[0]), tx.object(argsCommon[1]), tx.object(argsCommon[2]), tx.object(argsCommon[3]), tx.object(argsCommon[4]),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(a.price), tx.pure.u64(a.qty), tx.pure.bool(false), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+120)), tx.object('0x6')
      ]});
    }
    if (await devInspectOk(client, sender, tx)) await exec(tx);
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 10) * 1000));
}


