import { Transaction } from '@mysten/sui/transactions';

export class DexClient {
  private readonly pkg: string;
  private readonly deepbookPkg: string;
  private readonly core: string;
  constructor(pkgDex: string, deepbookPackageId: string, corePkgId?: string) {
    this.pkg = pkgDex;
    this.deepbookPkg = deepbookPackageId;
    this.core = corePkgId ?? pkgDex;
  }

  // ===== Helpers =====
  private coinType(inner: string): string { return `0x2::coin::Coin<${inner}>`; }
  private optNone(tx: Transaction, typeTag: string) { return tx.moveCall({ target: '0x1::option::none', typeArguments: [typeTag], arguments: [] }); }
  private optSomeObj(tx: Transaction, typeTag: string, id: string) { return tx.moveCall({ target: '0x1::option::some', typeArguments: [typeTag], arguments: [tx.object(id)] }); }
  private genProofAsOwner(tx: Transaction, balanceManagerId: string) {
    return tx.moveCall({ target: `${this.deepbookPkg}::balance_manager::generate_proof_as_owner`, arguments: [tx.object(balanceManagerId), tx.object('0x6')] });
  }

  // ===== Orders with protocol fee injection =====
  placeLimitOrderWithProtocolFeeBid(args: {
    baseType: string; quoteType: string;
    poolId: string; balanceManagerId: string;
    feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    feePaymentQuoteCoinId: string; // Coin<Quote>
    maybeUnxvCoinId?: string;      // Coin<UNXV>
    clientOrderId: bigint; orderType?: number; selfMatchingOption?: number;
    price: bigint; quantity: bigint; payWithDeep?: boolean; expireTimestampMs: bigint;
  }) {
    const tx = new Transaction();
    const tradeProof = this.genProofAsOwner(tx, args.balanceManagerId);
    const unxvType = `${this.core}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    tx.moveCall({
      target: `${this.pkg}::dex::place_limit_order_with_protocol_fee_bid<${args.baseType}, ${args.quoteType}>`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tradeProof,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentQuoteCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.orderType ?? 0),
        tx.pure.u8(args.selfMatchingOption ?? 0),
        tx.pure.u64(args.price),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.payWithDeep ?? false),
        tx.pure.u64(args.expireTimestampMs),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeLimitOrderWithProtocolFeeAsk(args: {
    baseType: string; quoteType: string;
    poolId: string; balanceManagerId: string;
    feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    feePaymentBaseCoinId: string; // Coin<Base>
    maybeUnxvCoinId?: string;     // Coin<UNXV>
    clientOrderId: bigint; orderType?: number; selfMatchingOption?: number;
    price: bigint; quantity: bigint; payWithDeep?: boolean; expireTimestampMs: bigint;
  }) {
    const tx = new Transaction();
    const tradeProof = this.genProofAsOwner(tx, args.balanceManagerId);
    const unxvType = `${this.core}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    tx.moveCall({
      target: `${this.pkg}::dex::place_limit_order_with_protocol_fee_ask<${args.baseType}, ${args.quoteType}>`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tradeProof,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentBaseCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.orderType ?? 0),
        tx.pure.u8(args.selfMatchingOption ?? 0),
        tx.pure.u64(args.price),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.payWithDeep ?? false),
        tx.pure.u64(args.expireTimestampMs),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeMarketOrderWithProtocolFeeBid(args: {
    baseType: string; quoteType: string;
    poolId: string; balanceManagerId: string;
    feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    feePaymentQuoteCoinId: string; // Coin<Quote>
    maybeUnxvCoinId?: string;     // Coin<UNXV>
    clientOrderId: bigint; selfMatchingOption?: number; quantity: bigint; payWithDeep?: boolean;
  }) {
    const tx = new Transaction();
    const tradeProof = this.genProofAsOwner(tx, args.balanceManagerId);
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order_with_protocol_fee_bid<${args.baseType}, ${args.quoteType}>`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tradeProof,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentQuoteCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.selfMatchingOption ?? 0),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.payWithDeep ?? false),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  placeMarketOrderWithProtocolFeeAsk(args: {
    baseType: string; quoteType: string;
    poolId: string; balanceManagerId: string;
    feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    feePaymentBaseCoinId: string; // Coin<Base>
    maybeUnxvCoinId?: string;     // Coin<UNXV>
    clientOrderId: bigint; selfMatchingOption?: number; quantity: bigint; payWithDeep?: boolean;
  }) {
    const tx = new Transaction();
    const tradeProof = this.genProofAsOwner(tx, args.balanceManagerId);
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order_with_protocol_fee_ask<${args.baseType}, ${args.quoteType}>`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tradeProof,
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.feePaymentBaseCoinId),
        optUnxv,
        tx.pure.u64(args.clientOrderId),
        tx.pure.u8(args.selfMatchingOption ?? 0),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.payWithDeep ?? false),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  // ===== Swaps (protocol fee on input; optional UNXV discount) =====
  swapExactBaseForQuote(args: {
    baseType: string; quoteType: string;
    poolId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    baseCoinId: string; maybeUnxvCoinId?: string; minQuoteOut: bigint;
  }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    tx.moveCall({
      target: `${this.pkg}::dex::swap_exact_base_for_quote<${args.baseType}, ${args.quoteType}>`,
        arguments: [
        tx.object(args.poolId),
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
        tx.object(args.baseCoinId),
        optUnxv,
          tx.object(args.stakingPoolId),
        tx.pure.u64(args.minQuoteOut),
          tx.object('0x6'),
        ],
      });
    return tx;
  }

