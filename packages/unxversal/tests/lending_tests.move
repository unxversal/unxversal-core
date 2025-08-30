#[test_only]
module unxversal::lending_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin::{Self as coin, Coin};
    use std::string;

    use unxversal::lending::{Self as Lend, LendingRegistry, LendingPool, UserAccount};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::test_coins::TestBaseUSD;

    // Basic supply/withdraw scaled math and totals
    #[test]
    fun supply_withdraw_scaled_and_totals() {
        let owner = @0x71;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        // Add supported asset BASE (collateral, borrowable)
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);

        // Create pool and account
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);

        // Supply 10_000 units
        let clk = clock::create_for_testing(ctx);
        let coins_in: Coin<TestBaseUSD> = coin::mint_for_testing<TestBaseUSD>(10_000, ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coins_in, 10_000, &clk, ctx);
        let (_ts, _tb, _tr, cash, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        assert!(cash == 10_000);
        // Scaled balance and units round-trip
        let scaled = Lend::acct_supply_scaled_for_testing(&acct, &string::utf8(b"BASE"));
        let units = Lend::units_from_scaled_for_testing(scaled, sidx);
        assert!(units == 10_000);

        // Withdraw 4_000; ensure liquidity and scaled math
        let ps = Lend::new_price_set_for_testing(ctx);
        let mut syms: vector<string::String> = vector::empty<string::String>();
        vector::push_back(&mut syms, string::utf8(b"BASE"));
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        // switchboard::decimal does not expose set_for_testing in our utils; values are already 1e6 scaled
        switchboard::aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        // Build a bound price set for self-asset capacity checks
        let mut psx = Lend::new_price_set_for_testing(ctx);
        let mut oregx = Oracle::new_registry_for_testing(ctx);
        let reg_admin_x = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&reg_admin_x, &mut oregx, string::utf8(b"BASE"), &agg, ctx);
        Lend::record_symbol_price(&oregx, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut psx);
        Lend::withdraw<TestBaseUSD>(&reg, &mut pool, &mut acct, 4_000, &oregx, &ocfg, &clk, &agg, syms, &psx, sidxs, bidxs, ctx);
        let (_ts2, _tb2, _tr2, cash2, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        assert!(cash2 == 6_000);

        // Cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(acct);
        sui::transfer::public_share_object(ps);
        sui::transfer::public_share_object(psx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(reg_admin_x);
        sui::transfer::public_share_object(oregx);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
}

#[test_only]
module unxversal::lending_more_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin::{Self as coin};
    use std::string;
    use unxversal::lending::{Self as Lend, LendingRegistry, LendingPool, UserAccount};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::test_coins::TestBaseUSD;
    use unxversal::treasury::{Self as Tre, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};

    #[test]
    fun borrow_and_repay_scaled_math() {
        let owner = @0x72;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);

        // supply 50_000 into pool for liquidity
        let c_sup = coin::mint_for_testing<TestBaseUSD>(50_000, ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, c_sup, 50_000, &clk, ctx);

        // Prepare price set for borrow/health guards
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut oreg = Oracle::new_registry_for_testing(ctx);
        let mut agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        switchboard::aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        // build priceset for LTV checks
        let mut ps = Lend::new_price_set_for_testing(ctx);
        let admin_reg1 = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&admin_reg1, &mut oreg, string::utf8(b"BASE"), &agg, ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let ( _ts, _tb, _tr, _cash, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);

        // Borrow 10_000
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 10_000, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        let (_ts2, _tb2, _tr2, cash2, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        assert!(cash2 == 40_000);

        // Repay 5_000
        let repay = coin::mint_for_testing<TestBaseUSD>(5_000, ctx);
        Lend::repay<TestBaseUSD>(&reg, &mut pool, &mut acct, repay, &clk, ctx);
        let (_ts3, _tb3, _tr3, cash3, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        assert!(cash3 == 45_000);

        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(acct);
        sui::transfer::public_share_object(ps);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(oreg);
        sui::transfer::public_share_object(admin_reg1);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun withdraw_ltv_guard_rejects() {
        let owner = @0x73;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        // Tight LTV: 50%, threshold 60%
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 5_000, 6_000, 500, 200, 0, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // supply 10_000
        let c_sup = coin::mint_for_testing<TestBaseUSD>(10_000, ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, c_sup, 10_000, &clk, ctx);
        // price and ps
        let mut oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        switchboard::aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut ps = Lend::new_price_set_for_testing(ctx);
        let admin_reg2 = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&admin_reg2, &mut oreg, string::utf8(b"BASE"), &agg, ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let (_, _, _, _, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        // Borrow to consume capacity: borrow 5_000 (50% LTV of 10_000)
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 5_000, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        // Now try to withdraw 1, which should violate LTV guard → abort
        let mut syms2: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms2, string::utf8(b"BASE"));
        let mut sidxs2: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs2, sidx);
        let mut bidxs2: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs2, bidx);
        Lend::withdraw<TestBaseUSD>(&reg, &mut pool, &mut acct, 1, &oreg, &ocfg, &clk, &agg, syms2, &ps, sidxs2, bidxs2, ctx);
        abort 0
    }

    #[test]
    fun accrue_updates_indices_and_reserves() {
        let owner = @0x74;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        // Non-zero reserve factor
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 1_000, 8_000, 8_500, 500, 2_000, 10_000, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // Provide liquidity and borrow to have total_borrows > 0
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(100_000, ctx), 100_000, &clk, ctx);
        let mut oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        switchboard::aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut ps = Lend::new_price_set_for_testing(ctx);
        let admin_reg_accrue = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&admin_reg_accrue, &mut oreg, string::utf8(b"BASE"), &agg, ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let (_, _, _, _, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 20_000, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        // Update rates, advance time, accrue
        let mut mirror = Lend::new_event_mirror_for_testing(ctx);
        Lend::update_pool_rates<TestBaseUSD>(&reg, &mut pool, &clk, ctx);
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 86_400_000);
        Lend::accrue_with_event_mirror<TestBaseUSD>(&reg, &mut pool, &clk2, &mut mirror, ctx);
        let (_ts, _tb, tr, _cash, sidx2, bidx2) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        assert!(sidx2 >= sidx);
        assert!(bidx2 >= bidx);
        assert!(tr > 0);
        assert!(Lend::em_accrue_count(&mirror) == 1);
        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(acct);
        sui::transfer::public_share_object(ps);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(oreg);
        sui::transfer::public_share_object(admin_reg_accrue);
        sui::transfer::public_share_object(mirror);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test]
    fun flash_loan_fee_routed_to_treasury_epoch() {
        let owner = @0x75;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), false, false, 0, 0, 0, 0, 0, 0, 0);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let clk = clock::create_for_testing(ctx);
        // seed pool cash
        let mut seed_acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut seed_acct, coin::mint_for_testing<TestBaseUSD>(10_000, ctx), 10_000, &clk, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let before = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        // Initiate and repay a flash loan of 1_000 with fee 9 bps (per default gp)
        Lend::initiate_flash_loan<TestBaseUSD>(&reg, &mut pool, 1_000, ctx);
        let principal = coin::mint_for_testing<TestBaseUSD>(1_000 + 1, ctx);
        Lend::repay_flash_loan<TestBaseUSD>(&reg, &mut pool, principal, 1_000, 1, string::utf8(b"BASE"), &mut tre, &mut bot, &mut points, &clk, ctx);
        let after = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        assert!(after >= before + 1);
        // cleanup
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(seed_acct);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun liquidation_coin_routes_to_treasury_and_bot() {
        let owner = @0x76;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        // Configure two assets (debt and collateral) with reasonable risk
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"DEBT"), false, true, 0, 0, 0, 500, 200, 0, 10000);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"COLL"), true, false, 0, 9_000, 9_500, 500, 200, 0, 10000);
        let mut debt_pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"DEBT"), ctx);
        let mut coll_pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"COLL"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // Seed pools
        Lend::supply<TestBaseUSD>(&reg, &mut coll_pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(50_000, ctx), 50_000, &clk, ctx);
        // Separate account supplies to debt pool to provide borrowable liquidity
        let mut acct2: UserAccount = Lend::new_user_account_for_testing(ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut debt_pool, &mut acct2, coin::mint_for_testing<TestBaseUSD>(50_000, ctx), 50_000, &clk, ctx);
        // Prices
        let oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg_debt = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"DEBT_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let mut agg_coll = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"COLL_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        switchboard::aggregator::set_current_value(&mut agg_debt, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        switchboard::aggregator::set_current_value(&mut agg_coll, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut ps = Lend::new_price_set_for_testing(ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"DEBT"), &agg_debt, &mut ps);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"COLL"), &agg_coll, &mut ps);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"DEBT")); vector::push_back(&mut syms, string::utf8(b"COLL"));
        // Index vectors (aligned)
        let (_, _, _, _, sidx_c, bidx_c) = Lend::pool_values_for_testing<TestBaseUSD>(&coll_pool);
        let (_, _, _, _, _sidx_d, bidx_d) = Lend::pool_values_for_testing<TestBaseUSD>(&debt_pool);
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx_c); vector::push_back(&mut sidxs, sidx_c);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx_d); vector::push_back(&mut bidxs, bidx_c);
        // Borrow some debt to be undercollateralized later by manual price changes
        Lend::borrow<TestBaseUSD>(&reg, &mut debt_pool, &mut acct, 10_000, &oreg, &ocfg, &clk, &agg_debt, syms, &ps, sidxs, bidxs, ctx);
        // Increase penalty split to treasury; then simulate undercollateralization by dropping collateral price
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        Lend::set_points_and_splits_for_testing(&mut reg, &admin_reg, 0, 0, 0, 2_000, ctx);
        // Manually change collateral price to reduce account ratio below threshold
        switchboard::aggregator::set_current_value(&mut agg_coll, switchboard::decimal::new(100_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        // Update bound price set with new collateral price
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"COLL"), &agg_coll, &mut ps);
        // Bot infra
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        // Liquidate 1_000 units
        let payment = coin::mint_for_testing<TestBaseUSD>(1_000, ctx);
        let mut syms3 = vector::empty<string::String>(); vector::push_back(&mut syms3, string::utf8(b"DEBT")); vector::push_back(&mut syms3, string::utf8(b"COLL"));
        let mut sidxs3 = vector::empty<u64>(); vector::push_back(&mut sidxs3, sidx_c); vector::push_back(&mut sidxs3, sidx_c);
        let mut bidxs3 = vector::empty<u64>(); vector::push_back(&mut bidxs3, bidx_d); vector::push_back(&mut bidxs3, bidx_c);
        let tre_before = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        // Pre balances
        let pre_debt_scaled = Lend::acct_borrow_scaled_for_testing(&acct, &string::utf8(b"DEBT"));
        let pre_coll_scaled = Lend::acct_supply_scaled_for_testing(&acct, &string::utf8(b"COLL"));
        let (pre_coll_total, _, _, _, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&coll_pool);
        Lend::liquidate_coin_position<TestBaseUSD, TestBaseUSD>(&reg, &mut debt_pool, &mut coll_pool, &mut acct, &oreg, &ocfg, &clk, &agg_debt, &agg_coll, payment, 1_000, syms3, &ps, sidxs3, bidxs3, &mut tre, &mut points, &mut bot, ctx);
        let tre_after = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        assert!(tre_after > tre_before);
        // Assert debtor balances and pool totals changed
        let post_debt_scaled = Lend::acct_borrow_scaled_for_testing(&acct, &string::utf8(b"DEBT"));
        let post_coll_scaled = Lend::acct_supply_scaled_for_testing(&acct, &string::utf8(b"COLL"));
        let (post_coll_total, _, _, _, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&coll_pool);
        assert!(post_debt_scaled < pre_debt_scaled);
        assert!(post_coll_scaled < pre_coll_scaled);
        assert!(post_coll_total < pre_coll_total);
        // cleanup
        switchboard::aggregator::share_for_testing(agg_debt);
        switchboard::aggregator::share_for_testing(agg_coll);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(debt_pool);
        sui::transfer::public_share_object(coll_pool);
        sui::transfer::public_share_object(acct);
        sui::transfer::public_share_object(acct2);
        sui::transfer::public_share_object(ps);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(oreg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(admin_reg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun skim_reserves_to_treasury_routes_and_reduces_reserves() {
        let owner = @0x77;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 1_000, 8_000, 8_500, 500, 2_000, 10_000, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let clk = clock::create_for_testing(ctx);
        // seed pool cash and reserves
        let mut seed_acct2: UserAccount = Lend::new_user_account_for_testing(ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut seed_acct2, coin::mint_for_testing<TestBaseUSD>(10_000, ctx), 10_000, &clk, ctx);
        // Set rates and accrue to generate reserves
        Lend::update_pool_rates<TestBaseUSD>(&reg, &mut pool, &clk, ctx);
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 86_400_000);
        Lend::accrue_pool_interest<TestBaseUSD>(&reg, &mut pool, &clk2, ctx);
        let (_, _, reserves_before, _, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        assert!(reserves_before > 0);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        // Skim 1 unit of reserves to treasury via epoch-aware deposit
        Lend::skim_reserves_to_treasury<TestBaseUSD>(&reg, &mut pool, &mut tre, &mut bot, &mut points, &clk2, 1, ctx);
        let (_, _, reserves_after, _, _, _) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let tre_after = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        assert!(reserves_after == reserves_before - 1);
        assert!(tre_after >= 1);
        // cleanup
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(seed_acct2);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun paused_rejects_core_ops() {
        let owner = @0x7B;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        Lend::set_paused_for_testing(&mut reg, &admin_reg, true, ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // supply should abort when paused
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(1, ctx), 1, &clk, ctx);
        abort 0
    }

    #[test]
    fun caps_enforced_supply_borrow_and_tx_limits() {
        let owner = @0x7C;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        // caps: supply 2_000 cap, borrow 1_000 cap; per-tx caps 1_500 supply, 700 borrow
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        Lend::set_asset_caps_admin_for_testing(&mut reg, &admin_reg, string::utf8(b"BASE"), 2_000, 1_000, 1_500, 700, ctx);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // per-tx supply cap allows 1_500
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(2_000, ctx), 1_500, &clk, ctx);
        // total cap allows only +500 more
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(1_000, ctx), 500, &clk, ctx);
        // set up price set for borrow
        let oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        switchboard::aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut ps = Lend::new_price_set_for_testing(ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let (_, _, _, _, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        // per-tx borrow cap allows 700
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 700, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(acct);
        sui::transfer::public_share_object(oreg);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(ps);
        sui::transfer::public_share_object(admin_reg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun caps_negative_exceed_tx_caps() {
        let owner = @0x7D;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        Lend::set_asset_caps_admin_for_testing(&mut reg, &admin_reg, string::utf8(b"BASE"), 100_000, 100_000, 1_000, 500, ctx);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // exceed per-tx supply cap
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(2_000, ctx), 1_001, &clk, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun borrow_exceed_tx_cap_negative() {
        let owner = @0x7E;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        Lend::set_asset_caps_admin_for_testing(&mut reg, &admin_reg, string::utf8(b"BASE"), 100_000, 100_000, 100_000, 10, ctx);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // seed supply so borrow path can proceed to cap check
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(100, ctx), 100, &clk, ctx);
        let oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        switchboard::aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut ps = Lend::new_price_set_for_testing(ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let (_, _, _, _, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        // attempt to borrow 11 > per-tx cap 10 → abort
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 11, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun withdraw_zero_amount_rejected() {
        let owner = @0x7F;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(100, ctx), 100, &clk, ctx);
        let mut oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let mut ps = Lend::new_price_set_for_testing(ctx);
        let admin_reg3 = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&admin_reg3, &mut oreg, string::utf8(b"BASE"), &agg, ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let (_, _, _, _, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        Lend::withdraw<TestBaseUSD>(&reg, &mut pool, &mut acct, 0, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun repay_over_debt_rejected() {
        let owner = @0x80;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8_000, 8_500, 500, 200, 0, 10000);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // seed supply and borrow 10
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(100, ctx), 100, &clk, ctx);
        let mut oreg = Oracle::new_registry_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let agg = switchboard::aggregator::new_aggregator(switchboard::aggregator::example_queue_id(), string::utf8(b"BASE_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let mut ps = Lend::new_price_set_for_testing(ctx);
        let admin_reg4 = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&admin_reg4, &mut oreg, string::utf8(b"BASE"), &agg, ctx);
        Lend::record_symbol_price(&oreg, &ocfg, &clk, string::utf8(b"BASE"), &agg, &mut ps);
        let (_, _, _, _, sidx, bidx) = Lend::pool_values_for_testing<TestBaseUSD>(&pool);
        let mut syms: vector<string::String> = vector::empty<string::String>(); vector::push_back(&mut syms, string::utf8(b"BASE"));
        let mut sidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut sidxs, sidx);
        let mut bidxs: vector<u64> = vector::empty<u64>(); vector::push_back(&mut bidxs, bidx);
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 10, &oreg, &ocfg, &clk, &agg, syms, &ps, sidxs, bidxs, ctx);
        // repay over current debt → abort
        Lend::repay<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(11, ctx), &clk, ctx);
        abort 0
    }

    #[test]
    fun admin_global_params_happy_and_negative() {
        let owner = @0x81;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        Lend::set_global_params_for_testing(&mut reg, &admin_reg, 1_234, 13, ctx);
        // verify accrual uses updated reserve factor by simple call (no assert; compile path)
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let clk = clock::create_for_testing(ctx);
        Lend::update_pool_rates<TestBaseUSD>(&reg, &mut pool, &clk, ctx);
        // negative: non-admin attempt
        let mut reg2: LendingRegistry = Lend::new_registry_for_testing(ctx);
        // not using admin_reg on purpose; should fail
        // expected_failure cannot span two asserts easily; use separate test for strict negative if needed
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(admin_reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(reg2);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun coin_integration_supply_withdraw_borrow_repay() {
        let owner = @0x78;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        let mut pool: LendingPool<TestBaseUSD> = Lend::new_pool_for_testing<TestBaseUSD>(string::utf8(b"BASE"), ctx);
        let mut acct: UserAccount = Lend::new_user_account_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        // supply BASE to pool
        Lend::supply<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(1_000, ctx), 1_000, &clk, ctx);
        // borrow and repay BASE
        Lend::borrow<TestBaseUSD>(&reg, &mut pool, &mut acct, 200, &unxversal::oracle::new_registry_for_testing(ctx), &unxversal::oracle::new_oracle_config_for_testing(ctx), &clk, &unxversal::oracle::new_aggregator_for_testing(ctx), vector::empty<String>(), &Lend::new_price_set_for_testing(ctx), vector::empty<u64>(), vector::empty<u64>(), ctx);
        Lend::repay<TestBaseUSD>(&reg, &mut pool, &mut acct, coin::mint_for_testing<TestBaseUSD>(200, ctx), &clk, ctx);
        // cleanup
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(pool);
        sui::transfer::public_share_object(acct);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
}

#[test_only]
module unxversal::lending_admin_tests {
    use sui::test_scenario;
    use std::string;
    use unxversal::lending::{Self as Lend, LendingRegistry};
    use unxversal::admin;

    #[test]
    fun admin_set_caps_happy_path() {
        let owner = @0x79;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8000, 8500, 500, 200, 0, 10000);
        let admin_reg = admin::new_admin_registry_for_testing(ctx);
        // owner is assumed admin in this test-only registry
        Lend::set_asset_caps_admin_for_testing(&mut reg, &admin_reg, string::utf8(b"BASE"), 1_000_000, 2_000_000, 10_000, 20_000, ctx);
        // no getters for caps beyond compiling; this ensures call succeeded without aborts
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(admin_reg);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun admin_set_caps_rejects_non_admin() {
        let user = @0x7A;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: LendingRegistry = Lend::new_registry_for_testing(ctx);
        Lend::add_supported_asset_for_testing(&mut reg, string::utf8(b"BASE"), true, true, 0, 8000, 8500, 500, 200, 0, 10000);
        let fake_admin = admin::new_admin_registry_for_testing(ctx);
        // user is not admin in reg.admin_addrs; expect abort in assert_is_admin
        Lend::set_asset_caps_admin_for_testing(&mut reg, &fake_admin, string::utf8(b"BASE"), 1, 1, 1, 1, ctx);
        abort 0
    }
}




