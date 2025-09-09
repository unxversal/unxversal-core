import { Transaction } from '@mysten/sui/transactions';

export class LendingClient {
  private pkg: string;
  constructor(pkg: string) { this.pkg = pkg; }

  // Dual-asset debt supplier: supply USDU-like Debt into market liquidity
  supplyDebt(args: { marketId: string; amountCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::supply_debt`, arguments: [tx.object(args.marketId), tx.object(args.amountCoinId), tx.object('0x6')] });
    return tx;
  }

  // Withdraw Debt by burning supplier shares
  withdrawDebt(args: { marketId: string; shares: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::withdraw_debt`, arguments: [tx.object(args.marketId), tx.pure.u128(args.shares), tx.object('0x6')] });
    return tx;
  }

  // Deposit collateral (Collat) to enable borrowing
  depositCollateral(args: { marketId: string; collatCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::deposit_collateral2`, arguments: [tx.object(args.marketId), tx.object(args.collatCoinId)] });
    return tx;
  }

  // Withdraw collateral with oracle health check
  withdrawCollateral(args: { marketId: string; amount: bigint; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::withdraw_collateral2`, arguments: [tx.object(args.marketId), tx.pure.u64(args.amount), tx.object(args.oracleRegistryId), tx.object(args.aggregatorId), tx.object('0x6')] });
    return tx;
  }

  // Borrow Debt against posted collateral
  borrowDebt(args: { marketId: string; amount: bigint; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::borrow_debt`, arguments: [tx.object(args.marketId), tx.pure.u64(args.amount), tx.object(args.oracleRegistryId), tx.object(args.aggregatorId), tx.object('0x6')] });
    return tx;
  }

  // Repay Debt for self or on behalf of borrower
  repayDebt(args: { marketId: string; payCoinId: string; borrower: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::repay_debt`, arguments: [tx.object(args.marketId), tx.object(args.payCoinId), tx.pure.address(args.borrower), tx.object('0x6')] });
    return tx;
  }

  // Liquidate unhealthy borrower: repay Debt and seize Collat with bonus
  liquidate(args: { marketId: string; borrower: string; repayCoinId: string; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::liquidate2`, arguments: [tx.object(args.marketId), tx.pure.address(args.borrower), tx.object(args.repayCoinId), tx.object(args.oracleRegistryId), tx.object(args.aggregatorId), tx.object('0x6')] });
    return tx;
  }
}


