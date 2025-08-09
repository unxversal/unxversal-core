# UnXversal Lending Protocol Design

> **Note:** For the latest permissioning, architecture, and on-chain/off-chain split, see [MOVING_FORWARD.md](../MOVING_FORWARD.md). This document has been updated to reflect the current policy: **asset and pool listing is permissioned (admin only); only the admin can add new supported assets and create lending pools.**

## System Architecture & User Flow Overview

### How All Components Work Together

The UnXversal Lending protocol creates a sophisticated credit system that seamlessly integrates with the entire ecosystem, enabling efficient capital allocation, leveraged trading, and yield generation through intelligent asset management. It supports both base coins (e.g., SUI, USDC, major tokens) and synthetic assets listed in the Synthetics protocol:

#### **Core Object Hierarchy & Relationships**

```
LendingRegistry (Shared, admin-controlled) ← Central lending configuration & risk parameters
    ↓ manages pools
LendingPool<T> (Shared, admin-created; coins & synths) → InterestRateModel ← dynamic rate calculation
    ↓ tracks liquidity         ↓ calculates APR/APY
UserPosition (individual) ← collateral & debt tracking
    ↓ validates safety
CollateralManager (Service) → PriceOracle ← real-time valuations
    ↓ monitors health          ↓ provides pricing
LiquidationEngine ← processes liquidations
    ↓ executes via
Internal DEX / AutoSwap Router ← asset conversions
    ↓ enables atomic liquidation without external flash loans
UNXV Integration → fee discounts & yield bonuses
```

#### **Complete User Journey Flows**

**1. LENDING FLOW (Supply Assets for Yield)**
```
User → deposit assets → LendingPool receives deposit → 
mint LP tokens (receipt) → calculate new interest rates → 
start earning yield → AutoSwap converts fees to UNXV → 
UNXV stakers receive yield bonuses → compound interest
```

**2. BORROWING FLOW (Leverage & Credit)**
```
User → deposit collateral → CollateralManager validates → 
PriceOracle confirms valuations → calculate borrowing capacity → 
user requests loan → validate collateralization ratio → 
execute loan → update interest accrual → 
monitor position health continuously
```

**3. LEVERAGED TRADING FLOW (DEX Integration)**
```
User → deposits collateral → borrows trading asset → 
automatic DEX integration → execute leveraged trade → 
maintain collateral monitoring → manage margin requirements → 
AutoSwap handles cross-asset operations → settle trades
```

**4. LIQUIDATION FLOW (Risk Management)**
```
CollateralManager detects under-collateralization → 
LiquidationEngine calculates liquidation amount → 
optionally source capital via protocol flash loan → 
settle debt and convert collateral via internal DEX/AutoSwap → 
distribute liquidation bonus → 
update all affected positions
```

#### **Key System Interactions**

- **LendingRegistry**: Central command center managing all lending pools, risk parameters, supported assets, and system-wide configurations
- **LendingPool<T>**: Individual asset pools (coins & synths) that handle deposits, withdrawals, interest accrual, liquidity management, and protocol flash loans per pool
- **CollateralManager**: Sophisticated risk management system that monitors collateral health, calculates borrowing capacity, and triggers liquidations
- **InterestRateModel**: Dynamic interest rate calculation engine that adjusts rates based on supply/demand, utilization, and market conditions
- **LiquidationEngine**: Automated liquidation system using internal DEX/AutoSwap routing for capital-efficient liquidations (no external flash loans)
- **PriceOracle**: Real-time price feeds ensuring accurate collateral valuation and liquidation triggers
- **UNXV Integration**: Comprehensive tokenomics integration providing fee discounts, yield bonuses, and protocol value accrual

#### **Critical Design Patterns**

1. **Isolated Pool Architecture**: Each asset has its own lending pool, preventing cross-asset contagion while enabling precise risk management
2. **Internal Routing Liquidations**: Capital-efficient liquidations executed via internal DEX/AutoSwap paths
3. **Dynamic Interest Rates**: Interest rates automatically adjust based on supply/demand to maintain optimal utilization
4. **Cross-Protocol Collateral**: Synthetic assets and staked assets can be used as collateral, maximizing capital efficiency
5. **Automated Risk Management**: Continuous monitoring and automated liquidations prevent protocol insolvency
6. **Yield Optimization**: UNXV stakers receive additional yield bonuses, creating sustainable tokenomics

#### **Data Flow & State Management**

- **Interest Accrual**: Continuous interest calculation → position updates → rate adjustments → yield distribution
- **Collateral Monitoring**: Real-time price feeds → health factor calculation → liquidation triggers → automated responses
- **Liquidity Management**: Deposit/withdrawal tracking → utilization calculation → rate model updates → optimal allocation
- **Risk Assessment**: Collateral valuation → borrowing capacity → safety margins → liquidation thresholds
- **Fee Processing**: Protocol fees → AutoSwap conversion → UNXV burning → yield bonus distribution

#### **Advanced Features & Mechanisms**

