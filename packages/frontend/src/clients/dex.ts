import { DeepBookClient } from '@mysten/deepbook-v3';
import type { Transaction } from '@mysten/sui/transactions';

export type DeepBookEnv = 'mainnet' | 'testnet';

export type DexClientConfig = {
  env: DeepBookEnv;
  client: any;
  address: string;
  pkgUnxversal?: string; // for lending flash loan helpers
};

/**
 * DexClient wraps the DeepBookV3 TS SDK to provide
 * - Order placement (limit/market)
 * - Order management (cancel/cancelAll)
 * - Swaps (exact base/quote)
 * - Flash loans (DeepBook borrow/return)
 * - BalanceManager helpers
 *
 * This class returns SDK call builders you can add to a Transaction via tx.add(...).
 */
export class DexClient {
  private readonly db: DeepBookClient;
  private readonly pkgUnxversal?: string;
  private readonly address: string;

  constructor(cfg: DexClientConfig) {
    this.db = new DeepBookClient({ env: cfg.env, client: cfg.client, address: cfg.address });
    this.pkgUnxversal = cfg.pkgUnxversal;
    this.address = cfg.address;
  }

  // =============== Orders ===============
  placeLimitOrder(params: any) {
    return this.db.deepBook.placeLimitOrder(params);
  }

  placeMarketOrder(params: any) {
    return this.db.deepBook.placeMarketOrder(params);
  }

  cancelOrder(poolKey: string, balanceManagerKey: string, orderId: string | number) {
    return this.db.deepBook.cancelOrder(poolKey, balanceManagerKey, String(orderId));
  }

  cancelAllOrders(poolKey: string, balanceManagerKey: string) {
    return this.db.deepBook.cancelAllOrders(poolKey, balanceManagerKey);
  }

  // =============== Swaps ===============
  swapExactBaseForQuote(params: any) {
    return this.db.deepBook.swapExactBaseForQuote(params);
  }

  swapExactQuoteForBase(params: any) {
    return this.db.deepBook.swapExactQuoteForBase(params);
  }

  // =============== BalanceManager ===============
  createAndShareBalanceManager() {
    return this.db.balanceManager.createAndShareBalanceManager();
  }

  depositIntoManager(balanceManagerKey: string, coinKey: string, amount: number) {
    return this.db.balanceManager.depositIntoManager(balanceManagerKey, coinKey, amount);
  }

  withdrawAllFromManager(balanceManagerKey: string, coinKey: string, recipient: string) {
    return this.db.balanceManager.withdrawAllFromManager(balanceManagerKey, coinKey, recipient);
  }

  // =============== Flash Loans (DeepBook) ===============
  borrowBaseAsset(poolKey: string, borrowAmount: number) {
    return this.db.flashLoans.borrowBaseAsset(poolKey, borrowAmount);
  }

  borrowQuoteAsset(poolKey: string, borrowAmount: number) {
    return this.db.flashLoans.borrowQuoteAsset(poolKey, borrowAmount);
  }

  returnQuoteAsset(args: { poolKey: string; borrowAmount: number; quoteCoinInput: any; flashLoan: any }) {
    return (this.db.flashLoans.returnQuoteAsset as any)({ poolKey: args.poolKey, borrowAmount: args.borrowAmount, quoteCoinInput: args.quoteCoinInput, flashLoan: args.flashLoan });
  }

  /**
   * Util: build a DeepBook flash loan flow around an optional single swap and repay.
   */
  flashLoanDeepBook(tx: Transaction, params: {
    // Fee config
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentCoinId: string;
    feePaymentCoinType: string;
    maybeUnxvCoinId?: string;
    takerFeeBpsOverride?: number | bigint;
    // Flash loan + trade
    borrowPoolKey: string;
    borrowAmount: number;
    // Optional single swap step on a different pool
    tradePoolKey?: string;
    tradeDirection?: 'quote->base' | 'base->quote';
    tradeAmount?: number; // amount in input token units
    minOut?: number;
    // Optional reacquire step to convert back into DEEP for repayment
    reacquirePoolKey?: string;
    reacquireDirection?: 'quote->base' | 'base->quote';
    reacquireAmount?: number;
  }) {
    if (!this.pkgUnxversal) throw new Error('pkgUnxversal required for protocol fee');

    // Take protocol fee from user-provided coin first
    const unxvType = `${this.pkgUnxversal}::unxv::UNXV`;
    const optUnxv = params.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(params.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    const optOverride = typeof params.takerFeeBpsOverride !== 'undefined'
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(params.takerFeeBpsOverride as bigint)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });
    const [reduced, _maybeBack] = tx.moveCall({
      target: `${this.pkgUnxversal}::bridge::take_protocol_fee_in_base<${params.feePaymentCoinType}>`,
      arguments: [
        tx.object(params.feeConfigId),
        tx.object(params.feeVaultId),
        tx.object(params.stakingPoolId),
        tx.object(params.feePaymentCoinId),
        optUnxv,
        optOverride,
        tx.object('0x6'),
      ],
    });
    tx.transferObjects([reduced], this.address);

