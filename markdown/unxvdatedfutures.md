# UnXversal Dated Futures Protocol Design

> **Note:** For the latest permissioning, architecture, and on-chain/off-chain split, see [MOVING_FORWARD.md](../MOVING_FORWARD.md). This document has been updated to reflect the current policy: **market/contract creation is permissionless (with a minimum interval restriction, e.g., daily as the smallest interval); anyone can create new futures contracts. DeepBook pool creation is also permissionless.**

## System Architecture & User Flow Overview

### How All Components Work Together

The UnXversal Dated Futures protocol provides traditional futures contracts with fixed expiration dates, enabling sophisticated term structure trading, calendar spreads, and automated settlement through comprehensive cross-protocol integration:

#### **Core Object Hierarchy & Relationships**

```
DatedFuturesRegistry (Shared, permissionless) ← Central futures configuration & expiration cycles (anyone can create contracts, subject to minimum interval enforcement)
    ↓ manages contracts
FuturesContract<T> (Shared) → ExpirationManager ← handles settlement & rollover
    ↓ tracks positions           ↓ automates expiration
FuturesPosition (individual) ← user contracts & P&L
    ↓ validates margin
MarginManager (Service) → PriceOracle ← TWAP/VWAP pricing
    ↓ monitors health           ↓ provides settlement prices
SettlementEngine ← processes contract expiration
    ↓ executes via
DeepBook Integration → AutoSwap ← asset delivery & cash settlement (DeepBook pool creation is permissionless)
    ↓ provides liquidity       ↓ handles conversions
UNXV Integration → fee discounts & premium features
```

---

## Permissioning Policy

- **Market/contract creation in the Dated Futures registry is permissionless (anyone can create, subject to minimum interval enforcement).**
- **DeepBook pool creation is permissionless.**
- **All trading, position management, and advanced order types are permissionless for users.**
- **Minimum interval enforcement (e.g., daily) is implemented to prevent spam and ensure orderly market creation.**
- **Off-chain bots (run by users or the CLI/server) can automate market creation, liquidation, and settlement, and are incentivized via rewards.**
- See [MOVING_FORWARD.md](../MOVING_FORWARD.md) for the full permissioning matrix and rationale.

---

#### **Complete User Journey Flows**

**1. FUTURES TRADING FLOW (Opening Contracts)**
```
User → select futures contract & expiration → choose position size → 
MarginManager validates collateral → open futures position → 
track time decay & convergence → monitor margin requirements → 
settle at expiration or roll forward
```

**2. CALENDAR SPREAD FLOW (Term Structure Trading)**
```
User → identify calendar spread opportunity → 
simultaneously long near-term & short far-term (or vice versa) → 
atomic execution of spread → monitor time decay differential → 
profit from term structure changes → close or roll positions
```

**3. CONTRACT SETTLEMENT FLOW (Expiration)**
```
Contract approaches expiration → SettlementEngine calculates TWAP/VWAP → 
determine final settlement price → cash settlement processing → 
AutoSwap handles asset conversions → settle all positions → 
release margin + profits → update contract statistics
```

**4. AUTO-ROLL FLOW (Position Continuation)**
```
User enables auto-roll → contract nears expiration → 
system identifies next contract → calculate roll cost → 
atomic close expiring & open new contract → 
maintain position continuity → update margin requirements
```

#### **Key System Interactions**

- **DatedFuturesRegistry**: Central hub managing all futures contracts, expiration schedules, margin requirements, and settlement parameters
- **FuturesContract<T>**: Individual futures contracts for each asset and expiration date handling trading and settlement
- **ExpirationManager**: Automated system managing contract lifecycles, settlement procedures, and rollover mechanisms
- **MarginManager**: Sophisticated margin system with daily mark-to-market and variation margin calls
- **SettlementEngine**: Automated settlement using TWAP/VWAP calculations with dispute resolution mechanisms
- **PriceOracle**: Time-weighted pricing for accurate and manipulation-resistant settlement prices

## Overview

UnXversal Dated Futures provides traditional futures contracts with fixed expiration dates on synthetic assets, enabling sophisticated hedging strategies, speculation, and arbitrage opportunities. Unlike perpetual futures, these contracts have defined settlement dates and use cash settlement based on underlying synthetic asset prices, offering traders precise risk management tools and institutional-grade derivatives functionality.

## Core Purpose and Features

### Primary Functions
- **Traditional Futures Contracts**: Fixed expiration dates (weekly, monthly, quarterly)
- **Cash Settlement**: Automatic settlement to USDC based on final settlement price
- **Contango/Backwardation**: Natural price curves and term structure trading
- **Calendar Spreads**: Trade between different expiration months
- **Sophisticated Hedging**: Precise risk management for synthetic asset exposure
- **Institutional Features**: Block trading, portfolio margining, and risk analytics

### Key Advantages
- **DeepBook Integration**: Deep liquidity and optimal price discovery across all contracts
- **Synthetic Asset Base**: Futures on sBTC, sETH, sSOL, and all synthetic assets
- **Term Structure Trading**: Capture volatility and time-based arbitrage opportunities
- **Cross-Protocol Synergy**: Integration with lending, options, and perpetuals
- **UNXV Utility**: Enhanced features and fee discounts for UNXV holders
- **Risk Management**: Advanced margin requirements and settlement procedures

## Core Architecture

### On-Chain Objects

