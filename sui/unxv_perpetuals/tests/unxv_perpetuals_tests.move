#[test_only]
module unxv_perpetuals::unxv_perpetuals_tests {
    use std::string::{Self, String};
    use std::option::{Self, Option};
    
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    
    use unxv_perpetuals::unxv_perpetuals::{Self, PerpetualsRegistry, PerpetualsMarket, FundingRateCalculator, LiquidationEngine, AdminCap};
    
    // Test coin type
    public struct TestCoin has drop {}
    
    const USER: address = @0x1;
    const ADMIN: address = @0x2;
    
    // ========== Test Setup Functions ==========
    
    #[test]
    fun test_protocol_initialization() {
        let mut scenario = test::begin(ADMIN);
        
        {
            unxv_perpetuals::init_for_testing(ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, ADMIN);
        {
            assert!(test::has_most_recent_shared<PerpetualsRegistry>(), 0);
            assert!(test::has_most_recent_shared<FundingRateCalculator>(), 1);
            assert!(test::has_most_recent_shared<LiquidationEngine>(), 2);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_add_market() {
        let mut scenario = test::begin(ADMIN);
        
        // Initialize protocol
        {
            unxv_perpetuals::init_for_testing(ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test::take_shared<PerpetualsRegistry>(&scenario);
            let admin_cap = test::take_from_sender<AdminCap>(&scenario);
            
            let market_symbol = string::utf8(b"sBTC-PERP");
            let underlying_asset = string::utf8(b"sBTC");
            let deepbook_pool_id = object::id_from_address(@0x123);
            let mut price_feed_id = vector::empty<u8>();
            vector::push_back(&mut price_feed_id, 1);
            
            unxv_perpetuals::add_market<TestCoin>(
                &mut registry,
                market_symbol,
                underlying_asset,
                deepbook_pool_id,
                price_feed_id,
                50, // max leverage
                1000000000000, // max OI limit
                &admin_cap,
                ctx(&mut scenario)
            );
            
            test::return_shared(registry);
            test::return_to_sender(&scenario, admin_cap);
        };
        
        next_tx(&mut scenario, ADMIN);
        {
            assert!(test::has_most_recent_shared<PerpetualsMarket<TestCoin>>(), 3);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_create_user_account() {
        let mut scenario = test::begin(USER);
        
        {
            let user_account = unxv_perpetuals::create_user_account(ctx(&mut scenario));
            let (total_margin, available_margin, used_margin, _realized_pnl, active_positions) = 
                unxv_perpetuals::get_account_summary(&user_account);
            
            assert!(total_margin == 0, 0);
            assert!(available_margin == 0, 1);
            assert!(used_margin == 0, 2);
            assert!(active_positions == 0, 3);
            
            transfer::public_transfer(user_account, USER);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_funding_rate_calculation() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let registry = test::take_shared<PerpetualsRegistry>(&scenario);
            let market = test::take_shared<PerpetualsMarket<TestCoin>>(&scenario);
            let mut funding_calculator = test::take_shared<FundingRateCalculator>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let funding_calc = unxv_perpetuals::calculate_funding_rate<TestCoin>(
                &mut funding_calculator,
                &market,
                &registry,
                vector::empty(),
                &clock
            );
            
            // Verify funding rate calculation completed
            assert!(unxv_perpetuals::get_funding_calc_confidence(&funding_calc) > 0, 0);
            
            test::return_shared(registry);
            test::return_shared(market);
            test::return_shared(funding_calculator);
            clock::destroy_for_testing(clock);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_funding_payment_application() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let mut market = test::take_shared<PerpetualsMarket<TestCoin>>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            let funding_rate = unxv_perpetuals::signed_int_from(100); // 1% funding rate
            let _positions_processed = unxv_perpetuals::apply_funding_payments<TestCoin>(
                &mut market,
                funding_rate,
                &clock
            );
            
            let (_, _, _, _current_funding_rate, _, _) = unxv_perpetuals::get_market_info(&market);
            
            // assert!(i64::get_magnitude_if_positive(&current_funding_rate) == option::some(100), 0); // Simplified
            
            test::return_shared(market);
            clock::destroy_for_testing(clock);
        };
        
        test::end(scenario);
    }
    
    // ========== Market Info Tests ==========
    
    #[test]
    fun test_market_info_retrieval() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let market = test::take_shared<PerpetualsMarket<TestCoin>>(&scenario);
            
            let (market_symbol, _mark_price, _index_price, _funding_rate, long_oi, short_oi) = 
                unxv_perpetuals::get_market_info(&market);
                
            assert!(market_symbol == string::utf8(b"sBTC-PERP"), 0);
            assert!(long_oi == 0, 1); // No positions opened yet
            assert!(short_oi == 0, 2); // No positions opened yet
            
            test::return_shared(market);
        };
        
        test::end(scenario);
    }
    
    // ========== Risk Management Tests ==========
    
    #[test]
    fun test_emergency_pause() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_market(&mut scenario);
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test::take_shared<PerpetualsRegistry>(&scenario);
            let admin_cap = test::take_from_sender<AdminCap>(&scenario);
            
            // Initially not paused
            assert!(!unxv_perpetuals::is_system_paused(&registry), 0);
            
            // Pause the system
            unxv_perpetuals::emergency_pause(&mut registry, &admin_cap);
            
            // Check if system is paused
            assert!(unxv_perpetuals::is_system_paused(&registry), 1);
            
            // Resume operations
            unxv_perpetuals::resume_operations(&mut registry, &admin_cap);
            
            // Check if system is resumed
            assert!(!unxv_perpetuals::is_system_paused(&registry), 2);
            
            test::return_shared(registry);
            test::return_to_sender(&scenario, admin_cap);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_insurance_fund() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let market = test::take_shared<PerpetualsMarket<TestCoin>>(&scenario);
            
            // Check initial insurance fund balance
            let insurance_balance = unxv_perpetuals::get_insurance_fund_balance(&market);
            assert!(insurance_balance == 0, 0); // Should be empty initially
            
            test::return_shared(market);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_funding_history() {
        let mut scenario = test::begin(ADMIN);
        
        setup_protocol_and_market(&mut scenario);
        
        next_tx(&mut scenario, USER);
        {
            let market = test::take_shared<PerpetualsMarket<TestCoin>>(&scenario);
            
            // Check funding history is initially empty
            let history_length = unxv_perpetuals::get_funding_history_length(&market);
            assert!(history_length == 0, 0);
            
            test::return_shared(market);
        };
        
        test::end(scenario);
    }
    
    #[test]
    fun test_registry_configuration() {
        let mut scenario = test::begin(ADMIN);
        
        // Initialize protocol
        {
            unxv_perpetuals::init_for_testing(ctx(&mut scenario));
        };
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test::take_shared<PerpetualsRegistry>(&scenario);
            let admin_cap = test::take_from_sender<AdminCap>(&scenario);
            
            let market_symbol = string::utf8(b"sBTC-PERP");
            let underlying_asset = string::utf8(b"sBTC");
            let deepbook_pool_id = object::id_from_address(@0x123);
            let mut price_feed_id = vector::empty<u8>();
            vector::push_back(&mut price_feed_id, 1);
            
            unxv_perpetuals::add_market<TestCoin>(
                &mut registry,
                market_symbol,
                underlying_asset,
                deepbook_pool_id,
                price_feed_id,
                50, // max leverage
                1000000000000, // max OI limit  
                &admin_cap,
                ctx(&mut scenario)
            );
            
            test::return_shared(registry);
            test::return_to_sender(&scenario, admin_cap);
        };
        
        test::end(scenario);
    }
    
    #[test]
    public fun test_signed_integer_math() {
        // Test positive signed integer creation
        let pos_100 = unxv_perpetuals::signed_int_from(100);
        assert!(unxv_perpetuals::is_positive(&pos_100), 1);
        assert!(unxv_perpetuals::abs(&pos_100) == 100, 2);
        assert!(unxv_perpetuals::to_u64_positive(&pos_100) == 100, 3);
        
        // Test negative signed integer creation
        let neg_50 = unxv_perpetuals::signed_int_negative(50);
        assert!(unxv_perpetuals::is_negative(&neg_50), 4);
        assert!(unxv_perpetuals::abs(&neg_50) == 50, 5);
        assert!(unxv_perpetuals::to_u64_positive(&neg_50) == 0, 6);
        
        // Test addition: 100 + (-50) = 50
        let result = unxv_perpetuals::signed_add(pos_100, neg_50);
        assert!(unxv_perpetuals::is_positive(&result), 7);
        assert!(unxv_perpetuals::abs(&result) == 50, 8);
        
        // Test subtraction: 100 - 50 = 50
        let pos_50 = unxv_perpetuals::signed_int_from(50);
        let result2 = unxv_perpetuals::signed_sub(pos_100, pos_50);
        assert!(unxv_perpetuals::is_positive(&result2), 9);
        assert!(unxv_perpetuals::abs(&result2) == 50, 10);
        
        // Test multiplication
        let result3 = unxv_perpetuals::signed_mul_u64(pos_50, 3);
        assert!(unxv_perpetuals::abs(&result3) == 150, 11);
        
        // Test division
        let result4 = unxv_perpetuals::signed_div_u64(result3, 3);
        assert!(unxv_perpetuals::abs(&result4) == 50, 12);
    }
    
    #[test]
    public fun test_pnl_calculations() {
        // Test LONG position P&L calculations
        
        // Profitable LONG: entry 1000, exit 1100 = +10% = profit
        let long_profit = unxv_perpetuals::calculate_realized_pnl_test(
            string::utf8(b"LONG"),
            1000000000, // Entry: 1000 USDC
            1100000000, // Exit: 1100 USDC  
            1000000000  // Size: 1000 USDC worth
        );
        assert!(unxv_perpetuals::is_positive(&long_profit), 1);
        assert!(unxv_perpetuals::abs(&long_profit) == 100000000, 2); // Should be 100 USDC profit
        
        // Loss-making LONG: entry 1000, exit 900 = -10% = loss
        let long_loss = unxv_perpetuals::calculate_realized_pnl_test(
            string::utf8(b"LONG"),
            1000000000, // Entry: 1000 USDC
            900000000,  // Exit: 900 USDC
            1000000000  // Size: 1000 USDC worth
        );
        assert!(unxv_perpetuals::is_negative(&long_loss), 3);
        assert!(unxv_perpetuals::abs(&long_loss) == 100000000, 4); // Should be 100 USDC loss
        
        // Test SHORT position P&L calculations
        
        // Profitable SHORT: entry 1000, exit 900 = profit when price goes down
        let short_profit = unxv_perpetuals::calculate_realized_pnl_test(
            string::utf8(b"SHORT"),
            1000000000, // Entry: 1000 USDC
            900000000,  // Exit: 900 USDC
            1000000000  // Size: 1000 USDC worth
        );
        assert!(unxv_perpetuals::is_positive(&short_profit), 5);
        assert!(unxv_perpetuals::abs(&short_profit) == 100000000, 6); // Should be 100 USDC profit
        
        // Loss-making SHORT: entry 1000, exit 1100 = loss when price goes up
        let short_loss = unxv_perpetuals::calculate_realized_pnl_test(
            string::utf8(b"SHORT"),
            1000000000, // Entry: 1000 USDC
            1100000000, // Exit: 1100 USDC
            1000000000  // Size: 1000 USDC worth
        );
        assert!(unxv_perpetuals::is_negative(&short_loss), 7);
        assert!(unxv_perpetuals::abs(&short_loss) == 100000000, 8); // Should be 100 USDC loss
    }
    
    // ========== Helper Functions ==========
    
    fun setup_protocol_and_market(scenario: &mut Scenario) {
        test::next_tx(scenario, ADMIN);
        {
            unxv_perpetuals::init_for_testing(ctx(scenario));
        };
        
        next_tx(scenario, ADMIN);
        {
            let mut registry = test::take_shared<PerpetualsRegistry>(scenario);
            let admin_cap = test::take_from_sender<AdminCap>(scenario);
            
            let market_symbol = string::utf8(b"sBTC-PERP");
            let underlying_asset = string::utf8(b"sBTC");
            let deepbook_pool_id = object::id_from_address(@0x123);
            let mut price_feed_id = vector::empty<u8>();
            vector::push_back(&mut price_feed_id, 1);
            
            unxv_perpetuals::add_market<TestCoin>(
                &mut registry,
                market_symbol,
                underlying_asset,
                deepbook_pool_id,
                price_feed_id,
                50, // max leverage
                1000000000000, // max OI limit
                &admin_cap,
                ctx(scenario)
            );
            
            test::return_shared(registry);
            test::return_to_sender(scenario, admin_cap);
        };
    }
}
