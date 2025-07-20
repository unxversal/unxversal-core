#[test_only]
module unxv_vaults::unxv_vaults_tests {
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::test_utils;
    use std::string::{Self, String};
    use std::vector;

    use unxv_vaults::unxv_vaults::{
        Self,
        TraderVaultRegistry,
        TraderVault,
        AdminCap,
        USDC,
        WithdrawalRequest,
        VaultInfo,
        ManagerInfo,
        InvestorPosition,
        TradingPosition,
        GlobalRiskLimits,
        InvestorProtections,
    };

    // Test token types for vaults
    public struct TokenA has drop {}
    public struct TokenB has drop {}

    const ADMIN: address = @0xAD;
    const MANAGER1: address = @0xA1;
    const MANAGER2: address = @0xA2;
    const INVESTOR1: address = @0x1;
    const INVESTOR2: address = @0x2;

    // Helper to create test coins
    fun create_test_token_a(amount: u64, scenario: &mut Scenario): Coin<TokenA> {
        coin::mint_for_testing<TokenA>(amount, test_scenario::ctx(scenario))
    }

    fun create_test_token_b(amount: u64, scenario: &mut Scenario): Coin<TokenB> {
        coin::mint_for_testing<TokenB>(amount, test_scenario::ctx(scenario))
    }

    fun create_test_usdc(amount: u64, scenario: &mut Scenario): Coin<USDC> {
        unxv_vaults::create_test_usdc(amount, test_scenario::ctx(scenario))
    }

    #[test]
    fun test_protocol_initialization() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        transfer::public_transfer(admin_cap, ADMIN);
        
        // Verify registry exists
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let (vault_count, total_aum, total_managers, total_investors, paused) = 
                unxv_vaults::get_registry_stats(&registry);
            
