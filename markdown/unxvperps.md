# UnXversal Perpetuals Protocol Design

> **Note:** For the latest permissioning, architecture, and on-chain/off-chain split, see [MOVING_FORWARD.md](../MOVING_FORWARD.md). This document has been updated to reflect the current policy: **market listing/creation is permissioned (admin only); only the admin can add new perpetual markets to the protocol. DeepBook itself is permissionless, but the Perpetuals registry is permissioned.**

## System Architecture & User Flow Overview

### How All Components Work Together

The UnXversal Perpetuals protocol creates a sophisticated leverage trading ecosystem that provides perpetual futures exposure with advanced risk management, funding mechanisms, and seamless cross-protocol integration:

#### **Core Object Hierarchy & Relationships**

```
PerpetualsRegistry (Shared, permissioned) ← Central configuration & supported assets (admin only)
    ↓ manages markets
PerpetualMarket<T> (Shared) → FundingRateEngine ← dynamic rate calculation
    ↓ tracks positions          ↓ maintains price convergence
PerpetualPosition (individual) ← user leverage & P&L
    ↓ validates margin
MarginManager (Service) → PriceOracle ← real-time pricing
    ↓ monitors health           ↓ provides mark prices
LiquidationEngine ← processes liquidations
    ↓ executes via
DeepBook Integration → AutoSwap ← asset conversions (DeepBook pool creation is permissionless, but Perpetuals registry listing is admin-only)
    ↓ provides liquidity       ↓ handles settlements
UNXV Integration → fee discounts & enhanced leverage
```

---

## Permissioning Policy

- **Market listing/creation in the Perpetuals registry is permissioned (admin only).**
- **DeepBook pool creation is permissionless, but only pools/markets added by the admin are recognized by the Perpetuals registry.**
- **All trading, position management, and advanced order types are permissionless for users, but only on markets listed by the admin.**
- See [MOVING_FORWARD.md](../MOVING_FORWARD.md) for the full permissioning matrix and rationale.

---

#### **Complete User Journey Flows**

**1. PERPETUAL TRADING FLOW (Opening Positions)**
```
User → select perpetual market → choose leverage & direction → 
MarginManager validates collateral → calculate required margin → 
open position → FundingRateEngine applies rates → 
real-time P&L tracking → monitor margin health → 
close position or get liquidated
```

**2. FUNDING RATE FLOW (Price Convergence)**
```
PriceOracle compares spot vs perp prices → 
FundingRateEngine calculates funding rate → 
longs pay shorts (or vice versa) → 
funding payments processed → 
price convergence maintained → 
rates updated for next period
```

**3. LIQUIDATION FLOW (Risk Management)**
```
MarginManager detects under-margined position → 
LiquidationEngine calculates liquidation size → 
DeepBook provides liquidation liquidity → 
close position at market → repay debt + penalty → 
distribute liquidation bonus → update insurance fund
```

**4. CROSS-MARGIN FLOW (Portfolio Management)**
```
User → multiple perpetual positions → 
MarginManager calculates portfolio margin → 
cross-margining reduces requirements → 
rebalance margin across positions → 
optimize capital efficiency → risk monitoring
```

#### **Key System Interactions**

- **PerpetualsRegistry**: Central command center managing all perpetual markets, leverage limits, funding parameters, and global risk settings
- **PerpetualMarket<T>**: Individual markets for each synthetic asset handling position management, funding rates, and trade execution
- **FundingRateEngine**: Sophisticated funding mechanism that maintains price convergence between perpetual and spot prices
- **MarginManager**: Advanced margin system supporting isolated and cross-margin modes with real-time health monitoring
- **LiquidationEngine**: Automated liquidation system with partial liquidations and insurance fund protection
- **PriceOracle**: Real-time price feeds ensuring accurate mark-to-market and funding rate calculation
- **DeepBook Integration**: Deep liquidity integration for optimal trade execution and liquidation processing

#### **Critical Design Patterns**

1. **Perpetual Futures Model**: Futures contracts without expiration maintained through funding rate mechanisms
2. **Dynamic Funding Rates**: Automatic rate adjustments based on price divergence between perpetual and spot markets
3. **Cross-Margin Efficiency**: Portfolio margining across all positions reduces capital requirements
4. **Partial Liquidations**: Graduated liquidation process to minimize impact and preserve positions when possible
5. **Insurance Fund Protection**: Protocol-owned insurance fund provides additional safety layer
6. **Leverage Tiers**: Variable leverage limits based on position size and market volatility

#### **Data Flow & State Management**

- **Price Discovery**: Spot prices → funding rate calculation → perpetual mark prices → position valuations
- **Margin Calculation**: Position sizes → portfolio risk → margin requirements → health factors → liquidation triggers
- **Funding Payments**: Price divergence → funding rates → payment calculations → automated transfers
- **Position Management**: Trade execution → position updates → P&L tracking → margin adjustments
- **Risk Monitoring**: Continuous health monitoring → liquidation triggers → automated responses

#### **Advanced Features & Mechanisms**

- **Up to 75x Leverage**: High leverage trading with sophisticated risk management
- **Isolated vs Cross Margin**: Users can choose between isolated positions or cross-margin portfolio
- **Advanced Order Types**: Stop-loss, take-profit, trailing stops, reduce-only orders
- **Funding Rate Optimization**: Intelligent funding rate calculation to minimize arbitrage opportunities
- **Position Size Limits**: Dynamic position limits based on market liquidity and volatility
- **Insurance Fund**: Automated insurance fund management for systemic risk protection

#### **Integration Points with UnXversal Ecosystem**

- **Synthetics**: All synthetic assets available as perpetual underlyings with native price feeds
- **Lending**: Cross-collateralization with lending positions and borrowed margin
- **DEX**: Arbitrage opportunities and cross-market trading strategies
- **AutoSwap**: Seamless collateral conversion and funding payment processing
- **Options**: Portfolio strategies combining perpetuals and options for advanced hedging
- **Liquid Staking**: stSUI collateral with enhanced margin efficiency

#### **Funding Rate & Economic Mechanisms**

- **Funding Rate Calculation**: Based on price divergence, interest rates, and market conditions
- **Funding Periods**: Regular funding payments (typically every 8 hours) to maintain price convergence
- **Long/Short Imbalance**: Funding flows from over-represented side to under-represented side
- **UNXV Benefits**: Reduced funding costs and enhanced margin efficiency for UNXV stakers
- **Fee Structure**: Competitive maker/taker fees with automatic UNXV conversion and burning

