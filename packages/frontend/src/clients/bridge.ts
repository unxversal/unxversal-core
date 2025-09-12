import { Transaction } from '@mysten/sui/transactions';

/**
 * BridgeClient builds PTBs for `unxversal::bridge` helpers.
 * - take_protocol_fee_in_base<Base>
 * - record_spot_from_quote<Quote>
 * - record_spot_from_base<Base>
 */
export class BridgeClient {
  private readonly pkg: string;
  constructor(pkgUnxversal: string) { this.pkg = pkgUnxversal; }

  /**
   * Charge taker protocol fee from an input base coin with optional UNXV discount.
   * Returns (reducedBaseCoin, maybeUnxvRefund) as separate transaction results.
   */
  takeProtocolFeeInBase<Base extends string>(args: {
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    baseCoinId: string; // Coin<Base>
    maybeUnxvCoinId?: string; // Optional Coin<UNXV>
    takerFeeBpsOverride?: number | bigint; // optional override
  }) {
    const tx = new Transaction();
    const unxvType = `${this.pkg}::unxv::UNXV`;
    const optUnxv = args.maybeUnxvCoinId
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [tx.object(args.maybeUnxvCoinId)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: [`0x2::coin::Coin<${unxvType}>`], arguments: [] });
    const optOverride = typeof args.takerFeeBpsOverride === 'number' || typeof args.takerFeeBpsOverride === 'bigint'
      ? tx.moveCall({ target: '0x1::option::some', typeArguments: ['u64'], arguments: [tx.pure.u64(args.takerFeeBpsOverride as bigint)] })
      : tx.moveCall({ target: '0x1::option::none', typeArguments: ['u64'], arguments: [] });

    const [reduced, maybeUnxvBack] = tx.moveCall({
      target: `${this.pkg}::bridge::take_protocol_fee_in_base<${(null as unknown as Base)}>`,
      arguments: [
        tx.object(args.feeConfigId),
        tx.object(args.feeVaultId),
        tx.object(args.stakingPoolId),
        tx.object(args.baseCoinId),
        optUnxv,
        optOverride,
        tx.object('0x6'),
      ],
    }) as any;

    return { tx, reduced, maybeUnxvBack };
  }

  /** Record spot volume/rewards using quote output. Returns Coin<Quote> unchanged to caller on chain. */
  recordSpotFromQuote<Quote extends string>(args: {
    rewardsId: string;
    oracleRegistryId: string;
    symbol: string; // e.g., "USDC/USD"
    pythPriceInfoId: string; // pyth::price_info::PriceInfoObject id
    quoteCoinId: string; // Coin<Quote>
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::bridge::record_spot_from_quote<${(null as unknown as Quote)}>`,
      arguments: [
        tx.object(args.rewardsId),
        tx.object(args.oracleRegistryId),
        tx.pure.string(args.symbol),
        tx.object(args.pythPriceInfoId),
        tx.object(args.quoteCoinId),
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    });
    return tx;
  }

  /** Record spot volume/rewards using base output. Returns Coin<Base> unchanged to caller on chain. */
  recordSpotFromBase<Base extends string>(args: {
    rewardsId: string;
    oracleRegistryId: string;
    symbol: string; // e.g., "SUI/USDC"
    pythPriceInfoId: string;
    baseCoinId: string; // Coin<Base>
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::bridge::record_spot_from_base<${(null as unknown as Base)}>`,
      arguments: [
        tx.object(args.rewardsId),
        tx.object(args.oracleRegistryId),
        tx.pure.string(args.symbol),
        tx.object(args.pythPriceInfoId),
        tx.object(args.baseCoinId),
        tx.object('0x6'),
        tx.object('0x6'),
      ],
    });
    return tx;
  }
}