- **Variable Interest Rates**: Dynamic rate adjustment based on utilization curves and market conditions
- **Collateral Factor Management**: Sophisticated LTV ratios based on asset volatility and liquidity
- **Internal Routing**: Native internal DEX/AutoSwap support for liquidations and conversions
- **Cross-Asset Borrowing**: Borrow any supported asset against any approved collateral
- **Liquidation Protection**: Multiple safety mechanisms including grace periods and partial liquidations
- **Yield Farming Integration**: Automatic yield farming opportunities for deposited assets

#### **Integration Points with UnXversal Ecosystem**

- **Synthetics**: Synthetic assets serve as both collateral and borrowable assets with specialized risk parameters
- **DEX**: Seamless integration for leveraged trading, liquidation execution, and cross-asset operations
- **AutoSwap**: All fees converted to UNXV, liquidated assets routed optimally, cross-protocol asset management
- **Options**: Options can be written against borrowed assets, premium used to repay loans
- **Perpetuals**: Borrowed assets used for perpetual trading with automatic margin management
- **Liquid Staking**: stSUI accepted as collateral with dynamic LTV based on staking rewards

#### **Risk Management & Safety Mechanisms**

- **Real-Time Monitoring**: Continuous position health monitoring with automatic liquidation triggers
- **Liquidation Cascades**: Protection against liquidation cascades through sophisticated risk models
- **Oracle Security**: Multiple oracle sources with deviation protection and circuit breakers
- **Interest Rate Caps**: Maximum interest rate limits to prevent extreme borrowing costs
- **Emergency Procedures**: Protocol pause capabilities and emergency asset recovery
- **Insurance Fund**: Protocol-owned insurance fund for covering potential bad debt

#### **Economic Mechanisms & Incentives**

- **Supply APY**: Competitive yields for asset suppliers based on borrowing demand
- **Borrow APR**: Dynamic borrowing rates that adjust to market conditions
- **UNXV Benefits**: Staking UNXV provides borrowing rate discounts and yield bonuses
- **Liquidation Bonuses**: Incentivize liquidators to maintain protocol health
- **Fee Distribution**: Protocol fees benefit UNXV holders through burning and yield bonuses

## Overview

UnXversal Lending is a robust lending protocol with **admin-permissioned asset and pool listing**. Only the admin can add new supported assets and create lending pools. Users can supply/borrow assets, but the set of available assets and pools is managed by the admin for risk and protocol consistency.

> **Key Policy:** Only assets and pools listed by the admin in the LendingRegistry are available for supply/borrow. Users cannot list new assets or create new pools directly.

## Integration with UnXversal Ecosystem

### Synthetics Protocol Integration
- **Synthetic Collateral**: Accept synthetic assets (sBTC, sETH, etc.) as collateral for borrowing
- **Synthetic Borrowing**: Users can borrow synthetic assets to gain leveraged exposure
- **Cross-Protocol Liquidations**: Liquidate undercollateralized positions using synthetic asset pools

### Spot DEX Integration  
- **Leveraged Trading**: Borrow assets directly for trading on the internal DEX
- **Automatic Liquidations**: Execute liquidations through internal routing (pools can optionally provide flash loans)

### UNXV Tokenomics
- **Interest Rate Discounts**: UNXV holders get reduced borrowing rates
- **Yield Bonuses**: UNXV stakers earn additional lending rewards
- **Fee Optimization**: All protocol fees auto-converted to UNXV and burned

## Core Architecture

### On-Chain Objects

#### 1. LendingRegistry (Shared Object, Admin-Controlled)
```move
struct LendingRegistry has key {
    id: UID,
    supported_assets: Table<String, AssetConfig>,
    lending_pools: Table<String, ID>,           // asset_name -> pool_id
    interest_rate_models: Table<String, InterestRateModel>,
    global_params: GlobalParams,
    risk_parameters: RiskParameters,
    oracle_feeds: Table<String, vector<u8>>,    // Pyth price feed IDs
    admin_cap: Option<AdminCap>,
}

struct AssetConfig has store {
    asset_name: String,
    asset_type: String,                         // "NATIVE", "SYNTHETIC", "WRAPPED"
    is_collateral: bool,
    is_borrowable: bool,
    collateral_factor: u64,                     // 80% = 8000 basis points
    liquidation_threshold: u64,                 // 85% = 8500 basis points
    liquidation_penalty: u64,                   // 5% = 500 basis points
    supply_cap: u64,                           // Maximum supply allowed
    borrow_cap: u64,                           // Maximum borrow allowed
    reserve_factor: u64,                       // Protocol fee percentage
}

struct GlobalParams has store {
    min_borrow_amount: u64,                    // Minimum borrow in USD value
    max_utilization_rate: u64,                 // 95% = 9500 basis points
    close_factor: u64,                         // 50% = 5000 basis points (max liquidation)
    grace_period: u64,                         // Time before liquidation (ms)
    flash_loan_fee: u64,                       // 9 basis points (0.09%)
}

struct RiskParameters has store {
    max_assets_as_collateral: u8,              // Maximum different collateral types
    health_factor_liquidation: u64,            // 1.0 = 10000 basis points
    debt_ceiling_global: u64,                  // Global debt limit in USD
    liquidation_incentive: u64,                // Additional liquidator reward
}

struct InterestRateModel has store {
    base_rate: u64,                            // Base interest rate (APR)
    multiplier: u64,                           // Rate slope factor
    jump_multiplier: u64,                      // Rate after optimal utilization
    optimal_utilization: u64,                  // Kink point in rate curve
}
```

