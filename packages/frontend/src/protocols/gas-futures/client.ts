import { Transaction } from '@mysten/sui/transactions';

export class GasFuturesClient {
  private pkg: string;
  constructor(pkg: string) { this.pkg = pkg; }

  openLong(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::gas_futures::open_long`,
      arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), optUnxv, tx.object('0x6'), tx.pure.u64(args.qty)],
    });
    return tx;
  }

  openShort(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::gas_futures::open_short`,
      arguments: [tx.object(args.marketId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), optUnxv, tx.object('0x6'), tx.pure.u64(args.qty)],
    });
    return tx;
  }
}


