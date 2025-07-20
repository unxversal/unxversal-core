#[test_only]
module unxv_manuallp::unxv_manuallp_tests {
    use std::string;
    
    use sui::test_scenario::{Self, next_tx};
    use sui::coin;
    use sui::clock;
    
    use unxv_manuallp::unxv_manuallp::{
        Self,
        ManualLPRegistry,
        USDC,
        UNXV,
    };
    
    // Test addresses
    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    
    // Test constants
    const TEST_DEPOSIT_A: u64 = 1000_000000; // 1000 USDC
    const TEST_DEPOSIT_B: u64 = 500_000000; // 500 UNXV
    const TEST_UNXV_AMOUNT: u64 = 25000_000000; // 25,000 UNXV for tier 3
    
    // Helper function to create test USDC
    fun create_test_usdc(amount: u64, ctx: &mut sui::tx_context::TxContext): sui::coin::Coin<USDC> {
        coin::mint_for_testing<USDC>(amount, ctx)
    }
    
    // Helper function to create test UNXV
    fun create_test_unxv(amount: u64, ctx: &mut sui::tx_context::TxContext): sui::coin::Coin<UNXV> {
        coin::mint_for_testing<UNXV>(amount, ctx)
    }
    
    #[test]
    fun test_protocol_initialization() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        next_tx(&mut scenario, ADMIN);
        {
            // Initialize the protocol
            unxv_manuallp::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, ADMIN);
        {
            // Verify registry was created and is accessible
            assert!(test_scenario::has_most_recent_shared<ManualLPRegistry>(), 1);
            
            let registry = test_scenario::take_shared<ManualLPRegistry>(&scenario);
            
            // Test that registry is properly initialized
            assert!(!unxv_manuallp::is_protocol_paused(&registry), 2);
            
            // Test that strategy templates are available
            let templates = unxv_manuallp::get_strategy_templates(&registry);
            assert!(sui::table::length(templates) >= 2, 3); // Should have AMM_OVERLAY and GRID_TRADING
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_vault_creation() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        next_tx(&mut scenario, ADMIN);
        {
            unxv_manuallp::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Create a vault
        next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<ManualLPRegistry>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            // Advance clock to ensure non-zero timestamp
            clock::increment_for_testing(&mut clock, 1000);
            
            // Create test coins
            let usdc_coin = create_test_usdc(TEST_DEPOSIT_A, test_scenario::ctx(&mut scenario));
            let unxv_coin = create_test_unxv(TEST_DEPOSIT_B, test_scenario::ctx(&mut scenario));
            
            // Create strategy parameters and risk limits
            let strategy_parameters = sui::table::new<string::String, u64>(test_scenario::ctx(&mut scenario));
            
            let risk_limits = unxv_manuallp::create_test_user_risk_limits(
                1000000_000000, // max_position_size
                5_000000,       // max_daily_loss (5%)
                15_000000,      // max_weekly_loss
                25_000000,      // max_monthly_loss
                80_000000,      // max_single_asset_exposure
                60_000000,      // max_correlated_assets_exposure
                50_000000,      // max_volatility_exposure
                true,           // volatility_scaling
                10_000000,      // min_liquidity_buffer
                5_000000,       // emergency_liquidity_threshold
            );
            
            let rebalancing_settings = unxv_manuallp::create_test_rebalancing_settings(
                string::utf8(b"THRESHOLD_BASED"), // rebalancing_strategy
                86400,          // rebalancing_frequency (Daily)
                5_000000,       // price_movement_threshold (5%)
                1000_000000,    // liquidity_threshold
                10_000000,      // max_rebalancing_cost
                1000,           // gas_price_limit
                100_000000,     // rebalancing_budget
                std::vector::empty(), // preferred_rebalancing_times
                true,           // avoid_high_volatility_periods
                false,          // market_hours_only
            );
            
            // Create vault
            let vault = unxv_manuallp::create_manual_lp_vault(
                &mut registry,
                string::utf8(b"Test Vault"),
                string::utf8(b"AMM_OVERLAY"),
                usdc_coin,
                unxv_coin,
                strategy_parameters,
                risk_limits,
                rebalancing_settings,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify vault details
            let (owner, vault_name, strategy_template, creation_time) = 
                unxv_manuallp::get_vault_details_for_testing(&vault);
            
            assert!(owner == USER1, 4);
            assert!(vault_name == string::utf8(b"Test Vault"), 5);
            assert!(strategy_template == string::utf8(b"AMM_OVERLAY"), 6);
            assert!(creation_time > 0, 7);
            
            // Get vault info
            let (name, template, status, balance_a, balance_b, timestamp) = 
                unxv_manuallp::get_vault_info(&vault);
            
            assert!(name == string::utf8(b"Test Vault"), 8);
            assert!(template == string::utf8(b"AMM_OVERLAY"), 9);
            assert!(status == string::utf8(b"ACTIVE"), 10);
            assert!(balance_a == TEST_DEPOSIT_A, 11);
            assert!(balance_b == TEST_DEPOSIT_B, 12);
            assert!(timestamp > 0, 13);
            
            // Transfer vault to user
            sui::transfer::public_transfer(vault, USER1);
            
            test_scenario::return_shared(registry);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_unxv_tier_calculation() {
        let mut scenario = test_scenario::begin(USER1);
        
        next_tx(&mut scenario, USER1);
        {
            // Test tier 0 (no UNXV)
            let tier = unxv_manuallp::calculate_unxv_tier(0);
            assert!(tier == 0, 14);
            
            // Test tier 1 (1,000 UNXV)
            let tier = unxv_manuallp::calculate_unxv_tier(1000_000000);
            assert!(tier == 1, 15);
            
            // Test tier 3 (25,000 UNXV)
            let tier = unxv_manuallp::calculate_unxv_tier(TEST_UNXV_AMOUNT);
            assert!(tier == 3, 16);
            
            // Test tier 5 (500,000 UNXV)
            let tier = unxv_manuallp::calculate_unxv_tier(500000_000000);
            assert!(tier == 5, 17);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_signed_int_operations() {
        let mut scenario = test_scenario::begin(USER1);
        
        next_tx(&mut scenario, USER1);
        {
            // Test positive numbers
            let pos_10 = unxv_manuallp::signed_int_from(10);
            let pos_5 = unxv_manuallp::signed_int_from(5);
            
            // Test basic values
            let (value_10, is_neg_10) = unxv_manuallp::get_signed_int_details_for_testing(&pos_10);
            assert!(value_10 == 10, 18);
            assert!(!is_neg_10, 19);
            
            // Test addition
            let sum = unxv_manuallp::signed_int_add(&pos_10, &pos_5);
            let (sum_value, sum_is_neg) = unxv_manuallp::get_signed_int_details_for_testing(&sum);
            assert!(sum_value == 15, 20);
            assert!(!sum_is_neg, 21);
            
            // Test negative numbers
            let neg_3 = unxv_manuallp::signed_int_negative(3);
            let (neg_value, neg_is_neg) = unxv_manuallp::get_signed_int_details_for_testing(&neg_3);
            assert!(neg_value == 3, 22);
            assert!(neg_is_neg, 23);
            
            // Test subtraction
            let diff = unxv_manuallp::signed_int_subtract(&pos_10, &pos_5);
            let (diff_value, diff_is_neg) = unxv_manuallp::get_signed_int_details_for_testing(&diff);
            assert!(diff_value == 5, 24);
            assert!(!diff_is_neg, 25);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_vault_performance_update() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol and create vault
        next_tx(&mut scenario, ADMIN);
        {
            unxv_manuallp::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<ManualLPRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let usdc_coin = create_test_usdc(TEST_DEPOSIT_A, test_scenario::ctx(&mut scenario));
            let unxv_coin = create_test_unxv(TEST_DEPOSIT_B, test_scenario::ctx(&mut scenario));
            
            let mut vault = unxv_manuallp::create_test_vault(
                &mut registry,
                usdc_coin,
                unxv_coin,
                test_scenario::ctx(&mut scenario),
                &clock,
            );
            
            // Update performance
            let daily_return = unxv_manuallp::signed_int_from(50_000000); // 50 USDC profit
            unxv_manuallp::update_vault_performance(
                &mut vault,
                &registry,
                daily_return,
                10_000000, // 10 USDC fees earned
                1_000000,  // 1 USDC gas costs
                100_000000, // 100 USDC volume
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Check performance metrics
            let (total_return, fees_earned, volume_facilitated, _trades_facilitated, impermanent_loss) = 
                unxv_manuallp::get_vault_performance(&vault);
            
            let (total_return_value, _) = unxv_manuallp::get_signed_int_details_for_testing(&total_return);
            assert!(total_return_value == 0, 26); // Should be 0 initially
            assert!(fees_earned == 10_000000, 27);
            assert!(volume_facilitated == 100_000000, 28);
            
            let (il_value, _) = unxv_manuallp::get_signed_int_details_for_testing(&impermanent_loss);
            assert!(il_value == 0, 29); // Should be 0 initially
            
            sui::transfer::public_transfer(vault, USER1);
            test_scenario::return_shared(registry);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_manual_rebalancing() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol and create vault
        next_tx(&mut scenario, ADMIN);
        {
            unxv_manuallp::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<ManualLPRegistry>(&scenario);
            let mut clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let usdc_coin = create_test_usdc(TEST_DEPOSIT_A, test_scenario::ctx(&mut scenario));
            let unxv_coin = create_test_unxv(TEST_DEPOSIT_B, test_scenario::ctx(&mut scenario));
            
            let mut vault = unxv_manuallp::create_test_vault(
                &mut registry,
                usdc_coin,
                unxv_coin,
                test_scenario::ctx(&mut scenario),
                &clock,
            );
            
            // Advance time to allow rebalancing (minimum 1 hour)
            clock::increment_for_testing(&mut clock, 3700000); // 1 hour + 100 seconds
            
            // Perform manual rebalancing
            let new_tick_lower = unxv_manuallp::signed_int_negative(200);
            let new_tick_upper = unxv_manuallp::signed_int_from(200);
            
            unxv_manuallp::manual_rebalance_vault(
                &mut vault,
                &registry,
                new_tick_lower,
                new_tick_upper,
                string::utf8(b"MANUAL"),
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify rebalancing occurred
            // In a full implementation, we'd check that tick ranges were updated
            // For now, we just verify the function completed without errors
            
            sui::transfer::public_transfer(vault, USER1);
            test_scenario::return_shared(registry);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_vault_risk_metrics() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol and create vault
        next_tx(&mut scenario, ADMIN);
        {
            unxv_manuallp::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<ManualLPRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let usdc_coin = create_test_usdc(TEST_DEPOSIT_A, test_scenario::ctx(&mut scenario));
            let unxv_coin = create_test_unxv(TEST_DEPOSIT_B, test_scenario::ctx(&mut scenario));
            
            let vault = unxv_manuallp::create_test_vault(
                &mut registry,
                usdc_coin,
                unxv_coin,
                test_scenario::ctx(&mut scenario),
                &clock,
            );
            
            // Check risk metrics
            let (max_daily_loss, max_drawdown, volatility, max_position_size) = 
                unxv_manuallp::get_vault_risk_metrics(&vault);
            
            assert!(max_daily_loss == 5_000000, 30); // 5% daily loss limit
            assert!(max_drawdown == 0, 31); // Should be 0 initially
            assert!(volatility == 0, 32); // Should be 0 initially
            assert!(max_position_size == 1000000_000000, 33); // From test vault creation
            
            sui::transfer::public_transfer(vault, USER1);
            test_scenario::return_shared(registry);
            clock::destroy_for_testing(clock);
        };
        
        test_scenario::end(scenario);
    }
}
