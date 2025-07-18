# UnXversal Spot DEX Protocol Design

## System Architecture & User Flow Overview

### How All Components Work Together

The UnXversal Spot DEX operates as an intelligent aggregation layer that orchestrates complex trading operations across multiple systems, creating a seamless and sophisticated trading experience:

#### **Core Object Hierarchy & Relationships**

```
DEXRegistry (Shared) ← Central trading configuration & routing logic
    ↓ manages routing
CrossAssetRouter (Service) → RouteCalculation ← path optimization
    ↓ executes routes          ↓ analyzes paths
OrderManager (Service) ← TradeProof validation
    ↓ processes orders
DeepBook Pools (Multiple) ← individual asset pairs
    ↓ provides liquidity      ↓ executes trades
BalanceManager ← holds user funds across all pools
    ↓ validates
MEVProtection (Service) → OrderExecution ← batch processing
    ↓ shields from MEV        ↓ optimizes execution
FeeOptimizer → AutoSwap ← UNXV conversions & burns
```

#### **Complete User Journey Flows**

**1. SIMPLE TRADING FLOW (Single Asset Pair)**
```
User → submit trade order → OrderManager validates → 
check DeepBook pool liquidity → apply MEV protection → 
execute trade on DeepBook → collect fees → 
UNXV discount applied → AutoSwap fee processing → 
update user balances
```

**2. CROSS-ASSET ROUTING FLOW (Multi-Hop Trading)**
```
User → request trade (A→C) → CrossAssetRouter calculates paths → 
find optimal route (A→B→C) → validate each hop → 
execute atomic multi-hop trade → 
Path: DeepBook Pool A/B → DeepBook Pool B/C → 
aggregate slippage → collect fees from each hop → 
final settlement
```

**3. ADVANCED ORDER FLOW (Stop-Loss, TWAP, etc.)**
```
User → submit advanced order → OrderManager stores order → 
continuous monitoring → trigger condition met → 
convert to market order → execute via standard flow → 
notify user of execution → update order history
```

**4. MEV PROTECTION FLOW (Sandwich Attack Prevention)**
```
User → enable MEV protection → OrderManager batches orders → 
time delay or private mempool → execute in batches → 
prevent front-running → validate execution fairness → 
complete trades
```

#### **Key System Interactions**

- **DEXRegistry**: Central hub that maintains all supported trading pairs, cross-asset routing paths, fee structures, and system-wide trading parameters
- **CrossAssetRouter**: Intelligent routing engine that calculates optimal paths for trades between any two assets, even if no direct pool exists
- **OrderManager**: Sophisticated order lifecycle management supporting complex order types, order books, and execution strategies
- **MEVProtection**: Advanced protection mechanisms including batch processing, time delays, and private mempools to shield users from MEV attacks
- **DeepBook Integration**: Direct integration with DeepBook's order matching engine, utilizing multiple pools for cross-asset routing
- **BalanceManager**: Sui's native balance management ensuring atomic operations across multiple pool interactions
- **FeeOptimizer**: Intelligent fee payment optimization automatically selecting the most cost-effective fee payment method

#### **Critical Design Patterns**

1. **Multi-Pool Orchestration**: Coordinates trades across multiple DeepBook pools to enable any-to-any asset trading
2. **Atomic Multi-Hop**: All cross-asset trades are atomic - either the entire route succeeds or everything reverts
3. **Intelligent Route Discovery**: Pre-computed and dynamically calculated routing paths with real-time liquidity analysis
4. **MEV Protection Layers**: Multiple protection mechanisms working together to prevent various forms of MEV extraction
5. **Order Type Abstraction**: Complex order types implemented as state machines on top of DeepBook's simple order matching
6. **Fee Optimization**: Dynamic fee payment selection based on user holdings, market conditions, and cost analysis

#### **Data Flow & State Management**

- **Route Calculation**: Real-time liquidity analysis → path optimization → execution cost estimation → route selection
- **Order Management**: Order submission → validation → storage → monitoring → execution → settlement → history
- **MEV Protection**: Order analysis → risk assessment → protection application → batch processing → fair execution
- **Fee Processing**: Trade execution → fee calculation → UNXV discount application → AutoSwap processing → burning
- **Cross-Asset Execution**: Route planning → pool sequencing → atomic execution → slippage aggregation → final settlement

#### **Advanced Features & Mechanisms**