#### 1. FuturesRegistry (Shared Object)
```move
struct FuturesRegistry has key {
    id: UID,
    
    // Contract management
    active_contracts: Table<String, FuturesContract>,    // Contract symbol -> contract data
    expired_contracts: Table<String, FuturesContract>,   // Historical contracts
    contract_series: Table<String, ContractSeries>,      // Asset -> series info
    
    // Expiration management
    expiration_schedule: Table<String, ExpirationSchedule>, // Asset -> expiration dates
    settlement_procedures: Table<String, SettlementConfig>, // Contract -> settlement config
    auto_settlement_enabled: bool,
    
    // Trading infrastructure
    deepbook_pools: Table<String, ID>,                   // Contract -> DeepBook pool ID
    price_feeds: Table<String, ID>,                      // Contract -> Pyth price feed ID
    synthetic_vaults: Table<String, ID>,                 // Underlying -> synthetic vault ID
    
    // Risk management
    margin_requirements: Table<String, MarginConfig>,    // Contract -> margin config
    position_limits: Table<String, PositionLimits>,     // Contract -> position limits
    daily_settlement_enabled: bool,                      // Mark-to-market daily
    
    // Fee structure
    trading_fees: TradingFeeStructure,                   // Base trading fees
    settlement_fees: SettlementFeeStructure,             // Settlement fees
    delivery_fees: DeliveryFeeStructure,                 // Physical delivery fees (future)
    
    // UNXV tokenomics
    unxv_benefits: Table<u64, TierBenefits>,            // Tier -> benefits
    fee_collection: FeeCollectionConfig,                 // Fee processing
    
    // Emergency controls
    emergency_settlement: bool,                          // Emergency early settlement
    trading_halts: Table<String, TradingHalt>,          // Contract -> halt status
    admin_cap: Option<AdminCap>,
}

struct FuturesContract has store {
    contract_symbol: String,                             // "sBTC-DEC24", "sETH-MAR25"
    underlying_asset: String,                            // "sBTC", "sETH"
    contract_size: u64,                                  // Size of one contract
    tick_size: u64,                                      // Minimum price increment
    
    // Expiration details
    expiration_timestamp: u64,                           // Contract expiration
    last_trading_day: u64,                              // Last day to trade
    settlement_timestamp: u64,                           // Settlement execution time
    settlement_method: String,                           // "CASH", "PHYSICAL" (future)
    
    // Contract status
    is_active: bool,                                     // Currently tradeable
    is_expired: bool,                                    // Past expiration
    is_settled: bool,                                    // Settlement completed
    settlement_price: Option<u64>,                       // Final settlement price
    
    // Market data
    current_price: u64,                                  // Current futures price
    underlying_price: u64,                               // Current underlying price
    basis: i64,                                          // futures_price - underlying_price
    volume_24h: u64,                                     // 24-hour trading volume
    open_interest: u64,                                  // Total open interest
    
    // Integration
    deepbook_pool_id: ID,                               // DeepBook pool for this contract
    balance_manager_id: ID,                             // Shared balance manager
    price_feed_id: ID,                                  // Pyth price feed
}

struct ContractSeries has store {
    underlying_asset: String,                            // "sBTC"
    contract_months: vector<String>,                     // ["DEC24", "MAR25", "JUN25", "SEP25"]
    contract_cycle: String,                              // "QUARTERLY", "MONTHLY", "WEEKLY"
    auto_listing: bool,                                  // Automatically list new contracts
    days_before_expiry: u64,                            // Stop trading X days before expiry
}

struct ExpirationSchedule has store {
    contract_cycle: String,                              // "QUARTERLY", "MONTHLY", "WEEKLY"
    expiration_day: String,                              // "THIRD_FRIDAY", "LAST_FRIDAY"
    expiration_time: u64,                               // Time of day in milliseconds
    timezone: String,                                    // "UTC"
    auto_rollover: bool,                                // Auto-create next contract
}

struct MarginConfig has store {
    initial_margin_rate: u64,                           // Initial margin requirement (5%)
    maintenance_margin_rate: u64,                       // Maintenance margin (3%)
    margin_type: String,                                // "SPAN", "SIMPLE", "PORTFOLIO"
    cross_margin_eligible: bool,                        // Can use cross-margin
    margin_currency: String,                            // "USDC"
    volatility_adjustment: u64,                         // Margin adjustment for volatility
}

struct PositionLimits has store {
    max_position_size: u64,                             // Maximum position size
    max_order_size: u64,                                // Maximum single order size
    position_limit_type: String,                        // "GROSS", "NET"
    accountability_threshold: u64,                      // Large position reporting
    delivery_limit: u64,                               // Maximum delivery position
}
```

