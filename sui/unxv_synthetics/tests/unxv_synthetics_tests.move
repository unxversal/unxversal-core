#[test_only]
module unxv_synthetics::unxv_synthetics_tests {
    use std::string;
    
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    
    use unxv_synthetics::unxv_synthetics::{
        Self,
        SynthRegistry,
        CollateralVault,
        AdminCap,
    };
    
    // Test addresses
    const ADMIN: address = @0xAD;
    const ALICE: address = @0xA11CE;
    const BOB: address = @0xB0B;
    
    // Test constants
    const INITIAL_COLLATERAL: u64 = 1000000; // 1M USDC (6 decimals)
    
    // ========== Test Setup Helpers ==========
    
    fun setup_test_scenario(): Scenario {
        test_scenario::begin(ADMIN)
    }
    
    fun create_test_clock(scenario: &mut Scenario): Clock {
        test_scenario::next_tx(scenario, ADMIN);
        clock::create_for_testing(scenario.ctx())
    }
    
    fun create_mock_price_info(): vector<u8> {
        // Mock Pyth price feed ID for testing
        x"e62df6c8b4c85fe1d72a89b5b96fe7a7e4f7e1b1b47c5b4b8e8e8e8e8e8e8e8e"
    }
    
    // ========== Test Module Initialization ==========
    
    #[test]
    fun test_module_init() {
        let mut scenario = setup_test_scenario();
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Check that registry was created and shared
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            // Verify initial state
            let params = unxv_synthetics::get_global_params(&registry);
            assert!(unxv_synthetics::get_params_min_collateral_ratio(params) == 15000, 0);
            assert!(!unxv_synthetics::is_system_paused(&registry), 1);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test Admin Functions ==========
    
    #[test]
    fun test_create_synthetic_asset() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Create a synthetic asset
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Synthetic Bitcoin"),
                string::utf8(b"sBTC"),
                8,
                create_mock_price_info(),
                15000, // 150% min collateral ratio
                &clock,
                scenario.ctx(),
            );
            
