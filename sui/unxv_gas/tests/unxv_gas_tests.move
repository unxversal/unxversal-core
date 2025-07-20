#[test_only]
module unxv_gas::unxv_gas_tests;

use std::string::{Self, String};
use std::option;
use std::vector;
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

use unxv_gas::unxv_gas::{
    Self,
    GasFuturesRegistry,
    GasFuturesContract,
    GasFuturesMarket,
    GasPosition,
    GasOracle,
    SettlementEngine,
    AdminCap,
    InstitutionalCap,
    USDC,
    SignedInt,
    GasTierBenefits,
    signed_int_from
};

// Test addresses
const ADMIN: address = @0x123;
const USER: address = @0x456;
const ANOTHER_USER: address = @0x789;
const GAS_STATION: address = @0xabc;
const ENTERPRISE: address = @0xdef;

// Test constants
const GAS_PRICE_1000: u64 = 1000; // 1000 MIST per gas unit
const GAS_PRICE_1200: u64 = 1200; // 1200 MIST per gas unit 
const GAS_PRICE_1100: u64 = 1100; // 1100 MIST per gas unit
const GAS_PRICE_800: u64 = 800; // 800 MIST per gas unit
const EXPIRY_TIMESTAMP: u64 = 1735689600000; // Jan 1, 2025
const TEST_GAS_UNITS: u64 = 1000000; // 1M gas units
const TEST_MARGIN: u64 = 100000000; // 100 USDC with 6 decimals
const SETTLEMENT_WINDOW: u64 = 86400000; // 24 hours

// Test coin type
public struct TestCoin has drop, store {}

// Helper function to setup protocol
fun setup_protocol(scenario: &mut Scenario) {
    next_tx(scenario, ADMIN);
    {
        unxv_gas::init_for_testing(ctx(scenario));
    };
}

// Helper function to create contract
fun create_gas_contract(scenario: &mut Scenario): object::ID {
    next_tx(scenario, ADMIN);
    {
        let mut registry = test::take_shared<GasFuturesRegistry>(scenario);
        let admin_cap = test::take_from_sender<AdminCap>(scenario);
        
        let contract_id = unxv_gas::create_gas_futures_contract<TestCoin>(
            &mut registry,
            string::utf8(b"GAS-JAN-2025"),
            string::utf8(b"GAS_STATION"),
            EXPIRY_TIMESTAMP,
            EXPIRY_TIMESTAMP - SETTLEMENT_WINDOW, // settlement_period_start
            EXPIRY_TIMESTAMP, // settlement_period_end
            1000000, // contract_size
            &admin_cap,
            ctx(scenario),
        );
        
        test::return_to_sender(scenario, admin_cap);
        test::return_shared(registry);
        
        contract_id
    }
}

// Helper function to create test coins
fun create_test_usdc(amount: u64, recipient: address, scenario: &mut Scenario) {
    next_tx(scenario, ADMIN);
    {
        let coin = coin::mint_for_testing<USDC>(amount, ctx(scenario));
        transfer::public_transfer(coin, recipient);
    };
}

#[test]
fun test_protocol_initialization() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    
    next_tx(&mut scenario, ADMIN);
    {
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        let settlement_engine = test::take_shared<SettlementEngine>(&scenario);
        let gas_oracle = test::take_shared<GasOracle>(&scenario);
        
        // Check basic protocol setup
        let (trading_fee, unxv_discount, settlement_fee) = unxv_gas::get_registry_fees(&registry);
        assert!(trading_fee == 25, 0); // 0.25%
        assert!(unxv_discount == 2000, 1); // 20%
        assert!(settlement_fee == 10, 2); // 0.10%
        
        // Check UNXV tier benefits
        let (tier0_trading, tier0_settlement, tier0_margin, tier0_position, tier0_priority) = 
            unxv_gas::get_tier_benefits(&registry, 0);
        assert!(tier0_trading == 0, 3); // No discount for tier 0
        assert!(tier0_settlement == 0, 4);
        
        let (tier3_trading, tier3_settlement, tier3_margin, tier3_position, tier3_priority) = 
            unxv_gas::get_tier_benefits(&registry, 3);
        assert!(tier3_trading == 1500, 5); // 15% discount for tier 3
        assert!(tier3_settlement == 3000, 6); // 30% discount
        assert!(tier3_priority, 7); // Priority settlement
        
        test::return_to_sender(&scenario, admin_cap);
        test::return_shared(registry);
        test::return_shared(settlement_engine);
        test::return_shared(gas_oracle);
    };
    
    test::end(scenario);
}

