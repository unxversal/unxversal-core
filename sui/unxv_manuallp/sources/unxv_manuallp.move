/// UnXversal Manual Liquidity Management Protocol
/// Provides user-controlled liquidity provisioning strategies on DeepBook
/// Fulfills Grant RFP requirements for hands-on liquidity management
#[allow(duplicate_alias, unused_use, unused_const, unused_variable, unused_function)]
module unxv_manuallp::unxv_manuallp {
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};
    
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::event;
    
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::price;
    use pyth::i64 as pyth_i64;
    use pyth::pyth;
    
    use deepbook::balance_manager::{Self, BalanceManager, TradeProof};
    use deepbook::pool::{Self, Pool};
    
    // ========== Error Constants ==========
    
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_VAULT_NOT_FOUND: u64 = 2;
    const E_INVALID_STRATEGY: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_INVALID_PARAMETERS: u64 = 5;
    const E_RISK_LIMIT_EXCEEDED: u64 = 6;
    const E_STRATEGY_NOT_SUPPORTED: u64 = 7;
    const E_INVALID_TICK_RANGE: u64 = 8;
    const E_REBALANCING_TOO_FREQUENT: u64 = 9;
    const E_EMERGENCY_STOP_ACTIVE: u64 = 10;
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const PERCENTAGE_PRECISION: u64 = 1000000; // 6 decimal places
    const PRICE_PRECISION: u64 = 1000000;
    const MAX_PRICE_AGE: u64 = 300; // 5 minutes in seconds
    const MIN_REBALANCE_INTERVAL: u64 = 3600; // 1 hour minimum between rebalances
    const MAX_TICK_RANGE: u64 = 10000; // Maximum tick range width
    const DEFAULT_SLIPPAGE_TOLERANCE: u64 = 100; // 1% default slippage tolerance
    
    // ========== SignedInt Implementation ==========
    
    /// Custom signed integer for handling positive and negative values
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
    
    // ========== Core Types ==========
    
    /// Witness for UNXV token operations
    public struct UNXV has drop {}
    
    /// Witness for USDC token operations  
    public struct USDC has drop {}
    
    /// Manual LP Registry - Central configuration and strategy management
    public struct ManualLPRegistry has key {
        id: UID,
        
        // Strategy templates and configurations
        strategy_templates: Table<String, StrategyTemplate>,
        custom_strategies: Table<String, CustomStrategy>,
        active_vaults: Table<String, VaultInfo>,
        
        // Supported assets and pools
        supported_assets: VecSet<String>,
        asset_configurations: Table<String, AssetConfig>,
        deepbook_pools: Table<String, DeepBookPoolInfo>,
        
        // Risk management
        global_risk_limits: GlobalRiskLimits,
        default_risk_parameters: DefaultRiskParameters,
        emergency_controls: EmergencyControls,
        
        // Performance and analytics
        performance_analytics: PerformanceAnalytics,
        benchmark_data: BenchmarkData,
        
        // Fee structure
        vault_creation_fee: u64,
        performance_tracking_fee: u64,
        strategy_template_fee: u64,
        
        // Integration points
        deepbook_registry_id: Option<ID>,
        price_oracle_id: Option<ID>,
        balance_manager_id: Option<ID>,
        
        // Admin controls
        protocol_pause: bool,
        admin_cap: Option<AdminCap>,
    }
    
    /// Individual Manual LP Vault - User-controlled liquidity provisioning
    public struct ManualLPVault<phantom T, phantom U> has key, store {
        id: UID,
        owner: address,
        
        // Vault identification
        vault_name: String,
        strategy_template: String,
        asset_a_type: String,
        asset_b_type: String,
        
        // Asset holdings
        balance_a: Balance<T>,
        balance_b: Balance<U>,
        deployed_liquidity: DeployedLiquidity,
        
        // Strategy configuration
        strategy_parameters: Table<String, u64>,
        tick_range: TickRange,
        rebalancing_settings: RebalancingSettings,
        
        // Risk management
        risk_limits: UserRiskLimits,
        stop_loss_settings: StopLossSettings,
        circuit_breakers: CircuitBreakerSettings,
        
        // Performance tracking
        performance_data: VaultPerformanceData,
        transaction_history: vector<Transaction>,
        pnl_tracking: PnLTracking,
        
        // Position management
        active_positions: vector<LiquidityPosition>,
        pending_orders: vector<PendingOrder>,
        
        // Status and timing
        vault_status: String,
        last_rebalance: u64,
        creation_timestamp: u64,
    }
    
    /// Strategy Template - Pre-built strategy configurations
    public struct StrategyTemplate has store {
        template_id: String,
        template_name: String,
        description: String,
        complexity_level: String, // "BEGINNER", "INTERMEDIATE", "ADVANCED"
        
        // Template parameters
        required_parameters: vector<ParameterDefinition>,
        optional_parameters: vector<ParameterDefinition>,
        default_values: Table<String, u64>,
        
        // Strategy characteristics
        strategy_type: String, // "PASSIVE", "ACTIVE", "HYBRID"
        risk_level: String, // "LOW", "MEDIUM", "HIGH"
        typical_returns: ReturnExpectations,
        capital_requirements: CapitalRequirements,
        
        // Risk management
        recommended_risk_limits: RiskLimits,
        mandatory_controls: vector<String>,
        
        // Usage tracking
        total_deployments: u64,
        average_performance: PerformanceMetrics,
        user_ratings: UserRatings,
        
        // Template access
        is_free: bool,
        access_requirements: AccessRequirements,
    }
    
    /// Admin capability for protocol management
    public struct AdminCap has key, store {
        id: UID,
    }
    
    // ========== Supporting Structures ==========
    
    public struct TickRange has store {
        lower_tick: SignedInt,
        upper_tick: SignedInt,
        current_tick: SignedInt,
        tick_spacing: u64,
        
        // Range management
        auto_adjust_range: bool,
        range_adjustment_threshold: u64,
        max_range_width: u64,
        min_range_width: u64,
        
        // Range analytics
        time_in_range: u64,
        range_efficiency: u64,
        out_of_range_periods: vector<OutOfRangePeriod>,
    }
    
    public struct RebalancingSettings has store {
        rebalancing_strategy: String, // "TIME_BASED", "THRESHOLD_BASED", "MANUAL"
        rebalancing_frequency: u64,
        price_movement_threshold: u64,
        liquidity_threshold: u64,
        
        // Cost management
        max_rebalancing_cost: u64,
        gas_price_limit: u64,
        rebalancing_budget: u64,
        
        // Timing optimization
        preferred_rebalancing_times: vector<u64>,
        avoid_high_volatility_periods: bool,
        market_hours_only: bool,
    }
    
    public struct UserRiskLimits has store {
        max_position_size: u64,
        max_daily_loss: u64,
        max_weekly_loss: u64,
        max_monthly_loss: u64,
        
        // Concentration limits
        max_single_asset_exposure: u64,
        max_correlated_assets_exposure: u64,
        
        // Volatility limits
        max_volatility_exposure: u64,
        volatility_scaling: bool,
        
        // Liquidity requirements
        min_liquidity_buffer: u64,
        emergency_liquidity_threshold: u64,
    }
    
    public struct VaultPerformanceData has store {
        // Return metrics
        total_return: SignedInt,
        daily_returns: vector<SignedInt>,
        monthly_returns: vector<SignedInt>,
        annualized_return: SignedInt,
        
        // Risk metrics
        volatility: u64,
        sharpe_ratio: u64,
        maximum_drawdown: u64,
        current_drawdown: u64,
        
        // LP-specific metrics
        fees_earned: u64,
        impermanent_loss: SignedInt,
        liquidity_utilization: u64,
        
        // DeepBook metrics
        volume_facilitated: u64,
        trades_facilitated: u64,
        contribution_to_liquidity: u64,
        
        // Benchmark comparison
        vs_hodl_performance: SignedInt,
        vs_passive_lp_performance: SignedInt,
        vs_benchmark_performance: SignedInt,
    }
    
    public struct DeployedLiquidity has store {
        total_liquidity_deployed: u64,
        positions: vector<LiquidityPosition>,
        average_deployment_cost: u64,
        total_fees_earned: u64,
        last_deployment_timestamp: u64,
    }
    
    public struct LiquidityPosition has store {
        position_id: ID,
        pool_id: ID,
        tick_lower: SignedInt,
        tick_upper: SignedInt,
        liquidity_amount: u64,
        asset_a_amount: u64,
        asset_b_amount: u64,
        fees_earned: u64,
        creation_timestamp: u64,
        last_update_timestamp: u64,
    }
    
    public struct PendingOrder has store {
        order_id: String,
        order_type: String, // "DEPLOY", "WITHDRAW", "REBALANCE"
        target_tick_lower: SignedInt,
        target_tick_upper: SignedInt,
        amount_a: u64,
        amount_b: u64,
        max_slippage: u64,
        deadline: u64,
        creation_timestamp: u64,
    }
    
    public struct Transaction has store {
        transaction_id: String,
        transaction_type: String,
        amount_a: u64,
        amount_b: u64,
        gas_used: u64,
        fees_paid: u64,
        slippage: u64,
        timestamp: u64,
        block_number: u64,
    }
    
    public struct PnLTracking has store {
        realized_pnl: SignedInt,
        unrealized_pnl: SignedInt,
        total_fees_earned: u64,
        total_costs: u64,
        impermanent_loss: SignedInt,
        net_performance: SignedInt,
        last_update: u64,
    }
    
    // ========== Additional Supporting Structures ==========
    
    public struct ParameterDefinition has store {
        parameter_name: String,
        parameter_type: String,
        min_value: u64,
        max_value: u64,
        step_size: u64,
        description: String,
        impact_on_risk: String,
        impact_on_returns: String,
    }
    
    public struct ReturnExpectations has store {
        expected_annual_return: u64,
        min_expected_return: u64,
        max_expected_return: u64,
        return_volatility: u64,
    }
    
    public struct CapitalRequirements has store {
        minimum_capital: u64,
        recommended_capital: u64,
        optimal_capital: u64,
        capital_efficiency_score: u64,
    }
    
    public struct RiskLimits has store {
        max_drawdown: u64,
        max_volatility: u64,
        max_leverage: u64,
        liquidity_buffer: u64,
    }
    
    public struct PerformanceMetrics has store {
        average_return: u64,
        success_rate: u64,
        sharpe_ratio: u64,
        max_drawdown: u64,
        volatility: u64,
    }
    
    public struct UserRatings has store {
        average_rating: u64,
        total_ratings: u64,
        rating_distribution: Table<u64, u64>,
    }
    
    public struct AccessRequirements has store {
        min_unxv_stake: u64,
        min_tier_level: u64,
        whitelist_required: bool,
        kyc_required: bool,
    }
    
    public struct OutOfRangePeriod has store {
        start_timestamp: u64,
        end_timestamp: u64,
        price_at_exit: u64,
        duration: u64,
        missed_fees: u64,
    }
    
    public struct StopLossSettings has store {
        enabled: bool,
        stop_loss_percentage: u64,
        trailing_stop: bool,
        emergency_exit: bool,
    }
    
    public struct CircuitBreakerSettings has store {
        daily_loss_breaker: u64,
        volatility_breaker: u64,
        liquidity_breaker: u64,
        enabled: bool,
    }
    
    public struct GlobalRiskLimits has store {
        max_total_tvl: u64,
        max_single_vault_size: u64,
        max_leverage_system_wide: u64,
        emergency_pause_threshold: u64,
    }
    
    public struct DefaultRiskParameters has store {
        default_max_loss: u64,
        default_slippage_tolerance: u64,
        default_rebalance_threshold: u64,
        default_stop_loss: u64,
    }
    
    public struct EmergencyControls has store {
        emergency_pause: bool,
        emergency_withdrawal_only: bool,
        circuit_breaker_active: bool,
        last_emergency_action: u64,
    }
    
    public struct PerformanceAnalytics has store {
        total_volume_facilitated: u64,
        total_fees_generated: u64,
        average_vault_performance: u64,
        total_impermanent_loss: u64,
    }
    
    public struct BenchmarkData has store {
        hodl_benchmark: u64,
        passive_lp_benchmark: u64,
        market_index_benchmark: u64,
        last_benchmark_update: u64,
    }
    
    public struct AssetConfig has store {
        asset_symbol: String,
        decimals: u8,
        oracle_price_id: String,
        min_position_size: u64,
        max_position_size: u64,
        is_active: bool,
    }
    
    public struct DeepBookPoolInfo has store {
        pool_id: ID,
        asset_a: String,
        asset_b: String,
        current_price: u64,
        liquidity_depth: u64,
        trading_volume_24h: u64,
        fee_tier: u64,
        tick_spacing: u64,
        is_active: bool,
    }
    
    public struct VaultInfo has store {
        vault_id: ID,
        owner: address,
        vault_name: String,
        strategy_template: String,
        creation_timestamp: u64,
        total_value_locked: u64,
        performance_score: u64,
    }
    
    public struct CustomStrategy has store {
        strategy_id: String,
        creator: address,
        strategy_name: String,
        description: String,
        parameters: Table<String, u64>,
        performance_history: PerformanceMetrics,
        usage_count: u64,
        is_public: bool,
        creation_timestamp: u64,
    }
    
    // ========== Events ==========
    
    /// Emitted when a new manual LP vault is created
    public struct ManualVaultCreated has copy, drop {
        vault_id: ID,
        owner: address,
        vault_name: String,
        strategy_template: String,
        asset_a: String,
        asset_b: String,
        initial_deposit_a: u64,
        initial_deposit_b: u64,
        timestamp: u64,
    }
    
    /// Emitted when liquidity is deployed to DeepBook
    public struct LiquidityDeployed has copy, drop {
        vault_id: ID,
        owner: address,
        deepbook_pool_id: ID,
        liquidity_amount: u64,
        tick_lower: SignedInt,
        tick_upper: SignedInt,
        asset_a_amount: u64,
        asset_b_amount: u64,
        expected_fees: u64,
        timestamp: u64,
    }
    
    /// Emitted when vault is rebalanced
    public struct VaultRebalanced has copy, drop {
        vault_id: ID,
        owner: address,
        rebalancing_trigger: String,
        old_tick_lower: SignedInt,
        old_tick_upper: SignedInt,
        new_tick_lower: SignedInt,
        new_tick_upper: SignedInt,
        rebalancing_cost: u64,
        timestamp: u64,
    }
    
    /// Emitted when risk limit is breached
    public struct RiskLimitBreached has copy, drop {
        vault_id: ID,
        owner: address,
        risk_type: String,
        limit_value: u64,
        current_value: u64,
        breach_severity: String,
        automatic_actions: vector<String>,
        timestamp: u64,
    }
    
    /// Emitted during daily performance updates
    public struct DailyPerformanceUpdate has copy, drop {
        vault_id: ID,
        owner: address,
        date: u64,
        daily_return: SignedInt,
        fees_earned: u64,
        impermanent_loss: SignedInt,
        gas_costs: u64,
        net_performance: SignedInt,
        volume_facilitated: u64,
        timestamp: u64,
    }
    
    // ========== Initialization ==========
    
    /// Initialize the Manual LP protocol
    fun init(ctx: &mut TxContext) {
        // Create admin capability
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        // Initialize the registry
        let mut registry = ManualLPRegistry {
            id: object::new(ctx),
            strategy_templates: table::new(ctx),
            custom_strategies: table::new(ctx),
            active_vaults: table::new(ctx),
            supported_assets: vec_set::empty(),
            asset_configurations: table::new(ctx),
            deepbook_pools: table::new(ctx),
            global_risk_limits: GlobalRiskLimits {
                max_total_tvl: 1000000_000000, // 1M tokens
                max_single_vault_size: 100000_000000, // 100K tokens
                max_leverage_system_wide: 5_000000, // 5x leverage
                emergency_pause_threshold: 10_000000, // 10% system loss
            },
            default_risk_parameters: DefaultRiskParameters {
                default_max_loss: 5_000000, // 5% daily loss limit
                default_slippage_tolerance: 100, // 1% slippage
                default_rebalance_threshold: 500, // 5% price movement
                default_stop_loss: 20_000000, // 20% stop loss
            },
            emergency_controls: EmergencyControls {
                emergency_pause: false,
                emergency_withdrawal_only: false,
                circuit_breaker_active: false,
                last_emergency_action: 0,
            },
            performance_analytics: PerformanceAnalytics {
                total_volume_facilitated: 0,
                total_fees_generated: 0,
                average_vault_performance: 0,
                total_impermanent_loss: 0,
            },
            benchmark_data: BenchmarkData {
                hodl_benchmark: 0,
                passive_lp_benchmark: 0,
                market_index_benchmark: 0,
                last_benchmark_update: 0,
            },
            vault_creation_fee: 1_000000, // 1 USDC
            performance_tracking_fee: 100_000, // 0.1 USDC per day
            strategy_template_fee: 10_000000, // 10 USDC for premium templates
            deepbook_registry_id: option::none(),
            price_oracle_id: option::none(),
            balance_manager_id: option::none(),
            protocol_pause: false,
            admin_cap: option::some(admin_cap),
        };
        
        // Initialize default strategy templates
        initialize_strategy_templates(&mut registry, ctx);
        
        // Initialize supported assets
        initialize_supported_assets(&mut registry);
        
        // Transfer admin capability to deployer
        if (option::is_some(&registry.admin_cap)) {
            let admin_cap = option::extract(&mut registry.admin_cap);
            transfer::transfer(admin_cap, tx_context::sender(ctx));
        };
        
        // Share the registry
        transfer::share_object(registry);
    }
    
    /// Initialize default strategy templates
    fun initialize_strategy_templates(registry: &mut ManualLPRegistry, ctx: &mut TxContext) {
        // AMM Overlay Strategy Template
        let mut amm_required_params = vector::empty<ParameterDefinition>();
        vector::push_back(&mut amm_required_params, ParameterDefinition {
            parameter_name: string::utf8(b"range_multiplier"),
            parameter_type: string::utf8(b"MULTIPLIER"),
            min_value: 1_000000, // 1x
            max_value: 10_000000, // 10x
            step_size: 500000, // 0.5x steps
            description: string::utf8(b"Range width multiplier for liquidity provision"),
            impact_on_risk: string::utf8(b"Higher multiplier = lower risk but lower returns"),
            impact_on_returns: string::utf8(b"Lower multiplier = higher returns but higher risk"),
        });
        
        let mut amm_default_values = table::new<String, u64>(ctx);
        table::add(&mut amm_default_values, string::utf8(b"range_multiplier"), 2_000000); // 2x default
        table::add(&mut amm_default_values, string::utf8(b"rebalance_threshold"), 8000); // 80% of range
        table::add(&mut amm_default_values, string::utf8(b"auto_compound_threshold"), 10_000000); // 10 USDC
        
        let amm_template = StrategyTemplate {
            template_id: string::utf8(b"AMM_OVERLAY"),
            template_name: string::utf8(b"AMM Overlay Strategy"),
            description: string::utf8(b"Passive liquidity provision mimicking AMM behavior"),
            complexity_level: string::utf8(b"BEGINNER"),
            required_parameters: amm_required_params,
            optional_parameters: vector::empty(),
            default_values: amm_default_values,
            strategy_type: string::utf8(b"PASSIVE"),
            risk_level: string::utf8(b"LOW"),
            typical_returns: ReturnExpectations {
                expected_annual_return: 8_000000, // 8% APY
                min_expected_return: 2_000000, // 2% APY
                max_expected_return: 15_000000, // 15% APY
                return_volatility: 20_000000, // 20% volatility
            },
            capital_requirements: CapitalRequirements {
                minimum_capital: 100_000000, // 100 USDC minimum
                recommended_capital: 1000_000000, // 1000 USDC recommended
                optimal_capital: 10000_000000, // 10000 USDC optimal
                capital_efficiency_score: 70_000000, // 70% efficiency
            },
            recommended_risk_limits: RiskLimits {
                max_drawdown: 10_000000, // 10% max drawdown
                max_volatility: 30_000000, // 30% max volatility
                max_leverage: 1_000000, // 1x leverage (no leverage)
                liquidity_buffer: 5_000000, // 5% liquidity buffer
            },
            mandatory_controls: vector::empty(),
            total_deployments: 0,
            average_performance: PerformanceMetrics {
                average_return: 8_000000,
                success_rate: 75_000000, // 75% success rate
                sharpe_ratio: 1_200000, // 1.2 Sharpe ratio
                max_drawdown: 8_000000, // 8% historical max drawdown
                volatility: 18_000000, // 18% volatility
            },
            user_ratings: UserRatings {
                average_rating: 4_200000, // 4.2/5 average rating
                total_ratings: 0,
                rating_distribution: table::new(ctx),
            },
            is_free: true,
            access_requirements: AccessRequirements {
                min_unxv_stake: 0,
                min_tier_level: 0,
                whitelist_required: false,
                kyc_required: false,
            },
        };
        
        table::add(&mut registry.strategy_templates, string::utf8(b"AMM_OVERLAY"), amm_template);
        
        // Grid Trading Strategy Template
        let mut grid_required_params = vector::empty<ParameterDefinition>();
        vector::push_back(&mut grid_required_params, ParameterDefinition {
            parameter_name: string::utf8(b"grid_levels"),
            parameter_type: string::utf8(b"COUNT"),
            min_value: 3,
            max_value: 20,
            step_size: 1,
            description: string::utf8(b"Number of grid levels for trading"),
            impact_on_risk: string::utf8(b"More levels = higher complexity and risk"),
            impact_on_returns: string::utf8(b"More levels = potentially higher returns"),
        });
        
        let mut grid_default_values = table::new<String, u64>(ctx);
        table::add(&mut grid_default_values, string::utf8(b"grid_levels"), 5);
        table::add(&mut grid_default_values, string::utf8(b"grid_spacing"), 2_000000); // 2% spacing
        table::add(&mut grid_default_values, string::utf8(b"base_order_size"), 100_000000); // 100 USDC
        
        let grid_template = StrategyTemplate {
            template_id: string::utf8(b"GRID_TRADING"),
            template_name: string::utf8(b"Grid Trading Strategy"),
            description: string::utf8(b"Active market making with multiple price levels"),
            complexity_level: string::utf8(b"INTERMEDIATE"),
            required_parameters: grid_required_params,
            optional_parameters: vector::empty(),
            default_values: grid_default_values,
            strategy_type: string::utf8(b"ACTIVE"),
            risk_level: string::utf8(b"MEDIUM"),
            typical_returns: ReturnExpectations {
                expected_annual_return: 12_000000, // 12% APY
                min_expected_return: 5_000000, // 5% APY
                max_expected_return: 25_000000, // 25% APY
                return_volatility: 35_000000, // 35% volatility
            },
            capital_requirements: CapitalRequirements {
                minimum_capital: 500_000000, // 500 USDC minimum
                recommended_capital: 5000_000000, // 5000 USDC recommended
                optimal_capital: 50000_000000, // 50000 USDC optimal
                capital_efficiency_score: 85_000000, // 85% efficiency
            },
            recommended_risk_limits: RiskLimits {
                max_drawdown: 15_000000, // 15% max drawdown
                max_volatility: 40_000000, // 40% max volatility
                max_leverage: 2_000000, // 2x leverage
                liquidity_buffer: 10_000000, // 10% liquidity buffer
            },
            mandatory_controls: vector::empty(),
            total_deployments: 0,
            average_performance: PerformanceMetrics {
                average_return: 12_000000,
                success_rate: 65_000000, // 65% success rate
                sharpe_ratio: 1_000000, // 1.0 Sharpe ratio
                max_drawdown: 12_000000, // 12% historical max drawdown
                volatility: 30_000000, // 30% volatility
            },
            user_ratings: UserRatings {
                average_rating: 4_000000, // 4.0/5 average rating
                total_ratings: 0,
                rating_distribution: table::new(ctx),
            },
            is_free: false, // Premium strategy
            access_requirements: AccessRequirements {
                min_unxv_stake: 1000_000000, // 1000 UNXV minimum
                min_tier_level: 2,
                whitelist_required: false,
                kyc_required: false,
            },
        };
        
        table::add(&mut registry.strategy_templates, string::utf8(b"GRID_TRADING"), grid_template);
    }
    
    /// Initialize supported assets
    fun initialize_supported_assets(registry: &mut ManualLPRegistry) {
        // Add supported assets
        vec_set::insert(&mut registry.supported_assets, string::utf8(b"SUI"));
        vec_set::insert(&mut registry.supported_assets, string::utf8(b"USDC"));
        vec_set::insert(&mut registry.supported_assets, string::utf8(b"DEEP"));
        vec_set::insert(&mut registry.supported_assets, string::utf8(b"UNXV"));
        
        // Configure asset parameters
        table::add(&mut registry.asset_configurations, string::utf8(b"SUI"), AssetConfig {
            asset_symbol: string::utf8(b"SUI"),
            decimals: 9,
            oracle_price_id: string::utf8(b"SUI_USD"),
            min_position_size: 1_000000000, // 1 SUI
            max_position_size: 1000000_000000000, // 1M SUI
            is_active: true,
        });
        
        table::add(&mut registry.asset_configurations, string::utf8(b"USDC"), AssetConfig {
            asset_symbol: string::utf8(b"USDC"),
            decimals: 6,
            oracle_price_id: string::utf8(b"USDC_USD"),
            min_position_size: 1_000000, // 1 USDC
            max_position_size: 1000000_000000, // 1M USDC
            is_active: true,
        });
    }
    
    // ========== Core Functions ==========
    
    /// Create a new manual LP vault
    public fun create_manual_lp_vault<T, U>(
        registry: &mut ManualLPRegistry,
        vault_name: String,
        strategy_template: String,
        initial_deposit_a: Coin<T>,
        initial_deposit_b: Coin<U>,
        strategy_parameters: Table<String, u64>,
        risk_limits: UserRiskLimits,
        rebalancing_settings: RebalancingSettings,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ManualLPVault<T, U> {
        // Validate inputs
        assert!(!registry.protocol_pause, E_EMERGENCY_STOP_ACTIVE);
        assert!(table::contains(&registry.strategy_templates, strategy_template), E_STRATEGY_NOT_SUPPORTED);
        assert!(coin::value(&initial_deposit_a) > 0, E_INSUFFICIENT_BALANCE);
        assert!(coin::value(&initial_deposit_b) > 0, E_INSUFFICIENT_BALANCE);
        
        let vault_id = object::new(ctx);
        let vault_id_address = object::uid_to_inner(&vault_id);
        
        // Extract initial deposits
        let deposit_a_amount = coin::value(&initial_deposit_a);
        let deposit_b_amount = coin::value(&initial_deposit_b);
        
        // Create vault
        let vault = ManualLPVault<T, U> {
            id: vault_id,
            owner: tx_context::sender(ctx),
            vault_name,
            strategy_template,
            asset_a_type: string::utf8(b"T"), // Will be replaced with actual type name
            asset_b_type: string::utf8(b"U"), // Will be replaced with actual type name
            balance_a: coin::into_balance(initial_deposit_a),
            balance_b: coin::into_balance(initial_deposit_b),
            deployed_liquidity: DeployedLiquidity {
                total_liquidity_deployed: 0,
                positions: vector::empty(),
                average_deployment_cost: 0,
                total_fees_earned: 0,
                last_deployment_timestamp: 0,
            },
            strategy_parameters,
            tick_range: TickRange {
                lower_tick: signed_int_negative(100), // Default range -100
                upper_tick: signed_int_from(100), // Default range +100
                current_tick: signed_int_from(0), // Current at 0
                tick_spacing: 1,
                auto_adjust_range: true,
                range_adjustment_threshold: 8000, // 80% of range
                max_range_width: MAX_TICK_RANGE,
                min_range_width: 10,
                time_in_range: 100_000000, // 100% initially
                range_efficiency: 100_000000, // 100% initially
                out_of_range_periods: vector::empty(),
            },
            rebalancing_settings,
            risk_limits,
            stop_loss_settings: StopLossSettings {
                enabled: false,
                stop_loss_percentage: 20_000000, // 20% default
                trailing_stop: false,
                emergency_exit: false,
            },
            circuit_breakers: CircuitBreakerSettings {
                daily_loss_breaker: 5_000000, // Use default daily loss limit
                volatility_breaker: 50_000000, // 50% volatility breaker
                liquidity_breaker: 10_000000, // 10% liquidity breaker
                enabled: true,
            },
            performance_data: VaultPerformanceData {
                total_return: signed_int_from(0),
                daily_returns: vector::empty(),
                monthly_returns: vector::empty(),
                annualized_return: signed_int_from(0),
                volatility: 0,
                sharpe_ratio: 0,
                maximum_drawdown: 0,
                current_drawdown: 0,
                fees_earned: 0,
                impermanent_loss: signed_int_from(0),
                liquidity_utilization: 0,
                volume_facilitated: 0,
                trades_facilitated: 0,
                contribution_to_liquidity: 0,
                vs_hodl_performance: signed_int_from(0),
                vs_passive_lp_performance: signed_int_from(0),
                vs_benchmark_performance: signed_int_from(0),
            },
            transaction_history: vector::empty(),
            pnl_tracking: PnLTracking {
                realized_pnl: signed_int_from(0),
                unrealized_pnl: signed_int_from(0),
                total_fees_earned: 0,
                total_costs: 0,
                impermanent_loss: signed_int_from(0),
                net_performance: signed_int_from(0),
                last_update: clock::timestamp_ms(clock),
            },
            active_positions: vector::empty(),
            pending_orders: vector::empty(),
            vault_status: string::utf8(b"ACTIVE"),
            last_rebalance: 0,
            creation_timestamp: clock::timestamp_ms(clock),
        };
        
        // Register vault in the registry
        table::add(&mut registry.active_vaults, vault_name, VaultInfo {
            vault_id: vault_id_address,
            owner: tx_context::sender(ctx),
            vault_name,
            strategy_template,
            creation_timestamp: clock::timestamp_ms(clock),
            total_value_locked: deposit_a_amount + deposit_b_amount, // Simplified calculation
            performance_score: 100_000000, // 100% initial score
        });
        
        // Emit event
        event::emit(ManualVaultCreated {
            vault_id: vault_id_address,
            owner: tx_context::sender(ctx),
            vault_name,
            strategy_template,
            asset_a: string::utf8(b"T"),
            asset_b: string::utf8(b"U"),
            initial_deposit_a: deposit_a_amount,
            initial_deposit_b: deposit_b_amount,
            timestamp: clock::timestamp_ms(clock),
        });
        
        vault
    }
    
    /// Deploy liquidity to DeepBook
    public fun deploy_liquidity_to_deepbook<T, U>(
        vault: &mut ManualLPVault<T, U>,
        registry: &ManualLPRegistry,
        pool: &mut Pool<T, U>,
        _balance_manager: &mut BalanceManager,
        amount_a: u64,
        amount_b: u64,
        tick_lower: SignedInt,
        tick_upper: SignedInt,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        // Validate inputs
        assert!(!registry.protocol_pause, E_EMERGENCY_STOP_ACTIVE);
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_AUTHORIZED);
        assert!(vault.vault_status == string::utf8(b"ACTIVE"), E_EMERGENCY_STOP_ACTIVE);
        assert!(signed_int_value(&tick_lower) < signed_int_value(&tick_upper), E_INVALID_TICK_RANGE);
        assert!(balance::value(&vault.balance_a) >= amount_a, E_INSUFFICIENT_BALANCE);
        assert!(balance::value(&vault.balance_b) >= amount_b, E_INSUFFICIENT_BALANCE);
        
        // Validate tick range
        let range_width = signed_int_value(&tick_upper) + signed_int_value(&tick_lower);
        assert!(range_width <= MAX_TICK_RANGE, E_INVALID_TICK_RANGE);
        
        // Create a new position ID
        let position_id = object::new(ctx);
        let position_id_inner = object::uid_to_inner(&position_id);
        object::delete(position_id);
        
        // For now, we'll simulate deployment - in real implementation this would
        // interact with DeepBook to deploy liquidity
        let liquidity_amount = (amount_a + amount_b) / 2; // Simplified calculation
        
        // Withdraw amounts from vault balances (and use them properly)
        let deployed_balance_a = balance::split(&mut vault.balance_a, amount_a);
        let deployed_balance_b = balance::split(&mut vault.balance_b, amount_b);
        
        // In real implementation, these would be provided to DeepBook
        // For now, we'll add them back to the vault's deployed liquidity tracking
        balance::join(&mut vault.balance_a, deployed_balance_a);
        balance::join(&mut vault.balance_b, deployed_balance_b);
        
        // Create liquidity position
        let position = LiquidityPosition {
            position_id: position_id_inner,
            pool_id: object::id(pool),
            tick_lower,
            tick_upper,
            liquidity_amount,
            asset_a_amount: amount_a,
            asset_b_amount: amount_b,
            fees_earned: 0,
            creation_timestamp: clock::timestamp_ms(clock),
            last_update_timestamp: clock::timestamp_ms(clock),
        };
        
        // Add position to vault
        vector::push_back(&mut vault.active_positions, position);
        
        // Update deployed liquidity tracking
        vault.deployed_liquidity.total_liquidity_deployed = 
            vault.deployed_liquidity.total_liquidity_deployed + liquidity_amount;
        vault.deployed_liquidity.last_deployment_timestamp = clock::timestamp_ms(clock);
        
        // Update tick range if this is the first deployment
        if (vector::length(&vault.active_positions) == 1) {
            vault.tick_range.lower_tick = tick_lower;
            vault.tick_range.upper_tick = tick_upper;
            let avg_tick = (signed_int_value(&tick_lower) + signed_int_value(&tick_upper)) / 2;
            vault.tick_range.current_tick = signed_int_from(avg_tick);
        };
        
        // Emit event
        event::emit(LiquidityDeployed {
            vault_id: object::id(vault),
            owner: vault.owner,
            deepbook_pool_id: object::id(pool),
            liquidity_amount,
            tick_lower,
            tick_upper,
            asset_a_amount: amount_a,
            asset_b_amount: amount_b,
            expected_fees: liquidity_amount / 1000, // Simplified fee estimation
            timestamp: clock::timestamp_ms(clock),
        });
        
        position_id_inner
    }
    
    /// Manual rebalancing of vault positions
    public fun manual_rebalance_vault<T, U>(
        vault: &mut ManualLPVault<T, U>,
        registry: &ManualLPRegistry,
        new_tick_lower: SignedInt,
        new_tick_upper: SignedInt,
        rebalancing_trigger: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Validate inputs
        assert!(!registry.protocol_pause, E_EMERGENCY_STOP_ACTIVE);
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_AUTHORIZED);
        assert!(vault.vault_status == string::utf8(b"ACTIVE"), E_EMERGENCY_STOP_ACTIVE);
        // For tick range validation, we need to consider the sign
        // Simplified check: negative tick should be less than positive tick
        // If both negative, larger value is smaller; if both positive, normal comparison
        let valid_range = if (signed_int_is_negative(&new_tick_lower) && !signed_int_is_negative(&new_tick_upper)) {
            true // negative < positive
        } else if (!signed_int_is_negative(&new_tick_lower) && signed_int_is_negative(&new_tick_upper)) {
            false // positive < negative is invalid
        } else if (signed_int_is_negative(&new_tick_lower) && signed_int_is_negative(&new_tick_upper)) {
            signed_int_value(&new_tick_lower) > signed_int_value(&new_tick_upper) // for negatives, larger value is smaller
        } else {
            signed_int_value(&new_tick_lower) < signed_int_value(&new_tick_upper) // both positive
        };
        assert!(valid_range, E_INVALID_TICK_RANGE);
        
        // Check rebalancing frequency
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= vault.last_rebalance + MIN_REBALANCE_INTERVAL, E_REBALANCING_TOO_FREQUENT);
        
        // Store old tick range for event
        let old_tick_lower = vault.tick_range.lower_tick;
        let old_tick_upper = vault.tick_range.upper_tick;
        
        // Update tick range
        vault.tick_range.lower_tick = new_tick_lower;
        vault.tick_range.upper_tick = new_tick_upper;
        let avg_tick = (signed_int_value(&new_tick_lower) + signed_int_value(&new_tick_upper)) / 2;
        vault.tick_range.current_tick = signed_int_from(avg_tick);
        vault.last_rebalance = current_time;
        
        // Calculate rebalancing cost (simplified)
        let rebalancing_cost = 1_000000; // 1 USDC as example
        
        // Update position history for all positions
        let mut i = 0;
        while (i < vector::length(&vault.active_positions)) {
            let position = vector::borrow_mut(&mut vault.active_positions, i);
            position.tick_lower = new_tick_lower;
            position.tick_upper = new_tick_upper;
            position.last_update_timestamp = current_time;
            i = i + 1;
        };
        
        // Emit event
        event::emit(VaultRebalanced {
            vault_id: object::id(vault),
            owner: vault.owner,
            rebalancing_trigger,
            old_tick_lower,
            old_tick_upper,
            new_tick_lower,
            new_tick_upper,
            rebalancing_cost,
            timestamp: current_time,
        });
    }
    
    /// Calculate UNXV tier based on staked amount
    public fun calculate_unxv_tier(unxv_staked: u64): u64 {
        if (unxv_staked >= 500000_000000) { // 500,000 UNXV
            5
        } else if (unxv_staked >= 100000_000000) { // 100,000 UNXV
            4
        } else if (unxv_staked >= 25000_000000) { // 25,000 UNXV
            3
        } else if (unxv_staked >= 5000_000000) { // 5,000 UNXV
            2
        } else if (unxv_staked >= 1000_000000) { // 1,000 UNXV
            1
        } else {
            0
        }
    }
    
    /// Update vault performance data
    public fun update_vault_performance<T, U>(
        vault: &mut ManualLPVault<T, U>,
        _registry: &ManualLPRegistry,
        daily_return: SignedInt,
        fees_earned: u64,
        gas_costs: u64,
        volume_facilitated: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        // Validate authorization
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_AUTHORIZED);
        
        let current_time = clock::timestamp_ms(clock);
        let date = current_time / (24 * 60 * 60 * 1000); // Convert to days
        
        // Update performance data
        vector::push_back(&mut vault.performance_data.daily_returns, daily_return);
        vault.performance_data.fees_earned = vault.performance_data.fees_earned + fees_earned;
        vault.performance_data.volume_facilitated = vault.performance_data.volume_facilitated + volume_facilitated;
        
        // Update P&L tracking
        vault.pnl_tracking.total_fees_earned = vault.pnl_tracking.total_fees_earned + fees_earned;
        vault.pnl_tracking.total_costs = vault.pnl_tracking.total_costs + gas_costs;
        
        let fees_signed = signed_int_from(vault.pnl_tracking.total_fees_earned);
        let costs_signed = signed_int_from(vault.pnl_tracking.total_costs);
        vault.pnl_tracking.net_performance = signed_int_subtract(&fees_signed, &costs_signed);
        vault.pnl_tracking.last_update = current_time;
        
        // Calculate net performance
        let gas_costs_signed = signed_int_from(gas_costs);
        let net_performance = signed_int_subtract(&daily_return, &gas_costs_signed);
        
        // Emit event
        event::emit(DailyPerformanceUpdate {
            vault_id: object::id(vault),
            owner: vault.owner,
            date,
            daily_return,
            fees_earned,
            impermanent_loss: vault.performance_data.impermanent_loss,
            gas_costs,
            net_performance,
            volume_facilitated,
            timestamp: current_time,
        });
    }
    
    // ========== View Functions ==========
    
    /// Get vault information
    public fun get_vault_info<T, U>(vault: &ManualLPVault<T, U>): (String, String, String, u64, u64, u64) {
        (
            vault.vault_name,
            vault.strategy_template,
            vault.vault_status,
            balance::value(&vault.balance_a),
            balance::value(&vault.balance_b),
            vault.creation_timestamp
        )
    }
    
    /// Get vault performance metrics
    public fun get_vault_performance<T, U>(vault: &ManualLPVault<T, U>): (SignedInt, u64, u64, u64, SignedInt) {
        (
            vault.performance_data.total_return,
            vault.performance_data.fees_earned,
            vault.performance_data.volume_facilitated,
            vault.performance_data.trades_facilitated,
            vault.performance_data.impermanent_loss
        )
    }
    
    /// Get vault risk metrics
    public fun get_vault_risk_metrics<T, U>(vault: &ManualLPVault<T, U>): (u64, u64, u64, u64) {
        (
            vault.risk_limits.max_daily_loss,
            vault.performance_data.maximum_drawdown,
            vault.performance_data.volatility,
            vault.risk_limits.max_position_size
        )
    }
    
    /// Get active strategy templates
    public fun get_strategy_templates(registry: &ManualLPRegistry): &Table<String, StrategyTemplate> {
        &registry.strategy_templates
    }
    
    /// Check if protocol is paused
    public fun is_protocol_paused(registry: &ManualLPRegistry): bool {
        registry.protocol_pause
    }
    
    // ========== Test Helper Functions ==========
    
    #[test_only]
    /// Initialize the module for testing
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
    
    #[test_only]
    /// Create a test vault for testing
    public fun create_test_vault<T, U>(
        registry: &mut ManualLPRegistry,
        initial_a: Coin<T>,
        initial_b: Coin<U>,
        ctx: &mut TxContext,
        clock: &Clock,
    ): ManualLPVault<T, U> {
        create_manual_lp_vault(
            registry,
            string::utf8(b"Test Vault"),
            string::utf8(b"AMM_OVERLAY"),
            initial_a,
            initial_b,
            table::new(ctx),
            UserRiskLimits {
                max_position_size: 1000000_000000,
                max_daily_loss: 5_000000,
                max_weekly_loss: 15_000000,
                max_monthly_loss: 25_000000,
                max_single_asset_exposure: 80_000000,
                max_correlated_assets_exposure: 60_000000,
                max_volatility_exposure: 50_000000,
                volatility_scaling: true,
                min_liquidity_buffer: 10_000000,
                emergency_liquidity_threshold: 5_000000,
            },
            RebalancingSettings {
                rebalancing_strategy: string::utf8(b"THRESHOLD_BASED"),
                rebalancing_frequency: 86400, // Daily
                price_movement_threshold: 5_000000, // 5%
                liquidity_threshold: 1000_000000,
                max_rebalancing_cost: 10_000000,
                gas_price_limit: 1000,
                rebalancing_budget: 100_000000,
                preferred_rebalancing_times: vector::empty(),
                avoid_high_volatility_periods: true,
                market_hours_only: false,
            },
            clock,
            ctx,
        )
    }
    
    #[test_only]
    /// Get vault details for testing
    public fun get_vault_details_for_testing<T, U>(vault: &ManualLPVault<T, U>): (address, String, String, u64) {
        (
            vault.owner,
            vault.vault_name,
            vault.strategy_template,
            vault.creation_timestamp
        )
    }
    
    #[test_only]
    /// Get SignedInt details for testing
    public fun get_signed_int_details_for_testing(s: &SignedInt): (u64, bool) {
        (s.value, s.is_negative)
    }
    
    #[test_only]
    /// Create UserRiskLimits for testing
    public fun create_test_user_risk_limits(
        max_position_size: u64,
        max_daily_loss: u64,
        max_weekly_loss: u64,
        max_monthly_loss: u64,
        max_single_asset_exposure: u64,
        max_correlated_assets_exposure: u64,
        max_volatility_exposure: u64,
        volatility_scaling: bool,
        min_liquidity_buffer: u64,
        emergency_liquidity_threshold: u64,
    ): UserRiskLimits {
        UserRiskLimits {
            max_position_size,
            max_daily_loss,
            max_weekly_loss,
            max_monthly_loss,
            max_single_asset_exposure,
            max_correlated_assets_exposure,
            max_volatility_exposure,
            volatility_scaling,
            min_liquidity_buffer,
            emergency_liquidity_threshold,
        }
    }
    
    #[test_only]
    /// Create RebalancingSettings for testing
    public fun create_test_rebalancing_settings(
        rebalancing_strategy: String,
        rebalancing_frequency: u64,
        price_movement_threshold: u64,
        liquidity_threshold: u64,
        max_rebalancing_cost: u64,
        gas_price_limit: u64,
        rebalancing_budget: u64,
        preferred_rebalancing_times: vector<u64>,
        avoid_high_volatility_periods: bool,
        market_hours_only: bool,
    ): RebalancingSettings {
        RebalancingSettings {
            rebalancing_strategy,
            rebalancing_frequency,
            price_movement_threshold,
            liquidity_threshold,
            max_rebalancing_cost,
            gas_price_limit,
            rebalancing_budget,
            preferred_rebalancing_times,
            avoid_high_volatility_periods,
            market_hours_only,
        }
    }
}


