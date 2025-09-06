import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { StrategyConfig } from '../config';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { buildDeepbookPublicIndexer } from '../../lib/indexer';

export function createPairingKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: StrategyConfig): Keeper {
  const p = cfg.pairing!;
  const db = buildDeepbookPublicIndexer(cfg.dex.deepbookIndexerUrl);

  async function step(): Promise<void> {
    // Pull recent trades to find our fills (by balance manager id if indexer supports), then post mirrored TP
    const trades = await db.trades(cfg.dex.poolId, { limit: 25 });
    const tpBps = BigInt(p.takeProfitBps);
    const tx = new Transaction();
    let cid = BigInt(Date.now());
    for (const t of trades) {
      // Without BM attribution, act on the latest few prints as heuristic
      const price = BigInt(Math.floor(Number(t.price)));
      const qty = BigInt(Math.max(1, Math.floor(Number(t.qty))));
      const isBuy = true; // unknown; place both small TP legs cautiously
      const tpUp = price + (price * tpBps) / 10_000n;
      const tpDn = price - (price * tpBps) / 10_000n;
      // Sell TP
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, typeArguments: [cfg.dex.baseType, cfg.dex.quoteType], arguments: [
        tx.object(cfg.dex.poolId), tx.object(cfg.dex.balanceManagerId), tx.object(cfg.dex.tradeProofId), tx.object(cfg.dex.feeConfigId), tx.object(cfg.dex.feeVaultId),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(tpUp), tx.pure.u64(qty), tx.pure.bool(false), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+90)), tx.object('0x6')
      ]});
      // Buy TP
      tx.moveCall({ target: `${import.meta.env.VITE_UNXV_PKG}::dex::place_limit_order`, typeArguments: [cfg.dex.baseType, cfg.dex.quoteType], arguments: [
        tx.object(cfg.dex.poolId), tx.object(cfg.dex.balanceManagerId), tx.object(cfg.dex.tradeProofId), tx.object(cfg.dex.feeConfigId), tx.object(cfg.dex.feeVaultId),
        tx.pure.u64(cid++), tx.pure.u8(0), tx.pure.u8(0), tx.pure.u64(tpDn), tx.pure.u64(qty), tx.pure.bool(true), tx.pure.bool(false), tx.pure.u64(BigInt(Math.floor(Date.now()/1000)+90)), tx.object('0x6')
      ]});
    }
    if ((tx as any).blockData?.commands?.length) {
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, Math.max(1000, (p.refreshSecs ?? 15) * 1000));
}


