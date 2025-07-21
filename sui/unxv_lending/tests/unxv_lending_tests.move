#[test_only]
module unxv_lending::unxv_lending_tests {
    use sui::test_scenario::{Self, Scenario};
    use sui::coin::{Self, Coin};
    use sui::balance;
    use sui::clock::{Self, Clock};
    use sui::test_utils;
    use std::string;
    use std::vector;
    
    use unxv_lending::unxv_lending::{
        Self,
        AdminCap,
        LendingRegistry,
        LendingPool,
        UserAccount,
        LiquidationEngine,
        YieldFarmingVault,
        AssetConfig,
        InterestRateModel,
        SupplyReceipt,
        RepayReceipt,
        HealthFactorResult,
        StakingResult,
        FlashLoan,
        LiquidationResult
    };
    
    // Test coin types
    public struct USDC has drop {}
    public struct SUI has drop {}
    public struct UNXV has drop {}
    
    // Test constants
    const ADMIN: address = @0xA11CE;
    const USER1: address = @0xB0B;
    const USER2: address = @0xCAB;
    const LIQUIDATOR: address = @0x11de;

    const USDC_DECIMALS: u8 = 6;
    const SUI_DECIMALS: u8 = 9;
    const UNXV_DECIMALS: u8 = 6;

    const MILLION: u64 = 1_000_000;
    const BILLION: u64 = 1_000_000_000;
    
    // Helper functions for test setup
    fun setup_protocol(scenario: &mut Scenario): (AdminCap, Clock) {
        test_scenario::next_tx(scenario, ADMIN);
        {
            let admin_cap = unxv_lending::init_lending_protocol(test_scenario::ctx(scenario));
            let clock = clock::create_for_testing(test_scenario::ctx(scenario));
            (admin_cap, clock)
        }
    }
    
    // Helper function to create test asset config
    fun create_test_asset_config(): AssetConfig {
        unxv_lending::create_test_asset_config_struct(
            string::utf8(b"USDC"),
            string::utf8(b"NATIVE"),
            true, // is_collateral
            true, // is_borrowable
            8000, // collateral_factor - 80%
            8500, // liquidation_threshold - 85%
            500,  // liquidation_penalty - 5%
            1000 * BILLION, // supply_cap
            800 * BILLION,  // borrow_cap
            1000, // reserve_factor - 10%
            true  // is_active
        )
    }

    // Helper function to create test interest model
    fun create_test_interest_model(): InterestRateModel {
        unxv_lending::create_test_interest_model_struct(
            200,   // base_rate - 2%
            1000,  // multiplier - 10%
            10000, // jump_multiplier - 100%
            8000,  // optimal_utilization - 80%
            50000  // max_rate - 500%
        )
    }

    fun create_test_coin<T>(amount: u64, scenario: &mut Scenario): Coin<T> {
        coin::from_balance(balance::create_for_testing<T>(amount), test_scenario::ctx(scenario))
    }

    // ========== Test Cases ==========
    