#### **Risk Management & Safety Mechanisms**

- **Real-Time Margin Monitoring**: Continuous position health monitoring with automatic liquidation triggers
- **Partial Liquidation System**: Graduated liquidation to reduce positions while preserving remaining capital
- **Insurance Fund**: Protocol-owned fund to cover potential shortfalls and maintain system solvency
- **Position Limits**: Dynamic limits based on market conditions and user risk profile
- **Circuit Breakers**: Automatic trading halts during extreme market conditions
- **Oracle Protection**: Multiple price feed validation and deviation protection

#### **Leverage & Margin System**

- **Variable Leverage**: Different leverage tiers based on position size and market volatility
- **Margin Requirements**: Dynamic initial and maintenance margin based on risk parameters
- **Cross-Margin Benefits**: Portfolio margining reduces overall capital requirements
- **Margin Calls**: Automated margin call system with grace periods and top-up options
- **Liquidation Protection**: Multiple safety mechanisms to prevent unnecessary liquidations

## Overview

UnXversal Perpetuals provides sophisticated perpetual futures trading on synthetic assets, enabling traders to gain leveraged exposure to sBTC, sETH, and other synthetic assets without expiration dates. The protocol features dynamic funding rates, advanced risk management, liquidation mechanisms, and seamless integration with the entire UnXversal ecosystem through DeepBook infrastructure.

## Core Purpose and Features

### Primary Functions
- **Perpetual Futures Trading**: Long/short positions on synthetic assets without expiration
- **Dynamic Funding Rates**: Automatic funding rate adjustments to maintain price convergence
- **Leveraged Trading**: Up to 50x leverage with sophisticated risk management
- **Cross-Margining**: Unified margin across all perpetual positions
- **Advanced Orders**: Stop-loss, take-profit, trailing stops, and conditional orders
- **Portfolio Hedging**: Hedge spot positions with perpetual futures

### Key Advantages
- **DeepBook Integration**: Deep liquidity and optimal price discovery
- **Synthetic Asset Base**: Trade futures on any synthetic asset (sBTC, sETH, sSOL, etc.)
- **Cross-Protocol Synergy**: Leverage lending, options, and autoswap infrastructure
- **UNXV Utility**: Fee discounts, priority access, and enhanced features for UNXV holders
- **Risk Management**: Advanced liquidation engine with partial liquidations and insurance fund

## Core Architecture

### On-Chain Objects

#### 1. PerpetualsRegistry (Shared Object)
```move
struct PerpetualsRegistry has key {
    id: UID,
    
    // Market management
    active_markets: VecSet<String>,              // ["sBTC-PERP", "sETH-PERP", etc.]
    market_configs: Table<String, MarketConfig>, // Market configuration data
    global_params: GlobalParameters,             // Protocol-wide parameters
    
    // Trading infrastructure
    deepbook_pools: Table<String, ID>,           // Market -> DeepBook pool ID
    price_feeds: Table<String, ID>,              // Market -> Pyth price feed ID
    synthetic_vaults: Table<String, ID>,         // Market -> synthetic vault ID
    
    // Risk management
    global_open_interest: Table<String, u64>,    // Market -> total open interest
    max_oi_limits: Table<String, u64>,           // Market -> maximum OI allowed
    funding_rate_caps: Table<String, u64>,       // Market -> max funding rate
    
    // Fee structure
    trading_fees: TradingFeeStructure,           // Base trading fees
    funding_fee_rate: u64,                       // Funding fee calculation rate
    liquidation_fees: LiquidationFeeStructure,   // Liquidation penalties
    
    // UNXV tokenomics
    unxv_discounts: Table<u64, u64>,            // Tier -> discount percentage
    fee_collection: FeeCollectionConfig,         // Fee processing configuration
    
    // Emergency controls
    circuit_breakers: Table<String, CircuitBreaker>, // Market -> circuit breaker
    emergency_pause: bool,
    admin_cap: Option<AdminCap>,
}

struct MarketConfig has store {
    market_symbol: String,                       // "sBTC-PERP"
    underlying_asset: String,                    // "sBTC"
    base_asset: String,                         // "USDC" (for margin)
    
    // Trading parameters
    min_position_size: u64,                     // Minimum position size
    max_leverage: u64,                          // Maximum leverage (50x)
    maintenance_margin: u64,                    // Minimum margin ratio (2%)
    initial_margin: u64,                        // Initial margin requirement (2.5%)
    
    // Funding rate parameters
    funding_interval: u64,                      // 1 hour in milliseconds
    funding_rate_precision: u64,               // Precision for funding calculations
    max_funding_rate: u64,                     // Maximum funding rate per interval
    
    // Risk parameters
    max_position_size: u64,                     // Maximum position size in USDC
    price_impact_limit: u64,                   // Maximum price impact for orders
    liquidation_buffer: u64,                   // Buffer for liquidation calculations
    
    // Market status
    is_active: bool,
    is_reduce_only: bool,                      // Only allow position reductions
    last_funding_update: u64,                  // Last funding rate update timestamp
}

struct GlobalParameters has store {
    insurance_fund_ratio: u64,                  // 10% of liquidation fees to insurance
    max_positions_per_user: u64,               // Maximum concurrent positions
    cross_margin_enabled: bool,                 // Cross-margin vs isolated margin
    auto_deleveraging_enabled: bool,            // Automatic deleveraging system
    mark_price_method: String,                  // "INDEX_PRICE" or "FAIR_PRICE"
}

struct TradingFeeStructure has store {
    maker_fee: u64,                            // -0.025% (rebate)
    taker_fee: u64,                            // 0.075%
    unxv_discount_maker: u64,                  // Additional discount for UNXV holders
    unxv_discount_taker: u64,                  // Additional discount for UNXV holders
    high_volume_tiers: Table<u64, VolumeTier>, // Volume-based fee tiers
}

struct VolumeTier has store {
    volume_threshold: u64,                      // 30-day volume in USDC
    maker_fee_discount: u64,                    // Additional maker discount
    taker_fee_discount: u64,                    // Additional taker discount
}

struct LiquidationFeeStructure has store {
    liquidation_penalty: u64,                  // 5% penalty on liquidated position
    liquidator_reward: u64,                    // 40% of penalty to liquidator
    insurance_fund_allocation: u64,             // 10% to insurance fund
    protocol_fee: u64,                         // 50% to protocol
}

struct CircuitBreaker has store {
    max_price_move: u64,                       // Maximum price movement (10%)
    time_window: u64,                          // Time window for price movement
    trading_halt_duration: u64,               // Duration of trading halt
    is_triggered: bool,
    trigger_timestamp: u64,
}
```

