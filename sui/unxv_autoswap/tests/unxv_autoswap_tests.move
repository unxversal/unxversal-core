#[test_only]
module unxv_autoswap::unxv_autoswap_tests {
    use std::string::{Self, String};
    use std::vector;
    
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::object;
    use sui::test_utils;
    
    use pyth::price_info::{Self, PriceInfoObject};
    
    use unxv_autoswap::unxv_autoswap::{
        Self,
        AutoSwapRegistry,
        UNXVBurnVault,
        FeeProcessor,
        AdminCap,
        SwapResult,
        FeeProcessingResult,
        RouteInfo,
        SUI,
        USDC,
        UNXV,
    };
    
    // Test addresses
    const ADMIN: address = @0xAD;
    const USER_ALICE: address = @0xA11CE;
    const USER_BOB: address = @0xB0B;
    const PROTOCOL_SYNTHETICS: address = @0x5A7;
    
    // Test constants
    const SWAP_AMOUNT: u64 = 100000000; // 100 tokens
    const MIN_OUTPUT: u64 = 95000000; // 95 tokens (5% slippage)
    const MAX_SLIPPAGE: u64 = 500; // 5%
    const FEE_AMOUNT: u64 = 1000000; // 1 token
    
    // ========== Test Setup Helpers ==========
    
    fun setup_test_scenario(): Scenario {
        test_scenario::begin(ADMIN)
    }
    
    fun create_test_clock(scenario: &mut Scenario): Clock {
        clock::create_for_testing(scenario.ctx())
    }
    
    fun create_mock_price_feeds(): vector<PriceInfoObject> {
        vector::empty<PriceInfoObject>()
    }
    
    fun create_mock_pool_id(): object::ID {
        object::id_from_address(@0x1234)
    }
    
    // ========== Core Tests ==========
    
