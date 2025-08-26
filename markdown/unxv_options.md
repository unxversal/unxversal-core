## Unxversal Options

### Purpose
Admin-whitelisted underlyings, permissionless market creation, OTC matching with margin and cash/physical settlement.

### Key Objects
- `OptionsRegistry`: underlyings table, market mapping, fee params, maker rebate, treasury id.
- `OptionMarket`: per-market config and metrics.
- OTC objects: `ShortOffer<C>`, `PremiumEscrow<C>`, `CoinShortOffer<Base>`, and underlying escrows.
- Positions: `OptionPosition<C>`, plus `ShortUnderlyingEscrow<Base>` and `LongUnderlyingEscrow<Base>`.

### Flows
- Underlyings: add/remove via `SynthRegistry` admins.
- Market creation: `create_option_market` with optional UNXV discounted creation fee.
- OTC matching: `match_offer_and_escrow`, `match_coin_offer_and_escrow`, and PUT escrow matcher.
- Exercise/Settlement: `exercise_american_now`, physical delivery paths, and `expire_and_settle_market_cash` with dispute queue.

### Fees
- Trade, settlement, and maker-rebate parameters in registry; UNXV discounts on taker fees.

### Off-chain
- Bots: market listing curator, premium matching, dispute/settlement queue processor, exercise orchestration.
- API: build tx for offers/escrows, matching, exercises, settlement.

### Testing
- See `markdown/tests_overview.md` for suite overview.
- Tests cover underlying registration and market creation, admin gating (happy/negative), fee math (discount, maker/taker split), exercise (American), physical delivery flows, cash settlement, queue + points, guards (tick, contract size, OI caps), duplicates and pre-expiry settlement rejections, cancellation and GC, and read-only helpers. All current tests pass.

### SDK and API interfaces (TS)
```ts
export interface OptionsApi {
  createMarket(req: OptionsCreateMarketRequest): Promise<TxBuildResult>;
  placeShortOffer(req: { marketId: string; qty: bigint; minPremium: bigint; collateralCoin: string; }): Promise<TxBuildResult>;
  placePremiumEscrow(req: { marketId: string; qty: bigint; premium: bigint; collateralCoin: string; cancelAfterMs: bigint; }): Promise<TxBuildResult>;
  matchOfferEscrow(req: { registryId: string; marketId: string; offerId: string; escrowId: string; maxFillQty: bigint; treasuryId: string; unxvCoins?: string[]; }): Promise<TxBuildResult>;
  settleMarket(req: { registryId: string; marketId: string; oracleCfgId: string; priceAggId: string; }): Promise<TxBuildResult>;
}

export class OptionsPremiumMatcherBot extends BotBase {
  protected async tick() {
    // read offers/escrows, sort by price, match within tick and contract constraints
  }
}
```


