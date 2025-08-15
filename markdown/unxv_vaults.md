## Unxversal Vaults

### Purpose
Provide protocol-safe liquidity provisioning and manager-led investment vehicles.

### Vault Types
- `LiquidityVault<Base, C>`
  - Holds `Coin<Base>` and `Coin<C>` balances; share accounting; min-cash buffer; order tracking IDs.
  - DEX LP: place/cancel/match via `dex` using vault-safe wrappers.
  - Synth LP: place/cancel/match `synthetics` orders against a manager-owned `CollateralVault<C>`.
  - NAV helpers, emergency pro-rata redemptions, manager shutdown.

- `TraderVault<C>`
  - Collateral-only, investor shares, manager stake bps enforcement, HWM performance fee accrual and payout to `treasury`.
  - Deposit/withdraw, manager stake add/unstake, crystallize and pay fees when liquidity allows.

### Admin & Gating
- Admin gating via `SynthRegistry` allow-list (UX `AdminCap` token is decorative).
- Treasury linkage for protocol fees.

### Off-chain
- Bots: vault order matching (DEX and Synth), expired order GC, periodic fee crystallization, price-driven rebalancing.
- API: build tx for vault lifecycle, DEX LP flows, and synth LP flows including min-cash enforcement on buys.

### SDK and API interfaces (TS)
```ts
export interface VaultsApi {
  createLiquidityVault(req: { registryId: string; baseSymbol: string; clockId: string; }): Promise<TxBuildResult>;
  lpDeposit(req: { registryId: string; vaultId: string; oracleCfgId: string; clockId: string; basePriceAggId: string; coin: string; }): Promise<TxBuildResult>;
  lpWithdraw(req: { registryId: string; vaultId: string; oracleCfgId: string; clockId: string; basePriceAggId: string; shares: bigint; }): Promise<TxBuildResult>;
  dexPlace(req: { cfgId: string; vaultId: string; side: 'buy'|'sell'; price: bigint; sizeBase: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  dexCancel(req: { vaultId: string; orderId: string; side: 'buy'|'sell'; }): Promise<TxBuildResult>;
  dexMatch(req: { cfgId: string; buyId: string; sellId: string; maxFillBase: bigint; takerIsBuyer: boolean; bounds: { min: bigint; max: bigint }; buyerVaultId: string; sellerVaultId: string; unxvCoins?: string[]; }): Promise<TxBuildResult>;
  synthPlace(req: { registryId: string; vaultId: string; collateralVaultId: string; symbol: string; side: 0|1; price: bigint; size: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  synthCancel(req: { orderId: string; vaultId: string; }): Promise<TxBuildResult>;
  synthMatch(req: { registryId: string; buyId: string; sellId: string; takerIsBuyer: boolean; bounds: { min: bigint; max: bigint }; buyerVaultId: string; sellerVaultId: string; unxvCoins?: string[]; treasuryId: string; }): Promise<TxBuildResult>;
}

export class VaultCrystallizerBot extends BotBase {
  protected async tick() {
    // periodically call crystallize_performance_fee and pay_accrued_fees on TraderVaults
  }
}
```


