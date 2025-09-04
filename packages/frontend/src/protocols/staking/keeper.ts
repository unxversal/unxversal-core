import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { makeLoop, type Keeper, devInspectOk, type TxExecutor } from '../common';

export type StakingKeeperConfig = {
  pkg: string;
  stakingPoolId: string;
  // Strategy provides UNXV reward coin object id to deposit as weekly reward
  getRewardCoinId: () => Promise<string | null>;
  intervalMs?: number;
};

export function createStakingKeeper(_client: SuiClient, _sender: string, exec: TxExecutor, cfg: StakingKeeperConfig): Keeper {
  const interval = cfg.intervalMs ?? 60_000; // typically weekly, but keep manual

  async function step(): Promise<void> {
    const coinId = await cfg.getRewardCoinId();
    if (!coinId) return;
    const tx = new Transaction();
    tx.moveCall({ target: `${cfg.pkg}::staking::add_weekly_reward`, arguments: [tx.object(cfg.stakingPoolId), tx.object(coinId), tx.object('0x6')] });
    // add_weekly_reward is simple; skip devInspect to ensure reward is applied
    await exec(tx);
  }

  return makeLoop(step, interval);
}