#### 2. PerpetualsMarket<T> (Shared Object)
```move
struct PerpetualsMarket<phantom T> has key {
    id: UID,
    
    // Market identification
    market_symbol: String,                      // "sBTC-PERP"
    underlying_type: String,                    // Phantom type identifier
    
    // Position tracking
    long_positions: Table<address, Position>,   // User -> long position
    short_positions: Table<address, Position>,  // User -> short position
    position_count: u64,                        // Total number of positions
    
    // Market state
    mark_price: u64,                           // Current mark price
    index_price: u64,                          // Underlying index price
    funding_rate: i64,                         // Current funding rate (can be negative)
    next_funding_time: u64,                    // Next funding calculation
    
    // Open interest tracking
    total_long_oi: u64,                        // Total long open interest
    total_short_oi: u64,                       // Total short open interest
    average_long_price: u64,                   // Volume-weighted average long price
    average_short_price: u64,                  // Volume-weighted average short price
    
    // Liquidity and volume
    total_volume_24h: u64,                     // 24-hour trading volume
    price_history: vector<PricePoint>,         // Recent price history for calculations
    funding_rate_history: vector<FundingPoint>, // Historical funding rates
    
    // Risk management
    liquidation_queue: vector<LiquidationRequest>, // Pending liquidations
    insurance_fund: Balance<USDC>,             // Market-specific insurance fund
    auto_deleverage_queue: vector<DeleverageEntry>, // Auto-deleveraging queue
    
    // Integration objects
    deepbook_pool_id: ID,                      // DeepBook pool for this market
    balance_manager_id: ID,                    // Shared balance manager
    price_feed_id: ID,                         // Pyth price feed
}

struct Position has store {
    user: address,
    position_id: ID,
    
    // Position details
    side: String,                              // "LONG" or "SHORT"
    size: u64,                                 // Position size in units
    entry_price: u64,                          // Average entry price
    margin: u64,                               // Allocated margin in USDC
    leverage: u64,                             // Position leverage
    
    // Profit/Loss tracking
    unrealized_pnl: i64,                       // Current unrealized P&L
    realized_pnl: i64,                         // Cumulative realized P&L
    funding_payments: i64,                     // Cumulative funding payments
    
    // Risk metrics
    liquidation_price: u64,                   // Price at which position gets liquidated
    maintenance_margin: u64,                   // Required maintenance margin
    margin_ratio: u64,                        // Current margin ratio
    
    // Position management
    created_timestamp: u64,
    last_update_timestamp: u64,
    auto_close_enabled: bool,                  // Auto-close on funding threshold
    
    // Order management
    stop_loss_price: Option<u64>,             // Stop-loss trigger price
    take_profit_price: Option<u64>,           // Take-profit trigger price
    trailing_stop_distance: Option<u64>,      // Trailing stop distance
}

struct PricePoint has store {
    timestamp: u64,
    mark_price: u64,
    index_price: u64,
    volume: u64,
}

struct FundingPoint has store {
    timestamp: u64,
    funding_rate: i64,
    premium: i64,                              // Mark price - index price
    oi_imbalance: i64,                         // Long OI - short OI
}

struct LiquidationRequest has store {
    position_id: ID,
    user: address,
    liquidation_price: u64,
    margin_deficit: u64,
    priority_score: u64,                       // Higher score = higher priority
    request_timestamp: u64,
}

struct DeleverageEntry has store {
    user: address,
    position_id: ID,
    profit_score: u64,                         // Used for ADL ranking
    position_size: u64,
    leverage: u64,
}
```

#### 3. UserAccount (Owned Object)
```move
struct UserAccount has key, store {
    id: UID,
    owner: address,
    
    // Margin management
    total_margin: u64,                         // Total margin in USDC
    available_margin: u64,                     // Available for new positions
    used_margin: u64,                          // Currently used for positions
    cross_margin_enabled: bool,                // Cross vs isolated margin
    
    // Position tracking
    active_positions: VecSet<ID>,              // Active position IDs
    position_history: vector<HistoricalPosition>, // Closed positions
    max_concurrent_positions: u64,             // User's position limit
    
    // Profit/Loss tracking
    total_realized_pnl: i64,                   // All-time realized P&L
    total_unrealized_pnl: i64,                 // Current unrealized P&L
    total_funding_payments: i64,               // Cumulative funding payments
    total_trading_fees: u64,                   // Cumulative trading fees paid
    
    // Risk management
    portfolio_margin_ratio: u64,              // Portfolio-wide margin ratio
    risk_level: String,                        // "LOW", "MEDIUM", "HIGH", "CRITICAL"
    liquidation_alerts: vector<LiquidationAlert>, // Position liquidation warnings
    
    // Trading preferences
    default_leverage: u64,                     // Default leverage for new positions
    auto_add_margin: bool,                     // Auto-add margin on liquidation risk
    notification_preferences: NotificationConfig, // User alert preferences
    
    // UNXV integration
    unxv_staked: u64,                         // Staked UNXV amount
    unxv_tier: u64,                           // UNXV tier level (0-5)
    fee_discounts_earned: u64,                // Total fee discounts from UNXV
    
    // Performance analytics
    win_rate: u64,                            // Percentage of profitable positions
    average_hold_time: u64,                   // Average position duration
    sharpe_ratio: u64,                        // Risk-adjusted returns
    max_drawdown: u64,                        // Maximum portfolio drawdown
}

struct HistoricalPosition has store {
    position_id: ID,
    market: String,
    side: String,
    size: u64,
    entry_price: u64,
    exit_price: u64,
    realized_pnl: i64,
    trading_fees: u64,
    funding_payments: i64,
    duration: u64,
    close_reason: String,                      // "USER_CLOSE", "LIQUIDATED", "STOP_LOSS", etc.
}

struct LiquidationAlert has store {
    position_id: ID,
    market: String,
    current_margin_ratio: u64,
    required_margin_ratio: u64,
    liquidation_price: u64,
    estimated_time_to_liquidation: u64,       // Based on current funding rate
    alert_level: String,                       // "WARNING", "CRITICAL", "IMMINENT"
}

struct NotificationConfig has store {
    liquidation_alerts: bool,
    funding_rate_alerts: bool,
    pnl_alerts: bool,
    position_alerts: bool,
    market_alerts: bool,
}
```

