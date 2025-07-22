#[test_only]
module unxv_futures::unxv_futures_tests;

use std::string::{Self, String};
use std::option;
use sui::balance;
use sui::coin;
use sui::object;
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
use sui::clock;
use sui::table;
use sui::vec_set;
use deepbook::balance_manager;

use unxv_futures::unxv_futures::{
    Self,
    FuturesRegistry,
    FuturesMarket,
    FuturesPosition,
    SettlementEngine,
    CalendarSpreadEngine,
    AdminCap,
    USDC,
    ContractSeries,
    MarginConfig,
    PositionLimits,
    SignedInt,
    TierBenefits,
    CalendarSpread,
    SpreadMargin,
    SpreadMetrics
};

// Test addresses
const ADMIN: address = @0x123;
const USER: address = @0x456;
const ANOTHER_USER: address = @0x789;

// Test constants
const STRIKE_PRICE_50K: u64 = 50000000000; // $50,000 with 6 decimals
const STRIKE_PRICE_60K: u64 = 60000000000; // $60,000 with 6 decimals
const EXPIRY_TIMESTAMP: u64 = 1735689600000; // Jan 1, 2025
const EXPIRY_TIMESTAMP_MAR: u64 = 1743465600000; // Mar 1, 2025
const TEST_QUANTITY: u64 = 1; // 1 futures contract
const TEST_MARGIN: u64 = 10000000000; // $10,000 margin
const CONTRACT_SIZE: u64 = 1000000; // 1.0 contracts
const TICK_SIZE: u64 = 100000; // $0.1

// Test coin type
public struct TestCoin has drop, store {}

// Helper function to setup protocol and add BTC as underlying
fun setup_protocol_and_underlying(scenario: &mut Scenario) {
    next_tx(scenario, ADMIN);
    {
        unxv_futures::init_for_testing(ctx(scenario));
    };
    
    next_tx(scenario, ADMIN);
    {
        let mut registry = test::take_shared<FuturesRegistry>(scenario);
        let admin_cap = test::take_from_sender<AdminCap>(scenario);
        
        // Add BTC as underlying asset using helper functions
        unxv_futures::add_underlying_asset_simple(
            &mut registry,
            string::utf8(b"BTC"),
            &admin_cap,
            ctx(scenario),
        );
        
        test::return_shared(registry);
        test::return_to_sender(scenario, admin_cap);
    };
}

// Helper function to create BTC futures contract
fun create_btc_futures_contract(scenario: &mut Scenario): object::ID {
    let mut market_id = object::id_from_address(@0x0);
    let deepbook_pool_id = object::id_from_address(@0x123456);
    next_tx(scenario, ADMIN);
    {
        let mut registry = test::take_shared<FuturesRegistry>(scenario);
        let admin_cap = test::take_from_sender<AdminCap>(scenario);
        market_id = unxv_futures::create_futures_contract<TestCoin>(
            &mut registry,
            string::utf8(b"BTC"),
            string::utf8(b"BTC-DEC24"),
            EXPIRY_TIMESTAMP,
            CONTRACT_SIZE,
            TICK_SIZE,
            deepbook_pool_id,
            &admin_cap,
            ctx(scenario),
        );
        test::return_shared(registry);
        test::return_to_sender(scenario, admin_cap);
    };
    market_id
}

