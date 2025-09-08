import { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';

export class OptionsClient {
  private client: SuiClient;
  private pkg: string;
  constructor(client: SuiClient, pkg: string) { this.client = client; this.pkg = pkg; }

  private async getMarketTypeArgs(marketId: string): Promise<{ base: string; quote: string }> {
    const o = await this.client.getObject({ id: marketId, options: { showType: true } });
    const t = o.data?.content && 'type' in o.data.content ? (o.data.content as { type: string }).type : undefined;
    if (!t) throw new Error('Market type not found');
    const lt = t.indexOf('<');
    const gt = t.lastIndexOf('>');
    if (lt === -1 || gt === -1) throw new Error('Unexpected market type');
    const inner = t.slice(lt + 1, gt);
    // split top-level by comma
    const parts: string[] = [];
    let depth = 0, cur = '';
    for (const ch of inner) {
      if (ch === '<') depth++;
      if (ch === '>') depth--;
      if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; continue; }
      cur += ch;
    }
    if (cur.trim()) parts.push(cur.trim());
    if (parts.length !== 2) throw new Error('Unexpected market generics');
    return { base: parts[0], quote: parts[1] };
  }

  private coinTypeOf(inner: string): string { return `0x2::coin::Coin<${inner}>`; }

  private makeNone(tx: Transaction, typeTag: string) {
    return tx.moveCall({ target: '0x1::option::none', typeArguments: [typeTag], arguments: [] });
  }

  private makeSomeObject(tx: Transaction, typeTag: string, objectId: string) {
    return tx.moveCall({ target: '0x1::option::some', typeArguments: [typeTag], arguments: [tx.object(objectId)] });
  }

  // place_option_sell_order<Base, Quote>(market, key, quantity, limit_premium_quote, expire_ts, collateral: Option<Coin<Base>>, collateral_q: Option<Coin<Quote>>,...)
  async sellOrder(args: {
    marketId: string;
    key: bigint;
    quantity: bigint;
    limitPremiumQuote: bigint;
    expireTs: bigint;
    baseCollateralCoinId?: string; // for calls
    quoteCollateralCoinId?: string; // for puts
  }) {
    const tx = new Transaction();
    const { base, quote } = await this.getMarketTypeArgs(args.marketId);
    const coinBase = this.coinTypeOf(base);
    const coinQuote = this.coinTypeOf(quote);
    const collBase = args.baseCollateralCoinId ? this.makeSomeObject(tx, coinBase, args.baseCollateralCoinId) : this.makeNone(tx, coinBase);
    const collQuote = args.quoteCollateralCoinId ? this.makeSomeObject(tx, coinQuote, args.quoteCollateralCoinId) : this.makeNone(tx, coinQuote);
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
  async buyOrder(args: {
    marketId: string;
    key: bigint;
    quantity: bigint;
    limitPremiumQuote: bigint;
    expireTs: bigint;
    premiumBudgetQuoteCoinId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    rewardsId: string;
    unxvFeeCoinId?: string;
  }) {
    const tx = new Transaction();
    const coinUnxv = this.coinTypeOf(`${this.pkg}::unxv::UNXV`);
    const feeOpt = args.unxvFeeCoinId ? this.makeSomeObject(tx, coinUnxv, args.unxvFeeCoinId) : this.makeNone(tx, coinUnxv);
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
        tx.object(args.rewardsId),
        feeOpt,
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
  async exercise(args: {
    marketId: string;
    positionId: string;
    amount: bigint;
    oracleRegistryId: string;
    aggregatorId: string;
    payQuoteCoinId?: string;
    payBaseCoinId?: string;
  }) {
    const tx = new Transaction();
    // Feed updates handled by backend/cron; no SDK usage in browser
    const { base, quote } = await this.getMarketTypeArgs(args.marketId);
    const coinBase = this.coinTypeOf(base);
    const coinQuote = this.coinTypeOf(quote);
    const payQ = args.payQuoteCoinId ? this.makeSomeObject(tx, coinQuote, args.payQuoteCoinId) : this.makeNone(tx, coinQuote);
    const payB = args.payBaseCoinId ? this.makeSomeObject(tx, coinBase, args.payBaseCoinId) : this.makeNone(tx, coinBase);
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