#### 4. FundingRateCalculator (Service Object)
```move
struct FundingRateCalculator has key {
    id: UID,
    operator: address,
    
    // Calculation parameters
    base_funding_rate: i64,                    // Base funding rate
    premium_component_weight: u64,             // Weight of premium in funding calculation
    oi_imbalance_weight: u64,                  // Weight of OI imbalance
    volatility_adjustment: u64,                // Volatility-based adjustment
    
    // Market data aggregation
    price_samples: Table<String, vector<u64>>, // Market -> price samples
    oi_samples: Table<String, vector<OISample>>, // Market -> OI samples
    funding_history: Table<String, vector<FundingPoint>>, // Historical funding data
    
    // Calculation frequency
    funding_interval: u64,                     // 1 hour
    calculation_lag: u64,                      // 5 minutes before funding
    max_funding_rate: u64,                     // 0.75% per interval
    
    // Market conditions
    market_volatility: Table<String, u64>,     // Volatility index per market
    liquidity_index: Table<String, u64>,       // Liquidity measure per market
    arbitrage_opportunities: Table<String, ArbitrageData>, // Cross-market arbitrage
}

struct OISample has store {
    timestamp: u64,
    long_oi: u64,
    short_oi: u64,
    net_oi: i64,                              // long_oi - short_oi
    oi_imbalance_ratio: u64,                  // |net_oi| / total_oi
}

struct ArbitrageData has store {
    spot_price: u64,                          // Spot price from synthetics
    perp_price: u64,                          // Perpetual futures price
    basis: i64,                               // perp_price - spot_price
    arbitrage_volume: u64,                    // Volume needed to close gap
    arbitrage_profitability: u64,             // Estimated profit from arbitrage
}
```

#### 5. LiquidationEngine (Service Object)
```move
struct LiquidationEngine has key {
    id: UID,
    operator: address,
    
    // Liquidation parameters
    maintenance_margin_buffer: u64,            // Additional buffer (0.5%)
    partial_liquidation_ratio: u64,           // Liquidate 50% first
    liquidation_fee_discount: u64,            // Discount for large liquidations
    
    // Processing queues
    liquidation_queue: vector<LiquidationRequest>,
    processing_batch_size: u64,               // Max liquidations per batch
    processing_frequency: u64,                // Process every 30 seconds
    
    // Liquidator management
    registered_liquidators: VecSet<address>,   // Approved liquidators
    liquidator_performance: Table<address, LiquidatorStats>, // Performance tracking
    liquidator_rewards: Table<address, u64>,   // Pending rewards
    
    // Insurance fund management
    insurance_fund_total: u64,                // Total insurance fund
    insurance_fund_utilization: u64,          // Current utilization
    insurance_fund_threshold: u64,            // Minimum threshold
    
    // Auto-deleveraging
    adl_enabled: bool,
    adl_threshold: u64,                       // Insurance fund threshold for ADL
    adl_ranking_method: String,               // "PROFIT_RANKING" or "TIME_PRIORITY"
    
    // Risk monitoring
    systemic_risk_indicators: SystemicRisk,
    liquidation_cascades: vector<CascadeEvent>, // Historical cascade events
    market_stress_indicators: Table<String, u64>, // Per-market stress levels
}

struct LiquidatorStats has store {
    liquidations_completed: u64,
    total_volume_liquidated: u64,
    average_response_time: u64,
    success_rate: u64,
    rewards_earned: u64,
}

struct SystemicRisk has store {
    total_leverage_ratio: u64,                // System-wide leverage
    correlation_index: u64,                   // Cross-market correlation
    liquidity_stress_index: u64,              // Liquidity pressure indicator
    funding_rate_extremes: u64,               // Extreme funding rate instances
}

struct CascadeEvent has store {
    trigger_timestamp: u64,
    initial_liquidation: ID,
    cascade_size: u64,                        // Number of additional liquidations
    total_volume: u64,
    price_impact: u64,
    recovery_time: u64,
}
```

### Events

#### 1. Position Management Events
```move
// When a new position is opened
struct PositionOpened has copy, drop {
    position_id: ID,
    user: address,
    market: String,
    side: String,                              // "LONG" or "SHORT"
    size: u64,
    entry_price: u64,
    leverage: u64,
    margin_posted: u64,
    trading_fee: u64,
    timestamp: u64,
}

// When a position is modified (size change)
struct PositionModified has copy, drop {
    position_id: ID,
    user: address,
    market: String,
    old_size: u64,
    new_size: u64,
    size_change: i64,                          // Can be negative for reductions
    new_entry_price: u64,                     // Adjusted entry price
    margin_change: i64,                        // Additional margin added/removed
    trading_fee: u64,
    timestamp: u64,
}

// When a position is closed
struct PositionClosed has copy, drop {
    position_id: ID,
    user: address,
    market: String,
    side: String,
    size: u64,
    entry_price: u64,
    exit_price: u64,
    realized_pnl: i64,
    trading_fees: u64,
    funding_payments: i64,
    close_reason: String,                      // "USER_CLOSE", "LIQUIDATED", "STOP_LOSS", etc.
    duration: u64,
    timestamp: u64,
}

// When margin is added or removed
struct MarginAdjusted has copy, drop {
    position_id: ID,
    user: address,
    market: String,
    margin_change: i64,                        // Positive for add, negative for remove
    new_margin: u64,
    new_leverage: u64,
    new_liquidation_price: u64,
    timestamp: u64,
}
```

