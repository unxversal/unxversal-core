import { Transaction } from '@mysten/sui/transactions';

export class FuturesClient {
  private readonly pkg: string;
  private readonly core: string;
  constructor(pkgFutures: string, corePkgId?: string) {
    this.pkg = pkgFutures;
    this.core = corePkgId ?? pkgFutures;
  }

  // ===== Collateral management =====
  depositCollateral<Collat extends string>(args: { marketId: string; collatCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::futures::deposit_collateral<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.collatCoinId)] as any });
    return tx;
  }

  withdrawCollateral<Collat extends string>(args: {
    marketId: string;
    amount: bigint;
    oracleRegistryId: string;
    aggregatorId: string;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::futures::withdraw_collateral<${(null as unknown as Collat)}>`,
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

  // ===== Trading (taker via matched engine) =====
  openLong<Collat extends string>(args: {
    marketId: string;
    oracleRegistryId: string;
    aggregatorId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    rewardsId: string;
    qty: bigint;
    maybeUnxvCoinId?: string;
  }) {
    const tx = new Transaction();
    const unxvType = `${this.core}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::futures::open_long<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.rewardsId),
        optUnxv,
        tx.object('0x6'),
        tx.pure.u64(args.qty),
      ],
    } as any);
    return tx;
  }

  openShort<Collat extends string>(args: {
    marketId: string;
    oracleRegistryId: string;
    aggregatorId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    rewardsId: string;
    qty: bigint;
    maybeUnxvCoinId?: string;
  }) {
    const tx = new Transaction();
    const unxvType = `${this.core}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::futures::open_short<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.rewardsId),
        optUnxv,
        tx.object('0x6'),
        tx.pure.u64(args.qty),
      ],
    } as any);
    return tx;
  }

  closeLong<Collat extends string>(args: {
    marketId: string;
    oracleRegistryId: string;
    aggregatorId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    rewardsId: string;
    qty: bigint;
    maybeUnxvCoinId?: string;
  }) {
    const tx = new Transaction();
    const unxvType = `${this.core}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::futures::close_long<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.rewardsId),
        optUnxv,
        tx.object('0x6'),
        tx.pure.u64(args.qty),
      ],
    } as any);
    return tx;
  }

  closeShort<Collat extends string>(args: {
    marketId: string;
    oracleRegistryId: string;
    aggregatorId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    rewardsId: string;
    qty: bigint;
    maybeUnxvCoinId?: string;
  }) {
    const tx = new Transaction();
    const unxvType = `${this.core}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::futures::close_short<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.rewardsId),
        optUnxv,
        tx.object('0x6'),
        tx.pure.u64(args.qty),
      ],
    } as any);
    return tx;
  }

  // ===== Maker orders =====
  placeLimitBid<Collat extends string>(args: {
    marketId: string;
    price1e6: bigint;
    qty: bigint;
    expireTs: bigint;
    oracleRegistryId: string;
    aggregatorId: string;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::futures::place_limit_bid<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u64(args.price1e6),
        tx.pure.u64(args.qty),
        tx.pure.u64(args.expireTs),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }

  placeLimitAsk<Collat extends string>(args: {
    marketId: string;
    price1e6: bigint;
    qty: bigint;
    expireTs: bigint;
    oracleRegistryId: string;
    aggregatorId: string;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::futures::place_limit_ask<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u64(args.price1e6),
        tx.pure.u64(args.qty),
        tx.pure.u64(args.expireTs),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }

  cancelOrder<Collat extends string>(args: { marketId: string; orderId: bigint; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::futures::cancel_order<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.pure.u128(args.orderId), tx.object(args.oracleRegistryId), tx.object(args.aggregatorId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  // ===== Liquidation & Settlement =====
  liquidate<Collat extends string>(args: { marketId: string; victim: string; qty: bigint; oracleRegistryId: string; aggregatorId: string; feeVaultId: string; rewardsId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::futures::liquidate<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.address(args.victim),
        tx.pure.u64(args.qty),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object(args.feeVaultId),
        tx.object(args.rewardsId),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }

  settleAfterExpiry<Collat extends string>(args: { marketId: string; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::futures::settle_after_expiry<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.oracleRegistryId), tx.object(args.aggregatorId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  claimPnlCredit<Collat extends string>(args: { marketId: string; feeVaultId: string; maxAmount?: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::futures::claim_pnl_credit<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.feeVaultId), tx.object('0x6'), tx.pure.u64(args.maxAmount ?? 0n)] } as any);
    return tx;
  }
}


