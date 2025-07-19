#[test_only]
module unxv_lending::unxv_lending_tests {
    use std::string;
    use std::vector;
    
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::object;
    use sui::test_utils;
    
    use pyth::price_info::PriceInfoObject;
    
    use unxv_lending::unxv_lending::{
        Self,
        LendingRegistry,
        LendingPool,
        UserAccount,
        LiquidationEngine,
        YieldFarmingVault,
        FlashLoan,
        SupplyReceipt,
        RepayReceipt,
        HealthFactorResult,
        StakingResult,
        USDC,
        SUI,
        UNXV
    };
    
    // Test addresses
    const ADMIN: address = @0xAD;
    const ALICE: address = @0xA11CE;
    const BOB: address = @0xB0B;
    const LIQUIDATOR: address = @0x11C;
    
    // Test constants
    const INITIAL_SUPPLY: u64 = 1000000000; // 1000 USDC
    const INITIAL_BORROW: u64 = 500000000;  // 500 USDC
    const STAKE_AMOUNT: u64 = 25000000;     // 25 UNXV (Tier 3)
    
    // ========== Test Setup Helpers ==========
    
    fun setup_test_scenario(): Scenario {
        test_scenario::begin(ADMIN)
    }
    
    fun create_test_clock(scenario: &mut Scenario): Clock {
        test_scenario::next_tx(scenario, ADMIN);
        clock::create_for_testing(scenario.ctx())
    }
    
    // ========== Test Module Initialization ==========
    
    #[test]
    fun test_module_init() {
        let mut scenario = setup_test_scenario();
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Check that shared objects were created
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let liquidation_engine = test_scenario::take_shared<LiquidationEngine>(&scenario);
            let yield_vault = test_scenario::take_shared<YieldFarmingVault>(&scenario);
            
            // Verify initial state
            assert!(!unxv_lending::is_system_paused(&registry), 0);
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(liquidation_engine);
            test_scenario::return_shared(yield_vault);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test Admin Functions ==========
    
    #[test]
    fun test_add_supported_asset_and_create_pool() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Add USDC as supported asset
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true,  // is_collateral
                true,  // is_borrowable
                8000   // 80% collateral factor
            );
            
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            // Verify asset was added
            assert!(unxv_lending::is_asset_supported(&registry, string::utf8(b"USDC")), 0);
            
