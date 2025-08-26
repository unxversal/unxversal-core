## Unxversal Dated Futures

### Purpose
Cash-settled dated futures with registry-governed listings and settlement via oracles.

### Key Objects
- `FuturesRegistry`: whitelisted underlyings, price feed IDs, trade/settlement fees, maker rebate, dispute window, treasury id.
- `FuturesContract`: symbol, underlying, contract/tick sizes, expiry and metrics.
- `FuturesPosition<C>`: position state and margin.

### Flows
- Listing: `whitelist_underlying` (admin) and `list_futures` (permissionless on whitelisted).
- Trading: `open_position`, `close_position` (stub PnL/margin), `record_fill` for fee accounting and metrics.
- Settlement: `settle_futures` records oracle price; `settle_position` distributes fees and returns margin.
- Liquidation: `liquidate_position` when equity < maintenance.

### Fees
- Trade fee with maker rebate and UNXV discount; settlement fees with bot reward split.

### Off-chain
- Bots: lister, fill recorder (from off-chain venues), liquidation scanner, settlement queue worker.
- API: build tx for listings (admin), positions, fills, settlement, liquidation.

### Testing
- See `markdown/tests_overview.md` for an overview.
- Tests cover discount/rebate math and clamp edges, pause guards, settlement flow and queue with points, full lifecycle (open/close/liquidate/settle), and oracle identity enforcement. All current tests pass.

### SDK and API interfaces (TS)
```ts
export interface FuturesApi {
  listContract(req: { registryId: string; underlying: string; symbol: string; contractSize: bigint; tickSize: bigint; expiryMs: bigint; initMarginBps: number; maintMarginBps: number; }): Promise<TxBuildResult>;
  recordFill(req: { registryId: string; contractId: string; price: bigint; size: bigint; takerIsBuyer: boolean; maker: string; unxvCoins?: string[]; unxvAggId: string; oracleCfgId: string; clockId: string; feeCoin: string; treasuryId: string; oiIncrease: boolean; minPrice: bigint; maxPrice: bigint; }): Promise<TxBuildResult>;
  openPosition(req: { contractId: string; side: 0|1; size: bigint; entryPrice: bigint; marginCoin: string; }): Promise<TxBuildResult>;
  closePosition(req: { registryId: string; contractId: string; posId: string; price: bigint; qty: bigint; treasuryId: string; }): Promise<TxBuildResult>; // tick-size enforced; close fee includes optional bot split
  settleContract(req: { registryId: string; contractId: string; oracleCfgId: string; clockId: string; priceAggId: string; treasuryId: string; }): Promise<TxBuildResult>;
  liquidate(req: { registryId: string; contractId: string; posId: string; markPrice: bigint; treasuryId: string; }): Promise<TxBuildResult>;
}

export class FuturesFillRecorderBot extends BotBase {
  protected async tick() {
    // pull fills from off-chain venue, convert to recordFill transactions with fees
  }
}
```