- **Slippage Protection**: Intelligent slippage calculation across multi-hop routes with user-defined tolerance levels
- **Liquidity Aggregation**: Real-time analysis of liquidity across all relevant pools for optimal execution
- **Gas Optimization**: Batch processing and transaction optimization to minimize gas costs for complex trades
- **Time-Weighted Average Price (TWAP)**: Large orders broken into smaller chunks executed over time to minimize market impact
- **Copy Trading**: Users can copy successful traders' strategies with automatic trade replication
- **Smart Order Routing**: AI-powered routing that considers fees, slippage, timing, and market conditions

#### **Integration Points with UnXversal Ecosystem**

- **Synthetics**: All synthetic assets are tradeable with automatic routing to/from USDC collateral
- **AutoSwap**: All trading fees automatically processed and UNXV burned for deflationary pressure
- **Options**: Option exercise can trigger automatic DEX trades for underlying asset delivery
- **Perpetuals**: Funding rate arbitrage and position adjustment via automated DEX trades
- **Lending**: Liquidated collateral automatically routed through DEX for debt repayment
- **Liquid Staking**: stSUI tokens seamlessly tradeable against all other assets

#### **Risk Management & Safety**

- **Circuit Breakers**: Automatic trading halts during extreme market conditions or system anomalies
- **Position Limits**: User-defined and system-wide position limits to prevent excessive exposure
- **Oracle Integration**: Real-time price validation to prevent trades at manipulated prices
- **Audit Trail**: Complete transaction history and trade attribution for compliance and analysis
- **Emergency Controls**: Multi-signature emergency controls for system protection

## Overview

UnXversal Spot DEX is an advanced trading aggregation layer built on top of DeepBook, providing sophisticated order types, cross-asset routing, MEV protection, and seamless integration with the broader UnXversal ecosystem. It serves as the foundational trading infrastructure for all other UnXversal protocols.

## DeepBook Integration Strategy

The Spot DEX acts as an intelligent trading layer on top of DeepBook:

- **Advanced Order Logic**: Implements complex order types not natively supported by DeepBook (stop-loss, TWAP, etc.)
- **Cross-Asset Routing**: Enables trading between different asset pairs via intermediary assets (e.g., sETH → USDC → sBTC using two separate DeepBook pools)
- **Batch Operations**: Combines multiple DeepBook operations into single transactions
- **Fee Optimization**: Automatically selects best fee payment method (UNXV, DEEP, or input asset)
- **Order Management**: Sophisticated order lifecycle management and execution

**Note**: Each asset pair (e.g., SUI/USDC) has exactly ONE DeepBook pool. Cross-asset routing involves sequential trades across multiple different pools, not optimization within the same pool.

## Core Architecture

### On-Chain Objects

#### 1. DEXRegistry (Shared Object)
```move
struct DEXRegistry has key {
    id: UID,
    supported_pools: Table<String, PoolInfo>,     // "ASSET1_ASSET2" -> pool info
    cross_asset_paths: Table<String, vector<String>>, // Pre-computed cross-asset paths
    order_types: VecSet<String>,                  // Supported advanced order types
    fee_structure: FeeStructure,
    global_settings: GlobalSettings,
    admin_cap: Option<AdminCap>,
}

struct PoolInfo has store {
    pool_id: ID,
    base_asset: String,
    quote_asset: String,
    deepbook_pool_id: ID,
    tick_size: u64,
    lot_size: u64,
    is_active: bool,
    total_volume_24h: u64,
}

struct FeeStructure has store {
    base_trading_fee: u64,        // 30 basis points (0.3%)
    unxv_discount: u64,           // 20% discount for UNXV payments
    routing_fee: u64,             // Additional fee for cross-asset routing
    maker_rebate: u64,            // Rebate for providing liquidity
}

struct GlobalSettings has store {
    max_hops: u8,                 // Maximum routing hops (default: 3)
    slippage_tolerance: u64,      // Default slippage protection
    order_expiry_max: u64,        // Maximum order expiry time
    mev_protection_enabled: bool,
    emergency_pause: bool,
}
```

