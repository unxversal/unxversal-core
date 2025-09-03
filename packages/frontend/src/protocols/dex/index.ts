import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { DexClient } from './dex';
export * as DexEvents from './dex-events';

export function dexEventTracker(pkg: string): IndexerTracker {
  return { id: `dex:${pkg}`, filter: moveModuleFilter(pkg, 'dex'), pageLimit: 200 };
}

// Build a PTB to create and share a DeepBook BalanceManager
export async function createAndShareBalanceManagerTx(pkgDeepbook: string) {
  const m = await import('@mysten/sui/transactions');
  const tx = new m.Transaction();
  const bm = tx.moveCall({ target: `${pkgDeepbook}::balance_manager::new`, arguments: [] });
  tx.moveCall({ target: `0x2::transfer::share_object`, arguments: [bm] });
  return tx;
}