            assert!(vault_count == 0, 1);
            assert!(total_aum == 0, 2);
            assert!(total_managers == 0, 3);
            assert!(total_investors == 0, 4);
            assert!(!paused, 5);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_create_trader_vault() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario); // 1M tokens
            
            // Create a new trader vault
            let vault_id = unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Test Vault"),
                string::utf8(b"Balanced growth strategy"),
                1000, // 10% profit share
                10000, // Minimum investment
                string::utf8(b"MODERATE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify vault was created
            assert!(!string::is_empty(&vault_id), 6);
            
            let (new_vault_count, new_total_aum, new_total_managers, _, _) = 
                unxv_vaults::get_registry_stats(&registry);
            
            assert!(new_vault_count == 1, 7);
            assert!(new_total_aum == 1000000, 8);
            assert!(new_total_managers == 1, 9);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_investor_deposit() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create vault
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Test Vault"),
                string::utf8(b"Growth strategy"),
                1500, // 15% profit share
                5000, // Minimum investment
                string::utf8(b"AGGRESSIVE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Investor makes deposit
        test_scenario::next_tx(&mut scenario, INVESTOR1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit = create_test_token_a(100000, &mut scenario); // 100K tokens
            
            let shares_issued = unxv_vaults::make_investor_deposit(
                &mut vault,
                &mut registry,
                deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            assert!(shares_issued > 0, 10);
            
            // Verify vault info updated
            let (_, _, total_assets, total_shares, _, _, accepting_deposits) = 
                unxv_vaults::get_vault_info(&vault);
            
            assert!(total_assets == 1100000, 11); // 1M + 100K
            assert!(total_shares > 1000000, 12);
            assert!(accepting_deposits, 13);
            
            // Verify investor position
            let (shares_owned, initial_investment, total_deposits, unrealized_pnl, fees_paid) = 
                unxv_vaults::get_investor_position(&vault, INVESTOR1);
            
            assert!(shares_owned > 0, 14);
            assert!(initial_investment == 100000, 15);
            assert!(total_deposits == 100000, 16);
            assert!(unxv_vaults::signed_int_is_zero(&unrealized_pnl), 17);
            assert!(fees_paid == 0, 18);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_withdrawal_request() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create vault, and make deposit
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Test Vault"),
                string::utf8(b"Conservative strategy"),
                800, // 8% profit share
                1000, // Minimum investment
                string::utf8(b"CONSERVATIVE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, INVESTOR1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit = create_test_token_a(50000, &mut scenario);
            
            unxv_vaults::make_investor_deposit(
                &mut vault,
                &mut registry,
                deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        // Request withdrawal
        test_scenario::next_tx(&mut scenario, INVESTOR1);
        {
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let (shares_owned, _, _, _, _) = 
                unxv_vaults::get_investor_position(&vault, INVESTOR1);
            
            let withdrawal_id = unxv_vaults::request_withdrawal(
                &mut vault,
                shares_owned / 2, // Withdraw half
                string::utf8(b"PARTIAL"),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify withdrawal request was created
            assert!(withdrawal_id != sui::object::id_from_address(@0x0), 19);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_vault_trade_execution() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create vault
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(2000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Trading Vault"),
                string::utf8(b"Active trading strategy"),
                2000, // 20% profit share
                50000, // Minimum investment
                string::utf8(b"AGGRESSIVE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Execute trade
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let trade_id = unxv_vaults::execute_vault_trade(
                &mut vault,
                &registry,
                string::utf8(b"BTC"),
                string::utf8(b"BUY"),
                100, // quantity
                50000, // execution price
                string::utf8(b"MOMENTUM"),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify trade was executed
            assert!(trade_id != sui::object::id_from_address(@0x0), 20);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_performance_fee_calculation() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create vault
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Performance Vault"),
                string::utf8(b"High performance strategy"),
                2500, // 25% profit share
                10000,
                string::utf8(b"AGGRESSIVE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Calculate performance fees (when above high water mark)
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let fees_earned = unxv_vaults::calculate_performance_fees(
                &mut vault,
                &mut registry,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Since no profits yet, fees should be 0
            assert!(fees_earned == 0, 21);
            
            // Check vault performance metrics
            let (total_return, max_drawdown, current_drawdown, high_water_mark, accrued_fees) = 
                unxv_vaults::get_vault_performance(&vault);
            
            assert!(unxv_vaults::signed_int_is_zero(&total_return), 22);
            assert!(max_drawdown == 0, 23);
            assert!(current_drawdown == 0, 24);
            assert!(high_water_mark > 0, 25);
            assert!(accrued_fees == 0, 26);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_manager_stake_validation() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create vault
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Stake Test Vault"),
                string::utf8(b"Stake validation test"),
                1000,
                1000,
                string::utf8(b"MODERATE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Validate manager stake
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            
            let stake_valid = unxv_vaults::validate_manager_stake(&vault, &registry);
            assert!(stake_valid, 27); // Should be valid initially
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_vault_performance_update() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create vault
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1500000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Performance Update Vault"),
                string::utf8(b"Performance tracking test"),
                1200,
                5000,
                string::utf8(b"MODERATE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Update performance
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            unxv_vaults::update_vault_performance(
                &mut vault,
                &mut registry,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify performance metrics exist
            let (_, _, _, high_water_mark, _) = 
                unxv_vaults::get_vault_performance(&vault);
            
            assert!(high_water_mark > 0, 28);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_emergency_controls() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Emergency Test Vault"),
                string::utf8(b"Emergency controls test"),
                1000,
                1000,
                string::utf8(b"MODERATE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Test emergency pause
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            
            // Emergency pause vault
            unxv_vaults::emergency_pause_vault(&mut vault, &registry, &admin_cap);
            
            // Verify vault is paused
            let (_, _, _, _, _, status, accepting_deposits) = 
                unxv_vaults::get_vault_info(&vault);
            
            assert!(status == string::utf8(b"PAUSED"), 29);
            assert!(!accepting_deposits, 30);
            
            // Resume operations
            unxv_vaults::resume_vault_operations(&mut vault, &registry, &admin_cap);
            
            // Verify vault is active again
            let (_, _, _, _, _, new_status, new_accepting_deposits) = 
                unxv_vaults::get_vault_info(&vault);
            
            assert!(new_status == string::utf8(b"ACTIVE"), 31);
            assert!(new_accepting_deposits, 32);
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_protocol_level_controls() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            
            // Test protocol pause
            unxv_vaults::emergency_pause_protocol(&mut registry, &admin_cap);
            
            let (_, _, _, _, paused) = unxv_vaults::get_registry_stats(&registry);
            assert!(paused, 33);
            
            // Resume protocol
            unxv_vaults::resume_protocol_operations(&mut registry, &admin_cap);
            
            let (_, _, _, _, new_paused) = unxv_vaults::get_registry_stats(&registry);
            assert!(!new_paused, 34);
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_multiple_investors_same_vault() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create vault
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(2000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Multi Investor Vault"),
                string::utf8(b"Multiple investors test"),
                1500,
                10000,
                string::utf8(b"MODERATE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // First investor deposit
        test_scenario::next_tx(&mut scenario, INVESTOR1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit1 = create_test_token_a(500000, &mut scenario);
            
            let shares1 = unxv_vaults::make_investor_deposit(
                &mut vault,
                &mut registry,
                deposit1,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            assert!(shares1 > 0, 35);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        // Second investor deposit
        test_scenario::next_tx(&mut scenario, INVESTOR2);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit2 = create_test_token_a(300000, &mut scenario);
            
            let shares2 = unxv_vaults::make_investor_deposit(
                &mut vault,
                &mut registry,
                deposit2,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            assert!(shares2 > 0, 36);
            
            // Verify vault has 2 investors
            let (_, _, total_assets, _, _, _, _) = 
                unxv_vaults::get_vault_info(&vault);
            
            assert!(total_assets == 2800000, 37); // 2M + 500K + 300K
            
            // Verify both investors have positions
            let (shares1, _, _, _, _) = 
                unxv_vaults::get_investor_position(&vault, INVESTOR1);
            let (shares2_check, _, _, _, _) = 
                unxv_vaults::get_investor_position(&vault, INVESTOR2);
            
            assert!(shares1 > 0, 38);
            assert!(shares2_check > 0, 39);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_manager_info_tracking() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Manager Info Test"),
                string::utf8(b"Manager tracking test"),
                1200,
                5000,
                string::utf8(b"MODERATE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Check manager info was created
            let (manager_name, total_aum, vault_count, overall_performance, reputation_score) = 
                unxv_vaults::get_manager_info(&registry, MANAGER1);
            
            assert!(!string::is_empty(&manager_name), 40);
            assert!(total_aum == 1000000, 41);
            assert!(vault_count == 1, 42);
            assert!(unxv_vaults::signed_int_is_zero(&overall_performance), 43);
            assert!(reputation_score > 0, 44);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_risk_parameters_update() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            
            // Create new risk limits
            let new_limits = unxv_vaults::create_test_global_risk_limits(
                3000, // max_single_position: 30%
                500, // max_leverage: 5x
                5000, // max_concentration: 50%
                1500, // daily_loss_limit: 15%
                3000, // monthly_loss_limit: 30%
                6000, // volatility_limit: 60%
                8000, // correlation_limit: 80%
            );
            
            // Update global risk parameters
            unxv_vaults::update_global_risk_parameters(&mut registry, new_limits, &admin_cap);
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

#[test]
    fun test_protocol_fees_update() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            
            // Update protocol fees
            unxv_vaults::update_protocol_fees(&mut registry, 200000, &admin_cap); // 200 USDC
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_multiple_vaults_same_manager() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        // Create first vault
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit1 = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Vault 1"),
                string::utf8(b"First vault"),
                1000,
                10000,
                string::utf8(b"CONSERVATIVE"),
                initial_deposit1,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Create second vault with same manager
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit2 = create_test_token_b(2000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenB>(
                &mut registry,
                string::utf8(b"Vault 2"),
                string::utf8(b"Second vault"),
                1500,
                20000,
                string::utf8(b"AGGRESSIVE"),
                initial_deposit2,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify manager info updated
            let (_, total_aum, vault_count, _, _) = 
                unxv_vaults::get_manager_info(&registry, MANAGER1);
            
            assert!(total_aum == 3000000, 45); // 1M + 2M
            assert!(vault_count == 2, 46);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_comprehensive_vault_operations() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_vaults::init_for_testing(test_scenario::ctx(&mut scenario));
        
        // Create vault
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let initial_deposit = create_test_token_a(5000000, &mut scenario);
            
            unxv_vaults::create_trader_vault<TokenA>(
                &mut registry,
                string::utf8(b"Comprehensive Test Vault"),
                string::utf8(b"Full feature test"),
                2000, // 20% profit share
                50000, // Min investment
                string::utf8(b"AGGRESSIVE"),
                initial_deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        // Add multiple investors
        test_scenario::next_tx(&mut scenario, INVESTOR1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let deposit = create_test_token_a(1000000, &mut scenario);
            
            unxv_vaults::make_investor_deposit(
                &mut vault,
                &mut registry,
                deposit,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        // Execute multiple trades
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            // Execute first trade
            unxv_vaults::execute_vault_trade(
                &mut vault,
                &registry,
                string::utf8(b"ETH"),
                string::utf8(b"BUY"),
                50,
                3000,
                string::utf8(b"MOMENTUM"),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        // Update performance and calculate fees
        test_scenario::next_tx(&mut scenario, MANAGER1);
        {
            let mut registry = test_scenario::take_shared<TraderVaultRegistry>(&scenario);
            let mut vault = test_scenario::take_shared<TraderVault<TokenA>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            unxv_vaults::update_vault_performance(
                &mut vault,
                &mut registry,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            unxv_vaults::calculate_performance_fees(
                &mut vault,
                &mut registry,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify comprehensive state
            let (vault_id, manager, total_assets, total_shares, share_price, status, accepting_deposits) = 
                unxv_vaults::get_vault_info(&vault);
            
            assert!(!string::is_empty(&vault_id), 47);
            assert!(manager == MANAGER1, 48);
            assert!(total_assets > 5000000, 49);
            assert!(total_shares > 0, 50);
            assert!(share_price > 0, 51);
            assert!(status == string::utf8(b"ACTIVE"), 52);
            assert!(accepting_deposits, 53);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(vault);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
}