#### 2. LendingPool (Admin-Created Only)
```move
struct LendingPool<phantom T> has key {
    id: UID,
    asset_name: String,
    
    // Pool balances
    total_supply: u64,                         // Total assets supplied
    total_borrows: u64,                        // Total assets borrowed
    total_reserves: u64,                       // Protocol reserves
    cash: Balance<T>,                          // Available liquidity
    
    // Interest tracking
    supply_index: u64,                         // Cumulative supply index
    borrow_index: u64,                         // Cumulative borrow index
    last_update_timestamp: u64,
    
    // Rate information
    current_supply_rate: u64,                  // Current supply APR
    current_borrow_rate: u64,                  // Current borrow APR
    utilization_rate: u64,                     // Current utilization
    
    // Integration objects
    router_pool_id: Option<ID>,                // Internal DEX/AutoSwap routing reference
    synthetic_registry_id: Option<ID>,         // If synthetic asset
}
```

#### 3. UserAccount (Owned Object)
```move
struct UserAccount has key {
    id: UID,
    owner: address,
    
    // Supply positions
    supply_balances: Table<String, SupplyPosition>,
    
    // Borrow positions  
    borrow_balances: Table<String, BorrowPosition>,
    
    // Account health
    total_collateral_value: u64,               // In USD terms
    total_borrow_value: u64,                   // In USD terms
    health_factor: u64,                        // Collateral/Borrow ratio
    
    // Risk tracking
    assets_as_collateral: VecSet<String>,
    last_health_check: u64,
    liquidation_threshold_breached: bool,
    
    // Rewards tracking
    unxv_stake_amount: u64,                    // UNXV staked for benefits
    reward_debt: Table<String, u64>,           // For yield farming
    
    // Account settings
    auto_compound: bool,                       // Auto-compound rewards
    max_slippage: u64,                         // For liquidations
}

struct SupplyPosition has store {
    principal_amount: u64,                     // Original supply amount
    scaled_balance: u64,                       // Balance with interest
    last_interest_index: u64,                  // For interest calculation
    is_collateral: bool,                       // Used as collateral
    supply_timestamp: u64,
}

struct BorrowPosition has store {
    principal_amount: u64,                     // Original borrow amount
    scaled_balance: u64,                       // Balance with interest
    last_interest_index: u64,                  // For interest calculation
    interest_rate_mode: String,                // "STABLE" or "VARIABLE"
    borrow_timestamp: u64,
}
```

#### 4. LiquidationEngine (Service Object)
```move
struct LiquidationEngine has key {
    id: UID,
    operator: address,
    
    // Liquidation parameters
    liquidation_threshold: u64,                // Health factor trigger
    liquidation_bonus: u64,                    // Liquidator reward
    max_liquidation_amount: u64,               // Per transaction limit
    
    // Integration with other protocols
    spot_dex_registry: ID,                     // For internal routing during liquidation
    
    // Performance tracking
    total_liquidations: u64,
    total_volume_liquidated: u64,
    average_liquidation_time: u64,
    
    // Risk management
    emergency_pause: bool,
    whitelisted_liquidators: VecSet<address>,
}
```

#### 5. YieldFarmingVault (Shared Object)
```move
struct YieldFarmingVault has key {
    id: UID,
    
    // Reward distribution
    unxv_rewards_per_second: u64,              // UNXV rewards rate
    total_allocation_points: u64,              // Total farm allocation
    pool_allocations: Table<String, u64>,      // Per-pool allocation points
    
    // UNXV staking benefits
    staked_unxv: Table<address, StakePosition>,
    stake_multipliers: Table<u64, u64>,        // Stake tier -> multiplier
    
    // Reward tracking
    total_rewards_distributed: u64,
    last_reward_timestamp: u64,
    reward_debt: Table<address, u64>,
}

struct StakePosition has store {
    amount: u64,                               // UNXV staked amount
    stake_timestamp: u64,                      // When staked
    tier: u64,                                 // Stake tier (0-5)
    multiplier: u64,                           // Reward multiplier
    locked_until: u64,                         // Lock expiry
}
```

### Events

#### 1. Supply and Borrow Events
```move
// When user supplies assets
struct AssetSupplied has copy, drop {
    user: address,
    asset: String,
    amount: u64,
    scaled_amount: u64,
    new_balance: u64,
    is_collateral: bool,
    supply_rate: u64,
    timestamp: u64,
}

// When user withdraws assets
struct AssetWithdrawn has copy, drop {
    user: address,
    asset: String,
    amount: u64,
    scaled_amount: u64,
    remaining_balance: u64,
    interest_earned: u64,
    timestamp: u64,
}

// When user borrows assets
struct AssetBorrowed has copy, drop {
    user: address,
    asset: String,
    amount: u64,
    scaled_amount: u64,
    new_borrow_balance: u64,
    borrow_rate: u64,
    health_factor: u64,
    timestamp: u64,
}

// When user repays debt
struct DebtRepaid has copy, drop {
    user: address,
    asset: String,
    amount: u64,
    scaled_amount: u64,
    remaining_debt: u64,
    interest_paid: u64,
    timestamp: u64,
}
```