#### 2. AdvancedOrder (Owned Object)
```move
struct AdvancedOrder has key {
    id: UID,
    owner: address,
    order_type: String,           // "STOP_LOSS", "TAKE_PROFIT", "TRAILING", "TWAP", "ICEBERG"
    status: String,               // "PENDING", "ACTIVE", "FILLED", "CANCELLED", "EXPIRED"
    
    // Basic order parameters
    base_asset: String,
    quote_asset: String,
    side: String,                 // "BUY" or "SELL"
    quantity: u64,
    filled_quantity: u64,
    
    // Advanced parameters (optional based on order type)
    trigger_price: Option<u64>,
    limit_price: Option<u64>,
    trailing_amount: Option<u64>,
    time_in_force: String,        // "GTC", "IOC", "FOK", "GTT"
    
    // Execution parameters
    created_at: u64,
    expires_at: Option<u64>,
    last_executed: u64,
    execution_count: u64,
    
    // Routing and fees
    routing_path: vector<String>,
    fee_payment_asset: String,
    estimated_fees: u64,
}
```

#### 3. TradingSession (Owned Object)
```move
struct TradingSession has key {
    id: UID,
    trader: address,
    balance_manager_id: ID,
    active_orders: VecSet<ID>,
    session_stats: SessionStats,
    risk_limits: RiskLimits,
    created_at: u64,
    last_activity: u64,
}

struct SessionStats has store {
    total_volume: u64,
    total_fees_paid: u64,
    orders_executed: u64,
    pnl_realized: i64,
    win_rate: u64,                // Percentage of profitable trades
}

struct RiskLimits has store {
    max_order_size: u64,
    max_daily_volume: u64,
    max_open_orders: u64,
    stop_loss_required: bool,
}
```

#### 4. CrossAssetRouter (Service Object)
```move
struct CrossAssetRouter has key {
    id: UID,
    operator: address,
    cached_routes: Table<String, CachedRoute>,
    last_updated: u64,
    routing_params: RoutingParams,
}

struct CachedRoute has store {
    path: vector<String>,         // ["ASSET_A", "USDC", "ASSET_B"]
    pool_ids: vector<ID>,         // Corresponding DeepBook pool IDs
    estimated_output: u64,        // Expected output amount
    total_fees: u64,              // Including all hops
    expires_at: u64,
}

struct RoutingParams has store {
    max_hops: u8,                 // Maximum routing hops (default: 3)
    preferred_intermediary: String, // Usually "USDC"
    min_liquidity_threshold: u64, // Minimum pool liquidity
    cache_duration: u64,          // Route cache validity
}
```

#### 5. MEVProtector (Service Object)
```move
struct MEVProtector has key {
    id: UID,
    operator: address,
    protection_rules: vector<ProtectionRule>,
    batch_orders: Table<u64, vector<ID>>, // Block number -> order IDs
    fair_ordering_enabled: bool,
}

struct ProtectionRule has store {
    rule_type: String,            // "SANDWICH", "FRONTRUN", "BACKRUN"
    detection_threshold: u64,
    penalty_amount: u64,
    auto_cancel: bool,
}
```

### Events

#### 1. Order Management Events
```move
// When advanced order is created
struct AdvancedOrderCreated has copy, drop {
    order_id: ID,
    owner: address,
    order_type: String,
    base_asset: String,
    quote_asset: String,
    side: String,
    quantity: u64,
    trigger_price: Option<u64>,
    routing_path: vector<String>,
    timestamp: u64,
}

// When order is executed (partial or full)
struct OrderExecuted has copy, drop {
    order_id: ID,
    execution_id: ID,
    filled_quantity: u64,
    execution_price: u64,
    remaining_quantity: u64,
    fees_paid: u64,
    fee_asset: String,
    deepbook_fills: vector<ID>,   // Underlying DeepBook fill IDs
    timestamp: u64,
}

// When order is cancelled
struct OrderCancelled has copy, drop {
    order_id: ID,
    owner: address,
    reason: String,              // "USER_CANCELLED", "EXPIRED", "RISK_LIMIT", "MEV_PROTECTION"
    filled_quantity: u64,
    timestamp: u64,
}
```

#### 2. Cross-Asset Routing Events
```move
// When cross-asset route is calculated
struct CrossAssetRouteCalculated has copy, drop {
    request_id: ID,
    input_asset: String,
    output_asset: String,
    input_amount: u64,
    routing_path: vector<String>,
    estimated_output: u64,
    total_fees: u64,
    hops_required: u8,
    calculation_time_ms: u64,
    timestamp: u64,
}

// When cross-asset trade is executed
struct CrossAssetTradeExecuted has copy, drop {
    trade_id: ID,
    trader: address,
    input_asset: String,
    output_asset: String,
    input_amount: u64,
    output_amount: u64,
    routing_path: vector<String>,
    hops_executed: u64,
    total_fees: u64,
    slippage: u64,
    timestamp: u64,
}
```

