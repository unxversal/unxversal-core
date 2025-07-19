/// Module: unxv_lending
/// UnXversal Lending Protocol - Permissionless lending and borrowing with UNXV integration
/// Supports supply/borrow operations, leveraged trading, flash loans, and yield farming
#[allow(duplicate_alias, unused_use, unused_const, unused_variable, unused_function)]
module unxv_lending::unxv_lending {
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
    
    // Pyth Network integration for price feeds
    use pyth::price_info::{PriceInfoObject};
    
    // USDC and other standard coins
    public struct USDC has drop {}
    public struct SUI has drop {}
    public struct UNXV has drop {}
    
    // ========== Error Constants ==========
    
    const E_NOT_ADMIN: u64 = 1;
    const E_ASSET_NOT_SUPPORTED: u64 = 2;
    const E_INSUFFICIENT_COLLATERAL: u64 = 3;
    const E_HEALTH_FACTOR_TOO_LOW: u64 = 4;
    const E_AMOUNT_TOO_SMALL: u64 = 5;
    const E_EXCEED_SUPPLY_CAP: u64 = 6;
    const E_EXCEED_BORROW_CAP: u64 = 7;
    const E_ASSET_NOT_BORROWABLE: u64 = 8;
    const E_ASSET_NOT_COLLATERAL: u64 = 9;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 10;
    const E_FLASH_LOAN_NOT_REPAID: u64 = 12;
    const E_INVALID_INTEREST_RATE_MODE: u64 = 13;
    const E_SYSTEM_PAUSED: u64 = 15;
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const SECONDS_PER_YEAR: u64 = 31536000;
    const MIN_HEALTH_FACTOR: u64 = 10000; // 1.0 = 100%
    const LIQUIDATION_BONUS: u64 = 500; // 5%
    const FLASH_LOAN_FEE: u64 = 9; // 0.09%
    const MAX_UTILIZATION_RATE: u64 = 9500; // 95%
    const GRACE_PERIOD: u64 = 300000; // 5 minutes in ms
    
    // UNXV Stake Tiers
    const TIER_1_THRESHOLD: u64 = 1000000; // 1,000 UNXV (6 decimals)
    const TIER_2_THRESHOLD: u64 = 5000000; // 5,000 UNXV
    const TIER_3_THRESHOLD: u64 = 25000000; // 25,000 UNXV
    const TIER_4_THRESHOLD: u64 = 100000000; // 100,000 UNXV
    const TIER_5_THRESHOLD: u64 = 500000000; // 500,000 UNXV
    
    // ========== Core Data Structures ==========
    
    /// Central registry for all lending operations and configurations
    public struct LendingRegistry has key {
        id: UID,
        supported_assets: Table<String, AssetConfig>,
        lending_pools: Table<String, ID>,
        interest_rate_models: Table<String, InterestRateModel>,
        global_params: GlobalParams,
        risk_parameters: RiskParameters,
        oracle_feeds: Table<String, vector<u8>>,
        admin_cap: Option<AdminCap>,
        total_users: u64,
        total_supply_usd: u64,
        total_borrows_usd: u64,
        is_paused: bool,
    }
    
