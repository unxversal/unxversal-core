import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';

export type OptionsKeeperConfig = {
  pkg: string;
  marketId: string;
  // series keys that this keeper should sweep for expiries
  seriesKeys: bigint[];
  sweepMax?: number;
  intervalMs?: number;
};

export function createOptionsKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: OptionsKeeperConfig): Keeper {
  const interval = cfg.intervalMs ?? 15_000;
  const pkg = cfg.pkg;
  const sweepMax = cfg.sweepMax ?? 50;

  async function step(): Promise<void> {
    for (const key of cfg.seriesKeys) {
      const tx = new Transaction();
      tx.moveCall({ target: `${pkg}::options::sweep_expired_orders`, arguments: [tx.object(cfg.marketId), tx.pure.u128(key), tx.pure.u64(sweepMax), tx.object('0x6')] });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, interval);
}


