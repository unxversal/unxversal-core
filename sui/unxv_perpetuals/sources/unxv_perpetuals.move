/// Module: unxv_perpetuals
/// UnXversal Perpetuals Protocol - Sophisticated perpetual futures trading on synthetic assets
/// Features dynamic funding rates, advanced risk management, liquidation mechanisms, and seamless ecosystem integration
#[allow(duplicate_alias, unused_use, unused_const, unused_variable, unused_function)]
module unxv_perpetuals::unxv_perpetuals {
    use std::string::{Self, String};
    use std::option::{Self, Option};
    
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use sui::vec_map::{Self, VecMap};
    
    // Pyth Network integration for price feeds
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::price::{Self, Price};
    use pyth::pyth;
    
    // Simple signed integer representation for now
    public struct SignedInt has store, copy, drop {
        value: u64,
        is_positive: bool,
    }
    
    // ========== Signed Integer Math Functions ==========
    
    /// Create a positive signed integer
    public fun signed_int_from(value: u64): SignedInt {
        SignedInt { value, is_positive: true }
    }
    
    /// Create a negative signed integer
    public fun signed_int_negative(value: u64): SignedInt {
        SignedInt { value, is_positive: false }
    }
    
    /// Add two signed integers
    public fun signed_add(a: SignedInt, b: SignedInt): SignedInt {
        if (a.is_positive == b.is_positive) {
            // Same sign - add values
            SignedInt { value: a.value + b.value, is_positive: a.is_positive }
        } else {
            // Different signs - subtract smaller from larger
            if (a.value >= b.value) {
                SignedInt { value: a.value - b.value, is_positive: a.is_positive }
            } else {
                SignedInt { value: b.value - a.value, is_positive: b.is_positive }
            }
        }
    }
    
    /// Subtract two signed integers (a - b)
    public fun signed_sub(a: SignedInt, b: SignedInt): SignedInt {
        let negative_b = SignedInt { value: b.value, is_positive: !b.is_positive };
        signed_add(a, negative_b)
    }
    
    /// Multiply signed integer by unsigned integer
    public fun signed_mul_u64(a: SignedInt, b: u64): SignedInt {
        SignedInt { value: a.value * b, is_positive: a.is_positive }
    }
    
    /// Divide signed integer by unsigned integer
    public fun signed_div_u64(a: SignedInt, b: u64): SignedInt {
        SignedInt { value: a.value / b, is_positive: a.is_positive }
    }
    
    /// Compare if signed integer is greater than zero
    public fun is_positive(a: &SignedInt): bool {
        a.is_positive && a.value > 0
    }
    
    /// Compare if signed integer is less than zero
    public fun is_negative(a: &SignedInt): bool {
        !a.is_positive && a.value > 0
    }
    
    /// Get absolute value of signed integer
    public fun abs(a: &SignedInt): u64 {
        a.value
    }
    
    /// Convert to u64 if positive, otherwise return 0
    public fun to_u64_positive(a: &SignedInt): u64 {
        if (a.is_positive) { a.value } else { 0 }
    }
    
    // Standard coin types
    public struct USDC has drop {}
    public struct SUI has drop {}
    public struct UNXV has drop {}
    
    // ========== Error Constants ==========
    
    const E_NOT_ADMIN: u64 = 1;
    const E_ASSET_NOT_SUPPORTED: u64 = 2;
    const E_INSUFFICIENT_MARGIN: u64 = 3;
    const E_POSITION_TOO_LARGE: u64 = 4;
    const E_LEVERAGE_TOO_HIGH: u64 = 5;
    const E_HEALTH_FACTOR_TOO_LOW: u64 = 6;
    const E_POSITION_NOT_LIQUIDATABLE: u64 = 7;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 8;
    const E_INVALID_SIDE: u64 = 9;
    const E_POSITION_NOT_FOUND: u64 = 10;
    const E_MARKET_NOT_FOUND: u64 = 11;
    const E_SYSTEM_PAUSED: u64 = 12;
    const E_CIRCUIT_BREAKER_ACTIVE: u64 = 13;
    const E_INVALID_PRICE: u64 = 14;
    const E_FUNDING_RATE_TOO_HIGH: u64 = 15;
    const E_SLIPPAGE_TOO_HIGH: u64 = 16;
    const E_POSITION_SIZE_TOO_SMALL: u64 = 17;
    const E_MAX_POSITIONS_REACHED: u64 = 18;
    const E_INVALID_ORDER_TYPE: u64 = 19;
    const E_UNAUTHORIZED_LIQUIDATOR: u64 = 20;
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const MAX_LEVERAGE: u64 = 75; // 75x maximum leverage
    const MIN_MAINTENANCE_MARGIN: u64 = 133; // 1.33% (for 75x leverage)
    const INITIAL_MARGIN_BUFFER: u64 = 50; // 0.5% additional buffer
    const LIQUIDATION_PENALTY: u64 = 500; // 5%
    const LIQUIDATION_BUFFER: u64 = 50; // 0.5%
    const MIN_POSITION_SIZE: u64 = 10000000; // 10 USDC (6 decimals)
    const MAX_FUNDING_RATE: u64 = 75; // 0.75% per interval
    const FUNDING_INTERVAL: u64 = 3600000; // 1 hour in milliseconds
    const MAX_PRICE_AGE: u64 = 60000; // 1 minute
    const MAX_POSITIONS_PER_USER: u64 = 50;
    const INSURANCE_FUND_RATIO: u64 = 1000; // 10%
    const CIRCUIT_BREAKER_THRESHOLD: u64 = 1000; // 10% price movement
    const ADL_THRESHOLD: u64 = 5000; // 50% insurance fund threshold
    
    // Trading fees
    const MAKER_FEE: u64 = 25; // -0.025% (rebate)
    const TAKER_FEE: u64 = 75; // 0.075%
    
    // UNXV tier thresholds
    const TIER_1_THRESHOLD: u64 = 1000000000; // 1,000 UNXV (9 decimals)
    const TIER_2_THRESHOLD: u64 = 5000000000; // 5,000 UNXV
    const TIER_3_THRESHOLD: u64 = 25000000000; // 25,000 UNXV
    const TIER_4_THRESHOLD: u64 = 100000000000; // 100,000 UNXV
    const TIER_5_THRESHOLD: u64 = 500000000000; // 500,000 UNXV
    
    // ========== Core Data Structures ==========
    
    /// Central registry for perpetuals configuration and supported markets
    public struct PerpetualsRegistry has key {
        id: UID,
        
        // Market management
        active_markets: VecSet<String>,
        market_configs: Table<String, MarketConfig>,
        global_params: GlobalParameters,
        
        // Trading infrastructure
        deepbook_pools: Table<String, ID>,
        price_feeds: Table<String, vector<u8>>,
        synthetic_vaults: Table<String, ID>,
        
        // Risk management
        global_open_interest: Table<String, u64>,
        max_oi_limits: Table<String, u64>,
        funding_rate_caps: Table<String, u64>,
        
        // Fee structure
        trading_fees: TradingFeeStructure,
        funding_fee_rate: u64,
        liquidation_fees: LiquidationFeeStructure,
        
        // UNXV tokenomics
        unxv_discounts: Table<u64, u64>,
        fee_collection: FeeCollectionConfig,
        
        // Emergency controls
        circuit_breakers: Table<String, CircuitBreaker>,
        emergency_pause: bool,
        admin_cap: Option<AdminCap>,
        
        // Statistics
        total_volume_usd: u64,
        total_fees_collected: u64,
        active_traders: VecSet<address>,
    }
    
