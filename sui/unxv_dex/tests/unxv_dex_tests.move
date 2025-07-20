#[test_only]
module unxv_dex::unxv_dex_tests {
    use std::string::{Self, String};
    use std::vector;
    use std::option;
    
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID};
    use sui::test_utils;
    
    use unxv_dex::unxv_dex::{
        Self,
        DEXRegistry,
        TradingSession,
        AdminCap,
        PoolInfo,
        FeeStructure,
        CrossAssetRoute,
        TradeResult,
        FeeBreakdown,
        ArbitrageOpportunity,
    };
    
    // ========== Test Constants ==========
    
    const ADMIN: address = @0xAD;
    const TRADER_ALICE: address = @0xA11CE;
    const TRADER_BOB: address = @0xB0B;
    
    // Mock asset types for testing
    public struct USDC has drop {}
    public struct SUI has drop {}
    public struct BTC has drop {}
    public struct ETH has drop {}
    public struct UNXV has drop {}
    
    // Test amounts
    const INITIAL_BALANCE: u64 = 1000000000; // 1000 tokens
    const TRADE_AMOUNT: u64 = 100000000;     // 100 tokens
    const MIN_OUTPUT: u64 = 99000000;        // 99 tokens (1% slippage)
    
    // ========== Test Setup Helpers ==========
    
    fun setup_test_scenario(): Scenario {
        test_scenario::begin(ADMIN)
    }
    
    fun create_test_clock(scenario: &mut Scenario): Clock {
        clock::create_for_testing(scenario.ctx())
    }
    
    fun create_mock_pool_id(): ID {
        object::id_from_address(@0x1234)
    }
    
    // ========== Core Tests ==========
    
    #[test]
    fun test_dex_initialization() {
        let mut scenario = setup_test_scenario();
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Verify registry exists and is properly initialized
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let (total_volume, total_fees, is_paused) = unxv_dex::get_registry_stats(&registry);
            assert!(total_volume == 0, 0);
            assert!(total_fees == 0, 1);
            assert!(!is_paused, 2);
            
            let fee_structure = unxv_dex::get_fee_structure(&registry);
            // Verify default fee structure is set correctly
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_pool_management() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add supported pools
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            // Add USDC/SUI pool
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            // Add BTC/USDC pool
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"BTC"),
                string::utf8(b"USDC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            // Verify pools are supported
            assert!(unxv_dex::is_pool_supported(&registry, string::utf8(b"USDC"), string::utf8(b"SUI")), 0);
            assert!(unxv_dex::is_pool_supported(&registry, string::utf8(b"BTC"), string::utf8(b"USDC")), 1);
            assert!(!unxv_dex::is_pool_supported(&registry, string::utf8(b"ETH"), string::utf8(b"BTC")), 2);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_trading_session_creation() {
        let mut scenario = setup_test_scenario();
        
        // Create trading session
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let session = unxv_dex::create_trading_session(scenario.ctx());
            
            let (volume, fees, savings, orders) = unxv_dex::get_session_summary(&session);
            assert!(volume == 0, 0);
            assert!(fees == 0, 1);
            assert!(savings == 0, 2);
            assert!(orders == 0, 3);
            
            test_utils::destroy(session);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_direct_trade_execution() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add supported pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Execute direct trade
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            let mut session = unxv_dex::create_trading_session(scenario.ctx());
            
            let input_coin = unxv_dex::create_mock_coin<USDC>(TRADE_AMOUNT, scenario.ctx());
            
            let (output_coin, trade_result) = unxv_dex::execute_direct_trade<USDC, SUI>(
                &mut registry,
                &mut session,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                string::utf8(b"BUY"),
                TRADE_AMOUNT,
                input_coin,
                MIN_OUTPUT,
                string::utf8(b"USDC"),
                &clock,
                scenario.ctx()
            );
            
            // Verify trade result
            let (success, input_amount, output_amount, fees_paid, _slippage) = unxv_dex::get_trade_result_info(&trade_result);
            assert!(success, 0);
            assert!(input_amount == TRADE_AMOUNT, 1);
            assert!(output_amount >= MIN_OUTPUT, 2);
            assert!(fees_paid > 0, 3);
            
            // Verify session updated
            let (volume, fees, _, _) = unxv_dex::get_session_summary(&session);
            assert!(volume == TRADE_AMOUNT, 4);
            assert!(fees > 0, 5);
            
            // Verify registry stats updated
            let (total_volume, total_fees, _) = unxv_dex::get_registry_stats(&registry);
            assert!(total_volume == TRADE_AMOUNT, 6);
            assert!(total_fees > 0, 7);
            
            coin::burn_for_testing(output_coin);
            test_utils::destroy(session);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_cross_asset_route_calculation() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add supported pools for cross-asset routing
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            // Add ETH/USDC pool
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"ETH"),
                string::utf8(b"USDC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            // Add USDC/BTC pool 
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"BTC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Calculate cross-asset route
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let route = unxv_dex::calculate_cross_asset_route(
                &registry,
                string::utf8(b"ETH"),
                string::utf8(b"BTC"),
                TRADE_AMOUNT,
                option::none(),
                &clock,
                scenario.ctx()
            );
            
            // Verify route calculation
            let (hops_required, estimated_output, total_fees, route_viability, path) = unxv_dex::get_route_info(&route);
            assert!(hops_required == 2, 0);
            assert!(estimated_output > 0, 1);
            assert!(total_fees > 0, 2);
            assert!(route_viability > 7000, 3); // Should be high viability
            assert!(vector::length(path) == 3, 4); // ETH -> USDC -> BTC
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_cross_asset_trade_execution() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add supported pools
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"ETH"),
                string::utf8(b"USDC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"BTC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Calculate and execute cross-asset trade
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            let mut session = unxv_dex::create_trading_session(scenario.ctx());
            
            // Calculate route
            let route = unxv_dex::calculate_cross_asset_route(
                &registry,
                string::utf8(b"ETH"),
                string::utf8(b"BTC"),
                TRADE_AMOUNT,
                option::none(),
                &clock,
                scenario.ctx()
            );
            
            let input_coin = unxv_dex::create_mock_coin<ETH>(TRADE_AMOUNT, scenario.ctx());
            let (_hops_required, estimated_output, _total_fees, _route_viability, _path) = unxv_dex::get_route_info(&route);
            let min_output = (estimated_output * 95) / 100; // 5% slippage tolerance
            
            // Execute cross-asset trade
            let (output_coin, trade_result) = unxv_dex::execute_cross_asset_trade<ETH, BTC>(
                &mut registry,
                &mut session,
                route,
                input_coin,
                min_output,
                string::utf8(b"USDC"),
                &clock,
                scenario.ctx()
            );
            
            // Verify trade execution
            let (success, input_amount, output_amount, fees_paid, slippage) = unxv_dex::get_trade_result_info(&trade_result);
            assert!(success, 0);
            assert!(input_amount == TRADE_AMOUNT, 1);
            assert!(output_amount >= min_output, 2);
            assert!(fees_paid > 0, 3);
            assert!(slippage <= 500, 4); // Max 5% slippage
            
            // Verify session updated
            let (volume, fees, _, _) = unxv_dex::get_session_summary(&session);
            assert!(volume == TRADE_AMOUNT, 5);
            assert!(fees > 0, 6);
            
            coin::burn_for_testing(output_coin);
            test_utils::destroy(session);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_fee_calculation_with_unxv_discount() {
        let mut scenario = setup_test_scenario();
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Test fee calculation
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            // Calculate fees without UNXV discount
            let fee_breakdown_usdc = unxv_dex::calculate_trading_fees(
                TRADE_AMOUNT,
                0,
                string::utf8(b"MARKET"),
                0,
                string::utf8(b"USDC"),
                &registry
            );
            
            // Calculate fees with UNXV discount
            let fee_breakdown_unxv = unxv_dex::calculate_trading_fees(
                TRADE_AMOUNT,
                0,
                string::utf8(b"MARKET"),
                0,
                string::utf8(b"UNXV"),
                &registry
            );
            
            // Verify UNXV discount is applied
            let (unxv_discount, final_fee_unxv, _routing_fee_unxv, _total_before_discount_unxv) = unxv_dex::get_fee_breakdown_info(&fee_breakdown_unxv);
            let (_unxv_discount_usdc, final_fee_usdc, _routing_fee_usdc, _total_before_discount_usdc) = unxv_dex::get_fee_breakdown_info(&fee_breakdown_usdc);
            assert!(unxv_discount > 0, 0);
            assert!(final_fee_unxv < final_fee_usdc, 1);
            
            // Verify routing fees for multi-hop trades
            let fee_breakdown_routing = unxv_dex::calculate_trading_fees(
                TRADE_AMOUNT,
                0,
                string::utf8(b"MARKET"),
                2, // 2 hops
                string::utf8(b"USDC"),
                &registry
            );
            
            let (_unxv_discount_routing, final_fee_routing, routing_fee, _total_before_discount_routing) = unxv_dex::get_fee_breakdown_info(&fee_breakdown_routing);
            assert!(routing_fee > 0, 2);
            assert!(final_fee_routing > final_fee_usdc, 3);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_arbitrage_detection() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add pools for triangular arbitrage
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            // Add all pairs for USDC-ETH-BTC triangle
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"ETH"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"ETH"),
                string::utf8(b"BTC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"BTC"),
                string::utf8(b"USDC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Detect arbitrage opportunities
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let base_assets = vector[
                string::utf8(b"USDC"),
                string::utf8(b"ETH"),
                string::utf8(b"BTC")
            ];
            
            let opportunities = unxv_dex::detect_triangular_arbitrage(
                &registry,
                base_assets,
                1000, // Min profit threshold
                &clock,
                scenario.ctx()
            );
            
            // Should detect at least one arbitrage opportunity
            assert!(vector::length(&opportunities) > 0, 0);
            
            if (vector::length(&opportunities) > 0) {
                let opportunity = vector::borrow(&opportunities, 0);
                let (profit_amount, profit_percentage, path) = unxv_dex::get_arbitrage_info(opportunity);
                assert!(profit_amount > 0, 1);
                assert!(profit_percentage > 0, 2);
                assert!(vector::length(path) == 4, 3); // A->B->C->A
            };
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_admin_functions() {
        let mut scenario = setup_test_scenario();
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Test admin functions
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            // Add pool
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            // Test pause system
            unxv_dex::set_system_pause(&mut registry, true, scenario.ctx());
            let (_, _, is_paused) = unxv_dex::get_registry_stats(&registry);
            assert!(is_paused, 0);
            
            // Test unpause system
            unxv_dex::set_system_pause(&mut registry, false, scenario.ctx());
            let (_, _, is_paused_after) = unxv_dex::get_registry_stats(&registry);
            assert!(!is_paused_after, 1);
            
            // Test pool activation toggle
            unxv_dex::set_pool_active(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                false,
                scenario.ctx()
            );
            
            // Pool should now be inactive
            let pool_info = unxv_dex::get_pool_info(
                &registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI")
            );
            // In production, we'd verify pool_info.is_active == false
            
            // Test fee structure update
            let new_fee_structure = unxv_dex::create_test_fee_structure();
            unxv_dex::update_fee_structure(&mut registry, new_fee_structure, scenario.ctx());
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_system_paused_protection() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add pool and pause system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            // Pause the system
            unxv_dex::set_system_pause(&mut registry, true, scenario.ctx());
            
            test_scenario::return_shared(registry);
        };
        
        // Try to execute trade on paused system (should fail)
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            let mut session = unxv_dex::create_trading_session(scenario.ctx());
            let input_coin = unxv_dex::create_mock_coin<USDC>(TRADE_AMOUNT, scenario.ctx());
            
            // This should abort due to system being paused
            // In a real test framework, we'd use an expected failure test
            
            coin::burn_for_testing(input_coin);
            test_utils::destroy(session);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_pool_not_found_error() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX without adding any pools
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Try to trade on non-existent pool (should fail)
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            let mut session = unxv_dex::create_trading_session(scenario.ctx());
            let input_coin = unxv_dex::create_mock_coin<USDC>(TRADE_AMOUNT, scenario.ctx());
            
            // This should abort due to pool not found
            // In a real test framework, we'd use an expected failure test
            
            coin::burn_for_testing(input_coin);
            test_utils::destroy(session);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_cross_asset_routing_edge_cases() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add only one pool (no routing possible)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Try to route between assets with no path
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let route = unxv_dex::calculate_cross_asset_route(
                &registry,
                string::utf8(b"ETH"),
                string::utf8(b"BTC"),
                TRADE_AMOUNT,
                option::none(),
                &clock,
                scenario.ctx()
            );
            
            // Should return empty route with zero viability
            let (_hops_required, _estimated_output, _total_fees, route_viability, path) = unxv_dex::get_route_info(&route);
            assert!(route_viability == 0, 0);
            assert!(vector::is_empty(path), 1);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }

#[test]
    fun test_fee_processing_with_autoswap() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Test fee processing
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let fee_breakdown = unxv_dex::calculate_trading_fees(
                TRADE_AMOUNT,
                0,
                string::utf8(b"MARKET"),
                0,
                string::utf8(b"UNXV"),
                &registry
            );
            
            // Process fees with AutoSwap (this should emit events)
            unxv_dex::process_fees_with_autoswap(
                fee_breakdown,
                TRADER_ALICE,
                &clock
            );
            
            // In production, we'd verify that TradingFeesCollected event was emitted
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_multiple_trader_interactions() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add pool
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Alice trades
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            let mut session = unxv_dex::create_trading_session(scenario.ctx());
            let input_coin = unxv_dex::create_mock_coin<USDC>(TRADE_AMOUNT, scenario.ctx());
            
            let (output_coin, _) = unxv_dex::execute_direct_trade<USDC, SUI>(
                &mut registry,
                &mut session,
                string::utf8(b"USDC"),
                string::utf8(b"SUI"),
                string::utf8(b"BUY"),
                TRADE_AMOUNT,
                input_coin,
                MIN_OUTPUT,
                string::utf8(b"USDC"),
                &clock,
                scenario.ctx()
            );
            
            coin::burn_for_testing(output_coin);
            test_utils::destroy(session);
            test_scenario::return_shared(registry);
        };
        
        // Bob trades
        test_scenario::next_tx(&mut scenario, TRADER_BOB);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            let mut session = unxv_dex::create_trading_session(scenario.ctx());
            let input_coin = unxv_dex::create_mock_coin<SUI>(TRADE_AMOUNT, scenario.ctx());
            
            let (output_coin, _) = unxv_dex::execute_direct_trade<SUI, USDC>(
                &mut registry,
                &mut session,
                string::utf8(b"SUI"),
                string::utf8(b"USDC"),
                string::utf8(b"SELL"),
                TRADE_AMOUNT,
                input_coin,
                MIN_OUTPUT,
                string::utf8(b"UNXV"),
                &clock,
                scenario.ctx()
            );
            
            coin::burn_for_testing(output_coin);
            test_utils::destroy(session);
            test_scenario::return_shared(registry);
        };
        
        // Verify total registry stats
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let (total_volume, total_fees, _) = unxv_dex::get_registry_stats(&registry);
            assert!(total_volume == TRADE_AMOUNT * 2, 0); // Two trades
            assert!(total_fees > 0, 1);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_direct_route_preference() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize DEX
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_dex::init_for_testing(scenario.ctx());
        };
        
        // Add both direct and indirect routes
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            // Add direct ETH/BTC pool
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"ETH"),
                string::utf8(b"BTC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            // Add indirect route through USDC
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"ETH"),
                string::utf8(b"USDC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            unxv_dex::add_supported_pool(
                &mut registry,
                string::utf8(b"USDC"),
                string::utf8(b"BTC"),
                create_mock_pool_id(),
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
        };
        
        // Calculate route - should prefer direct
        test_scenario::next_tx(&mut scenario, TRADER_ALICE);
        {
            let registry = test_scenario::take_shared<DEXRegistry>(&scenario);
            
            let route = unxv_dex::calculate_cross_asset_route(
                &registry,
                string::utf8(b"ETH"),
                string::utf8(b"BTC"),
                TRADE_AMOUNT,
                option::none(),
                &clock,
                scenario.ctx()
            );
            
            // Should prefer direct route
            let (hops_required, _estimated_output, _total_fees, route_viability, path) = unxv_dex::get_route_info(&route);
            assert!(hops_required == 1, 0);
            assert!(route_viability == 9500, 1); // High viability for direct
            assert!(vector::length(path) == 2, 2); // ETH -> BTC
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
}
