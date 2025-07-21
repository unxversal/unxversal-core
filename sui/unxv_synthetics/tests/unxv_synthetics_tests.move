#[test_only]
module unxv_synthetics::synthetics_tests {
    use std::string;
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::balance;
    
    use unxv_synthetics::unxv_synthetics::{
        Self,
        SynthRegistry,
        AdminCap,
        CollateralVault,
        USDC,
    };
    
    // Test constants
    const ADMIN: address = @0xA;
    const USER1: address = @0xB;
    
    const INITIAL_USDC: u64 = 1000000000; // 1000 USDC (6 decimals)
    const SBTC_DECIMALS: u8 = 8;
    
    // Helper function to create USDC coins for testing
    fun create_usdc(amount: u64, scenario: &mut Scenario): Coin<USDC> {
        coin::from_balance(balance::create_for_testing<USDC>(amount), test_scenario::ctx(scenario))
    }
    
    #[test]
    fun test_basic_functionality() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Initialize the protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Test basic vault operations
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut vault = unxv_synthetics::create_vault(test_scenario::ctx(&mut scenario));
            assert!(unxv_synthetics::get_vault_owner(&vault) == USER1, 1);
            assert!(unxv_synthetics::get_vault_collateral_balance(&vault) == 0, 2);
            
            // Deposit collateral
            let usdc_coin = create_usdc(INITIAL_USDC, &mut scenario);
            unxv_synthetics::deposit_collateral(
                &mut vault,
                usdc_coin,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            assert!(unxv_synthetics::get_vault_collateral_balance(&vault) == INITIAL_USDC, 3);
            
            test_scenario::return_to_sender(&scenario, vault);
        };
        
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_admin_functions() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Initialize the protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Test admin operations
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<AdminCap>(&scenario);
            
            // Create a synthetic asset
            unxv_synthetics::create_synthetic_asset(
                &admin_cap,
                &mut registry,
                string::utf8(b"Synthetic Bitcoin"),
                string::utf8(b"sBTC"),
                SBTC_DECIMALS,
                vector[1, 2, 3, 4], // Mock Pyth feed ID
                15000, // 150% min collateral ratio
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify the synthetic asset was created
            let asset = unxv_synthetics::get_synthetic_asset(&registry, string::utf8(b"sBTC"));
            assert!(unxv_synthetics::get_asset_name(asset) == string::utf8(b"Synthetic Bitcoin"), 1);
            assert!(unxv_synthetics::get_asset_symbol(asset) == string::utf8(b"sBTC"), 2);
            assert!(unxv_synthetics::get_asset_decimals(asset) == SBTC_DECIMALS, 3);
            assert!(unxv_synthetics::get_asset_min_collateral_ratio(asset) == 15000, 4);
            assert!(unxv_synthetics::get_asset_is_active(asset) == true, 5);
            assert!(unxv_synthetics::get_asset_total_supply(asset) == 0, 6);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_global_params() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Check global parameters
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<SynthRegistry>(&scenario);
            let params = unxv_synthetics::get_global_params(&registry);
            
            assert!(unxv_synthetics::get_params_min_collateral_ratio(params) == 15000, 1);
            assert!(unxv_synthetics::get_params_liquidation_threshold(params) == 12000, 2);
            assert!(unxv_synthetics::get_params_liquidation_penalty(params) == 500, 3);
            
            test_scenario::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_debt_tracking() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
        
        // Setup
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_synthetics::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Create vault
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let vault = unxv_synthetics::create_vault(test_scenario::ctx(&mut scenario));
            
            // Test debt tracking (should be 0 initially)
            assert!(unxv_synthetics::get_vault_debt(&vault, string::utf8(b"sBTC")) == 0, 1);
            assert!(unxv_synthetics::get_vault_debt(&vault, string::utf8(b"sETH")) == 0, 2);
            
            test_scenario::return_to_sender(&scenario, vault);
        };
        
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
