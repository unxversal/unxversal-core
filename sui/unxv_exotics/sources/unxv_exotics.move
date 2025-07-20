/// Module: unxv_exotics
/// UnXversal Exotic Derivatives Protocol - Sophisticated financial instruments with custom payoff structures
/// Enables advanced trading strategies through barrier options, power perpetuals, range accruals, and bespoke derivatives
#[allow(duplicate_alias, unused_use, unused_const, unused_variable, unused_function)]
module unxv_exotics::unxv_exotics {
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
    use pyth::i64::{Self as pyth_i64, I64};
    use pyth::pyth;
    
    // DeepBook integration for liquidity
    use deepbook::balance_manager::{BalanceManager, TradeProof};
    
    // Standard coin types
    public struct USDC has drop {}
    public struct SUI has drop {}
    public struct UNXV has drop {}
    
    // ========== Error Constants ==========
    
    const E_NOT_ADMIN: u64 = 1;
    const E_PAYOFF_NOT_SUPPORTED: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_INVALID_PARAMETERS: u64 = 4;
    const E_POSITION_NOT_FOUND: u64 = 5;
    const E_MARKET_NOT_FOUND: u64 = 6;
    const E_SYSTEM_PAUSED: u64 = 7;
    const E_INVALID_PRICE: u64 = 8;
    const E_BARRIER_ALREADY_HIT: u64 = 9;
    const E_OPTION_EXPIRED: u64 = 10;
    const E_INSUFFICIENT_PREMIUM: u64 = 11;
    const E_CUSTOM_PAYOFF_NOT_APPROVED: u64 = 12;
    const E_INVALID_COMPLEXITY_SCORE: u64 = 13;
    const E_UNAUTHORIZED_ACCESS: u64 = 14;
    const E_PRICING_ENGINE_NOT_FOUND: u64 = 15;
    const E_SETTLEMENT_NOT_READY: u64 = 16;
    const E_INVALID_GREEKS: u64 = 17;
    const E_RISK_LIMITS_EXCEEDED: u64 = 18;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 19;
    const E_BARRIER_BREACHED: u64 = 20;
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000;
    const VOLATILITY_PRECISION: u64 = 1000000;
    const PRICE_PRECISION: u64 = 1000000;
    const MAX_PRICE_AGE: u64 = 300; // 5 minutes in seconds
    const DEFAULT_PREMIUM_FEE: u64 = 30; // 0.3%
    const DEFAULT_SETTLEMENT_FEE: u64 = 25; // 0.25%
    const MIN_BARRIER_DISTANCE: u64 = 500; // 5% minimum distance from barrier
    const MAX_POWER_EXPONENT: u64 = 5; // Maximum power for power perpetuals
    const MIN_RANGE_WIDTH: u64 = 200; // 2% minimum range width for range accruals
    const CUSTOM_PAYOFF_DEPLOYMENT_COST: u64 = 1000_000000; // 1000 USDC
    const MAX_COMPLEXITY_SCORE: u64 = 1000;
    
    // UNXV tier thresholds
    const TIER_1_THRESHOLD: u64 = 1000_000000; // 1,000 UNXV
    const TIER_2_THRESHOLD: u64 = 5000_000000; // 5,000 UNXV
    const TIER_3_THRESHOLD: u64 = 25000_000000; // 25,000 UNXV
    const TIER_4_THRESHOLD: u64 = 100000_000000; // 100,000 UNXV
    const TIER_5_THRESHOLD: u64 = 500000_000000; // 500,000 UNXV
    
    // ========== SignedInt Helper ==========
    
    /// SignedInt for handling positive and negative values
    public struct SignedInt has copy, drop, store {
        value: u64,
        is_negative: bool,
    }
    
    /// Helper functions for SignedInt
    public fun signed_int_from(value: u64): SignedInt {
        SignedInt { value, is_negative: false }
    }
    
    public fun signed_int_negative(value: u64): SignedInt {
        SignedInt { value, is_negative: true }
    }
    
    public fun signed_int_add(a: &SignedInt, b: &SignedInt): SignedInt {
        if (a.is_negative == b.is_negative) {
            SignedInt { value: a.value + b.value, is_negative: a.is_negative }
        } else {
            if (a.value >= b.value) {
                SignedInt { value: a.value - b.value, is_negative: a.is_negative }
            } else {
                SignedInt { value: b.value - a.value, is_negative: b.is_negative }
            }
        }
    }
    
    public fun signed_int_subtract(a: &SignedInt, b: &SignedInt): SignedInt {
        let b_negated = SignedInt { value: b.value, is_negative: !b.is_negative };
        signed_int_add(a, &b_negated)
    }
    
    public fun signed_int_value(s: &SignedInt): u64 {
        s.value
    }
    
    public fun signed_int_is_negative(s: &SignedInt): bool {
        s.is_negative
    }
    
    // ========== Core Data Structures ==========
    
    /// Central registry for exotic derivatives configuration
    public struct ExoticDerivativesRegistry has key {
        id: UID,
        
        // Product catalog
        supported_payoffs: Table<String, PayoffStructure>,
        active_products: Table<String, ExoticProduct>,
        custom_payoffs: Table<String, CustomPayoff>,
        
        // Pricing infrastructure
        pricing_engines: Table<String, ID>, // Engine type -> pricing engine ID
        monte_carlo_configs: MonteCarloConfigs,
        
        // Greeks calculation
        greeks_engines: GreeksCalculationEngines,
        
        // Risk management
        exotic_risk_limits: ExoticRiskLimits,
        
        // Market making
        exotic_market_makers: Table<address, MarketMakerInfo>,
        
        // Integration
        underlying_assets: Table<String, UnderlyingAsset>,
        settlement_mechanisms: SettlementMechanisms,
        
        // UNXV integration
        unxv_exotic_benefits: Table<u64, ExoticTierBenefits>,
        
        // Emergency controls
        emergency_settlement: bool,
        admin_cap: Option<AdminCap>,
    }
    
    /// Payoff structure configuration
    public struct PayoffStructure has store {
        payoff_code: String,
        payoff_name: String,
        payoff_formula: String,
        
        // Parameters
        required_parameters: vector<ParameterDefinition>,
        parameter_constraints: ParameterConstraints,
        
        // Pricing complexity
        pricing_method: String,
        computational_complexity: u64,
        
        // Risk characteristics
        risk_factors: vector<RiskFactor>,
        max_leverage_equivalent: u64,
        path_dependency: bool,
        early_exercise: bool,
        
        // Market characteristics
        typical_bid_ask_spread: u64,
        institutional_focus: bool,
    }
    
    /// Parameter definition for payoffs
    public struct ParameterDefinition has store {
        parameter_name: String,
        parameter_type: String,
        default_value: Option<u64>,
        description: String,
    }
    
    /// Parameter constraints
    public struct ParameterConstraints has store {
        min_values: Table<String, u64>,
        max_values: Table<String, u64>,
        valid_ranges: Table<String, vector<u64>>,
    }
    
    /// Risk factor
    public struct RiskFactor has store {
        factor_name: String,
        factor_type: String,
        impact_level: String,
        mitigation_required: bool,
    }
    
    /// Simplified payoff info for positions
    public struct PayoffInfo has store, copy, drop {
        payoff_code: String,
        payoff_name: String,
        pricing_method: String,
        path_dependency: bool,
        max_leverage_equivalent: u64,
    }
    
    /// Exotic product configuration
    public struct ExoticProduct has store {
        product_id: String,
        payoff_code: String,
        underlying_asset: String,
        
        // Product specifications
        parameters: Table<String, u64>,
        expiration_timestamp: u64,
        settlement_method: String,
        
        // Market data
        current_price: u64,
        theoretical_value: u64,
        implied_volatility: u64,
        
        // Greeks
        delta: SignedInt,
        gamma: SignedInt,
        theta: SignedInt,
        vega: SignedInt,
        rho: SignedInt,
        exotic_greeks: Table<String, SignedInt>,
        
        // Trading data
        volume_24h: u64,
        open_interest: u64,
        bid_price: u64,
        ask_price: u64,
        last_trade_price: u64,
        
        // Risk metrics
        maximum_loss: u64,
        probability_profit: u64,
        expected_return: SignedInt,
        risk_reward_ratio: u64,
        
        // Status
        is_active: bool,
        is_listed: bool,
        market_maker_count: u64,
    }
    
    /// Custom payoff definition
    public struct CustomPayoff has store {
        creator: address,
        payoff_name: String,
        payoff_description: String,
        
        // Mathematical definition
        payoff_function: PayoffFunction,
        parameter_definitions: vector<ParameterDefinition>,
        constraints: PayoffConstraints,
        
