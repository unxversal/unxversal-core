import { Transaction } from '@mysten/sui/transactions';

export class StakingClient {
  private pkg: string;
  constructor(pkg: string) { this.pkg = pkg; }

  stake(args: { poolId: string; unxvCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::staking::stake_unx`,
      arguments: [tx.object(args.poolId), tx.object(args.unxvCoinId), tx.object('0x6')],
    });
    return tx;
  }

  unstake(args: { poolId: string; amount: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::staking::unstake_unx`, arguments: [tx.object(args.poolId), tx.pure.u64(args.amount), tx.object('0x6')] });
    return tx;
  }

  addWeeklyReward(args: { poolId: string; unxvRewardCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::staking::add_weekly_reward`, arguments: [tx.object(args.poolId), tx.object(args.unxvRewardCoinId), tx.object('0x6')] });
    return tx;
  }

  claimRewards(args: { poolId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::staking::claim_rewards`, arguments: [tx.object(args.poolId), tx.object('0x6')] });
    return tx;
  }
}


