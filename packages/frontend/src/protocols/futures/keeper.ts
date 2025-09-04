import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';
import { db } from '../../lib/storage';

export type FuturesKeeperConfig = {
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeVaultId: string;
  // Optional limit for how many candidates to try per sweep
  maxVictims?: number;
  intervalMs?: number;
};

export function createFuturesKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: FuturesKeeperConfig): Keeper {
  const interval = cfg.intervalMs ?? 5_000;
  const pkg = cfg.pkg;

  async function step(): Promise<void> {
    // Heuristic: sample recent PositionChanged events to get addresses, try small-qty close against maintenance breaches (on-chain checks will guard)
    const rows = await db.events.where('type').equals(`${pkg}::futures::PositionChanged`).reverse().limit(cfg.maxVictims ?? 5).toArray();
    const seen = new Set<string>();
    for (const r of rows) {
      const p = (r.parsedJson as any) || {};
      const victim: string | undefined = p.who;
      if (!victim || seen.has(victim)) continue;
      seen.add(victim);
      const qty: bigint = BigInt(Math.max(1, Number(p.new_long || 0) + Number(p.new_short || 0) > 0 ? Math.ceil((Number(p.new_long || 0) + Number(p.new_short || 0)) * 0.1) : 1));
      const tx = new Transaction();
      tx.moveCall({
        target: `${pkg}::futures::liquidate`,
        arguments: [tx.object(cfg.marketId), tx.pure.address(victim), tx.pure.u64(qty), tx.object(cfg.oracleRegistryId), tx.object(cfg.aggregatorId), tx.object(cfg.feeVaultId), tx.object('0x6'), tx.object('0x6')],
      });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, interval);
}


