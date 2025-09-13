import { Transaction } from '@mysten/sui/transactions';

export class XFutureClient {
  private readonly pkg: string;
  constructor(pkgUnxversal: string) { this.pkg = pkgUnxversal; }

  // ===== Collateral =====
  depositCollateral<Collat extends string>(args: { marketId: string; collatCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::deposit_collateral<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.collatCoinId), tx.object('0x6')] } as any);
    return tx;
  }

  withdrawCollateral<Collat extends string>(args: { marketId: string; amount: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::withdraw_collateral<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.u64(args.amount), tx.object('0x6'), tx.object('0x6')] } as any);
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
    tx.moveCall({ target: `${this.pkg}::xfutures::open_long<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.pure.u64(args.qty)] } as any);
    return tx;
  }

  openShort<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({ target: `${this.pkg}::xfutures::open_short<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.pure.u64(args.qty)] } as any);
    return tx;
  }

  closeLong<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({ target: `${this.pkg}::xfutures::close_long<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.pure.u64(args.qty)] } as any);
    return tx;
  }

  closeShort<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const optUnxv = this.optUnxv(tx, args.maybeUnxvCoinId);
    tx.moveCall({ target: `${this.pkg}::xfutures::close_short<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), optUnxv, tx.object('0x6'), tx.pure.u64(args.qty)] } as any);
    return tx;
  }

  // ===== Maker orders =====
  placeLimitBid<Collat extends string>(args: { marketId: string; price1e6: bigint; qty: bigint; expireTs: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::place_limit_bid<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.u64(args.price1e6), tx.pure.u64(args.qty), tx.pure.u64(args.expireTs), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  placeLimitAsk<Collat extends string>(args: { marketId: string; price1e6: bigint; qty: bigint; expireTs: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::place_limit_ask<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.u64(args.price1e6), tx.pure.u64(args.qty), tx.pure.u64(args.expireTs), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  cancelOrder<Collat extends string>(args: { marketId: string; orderId: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::cancel_order<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.u128(args.orderId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  // ===== Liquidation & Settlement =====
  liquidate<Collat extends string>(args: { marketId: string; victim: string; qty: bigint; feeConfigId: string; feeVaultId: string; rewardsId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::liquidate<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.address(args.victim), tx.pure.u64(args.qty), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.rewardsId), tx.object('0x6')] } as any);
    return tx;
  }

  snapSettlementPrice<Collat extends string>(args: { marketId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::snap_settlement_price<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  settleSelf<Collat extends string>(args: { marketId: string; feeVaultId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xfutures::settle_self<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.feeVaultId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }
}