#### 2. Liquidation Events
```move
// When liquidation is executed
struct LiquidationExecuted has copy, drop {
    liquidator: address,
    borrower: address,
    collateral_asset: String,
    debt_asset: String,
    debt_amount: u64,
    collateral_seized: u64,
    liquidation_bonus: u64,
    health_factor_before: u64,
    health_factor_after: u64,
    flash_loan_used: bool,
    timestamp: u64,
}

// When liquidation opportunity is detected
struct LiquidationOpportunityDetected has copy, drop {
    borrower: address,
    health_factor: u64,
    total_collateral_value: u64,
    total_debt_value: u64,
    liquidatable_amount: u64,
    estimated_profit: u64,
    timestamp: u64,
}
```

#### 3. Interest Rate Events
```move
// When interest rates are updated
struct InterestRatesUpdated has copy, drop {
    asset: String,
    old_supply_rate: u64,
    new_supply_rate: u64,
    old_borrow_rate: u64,
    new_borrow_rate: u64,
    utilization_rate: u64,
    total_supply: u64,
    total_borrows: u64,
    timestamp: u64,
}

// When user switches interest rate mode
struct InterestRateModeSwitched has copy, drop {
    user: address,
    asset: String,
    old_mode: String,
    new_mode: String,
    current_rate: u64,
    timestamp: u64,
}
```

#### 4. Yield Farming Events
```move
// When UNXV rewards are claimed
struct RewardsClaimed has copy, drop {
    user: address,
    unxv_amount: u64,
    bonus_multiplier: u64,
    stake_tier: u64,
    total_rewards_earned: u64,
    timestamp: u64,
}

// When UNXV is staked for benefits
struct UnxvStaked has copy, drop {
    user: address,
    amount: u64,
    new_tier: u64,
    new_multiplier: u64,
    lock_duration: u64,
    benefits: vector<String>,
    timestamp: u64,
}
```

#### 5. Protocol Events
```move
// When protocol reserves are updated
struct ReservesUpdated has copy, drop {
    asset: String,
    old_reserves: u64,
    new_reserves: u64,
    reserves_added: u64,
    reserve_factor: u64,
    timestamp: u64,
}

// When fees are collected and burned
struct ProtocolFeesProcessed has copy, drop {
    total_fees_collected: u64,
    unxv_burned: u64,
    reserve_allocation: u64,
    fee_sources: vector<String>,
    timestamp: u64,
}
```

## Core Functions

### 1. Supply and Withdraw Operations

#### Asset Supply
```move
public fun supply_asset<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    supply_amount: Coin<T>,
    use_as_collateral: bool,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): SupplyReceipt

struct SupplyReceipt has drop {
    amount_supplied: u64,
    scaled_amount: u64,
    new_supply_rate: u64,
    interest_earned: u64,
}
```

#### Asset Withdrawal
```move
public fun withdraw_asset<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    withdraw_amount: u64,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>

// Withdraw all available (considering health factor)
public fun withdraw_max_available<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

### 2. Borrow and Repay Operations

#### Asset Borrowing
```move
public fun borrow_asset<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    borrow_amount: u64,
    interest_rate_mode: String,        // "STABLE" or "VARIABLE"
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>

// Borrow maximum available amount
public fun borrow_max_available<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    target_health_factor: u64,         // Desired health factor after borrow
    interest_rate_mode: String,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T>
```

#### Debt Repayment
```move
public fun repay_debt<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    repay_amount: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): RepayReceipt

struct RepayReceipt has drop {
    amount_repaid: u64,
    interest_paid: u64,
    remaining_debt: u64,
    health_factor_improvement: u64,
}

