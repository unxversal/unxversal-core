# UNXV Lending Protocol

A comprehensive decentralized lending protocol built on Sui that enables users to supply assets as collateral, borrow against their collateral, and participate in a sophisticated risk management system with real-time price feeds and liquidation mechanisms.

## Overview

The UNXV Lending Protocol provides:
- **Collateralized Lending**: Supply assets as collateral to borrow other supported assets
- **Real-time Risk Management**: Pyth price feeds for accurate asset valuation and health factor calculations
- **Liquidation Protection**: Automated liquidation system to maintain protocol solvency
- **UNXV Token Benefits**: Staking UNXV tokens provides borrowing discounts and enhanced rewards
- **Flash Loans**: Uncollateralized loans for arbitrage and liquidation activities
- **Interest Rate Models**: Dynamic interest rates based on utilization and market conditions

## Architecture

### Core Components

1. **LendingRegistry**: Global protocol configuration and asset management
2. **LendingPool**: Per-asset pools that manage liquidity and interest rates
3. **UserAccount**: Individual user positions, collateral, and debt tracking
4. **LiquidationEngine**: Manages liquidation parameters and execution
5. **StakingRegistry**: UNXV token staking and benefits system

### Price Integration

- **Pyth Network**: Real-time price feeds for all supported assets
- **Price Validation**: Staleness checks (max 60 seconds) and feed ID validation
- **Health Factor Calculations**: Real-time collateral and debt valuation

### Risk Management

- **Health Factor**: Collateral value / Debt value ratio with liquidation thresholds
- **Liquidation Threshold**: Minimum health factor (typically 120% = 12000 basis points)
- **Collateral Factors**: Asset-specific risk parameters (70-85% for most assets)
- **Interest Rate Models**: Dynamic rates based on utilization curves

## Key Features

### Supply & Withdraw
```move
public fun supply_asset<T>(
    registry: &mut LendingRegistry,
    account: &mut UserAccount,
    pool: &mut LendingPool<T>,
    asset: Coin<T>,
    is_collateral: bool,
    collateral_asset_names: &vector<String>,
    collateral_price_feeds: &vector<PriceInfoObject>,
    debt_asset_names: &vector<String>,
    debt_price_feeds: &vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): SupplyReceipt
```

### Borrow & Repay
```move
public fun borrow_asset<T>(
    registry: &mut LendingRegistry,
    account: &mut UserAccount,
    pool: &mut LendingPool<T>,
    borrow_amount: u64,
    collateral_asset_names: &vector<String>,
    collateral_price_feeds: &vector<PriceInfoObject>,
    debt_asset_names: &vector<String>,
    debt_price_feeds: &vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

### Health Factor Monitoring
```move
public fun calculate_current_health_factor(
    account: &UserAccount,
    registry: &LendingRegistry,
    collateral_asset_names: &vector<String>,
    collateral_price_feeds: &vector<PriceInfoObject>,
    debt_asset_names: &vector<String>,
    debt_price_feeds: &vector<PriceInfoObject>,
    clock: &Clock,
): u64
```

### Flash Loans
```move
public fun create_flash_loan<T>(
    pool: &mut LendingPool<T>,
    amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, FlashLoan)

