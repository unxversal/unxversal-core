import { moveModuleFilter } from '../common';
import type { IndexerTracker } from '../../lib/indexer';
import { Transaction } from '@mysten/sui/transactions';
import { getContracts } from '../../lib/env';

export function dexEventTracker(pkg: string): IndexerTracker {
  return {
    id: `dex:${pkg}`,
    filter: moveModuleFilter(pkg, 'dex'),
    pageLimit: 200,
  };
}

export class DexClient {
  private pkg: string;
  constructor(pkg: string) { this.pkg = pkg; }
  placeLimitOrder(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
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
    // generate TradeProof as owner inside PTB
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({
      target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`,
      arguments: [tx.object(args.balanceManagerId)],
    });
    tx.moveCall({
      target: `${this.pkg}::dex::place_limit_order`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
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
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    feeConfigId: string;
    feeVaultId: string;
    clientOrderId: bigint;
    selfMatchingOption: number; // u8
    quantity: bigint; // u64
    isBid: boolean;
    payWithDeep: boolean;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({
      target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`,
      arguments: [tx.object(args.balanceManagerId)],
    });
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
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
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    orderId: bigint;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({
      target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`,
      arguments: [tx.object(args.balanceManagerId)],
    });
    tx.moveCall({
      target: `${this.pkg}::dex::cancel_order`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
        tx.pure.u128(args.orderId),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  modifyOrder(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    orderId: bigint;
    newQuantity: bigint;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({
      target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`,
      arguments: [tx.object(args.balanceManagerId)],
    });
    tx.moveCall({
      target: `${this.pkg}::dex::modify_order`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
        tx.pure.u128(args.orderId),
        tx.pure.u64(args.newQuantity),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  withdrawSettledAmounts(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({
      target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`,
      arguments: [tx.object(args.balanceManagerId)],
    });
    tx.moveCall({
      target: `${this.pkg}::dex::withdraw_settled_amounts`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
      ],
    });
    return tx;
  }

  // Injection-fee variants (prefer_deep_backend = false path)
  placeLimitOrderWithProtocolFeeBid(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentQuoteCoinId: string; // Coin<Quote>
    maybeUnxvCoinId?: string; // Coin<UNXV>
    clientOrderId: bigint;
    orderType: number;
    selfMatchingOption: number;
    price: bigint;
    quantity: bigint;
    payWithDeep: boolean;
    expireTimestamp: bigint;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({ target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`, arguments: [tx.object(args.balanceManagerId)] });
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: `0x1::option::some`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: `0x1::option::none`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::dex::place_limit_order_with_protocol_fee_bid`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentQuoteCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.orderType),
        tx.pure.u8(args.selfMatchingOption),
        tx.pure.u64(args.price),
        tx.pure.u64(args.quantity),
        tx.pure.bool(true),
        tx.pure.bool(args.payWithDeep),
        tx.pure.u64(args.expireTimestamp),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeLimitOrderWithProtocolFeeAsk(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentBaseCoinId: string; // Coin<Base>
    maybeUnxvCoinId?: string; // Coin<UNXV>
    clientOrderId: bigint;
    orderType: number;
    selfMatchingOption: number;
    price: bigint;
    quantity: bigint;
    payWithDeep: boolean;
    expireTimestamp: bigint;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({ target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`, arguments: [tx.object(args.balanceManagerId)] });
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: `0x1::option::some`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: `0x1::option::none`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::dex::place_limit_order_with_protocol_fee_ask`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentBaseCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.orderType),
        tx.pure.u8(args.selfMatchingOption),
        tx.pure.u64(args.price),
        tx.pure.u64(args.quantity),
        tx.pure.bool(false),
        tx.pure.bool(args.payWithDeep),
        tx.pure.u64(args.expireTimestamp),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeMarketOrderWithProtocolFeeBid(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentQuoteCoinId: string;
    maybeUnxvCoinId?: string;
    clientOrderId: bigint;
    selfMatchingOption: number;
    quantity: bigint;
    payWithDeep: boolean;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({ target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`, arguments: [tx.object(args.balanceManagerId)] });
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: `0x1::option::some`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: `0x1::option::none`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order_with_protocol_fee_bid`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentQuoteCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.selfMatchingOption),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.payWithDeep),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeMarketOrderWithProtocolFeeAsk(args: {
    baseType: string;
    quoteType: string;
    poolId: string;
    balanceManagerId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentBaseCoinId: string;
    maybeUnxvCoinId?: string;
    clientOrderId: bigint;
    selfMatchingOption: number;
    quantity: bigint;
    payWithDeep: boolean;
  }) {
    const tx = new Transaction();
    const { pkgDeepbook } = getContracts();
    const gen = tx.moveCall({ target: `${pkgDeepbook}::balance_manager::generate_proof_as_owner`, arguments: [tx.object(args.balanceManagerId)] });
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: `0x1::option::some`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: `0x1::option::none`, typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order_with_protocol_fee_ask`,
      typeArguments: [args.baseType, args.quoteType],
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        gen,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentBaseCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.selfMatchingOption),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.payWithDeep),
        tx.object('0x6'),
      ],
    });
    return tx;
  }
  createPermissionlessPool(args: {
    baseType: string;
    quoteType: string;
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
      typeArguments: [args.baseType, args.quoteType],
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


