## Unxversal Perpetuals (Overview)

Perpetuals implement continuous trading with funding payments and risk controls. The module mirrors `futures.move` patterns with:

- Registry of markets and parameters (fee, rebate, funding intervals).
- Positions with margin, PnL, and liquidation logic.
- Funding index and periodic transfer mechanism.
- Off-chain bots for funding, matching, liquidation, and settlement reporting.

### Testing
- See `markdown/tests_overview.md` for a full suite summary.
- Coverage includes fee math (taker fee, maker rebate, UNXV discount, bot split), market controls (tick/bounds/pause), funding refresh and accrual, liquidation, and points integration. All current tests pass.

API and bot contracts mirror Futures with additional funding operations:
- `POST /perps/recordFill`, `POST /perps/position/open|close`, `POST /perps/liquidate`, `POST /perps/refreshFunding`.
- `FundingBot` computes premiums and calls `refresh_market_funding`; then accrues per-position funding via `apply_funding_for_position`.

### SDK and API interfaces (TS)
```ts
export interface PerpsApi {
  recordFill(req: { marketId: string; price: bigint; size: bigint; takerIsBuyer: boolean; maker: string; feeCoin: string; }): Promise<TxBuildResult>;
  openPosition(req: { marketId: string; side: 0|1; size: bigint; entryPrice: bigint; marginCoin: string; }): Promise<TxBuildResult>;
  closePosition(req: { marketId: string; posId: string; price: bigint; qty: bigint; }): Promise<TxBuildResult>;
  liquidate(req: { marketId: string; posId: string; markPrice: bigint; }): Promise<TxBuildResult>;
}

export class FundingBot extends BotBase {
  protected async tick() {
    // compute funding imbalances and submit funding transfer txs
  }
}
```

