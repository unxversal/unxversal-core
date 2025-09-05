import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { clampOrderQtyByCaps, readRiskCaps } from '../../lib/riskCaps';
import { getLatestPrice } from '../../lib/switchboard';

function u64(n: number | bigint): bigint { return BigInt(Math.floor(Number(n))); }

export function createOracleAnchoredKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.oracleAnchored!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function getMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dex.poolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return u64(0);
  }

  async function getOracle(): Promise<bigint> {
    // Prefer Switchboard if configured
    if ((cfg as any).marketData?.switchboardSymbol) {
      const px = getLatestPrice((cfg as any).marketData.switchboardSymbol);
      if (px && px > 0) return u64(Math.floor(px));
    }
    // Fallback: ticker last_price
    const tick = await db.ticker();
    const m = Object.values(tick)[0] as any;
    return u64(Math.floor(m?.last_price ?? 0));
  }

  async function step(): Promise<void> {
    const mid = await getMid(); if (mid === 0n) return;
    const oracle = await getOracle(); if (oracle === 0n) return;
    const caps = cfg.vaultId ? await readRiskCaps(client, (import.meta as any).env.VITE_UNXV_PKG, cfg.vaultId) : null;
    if (caps?.paused) return;
    const devBps = mid > oracle ? ((mid - oracle) * 10_000n) / oracle : ((oracle - mid) * 10_000n) / oracle;
    if (devBps > BigInt(p.maxDeviationBps)) return; // widen/halt when too far
    const levels = BigInt(p.levelsPerSide);
    const stepBps = BigInt(p.stepBps);
    const notional = BigInt(p.perLevelQuoteNotional);
    const tx = new Transaction(); let cid = BigInt(Date.now());
    for (let i = 1n; i <= levels; i++) {
      const off = (oracle * (i * stepBps)) / 10_000n;
      const pb = oracle - off; const pa = oracle + off;
      const qb = clampOrderQtyByCaps(notional / (pb === 0n ? 1n : pb), caps);
      const qa = clampOrderQtyByCaps(notional / (pa === 0n ? 1n : pa), caps);
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


