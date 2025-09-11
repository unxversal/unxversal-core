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
export async function depositToBalanceManagerTx(
  pkgDeepbook: string,
  pkgUnxversal: string,
  balanceManagerId: string,
  coinId: string,
  coinType: string,
  feeConfigId: string,
  feeVaultId: string,
  stakingPoolId: string,
  maybeUnxvCoinId?: string,
) {
  const m = await import('@mysten/sui/transactions');
  const tx = new m.Transaction();

  // Option<Coin<UNXV>> for discount
  const unxvType = `${pkgUnxversal}::unxv::UNXV`;
  const optUnxv = maybeUnxvCoinId
    ? tx.moveCall({ target: `0x1::option::some`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(maybeUnxvCoinId)] })
    : tx.moveCall({ target: `0x1::option::none`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });

  // taker_fee_bps_override: None
  const optOverride = tx.moveCall({ target: `0x1::option::none`, typeArguments: ['u64'], arguments: [] });

  // Charge protocol fee from the deposit coin using bridge; returns reduced Coin<T>
  const [reducedCoin, _maybeUnxvBack] = tx.moveCall({
    target: `${pkgUnxversal}::bridge::take_protocol_fee_in_base<${coinType}>`,
    arguments: [
      tx.object(feeConfigId),
      tx.object(feeVaultId),
      tx.object(stakingPoolId),
      tx.object(coinId),
      optUnxv,
      optOverride,
      tx.object('0x6'),
    ],
  });

  // Deposit reduced coin into DeepBook BalanceManager
  tx.moveCall({
    target: `${pkgDeepbook}::balance_manager::deposit<${coinType}>`,
    arguments: [tx.object(balanceManagerId), reducedCoin],
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