#### 2. FuturesMarket<T> (Shared Object)
```move
struct FuturesMarket<phantom T> has key {
    id: UID,
    
    // Market identification
    contract_symbol: String,                             // "sBTC-DEC24"
    underlying_type: String,                            // Phantom type identifier
    expiration_timestamp: u64,                          // Contract expiration
    
    // Position tracking
    long_positions: Table<address, FuturesPosition>,    // User -> long position
    short_positions: Table<address, FuturesPosition>,   // User -> short position
    total_positions: u64,                               // Total number of positions
    
    // Market state
    current_price: u64,                                 // Current futures price
    settlement_price: Option<u64>,                      // Final settlement price
    daily_settlement_price: u64,                        // Daily mark-to-market price
    price_history: vector<PricePoint>,                  // Historical prices
    
    // Volume and open interest
    total_volume_24h: u64,                              // 24-hour volume
    total_open_interest: u64,                           // Total open interest
    oi_by_expiry: Table<u64, u64>,                     // Expiry -> open interest
    volume_by_expiry: Table<u64, u64>,                 // Expiry -> volume
    
    // Term structure
    term_structure: TermStructure,                      // Price curve across expirations
    implied_volatility: u64,                           // Market implied volatility
    time_to_expiry: u64,                               // Days until expiration
    
    // Settlement tracking
    pending_settlements: vector<SettlementRequest>,     // Positions awaiting settlement
    settled_positions: u64,                            // Count of settled positions
    settlement_funds: Balance<USDC>,                    // Funds for settlements
    
    // Integration objects
    deepbook_pool_id: ID,                              // DeepBook pool
    balance_manager_id: ID,                            // Balance manager
    price_feed_id: ID,                                 // Price feed
}

struct FuturesPosition has store {
    user: address,
    position_id: ID,
    
    // Position details
    side: String,                                       // "LONG" or "SHORT"
    size: u64,                                         // Position size in contracts
    average_price: u64,                                // Average entry price
    margin_posted: u64,                                // Posted margin in USDC
    
    // Profit/Loss tracking
    unrealized_pnl: i64,                               // Current unrealized P&L
    daily_pnl: i64,                                    // Daily P&L from settlement
    cumulative_pnl: i64,                               // Total P&L since opening
    margin_calls: u64,                                 // Number of margin calls
    
    // Position management
    created_timestamp: u64,
    last_settlement_timestamp: u64,                    // Last daily settlement
    auto_roll_enabled: bool,                           // Auto-roll to next contract
    
    // Settlement details
    settlement_eligible: bool,                          // Ready for final settlement
    settlement_amount: Option<u64>,                     // Final settlement value
    settlement_timestamp: Option<u64>,                  // When settled
}

struct TermStructure has store {
    curve_points: vector<CurvePoint>,                   // Price curve data points
    contango_backwardation: i64,                       // Positive = contango, negative = backwardation
    implied_carry_cost: u64,                           // Implied cost of carry
    volatility_term_structure: vector<VolatilityPoint>, // Volatility across terms
    last_update: u64,
}

struct CurvePoint has store {
    expiration_timestamp: u64,
    futures_price: u64,
    time_to_expiry: u64,
    open_interest: u64,
    implied_volatility: u64,
}

struct VolatilityPoint has store {
    expiration_timestamp: u64,
    implied_volatility: u64,
    realized_volatility: u64,
    volatility_premium: i64,                           // Implied - realized
}

struct SettlementRequest has store {
    position_id: ID,
    user: address,
    position_size: u64,
    settlement_price: u64,
    settlement_amount: u64,
    settlement_type: String,                           // "FINAL", "DAILY", "EARLY"
    processing_priority: u64,
}
```

#### 3. SettlementEngine (Service Object)
```move
struct SettlementEngine has key {
    id: UID,
    operator: address,
    
    // Settlement parameters
    settlement_window: u64,                             // Time window for settlement (1 hour)
    settlement_price_sources: vector<String>,           // Price source priorities
    price_deviation_threshold: u64,                     // Max deviation between sources (1%)
    
    // Settlement processing
    daily_settlement_enabled: bool,                     // Mark-to-market daily
    daily_settlement_time: u64,                        // UTC time for daily settlement
    final_settlement_lag: u64,                         // Delay after expiration (30 minutes)
    
    // Settlement funds management
    settlement_reserves: Table<String, Balance<USDC>>, // Contract -> settlement reserves
    reserve_requirements: Table<String, u64>,          // Contract -> required reserves
    emergency_reserves: Balance<USDC>,                 // Emergency settlement fund
    
    // Processing queues
    settlement_queue: vector<SettlementRequest>,       // Pending settlements
    processing_batch_size: u64,                       // Max settlements per batch
    processing_frequency: u64,                         // Process every 10 minutes
    
    // Dispute resolution
    settlement_disputes: vector<SettlementDispute>,    // Price disputes
    dispute_resolution_period: u64,                    // 24 hours for disputes
    arbitration_panel: vector<address>,                // Dispute arbitrators
    
    // Performance tracking
    settlement_success_rate: u64,                      // Successful settlement rate
    average_settlement_time: u64,                      // Average processing time
    total_settlements_processed: u64,                  // Total lifetime settlements
}

struct SettlementDispute has store {
    contract_symbol: String,
    disputed_price: u64,
    claimed_correct_price: u64,
    disputing_parties: vector<address>,
    evidence: vector<String>,                          // IPFS hashes of evidence
    dispute_timestamp: u64,
    resolution_deadline: u64,
    status: String,                                    // "PENDING", "RESOLVED", "ESCALATED"
}
```

#### 4. CalendarSpreadEngine (Service Object)
```move
struct CalendarSpreadEngine has key {
    id: UID,
    operator: address,
    
    // Spread definitions
    available_spreads: Table<String, CalendarSpread>,  // Spread symbol -> spread config
    spread_margins: Table<String, SpreadMargin>,       // Spread -> margin requirements
    auto_spread_creation: bool,                        // Auto-create common spreads
    
    // Spread trading
    active_spread_orders: Table<ID, SpreadOrder>,      // Order ID -> spread order
    spread_executions: vector<SpreadExecution>,        // Recent spread executions
    spread_book: Table<String, SpreadOrderBook>,       // Spread -> order book
    
    // Risk management
    spread_position_limits: Table<String, u64>,        // Spread -> position limits
    inter_month_correlations: Table<String, u64>,      // Correlation between months
    spread_volatility: Table<String, u64>,             // Spread volatility tracking
    
    // Analytics
    spread_performance: Table<String, SpreadMetrics>,  // Spread -> performance data
    arbitrage_opportunities: vector<ArbitrageOpportunity>, // Real-time arbitrage alerts
}

struct CalendarSpread has store {
    spread_symbol: String,                              // "sBTC-DEC24/MAR25"
    front_month: String,                               // "sBTC-DEC24"
    back_month: String,                                // "sBTC-MAR25"
    spread_ratio: u64,                                 // 1:1, 2:1, etc.
    tick_size: u64,                                    // Minimum spread increment
    is_active: bool,
}

struct SpreadOrder has store {
    order_id: ID,
    user: address,
    spread_symbol: String,
    side: String,                                      // "BUY_SPREAD", "SELL_SPREAD"
    quantity: u64,
    spread_price: u64,                                 // Price differential
    order_type: String,                                // "LIMIT", "MARKET"
    time_in_force: String,                             // "GTC", "IOC", "FOK"
    status: String,                                    // "PENDING", "PARTIAL", "FILLED", "CANCELLED"
}

struct SpreadExecution has store {
    spread_symbol: String,
    executed_quantity: u64,
    spread_price: u64,
    front_month_price: u64,
    back_month_price: u64,
    execution_timestamp: u64,
    buyer: address,
    seller: address,
}

struct ArbitrageOpportunity has store {
    opportunity_type: String,                          // "CALENDAR_SPREAD", "FUTURES_SPOT", "CROSS_EXCHANGE"
    asset: String,
    contracts_involved: vector<String>,
    price_discrepancy: u64,
    estimated_profit: u64,
    required_capital: u64,
    risk_score: u64,
    expiry_timestamp: u64,
}
```

