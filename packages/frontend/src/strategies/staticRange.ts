import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from './config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../protocols/common';
import { buildDeepbookPublicIndexer } from '../lib/indexer';
import { getLatestPrice } from '../lib/switchboard';
import { clampOrderQtyByCaps, readRiskCaps } from '../lib/riskCaps';

function u64(n: number | bigint): bigint { return BigInt(Math.floor(Number(n))); }

export function createStaticRangeKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const { poolId, balanceManagerId, tradeProofId, feeConfigId, feeVaultId } = cfg.dex;
  const p = cfg.staticRange;

  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);
  async function priceMid(): Promise<bigint> {
    if (cfg.staticRange.midSource === 'switchboard' && cfg.marketData?.switchboardSymbol) {
      const px = getLatestPrice(cfg.marketData.switchboardSymbol);
      if (px && px > 0) return u64(Math.floor(px));
    }
    const ob = await db.orderbook(cfg.dex.poolId, { level: 1, depth: 1 });
    if (ob.bids?.length && ob.asks?.length) {
      const bestBid = BigInt(ob.bids[0][0]);
      const bestAsk = BigInt(ob.asks[0][0]);
      return (bestBid + bestAsk) / 2n;
    }
    return u64(0);
  }

  function buildLadder(mid: bigint): { bids: Array<{ price: bigint; qty: bigint }>; asks: Array<{ price: bigint; qty: bigint }> } {
    const half = BigInt(Math.floor(p.levelsPerSide));
    const step = BigInt(p.stepBps);
    const perNotional = BigInt(p.perLevelQuoteNotional);
    const bids: Array<{ price: bigint; qty: bigint }> = [];
    const asks: Array<{ price: bigint; qty: bigint }> = [];
    for (let i = 1n; i <= half; i++) {
      const offBps = i * step;
      const priceBid = mid - (mid * offBps) / 10_000n;
      const priceAsk = mid + (mid * offBps) / 10_000n;
      const qtyBid = perNotional / (priceBid === 0n ? 1n : priceBid);
      const qtyAsk = perNotional / (priceAsk === 0n ? 1n : priceAsk);
      bids.push({ price: priceBid, qty: qtyBid });
      asks.push({ price: priceAsk, qty: qtyAsk });
    }
    return { bids, asks };
  }

  async function step(): Promise<void> {
    const mid = await priceMid();
    let { bids, asks } = buildLadder(mid);
    const caps = cfg.vaultId ? await readRiskCaps(client, (import.meta as any).env.VITE_UNXV_PKG, cfg.vaultId) : null;
    if (caps?.paused) return;
    if (caps?.min_distance_bps && Number(caps.min_distance_bps) > 0) {
      // Filter any legs too close to mid
      const filterLegs = (price: bigint) => {
        const dist = price > mid ? Number(((price - mid) * 10_000n) / mid) : Number(((mid - price) * 10_000n) / mid);
        return dist >= caps.min_distance_bps;
      };
      bids = bids.filter((l) => filterLegs(l.price));
      asks = asks.filter((l) => filterLegs(l.price));
    }
    const tx = new Transaction();
    // Place a small subset per tick to avoid size; maker-only enforcement should be in Move
    let cid = BigInt(Date.now());
    for (const b of bids.slice(0, 2)) {
      tx.moveCall({
        target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`,
        arguments: [
          tx.object(poolId),
          tx.object(balanceManagerId),
          tx.object(tradeProofId),
          tx.object(feeConfigId),
          tx.object(feeVaultId),
          tx.pure.u64(cid++),
          tx.pure.u8(0), // orderType GTC
          tx.pure.u8(0), // selfMatchingOption
          tx.pure.u64(b.price),
          tx.pure.u64(clampOrderQtyByCaps(b.qty, caps)),
          tx.pure.bool(true),
          tx.pure.bool(false),
          tx.pure.u64(BigInt(Math.floor(Date.now() / 1000) + 120)),
          tx.object('0x6'),
        ],
      });
    }
    for (const a of asks.slice(0, 2)) {
      tx.moveCall({
        target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`,
        arguments: [
          tx.object(poolId),
          tx.object(balanceManagerId),
          tx.object(tradeProofId),
          tx.object(feeConfigId),
          tx.object(feeVaultId),
          tx.pure.u64(cid++),
          tx.pure.u8(0),
          tx.pure.u8(0),
          tx.pure.u64(a.price),
          tx.pure.u64(clampOrderQtyByCaps(a.qty, caps)),
          tx.pure.bool(false),
          tx.pure.bool(false),
          tx.pure.u64(BigInt(Math.floor(Date.now() / 1000) + 120)),
          tx.object('0x6'),
        ],
      });
    }
    if (await devInspectOk(client, sender, tx)) await exec(tx);
  }

  return makeLoop(step, Math.max(1000, p.refreshSecs * 1000));
}


