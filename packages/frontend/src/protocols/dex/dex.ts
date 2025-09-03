import { SuiClient } from '@mysten/sui/client';
import { moveModuleFilter } from '../common';
import type { IndexerTracker } from '../../lib/indexer';
import { Transaction } from '@mysten/sui/transactions';

export function dexEventTracker(pkg: string): IndexerTracker {
  return {
    id: `dex:${pkg}`,
    filter: moveModuleFilter(pkg, 'dex'),
    pageLimit: 200,
  };
}

export class DexClient {
  private client: SuiClient;
  private pkg: string;
  constructor(client: SuiClient, pkg: string) { this.client = client; this.pkg = pkg; }
  placeLimitOrder(args: {
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
    feeConfigId: string;
    feeVaultId: string;
    clientOrderId: bigint;
    orderType: number; // u8
    selfMatchingOption: number; // u8
    price: bigint; // u64
    quantity: bigint; // u64
    isBid: boolean;
    payWithDeep: boolean;
    expireTimestamp: bigint; // u64
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::place_limit_order`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tx.object(args.tradeProofId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.orderType),
        tx.pure.u8(args.selfMatchingOption),
        tx.pure.u64(args.price),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.isBid),
        tx.pure.bool(args.payWithDeep),
        tx.pure.u64(args.expireTimestamp),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeMarketOrder(args: {
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
    feeConfigId: string;
    feeVaultId: string;
    clientOrderId: bigint;
    selfMatchingOption: number; // u8
    quantity: bigint; // u64
    isBid: boolean;
    payWithDeep: boolean;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tx.object(args.tradeProofId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.selfMatchingOption),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.isBid),
        tx.pure.bool(args.payWithDeep),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  cancelOrder(args: {
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
    orderId: bigint;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::cancel_order`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tx.object(args.tradeProofId),
        tx.pure.u128(args.orderId),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  modifyOrder(args: {
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
    orderId: bigint;
    newQuantity: bigint;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::modify_order`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tx.object(args.tradeProofId),
        tx.pure.u128(args.orderId),
        tx.pure.u64(args.newQuantity),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  withdrawSettledAmounts(args: {
    poolId: string;
    balanceManagerId: string;
    tradeProofId: string;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::withdraw_settled_amounts`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tx.object(args.tradeProofId),
      ],
    });
    return tx;
  }
  createPermissionlessPool(args: {
    registryId: string; // DeepBook registry
    feeConfigId: string;
    feeVaultId: string;
    feePaymentUnxvCoinId: string; // Coin<UNXV>
    tickSize: bigint;
    lotSize: bigint;
    minSize: bigint;
    stakingPoolId: string;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::create_permissionless_pool`,
      arguments: [
        tx.object(args.registryId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.feePaymentUnxvCoinId),
        tx.pure.u64(args.tickSize),
        tx.pure.u64(args.lotSize),
        tx.pure.u64(args.minSize),
        tx.object(args.stakingPoolId),
        tx.object('0x6'),
      ],
    });
    return tx;
  }
}