#### 3. MEV Protection Events
```move
// When MEV attack is detected and prevented
struct MEVAttackPrevented has copy, drop {
    attack_type: String,
    victim_order_id: ID,
    attacker_address: address,
    prevented_loss: u64,
    penalty_applied: u64,
    timestamp: u64,
}

// When batch ordering is used
struct BatchOrderProcessed has copy, drop {
    batch_id: ID,
    block_number: u64,
    orders_count: u64,
    total_volume: u64,
    fair_ordering_applied: bool,
    timestamp: u64,
}
```

#### 4. Fee Events
```move
// When fees are collected and processed
struct TradingFeesCollected has copy, drop {
    trader: address,
    base_fee: u64,
    unxv_discount: u64,
    routing_fee: u64,
    total_fee: u64,
    fee_asset: String,
    unxv_burned: u64,
    timestamp: u64,
}

// When maker rebates are distributed
struct MakerRebateDistributed has copy, drop {
    maker: address,
    pool_id: ID,
    rebate_amount: u64,
    rebate_asset: String,
    volume_contributed: u64,
    timestamp: u64,
}
```

## Core Functions

### 1. Advanced Order Management

#### Stop Loss Orders
```move
public fun create_stop_loss_order(
    registry: &mut DEXRegistry,
    session: &mut TradingSession,
    base_asset: String,
    quote_asset: String,
    side: String,
    quantity: u64,
    trigger_price: u64,
    limit_price: Option<u64>,
    fee_payment_asset: String,
    ctx: &mut TxContext,
): ID

public fun check_stop_loss_triggers(
    registry: &DEXRegistry,
    order_ids: vector<ID>,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): vector<ID> // Returns triggered order IDs
```

#### Take Profit Orders
```move
public fun create_take_profit_order(
    registry: &mut DEXRegistry,
    session: &mut TradingSession,
    base_asset: String,
    quote_asset: String,
    side: String,
    quantity: u64,
    trigger_price: u64,
    limit_price: Option<u64>,
    fee_payment_asset: String,
    ctx: &mut TxContext,
): ID
```

#### Trailing Stop Orders
```move
public fun create_trailing_stop_order(
    registry: &mut DEXRegistry,
    session: &mut TradingSession,
    base_asset: String,
    quote_asset: String,
    side: String,
    quantity: u64,
    trailing_amount: u64,      // In basis points or absolute value
    trailing_type: String,     // "PERCENTAGE" or "ABSOLUTE"
    fee_payment_asset: String,
    ctx: &mut TxContext,
): ID

public fun update_trailing_stop(
    order: &mut AdvancedOrder,
    current_price: u64,
    registry: &DEXRegistry,
): bool // Returns true if trigger price updated
```

#### TWAP (Time-Weighted Average Price) Orders
```move
public fun create_twap_order(
    registry: &mut DEXRegistry,
    session: &mut TradingSession,
    base_asset: String,
    quote_asset: String,
    side: String,
    total_quantity: u64,
    duration_minutes: u64,
    interval_minutes: u64,
    price_limit: Option<u64>,
    fee_payment_asset: String,
    ctx: &mut TxContext,
): ID

public fun execute_twap_slice(
    order: &mut AdvancedOrder,
    registry: &mut DEXRegistry,
    deepbook_pools: vector<Pool>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<OrderFill>
```

#### Iceberg Orders
```move
public fun create_iceberg_order(
    registry: &mut DEXRegistry,
    session: &mut TradingSession,
    base_asset: String,
    quote_asset: String,
    side: String,
    total_quantity: u64,
    visible_quantity: u64,     // Amount visible in order book
    price: u64,
    fee_payment_asset: String,
    ctx: &mut TxContext,
): ID

public fun refresh_iceberg_slice(
    order: &mut AdvancedOrder,
    registry: &mut DEXRegistry,
    deepbook_pool: &mut Pool,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &mut TxContext,
)
```

### 2. Cross-Asset Routing

