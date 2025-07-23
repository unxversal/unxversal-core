/// UnXversal Lending Protocol
/// A comprehensive DeFi lending platform with synthetic asset support,
/// leveraged trading integration, and UNXV tokenomics.
module unxv_lending::unxv_lending {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::math;
    use std::string::{String};
    use std::vector;
    use std::option::{Self, Option};
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::pyth;
    use pyth::price;
    use pyth::price_identifier;
    use pyth::i64 as pyth_i64;
    use deepbook::balance_manager::{BalanceManager, TradeProof};
    use deepbook::pool::{Pool};

    // Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_COLLATERAL: u64 = 2;
    const E_HEALTH_FACTOR_TOO_LOW: u64 = 3;
    const E_ASSET_NOT_SUPPORTED: u64 = 4;
    const E_POOL_NOT_EXISTS: u64 = 5;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 6;
    const E_BORROW_CAP_EXCEEDED: u64 = 7;
    const E_SUPPLY_CAP_EXCEEDED: u64 = 8;
    const E_INVALID_INTEREST_RATE_MODE: u64 = 9;
    const E_LIQUIDATION_NOT_ALLOWED: u64 = 10;
    const E_FLASH_LOAN_NOT_REPAID: u64 = 11;
    const E_EMERGENCY_PAUSE_ACTIVE: u64 = 12;
    const E_INVALID_UNXV_TIER: u64 = 13;
    const E_INSUFFICIENT_REWARDS: u64 = 14;

    // Constants
    const BASIS_POINTS: u64 = 10000;
    const MIN_HEALTH_FACTOR: u64 = 10000; // 1.0
    const LIQUIDATION_THRESHOLD: u64 = 8500; // 0.85
    const SECONDS_PER_YEAR: u64 = 31536000;
    const INITIAL_EXCHANGE_RATE: u64 = 1000000; // 1.0 with 6 decimals

    // Admin capability
    public struct AdminCap has key, store {
        id: UID,
    }

    // Core registry managing all lending operations
    public struct LendingRegistry has key {
        id: UID,
        supported_assets: Table<String, AssetConfig>,
        lending_pools: Table<String, ID>,
        interest_rate_models: Table<String, InterestRateModel>,
        global_params: GlobalParams,
        risk_parameters: RiskParameters,
        oracle_feeds: Table<String, vector<u8>>, // Pyth price feed IDs
        admin_cap: Option<AdminCap>,
        emergency_pause: bool,
        version: u64,
    }

    // Asset configuration parameters
    public struct AssetConfig has store {
        asset_name: String,
        asset_type: String, // "NATIVE", "SYNTHETIC", "WRAPPED"
        is_collateral: bool,
        is_borrowable: bool,
        collateral_factor: u64, // 80% = 8000 basis points
        liquidation_threshold: u64, // 85% = 8500 basis points
        liquidation_penalty: u64, // 5% = 500 basis points
        supply_cap: u64,
        borrow_cap: u64,
        reserve_factor: u64, // Protocol fee percentage
        is_active: bool,
    }

    // Global protocol parameters
    public struct GlobalParams has store {
        min_borrow_amount: u64, // Minimum borrow in USD value
        max_utilization_rate: u64, // 95% = 9500 basis points
        close_factor: u64, // 50% = 5000 basis points
        grace_period: u64, // Time before liquidation (ms)
        flash_loan_fee: u64, // 9 basis points (0.09%)
        protocol_fee: u64, // Overall protocol fee
    }

    // Risk management parameters
    public struct RiskParameters has store {
        max_assets_as_collateral: u8,
        health_factor_liquidation: u64, // 1.0 = 10000 basis points
        debt_ceiling_global: u64,
        liquidation_incentive: u64,
        max_liquidation_amount: u64,
    }

    // Interest rate model for dynamic rates
    public struct InterestRateModel has store {
        base_rate: u64, // Base interest rate (APR)
        multiplier: u64, // Rate slope factor
        jump_multiplier: u64, // Rate after optimal utilization
        optimal_utilization: u64, // Kink point in rate curve
        max_rate: u64, // Rate ceiling for safety
    }

    // Individual lending pool for each asset
    public struct LendingPool<phantom T> has key {
        id: UID,
        asset_name: String,
        
        // Pool balances
        total_supply: u64,
        total_borrows: u64,
        total_reserves: u64,
        cash: Balance<T>,
        
        // Interest tracking
        supply_index: u64,
        borrow_index: u64,
        last_update_timestamp: u64,
        
        // Rate information
        current_supply_rate: u64,
        current_borrow_rate: u64,
        utilization_rate: u64,
        
        // Integration objects
        deepbook_pool_id: Option<ID>,
        synthetic_registry_id: Option<ID>,
        
        // Pool status
        is_active: bool,
        is_frozen: bool,
    }
    
    // User account tracking all positions
    public struct UserAccount has key {
        id: UID,
        owner: address,
        
        // Supply positions
        supply_balances: Table<String, SupplyPosition>,
        
        // Borrow positions
        borrow_balances: Table<String, BorrowPosition>,
        
        // Account health
        total_collateral_value: u64,
        total_borrow_value: u64,
        health_factor: u64,
        
        // Risk tracking
        assets_as_collateral: VecSet<String>,
        last_health_check: u64,
        liquidation_threshold_breached: bool,
        
        // Rewards tracking
        unxv_stake_amount: u64,
        reward_debt: Table<String, u64>,
        
        // Account settings
        auto_compound: bool,
        max_slippage: u64,
        account_tier: u64, // UNXV staking tier
    }
    
    // Supply position details
    public struct SupplyPosition has store {
        principal_amount: u64,
        scaled_balance: u64,
        last_interest_index: u64,
        is_collateral: bool,
        supply_timestamp: u64,
        last_reward_index: u64,
    }
    
    // Borrow position details
    public struct BorrowPosition has store {
        principal_amount: u64,
        scaled_balance: u64,
        last_interest_index: u64,
        interest_rate_mode: String, // "STABLE" or "VARIABLE"
        borrow_timestamp: u64,
        stable_rate: Option<u64>, // For stable rate mode
    }
    
    // Liquidation engine for automated liquidations
    public struct LiquidationEngine has key {
        id: UID,
        operator: address,
        
        // Liquidation parameters
        liquidation_threshold: u64,
        liquidation_bonus: u64,
        max_liquidation_amount: u64,
        
        // Integration
        spot_dex_registry: Option<ID>,
        flash_loan_providers: VecSet<ID>,
        
        // Performance tracking
        total_liquidations: u64,
        total_volume_liquidated: u64,
        average_liquidation_time: u64,
        
        // Status
        emergency_pause: bool,
        whitelisted_liquidators: VecSet<address>,
    }
    
    // Yield farming vault for UNXV rewards
    public struct YieldFarmingVault has key {
        id: UID,
        
        // Reward distribution
        unxv_rewards_per_second: u64,
        total_allocation_points: u64,
        pool_allocations: Table<String, u64>,
        
        // UNXV staking benefits
        staked_unxv: Table<address, StakePosition>,
        stake_multipliers: Table<u64, u64>, // tier -> multiplier
        
        // Reward tracking
        total_rewards_distributed: u64,
        last_reward_timestamp: u64,
        reward_debt: Table<address, u64>,
        
