import { SuiClient } from '@mysten/sui/client';
import { Transaction, Inputs } from '@mysten/sui/transactions';

export class OptionsClient {
  private client: SuiClient;
  private pkg: string;
  constructor(client: SuiClient, pkg: string) { this.client = client; this.pkg = pkg; }

  // place_option_sell_order<Base, Quote>(market, key, quantity, limit_premium_quote, expire_ts, collateral: Option<Coin<Base>>, collateral_q: Option<Coin<Quote>>,...)
  sellOrder(args: {
    marketId: string;
    key: bigint;
    quantity: bigint;
    limitPremiumQuote: bigint;
    expireTs: bigint;
    baseCollateralCoinId?: string; // for calls
    quoteCollateralCoinId?: string; // for puts
  }) {
    const tx = new Transaction();
    const collBase = args.baseCollateralCoinId ? tx.pure.option('object', Inputs.ObjectRef({ objectId: args.baseCollateralCoinId, digest: '', version: 0 })) : tx.pure.option('object', null);
    const collQuote = args.quoteCollateralCoinId ? tx.pure.option('object', Inputs.ObjectRef({ objectId: args.quoteCollateralCoinId, digest: '', version: 0 })) : tx.pure.option('object', null);
    tx.moveCall({
      target: `${this.pkg}::options::place_option_sell_order`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u128(args.key),
        tx.pure.u64(args.quantity),
        tx.pure.u64(args.limitPremiumQuote),
        tx.pure.u64(args.expireTs),
        collBase,
        collQuote,
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  // place_option_buy_order<Base, Quote>(market, key, quantity, limit_premium_quote, expire_ts, premium_budget_quote, cfg, vault, staking_pool, fee_unxv_in, clock, ctx)
  buyOrder(args: {
    marketId: string;
    key: bigint;
    quantity: bigint;
    limitPremiumQuote: bigint;
    expireTs: bigint;
    premiumBudgetQuoteCoinId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    unxvFeeCoinId?: string;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::options::place_option_buy_order`,
      arguments: [
        tx.object(args.marketId),
        tx.pure.u128(args.key),
        tx.pure.u64(args.quantity),
        tx.pure.u64(args.limitPremiumQuote),
        tx.pure.u64(args.expireTs),
        tx.object(args.premiumBudgetQuoteCoinId),
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        args.unxvFeeCoinId ? tx.object(args.unxvFeeCoinId) : tx.pure.option('address', null),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  cancelOrder(args: { marketId: string; key: bigint; orderId: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::options::cancel_option_order`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.pure.u128(args.orderId), tx.object('0x6')] });
    return tx;
  }

  // exercise_option<Base, Quote>(market, pos, amount, reg, agg, pay_quote, pay_base, clock, ctx)
  exercise(args: {
    marketId: string;
    positionId: string;
    amount: bigint;
    oracleRegistryId: string;
    aggregatorId: string;
    payQuoteCoinId?: string;
    payBaseCoinId?: string;
  }) {
    const tx = new Transaction();
    const payQ = args.payQuoteCoinId ? tx.pure.option('object', tx.object(args.payQuoteCoinId)) : tx.pure.option('object', null);
    const payB = args.payBaseCoinId ? tx.pure.option('object', tx.object(args.payBaseCoinId)) : tx.pure.option('object', null);
    tx.moveCall({
      target: `${this.pkg}::options::exercise_option`,
      arguments: [
        tx.object(args.marketId),
        tx.object(args.positionId),
        tx.pure.u64(args.amount),
        tx.object(args.oracleRegistryId),
        tx.object(args.aggregatorId),
        payQ,
        payB,
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  writerClaim(args: { marketId: string; key: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::options::writer_claim_proceeds`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.object('0x6')] });
    return tx;
  }
}


