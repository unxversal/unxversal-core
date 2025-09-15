import { Transaction } from '@mysten/sui/transactions';

export class PerpetualsClient {
  private readonly pkg: string;
  private readonly core: string;
  constructor(pkgPerps: string, corePkgId?: string) { this.pkg = pkgPerps; this.core = corePkgId ?? pkgPerps; }

  // ===== Collateral =====
  depositCollateral<Collat extends string>(args: { marketId: string; collatCoinId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::perpetuals::deposit_collateral<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object(args.collatCoinId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  withdrawCollateral<Collat extends string>(args: { marketId: string; amount: bigint; oracleRegistryId: string; aggregatorId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::perpetuals::withdraw_collateral<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u64(args.amount),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    } as any);
    return tx;
  }

  // ===== Trading =====
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
      target: `${this.pkg}::perpetuals::open_long<${(null as unknown as Collat)}>`,
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
      target: `${this.pkg}::perpetuals::open_short<${(null as unknown as Collat)}>`,
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
      target: `${this.pkg}::perpetuals::close_long<${(null as unknown as Collat)}>`,
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
      target: `${this.pkg}::perpetuals::close_short<${(null as unknown as Collat)}>`,
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
        tx.object('0x6'),
        tx.pure.u64(args.qty),
      ],
    } as any);
    return tx;
  }

  // ===== Funding & Liquidation =====
  settleFundingForCaller<Collat extends string>(args: { marketId: string }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::perpetuals::settle_funding_for_caller<${(null as unknown as Collat)}>`, arguments: [tx.object(args.marketId), tx.object('0x6'), tx.object('0x6')] } as any);
    return tx;
  }

  liquidate<Collat extends string>(args: { marketId: string; victim: string; qty: bigint; oracleRegistryId: string; aggregatorId: string; feeVaultId: string; rewardsId: string }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::perpetuals::liquidate<${(null as unknown as Collat)}>`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.address(args.victim),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        tx.object(args.feeVaultId),
        tx.object(args.rewardsId),
        tx.object('0x6'),
        tx.object('0x6'),
        tx.pure.u64(args.qty),
      ],
    } as any);
    return tx;
  }
}