#### 2. Funding Rate Events
```move
// When funding rate is calculated and applied
struct FundingRateUpdated has copy, drop {
    market: String,
    funding_rate: i64,                         // Can be negative
    premium_component: i64,                    // Mark price - index price
    oi_imbalance_component: i64,               // OI imbalance effect
    volatility_adjustment: i64,                // Volatility-based adjustment
    total_funding_volume: u64,                 // Total volume paying funding
    funding_interval: u64,
    timestamp: u64,
}

// When funding payment is made
struct FundingPaymentMade has copy, drop {
    position_id: ID,
    user: address,
    market: String,
    funding_amount: i64,                       // Positive = received, negative = paid
    funding_rate: i64,
    position_size: u64,
    cumulative_funding: i64,                   // Total funding for this position
    timestamp: u64,
}

// When funding rate hits extreme levels
struct FundingRateAlert has copy, drop {
    market: String,
    funding_rate: i64,
    threshold_breached: String,                // "HIGH_POSITIVE", "HIGH_NEGATIVE"
    market_imbalance: i64,                     // Long OI - short OI
    recommended_action: String,                // Trading recommendation
    timestamp: u64,
}
```

#### 3. Liquidation Events
```move
// When a position is flagged for liquidation
struct LiquidationTriggered has copy, drop {
    position_id: ID,
    user: address,
    market: String,
    current_margin_ratio: u64,
    required_margin_ratio: u64,
    liquidation_price: u64,
    current_price: u64,
    position_size: u64,
    estimated_liquidation_fee: u64,
    timestamp: u64,
}

// When liquidation is executed
struct LiquidationExecuted has copy, drop {
    position_id: ID,
    user: address,
    liquidator: address,
    market: String,
    liquidated_size: u64,                      // Partial or full liquidation
    liquidation_price: u64,
    liquidation_fee: u64,
    liquidator_reward: u64,
    insurance_fund_contribution: u64,
    remaining_position_size: u64,
    is_partial: bool,
    timestamp: u64,
}

// When auto-deleveraging is triggered
struct AutoDeleveragingExecuted has copy, drop {
    market: String,
    total_positions_deleveraged: u64,
    total_volume_deleveraged: u64,
    adl_price: u64,
    insurance_fund_deficit: u64,
    affected_users: vector<address>,
    timestamp: u64,
}
```

#### 4. Risk Management Events
```move
// When circuit breaker is triggered
struct CircuitBreakerTriggered has copy, drop {
    market: String,
    trigger_reason: String,                    // "PRICE_MOVEMENT", "VOLATILITY", "VOLUME"
    price_movement: u64,                       // Percentage price movement
    trading_halt_duration: u64,               // Duration of halt
    affected_positions: u64,                   // Number of affected positions
    timestamp: u64,
}

// When systemic risk is detected
struct SystemicRiskAlert has copy, drop {
    risk_type: String,                         // "HIGH_LEVERAGE", "CORRELATION", "LIQUIDITY"
    risk_level: u64,                          // 0-100 risk score
    affected_markets: vector<String>,
    recommended_actions: vector<String>,
    timestamp: u64,
}

// When insurance fund is utilized
struct InsuranceFundUsed has copy, drop {
    market: String,
    amount_used: u64,
    reason: String,                           // "LIQUIDATION_DEFICIT", "ADL_COMPENSATION"
    remaining_balance: u64,
    fund_utilization_ratio: u64,
    replenishment_needed: bool,
    timestamp: u64,
}
```

## Core Functions

### 1. Position Management

#### Opening Positions
```move
public fun open_position<T>(
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    user_account: &mut UserAccount,
    side: String,                              // "LONG" or "SHORT"
    size: u64,                                 // Position size
    leverage: u64,                             // Desired leverage
    margin_coin: Coin<USDC>,                   // Margin to deposit
    price_limit: Option<u64>,                  // Maximum price for limit orders
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Position, PositionResult)

struct PositionResult has drop {
    position_id: ID,
    entry_price: u64,
    margin_required: u64,
    liquidation_price: u64,
    trading_fee: u64,
    estimated_funding: i64,                    // Next funding payment estimate
}

// Open position with advanced order types
public fun open_position_advanced<T>(
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    user_account: &mut UserAccount,
    order_params: AdvancedOrderParams,
    margin_coin: Coin<USDC>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Position, PositionResult)

struct AdvancedOrderParams has drop {
    side: String,
    size: u64,
    leverage: u64,
    order_type: String,                        // "MARKET", "LIMIT", "STOP_MARKET", "STOP_LIMIT"
    trigger_price: Option<u64>,               // For stop orders
    limit_price: Option<u64>,                 // For limit orders
    time_in_force: String,                    // "GTC", "IOC", "FOK"
    reduce_only: bool,                        // Only reduce existing positions
    post_only: bool,                          // Only make liquidity
}
```

#### Modifying Positions
```move
public fun increase_position_size<T>(
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    position: &mut Position,
    user_account: &mut UserAccount,
    additional_size: u64,
    additional_margin: Coin<USDC>,
    price_limit: Option<u64>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): PositionModificationResult

public fun reduce_position_size<T>(
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    position: &mut Position,
    user_account: &mut UserAccount,
    reduction_size: u64,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (PositionModificationResult, Coin<USDC>)

struct PositionModificationResult has drop {
    new_size: u64,
    new_entry_price: u64,
    new_liquidation_price: u64,
    realized_pnl: i64,
    trading_fee: u64,
    margin_change: i64,
}

// Add or remove margin from position
public fun adjust_position_margin<T>(
    position: &mut Position,
    user_account: &mut UserAccount,
    margin_change: i64,                        // Positive to add, negative to remove
    margin_coin: Option<Coin<USDC>>,          // Required if adding margin
    clock: &Clock,
    ctx: &mut TxContext,
): (MarginAdjustmentResult, Option<Coin<USDC>>)

struct MarginAdjustmentResult has drop {
    new_margin: u64,
    new_leverage: u64,
    new_liquidation_price: u64,
    new_margin_ratio: u64,
}
```

#### Closing Positions
```move
public fun close_position<T>(
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    position: Position,                        // Take ownership to close
    user_account: &mut UserAccount,
    size_to_close: Option<u64>,               // None for full close
    price_limit: Option<u64>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (PositionCloseResult, Coin<USDC>)

struct PositionCloseResult has drop {
    closed_size: u64,
    exit_price: u64,
    realized_pnl: i64,
    trading_fee: u64,
    funding_payments: i64,
    margin_returned: u64,
    remaining_position: Option<Position>,      // If partial close
}

// Close position with stop-loss or take-profit
public fun close_position_conditional<T>(
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    position: Position,
    user_account: &mut UserAccount,
    trigger_price: u64,
    trigger_type: String,                      // "STOP_LOSS", "TAKE_PROFIT"
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): (PositionCloseResult, Coin<USDC>)
```