            // Verify asset was created
            let asset = unxv_synthetics::get_synthetic_asset(&registry, string::utf8(b"sBTC"));
            assert!(unxv_synthetics::get_asset_name(asset) == string::utf8(b"Synthetic Bitcoin"), 0);
            assert!(unxv_synthetics::get_asset_symbol(asset) == string::utf8(b"sBTC"), 1);
            assert!(unxv_synthetics::get_asset_decimals(asset) == 8, 2);
            assert!(unxv_synthetics::get_asset_min_collateral_ratio(asset) == 15000, 3);
            assert!(unxv_synthetics::get_asset_is_active(asset), 4);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_pause_resume_system() {
        let mut scenario = setup_test_scenario();
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Test emergency pause
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::emergency_pause(&admin_cap, &mut registry, scenario.ctx());
            assert!(unxv_synthetics::is_system_paused(&registry), 0);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        // Test resume system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::resume_system(&admin_cap, &mut registry, scenario.ctx());
            assert!(!unxv_synthetics::is_system_paused(&registry), 1);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_update_global_params() {
        let mut scenario = setup_test_scenario();
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Update global parameters
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            let new_params = unxv_synthetics::create_global_params_for_testing(
                20000, // 200%
                15000, // 150%
                1000, // 10%
                50,
                300, // 3%
                100, // 1%
                50, // 0.5%
            );
            
            unxv_synthetics::update_global_params(&admin_cap, &mut registry, new_params, scenario.ctx());
            
            let params = unxv_synthetics::get_global_params(&registry);
            assert!(unxv_synthetics::get_params_min_collateral_ratio(params) == 20000, 0);
            assert!(unxv_synthetics::get_params_liquidation_threshold(params) == 15000, 1);
            assert!(unxv_synthetics::get_params_liquidation_penalty(params) == 1000, 2);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test Vault Management ==========
    
    #[test]
    fun test_vault_creation() {
        let mut scenario = setup_test_scenario();
        
        // Create vault as Alice
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let vault = unxv_synthetics::create_vault(scenario.ctx());
            
            // Verify vault properties
            assert!(unxv_synthetics::get_vault_collateral_balance(&vault) == 0, 0);
            assert!(unxv_synthetics::get_vault_debt(&vault, string::utf8(b"sBTC")) == 0, 1);
            
            // Transfer vault to Alice for further tests
            sui::transfer::public_transfer(vault, ALICE);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_collateral_deposit_withdraw() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Create vault and deposit collateral as Alice
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let vault = unxv_synthetics::create_vault(scenario.ctx());
            sui::transfer::public_transfer(vault, ALICE);
        };
        
        // Deposit collateral
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut vault = test_scenario::take_from_sender<CollateralVault>(&scenario);
            let usdc = unxv_synthetics::create_test_usdc(INITIAL_COLLATERAL, scenario.ctx());
            
            unxv_synthetics::deposit_collateral(&mut vault, usdc, &clock, scenario.ctx());
            
            // Verify deposit
            assert!(unxv_synthetics::get_vault_collateral_balance(&vault) == INITIAL_COLLATERAL, 0);
            
            test_scenario::return_to_sender(&scenario, vault);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    // ========== Test Error Conditions ==========
    
    #[test]
    #[expected_failure]
    fun test_unauthorized_asset_creation() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Try to create asset as non-admin without AdminCap (should fail)
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            // Alice tries to take AdminCap but doesn't have one - this will fail
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Synthetic Bitcoin"),
                string::utf8(b"sBTC"),
                8,
                create_mock_price_info(),
                15000,
                &clock,
                scenario.ctx(),
            );
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure]
    fun test_duplicate_asset_creation() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Create first asset
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Synthetic Bitcoin"),
                string::utf8(b"sBTC"),
                8,
                create_mock_price_info(),
                15000,
                &clock,
                scenario.ctx(),
            );
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        // Try to create duplicate asset (should fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Another Bitcoin"),
                string::utf8(b"sBTC"), // Same symbol
                8,
                create_mock_price_info(),
                15000,
                &clock,
                scenario.ctx(),
            );
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure]
    fun test_unauthorized_vault_access() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Alice creates vault
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let vault = unxv_synthetics::create_vault(scenario.ctx());
            sui::transfer::public_transfer(vault, ALICE);
        };
        
        // Bob tries to deposit to Alice's vault (should fail)
        test_scenario::next_tx(&mut scenario, BOB);
        {
            let mut vault = test_scenario::take_from_address<CollateralVault>(&scenario, ALICE);
            let usdc = unxv_synthetics::create_test_usdc(INITIAL_COLLATERAL, scenario.ctx());
            
            unxv_synthetics::deposit_collateral(&mut vault, usdc, &clock, scenario.ctx());
            
            test_scenario::return_to_address(ALICE, vault);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure]
    fun test_zero_amount_deposit() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Create vault
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let vault = unxv_synthetics::create_vault(scenario.ctx());
            sui::transfer::public_transfer(vault, ALICE);
        };
        
        // Try to deposit zero amount (should fail)
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut vault = test_scenario::take_from_sender<CollateralVault>(&scenario);
            let usdc = unxv_synthetics::create_test_usdc(0, scenario.ctx()); // Zero amount
            
            unxv_synthetics::deposit_collateral(&mut vault, usdc, &clock, scenario.ctx());
            
            test_scenario::return_to_sender(&scenario, vault);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    // ========== Test Health Check Functions ==========
    
    #[test]
    fun test_system_stability_check() {
        let mut scenario = setup_test_scenario();
        
        // Initialize system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            let health = unxv_synthetics::check_system_stability(&registry);
            
            // System should be solvent with no positions
            assert!(unxv_synthetics::get_health_system_solvent(&health), 0);
            assert!(unxv_synthetics::get_health_at_risk_vaults(&health) == 0, 1);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test Fee Calculations ==========

#[test]
    fun test_fee_calculation_basic() {
        let mut scenario = setup_test_scenario();
        
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            // Test basic fee calculation without UNXV discount
            let fee_calc = unxv_synthetics::calculate_fee_with_discount(
                10000, // $100 base amount
                50,    // 0.5% fee rate
                string::utf8(b"USDC"),
                0      // No UNXV balance
            );
            
            assert!(unxv_synthetics::get_fee_base_fee(&fee_calc) == 50, 0); // 0.5% of 10000
            assert!(unxv_synthetics::get_fee_unxv_discount(&fee_calc) == 0, 1); // No discount
            assert!(unxv_synthetics::get_fee_final_fee(&fee_calc) == 50, 2); // Same as base fee
            assert!(unxv_synthetics::get_fee_payment_asset(&fee_calc) == string::utf8(b"USDC"), 3);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Integration Tests ==========
    
    #[test]
    fun test_full_workflow() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Step 1: Initialize system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        // Step 2: Create synthetic asset
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Synthetic Bitcoin"),
                string::utf8(b"sBTC"),
                8,
                create_mock_price_info(),
                15000,
                &clock,
                scenario.ctx(),
            );
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        // Step 3: Create vault and deposit collateral
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let vault = unxv_synthetics::create_vault(scenario.ctx());
            let mut vault = vault;
            let usdc = unxv_synthetics::create_test_usdc(INITIAL_COLLATERAL, scenario.ctx());
            
            unxv_synthetics::deposit_collateral(&mut vault, usdc, &clock, scenario.ctx());
            
            // Verify collateral was deposited
            assert!(unxv_synthetics::get_vault_collateral_balance(&vault) == INITIAL_COLLATERAL, 0);
            
            sui::transfer::public_transfer(vault, ALICE);
        };
        
        // Step 4: Verify system state
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let vault = test_scenario::take_from_sender<CollateralVault>(&scenario);
            let registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            // Check that vault has correct balance and no debt
            assert!(unxv_synthetics::get_vault_collateral_balance(&vault) == INITIAL_COLLATERAL, 1);
            assert!(unxv_synthetics::get_vault_debt(&vault, string::utf8(b"sBTC")) == 0, 2);
            
            // Check that synthetic asset exists and is active
            let asset = unxv_synthetics::get_synthetic_asset(&registry, string::utf8(b"sBTC"));
            assert!(unxv_synthetics::get_asset_is_active(asset), 3);
            assert!(unxv_synthetics::get_asset_total_supply(asset) == 0, 4); // No tokens minted yet
            
            test_scenario::return_to_sender(&scenario, vault);
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_getter_functions() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize and create test data
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Synthetic Bitcoin"),
                string::utf8(b"sBTC"),
                8,
                create_mock_price_info(),
                15000,
                &clock,
                scenario.ctx(),
            );
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(registry);
        };
        
        // Test getter functions
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            
            // Test get_synthetic_asset
            let asset = unxv_synthetics::get_synthetic_asset(&registry, string::utf8(b"sBTC"));
            assert!(unxv_synthetics::get_asset_name(asset) == string::utf8(b"Synthetic Bitcoin"), 0);
            assert!(unxv_synthetics::get_asset_symbol(asset) == string::utf8(b"sBTC"), 1);
            assert!(unxv_synthetics::get_asset_decimals(asset) == 8, 2);
            
            // Test get_global_params
            let params = unxv_synthetics::get_global_params(&registry);
            assert!(unxv_synthetics::get_params_min_collateral_ratio(params) == 15000, 3);
            assert!(unxv_synthetics::get_params_liquidation_threshold(params) == 12000, 4);
            
            // Test is_system_paused
            assert!(!unxv_synthetics::is_system_paused(&registry), 5);
            
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
}