        // Vault status
        is_active: bool,
    }
    
    // UNXV stake position
    public struct StakePosition has store, drop {
        amount: u64,
        stake_timestamp: u64,
        tier: u64, // 0-5 (Bronze to Diamond)
        multiplier: u64,
        locked_until: u64,
        rewards_earned: u64,
    }

    // Flash loan hot potato
    public struct FlashLoan {
        pool_id: ID,
        asset_name: String,
        amount: u64,
        fee: u64,
        recipient: address,
    }

    // Market condition tracking (simplified)
    public struct MarketConditions has drop {
        overall_utilization: u64,
        volatility_index: u64,
        liquidity_stress: bool,
    }

    // Event structs for comprehensive logging
    public struct AssetSupplied has copy, drop {
        user: address,
        asset: String,
        amount: u64,
        scaled_amount: u64,
        new_balance: u64,
        is_collateral: bool,
        supply_rate: u64,
        timestamp: u64,
    }
    
    public struct AssetWithdrawn has copy, drop {
        user: address,
        asset: String,
        amount: u64,
        scaled_amount: u64,
        remaining_balance: u64,
        interest_earned: u64,
        timestamp: u64,
    }
    
    public struct AssetBorrowed has copy, drop {
        user: address,
        asset: String,
        amount: u64,
        scaled_amount: u64,
        new_borrow_balance: u64,
        borrow_rate: u64,
        health_factor: u64,
        timestamp: u64,
    }
    
    public struct DebtRepaid has copy, drop {
        user: address,
        asset: String,
        amount: u64,
        scaled_amount: u64,
        remaining_debt: u64,
        interest_paid: u64,
        timestamp: u64,
    }
    
    public struct LiquidationExecuted has copy, drop {
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
    
    public struct InterestRatesUpdated has copy, drop {
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
    
    public struct RewardsClaimed has copy, drop {
        user: address,
        unxv_amount: u64,
        bonus_multiplier: u64,
        stake_tier: u64,
        total_rewards_earned: u64,
        timestamp: u64,
    }

    public struct UnxvStaked has copy, drop {
        user: address,
        amount: u64,
        new_tier: u64,
        new_multiplier: u64,
        lock_duration: u64,
        benefits: vector<String>,
        timestamp: u64,
    }
    
    public struct FlashLoanExecuted has copy, drop {
        borrower: address,
        asset: String,
        amount: u64,
        fee: u64,
        purpose: String,
        timestamp: u64,
    }
    
    public struct ProtocolFeesProcessed has copy, drop {
        total_fees_collected: u64,
        unxv_burned: u64,
        reserve_allocation: u64,
        fee_sources: vector<String>,
        timestamp: u64,
    }
    
    // Result structs for function returns
    public struct SupplyReceipt has drop {
        amount_supplied: u64,
        scaled_amount: u64,
        new_supply_rate: u64,
        interest_earned: u64,
    }

    public struct RepayReceipt has drop {
        amount_repaid: u64,
        interest_paid: u64,
        remaining_debt: u64,
        health_factor_improvement: u64,
    }

    public struct HealthFactorResult has drop {
        health_factor: u64,
        total_collateral_value: u64,
        total_debt_value: u64,
        liquidation_threshold_value: u64,
        time_to_liquidation: Option<u64>,
        is_liquidatable: bool,
    }

    public struct InterestRateResult has drop {
        supply_rate: u64,
        borrow_rate: u64,
        utilization_rate: u64,
        optimal_utilization: u64,
        rate_trend: String,
    }

    public struct LiquidationResult has drop {
        debt_repaid: u64,
        collateral_seized: u64,
        liquidation_bonus: u64,
        liquidator_profit: u64,
        borrower_health_factor: u64,
        gas_cost: u64,
    }

    public struct StakingResult has drop {
        new_tier: u64,
        new_multiplier: u64,
        borrow_rate_discount: u64,
        supply_rate_bonus: u64,
        benefits: vector<String>,
    }

    public struct BenefitCalculation has drop {
        base_rate: u64,
        discount_percentage: u64,
        final_rate: u64,
        reward_multiplier: u64,
        estimated_savings_annual: u64,
    }

    // Initialization functions
    public fun init_lending_protocol(ctx: &mut TxContext): AdminCap {
        let admin_cap = AdminCap { id: object::new(ctx) };
        
        let mut registry = LendingRegistry {
            id: object::new(ctx),
            supported_assets: table::new(ctx),
            lending_pools: table::new(ctx),
            interest_rate_models: table::new(ctx),
            global_params: GlobalParams {
                min_borrow_amount: 1000000, // $1 minimum borrow
                max_utilization_rate: 9500, // 95%
                close_factor: 5000, // 50%
                grace_period: 86400000, // 24 hours in ms
                flash_loan_fee: 9, // 0.09%
                protocol_fee: 1000, // 10%
            },
            risk_parameters: RiskParameters {
                max_assets_as_collateral: 10,
                health_factor_liquidation: 10000, // 1.0
                debt_ceiling_global: 1000000000000, // $1B limit
                liquidation_incentive: 500, // 5%
                max_liquidation_amount: 1000000000, // $1M per tx
            },
            oracle_feeds: table::new(ctx),
            admin_cap: option::none(),
            emergency_pause: false,
            version: 1,
        };
        
        let liquidation_engine = LiquidationEngine {
            id: object::new(ctx),
            operator: tx_context::sender(ctx),
            liquidation_threshold: 8500, // 85%
            liquidation_bonus: 500, // 5%
            max_liquidation_amount: 1000000000, // $1M
            spot_dex_registry: option::none(),
            flash_loan_providers: vec_set::empty(),
            total_liquidations: 0,
            total_volume_liquidated: 0,
            average_liquidation_time: 0,
            emergency_pause: false,
            whitelisted_liquidators: vec_set::empty(),
        };
        
        let mut yield_vault = YieldFarmingVault {
            id: object::new(ctx),
            unxv_rewards_per_second: 1000000, // 1 UNXV per second
            total_allocation_points: 0,
            pool_allocations: table::new(ctx),
            staked_unxv: table::new(ctx),
            stake_multipliers: table::new(ctx),
            total_rewards_distributed: 0,
            last_reward_timestamp: 0,
            reward_debt: table::new(ctx),
            is_active: true,
        };

        // Initialize stake multipliers
        init_stake_multipliers(&mut yield_vault, ctx);
        
        transfer::share_object(registry);
        transfer::share_object(liquidation_engine);
        transfer::share_object(yield_vault);

        admin_cap
    }

    // Initialize UNXV staking tier multipliers
    fun init_stake_multipliers(vault: &mut YieldFarmingVault, _ctx: &mut TxContext) {
        table::add(&mut vault.stake_multipliers, 0, 10000); // No stake: 1.0x
        table::add(&mut vault.stake_multipliers, 1, 10200); // Bronze: 1.02x (2% bonus)
        table::add(&mut vault.stake_multipliers, 2, 10500); // Silver: 1.05x (5% bonus)
        table::add(&mut vault.stake_multipliers, 3, 11000); // Gold: 1.10x (10% bonus)
        table::add(&mut vault.stake_multipliers, 4, 11500); // Platinum: 1.15x (15% bonus)
        table::add(&mut vault.stake_multipliers, 5, 12000); // Diamond: 1.20x (20% bonus)
    }