#### Route Discovery
```move
// For direct trades (same pool)
public fun execute_direct_trade(
    registry: &DEXRegistry,
    base_asset: String,
    quote_asset: String,
    side: String,
    amount: u64,
    deepbook_pool: &mut Pool,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): OrderInfo

// For cross-asset trades (multiple pools)
public fun calculate_cross_asset_route(
    registry: &DEXRegistry,
    router: &CrossAssetRouter,
    input_asset: String,
    output_asset: String,
    input_amount: u64,
): CrossAssetRoute

struct CrossAssetRoute has drop {
    path: vector<String>,          // ["sETH", "USDC", "sBTC"]
    pool_ids: vector<ID>,          // Corresponding DeepBook pool IDs
    estimated_output: u64,
    total_fees: u64,
    hops_required: u8,
}
```

#### Multi-Hop Execution
```move
public fun execute_cross_asset_trade(
    registry: &mut DEXRegistry,
    route: CrossAssetRoute,
    input_coin: Coin,
    min_output: u64,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    deepbook_pools: vector<Pool>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin, TradeResult)

struct TradeResult has drop {
    hops_executed: u8,
    actual_output: u64,
    total_fees_paid: u64,
    slippage: u64,
    execution_time_ms: u64,
}
```

#### Arbitrage Detection
```move
public fun detect_cross_asset_arbitrage(
    registry: &DEXRegistry,
    router: &CrossAssetRouter,
    base_assets: vector<String>,  // Assets to check for triangular arbitrage
    min_profit_threshold: u64,
    clock: &Clock,
): vector<ArbitrageOpportunity>

struct ArbitrageOpportunity has drop {
    path: vector<String>,         // ["USDC", "sETH", "sBTC", "USDC"]
    pool_ids: vector<ID>,
    profit_amount: u64,
    profit_percentage: u64,
    required_capital: u64,
    time_sensitivity: u64,
}

public fun execute_arbitrage_flash_loan(
    opportunity: ArbitrageOpportunity,
    registry: &mut DEXRegistry,
    deepbook_pools: vector<Pool>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
): FlashLoan // Hot potato for atomic arbitrage
```

### 3. MEV Protection

#### Fair Ordering
```move
public fun submit_order_to_batch(
    protector: &mut MEVProtector,
    order: AdvancedOrder,
    priority_fee: u64,
    ctx: &mut TxContext,
): BatchTicket

public fun process_batch_orders(
    protector: &mut MEVProtector,
    registry: &mut DEXRegistry,
    block_number: u64,
    deepbook_pools: vector<Pool>,
    ctx: &mut TxContext,
): vector<OrderResult>
```

#### Sandwich Attack Prevention
```move
public fun detect_sandwich_attack(
    protector: &MEVProtector,
    pending_order: &AdvancedOrder,
    recent_orders: vector<AdvancedOrder>,
    price_history: vector<u64>,
): bool

public fun apply_mev_protection(
    order: &mut AdvancedOrder,
    protection_level: String,   // "BASIC", "ENHANCED", "MAXIMUM"
    registry: &DEXRegistry,
): ProtectionResult

struct ProtectionResult has drop {
    protection_applied: bool,
    estimated_protection_cost: u64,
    max_slippage_override: Option<u64>,
    delay_execution: Option<u64>,
}
```

### 4. Fee Management and UNXV Integration

#### Fee Calculation
```move
public fun calculate_trading_fees(
    base_amount: u64,
    quote_amount: u64,
    order_type: String,
    routing_hops: u64,
    fee_payment_asset: String,
    trader_tier: String,        // "BASIC", "PREMIUM", "VIP"
    registry: &DEXRegistry,
): FeeBreakdown

struct FeeBreakdown has drop {
    base_trading_fee: u64,
    routing_fee: u64,
    order_type_fee: u64,
    total_fee_before_discount: u64,
    unxv_discount: u64,
    final_fee: u64,
    fee_asset: String,
}
```

#### UNXV Auto-Swap Integration
```move
public fun process_fee_with_autoswap(
    fee_breakdown: FeeBreakdown,
    trader: address,
    balance_manager: &mut BalanceManager,
    autoswap_contract: &mut AutoSwapContract,
    unxv_burn_contract: &mut UNXVBurnContract,
    ctx: &mut TxContext,
)

public fun distribute_maker_rebates(
    pool_id: ID,
    total_fees_collected: u64,
    maker_addresses: vector<address>,
    maker_volumes: vector<u64>,
    registry: &DEXRegistry,
    ctx: &mut TxContext,
)
```

