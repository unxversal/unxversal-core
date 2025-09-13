import { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';

export class XOptionsClient {
  private readonly client: SuiClient;
  private readonly pkg: string;
  constructor(client: SuiClient, pkgUnxversal: string) { this.client = client; this.pkg = pkgUnxversal; }

  private async marketTypeArgs(marketId: string): Promise<{ base: string; quote: string }> {
    const o = await this.client.getObject({ id: marketId, options: { showType: true } });
    const t = o.data?.content && 'type' in o.data.content ? (o.data.content as { type: string }).type : undefined;
    if (!t) throw new Error('Market type not found');
    const lt = t.indexOf('<'); const gt = t.lastIndexOf('>');
    if (lt === -1 || gt === -1) throw new Error('Unexpected market type');
    const inner = t.slice(lt + 1, gt);
    const parts: string[] = []; let depth = 0, cur = '';
    for (const ch of inner) { if (ch === '<') depth++; if (ch === '>') depth--; if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; continue; } cur += ch; }
    if (cur.trim()) parts.push(cur.trim());
    if (parts.length !== 2) throw new Error('Unexpected market generics');
    return { base: parts[0], quote: parts[1] };
  }

  private coinType(inner: string): string { return `0x2::coin::Coin<${inner}>`; }
  private optNone(tx: Transaction, typeTag: string) { return tx.moveCall({ target: '0x1::option::none', typeArguments: [typeTag], arguments: [] }); }
  private optSomeObj(tx: Transaction, typeTag: string, id: string) { return tx.moveCall({ target: '0x1::option::some', typeArguments: [typeTag], arguments: [tx.object(id)] }); }

  // ===== Maker (sell) =====
  async placeSellOrder(args: { marketId: string; key: bigint; quantity: bigint; limitPremiumQuote: bigint; expireTs: bigint; baseCollateralCoinId?: string; quoteCollateralCoinId?: string }) {
    const tx = new Transaction();
    const { base, quote } = await this.marketTypeArgs(args.marketId);
    const coinBase = this.coinType(base); const coinQuote = this.coinType(quote);
    const collBase = args.baseCollateralCoinId ? this.optSomeObj(tx, coinBase, args.baseCollateralCoinId) : this.optNone(tx, coinBase);
    const collQuote = args.quoteCollateralCoinId ? this.optSomeObj(tx, coinQuote, args.quoteCollateralCoinId) : this.optNone(tx, coinQuote);
    tx.moveCall({ target: `${this.pkg}::xoptions::place_option_sell_order`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.pure.u64(args.quantity), tx.pure.u64(args.limitPremiumQuote), tx.pure.u64(args.expireTs), collBase, collQuote, tx.object('0x6')] });
    return tx;
  }

  // ===== Taker (buy) =====
  buyOrder(args: { marketId: string; key: bigint; quantity: bigint; limitPremiumQuote: bigint; expireTs: bigint; premiumBudgetQuoteCoinId: string; feeConfigId: string; feeVaultId: string; stakingPoolId: string; rewardsId: string; unxvFeeCoinId?: string }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const coin = this.coinType(unxvType);
    const feeOpt = args.unxvFeeCoinId ? this.optSomeObj(tx, coin, args.unxvFeeCoinId) : this.optNone(tx, coin);
    tx.moveCall({ target: `${this.pkg}::xoptions::place_option_buy_order`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.pure.u64(args.quantity), tx.pure.u64(args.limitPremiumQuote), tx.pure.u64(args.expireTs), tx.object(args.premiumBudgetQuoteCoinId), tx.object(args.feeConfigId), tx.object(args.feeVaultId), tx.object(args.stakingPoolId), tx.object(args.rewardsId), feeOpt, tx.object('0x6')] });
    return tx;
  }

  // ===== Cancel =====
  cancelOrder(args: { marketId: string; key: bigint; orderId: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xoptions::cancel_option_order`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.pure.u128(args.orderId), tx.object('0x6')] });
    return tx;
  }

  // ===== Exercise =====
  async exercise(args: { marketId: string; positionId: string; amount: bigint; payQuoteCoinId?: string; payBaseCoinId?: string }) {
    const tx = new Transaction();
    const { base, quote } = await this.marketTypeArgs(args.marketId);
    const coinBase = this.coinType(base); const coinQuote = this.coinType(quote);
    const payQ = args.payQuoteCoinId ? this.optSomeObj(tx, coinQuote, args.payQuoteCoinId) : this.optNone(tx, coinQuote);
    const payB = args.payBaseCoinId ? this.optSomeObj(tx, coinBase, args.payBaseCoinId) : this.optNone(tx, coinBase);
    tx.moveCall({ target: `${this.pkg}::xoptions::exercise_option`, arguments: [tx.object(args.marketId), tx.object(args.positionId), tx.pure.u64(args.amount), payQ, payB, tx.object('0x6'), tx.object('0x6')] });
    return tx;
  }

  // ===== Settle after expiry =====
  async settleAfterExpiry(args: { marketId: string; positionId: string; amount: bigint; payQuoteCoinId?: string; payBaseCoinId?: string }) {
    const tx = new Transaction();
    const { base, quote } = await this.marketTypeArgs(args.marketId);
    const coinBase = this.coinType(base); const coinQuote = this.coinType(quote);
    const payQ = args.payQuoteCoinId ? this.optSomeObj(tx, coinQuote, args.payQuoteCoinId) : this.optNone(tx, coinQuote);
    const payB = args.payBaseCoinId ? this.optSomeObj(tx, coinBase, args.payBaseCoinId) : this.optNone(tx, coinBase);
    tx.moveCall({ target: `${this.pkg}::xoptions::settle_position_after_expiry`, arguments: [tx.object(args.marketId), tx.object(args.positionId), tx.pure.u64(args.amount), payQ, payB, tx.object('0x6'), tx.object('0x6')] });
    return tx;
  }

  // ===== Writer claims / unlock =====
  writerClaim(args: { marketId: string; key: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xoptions::writer_claim_proceeds`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.object('0x6'), tx.object('0x6')] });
    return tx;
  }

  writerUnlockAfterExpiry(args: { marketId: string; key: bigint }) {
    const tx = new Transaction();
    tx.moveCall({ target: `${this.pkg}::xoptions::writer_unlock_after_expiry`, arguments: [tx.object(args.marketId), tx.pure.u128(args.key), tx.object('0x6'), tx.object('0x6')] });
    return tx;
  }
}