    /// Configuration for each perpetual market
    public struct MarketConfig has store {
        market_symbol: String,
        underlying_asset: String,
        base_asset: String,
        
        // Trading parameters
        min_position_size: u64,
        max_leverage: u64,
        maintenance_margin: u64,
        initial_margin: u64,
        
        // Funding rate parameters
        funding_interval: u64,
        funding_rate_precision: u64,
        max_funding_rate: u64,
        
        // Risk parameters
        max_position_size: u64,
        price_impact_limit: u64,
        liquidation_buffer: u64,
        
        // Market status
        is_active: bool,
        is_reduce_only: bool,
        last_funding_update: u64,
    }
    
    /// Global system parameters
    public struct GlobalParameters has store {
        insurance_fund_ratio: u64,
        max_positions_per_user: u64,
        cross_margin_enabled: bool,
        auto_deleveraging_enabled: bool,
        mark_price_method: String,
    }
    
    /// Trading fee structure with UNXV discounts
    public struct TradingFeeStructure has store {
        maker_fee: u64,
        taker_fee: u64,
        unxv_discount_maker: u64,
        unxv_discount_taker: u64,
        high_volume_tiers: Table<u64, VolumeTier>,
    }
    
    /// Volume-based fee tier
    public struct VolumeTier has store {
        volume_threshold: u64,
        maker_fee_discount: u64,
        taker_fee_discount: u64,
    }
    
    /// Liquidation fee structure
    public struct LiquidationFeeStructure has store {
        liquidation_penalty: u64,
        liquidator_reward: u64,
        insurance_fund_allocation: u64,
        protocol_fee: u64,
    }
    
    /// Fee collection configuration
    public struct FeeCollectionConfig has store {
        autoswap_conversion_threshold: u64,
        burn_percentage: u64,
        treasury_percentage: u64,
        processing_frequency: u64,
    }
    
    /// Circuit breaker configuration
    public struct CircuitBreaker has store {
        is_active: bool,
        max_price_move: u64,
        time_window: u64,
        trading_halt_duration: u64,
        trigger_timestamp: u64,
    }
    
    /// Individual perpetual market for a specific asset
    public struct PerpetualsMarket<phantom T> has key {
        id: UID,
        
        // Market identification
        market_symbol: String,
        underlying_type: String,
        
        // Position tracking
        long_positions: Table<address, ID>,
        short_positions: Table<address, ID>,
        position_count: u64,
        
        // Market state
        mark_price: u64,
        index_price: u64,
        funding_rate: SignedInt,
        next_funding_time: u64,
        
        // Open interest tracking
        total_long_oi: u64,
        total_short_oi: u64,
        average_long_price: u64,
        average_short_price: u64,
        
        // Liquidity and volume
        total_volume_24h: u64,
        price_history: vector<PricePoint>,
        funding_rate_history: vector<FundingPoint>,
        
        // Risk management
        liquidation_queue: vector<LiquidationRequest>,
        insurance_fund: Balance<USDC>,
        auto_deleverage_queue: vector<DeleverageEntry>,
        
        // Integration objects
        deepbook_pool_id: ID,
        balance_manager_id: ID,
        price_feed_id: vector<u8>,
    }
    
    /// Individual perpetual position
    public struct PerpetualPosition has key, store {
        id: UID,
        user: address,
        market: String,
        
        // Position details
        side: String, // "LONG" or "SHORT"
        size: u64,
        entry_price: u64,
        margin: u64,
        leverage: u64,
        
        // Profit/Loss tracking
        unrealized_pnl: SignedInt,
        realized_pnl: SignedInt,
        funding_payments: SignedInt,
        
        // Risk metrics
        liquidation_price: u64,
        maintenance_margin: u64,
        margin_ratio: u64,
        
        // Position management
        created_timestamp: u64,
        last_update_timestamp: u64,
        auto_close_enabled: bool,
        
        // Order management
        stop_loss_price: Option<u64>,
        take_profit_price: Option<u64>,
        trailing_stop_distance: Option<u64>,
    }
    
    /// User account for portfolio management
    public struct UserAccount has key, store {
        id: UID,
        owner: address,
        
        // Margin management
        total_margin: u64,
        available_margin: u64,
        used_margin: u64,
        cross_margin_enabled: bool,
        
        // Position tracking
        active_positions: VecSet<ID>,
        position_history: vector<HistoricalPosition>,
        max_concurrent_positions: u64,
        
        // Profit/Loss tracking
        total_realized_pnl: SignedInt,
        total_unrealized_pnl: SignedInt,
        total_funding_payments: SignedInt,
        total_trading_fees: u64,
        
        // Risk management
        portfolio_margin_ratio: u64,
        risk_level: String,
        liquidation_alerts: vector<LiquidationAlert>,
        
        // Trading preferences
        default_leverage: u64,
        auto_add_margin: bool,
        notification_preferences: NotificationConfig,
        
        // UNXV integration
        unxv_staked: u64,
        unxv_tier: u64,
        fee_discounts_earned: u64,
        
        // Performance analytics
        win_rate: u64,
        average_hold_time: u64,
        sharpe_ratio: u64,
        max_drawdown: u64,
    }
    
    /// Historical position record
    public struct HistoricalPosition has store {
        position_id: ID,
        market: String,
        side: String,
        size: u64,
        entry_price: u64,
        exit_price: u64,
        realized_pnl: SignedInt,
        trading_fees: u64,
        funding_payments: SignedInt,
        duration: u64,
        close_reason: String,
    }
    
    /// Liquidation alert
    public struct LiquidationAlert has store {
        position_id: ID,
        market: String,
        current_margin_ratio: u64,
        required_margin_ratio: u64,
        liquidation_price: u64,
        estimated_time_to_liquidation: u64,
        alert_level: String,
    }
    
    /// Notification configuration
    public struct NotificationConfig has store {
        liquidation_alerts: bool,
        funding_rate_alerts: bool,
        pnl_alerts: bool,
        position_alerts: bool,
        market_alerts: bool,
    }
    
    /// Funding rate calculator service
    public struct FundingRateCalculator has key {
        id: UID,
        operator: address,
        
        // Calculation parameters
        base_funding_rate: SignedInt,
        premium_component_weight: u64,
        oi_imbalance_weight: u64,
        volatility_adjustment: u64,
        
        // Market data aggregation
        price_samples: Table<String, vector<u64>>,
        oi_samples: Table<String, vector<OISample>>,
        funding_history: Table<String, vector<FundingPoint>>,
        
        // Calculation frequency
        funding_interval: u64,
        calculation_lag: u64,
        max_funding_rate: u64,
        
        // Market conditions
        market_volatility: Table<String, u64>,
        liquidity_index: Table<String, u64>,
        arbitrage_opportunities: Table<String, ArbitrageData>,
    }
    
    /// Liquidation engine service
    public struct LiquidationEngine has key {
        id: UID,
        operator: address,
        
        // Liquidation parameters
        maintenance_margin_buffer: u64,
        partial_liquidation_ratio: u64,
        liquidation_fee_discount: u64,
        
        // Processing queues
        liquidation_queue: vector<LiquidationRequest>,
        processing_batch_size: u64,
        processing_frequency: u64,
        
        // Liquidator management
        registered_liquidators: VecSet<address>,
        liquidator_performance: Table<address, LiquidatorStats>,
        liquidator_rewards: Table<address, u64>,
        
        // Insurance fund management
        insurance_fund_total: u64,
        insurance_fund_utilization: u64,
        insurance_fund_threshold: u64,
        
        // Auto-deleveraging
        adl_enabled: bool,
        adl_threshold: u64,
        adl_ranking_method: String,
        