### 2. Funding Rate System

#### Funding Rate Calculation
```move
public fun calculate_funding_rate(
    calculator: &mut FundingRateCalculator,
    market: &PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    market_symbol: String,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): FundingRateCalculation

struct FundingRateCalculation has drop {
    funding_rate: i64,                         // Final funding rate
    premium_component: i64,                    // (mark_price - index_price) / index_price
    oi_imbalance_component: i64,              // Based on long vs short OI
    volatility_adjustment: i64,                // Market volatility adjustment
    time_decay_factor: u64,                   // Time until next funding
    confidence_level: u64,                    // Calculation confidence (0-100)
}

// Apply funding payments to all positions
public fun apply_funding_payments<T>(
    market: &mut PerpetualsMarket<T>,
    calculator: &FundingRateCalculator,
    funding_rate: i64,
    autoswap_registry: &AutoSwapRegistry,
    fee_processor: &mut FeeProcessor,
    clock: &Clock,
    ctx: &mut TxContext,
): FundingApplicationResult

struct FundingApplicationResult has drop {
    total_positions_processed: u64,
    total_funding_collected: u64,             // From position holders paying funding
    total_funding_distributed: u64,           // To position holders receiving funding
    net_funding_balance: i64,
    processing_fees: u64,
}
```

#### Dynamic Funding Rate Adjustments
```move
public fun update_funding_parameters(
    calculator: &mut FundingRateCalculator,
    market_symbol: String,
    market_conditions: MarketConditions,
    volatility_metrics: VolatilityMetrics,
    _admin_cap: &AdminCap,
): ParameterUpdateResult

struct MarketConditions has drop {
    average_spread: u64,                       // Average bid-ask spread
    volume_24h: u64,                          // 24-hour trading volume
    oi_growth_rate: u64,                      // Open interest growth rate
    arbitrage_activity: u64,                  // Cross-market arbitrage volume
}

struct VolatilityMetrics has drop {
    realized_volatility: u64,                 // Recent price volatility
    implied_volatility: u64,                  // From options markets
    volatility_trend: String,                 // "INCREASING", "DECREASING", "STABLE"
    volatility_percentile: u64,               // Historical percentile
}

struct ParameterUpdateResult has drop {
    old_max_funding_rate: u64,
    new_max_funding_rate: u64,
    old_premium_weight: u64,
    new_premium_weight: u64,
    old_oi_weight: u64,
    new_oi_weight: u64,
    update_reason: String,
}
```

### 3. Liquidation System

#### Liquidation Detection and Execution
```move
public fun check_liquidation_eligibility<T>(
    market: &PerpetualsMarket<T>,
    position: &Position,
    current_price: u64,
    margin_requirements: MarginRequirements,
): LiquidationCheck

struct MarginRequirements has drop {
    maintenance_margin_ratio: u64,
    liquidation_buffer: u64,
    funding_payment_estimate: i64,
}

struct LiquidationCheck has drop {
    is_liquidatable: bool,
    current_margin_ratio: u64,
    required_margin_ratio: u64,
    liquidation_price: u64,
    time_to_liquidation: Option<u64>,         // Based on funding trends
    severity: String,                         // "WARNING", "CRITICAL", "IMMEDIATE"
}

// Execute liquidation
public fun liquidate_position<T>(
    engine: &mut LiquidationEngine,
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    position: &mut Position,
    user_account: &mut UserAccount,
    liquidator: address,
    liquidation_size: Option<u64>,            // For partial liquidations
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): LiquidationResult

struct LiquidationResult has drop {
    liquidated_size: u64,
    liquidation_price: u64,
    liquidation_fee: u64,
    liquidator_reward: u64,
    insurance_fund_contribution: u64,
    user_remaining_margin: u64,
    position_fully_closed: bool,
}
```

#### Auto-Deleveraging System
```move
public fun execute_auto_deleveraging<T>(
    engine: &mut LiquidationEngine,
    market: &mut PerpetualsMarket<T>,
    registry: &PerpetualsRegistry,
    insurance_fund_deficit: u64,
    affected_positions: vector<&mut Position>,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): AutoDeleveragingResult

struct AutoDeleveragingResult has drop {
    total_positions_deleveraged: u64,
    total_volume_deleveraged: u64,
    average_deleverage_price: u64,
    compensation_payments: Table<address, u64>, // User -> compensation
    deficit_covered: u64,
    remaining_deficit: u64,
}

// Calculate ADL ranking for positions
public fun calculate_adl_ranking<T>(
    market: &PerpetualsMarket<T>,
    side: String,                              // Rank "LONG" or "SHORT" positions
): vector<ADLRanking>

struct ADLRanking has drop {
    position_id: ID,
    user: address,
    profit_score: u64,                        // Higher = more likely to be deleveraged
    position_size: u64,
    unrealized_pnl_percentage: u64,
    leverage: u64,
    time_in_profit: u64,
}
```

### 4. Advanced Order Types

#### Stop Orders and Conditional Orders
```move
public fun place_stop_loss_order<T>(
    market: &PerpetualsMarket<T>,
    position: &mut Position,
    trigger_price: u64,
    order_size: Option<u64>,                   // None for full position
    order_type: String,                        // "STOP_MARKET", "STOP_LIMIT"
    limit_price: Option<u64>,                  // Required for stop-limit
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalOrder

public fun place_take_profit_order<T>(
    market: &PerpetualsMarket<T>,
    position: &mut Position,
    trigger_price: u64,
    order_size: Option<u64>,
    order_type: String,
    limit_price: Option<u64>,
    clock: &Clock,
    ctx: &mut TxContext,
): ConditionalOrder

struct ConditionalOrder has key, store {
    id: UID,
    position_id: ID,
    user: address,
    market: String,
    
    // Order details
    order_type: String,                        // "STOP_LOSS", "TAKE_PROFIT", "TRAILING_STOP"
    trigger_price: u64,
    limit_price: Option<u64>,
    order_size: u64,
    
    // Execution parameters
    time_in_force: String,
    reduce_only: bool,
    trigger_condition: String,                 // "MARK_PRICE", "INDEX_PRICE", "LAST_PRICE"
    
    // Status tracking
    status: String,                           // "PENDING", "TRIGGERED", "FILLED", "CANCELLED"
    created_timestamp: u64,
    triggered_timestamp: Option<u64>,
    filled_timestamp: Option<u64>,
}
```