    /// Configuration for each supported asset
    #[allow(unused_field)]
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
        decimals: u8,
        price_feed_id: vector<u8>,
    }
    
    /// Global system parameters
    public struct GlobalParams has store, drop {
        min_borrow_amount: u64,
        max_utilization_rate: u64,
        close_factor: u64, // 50% = 5000 basis points
        grace_period: u64,
        flash_loan_fee: u64,
        protocol_fee_rate: u64,
    }
    
    /// Risk management parameters
    public struct RiskParameters has store, drop {
        max_assets_as_collateral: u8,
        health_factor_liquidation: u64,
        debt_ceiling_global: u64,
        liquidation_incentive: u64,
    }
    
    /// Interest rate model for dynamic rate calculation
    public struct InterestRateModel has store, drop {
        base_rate: u64, // Base APR
        multiplier: u64, // Rate slope factor
        jump_multiplier: u64, // Rate after optimal utilization
        optimal_utilization: u64, // Kink point
    }
    
    /// Admin capability for privileged operations
    public struct AdminCap has key, store {
        id: UID,
    }
    
    /// Individual lending pool for each asset
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
        
        // Current rates
        current_supply_rate: u64,
        current_borrow_rate: u64,
        utilization_rate: u64,
        
        // Integration
        deepbook_pool_id: Option<ID>,
        synthetic_registry_id: Option<ID>,
    }
    
    /// User account for tracking positions and health
    public struct UserAccount has key, store {
        id: UID,
        owner: address,
        supply_balances: Table<String, SupplyPosition>,
        borrow_balances: Table<String, BorrowPosition>,
        health_factor: u64,
        total_collateral_value: u64,
        total_borrow_value: u64,
        liquidation_threshold_breached: bool,
        last_health_check: u64,
        account_tier: u64, // UNXV staking tier
        last_reward_claim: u64,
    }
    
    /// Supply position details
    public struct SupplyPosition has store {
        principal_amount: u64,
        scaled_balance: u64,
        last_interest_index: u64,
        is_collateral: bool,
        supply_timestamp: u64,
    }
    
    /// Borrow position details
    public struct BorrowPosition has store {
        principal_amount: u64,
        scaled_balance: u64,
        last_interest_index: u64,
        interest_rate_mode: String, // "VARIABLE" or "STABLE"
        borrow_timestamp: u64,
    }
    
    /// Liquidation engine for automated liquidations
    public struct LiquidationEngine has key {
        id: UID,
        operator: address,
        liquidation_threshold: u64,
        liquidation_bonus: u64,
        max_liquidation_amount: u64,
        spot_dex_registry: Option<ID>,
        flash_loan_providers: VecSet<ID>,
        total_liquidations: u64,
        total_volume_liquidated: u64,
        emergency_pause: bool,
        whitelisted_liquidators: VecSet<address>,
    }
    
    /// Yield farming vault for UNXV rewards
    public struct YieldFarmingVault has key {
        id: UID,
        unxv_rewards_per_second: u64,
        total_allocation_points: u64,
        pool_allocations: Table<String, u64>,
        staked_unxv: Table<address, StakePosition>,
        stake_multipliers: Table<u64, u64>,
        total_rewards_distributed: u64,
        last_reward_timestamp: u64,
        reward_debt: Table<address, u64>,
        vault_balance: Balance<UNXV>, // Store staked UNXV tokens
    }
    
    /// UNXV staking position
    public struct StakePosition has store, drop {
        amount: u64,
        stake_timestamp: u64,
        tier: u64,
        multiplier: u64,
        locked_until: u64,
    }
    
    /// Flash loan hot potato
    public struct FlashLoan has key {
        id: UID,
        amount: u64,
        fee: u64,
        asset: String,
        borrower: address,
        must_repay: bool,
    }
    
    /// Receipt structures for operations
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
    
    #[allow(unused_field)]
    public struct LiquidationResult has drop {
        debt_repaid: u64,
        collateral_seized: u64,
        liquidation_bonus: u64,
        liquidator_profit: u64,
        borrower_health_factor: u64,
        gas_cost: u64,
    }
    
    #[allow(unused_field)]
    public struct InterestRateResult has drop {
        supply_rate: u64,
        borrow_rate: u64,
        utilization_rate: u64,
        optimal_utilization: u64,
        rate_trend: String,
    }
    
    public struct StakingResult has drop {
        new_tier: u64,
        new_multiplier: u64,
        borrow_rate_discount: u64,
        supply_rate_bonus: u64,
        benefits: vector<String>,
    }
    
    // ========== Events ==========
    
    /// Supply and withdraw events
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
    
    /// Borrow and repay events
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
    
    /// Liquidation events
    #[allow(unused_field)]
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
    
    /// Interest rate events
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
    
    /// UNXV staking events
    public struct UnxvStaked has copy, drop {
        user: address,
        amount: u64,
        new_tier: u64,
        new_multiplier: u64,
        lock_duration: u64,
        benefits: vector<String>,
        timestamp: u64,
    }
    
    #[allow(unused_field)]
    public struct RewardsClaimed has copy, drop {
        user: address,
        unxv_amount: u64,
        bonus_multiplier: u64,
        stake_tier: u64,
        total_rewards_earned: u64,
        timestamp: u64,
    }
    
    /// Flash loan events
    public struct FlashLoanInitiated has copy, drop {
        borrower: address,
        asset: String,
        amount: u64,
        fee: u64,
        timestamp: u64,
    }
    
    public struct FlashLoanRepaid has copy, drop {
        borrower: address,
        asset: String,
        amount: u64,
        fee_paid: u64,
        timestamp: u64,
    }
    
    // ========== Module Initialization ==========
    
    /// Initialize the lending protocol
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        let global_params = GlobalParams {
            min_borrow_amount: 100000000, // $100 in 6 decimals
            max_utilization_rate: MAX_UTILIZATION_RATE,
            close_factor: 5000, // 50%
            grace_period: GRACE_PERIOD,
            flash_loan_fee: FLASH_LOAN_FEE,
            protocol_fee_rate: 1000, // 10%
        };
        
        let risk_parameters = RiskParameters {
            max_assets_as_collateral: 10,
            health_factor_liquidation: MIN_HEALTH_FACTOR,
            debt_ceiling_global: 1000000000000, // $1B
            liquidation_incentive: LIQUIDATION_BONUS,
        };
        
        let registry = LendingRegistry {
            id: object::new(ctx),
            supported_assets: table::new(ctx),
            lending_pools: table::new(ctx),
            interest_rate_models: table::new(ctx),
            global_params,
            risk_parameters,
            oracle_feeds: table::new(ctx),
            admin_cap: option::some(admin_cap),
            total_users: 0,
            total_supply_usd: 0,
            total_borrows_usd: 0,
            is_paused: false,
        };
        
        let liquidation_engine = LiquidationEngine {
            id: object::new(ctx),
            operator: tx_context::sender(ctx),
            liquidation_threshold: MIN_HEALTH_FACTOR,
            liquidation_bonus: LIQUIDATION_BONUS,
            max_liquidation_amount: 10000000000, // $10M
            spot_dex_registry: option::none(),
            flash_loan_providers: vec_set::empty(),
            total_liquidations: 0,
            total_volume_liquidated: 0,
            emergency_pause: false,
            whitelisted_liquidators: vec_set::empty(),
        };
        
        let mut yield_farming_vault = YieldFarmingVault {
            id: object::new(ctx),
            unxv_rewards_per_second: 1000000, // 1 UNXV per second
            total_allocation_points: 0,
            pool_allocations: table::new(ctx),
            staked_unxv: table::new(ctx),
            stake_multipliers: table::new(ctx),
            total_rewards_distributed: 0,
            last_reward_timestamp: 0, // Set to 0 for initialization
            reward_debt: table::new(ctx),
            vault_balance: balance::zero<UNXV>(),
        };
        
        // Initialize stake tier multipliers
        table::add(&mut yield_farming_vault.stake_multipliers, 0, 10000); // 1.0x
        table::add(&mut yield_farming_vault.stake_multipliers, 1, 10500); // 1.05x
        table::add(&mut yield_farming_vault.stake_multipliers, 2, 11000); // 1.1x
        table::add(&mut yield_farming_vault.stake_multipliers, 3, 12000); // 1.2x
        table::add(&mut yield_farming_vault.stake_multipliers, 4, 13000); // 1.3x
        table::add(&mut yield_farming_vault.stake_multipliers, 5, 15000); // 1.5x
        
        transfer::share_object(registry);
        transfer::share_object(liquidation_engine);
        transfer::share_object(yield_farming_vault);
    }
    
    // ========== Admin Functions ==========
    
    /// Add a new supported asset to the protocol
    public fun add_supported_asset(
        registry: &mut LendingRegistry,
        asset_name: String,
        asset_config: AssetConfig,
        interest_rate_model: InterestRateModel,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        let price_feed_id = asset_config.price_feed_id;
        table::add(&mut registry.supported_assets, asset_name, asset_config);
        table::add(&mut registry.interest_rate_models, asset_name, interest_rate_model);
        table::add(&mut registry.oracle_feeds, asset_name, price_feed_id);
    }
    
    /// Create a new lending pool for an asset
    public fun create_lending_pool<T>(
        registry: &mut LendingRegistry,
        asset_name: String,
        ctx: &mut TxContext,
    ): ID {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        assert!(table::contains(&registry.supported_assets, asset_name), E_ASSET_NOT_SUPPORTED);
        
        let pool = LendingPool<T> {
            id: object::new(ctx),
            asset_name,
            total_supply: 0,
            total_borrows: 0,
            total_reserves: 0,
            cash: balance::zero<T>(),
            supply_index: BASIS_POINTS,
            borrow_index: BASIS_POINTS,
            last_update_timestamp: 0,
            current_supply_rate: 0,
            current_borrow_rate: 0,
            utilization_rate: 0,
            deepbook_pool_id: option::none(),
            synthetic_registry_id: option::none(),
        };
        
        let pool_id = object::uid_to_inner(&pool.id);
        table::add(&mut registry.lending_pools, asset_name, pool_id);
        
        transfer::share_object(pool);
        pool_id
    }
    
    /// Update global system parameters
    public fun update_global_params(
        registry: &mut LendingRegistry,
        new_params: GlobalParams,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        registry.global_params = new_params;
    }
    
    /// Pause the protocol in emergency
    public fun emergency_pause(
        registry: &mut LendingRegistry,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        registry.is_paused = true;
    }
    
    /// Resume protocol operations
    public fun resume_system(
        registry: &mut LendingRegistry,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        registry.is_paused = false;
    }
    
    // ========== User Account Management ==========
    
    /// Create a new user account
    public fun create_user_account(ctx: &mut TxContext): UserAccount {
        UserAccount {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            supply_balances: table::new(ctx),
            borrow_balances: table::new(ctx),
            health_factor: BASIS_POINTS * 10,
            total_collateral_value: 0,
            total_borrow_value: 0,
            liquidation_threshold_breached: false,
            last_health_check: 0,
            account_tier: 0,
            last_reward_claim: 0,
        }
    }
    
    // ========== Supply and Withdraw Operations ==========
    
    /// Supply assets to earn yield
    public fun supply_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        supply_amount: Coin<T>,
        use_as_collateral: bool,
        _price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SupplyReceipt {
        assert!(account.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(table::contains(&registry.supported_assets, pool.asset_name), E_ASSET_NOT_SUPPORTED);
        
        let amount = coin::value(&supply_amount);
        assert!(amount > 0, E_AMOUNT_TOO_SMALL);
        
        let asset_config = table::borrow(&registry.supported_assets, pool.asset_name);
        assert!(pool.total_supply + amount <= asset_config.supply_cap, E_EXCEED_SUPPLY_CAP);
        
        if (use_as_collateral) {
            assert!(asset_config.is_collateral, E_ASSET_NOT_COLLATERAL);
        };
        
        // Update interest before supply
        update_interest_rates(pool, registry, clock);
        
        // Calculate scaled amount
        let scaled_amount = (amount * BASIS_POINTS) / pool.supply_index;
        
        // Add to pool
        balance::join(&mut pool.cash, coin::into_balance(supply_amount));
        pool.total_supply = pool.total_supply + amount;
        
        // Update utilization rate and interest rates to reflect new supply
        pool.utilization_rate = if (pool.total_supply == 0) {
            0
        } else {
            (pool.total_borrows * BASIS_POINTS) / pool.total_supply
        };
        
        // Update current rates based on new utilization
        let rate_model = table::borrow(&registry.interest_rate_models, pool.asset_name);
        let (supply_rate, borrow_rate) = calculate_interest_rates_internal(pool.utilization_rate, rate_model);
        pool.current_supply_rate = supply_rate;
        pool.current_borrow_rate = borrow_rate;
        
        // Update user position
        if (table::contains(&account.supply_balances, pool.asset_name)) {
            let position = table::borrow_mut(&mut account.supply_balances, pool.asset_name);
            // Calculate accrued interest before updating
            let new_scaled_balance = position.scaled_balance + scaled_amount;
            let new_principal = (new_scaled_balance * pool.supply_index) / BASIS_POINTS;
            let _interest_earned = new_principal - position.principal_amount;
            
            position.principal_amount = new_principal;
            position.scaled_balance = new_scaled_balance;
            position.last_interest_index = pool.supply_index;
            if (use_as_collateral && !position.is_collateral) {
                position.is_collateral = true;
            };
        } else {
            let position = SupplyPosition {
                principal_amount: amount,
                scaled_balance: scaled_amount,
                last_interest_index: pool.supply_index,
                is_collateral: use_as_collateral,
                supply_timestamp: clock::timestamp_ms(clock),
            };
            table::add(&mut account.supply_balances, pool.asset_name, position);
        };
        
        if (use_as_collateral) {
            // Collateral tracking removed for simplicity
        };
        
        // Update account health
        update_account_health(account, registry, _price_feeds, clock);
        
        event::emit(AssetSupplied {
            user: tx_context::sender(ctx),
            asset: pool.asset_name,
            amount,
            scaled_amount,
            new_balance: amount,
            is_collateral: use_as_collateral,
            supply_rate: pool.current_supply_rate,
            timestamp: clock::timestamp_ms(clock),
        });
        
        SupplyReceipt {
            amount_supplied: amount,
            scaled_amount,
            new_supply_rate: pool.current_supply_rate,
            interest_earned: 0,
        }
    }
    
    /// Withdraw supplied assets
    public fun withdraw_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        withdraw_amount: u64,
        price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(account.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(table::contains(&account.supply_balances, pool.asset_name), E_ASSET_NOT_SUPPORTED);
        assert!(withdraw_amount > 0, E_AMOUNT_TOO_SMALL);
        
        // Update interest before withdrawal
        update_interest_rates(pool, registry, clock);
        
        let (current_balance, scaled_withdraw, remaining_balance) = {
            let position = table::borrow_mut(&mut account.supply_balances, pool.asset_name);
            let current_balance = (position.scaled_balance * pool.supply_index) / BASIS_POINTS;
            assert!(current_balance >= withdraw_amount, E_INSUFFICIENT_COLLATERAL);
            
            // Calculate new position
            let scaled_withdraw = (withdraw_amount * BASIS_POINTS) / pool.supply_index;
            position.scaled_balance = position.scaled_balance - scaled_withdraw;
            position.principal_amount = (position.scaled_balance * pool.supply_index) / BASIS_POINTS;
            (current_balance, scaled_withdraw, position.principal_amount)
        };
        
        // Check liquidity
        assert!(balance::value(&pool.cash) >= withdraw_amount, E_INSUFFICIENT_LIQUIDITY);
        
        // Update pool
        pool.total_supply = pool.total_supply - withdraw_amount;
        let withdrawn_balance = balance::split(&mut pool.cash, withdraw_amount);
        
        // Update utilization rate and interest rates to reflect reduced supply
        pool.utilization_rate = if (pool.total_supply == 0) {
            0
        } else {
            (pool.total_borrows * BASIS_POINTS) / pool.total_supply
        };
        
        // Update current rates based on new utilization
        let rate_model = table::borrow(&registry.interest_rate_models, pool.asset_name);
        let (supply_rate, borrow_rate) = calculate_interest_rates_internal(pool.utilization_rate, rate_model);
        pool.current_supply_rate = supply_rate;
        pool.current_borrow_rate = borrow_rate;
        
        // Update account health and check if withdrawal is safe
        update_account_health(account, registry, price_feeds, clock);
        
        event::emit(AssetWithdrawn {
            user: tx_context::sender(ctx),
            asset: pool.asset_name,
            amount: withdraw_amount,
            scaled_amount: scaled_withdraw,
            remaining_balance: remaining_balance,
            interest_earned: current_balance - remaining_balance,
            timestamp: clock::timestamp_ms(clock),
        });
        
        coin::from_balance(withdrawn_balance, ctx)
    }
    
    // ========== Borrow and Repay Operations ==========
    
    /// Borrow assets against collateral
    public fun borrow_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        borrow_amount: u64,
        interest_rate_mode: String,
        price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(account.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(table::contains(&registry.supported_assets, pool.asset_name), E_ASSET_NOT_SUPPORTED);
        assert!(borrow_amount > 0, E_AMOUNT_TOO_SMALL);
        assert!(interest_rate_mode == string::utf8(b"VARIABLE"), E_INVALID_INTEREST_RATE_MODE);
        
        let asset_config = table::borrow(&registry.supported_assets, pool.asset_name);
        assert!(asset_config.is_borrowable, E_ASSET_NOT_BORROWABLE);
        assert!(pool.total_borrows + borrow_amount <= asset_config.borrow_cap, E_EXCEED_BORROW_CAP);
        assert!(balance::value(&pool.cash) >= borrow_amount, E_INSUFFICIENT_LIQUIDITY);
        
        // Update interest before borrow
        update_interest_rates(pool, registry, clock);
        
        // Calculate scaled borrow amount
        let scaled_amount = (borrow_amount * BASIS_POINTS) / pool.borrow_index;
        
        // Update user position
        if (table::contains(&account.borrow_balances, pool.asset_name)) {
            let position = table::borrow_mut(&mut account.borrow_balances, pool.asset_name);
            position.scaled_balance = position.scaled_balance + scaled_amount;
            position.principal_amount = (position.scaled_balance * pool.borrow_index) / BASIS_POINTS;
        } else {
            let position = BorrowPosition {
                principal_amount: borrow_amount,
                scaled_balance: scaled_amount,
                last_interest_index: pool.borrow_index,
                interest_rate_mode,
                borrow_timestamp: clock::timestamp_ms(clock),
            };
            table::add(&mut account.borrow_balances, pool.asset_name, position);
        };
        
        // Update pool
        pool.total_borrows = pool.total_borrows + borrow_amount;
        let borrowed_balance = balance::split(&mut pool.cash, borrow_amount);
        
        // Update utilization rate and interest rates to reflect new borrow amount
        pool.utilization_rate = if (pool.total_supply == 0) {
            0
        } else {
            (pool.total_borrows * BASIS_POINTS) / pool.total_supply
        };
        
        // Update current rates based on new utilization
        let rate_model = table::borrow(&registry.interest_rate_models, pool.asset_name);
        let (supply_rate, borrow_rate) = calculate_interest_rates_internal(pool.utilization_rate, rate_model);
        pool.current_supply_rate = supply_rate;
        pool.current_borrow_rate = borrow_rate;
        
        // Update and check account health
        update_account_health(account, registry, price_feeds, clock);
        assert!(account.health_factor >= MIN_HEALTH_FACTOR, E_HEALTH_FACTOR_TOO_LOW);
        
        event::emit(AssetBorrowed {
            user: tx_context::sender(ctx),
            asset: pool.asset_name,
            amount: borrow_amount,
            scaled_amount,
            new_borrow_balance: borrow_amount,
            borrow_rate: pool.current_borrow_rate,
            health_factor: account.health_factor,
            timestamp: clock::timestamp_ms(clock),
        });
        
        coin::from_balance(borrowed_balance, ctx)
    }
    
    /// Repay borrowed assets
    public fun repay_debt<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        repay_amount: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): RepayReceipt {
        assert!(account.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(table::contains(&account.borrow_balances, pool.asset_name), E_ASSET_NOT_SUPPORTED);
        
        let repay_value = coin::value(&repay_amount);
        assert!(repay_value > 0, E_AMOUNT_TOO_SMALL);
        
        // Update interest before repay
        update_interest_rates(pool, registry, clock);
        
        let (current_debt, actual_repay, scaled_repay, remaining_debt) = {
            let position = table::borrow_mut(&mut account.borrow_balances, pool.asset_name);
            let current_debt = (position.scaled_balance * pool.borrow_index) / BASIS_POINTS;
            
            let actual_repay = min(repay_value, current_debt);
            let scaled_repay = (actual_repay * BASIS_POINTS) / pool.borrow_index;
            
            // Update position
            position.scaled_balance = position.scaled_balance - scaled_repay;
            position.principal_amount = (position.scaled_balance * pool.borrow_index) / BASIS_POINTS;
            (current_debt, actual_repay, scaled_repay, position.principal_amount)
        };
        
        // Update pool
        pool.total_borrows = pool.total_borrows - actual_repay;
        balance::join(&mut pool.cash, coin::into_balance(repay_amount));
        
        // Update utilization rate and interest rates to reflect reduced borrows
        pool.utilization_rate = if (pool.total_supply == 0) {
            0
        } else {
            (pool.total_borrows * BASIS_POINTS) / pool.total_supply
        };
        
        // Update current rates based on new utilization
        let rate_model = table::borrow(&registry.interest_rate_models, pool.asset_name);
        let (supply_rate, borrow_rate) = calculate_interest_rates_internal(pool.utilization_rate, rate_model);
        pool.current_supply_rate = supply_rate;
        pool.current_borrow_rate = borrow_rate;
        
        // Update account health
        let old_health = account.health_factor;
        let empty_price_feeds = vector::empty<PriceInfoObject>();
        update_account_health(account, registry, &empty_price_feeds, clock);
        vector::destroy_empty(empty_price_feeds);
        let health_improvement = account.health_factor - old_health;
        
        event::emit(DebtRepaid {
            user: tx_context::sender(ctx),
            asset: pool.asset_name,
            amount: actual_repay,
            scaled_amount: scaled_repay,
            remaining_debt: remaining_debt,
            interest_paid: current_debt - remaining_debt,
            timestamp: clock::timestamp_ms(clock),
        });
        
        RepayReceipt {
            amount_repaid: actual_repay,
            interest_paid: current_debt - remaining_debt,
            remaining_debt: remaining_debt,
            health_factor_improvement: health_improvement,
        }
    }
    
    // ========== Interest Rate Management ==========
    
    /// Update interest rates for a pool
    public fun update_interest_rates<T>(
        pool: &mut LendingPool<T>,
        registry: &LendingRegistry,
        clock: &Clock,
    ) {
        let now = clock::timestamp_ms(clock);
        if (pool.last_update_timestamp == 0) {
            pool.last_update_timestamp = now;
            return
        };
        
        let time_elapsed = now - pool.last_update_timestamp;
        if (time_elapsed == 0) return;
        
        let rate_model = table::borrow(&registry.interest_rate_models, pool.asset_name);
        
        // Calculate utilization rate
        let utilization = if (pool.total_supply == 0) {
            0
        } else {
            (pool.total_borrows * BASIS_POINTS) / pool.total_supply
        };
        
        // Calculate interest rates based on utilization
        let (supply_rate, borrow_rate) = calculate_interest_rates_internal(utilization, rate_model);
        
        // Apply interest accrual
        if (pool.total_supply > 0) {
            let supply_interest = (supply_rate * time_elapsed) / (SECONDS_PER_YEAR * 1000);
            pool.supply_index = pool.supply_index + (pool.supply_index * supply_interest) / BASIS_POINTS;
        };
        
        if (pool.total_borrows > 0) {
            let borrow_interest = (borrow_rate * time_elapsed) / (SECONDS_PER_YEAR * 1000);
            pool.borrow_index = pool.borrow_index + (pool.borrow_index * borrow_interest) / BASIS_POINTS;
        };
        
        let old_supply_rate = pool.current_supply_rate;
        let old_borrow_rate = pool.current_borrow_rate;
        
        pool.current_supply_rate = supply_rate;
        pool.current_borrow_rate = borrow_rate;
        pool.utilization_rate = utilization;
        pool.last_update_timestamp = now;
        
        event::emit(InterestRatesUpdated {
            asset: pool.asset_name,
            old_supply_rate,
            new_supply_rate: supply_rate,
            old_borrow_rate,
            new_borrow_rate: borrow_rate,
            utilization_rate: utilization,
            total_supply: pool.total_supply,
            total_borrows: pool.total_borrows,
            timestamp: now,
        });
    }
    
    /// Internal interest rate calculation
    fun calculate_interest_rates_internal(
        utilization_rate: u64,
        model: &InterestRateModel,
    ): (u64, u64) {
        let borrow_rate = if (utilization_rate <= model.optimal_utilization) {
            model.base_rate + (utilization_rate * model.multiplier) / BASIS_POINTS
        } else {
            let excess_util = utilization_rate - model.optimal_utilization;
            model.base_rate + 
            (model.optimal_utilization * model.multiplier) / BASIS_POINTS +
            (excess_util * model.jump_multiplier) / BASIS_POINTS
        };
        
        let supply_rate = (borrow_rate * utilization_rate) / BASIS_POINTS;
        
        (supply_rate, borrow_rate)
    }
    
    // ========== Health Factor and Liquidation ==========
    
    /// Calculate account health factor
    public fun calculate_health_factor(
        account: &UserAccount,
        _registry: &LendingRegistry,
        _price_feeds: &vector<PriceInfoObject>,
        _clock: &Clock,
    ): HealthFactorResult {
        let (total_collateral, total_debt, liquidation_threshold) = calculate_account_values(
            account, _registry, _price_feeds, _clock
        );
        
        let health_factor = if (total_debt == 0) {
            BASIS_POINTS * 10 // Very high when no debt
        } else {
            (liquidation_threshold * BASIS_POINTS) / total_debt
        };
        
        HealthFactorResult {
            health_factor,
            total_collateral_value: total_collateral,
            total_debt_value: total_debt,
            liquidation_threshold_value: liquidation_threshold,
            time_to_liquidation: option::none(),
            is_liquidatable: health_factor < MIN_HEALTH_FACTOR,
        }
    }
    
    /// Update account health metrics
    fun update_account_health(
        account: &mut UserAccount,
        registry: &LendingRegistry,
        price_feeds: &vector<PriceInfoObject>,
        clock: &Clock,
    ) {
        let result = calculate_health_factor(account, registry, price_feeds, clock);
        account.health_factor = result.health_factor;
        account.total_collateral_value = result.total_collateral_value;
        account.total_borrow_value = result.total_debt_value;
        account.liquidation_threshold_breached = result.is_liquidatable;
        account.last_health_check = clock::timestamp_ms(clock);
    }
    
    /// Calculate account collateral and debt values
    fun calculate_account_values(
        account: &UserAccount,
        _registry: &LendingRegistry,
        _price_feeds: &vector<PriceInfoObject>,
        _clock: &Clock,
    ): (u64, u64, u64) {
        // This would iterate through all positions and calculate values
        // For simplicity, returning placeholder values
        (account.total_collateral_value, account.total_borrow_value, account.total_collateral_value * 85 / 100)
    }
    
    // ========== UNXV Staking and Rewards ==========
    
    /// Stake UNXV for lending benefits
    public fun stake_unxv_for_benefits(
        vault: &mut YieldFarmingVault,
        account: &mut UserAccount,
        stake_amount: Coin<UNXV>,
        lock_duration: u64,
        ctx: &mut TxContext,
    ): StakingResult {
        assert!(account.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        
        let amount = coin::value(&stake_amount);
        assert!(amount > 0, E_AMOUNT_TOO_SMALL);
        
        // Calculate new tier
        let new_total = amount; // Simplified for demo
        let new_tier = calculate_stake_tier(new_total);
        let multiplier = *table::borrow(&vault.stake_multipliers, new_tier);
        
        // Update account
        account.account_tier = new_tier;
        
        // Create or update stake position
        let stake_position = StakePosition {
            amount: new_total,
            stake_timestamp: 0, // Would use clock
            tier: new_tier,
            multiplier,
            locked_until: lock_duration,
        };
        
        if (table::contains(&vault.staked_unxv, account.owner)) {
            let existing = table::borrow_mut(&mut vault.staked_unxv, account.owner);
            *existing = stake_position;
        } else {
            table::add(&mut vault.staked_unxv, account.owner, stake_position);
        };
        
        // Store the staked UNXV in vault
        balance::join(&mut vault.vault_balance, coin::into_balance(stake_amount));
        
        let benefits = calculate_tier_benefits(new_tier);
        
        event::emit(UnxvStaked {
            user: account.owner,
            amount,
            new_tier,
            new_multiplier: multiplier,
            lock_duration,
            benefits,
            timestamp: 0,
        });
        
        StakingResult {
            new_tier,
            new_multiplier: multiplier,
            borrow_rate_discount: get_tier_borrow_discount(new_tier),
            supply_rate_bonus: get_tier_supply_bonus(new_tier),
            benefits,
        }
    }
    
    /// Calculate UNXV stake tier based on amount
    fun calculate_stake_tier(amount: u64): u64 {
        if (amount >= TIER_5_THRESHOLD) 5
        else if (amount >= TIER_4_THRESHOLD) 4
        else if (amount >= TIER_3_THRESHOLD) 3
        else if (amount >= TIER_2_THRESHOLD) 2
        else if (amount >= TIER_1_THRESHOLD) 1
        else 0
    }
    
    /// Get borrow rate discount for tier
    fun get_tier_borrow_discount(tier: u64): u64 {
        if (tier == 5) 2500       // 25%
        else if (tier == 4) 2000  // 20%
        else if (tier == 3) 1500  // 15%
        else if (tier == 2) 1000  // 10%
        else if (tier == 1) 500   // 5%
        else 0
    }
    
    /// Get supply rate bonus for tier
    fun get_tier_supply_bonus(tier: u64): u64 {
        if (tier == 5) 2000       // 20%
        else if (tier == 4) 1500  // 15%
        else if (tier == 3) 1000  // 10%
        else if (tier == 2) 500   // 5%
        else if (tier == 1) 200   // 2%
        else 0
    }
    
    /// Calculate tier benefits
    fun calculate_tier_benefits(tier: u64): vector<String> {
        let mut benefits = vector::empty<String>();
        if (tier >= 1) {
            vector::push_back(&mut benefits, string::utf8(b"Borrow Rate Discount"));
            vector::push_back(&mut benefits, string::utf8(b"Supply Rate Bonus"));
        };
        if (tier >= 3) {
            vector::push_back(&mut benefits, string::utf8(b"Priority Liquidation Protection"));
        };
        if (tier >= 5) {
            vector::push_back(&mut benefits, string::utf8(b"Exclusive Strategy Access"));
        };
        benefits
    }
    
    // ========== Flash Loans ==========
    
    /// Initiate a flash loan
    public fun initiate_flash_loan<T>(
        pool: &mut LendingPool<T>,
        registry: &LendingRegistry,
        loan_amount: u64,
        ctx: &mut TxContext,
    ): (Coin<T>, FlashLoan) {
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(loan_amount > 0, E_AMOUNT_TOO_SMALL);
        assert!(balance::value(&pool.cash) >= loan_amount, E_INSUFFICIENT_LIQUIDITY);
        
        let fee = (loan_amount * registry.global_params.flash_loan_fee) / BASIS_POINTS;
        
        let flash_loan = FlashLoan {
            id: object::new(ctx),
            amount: loan_amount,
            fee,
            asset: pool.asset_name,
            borrower: tx_context::sender(ctx),
            must_repay: true,
        };
        
        let loan_balance = balance::split(&mut pool.cash, loan_amount);
        
        event::emit(FlashLoanInitiated {
            borrower: tx_context::sender(ctx),
            asset: pool.asset_name,
            amount: loan_amount,
            fee,
            timestamp: 0,
        });
        
        (coin::from_balance(loan_balance, ctx), flash_loan)
    }
    
    /// Repay a flash loan
    public fun repay_flash_loan<T>(
        pool: &mut LendingPool<T>,
        _registry: &LendingRegistry,
        loan_repayment: Coin<T>,
        flash_loan: FlashLoan,
        ctx: &mut TxContext,
    ) {
        assert!(flash_loan.borrower == tx_context::sender(ctx), E_NOT_ADMIN);
        assert!(flash_loan.must_repay, E_FLASH_LOAN_NOT_REPAID);
        
        let repay_amount = coin::value(&loan_repayment);
        let required_amount = flash_loan.amount + flash_loan.fee;
        assert!(repay_amount >= required_amount, E_FLASH_LOAN_NOT_REPAID);
        
        balance::join(&mut pool.cash, coin::into_balance(loan_repayment));
        
        event::emit(FlashLoanRepaid {
            borrower: flash_loan.borrower,
            asset: flash_loan.asset,
            amount: flash_loan.amount,
            fee_paid: flash_loan.fee,
            timestamp: 0,
        });
        
        let FlashLoan { id, amount: _, fee: _, asset: _, borrower: _, must_repay: _ } = flash_loan;
        object::delete(id);
    }
    
    // ========== Helper Functions ==========
    
    /// Get minimum of two values
    fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }
    
    /// Get maximum of two values (unused but kept for completeness)
    fun max(a: u64, b: u64): u64 {
        if (a > b) a else b
    }
    
    // ========== Getter Functions ==========
    
    /// Get lending pool information
    public fun get_pool_info<T>(pool: &LendingPool<T>): (u64, u64, u64, u64, u64) {
        (
            pool.total_supply,
            pool.total_borrows,
            pool.current_supply_rate,
            pool.current_borrow_rate,
            pool.utilization_rate
        )
    }
    
    /// Get user account summary
    public fun get_account_summary(account: &UserAccount): (u64, u64, u64, u64) {
        (
            account.total_collateral_value,
            account.total_borrow_value,
            account.health_factor,
            account.account_tier
        )
    }
    
    /// Check if asset is supported
    public fun is_asset_supported(registry: &LendingRegistry, asset_name: String): bool {
        table::contains(&registry.supported_assets, asset_name)
    }
    
    /// Get asset configuration
    public fun get_asset_config(registry: &LendingRegistry, asset_name: String): &AssetConfig {
        table::borrow(&registry.supported_assets, asset_name)
    }
    
    /// Get global parameters
    public fun get_global_params(registry: &LendingRegistry): &GlobalParams {
        &registry.global_params
    }
    
    /// Check if system is paused
    public fun is_system_paused(registry: &LendingRegistry): bool {
        registry.is_paused
    }
    
    // ========== Test-only Functions ==========
    
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
    
    #[test_only]
    public fun create_test_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
        coin::from_balance(balance::create_for_testing<T>(amount), ctx)
    }
    
    #[test_only]
    public fun create_test_asset_config(
        asset_name: String,
        is_collateral: bool,
        is_borrowable: bool,
        collateral_factor: u64,
    ): AssetConfig {
        AssetConfig {
            asset_name,
            asset_type: string::utf8(b"NATIVE"),
            is_collateral,
            is_borrowable,
            collateral_factor,
            liquidation_threshold: 8500,
            liquidation_penalty: 500,
            supply_cap: 1000000000000,
            borrow_cap: 800000000000,
            reserve_factor: 1000,
            decimals: 6,
            price_feed_id: vector::empty(),
        }
    }
    
    #[test_only]
    public fun create_test_interest_model(): InterestRateModel {
        InterestRateModel {
            base_rate: 200,      // 2%
            multiplier: 1000,    // 10%
            jump_multiplier: 10000, // 100%
            optimal_utilization: 8000, // 80%
        }
    }

    // ========== Getter Functions for Tests ==========
    
    /// Get supply receipt fields for testing
    #[test_only]
    public fun get_supply_receipt_info(receipt: &SupplyReceipt): (u64, u64, u64, u64) {
        (receipt.amount_supplied, receipt.scaled_amount, receipt.new_supply_rate, receipt.interest_earned)
    }
    
    /// Get repay receipt fields for testing  
    #[test_only]
    public fun get_repay_receipt_info(receipt: &RepayReceipt): (u64, u64, u64, u64) {
        (receipt.amount_repaid, receipt.interest_paid, receipt.remaining_debt, receipt.health_factor_improvement)
    }
    
    /// Get health factor result fields for testing
    #[test_only]
    public fun get_health_factor_result_info(result: &HealthFactorResult): (u64, bool) {
        (result.health_factor, result.is_liquidatable)
    }
    
    /// Get staking result fields for testing
    #[test_only]
    public fun get_staking_result_info(result: &StakingResult): (u64, u64, u64, vector<String>) {
        (result.new_tier, result.borrow_rate_discount, result.supply_rate_bonus, result.benefits)
    }
    
    // ========== Test-Only Wrapper Functions ==========
    
    /// Test-only wrapper for supply_asset that handles price feeds internally
    #[test_only]
    public fun test_supply_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        supply_amount: Coin<T>,
        use_as_collateral: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SupplyReceipt {
        let empty_feeds = vector::empty<PriceInfoObject>();
        let result = supply_asset(pool, account, registry, supply_amount, use_as_collateral, &empty_feeds, clock, ctx);
        vector::destroy_empty(empty_feeds);
        result
    }
    
    /// Test-only wrapper for withdraw_asset that handles price feeds internally
    #[test_only]
    public fun test_withdraw_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        withdraw_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        let empty_feeds = vector::empty<PriceInfoObject>();
        let result = withdraw_asset(pool, account, registry, withdraw_amount, &empty_feeds, clock, ctx);
        vector::destroy_empty(empty_feeds);
        result
    }
    
    /// Test-only wrapper for borrow_asset that handles price feeds internally
    #[test_only]
    public fun test_borrow_asset<T>(
        pool: &mut LendingPool<T>,
        account: &mut UserAccount,
        registry: &LendingRegistry,
        borrow_amount: u64,
        interest_rate_mode: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        let empty_feeds = vector::empty<PriceInfoObject>();
        let result = borrow_asset(pool, account, registry, borrow_amount, interest_rate_mode, &empty_feeds, clock, ctx);
        vector::destroy_empty(empty_feeds);
        result
    }
    
    /// Test-only wrapper for calculate_health_factor that handles price feeds internally
    #[test_only]
    public fun test_calculate_health_factor(
        account: &UserAccount,
        registry: &LendingRegistry,
        clock: &Clock,
    ): HealthFactorResult {
        let empty_feeds = vector::empty<PriceInfoObject>();
        let result = calculate_health_factor(account, registry, &empty_feeds, clock);
        vector::destroy_empty(empty_feeds);
        result
    }
}


