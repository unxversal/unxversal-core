import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

export type DexKeeperConfig = {
  pkg: string;
  poolId: string;
  balanceManagerId: string;
  tradeProofId: string;
  feeConfigId: string;
  feeVaultId: string;
  // DeepBook public indexer base URL to pull orderbook
  deepbookIndexerUrl: string;
  // Built-in simple strategy: place small maker orders inside the top-of-book spread; cancel if spread is too wide.
  // You can later replace this with a richer strategy in-code, but no external function is required.
  intervalMs?: number;
};

export function createDexKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: DexKeeperConfig): Keeper {
  const interval = cfg.intervalMs ?? 10_000;
  const pkg = cfg.pkg;
  const db = buildDeepbookPublicIndexer(cfg.deepbookIndexerUrl);

  async function step(): Promise<void> {
    const ob = await db.orderbook(cfg.poolId, { level: 2, depth: 10 });
    if (!ob.bids.length || !ob.asks.length) return;
    const bestBid = BigInt(ob.bids[0][0]);
    const bestAsk = BigInt(ob.asks[0][0]);
    const mid = (bestBid + bestAsk) / BigInt(2);
    const spread = bestAsk - bestBid;
    // Simple rule: if spread reasonable, place both a tiny bid and ask around mid; else do nothing
    const place = spread <= (mid / BigInt(2000)) /* <= 5 bps */;
    if (!place) return;
    const tx = new Transaction();
    const clientOrderId = BigInt(Date.now());
    const orderType = 0; // GTC
    const selfMatchingOption = 0;
    const qty = BigInt(1); // tiny quote
    const expireTs = BigInt(Math.floor(Date.now() / 1000) + 120);
    // place bid
    tx.moveCall({
      target: `${pkg}::dex::place_limit_order`,
      arguments: [
        tx.object(cfg.poolId),
        tx.object(cfg.balanceManagerId),
        tx.object(cfg.tradeProofId),
        tx.object(cfg.feeConfigId),
        tx.object(cfg.feeVaultId),
        tx.pure.u64(clientOrderId),
        tx.pure.u8(orderType),
        tx.pure.u8(selfMatchingOption),
        tx.pure.u64(mid - BigInt(1)),
        tx.pure.u64(qty),
        tx.pure.bool(true),
        tx.pure.bool(false),
        tx.pure.u64(expireTs),
        tx.object('0x6'),
      ],
    });
    // place ask
    tx.moveCall({
      target: `${pkg}::dex::place_limit_order`,
      arguments: [
        tx.object(cfg.poolId),
        tx.object(cfg.balanceManagerId),
        tx.object(cfg.tradeProofId),
        tx.object(cfg.feeConfigId),
        tx.object(cfg.feeVaultId),
        tx.pure.u64(clientOrderId + BigInt(1)),
        tx.pure.u8(orderType),
        tx.pure.u8(selfMatchingOption),
        tx.pure.u64(mid + BigInt(1)),
        tx.pure.u64(qty),
        tx.pure.bool(false),
        tx.pure.bool(false),
        tx.pure.u64(expireTs),
        tx.object('0x6'),
      ],
    });
    if (await devInspectOk(client, sender, tx)) await exec(tx);
  }

  return makeLoop(step, interval);
}


