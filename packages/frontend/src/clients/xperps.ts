import { Transaction } from '@mysten/sui/transactions';

export class XPerpsClient {
  private readonly pkg: string;
  constructor(pkgUnxversal: string) { this.pkg = pkgUnxversal; }

  // ===== Collateral =====
  depositCollateral<Collat extends string>(args: { marketId: string; collatCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xperps::deposit_collateral<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.collatCoinId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  withdrawCollateral<Collat extends string>(args: { marketId: string; amount: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xperps::withdraw_collateral<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.u64(args.amount), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  // ===== Trading (matched engine) =====
  private optUnxv(tx: Transaction, unxvCoinId?: string) {
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const coin = `0x2::coin::Coin<${unxvType}>`;
    return unxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [coin], arguments: [tx.object(unxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [coin], arguments: [] });
  }

  openLong<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({
      target: `${this.pkg}::xperps::open_long<${(null as unknown as Collat)}>`,
      arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.object('0x6'), tx.pure.u64(args.qty)],
    } as any);
    return tx;
  }

  openShort<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({
      target: `${this.pkg}::xperps::open_short<${(null as unknown as Collat)}>`,
      arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.object('0x6'), tx.pure.u64(args.qty)],
    } as any);
    return tx;
  }

  closeLong<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({
      target: `${this.pkg}::xperps::close_long<${(null as unknown as Collat)}>`,
      arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.object('0x6'), tx.pure.u64(args.qty)],
    } as any);
    return tx;
  }

  closeShort<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({
      target: `${this.pkg}::xperps::close_short<${(null as unknown as Collat)}>`,
      arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.object('0x6'), tx.pure.u64(args.qty)],
    } as any);
    return tx;
  }

  // ===== Funding & liquidation =====
  settleFundingForCaller<Collat extends string>(args: { marketId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xperps::settle_funding_for_caller<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  liquidate<Collat extends string>(args: { marketId: string; victim: string; qty: bigint; feeConfigId: string; feeVaultId: string; rewardsId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::xperps::liquidate<${(null as unknown as Collat)}>`,
      arguments: [tx.object(args.marketId), tx.pure.address(args.victim), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.rewardsId), tx.object('0x6'), tx.object('0x6'), tx.pure.u64(args.qty)],
    } as any);
    return tx;
  }
}


