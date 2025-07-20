#[test_only]
module unxv_liquidity::unxv_liquidity_tests {
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::test_utils;
    use std::string::{Self, String};
    use std::vector;

    use unxv_liquidity::unxv_liquidity::{
        Self,
        LiquidityRegistry,
        LiquidityPool,
        AdminCap,
        USDC,
        MarketConditions,
        ArbitrageOpportunity,
        RiskParameters,
        LiquidityAddResult,
        WithdrawalResult,
        OptimizationResult,
        SignedInt
    };

    // Test coin types for pools
    public struct TokenA has drop {}
    public struct TokenB has drop {}

    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    const USER2: address = @0x2;

    // Helper function to create test market conditions
    fun create_test_market_conditions(): MarketConditions {
        unxv_liquidity::create_test_market_conditions()
    }

    // Helper function to create test arbitrage opportunity
    fun create_test_arbitrage_opportunity(): ArbitrageOpportunity {
        unxv_liquidity::create_test_arbitrage_opportunity()
    }

    // Helper to create test coins
    fun create_test_token_a(amount: u64, scenario: &mut Scenario): Coin<TokenA> {
        coin::mint_for_testing<TokenA>(amount, test_scenario::ctx(scenario))
    }

    fun create_test_token_b(amount: u64, scenario: &mut Scenario): Coin<TokenB> {
        coin::mint_for_testing<TokenB>(amount, test_scenario::ctx(scenario))
    }

    fun create_test_usdc(amount: u64, scenario: &mut Scenario): Coin<USDC> {
        unxv_liquidity::create_test_usdc(amount, test_scenario::ctx(scenario))
    }

    #[test]
    fun test_protocol_initialization() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        transfer::public_transfer(admin_cap, ADMIN);
        
        // Verify registry exists
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let (total_pools, total_liquidity, volume_24h, fees_collected, paused) = 
                unxv_liquidity::get_registry_stats(&registry);
            
            assert!(total_pools == 0, 1);
            assert!(total_liquidity == 0, 2);
            assert!(volume_24h == 0, 3);
            assert!(fees_collected == 0, 4);
            assert!(!paused, 5);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_create_liquidity_pool() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            // Create a new liquidity pool
            let pool_id = unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300, // 3% fee rate
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify pool was created
            let (total_pools, _, _, _, _) = unxv_liquidity::get_registry_stats(&registry);
            assert!(total_pools == 1, 6);
            
