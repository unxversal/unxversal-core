import { Transaction } from '@mysten/sui/transactions';

export class LendingClient {
  private readonly pkg: string;
  constructor(pkgUnxversal: string) { this.pkg = pkgUnxversal; }

  // ===== Debt supplier flows (Debt side liquidity) =====
  supplyDebt<Collat extends string, Debt extends string>(args: { marketId: string; amountDebtCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::supply_debt<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`, arguments: [tx.object(args.marketId), tx.object(args.amountDebtCoinId), tx.object('0x6')] } as any);
    return tx;
  }

  withdrawDebt<Collat extends string, Debt extends string>(args: { marketId: string; shares: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::withdraw_debt<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`, arguments: [tx.object(args.marketId), tx.pure.u128(args.shares), tx.object('0x6')] } as any);
    return tx;
  }

  // ===== Collateral flows (deposit collateral / withdraw with oracle checks) =====
  depositCollateral<Collat extends string, Debt extends string>(args: { marketId: string; collatCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::deposit_collateral2<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`, arguments: [tx.object(args.marketId), tx.object(args.collatCoinId)] } as any);
    return tx;
  }

  withdrawCollateral<Collat extends string, Debt extends string>(args: { marketId: string; amount: bigint; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::lending::withdraw_collateral2<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u64(args.amount),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }

  // ===== Borrow / Repay =====
  borrowDebt<Collat extends string, Debt extends string>(args: { marketId: string; amount: bigint; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::lending::borrow_debt<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u64(args.amount),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }

  repayDebt<Collat extends string, Debt extends string>(args: { marketId: string; payDebtCoinId: string; borrower: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::lending::repay_debt<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`, arguments: [tx.object(args.marketId), tx.object(args.payDebtCoinId), tx.pure.address(args.borrower), tx.object('0x6')] } as any);
    return tx;
  }

  // ===== Liquidation =====
  liquidate<Collat extends string, Debt extends string>(args: { marketId: string; borrower: string; repayDebtCoinId: string; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::lending::liquidate2<${(null as unknown as Collat)}, ${(null as unknown as Debt)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.address(args.borrower),
        tx.object(args.repayDebtCoinId),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }
}


