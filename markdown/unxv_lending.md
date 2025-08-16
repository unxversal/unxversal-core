## Unxversal Lending

### Purpose
Coin-based lending pools with per-asset risk controls, scaled index accounting, flash loans, and synth market support.

### Key Objects
- `LendingRegistry`: supported assets, interest rate models, global params, synth markets, admin allow-list.
- `LendingPool<T>`: cash, totals, indexes (supply/borrow 1e6), current rates.
- `UserAccount`: scaled supply/borrow per asset; synth liquidity and borrow units.

### Flows
- Supply/Withdraw: indexes maintained via `accrue_pool_interest`; health checks convert scaled to units via provided indexes.
- Borrow/Repay: LTV and health enforced using true units computed from indexes; borrow updates scaled balances.
- Liquidation (coins): repay top-ranked (by value) debt first (priority enforced), seize collateral value + bonus if below threshold.
- Flash Loans: coin flash loans accrue fee to reserves; synth flash loans mint/burn exposure within a single tx with fee in units.

### SDK and API interfaces (TS)
```ts
export interface LendingApi {
  openAccount(): Promise<TxBuildResult>;
  createPool(req: { assetSymbol: string; publisherId: string }): Promise<TxBuildResult>;
  supply<T=string>(req: { poolId: string; accountId: string; coinId: string; amount: bigint }): Promise<TxBuildResult>;
  withdraw<T=string>(req: { poolId: string; accountId: string; amount: bigint; oracleCfgId: string; clockId: string; priceSelfAggId: string; symbols: string[]; prices: bigint[]; supplyIndexes: bigint[]; borrowIndexes: bigint[] }): Promise<TxBuildResult>;
  borrow<T=string>(req: { poolId: string; accountId: string; amount: bigint; oracleCfgId: string; clockId: string; priceDebtAggId: string; symbols: string[]; prices: bigint[]; supplyIndexes: bigint[]; borrowIndexes: bigint[] }): Promise<TxBuildResult>;
  repay<T=string>(req: { poolId: string; accountId: string; paymentCoin: string }): Promise<TxBuildResult>;
  liquidate<T=string>(req: { debtPoolId: string; collPoolId: string; debtorId: string; oracleCfgId: string; clockId: string; debtAggId: string; collAggId: string; paymentCoin: string; repayAmount: bigint; symbols: string[]; prices: bigint[]; supplyIndexes: bigint[]; borrowIndexes: bigint[] }): Promise<TxBuildResult>;
}
```


