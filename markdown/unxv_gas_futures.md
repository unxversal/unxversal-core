## Unxversal Gas Futures

### Purpose
Cash-settled futures on Sui gas price, priced in micro-USD per gas via RGP×SUI.

### Key Objects
- `GasFuturesRegistry`: contract map, trade/settlement params, dispute window, defaults, treasury id.
- `GasFuturesContract`: symbol, contract size (gas units), tick size, expiry and metrics.
- `GasPosition<C>`: position state and margin.

### Flows
- Listing: `list_gas_futures` with cooldown and defaults.
- Trading: `open_gas_position`, `close_gas_position`, and `record_gas_fill` with UNXV discount and maker rebate.
- Settlement: `settle_gas_futures` computes price; `settle_gas_position` distributes fee and returns margin.
- Liquidation: `liquidate_gas_position` when equity < maintenance.

### Off-chain
- Bots: lister, recorder, liquidation, settlement queue, display registrar.
- API: endpoints mirror dated futures with gas-specific parameters and price checks.

### SDK and API interfaces (TS)
```ts
export interface GasFuturesApi {
  listContract(req: { registryId: string; symbol: string; contractSizeGas: bigint; tickSizeMicroUsdPerGas: bigint; expiryMs: bigint; initMarginBps?: number; maintMarginBps?: number; }): Promise<TxBuildResult>;
  recordFill(req: { registryId: string; contractId: string; priceMicroUsdPerGas: bigint; size: bigint; takerIsBuyer: boolean; maker: string; unxvCoins?: string[]; suiUsdAggId: string; unxvUsdAggId: string; oracleCfgId: string; clockId: string; feeCoin: string; treasuryId: string; oiIncrease: boolean; min: bigint; max: bigint; }): Promise<TxBuildResult>;
  openPosition(req: { contractId: string; side: 0|1; size: bigint; entryPriceMicroUsdPerGas: bigint; marginCoin: string; }): Promise<TxBuildResult>;
  closePosition(req: { registryId: string; contractId: string; posId: string; priceMicroUsdPerGas: bigint; qty: bigint; treasuryId: string; }): Promise<TxBuildResult>;
  settleContract(req: { registryId: string; contractId: string; oracleCfgId: string; clockId: string; suiUsdAggId: string; }): Promise<TxBuildResult>;
}

export class GasLiquidationBot extends BotBase {
  protected async tick() {
    // compute maintenance equity vs price; submit liquidations
  }
}
```


