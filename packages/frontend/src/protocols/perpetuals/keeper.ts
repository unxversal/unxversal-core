import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';
import { db } from '../../lib/storage';

export type PerpKeeperConfig = {
  pkg: string;
  marketId: string;
  oracleRegistryId: string;
  aggregatorId: string;
  feeConfigId: string;
  feeVaultId: string;
  stakingPoolId: string;
  // Optional: compute funding delta/direction off-chain (e.g., via Surge). If absent, funding update is skipped.
  fundingDelta1e6?: () => Promise<{ longsPay: boolean; delta1e6: number } | null>;
  maxVictims?: number;
  intervalMs?: number;
};

export function createPerpKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: PerpKeeperConfig): Keeper {
  const interval = cfg.intervalMs ?? 5_000;
  const pkg = cfg.pkg;

  async function step(): Promise<void> {
    // 1) Funding update if available
    const f = cfg.fundingDelta1e6 ? await cfg.fundingDelta1e6() : null;
    if (f && f.delta1e6 > 0) {
      const txF = new Transaction();
      txF.moveCall({ target: `${pkg}::perpetuals::apply_funding_update`, arguments: [txF.object(cfg.oracleRegistryId), txF.object(cfg.marketId), txF.pure.bool(f.longsPay), txF.pure.u64(f.delta1e6), txF.object('0x6')] });
      if (await devInspectOk(client, sender, txF)) await exec(txF);
    }

    // 2) Liquidations
    const rows = await db.events.where('type').equals(`${pkg}::perpetuals::PositionChanged`).reverse().limit(cfg.maxVictims ?? 5).toArray();
    const seen = new Set<string>();
    for (const r of rows) {
      const p = (r.parsedJson as any) || {};
      const victim: string | undefined = p.who;
      if (!victim || seen.has(victim)) continue;
      seen.add(victim);
      const qty: bigint = BigInt(Math.max(1, Number(p.new_long || 0) + Number(p.new_short || 0) > 0 ? Math.ceil((Number(p.new_long || 0) + Number(p.new_short || 0)) * 0.1) : 1));
      const tx = new Transaction();
      tx.moveCall({
        target: `${pkg}::perpetuals::liquidate`,
        arguments: [tx.object(cfg.marketId), tx.pure.address(victim), tx.object(cfg.oracleRegistryId), tx.object(cfg.aggregatorId), tx.object(cfg.feeVaultId), tx.object('0x6'), tx.object('0x6'), tx.pure.u64(qty)],
      });
      if (await devInspectOk(client, sender, tx)) await exec(tx);
    }
  }

  return makeLoop(step, interval);
}