// Repay all debt for an asset
public fun repay_all_debt<T>(
    pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    registry: &LendingRegistry,
    repay_coins: vector<Coin<T>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (RepayReceipt, vector<Coin<T>>) // Returns receipt and leftover coins
```

### 3. Leveraged Trading Integration

#### Borrow for Trading
```move
public fun borrow_for_leveraged_trade<T>(
    lending_pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    dex_registry: &DEXRegistry,
    borrow_amount: u64,
    trade_params: LeveragedTradeParams,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): LeveragedTradeResult

struct LeveragedTradeParams has drop {
    target_asset: String,              // Asset to buy with borrowed funds
    max_slippage: u64,                 // Maximum acceptable slippage
    stop_loss_price: Option<u64>,      // Automatic stop-loss
    take_profit_price: Option<u64>,    // Automatic take-profit
}

struct LeveragedTradeResult has drop {
    borrowed_amount: u64,
    assets_purchased: u64,
    leverage_ratio: u64,
    new_health_factor: u64,
    trade_id: ID,
}
```

#### Close Leveraged Position
```move
public fun close_leveraged_position<T>(
    lending_pool: &mut LendingPool<T>,
    account: &mut UserAccount,
    dex_registry: &DEXRegistry,
    position_id: ID,
    close_percentage: u64,             // 100% = 10000 basis points
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    deepbook_pools: vector<Pool>,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): PositionCloseResult

struct PositionCloseResult has drop {
    assets_sold: u64,
    debt_repaid: u64,
    profit_loss: i64,                  // Signed integer for P&L
    remaining_collateral: u64,
    final_health_factor: u64,
}
```

### 4. Liquidation System

#### Health Factor Monitoring
```move
public fun calculate_health_factor(
    account: &UserAccount,
    registry: &LendingRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): HealthFactorResult

struct HealthFactorResult has drop {
    health_factor: u64,                // 1.0 = 10000 basis points
    total_collateral_value: u64,
    total_debt_value: u64,
    liquidation_threshold_value: u64,
    time_to_liquidation: Option<u64>,  // Estimated time in ms
    is_liquidatable: bool,
}

public fun update_account_health(
    account: &mut UserAccount,
    registry: &LendingRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): bool // Returns true if liquidatable
```

#### Liquidation Execution
```move
public fun liquidate_position(
    liquidation_engine: &mut LiquidationEngine,
    borrower_account: &mut UserAccount,
    liquidator_account: &mut UserAccount,
    debt_asset: String,
    collateral_asset: String,
    liquidation_amount: u64,
    lending_pools: vector<LendingPool>,
    dex_registry: &DEXRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidationResult

struct LiquidationResult has drop {
    debt_repaid: u64,
    collateral_seized: u64,
    liquidation_bonus: u64,
    liquidator_profit: u64,
    borrower_health_factor: u64,
    gas_cost: u64,
}
```

// Flash loan liquidation removed: internal routing handles conversions without external flash loans

### 5. Interest Rate Management

#### Rate Calculation
```move
public fun calculate_interest_rates(
    pool: &LendingPool,
    registry: &LendingRegistry,
    asset_name: String,
): InterestRateResult

struct InterestRateResult has drop {
    supply_rate: u64,                  // APR for suppliers
    borrow_rate: u64,                  // APR for borrowers
    utilization_rate: u64,             // Current utilization
    optimal_utilization: u64,          // Target utilization
    rate_trend: String,                // "INCREASING", "DECREASING", "STABLE"
}

public fun update_interest_rates<T>(
    pool: &mut LendingPool<T>,
    registry: &LendingRegistry,
    clock: &Clock,
)
```

#### Dynamic Rate Adjustments
```move
public fun optimize_interest_rates(
    pools: vector<LendingPool>,
    registry: &mut LendingRegistry,
    market_conditions: MarketConditions,
    clock: &Clock,
): vector<RateAdjustment>

struct MarketConditions has drop {
    overall_utilization: u64,
    volatility_index: u64,
    liquidity_stress: bool,
    external_rates: Table<String, u64>, // DeFi market rates
}

struct RateAdjustment has drop {
    asset: String,
    old_rate: u64,
    new_rate: u64,
    adjustment_reason: String,
}
```

### 6. UNXV Staking and Rewards

#### UNXV Staking for Benefits
```move
public fun stake_unxv_for_benefits(
    vault: &mut YieldFarmingVault,
    account: &mut UserAccount,
    stake_amount: Coin<UNXV>,
    lock_duration: u64,                // Lock period in milliseconds
    ctx: &mut TxContext,
): StakingResult

struct StakingResult has drop {
    new_tier: u64,                     // 0-5 (Bronze to Diamond)
    new_multiplier: u64,               // Reward multiplier
    borrow_rate_discount: u64,         // Basis points discount
    supply_rate_bonus: u64,            // Basis points bonus
    benefits: vector<String>,          // List of unlocked benefits
}

// UNXV Stake Tiers:
// Tier 0 (No stake): 0 UNXV - No benefits
// Tier 1 (Bronze): 1,000 UNXV - 5% borrow discount, 2% supply bonus
// Tier 2 (Silver): 5,000 UNXV - 10% borrow discount, 5% supply bonus
// Tier 3 (Gold): 25,000 UNXV - 15% borrow discount, 10% supply bonus  
// Tier 4 (Platinum): 100,000 UNXV - 20% borrow discount, 15% supply bonus
// Tier 5 (Diamond): 500,000 UNXV - 25% borrow discount, 20% supply bonus
```

#### Yield Farming Rewards
```move
public fun claim_yield_rewards(
    vault: &mut YieldFarmingVault,
    account: &mut UserAccount,
    pools_to_claim: vector<String>,
    auto_compound: bool,
    ctx: &mut TxContext,
): RewardsClaimed

public fun calculate_pending_rewards(
    vault: &YieldFarmingVault,
    account: &UserAccount,
    pool_name: String,
): u64
```

### 7. Routing & Conversions

```move
// Internal routing for conversions required during liquidation/trading
public fun route_and_convert(
    dex_registry: &DEXRegistry,
    from_asset: String,
    to_asset: String,
    amount_in: u64,
    min_out: u64,
    ctx: &mut TxContext,
): u64 // amount_out
```

### 8. Flash Loans

#### Flash Loan Provision
```move
public fun initiate_flash_loan<T>(
    pool: &mut LendingPool<T>,
    registry: &LendingRegistry,
    loan_amount: u64,
    ctx: &mut TxContext,
): (Coin<T>, FlashLoan) // Hot potato pattern

public fun repay_flash_loan<T>(
    pool: &mut LendingPool<T>,
    registry: &LendingRegistry,
    loan_repayment: Coin<T>,
    flash_loan: FlashLoan,
    ctx: &mut TxContext,
)
```

#### Flash Loan Arbitrage (optional)
```move
public fun flash_arbitrage_lending_rates(
    source_pool: &mut LendingPool,
    target_pool: &mut LendingPool,
    arbitrage_amount: u64,
    dex_registry: &DEXRegistry,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): ArbitrageResult
```

## Advanced Features

### 1. Credit Delegation
```move
struct CreditDelegation has key {
    id: UID,
    delegator: address,                // Lender
    borrower: address,                 // Borrower
    asset: String,                     // Delegated asset
    credit_limit: u64,                 // Maximum borrowable amount
    interest_rate: u64,                // Agreed interest rate
    expiry: u64,                       // Delegation expiry
    used_credit: u64,                  // Currently borrowed amount
    collateral_required: bool,         // Whether borrower needs collateral
}

public fun delegate_credit(
    lender_account: &mut UserAccount,
    borrower: address,
    asset: String,
    credit_limit: u64,
    interest_rate: u64,
    duration: u64,
    ctx: &mut TxContext,
): ID
```

### 2. Isolated Lending Markets
```move
struct IsolatedMarket has key {
    id: UID,
    creator: address,
    asset_pairs: vector<String>,       // Allowed borrowing pairs
    risk_parameters: RiskParameters,
    interest_rate_models: Table<String, InterestRateModel>,
    total_supply: u64,
    total_borrows: u64,
    is_active: bool,
}

public fun create_isolated_market(
    creator: address,
    asset_pairs: vector<String>,
    risk_params: RiskParameters,
    initial_liquidity: vector<Coin>,
    ctx: &mut TxContext,
): ID
```

### 3. Lending Strategies
```move
struct LendingStrategy has key {
    id: UID,
    strategy_type: String,             // "YIELD_MAXIMIZER", "RISK_MINIMIZER", "BALANCED"
    target_assets: vector<String>,
    parameters: StrategyParams,
    performance_stats: StrategyStats,
    is_active: bool,
}

public fun create_yield_maximizer_strategy(
    target_yield: u64,                 // Target APR
    max_risk_level: u64,               // Risk tolerance
    assets: vector<String>,
    ctx: &mut TxContext,
): ID

public fun execute_strategy_rebalance(
    strategy: &mut LendingStrategy,
    pools: vector<LendingPool>,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): RebalanceResult
```

## Integration Patterns

### 1. Synthetics Protocol Integration
```move
// Use synthetic assets as collateral
public fun supply_synthetic_collateral<T>(
    lending_pool: &mut LendingPool<T>,
    synthetics_registry: &SyntheticsRegistry,
    account: &mut UserAccount,
    synthetic_coin: SyntheticCoin<T>,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
)

// Borrow against synthetic positions
public fun borrow_against_synthetic_vault(
    lending_registry: &LendingRegistry,
    synthetics_vault: &CollateralVault,
    borrow_asset: String,
    borrow_amount: u64,
    ctx: &mut TxContext,
): Coin
```

### 2. Spot DEX Integration
```move
// Automated liquidation through DEX
public fun liquidate_via_dex_routing(
    liquidation_engine: &mut LiquidationEngine,
    borrower_account: &mut UserAccount,
    dex_registry: &DEXRegistry,
    liquidation_params: LiquidationParams,
    deepbook_pools: vector<Pool>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidationResult

// Leveraged trading positions
public fun manage_leveraged_position(
    account: &mut UserAccount,
    position_id: ID,
    action: String,                    // "INCREASE", "DECREASE", "CLOSE"
    dex_registry: &DEXRegistry,
    lending_pools: vector<LendingPool>,
    ctx: &mut TxContext,
)
```

### 3. UNXV Ecosystem Integration
```move
// UNXV fee discount calculation
public fun calculate_unxv_benefits(
    account: &UserAccount,
    vault: &YieldFarmingVault,
    operation_type: String,            // "BORROW", "SUPPLY", "LIQUIDATE"
    base_rate: u64,
): BenefitCalculation

struct BenefitCalculation has drop {
    base_rate: u64,
    discount_percentage: u64,
    final_rate: u64,
    reward_multiplier: u64,
    estimated_savings_annual: u64,
}

// Auto-convert fees to UNXV and burn
public fun process_protocol_fees(
    registry: &mut LendingRegistry,
    autoswap_contract: &mut AutoSwapContract,
    unxv_burn_contract: &mut UNXVBurnContract,
    collected_fees: Table<String, u64>,
    ctx: &mut TxContext,
)
```

## Risk Management

### 1. Portfolio Risk Assessment
```move
public fun assess_portfolio_risk(
    account: &UserAccount,
    registry: &LendingRegistry,
    price_feeds: vector<PriceInfoObject>,
    volatility_data: Table<String, u64>,
    clock: &Clock,
): RiskAssessment

struct RiskAssessment has drop {
    overall_risk_score: u64,           // 0-100 scale
    diversification_score: u64,        // Portfolio diversity
    correlation_risk: u64,             // Asset correlation risk
    liquidity_risk: u64,               // Exit liquidity risk
    recommended_actions: vector<String>,
    stress_test_results: StressTestResults,
}

struct StressTestResults has drop {
    price_drop_10pct: HealthFactorResult,
    price_drop_25pct: HealthFactorResult,
    price_drop_50pct: HealthFactorResult,
    interest_rate_spike: HealthFactorResult,
}
```

### 2. Automated Risk Controls
```move
public fun apply_risk_controls(
    account: &mut UserAccount,
    registry: &LendingRegistry,
    risk_params: RiskControlParams,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): vector<RiskAction>

struct RiskControlParams has store {
    auto_repay_threshold: u64,         // Health factor trigger
    max_leverage: u64,                 // Maximum allowed leverage
    diversification_limits: Table<String, u64>, // Per-asset limits
    stop_loss_enabled: bool,
}

struct RiskAction has drop {
    action_type: String,               // "REPAY", "REDUCE_EXPOSURE", "LIQUIDATE"
    asset: String,
    amount: u64,
    urgency: String,                   // "LOW", "MEDIUM", "HIGH", "CRITICAL"
    estimated_cost: u64,
}
```

### 3. Insurance Fund
```move
struct InsuranceFund has key {
    id: UID,
    total_reserves: Table<String, Balance>,
    coverage_limits: Table<String, u64>,
    claim_history: vector<InsuranceClaim>,
    fund_utilization: u64,             // Percentage of fund used
}

struct InsuranceClaim has store {
    claimant: address,
    asset: String,
    amount_claimed: u64,
    claim_reason: String,
    claim_timestamp: u64,
    approved: bool,
}

public fun file_insurance_claim(
    fund: &mut InsuranceFund,
    claimant: address,
    asset: String,
    loss_amount: u64,
    evidence: vector<u8>,              // Proof of loss
    ctx: &mut TxContext,
): ID
```

## Indexer Integration

### Events to Index
1. **AssetSupplied/Withdrawn** - Liquidity provision tracking
2. **AssetBorrowed/DebtRepaid** - Borrowing activity monitoring  
3. **LiquidationExecuted** - Liquidation analytics
4. **InterestRatesUpdated** - Rate tracking and optimization
5. **RewardsClaimed** - Yield farming analytics
6. **ProtocolFeesProcessed** - Revenue and tokenomics tracking

### Custom API Endpoints
```typescript
// Lending positions and health
/api/v1/lending/positions/{address}     // User positions and health
/api/v1/lending/health/{address}        // Health factor monitoring
/api/v1/lending/liquidations/opportunities // Liquidation opportunities

// Market data and rates
/api/v1/lending/markets/overview        // All lending markets
/api/v1/lending/rates/current          // Current interest rates
/api/v1/lending/rates/history          // Historical rate data
/api/v1/lending/utilization            // Pool utilization metrics

// Yield farming and rewards
/api/v1/lending/rewards/pending/{address} // Pending UNXV rewards
/api/v1/lending/staking/tiers          // UNXV staking tier info
/api/v1/lending/strategies/performance  // Strategy performance data

// Risk and analytics
/api/v1/lending/risk/assessment/{address} // Risk analysis
/api/v1/lending/analytics/volume       // Lending volume analytics
/api/v1/lending/flash-loans/activity   // Flash loan usage metrics

// Integration endpoints
/api/v1/lending/synthetics/collateral  // Synthetic collateral data
/api/v1/lending/leveraged-trading      // Leveraged position tracking
/api/v1/lending/arbitrage/opportunities // Cross-protocol arbitrage
```

## CLI/Server Components

### 1. Position Manager
```typescript
class PositionManager {
    private suiClient: SuiClient;
    private priceOracle: PriceOracle;
    
    async getUserPositions(address: string): Promise<UserPositions>;
    async calculateHealthFactor(address: string): Promise<HealthFactor>;
    async optimizePositions(address: string): Promise<OptimizationSuggestions>;
    async autoCompoundRewards(address: string): Promise<void>;
}
```

### 2. Liquidation Monitor
```typescript
class LiquidationMonitor {
    private positionTracker: PositionTracker;
    private riskCalculator: RiskCalculator;
    
    async scanForLiquidations(): Promise<LiquidationOpportunity[]>;
    async executeLiquidation(opportunity: LiquidationOpportunity): Promise<void>;
    async calculateLiquidationProfit(position: Position): Promise<number>;
    async monitorHealthFactors(): Promise<void>;
}
```

### 3. Interest Rate Optimizer
```typescript
class InterestRateOptimizer {
    private rateModels: InterestRateModel[];
    private marketAnalyzer: MarketAnalyzer;
    
    async optimizeRates(): Promise<RateOptimizationResult>;
    async predictRateChanges(): Promise<RatePrediction[]>;
    async analyzeCompetitorRates(): Promise<CompetitorAnalysis>;
    async updateRateModels(): Promise<void>;
}
```

### 4. Yield Strategy Engine
```typescript
class YieldStrategyEngine {
    private strategyRegistry: StrategyRegistry;
    private riskAssessor: RiskAssessor;
    
    async createYieldStrategy(params: StrategyParams): Promise<string>;
    async executeStrategy(strategyId: string): Promise<void>;
    async rebalancePortfolio(address: string): Promise<void>;
    async backtestStrategy(strategy: Strategy): Promise<BacktestResults>;
}
```

### 5. Arbitrage Bots (optional)
```typescript
class RoutingArbitrageBot {
    private arbitrageScanner: ArbitrageScanner;
    private executionEngine: ExecutionEngine;
    
    async scanArbitrageOpportunities(): Promise<ArbitrageOpportunity[]>;
    async executeRouteArbitrage(opportunity: ArbitrageOpportunity): Promise<void>;
    async calculateProfitability(rates: InterestRates[]): Promise<number>;
    async monitorCrossProtocolRates(): Promise<void>;
}
class FlashLoanArbitrageBot {
    private arbitrageScanner: ArbitrageScanner;
    private executionEngine: ExecutionEngine;
    
    async scanArbitrageOpportunities(): Promise<ArbitrageOpportunity[]>;
    async executeFlashLoanArbitrage(opportunity: ArbitrageOpportunity): Promise<void>;
    async calculateProfitability(rates: InterestRates[]): Promise<number>;
    async monitorCrossProtocolRates(): Promise<void>;
}
```

## Frontend Integration

### 1. Lending Dashboard
- **Position Overview**: Supply/borrow balances, health factor, P&L
- **Interest Rate Tracking**: Current rates, historical charts, predictions
- **Risk Monitoring**: Health factor alerts, liquidation warnings
- **UNXV Benefits**: Staking tier, discounts, reward estimates

### 2. Advanced Trading Interface
- **Leveraged Trading**: Borrow-to-trade with integrated DEX
- **Position Management**: Stop-loss, take-profit, leverage adjustment
- **Cross-Asset Strategies**: Synthetic collateral optimization
- **Flash Loan Tools**: Arbitrage opportunity detection

### 3. Yield Optimization
- **Strategy Builder**: Create custom yield strategies
- **Auto-Compound Settings**: Automated reward compounding
- **Risk-Return Analysis**: Strategy backtesting and optimization
- **Performance Tracking**: Real-time strategy performance

## Security Considerations

1. **Oracle Manipulation**: Multi-oracle price validation with deviation checks
2. **Flash Loan Attacks**: Atomic operation validation and reentrancy protection
3. **Interest Rate Manipulation**: Rate change limits and time delays
4. **Liquidation Front-Running**: MEV protection and fair ordering
5. **Smart Contract Risks**: Formal verification and comprehensive auditing
6. **Economic Attacks**: Incentive alignment and circuit breakers
7. **Cross-Protocol Risks**: Integration security with synthetics and DEX

## Permissioning & Market Creation

- **Asset/Pool Listing:** Only the admin (holding AdminCap) can add new supported assets and create lending pools. This is a permissioned operation for risk management and protocol consistency.
- **On-Chain/Off-Chain Split:**
  - On-chain: All supply, borrow, collateral, and liquidation logic; admin listing of assets/pools; event emission.
  - Off-chain: Indexing, liquidation bots, price monitoring, and user-facing automation.

## Deployment Strategy

- **Phase 1:** Deploy registry, admin lists initial assets and creates pools (SUI, USDC, major tokens, etc.)
- **Phase 2:** Add advanced features and integrations as needed, with admin managing new asset/pool listings
- **Phase 3:** Admin can add new assets/pools as needed, but users cannot list new assets or create pools directly

## UNXV Integration Benefits

### For Lenders
- **Enhanced Yields**: Up to 20% bonus APR for UNXV stakers
- **Reduced Risk**: Priority liquidation protection
- **Fee Savings**: Reduced protocol fees with UNXV payments
- **Exclusive Features**: Access to premium strategies and markets

### For Borrowers
- **Lower Rates**: Up to 25% discount on borrowing rates for UNXV stakers
- **Higher LTV**: Increased borrowing capacity with UNXV collateral
- **Flexible Terms**: Access to credit delegation and isolated markets
- **Trading Integration**: Seamless leveraged trading with DEX

### For Protocol
- **Sustainable Revenue**: Fee collection and strategic reserve building
- **UNXV Demand**: Constant buying pressure from staking benefits
- **Deflationary Pressure**: Protocol fee burning reduces UNXV supply
- **Network Effects**: Integration with all UnXversal protocols creates ecosystem value

The UnXversal Lending Protocol creates a robust foundation for the DeFi ecosystem while providing clear utility and value accrual for UNXV token holders through innovative staking mechanisms and cross-protocol integration. 