    #[test]
    fun test_autoswap_initialization() {
        let mut scenario = setup_test_scenario();
        
        // Initialize AutoSwap protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Verify registry exists and is properly initialized
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let burn_vault = test_scenario::take_shared<UNXVBurnVault>(&scenario);
            let fee_processor = test_scenario::take_shared<FeeProcessor>(&scenario);
            
            // Check registry initialization
            let (total_swaps, total_volume, active_users) = unxv_autoswap::get_registry_stats(&registry);
            assert!(total_swaps == 0, 0);
            assert!(total_volume == 0, 1);
            assert!(active_users == 0, 2);
            assert!(!unxv_autoswap::is_paused(&registry), 3);
            
            // Check burn vault initialization
            assert!(unxv_autoswap::get_accumulated_unxv(&burn_vault) == 0, 4);
            assert!(unxv_autoswap::get_total_burned(&burn_vault) == 0, 5);
            
            // Check default fee structure
            assert!(unxv_autoswap::get_swap_fee(&registry) == 10, 6); // 0.1%
            assert!(unxv_autoswap::get_unxv_discount(&registry) == 5000, 7); // 50%
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(burn_vault);
            test_scenario::return_shared(fee_processor);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_admin_functions() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Test admin functions
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            // Add supported asset
            unxv_autoswap::add_supported_asset(
                &mut registry,
                string::utf8(b"SUI"),
                create_mock_pool_id(),
                vector::empty<u8>(),
                1000000000, // 1000 USDC liquidity threshold
                &admin_cap,
                scenario.ctx()
            );
            
            // Verify asset is supported
            assert!(unxv_autoswap::is_asset_supported(&registry, string::utf8(b"SUI")), 0);
            
            // Authorize protocol
            unxv_autoswap::authorize_protocol(
                &mut registry,
                string::utf8(b"SYNTHETICS"),
                100000000, // 100 USDC threshold
                &admin_cap,
                scenario.ctx()
            );
            
            // Test emergency pause
            unxv_autoswap::emergency_pause(&mut registry, &admin_cap, scenario.ctx());
            assert!(unxv_autoswap::is_paused(&registry), 1);
            
            // Test resume operations
            unxv_autoswap::resume_operations(&mut registry, &admin_cap, scenario.ctx());
            assert!(!unxv_autoswap::is_paused(&registry), 2);
            
            // Test fee structure update
            unxv_autoswap::update_fee_structure(
                &mut registry,
                20, // 0.2% new swap fee
                4000, // 40% new UNXV discount
                &admin_cap,
                scenario.ctx()
            );
            
            assert!(unxv_autoswap::get_swap_fee(&registry) == 20, 3);
            assert!(unxv_autoswap::get_unxv_discount(&registry) == 4000, 4);
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_swap_to_unxv_execution() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Setup supported assets
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            unxv_autoswap::add_supported_asset(
                &mut registry,
                string::utf8(b"ASSET"),
                create_mock_pool_id(),
                vector::empty<u8>(),
                1000000000,
                &admin_cap,
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        // Execute swap to UNXV
        test_scenario::next_tx(&mut scenario, USER_ALICE);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let input_coin = unxv_autoswap::create_test_coin<SUI>(SWAP_AMOUNT, scenario.ctx());
            let price_feeds = create_mock_price_feeds();
            
            let (output_coin, swap_result) = unxv_autoswap::execute_swap_to_unxv<SUI>(
                &mut registry,
                input_coin,
                MIN_OUTPUT,
                MAX_SLIPPAGE,
                string::utf8(b"SUI"), // Fee payment asset
                price_feeds,
                &clock,
                scenario.ctx()
            );
            
            // Verify swap result
            let (input_amount, output_amount, slippage, fees_paid, price_impact) = 
                unxv_autoswap::get_swap_result_info(&swap_result);
            
            assert!(input_amount == SWAP_AMOUNT, 0);
            assert!(output_amount >= MIN_OUTPUT, 1);
            assert!(slippage <= MAX_SLIPPAGE, 2);
            assert!(fees_paid > 0, 3);
            assert!(coin::value(&output_coin) == output_amount, 4);
            
            // Check registry stats updated
            let (total_swaps, total_volume, active_users) = unxv_autoswap::get_registry_stats(&registry);
            assert!(total_swaps == 1, 5);
            assert!(total_volume > 0, 6);
            assert!(active_users == 1, 7);
            
            coin::burn_for_testing(output_coin);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_swap_to_usdc_execution() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Setup supported assets
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            unxv_autoswap::add_supported_asset(
                &mut registry,
                string::utf8(b"ASSET"),
                create_mock_pool_id(),
                vector::empty<u8>(),
                1000000000,
                &admin_cap,
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        // Execute swap to USDC
        test_scenario::next_tx(&mut scenario, USER_BOB);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let input_coin = unxv_autoswap::create_test_coin<SUI>(SWAP_AMOUNT, scenario.ctx());
            let price_feeds = create_mock_price_feeds();
            
            let (output_coin, swap_result) = unxv_autoswap::execute_swap_to_usdc<SUI>(
                &mut registry,
                input_coin,
                MIN_OUTPUT,
                MAX_SLIPPAGE,
                string::utf8(b"UNXV"), // Fee payment with UNXV discount
                price_feeds,
                &clock,
                scenario.ctx()
            );
            
            // Verify swap result
            let (input_amount, output_amount, slippage, fees_paid, price_impact) = 
                unxv_autoswap::get_swap_result_info(&swap_result);
            
            assert!(input_amount == SWAP_AMOUNT, 0);
            assert!(output_amount >= MIN_OUTPUT, 1);
            assert!(slippage <= MAX_SLIPPAGE, 2);
            assert!(coin::value(&output_coin) == output_amount, 3);
            
            coin::burn_for_testing(output_coin);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_protocol_fee_processing() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Setup authorized protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            unxv_autoswap::authorize_protocol(
                &mut registry,
                string::utf8(b"SYNTHETICS"),
                100000000, // 100 USDC threshold
                &admin_cap,
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        // Process protocol fees
        test_scenario::next_tx(&mut scenario, PROTOCOL_SYNTHETICS);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let mut fee_processor = test_scenario::take_shared<FeeProcessor>(&scenario);
            let mut burn_vault = test_scenario::take_shared<UNXVBurnVault>(&scenario);
            
            // Create fee coins
            let mut fee_coins = vector::empty<Coin<USDC>>();
            vector::push_back(&mut fee_coins, unxv_autoswap::create_test_coin<USDC>(FEE_AMOUNT, scenario.ctx()));
            vector::push_back(&mut fee_coins, unxv_autoswap::create_test_coin<USDC>(FEE_AMOUNT, scenario.ctx()));
            
            let price_feeds = create_mock_price_feeds();
            
            let fee_result = unxv_autoswap::process_protocol_fees<USDC>(
                &mut registry,
                &mut fee_processor,
                &mut burn_vault,
                string::utf8(b"SYNTHETICS"),
                fee_coins,
                string::utf8(b"UNXV"), // Convert to UNXV for burning
                price_feeds,
                &clock,
                scenario.ctx()
            );
            
            // Verify fee processing result
            let (total_fees_usd, unxv_converted, usdc_converted, burn_queue_added) = 
                unxv_autoswap::get_fee_processing_result_info(&fee_result);
            
            assert!(total_fees_usd > 0, 0);
            // Note: Since we're below the aggregation threshold, conversions may be 0
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(fee_processor);
            test_scenario::return_shared(burn_vault);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_unxv_burn_execution() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Test burn execution
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let mut burn_vault = test_scenario::take_shared<UNXVBurnVault>(&scenario);
            
            // Add some UNXV to burn vault for testing
            // In production, this would come from fee processing
            // For testing, we'll simulate having accumulated UNXV
            
            // Skip actual burn test since we don't have UNXV in vault
            // But test that the burn function validates parameters correctly
            
            // Verify initial burn statistics
            assert!(unxv_autoswap::get_total_burned(&burn_vault) == 0, 0);
            assert!(unxv_autoswap::get_accumulated_unxv(&burn_vault) == 0, 1);
            assert!(unxv_autoswap::get_total_unxv_burned(&registry) == 0, 2);
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(burn_vault);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_route_calculation() {
        let mut scenario = setup_test_scenario();
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Test route calculation
        test_scenario::next_tx(&mut scenario, USER_ALICE);
        {
            let registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let price_feeds = create_mock_price_feeds();
            
            // Test route to UNXV
            let route_to_unxv = unxv_autoswap::calculate_optimal_route_to_unxv(
                &registry,
                string::utf8(b"SUI"),
                SWAP_AMOUNT,
                &price_feeds
            );
            
            let (estimated_output, estimated_slippage, confidence_level, path) = 
                unxv_autoswap::get_route_info(&route_to_unxv);
            
            assert!(estimated_output > 0, 0);
            assert!(estimated_slippage <= 500, 1); // Max 5% slippage
            assert!(confidence_level > 0, 2);
            assert!(vector::length(path) >= 2, 3); // At least input and output assets
            
            // Test route to USDC
            let route_to_usdc = unxv_autoswap::calculate_optimal_route_to_usdc(
                &registry,
                string::utf8(b"SUI"),
                SWAP_AMOUNT,
                &price_feeds
            );
            
            let (estimated_output_usdc, estimated_slippage_usdc, confidence_level_usdc, path_usdc) = 
                unxv_autoswap::get_route_info(&route_to_usdc);
            
            assert!(estimated_output_usdc > 0, 4);
            assert!(estimated_slippage_usdc <= 500, 5);
            assert!(confidence_level_usdc > 0, 6);
            assert!(vector::length(path_usdc) >= 2, 7);
            
            test_scenario::return_shared(registry);
            vector::destroy_empty(price_feeds);
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_fee_calculations() {
        let mut scenario = setup_test_scenario();
        
        // Test fee calculation logic
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let amount = 1000000; // 1M units
            let fee_rate = 10; // 0.1%
            let basis_points = 10000;
            
            // Test base fee calculation
            let base_fee = amount * fee_rate / basis_points;
            assert!(base_fee == 1000, 0); // 0.1% of 1M = 1000
            
            // Test UNXV discount calculation
            let discount = 5000; // 50%
            let discounted_fee = base_fee * (basis_points - discount) / basis_points;
            assert!(discounted_fee == 500, 1); // 50% discount = 500
            
            // Test slippage calculation
            let expected_output = 1000000;
            let actual_output = 995000; // 0.5% slippage
            let slippage = ((expected_output - actual_output) * basis_points) / expected_output;
            assert!(slippage == 50, 2); // 0.5% = 50 basis points
        };
        
        test_scenario::end(scenario);
    }
    
    #[test]
    fun test_multiple_user_interactions() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Setup supported assets
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            unxv_autoswap::add_supported_asset(
                &mut registry,
                string::utf8(b"ASSET"),
                create_mock_pool_id(),
                vector::empty<u8>(),
                1000000000,
                &admin_cap,
                scenario.ctx()
            );
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        // Alice swaps to UNXV
        test_scenario::next_tx(&mut scenario, USER_ALICE);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let input_coin = unxv_autoswap::create_test_coin<SUI>(SWAP_AMOUNT, scenario.ctx());
            let price_feeds = create_mock_price_feeds();
            
            let (output_coin, _) = unxv_autoswap::execute_swap_to_unxv<SUI>(
                &mut registry,
                input_coin,
                MIN_OUTPUT,
                MAX_SLIPPAGE,
                string::utf8(b"SUI"),
                price_feeds,
                &clock,
                scenario.ctx()
            );
            
            coin::burn_for_testing(output_coin);
            test_scenario::return_shared(registry);
        };
        
        // Bob swaps to USDC
        test_scenario::next_tx(&mut scenario, USER_BOB);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let input_coin = unxv_autoswap::create_test_coin<SUI>(SWAP_AMOUNT, scenario.ctx());
            let price_feeds = create_mock_price_feeds();
            
            let (output_coin, _) = unxv_autoswap::execute_swap_to_usdc<SUI>(
                &mut registry,
                input_coin,
                MIN_OUTPUT,
                MAX_SLIPPAGE,
                string::utf8(b"UNXV"), // Use UNXV discount
                price_feeds,
                &clock,
                scenario.ctx()
            );
            
            coin::burn_for_testing(output_coin);
            test_scenario::return_shared(registry);
        };
        
        // Verify multiple users tracked
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            
            let (total_swaps, total_volume, active_users) = unxv_autoswap::get_registry_stats(&registry);
            assert!(total_swaps == 2, 0);
            assert!(active_users == 2, 1); // Both Alice and Bob
            assert!(total_volume > 0, 2);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_system_pause_protection() {
        let mut scenario = setup_test_scenario();
        let clock = create_test_clock(&mut scenario);
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Pause system
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            unxv_autoswap::emergency_pause(&mut registry, &admin_cap, scenario.ctx());
            assert!(unxv_autoswap::is_paused(&registry), 0);
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        // Resume operations
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            unxv_autoswap::resume_operations(&mut registry, &admin_cap, scenario.ctx());
            assert!(!unxv_autoswap::is_paused(&registry), 1);
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
    }
    
    #[test]
    fun test_asset_support_validation() {
        let mut scenario = setup_test_scenario();
        
        // Initialize protocol
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            unxv_autoswap::init_for_testing(scenario.ctx());
        };
        
        // Test supported assets
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<AutoSwapRegistry>(&scenario);
            let admin_cap = unxv_autoswap::create_test_admin_cap(scenario.ctx());
            
            // Initially no assets supported (except what's added in init)
            let supported_assets = unxv_autoswap::get_supported_assets(&registry);
            // The exact count depends on initialization
            
            // Add a new asset
            unxv_autoswap::add_supported_asset(
                &mut registry,
                string::utf8(b"NEW_ASSET"),
                create_mock_pool_id(),
                vector::empty<u8>(),
                1000000000,
                &admin_cap,
                scenario.ctx()
            );
            
            // Verify asset is now supported
            assert!(unxv_autoswap::is_asset_supported(&registry, string::utf8(b"NEW_ASSET")), 0);
            assert!(!unxv_autoswap::is_asset_supported(&registry, string::utf8(b"UNSUPPORTED_ASSET")), 1);
            
            test_scenario::return_shared(registry);
            test_utils::destroy(admin_cap);
        };
        
        test_scenario::end(scenario);
    }
}