    #[test]
    fun test_protocol_initialization() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, clock) = setup_protocol(&mut scenario);

        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let liquidation_engine = test_scenario::take_shared<LiquidationEngine>(&scenario);
            let yield_vault = test_scenario::take_shared<YieldFarmingVault>(&scenario);
            
            // Test registry initialization
            assert!(!unxv_lending::is_emergency_paused(&registry), 0);
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(liquidation_engine);
            test_scenario::return_shared(yield_vault);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_add_supported_asset_and_create_pool() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, clock) = setup_protocol(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
        
        // Add USDC as supported asset
            let asset_config = create_test_asset_config();
            
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
        
        // Create lending pool for USDC
            let pool_id = unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify pool was created successfully
            assert!(pool_id != sui::object::id_from_address(@0x0), 0);
            
            test_scenario::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_create_user_account() {
        let mut scenario = test_scenario::begin(USER1);
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
            
            // Verify account initialization
            assert!(unxv_lending::get_user_health_factor(&account) == 0, 0);
            assert!(unxv_lending::get_user_supply_balance(&account, string::utf8(b"USDC")) == 0, 1);
            assert!(unxv_lending::get_user_borrow_balance(&account, string::utf8(b"USDC")) == 0, 2);

            test_utils::destroy(account);
        };
            
        test_scenario::end(scenario);
    }

    #[test]
    fun test_supply_asset() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);
        
        // Setup USDC asset and pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();

            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );

            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        // User supplies USDC
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));

            let supply_amount = 1000 * MILLION; // 1000 USDC
            let supply_coin = create_test_coin<USDC>(supply_amount, &mut scenario);

            clock::increment_for_testing(&mut clock, 1000); // Advance time

            let receipt = unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                true, // use as collateral
                &clock,
                test_scenario::ctx(&mut scenario),
            );

            // Verify supply was successful
            assert!(unxv_lending::supply_receipt_amount_supplied(&receipt) == supply_amount, 0);
            assert!(unxv_lending::get_pool_total_supply(&pool) == supply_amount, 1);
            assert!(unxv_lending::get_user_supply_balance(&account, string::utf8(b"USDC")) > 0, 2);

            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(receipt);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_borrow_asset() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);
        
        // Setup USDC asset and pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        // First user supplies USDC (provides liquidity)
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account1 = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
            
            let supply_amount = 10000 * MILLION; // 10,000 USDC
            let supply_coin = create_test_coin<USDC>(supply_amount, &mut scenario);
            
            clock::increment_for_testing(&mut clock, 1000);

            unxv_lending::supply_asset(
                &mut pool,
                &mut account1,
                &registry,
                supply_coin,
                true,
                &clock,
                test_scenario::ctx(&mut scenario),
            );

            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account1);
        };

        // Second user supplies collateral and borrows
        test_scenario::next_tx(&mut scenario, USER2);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account2 = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));

            // Supply collateral first
            let collateral_amount = 2000 * MILLION; // 2,000 USDC
            let collateral_coin = create_test_coin<USDC>(collateral_amount, &mut scenario);

            clock::increment_for_testing(&mut clock, 1000);

            unxv_lending::supply_asset(
                &mut pool,
                &mut account2,
                &registry,
                collateral_coin,
                true, // use as collateral
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Now borrow against collateral
            let borrow_amount = 1000 * MILLION; // 1,000 USDC (50% LTV)

            clock::increment_for_testing(&mut clock, 1000);

            let borrowed_coin = unxv_lending::borrow_asset(
                &mut pool,
                &mut account2,
                &registry,
                borrow_amount,
                string::utf8(b"VARIABLE"),
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify borrow was successful
            assert!(coin::value(&borrowed_coin) == borrow_amount, 0);
            assert!(unxv_lending::get_pool_total_borrows(&pool) == borrow_amount, 1);
            assert!(unxv_lending::get_user_borrow_balance(&account2, string::utf8(b"USDC")) > 0, 2);
            assert!(unxv_lending::get_user_health_factor(&account2) >= 10000, 3); // Health factor >= 1.0
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account2);
            test_utils::destroy(borrowed_coin);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test] 
    fun test_repay_debt() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);
        
        // Setup and execute borrow (reusing previous test logic)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Setup liquidity and borrowing
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));

            // Supply liquidity
            let supply_coin = create_test_coin<USDC>(10000 * MILLION, &mut scenario);
            unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                true,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Borrow
            clock::increment_for_testing(&mut clock, 1000);
            let borrow_amount = 1000 * MILLION;
            let borrowed_coin = unxv_lending::borrow_asset(
                &mut pool,
                &mut account,
                &registry,
                borrow_amount,
                string::utf8(b"VARIABLE"),
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Wait some time for interest to accrue
            clock::increment_for_testing(&mut clock, 86400000); // 1 day

            // Repay debt
            let repay_coin = create_test_coin<USDC>(borrow_amount + 100000, &mut scenario); // Extra for interest
            let receipt = unxv_lending::repay_debt(
                &mut pool,
                &mut account,
                &registry,
                repay_coin,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify repayment
            assert!(unxv_lending::repay_receipt_amount_repaid(&receipt) > 0, 0);
            assert!(unxv_lending::get_user_borrow_balance(&account, string::utf8(b"USDC")) < borrow_amount, 1);
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(borrowed_coin);
            test_utils::destroy(receipt);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_withdraw_asset() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);
        
        // Setup USDC asset and pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );

            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Supply and then withdraw
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));

            let supply_amount = 1000 * MILLION;
            let supply_coin = create_test_coin<USDC>(supply_amount, &mut scenario);

            // Supply
            unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                false, // Not as collateral for easier withdrawal
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Wait for some interest to accrue
            clock::increment_for_testing(&mut clock, 86400000); // 1 day

            // Withdraw partial amount
            let withdraw_amount = 500 * MILLION;
            let withdrawn_coin = unxv_lending::withdraw_asset(
                &mut pool,
                &mut account,
                &registry,
                withdraw_amount,
                &clock,
                test_scenario::ctx(&mut scenario),
            );

            // Verify withdrawal
            assert!(coin::value(&withdrawn_coin) == withdraw_amount, 0);
            assert!(unxv_lending::get_pool_total_supply(&pool) == supply_amount - withdraw_amount, 1);
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(withdrawn_coin);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_unxv_staking() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);

        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut vault = test_scenario::take_shared<YieldFarmingVault>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
            
            let stake_amount = 5 * MILLION; // 5 UNXV for Silver tier (5,000,000 with 6 decimals)
            let stake_coin = create_test_coin<UNXV>(stake_amount, &mut scenario);
            let lock_duration = 30 * 24 * 60 * 60 * 1000; // 30 days

            clock::increment_for_testing(&mut clock, 1000);
            
            let staking_result = unxv_lending::stake_unxv_for_benefits(
                &mut vault,
                &mut account,
                stake_coin,
                lock_duration,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify staking result
            assert!(unxv_lending::staking_result_new_tier(&staking_result) == 2, 0); // Silver tier
            assert!(unxv_lending::staking_result_borrow_rate_discount(&staking_result) == 1000, 1); // 10% discount
            assert!(unxv_lending::staking_result_supply_rate_bonus(&staking_result) == 500, 2); // 5% bonus
            
            test_scenario::return_shared(vault);
            test_utils::destroy(account);
            test_utils::destroy(staking_result);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_flash_loan() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, clock) = setup_protocol(&mut scenario);
        
        // Setup USDC asset and pool with liquidity
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Add liquidity to pool
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
            
            let supply_coin = create_test_coin<USDC>(10000 * MILLION, &mut scenario);
            unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                false,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
        };
        
        // Execute flash loan
        test_scenario::next_tx(&mut scenario, USER2);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let loan_amount = 1000 * MILLION;
            
            // Initiate flash loan
            let (loan_coin, flash_loan) = unxv_lending::initiate_flash_loan(
                &mut pool,
                &registry,
                loan_amount,
                test_scenario::ctx(&mut scenario),
            );
            
            // Verify loan received
            assert!(coin::value(&loan_coin) == loan_amount, 0);
            
            // Prepare repayment (loan + fee)
            let fee = (loan_amount * 9) / 10000; // 0.09% fee
            let repay_amount = loan_amount + fee;
            let mut repay_coin = create_test_coin<USDC>(repay_amount, &mut scenario);
            
            // Merge loan coin back for repayment simulation
            coin::join(&mut repay_coin, loan_coin);
            
            // Repay flash loan
            unxv_lending::repay_flash_loan(
                &mut pool,
                &registry,
                repay_coin,
                flash_loan,
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_interest_rate_updates() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);
        
        // Setup USDC asset and pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);

            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();

            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );

            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );

            test_scenario::return_shared(registry);
        };

        // Test interest rate changes with utilization
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let initial_utilization = unxv_lending::get_pool_utilization(&pool);
            assert!(initial_utilization == 0, 0); // No utilization initially

            // Update interest rates
            clock::increment_for_testing(&mut clock, 3600000); // 1 hour
            unxv_lending::update_interest_rates(&mut pool, &registry, &clock);

            // Add some supply and borrow to change utilization
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
            
            // Supply
            let supply_coin = create_test_coin<USDC>(1000 * MILLION, &mut scenario);
            unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                true,
                &clock,
                test_scenario::ctx(&mut scenario),
            );

            // Borrow to increase utilization
            let borrowed_coin = unxv_lending::borrow_asset(
                &mut pool,
                &mut account,
                &registry,
                400 * MILLION, // 40% utilization
                string::utf8(b"VARIABLE"),
                &clock,
                test_scenario::ctx(&mut scenario),
            );

            // Check that utilization increased
            let new_utilization = unxv_lending::get_pool_utilization(&pool);
            assert!(new_utilization > initial_utilization, 1);
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(borrowed_coin);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

