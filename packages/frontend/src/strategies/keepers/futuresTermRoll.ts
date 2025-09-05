import type { SuiClient } from '@mysten/sui/client';
import { devInspectOk, makeLoop, type Keeper, type TxExecutor } from '../../protocols/common';
import { FuturesClient } from '../../protocols/futures/client';

export type FuturesTermRollConfig = {
  pkg: string;
  front: { marketId: string; oracleRegistryId: string; aggregatorId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string };
  back: { marketId: string; oracleRegistryId: string; aggregatorId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string };
  qty: bigint; // calendar spread size per action
  refreshSecs?: number;
};

export function createFuturesTermRollKeeper(client: SuiClient, sender: string, exec: TxExecutor, cfg: FuturesTermRollConfig): Keeper {
  const fut = new FuturesClient(cfg.pkg);

  async function step(): Promise<void> {
    // Roll: short front, long back (or switch based on curve). v1: fixed direction.
    const txShortFront = fut.openShort({ marketId: cfg.front.marketId, oracleRegistryId: cfg.front.oracleRegistryId, aggregatorId: cfg.front.aggregatorId, feeConfigId: cfg.front.feeConfigId, feeVaultId: cfg.front.feeVaultId, stakingPoolId: cfg.front.stakingPoolId, qty: cfg.qty });
    if (await devInspectOk(client, sender, txShortFront)) await exec(txShortFront);
    const txLongBack = fut.openLong({ marketId: cfg.back.marketId, oracleRegistryId: cfg.back.oracleRegistryId, aggregatorId: cfg.back.aggregatorId, feeConfigId: cfg.back.feeConfigId, feeVaultId: cfg.back.feeVaultId, stakingPoolId: cfg.back.stakingPoolId, qty: cfg.qty });
    if (await devInspectOk(client, sender, txLongBack)) await exec(txLongBack);
  }

  return makeLoop(step, Math.max(1000, (cfg.refreshSecs ?? 60) * 1000));
}