        // Validation
        risk_assessment: CustomPayoffRisk,
        approval_status: String,
        
        // Usage
        deployment_cost: u64,
        usage_fee: u64,
        creator_royalty: u64,
        
        // Performance
        user_adoption: u64,
        total_volume: u64,
    }
    
    /// Payoff function definition
    public struct PayoffFunction has store {
        function_type: String,
        function_definition: String,
        input_variables: vector<String>,
        output_type: String,
        complexity_score: u64,
    }
    
    /// Payoff constraints
    public struct PayoffConstraints has store {
        max_payout: Option<u64>,
        min_payout: Option<u64>,
        risk_limitations: vector<String>,
        regulatory_constraints: vector<String>,
    }
    
    /// Custom payoff risk assessment
    public struct CustomPayoffRisk has store {
        risk_level: String,
        key_risks: vector<String>,
        maximum_loss_potential: u64,
        stress_test_results: vector<u64>,
    }
    
    /// Exotic options market for specific underlying
    public struct ExoticOptionsMarket<phantom T> has key {
        id: UID,
        
        // Market identification
        underlying_asset: String,
        supported_payoffs: VecSet<String>,
        
        // Active positions
        long_positions: Table<address, vector<ID>>,
        short_positions: Table<address, vector<ID>>,
        market_maker_positions: Table<address, MMPosition>,
        
        // Pricing and Greeks
        pricing_engine: PricingEngineInstance,
        real_time_greeks: RealTimeGreeks,
        implied_volatility_surface: VolatilitySurface,
        
        // Order book
        order_book: ExoticOrderBook,
        market_maker_quotes: Table<address, MMQuote>,
        recent_trades: vector<ExoticTrade>,
        
        // Risk management
        position_limits: PositionLimits,
        exposure_tracking: ExposureTracking,
        margin_requirements: MarginRequirements,
        
        // Market data
        volatility_estimates: VolatilityEstimates,
        risk_free_rate: u64,
        dividend_yield: u64,
        
        // Settlement
        settlement_queue: vector<SettlementRequest>,
        settlement_prices: Table<u64, SettlementPrice>,
        
        // Integration
        deepbook_pool_id: ID,
        balance_manager_id: ID,
        price_oracle_id: ID,
    }
    
    /// Individual exotic position
    public struct ExoticPosition has key, store {
        id: UID,
        user: address,
        
        // Position details
        payoff_code: String,
        side: String,
        quantity: u64,
        entry_price: u64,
        
        // Payoff parameters
        strike_price: Option<u64>,
        barrier_levels: vector<u64>,
        coupon_rate: Option<u64>,
        power_exponent: Option<u64>,
        
        // Custom parameters
        custom_parameters: Table<String, u64>,
        payoff_info: PayoffInfo,
        
        // Risk metrics
        current_pnl: SignedInt,
        maximum_loss: u64,
        greeks: PositionGreeks,
        
        // Monitoring
        barrier_monitoring: BarrierMonitoring,
        accrual_tracking: AccrualTracking,
        
        // Position management
        created_timestamp: u64,
        expiration_timestamp: u64,
        early_exercise_allowed: bool,
        auto_exercise_enabled: bool,
        stop_loss_level: Option<u64>,
        take_profit_level: Option<u64>,
    }
    
    /// Barrier monitoring for barrier products
    public struct BarrierMonitoring has store {
        barrier_type: String,
        barrier_levels: vector<u64>,
        barrier_hit: vector<bool>,
        hit_timestamps: vector<Option<u64>>,
        monitoring_frequency: u64,
        current_status: String,
    }
    
    /// Accrual tracking for range accrual products
    public struct AccrualTracking has store {
        accrual_periods: vector<AccrualPeriod>,
        total_accrued: u64,
        current_period: u64,
        accrual_rate: u64,
        range_boundaries: RangeBoundaries,
    }
    
    /// Accrual period data
    public struct AccrualPeriod has store {
        period_start: u64,
        period_end: u64,
        price_in_range: bool,
        accrual_amount: u64,
        average_price: u64,
    }
    
    /// Range boundaries for range products
    public struct RangeBoundaries has store {
        range_lower: u64,
        range_upper: u64,
        range_width: u64,
    }
    
    /// Position Greeks
    public struct PositionGreeks has store, copy, drop {
        delta: SignedInt,
        gamma: SignedInt,
        theta: SignedInt,
        vega: SignedInt,
        rho: SignedInt,
        exotic_greeks: vector<ExoticGreek>,
    }
    
    /// Exotic Greek
    public struct ExoticGreek has store, copy, drop {
        greek_name: String,
        greek_value: SignedInt,
        description: String,
    }
    
    /// Pricing engine instance
    public struct PricingEngine has key {
        id: UID,
        operator: address,
        
        // Pricing methodologies
        analytical_models: AnalyticalModels,
        monte_carlo_engine: MonteCarloEngine,
        machine_learning_models: MLPricingModels,
        
        // Model calibration
        calibration_data: CalibrationData,
        model_parameters: ModelParameters,
        
        // Greeks calculation
        greeks_calculator: GreeksCalculator,
        
        // Model validation
        performance_metrics: ModelPerformanceMetrics,
        
        // Real-time features
        real_time_pricing: RealTimePricing,
        
        // Risk management
        pricing_bounds: PricingBounds,
    }
    
    /// Admin capability
    public struct AdminCap has key, store {
        id: UID,
    }
    
    // ========== Supporting Structures ==========
    
    public struct MonteCarloConfigs has store {
        default_paths: u64,
        default_steps: u64,
        variance_reduction_enabled: bool,
        parallel_processing: bool,
    }
    
    public struct GreeksCalculationEngines has store {
        real_time_enabled: bool,
        calculation_frequency: u64,
        sensitivity_analysis_enabled: bool,
    }
    
    public struct ExoticRiskLimits has store {
        max_position_size: u64,
        max_portfolio_concentration: u64,
        max_leverage_equivalent: u64,
        stress_test_requirements: bool,
    }
    
    public struct MarketMakerInfo has store {
        market_maker: address,
        products_supported: VecSet<String>,
        average_spread: u64,
        uptime_percentage: u64,
        volume_contribution: u64,
    }
    
    public struct UnderlyingAsset has store {
        asset_symbol: String,
        asset_type: String,
        price_feed_id: vector<u8>,
        volatility_estimate: u64,
        is_supported: bool,
    }
    
    public struct SettlementMechanisms has store {
        cash_settlement_enabled: bool,
        physical_settlement_enabled: bool,
        automatic_settlement: bool,
        settlement_lag: u64,
    }
    
    public struct ExoticTierBenefits has store {
        tier_level: u64,
        premium_discount: u64,
        custom_payoff_access: bool,
        structured_products_access: bool,
        advanced_pricing_models: bool,
        institutional_products: bool,
        market_making_benefits: bool,
        priority_execution: bool,
        custom_risk_limits: bool,
        bespoke_product_creation: bool,
        advanced_analytics_access: bool,
        cross_protocol_exotic_access: bool,
        exotic_yield_farming_access: bool,
    }
    
    public struct PricingEngineInstance has store {
        engine_id: ID,
        engine_type: String,
        last_update: u64,
        accuracy_score: u64,
    }
    
    public struct RealTimeGreeks has store {
        last_calculation: u64,
        calculation_frequency: u64,
        accuracy_level: u64,
    }
    
    public struct VolatilitySurface has store {
        surface_points: vector<VolatilityPoint>,
        last_updated: u64,
        interpolation_method: String,
    }
    
    public struct VolatilityPoint has store {
        strike: u64,
        expiry: u64,
        implied_volatility: u64,
        bid_vol: u64,
        ask_vol: u64,
    }
    
    public struct ExoticOrderBook has store {
        bid_orders: vector<ExoticOrder>,
        ask_orders: vector<ExoticOrder>,
        last_trade_price: u64,
        spread: u64,
    }
    
    public struct ExoticOrder has store {
        order_id: ID,
        trader: address,
        product_id: String,
        side: String,
        quantity: u64,
        price: u64,
        order_type: String,
        timestamp: u64,
    }
    
    public struct MMQuote has store {
        market_maker: address,
        bid_price: u64,
        ask_price: u64,
        bid_size: u64,
        ask_size: u64,
        quote_timestamp: u64,
    }
    
    public struct MMPosition has store {
        market_maker: address,
        net_position: SignedInt,
        inventory: Table<String, u64>,
        risk_exposure: u64,
    }
    
    public struct ExoticTrade has store {
        trade_id: ID,
        buyer: address,
        seller: address,
        product_id: String,
        quantity: u64,
        price: u64,
        timestamp: u64,
    }
    