#### Trailing Stop Orders
```move
public fun place_trailing_stop<T>(
    market: &PerpetualsMarket<T>,
    position: &mut Position,
    trail_amount: u64,                         // Trail distance in price units
    trail_percentage: Option<u64>,             // Alternative: trail as percentage
    callback_rate: Option<u64>,               // Percentage for callback
    clock: &Clock,
    ctx: &mut TxContext,
): TrailingStopOrder

struct TrailingStopOrder has key, store {
    id: UID,
    position_id: ID,
    user: address,
    
    // Trailing parameters
    trail_amount: u64,
    trail_percentage: Option<u64>,
    callback_rate: Option<u64>,
    
    // Dynamic tracking
    highest_price: u64,                       // For long positions
    lowest_price: u64,                        // For short positions
    current_stop_price: u64,
    
    // Status
    is_active: bool,
    last_update_price: u64,
    last_update_timestamp: u64,
}

// Update trailing stop based on price movement
public fun update_trailing_stop<T>(
    market: &PerpetualsMarket<T>,
    trailing_order: &mut TrailingStopOrder,
    current_price: u64,
    position: &Position,
    clock: &Clock,
): TrailingStopUpdate

struct TrailingStopUpdate has drop {
    stop_price_updated: bool,
    new_stop_price: u64,
    trigger_distance: u64,
    should_execute: bool,
}
```

### 5. Portfolio Management

#### Cross-Margin Management
```move
public fun enable_cross_margin(
    user_account: &mut UserAccount,
    positions: vector<&mut Position>,
    margin_requirements: CrossMarginRequirements,
): CrossMarginResult

struct CrossMarginRequirements has drop {
    min_margin_ratio: u64,                    // Minimum portfolio margin ratio
    correlation_adjustments: Table<String, u64>, // Inter-market correlations
    concentration_limits: Table<String, u64>, // Position size limits per market
}

struct CrossMarginResult has drop {
    total_margin_requirement: u64,
    margin_savings: u64,                      // Compared to isolated margin
    portfolio_margin_ratio: u64,
    maximum_additional_size: Table<String, u64>, // Per market
}

// Calculate portfolio-level risk metrics
public fun calculate_portfolio_risk(
    user_account: &UserAccount,
    positions: vector<&Position>,
    market_correlations: Table<String, Table<String, u64>>,
    volatility_data: Table<String, u64>,
): PortfolioRisk

struct PortfolioRisk has drop {
    total_exposure: u64,
    net_delta: i64,                           // Portfolio delta exposure
    var_95: u64,                              // 95% Value at Risk
    var_99: u64,                              // 99% Value at Risk
    max_drawdown_estimate: u64,
    sharpe_ratio: u64,
    correlation_risk: u64,                    // Risk from correlated positions
    concentration_risk: u64,                  // Risk from position concentration
}
```

#### Portfolio Rebalancing
```move
public fun suggest_portfolio_rebalancing(
    user_account: &UserAccount,
    positions: vector<&Position>,
    market_conditions: Table<String, MarketConditions>,
    rebalancing_goals: RebalancingGoals,
): RebalancingPlan

struct RebalancingGoals has drop {
    target_leverage: u64,
    risk_tolerance: String,                   // "CONSERVATIVE", "MODERATE", "AGGRESSIVE"
    profit_taking_threshold: u64,
    loss_cutting_threshold: u64,
    diversification_target: u64,
}

struct RebalancingPlan has drop {
    positions_to_reduce: vector<PositionAdjustment>,
    positions_to_increase: vector<PositionAdjustment>,
    new_positions_suggested: vector<NewPositionSuggestion>,
    expected_risk_reduction: u64,
    expected_return_impact: i64,
    estimated_trading_costs: u64,
}

struct PositionAdjustment has drop {
    position_id: ID,
    market: String,
    current_size: u64,
    suggested_size: u64,
    adjustment_reason: String,
    priority: u64,                           // 1-10, higher = more important
}

struct NewPositionSuggestion has drop {
    market: String,
    side: String,
    suggested_size: u64,
    suggested_leverage: u64,
    rationale: String,
    expected_return: u64,
    risk_score: u64,
}
```

## Integration with UnXversal Ecosystem

### 1. Synthetics Integration
```move
public fun hedge_synthetic_position<T>(
    synthetics_registry: &SyntheticsRegistry,
    perp_market: &mut PerpetualsMarket<T>,
    synthetic_position: &SyntheticPosition,
    hedge_ratio: u64,                         // 50% = partial hedge, 100% = full hedge
    user_account: &mut UserAccount,
    margin_coin: Coin<USDC>,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): HedgeResult

struct HedgeResult has drop {
    hedge_position_id: ID,
    hedge_size: u64,
    hedge_effectiveness: u64,                 // Expected correlation
    margin_required: u64,
    estimated_funding_cost: i64,
}
```

### 2. Lending Integration
```move
public fun leverage_with_lending(
    lending_pool: &mut LendingPool<USDC>,
    perp_market: &mut PerpetualsMarket<T>,
    user_account: &mut UserAccount,
    collateral_coin: Coin<USDC>,
    borrow_amount: u64,
    leverage_target: u64,
    position_params: PositionParams,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): LeveragedPositionResult

struct LeveragedPositionResult has drop {
    position_id: ID,
    total_leverage: u64,                      // Combined leverage from margin + borrowing
    lending_position_id: ID,
    interest_rate: u64,
    liquidation_risk: String,                 // Risk level assessment
}
```

### 3. Options Integration
```move
public fun create_covered_call_strategy<T>(
    perp_market: &PerpetualsMarket<T>,
    options_market: &OptionsMarket<T>,
    position: &Position,                      // Long perpetual position
    strike_price: u64,
    expiration: u64,
    premium_target: u64,
    user_account: &mut UserAccount,
    balance_manager: &mut BalanceManager,
    clock: &Clock,
    ctx: &mut TxContext,
): CoveredCallResult

struct CoveredCallResult has drop {
    option_position_id: ID,
    premium_received: u64,
    max_profit: u64,
    breakeven_price: u64,
    strategy_delta: i64,
    strategy_theta: i64,
}
```