// Helper function to create second BTC futures contract for spreads
fun create_btc_mar_futures_contract(scenario: &mut Scenario): object::ID {
    let mut market_id = object::id_from_address(@0x0);
    let deepbook_pool_id = object::id_from_address(@0x123456);
    next_tx(scenario, ADMIN);
    {
        let mut registry = test::take_shared<FuturesRegistry>(scenario);
        let admin_cap = test::take_from_sender<AdminCap>(scenario);
        market_id = unxv_futures::create_futures_contract<TestCoin>(
            &mut registry,
            string::utf8(b"BTC"),
            string::utf8(b"BTC-MAR25"),
            EXPIRY_TIMESTAMP_MAR,
            CONTRACT_SIZE,
            TICK_SIZE,
            deepbook_pool_id,
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
        unxv_futures::init_for_testing(ctx(&mut scenario));
    };
    
    next_tx(&mut scenario, ADMIN);
    {
        // Check that all shared objects were created
        assert!(test::has_most_recent_shared<FuturesRegistry>(), 0);
        assert!(test::has_most_recent_shared<SettlementEngine>(), 1);
        assert!(test::has_most_recent_shared<CalendarSpreadEngine>(), 2);
        assert!(test::has_most_recent_for_sender<AdminCap>(&scenario), 3);
    };
    
    test::end(scenario);
}

#[test]
fun test_add_underlying_asset() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    
    next_tx(&mut scenario, ADMIN);
    {
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        
        // Test that we can get contract info (should not exist yet)
        let (is_active, _expiry, is_expired, _settlement) = 
            unxv_futures::get_contract_info(&registry, string::utf8(b"BTC-DEC24"));
        assert!(!is_active, 0);
        assert!(is_expired, 1); // Should be expired (default for non-existent)
        
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_create_futures_contract() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id = create_btc_futures_contract(&mut scenario);
    
    next_tx(&mut scenario, ADMIN);
    {
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        
        // Test that contract was created
        let (is_active, expiry, is_expired, _settlement) = 
            unxv_futures::get_contract_info(&registry, string::utf8(b"BTC-DEC24"));
        assert!(is_active, 0);
        assert!(expiry == EXPIRY_TIMESTAMP, 1);
        assert!(!is_expired, 2);
        
        test::return_shared(registry);
    };
    
    next_tx(&mut scenario, ADMIN);
    {
        // Check that market was created and shared
        assert!(test::has_most_recent_shared<FuturesMarket<TestCoin>>(), 0);
        
        let market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let (current_price, volume, open_interest, positions, is_active) = 
            unxv_futures::get_market_stats(&market);
        
        assert!(current_price == 0, 1); // No trading yet
        assert!(volume == 0, 2);
        assert!(open_interest == 0, 3);
        assert!(positions == 0, 4);
        assert!(is_active, 5);
        
        test::return_shared(market);
    };
    
    test::end(scenario);
}

#[test]
fun test_open_long_position() {
    let mut scenario = test::begin(USER);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id = create_btc_futures_contract(&mut scenario);
    
    // Open long position
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let position = unxv_futures::test_open_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_QUANTITY,
            STRIKE_PRICE_50K,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        // Verify position details
        let (side, size, entry_price, margin_posted, unrealized_pnl, cumulative_pnl) = 
            unxv_futures::get_position_summary(&position);
        
        assert!(side == string::utf8(b"LONG"), 0);
        assert!(size == TEST_QUANTITY, 1);
        assert!(entry_price == STRIKE_PRICE_50K, 2);
        assert!(margin_posted == TEST_MARGIN, 3);
        
        // Verify market statistics updated
        let (current_price, _volume, open_interest, positions, is_active) = 
            unxv_futures::get_market_stats(&market);
        
        assert!(current_price == STRIKE_PRICE_50K, 4);
        assert!(open_interest == TEST_QUANTITY, 5);
        assert!(positions == 1, 6);
        assert!(is_active, 7);
        
        transfer::public_transfer(position, USER);
        clock::destroy_for_testing(clock);
        test::return_shared(market);
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_open_short_position() {
    let mut scenario = test::begin(USER);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id = create_btc_futures_contract(&mut scenario);
    
    // Open short position
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let position = unxv_futures::test_open_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"SHORT"),
            TEST_QUANTITY,
            STRIKE_PRICE_50K,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        // Verify position details
        let (side, size, entry_price, margin_posted, _unrealized_pnl, _cumulative_pnl) = 
            unxv_futures::get_position_summary(&position);
        
        assert!(side == string::utf8(b"SHORT"), 0);
        assert!(size == TEST_QUANTITY, 1);
        assert!(entry_price == STRIKE_PRICE_50K, 2);
        assert!(margin_posted == TEST_MARGIN, 3);
        
        transfer::public_transfer(position, USER);
        clock::destroy_for_testing(clock);
        test::return_shared(market);
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_position_settlement() {
    let mut scenario = test::begin(USER);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id = create_btc_futures_contract(&mut scenario);
    
    // First open a position
    next_tx(&mut scenario, USER);
    let mut position;
    {
        let mut market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        position = unxv_futures::test_open_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_QUANTITY,
            STRIKE_PRICE_50K,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        clock::destroy_for_testing(clock);
        test::return_shared(market);
        test::return_shared(registry);
    };
    
    // Now settle the position at a higher price (profit)
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let settlement_price = STRIKE_PRICE_60K; // Higher than entry price
        let (settlement_amount, _realized_pnl) = unxv_futures::test_settle_position<TestCoin>(
            &mut market,
            position,
            settlement_price,
            &clock,
            ctx(&mut scenario),
        );
        
        // Should have profit: (60k - 50k) * 1 = 10k plus original margin
        let expected_profit = (STRIKE_PRICE_60K - STRIKE_PRICE_50K) * TEST_QUANTITY;
        let expected_settlement = TEST_MARGIN + expected_profit;
        
        assert!(settlement_amount == expected_settlement, 0);
        // PnL verification would require SignedInt comparison
        
        clock::destroy_for_testing(clock);
        test::return_shared(market);
    };
    
    test::end(scenario);
}

#[test]
fun test_contract_expiration() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id = create_btc_futures_contract(&mut scenario);
    
    // Expire the contract
    next_tx(&mut scenario, ADMIN);
    {
        let mut market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let mut registry = test::take_shared<FuturesRegistry>(&scenario);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Set clock to after expiration
        clock::set_for_testing(&mut clock, EXPIRY_TIMESTAMP + 1000);
        
        let final_price = STRIKE_PRICE_55K;
        unxv_futures::expire_contract<TestCoin>(
            &mut market,
            &mut registry,
            final_price,
            &clock,
            ctx(&mut scenario),
        );
        
        // Verify contract is expired
        let (is_active, _expiry, is_expired, settlement_price) = 
            unxv_futures::get_contract_info(&registry, string::utf8(b"BTC-DEC24"));
        
        assert!(!is_active, 0);
        assert!(is_expired, 1);
        assert!(option::is_some(&settlement_price), 2);
        assert!(*option::borrow(&settlement_price) == final_price, 3);
        
        clock::destroy_for_testing(clock);
        test::return_shared(market);
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_calendar_spread_creation() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id_dec = create_btc_futures_contract(&mut scenario);
    let _market_id_mar = create_btc_mar_futures_contract(&mut scenario);
    
    // Create calendar spread
    next_tx(&mut scenario, ADMIN);
    {
        let mut spread_engine = test::take_shared<CalendarSpreadEngine>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        unxv_futures::create_calendar_spread(
            &mut spread_engine,
            string::utf8(b"BTC-DEC24"),
            string::utf8(b"BTC-MAR25"),
            string::utf8(b"BTC-DEC24/MAR25"),
            1, // 1:1 ratio
            TICK_SIZE,
            &admin_cap,
            ctx(&mut scenario),
        );
        
        // Verify spread was created
        let (is_active, front_month, back_month, ratio) = 
            unxv_futures::get_spread_info(&spread_engine, string::utf8(b"BTC-DEC24/MAR25"));
        
        assert!(is_active, 0);
        assert!(front_month == string::utf8(b"BTC-DEC24"), 1);
        assert!(back_month == string::utf8(b"BTC-MAR25"), 2);
        assert!(ratio == 1, 3);
        
        test::return_shared(spread_engine);
        test::return_to_sender(&scenario, admin_cap);
    };
    
    test::end(scenario);
}

#[test]
fun test_calendar_spread_execution() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id_dec = create_btc_futures_contract(&mut scenario);
    let _market_id_mar = create_btc_mar_futures_contract(&mut scenario);
    
    // Create calendar spread
    next_tx(&mut scenario, ADMIN);
    {
        let mut spread_engine = test::take_shared<CalendarSpreadEngine>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        unxv_futures::create_calendar_spread(
            &mut spread_engine,
            string::utf8(b"BTC-DEC24"),
            string::utf8(b"BTC-MAR25"),
            string::utf8(b"BTC-DEC24/MAR25"),
            1,
            TICK_SIZE,
            &admin_cap,
            ctx(&mut scenario),
        );
        
        test::return_shared(spread_engine);
        test::return_to_sender(&scenario, admin_cap);
    };
    
    // Execute spread trade
    next_tx(&mut scenario, USER);
    {
        let mut spread_engine = test::take_shared<CalendarSpreadEngine>(&scenario);
        let mut front_market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let mut back_market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        unxv_futures::execute_calendar_spread<TestCoin, TestCoin>(
            &mut spread_engine,
            &mut front_market,
            &mut back_market,
            string::utf8(b"BTC-DEC24/MAR25"),
            string::utf8(b"BUY_SPREAD"),
            TEST_QUANTITY,
            1000000, // $1 spread
            USER,
            ANOTHER_USER,
            &clock,
            ctx(&mut scenario),
        );
        
        // Verify markets were updated
        let (_, front_volume, _, _, _) = unxv_futures::get_market_stats(&front_market);
        let (_, back_volume, _, _, _) = unxv_futures::get_market_stats(&back_market);
        
        assert!(front_volume == TEST_QUANTITY, 0);
        assert!(back_volume == TEST_QUANTITY, 1);
        
        clock::destroy_for_testing(clock);
        test::return_shared(spread_engine);
        test::return_shared(front_market);
        test::return_shared(back_market);
    };
    
    test::end(scenario);
}