### 5. Portfolio and Risk Management

#### Portfolio Tracking
```move
public fun get_portfolio_summary(
    session: &TradingSession,
    balance_manager: &BalanceManager,
    registry: &DEXRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): PortfolioSummary

struct PortfolioSummary has drop {
    total_value_usd: u64,
    asset_allocations: vector<AssetAllocation>,
    open_orders_value: u64,
    unrealized_pnl: i64,
    daily_pnl: i64,
    risk_metrics: RiskMetrics,
}

struct AssetAllocation has drop {
    asset: String,
    amount: u64,
    value_usd: u64,
    percentage: u64,
}

struct RiskMetrics has drop {
    portfolio_beta: u64,
    max_drawdown: u64,
    sharpe_ratio: u64,
    var_95: u64,              // Value at Risk (95% confidence)
}
```

#### Risk Monitoring
```move
public fun check_risk_limits(
    session: &TradingSession,
    new_order: &AdvancedOrder,
    registry: &DEXRegistry,
    price_feeds: vector<PriceInfoObject>,
): RiskCheckResult

struct RiskCheckResult has drop {
    passed: bool,
    violated_limits: vector<String>,
    recommended_actions: vector<String>,
    max_order_size_allowed: u64,
}

public fun auto_apply_risk_management(
    session: &mut TradingSession,
    portfolio: PortfolioSummary,
    registry: &DEXRegistry,
    ctx: &mut TxContext,
): vector<RiskAction>

struct RiskAction has drop {
    action_type: String,      // "REDUCE_POSITION", "ADD_STOP_LOSS", "CLOSE_ORDERS"
    asset: String,
    amount: u64,
    reason: String,
}
```

## Advanced Features

### 1. Smart Order Execution
```move
struct SmartExecutor has key {
    id: UID,
    operator: address,
    execution_algorithms: vector<String>, // "TWAP", "VWAP", "ICEBERG", "ADAPTIVE"
    performance_metrics: Table<String, PerformanceMetric>,
    ml_model_weights: vector<u64>,        // For AI-powered execution
}

public fun execute_smart_order(
    executor: &SmartExecutor,
    order: &AdvancedOrder,
    market_conditions: MarketConditions,
    registry: &DEXRegistry,
    deepbook_pool: &mut Pool,
): SmartExecutionResult
```

### 2. Algorithmic Trading Support
```move
struct TradingAlgorithm has key {
    id: UID,
    owner: address,
    algorithm_type: String,     // "GRID", "DCA", "MOMENTUM", "MEAN_REVERSION"
    parameters: AlgorithmParams,
    performance_stats: AlgoStats,
    is_active: bool,
}

public fun create_grid_trading_strategy(
    base_asset: String,
    quote_asset: String,
    price_range: PriceRange,
    grid_levels: u64,
    investment_amount: u64,
    session: &mut TradingSession,
    ctx: &mut TxContext,
): ID

public fun execute_dca_strategy(
    algorithm: &mut TradingAlgorithm,
    registry: &DEXRegistry,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    clock: &Clock,
    ctx: &mut TxContext,
)
```

### 3. Copy Trading System
```move
struct CopyTradingVault has key {
    id: UID,
    strategy_provider: address,
    followers: VecSet<address>,
    copy_settings: CopySettings,
    performance_fee: u64,       // Percentage taken by strategy provider
    total_aum: u64,            // Assets under management
}

struct CopySettings has store {
    copy_ratio: u64,           // Percentage of portfolio to allocate
    max_risk_per_trade: u64,
    stop_copy_drawdown: u64,   // Stop copying if drawdown exceeds this
    copy_delay: u64,           // Delay in milliseconds
}

public fun follow_strategy(
    vault: &mut CopyTradingVault,
    follower: address,
    allocation_amount: u64,
    copy_settings: CopySettings,
    balance_manager: &mut BalanceManager,
    ctx: &mut TxContext,
)
```

## DeepBook Integration Details

### 1. Pool Management
```move
public fun sync_deepbook_pools(
    registry: &mut DEXRegistry,
    deepbook_registry: &Registry,
    clock: &Clock,
) {
    // Sync pool information from DeepBook
    // Update volume metrics and pool status
    // Refresh cross-asset routing paths
}

public fun create_liquidity_incentive_pool(
    registry: &mut DEXRegistry,
    base_asset: String,
    quote_asset: String,
    incentive_amount: u64,
    duration_days: u64,
    deepbook_registry: &mut Registry,
    ctx: &mut TxContext,
): ID
```