### Events

#### 1. Contract Lifecycle Events
```move
// When a new futures contract is listed
struct FuturesContractListed has copy, drop {
    contract_symbol: String,
    underlying_asset: String,
    expiration_timestamp: u64,
    contract_size: u64,
    initial_margin_rate: u64,
    deepbook_pool_id: ID,
    listing_timestamp: u64,
}

// When a contract expires
struct FuturesContractExpired has copy, drop {
    contract_symbol: String,
    expiration_timestamp: u64,
    final_settlement_price: u64,
    total_open_interest: u64,
    positions_to_settle: u64,
    settlement_deadline: u64,
    timestamp: u64,
}

// When settlement price is determined
struct SettlementPriceSet has copy, drop {
    contract_symbol: String,
    settlement_price: u64,
    price_sources: vector<String>,
    price_deviation: u64,
    settlement_timestamp: u64,
    disputes_allowed_until: u64,
}
```

#### 2. Position Events
```move
// When futures position is opened
struct FuturesPositionOpened has copy, drop {
    position_id: ID,
    user: address,
    contract_symbol: String,
    side: String,
    size: u64,
    entry_price: u64,
    margin_posted: u64,
    trading_fee: u64,
    days_to_expiry: u64,
    timestamp: u64,
}

// When position is rolled to next contract
struct PositionRolled has copy, drop {
    old_position_id: ID,
    new_position_id: ID,
    user: address,
    from_contract: String,
    to_contract: String,
    position_size: u64,
    roll_price: u64,
    roll_cost: i64,                                    // Cost or credit from rolling
    timestamp: u64,
}

// When position is settled
struct PositionSettled has copy, drop {
    position_id: ID,
    user: address,
    contract_symbol: String,
    position_size: u64,
    settlement_price: u64,
    settlement_amount: u64,
    realized_pnl: i64,
    settlement_fee: u64,
    settlement_type: String,                           // "FINAL", "EARLY", "FORCED"
    timestamp: u64,
}
```

#### 3. Calendar Spread Events
```move
// When calendar spread order is placed
struct CalendarSpreadOrderPlaced has copy, drop {
    order_id: ID,
    user: address,
    spread_symbol: String,
    side: String,
    quantity: u64,
    spread_price: u64,
    front_month_price: u64,
    back_month_price: u64,
    timestamp: u64,
}

// When calendar spread is executed
struct CalendarSpreadExecuted has copy, drop {
    execution_id: ID,
    spread_symbol: String,
    executed_quantity: u64,
    spread_price: u64,
    buyer: address,
    seller: address,
    total_value: u64,
    timestamp: u64,
}
```

#### 4. Term Structure Events
```move
// When term structure is updated
struct TermStructureUpdated has copy, drop {
    underlying_asset: String,
    curve_points: vector<CurvePoint>,
    contango_backwardation: i64,
    implied_volatility_average: u64,
    update_timestamp: u64,
}

// When arbitrage opportunity is detected
struct ArbitrageOpportunityDetected has copy, drop {
    opportunity_id: ID,
    opportunity_type: String,
    assets_involved: vector<String>,
    estimated_profit: u64,
    required_capital: u64,
    risk_score: u64,
    expiry_timestamp: u64,
    detection_timestamp: u64,
}
```

## Core Functions

### 1. Contract Management

#### Listing New Contracts
```move
public fun list_futures_contract<T>(
    registry: &mut FuturesRegistry,
    underlying_asset: String,
    expiration_timestamp: u64,
    contract_specifications: ContractSpecs,
    margin_config: MarginConfig,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): (FuturesMarket<T>, ContractListingResult)

struct ContractSpecs has drop {
    contract_size: u64,
    tick_size: u64,
    settlement_method: String,                         // "CASH", "PHYSICAL"
    last_trading_offset: u64,                         // Days before expiration
    position_limits: PositionLimits,
}

struct ContractListingResult has drop {
    contract_symbol: String,
    deepbook_pool_id: ID,
    initial_margin_rate: u64,
    estimated_trading_start: u64,
}

// Auto-list next contract in series
public fun auto_list_next_contract<T>(
    registry: &mut FuturesRegistry,
    series: &ContractSeries,
    current_contract: &FuturesContract,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<FuturesMarket<T>>
```