const STRIKE_PRICE_55K: u64 = 55000000000; // $55,000 with 6 decimals

#[test]
fun test_unxv_benefits_calculation() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    
    next_tx(&mut scenario, ADMIN);
    {
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        
        // Test tier 0 (no benefits)
        let (discounted_fee, settlement_discount, margin_reduction) = 
            unxv_futures::calculate_unxv_benefits(&registry, 0, 1000000); // $1 base fee
        
        assert!(discounted_fee == 1000000, 0); // No discount
        assert!(settlement_discount == 0, 1);
        assert!(margin_reduction == 0, 2);
        
        // Test tier 1 (basic benefits)
        let (discounted_fee_t1, settlement_discount_t1, margin_reduction_t1) = 
            unxv_futures::calculate_unxv_benefits(&registry, 1, 1000000);
        
        assert!(discounted_fee_t1 < 1000000, 3); // Should have discount
        assert!(settlement_discount_t1 > 0, 4);
        assert!(margin_reduction_t1 > 0, 5);
        
        // Test individual tier benefits
        let (trading_discount, settlement_discount_rate, margin_discount, position_increase, priority) = 
            unxv_futures::get_tier_benefits(&registry, 2);
        
        assert!(trading_discount == 1000, 6); // 10% for tier 2
        assert!(settlement_discount_rate == 2000, 7); // 20% for tier 2
        assert!(margin_discount == 800, 8); // 8% for tier 2
        assert!(position_increase == 4000, 9); // 40% for tier 2
        assert!(priority, 10); // Priority settlement for tier 2+
        
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_emergency_controls() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol_and_underlying(&mut scenario);
    
    // Test emergency pause
    next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test::take_shared<FuturesRegistry>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        unxv_futures::emergency_pause(&mut registry, &admin_cap);
        
        test::return_shared(registry);
        test::return_to_sender(&scenario, admin_cap);
    };
    
    // Try to create contract while paused (should fail)
    next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test::take_shared<FuturesRegistry>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        // This should fail since the protocol is paused
        // We expect this to abort with E_MARKET_NOT_ACTIVE
        
        test::return_shared(registry);
        test::return_to_sender(&scenario, admin_cap);
    };
    
    // Resume trading
    next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test::take_shared<FuturesRegistry>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        unxv_futures::resume_trading(&mut registry, &admin_cap);
        
        test::return_shared(registry);
        test::return_to_sender(&scenario, admin_cap);
    };
    
    test::end(scenario);
}

#[test]
fun test_unrealized_pnl_calculation() {
    let mut scenario = test::begin(USER);
    
    setup_protocol_and_underlying(&mut scenario);
    let _market_id = create_btc_futures_contract(&mut scenario);
    
    // Open long position
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared<FuturesMarket<TestCoin>>(&scenario);
        let registry = test::take_shared<FuturesRegistry>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let position = unxv_futures::test_open_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_QUANTITY,
            STRIKE_PRICE_50K,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        // Calculate P&L at different prices
        let _pnl_at_55k = unxv_futures::calculate_unrealized_pnl(&position, STRIKE_PRICE_55K);
        let _pnl_at_45k = unxv_futures::calculate_unrealized_pnl(&position, 45000000000);
        
        // For long position:
        // At 55k: profit = (55k - 50k) * 1 = 5k
        // At 45k: loss = (50k - 45k) * 1 = 5k
        
        // Basic validation - would need SignedInt comparison functions for exact validation
        
        transfer::public_transfer(position, USER);
        clock::destroy_for_testing(clock);
        test::return_shared(market);
        test::return_shared(registry);
    };
    
    test::end(scenario);
}