### 2. Advanced DeepBook Operations
```move
public fun batch_deepbook_operations(
    operations: vector<DeepBookOperation>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    deepbook_pools: vector<Pool>,
    ctx: &mut TxContext,
): vector<OperationResult>

struct DeepBookOperation has drop {
    operation_type: String,    // "PLACE_ORDER", "CANCEL_ORDER", "MODIFY_ORDER"
    pool_id: ID,
    parameters: vector<u64>,
    order_id: Option<u128>,
}

public fun implement_flash_arbitrage_strategy(
    arbitrage_opportunities: vector<ArbitrageOpportunity>,
    registry: &DEXRegistry,
    deepbook_pools: vector<Pool>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &mut TxContext,
): ArbitrageResult
```

## Indexer Integration

### Events to Index
1. **AdvancedOrderCreated/Executed/Cancelled** - Order lifecycle tracking
2. **CrossAssetTradeExecuted** - Multi-hop trade analysis
3. **CrossAssetRouteCalculated** - Cross-asset routing metrics
4. **MEVAttackPrevented** - Security monitoring
5. **TradingFeesCollected** - Revenue analytics
6. **ArbitrageOpportunity** - Triangular arbitrage opportunities

### Custom API Endpoints
```typescript
// Advanced order management
/api/v1/dex/orders/advanced              // List advanced orders
/api/v1/dex/orders/{id}/status          // Order status and fills
/api/v1/dex/orders/types                // Supported order types

// Cross-asset routing and pricing
/api/v1/dex/routes/cross-asset          // Calculate cross-asset routes
/api/v1/dex/routes/direct               // Direct pair trading
/api/v1/dex/arbitrage/triangular        // Triangular arbitrage opportunities

// Portfolio and analytics
/api/v1/dex/portfolio/{address}         // Portfolio summary
/api/v1/dex/analytics/volume            // Trading volume analytics
/api/v1/dex/analytics/fees              // Fee collection analytics

// MEV and security
/api/v1/dex/mev/protection              // MEV protection status
/api/v1/dex/security/alerts             // Security alerts and incidents

// Market data
/api/v1/dex/markets/overview            // All market pairs
/api/v1/dex/markets/{pair}/depth        // Enhanced order book depth
/api/v1/dex/markets/{pair}/trades       // Recent trades with routing info
```

## CLI/Server Components

### 1. Advanced Order Manager
```typescript
class AdvancedOrderManager {
    private suiClient: SuiClient;
    private priceFeeds: PriceFeedManager;
    
    async createStopLoss(params: StopLossParams): Promise<string>;
    async createTakeProfit(params: TakeProfitParams): Promise<string>;
    async createTrailingStop(params: TrailingStopParams): Promise<string>;
    async createTWAPOrder(params: TWAPParams): Promise<string>;
    async createIcebergOrder(params: IcebergParams): Promise<string>;
    
    async monitorOrderTriggers(): Promise<void>;
    async executeTriggeredOrders(orderIds: string[]): Promise<void>;
}
```

### 2. Cross-Asset Router Service
```typescript
class CrossAssetRouterService {
    private poolManager: PoolManager;
    private priceOracle: PriceOracle;
    
    async calculateCrossAssetRoute(
        inputAsset: string,
        outputAsset: string,
        amount: number,
    ): Promise<CrossAssetRoute>;
    
    async updateRoutingCache(): Promise<void>;
    async detectTriangularArbitrage(): Promise<ArbitrageOpportunity[]>;
    async executeArbitrage(opportunity: ArbitrageOpportunity): Promise<void>;
}
```

### 3. MEV Protection Service
```typescript
class MEVProtectionService {
    private orderMonitor: OrderMonitor;
    private batchProcessor: BatchProcessor;
    
    async detectMEVAttacks(pendingOrders: Order[]): Promise<MEVThreat[]>;
    async applyProtection(order: Order, protection: ProtectionLevel): Promise<void>;
    async processBatchOrders(blockNumber: number): Promise<void>;
    async generateFairOrderingSequence(orders: Order[]): Promise<Order[]>;
}
```