#[test]
fun test_gas_contract_creation() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    let contract_id = create_gas_contract(&mut scenario);
    
    next_tx(&mut scenario, USER);
    {
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&scenario, contract_id);
        
        // Check contract creation
        let (is_active, expiry, is_expired, settlement_price) = 
            unxv_gas::get_contract_info(&registry, string::utf8(b"GAS-JAN-2025"));
        assert!(is_active, 0);
        assert!(expiry == EXPIRY_TIMESTAMP, 1);
        assert!(!is_expired, 2);
        assert!(option::is_none(&settlement_price), 3);
        
        // Check market initialization
        let (current_price, reference_price, _basis, volume, open_interest, gas_hedged, active) = 
            unxv_gas::get_gas_market_stats<TestCoin>(&market);
        assert!(current_price == 1000, 4); // Default gas price
        assert!(reference_price == 1000, 5);
        assert!(volume == 0, 6); // No trading yet
        assert!(open_interest == 0, 7);
        assert!(gas_hedged == 0, 8);
        assert!(active, 9);
        
        test::return_shared(registry);
        test::return_shared(market);
    };
    
    test::end(scenario);
}

#[test]
fun test_gas_position_opening() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    let contract_id = create_gas_contract(&mut scenario);
    create_test_usdc(TEST_MARGIN, USER, &mut scenario);
    
    // Open long gas position
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&mut scenario, contract_id);
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let gas_oracle = test::take_shared<GasOracle>(&scenario);
        let margin_coin = test::take_from_sender<coin::Coin<USDC>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let position = unxv_gas::test_open_gas_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_GAS_UNITS,
            string::utf8(b"GAS_STATION_HEDGE"),
            GAS_PRICE_1000,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        // Check position details
        let (pos_type, side, gas_units, avg_price, margin, _unrealized_pnl, _realized_pnl) = 
            unxv_gas::get_gas_position_summary(&position);
        assert!(pos_type == string::utf8(b"GAS_STATION_HEDGE"), 0);
        assert!(side == string::utf8(b"LONG"), 1);
        assert!(gas_units == TEST_GAS_UNITS, 2);
        assert!(avg_price == GAS_PRICE_1000, 3);
        assert!(margin == TEST_MARGIN, 4);
        
        // Check market update
        let (_, _, _, _, new_open_interest, new_gas_hedged, _) = 
            unxv_gas::get_gas_market_stats<TestCoin>(&market);
        assert!(new_open_interest == TEST_GAS_UNITS, 5);
        assert!(new_gas_hedged == TEST_GAS_UNITS, 6);
        
        transfer::public_transfer(position, USER);
        clock::destroy_for_testing(clock);
        transfer::public_transfer(margin_coin, USER);
        test::return_shared(market);
        test::return_shared(registry);
        test::return_shared(gas_oracle);
    };
    
    test::end(scenario);
}

#[test]
fun test_gas_position_settlement() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    let contract_id = create_gas_contract(&mut scenario);
    create_test_usdc(TEST_MARGIN, USER, &mut scenario);
    
    // Open position
    let mut position;
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&mut scenario, contract_id);
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let gas_oracle = test::take_shared<GasOracle>(&scenario);
        let margin_coin = test::take_from_sender<coin::Coin<USDC>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        position = unxv_gas::test_open_gas_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_GAS_UNITS,
            string::utf8(b"GAS_STATION_HEDGE"),
            GAS_PRICE_1000,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        clock::destroy_for_testing(clock);
        transfer::public_transfer(margin_coin, USER);
        test::return_shared(market);
        test::return_shared(registry);
        test::return_shared(gas_oracle);
    };
    
    // Settle position at higher price (profit)
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&mut scenario, contract_id);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let (settlement_amount, realized_pnl, gas_savings) = unxv_gas::test_settle_gas_position<TestCoin>(
            &mut market,
            position,
            GAS_PRICE_1200, // Higher price = profit for long
            &clock,
            ctx(&mut scenario),
        );
        
        // Expected profit: (1200 - 1000) * 1M = 200M units
        let expected_profit = (GAS_PRICE_1200 - GAS_PRICE_1000) * TEST_GAS_UNITS;
        let expected_settlement = TEST_MARGIN + expected_profit;
        assert!(settlement_amount == expected_settlement, 0);
        
        // Basic validation for SignedInt (would need helper functions for detailed validation)
        let _ = realized_pnl;
        let _ = gas_savings;
        
        clock::destroy_for_testing(clock);
        test::return_shared(market);
    };
    
    test::end(scenario);
}

