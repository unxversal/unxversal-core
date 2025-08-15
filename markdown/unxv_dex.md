## Unxversal DEX

### Purpose
On-chain orderbook for coin-base markets with vault-safe variants for protocol-owned liquidity.

### Key Objects
- `DexConfig`: global fee settings, maker rebate, UNXV discount, paused flag, treasury id.
- `CoinOrderSell<Base>`, `CoinOrderBuy<Base, C>`: escrowed user orders.
- `VaultOrderSell<Base>`, `VaultOrderBuy<Base, C>`: vault-safe orders that split/join escrow against vault coin stores.

### Flows
- Place: `place_coin_*`, `place_vault_*` (entry) and package-visible wrappers for intra-package usage.
- Cancel: `cancel_*` for both coin and vault orders; expiry cancel variants.
- Match: `match_coin_orders` and `match_vault_orders` deliver fills, charge taker fee, apply UNXV discount, pay maker rebate, deposit fee to treasury.

### Off-chain
- Bots: order matching and expiry GC; config display registration.
- API: build order placement, cancel, and match transactions; decode order states.

### SDK and API interfaces (TS)
```ts
export interface DexApi {
  placeCoinSell(req: { cfgId: string; price: bigint; sizeBase: bigint; baseCoin: string; expiryMs: bigint; }): Promise<TxBuildResult>;
  placeCoinBuy(req: { cfgId: string; price: bigint; sizeBase: bigint; collateralCoin: string; expiryMs: bigint; }): Promise<TxBuildResult>;
  placeVaultSell(req: { cfgId: string; vaultId: string; price: bigint; sizeBase: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  placeVaultBuy(req: { cfgId: string; vaultId: string; price: bigint; sizeBase: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  cancelVaultOrder(req: { orderId: string; vaultId: string; side: 'buy'|'sell'; }): Promise<TxBuildResult>;
  matchVault(req: { cfgId: string; buyId: string; sellId: string; maxFillBase: bigint; takerIsBuyer: boolean; bounds: { min: bigint; max: bigint }; buyerVaultId: string; sellerVaultId: string; unxvCoins?: string[]; }): Promise<TxBuildResult>;
}

export class DexMatcherBot extends BotBase {
  protected async tick() {
    // 1) scan vault orders, 2) compute crossed matches, 3) submit matchVault() txs
  }
}
```


