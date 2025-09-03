import { SuiClient, Transaction } from '@mysten/sui/client';

export class UnxvDexClient {
  constructor(private client: SuiClient, private pkg: string) {}

  async placeMarketOrder<Base extends string, Quote extends string>(args: {
    poolId: string; // DeepBook pool ID (object ID)
    balanceManagerId: string; // user's BalanceManager shared object
    tradeProof: string; // TradeProof ID built off-chain
    isBid: boolean;
    quantity: bigint; // base units
    payWithDeep: boolean;
  }) {
    const tx = new Transaction();
    tx.moveCall({
      target: `${this.pkg}::dex::place_market_order`,
      arguments: [
        tx.object(args.poolId),
        tx.object(args.balanceManagerId),
        tx.object(args.tradeProof),
        tx.pure.u64(0n), // client_order_id placeholder; consider a caller-provided id
        tx.pure.u8(0),
        tx.pure.u64(args.quantity),
        tx.pure.bool(args.isBid),
        tx.pure.bool(args.payWithDeep),
        tx.object('0x6'), // Clock at 0x6
      ],
    });
    return tx;
  }
}

export class UnxvPerpClient {
  constructor(private client: SuiClient, private pkg: string) {}

  // Example: open long using UNXV fee coin (optional)
  openLong<Collat extends string>(args: {
    marketId: string;
    oracleRegistryId: string;
    aggregatorId: string;
    feeConfigId: string;
    feeVaultId: string;
    stakingPoolId: string;
    qty: bigint;
    maybeUnxvCoinId?: string;
  }) {
    const tx = new Transaction();
    const inputs = [
      tx.object(args.marketId),
      tx.object(args.oracleRegistryId),
      tx.object(args.aggregatorId),
      tx.object(args.feeConfigId),
      tx.object(args.feeVaultId),
      tx.object(args.stakingPoolId),
      ...(args.maybeUnxvCoinId ? [tx.object(args.maybeUnxvCoinId)] : [tx.pure.option('address', null)]),
      tx.object('0x6'),
      tx.pure.u64(args.qty),
    ];
    tx.moveCall({ target: `${this.pkg}::perpetuals::open_long`, arguments: inputs as any });
    return tx;
  }
}