    public struct PositionLimits has store {
        max_single_position: u64,
        max_total_exposure: u64,
        concentration_limit: u64,
    }
    
    public struct ExposureTracking has store {
        total_long_exposure: u64,
        total_short_exposure: u64,
        net_exposure: SignedInt,
        last_updated: u64,
    }
    
    public struct MarginRequirements has store {
        initial_margin_rate: u64,
        maintenance_margin_rate: u64,
        stress_test_margin: u64,
    }
    
    public struct VolatilityEstimates has store {
        historical_vol: u64,
        implied_vol: u64,
        realized_vol: u64,
        vol_forecast: u64,
    }
    
    public struct SettlementRequest has store {
        position_id: ID,
        settlement_type: String,
        settlement_amount: u64,
        settlement_timestamp: u64,
    }
    
    public struct SettlementPrice has store {
        underlying_price: u64,
        settlement_method: String,
        data_source: String,
        timestamp: u64,
    }
    
    public struct AnalyticalModels has store {
        black_scholes_enabled: bool,
        barrier_models_enabled: bool,
        asian_models_enabled: bool,
        power_models_enabled: bool,
    }
    
    public struct MonteCarloEngine has store {
        simulation_paths: u64,
        time_steps: u64,
        variance_reduction: bool,
        confidence_level: u64,
    }
    
    public struct MLPricingModels has store {
        neural_networks_enabled: bool,
        ensemble_methods_enabled: bool,
        model_accuracy: u64,
        last_training: u64,
    }
    
    public struct CalibrationData has store {
        historical_prices: vector<u64>,
        volatility_data: vector<u64>,
        last_calibration: u64,
    }
    
    public struct ModelParameters has store {
        risk_free_rate: u64,
        dividend_yield: u64,
        volatility_adjustment: u64,
    }
    
    public struct GreeksCalculator has store {
        calculation_method: String,
        accuracy_level: u64,
        real_time_enabled: bool,
    }
    
    public struct ModelPerformanceMetrics has store {
        pricing_accuracy: u64,
        prediction_error: u64,
        backtesting_results: vector<u64>,
    }
    
    public struct RealTimePricing has store {
        update_frequency: u64,
        last_update: u64,
        streaming_enabled: bool,
    }
    
    public struct PricingBounds has store {
        min_price: u64,
        max_price: u64,
        sanity_check_enabled: bool,
    }
    
    // ========== Result Structures ==========
    
    public struct ExoticPositionResult has drop {
        position_id: ID,
        entry_price: u64,
        premium_paid: u64,
        maximum_loss: u64,
        maximum_gain: Option<u64>,
        probability_profit: u64,
        expected_return: SignedInt,
        greeks: PositionGreeks,
        risk_factors: vector<String>,
        barrier_monitoring_enabled: bool,
        accrual_tracking_enabled: bool,
        auto_exercise_threshold: Option<u64>,
    }
    
    public struct KnockoutCallResult has drop {
        position_id: ID,
        ko_call_premium: u64,
        vanilla_call_premium: u64,
        discount_vs_vanilla: u64,
        knockout_probability: u64,
        survival_probability: u64,
        expected_payoff: u64,
        barrier_level: u64,
        distance_to_barrier: u64,
        barrier_monitoring_frequency: u64,
        risk_warnings: vector<String>,
    }
    
    public struct RangeAccrualResult has drop {
        position_id: ID,
        note_price: u64,
        expected_coupons: u64,
        maximum_coupons: u64,
        probability_in_range: u64,
        range_width: u64,
        current_price: u64,
        distance_to_bounds: RangeDistance,
        historical_time_in_range: u64,
        accrual_periods: u64,
        accrual_calendar: vector<u64>,
        first_accrual_date: u64,
    }
    
    public struct RangeDistance has drop {
        distance_to_lower: u64,
        distance_to_upper: u64,
        buffer_percentage: u64,
    }
    
    public struct PowerPerpResult has drop {
        position_id: ID,
        power_exponent: u64,
        effective_leverage: u64,
        entry_index_level: u64,
        funding_rate: SignedInt,
        variance_component: u64,
        skew_component: SignedInt,
        funding_frequency: u64,
        leverage_amplification: u64,
        gamma_exposure: SignedInt,
        volatility_sensitivity: SignedInt,
        initial_margin: u64,
        maintenance_margin: u64,
        margin_call_level: u64,
        liquidation_level: u64,
        performance_attribution: PowerPerpAttribution,
    }
    
    public struct PowerPerpAttribution has drop {
        price_pnl: SignedInt,
        convexity_pnl: SignedInt,
        funding_pnl: SignedInt,
        carry_pnl: SignedInt,
        total_pnl: SignedInt,
    }
    
    public struct ExoticPricingResult has drop {
        theoretical_value: u64,
        bid_price: u64,
        ask_price: u64,
        pricing_confidence: u64,
        pricing_error_estimate: u64,
        model_risk_adjustment: u64,
        pricing_method_used: String,
        computation_time_ms: u64,
        convergence_achieved: bool,
        simulation_paths: Option<u64>,
        alternative_prices: vector<AlternativePrice>,
    }
    
    public struct AlternativePrice has drop {
        pricing_method: String,
        price: u64,
        confidence: u64,
        computation_time: u64,
    }
    
    public struct EffectiveExoticCosts has drop {
        tier_level: u64,
        original_premium: u64,
        unxv_discount: u64,
        complexity_adjustment: u64,
        market_making_rebate: u64,
        net_premium: u64,
        total_savings_percentage: u64,
        exclusive_features_unlocked: vector<String>,
    }
    
    // ========== Events ==========
    
    /// Exotic position opened event
    public struct ExoticPositionOpened has copy, drop {
        position_id: ID,
        user: address,
        payoff_code: String,
        underlying_asset: String,
        side: String,
        quantity: u64,
        entry_price: u64,
        expiration_timestamp: u64,
        maximum_loss: u64,
        probability_profit: u64,
        entry_greeks: PositionGreeks,
        timestamp: u64,
    }
    
    /// Barrier breached event
    public struct BarrierBreached has copy, drop {
        position_id: ID,
        user: address,
        payoff_code: String,
        barrier_type: String,
        barrier_level: u64,
        current_price: u64,
        breach_timestamp: u64,
        position_status: String,
        impact_on_payoff: String,
    }
    
    /// Range accrual coupon earned event
    public struct RangeAccrualCouponEarned has copy, drop {
        position_id: ID,
        user: address,
        accrual_period: u64,
        coupon_amount: u64,
        days_in_range: u64,
        total_days: u64,
        accrual_rate: u64,
        range_lower: u64,
        range_upper: u64,
        average_price_in_period: u64,
        cumulative_coupons: u64,
        timestamp: u64,
    }
    
    /// Power perpetual funding paid event
    public struct PowerPerpFundingPaid has copy, drop {
        position_id: ID,
        user: address,
        power_exponent: u64,
        funding_amount: SignedInt,
        underlying_price: u64,
        variance_contribution: u64,
        skew_contribution: SignedInt,
        funding_rate: SignedInt,
        position_value: u64,
        cumulative_funding: SignedInt,
        timestamp: u64,
    }
    
    /// Exotic product priced event
    public struct ExoticProductPriced has copy, drop {
        product_id: String,
        payoff_code: String,
        underlying_asset: String,
        pricing_method: String,
        theoretical_value: u64,
        bid_price: u64,
        ask_price: u64,
        mid_price: u64,
        delta: SignedInt,
        gamma: SignedInt,
        theta: SignedInt,
        vega: SignedInt,
        rho: SignedInt,
        computational_time_ms: u64,
        confidence_level: u64,
        pricing_error_estimate: u64,
        last_calibration: u64,
        timestamp: u64,
    }
    
    /// Custom payoff created event
    public struct CustomPayoffCreated has copy, drop {
        creator: address,
        payoff_name: String,
        payoff_code: String,
        payoff_description: String,
        complexity_score: u64,
        estimated_pricing_cost: u64,
        risk_assessment: String,
        deployment_cost: u64,
        usage_fee: u64,
        creator_royalty: u64,
        approval_required: bool,
        estimated_approval_time: u64,
        regulatory_review_required: bool,
        timestamp: u64,
    }
    
    // ========== Core Functions ==========
    
    /// Initialize the Exotic Derivatives protocol
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        // Initialize tier benefits
        let mut unxv_exotic_benefits = table::new<u64, ExoticTierBenefits>(ctx);
        
