import { Transaction } from '@mysten/sui/transactions';

export class StakingClient {
  private readonly pkg: string;
  constructor(pkgUnxversal: string) { this.pkg = pkgUnxversal; }

  /**
   * Stake UNXV into the staking pool. Stake activates next week.
   * - poolId: `unxversal::staking::StakingPool` object id
   * - unxvCoinId: object id of `Coin<UNXV>` to deposit
   */
  stakeUnx(args: { poolId: string; unxvCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::staking::stake_unx`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.unxvCoinId),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /**
   * Schedule an unstake of UNXV, effective at the next week boundary.
   * - amount: base units (UNXV decimals)
   * Returns a Coin<UNXV> immediately as principal outflow per module design.
   */
  unstakeUnx(args: { poolId: string; amount: bigint | number }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::staking::unstake_unx`,
      arguments: [
        tx.object(args.poolId),
        tx.pure.u64(args.amount as bigint),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /**
   * Claim accrued UNXV rewards for all fully completed weeks since last claim.
   */
  claimRewards(args: { poolId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::staking::claim_rewards`,
      arguments: [
        tx.object(args.poolId),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /**
   * Add weekly UNXV reward to the current week. Intended for protocol/admin use.
   * - rewardCoinId: object id of `Coin<UNXV>` to deposit into the reward vault
   */
  addWeeklyReward(args: { poolId: string; rewardCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::staking::add_weekly_reward`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.rewardCoinId),
        tx.object('0x6'),
      ],
    });
    return tx;
  }
}