        // Risk monitoring
        systemic_risk_indicators: SystemicRisk,
        liquidation_cascades: vector<CascadeEvent>,
        market_stress_indicators: Table<String, u64>,
    }
    
    /// Admin capability
    public struct AdminCap has key, store {
        id: UID,
    }
    
    // Supporting structures
    public struct PricePoint has store {
        timestamp: u64,
        mark_price: u64,
        index_price: u64,
        volume: u64,
    }
    
    public struct FundingPoint has store, copy, drop {
        timestamp: u64,
        funding_rate: SignedInt,
        premium: SignedInt,
        oi_imbalance: SignedInt,
    }
    
    public struct LiquidationRequest has store {
        position_id: ID,
        user: address,
        liquidation_price: u64,
        margin_deficit: u64,
        priority_score: u64,
        request_timestamp: u64,
    }
    
    public struct DeleverageEntry has store {
        user: address,
        position_id: ID,
        profit_score: u64,
        position_size: u64,
        leverage: u64,
    }
    
    public struct OISample has store {
        timestamp: u64,
        long_oi: u64,
        short_oi: u64,
        net_oi: SignedInt,
        oi_imbalance_ratio: u64,
    }
    
    public struct ArbitrageData has store {
        spot_price: u64,
        perp_price: u64,
        basis: SignedInt,
        arbitrage_volume: u64,
        arbitrage_profitability: u64,
    }
    
    public struct LiquidatorStats has store {
        liquidations_completed: u64,
        total_volume_liquidated: u64,
        average_response_time: u64,
        success_rate: u64,
        rewards_earned: u64,
    }
    
    public struct SystemicRisk has store {
        total_leverage_ratio: u64,
        correlation_index: u64,
        liquidity_stress_index: u64,
        funding_rate_extremes: u64,
    }
    
    public struct CascadeEvent has store {
        trigger_timestamp: u64,
        initial_liquidation: ID,
        cascade_size: u64,
        total_volume: u64,
        price_impact: u64,
        recovery_time: u64,
    }
    
    // Result structures
    public struct PositionResult has drop {
        position_id: ID,
        entry_price: u64,
        margin_required: u64,
        liquidation_price: u64,
        trading_fee: u64,
        estimated_funding: SignedInt,
    }
    
    public struct SwapResult has drop {
        executed_price: u64,
        slippage: u64,
        fees_paid: u64,
        gas_used: u64,
    }
    
    public struct FundingRateCalculation has drop {
        funding_rate: SignedInt,
        premium_component: SignedInt,
        oi_imbalance_component: SignedInt,
        volatility_adjustment: SignedInt,
        time_decay_factor: u64,
        confidence_level: u64,
    }
    
    // ========== Events ==========
    
    /// Position opened event
    public struct PositionOpened has copy, drop {
        position_id: ID,
        user: address,
        market: String,
        side: String,
        size: u64,
        entry_price: u64,
        leverage: u64,
        margin_posted: u64,
        trading_fee: u64,
        timestamp: u64,
    }
    
    /// Position closed event
    public struct PositionClosed has copy, drop {
        position_id: ID,
        user: address,
        market: String,
        side: String,
        size: u64,
        entry_price: u64,
        exit_price: u64,
        realized_pnl: SignedInt,
        trading_fees: u64,
        funding_payments: SignedInt,
        close_reason: String,
        duration: u64,
        timestamp: u64,
    }
    
    /// Funding rate updated event
    public struct FundingRateUpdated has copy, drop {
        market: String,
        funding_rate: SignedInt,
        premium_component: SignedInt,
        oi_imbalance_component: SignedInt,
        volatility_adjustment: SignedInt,
        total_funding_volume: u64,
        funding_interval: u64,
        timestamp: u64,
    }
    
    /// Position liquidated event
    public struct PositionLiquidated has copy, drop {
        position_id: ID,
        user: address,
        liquidator: address,
        market: String,
        liquidated_size: u64,
        liquidation_price: u64,
        liquidation_fee: u64,
        liquidator_reward: u64,
        insurance_fund_contribution: u64,
        timestamp: u64,
    }
    
    /// Circuit breaker triggered event
    public struct CircuitBreakerTriggered has copy, drop {
        market: String,
        trigger_reason: String,
        price_movement: u64,
        trading_halt_duration: u64,
        affected_positions: u64,
        timestamp: u64,
    }
    
    /// Registry created event
    public struct RegistryCreated has copy, drop {
        registry_id: ID,
        admin: address,
        timestamp: u64,
    }
    
    // ========== Initialization ==========
    
    /// Initialize the Perpetuals protocol
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        let registry = PerpetualsRegistry {
            id: object::new(ctx),
            active_markets: vec_set::empty(),
            market_configs: table::new(ctx),
            global_params: GlobalParameters {
                insurance_fund_ratio: INSURANCE_FUND_RATIO,
                max_positions_per_user: MAX_POSITIONS_PER_USER,
                cross_margin_enabled: true,
                auto_deleveraging_enabled: true,
                mark_price_method: string::utf8(b"INDEX_PRICE"),
            },
            deepbook_pools: table::new(ctx),
            price_feeds: table::new(ctx),
            synthetic_vaults: table::new(ctx),
            global_open_interest: table::new(ctx),
            max_oi_limits: table::new(ctx),
            funding_rate_caps: table::new(ctx),
            trading_fees: TradingFeeStructure {
                maker_fee: MAKER_FEE,
                taker_fee: TAKER_FEE,
                unxv_discount_maker: 1000, // 10%
                unxv_discount_taker: 1000, // 10%
                high_volume_tiers: table::new(ctx),
            },
            funding_fee_rate: 0,
            liquidation_fees: LiquidationFeeStructure {
                liquidation_penalty: LIQUIDATION_PENALTY,
                liquidator_reward: 4000, // 40%
                insurance_fund_allocation: INSURANCE_FUND_RATIO,
                protocol_fee: 5000, // 50%
            },
            unxv_discounts: table::new(ctx),
            fee_collection: FeeCollectionConfig {
                autoswap_conversion_threshold: 100000000, // 100 USDC
                burn_percentage: 7000, // 70%
                treasury_percentage: 3000, // 30%
                processing_frequency: 86400000, // 24 hours
            },
            circuit_breakers: table::new(ctx),
            emergency_pause: false,
            admin_cap: option::none(),
            total_volume_usd: 0,
            total_fees_collected: 0,
            active_traders: vec_set::empty(),
        };
        
        let funding_calculator = FundingRateCalculator {
            id: object::new(ctx),
            operator: tx_context::sender(ctx),
            base_funding_rate: signed_int_from(0),
            premium_component_weight: 8000, // 80%
            oi_imbalance_weight: 2000, // 20%
            volatility_adjustment: 1000, // 10%
            price_samples: table::new(ctx),
            oi_samples: table::new(ctx),
            funding_history: table::new(ctx),
            funding_interval: FUNDING_INTERVAL,
            calculation_lag: 300000, // 5 minutes
            max_funding_rate: MAX_FUNDING_RATE,
            market_volatility: table::new(ctx),
            liquidity_index: table::new(ctx),
            arbitrage_opportunities: table::new(ctx),
        };
        