### 4. Autoswap Integration
```move
public fun process_perpetuals_fees(
    fee_processor: &mut FeeProcessor,
    autoswap_unxv: &mut AutoSwapUNXV,
    trading_fees: Table<String, u64>,          // Market -> fees
    funding_fees: Table<String, u64>,
    liquidation_fees: Table<String, u64>,
    perpetuals_treasury: address,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): ProtocolFeeResult
```

## UNXV Tokenomics Integration

### UNXV Staking Tiers and Benefits
```move
struct UNXVPerpetualsBenefits has store {
    // Tier 0 (0 UNXV): Standard rates
    tier_0: TierBenefits,
    
    // Tier 1 (1,000 UNXV): Basic benefits
    tier_1: TierBenefits,
    
    // Tier 2 (5,000 UNXV): Enhanced benefits
    tier_2: TierBenefits,
    
    // Tier 3 (25,000 UNXV): Premium benefits
    tier_3: TierBenefits,
    
    // Tier 4 (100,000 UNXV): VIP benefits
    tier_4: TierBenefits,
    
    // Tier 5 (500,000 UNXV): Whale benefits
    tier_5: TierBenefits,
}

struct TierBenefits has store {
    trading_fee_discount: u64,                // 0%, 5%, 10%, 15%, 20%, 25%
    funding_fee_discount: u64,                // 0%, 2%, 5%, 8%, 12%, 15%
    max_leverage_bonus: u64,                  // +0x, +5x, +10x, +15x, +20x, +25x
    liquidation_protection: u64,             // 0%, 5%, 10%, 15%, 20%, 25% buffer
    priority_order_processing: bool,          // false, false, true, true, true, true
    advanced_analytics: bool,                 // false, false, false, true, true, true
    custom_risk_parameters: bool,             // false, false, false, false, true, true
    institutional_features: bool,             // false, false, false, false, false, true
}

// Calculate user's effective tier benefits
public fun calculate_tier_benefits(
    user_account: &UserAccount,
    unxv_staked: u64,
    trading_volume_30d: u64,
): EffectiveBenefits

struct EffectiveBenefits has drop {
    tier_level: u64,
    effective_trading_fee: u64,              // After all discounts
    effective_funding_fee: u64,
    max_leverage_available: u64,
    liquidation_buffer: u64,
    special_features: vector<String>,
}
```

### Fee Collection and UNXV Burns
```move
// All perpetuals fees flow through autoswap for UNXV conversion and burning
public fun collect_all_perpetuals_fees(
    registry: &PerpetualsRegistry,
    markets: vector<&PerpetualsMarket>,
    fee_processor: &mut FeeProcessor,
    autoswap_unxv: &mut AutoSwapUNXV,
    collection_period: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): TotalFeeCollection

struct TotalFeeCollection has drop {
    total_trading_fees: u64,
    total_funding_fees: u64,
    total_liquidation_fees: u64,
    unxv_converted: u64,
    unxv_burned: u64,
    protocol_revenue: u64,
    collection_efficiency: u64,
}
```

## Advanced Analytics and Risk Management

### 1. Real-time Risk Monitoring
```move
public fun monitor_system_risk(
    registry: &PerpetualsRegistry,
    markets: vector<&PerpetualsMarket>,
    liquidation_engine: &LiquidationEngine,
    funding_calculator: &FundingRateCalculator,
): SystemRiskAssessment

struct SystemRiskAssessment has drop {
    overall_risk_score: u64,                  // 0-100, higher = more risky
    leverage_concentration: u64,              // System-wide leverage concentration
    liquidation_cascade_risk: u64,           // Risk of liquidation cascades
    funding_rate_extremes: u64,              // Extreme funding rate instances
    cross_market_correlation: u64,           // Correlation risk across markets
    liquidity_stress_index: u64,             // Liquidity availability under stress
    insurance_fund_adequacy: u64,            // Insurance fund coverage ratio
    recommendations: vector<String>,
}
```

### 2. Performance Analytics
```move
public fun generate_trading_analytics(
    user_account: &UserAccount,
    historical_positions: vector<HistoricalPosition>,
    time_period: u64,
): TradingAnalytics

struct TradingAnalytics has drop {
    total_trades: u64,
    win_rate: u64,
    profit_factor: u64,                       // Gross profit / gross loss
    sharpe_ratio: u64,
    max_drawdown: u64,
    average_trade_duration: u64,
    best_performing_market: String,
    worst_performing_market: String,
    risk_adjusted_return: u64,
    consistency_score: u64,
}
```

## Security and Risk Considerations

1. **Oracle Manipulation**: Multi-oracle price validation with deviation checks
2. **Flash Loan Attacks**: Position opening/closing constraints and cooldowns
3. **Liquidation Manipulation**: Robust liquidation engine with slippage protection
4. **Funding Rate Manipulation**: Capped funding rates and multi-factor calculations
5. **Systemic Risk**: Insurance fund, auto-deleveraging, and circuit breakers
6. **Smart Contract Risk**: Formal verification and comprehensive auditing
7. **Economic Attacks**: Incentive alignment and game-theory analysis

## Deployment Strategy

### Phase 1: Core Infrastructure (Month 1-2)
- Deploy perpetuals registry and basic markets (sBTC-PERP, sETH-PERP)
- Implement position management and basic liquidation
- Launch funding rate system with simple calculations
- Integrate with autoswap for fee processing

### Phase 2: Advanced Features (Month 3-4)
- Add advanced order types and conditional orders
- Implement cross-margin and portfolio management
- Deploy sophisticated liquidation engine with partial liquidations
- Launch auto-deleveraging system

### Phase 3: Ecosystem Integration (Month 5-6)
- Full integration with synthetics, lending, and options
- Deploy advanced analytics and risk monitoring
- Implement institutional features and APIs
- Launch cross-chain preparation infrastructure

The UnXversal Perpetuals Protocol represents the most sophisticated derivatives product in the ecosystem, providing institutional-grade perpetual futures trading with deep DeepBook liquidity integration, comprehensive risk management, and seamless ecosystem interoperability while driving significant UNXV utility and deflationary pressure through fee conversion and burning mechanisms. 