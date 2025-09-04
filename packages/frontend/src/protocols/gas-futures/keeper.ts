import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';
import { db } from '../../lib/storage';

export type GasFuturesKeeperConfig = {
  pkg: string;
  marketId: string;
  feeVaultId: string;
  maxVictims?: number;
  intervalMs?: number;
};

export function createGasFuturesKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: GasFuturesKeeperConfig): Keeper {
  const interval = cfg.intervalMs ?? 5_000;
  const pkg = cfg.pkg;

  async function step(): Promise<void> {
    const rows = await db.events.where('type').equals(`${pkg}::gas_futures::PositionChanged`).reverse().limit(cfg.maxVictims ?? 5).toArray();
    const seen = new Set<string>();
    for (const r of rows) {
      const p = (r.parsedJson as any) || {};
      const victim: string | undefined = p.who;
      if (!victim || seen.has(victim)) continue;
      seen.add(victim);
      const qty: bigint = BigInt(Math.max(1, Number(p.new_long || 0) + Number(p.new_short || 0) > 0 ? Math.ceil((Number(p.new_long || 0) + Number(p.new_short || 0)) * 0.1) : 1));
      const tx = new Transaction();
      tx.moveCall({
        target: `${pkg}::gas_futures::liquidate`,
        arguments: [tx.object(cfg.marketId), tx.pure.address(victim), tx.pure.u64(qty), tx.object(cfg.feeVaultId), tx.object('0x6'), tx.object('0x6')],
      });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, interval);
}