### 4. Portfolio Manager
```typescript
class PortfolioManager {
    private balanceTracker: BalanceTracker;
    private riskCalculator: RiskCalculator;
    
    async getPortfolioSummary(address: string): Promise<PortfolioSummary>;
    async calculateRiskMetrics(portfolio: Portfolio): Promise<RiskMetrics>;
    async checkRiskLimits(newOrder: Order): Promise<RiskCheckResult>;
    async applyRiskManagement(session: TradingSession): Promise<RiskAction[]>;
}
```

### 5. Strategy Execution Engine
```typescript
class StrategyExecutionEngine {
    private strategyRegistry: StrategyRegistry;
    private executionScheduler: ExecutionScheduler;
    
    async createStrategy(params: StrategyParams): Promise<string>;
    async executeStrategy(strategyId: string): Promise<void>;
    async monitorPerformance(strategyId: string): Promise<PerformanceMetrics>;
    async optimizeParameters(strategyId: string): Promise<void>;
}
```

## Frontend Integration

### 1. Advanced Trading Interface
- **Order Type Selector**: UI for all advanced order types
- **Route Visualization**: Show optimal routing paths
- **Real-time Triggers**: Monitor stop-loss/take-profit triggers
- **MEV Protection Settings**: Configure protection levels
- **Fee Optimization**: Display fee savings with UNXV

### 2. Portfolio Dashboard
- **Real-time P&L**: Live portfolio performance
- **Risk Metrics**: VaR, beta, drawdown analysis
- **Order Management**: View and manage all active orders
- **Strategy Performance**: Track algorithmic strategies
- **Copy Trading**: Follow and analyze strategy providers

### 3. Analytics and Insights
- **Market Intelligence**: Triangular arbitrage opportunities, market trends
- **Cross-Asset Analytics**: Multi-hop trading performance and savings
- **Fee Analytics**: Fee breakdowns and UNXV savings
- **Security Dashboard**: MEV protection status and alerts

## Integration with Other UnXversal Protocols

### 1. Synthetics Integration
```move
public fun trade_synthetic_assets(
    synthetic_pairs: vector<String>,
    registry: &DEXRegistry,
    synthetics_registry: &SyntheticsRegistry,
    // ... parameters
)
```

### 2. Lending Integration  
```move
public fun leveraged_trading_order(
    collateral_amount: u64,
    leverage_ratio: u64,
    lending_pool: &LendingPool,
    // ... parameters
)
```

### 3. Options Integration
```move
public fun delta_hedged_trading(
    option_position: &OptionPosition,
    hedge_ratio: u64,
    registry: &DEXRegistry,
    // ... parameters
)
```

## Security Considerations

1. **Oracle Manipulation**: Multiple price feed validation and deviation checks
2. **Flash Loan Attacks**: Atomic operation constraints and balance verification
3. **MEV Attacks**: Comprehensive detection and protection mechanisms
4. **Front-running**: Fair ordering and batch processing
5. **Smart Contract Risks**: Formal verification and extensive testing
6. **Economic Attacks**: Incentive alignment and circuit breakers
7. **Route Manipulation**: Multiple route validation and slippage protection

## Deployment Strategy

### Phase 1: Core DEX Features
- Deploy basic routing and aggregation
- Implement stop-loss and take-profit orders
- Set up MEV protection infrastructure
- Launch UNXV fee integration

### Phase 2: Advanced Features
- Add TWAP and iceberg orders
- Implement copy trading system
- Deploy algorithmic trading support
- Launch cross-asset routing

### Phase 3: Ecosystem Integration
- Integration with synthetics trading
- Leveraged trading with lending protocol
- Options and futures trading interface
- Advanced analytics and insights

## UNXV Integration Benefits

### For Traders
- **20% Fee Discount**: Immediate cost savings
- **Advanced Execution**: Professional-grade order types and cross-asset trading
- **Smart Features**: TWAP, iceberg, trailing stops, and more
- **MEV Protection**: Protection from predatory trading

### For Protocol
- **Fee Revenue**: Sustainable income from trading fees
- **UNXV Demand**: Constant buying pressure from fee discounts
- **Deflationary Pressure**: Fee burning reduces supply
- **Ecosystem Growth**: Foundation for other protocols

The UnXversal Spot DEX creates a comprehensive trading infrastructure that serves as the backbone for the entire ecosystem while providing immediate utility and value for UNXV token holders. 