    // Admin functions for protocol configuration
    public fun add_supported_asset(
        registry: &mut LendingRegistry,
        _admin_cap: &AdminCap,
        asset_name: String,
        _asset_type: String,
        config: AssetConfig,
        rate_model: InterestRateModel,
        oracle_feed_id: vector<u8>,
        _ctx: &mut TxContext,
    ) {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        
        table::add(&mut registry.supported_assets, asset_name, config);
        table::add(&mut registry.interest_rate_models, asset_name, rate_model);
        table::add(&mut registry.oracle_feeds, asset_name, oracle_feed_id);
    }

    public fun create_lending_pool<T>(
        registry: &mut LendingRegistry,
        _admin_cap: &AdminCap,
        asset_name: String,
        ctx: &mut TxContext,
    ): ID {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(table::contains(&registry.supported_assets, asset_name), E_ASSET_NOT_SUPPORTED);
        
        let pool = LendingPool<T> {
            id: object::new(ctx),
            asset_name,
            total_supply: 0,
            total_borrows: 0,
            total_reserves: 0,
            cash: balance::zero<T>(),
            supply_index: INITIAL_EXCHANGE_RATE,
            borrow_index: INITIAL_EXCHANGE_RATE,
            last_update_timestamp: 0,
            current_supply_rate: 0,
            current_borrow_rate: 0,
            utilization_rate: 0,
            deepbook_pool_id: option::none(),
            synthetic_registry_id: option::none(),
            is_active: true,
            is_frozen: false,
        };
        
        let pool_id = object::id(&pool);
        table::add(&mut registry.lending_pools, asset_name, pool_id);
        transfer::share_object(pool);
        pool_id
    }
    
    // User account management
    public fun create_user_account(ctx: &mut TxContext): UserAccount {
        UserAccount {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            supply_balances: table::new(ctx),
            borrow_balances: table::new(ctx),
            total_collateral_value: 0,
            total_borrow_value: 0,
            health_factor: 0,
            assets_as_collateral: vec_set::empty(),
            last_health_check: 0,
            liquidation_threshold_breached: false,
            unxv_stake_amount: 0,
            reward_debt: table::new(ctx),
            auto_compound: false,
            max_slippage: 300, // 3%
            account_tier: 0,
        }
    }
    
    // Supply operations
    public fun supply_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        supply_coin: Coin<T>,
        use_as_collateral: bool,
        clock: &Clock,
        ctx: &mut TxContext,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
    ): SupplyReceipt {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(pool.is_active && !pool.is_frozen, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == account.owner, E_NOT_AUTHORIZED);

        let supply_amount = coin::value(&supply_coin);
        let asset_config = table::borrow(&registry.supported_assets, pool.asset_name);
        
        // Check supply cap
        assert!(pool.total_supply + supply_amount <= asset_config.supply_cap, E_SUPPLY_CAP_EXCEEDED);
        
        // Update interest rates before supply
        update_interest_rates(pool, registry, clock);
        
        // Calculate scaled amount based on current exchange rate
        let scaled_amount = (supply_amount * INITIAL_EXCHANGE_RATE) / pool.supply_index;
        
        // Add to pool cash
        let coin_balance = coin::into_balance(supply_coin);
        balance::join(&mut pool.cash, coin_balance);
        
        // Update pool totals
        pool.total_supply = pool.total_supply + supply_amount;
        
        // Update user position
        let current_timestamp = clock::timestamp_ms(clock);
        if (table::contains(&account.supply_balances, pool.asset_name)) {
            let position = table::borrow_mut(&mut account.supply_balances, pool.asset_name);
            position.scaled_balance = position.scaled_balance + scaled_amount;
            position.last_interest_index = pool.supply_index;
            if (use_as_collateral && asset_config.is_collateral) {
                position.is_collateral = true;
                vec_set::insert(&mut account.assets_as_collateral, pool.asset_name);
            };
        } else {
            let new_position = SupplyPosition {
                principal_amount: supply_amount,
                scaled_balance: scaled_amount,
                last_interest_index: pool.supply_index,
                is_collateral: use_as_collateral && asset_config.is_collateral,
                supply_timestamp: current_timestamp,
                last_reward_index: 0,
            };
            table::add(&mut account.supply_balances, pool.asset_name, new_position);
            if (use_as_collateral && asset_config.is_collateral) {
                vec_set::insert(&mut account.assets_as_collateral, pool.asset_name);
            };
        };
        
        // Emit supply event
        event::emit(AssetSupplied {
            user: account.owner,
            asset: pool.asset_name,
            amount: supply_amount,
            scaled_amount,
            new_balance: scaled_amount,
            is_collateral: use_as_collateral,
            supply_rate: pool.current_supply_rate,
            timestamp: current_timestamp,
        });
        
        SupplyReceipt {
            amount_supplied: supply_amount,
            scaled_amount,
            new_supply_rate: pool.current_supply_rate,
            interest_earned: 0, // First supply has no interest
        }
    }
    
    // Withdraw operations
    public fun withdraw_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        withdraw_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
    ): Coin<T> {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(pool.is_active, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == account.owner, E_NOT_AUTHORIZED);
        assert!(table::contains(&account.supply_balances, pool.asset_name), E_ASSET_NOT_SUPPORTED);
        
        // Update interest rates before withdrawal
        update_interest_rates(pool, registry, clock);
        
        // Check if withdrawal affects collateral health before borrowing position
        let asset_name = pool.asset_name;
        let is_collateral = {
            let position = table::borrow(&account.supply_balances, asset_name);
            position.is_collateral
        };
        
        if (is_collateral) {
            // Update account health after hypothetical withdrawal
            let position = table::borrow(&account.supply_balances, asset_name);
            let current_balance = position.scaled_balance;
            let scaled_withdraw = (withdraw_amount * INITIAL_EXCHANGE_RATE) / pool.supply_index;
            let new_scaled_balance = if (scaled_withdraw <= current_balance) { current_balance - scaled_withdraw } else { 0 };
            let hypothetical_health = calculate_health_factor_after_withdrawal(
                account, registry, asset_name, new_scaled_balance,
                collateral_asset_names, collateral_price_feeds, debt_asset_names, debt_price_feeds, clock
            );
            assert!(hypothetical_health >= MIN_HEALTH_FACTOR, E_HEALTH_FACTOR_TOO_LOW);
        };

        let position = table::borrow_mut(&mut account.supply_balances, asset_name);
        
        // Calculate current balance with accrued interest
        let current_balance = (position.scaled_balance * pool.supply_index) / INITIAL_EXCHANGE_RATE;
        assert!(withdraw_amount <= current_balance, E_INSUFFICIENT_LIQUIDITY);
        assert!(withdraw_amount <= balance::value(&pool.cash), E_INSUFFICIENT_LIQUIDITY);

        // Calculate scaled amount to deduct
        let scaled_withdraw = (withdraw_amount * INITIAL_EXCHANGE_RATE) / pool.supply_index;

        // Update position
        position.scaled_balance = position.scaled_balance - scaled_withdraw;
        position.last_interest_index = pool.supply_index;
        
        // If position becomes zero, remove collateral status
        if (position.scaled_balance == 0) {
            position.is_collateral = false;
            vec_set::remove(&mut account.assets_as_collateral, &pool.asset_name);
        };

        // Update pool totals
        pool.total_supply = pool.total_supply - withdraw_amount;
        
        // Withdraw from pool cash
        let withdrawn_balance = balance::split(&mut pool.cash, withdraw_amount);
        let withdrawal_coin = coin::from_balance(withdrawn_balance, ctx);

        // Emit withdrawal event
        let current_timestamp = clock::timestamp_ms(clock);
        event::emit(AssetWithdrawn {
            user: account.owner,
            asset: pool.asset_name,
            amount: withdraw_amount,
            scaled_amount: scaled_withdraw,
            remaining_balance: (position.scaled_balance * pool.supply_index) / INITIAL_EXCHANGE_RATE,
            interest_earned: current_balance - position.principal_amount,
            timestamp: current_timestamp,
        });

        withdrawal_coin
    }