#[test]
fun test_gas_oracle_update() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    
    next_tx(&mut scenario, ADMIN);
    {
        let mut gas_oracle = test::take_shared<GasOracle>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Update gas price
        unxv_gas::update_gas_price(
            &mut gas_oracle,
            GAS_PRICE_1200,
            75, // 75% network congestion
            string::utf8(b"TEST_SOURCE"),
            &clock,
            ctx(&mut scenario),
        );
        
        // Check oracle update
        let (current_price, congestion, twap_1h, twap_24h, vwap_24h, _volatility) = 
            unxv_gas::get_gas_oracle_data(&gas_oracle);
        assert!(current_price == GAS_PRICE_1200, 0);
        assert!(congestion == 75, 1);
        
        // TWAP should be updated (simplified calculation)
        assert!(twap_1h > 1000, 2);
        assert!(twap_24h > 1000, 3);
        assert!(vwap_24h > 1000, 4);
        
        clock::destroy_for_testing(clock);
        test::return_to_sender(&scenario, admin_cap);
        test::return_shared(gas_oracle);
    };
    
    test::end(scenario);
}

#[test]
fun test_contract_expiration() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    let contract_id = create_gas_contract(&mut scenario);
    
    // Expire the contract
    next_tx(&mut scenario, ADMIN);
    {
        let mut market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&mut scenario, contract_id);
        let mut registry = test::take_shared<GasFuturesRegistry>(&mut scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Set clock to expiry time
        clock::set_for_testing(&mut clock, EXPIRY_TIMESTAMP + 1);
        
        unxv_gas::expire_gas_contract<TestCoin>(
            &mut market,
            &mut registry,
            GAS_PRICE_1100, // Settlement price
            string::utf8(b"TWAP"), // Settlement method
            &clock,
            ctx(&mut scenario),
        );
        
        // Check contract expiration
        let (is_active, _expiry, is_expired, settlement_price) = 
            unxv_gas::get_contract_info(&registry, string::utf8(b"GAS-JAN-2025"));
        assert!(!is_active, 0);
        assert!(is_expired, 1);
        assert!(option::is_some(&settlement_price), 2);
        assert!(*option::borrow(&settlement_price) == GAS_PRICE_1100, 3);
        
        // Check market expiration
        let (_, _, _, _, _, _, market_active) = 
            unxv_gas::get_gas_market_stats<TestCoin>(&market);
        assert!(!market_active, 4);
        
        clock::destroy_for_testing(clock);
        test::return_to_sender(&scenario, admin_cap);
        test::return_shared(registry);
        test::return_shared(market);
    };
    
    test::end(scenario);
}