#### Contract Expiration and Settlement
```move
public fun expire_contract<T>(
    registry: &mut FuturesRegistry,
    market: &mut FuturesMarket<T>,
    settlement_engine: &mut SettlementEngine,
    final_settlement_price: u64,
    price_sources: vector<String>,
    clock: &Clock,
    ctx: &mut TxContext,
): ExpirationResult

struct ExpirationResult has drop {
    positions_to_settle: u64,
    total_settlement_value: u64,
    settlement_deadline: u64,
    auto_settlement_enabled: bool,
}

// Calculate final settlement price
public fun calculate_settlement_price<T>(
    market: &FuturesMarket<T>,
    price_feeds: vector<PriceInfoObject>,
    synthetic_vault: &SyntheticVault<T>,
    settlement_window: u64,
    clock: &Clock,
): SettlementPriceCalculation

struct SettlementPriceCalculation has drop {
    settlement_price: u64,
    price_sources: vector<PriceSource>,
    confidence_level: u64,
    price_deviation: u64,
    calculation_method: String,                        // "TWAP", "VWAP", "LAST"
}

struct PriceSource has drop {
    source_name: String,
    price: u64,
    weight: u64,
    timestamp: u64,
    reliability_score: u64,
}
```

### 2. Position Management

#### Opening Futures Positions
```move
public fun open_futures_position<T>(
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    user_account: &mut UserAccount,
    side: String,                                      // "LONG" or "SHORT"
    size: u64,                                         // Number of contracts
    price_limit: Option<u64>,                          // Limit price
    margin_coin: Coin<USDC>,                          // Margin to post
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (FuturesPosition, PositionResult)

struct PositionResult has drop {
    position_id: ID,
    entry_price: u64,
    margin_required: u64,
    contract_value: u64,
    days_to_expiry: u64,
    trading_fee: u64,
    estimated_carry_cost: i64,
}

// Open position with auto-roll feature
public fun open_position_with_auto_roll<T>(
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    user_account: &mut UserAccount,
    position_params: PositionParams,
    auto_roll_config: AutoRollConfig,
    margin_coin: Coin<USDC>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (FuturesPosition, PositionResult)

struct AutoRollConfig has drop {
    roll_days_before_expiry: u64,                     // Auto-roll X days before expiry
    max_roll_cost: u64,                               // Maximum cost to pay for rolling
    roll_to_contract: Option<String>,                 // Specific contract to roll to
    auto_roll_enabled: bool,
}
```

#### Position Rolling
```move
public fun roll_position<T, U>(
    old_market: &mut FuturesMarket<T>,
    new_market: &mut FuturesMarket<U>,
    registry: &FuturesRegistry,
    position: FuturesPosition,                        // Take ownership
    user_account: &mut UserAccount,
    roll_strategy: RollStrategy,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (FuturesPosition, RollResult)

struct RollStrategy has drop {
    roll_type: String,                                // "SAME_SIZE", "MAINTAIN_VALUE", "CUSTOM"
    new_position_size: Option<u64>,                   // For custom size
    max_slippage: u64,                                // Maximum slippage tolerance
    execute_at_market: bool,                          // Market vs limit order
}

struct RollResult has drop {
    old_position_id: ID,
    new_position_id: ID,
    roll_price: u64,
    roll_cost: i64,                                   // Positive = cost, negative = credit
    new_margin_requirement: u64,
    margin_adjustment: Coin<USDC>,
}

// Automatic rolling execution
public fun execute_auto_roll<T, U>(
    old_market: &mut FuturesMarket<T>,
    new_market: &mut FuturesMarket<U>,
    registry: &FuturesRegistry,
    position: &mut FuturesPosition,
    auto_roll_config: &AutoRollConfig,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): AutoRollResult

struct AutoRollResult has drop {
    roll_executed: bool,
    roll_reason: String,                              // "SCHEDULE", "EARLY_EXERCISE", "RISK_LIMIT"
    new_position_id: Option<ID>,
    roll_cost: i64,
    next_roll_date: Option<u64>,
}
```

### 3. Calendar Spread Trading

#### Creating and Trading Spreads
```move
public fun create_calendar_spread<T, U>(
    spread_engine: &mut CalendarSpreadEngine,
    front_market: &FuturesMarket<T>,
    back_market: &FuturesMarket<U>,
    spread_config: SpreadConfig,
    _admin_cap: &AdminCap,
): CalendarSpread

struct SpreadConfig has drop {
    spread_symbol: String,
    ratio: u64,                                       // Front:back ratio (usually 1:1)
    tick_size: u64,
    margin_requirement: u64,
    position_limit: u64,
}

public fun place_spread_order<T, U>(
    spread_engine: &mut CalendarSpreadEngine,
    front_market: &mut FuturesMarket<T>,
    back_market: &mut FuturesMarket<U>,
    user_account: &mut UserAccount,
    spread_order: SpreadOrderParams,
    margin_coin: Coin<USDC>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): (SpreadOrder, SpreadOrderResult)

struct SpreadOrderParams has drop {
    spread_symbol: String,
    side: String,                                     // "BUY_SPREAD", "SELL_SPREAD"
    quantity: u64,
    spread_price: u64,                               // Price differential
    order_type: String,                              // "LIMIT", "MARKET"
    time_in_force: String,
}

struct SpreadOrderResult has drop {
    order_id: ID,
    estimated_margin: u64,
    front_month_exposure: u64,
    back_month_exposure: u64,
    risk_reduction: u64,                             // Risk reduction vs outright positions
}
```

#### Spread Execution and Settlement
```move
public fun execute_spread_order<T, U>(
    spread_engine: &mut CalendarSpreadEngine,
    front_market: &mut FuturesMarket<T>,
    back_market: &mut FuturesMarket<U>,
    buy_order: &mut SpreadOrder,
    sell_order: &mut SpreadOrder,
    execution_price: u64,
    execution_quantity: u64,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): SpreadExecution

// Automatic spread unwinding at expiration
public fun unwind_calendar_spread<T, U>(
    spread_engine: &mut CalendarSpreadEngine,
    front_market: &mut FuturesMarket<T>,
    back_market: &FuturesMarket<U>,
    spread_position: SpreadPosition,
    settlement_prices: SpreadSettlementPrices,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): SpreadUnwindResult

struct SpreadSettlementPrices has drop {
    front_month_settlement: u64,
    back_month_price: u64,                           // Current price if not expired
    spread_settlement_value: i64,
}

struct SpreadUnwindResult has drop {
    total_pnl: i64,
    front_month_settlement: u64,
    back_month_action: String,                       // "MAINTAIN", "CLOSE", "ROLL"
    margin_released: u64,
    trading_fees: u64,
}
```

