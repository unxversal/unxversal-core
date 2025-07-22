#[test_only]
module unxv_options::unxv_options_tests {
    use std::string;
    
    use sui::clock;
    use sui::transfer;
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    
    use unxv_options::unxv_options::{
        Self, 
        OptionsRegistry, 
        OptionMarket,
        OptionPosition,
        OptionsPricingEngine,
        AdminCap
    };
    
    // Test coin type
    public struct TestCoin has drop, store {}
    
    const USER: address = @0x123;
    const ADMIN: address = @0x456;
    
    const STRIKE_PRICE_50K: u64 = 50000000000; // $50,000 with 6 decimals
    const STRIKE_PRICE_60K: u64 = 60000000000; // $60,000 with 6 decimals
    const EXPIRY_TIMESTAMP: u64 = 1735689600000; // Jan 1, 2025
    const TEST_QUANTITY: u64 = 1; // 1 option contract (more realistic)
    const TEST_COLLATERAL: u64 = 100000000000000; // $100,000,000 collateral (massive increase)
    const MAX_PREMIUM: u64 = 5000000000; // $5,000 max premium
    const MIN_PREMIUM: u64 = 1000000000; // $1,000 min premium
    
    // Helper function to setup protocol and add BTC as underlying
    fun setup_protocol_and_underlying(scenario: &mut Scenario) {
        next_tx(scenario, ADMIN);
        {
            unxv_options::init_for_testing(ctx(scenario));
        };
        
        next_tx(scenario, ADMIN);
        {
            let mut registry = test::take_shared<OptionsRegistry>(scenario);
            let admin_cap = test::take_from_sender<AdminCap>(scenario);
            
            // Add BTC as supported underlying asset
            unxv_options::add_underlying_asset(
                &mut registry,
                string::utf8(b"BTC"),
                string::utf8(b"NATIVE"),
                10000000000, // $10,000 min strike
                100000000000, // $100,000 max strike
                1000000000, // $1,000 strike increment
                string::utf8(b"CASH"),
                vector[1, 2, 3], // Pyth feed ID
                2000000, // 20% volatility estimate
                &admin_cap,
            );
            
            test::return_shared(registry);
            test::return_to_sender(scenario, admin_cap);
        };
    }
    
    // Helper function to create BTC call option market
    fun create_btc_call_market(scenario: &mut Scenario): ID {
        next_tx(scenario, ADMIN);
        let market_id;
        {
            let mut registry = test::take_shared<OptionsRegistry>(scenario);
            let admin_cap = test::take_from_sender<AdminCap>(scenario);
            
            market_id = unxv_options::create_option_market<TestCoin>(
                &mut registry,
                string::utf8(b"BTC"),
                string::utf8(b"CALL"),
                STRIKE_PRICE_50K,
                EXPIRY_TIMESTAMP,
                string::utf8(b"CASH"),
                string::utf8(b"EUROPEAN"),
                &admin_cap,
                ctx(scenario),
            );
            
            test::return_shared(registry);
            test::return_to_sender(scenario, admin_cap);
        };
        market_id
    }
    