public fun repay_flash_loan<T>(
    pool: &mut LendingPool<T>,
    loan_repayment: Coin<T>,
    flash_loan: FlashLoan,
)
```

### UNXV Staking Benefits
```move
public fun stake_unxv_for_benefits(
    staking_registry: &mut StakingRegistry,
    account: &mut UserAccount,
    stake_coin: Coin<UNXV>,
    ctx: &TxContext,
): StakingResult
```

## Deployment Requirements

### Required Objects

The lending protocol requires the following deployed objects and dependencies:

#### 1. Pyth Price Feeds
- **Pyth State Object**: `0x243759059f4c3111179da5878c12f68d612c21a8d54d85edc86164bb18be1c7c` (Testnet)
- **Wormhole State Object**: `0x31358d198147da50db32eda2562951d53973a0c0ad5ed738e9b17d88b213d790` (Testnet)
- **Price Feed IDs**: Configured per asset in the LendingRegistry.oracle_feeds table

#### 2. DeepBook Integration (Future)
- **Balance Manager**: For advanced trading and liquidity management
- **Pool Objects**: For each trading pair supported by the protocol

#### 3. UNXV Token Contract
- **UNXV Coin Type**: The native governance and utility token
- **Staking Rewards**: Token emission for staking participants

### Deployment Steps

1. **Deploy Core Contracts**:
   ```bash
   sui move build
   sui move publish --gas-budget 50000000
   ```

2. **Initialize Protocol Registry**:
   ```move
   let registry = create_lending_registry(ctx);
   ```

3. **Configure Supported Assets**:
   ```move
   add_supported_asset(
       registry,
       asset_name,
       collateral_factor,  // e.g., 8000 = 80%
       reserve_factor,     // e.g., 1000 = 10%
       oracle_feed_id,     // Pyth price feed ID
       admin_cap,
   );
   ```

4. **Create Asset Pools**:
   ```move
   let pool = create_lending_pool<AssetType>(registry, ctx);
   ```

5. **Set Interest Rate Models**:
   ```move
   set_interest_rate_model(
       pool,
       base_rate,          // e.g., 200 = 2%
       multiplier,         // e.g., 1000 = 10%
       jump_multiplier,    // e.g., 5000 = 50%
       optimal_utilization // e.g., 8000 = 80%
   );
   ```

### Required Price Feeds

The protocol requires Pyth price feeds for all supported assets:

| Asset | Feed ID (Testnet) | Decimals |
|-------|-------------------|----------|
| SUI | `0x50c67b3fd225db8912a424dd4baed60ffdde625ed2feaaf283724f9608fea266` | 9 |
| USDC | `0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | 6 |
| ETH | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` | 8 |

### Asset Configuration

Each supported asset requires configuration in the LendingRegistry:

```move
AssetConfig {
    asset_name: String,              // "SUI", "USDC", etc.
    asset_type: String,              // "NATIVE", "WRAPPED", "SYNTHETIC"
    collateral_factor: u64,          // 8000 = 80% LTV
    reserve_factor: u64,             // 1000 = 10% protocol fee
    liquidation_threshold: u64,      // 8500 = 85% liquidation threshold
    liquidation_penalty: u64,        // 500 = 5% liquidation bonus
    max_supply: u64,                 // Maximum supply cap
    max_borrow: u64,                 // Maximum borrow cap
    is_active: bool,                 // Can be supplied/borrowed
}
```

## Usage Examples

### Basic Lending Flow

1. **Supply Collateral**:
   ```typescript
   const tx = new Transaction();
   
   // Update Pyth price feeds first
   const priceInfoObjectIds = await pythClient.updatePriceFeeds(
     tx, priceUpdateData, priceIds
   );
   
   // Supply SUI as collateral
   tx.moveCall({
     target: `${packageId}::unxv_lending::supply_asset`,
     arguments: [
       tx.object(registry),
       tx.object(userAccount),
       tx.object(suiPool),
       tx.object(suiCoin),
       tx.pure(true), // is_collateral
       tx.pure(['SUI']), // collateral_asset_names
       tx.pure(priceInfoObjectIds), // price_feeds
       tx.pure([]), // debt_asset_names
       tx.pure([]), // debt_price_feeds
       tx.object(CLOCK),
     ],
     typeArguments: [SUI_TYPE],
   });
   ```

2. **Borrow Against Collateral**:
   ```typescript
   // Borrow USDC against SUI collateral
   tx.moveCall({
     target: `${packageId}::unxv_lending::borrow_asset`,
     arguments: [
       tx.object(registry),
       tx.object(userAccount),
       tx.object(usdcPool),
       tx.pure(borrowAmount),
       tx.pure(['SUI']), // collateral_asset_names
       tx.pure(suiPriceFeeds), // collateral_price_feeds
       tx.pure(['USDC']), // debt_asset_names
       tx.pure(usdcPriceFeeds), // debt_price_feeds
       tx.object(CLOCK),
     ],
     typeArguments: [USDC_TYPE],
   });
   ```

3. **Monitor Health Factor**:
   ```typescript
   const healthFactor = await sui.devInspectTransactionBlock({
     transactionBlock: tx,
     sender: address,
   });
   
   // Health factor < 12000 (120%) triggers liquidation risk
   if (healthFactor < 12000) {
     console.warn("Position at risk of liquidation");
   }
   ```

### Flash Loan Example

```typescript
// 1. Create flash loan
tx.moveCall({
  target: `${packageId}::unxv_lending::create_flash_loan`,
  arguments: [
    tx.object(pool),
    tx.pure(flashLoanAmount),
  ],
  typeArguments: [ASSET_TYPE],
});

// 2. Execute arbitrage/liquidation logic
// ... your custom logic here ...

// 3. Repay flash loan (must happen in same transaction)
tx.moveCall({
  target: `${packageId}::unxv_lending::repay_flash_loan`,
  arguments: [
    tx.object(pool),
    tx.object(repaymentCoin), // Original amount + fee
    tx.object(flashLoan),
  ],
  typeArguments: [ASSET_TYPE],
});
```

## Security Features

### Risk Parameters
- **Collateral Factors**: Conservative LTV ratios (70-85%)
- **Liquidation Thresholds**: Safety margins above collateral factors
- **Interest Rate Caps**: Maximum rates to prevent exploitation
- **Supply/Borrow Caps**: Per-asset limits to control exposure

### Price Feed Security
- **Staleness Checks**: Rejects prices older than 60 seconds
- **Feed Validation**: Verifies Pyth feed IDs against registry
- **Fallback Mechanisms**: Emergency pause functionality

### Access Controls
- **Admin Functions**: Protected by AdminCap
- **User Isolation**: Account-specific position tracking
- **Emergency Controls**: Protocol-wide pause capabilities

## Constants

```move
// Basis points for percentage calculations
const BASIS_POINTS: u64 = 10000; // 100% = 10000 bp

// Risk thresholds
const MIN_HEALTH_FACTOR: u64 = 12000; // 120%
const LIQUIDATION_THRESHOLD: u64 = 8500; // 85%

// Interest rate limits
const MAX_INTEREST_RATE: u64 = 10000; // 100% APY

// Price feed staleness
const MAX_PRICE_AGE: u64 = 60; // 60 seconds
```

## Testing

Build and test the protocol:

```bash
# Build the contract
sui move build

# Run tests
sui move test

# Deploy to testnet
sui move publish --gas-budget 50000000
```

## Integration

The UNXV Lending Protocol integrates with:
- **Pyth Network**: Real-time price feeds
- **DeepBook**: Future trading and liquidity features
- **UNXV Ecosystem**: Governance and utility token benefits
- **Sui Framework**: Native coin types and object capabilities

For integration examples and detailed API documentation, see the inline documentation in the source code. 