### 4. Settlement System

#### Daily Mark-to-Market Settlement
```move
public fun execute_daily_settlement<T>(
    settlement_engine: &mut SettlementEngine,
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    settlement_price: u64,
    autoswap_registry: &AutoSwapRegistry,
    fee_processor: &mut FeeProcessor,
    clock: &Clock,
    ctx: &mut TxContext,
): DailySettlementResult

struct DailySettlementResult has drop {
    positions_settled: u64,
    total_margin_calls: u64,
    total_pnl_realized: i64,
    settlement_fees_collected: u64,
    margin_calls_issued: vector<MarginCall>,
}

struct MarginCall has drop {
    position_id: ID,
    user: address,
    required_margin: u64,
    current_margin: u64,
    deficit: u64,
    deadline: u64,
}

// Process margin calls
public fun process_margin_call<T>(
    market: &mut FuturesMarket<T>,
    position: &mut FuturesPosition,
    user_account: &mut UserAccount,
    additional_margin: Coin<USDC>,
    action: String,                                   // "ADD_MARGIN", "REDUCE_POSITION", "CLOSE"
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): MarginCallResult

struct MarginCallResult has drop {
    margin_call_satisfied: bool,
    new_margin_level: u64,
    position_adjustment: Option<u64>,                 // New position size if reduced
    liquidation_triggered: bool,
}
```

#### Final Settlement
```move
public fun execute_final_settlement<T>(
    settlement_engine: &mut SettlementEngine,
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    final_settlement_price: u64,
    settlement_batch: vector<&mut FuturesPosition>,
    autoswap_registry: &AutoSwapRegistry,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): FinalSettlementResult

struct FinalSettlementResult has drop {
    positions_settled: u64,
    total_settlement_value: u64,
    settlement_success_rate: u64,
    disputes_raised: u64,
    processing_time_ms: u64,
    settlement_fees_collected: u64,
}

// Handle settlement disputes
public fun file_settlement_dispute(
    settlement_engine: &mut SettlementEngine,
    contract_symbol: String,
    disputed_price: u64,
    claimed_correct_price: u64,
    evidence: vector<String>,                         // IPFS hashes
    disputing_user: address,
    clock: &Clock,
    ctx: &mut TxContext,
): SettlementDispute

public fun resolve_settlement_dispute(
    settlement_engine: &mut SettlementEngine,
    dispute: &mut SettlementDispute,
    resolution: DisputeResolution,
    arbitrator: address,
    _arbitrator_cap: &ArbitratorCap,
    clock: &Clock,
    ctx: &mut TxContext,
): DisputeResolutionResult

struct DisputeResolution has drop {
    final_settlement_price: u64,
    compensation_required: bool,
    compensation_amount: u64,
    resolution_rationale: String,
}
```

### 5. Term Structure and Analytics

#### Term Structure Calculation
```move
public fun calculate_term_structure(
    registry: &FuturesRegistry,
    underlying_asset: String,
    active_contracts: vector<&FuturesContract>,
    price_feeds: vector<PriceInfoObject>,
    interest_rate: u64,
    dividend_yield: u64,
    clock: &Clock,
): TermStructureAnalysis

struct TermStructureAnalysis has drop {
    curve_shape: String,                              // "CONTANGO", "BACKWARDATION", "FLAT"
    slope: i64,                                       // Curve slope
    curvature: i64,                                   // Second derivative
    implied_volatilities: vector<u64>,               // Implied vol per expiry
    fair_value_deviations: vector<i64>,              // Actual vs theoretical price
    arbitrage_opportunities: vector<ArbitrageOpportunity>,
}

// Identify arbitrage opportunities
public fun detect_arbitrage_opportunities(
    registry: &FuturesRegistry,
    term_structure: &TermStructure,
    spot_price: u64,
    interest_rate: u64,
    storage_cost: u64,
    convenience_yield: u64,
): vector<ArbitrageOpportunity>

// Calculate implied volatility from futures prices
public fun calculate_implied_volatility(
    futures_price: u64,
    spot_price: u64,
    time_to_expiry: u64,
    interest_rate: u64,
    dividend_yield: u64,
): ImpliedVolatilityResult

struct ImpliedVolatilityResult has drop {
    implied_volatility: u64,
    confidence_interval: u64,
    calculation_method: String,
    convergence_iterations: u64,
}
```

#### Risk Analytics
```move
public fun calculate_portfolio_risk(
    user_account: &UserAccount,
    futures_positions: vector<&FuturesPosition>,
    correlations: Table<String, Table<String, u64>>,
    volatilities: Table<String, u64>,
    time_horizon: u64,
): FuturesPortfolioRisk

struct FuturesPortfolioRisk has drop {
    total_exposure: u64,
    net_delta: i64,
    gamma_exposure: i64,
    theta_decay: i64,
    vega_exposure: i64,
    var_95: u64,                                     // 95% Value at Risk
    expected_shortfall: u64,                         // Conditional VaR
    maximum_drawdown: u64,
    correlation_risk: u64,
}

// Stress testing
public fun stress_test_portfolio(
    positions: vector<&FuturesPosition>,
    stress_scenarios: vector<StressScenario>,
): StressTestResult

struct StressScenario has drop {
    scenario_name: String,
    price_shocks: Table<String, i64>,               // Asset -> price shock %
    volatility_shocks: Table<String, i64>,
    correlation_shocks: Table<String, i64>,
    probability: u64,
}

struct StressTestResult has drop {
    scenario_results: vector<ScenarioResult>,
    worst_case_loss: u64,
    probability_of_loss: u64,
    recovery_time_estimate: u64,
}

struct ScenarioResult has drop {
    scenario_name: String,
    portfolio_pnl: i64,
    margin_impact: i64,
    liquidation_risk: u64,
    recommended_actions: vector<String>,
}
```