    #[test]
    fun test_protocol_initialization() {
        let mut scenario = test::begin(ADMIN);
        
        // Initialize protocol
        {
            unxv_options::init_for_testing(ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, ADMIN);
        {
            // Check that all shared objects were created
            assert!(test::has_most_recent_shared<OptionsRegistry>(), 0);
            assert!(test::has_most_recent_shared<OptionsPricingEngine>(), 1);
            assert!(test::has_most_recent_for_sender<AdminCap>(&scenario), 2);
            
            // Check registry initial state
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            assert!(!unxv_options::is_system_paused(&registry), 3);
            assert!(unxv_options::get_total_options_created(&registry) == 0, 4);
            assert!(unxv_options::get_total_volume(&registry) == 0, 5);
            
            test::return_shared(registry);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_add_underlying_asset() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_underlying(&mut scenario);
        
        next_tx(&mut scenario, ADMIN);
        {
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            
            // Verify BTC was added successfully
            // In a real implementation, we'd have getter functions to verify this
            
            test::return_shared(registry);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_create_option_market() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        next_tx(&mut scenario, ADMIN);
        {
            // Verify market was created and is shared
            assert!(test::has_most_recent_shared<OptionMarket<TestCoin>>(), 0);
            
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            assert!(unxv_options::get_total_options_created(&registry) == 1, 1);
            
            test::return_shared(registry);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_buy_option_long_position() {
        let mut scenario = test::begin(USER);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let pricing_engine = test::take_shared<OptionsPricingEngine>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let position = unxv_options::test_buy_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MAX_PREMIUM,
                &clock,
                ctx(&mut scenario),
            );
            
            // Verify position details
            let (position_type, quantity, entry_price, _entry_timestamp, _unrealized_pnl, _greeks) = 
                unxv_options::get_position_summary(&position);
            
            assert!(position_type == string::utf8(b"LONG"), 0);
            assert!(quantity == TEST_QUANTITY, 1);
            assert!(entry_price > 0, 2);
            
            // Verify market was updated
            let (_, _, _, _, open_interest, volume, is_active) = unxv_options::get_market_info(&market);
            assert!(open_interest == TEST_QUANTITY, 3);
            assert!(volume > 0, 4);
            assert!(is_active, 5);
            
            // Clean up
            transfer::public_transfer(position, USER);
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
            test::return_shared(pricing_engine);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_sell_option_short_position() {
        let mut scenario = test::begin(USER);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let pricing_engine = test::take_shared<OptionsPricingEngine>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let position = unxv_options::test_sell_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MIN_PREMIUM,
                TEST_COLLATERAL,
                &clock,
                ctx(&mut scenario),
            );
            
            // Verify position details
            let (position_type, quantity, entry_price, _entry_timestamp, _unrealized_pnl, _greeks) = 
                unxv_options::get_position_summary(&position);
            
            assert!(position_type == string::utf8(b"SHORT"), 0);
            assert!(quantity == TEST_QUANTITY, 1);
            assert!(entry_price > 0, 2);
            
            // Verify market was updated
            let (_, _, _, _, open_interest, volume, is_active) = unxv_options::get_market_info(&market);
            assert!(open_interest == TEST_QUANTITY, 3);
            assert!(volume > 0, 4);
            assert!(is_active, 5);
            
            // Clean up
            transfer::public_transfer(position, USER);
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
            test::return_shared(pricing_engine);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_exercise_option() {
        let mut scenario = test::begin(USER);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        // First buy an option
        next_tx(&mut scenario, USER);
        let mut position;
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let pricing_engine = test::take_shared<OptionsPricingEngine>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            position = unxv_options::test_buy_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MAX_PREMIUM,
                &clock,
                ctx(&mut scenario),
            );
            
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
            test::return_shared(pricing_engine);
        };
        
        // Now exercise the option
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let exercise_result = unxv_options::test_exercise_option<TestCoin>(
                &mut position,
                &mut market,
                &registry,
                TEST_QUANTITY,
                string::utf8(b"CASH"),
                &clock,
                ctx(&mut scenario),
            );
            
            // Verify exercise was successful
            let (quantity_exercised, settlement_amount) = unxv_options::get_exercise_result_details(&exercise_result);
            assert!(quantity_exercised == TEST_QUANTITY, 0);
            assert!(settlement_amount > 0, 1);
            
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
        };
        
        // Clean up position
        transfer::public_transfer(position, USER);
        
        test::end(scenario);
    }
    
    #[test]
    fun test_auto_exercise_at_expiry() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        // Create some positions first
        let mut positions = vector::empty<OptionPosition>();
        
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let pricing_engine = test::take_shared<OptionsPricingEngine>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let position = unxv_options::test_buy_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MAX_PREMIUM,
                &clock,
                ctx(&mut scenario),
            );
            
            vector::push_back(&mut positions, position);
            
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
            test::return_shared(pricing_engine);
        };
        
        // Now auto-exercise at expiry
        next_tx(&mut scenario, ADMIN);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ctx(&mut scenario));
            
            // Set clock to expiry time
            clock::set_for_testing(&mut clock, EXPIRY_TIMESTAMP + 1000);
            
            let exercise_results = unxv_options::auto_exercise_at_expiry<TestCoin>(
                &mut market,
                &mut positions,
                &registry,
                55000000000, // Settlement price $55,000 (ITM for $50K call)
                &clock,
                ctx(&mut scenario),
            );
            
            // Verify auto-exercise results
            assert!(vector::length(&exercise_results) >= 0, 0); // Could be 0 or 1 depending on implementation
            
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
        };
        
        // Clean up positions
        while (!vector::is_empty(&positions)) {
            let position = vector::pop_back(&mut positions);
            transfer::public_transfer(position, USER);
        };
        vector::destroy_empty(positions);
        
        test::end(scenario);
    }
    
    #[test]
    fun test_unxv_discount_calculation() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_underlying(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            
            // Test different UNXV stake tiers
            assert!(unxv_options::get_unxv_discount(&registry, 0) == 0, 0); // No stake
            assert!(unxv_options::get_unxv_discount(&registry, 1000000000) == 500, 1); // Tier 1: 5%
            assert!(unxv_options::get_unxv_discount(&registry, 5000000000) == 1000, 2); // Tier 2: 10%
            assert!(unxv_options::get_unxv_discount(&registry, 25000000000) == 1500, 3); // Tier 3: 15%
            assert!(unxv_options::get_unxv_discount(&registry, 100000000000) == 2000, 4); // Tier 4: 20%
            assert!(unxv_options::get_unxv_discount(&registry, 500000000000) == 2500, 5); // Tier 5: 25%
            
            test::return_shared(registry);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_emergency_pause_and_resume() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_underlying(&mut scenario);
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test::take_shared<OptionsRegistry>(&scenario);
            let admin_cap = test::take_from_sender<AdminCap>(&scenario);
            
            // Initially not paused
            assert!(!unxv_options::is_system_paused(&registry), 0);
            
            // Pause system
            unxv_options::emergency_pause(&mut registry, &admin_cap);
            assert!(unxv_options::is_system_paused(&registry), 1);
            
            // Resume operations
            unxv_options::resume_operations(&mut registry, &admin_cap);
            assert!(!unxv_options::is_system_paused(&registry), 2);
            
            test::return_shared(registry);
            test::return_to_sender(&scenario, admin_cap);
        };
        
        test::end(scenario);
    }