#[test]
    fun test_emergency_pause() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, clock) = setup_protocol(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);

            // Pause protocol
            unxv_lending::emergency_pause_protocol(
                &mut registry,
                &admin_cap,
                test_scenario::ctx(&mut scenario),
            );

            assert!(unxv_lending::is_emergency_paused(&registry), 0);

            // Resume protocol
            unxv_lending::resume_protocol(
                &mut registry,
                &admin_cap,
                test_scenario::ctx(&mut scenario),
            );

            assert!(!unxv_lending::is_emergency_paused(&registry), 1);

            test_scenario::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_health_factor_calculation() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, mut clock) = setup_protocol(&mut scenario);

        // Setup asset and pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));

            // Supply collateral
            let supply_coin = create_test_coin<USDC>(2000 * MILLION, &mut scenario);
            unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                true,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            // Calculate health factor with no debt (should be very high)
            clock::increment_for_testing(&mut clock, 1000);
            let health_result = unxv_lending::calculate_health_factor(
                &account,
                &registry,
                &clock,
            );

            assert!(!unxv_lending::health_factor_result_is_liquidatable(&health_result), 0);
            assert!(unxv_lending::health_factor_result_health_factor(&health_result) > 10000, 1); // > 1.0
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(health_result);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = 6)]
    fun test_borrow_exceeds_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, clock) = setup_protocol(&mut scenario);

        // Setup asset without sufficient liquidity
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
            
            // Try to borrow from empty pool (should fail)
            let borrowed_coin = unxv_lending::borrow_asset(
                &mut pool,
                &mut account,
                &registry,
                1000 * MILLION,
                string::utf8(b"VARIABLE"),
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
            test_utils::destroy(account);
            test_utils::destroy(borrowed_coin);
        };
        
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
    
    #[test]
    #[expected_failure(abort_code = 1)]
    fun test_unauthorized_access() {
        let mut scenario = test_scenario::begin(ADMIN);
        let (admin_cap, clock) = setup_protocol(&mut scenario);
        
        // Create account as USER1
        test_scenario::next_tx(&mut scenario, USER1);
        let mut account = unxv_lending::create_user_account(test_scenario::ctx(&mut scenario));
        
        // Setup USDC asset and pool first
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let asset_config = create_test_asset_config();
            let rate_model = create_test_interest_model();
            let oracle_feed_id = vector::empty<u8>();
            
            unxv_lending::add_supported_asset(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                string::utf8(b"NATIVE"),
                asset_config,
                rate_model,
                oracle_feed_id,
                test_scenario::ctx(&mut scenario),
            );
            
            unxv_lending::create_lending_pool<USDC>(
                &mut registry,
                &admin_cap,
                string::utf8(b"USDC"),
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Try to use account from wrong sender (should fail)
        test_scenario::next_tx(&mut scenario, USER2); // Wrong user trying to use USER1's account
        {
            let mut pool = test_scenario::take_shared<LendingPool<USDC>>(&scenario);
            let registry = test_scenario::take_shared<LendingRegistry>(&scenario);
            let supply_coin = create_test_coin<USDC>(1000 * MILLION, &mut scenario);
            
            // This should fail because USER2 is trying to use USER1's account
            let _receipt = unxv_lending::supply_asset(
                &mut pool,
                &mut account,
                &registry,
                supply_coin,
                true,
                &clock,
                test_scenario::ctx(&mut scenario),
            );
            
            test_scenario::return_shared(pool);
            test_scenario::return_shared(registry);
        };

        test_utils::destroy(account);
        clock::destroy_for_testing(clock);
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
}