        // Tier 0: Standard access
        table::add(&mut unxv_exotic_benefits, 0, ExoticTierBenefits {
            tier_level: 0,
            premium_discount: 0,
            custom_payoff_access: false,
            structured_products_access: false,
            advanced_pricing_models: false,
            institutional_products: false,
            market_making_benefits: false,
            priority_execution: false,
            custom_risk_limits: false,
            bespoke_product_creation: false,
            advanced_analytics_access: false,
            cross_protocol_exotic_access: false,
            exotic_yield_farming_access: false,
        });
        
        // Tier 1: Basic exotic access
        table::add(&mut unxv_exotic_benefits, 1, ExoticTierBenefits {
            tier_level: 1,
            premium_discount: 800, // 8%
            custom_payoff_access: false,
            structured_products_access: false,
            advanced_pricing_models: false,
            institutional_products: false,
            market_making_benefits: false,
            priority_execution: false,
            custom_risk_limits: false,
            bespoke_product_creation: false,
            advanced_analytics_access: false,
            cross_protocol_exotic_access: false,
            exotic_yield_farming_access: false,
        });
        
        // Tier 2: Enhanced exotic features
        table::add(&mut unxv_exotic_benefits, 2, ExoticTierBenefits {
            tier_level: 2,
            premium_discount: 1500, // 15%
            custom_payoff_access: true,
            structured_products_access: false,
            advanced_pricing_models: false,
            institutional_products: false,
            market_making_benefits: true,
            priority_execution: false,
            custom_risk_limits: false,
            bespoke_product_creation: false,
            advanced_analytics_access: false,
            cross_protocol_exotic_access: true,
            exotic_yield_farming_access: true,
        });
        
        // Tier 3: Premium exotic access
        table::add(&mut unxv_exotic_benefits, 3, ExoticTierBenefits {
            tier_level: 3,
            premium_discount: 2500, // 25%
            custom_payoff_access: true,
            structured_products_access: true,
            advanced_pricing_models: false,
            institutional_products: false,
            market_making_benefits: true,
            priority_execution: true,
            custom_risk_limits: false,
            bespoke_product_creation: false,
            advanced_analytics_access: true,
            cross_protocol_exotic_access: true,
            exotic_yield_farming_access: true,
        });
        
        // Tier 4: VIP exotic features
        table::add(&mut unxv_exotic_benefits, 4, ExoticTierBenefits {
            tier_level: 4,
            premium_discount: 4000, // 40%
            custom_payoff_access: true,
            structured_products_access: true,
            advanced_pricing_models: true,
            institutional_products: false,
            market_making_benefits: true,
            priority_execution: true,
            custom_risk_limits: true,
            bespoke_product_creation: false,
            advanced_analytics_access: true,
            cross_protocol_exotic_access: true,
            exotic_yield_farming_access: true,
        });
        
        // Tier 5: Institutional exotic access
        table::add(&mut unxv_exotic_benefits, 5, ExoticTierBenefits {
            tier_level: 5,
            premium_discount: 6000, // 60%
            custom_payoff_access: true,
            structured_products_access: true,
            advanced_pricing_models: true,
            institutional_products: true,
            market_making_benefits: true,
            priority_execution: true,
            custom_risk_limits: true,
            bespoke_product_creation: true,
            advanced_analytics_access: true,
            cross_protocol_exotic_access: true,
            exotic_yield_farming_access: true,
        });
        
        let mut registry = ExoticDerivativesRegistry {
            id: object::new(ctx),
            supported_payoffs: table::new(ctx),
            active_products: table::new(ctx),
            custom_payoffs: table::new(ctx),
            pricing_engines: table::new(ctx),
            monte_carlo_configs: MonteCarloConfigs {
                default_paths: 10000,
                default_steps: 100,
                variance_reduction_enabled: true,
                parallel_processing: true,
            },
            greeks_engines: GreeksCalculationEngines {
                real_time_enabled: true,
                calculation_frequency: 300, // 5 minutes
                sensitivity_analysis_enabled: true,
            },
            exotic_risk_limits: ExoticRiskLimits {
                max_position_size: 1000000_000000, // 1M USDC
                max_portfolio_concentration: 2500, // 25%
                max_leverage_equivalent: 10000, // 100x
                stress_test_requirements: true,
            },
            exotic_market_makers: table::new(ctx),
            underlying_assets: table::new(ctx),
            settlement_mechanisms: SettlementMechanisms {
                cash_settlement_enabled: true,
                physical_settlement_enabled: false,
                automatic_settlement: true,
                settlement_lag: 3600, // 1 hour
            },
            unxv_exotic_benefits,
            emergency_settlement: false,
            admin_cap: option::some(admin_cap),
        };
        
        // Initialize supported payoffs
        initialize_payoff_structures(&mut registry, ctx);
        