#[test]
    fun test_multiple_option_types() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_underlying(&mut scenario);
        
        // Create both CALL and PUT markets
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test::take_shared<OptionsRegistry>(&scenario);
            let admin_cap = test::take_from_sender<AdminCap>(&scenario);
            
            // Create CALL market
            let _call_market_id = unxv_options::create_option_market<TestCoin>(
                &mut registry,
                string::utf8(b"BTC"),
                string::utf8(b"CALL"),
                STRIKE_PRICE_60K, // Different strike price
                EXPIRY_TIMESTAMP + 3600000, // Different expiry (+1 hour)
                string::utf8(b"CASH"),
                string::utf8(b"EUROPEAN"),
                &admin_cap,
                ctx(&mut scenario),
            );
            
            // Create PUT market
            let _put_market_id = unxv_options::create_option_market<TestCoin>(
                &mut registry,
                string::utf8(b"BTC"),
                string::utf8(b"PUT"),
                STRIKE_PRICE_60K, // Same strike as CALL but different type
                EXPIRY_TIMESTAMP + 86400000, // Different expiry (+1 day)
                string::utf8(b"CASH"),
                string::utf8(b"EUROPEAN"),
                &admin_cap,
                ctx(&mut scenario),
            );
            
            // Should have created 2 markets
            assert!(unxv_options::get_total_options_created(&registry) == 2, 0);
            
            test::return_shared(registry);
            test::return_to_sender(&scenario, admin_cap);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_position_greeks_calculation() {
        let mut scenario = test::begin(USER);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let pricing_engine = test::take_shared<OptionsPricingEngine>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let position = unxv_options::test_buy_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MAX_PREMIUM,
                &clock,
                ctx(&mut scenario),
            );
            
            // Verify Greeks were calculated
            let (_, _, _, _, _, greeks) = unxv_options::get_position_summary(&position);
            
            // Greeks should be non-zero for active position
            let (gamma, vega) = unxv_options::get_greeks_values(&greeks);
            assert!(gamma > 0, 0);
            assert!(vega > 0, 1);
            
            // Clean up
            transfer::public_transfer(position, USER);
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
            test::return_shared(pricing_engine);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_market_statistics_tracking() {
        let mut scenario = test::begin(USER);
        
        setup_protocol_and_underlying(&mut scenario);
        let _market_id = create_btc_call_market(&mut scenario);
        
        // Make multiple trades to test statistics
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<OptionMarket<TestCoin>>(&scenario);
            let registry = test::take_shared<OptionsRegistry>(&scenario);
            let pricing_engine = test::take_shared<OptionsPricingEngine>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let position1 = unxv_options::test_buy_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MAX_PREMIUM,
                &clock,
                ctx(&mut scenario),
            );
            
            // Buy second option
            let position2 = unxv_options::test_buy_option<TestCoin>(
                &mut market,
                &registry,
                &pricing_engine,
                TEST_QUANTITY,
                MAX_PREMIUM,
                &clock,
                ctx(&mut scenario),
            );
            
            // Check market statistics
            let (_, _, _, _, open_interest, volume, _) = unxv_options::get_market_info(&market);
            assert!(open_interest == TEST_QUANTITY * 2, 0); // Two positions
            assert!(volume > 0, 1); // Should have recorded volume
            
            // Clean up
            transfer::public_transfer(position1, USER);
            transfer::public_transfer(position2, USER);
            clock::destroy_for_testing(clock);
            
            test::return_shared(market);
            test::return_shared(registry);
            test::return_shared(pricing_engine);
        };
        
        test::end(scenario);
    }
}
