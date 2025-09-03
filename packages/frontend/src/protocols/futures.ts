import { SuiClient, Transaction } from '@mysten/sui/client';
import { moveModuleFilter } from './common';
import type { IndexerTracker } from '../lib/indexer';

export function futuresEventTracker(pkg: string): IndexerTracker {
  return { id: 'futures', filter: moveModuleFilter(pkg, 'futures'), pageLimit: 200 };
}

export class FuturesClient {
  constructor(private client: SuiClient, private pkg: string) {}

  openLong<Collat extends string>(args: {
    marketId: string;
    oracleRegistryId: string;
    aggregatorId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    qty: bigint;
    maybeUnxvCoinId?: string;
  }) {
    const tx = new Transaction();
    const inputs = [
      tx.object(args.marketId),
      tx.object(args.oracleRegistryId),
      tx.object(args.aggregatorId),
      tx.object(args.feeConfigId),
      tx.object(args.feeVaultId),
      tx.object(args.stakingPoolId),
      args.maybeUnxvCoinId ? tx.object(args.maybeUnxvCoinId) : tx.pure.option('address', null),
      tx.object('0x6'),
      tx.pure.u64(args.qty),
    ];
    tx.moveCall({ target: `${this.pkg}::futures::open_long`, arguments: inputs as any });
    return tx;
  }
}


