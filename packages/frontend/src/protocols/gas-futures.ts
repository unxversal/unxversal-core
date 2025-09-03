import { SuiClient, Transaction } from '@mysten/sui/client';
import { moveModuleFilter } from './common';
import type { IndexerTracker } from '../lib/indexer';

export function gasFuturesEventTracker(pkg: string): IndexerTracker {
  return { id: 'gas_futures', filter: moveModuleFilter(pkg, 'gas_futures'), pageLimit: 200 };
}

export class GasFuturesClient {
  constructor(private client: SuiClient, private pkg: string) {}

  openLong<Collat extends string>(args: { marketId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; qty: bigint; maybeUnxvCoinId?: string }) {
    const tx = new Transaction();
    const inputs = [
      tx.object(args.marketId),
      tx.object(args.feeConfigId),
      tx.object(args.feeVaultId),
      tx.object(args.stakingPoolId),
      args.maybeUnxvCoinId ? tx.object(args.maybeUnxvCoinId) : tx.pure.option('address', null),
      tx.object('0x6'),
      tx.pure.u64(args.qty),
    ];
    tx.moveCall({ target: `${this.pkg}::gas_futures::open_long`, arguments: inputs as any });
    return tx;
  }
}