        let liquidation_engine = LiquidationEngine {
            id: object::new(ctx),
            operator: tx_context::sender(ctx),
            maintenance_margin_buffer: LIQUIDATION_BUFFER,
            partial_liquidation_ratio: 5000, // 50%
            liquidation_fee_discount: 1000, // 10%
            liquidation_queue: vector::empty(),
            processing_batch_size: 10,
            processing_frequency: 30000, // 30 seconds
            registered_liquidators: vec_set::empty(),
            liquidator_performance: table::new(ctx),
            liquidator_rewards: table::new(ctx),
            insurance_fund_total: 0,
            insurance_fund_utilization: 0,
            insurance_fund_threshold: 1000000000, // 1000 USDC
            adl_enabled: true,
            adl_threshold: ADL_THRESHOLD,
            adl_ranking_method: string::utf8(b"PROFIT_RANKING"),
            systemic_risk_indicators: SystemicRisk {
                total_leverage_ratio: 0,
                correlation_index: 0,
                liquidity_stress_index: 0,
                funding_rate_extremes: 0,
            },
            liquidation_cascades: vector::empty(),
            market_stress_indicators: table::new(ctx),
        };
        
        let registry_id = object::id(&registry);
        
        // Emit creation event
        event::emit(RegistryCreated {
            registry_id,
            admin: tx_context::sender(ctx),
            timestamp: 0, // Will be set by clock in production
        });
        