    const [borrowedBase, flashLoan] = tx.add((this.borrowBaseAsset(params.borrowPoolKey, params.borrowAmount) as any));

    // Optional one hop trade using borrowed coin as DEEP fee coin (if direction is quote->base)
    if (params.tradePoolKey && params.tradeAmount && params.tradeDirection) {
      if (params.tradeDirection === 'quote->base') {
        tx.add(
          this.swapExactQuoteForBase({
            poolKey: params.tradePoolKey,
            amount: params.tradeAmount,
            deepAmount: 0,
            minOut: params.minOut ?? 0,
            deepCoin: borrowedBase,
          }) as any,
        );
      } else {
        tx.add(
          this.swapExactBaseForQuote({
            poolKey: params.tradePoolKey,
            amount: params.tradeAmount,
            deepAmount: 0,
            minOut: params.minOut ?? 0,
            deepCoin: borrowedBase,
          }) as any,
        );
      }
    }

    // Optional reacquire step to obtain DEEP for repayment
    if (params.reacquirePoolKey && params.reacquireAmount && params.reacquireDirection) {
      if (params.reacquireDirection === 'quote->base') {
        tx.add(
          this.swapExactQuoteForBase({
            poolKey: params.reacquirePoolKey,
            amount: params.reacquireAmount,
            deepAmount: 0,
            minOut: 0,
          }) as any,
        );
      } else {
        tx.add(
          this.swapExactBaseForQuote({
            poolKey: params.reacquirePoolKey,
            amount: params.reacquireAmount,
            deepAmount: 0,
            minOut: 0,
          }) as any,
        );
      }
    }