## Integration with UnXversal Ecosystem

### 1. Synthetics Integration
```move
public fun hedge_synthetic_vault<T>(
    synthetics_vault: &SyntheticVault<T>,
    futures_market: &mut FuturesMarket<T>,
    hedge_ratio: u64,                                // Percentage to hedge (0-100%)
    hedge_duration: u64,                             // Target hedge duration
    registry: &FuturesRegistry,
    balance_manager: &mut BalanceManager,
    autoswap_registry: &AutoSwapRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): VaultHedgeResult

struct VaultHedgeResult has drop {
    hedge_position_id: ID,
    hedge_effectiveness: u64,
    hedge_cost: u64,
    hedge_maintenance_schedule: vector<u64>,
    risk_reduction: u64,
}
```

### 2. Options Integration
```move
public fun create_synthetic_option<T>(
    futures_market: &FuturesMarket<T>,
    options_market: &OptionsMarket<T>,
    strategy_type: String,                           // "SYNTHETIC_CALL", "SYNTHETIC_PUT"
    strike_price: u64,
    expiration: u64,
    futures_position: &FuturesPosition,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): SyntheticOptionResult

struct SyntheticOptionResult has drop {
    synthetic_position_id: ID,
    option_equivalent_delta: i64,
    cost_efficiency: u64,                           // vs buying actual option
    risk_profile: OptionRiskProfile,
}
```

### 3. Perpetuals Integration
```move
public fun arbitrage_perp_futures<T>(
    perp_market: &PerpetualsMarket<T>,
    futures_market: &FuturesMarket<T>,
    arbitrage_threshold: u64,                       // Minimum price difference
    max_position_size: u64,
    user_account: &mut UserAccount,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    autoswap_registry: &AutoSwapRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): ArbitrageResult

struct ArbitrageResult has drop {
    arbitrage_executed: bool,
    perp_position_id: Option<ID>,
    futures_position_id: Option<ID>,
    expected_profit: u64,
    holding_period: u64,
    risk_score: u64,
}
```

### 4. Autoswap Integration
```move
public fun process_futures_fees(
    fee_processor: &mut FeeProcessor,
    autoswap_unxv: &mut AutoSwapUNXV,
    trading_fees: Table<String, u64>,              // Contract -> fees
    settlement_fees: Table<String, u64>,
    margin_call_fees: Table<String, u64>,
    futures_treasury: address,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtocolFeeResult
```

## UNXV Tokenomics Integration

### UNXV Staking Benefits for Futures Trading
```move
struct UNXVFuturesBenefits has store {
    // Tier 0 (0 UNXV): Standard rates
    tier_0: FuturesTierBenefits,
    
    // Tier 1 (1,000 UNXV): Basic futures benefits
    tier_1: FuturesTierBenefits,
    
    // Tier 2 (5,000 UNXV): Enhanced futures benefits
    tier_2: FuturesTierBenefits,
    
    // Tier 3 (25,000 UNXV): Premium futures benefits
    tier_3: FuturesTierBenefits,
    
    // Tier 4 (100,000 UNXV): VIP futures benefits
    tier_4: FuturesTierBenefits,
    
    // Tier 5 (500,000 UNXV): Institutional futures benefits
    tier_5: FuturesTierBenefits,
}

struct FuturesTierBenefits has store {
    trading_fee_discount: u64,                      // 0%, 5%, 10%, 15%, 20%, 25%
    settlement_fee_discount: u64,                   // 0%, 10%, 20%, 30%, 40%, 50%
    margin_requirement_reduction: u64,              // 0%, 5%, 8%, 12%, 18%, 25%
    position_limit_increase: u64,                   // 0%, 20%, 40%, 75%, 150%, 300%
    priority_settlement: bool,                      // false, false, true, true, true, true
    advanced_analytics: bool,                       // false, false, false, true, true, true
    custom_contract_creation: bool,                 // false, false, false, false, true, true
    institutional_block_trading: bool,              // false, false, false, false, false, true
    auto_roll_discounts: u64,                      // 0%, 25%, 50%, 75%, 90%, 100%
    calendar_spread_discounts: u64,                // 0%, 20%, 35%, 50%, 70%, 90%
}
```

## Advanced Features

### 1. Block Trading for Institutions
```move
public fun execute_block_trade<T>(
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    block_trade_params: BlockTradeParams,
    counterparties: vector<address>,
    trade_price: u64,
    _institutional_cap: &InstitutionalCap,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): BlockTradeResult

struct BlockTradeParams has drop {
    total_quantity: u64,
    allocations: Table<address, u64>,               // User -> allocation
    trade_type: String,                             // "CROSS", "AGENCY", "PRINCIPAL"
    settlement_terms: String,                       // "T+0", "T+1", "T+2"
    minimum_block_size: u64,
}

struct BlockTradeResult has drop {
    trade_id: ID,
    total_value: u64,
    participants: u64,
    average_fill_price: u64,
    fee_savings: u64,
    settlement_date: u64,
}
```