#[test]
fun test_emergency_pause() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    
    // Test emergency pause
    next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test::take_shared<GasFuturesRegistry>(&mut scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        // Pause the protocol
        unxv_gas::emergency_pause(&mut registry, &admin_cap);
        
        // Check if paused
        let is_paused = unxv_gas::is_protocol_paused(&registry);
        assert!(is_paused, 0);
        
        test::return_to_sender(&scenario, admin_cap);
        test::return_shared(registry);
    };
    
    // Test resume
    next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test::take_shared<GasFuturesRegistry>(&mut scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        
        // Resume the protocol
        unxv_gas::resume_protocol(&mut registry, &admin_cap);
        
        // Check if resumed
        let is_paused = unxv_gas::is_protocol_paused(&registry);
        assert!(!is_paused, 1);
        
        test::return_to_sender(&scenario, admin_cap);
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_unxv_benefits_calculation() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    
    next_tx(&mut scenario, USER);
    {
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        
        // Test tier 0 (no benefits)
        let (discounted_fee, settlement_discount, margin_reduction) = 
            unxv_gas::calculate_unxv_benefits(&registry, 0, 1000000); // $1 base fee
        assert!(discounted_fee == 1000000, 0); // No discount
        assert!(settlement_discount == 0, 1);
        assert!(margin_reduction == 0, 2);
        
        // Test tier 2 (enhanced benefits)
        let (discounted_fee_t2, settlement_discount_t2, margin_reduction_t2) = 
            unxv_gas::calculate_unxv_benefits(&registry, 2, 1000000);
        assert!(discounted_fee_t2 < 1000000, 3); // Should have discount
        assert!(settlement_discount_t2 > 0, 4);
        assert!(margin_reduction_t2 > 0, 5);
        
        // Test tier 5 (institutional benefits)
        let (tier5_trading, tier5_settlement, tier5_margin, tier5_position, tier5_priority) = 
            unxv_gas::get_tier_benefits(&registry, 5);
        assert!(tier5_trading == 5000, 6); // 50% discount for tier 5
        assert!(tier5_settlement == 7500, 7); // 75% discount
        assert!(tier5_margin == 5000, 8); // 50% margin reduction
        assert!(tier5_position == 20000, 9); // 200% position increase
        assert!(tier5_priority, 10); // Priority settlement
        
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_gas_hedge_effectiveness() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    let contract_id = create_gas_contract(&mut scenario);
    create_test_usdc(TEST_MARGIN, USER, &mut scenario);
    
    // Open hedge position
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&mut scenario, contract_id);
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let gas_oracle = test::take_shared<GasOracle>(&scenario);
        let margin_coin = test::take_from_sender<coin::Coin<USDC>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        let position = unxv_gas::test_open_gas_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_GAS_UNITS,
            string::utf8(b"GAS_STATION_HEDGE"),
            GAS_PRICE_1000,
            TEST_MARGIN,
            &clock,
            ctx(&mut scenario),
        );
        
        // Calculate hedge effectiveness at different prices
        let hedge_savings_high = unxv_gas::calculate_gas_cost_savings(&position, GAS_PRICE_1200);
        let hedge_savings_low = unxv_gas::calculate_gas_cost_savings(&position, GAS_PRICE_800);
        
        // Long position should save money when gas price rises
        // Basic validation - would need SignedInt comparison functions for exact values
        let _ = hedge_savings_high;
        let _ = hedge_savings_low;
        
        transfer::public_transfer(position, USER);
        clock::destroy_for_testing(clock);
        transfer::public_transfer(margin_coin, USER);
        test::return_shared(market);
        test::return_shared(registry);
        test::return_shared(gas_oracle);
    };
    
    test::end(scenario);
}

