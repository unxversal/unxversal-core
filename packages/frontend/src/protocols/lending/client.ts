import { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';

export class LendingClient {
  private client: SuiClient;
  private pkg: string;
  constructor(client: SuiClient, pkg: string) { this.client = client; this.pkg = pkg; }

  // deposit<T>(pool: &mut LendingPool<T>, amount: Coin<T>, clock: &Clock, ctx: &mut TxContext)
  deposit(args: { poolId: string; amountCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::lending::deposit`,
      arguments: [tx.object(args.poolId), tx.object(args.amountCoinId), tx.object('0x6')],
    });
    return tx;
  }

  // withdraw<T>(pool: &mut LendingPool<T>, shares: u128, clock: &Clock, ctx: &mut TxContext): Coin<T>
  withdraw(args: { poolId: string; shares: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::withdraw`, arguments: [tx.object(args.poolId), tx.pure.u128(args.shares), tx.object('0x6')] });
    return tx;
  }

  // borrow<T>(pool: &mut LendingPool<T>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<T>
  borrow(args: { poolId: string; amount: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::borrow`, arguments: [tx.object(args.poolId), tx.pure.u64(args.amount), tx.object('0x6')] });
    return tx;
  }

  // borrow_with_fee<T>(pool, amount, staking_pool, cfg, clock, ctx)
  borrowWithFee(args: { poolId: string; amount: bigint; stakingPoolId: string; feeConfigId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::lending::borrow_with_fee`,
      arguments: [tx.object(args.poolId), tx.pure.u64(args.amount), tx.object(args.stakingPoolId), tx.object(args.feeConfigId), tx.object('0x6')],
    });
    return tx;
  }

  // repay<T>(pool: &mut LendingPool<T>, pay: Coin<T>, borrower: address, clock: &Clock, ctx: &mut TxContext): Coin<T>
  repay(args: { poolId: string; payCoinId: string; borrower: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::repay`, arguments: [tx.object(args.poolId), tx.object(args.payCoinId), tx.pure.address(args.borrower), tx.object('0x6')] });
    return tx;
  }

  // liquidate<T>(pool: &mut LendingPool<T>, borrower: address, repay_amount: Coin<T>, clock: &Clock, ctx: &mut TxContext): Coin<T>
  liquidate(args: { poolId: string; borrower: string; repayCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::liquidate`, arguments: [tx.object(args.poolId), tx.pure.address(args.borrower), tx.object(args.repayCoinId), tx.object('0x6')] });
    return tx;
  }
}