            test_scenario::return_shared(registry);
        };
        
        // Create lending pool for USDC
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let pool_id = unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            // Verify pool was created
            assert!(object::id_to_address(&pool_id) != @0x0, 0);
            
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_pause_and_resume_system() {
        let mut scenario = setup_test_scenario();
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Test emergency pause
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            unxv_lending::emergency_pause(&mut registry, scenario.ctx());
            assert!(unxv_lending::is_system_paused(&registry), 0);
            
            test_scenario::return_shared(registry);
        };
        
        // Test resume system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            unxv_lending::resume_system(&mut registry, scenario.ctx());
            assert!(!unxv_lending::is_system_paused(&registry), 1);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test User Account Management ==========
    
    #[test]
    fun test_user_account_creation() {
        let mut scenario = setup_test_scenario();
        
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let account = unxv_lending::create_user_account(scenario.ctx());
            
            // Verify account properties
            let (collateral, debt, health_factor, tier) = unxv_lending::get_account_summary(&account);
            assert!(collateral == 0, 0);
            assert!(debt == 0, 1);
            assert!(health_factor > 0, 2);
            assert!(tier == 0, 3);
            
            test_utils::destroy(account);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test Supply and Withdraw Operations ==========
    
    #[test]
    fun test_supply_and_withdraw_asset() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize and setup
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Add USDC support and create pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Alice supplies USDC
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let usdc_coin = unxv_lending::create_test_coin<USDC>(INITIAL_SUPPLY, scenario.ctx());
            
            let receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                usdc_coin,
                true, // use as collateral
                &clock,
                scenario.ctx()
            );
            
            // Verify supply receipt
            let (amount_supplied, scaled_amount, _, _) = unxv_lending::get_supply_receipt_info(&receipt);
            assert!(amount_supplied == INITIAL_SUPPLY, 0);
            assert!(scaled_amount > 0, 1);
            
            // Verify pool state
            let (total_supply, _, supply_rate, _, _) = unxv_lending::get_pool_info(&pool);
            assert!(total_supply == INITIAL_SUPPLY, 2);
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(receipt);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    // ========== Test Borrow and Repay Operations ==========
    
    #[test] 
    fun test_borrow_and_repay_workflow() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Setup protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Alice supplies and then borrows
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            // First supply collateral
            let usdc_coin = unxv_lending::create_test_coin<USDC>(INITIAL_SUPPLY, scenario.ctx());
            let _supply_receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                usdc_coin,
                true,
                &clock,
                scenario.ctx()
            );
            
            // Then borrow against collateral
            let borrowed_coin = unxv_lending::test_borrow_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                INITIAL_BORROW,
                string::utf8(b"VARIABLE"),
                &clock,
                scenario.ctx()
            );
            
            // Verify borrow
            assert!(coin::value(&borrowed_coin) == INITIAL_BORROW, 0);
            
            // Repay some debt
            let repay_coin = unxv_lending::create_test_coin<USDC>(INITIAL_BORROW / 2, scenario.ctx());
            let repay_receipt = unxv_lending::repay_debt<USDC>(
                &mut pool,
                &mut account,
                &registry,
                repay_coin,
                &clock,
                scenario.ctx()
            );
            
            // Verify repayment
            let (amount_repaid, _, _, _) = unxv_lending::get_repay_receipt_info(&repay_receipt);
            assert!(amount_repaid == INITIAL_BORROW / 2, 1);
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(_supply_receipt);
            test_utils::destroy(borrowed_coin);
            test_utils::destroy(repay_receipt);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    // ========== Test Health Factor ==========
    
    #[test]
    fun test_health_factor_calculation() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Setup protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Test health factor with no debt (should be very high)
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let health_result = unxv_lending::test_calculate_health_factor(
                &account,
                &registry,
                &clock
            );
            
            // Health factor should be very high with no debt
            let (health_factor, is_liquidatable) = unxv_lending::get_health_factor_result_info(&health_result);
            assert!(health_factor > 10000, 0);
            assert!(!is_liquidatable, 1);
            
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(health_result);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    // ========== Test UNXV Staking ==========
    
    #[test]
    fun test_unxv_staking_benefits() {
        let mut scenario = setup_test_scenario();
        
        // Initialize the module
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Alice stakes UNXV for benefits
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut vault = test_scenario::take_shared<YieldFarmingVault>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            
            let unxv_coin = unxv_lending::create_test_coin<UNXV>(STAKE_AMOUNT, scenario.ctx());
            
            let staking_result = unxv_lending::stake_unxv_for_benefits(
                &mut vault,
                &mut account,
                unxv_coin,
                0, // no lock duration for test
                scenario.ctx()
            );
            
            // Verify staking result - should be Tier 3 (25K UNXV)
            let (new_tier, borrow_rate_discount, supply_rate_bonus, benefits) = unxv_lending::get_staking_result_info(&staking_result);
            assert!(new_tier == 3, 0);
            assert!(borrow_rate_discount > 0, 1);
            assert!(supply_rate_bonus > 0, 2);
            assert!(vector::length(&benefits) > 0, 3);
            
            test_scenario::return_shared(vault);
            test_utils::destroy(account);
            test_utils::destroy(staking_result);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Test Flash Loans ==========
    
    #[test]
    fun test_flash_loan_workflow() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Setup protocol with liquidity
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Add liquidity first
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let usdc_coin = unxv_lending::create_test_coin<USDC>(INITIAL_SUPPLY * 2, scenario.ctx());
            let _supply_receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                usdc_coin,
                false,
                &clock,
                scenario.ctx()
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(_supply_receipt);
        };
        
        // Bob takes flash loan
        test_scenario::next_tx(&mut scenario, BOB);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let flash_amount = INITIAL_SUPPLY;
            
            // Initiate flash loan
            let (loan_coin, flash_loan) = unxv_lending::initiate_flash_loan<USDC>(
                &mut pool,
                &registry,
                flash_amount,
                scenario.ctx()
            );
            
            // Verify loan amount
            assert!(coin::value(&loan_coin) == flash_amount, 0);
            
            // Simulate some operation with borrowed funds...
            // For test, just prepare repayment
            let fee = (flash_amount * 9) / 10000; // 0.09% fee
            let repay_amount = flash_amount + fee;
            let mut repay_coin = unxv_lending::create_test_coin<USDC>(repay_amount, scenario.ctx());
            
            // Add borrowed amount to repayment
            coin::join(&mut repay_coin, loan_coin);
            
            // Repay flash loan
            unxv_lending::repay_flash_loan<USDC>(
                &mut pool,
                &registry,
                repay_coin,
                flash_loan,
                scenario.ctx()
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    // ========== Test Error Conditions ==========
    
    #[test]
    #[expected_failure]
    fun test_supply_unsupported_asset() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Try to supply unsupported asset (no pool created)
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let usdc_coin = unxv_lending::create_test_coin<USDC>(INITIAL_SUPPLY, scenario.ctx());
            
            // This should fail - no USDC support added
            let _receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                usdc_coin,
                true,
                &clock,
                scenario.ctx()
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(_receipt);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure]
    fun test_borrow_insufficient_collateral() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Setup protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Try to borrow without sufficient collateral
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            // Supply small amount as collateral
            let usdc_coin = unxv_lending::create_test_coin<USDC>(100000, scenario.ctx());
            let _supply_receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                usdc_coin,
                true,
                &clock,
                scenario.ctx()
            );
            
            // Try to borrow way more than collateral allows
            let _borrowed_coin = unxv_lending::test_borrow_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                INITIAL_SUPPLY, // Much more than collateral
                string::utf8(b"VARIABLE"),
                &clock,
                scenario.ctx()
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(_supply_receipt);
            test_utils::destroy(_borrowed_coin);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure]
    fun test_flash_loan_not_repaid() {
        let mut scenario = setup_test_scenario();
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Try flash loan without proper repayment
        test_scenario::next_tx(&mut scenario, BOB);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let (loan_coin, flash_loan) = unxv_lending::initiate_flash_loan<USDC>(
                &mut pool,
                &registry,
                1000000,
                scenario.ctx()
            );
            
            // Try to repay with insufficient amount (should fail)
            let insufficient_repay = unxv_lending::create_test_coin<USDC>(500000, scenario.ctx());
            
            unxv_lending::repay_flash_loan<USDC>(
                &mut pool,
                &registry,
                insufficient_repay,
                flash_loan,
                scenario.ctx()
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(loan_coin);
        };
        
        test_scenario::end(scenario);
    }
    
    // ========== Integration Tests ==========
    
    #[test]
    fun test_full_lending_workflow() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Step 1: Initialize system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_lending::init_for_testing(scenario.ctx());
        };
        
        // Step 2: Setup USDC asset
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = unxv_lending::create_test_asset_config(
                string::utf8(b"USDC"),
                true, true, 8000
            );
            let interest_model = unxv_lending::create_test_interest_model();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                string::utf8(b"USDC"),
                asset_config,
                interest_model,
                scenario.ctx()
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                string::utf8(b"USDC"),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Step 3: Alice supplies liquidity
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let usdc_coin = unxv_lending::create_test_coin<USDC>(INITIAL_SUPPLY, scenario.ctx());
            let _supply_receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                usdc_coin,
                true,
                &clock,
                scenario.ctx()
            );
            
            sui::transfer::public_transfer(account, ALICE);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(_supply_receipt);
        };
        
        // Step 4: Bob borrows against Alice's liquidity
        test_scenario::next_tx(&mut scenario, BOB);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let mut account = unxv_lending::create_user_account(scenario.ctx());
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            // Bob supplies collateral first
            let collateral_coin = unxv_lending::create_test_coin<USDC>(INITIAL_SUPPLY / 2, scenario.ctx());
            let _supply_receipt = unxv_lending::test_supply_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                collateral_coin,
                true,
                &clock,
                scenario.ctx()
            );
            
            // Bob borrows
            let borrowed_coin = unxv_lending::test_borrow_asset<USDC>(
                &mut pool,
                &mut account,
                &registry,
                INITIAL_BORROW / 4, // Conservative borrow
                string::utf8(b"VARIABLE"),
                &clock,
                scenario.ctx()
            );
            
            // Verify borrow succeeded
            assert!(coin::value(&borrowed_coin) > 0, 0);
            
            sui::transfer::public_transfer(account, BOB);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(_supply_receipt);
            test_utils::destroy(borrowed_coin);
        };
        
        // Step 5: Verify system state
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let (total_supply, total_borrows, supply_rate, borrow_rate, utilization) = 
                unxv_lending::get_pool_info(&pool);
            
            // Verify pool has liquidity and borrows
            assert!(total_supply > 0, 1);
            assert!(total_borrows > 0, 2);
            assert!(utilization > 0, 3);
            assert!(supply_rate >= 0, 4);
            assert!(borrow_rate > supply_rate, 5);
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
        };
        
        clock.destroy_for_testing();
        test_scenario::end(scenario);
    }
}
