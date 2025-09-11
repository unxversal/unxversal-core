import type { IndexerTracker } from '../../lib/indexer';
import { moveModuleFilter } from '../common';
export { DexClient } from './dex';
export * as DexEvents from './dex-events';
export { createDexKeeper } from './keeper';

export function dexEventTracker(pkg: string): IndexerTracker {
  return { id: `dex:${pkg}`, filter: moveModuleFilter(pkg, 'dex'), pageLimit: 200 };
}

// Build a PTB to create and share a DeepBook BalanceManager
export async function createAndShareBalanceManagerTx(pkgDeepbook: string) {
  const m = await import('@mysten/sui/transactions');
  const tx = new m.Transaction();
  const bm = tx.moveCall({ target: `${pkgDeepbook}::balance_manager::new`, arguments: [ ] });
  tx.moveCall({ target: `0x2::transfer::share_object`, arguments: [bm] });
  return tx;
}

// Deposit helper: deposit a Coin<T> into BalanceManager using owner path
export async function depositToBalanceManagerTx(pkgDeepbook: string, balanceManagerId: string, coinId: string, coinType: string) {
  const m = await import('@mysten/sui/transactions');
  const tx = new m.Transaction();
  tx.moveCall({
    target: `${pkgDeepbook}::balance_manager::deposit<${coinType}>`,
    arguments: [tx.object(balanceManagerId), tx.object(coinId)],
  });
  return tx;
}

// Withdraw helper: withdraw amount (or all) from BalanceManager owner path
export async function withdrawFromBalanceManagerTx(pkgDeepbook: string, balanceManagerId: string, amount: bigint, coinType: string) {
  const m = await import('@mysten/sui/transactions');
  const tx = new m.Transaction();
  tx.moveCall({
    target: `${pkgDeepbook}::balance_manager::withdraw<${coinType}>`,
    arguments: [tx.object(balanceManagerId), tx.pure.u64(amount)],
  });
  // withdraw returns Coin<T>; leave coin in outputs for wallet to return to sender or handle externally
  return tx;
}