  swapExactQuoteForBase(args: {
    baseType: string; quoteType: string;
    poolId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    quoteCoinId: string; maybeUnxvCoinId?: string; minBaseOut: bigint;
  }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    tx.moveCall({
      target: `${this.pkg}::dex::swap_exact_quote_for_base<${args.baseType}, ${args.quoteType}>`,
        arguments: [
        tx.object(args.poolId),
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
        tx.object(args.quoteCoinId),
        optUnxv,
          tx.object(args.stakingPoolId),
        tx.pure.u64(args.minBaseOut),
          tx.object('0x6'),
        ],
      });
    return tx;
  }

  // ===== Order management =====
  cancelOrder(args: { baseType: string; quoteType: string; poolId: string; balanceManagerId: string; orderId: bigint; }) {
    const tx = new Transaction();
    const proof = this.genProofAsOwner(tx, args.balanceManagerId);
    tx.moveCall({
      target: `${this.pkg}::dex::cancel_order<${args.baseType}, ${args.quoteType}>`,
      arguments: [tx.object(args.poolId), tx.object(args.balanceManagerId), proof, tx.pure.u128(args.orderId), tx.object('0x6')],
    });
    return tx;
  }

  modifyOrder(args: { baseType: string; quoteType: string; poolId: string; balanceManagerId: string; orderId: bigint; newQuantity: bigint; }) {
    const tx = new Transaction();
    const proof = this.genProofAsOwner(tx, args.balanceManagerId);
    tx.moveCall({
      target: `${this.pkg}::dex::modify_order<${args.baseType}, ${args.quoteType}>`,
      arguments: [tx.object(args.poolId), tx.object(args.balanceManagerId), proof, tx.pure.u128(args.orderId), tx.pure.u64(args.newQuantity), tx.object('0x6')],
    });
    return tx;
  }

  withdrawSettled(args: { baseType: string; quoteType: string; poolId: string; balanceManagerId: string; }) {
    const tx = new Transaction();
    const proof = this.genProofAsOwner(tx, args.balanceManagerId);
    tx.moveCall({ target: `${this.pkg}::dex::withdraw_settled_amounts<${args.baseType}, ${args.quoteType}>`, arguments: [tx.object(args.poolId), tx.object(args.balanceManagerId), proof] });
    return tx;
  }

  // ===== Pool creation =====
  createPermissionlessPool(args: {
    baseType: string; quoteType: string;
    registryId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string;
    unxvFeeCoinId: string; tickSize: bigint; lotSize: bigint; minSize: bigint;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::create_permissionless_pool<${args.baseType}, ${args.quoteType}>`,
        arguments: [
        tx.object(args.registryId),
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
        tx.object(args.unxvFeeCoinId),
        tx.pure.u64(args.tickSize),
        tx.pure.u64(args.lotSize),
        tx.pure.u64(args.minSize),
          tx.object(args.stakingPoolId),
          tx.object('0x6'),
        ],
      });
    return tx;
  }

  createPoolAdmin(args: { baseType: string; quoteType: string; adminRegistryId: string; registryId: string; tickSize: bigint; lotSize: bigint; minSize: bigint; }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::create_pool_admin<${args.baseType}, ${args.quoteType}>`,
      arguments: [tx.object(args.adminRegistryId), tx.object(args.registryId), tx.pure.u64(args.tickSize), tx.pure.u64(args.lotSize), tx.pure.u64(args.minSize)],
    });
    return tx;
  }

  // ===== UI swap wrapper (combined maker+taker protocol fee) =====
  swapExactQuantityUI(args: { baseType: string; quoteType: string; poolId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; baseInCoinId?: string; quoteInCoinId?: string; maybeUnxvCoinId?: string; minOut: bigint; }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId ? this.optSomeObj(tx, this.coinType(unxvType), args.maybeUnxvCoinId) : this.optNone(tx, this.coinType(unxvType));
    // Ensure both base and quote Coin inputs exist; create zero coin when not provided
    let baseIn: any;
    let quoteIn: any;
    if (args.baseInCoinId) {
      baseIn = tx.object(args.baseInCoinId);
    } else {
      [baseIn] = tx.moveCall({ target: '0x2::coin::zero', typeArguments: [args.baseType], arguments: [] });
    }
    if (args.quoteInCoinId) {
      quoteIn = tx.object(args.quoteInCoinId);
    } else {
      [quoteIn] = tx.moveCall({ target: '0x2::coin::zero', typeArguments: [args.quoteType], arguments: [] });
    }
    tx.moveCall({
      target: `${this.pkg}::dex::swap_exact_quantity_ui<${args.baseType}, ${args.quoteType}>`,
        arguments: [
        tx.object(args.poolId),
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
          tx.object(args.stakingPoolId),
        baseIn,
        quoteIn,
          optUnxv,
        tx.pure.u64(args.minOut),
          tx.object('0x6'),
        ],
      });
    return tx;
  }
}