    // Borrow operations
    public fun borrow_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        borrow_amount: u64,
        interest_rate_mode: String,
        clock: &Clock,
        ctx: &mut TxContext,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
    ): Coin<T> {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(pool.is_active && !pool.is_frozen, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == account.owner, E_NOT_AUTHORIZED);
        
        let asset_config = table::borrow(&registry.supported_assets, pool.asset_name);
        assert!(asset_config.is_borrowable, E_ASSET_NOT_SUPPORTED);
        assert!(borrow_amount >= registry.global_params.min_borrow_amount, E_INSUFFICIENT_COLLATERAL);
        assert!(pool.total_borrows + borrow_amount <= asset_config.borrow_cap, E_BORROW_CAP_EXCEEDED);
        assert!(borrow_amount <= balance::value(&pool.cash), E_INSUFFICIENT_LIQUIDITY);
        assert!(
            interest_rate_mode == std::string::utf8(b"VARIABLE") || 
            interest_rate_mode == std::string::utf8(b"STABLE"), 
            E_INVALID_INTEREST_RATE_MODE
        );

        // Update interest rates before borrow
        update_interest_rates(pool, registry, clock);

        // Calculate health factor after hypothetical borrow
        let health_after_borrow = calculate_health_factor_after_borrow(
            account, registry, pool.asset_name, borrow_amount, collateral_asset_names, collateral_price_feeds, debt_asset_names, debt_price_feeds, clock
        );
        assert!(health_after_borrow >= MIN_HEALTH_FACTOR, E_HEALTH_FACTOR_TOO_LOW);
        
        // Calculate scaled borrow amount
        let scaled_borrow = (borrow_amount * INITIAL_EXCHANGE_RATE) / pool.borrow_index;
        
        // Update user borrow position
        let current_timestamp = clock::timestamp_ms(clock);
        if (table::contains(&account.borrow_balances, pool.asset_name)) {
            let borrow_position = table::borrow_mut(&mut account.borrow_balances, pool.asset_name);
            borrow_position.scaled_balance = borrow_position.scaled_balance + scaled_borrow;
            borrow_position.last_interest_index = pool.borrow_index;
        } else {
            let new_borrow_position = BorrowPosition {
                principal_amount: borrow_amount,
                scaled_balance: scaled_borrow,
                last_interest_index: pool.borrow_index,
                interest_rate_mode,
                borrow_timestamp: current_timestamp,
                stable_rate: if (interest_rate_mode == std::string::utf8(b"STABLE")) {
                    option::some(pool.current_borrow_rate)
                } else {
                    option::none()
                },
            };
            table::add(&mut account.borrow_balances, pool.asset_name, new_borrow_position);
        };

        // Update pool totals
        pool.total_borrows = pool.total_borrows + borrow_amount;
        
        // Update utilization rate after borrow
        let total_liquidity = pool.total_supply + balance::value(&pool.cash);
        pool.utilization_rate = if (total_liquidity > 0) {
            (pool.total_borrows * BASIS_POINTS) / total_liquidity
        } else { 0 };
        
        // Apply UNXV discount if applicable
        let final_rate = apply_unxv_borrow_discount(pool.current_borrow_rate, account.account_tier);

        // Withdraw borrowed amount from pool
        let borrowed_balance = balance::split(&mut pool.cash, borrow_amount);
        let borrowed_coin = coin::from_balance(borrowed_balance, ctx);

        // Update account health factor
        account.health_factor = health_after_borrow;
        account.last_health_check = current_timestamp;

        // Emit borrow event
        event::emit(AssetBorrowed {
            user: account.owner,
            asset: pool.asset_name,
            amount: borrow_amount,
            scaled_amount: scaled_borrow,
            new_borrow_balance: scaled_borrow,
            borrow_rate: final_rate,
            health_factor: health_after_borrow,
            timestamp: current_timestamp,
        });

        borrowed_coin
    }

    // Repay operations
    public fun repay_debt<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        repay_coin: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
    ): RepayReceipt {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(pool.is_active, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == account.owner, E_NOT_AUTHORIZED);
        assert!(table::contains(&account.borrow_balances, pool.asset_name), E_ASSET_NOT_SUPPORTED);
        
        // Update interest rates before repay
        update_interest_rates(pool, registry, clock);
        
        let borrow_position = table::borrow_mut(&mut account.borrow_balances, pool.asset_name);
        let repay_amount = coin::value(&repay_coin);
        
        // Calculate current debt with accrued interest
        let current_debt = (borrow_position.scaled_balance * pool.borrow_index) / INITIAL_EXCHANGE_RATE;
        let actual_repay = math::min(repay_amount, current_debt);
        let interest_paid = current_debt - borrow_position.principal_amount;

        // Calculate scaled repay amount
        let scaled_repay = (actual_repay * INITIAL_EXCHANGE_RATE) / pool.borrow_index;

        // Update borrow position
        borrow_position.scaled_balance = borrow_position.scaled_balance - scaled_repay;
        borrow_position.last_interest_index = pool.borrow_index;
        
        // If debt is fully repaid, remove position
        let remaining_debt = (borrow_position.scaled_balance * pool.borrow_index) / INITIAL_EXCHANGE_RATE;
        
        // Update pool totals
        pool.total_borrows = pool.total_borrows - actual_repay;
        
        // Add repayment to pool reserves (protocol fee)
        let asset_config = table::borrow(&registry.supported_assets, pool.asset_name);
        let reserve_amount = (actual_repay * asset_config.reserve_factor) / BASIS_POINTS;
        pool.total_reserves = pool.total_reserves + reserve_amount;
        
        // Add to pool cash
        let repay_balance = coin::into_balance(repay_coin);
        balance::join(&mut pool.cash, repay_balance);

        // Calculate health factor improvement
        let new_health_factor = calculate_current_health_factor(account, registry, collateral_asset_names, collateral_price_feeds, debt_asset_names, debt_price_feeds, clock);
        let health_improvement = if (new_health_factor > account.health_factor) {
            new_health_factor - account.health_factor
        } else { 0 };
        
        account.health_factor = new_health_factor;
        account.last_health_check = clock::timestamp_ms(clock);

        // Emit repay event
        event::emit(DebtRepaid {
            user: account.owner,
            asset: pool.asset_name,
            amount: actual_repay,
            scaled_amount: scaled_repay,
            remaining_debt,
            interest_paid,
            timestamp: clock::timestamp_ms(clock),
        });
        
        RepayReceipt {
            amount_repaid: actual_repay,
            interest_paid,
            remaining_debt,
            health_factor_improvement: health_improvement,
        }
    }
    
    // Interest rate calculation and updates
    public fun update_interest_rates<T>(
        pool: &mut LendingPool<T>,
        registry: &LendingRegistry,
        clock: &Clock,
    ) {
        let rate_model = table::borrow(&registry.interest_rate_models, pool.asset_name);
        let current_timestamp = clock::timestamp_ms(clock);
        
        // Calculate time elapsed since last update
        let time_elapsed = if (pool.last_update_timestamp > 0) {
            current_timestamp - pool.last_update_timestamp
        } else { 0 };

        // Apply compound interest if time has passed
        if (time_elapsed > 0) {
            let interest_accumulated = calculate_compound_interest(pool, time_elapsed);
            pool.total_borrows = pool.total_borrows + interest_accumulated;
        };

        // Calculate utilization rate
        let total_liquidity = pool.total_supply + balance::value(&pool.cash);
        pool.utilization_rate = if (total_liquidity > 0) {
            (pool.total_borrows * BASIS_POINTS) / total_liquidity
        } else { 0 };

        // Calculate new rates based on utilization
        let old_supply_rate = pool.current_supply_rate;
        let old_borrow_rate = pool.current_borrow_rate;
        
        let new_rates = calculate_interest_rates_from_model(rate_model, pool.utilization_rate);
        pool.current_borrow_rate = new_rates.borrow_rate;
        pool.current_supply_rate = new_rates.supply_rate;
        pool.last_update_timestamp = current_timestamp;

        // Update interest indexes
        if (time_elapsed > 0) {
            update_interest_indexes(pool, time_elapsed);
        };

        // Emit rate update event
        event::emit(InterestRatesUpdated {
            asset: pool.asset_name,
            old_supply_rate,
            new_supply_rate: pool.current_supply_rate,
            old_borrow_rate,
            new_borrow_rate: pool.current_borrow_rate,
            utilization_rate: pool.utilization_rate,
            total_supply: pool.total_supply,
            total_borrows: pool.total_borrows,
            timestamp: current_timestamp,
        });
    }
    
    // Helper function to calculate interest rates from model
    fun calculate_interest_rates_from_model(
        model: &InterestRateModel,
        utilization: u64,
    ): InterestRateResult {
        let borrow_rate = if (utilization <= model.optimal_utilization) {
            // Before kink: base_rate + (utilization * multiplier / optimal_utilization)
            model.base_rate + (utilization * model.multiplier) / model.optimal_utilization
        } else {
            // After kink: base_rate + multiplier + ((utilization - optimal) * jump_multiplier / (100% - optimal))
            let excess_utilization = utilization - model.optimal_utilization;
            let excess_multiplier = (excess_utilization * model.jump_multiplier) / 
                                   (BASIS_POINTS - model.optimal_utilization);
            model.base_rate + model.multiplier + excess_multiplier
        };

        // Cap at max rate for safety
        let final_borrow_rate = math::min(borrow_rate, model.max_rate);
        
        // Supply rate = borrow_rate * utilization * (1 - reserve_factor)
        let supply_rate = (final_borrow_rate * utilization * 9000) / (BASIS_POINTS * BASIS_POINTS); // 90% to suppliers

        InterestRateResult {
            supply_rate,
            borrow_rate: final_borrow_rate,
            utilization_rate: utilization,
            optimal_utilization: model.optimal_utilization,
            rate_trend: std::string::utf8(b"STABLE"), // Simplified for now
        }
    }

    // Calculate compound interest accumulation
    fun calculate_compound_interest<T>(pool: &LendingPool<T>, time_elapsed_ms: u64): u64 {
        if (pool.total_borrows == 0) return 0;
        
        // Convert milliseconds to seconds, then to years
        let time_elapsed_years = (time_elapsed_ms / 1000) / SECONDS_PER_YEAR;
        
        // Simple interest calculation: principal * rate * time
        // For production, should use compound interest formula
        (pool.total_borrows * pool.current_borrow_rate * time_elapsed_years) / BASIS_POINTS
    }

    // Update supply and borrow indexes for interest accrual
    fun update_interest_indexes<T>(pool: &mut LendingPool<T>, time_elapsed_ms: u64) {
        let time_elapsed_years = (time_elapsed_ms / 1000) / SECONDS_PER_YEAR;
        
        // Update borrow index
        let borrow_interest_factor = 1 + (pool.current_borrow_rate * time_elapsed_years) / BASIS_POINTS;
        pool.borrow_index = (pool.borrow_index * borrow_interest_factor) / 1;
        
        // Update supply index  
        let supply_interest_factor = 1 + (pool.current_supply_rate * time_elapsed_years) / BASIS_POINTS;
        pool.supply_index = (pool.supply_index * supply_interest_factor) / 1;
    }

    // Health factor calculations
    /// Calculate current health factor given explicit asset names and price feeds
    /// asset_names and price_feeds must be parallel arrays for all collateral and debt assets
    public fun calculate_current_health_factor(
        account: &UserAccount,
        registry: &LendingRegistry,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
    ): u64 {
        let mut total_collateral_value = 0;
        let collateral_len = vector::length(collateral_asset_names);
        let mut i = 0;
        while (i < collateral_len) {
            let asset_name = *vector::borrow(collateral_asset_names, i);
            if (table::contains(&account.supply_balances, asset_name)) {
                let position = table::borrow(&account.supply_balances, asset_name);
                if (position.is_collateral) {
                    let asset_config = table::borrow(&registry.supported_assets, asset_name);
                    let asset_price = get_asset_price(registry, collateral_price_feeds, asset_name, clock);
                    let balance_value = position.scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                    total_collateral_value = total_collateral_value + (balance_value * asset_config.collateral_factor) / BASIS_POINTS;
                };
            };
            i = i + 1;
        };
        
        let mut total_debt_value = 0;
        let debt_len = vector::length(debt_asset_names);
        let mut j = 0;
        while (j < debt_len) {
            let asset_name = *vector::borrow(debt_asset_names, j);
            if (table::contains(&account.borrow_balances, asset_name)) {
                let borrow_position = table::borrow(&account.borrow_balances, asset_name);
                let asset_price = get_asset_price(registry, debt_price_feeds, asset_name, clock);
                let debt_value = borrow_position.scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                total_debt_value = total_debt_value + debt_value;
            };
            j = j + 1;
        };
        
        if (total_debt_value == 0) {
            BASIS_POINTS * 10
        } else {
            (total_collateral_value * BASIS_POINTS) / total_debt_value
        }
    }

    /// Calculate health factor after withdrawal for a specific asset
    /// The caller must pass the hypothetical new scaled balance for the asset being withdrawn
    public fun calculate_health_factor_after_withdrawal(
        account: &UserAccount,
        registry: &LendingRegistry,
        asset_name: String,
        new_scaled_balance: u64,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
    ): u64 {
        let mut total_collateral_value = 0;
        let collateral_len = vector::length(collateral_asset_names);
        let mut i = 0;
        while (i < collateral_len) {
            let name = *vector::borrow(collateral_asset_names, i);
            if (name == asset_name) {
                if (table::contains(&account.supply_balances, name)) {
                    let position = table::borrow(&account.supply_balances, name);
                    if (position.is_collateral) {
                        let asset_config = table::borrow(&registry.supported_assets, name);
                        let asset_price = get_asset_price(registry, collateral_price_feeds, name, clock);
                        let balance_value = new_scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                        total_collateral_value = total_collateral_value + (balance_value * asset_config.collateral_factor) / BASIS_POINTS;
                    };
                };
            } else if (table::contains(&account.supply_balances, name)) {
                let position = table::borrow(&account.supply_balances, name);
                if (position.is_collateral) {
                    let asset_config = table::borrow(&registry.supported_assets, name);
                    let asset_price = get_asset_price(registry, collateral_price_feeds, name, clock);
                    let balance_value = position.scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                    total_collateral_value = total_collateral_value + (balance_value * asset_config.collateral_factor) / BASIS_POINTS;
                };
            };
            i = i + 1;
        };
        
        let mut total_debt_value = 0;
        let debt_len = vector::length(debt_asset_names);
        let mut j = 0;
        while (j < debt_len) {
            let name = *vector::borrow(debt_asset_names, j);
            if (table::contains(&account.borrow_balances, name)) {
                let borrow_position = table::borrow(&account.borrow_balances, name);
                let asset_price = get_asset_price(registry, debt_price_feeds, name, clock);
                let debt_value = borrow_position.scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                total_debt_value = total_debt_value + debt_value;
            };
            j = j + 1;
        };
        
        if (total_debt_value == 0) {
            BASIS_POINTS * 10
        } else {
            (total_collateral_value * BASIS_POINTS) / total_debt_value
        }
    }

    /// Calculate health factor after borrow for a specific asset
    /// The caller must pass the hypothetical new scaled debt for the asset being borrowed
    public fun calculate_health_factor_after_borrow(
        account: &UserAccount,
        registry: &LendingRegistry,
        asset_name: String,
        new_scaled_debt: u64,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
    ): u64 {
        let mut total_collateral_value = 0;
        let collateral_len = vector::length(collateral_asset_names);
        let mut i = 0;
        while (i < collateral_len) {
            let name = *vector::borrow(collateral_asset_names, i);
            if (table::contains(&account.supply_balances, name)) {
                let position = table::borrow(&account.supply_balances, name);
                if (position.is_collateral) {
                    let asset_config = table::borrow(&registry.supported_assets, name);
                    let asset_price = get_asset_price(registry, collateral_price_feeds, name, clock);
                    let balance_value = position.scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                    total_collateral_value = total_collateral_value + (balance_value * asset_config.collateral_factor) / BASIS_POINTS;
                };
            };
            i = i + 1;
        };
        
        let mut total_debt_value = 0;
        let debt_len = vector::length(debt_asset_names);
        let mut j = 0;
        while (j < debt_len) {
            let name = *vector::borrow(debt_asset_names, j);
            if (name == asset_name) {
                let asset_price = get_asset_price(registry, debt_price_feeds, name, clock);
                let debt_value = new_scaled_debt * asset_price / INITIAL_EXCHANGE_RATE;
                total_debt_value = total_debt_value + debt_value;
            } else if (table::contains(&account.borrow_balances, name)) {
                let borrow_position = table::borrow(&account.borrow_balances, name);
                let asset_price = get_asset_price(registry, debt_price_feeds, name, clock);
                let debt_value = borrow_position.scaled_balance * asset_price / INITIAL_EXCHANGE_RATE;
                total_debt_value = total_debt_value + debt_value;
            };
            j = j + 1;
        };
        
        if (total_debt_value == 0) {
            BASIS_POINTS * 10
        } else {
            (total_collateral_value * BASIS_POINTS) / total_debt_value
        }
    }

    // UNXV benefits calculation
    fun apply_unxv_borrow_discount(base_rate: u64, tier: u64): u64 {
        let discount = if (tier == 0) {
            0      // No discount
        } else if (tier == 1) {
            500    // 5% discount
        } else if (tier == 2) {
            1000   // 10% discount
        } else if (tier == 3) {
            1500   // 15% discount
        } else if (tier == 4) {
            2000   // 20% discount
        } else if (tier == 5) {
            2500   // 25% discount
        } else {
            0
        };
        
        let discounted_amount = (base_rate * discount) / BASIS_POINTS;
        if (base_rate > discounted_amount) {
            base_rate - discounted_amount
        } else {
            0
        }
    }

    // UNXV staking operations
    public fun stake_unxv_for_benefits<UNXV>(
        vault: &mut YieldFarmingVault,
        account: &mut UserAccount,
        stake_coin: Coin<UNXV>,
        lock_duration: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): StakingResult {
        assert!(vault.is_active, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == account.owner, E_NOT_AUTHORIZED);

        let stake_amount = coin::value(&stake_coin);
        let current_timestamp = clock::timestamp_ms(clock);

        // Calculate new total staked amount
        let existing_amount = if (table::contains(&vault.staked_unxv, account.owner)) {
            let existing_stake = table::borrow(&vault.staked_unxv, account.owner);
            existing_stake.amount
        } else {
            0
        };

        let new_total_stake = existing_amount + stake_amount;
        let new_tier = calculate_stake_tier(new_total_stake);
        let new_multiplier = *table::borrow(&vault.stake_multipliers, new_tier);
        
        // Create or update stake position
        let stake_position = StakePosition {
            amount: new_total_stake,
            stake_timestamp: current_timestamp,
            tier: new_tier,
            multiplier: new_multiplier,
            locked_until: current_timestamp + lock_duration,
            rewards_earned: 0,
        };
        
        if (table::contains(&vault.staked_unxv, account.owner)) {
            let existing = table::borrow_mut(&mut vault.staked_unxv, account.owner);
            *existing = stake_position;
        } else {
            table::add(&mut vault.staked_unxv, account.owner, stake_position);
        };
        
        // Update account tier and stake amount
        account.account_tier = new_tier;
        account.unxv_stake_amount = new_total_stake;

        // Destroy the staked coin (simplified for v1)
        transfer::public_transfer(stake_coin, @0x0); // Burn the staked coin
        
        let benefits = calculate_tier_benefits(new_tier);
        
        // Emit staking event
        event::emit(UnxvStaked {
            user: account.owner,
            amount: stake_amount,
            new_tier,
            new_multiplier,
            lock_duration,
            benefits,
            timestamp: current_timestamp,
        });
        
        StakingResult {
            new_tier,
            new_multiplier,
            borrow_rate_discount: get_tier_borrow_discount(new_tier),
            supply_rate_bonus: get_tier_supply_bonus(new_tier),
            benefits,
        }
    }
    
    // Calculate UNXV stake tier based on amount
    fun calculate_stake_tier(amount: u64): u64 {
        if (amount >= 500000000) { // 500,000 UNXV
            5 // Diamond
        } else if (amount >= 100000000) { // 100,000 UNXV
            4 // Platinum
        } else if (amount >= 25000000) { // 25,000 UNXV
            3 // Gold
        } else if (amount >= 5000000) { // 5,000 UNXV
            2 // Silver
        } else if (amount >= 1000000) { // 1,000 UNXV
            1 // Bronze
        } else {
            0 // No tier
        }
    }

    // Get borrow rate discount for tier
    fun get_tier_borrow_discount(tier: u64): u64 {
        if (tier == 5) {
            2500       // 25%
        } else if (tier == 4) {
            2000  // 20%
        } else if (tier == 3) {
            1500  // 15%
        } else if (tier == 2) {
            1000  // 10%
        } else if (tier == 1) {
            500   // 5%
        } else {
            0
        }
    }

    // Get supply rate bonus for tier
    fun get_tier_supply_bonus(tier: u64): u64 {
        if (tier == 5) {
            2000       // 20%
        } else if (tier == 4) {
            1500  // 15%
        } else if (tier == 3) {
            1000  // 10%
        } else if (tier == 2) {
            500   // 5%
        } else if (tier == 1) {
            200   // 2%
        } else {
            0
        }
    }

    // Calculate tier benefits
    fun calculate_tier_benefits(tier: u64): vector<String> {
        let mut benefits = vector::empty<String>();
        if (tier >= 1) {
            vector::push_back(&mut benefits, std::string::utf8(b"Borrow Rate Discount"));
            vector::push_back(&mut benefits, std::string::utf8(b"Supply Rate Bonus"));
        };
        if (tier >= 3) {
            vector::push_back(&mut benefits, std::string::utf8(b"Priority Liquidation Protection"));
        };
        if (tier >= 5) {
            vector::push_back(&mut benefits, std::string::utf8(b"Exclusive Strategy Access"));
        };
        benefits
    }
    
    // Claim UNXV rewards from yield farming
    public fun claim_yield_rewards<UNXV>(
        vault: &mut YieldFarmingVault,
        account: &mut UserAccount,
        _pools_to_claim: vector<String>,
        auto_compound: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<UNXV> {
        assert!(vault.is_active, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == account.owner, E_NOT_AUTHORIZED);

        let current_timestamp = clock::timestamp_ms(clock);
        let total_rewards = 0; // Simplified calculation for v1

        // Update reward tracking
        account.auto_compound = auto_compound;

        // Emit rewards claimed event
        event::emit(RewardsClaimed {
            user: account.owner,
            unxv_amount: total_rewards,
            bonus_multiplier: if (table::contains(&vault.staked_unxv, account.owner)) {
                let stake_pos = table::borrow(&vault.staked_unxv, account.owner);
                stake_pos.multiplier
            } else {
                10000
            },
            stake_tier: account.account_tier,
            total_rewards_earned: total_rewards,
            timestamp: current_timestamp,
        });

        // Return rewards coin (simplified for v1)
        coin::zero<UNXV>(ctx)
    }

    // Flash loan operations
    public fun initiate_flash_loan<T>(
        pool: &mut LendingPool<T>,
        registry: &LendingRegistry,
        loan_amount: u64,
        ctx: &mut TxContext,
    ): (Coin<T>, FlashLoan) {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(pool.is_active, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(loan_amount > 0, E_INSUFFICIENT_COLLATERAL);
        assert!(balance::value(&pool.cash) >= loan_amount, E_INSUFFICIENT_LIQUIDITY);
        
        let fee = (loan_amount * registry.global_params.flash_loan_fee) / BASIS_POINTS;
        
        let flash_loan = FlashLoan {
            pool_id: object::id(pool),
            asset_name: pool.asset_name,
            amount: loan_amount,
            fee,
            recipient: tx_context::sender(ctx),
        };
        
        let loan_balance = balance::split(&mut pool.cash, loan_amount);
        let loan_coin = coin::from_balance(loan_balance, ctx);
        
        // Emit flash loan event
        event::emit(FlashLoanExecuted {
            borrower: tx_context::sender(ctx),
            asset: pool.asset_name,
            amount: loan_amount,
            fee,
            purpose: std::string::utf8(b"FLASH_LOAN"),
            timestamp: 0, // Would use clock in production
        });
        
        (loan_coin, flash_loan)
    }
    
    public fun repay_flash_loan<T>(
        pool: &mut LendingPool<T>,
        registry: &LendingRegistry,
        loan_repayment: Coin<T>,
        flash_loan: FlashLoan,
        ctx: &mut TxContext,
    ) {
        assert!(!registry.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(flash_loan.recipient == tx_context::sender(ctx), E_NOT_AUTHORIZED);
        assert!(flash_loan.pool_id == object::id(pool), E_POOL_NOT_EXISTS);
        
        let repay_amount = coin::value(&loan_repayment);
        let required_amount = flash_loan.amount + flash_loan.fee;
        assert!(repay_amount >= required_amount, E_FLASH_LOAN_NOT_REPAID);
        
        // Add repayment to pool
        balance::join(&mut pool.cash, coin::into_balance(loan_repayment));
        
        // Add fee to reserves
        pool.total_reserves = pool.total_reserves + flash_loan.fee;

        // Destroy flash loan (hot potato consumed)
        let FlashLoan { 
            pool_id: _, 
            asset_name: _, 
            amount: _, 
            fee: _, 
            recipient: _ 
        } = flash_loan;
    }

    // Calculate current account health factor
    public fun calculate_health_factor(
        account: &UserAccount,
        registry: &LendingRegistry,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
    ): HealthFactorResult {
        let _current_timestamp = clock::timestamp_ms(clock);
        let health_factor = calculate_current_health_factor(
            account,
            registry,
            collateral_asset_names,
            collateral_price_feeds,
            debt_asset_names,
            debt_price_feeds,
            clock
        );
        HealthFactorResult {
            health_factor,
            total_collateral_value: account.total_collateral_value,
            total_debt_value: account.total_borrow_value,
            liquidation_threshold_value: (account.total_collateral_value * LIQUIDATION_THRESHOLD) / BASIS_POINTS,
            time_to_liquidation: option::none<u64>(), // Would calculate based on price trends
            is_liquidatable: health_factor < MIN_HEALTH_FACTOR,
        }
    }

    // Basic liquidation function (simplified for v1)
    public fun liquidate_position<T, C>(
        liquidation_engine: &mut LiquidationEngine,
        borrower_account: &mut UserAccount,
        liquidator_account: &mut UserAccount,
        debt_pool: &mut LendingPool<T>,
        collateral_pool: &mut LendingPool<C>,
        registry: &LendingRegistry,
        liquidation_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
        collateral_asset_names: &vector<String>,
        collateral_price_feeds: &vector<PriceInfoObject>,
        debt_asset_names: &vector<String>,
        debt_price_feeds: &vector<PriceInfoObject>,
    ): LiquidationResult {
        assert!(!liquidation_engine.emergency_pause, E_EMERGENCY_PAUSE_ACTIVE);
        assert!(tx_context::sender(ctx) == liquidator_account.owner, E_NOT_AUTHORIZED);

        // Check if borrower is liquidatable
        let health_result = calculate_current_health_factor(borrower_account, registry, collateral_asset_names, collateral_price_feeds, debt_asset_names, debt_price_feeds, clock);
        assert!(health_result < MIN_HEALTH_FACTOR, E_LIQUIDATION_NOT_ALLOWED);

        let current_timestamp = clock::timestamp_ms(clock);

        // Simplified liquidation calculation
        let collateral_seized = (liquidation_amount * (BASIS_POINTS + liquidation_engine.liquidation_bonus)) / BASIS_POINTS;
        let liquidator_profit = (liquidation_amount * liquidation_engine.liquidation_bonus) / BASIS_POINTS;

        // Update liquidation engine stats
        liquidation_engine.total_liquidations = liquidation_engine.total_liquidations + 1;
        liquidation_engine.total_volume_liquidated = liquidation_engine.total_volume_liquidated + liquidation_amount;

        // Emit liquidation event
        event::emit(LiquidationExecuted {
            liquidator: liquidator_account.owner,
            borrower: borrower_account.owner,
            collateral_asset: collateral_pool.asset_name,
            debt_asset: debt_pool.asset_name,
            debt_amount: liquidation_amount,
            collateral_seized,
            liquidation_bonus: liquidation_engine.liquidation_bonus,
            health_factor_before: health_result,
            health_factor_after: MIN_HEALTH_FACTOR + 1000, // Simplified
            flash_loan_used: false,
            timestamp: current_timestamp,
        });

        LiquidationResult {
            debt_repaid: liquidation_amount,
            collateral_seized,
            liquidation_bonus: liquidation_engine.liquidation_bonus,
            liquidator_profit,
            borrower_health_factor: MIN_HEALTH_FACTOR + 1000, // Simplified
            gas_cost: 1000000, // Estimated gas cost
        }
    }

    // Emergency pause functions
    public fun emergency_pause_protocol(
        registry: &mut LendingRegistry,
        _admin_cap: &AdminCap,
        _ctx: &TxContext,
    ) {
        registry.emergency_pause = true;
    }

    public fun resume_protocol(
        registry: &mut LendingRegistry,
        _admin_cap: &AdminCap,
        _ctx: &TxContext,
    ) {
        registry.emergency_pause = false;
    }

    // Protocol fee management
    public fun process_protocol_fees(
        _registry: &mut LendingRegistry,
        collected_fees: Table<String, u64>,
        _ctx: &mut TxContext,
    ) {
        let total_fees = 0;
        let fee_sources = vector::empty<String>();

        // Calculate total fees (simplified)
        // In production, would iterate through all pools
        table::destroy_empty(collected_fees); // Destroy the empty table

        // Emit fee processing event
        event::emit(ProtocolFeesProcessed {
            total_fees_collected: total_fees,
            unxv_burned: total_fees / 2, // 50% burned
            reserve_allocation: total_fees / 2, // 50% to reserves
            fee_sources,
            timestamp: 0, // Would use clock
        });
    }

    /// Helper to fetch and validate asset price from Pyth
    public fun get_asset_price(
        registry: &LendingRegistry,
        price_feeds: &vector<PriceInfoObject>,
        asset: String,
        clock: &Clock
    ): u64 {
        assert!(!vector::is_empty(price_feeds), E_ASSET_NOT_SUPPORTED);
        let price_info_object = vector::borrow(price_feeds, 0);
        let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
        let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
        assert!(table::contains(&registry.oracle_feeds, asset), E_ASSET_NOT_SUPPORTED);
        let expected_feed_id = table::borrow(&registry.oracle_feeds, asset);
        assert!(price_id == *expected_feed_id, E_ASSET_NOT_SUPPORTED);
        let price_struct = pyth::get_price_no_older_than(price_info_object, clock, 60_000); // 60s
        let price_i64 = price::get_price(&price_struct);
        let price_u64 = pyth_i64::get_magnitude_if_positive(&price_i64);
        assert!(price_u64 > 0, E_ASSET_NOT_SUPPORTED);
        let expo = price::get_expo(&price_struct);
        let expo_magnitude = pyth_i64::get_magnitude_if_positive(&expo);
        if (expo_magnitude <= 8) {
            price_u64 * 1000000 // Scale to 6 decimals for USD prices
        } else {
            price_u64 / 100 // Handle very large exponents
        }
    }

    // Test-only functions for internal state inspection
    #[test_only]
    public fun get_pool_total_supply<T>(pool: &LendingPool<T>): u64 {
        return pool.total_supply;
    }

    #[test_only]
    public fun get_pool_total_borrows<T>(pool: &LendingPool<T>): u64 {
        return pool.total_borrows;
    }

    #[test_only]
    public fun get_pool_utilization<T>(pool: &LendingPool<T>): u64 {
        return pool.utilization_rate;
    }

    #[test_only]
    public fun get_user_supply_balance(account: &UserAccount, asset: String): u64 {
        if (table::contains(&account.supply_balances, asset)) {
            let position = table::borrow(&account.supply_balances, asset);
            return position.scaled_balance;
        } else {
            return 0;
        }
    }

    #[test_only]
    public fun get_user_borrow_balance(account: &UserAccount, asset: String): u64 {
        if (table::contains(&account.borrow_balances, asset)) {
            let position = table::borrow(&account.borrow_balances, asset);
            return position.scaled_balance;
        } else {
            return 0;
        }
    }
    
    #[test_only]
    public fun get_user_health_factor(account: &UserAccount): u64 {
        return account.health_factor;
    }
    
    #[test_only]
    public fun is_emergency_paused(registry: &LendingRegistry): bool {
        return registry.emergency_pause;
    }
    
    // Test helper functions for creating structs
    #[test_only]
    public fun create_test_asset_config_struct(
        asset_name: String,
        asset_type: String,
        is_collateral: bool,
        is_borrowable: bool,
        collateral_factor: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        supply_cap: u64,
        borrow_cap: u64,
        reserve_factor: u64,
        is_active: bool,
    ): AssetConfig {
        return AssetConfig {
            asset_name,
            asset_type,
            is_collateral,
            is_borrowable,
            collateral_factor,
            liquidation_threshold,
            liquidation_penalty,
            supply_cap,
            borrow_cap,
            reserve_factor,
            is_active,
        };
    }
    
    #[test_only]
    public fun create_test_interest_model_struct(
        base_rate: u64,
        multiplier: u64,
        jump_multiplier: u64,
        optimal_utilization: u64,
        max_rate: u64,
    ): InterestRateModel {
        return InterestRateModel {
            base_rate,
            multiplier,
            jump_multiplier,
            optimal_utilization,
            max_rate,
        };
    }

    // Getter functions for result structs (for testing)
    public fun supply_receipt_amount_supplied(receipt: &SupplyReceipt): u64 {
        receipt.amount_supplied
    }

    public fun repay_receipt_amount_repaid(receipt: &RepayReceipt): u64 {
        receipt.amount_repaid
    }

    public fun health_factor_result_health_factor(result: &HealthFactorResult): u64 {
        result.health_factor
    }

    public fun health_factor_result_is_liquidatable(result: &HealthFactorResult): bool {
        result.is_liquidatable
    }

    public fun staking_result_new_tier(result: &StakingResult): u64 {
        result.new_tier
    }

    public fun staking_result_borrow_rate_discount(result: &StakingResult): u64 {
        result.borrow_rate_discount
    }

    public fun staking_result_supply_rate_bonus(result: &StakingResult): u64 {
        result.supply_rate_bonus
    }
}