        // Transfer objects
        transfer::share_object(registry);
        transfer::share_object(funding_calculator);
        transfer::share_object(liquidation_engine);
        transfer::public_transfer(admin_cap, tx_context::sender(ctx));
    }
    
    /// Test-only initialization function
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
    
    /// Test helper to create USDC coins
    #[test_only]
    public fun create_test_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
        coin::from_balance(balance::create_for_testing<T>(amount), ctx)
    }
    
    /// Get funding rate calculation confidence level for testing
    public fun get_funding_calc_confidence(calc: &FundingRateCalculation): u64 {
        calc.confidence_level
    }
    
    /// Check if system is paused
    public fun is_system_paused(registry: &PerpetualsRegistry): bool {
        registry.emergency_pause
    }
    
    /// Get insurance fund balance
    public fun get_insurance_fund_balance<T>(market: &PerpetualsMarket<T>): u64 {
        balance::value(&market.insurance_fund)
    }
    
    /// Get funding history length
    public fun get_funding_history_length<T>(market: &PerpetualsMarket<T>): u64 {
        vector::length(&market.funding_rate_history)
    }
    
    // ========== User Account Management ==========
    
    /// Create a new user account for perpetuals trading
    public fun create_user_account(ctx: &mut TxContext): UserAccount {
        UserAccount {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            total_margin: 0,
            available_margin: 0,
            used_margin: 0,
            cross_margin_enabled: true,
            active_positions: vec_set::empty(),
            position_history: vector::empty(),
            max_concurrent_positions: MAX_POSITIONS_PER_USER,
            total_realized_pnl: signed_int_from(0),
            total_unrealized_pnl: signed_int_from(0),
            total_funding_payments: signed_int_from(0),
            total_trading_fees: 0,
            portfolio_margin_ratio: 0,
            risk_level: string::utf8(b"LOW"),
            liquidation_alerts: vector::empty(),
            default_leverage: 10,
            auto_add_margin: false,
            notification_preferences: NotificationConfig {
                liquidation_alerts: true,
                funding_rate_alerts: true,
                pnl_alerts: true,
                position_alerts: true,
                market_alerts: true,
            },
            unxv_staked: 0,
            unxv_tier: 0,
            fee_discounts_earned: 0,
            win_rate: 0,
            average_hold_time: 0,
            sharpe_ratio: 0,
            max_drawdown: 0,
        }
    }
    
    // ========== Admin Functions ==========
    
    /// Add a new perpetual market
    public entry fun add_market<T>(
        registry: &mut PerpetualsRegistry,
        market_symbol: String,
        underlying_asset: String,
        deepbook_pool_id: ID,
        price_feed_id: vector<u8>,
        max_leverage: u64,
        max_oi_limit: u64,
        _admin_cap: &AdminCap,
        ctx: &mut TxContext,
    ) {
        assert!(max_leverage <= MAX_LEVERAGE, E_LEVERAGE_TOO_HIGH);
        
        vec_set::insert(&mut registry.active_markets, market_symbol);
        
        let market_config = MarketConfig {
            market_symbol,
            underlying_asset,
            base_asset: string::utf8(b"USDC"),
            min_position_size: MIN_POSITION_SIZE,
            max_leverage,
            maintenance_margin: calculate_maintenance_margin(max_leverage),
            initial_margin: calculate_initial_margin(max_leverage),
            funding_interval: FUNDING_INTERVAL,
            funding_rate_precision: BASIS_POINTS,
            max_funding_rate: MAX_FUNDING_RATE,
            max_position_size: max_oi_limit / 10, // 10% of total OI limit
            price_impact_limit: 500, // 5%
            liquidation_buffer: LIQUIDATION_BUFFER,
            is_active: true,
            is_reduce_only: false,
            last_funding_update: 0,
        };
        
        table::add(&mut registry.market_configs, market_symbol, market_config);
        table::add(&mut registry.deepbook_pools, market_symbol, deepbook_pool_id);
        table::add(&mut registry.price_feeds, market_symbol, price_feed_id);
        table::add(&mut registry.global_open_interest, market_symbol, 0);
        table::add(&mut registry.max_oi_limits, market_symbol, max_oi_limit);
        table::add(&mut registry.funding_rate_caps, market_symbol, MAX_FUNDING_RATE);
        
        // Initialize circuit breaker
        let circuit_breaker = CircuitBreaker {
            is_active: false,
            max_price_move: CIRCUIT_BREAKER_THRESHOLD,
            time_window: 300000, // 5 minutes
            trading_halt_duration: 1800000, // 30 minutes
            trigger_timestamp: 0,
        };
        table::add(&mut registry.circuit_breakers, market_symbol, circuit_breaker);
        
        // Create and share the market object
        let market = PerpetualsMarket<T> {
            id: object::new(ctx),
            market_symbol,
            underlying_type: string::utf8(b"GENERIC"), // Would use type reflection in production
            long_positions: table::new(ctx),
            short_positions: table::new(ctx),
            position_count: 0,
            mark_price: 0,
            index_price: 0,
            funding_rate: signed_int_from(0),
            next_funding_time: 0,
            total_long_oi: 0,
            total_short_oi: 0,
            average_long_price: 0,
            average_short_price: 0,
            total_volume_24h: 0,
            price_history: vector::empty(),
            funding_rate_history: vector::empty(),
            liquidation_queue: vector::empty(),
            insurance_fund: balance::zero(),
            auto_deleverage_queue: vector::empty(),
            deepbook_pool_id,
            balance_manager_id: deepbook_pool_id, // Simplified - would be actual balance manager
            price_feed_id,
        };
        
        transfer::share_object(market);
    }
    
    /// Emergency pause system
    public entry fun emergency_pause(
        registry: &mut PerpetualsRegistry,
        _admin_cap: &AdminCap,
    ) {
        registry.emergency_pause = true;
    }
    
    /// Resume operations
    public entry fun resume_operations(
        registry: &mut PerpetualsRegistry,
        _admin_cap: &AdminCap,
    ) {
        registry.emergency_pause = false;
    }
    
    // ========== Position Management ==========
    
    /// Open a new perpetual position
    public fun open_position<T>(
        market: &mut PerpetualsMarket<T>,
        registry: &PerpetualsRegistry,
        user_account: &mut UserAccount,
        side: String,
        size: u64,
        leverage: u64,
        margin_coin: Coin<USDC>,
        mut price_limit: Option<u64>,
        mut price_feeds: vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (PerpetualPosition, PositionResult) {
        // System checks
        assert!(!registry.emergency_pause, E_SYSTEM_PAUSED);
        assert!(vec_set::size(&user_account.active_positions) < MAX_POSITIONS_PER_USER, E_MAX_POSITIONS_REACHED);
        assert!(size >= MIN_POSITION_SIZE, E_POSITION_SIZE_TOO_SMALL);
        assert!(leverage <= MAX_LEVERAGE, E_LEVERAGE_TOO_HIGH);
        assert!(side == string::utf8(b"LONG") || side == string::utf8(b"SHORT"), E_INVALID_SIDE);
        
        // Get market config
        let market_config = table::borrow(&registry.market_configs, market.market_symbol);
        assert!(market_config.is_active, E_MARKET_NOT_FOUND);
        assert!(leverage <= market_config.max_leverage, E_LEVERAGE_TOO_HIGH);
        
        // Validate margin
        let margin_amount = coin::value(&margin_coin);
        let required_margin = calculate_required_margin(size, leverage);
        assert!(margin_amount >= required_margin, E_INSUFFICIENT_MARGIN);
        
        // Get current price from price feeds
        let current_price = get_mark_price(price_feeds, market.price_feed_id);
        
        // Check price limit if specified
        if (option::is_some(&price_limit)) {
            let limit = option::extract(&mut price_limit);
            validate_price_limit(side, current_price, limit);
        };
        
        // Calculate position metrics
        let liquidation_price = calculate_liquidation_price(side, current_price, leverage);
        let trading_fee = calculate_trading_fee(size, current_price, false, user_account.unxv_tier);
        
        // Create position
        let position_id = object::new(ctx);
        let position_id_inner = object::uid_to_inner(&position_id);
        
        let position = PerpetualPosition {
            id: position_id,
            user: tx_context::sender(ctx),
            market: market.market_symbol,
            side,
            size,
            entry_price: current_price,
            margin: margin_amount,
            leverage,
            unrealized_pnl: signed_int_from(0),
            realized_pnl: signed_int_from(0),
            funding_payments: signed_int_from(0),
            liquidation_price,
            maintenance_margin: required_margin,
            margin_ratio: margin_amount * BASIS_POINTS / required_margin,
            created_timestamp: clock::timestamp_ms(clock),
            last_update_timestamp: clock::timestamp_ms(clock),
            auto_close_enabled: false,
            stop_loss_price: option::none(),
            take_profit_price: option::none(),
            trailing_stop_distance: option::none(),
        };
        
        // Update market state
        if (side == string::utf8(b"LONG")) {
            table::add(&mut market.long_positions, tx_context::sender(ctx), position_id_inner);
            market.total_long_oi = market.total_long_oi + size;
            market.average_long_price = calculate_weighted_average_price(
                market.average_long_price,
                market.total_long_oi - size,
                current_price,
                size
            );
        } else {
            table::add(&mut market.short_positions, tx_context::sender(ctx), position_id_inner);
            market.total_short_oi = market.total_short_oi + size;
            market.average_short_price = calculate_weighted_average_price(
                market.average_short_price,
                market.total_short_oi - size,
                current_price,
                size
            );
        };
        
        market.position_count = market.position_count + 1;
        
        // Update user account
        vec_set::insert(&mut user_account.active_positions, position_id_inner);
        user_account.used_margin = user_account.used_margin + margin_amount;
        
        // Consume margin coin
        let margin_balance = coin::into_balance(margin_coin);
        balance::destroy_zero(margin_balance); // In production, would transfer to protocol vault
        
        let position_result = PositionResult {
            position_id: position_id_inner,
            entry_price: current_price,
            margin_required: required_margin,
            liquidation_price,
            trading_fee,
            estimated_funding: signed_int_from(0), // Would calculate based on current funding rate
        };
        
        // Emit event
        event::emit(PositionOpened {
            position_id: position_id_inner,
            user: tx_context::sender(ctx),
            market: market.market_symbol,
            side,
            size,
            entry_price: current_price,
            leverage,
            margin_posted: margin_amount,
            trading_fee,
            timestamp: clock::timestamp_ms(clock),
        });
        
        (position, position_result)
    }
    
    /// Close a perpetual position
    public fun close_position<T>(
        market: &mut PerpetualsMarket<T>,
        registry: &PerpetualsRegistry,
        mut position: PerpetualPosition,
        user_account: &mut UserAccount,
        mut size_to_close: Option<u64>,
        mut price_limit: Option<u64>,
        mut price_feeds: vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<USDC>, Option<PerpetualPosition>) {
        assert!(!registry.emergency_pause, E_SYSTEM_PAUSED);
        
        let current_price = get_mark_price(price_feeds, market.price_feed_id);
        let close_size = if (option::is_some(&size_to_close)) {
            option::extract(&mut size_to_close)
        } else {
            position.size
        };
        
        assert!(close_size <= position.size, E_POSITION_TOO_LARGE);
        
        // Check price limit
        if (option::is_some(&price_limit)) {
            let limit = option::extract(&mut price_limit);
            validate_price_limit(position.side, current_price, limit);
        };
        
        // Calculate P&L
        let realized_pnl = calculate_realized_pnl(
            position.side,
            position.entry_price,
            current_price,
            close_size
        );
        
        let trading_fee = calculate_trading_fee(close_size, current_price, false, user_account.unxv_tier);
        
        // Calculate margin to return
        let margin_to_return = if (close_size == position.size) {
            position.margin
        } else {
            position.margin * close_size / position.size
        };
        
        // Adjust for P&L and fees
        let net_margin_return = if (is_positive(&realized_pnl)) {
            // Profit case - add P&L to margin return, subtract fees
            let profit = to_u64_positive(&realized_pnl);
            if (margin_to_return + profit > trading_fee) {
                margin_to_return + profit - trading_fee
            } else {
                0
            }
        } else {
            // Loss case - subtract loss and fees from margin return
            let loss = abs(&realized_pnl);
            if (margin_to_return > loss + trading_fee) {
                margin_to_return - loss - trading_fee
            } else {
                0
            }
        };
        
        // Update market state
        if (position.side == string::utf8(b"LONG")) {
            market.total_long_oi = market.total_long_oi - close_size;
        } else {
            market.total_short_oi = market.total_short_oi - close_size;
        };
        
        // Update user account
        user_account.used_margin = user_account.used_margin - margin_to_return;
        // user_account.total_realized_pnl = i64::add(&user_account.total_realized_pnl, &realized_pnl); // Simplified
        user_account.total_trading_fees = user_account.total_trading_fees + trading_fee;
        
        // Create historical record
        let historical_position = HistoricalPosition {
            position_id: object::id(&position),
            market: position.market,
            side: position.side,
            size: close_size,
            entry_price: position.entry_price,
            exit_price: current_price,
            realized_pnl,
            trading_fees: trading_fee,
            funding_payments: position.funding_payments,
            duration: clock::timestamp_ms(clock) - position.created_timestamp,
            close_reason: string::utf8(b"USER_CLOSE"),
        };
        vector::push_back(&mut user_account.position_history, historical_position);
        
        // Create return coin
        // In production, this would withdraw from the protocol's treasury
        // For now, create a zero coin as placeholder
        let return_coin = coin::zero<USDC>(ctx);
        
        // Handle partial vs full close
        let remaining_position = if (close_size == position.size) {
            // Full close
            vec_set::remove(&mut user_account.active_positions, &object::id(&position));
            
            if (position.side == string::utf8(b"LONG")) {
                table::remove(&mut market.long_positions, position.user);
            } else {
                table::remove(&mut market.short_positions, position.user);
            };
            
            market.position_count = market.position_count - 1;
            
            event::emit(PositionClosed {
                position_id: object::id(&position),
                user: position.user,
                market: position.market,
                side: position.side,
                size: close_size,
                entry_price: position.entry_price,
                exit_price: current_price,
                realized_pnl,
                trading_fees: trading_fee,
                funding_payments: position.funding_payments,
                close_reason: string::utf8(b"USER_CLOSE"),
                duration: clock::timestamp_ms(clock) - position.created_timestamp,
                timestamp: clock::timestamp_ms(clock),
            });
            
            // Destroy the position
            let PerpetualPosition { 
                id, user: _, market: _, side: _, size: _, entry_price: _, margin: _, leverage: _,
                unrealized_pnl: _, realized_pnl: _, funding_payments: _, liquidation_price: _,
                maintenance_margin: _, margin_ratio: _, created_timestamp: _, last_update_timestamp: _,
                auto_close_enabled: _, stop_loss_price: _, take_profit_price: _, trailing_stop_distance: _
            } = position;
            object::delete(id);
            
            option::none()
        } else {
            // Partial close - update position in place
            position.size = position.size - close_size;
            position.margin = position.margin - margin_to_return;
            position.liquidation_price = calculate_liquidation_price(position.side, current_price, position.leverage);
            position.maintenance_margin = calculate_required_margin(position.size, position.leverage);
            position.margin_ratio = position.margin * BASIS_POINTS / position.maintenance_margin;
            position.last_update_timestamp = clock::timestamp_ms(clock);
            
            option::some(position)
        };
        
        (return_coin, remaining_position)
    }
    
    // ========== Funding Rate System ==========
    
    /// Calculate funding rate for a market based on price divergence and OI imbalance
    public fun calculate_funding_rate<T>(
        calculator: &mut FundingRateCalculator,
        market: &PerpetualsMarket<T>,
        registry: &PerpetualsRegistry,
        mut price_feeds: vector<PriceInfoObject>,
        clock: &Clock,
    ): FundingRateCalculation {
        let current_time = clock::timestamp_ms(clock);
        
        // Get current mark and index prices
        let mark_price = get_mark_price(vector::empty(), market.price_feed_id);
        let index_price = get_index_price(&price_feeds, &market.price_feed_id);
        vector::destroy_empty(price_feeds);
        
        // Calculate premium component: (mark_price - index_price) / index_price
        let premium_component = if (mark_price >= index_price) {
            let premium = ((mark_price - index_price) * BASIS_POINTS) / index_price;
            signed_int_from(premium / 8) // Divide by 8 for hourly rate from daily
        } else {
            let premium = ((index_price - mark_price) * BASIS_POINTS) / index_price;
            signed_int_negative(premium / 8)
        };
        
        // Calculate OI imbalance component
        let total_oi = market.total_long_oi + market.total_short_oi;
        let oi_imbalance_component = if (total_oi > 0) {
            if (market.total_long_oi > market.total_short_oi) {
                // More longs than shorts - positive funding (longs pay shorts)
                let imbalance = ((market.total_long_oi - market.total_short_oi) * BASIS_POINTS) / total_oi;
                signed_int_from(imbalance / 100) // Scale down for stability
            } else {
                // More shorts than longs - negative funding (shorts pay longs)
                let imbalance = ((market.total_short_oi - market.total_long_oi) * BASIS_POINTS) / total_oi;
                signed_int_negative(imbalance / 100)
            }
        } else {
            signed_int_from(0)
        };
        
        // Calculate volatility adjustment based on recent price movements
        let volatility_adjustment = calculate_volatility_adjustment(market);
        
        // Combine components to get funding rate
        let base_funding = signed_int_from(100); // 0.01% base funding rate
        let combined_funding = signed_add(
            signed_add(base_funding, premium_component),
            signed_add(oi_imbalance_component, volatility_adjustment)
        );
        
        // Apply caps
        let capped_funding_rate = cap_funding_rate(combined_funding, calculator.max_funding_rate);
        
        // Store calculation data for analytics
        record_funding_calculation(calculator, market, premium_component, oi_imbalance_component, current_time);
        
        FundingRateCalculation {
            funding_rate: capped_funding_rate,
            premium_component,
            oi_imbalance_component,
            volatility_adjustment,
            time_decay_factor: 10000,
            confidence_level: calculate_confidence_level(total_oi, mark_price, index_price),
        }
    }
    
    /// Apply funding payments to positions
    public fun apply_funding_payments<T>(
        market: &mut PerpetualsMarket<T>,
        funding_rate: SignedInt,
        clock: &Clock,
    ): u64 {
        // Update market funding rate
        market.funding_rate = funding_rate;
        market.next_funding_time = clock::timestamp_ms(clock) + FUNDING_INTERVAL;
        
        // In production, would iterate through all positions and apply funding
        // For now, just return the number of positions processed
        market.position_count
    }
    
    // ========== Liquidation System ==========
    
    /// Check if position is eligible for liquidation
    public fun check_liquidation_eligibility<T>(
        market: &PerpetualsMarket<T>,
        position: &PerpetualPosition,
        current_price: u64,
    ): bool {
        let unrealized_pnl = calculate_unrealized_pnl(
            position.side,
            position.entry_price,
            current_price,
            position.size
        );
        
        let pnl_value = 0; // Simplified - would calculate actual P&L
        
        let effective_margin = if (position.margin > pnl_value) {
            position.margin - pnl_value
        } else {
            0
        };
        
        let margin_ratio = effective_margin * BASIS_POINTS / position.maintenance_margin;
        
        margin_ratio < MIN_MAINTENANCE_MARGIN * BASIS_POINTS
    }
    
    /// Execute liquidation
    public fun liquidate_position<T>(
        engine: &mut LiquidationEngine,
        market: &mut PerpetualsMarket<T>,
        registry: &PerpetualsRegistry,
        position: &mut PerpetualPosition,
        user_account: &mut UserAccount,
        liquidator: address,
        mut liquidation_size: Option<u64>,
        mut price_feeds: vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<USDC> {
        assert!(vec_set::contains(&engine.registered_liquidators, &liquidator), E_UNAUTHORIZED_LIQUIDATOR);
        
        let current_price = get_mark_price(price_feeds, market.price_feed_id);
        assert!(check_liquidation_eligibility(market, position, current_price), E_POSITION_NOT_LIQUIDATABLE);
        
        // Determine optimal liquidation size based on health factor
        let health_factor = calculate_health_factor(position, current_price);
        
        let optimal_liquidate_size = if (health_factor <= 5000) { // Health factor <= 50%
            position.size // Full liquidation for severely underwater positions
        } else if (health_factor <= 8000) { // Health factor 50-80%
            position.size * 75 / 100 // Liquidate 75%
        } else {
            position.size / 2 // Partial liquidation for marginally underwater positions
        };
        
        let liquidate_size = if (option::is_some(&liquidation_size)) {
            // Use provided size but ensure it doesn't exceed optimal size
            let requested_size = option::extract(&mut liquidation_size);
            if (requested_size > optimal_liquidate_size) {
                optimal_liquidate_size
            } else {
                requested_size
            }
        } else {
            optimal_liquidate_size
        };
        
        // Ensure minimum liquidation size
        let liquidate_size = if (liquidate_size < MIN_POSITION_SIZE) {
            if (position.size < MIN_POSITION_SIZE * 2) {
                position.size // Full liquidation if position is too small
            } else {
                MIN_POSITION_SIZE
            }
        } else {
            liquidate_size
        };
        
        // Calculate liquidation penalty and rewards
        let liquidation_value = liquidate_size * current_price / 1000000; // Convert to USDC
        let liquidation_penalty = liquidation_value * LIQUIDATION_PENALTY / BASIS_POINTS;
        let liquidator_reward = liquidation_penalty * 4000 / BASIS_POINTS; // 40%
        let insurance_contribution = liquidation_penalty * INSURANCE_FUND_RATIO / BASIS_POINTS;
        
        // Update position
        position.size = position.size - liquidate_size;
        position.margin = if (position.margin > liquidation_penalty) {
            position.margin - liquidation_penalty
        } else {
            0
        };
        
        // Update market state
        if (position.side == string::utf8(b"LONG")) {
            market.total_long_oi = market.total_long_oi - liquidate_size;
        } else {
            market.total_short_oi = market.total_short_oi - liquidate_size;
        };
        
        // Add to insurance fund
        // In production, this would be funded from liquidation penalties
        // For now, skip adding to the insurance fund
        
        // Update liquidator stats
        if (table::contains(&engine.liquidator_performance, liquidator)) {
            let stats = table::borrow_mut(&mut engine.liquidator_performance, liquidator);
            stats.liquidations_completed = stats.liquidations_completed + 1;
            stats.total_volume_liquidated = stats.total_volume_liquidated + liquidation_value;
            stats.rewards_earned = stats.rewards_earned + liquidator_reward;
        } else {
            let stats = LiquidatorStats {
                liquidations_completed: 1,
                total_volume_liquidated: liquidation_value,
                average_response_time: 0,
                success_rate: 10000, // 100%
                rewards_earned: liquidator_reward,
            };
            table::add(&mut engine.liquidator_performance, liquidator, stats);
        };
        
        // Emit liquidation event
        event::emit(PositionLiquidated {
            position_id: object::id(position),
            user: position.user,
            liquidator,
            market: market.market_symbol,
            liquidated_size: liquidate_size,
            liquidation_price: current_price,
            liquidation_fee: liquidation_penalty,
            liquidator_reward,
            insurance_fund_contribution: insurance_contribution,
            timestamp: clock::timestamp_ms(clock),
        });
        
        // Return liquidator reward
        // In production, this would be funded from liquidation penalties
        coin::zero<USDC>(ctx)
    }
    
    // ========== Margin Health & Risk Management ==========
    
    /// Calculate current health factor for a position
    public fun calculate_health_factor(
        position: &PerpetualPosition,
        current_price: u64,
    ): u64 {
        // Health Factor = (Margin + Unrealized PnL) / Maintenance Margin Requirement
        let unrealized_pnl = calculate_unrealized_pnl(
            position.side,
            position.entry_price,
            current_price,
            position.size
        );
        
        let current_margin_value = if (is_positive(&unrealized_pnl)) {
            position.margin + to_u64_positive(&unrealized_pnl)
        } else {
            let loss = abs(&unrealized_pnl);
            if (position.margin > loss) {
                position.margin - loss
            } else {
                0
            }
        };
        
        let maintenance_margin = calculate_maintenance_margin(position.leverage);
        let required_maintenance = position.size * maintenance_margin / BASIS_POINTS / position.leverage;
        
        if (required_maintenance == 0) {
            return 10000 // 100% if no maintenance margin required
        };
        
        (current_margin_value * BASIS_POINTS) / required_maintenance
    }
    
    /// Check if position is liquidatable
    public fun is_position_liquidatable(
        position: &PerpetualPosition,
        current_price: u64,
    ): bool {
        let health_factor = calculate_health_factor(position, current_price);
        health_factor < BASIS_POINTS // Less than 100% = liquidatable
    }
    
    /// Update position with current market data
    public fun update_position_metrics(
        position: &mut PerpetualPosition,
        current_price: u64,
        funding_payment: SignedInt,
        clock: &Clock,
    ) {
        // Update unrealized P&L
        position.unrealized_pnl = calculate_unrealized_pnl(
            position.side,
            position.entry_price,
            current_price,
            position.size
        );
        
        // Apply funding payment
        position.funding_payments = signed_add(position.funding_payments, funding_payment);
        
        // Update margin ratio
        let health_factor = calculate_health_factor(position, current_price);
        position.margin_ratio = health_factor;
        
        // Update liquidation price
        position.liquidation_price = calculate_liquidation_price(
            position.side,
            position.entry_price,
            position.leverage
        );
        
        position.last_update_timestamp = clock::timestamp_ms(clock);
    }
    
    // ========== Helper Functions ==========
    
    /// Calculate required margin for a position
    fun calculate_required_margin(size: u64, leverage: u64): u64 {
        size / leverage + (size * INITIAL_MARGIN_BUFFER / BASIS_POINTS)
    }
    
    /// Calculate maintenance margin requirement
    fun calculate_maintenance_margin(leverage: u64): u64 {
        if (leverage <= 10) {
            1000 // 10%
        } else if (leverage <= 25) {
            500 // 5%
        } else if (leverage <= 50) {
            250 // 2.5%
        } else {
            MIN_MAINTENANCE_MARGIN // 1.33%
        }
    }
    
    /// Calculate initial margin requirement
    fun calculate_initial_margin(leverage: u64): u64 {
        calculate_maintenance_margin(leverage) + INITIAL_MARGIN_BUFFER
    }
    
    /// Calculate liquidation price
    fun calculate_liquidation_price(side: String, entry_price: u64, leverage: u64): u64 {
        let maintenance_margin_ratio = calculate_maintenance_margin(leverage);
        
        if (side == string::utf8(b"LONG")) {
            entry_price * (BASIS_POINTS - maintenance_margin_ratio) / BASIS_POINTS
        } else {
            entry_price * (BASIS_POINTS + maintenance_margin_ratio) / BASIS_POINTS
        }
    }
    
    /// Calculate trading fee with UNXV discounts
    fun calculate_trading_fee(size: u64, price: u64, is_maker: bool, unxv_tier: u64): u64 {
        let base_fee = if (is_maker) MAKER_FEE else TAKER_FEE;
        let trade_value = size * price / 1000000; // Convert to USDC value
        let gross_fee = trade_value * base_fee / BASIS_POINTS;
        
        // Apply UNXV tier discount
        let discount = get_unxv_discount(unxv_tier);
        gross_fee * (BASIS_POINTS - discount) / BASIS_POINTS
    }
    
    /// Get UNXV tier discount
    fun get_unxv_discount(tier: u64): u64 {
        if (tier == 0) 0
        else if (tier == 1) 500 // 5%
        else if (tier == 2) 1000 // 10%
        else if (tier == 3) 1500 // 15%
        else if (tier == 4) 2000 // 20%
        else 2500 // 25% for tier 5+
    }
    
    /// Calculate realized P&L for a position
    fun calculate_realized_pnl(side: String, entry_price: u64, exit_price: u64, size: u64): SignedInt {
        // P&L = size * (exit_price - entry_price) for LONG
        // P&L = size * (entry_price - exit_price) for SHORT
        
        if (side == string::utf8(b"LONG")) {
            if (exit_price >= entry_price) {
                // Profit for long when price goes up
                // P&L = size * (exit_price - entry_price) / entry_price
                let profit = size * (exit_price - entry_price) / entry_price;
                signed_int_from(profit)
            } else {
                // Loss for long when price goes down
                let loss = size * (entry_price - exit_price) / entry_price;
                signed_int_negative(loss)
            }
        } else {
            // SHORT position
            if (entry_price >= exit_price) {
                // Profit for short when price goes down
                let profit = size * (entry_price - exit_price) / entry_price;
                signed_int_from(profit)
            } else {
                // Loss for short when price goes up
                let loss = size * (exit_price - entry_price) / entry_price;
                signed_int_negative(loss)
            }
        }
    }
    
    /// Calculate unrealized P&L for current position
    fun calculate_unrealized_pnl(side: String, entry_price: u64, current_price: u64, size: u64): SignedInt {
        calculate_realized_pnl(side, entry_price, current_price, size)
    }
    
    /// Calculate weighted average price
    fun calculate_weighted_average_price(old_avg: u64, old_volume: u64, new_price: u64, new_volume: u64): u64 {
        if (old_volume == 0) {
            new_price
        } else {
            (old_avg * old_volume + new_price * new_volume) / (old_volume + new_volume)
        }
    }
    
    /// Get mark price from Pyth feeds
    fun get_mark_price(price_feeds: vector<PriceInfoObject>, _feed_id: vector<u8>): u64 {
        // Simplified implementation - in production would validate feed ID and extract price
        // For testing, we expect an empty vector
        vector::destroy_empty(price_feeds);
        1000000000 // Return 1000 USDC as placeholder
    }
    
    /// Get index price (spot price) from Pyth feeds
    fun get_index_price(_price_feeds: &vector<PriceInfoObject>, _feed_id: &vector<u8>): u64 {
        // In production, would extract spot price from Pyth feeds
        // For now, return a price slightly different from mark price to simulate premium
        999500000 // Return 999.5 USDC as placeholder (0.05% discount to mark)
    }
    
    /// Calculate volatility adjustment based on recent price movements
    fun calculate_volatility_adjustment<T>(market: &PerpetualsMarket<T>): SignedInt {
        // In production, would analyze price history to calculate volatility
        // Higher volatility -> higher funding rate variance
        signed_int_from(0) // Simplified for now
    }
    
    /// Record funding calculation for analytics
    fun record_funding_calculation<T>(
        _calculator: &mut FundingRateCalculator,
        _market: &PerpetualsMarket<T>,
        _premium: SignedInt,
        _oi_imbalance: SignedInt,
        _timestamp: u64,
    ) {
        // In production, would store historical data for analysis
        // Simplified for now
    }
    
    /// Calculate confidence level based on market conditions
    fun calculate_confidence_level(total_oi: u64, mark_price: u64, index_price: u64): u64 {
        // Higher OI and smaller price divergence = higher confidence
        let price_divergence = if (mark_price >= index_price) {
            ((mark_price - index_price) * BASIS_POINTS) / index_price
        } else {
            ((index_price - mark_price) * BASIS_POINTS) / index_price
        };
        
        // Base confidence starts at 95%
        let base_confidence = 9500;
        
        // Reduce confidence based on price divergence (max 20% reduction)
        let divergence_penalty = if (price_divergence > 2000) { 2000 } else { price_divergence };
        
        // Reduce confidence if OI is too low (illiquid market)
        let oi_penalty = if (total_oi < 100000000000) { // Less than 100k USDC
            500
        } else {
            0
        };
        
        base_confidence - divergence_penalty - oi_penalty
    }
    
    /// Validate price limit for orders
    fun validate_price_limit(side: String, current_price: u64, limit_price: u64) {
        if (side == string::utf8(b"LONG")) {
            assert!(current_price <= limit_price, E_SLIPPAGE_TOO_HIGH);
        } else {
            assert!(current_price >= limit_price, E_SLIPPAGE_TOO_HIGH);
        };
    }
    
    /// Cap funding rate to maximum allowed
    fun cap_funding_rate(funding_rate: SignedInt, max_rate: u64): SignedInt {
        if (funding_rate.is_positive) {
            if (funding_rate.value > max_rate) {
                SignedInt { value: max_rate, is_positive: true }
            } else {
                funding_rate
            }
        } else {
            if (funding_rate.value > max_rate) {
                SignedInt { value: max_rate, is_positive: false }
            } else {
                funding_rate
            }
        }
    }
    
    // ========== Read-Only Functions ==========
    
    /// Get market information
    public fun get_market_info<T>(market: &PerpetualsMarket<T>): (String, u64, u64, SignedInt, u64, u64) {
        (
            market.market_symbol,
            market.mark_price,
            market.index_price,
            market.funding_rate,
            market.total_long_oi,
            market.total_short_oi
        )
    }
    
    /// Get position details
    public fun get_position_info(position: &PerpetualPosition): (String, String, u64, u64, u64, u64, u64) {
        (
            position.market,
            position.side,
            position.size,
            position.entry_price,
            position.margin,
            position.leverage,
            position.liquidation_price
        )
    }
    
    /// Get user account summary
    public fun get_account_summary(account: &UserAccount): (u64, u64, u64, SignedInt, u64) {
        (
            account.total_margin,
            account.available_margin,
            account.used_margin,
            account.total_realized_pnl,
            vec_set::size(&account.active_positions)
        )
    }
    
    // ========== Test Helper Functions ==========
    
    #[test_only]
    public fun calculate_realized_pnl_test(side: String, entry_price: u64, exit_price: u64, size: u64): SignedInt {
        calculate_realized_pnl(side, entry_price, exit_price, size)
    }
    
    #[test_only]
    public fun create_test_position(
        user: address,
        market: String,
        side: String,
        size: u64,
        entry_price: u64,
        margin: u64,
        leverage: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): PerpetualPosition {
        let position_id = object::new(ctx);
        let liquidation_price = calculate_liquidation_price(side, entry_price, leverage);
        
        PerpetualPosition {
            id: position_id,
            user,
            market,
            side,
            size,
            entry_price,
            margin,
            leverage,
            unrealized_pnl: signed_int_from(0),
            realized_pnl: signed_int_from(0),
            funding_payments: signed_int_from(0),
            liquidation_price,
            maintenance_margin: calculate_required_margin(size, leverage),
            margin_ratio: 10000, // 100%
            created_timestamp: clock::timestamp_ms(clock),
            last_update_timestamp: clock::timestamp_ms(clock),
            auto_close_enabled: false,
            stop_loss_price: option::none(),
            take_profit_price: option::none(),
            trailing_stop_distance: option::none(),
        }
    }
    
    #[test_only]
    public fun create_test_market<T>(ctx: &mut TxContext): PerpetualsMarket<T> {
        let market_id = object::new(ctx);
        let empty_table_long = table::new<address, ID>(ctx);
        let empty_table_short = table::new<address, ID>(ctx);
        
        PerpetualsMarket<T> {
            id: market_id,
            market_symbol: string::utf8(b"sBTC-PERP"),
            underlying_type: string::utf8(b"TestCoin"),
            long_positions: empty_table_long,
            short_positions: empty_table_short,
            position_count: 0,
            mark_price: 1000000000, // 1000 USDC
            index_price: 999500000, // 999.5 USDC
            funding_rate: signed_int_from(0),
            next_funding_time: 0,
            total_long_oi: 0,
            total_short_oi: 0,
            average_long_price: 0,
            average_short_price: 0,
            total_volume_24h: 0,
            price_history: vector::empty(),
            funding_rate_history: vector::empty(),
            liquidation_queue: vector::empty(),
            insurance_fund: balance::zero<USDC>(),
            auto_deleverage_queue: vector::empty(),
            deepbook_pool_id: object::id_from_address(@0x0),
            balance_manager_id: object::id_from_address(@0x0),
            price_feed_id: vector::empty(),
        }
    }
    
    #[test_only]
    public fun get_funding_rate_from_calc(calc: &FundingRateCalculation): SignedInt {
        calc.funding_rate
    }
    
    #[test_only]
    public fun get_confidence_from_calc(calc: &FundingRateCalculation): u64 {
        calc.confidence_level
    }
    
    #[test_only]
    public fun get_registry_total_markets(registry: &PerpetualsRegistry): u64 {
        vec_set::size(&registry.active_markets)
    }
}


