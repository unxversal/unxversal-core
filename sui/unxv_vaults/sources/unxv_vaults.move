/// UnXversal Trader Vaults Protocol
/// 
/// This module implements a permissionless fund management ecosystem where skilled traders
/// manage investor capital with required stake alignment, configurable profit sharing,
/// and comprehensive investor protection through sophisticated risk management.

module unxv_vaults::unxv_vaults {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::vec_set::{Self, VecSet};
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};

    // ==================== Error Constants ====================
    
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_STAKE: u64 = 2;
    const E_INVALID_PROFIT_SHARE: u64 = 3;
    const E_VAULT_PAUSED: u64 = 4;
    const E_MINIMUM_INVESTMENT_NOT_MET: u64 = 5;
    const E_MAXIMUM_INVESTORS_REACHED: u64 = 6;
    const E_WITHDRAWAL_NOT_ALLOWED: u64 = 7;
    const E_RISK_LIMIT_EXCEEDED: u64 = 8;
    const E_INVALID_TRADE_PARAMETERS: u64 = 9;
    const E_INSUFFICIENT_BALANCE: u64 = 10;
    const E_POSITION_NOT_FOUND: u64 = 11;
    const E_STAKE_DEFICIT: u64 = 12;
    const E_INVALID_VAULT_STATUS: u64 = 13;
    const E_DRAWDOWN_LIMIT_EXCEEDED: u64 = 14;
    const E_PROTOCOL_PAUSED: u64 = 15;

    // ==================== Core Structs ====================

    /// Placeholder for USDC token type
    public struct USDC has drop {}

    /// Administrative capability
    public struct AdminCap has key, store {
        id: UID,
    }

    /// Central registry for managing all trader vaults
    public struct TraderVaultRegistry has key {
        id: UID,
        
        // Vault management
        active_vaults: Table<String, VaultInfo>,
        vault_managers: Table<address, ManagerInfo>,
        vault_count: u64,
        
        // Global parameters
        min_stake_percentage: u64,                      // Default: 5%
        max_profit_share: u64,                          // Default: 25%
        min_profit_share: u64,                          // Default: 5%
        default_profit_share: u64,                      // Default: 10%
        
        // Risk management
        global_risk_limits: GlobalRiskLimits,
        default_investor_protections: InvestorProtections,
        
        // Performance tracking
        total_aum: u64,                                 // Total assets under management
        total_managers: u64,                            // Total number of managers
        total_investors: u64,                           // Total number of investors
        
        // Protocol settings
        protocol_paused: bool,
        vault_creation_fee: u64,
        
        // UNXV integration
        unxv_tier_benefits: Table<u64, TierBenefits>,
        
        // Admin capabilities
        admin_cap: AdminCap,
    }

    /// Individual trader vault for specific asset
    public struct TraderVault<phantom T> has key {
        id: UID,
        
        // Vault identification
        vault_id: String,
        vault_name: String,
        manager: address,
        
        // Asset management
        vault_balance: Balance<T>,
        total_shares: u64,
        share_price: u64,                               // Current NAV per share
        
        // Stake tracking
        manager_shares: u64,
        manager_stake_value: u64,
        required_stake_value: u64,
        stake_deficit: u64,
        
        // Investor tracking
        investor_positions: Table<address, InvestorPosition>,
        investor_count: u64,
        max_investors: u64,
        
        // Trading positions
        active_positions: Table<String, TradingPosition>,
        position_count: u64,
        
        // Performance tracking
        inception_date: u64,
        high_water_mark: u64,
        total_return: SignedInt,
        max_drawdown: u64,
        current_drawdown: u64,
        
        // Fee tracking
        profit_share_percentage: u64,
        accrued_performance_fees: u64,
        total_fees_paid: u64,
        last_fee_calculation: u64,
        
        // Vault settings
        minimum_investment: u64,
        accepting_deposits: bool,
        vault_status: String,                           // "ACTIVE", "PAUSED", "CLOSED"
        risk_profile: String,                           // "CONSERVATIVE", "MODERATE", "AGGRESSIVE"
        strategy_description: String,
        
        // Risk management
        investor_protections: InvestorProtections,
        vault_risk_limits: VaultRiskLimits,
        
        // Trading controls
        daily_trades: u64,
        last_trade_date: u64,
        trading_enabled: bool,
    }

    /// Vault information summary
    public struct VaultInfo has store {
        vault_id: String,
        vault_name: String,
        manager: address,
        total_assets: u64,
        manager_stake: u64,
        manager_stake_percentage: u64,
        investor_deposits: u64,
        profit_share_percentage: u64,
        inception_date: u64,
        total_return: SignedInt,
        annualized_return: SignedInt,
        max_drawdown: u64,
        sharpe_ratio: u64,
        vault_status: String,
        accepting_deposits: bool,
        minimum_investment: u64,
        investor_count: u64,
        risk_profile: String,
    }

    /// Manager information and track record
    public struct ManagerInfo has store {
        manager_address: address,
        manager_name: String,
        managed_vaults: vector<String>,
        total_aum: u64,
        vault_count: u64,
        overall_performance: SignedInt,
        reputation_score: u64,
        total_profit_generated: u64,
        total_fees_earned: u64,
        trading_experience: String,
        trading_style: String,
        verification_status: String,
        track_record_length: u64,
    }

    /// Individual investor position in a vault
    public struct InvestorPosition has store {
        investor: address,
        shares_owned: u64,
        initial_investment: u64,
        total_deposits: u64,
        total_withdrawals: u64,
        unrealized_pnl: SignedInt,
        realized_pnl: SignedInt,
        fees_paid: u64,
        first_investment_date: u64,
        last_activity_date: u64,
        average_cost_basis: u64,
        auto_reinvest: bool,
        risk_tolerance: String,
    }

    /// Trading position within a vault
    public struct TradingPosition has store {
        position_id: String,
        asset: String,
        position_type: String,                          // "LONG", "SHORT"
        entry_price: u64,
        current_price: u64,
        quantity: u64,
        notional_value: u64,
        unrealized_pnl: SignedInt,
        realized_pnl: SignedInt,
        position_risk: u64,
        stop_loss: Option<u64>,
        take_profit: Option<u64>,
        entry_timestamp: u64,
        last_update: u64,
        strategy_tag: String,
        confidence_level: u64,
    }

    /// Global risk limits for all vaults
    public struct GlobalRiskLimits has copy, drop, store {
        max_single_position: u64,                      // Maximum single position size
        max_leverage: u64,                              // Maximum leverage allowed
        max_concentration: u64,                         // Maximum concentration in one asset
        daily_loss_limit: u64,                         // Maximum daily loss
        monthly_loss_limit: u64,                       // Maximum monthly loss
        volatility_limit: u64,                         // Maximum volatility
        correlation_limit: u64,                        // Maximum correlation exposure
    }

    /// Vault-specific risk limits
    public struct VaultRiskLimits has store {
        max_position_size: u64,
        max_leverage: u64,
        max_correlation_exposure: u64,
        stop_loss_threshold: u64,
        daily_var_limit: u64,
        portfolio_var_limit: u64,
        min_cash_percentage: u64,
        max_illiquid_percentage: u64,
        max_trades_per_day: u64,
        max_new_positions_per_day: u64,
    }

    /// Investor protection mechanisms
    public struct InvestorProtections has copy, drop, store {
        max_drawdown_limit: u64,
        daily_loss_limit: u64,
        monthly_loss_limit: u64,
        withdrawal_frequency: String,                   // "DAILY", "WEEKLY", "MONTHLY"
        withdrawal_notice_period: u64,
        emergency_withdrawal: bool,
        max_single_position: u64,
        max_concentration: u64,
        lock_up_period: u64,
        cooling_off_period: u64,
    }

    /// UNXV tier benefits
    public struct TierBenefits has store {
        tier_level: u64,
        trading_fee_discount: u64,
        vault_creation_fee_discount: u64,
        advanced_analytics_access: bool,
        priority_execution: bool,
        custom_strategy_access: bool,
        higher_profit_share_allowed: bool,
        performance_boost: u64,
        reputation_boost: u64,
        marketing_support: bool,
    }

    /// Withdrawal request
    public struct WithdrawalRequest has key, store {
        id: UID,
        vault_id: String,
        investor: address,
        shares_to_redeem: u64,
        estimated_amount: u64,
        request_timestamp: u64,
        notice_period_end: u64,
        withdrawal_type: String,                        // "PARTIAL", "FULL", "EMERGENCY"
        processing_status: String,                      // "PENDING", "APPROVED", "PROCESSED"
    }

    /// Signed integer for P&L calculations
    public struct SignedInt has copy, drop, store {
        value: u64,
        is_negative: bool,
    }

    // ==================== Events ====================

    /// Event when new trader vault is created
    public struct TraderVaultCreated has copy, drop {
        vault_id: String,
        manager: address,
        vault_name: String,
        initial_deposit: u64,
        manager_stake: u64,
        manager_stake_percentage: u64,
        profit_share_percentage: u64,
        minimum_investment: u64,
        risk_profile: String,
        strategy_description: String,
        timestamp: u64,
    }

    /// Event when investor makes deposit
    public struct InvestorDeposit has copy, drop {
        vault_id: String,
        investor: address,
        deposit_amount: u64,
        shares_issued: u64,
        share_price: u64,
        total_shares_after_deposit: u64,
        percentage_ownership: u64,
        first_time_investor: bool,
        total_vault_assets_after: u64,
        investor_count_after: u64,
        timestamp: u64,
    }

    /// Event when investor requests withdrawal
    public struct WithdrawalRequested has copy, drop {
        vault_id: String,
        investor: address,
        withdrawal_request_id: ID,
        shares_to_redeem: u64,
        estimated_withdrawal_amount: u64,
        current_share_price: u64,
        notice_period_end: u64,
        estimated_processing_date: u64,
        withdrawal_fee: u64,
        remaining_shares: u64,
        remaining_investment_value: u64,
        timestamp: u64,
    }

    /// Event when manager's stake falls below minimum
    public struct StakeDeficitAlert has copy, drop {
        vault_id: String,
        manager: address,
        required_stake_amount: u64,
        current_stake_amount: u64,
        stake_deficit: u64,
        stake_deficit_percentage: u64,
        trading_restrictions_applied: bool,
        grace_period_end: u64,
        minimum_additional_stake_needed: u64,
        timestamp: u64,
    }

    /// Event when vault manager executes trade
    public struct TradeExecuted has copy, drop {
        vault_id: String,
        manager: address,
        trade_id: ID,
        asset: String,
        trade_type: String,                             // "BUY", "SELL", "SHORT", "COVER"
        quantity: u64,
        execution_price: u64,
        total_value: u64,
        execution_venue: String,
        slippage: u64,
        transaction_costs: u64,
        vault_cash_change: SignedInt,
        portfolio_risk_change: SignedInt,
        timestamp: u64,
    }

    /// Event for daily performance update
    public struct DailyPerformanceUpdate has copy, drop {
        vault_id: String,
        date: u64,
        daily_return: SignedInt,
        nav_per_share: u64,
        total_vault_value: u64,
        trades_today: u64,
        trading_pnl: SignedInt,
        daily_var: u64,
        portfolio_volatility: u64,
        current_drawdown: u64,
        net_flows: SignedInt,
        investor_count: u64,
        timestamp: u64,
    }

    /// Event when performance fees are calculated
    public struct PerformanceFeesCalculated has copy, drop {
        vault_id: String,
        manager: address,
        calculation_period: u64,
        high_water_mark: u64,
        current_nav: u64,
        profit_above_hwm: u64,
        performance_fee_rate: u64,
        fees_earned: u64,
        manager_fee_share: u64,
        protocol_fee_share: u64,
        nav_after_fees: u64,
        investor_impact: u64,
        timestamp: u64,
    }

    /// Event when vault reaches new high water mark
    public struct NewHighWaterMark has copy, drop {
        vault_id: String,
        manager: address,
        old_high_water_mark: u64,
        new_high_water_mark: u64,
        improvement: u64,
        improvement_percentage: u64,
        days_since_last_hwm: u64,
        investor_returns: u64,
        cumulative_fees_paid: u64,
        timestamp: u64,
    }

    // ==================== Initialization ====================

    /// Initialize the module
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        // Create default protections
        let default_protections = InvestorProtections {
            max_drawdown_limit: 2000,                   // 20%
            daily_loss_limit: 500,                      // 5%
            monthly_loss_limit: 1500,                   // 15%
            withdrawal_frequency: string::utf8(b"WEEKLY"),
            withdrawal_notice_period: 7,                // 7 days
            emergency_withdrawal: true,
            max_single_position: 2000,                  // 20%
            max_concentration: 3000,                    // 30%
            lock_up_period: 2592000000,                 // 30 days in ms
            cooling_off_period: 86400000,               // 1 day in ms
        };

        // Create default risk limits
        let default_risk_limits = GlobalRiskLimits {
            max_single_position: 2500,                  // 25%
            max_leverage: 300,                          // 3x
            max_concentration: 4000,                    // 40%
            daily_loss_limit: 1000,                     // 10%
            monthly_loss_limit: 2000,                   // 20%
            volatility_limit: 5000,                     // 50%
            correlation_limit: 7000,                    // 70%
        };

        let registry = TraderVaultRegistry {
            id: object::new(ctx),
            active_vaults: table::new(ctx),
            vault_managers: table::new(ctx),
            vault_count: 0,
            min_stake_percentage: 500,                  // 5%
            max_profit_share: 2500,                     // 25%
            min_profit_share: 500,                      // 5%
            default_profit_share: 1000,                 // 10%
            global_risk_limits: default_risk_limits,
            default_investor_protections: default_protections,
            total_aum: 0,
            total_managers: 0,
            total_investors: 0,
            protocol_paused: false,
            vault_creation_fee: 100000,                 // 100 USDC equivalent
            unxv_tier_benefits: table::new(ctx),
            admin_cap,
        };

        transfer::share_object(registry);
    }

    // ==================== Core Functions ====================

    /// Create a new trader vault
    public fun create_trader_vault<T>(
        registry: &mut TraderVaultRegistry,
        vault_name: String,
        strategy_description: String,
        profit_share_percentage: u64,
        minimum_investment: u64,
        risk_profile: String,
        initial_deposit: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): String {
        assert!(!registry.protocol_paused, E_PROTOCOL_PAUSED);
        assert!(profit_share_percentage >= registry.min_profit_share && 
                profit_share_percentage <= registry.max_profit_share, E_INVALID_PROFIT_SHARE);

        let timestamp = clock::timestamp_ms(clock);
        let manager = tx_context::sender(ctx);
        let initial_amount = coin::value(&initial_deposit);
        
        // Create vault ID
        let vault_count = registry.vault_count + 1;
        let mut vault_id = string::utf8(b"VAULT_");
        let count_bytes = sui::bcs::to_bytes(&vault_count);
        string::append(&mut vault_id, string::utf8(count_bytes));

        // Validate minimum stake requirement
        let required_stake = (initial_amount * registry.min_stake_percentage) / 10000;
        assert!(initial_amount >= required_stake, E_INSUFFICIENT_STAKE);

        // Create vault risk limits
        let vault_risk_limits = VaultRiskLimits {
            max_position_size: 2000,                    // 20%
            max_leverage: 200,                          // 2x
            max_correlation_exposure: 6000,             // 60%
            stop_loss_threshold: 1000,                  // 10%
            daily_var_limit: 500,                       // 5%
            portfolio_var_limit: 1500,                  // 15%
            min_cash_percentage: 1000,                  // 10%
            max_illiquid_percentage: 3000,              // 30%
            max_trades_per_day: 50,
            max_new_positions_per_day: 10,
        };

        let vault = TraderVault<T> {
            id: object::new(ctx),
            vault_id: vault_id,
            vault_name,
            manager,
            vault_balance: coin::into_balance(initial_deposit),
            total_shares: 1000000,                      // Initial shares (1M)
            share_price: 1000000,                       // $1.00 in micro units
            manager_shares: 1000000,                    // All initial shares to manager
            manager_stake_value: initial_amount,
            required_stake_value: required_stake,
            stake_deficit: 0,
            investor_positions: table::new(ctx),
            investor_count: 0,
            max_investors: 100,
            active_positions: table::new(ctx),
            position_count: 0,
            inception_date: timestamp,
            high_water_mark: 1000000,                   // Initial NAV
            total_return: SignedInt { value: 0, is_negative: false },
            max_drawdown: 0,
            current_drawdown: 0,
            profit_share_percentage,
            accrued_performance_fees: 0,
            total_fees_paid: 0,
            last_fee_calculation: timestamp,
            minimum_investment,
            accepting_deposits: true,
            vault_status: string::utf8(b"ACTIVE"),
            risk_profile,
            strategy_description,
            investor_protections: registry.default_investor_protections,
            vault_risk_limits,
            daily_trades: 0,
            last_trade_date: 0,
            trading_enabled: true,
        };

        // Create vault info
        let vault_info = VaultInfo {
            vault_id: vault.vault_id,
            vault_name: vault.vault_name,
            manager,
            total_assets: initial_amount,
            manager_stake: initial_amount,
            manager_stake_percentage: 10000,            // 100% initially
            investor_deposits: 0,
            profit_share_percentage,
            inception_date: timestamp,
            total_return: SignedInt { value: 0, is_negative: false },
            annualized_return: SignedInt { value: 0, is_negative: false },
            max_drawdown: 0,
            sharpe_ratio: 0,
            vault_status: string::utf8(b"ACTIVE"),
            accepting_deposits: true,
            minimum_investment,
            investor_count: 0,
            risk_profile,
        };

        // Update manager info
        if (table::contains(&registry.vault_managers, manager)) {
            let manager_info = table::borrow_mut(&mut registry.vault_managers, manager);
            vector::push_back(&mut manager_info.managed_vaults, vault.vault_id);
            manager_info.vault_count = manager_info.vault_count + 1;
            manager_info.total_aum = manager_info.total_aum + initial_amount;
        } else {
            let manager_info = ManagerInfo {
                manager_address: manager,
                manager_name: string::utf8(b"Manager"),
                managed_vaults: vector::singleton(vault.vault_id),
                total_aum: initial_amount,
                vault_count: 1,
                overall_performance: SignedInt { value: 0, is_negative: false },
                reputation_score: 5000,                 // Starting score of 50
                total_profit_generated: 0,
                total_fees_earned: 0,
                trading_experience: string::utf8(b"INTERMEDIATE"),
                trading_style: string::utf8(b"BALANCED"),
                verification_status: string::utf8(b"UNVERIFIED"),
                track_record_length: 0,
            };
            table::add(&mut registry.vault_managers, manager, manager_info);
            registry.total_managers = registry.total_managers + 1;
        };

        // Add vault to registry
        table::add(&mut registry.active_vaults, vault.vault_id, vault_info);
        registry.vault_count = vault_count;
        registry.total_aum = registry.total_aum + initial_amount;

        // Emit event
        event::emit(TraderVaultCreated {
            vault_id: vault.vault_id,
            manager,
            vault_name: vault.vault_name,
            initial_deposit: initial_amount,
            manager_stake: initial_amount,
            manager_stake_percentage: 10000,
            profit_share_percentage,
            minimum_investment,
            risk_profile: vault.risk_profile,
            strategy_description: vault.strategy_description,
            timestamp,
        });

        let vault_id_copy = vault.vault_id;
        transfer::share_object(vault);
        vault_id_copy
    }

    /// Make investor deposit into vault
    public fun make_investor_deposit<T>(
        vault: &mut TraderVault<T>,
        registry: &mut TraderVaultRegistry,
        deposit: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        assert!(vault.accepting_deposits, E_VAULT_PAUSED);
        assert!(!registry.protocol_paused, E_PROTOCOL_PAUSED);
        
        let investor = tx_context::sender(ctx);
        let deposit_amount = coin::value(&deposit);
        let timestamp = clock::timestamp_ms(clock);
        
        assert!(deposit_amount >= vault.minimum_investment, E_MINIMUM_INVESTMENT_NOT_MET);
        assert!(vault.investor_count < vault.max_investors, E_MAXIMUM_INVESTORS_REACHED);

        // Calculate shares to issue
        let total_vault_value = balance::value(&vault.vault_balance);
        let shares_to_issue = if (vault.total_shares == 0) {
            deposit_amount
        } else {
            (deposit_amount * vault.total_shares) / total_vault_value
        };

        // Add deposit to vault
        balance::join(&mut vault.vault_balance, coin::into_balance(deposit));
        vault.total_shares = vault.total_shares + shares_to_issue;

        // Track investor position
        let is_first_time = !table::contains(&vault.investor_positions, investor);
        
        if (is_first_time) {
            let position = InvestorPosition {
                investor,
                shares_owned: shares_to_issue,
                initial_investment: deposit_amount,
                total_deposits: deposit_amount,
                total_withdrawals: 0,
                unrealized_pnl: SignedInt { value: 0, is_negative: false },
                realized_pnl: SignedInt { value: 0, is_negative: false },
                fees_paid: 0,
                first_investment_date: timestamp,
                last_activity_date: timestamp,
                average_cost_basis: vault.share_price,
                auto_reinvest: false,
                risk_tolerance: string::utf8(b"MODERATE"),
            };
            table::add(&mut vault.investor_positions, investor, position);
            vault.investor_count = vault.investor_count + 1;
            registry.total_investors = registry.total_investors + 1;
        } else {
            let position = table::borrow_mut(&mut vault.investor_positions, investor);
            position.shares_owned = position.shares_owned + shares_to_issue;
            position.total_deposits = position.total_deposits + deposit_amount;
            position.last_activity_date = timestamp;
        };

        // Update vault info in registry
        if (table::contains(&registry.active_vaults, vault.vault_id)) {
            let vault_info = table::borrow_mut(&mut registry.active_vaults, vault.vault_id);
            vault_info.total_assets = vault_info.total_assets + deposit_amount;
            vault_info.investor_deposits = vault_info.investor_deposits + deposit_amount;
            vault_info.investor_count = vault.investor_count;
            
            // Recalculate manager stake percentage
            vault_info.manager_stake_percentage = 
                (vault.manager_stake_value * 10000) / vault_info.total_assets;
        };

        // Update total AUM
        registry.total_aum = registry.total_aum + deposit_amount;

        // Calculate ownership percentage
        let ownership_percentage = (shares_to_issue * 10000) / vault.total_shares;
        
        // Emit event
        event::emit(InvestorDeposit {
            vault_id: vault.vault_id,
            investor,
            deposit_amount,
            shares_issued: shares_to_issue,
            share_price: vault.share_price,
            total_shares_after_deposit: vault.total_shares,
            percentage_ownership: ownership_percentage,
            first_time_investor: is_first_time,
            total_vault_assets_after: balance::value(&vault.vault_balance),
            investor_count_after: vault.investor_count,
            timestamp,
        });

        shares_to_issue
    }

    /// Request withdrawal from vault
    public fun request_withdrawal<T>(
        vault: &mut TraderVault<T>,
        shares_to_redeem: u64,
        withdrawal_type: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let investor = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);
        
        assert!(table::contains(&vault.investor_positions, investor), E_NOT_AUTHORIZED);
        
        let position = table::borrow(&vault.investor_positions, investor);
        assert!(position.shares_owned >= shares_to_redeem, E_INSUFFICIENT_BALANCE);

        // Calculate estimated withdrawal amount
        let total_vault_value = balance::value(&vault.vault_balance);
        let estimated_amount = (shares_to_redeem * total_vault_value) / vault.total_shares;
        
        // Determine notice period based on vault settings
        let notice_period = vault.investor_protections.withdrawal_notice_period * 86400000; // Convert days to ms
        let notice_period_end = timestamp + notice_period;
        
        let withdrawal_request = WithdrawalRequest {
            id: object::new(ctx),
            vault_id: vault.vault_id,
            investor,
            shares_to_redeem,
            estimated_amount,
            request_timestamp: timestamp,
            notice_period_end,
            withdrawal_type,
            processing_status: string::utf8(b"PENDING"),
        };

        let request_id = object::uid_to_inner(&withdrawal_request.id);
        
        // Calculate remaining position
        let remaining_shares = position.shares_owned - shares_to_redeem;
        let remaining_value = (remaining_shares * total_vault_value) / vault.total_shares;
        
        // Emit event
        event::emit(WithdrawalRequested {
            vault_id: vault.vault_id,
            investor,
            withdrawal_request_id: request_id,
            shares_to_redeem,
            estimated_withdrawal_amount: estimated_amount,
            current_share_price: vault.share_price,
            notice_period_end,
            estimated_processing_date: notice_period_end + 86400000, // +1 day processing
            withdrawal_fee: 0,                           // No withdrawal fee for now
            remaining_shares,
            remaining_investment_value: remaining_value,
            timestamp,
        });

        transfer::public_transfer(withdrawal_request, investor);
        request_id
    }

    /// Execute vault trade (simplified for demo)
    public fun execute_vault_trade<T>(
        vault: &mut TraderVault<T>,
        registry: &TraderVaultRegistry,
        asset: String,
        trade_type: String,
        quantity: u64,
        execution_price: u64,
        strategy_tag: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let manager = tx_context::sender(ctx);
        let timestamp = clock::timestamp_ms(clock);
        
        assert!(vault.manager == manager, E_NOT_AUTHORIZED);
        assert!(vault.trading_enabled, E_VAULT_PAUSED);
        assert!(!registry.protocol_paused, E_PROTOCOL_PAUSED);

        // Validate daily trade limit
        let current_date = timestamp / 86400000;      // Convert to days
        let last_trade_date = vault.last_trade_date / 86400000;
        
        if (current_date == last_trade_date) {
            assert!(vault.daily_trades < vault.vault_risk_limits.max_trades_per_day, E_RISK_LIMIT_EXCEEDED);
        };

        let trade_id = object::new(ctx);
        let trade_id_inner = object::uid_to_inner(&trade_id);
        object::delete(trade_id);

        let total_value = quantity * execution_price;
        let slippage = 10;                              // 0.1% simplified slippage
        let transaction_costs = total_value / 1000;     // 0.1% transaction cost

        // Create trading position (simplified)
        let mut position_id = string::utf8(b"POS_");
        string::append_utf8(&mut position_id, b"001");

        let trading_position = TradingPosition {
            position_id,
            asset,
            position_type: if (trade_type == string::utf8(b"BUY")) {
                string::utf8(b"LONG")
            } else {
                string::utf8(b"SHORT")
            },
            entry_price: execution_price,
            current_price: execution_price,
            quantity,
            notional_value: total_value,
            unrealized_pnl: SignedInt { value: 0, is_negative: false },
            realized_pnl: SignedInt { value: 0, is_negative: false },
            position_risk: 1000,                        // 10% risk
            stop_loss: option::none(),
            take_profit: option::none(),
            entry_timestamp: timestamp,
            last_update: timestamp,
            strategy_tag,
            confidence_level: 7,
        };

        // Store asset before moving trading_position
        let asset_copy = trading_position.asset;
        
        table::add(&mut vault.active_positions, trading_position.position_id, trading_position);
        vault.position_count = vault.position_count + 1;

        // Update daily trades
        if (current_date == last_trade_date) {
            vault.daily_trades = vault.daily_trades + 1;
        } else {
            vault.daily_trades = 1;
            vault.last_trade_date = timestamp;
        };

        // Emit event
        event::emit(TradeExecuted {
            vault_id: vault.vault_id,
            manager,
            trade_id: trade_id_inner,
            asset: asset_copy,
            trade_type,
            quantity,
            execution_price,
            total_value,
            execution_venue: string::utf8(b"DEFAULT"),
            slippage,
            transaction_costs,
            vault_cash_change: if (trade_type == string::utf8(b"BUY")) { 
                SignedInt { value: total_value, is_negative: true } 
            } else { 
                SignedInt { value: total_value, is_negative: false } 
            },
            portfolio_risk_change: SignedInt { value: 500, is_negative: false }, // 5% risk increase
            timestamp,
        });

        trade_id_inner
    }

    /// Calculate and distribute performance fees
    public fun calculate_performance_fees<T>(
        vault: &mut TraderVault<T>,
        registry: &mut TraderVaultRegistry,
        clock: &Clock,
        ctx: &TxContext,
    ): u64 {
        let timestamp = clock::timestamp_ms(clock);
        let current_nav = calculate_nav_per_share(vault);
        
        // Only calculate fees if above high water mark
        if (current_nav <= vault.high_water_mark) {
            return 0
        };

        let profit_above_hwm = current_nav - vault.high_water_mark;
        let total_vault_value = balance::value(&vault.vault_balance);
        let total_profit = (profit_above_hwm * total_vault_value) / 1000000;
        
        let performance_fee_rate = vault.profit_share_percentage;
        let fees_earned = (total_profit * performance_fee_rate) / 10000;
        
        // Update high water mark
        vault.high_water_mark = current_nav;
        vault.accrued_performance_fees = vault.accrued_performance_fees + fees_earned;
        vault.total_fees_paid = vault.total_fees_paid + fees_earned;
        vault.last_fee_calculation = timestamp;

        // Update manager info
        if (table::contains(&registry.vault_managers, vault.manager)) {
            let manager_info = table::borrow_mut(&mut registry.vault_managers, vault.manager);
            manager_info.total_fees_earned = manager_info.total_fees_earned + fees_earned;
        };

        // Emit event
        event::emit(PerformanceFeesCalculated {
            vault_id: vault.vault_id,
            manager: vault.manager,
            calculation_period: timestamp - vault.last_fee_calculation,
            high_water_mark: vault.high_water_mark,
            current_nav,
            profit_above_hwm,
            performance_fee_rate,
            fees_earned,
            manager_fee_share: fees_earned,
            protocol_fee_share: 0,                      // No protocol fee for now
            nav_after_fees: current_nav,
            investor_impact: profit_above_hwm - ((fees_earned * 1000000) / total_vault_value),
            timestamp,
        });

        fees_earned
    }

    /// Validate manager stake requirement
    public fun validate_manager_stake<T>(
        vault: &TraderVault<T>,
        registry: &TraderVaultRegistry,
    ): bool {
        let total_vault_value = balance::value(&vault.vault_balance);
        let required_stake = (total_vault_value * registry.min_stake_percentage) / 10000;
        vault.manager_stake_value >= required_stake
    }

    /// Update vault performance metrics
    public fun update_vault_performance<T>(
        vault: &mut TraderVault<T>,
        registry: &mut TraderVaultRegistry,
        clock: &Clock,
        _ctx: &TxContext,
    ) {
        let timestamp = clock::timestamp_ms(clock);
        let current_nav = calculate_nav_per_share(vault);
        let total_vault_value = balance::value(&vault.vault_balance);
        
        // Calculate daily return
        let daily_return = if (current_nav >= vault.share_price) {
            SignedInt { 
                value: ((current_nav - vault.share_price) * 10000) / vault.share_price, 
                is_negative: false 
            }
        } else {
            SignedInt { 
                value: ((vault.share_price - current_nav) * 10000) / vault.share_price, 
                is_negative: true 
            }
        };
        vault.share_price = current_nav;
        
        // Calculate drawdown
        if (current_nav < vault.high_water_mark) {
            let drawdown = ((vault.high_water_mark - current_nav) * 10000) / vault.high_water_mark;
            vault.current_drawdown = drawdown;
            if (drawdown > vault.max_drawdown) {
                vault.max_drawdown = drawdown;
            };
        } else {
            vault.current_drawdown = 0;
        };

        // Update vault info in registry
        if (table::contains(&registry.active_vaults, vault.vault_id)) {
            let vault_info = table::borrow_mut(&mut registry.active_vaults, vault.vault_id);
            vault_info.total_assets = total_vault_value;
            vault_info.max_drawdown = vault.max_drawdown;
            
            // Calculate annualized return (simplified)
            let time_elapsed = timestamp - vault.inception_date;
            if (time_elapsed > 31536000000) {  // More than 1 year
                let total_return_pct = if (current_nav >= 1000000) {
                    SignedInt { 
                        value: ((current_nav - 1000000) * 10000) / 1000000, 
                        is_negative: false 
                    }
                } else {
                    SignedInt { 
                        value: ((1000000 - current_nav) * 10000) / 1000000, 
                        is_negative: true 
                    }
                };
                vault_info.annualized_return = total_return_pct;
                vault_info.total_return = total_return_pct;
            };
        };

        // Emit performance update event
        event::emit(DailyPerformanceUpdate {
            vault_id: vault.vault_id,
            date: timestamp / 86400000,                 // Convert to days
            daily_return,
            nav_per_share: current_nav,
            total_vault_value,
            trades_today: vault.daily_trades,
            trading_pnl: SignedInt { value: 0, is_negative: false }, // Simplified
            daily_var: 500,                             // 5% simplified VaR
            portfolio_volatility: 1500,                 // 15% simplified volatility
            current_drawdown: vault.current_drawdown,
            net_flows: SignedInt { value: 0, is_negative: false }, // Simplified
            investor_count: vault.investor_count,
            timestamp,
        });
    }

    /// Emergency pause vault
    public fun emergency_pause_vault<T>(
        vault: &mut TraderVault<T>,
        registry: &TraderVaultRegistry,
        _admin_cap: &AdminCap,
    ) {
        vault.accepting_deposits = false;
        vault.trading_enabled = false;
        vault.vault_status = string::utf8(b"PAUSED");
    }

    /// Resume vault operations
    public fun resume_vault_operations<T>(
        vault: &mut TraderVault<T>,
        registry: &TraderVaultRegistry,
        _admin_cap: &AdminCap,
    ) {
        vault.accepting_deposits = true;
        vault.trading_enabled = true;
        vault.vault_status = string::utf8(b"ACTIVE");
    }

    // ==================== Helper Functions ====================

    /// Calculate NAV per share
    fun calculate_nav_per_share<T>(vault: &TraderVault<T>): u64 {
        let total_value = balance::value(&vault.vault_balance);
        if (vault.total_shares == 0) {
            1000000  // $1.00 default
        } else {
            (total_value * 1000000) / vault.total_shares
        }
    }

    /// Calculate total return
    fun calculate_total_return(initial_value: u64, current_value: u64): SignedInt {
        if (current_value >= initial_value) {
            SignedInt { 
                value: ((current_value - initial_value) * 10000) / initial_value, 
                is_negative: false 
            }
        } else {
            SignedInt { 
                value: ((initial_value - current_value) * 10000) / initial_value, 
                is_negative: true 
            }
        }
    }

    /// Check if risk limits are exceeded
    fun check_risk_limits<T>(vault: &TraderVault<T>, position_value: u64): bool {
        let total_value = balance::value(&vault.vault_balance);
        let position_percentage = (position_value * 10000) / total_value;
        position_percentage <= vault.vault_risk_limits.max_position_size
    }

    // ==================== Admin Functions ====================

    /// Update global risk parameters
    public fun update_global_risk_parameters(
        registry: &mut TraderVaultRegistry,
        new_limits: GlobalRiskLimits,
        _admin_cap: &AdminCap,
    ) {
        registry.global_risk_limits = new_limits;
    }

    /// Update protocol fees
    public fun update_protocol_fees(
        registry: &mut TraderVaultRegistry,
        vault_creation_fee: u64,
        _admin_cap: &AdminCap,
    ) {
        registry.vault_creation_fee = vault_creation_fee;
    }

    /// Emergency pause protocol
    public fun emergency_pause_protocol(
        registry: &mut TraderVaultRegistry,
        _admin_cap: &AdminCap,
    ) {
        registry.protocol_paused = true;
    }

    /// Resume protocol operations
    public fun resume_protocol_operations(
        registry: &mut TraderVaultRegistry,
        _admin_cap: &AdminCap,
    ) {
        registry.protocol_paused = false;
    }

    // ==================== View Functions ====================

    /// Get vault information
    public fun get_vault_info<T>(vault: &TraderVault<T>): (String, address, u64, u64, u64, String, bool) {
        (
            vault.vault_id,
            vault.manager,
            balance::value(&vault.vault_balance),
            vault.total_shares,
            vault.share_price,
            vault.vault_status,
            vault.accepting_deposits
        )
    }

    /// Get investor position
    public fun get_investor_position<T>(vault: &TraderVault<T>, investor: address): (u64, u64, u64, SignedInt, u64) {
        if (table::contains(&vault.investor_positions, investor)) {
            let position = table::borrow(&vault.investor_positions, investor);
            (
                position.shares_owned,
                position.initial_investment,
                position.total_deposits,
                position.unrealized_pnl,
                position.fees_paid
            )
        } else {
            (0, 0, 0, SignedInt { value: 0, is_negative: false }, 0)
        }
    }

    /// Get vault performance metrics
    public fun get_vault_performance<T>(vault: &TraderVault<T>): (SignedInt, u64, u64, u64, u64) {
        (
            vault.total_return,
            vault.max_drawdown,
            vault.current_drawdown,
            vault.high_water_mark,
            vault.accrued_performance_fees
        )
    }

    /// Get manager information
    public fun get_manager_info(registry: &TraderVaultRegistry, manager: address): (String, u64, u64, SignedInt, u64) {
        if (table::contains(&registry.vault_managers, manager)) {
            let manager_info = table::borrow(&registry.vault_managers, manager);
            (
                manager_info.manager_name,
                manager_info.total_aum,
                manager_info.vault_count,
                manager_info.overall_performance,
                manager_info.reputation_score
            )
        } else {
            (string::utf8(b""), 0, 0, SignedInt { value: 0, is_negative: false }, 0)
        }
    }

    /// Get registry statistics
    public fun get_registry_stats(registry: &TraderVaultRegistry): (u64, u64, u64, u64, bool) {
        (
            registry.vault_count,
            registry.total_aum,
            registry.total_managers,
            registry.total_investors,
            registry.protocol_paused
        )
    }

    // ==================== Test Helper Functions ====================

    #[test_only]
    /// Initialize for testing
    public fun init_for_testing(ctx: &mut TxContext): AdminCap {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        let default_protections = InvestorProtections {
            max_drawdown_limit: 2000,
            daily_loss_limit: 500,
            monthly_loss_limit: 1500,
            withdrawal_frequency: string::utf8(b"WEEKLY"),
            withdrawal_notice_period: 7,
            emergency_withdrawal: true,
            max_single_position: 2000,
            max_concentration: 3000,
            lock_up_period: 2592000000,
            cooling_off_period: 86400000,
        };

        let default_risk_limits = GlobalRiskLimits {
            max_single_position: 2500,
            max_leverage: 300,
            max_concentration: 4000,
            daily_loss_limit: 1000,
            monthly_loss_limit: 2000,
            volatility_limit: 5000,
            correlation_limit: 7000,
        };

        // Create another admin cap to return for testing
        let return_admin_cap = AdminCap {
            id: object::new(ctx),
        };

        let registry = TraderVaultRegistry {
            id: object::new(ctx),
            active_vaults: table::new(ctx),
            vault_managers: table::new(ctx),
            vault_count: 0,
            min_stake_percentage: 500,
            max_profit_share: 2500,
            min_profit_share: 500,
            default_profit_share: 1000,
            global_risk_limits: default_risk_limits,
            default_investor_protections: default_protections,
            total_aum: 0,
            total_managers: 0,
            total_investors: 0,
            protocol_paused: false,
            vault_creation_fee: 100000,
            unxv_tier_benefits: table::new(ctx),
            admin_cap,
        };

        transfer::share_object(registry);
        return_admin_cap
    }

    #[test_only]
    /// Create test USDC coin
    public fun create_test_usdc(amount: u64, ctx: &mut TxContext): Coin<USDC> {
        coin::mint_for_testing<USDC>(amount, ctx)
    }

    #[test_only]
    /// Get admin cap for testing
    public fun get_admin_cap_for_testing(registry: &TraderVaultRegistry): &AdminCap {
        &registry.admin_cap
    }

    #[test_only]
    /// Create GlobalRiskLimits for testing
    public fun create_test_global_risk_limits(
        max_single_position: u64,
        max_leverage: u64,
        max_concentration: u64,
        daily_loss_limit: u64,
        monthly_loss_limit: u64,
        volatility_limit: u64,
        correlation_limit: u64,
    ): GlobalRiskLimits {
        GlobalRiskLimits {
            max_single_position,
            max_leverage,
            max_concentration,
            daily_loss_limit,
            monthly_loss_limit,
            volatility_limit,
            correlation_limit,
        }
    }

    #[test_only]
    /// Check if SignedInt is zero
    public fun signed_int_is_zero(value: &SignedInt): bool {
        value.value == 0
    }

    #[test_only]
    /// Get SignedInt value for comparison
    public fun signed_int_value(value: &SignedInt): u64 {
        value.value
    }

    #[test_only]
    /// Check if SignedInt is negative
    public fun signed_int_is_negative(value: &SignedInt): bool {
        value.is_negative
    }
}