            // Verify pool exists
            assert!(unxv_liquidity::pool_exists(&registry, 
                string::utf8(b"TokenA"), 
                string::utf8(b"TokenB")), 7);
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_add_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol and create pool
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        // User adds liquidity
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario); // 1M TokenA
            let token_b = create_test_token_b(1000000, &mut scenario); // 1M TokenB
            
            let result = unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0, // min LP tokens
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50, // 50% IL protection
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify liquidity was added
            let (reserve_a, reserve_b, total_shares, price_ratio, apy) = 
                unxv_liquidity::get_pool_info(&pool);
            
            assert!(reserve_a == 1000000, 8);
            assert!(reserve_b == 1000000, 9);
            assert!(total_shares > 0, 10);
            assert!(price_ratio == 1000000, 11); // 1:1 ratio
            
            // Verify user position
            let (shares_owned, current_value, fees_earned, unxv_tier) = 
                unxv_liquidity::get_lp_position(&pool, USER1);
            
            assert!(shares_owned > 0, 12);
            assert!(current_value > 0, 13);
            assert!(fees_earned == 0, 14); // No fees earned yet
            assert!(unxv_tier == 0, 15); // No UNXV staked
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_remove_liquidity() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create pool, and add liquidity
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // Remove liquidity
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let (shares_owned, _, _, _) = unxv_liquidity::get_lp_position(&pool, USER1);
            let shares_to_remove = shares_owned / 2; // Remove 50%
            
            let (coin_a, coin_b, result) = unxv_liquidity::remove_liquidity(
                &mut registry,
                &mut pool,
                shares_to_remove,
                0, // min asset A
                0, // min asset B
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify coins were returned
            assert!(coin::value(&coin_a) > 0, 16);
            assert!(coin::value(&coin_b) > 0, 17);
            
            // Verify user still has remaining position
            let (remaining_shares, _, _, _) = unxv_liquidity::get_lp_position(&pool, USER1);
            assert!(remaining_shares > 0, 18);
            assert!(remaining_shares < shares_owned, 19);
            
            coin::burn_for_testing(coin_a);
            coin::burn_for_testing(coin_b);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_yield_optimization() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create pool, and add liquidity
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // Test yield optimization
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let market_conditions = create_test_market_conditions();
            
            let result = unxv_liquidity::optimize_yield_strategy(
                &mut registry,
                &mut pool,
                market_conditions,
                1500, // 15% target APY
                5000, // 50% max risk score
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify optimization result
            // Note: The actual strategy selected depends on the optimization logic
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_arbitrage_detection() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            // Create multiple pools for arbitrage opportunities
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            let mut monitoring_scope = vector::empty<String>();
            vector::push_back(&mut monitoring_scope, string::utf8(b"TokenA-TokenB"));
            
            let opportunities = unxv_liquidity::detect_arbitrage_opportunities(
                &registry,
                monitoring_scope,
                1000, // min profit threshold
                5000  // max risk tolerance
            );
            
            // Should detect opportunities (implementation dependent)
            // For this simplified test, we just verify the function doesn't fail
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_cross_protocol_arbitrage_execution() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let opportunity = create_test_arbitrage_opportunity();
            
            let success = unxv_liquidity::execute_cross_protocol_arbitrage(
                &mut registry,
                opportunity,
                100000, // capital allocation
                500,    // max slippage (5%)
                &admin_cap,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            assert!(success, 20);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_il_protection_purchase() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create pool, and add liquidity
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // Purchase IL protection
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let premium_payment = create_test_usdc(10000, &mut scenario); // $100 premium
            
            let policy_id = unxv_liquidity::purchase_il_protection(
                &mut registry,
                &pool,
                USER1,
                80, // 80% coverage
                31536000000, // 1 year duration
                premium_payment,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify IL protection stats updated
            let (coverage_outstanding, insurance_reserves, claims_paid) = 
                unxv_liquidity::get_il_protection_stats(&registry);
            
            assert!(coverage_outstanding > 0, 21);
            assert!(insurance_reserves >= 10000, 22);
            assert!(claims_paid == 0, 23);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_pool_rebalancing() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create pool, and add liquidity
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // Test pool rebalancing
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let (_, _, _, old_ratio, _) = unxv_liquidity::get_pool_info(&pool);
            let new_ratio = 1200000; // 1.2:1 ratio
            
            unxv_liquidity::rebalance_pool(
                &mut registry,
                &mut pool,
                string::utf8(b"SCHEDULED"),
                new_ratio,
                500, // 5% max slippage
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            let (_, _, _, updated_ratio, _) = unxv_liquidity::get_pool_info(&pool);
            assert!(updated_ratio == new_ratio, 24);
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_unxv_benefits() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create pool, and add liquidity
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // Apply UNXV benefits
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            unxv_liquidity::apply_unxv_benefits(
                &mut registry,
                &mut pool,
                USER1,
                25000, // 25k UNXV staked (Tier 3)
                string::utf8(b"FEE_DISCOUNT"),
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            let (_, _, _, unxv_tier) = unxv_liquidity::get_lp_position(&pool, USER1);
            assert!(unxv_tier == 3, 25); // Should be Tier 3
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_farming_rewards_harvest() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol, create pool, and add liquidity
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // Harvest farming rewards
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let reward_coin = unxv_liquidity::harvest_farming_rewards(
                &mut registry,
                &mut pool,
                USER1,
                true, // auto compound
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify rewards were processed
            let (_, _, fees_earned, _) = unxv_liquidity::get_lp_position(&pool, USER1);
            assert!(fees_earned > 0, 26);
            
            coin::burn_for_testing(reward_coin);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_emergency_controls() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            // Test emergency pause
            unxv_liquidity::emergency_pause(&mut registry, &admin_cap);
            
            let (_, _, _, _, paused) = unxv_liquidity::get_registry_stats(&registry);
            assert!(paused, 27);
            
            // Test resume operations
            unxv_liquidity::resume_operations(&mut registry, &admin_cap);
            
            let (_, _, _, _, resumed) = unxv_liquidity::get_registry_stats(&registry);
            assert!(!resumed, 28);
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_risk_parameters_update() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            let new_params = unxv_liquidity::create_test_risk_parameters();
            
            unxv_liquidity::update_risk_parameters(&mut registry, new_params, &admin_cap);
            
            // Risk parameters are updated internally
            // This test verifies the function executes without error
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

#[test]
    fun test_insurance_reserves_management() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize protocol
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            let reserves = create_test_usdc(100000, &mut scenario); // $1000 reserves
            
            unxv_liquidity::add_insurance_reserves(&mut registry, reserves, &admin_cap);
            
            let (_, insurance_reserves, _) = unxv_liquidity::get_il_protection_stats(&registry);
            assert!(insurance_reserves >= 100000, 29);
            
            test_scenario::return_shared(registry);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }

    #[test]
    fun test_signed_integer_operations() {
        // Test signed integer helper functions
        let positive = unxv_liquidity::signed_int_positive(1000);
        let negative = unxv_liquidity::signed_int_negative(500);
        let zero = unxv_liquidity::signed_int_zero();
        
        assert!(unxv_liquidity::signed_int_value(&positive) == 1000, 30);
        assert!(unxv_liquidity::signed_int_is_positive(&positive), 31);
        assert!(!unxv_liquidity::signed_int_is_positive(&negative), 32);
        assert!(unxv_liquidity::signed_int_value(&zero) == 0, 33);
        assert!(unxv_liquidity::signed_int_is_positive(&zero), 34);
        
        // Test addition
        let sum = unxv_liquidity::signed_int_add(positive, negative);
        assert!(unxv_liquidity::signed_int_value(&sum) == 500, 35);
        assert!(unxv_liquidity::signed_int_is_positive(&sum), 36);
    }

    #[test]
    fun test_multiple_users_same_pool() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Initialize protocol and create pool
        let admin_cap = unxv_liquidity::init_for_testing(test_scenario::ctx(&mut scenario));
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            
            unxv_liquidity::create_liquidity_pool<TokenA, TokenB>(
                &mut registry,
                string::utf8(b"TokenA"),
                string::utf8(b"TokenB"),
                string::utf8(b"VOLATILE"),
                300,
                &admin_cap,
                test_scenario::ctx(&mut scenario)
            );
            
            test_scenario::return_shared(registry);
        };
        
        // User 1 adds liquidity
        test_scenario::next_tx(&mut scenario, USER1);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(1000000, &mut scenario);
            let token_b = create_test_token_b(1000000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"BALANCED_YIELD_OPTIMIZATION"),
                50,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        // User 2 adds liquidity
        test_scenario::next_tx(&mut scenario, USER2);
        {
            let mut registry = test_scenario::take_shared<LiquidityRegistry>(&scenario);
            let mut pool = test_scenario::take_shared<LiquidityPool<TokenA, TokenB>>(&scenario);
            let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
            
            let token_a = create_test_token_a(500000, &mut scenario);
            let token_b = create_test_token_b(500000, &mut scenario);
            
            unxv_liquidity::add_liquidity(
                &mut registry,
                &mut pool,
                token_a,
                token_b,
                0,
                string::utf8(b"CONSERVATIVE_STABLE_FARMING"),
                25,
                &clock,
                test_scenario::ctx(&mut scenario)
            );
            
            // Verify both users have positions
            let (user1_shares, _, _, _) = unxv_liquidity::get_lp_position(&pool, USER1);
            let (user2_shares, _, _, _) = unxv_liquidity::get_lp_position(&pool, USER2);
            
            assert!(user1_shares > 0, 37);
            assert!(user2_shares > 0, 38);
            assert!(user1_shares > user2_shares, 39); // User1 added more liquidity
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(pool);
        };
        
        test_utils::destroy(admin_cap);
        test_scenario::end(scenario);
    }
}