        transfer::share_object(registry);
    }
    
    /// Initialize standard payoff structures
    fun initialize_payoff_structures(registry: &mut ExoticDerivativesRegistry, ctx: &mut TxContext) {
        // Knock-Out Call
        let mut ko_call_params = vector::empty<ParameterDefinition>();
        vector::push_back(&mut ko_call_params, ParameterDefinition {
            parameter_name: string::utf8(b"strike_price"),
            parameter_type: string::utf8(b"PRICE"),
            default_value: option::none(),
            description: string::utf8(b"Strike price for the call option"),
        });
        vector::push_back(&mut ko_call_params, ParameterDefinition {
            parameter_name: string::utf8(b"barrier_level"),
            parameter_type: string::utf8(b"PRICE"),
            default_value: option::none(),
            description: string::utf8(b"Knock-out barrier level"),
        });
        
        let ko_call_constraints = ParameterConstraints {
            min_values: table::new(ctx),
            max_values: table::new(ctx),
            valid_ranges: table::new(ctx),
        };
        
        let mut ko_call_risks = vector::empty<RiskFactor>();
        vector::push_back(&mut ko_call_risks, RiskFactor {
            factor_name: string::utf8(b"barrier_risk"),
            factor_type: string::utf8(b"KNOCKOUT"),
            impact_level: string::utf8(b"HIGH"),
            mitigation_required: true,
        });
        
        table::add(&mut registry.supported_payoffs, string::utf8(b"KO_CALL"), PayoffStructure {
            payoff_code: string::utf8(b"KO_CALL"),
            payoff_name: string::utf8(b"Knock-Out Call"),
            payoff_formula: string::utf8(b"max(0, S_T - K) if S_t < B for all t, else 0"),
            required_parameters: ko_call_params,
            parameter_constraints: ko_call_constraints,
            pricing_method: string::utf8(b"MONTE_CARLO"),
            computational_complexity: 300,
            risk_factors: ko_call_risks,
            max_leverage_equivalent: 1000, // 10x
            path_dependency: true,
            early_exercise: false,
            typical_bid_ask_spread: 200, // 2%
            institutional_focus: false,
        });
        
        // Knock-In Put
        let mut ki_put_params = vector::empty<ParameterDefinition>();
        vector::push_back(&mut ki_put_params, ParameterDefinition {
            parameter_name: string::utf8(b"strike_price"),
            parameter_type: string::utf8(b"PRICE"),
            default_value: option::none(),
            description: string::utf8(b"Strike price for the put option"),
        });
        vector::push_back(&mut ki_put_params, ParameterDefinition {
            parameter_name: string::utf8(b"barrier_level"),
            parameter_type: string::utf8(b"PRICE"),
            default_value: option::none(),
            description: string::utf8(b"Knock-in barrier level"),
        });
        
        let ki_put_constraints = ParameterConstraints {
            min_values: table::new(ctx),
            max_values: table::new(ctx),
            valid_ranges: table::new(ctx),
        };
        
        let mut ki_put_risks = vector::empty<RiskFactor>();
        vector::push_back(&mut ki_put_risks, RiskFactor {
            factor_name: string::utf8(b"activation_risk"),
            factor_type: string::utf8(b"KNOCKIN"),
            impact_level: string::utf8(b"MEDIUM"),
            mitigation_required: false,
        });
        
        table::add(&mut registry.supported_payoffs, string::utf8(b"KI_PUT"), PayoffStructure {
            payoff_code: string::utf8(b"KI_PUT"),
            payoff_name: string::utf8(b"Knock-In Put"),
            payoff_formula: string::utf8(b"max(0, K - S_T) if S_t <= B for any t, else 0"),
            required_parameters: ki_put_params,
            parameter_constraints: ki_put_constraints,
            pricing_method: string::utf8(b"MONTE_CARLO"),
            computational_complexity: 300,
            risk_factors: ki_put_risks,
            max_leverage_equivalent: 1000, // 10x
            path_dependency: true,
            early_exercise: false,
            typical_bid_ask_spread: 250, // 2.5%
            institutional_focus: false,
        });
        
        // Range Accrual
        let mut range_acc_params = vector::empty<ParameterDefinition>();
        vector::push_back(&mut range_acc_params, ParameterDefinition {
            parameter_name: string::utf8(b"range_lower"),
            parameter_type: string::utf8(b"PRICE"),
            default_value: option::none(),
            description: string::utf8(b"Lower bound of accrual range"),
        });
        vector::push_back(&mut range_acc_params, ParameterDefinition {
            parameter_name: string::utf8(b"range_upper"),
            parameter_type: string::utf8(b"PRICE"),
            default_value: option::none(),
            description: string::utf8(b"Upper bound of accrual range"),
        });
        vector::push_back(&mut range_acc_params, ParameterDefinition {
            parameter_name: string::utf8(b"coupon_rate"),
            parameter_type: string::utf8(b"PERCENTAGE"),
            default_value: option::some(500), // 5%
            description: string::utf8(b"Coupon rate per accrual period"),
        });
        
        let range_acc_constraints = ParameterConstraints {
            min_values: table::new(ctx),
            max_values: table::new(ctx),
            valid_ranges: table::new(ctx),
        };
        
        let mut range_acc_risks = vector::empty<RiskFactor>();
        vector::push_back(&mut range_acc_risks, RiskFactor {
            factor_name: string::utf8(b"range_breach_risk"),
            factor_type: string::utf8(b"RANGE_DEPENDENT"),
            impact_level: string::utf8(b"MEDIUM"),
            mitigation_required: false,
        });
        
        table::add(&mut registry.supported_payoffs, string::utf8(b"RANGE_ACC"), PayoffStructure {
            payoff_code: string::utf8(b"RANGE_ACC"),
            payoff_name: string::utf8(b"Range Accrual Note"),
            payoff_formula: string::utf8(b"Sum(c * 1_{L <= S_t <= U}) for each period t"),
            required_parameters: range_acc_params,
            parameter_constraints: range_acc_constraints,
            pricing_method: string::utf8(b"ANALYTICAL"),
            computational_complexity: 150,
            risk_factors: range_acc_risks,
            max_leverage_equivalent: 200, // 2x
            path_dependency: true,
            early_exercise: false,
            typical_bid_ask_spread: 100, // 1%
            institutional_focus: true,
        });
        
        // Power Perpetual
        let mut pwr_perp_params = vector::empty<ParameterDefinition>();
        vector::push_back(&mut pwr_perp_params, ParameterDefinition {
            parameter_name: string::utf8(b"power_exponent"),
            parameter_type: string::utf8(b"INTEGER"),
            default_value: option::some(2),
            description: string::utf8(b"Power exponent n for S^n exposure"),
        });
        
        let pwr_perp_constraints = ParameterConstraints {
            min_values: table::new(ctx),
            max_values: table::new(ctx),
            valid_ranges: table::new(ctx),
        };
        
        let mut pwr_perp_risks = vector::empty<RiskFactor>();
        vector::push_back(&mut pwr_perp_risks, RiskFactor {
            factor_name: string::utf8(b"convexity_risk"),
            factor_type: string::utf8(b"LEVERAGE_AMPLIFICATION"),
            impact_level: string::utf8(b"EXTREME"),
            mitigation_required: true,
        });
        vector::push_back(&mut pwr_perp_risks, RiskFactor {
            factor_name: string::utf8(b"funding_risk"),
            factor_type: string::utf8(b"PERPETUAL_FUNDING"),
            impact_level: string::utf8(b"HIGH"),
            mitigation_required: true,
        });
        
        table::add(&mut registry.supported_payoffs, string::utf8(b"PWR_PERP"), PayoffStructure {
            payoff_code: string::utf8(b"PWR_PERP"),
            payoff_name: string::utf8(b"Power Perpetual"),
            payoff_formula: string::utf8(b"funding_adjusted(S_t^n - S_0^n)"),
            required_parameters: pwr_perp_params,
            parameter_constraints: pwr_perp_constraints,
            pricing_method: string::utf8(b"ANALYTICAL"),
            computational_complexity: 400,
            risk_factors: pwr_perp_risks,
            max_leverage_equivalent: 10000, // 100x effective
            path_dependency: false,
            early_exercise: false,
            typical_bid_ask_spread: 300, // 3%
            institutional_focus: true,
        });
    }
    
    /// Create a new exotic options market for an underlying asset
    public fun create_exotic_options_market<T>(
        registry: &mut ExoticDerivativesRegistry,
        underlying_symbol: String,
        deepbook_pool_id: ID,
        balance_manager_id: ID,
        price_oracle_id: ID,
        _admin_cap: &AdminCap,
        ctx: &mut TxContext,
    ): ID {
        let mut supported_payoffs = vec_set::empty<String>();
        vec_set::insert(&mut supported_payoffs, string::utf8(b"KO_CALL"));
        vec_set::insert(&mut supported_payoffs, string::utf8(b"KI_PUT"));
        vec_set::insert(&mut supported_payoffs, string::utf8(b"RANGE_ACC"));
        vec_set::insert(&mut supported_payoffs, string::utf8(b"PWR_PERP"));
        
        let market = ExoticOptionsMarket<T> {
            id: object::new(ctx),
            underlying_asset: underlying_symbol,
            supported_payoffs,
            long_positions: table::new(ctx),
            short_positions: table::new(ctx),
            market_maker_positions: table::new(ctx),
            pricing_engine: PricingEngineInstance {
                engine_id: object::id_from_address(@0x0),
                engine_type: string::utf8(b"MONTE_CARLO"),
                last_update: 0,
                accuracy_score: 95,
            },
            real_time_greeks: RealTimeGreeks {
                last_calculation: 0,
                calculation_frequency: 300,
                accuracy_level: 90,
            },
            implied_volatility_surface: VolatilitySurface {
                surface_points: vector::empty(),
                last_updated: 0,
                interpolation_method: string::utf8(b"CUBIC_SPLINE"),
            },
            order_book: ExoticOrderBook {
                bid_orders: vector::empty(),
                ask_orders: vector::empty(),
                last_trade_price: 0,
                spread: 0,
            },
            market_maker_quotes: table::new(ctx),
            recent_trades: vector::empty(),
            position_limits: PositionLimits {
                max_single_position: 100000_000000, // 100k USDC
                max_total_exposure: 1000000_000000, // 1M USDC
                concentration_limit: 2500, // 25%
            },
            exposure_tracking: ExposureTracking {
                total_long_exposure: 0,
                total_short_exposure: 0,
                net_exposure: signed_int_from(0),
                last_updated: 0,
            },
            margin_requirements: MarginRequirements {
                initial_margin_rate: 1500, // 15%
                maintenance_margin_rate: 1000, // 10%
                stress_test_margin: 2000, // 20%
            },
            volatility_estimates: VolatilityEstimates {
                historical_vol: 25_000000, // 25%
                implied_vol: 25_000000, // 25%
                realized_vol: 25_000000, // 25%
                vol_forecast: 25_000000, // 25%
            },
            risk_free_rate: 300, // 3%
            dividend_yield: 0,
            settlement_queue: vector::empty(),
            settlement_prices: table::new(ctx),
            deepbook_pool_id,
            balance_manager_id,
            price_oracle_id,
        };
        
        let market_id = object::id(&market);
        transfer::share_object(market);
        market_id
    }
    
    /// Open a knock-out call position
    public fun open_knockout_call<T>(
        market: &mut ExoticOptionsMarket<T>,
        registry: &ExoticDerivativesRegistry,
        strike_price: u64,
        barrier_level: u64,
        expiration: u64,
        quantity: u64,
        max_premium: u64,
        unxv_staked: u64,
        balance_manager: &mut BalanceManager,
        premium_payment: Coin<USDC>,
        price_oracle: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (ExoticPosition, KnockoutCallResult) {
        // Validate parameters
        assert!(vec_set::contains(&market.supported_payoffs, &string::utf8(b"KO_CALL")), E_PAYOFF_NOT_SUPPORTED);
        assert!(strike_price > 0 && barrier_level > 0, E_INVALID_PARAMETERS);
        assert!(quantity > 0, E_INVALID_PARAMETERS);
        assert!(expiration > clock::timestamp_ms(clock), E_OPTION_EXPIRED);
        
        // Get current price from Pyth oracle
        let price_struct = pyth::get_price_no_older_than(price_oracle, clock, MAX_PRICE_AGE);
        let price_i64 = price::get_price(&price_struct);
        let current_price = pyth_i64::get_magnitude_if_positive(&price_i64);
        
        // Validate barrier distance
        let barrier_distance = if (current_price > barrier_level) {
            current_price - barrier_level
        } else {
            barrier_level - current_price
        };
        assert!(barrier_distance * BASIS_POINTS / current_price >= MIN_BARRIER_DISTANCE, E_INVALID_PARAMETERS);
        
        // Calculate tier and effective costs
        let tier_level = calculate_unxv_tier(unxv_staked);
        let tier_benefits = table::borrow(&registry.unxv_exotic_benefits, tier_level);
        
        // Price the knock-out call
        let ko_call_premium = price_knockout_call(
            current_price,
            strike_price,
            barrier_level,
            expiration,
            market.volatility_estimates.implied_vol,
            market.risk_free_rate,
            quantity
        );
        
        // Apply UNXV discount
        let effective_premium = ko_call_premium * (BASIS_POINTS - tier_benefits.premium_discount) / BASIS_POINTS;
        assert!(effective_premium <= max_premium, E_INSUFFICIENT_PREMIUM);
        
        // Validate premium payment
        assert!(coin::value(&premium_payment) >= effective_premium, E_INSUFFICIENT_BALANCE);
        
        // Create custom parameters
        let mut custom_parameters = table::new<String, u64>(ctx);
        table::add(&mut custom_parameters, string::utf8(b"strike_price"), strike_price);
        table::add(&mut custom_parameters, string::utf8(b"barrier_level"), barrier_level);
        
        // Create barrier monitoring
        let mut barrier_levels = vector::empty<u64>();
        vector::push_back(&mut barrier_levels, barrier_level);
        let mut barrier_hit = vector::empty<bool>();
        vector::push_back(&mut barrier_hit, false);
        let mut hit_timestamps = vector::empty<Option<u64>>();
        vector::push_back(&mut hit_timestamps, option::none());
        
        let barrier_monitoring = BarrierMonitoring {
            barrier_type: string::utf8(b"KNOCK_OUT"),
            barrier_levels,
            barrier_hit,
            hit_timestamps,
            monitoring_frequency: 300000, // 5 minutes
            current_status: string::utf8(b"ACTIVE"),
        };
        
        // Calculate initial Greeks
        let greeks = calculate_knockout_call_greeks(
            current_price,
            strike_price,
            barrier_level,
            expiration,
            market.volatility_estimates.implied_vol,
            market.risk_free_rate
        );
        
        // Create position
        let position = ExoticPosition {
            id: object::new(ctx),
            user: tx_context::sender(ctx),
            payoff_code: string::utf8(b"KO_CALL"),
            side: string::utf8(b"LONG"),
            quantity,
            entry_price: effective_premium,
            strike_price: option::some(strike_price),
            barrier_levels: vector::singleton(barrier_level),
            coupon_rate: option::none(),
            power_exponent: option::none(),
            custom_parameters,
            payoff_info: PayoffInfo {
                payoff_code: string::utf8(b"KO_CALL"),
                payoff_name: string::utf8(b"Knock-Out Call"),
                pricing_method: string::utf8(b"MONTE_CARLO"),
                path_dependency: true,
                max_leverage_equivalent: 1000,
            },
            current_pnl: signed_int_from(0),
            maximum_loss: effective_premium,
            greeks,
            barrier_monitoring,
            accrual_tracking: AccrualTracking {
                accrual_periods: vector::empty(),
                total_accrued: 0,
                current_period: 0,
                accrual_rate: 0,
                range_boundaries: RangeBoundaries {
                    range_lower: 0,
                    range_upper: 0,
                    range_width: 0,
                },
            },
            created_timestamp: clock::timestamp_ms(clock),
            expiration_timestamp: expiration,
            early_exercise_allowed: false,
            auto_exercise_enabled: true,
            stop_loss_level: option::none(),
            take_profit_level: option::none(),
        };
        
        let position_id = object::id(&position);
        
        // Calculate vanilla call premium for comparison
        let vanilla_call_premium = price_vanilla_call(
            current_price,
            strike_price,
            expiration,
            market.volatility_estimates.implied_vol,
            market.risk_free_rate,
            quantity
        );
        
        // Calculate knockout probability
        let knockout_probability = calculate_knockout_probability(
            current_price,
            barrier_level,
            expiration,
            market.volatility_estimates.implied_vol
        );
        
        // Create result
        let result = KnockoutCallResult {
            position_id,
            ko_call_premium: effective_premium,
            vanilla_call_premium,
            discount_vs_vanilla: vanilla_call_premium - effective_premium,
            knockout_probability,
            survival_probability: BASIS_POINTS - knockout_probability,
            expected_payoff: calculate_expected_payoff_ko_call(
                current_price,
                strike_price,
                barrier_level,
                market.volatility_estimates.implied_vol,
                expiration
            ),
            barrier_level,
            distance_to_barrier: barrier_distance,
            barrier_monitoring_frequency: 300000, // 5 minutes
            risk_warnings: vector::singleton(string::utf8(b"Position will expire worthless if barrier is hit")),
        };
        
        // Handle premium payment
        transfer::public_transfer(premium_payment, @0x0); // Send to treasury
        
        // Emit event
        event::emit(ExoticPositionOpened {
            position_id,
            user: tx_context::sender(ctx),
            payoff_code: string::utf8(b"KO_CALL"),
            underlying_asset: market.underlying_asset,
            side: string::utf8(b"LONG"),
            quantity,
            entry_price: effective_premium,
            expiration_timestamp: expiration,
            maximum_loss: effective_premium,
            probability_profit: result.survival_probability,
            entry_greeks: greeks,
            timestamp: clock::timestamp_ms(clock),
        });
        
        (position, result)
    }
    
    /// Create a range accrual note
    public fun create_range_accrual_note<T>(
        market: &mut ExoticOptionsMarket<T>,
        registry: &ExoticDerivativesRegistry,
        range_lower: u64,
        range_upper: u64,
        coupon_rate: u64,
        accrual_frequency: u64,
        maturity: u64,
        notional_amount: u64,
        unxv_staked: u64,
        note_payment: Coin<USDC>,
        price_oracle: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (ExoticPosition, RangeAccrualResult) {
        // Validate parameters
        assert!(vec_set::contains(&market.supported_payoffs, &string::utf8(b"RANGE_ACC")), E_PAYOFF_NOT_SUPPORTED);
        assert!(range_upper > range_lower, E_INVALID_PARAMETERS);
        assert!(notional_amount > 0, E_INVALID_PARAMETERS);
        assert!(maturity > clock::timestamp_ms(clock), E_OPTION_EXPIRED);
        
        // Validate range width
        let range_width = range_upper - range_lower;
        let range_midpoint = (range_upper + range_lower) / 2;
        assert!(range_width * BASIS_POINTS / range_midpoint >= MIN_RANGE_WIDTH, E_INVALID_PARAMETERS);
        
        // Get current price from Pyth oracle
        let price_struct = pyth::get_price_no_older_than(price_oracle, clock, MAX_PRICE_AGE);
        let price_i64 = price::get_price(&price_struct);
        let current_price = pyth_i64::get_magnitude_if_positive(&price_i64);
        
        // Calculate tier and effective costs
        let tier_level = calculate_unxv_tier(unxv_staked);
        let tier_benefits = table::borrow(&registry.unxv_exotic_benefits, tier_level);
        
        // Price the range accrual note
        let note_price = price_range_accrual_note(
            current_price,
            range_lower,
            range_upper,
            coupon_rate,
            maturity,
            market.volatility_estimates.implied_vol,
            market.risk_free_rate,
            notional_amount
        );
        
        // Apply UNXV discount
        let effective_price = note_price * (BASIS_POINTS - tier_benefits.premium_discount) / BASIS_POINTS;
        
        // Validate payment
        assert!(coin::value(&note_payment) >= effective_price, E_INSUFFICIENT_BALANCE);
        
        // Create custom parameters
        let mut custom_parameters = table::new<String, u64>(ctx);
        table::add(&mut custom_parameters, string::utf8(b"range_lower"), range_lower);
        table::add(&mut custom_parameters, string::utf8(b"range_upper"), range_upper);
        table::add(&mut custom_parameters, string::utf8(b"coupon_rate"), coupon_rate);
        table::add(&mut custom_parameters, string::utf8(b"accrual_frequency"), accrual_frequency);
        
        // Create accrual tracking
        let accrual_tracking = AccrualTracking {
            accrual_periods: vector::empty(),
            total_accrued: 0,
            current_period: 0,
            accrual_rate: coupon_rate,
            range_boundaries: RangeBoundaries {
                range_lower,
                range_upper,
                range_width,
            },
        };
        
        // Calculate Greeks (simplified for range accrual)
        let greeks = PositionGreeks {
            delta: signed_int_from(0),
            gamma: signed_int_from(0),
            theta: signed_int_negative(effective_price / ((maturity - clock::timestamp_ms(clock)) / 86400000)), // Daily theta
            vega: signed_int_from(effective_price / 100), // Simplified vega
            rho: signed_int_from(effective_price / 200), // Simplified rho
            exotic_greeks: vector::empty(),
        };
        
        // Create position
        let position = ExoticPosition {
            id: object::new(ctx),
            user: tx_context::sender(ctx),
            payoff_code: string::utf8(b"RANGE_ACC"),
            side: string::utf8(b"LONG"),
            quantity: notional_amount,
            entry_price: effective_price,
            strike_price: option::none(),
            barrier_levels: vector::empty(),
            coupon_rate: option::some(coupon_rate),
            power_exponent: option::none(),
            custom_parameters,
            payoff_info: PayoffInfo {
                payoff_code: string::utf8(b"RANGE_ACC"),
                payoff_name: string::utf8(b"Range Accrual Note"),
                pricing_method: string::utf8(b"ANALYTICAL"),
                path_dependency: true,
                max_leverage_equivalent: 200,
            },
            current_pnl: signed_int_from(0),
            maximum_loss: effective_price,
            greeks,
            barrier_monitoring: BarrierMonitoring {
                barrier_type: string::utf8(b"NONE"),
                barrier_levels: vector::empty(),
                barrier_hit: vector::empty(),
                hit_timestamps: vector::empty(),
                monitoring_frequency: 0,
                current_status: string::utf8(b"INACTIVE"),
            },
            accrual_tracking,
            created_timestamp: clock::timestamp_ms(clock),
            expiration_timestamp: maturity,
            early_exercise_allowed: false,
            auto_exercise_enabled: true,
            stop_loss_level: option::none(),
            take_profit_level: option::none(),
        };
        
        let position_id = object::id(&position);
        
        // Calculate expected metrics
        let time_to_maturity = maturity - clock::timestamp_ms(clock);
        let accrual_periods = time_to_maturity / accrual_frequency;
        let expected_coupons = calculate_expected_coupons(
            current_price,
            range_lower,
            range_upper,
            coupon_rate,
            accrual_periods,
            market.volatility_estimates.implied_vol
        );
        let maximum_coupons = coupon_rate * accrual_periods;
        
        // Calculate historical time in range (simplified)
        let historical_time_in_range = 6000; // 60% as example
        
        // Calculate probability of being in range
        let probability_in_range = calculate_range_probability(
            current_price,
            range_lower,
            range_upper,
            market.volatility_estimates.implied_vol,
            time_to_maturity
        );
        
        // Calculate distance to bounds
        let distance_to_bounds = RangeDistance {
            distance_to_lower: if (current_price > range_lower) { current_price - range_lower } else { 0 },
            distance_to_upper: if (current_price < range_upper) { range_upper - current_price } else { 0 },
            buffer_percentage: range_width * BASIS_POINTS / current_price / 2,
        };
        
        // Create accrual calendar
        let mut accrual_calendar = vector::empty<u64>();
        let mut i = 0;
        while (i < accrual_periods) {
            vector::push_back(&mut accrual_calendar, clock::timestamp_ms(clock) + (i + 1) * accrual_frequency);
            i = i + 1;
        };
        
        // Create result
        let result = RangeAccrualResult {
            position_id,
            note_price: effective_price,
            expected_coupons,
            maximum_coupons,
            probability_in_range,
            range_width,
            current_price,
            distance_to_bounds,
            historical_time_in_range,
            accrual_periods,
            accrual_calendar,
            first_accrual_date: clock::timestamp_ms(clock) + accrual_frequency,
        };
        
        // Handle payment
        transfer::public_transfer(note_payment, @0x0); // Send to treasury
        
        // Emit event
        event::emit(ExoticPositionOpened {
            position_id,
            user: tx_context::sender(ctx),
            payoff_code: string::utf8(b"RANGE_ACC"),
            underlying_asset: market.underlying_asset,
            side: string::utf8(b"LONG"),
            quantity: notional_amount,
            entry_price: effective_price,
            expiration_timestamp: maturity,
            maximum_loss: effective_price,
            probability_profit: probability_in_range,
            entry_greeks: greeks,
            timestamp: clock::timestamp_ms(clock),
        });
        
        (position, result)
    }
    
    /// Calculate UNXV tier based on staked amount
    public fun calculate_unxv_tier(unxv_staked: u64): u64 {
        if (unxv_staked >= TIER_5_THRESHOLD) {
            5
        } else if (unxv_staked >= TIER_4_THRESHOLD) {
            4
        } else if (unxv_staked >= TIER_3_THRESHOLD) {
            3
        } else if (unxv_staked >= TIER_2_THRESHOLD) {
            2
        } else if (unxv_staked >= TIER_1_THRESHOLD) {
            1
        } else {
            0
        }
    }
    
    /// Calculate effective exotic costs with UNXV benefits
    public fun calculate_effective_exotic_costs(
        registry: &ExoticDerivativesRegistry,
        unxv_staked: u64,
        base_premium: u64,
        complexity_multiplier: u64,
        market_making_rebates: u64,
    ): EffectiveExoticCosts {
        let tier_level = calculate_unxv_tier(unxv_staked);
        let tier_benefits = table::borrow(&registry.unxv_exotic_benefits, tier_level);
        
        let unxv_discount = base_premium * tier_benefits.premium_discount / BASIS_POINTS;
        let complexity_adjustment = base_premium * complexity_multiplier / BASIS_POINTS;
        let net_premium = base_premium - unxv_discount + complexity_adjustment - market_making_rebates;
        
        let total_savings_percentage = if (base_premium > 0) {
            (unxv_discount + market_making_rebates) * BASIS_POINTS / base_premium
        } else {
            0
        };
        
        let mut exclusive_features_unlocked = vector::empty<String>();
        if (tier_benefits.custom_payoff_access) {
            vector::push_back(&mut exclusive_features_unlocked, string::utf8(b"Custom Payoff Creation"));
        };
        if (tier_benefits.structured_products_access) {
            vector::push_back(&mut exclusive_features_unlocked, string::utf8(b"Structured Products"));
        };
        if (tier_benefits.institutional_products) {
            vector::push_back(&mut exclusive_features_unlocked, string::utf8(b"Institutional Products"));
        };
        
        EffectiveExoticCosts {
            tier_level,
            original_premium: base_premium,
            unxv_discount,
            complexity_adjustment,
            market_making_rebate: market_making_rebates,
            net_premium,
            total_savings_percentage,
            exclusive_features_unlocked,
        }
    }
    
    // ========== Pricing Functions ==========
    
    /// Price a knock-out call option (simplified implementation)
    fun price_knockout_call(
        spot_price: u64,
        strike: u64,
        barrier: u64,
        expiry: u64,
        volatility: u64,
        risk_free_rate: u64,
        quantity: u64,
    ): u64 {
        // Simplified pricing - in production would use Monte Carlo or analytical formulas
        let vanilla_call_price = price_vanilla_call(spot_price, strike, expiry, volatility, risk_free_rate, quantity);
        let knockout_discount = calculate_knockout_probability(spot_price, barrier, expiry, volatility);
        vanilla_call_price * (BASIS_POINTS - knockout_discount) / BASIS_POINTS
    }
    
    /// Price a vanilla call option (Black-Scholes simplified)
    fun price_vanilla_call(
        spot_price: u64,
        strike: u64,
        expiry: u64,
        volatility: u64,
        risk_free_rate: u64,
        quantity: u64,
    ): u64 {
        // Simplified Black-Scholes implementation
        let time_to_expiry = 365 * 24 * 60 * 60 * 1000; // 1 year in milliseconds
        let intrinsic_value = if (spot_price > strike) { spot_price - strike } else { 0 };
        let time_value = (spot_price * volatility * time_to_expiry) / (100 * VOLATILITY_PRECISION);
        (intrinsic_value + time_value) * quantity / PRICE_PRECISION
    }
    
    /// Price a range accrual note
    fun price_range_accrual_note(
        spot_price: u64,
        range_lower: u64,
        range_upper: u64,
        coupon_rate: u64,
        maturity: u64,
        volatility: u64,
        risk_free_rate: u64,
        notional: u64,
    ): u64 {
        // Simplified pricing based on probability of staying in range
        let range_probability = calculate_range_probability(spot_price, range_lower, range_upper, volatility, maturity);
        let expected_coupon = coupon_rate * range_probability / BASIS_POINTS;
        notional * (BASIS_POINTS + expected_coupon) / BASIS_POINTS
    }
    
    /// Calculate knockout probability
    fun calculate_knockout_probability(
        spot_price: u64,
        barrier: u64,
        expiry: u64,
        volatility: u64,
    ): u64 {
        // Simplified calculation - in production would use proper barrier option formulas
        if (spot_price <= barrier) {
            10000 // 100% if already at barrier
        } else {
            let distance_ratio = (spot_price - barrier) * BASIS_POINTS / spot_price;
            let time_factor = expiry / (365 * 24 * 60 * 60 * 1000); // Years
            let vol_factor = volatility * time_factor / VOLATILITY_PRECISION;
            
            // Simplified probability calculation
            if (distance_ratio < vol_factor) {
                vol_factor - distance_ratio
            } else {
                vol_factor / 2
            }
        }
    }
    
    /// Calculate range probability
    fun calculate_range_probability(
        spot_price: u64,
        range_lower: u64,
        range_upper: u64,
        volatility: u64,
        time_to_expiry: u64,
    ): u64 {
        // Simplified calculation for probability of staying in range
        let range_center = (range_lower + range_upper) / 2;
        let range_width = range_upper - range_lower;
        
        if (spot_price >= range_lower && spot_price <= range_upper) {
            // Currently in range
            let distance_from_center = if (spot_price > range_center) {
                spot_price - range_center
            } else {
                range_center - spot_price
            };
            
            let normalized_distance = distance_from_center * BASIS_POINTS / range_width;
            let time_factor = time_to_expiry / (365 * 24 * 60 * 60 * 1000);
            let vol_impact = volatility * time_factor / VOLATILITY_PRECISION;
            
            if (normalized_distance < vol_impact) {
                BASIS_POINTS - normalized_distance
            } else {
                BASIS_POINTS - vol_impact
            }
        } else {
            // Currently outside range
            2000 // 20% probability
        }
    }
    
    /// Calculate expected payoff for knock-out call
    fun calculate_expected_payoff_ko_call(
        spot_price: u64,
        strike: u64,
        barrier: u64,
        volatility: u64,
        expiry: u64,
    ): u64 {
        let survival_prob = BASIS_POINTS - calculate_knockout_probability(spot_price, barrier, expiry, volatility);
        let expected_spot_at_expiry = spot_price; // Simplified - would use drift in practice
        
        if (expected_spot_at_expiry > strike) {
            (expected_spot_at_expiry - strike) * survival_prob / BASIS_POINTS
        } else {
            0
        }
    }
    
    /// Calculate expected coupons for range accrual
    fun calculate_expected_coupons(
        spot_price: u64,
        range_lower: u64,
        range_upper: u64,
        coupon_rate: u64,
        accrual_periods: u64,
        volatility: u64,
    ): u64 {
        let single_period_probability = calculate_range_probability(
            spot_price,
            range_lower,
            range_upper,
            volatility,
            86400000 * 30 // 30 days
        );
        
        coupon_rate * accrual_periods * single_period_probability / BASIS_POINTS
    }
    
    /// Calculate Greeks for knock-out call
    fun calculate_knockout_call_greeks(
        spot_price: u64,
        strike: u64,
        barrier: u64,
        expiry: u64,
        volatility: u64,
        risk_free_rate: u64,
    ): PositionGreeks {
        // Simplified Greeks calculation
        let delta_value = if (spot_price > strike && spot_price > barrier) {
            5000 // 0.5 simplified delta
        } else {
            1000 // 0.1 simplified delta
        };
        
        PositionGreeks {
            delta: signed_int_from(delta_value),
            gamma: signed_int_from(100), // Simplified gamma
            theta: signed_int_negative(50), // Time decay
            vega: signed_int_from(200), // Volatility sensitivity
            rho: signed_int_from(100), // Interest rate sensitivity
            exotic_greeks: vector::empty(),
        }
    }
    
    // ========== Test Helper Functions ==========
    
    #[test_only]
    /// Initialize the module for testing
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
    
    #[test_only]
    /// Test helper to create a registry
    public fun create_test_registry(ctx: &mut TxContext): ExoticDerivativesRegistry {
        let mut unxv_exotic_benefits = table::new<u64, ExoticTierBenefits>(ctx);
        table::add(&mut unxv_exotic_benefits, 0, ExoticTierBenefits {
            tier_level: 0,
            premium_discount: 0,
            custom_payoff_access: false,
            structured_products_access: false,
            advanced_pricing_models: false,
            institutional_products: false,
            market_making_benefits: false,
            priority_execution: false,
            custom_risk_limits: false,
            bespoke_product_creation: false,
            advanced_analytics_access: false,
            cross_protocol_exotic_access: false,
            exotic_yield_farming_access: false,
        });
        
        ExoticDerivativesRegistry {
            id: object::new(ctx),
            supported_payoffs: table::new(ctx),
            active_products: table::new(ctx),
            custom_payoffs: table::new(ctx),
            pricing_engines: table::new(ctx),
            monte_carlo_configs: MonteCarloConfigs {
                default_paths: 1000,
                default_steps: 50,
                variance_reduction_enabled: false,
                parallel_processing: false,
            },
            greeks_engines: GreeksCalculationEngines {
                real_time_enabled: false,
                calculation_frequency: 3600,
                sensitivity_analysis_enabled: false,
            },
            exotic_risk_limits: ExoticRiskLimits {
                max_position_size: 10000_000000,
                max_portfolio_concentration: 5000,
                max_leverage_equivalent: 1000,
                stress_test_requirements: false,
            },
            exotic_market_makers: table::new(ctx),
            underlying_assets: table::new(ctx),
            settlement_mechanisms: SettlementMechanisms {
                cash_settlement_enabled: true,
                physical_settlement_enabled: false,
                automatic_settlement: false,
                settlement_lag: 0,
            },
            unxv_exotic_benefits,
            emergency_settlement: false,
            admin_cap: option::none(),
        }
    }
    
    #[test_only]
    /// Test helper to get position details
    public fun get_position_details(position: &ExoticPosition): (String, String, u64, u64) {
        (position.payoff_code, position.side, position.quantity, position.entry_price)
    }
    
    #[test_only]
    /// Test helper to get position PnL
    public fun get_position_pnl(position: &ExoticPosition): SignedInt {
        position.current_pnl
    }
    
    #[test_only]
    /// Test helper to check emergency settlement status
    public fun emergency_settlement(registry: &ExoticDerivativesRegistry): bool {
        registry.emergency_settlement
    }
    
    #[test_only]
    /// Test helper to expose knockout probability calculation for testing
    public fun test_calculate_knockout_probability(
        spot_price: u64,
        barrier: u64,
        expiry: u64,
        volatility: u64,
    ): u64 {
        // Call the internal function
        calculate_knockout_probability(spot_price, barrier, expiry, volatility)
    }
    
    #[test_only]
    /// Test helper to expose range probability calculation for testing
    public fun test_calculate_range_probability(
        spot_price: u64,
        range_lower: u64,
        range_upper: u64,
        volatility: u64,
        time_to_expiry: u64,
    ): u64 {
        // Call the internal function
        calculate_range_probability(spot_price, range_lower, range_upper, volatility, time_to_expiry)
    }
    
    #[test_only]
    /// Test helper to access KnockoutCallResult fields
    public fun get_knockout_call_result_details(result: &KnockoutCallResult): (u64, u64, u64, u64, u64) {
        (
            result.barrier_level,
            result.survival_probability,
            result.knockout_probability,
            result.vanilla_call_premium,
            result.discount_vs_vanilla
        )
    }
    
    #[test_only]
    /// Test helper to access RangeAccrualResult fields
    public fun get_range_accrual_result_details(result: &RangeAccrualResult): (u64, u64, u64, u64) {
        (
            result.range_width,
            result.current_price,
            result.probability_in_range,
            result.accrual_periods
        )
    }
    
    #[test_only]
    /// Test helper to access EffectiveExoticCosts fields
    public fun get_effective_exotic_costs_details(costs: &EffectiveExoticCosts): (u64, u64, u64, u64, u64, u64, u64) {
        (
            costs.tier_level,
            costs.original_premium,
            costs.unxv_discount,
            costs.complexity_adjustment,
            costs.market_making_rebate,
            costs.net_premium,
            costs.total_savings_percentage
        )
    }
    
    #[test_only]
    /// Test helper to access SignedInt fields
    public fun get_signed_int_value(signed_int: &SignedInt): u64 {
        signed_int.value
    }
    
    #[test_only]
    /// Test helper to access SignedInt negative flag
    public fun get_signed_int_is_negative(signed_int: &SignedInt): bool {
        signed_int.is_negative
    }
    
}


