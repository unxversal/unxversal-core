import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';
import { PerpetualsClient } from '../../protocols/perpetuals/client';
import { clampOrderQtyByCaps, readRiskCaps } from '../../lib/riskCaps';

function u64(n: number | bigint): bigint { return BigInt(Math.floor(Number(n))); }

export function createDeltaHedgedMakerKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.deltaHedgedMaker!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);
  const perp = new PerpetualsClient(p.perps.pkg);

  async function getMid(): Promise<bigint> {
    const ob = await db.orderbook(cfg.dex.poolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const b = BigInt(ob.bids[0][0]); const a = BigInt(ob.asks[0][0]);
      return (b + a) / 2n;
    }
    return u64(0);
  }

  // TODO: replace with on-chain vault inventory once exposed; using 50/50 neutral assumption
  async function estimateNetBaseDelta(): Promise<number> {
    // In v1, we assume current net base is approximately neutral and adjust only on clear drift via recent fills.
    // A simple heuristic: look at last trades and infer small tilt; here we return 0 to avoid over-hedging.
    return 0;
  }

  function buildSpotLadder(mid: bigint): Array<{ price: bigint; qty: bigint; isBid: boolean }> {
    const out: Array<{ price: bigint; qty: bigint; isBid: boolean }> = [];
    const levels = BigInt(p.levelsPerSide);
    const step = BigInt(p.stepBps);
    const notional = BigInt(p.perLevelQuoteNotional);
    for (let i = 1n; i <= levels; i++) {
      const off = (mid * (i * step)) / 10_000n;
      const pb = mid - off; const pa = mid + off;
      const qb = notional / (pb === 0n ? 1n : pb);
      const qa = notional / (pa === 0n ? 1n : pa);
      out.push({ price: pb, qty: qb, isBid: true });
      out.push({ price: pa, qty: qa, isBid: false });
    }
    return out;
  }

  async function placeSpotQuotes(): Promise<void> {
    const mid = await getMid(); if (mid === 0n) return;
    const ladder = buildSpotLadder(mid);
    const caps = cfg.vaultId ? await readRiskCaps(client, (import.meta as any).env.VITE_UNXV_PKG, cfg.vaultId) : null;
    if (caps?.paused) return;
    const tx = new Transaction();
    let cid = BigInt(Date.now());
    for (const leg of ladder.slice(0, 4)) {
      const qty = clampOrderQtyByCaps(leg.qty, caps);
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, arguments: [
        tx.object(cfg.dex.poolId), tx.object(cfg.dex.balanceManagerId), tx.object(cfg.dex.tradeProofId), tx.object(cfg.dex.feeConfigId), tx.object(cfg.dex.feeVaultId),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(leg.price), tx.pure.u64(qty), tx.pure.bool(leg.isBid), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+120)), tx.object('0x6')
      ]});
    }
    if (await devInspectOk(client, sender, tx)) await exec(tx);
  }

  async function hedgeDeltaIfNeeded(): Promise<void> {
    const delta = await estimateNetBaseDelta();
    const tol = p.perps.toleranceQty;
    if (Math.abs(delta) <= tol) return;
    const maxPer = p.perps.maxHedgeQtyPerAction;
    const hedgeQty = BigInt(Math.min(maxPer, Math.max(tol, Math.floor(Math.abs(delta)))));
    if (hedgeQty <= 0n) return;
    // If delta > 0 (long base), short perps; if delta < 0 (short base), long perps
    const tx = delta > 0
      ? perp.openShort({ marketId: p.perps.marketId, oracleRegistryId: p.perps.oracleRegistryId, aggregatorId: p.perps.aggregatorId, feeConfigId: p.perps.feeConfigId, feeVaultId: p.perps.feeVaultId, stakingPoolId: p.perps.stakingPoolId, qty: hedgeQty })
      : perp.openLong({ marketId: p.perps.marketId, oracleRegistryId: p.perps.oracleRegistryId, aggregatorId: p.perps.aggregatorId, feeConfigId: p.perps.feeConfigId, feeVaultId: p.perps.feeVaultId, stakingPoolId: p.perps.stakingPoolId, qty: hedgeQty });
    if (await devInspectOk(client, sender, tx)) await exec(tx);
  }

  async function step(): Promise<void> {
    await placeSpotQuotes();
    await hedgeDeltaIfNeeded();
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 10) * 1000));
}



