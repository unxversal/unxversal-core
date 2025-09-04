import type { SuiClient } from '@mysten/sui/client';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';
import { LendingClient } from './client';
import { db } from '../../lib/storage';

export type LendingKeeperConfig = {
  pkg: string;
  poolId: string;
  // how many addresses to probe each cycle
  sampleSize?: number;
  // interval
  intervalMs?: number;
};

export function createLendingKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: LendingKeeperConfig): Keeper {
  const lending = new LendingClient(cfg.pkg);
  const interval = cfg.intervalMs ?? 5_000;

  async function poolAssetType(): Promise<string | null> {
    try {
      const o = await client.getObject({ id: cfg.poolId, options: { showType: true } });
      const t = o.data?.content && 'type' in o.data.content ? (o.data.content as { type: string }).type : undefined;
      if (!t) return null;
      const lt = t.indexOf('<'); const gt = t.lastIndexOf('>');
      if (lt === -1 || gt === -1) return null;
      return t.slice(lt + 1, gt).trim();
    } catch { return null; }
  }

  async function pickRepayCoinId(): Promise<string | null> {
    const asset = await poolAssetType();
    if (!asset) return null;
    const coinType = `0x2::coin::Coin<${asset}>`;
    const res = await client.getCoins({ owner: sender, coinType, limit: 50 });
    const first = res.data?.find((c) => Number(c.balance) > 0);
    return first?.coinObjectId ?? null;
  }

  async function step(): Promise<void> {
    // Strategy: sample recent borrowers from indexer table and probe health using is_healthy_for
    const sample = await db.events.where('type').startsWith(`${cfg.pkg}::lending::Borrow`).reverse().limit(cfg.sampleSize ?? 5).toArray();
    const unique = Array.from(new Set(sample.map((r: any) => (r.parsedJson as any)?.who).filter(Boolean) as string[]));
    for (const borrower of unique) {
      const repayCoinId = await pickRepayCoinId();
      if (!repayCoinId) continue;
      const tx = lending.liquidate({ poolId: cfg.poolId, borrower, repayCoinId });
      const ok = await devInspectOk(client, sender, tx);
      if (!ok) continue;
      await exec(tx);
    }
  }

  return makeLoop(step, interval);
}