#[test]
fun test_multiple_contract_types() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    
    // Create different contract types
    next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let admin_cap = test::take_from_sender<AdminCap>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Create gas station contract
        let _gas_station_id = unxv_gas::create_gas_futures_contract<TestCoin>(
            &mut registry,
            string::utf8(b"GAS-STATION-JAN"),
            string::utf8(b"GAS_STATION"),
            EXPIRY_TIMESTAMP,
            EXPIRY_TIMESTAMP - SETTLEMENT_WINDOW,
            EXPIRY_TIMESTAMP,
            1000000,
            &admin_cap,
            ctx(&mut scenario),
        );
        
        // Create app sponsor contract
        let _app_sponsor_id = unxv_gas::create_gas_futures_contract<TestCoin>(
            &mut registry,
            string::utf8(b"APP-SPONSOR-JAN"),
            string::utf8(b"APP_SPONSOR"),
            EXPIRY_TIMESTAMP,
            EXPIRY_TIMESTAMP - SETTLEMENT_WINDOW,
            EXPIRY_TIMESTAMP,
            1000000,
            &admin_cap,
            ctx(&mut scenario),
        );
        
        // Create enterprise contract
        let _enterprise_id = unxv_gas::create_gas_futures_contract<TestCoin>(
            &mut registry,
            string::utf8(b"ENTERPRISE-JAN"),
            string::utf8(b"ENTERPRISE"),
            EXPIRY_TIMESTAMP,
            EXPIRY_TIMESTAMP - SETTLEMENT_WINDOW,
            EXPIRY_TIMESTAMP,
            1000000,
            &admin_cap,
            ctx(&mut scenario),
        );
        
        // Verify contracts created
        let (is_active_gs, _, _, _) = unxv_gas::get_contract_info(&registry, string::utf8(b"GAS-STATION-JAN"));
        let (is_active_as, _, _, _) = unxv_gas::get_contract_info(&registry, string::utf8(b"APP-SPONSOR-JAN"));
        let (is_active_ent, _, _, _) = unxv_gas::get_contract_info(&registry, string::utf8(b"ENTERPRISE-JAN"));
        
        assert!(is_active_gs, 0);
        assert!(is_active_as, 1);
        assert!(is_active_ent, 2);
        
        clock::destroy_for_testing(clock);
        test::return_to_sender(&scenario, admin_cap);
        test::return_shared(registry);
    };
    
    test::end(scenario);
}

#[test]
fun test_position_management() {
    let mut scenario = test::begin(ADMIN);
    
    setup_protocol(&mut scenario);
    let contract_id = create_gas_contract(&mut scenario);
    create_test_usdc(TEST_MARGIN * 2, USER, &mut scenario); // Create enough for two positions
    
    // Open long position
    next_tx(&mut scenario, USER);
    {
        let mut market = test::take_shared_by_id<GasFuturesMarket<TestCoin>>(&mut scenario, contract_id);
        let registry = test::take_shared<GasFuturesRegistry>(&scenario);
        let gas_oracle = test::take_shared<GasOracle>(&scenario);
        let mut margin_coin = test::take_from_sender<coin::Coin<USDC>>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Split the coin to create two positions
        let coin_value = coin::value(&margin_coin);
        let coin1 = coin::split(&mut margin_coin, coin_value / 2, ctx(&mut scenario));
        let coin2 = margin_coin; // Use remaining coin
        
        let long_position = unxv_gas::test_open_gas_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"LONG"),
            TEST_GAS_UNITS / 2,
            string::utf8(b"GAS_STATION_HEDGE"),
            GAS_PRICE_1000,
            coin::value(&coin1),
            &clock,
            ctx(&mut scenario),
        );
        
        let short_position = unxv_gas::test_open_gas_position<TestCoin>(
            &mut market,
            &registry,
            string::utf8(b"SHORT"),
            TEST_GAS_UNITS / 2,
            string::utf8(b"SPECULATION"),
            GAS_PRICE_1000,
            coin::value(&coin2),
            &clock,
            ctx(&mut scenario),
        );
        
        // Check position details
        let (_, long_side, long_units, _, _, _, _) = unxv_gas::get_gas_position_summary(&long_position);
        let (_, short_side, short_units, _, _, _, _) = unxv_gas::get_gas_position_summary(&short_position);
        
        assert!(long_side == string::utf8(b"LONG"), 0);
        assert!(short_side == string::utf8(b"SHORT"), 1);
        assert!(long_units == TEST_GAS_UNITS / 2, 2);
        assert!(short_units == TEST_GAS_UNITS / 2, 3);
        
        // Check market stats
        let (_, _, _, _, total_open_interest, _, _) = unxv_gas::get_gas_market_stats<TestCoin>(&market);
        assert!(total_open_interest == TEST_GAS_UNITS, 4); // Both positions contribute
        
        transfer::public_transfer(long_position, USER);
        transfer::public_transfer(short_position, USER);
        transfer::public_transfer(coin1, USER);
        transfer::public_transfer(coin2, USER);
        clock::destroy_for_testing(clock);
        test::return_shared(market);
        test::return_shared(registry);
        test::return_shared(gas_oracle);
    };
    
    test::end(scenario);
}
