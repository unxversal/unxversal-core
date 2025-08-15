## Unxversal Synthetics

### Purpose
Collateralized synthetic assets with a central `SynthRegistry` for governance and global parameters.

### Key Objects
- `SynthRegistry`: global params, admin allow-list, listed assets, oracle feed mapping, treasury linkage, collateral config binding.
- `CollateralConfig<C>`: binds the concrete collateral coin type C (one-time).
- `CollateralVault<C>`: user-owned vault holding collateral and per-asset debt table.
- `Order`: shared order object for decentralized matching of synthetic exposure.

### Core Flows
- Listing: `create_synthetic_asset` registers an asset with per-asset overrides.
- Collateralization: `create_vault`, `deposit_collateral`, `withdraw_*` with CCR checks.
- Mint/Burn: `mint_synthetic`, `burn_synthetic` with UNXV discount fee support; multi-asset variants.
- Stability: `accrue_stability` prorates per elapsed time against USD debt value.
- Liquidation: `liquidate_vault` and `liquidate_vault_multi` seize collateral with bot reward split.
- Orderbook: `place_limit_order`, `cancel_order`, `match_orders` to trade exposure between vaults.

### Fees
- Mint/Burn fees: global defaults with per-asset overrides.
- UNXV discount: optional UNXV payments reduce fee liability at oracle price.
- Fees route to `treasury` via `deposit_collateral`/`deposit_unxv`.

### Off-chain
- Bots: synth matcher, liquidation, stability accrual scheduler, GC of expired orders.
- API: build tx for vault lifecycle and order placement/matching; read debt and health.

### SDK and API interfaces (TS)
```ts
export interface SynthVaultState { collateral: bigint; debts: Record<string, bigint>; ratioBps: number; }

export interface SynthApi {
  createVault(req: { cfgId: string; registryId: string; }): Promise<TxBuildResult>;
  deposit(req: { vaultId: string; coinId: string; amount: bigint; }): Promise<TxBuildResult>;
  withdraw(req: { vaultId: string; amount: bigint; symbolHint?: string; }): Promise<TxBuildResult>;
  mint(req: { registryId: string; vaultId: string; symbol: string; amountUnits: bigint; unxvCoins?: string[]; }): Promise<TxBuildResult>;
  burn(req: { registryId: string; vaultId: string; symbol: string; amountUnits: bigint; unxvCoins?: string[]; }): Promise<TxBuildResult>;
  placeOrder(req: { registryId: string; vaultId: string; symbol: string; side: 0|1; price: bigint; size: bigint; expiryMs: bigint; }): Promise<TxBuildResult>;
  cancelOrder(req: { orderId: string; }): Promise<TxBuildResult>;
  matchOrders(req: { registryId: string; buyId: string; sellId: string; takerIsBuyer: boolean; bounds: { min: bigint; max: bigint }; buyerVaultId: string; sellerVaultId: string; unxvCoins?: string[]; }): Promise<TxBuildResult>;
  health(req: { vaultId: string; symbol: string; }): Promise<SynthVaultState>;
}

export class SynthMatcherBot extends BotBase {
  protected async tick() {
    // 1) fetch open orders by symbol; 2) find crossed pairs; 3) submit match txs
  }
}
```