    const loanRemain = tx.add((this.returnBaseAsset(params.borrowPoolKey, params.borrowAmount, borrowedBase, flashLoan) as any));
    return loanRemain; // Transaction object for any leftover to transfer if desired
  }

  // =============== Flash Loans (Lending module) ===============
  /**
   * Build a lending-module flash loan around optional DeepBook swap.
   * Caller must provide correct type tags and market id.
   */
  flashLoanLending(tx: Transaction, params: {
    // Fee config
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentCoinId: string;
    feePaymentCoinType: string;
    maybeUnxvCoinId?: string;
    takerFeeBpsOverride?: number | bigint;
    // Lending market + trade
    marketId: string;
    collatType: string; // fully qualified type tag
    debtType: string;   // fully qualified type tag
    amount: number | bigint;
    tradePoolKey?: string;
    tradeDirection?: 'quote->base' | 'base->quote';
    tradeAmount?: number;
    minOut?: number;
  }) {
    if (!this.pkgUnxversal) throw new Error('pkgUnxversal required for lending flash loans');
    // Take protocol fee from user-provided coin
    const unxvType = `${this.pkgUnxversal}::unxv::UNXV`;
    const optUnxv = params.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(params.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    const optOverride = typeof params.takerFeeBpsOverride !== 'undefined'
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(params.takerFeeBpsOverride as bigint)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });
    const [reduced, _maybeBack] = tx.moveCall({
      target: `${this.pkgUnxversal}::bridge::take_protocol_fee_in_base<${params.feePaymentCoinType}>`,
      arguments: [
        tx.object(params.feeConfigId),
        tx.object(params.feeVaultId),
        tx.object(params.stakingPoolId),
        tx.object(params.feePaymentCoinId),
        optUnxv,
        optOverride,
        tx.object('0x6'),
      ],
    });
    tx.transferObjects([reduced], this.address);

    const loanCall = tx.moveCall({
      target: `${this.pkgUnxversal}::lending::flash_loan_debt<${params.collatType}, ${params.debtType}>`,
      arguments: [
        tx.object(params.marketId),
        tx.pure.u64(params.amount as bigint),
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    });
    const borrowedDebt = loanCall[0];
    const cap = loanCall[1];

    if (params.tradePoolKey && params.tradeAmount && params.tradeDirection) {
      if (params.tradeDirection === 'quote->base') {
        tx.add(this.swapExactQuoteForBase({ poolKey: params.tradePoolKey, amount: params.tradeAmount, deepAmount: 0, minOut: params.minOut ?? 0 }) as any);
      } else {
        tx.add(this.swapExactBaseForQuote({ poolKey: params.tradePoolKey, amount: params.tradeAmount, deepAmount: 0, minOut: params.minOut ?? 0 }) as any);
      }
    }

    const repayRemain = tx.moveCall({
      target: `${this.pkgUnxversal}::lending::flash_repay_debt<${params.collatType}, ${params.debtType}>`,
      arguments: [
        tx.object(params.marketId),
        borrowedDebt,
        cap,
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    });
    return repayRemain;
  }

  // Fix TS overload mismatch by using positional arguments
  returnBaseAsset(poolKey: string, borrowAmount: number, baseCoinInput: any, flashLoan: any) {
    return (this.db.flashLoans.returnBaseAsset as any)({ poolKey, borrowAmount, baseCoinInput, flashLoan });
  }

  // =============== Wrappers with Unxversal Protocol Fee ===============
  /**
   * Place a DeepBook limit order after collecting protocol fee via bridge on a provided fee coin.
   */
  placeLimitOrderWithProtocolFee(args: {
    // Fee config
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentCoinId: string;
    feePaymentCoinType: string; // inner type for Coin<...>
    maybeUnxvCoinId?: string;
    takerFeeBpsOverride?: number | bigint;
    // Order params
    poolKey: string;
    balanceManagerKey: string;
    clientOrderId: string;
    orderType?: number;
    selfMatchingOption?: number;
    price: number;
    quantity: number;
    isBid: boolean;
    payWithDeep?: boolean;
    expiration?: number | bigint;
  }) {
    if (!this.pkgUnxversal) throw new Error('pkgUnxversal required for protocol fee');
    return (tx: Transaction) => {
      // Charge protocol fee from provided coin
      const unxvType = `${this.pkgUnxversal}::unxv::UNXV`;
      const optUnxv = args.maybeUnxvCoinId
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
      const optOverride = typeof args.takerFeeBpsOverride !== 'undefined'
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(args.takerFeeBpsOverride as bigint)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });
      const [reduced, _maybeBack] = tx.moveCall({
        target: `${this.pkgUnxversal}::bridge::take_protocol_fee_in_base<${args.feePaymentCoinType}>`,
        arguments: [
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
          tx.object(args.stakingPoolId),
          tx.object(args.feePaymentCoinId),
          optUnxv,
          optOverride,
          tx.object('0x6'),
        ],
      });
      // Return remaining fee coin
      tx.transferObjects([reduced], this.address);

      // Place DeepBook order
      const dbParams: any = {
        poolKey: args.poolKey,
        balanceManagerKey: args.balanceManagerKey,
        clientOrderId: args.clientOrderId,
        orderType: args.orderType ?? 0,
        selfMatchingOption: args.selfMatchingOption ?? 0,
        price: args.price,
        quantity: args.quantity,
        isBid: args.isBid,
        payWithDeep: args.payWithDeep ?? false,
        expiration: args.expiration ?? Math.floor(Date.now() / 1000) + 120,
      };
      (this.db.deepBook.placeLimitOrder(dbParams) as any)(tx);
    };
  }

  /**
   * Place a DeepBook market order after collecting protocol fee via bridge on a provided fee coin.
   */
  placeMarketOrderWithProtocolFee(args: {
    // Fee config
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentCoinId: string;
    feePaymentCoinType: string;
    maybeUnxvCoinId?: string;
    takerFeeBpsOverride?: number | bigint;
    // Order params
    poolKey: string;
    balanceManagerKey: string;
    clientOrderId: string;
    quantity: number;
    isBid: boolean;
    payWithDeep?: boolean;
    selfMatchingOption?: number;
  }) {
    if (!this.pkgUnxversal) throw new Error('pkgUnxversal required for protocol fee');
    return (tx: Transaction) => {
      const unxvType = `${this.pkgUnxversal}::unxv::UNXV`;
      const optUnxv = args.maybeUnxvCoinId
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
      const optOverride = typeof args.takerFeeBpsOverride !== 'undefined'
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(args.takerFeeBpsOverride as bigint)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });
      const [reduced, _maybeBack] = tx.moveCall({
        target: `${this.pkgUnxversal}::bridge::take_protocol_fee_in_base<${args.feePaymentCoinType}>`,
        arguments: [
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
          tx.object(args.stakingPoolId),
          tx.object(args.feePaymentCoinId),
          optUnxv,
          optOverride,
          tx.object('0x6'),
        ],
      });
      tx.transferObjects([reduced], this.address);

      const dbParams: any = {
        poolKey: args.poolKey,
        balanceManagerKey: args.balanceManagerKey,
        clientOrderId: args.clientOrderId,
        quantity: args.quantity,
        isBid: args.isBid,
        payWithDeep: args.payWithDeep ?? false,
        selfMatchingOption: args.selfMatchingOption ?? 0,
      };
      (this.db.deepBook.placeMarketOrder(dbParams) as any)(tx);
    };
  }

  /**
   * Swap wrappers that collect protocol fee from a provided fee coin before calling DeepBook swap.
   */
  swapExactBaseForQuoteWithProtocolFee(args: {
    // Fee config
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentCoinId: string;
    feePaymentCoinType: string;
    maybeUnxvCoinId?: string;
    takerFeeBpsOverride?: number | bigint;
    // Swap params
    poolKey: string;
    amount: number;
    deepAmount: number;
    minOut: number;
    deepCoin?: any;
  }) {
    if (!this.pkgUnxversal) throw new Error('pkgUnxversal required for protocol fee');
    return (tx: Transaction) => {
      const unxvType = `${this.pkgUnxversal}::unxv::UNXV`;
      const optUnxv = args.maybeUnxvCoinId
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
      const optOverride = typeof args.takerFeeBpsOverride !== 'undefined'
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(args.takerFeeBpsOverride as bigint)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });
      const [reduced, _maybeBack] = tx.moveCall({
        target: `${this.pkgUnxversal}::bridge::take_protocol_fee_in_base<${args.feePaymentCoinType}>`,
        arguments: [
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
          tx.object(args.stakingPoolId),
          tx.object(args.feePaymentCoinId),
          optUnxv,
          optOverride,
          tx.object('0x6'),
        ],
      });
      tx.transferObjects([reduced], this.address);

      (this.db.deepBook.swapExactBaseForQuote({
        poolKey: args.poolKey,
        amount: args.amount,
        deepAmount: args.deepAmount,
        minOut: args.minOut,
        deepCoin: args.deepCoin,
      }) as any)(tx);
    };
  }

  swapExactQuoteForBaseWithProtocolFee(args: {
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    feePaymentCoinId: string;
    feePaymentCoinType: string;
    maybeUnxvCoinId?: string;
    takerFeeBpsOverride?: number | bigint;
    poolKey: string;
    amount: number;
    deepAmount: number;
    minOut: number;
    deepCoin?: any;
  }) {
    if (!this.pkgUnxversal) throw new Error('pkgUnxversal required for protocol fee');
    return (tx: Transaction) => {
      const unxvType = `${this.pkgUnxversal}::unxv::UNXV`;
      const optUnxv = args.maybeUnxvCoinId
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
      const optOverride = typeof args.takerFeeBpsOverride !== 'undefined'
        ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(args.takerFeeBpsOverride as bigint)] })
        : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });
      const [reduced, _maybeBack] = tx.moveCall({
        target: `${this.pkgUnxversal}::bridge::take_protocol_fee_in_base<${args.feePaymentCoinType}>`,
        arguments: [
          tx.object(args.feeConfigId),
          tx.object(args.feeVaultId),
          tx.object(args.stakingPoolId),
          tx.object(args.feePaymentCoinId),
          optUnxv,
          optOverride,
          tx.object('0x6'),
        ],
      });
      tx.transferObjects([reduced], this.address);

      (this.db.deepBook.swapExactQuoteForBase({
        poolKey: args.poolKey,
        amount: args.amount,
        deepAmount: args.deepAmount,
        minOut: args.minOut,
        deepCoin: args.deepCoin,
      }) as any)(tx);
    };
  }
}