### 2. Portfolio Margining
```move
public fun calculate_portfolio_margin(
    user_account: &UserAccount,
    futures_positions: vector<&FuturesPosition>,
    options_positions: vector<&OptionPosition>,
    correlations: Table<String, Table<String, u64>>,
    volatilities: Table<String, u64>,
): PortfolioMarginResult

struct PortfolioMarginResult has drop {
    total_margin_requirement: u64,
    margin_savings: u64,                           // vs. individual margins
    concentration_penalties: u64,
    diversification_benefits: u64,
    maximum_risk_scenarios: vector<u64>,
}
```

### 3. Algorithmic Trading Support
```move
public fun register_trading_algorithm(
    registry: &FuturesRegistry,
    algorithm_params: AlgorithmParams,
    risk_limits: AlgorithmRiskLimits,
    operator: address,
    _algo_trading_cap: &AlgoTradingCap,
    ctx: &mut TxContext,
): TradingAlgorithm

struct AlgorithmParams has drop {
    algorithm_type: String,                         // "MARKET_MAKING", "ARBITRAGE", "TREND"
    target_markets: vector<String>,
    max_position_size: u64,
    max_daily_volume: u64,
    latency_requirements: u64,
}

struct AlgorithmRiskLimits has store {
    max_loss_per_day: u64,
    max_loss_per_trade: u64,
    position_concentration_limit: u64,
    correlation_limit: u64,
    volatility_limit: u64,
}
```

## Security Considerations

1. **Settlement Price Manipulation**: Multi-source price validation with deviation checks
2. **Front-Running**: Batch processing and time-priority mechanisms
3. **Oracle Attacks**: Redundant price feeds and sanity checks
4. **Margin Manipulation**: Real-time margin monitoring and automatic calls
5. **Contract Rollover Attacks**: Secure auto-roll mechanisms with user consent
6. **Calendar Spread Manipulation**: Cross-contract validation and monitoring
7. **Settlement Disputes**: Robust arbitration process with time limits

## Deployment Strategy

### Phase 1: Core Futures (Month 1-2)
- Deploy futures registry and basic contracts (sBTC-DEC24, sETH-DEC24)
- Implement position management and daily settlement
- Launch calendar spread trading
- Integrate with autoswap for fee processing

### Phase 2: Advanced Settlement (Month 3-4)
- Deploy sophisticated settlement engine with dispute resolution
- Implement auto-roll functionality
- Add term structure analytics and arbitrage detection
- Launch portfolio margining

### Phase 3: Institutional Features (Month 5-6)
- Deploy block trading and algorithmic trading support
- Implement advanced risk management and stress testing
- Add cross-protocol arbitrage strategies
- Launch institutional-grade APIs and analytics

The UnXversal Dated Futures Protocol provides institutional-grade traditional futures trading with sophisticated settlement mechanisms, calendar spreads, and comprehensive risk management, completing the core derivatives infrastructure while driving significant UNXV utility through enhanced features and fee conversions. 

---

## Required Bots and Automation

### 1. Market Creation Bots
- **Role:** Create new futures contracts at required intervals (e.g., daily, weekly).
- **Interaction:** Call on-chain market creation functions; interact with market creation registry.
- **Reward:** Receive a percentage of protocol fees for new market creation (see FEE_REVIEW.md).

### 2. Settlement Bots
- **Role:** Trigger settlement for expiring contracts and process daily mark-to-market.
- **Interaction:** Call on-chain settlement functions; interact with settlement queue.
- **Reward:** Receive a percentage of settlement fees.

### 3. Automation Bots
- **Role:** Automate risk checks, rebalancing, and protocol parameter updates (if allowed).
- **Interaction:** Monitor protocol events, submit transactions as needed.
- **Reward:** Can be incentivized via protocol fees or UNXV boosts.

---

## On-Chain Objects/Interfaces for Bots

```move
struct MarketCreationRequest has store {
    asset: String,
    expiry: u64,
    contract_type: String, // e.g., "WEEKLY", "MONTHLY"
    request_timestamp: u64,
}

struct MarketCreationRegistry has key, store {
    id: UID,
    created_markets: vector<String>,
    last_creation_timestamp: u64,
    pending_requests: vector<MarketCreationRequest>,
}

struct SettlementRequest has store {
    contract_id: ID,
    expiry_timestamp: u64,
    settlement_price: Option<u64>,
    is_settled: bool,
    request_timestamp: u64,
}

struct SettlementQueue has key, store {
    id: UID,
    pending_settlements: vector<SettlementRequest>,
}

struct BotRewardTracker has key, store {
    id: UID,
    bot_address: address,
    total_rewards_earned: u64,
    last_reward_timestamp: u64,
}
```

---

## Off-Chain Bot Interfaces (TypeScript)

```typescript
interface MarketCreationBot {
  pollMarketCreationRegistry(): Promise<MarketCreationRequest[]>;
  submitMarketCreation(request: MarketCreationRequest): Promise<TxResult>;
  claimReward(botAddress: string): Promise<RewardReceipt>;
}

interface SettlementBot {
  pollSettlementQueue(): Promise<SettlementRequest[]>;
  submitSettlement(contractId: string): Promise<TxResult>;
  claimReward(botAddress: string): Promise<RewardReceipt>;
}

interface RewardTrackerBot {
  getTotalRewards(botAddress: string): Promise<number>;
  getLastRewardTimestamp(botAddress: string): Promise<number>;
}

interface TxResult {
  success: boolean;
  txHash: string;
  error?: string;
}

interface RewardReceipt {
  amount: number;
  timestamp: number;
  txHash: string;
}
```

---

## References
- See [FEE_REVIEW.md](../FEE_REVIEW.md) and [UNXV_BOTS.md](../UNXV_BOTS.md) for details on bot rewards and incentives. 