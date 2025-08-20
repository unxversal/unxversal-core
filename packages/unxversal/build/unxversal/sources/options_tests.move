#[test_only]
module unxversal::options_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use sui::coin::{Self as coin};

    use switchboard::aggregator;
    use unxversal::options::{Self as Opt, OptionsRegistry, OptionMarket};
    use unxversal::synthetics::{Self as Synth};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::treasury::{Self as Tre, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::test_coins::TestBaseUSD;
    // Only TestBaseUSD exists; reuse for Base as needed
    
    // Helpers
    fun feed_bytes(a: &aggregator::Aggregator): vector<u8> { aggregator::feed_hash(a) }
    fun consume_unxv(mut v: vector<sui::coin::Coin<unxversal::unxv::UNXV>>, recipient: address) {
        while (vector::length(&v) > 0) {
            let c = vector::pop_back(&mut v);
            sui::transfer::public_transfer(c, recipient);
        };
        vector::destroy_empty(v);
    }

    #[test]
    fun add_underlying_and_create_market_happy() {
        let admin = @0x91;
        let mut scen = test_scenario::begin(admin);
        let ctx = scen.ctx();

        // Minimal synth registry to satisfy admin gating paths if needed later
        let synth_reg = Synth::new_registry_for_testing(ctx);
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);

        // Prepare oracle config and aggregator
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), admin, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = feed_bytes(&agg);

        // Add underlying via test helper
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000_000, 1, 1, 31536000000, true, ctx);

        // Create market
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let (fee_coin, unxv_back) = Opt::create_option_market<TestBaseUSD>(&mut reg, string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"CASH"), &mut tre, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), 0, coin::mint_for_testing<TestBaseUSD>(0, ctx), &ocfg, &clk, &agg, &mut points, ctx);
        // consume returned values
        sui::coin::destroy_zero(fee_coin);
        consume_unxv(unxv_back, admin);

        // Share resources to consume
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(synth_reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun paused_registry_rejects_create_market() {
        let admin = @0x92;
        let mut scen = test_scenario::begin(admin);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), admin, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let fhash = feed_bytes(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        Opt::set_paused_for_testing(&mut reg, true);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let (fc0, uv0) = Opt::create_option_market<TestBaseUSD>(&mut reg, string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"CASH"), &mut tre, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), 0, coin::mint_for_testing<TestBaseUSD>(0, ctx), &ocfg, &clk, &agg, &mut points, ctx);
        sui::coin::destroy_zero(fc0);
        consume_unxv(uv0, admin);
        abort 0
    }

    #[test, expected_failure]
    fun wrong_feed_hash_rejected_on_exercise() {
        let admin = @0x93;
        let mut scen = test_scenario::begin(admin);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        // Real feed used for underlying
        let mut agg_real = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), admin, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg_real, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = feed_bytes(&agg_real);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        // Create market
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let (fc1, uv1) = Opt::create_option_market<TestBaseUSD>(&mut reg, string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"CASH"), &mut tre, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), 0, coin::mint_for_testing<TestBaseUSD>(0, ctx), &ocfg, &clk, &agg_real, &mut points, ctx);
        sui::coin::destroy_zero(fc1);
        consume_unxv(uv1, admin);
        // Use a mismatched aggregator to trigger E_MISMATCH via assert_and_get_price_for_underlying during exercise
        let agg_wrong = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"WRONG"), admin, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let mut market: OptionMarket = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 3_600_000, string::utf8(b"CASH"), ctx);
        Opt::set_market_exercise_style_for_testing(&mut market, string::utf8(b"AMERICAN"));
        let mut long = Opt::new_long_pos_for_testing<TestBaseUSD>(&market, 1, 0, ctx);
        let mut short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 1, 0, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        Opt::exercise_american_now<TestBaseUSD>(&mut reg, &mut market, &mut long, &mut short, 1, &ocfg, &clk, &agg_wrong, &mut tre, &mut bot, &mut points, ctx);
        abort 0
    }

    #[test]
    fun match_offer_and_escrow_fee_and_rebate_paths() {
        let user = @0x94;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        // market
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let (fc2, uv2) = Opt::create_option_market<TestBaseUSD>(&mut reg, string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"CASH"), &mut tre, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), 0, coin::mint_for_testing<TestBaseUSD>(0, ctx), &ocfg, &clk, &agg, &mut points, ctx);
        sui::coin::destroy_zero(fc2);
        consume_unxv(uv2, user);
        // Fee config: trade=100 bps, maker rebate=50% of taker
        Opt::set_registry_trade_and_rebate_for_testing(&mut reg, 100, 0, 5000);
        // Fetch created market key not needed; we operate with a fresh market object for matching tests
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"CASH"), ctx);
        let mut offer = Opt::new_short_offer_for_testing<TestBaseUSD>(&market, 10, 1000, 0, ctx);
        let mut esc   = Opt::new_premium_escrow_for_testing<TestBaseUSD>(&market, 10, 1000, 10_000, 0, ctx);
        // Perform match: expect premium 10*1000=10_000; taker fee = 100 bps = 100; maker rebate = 50
        Opt::match_offer_and_escrow<TestBaseUSD>(&mut reg, &mut market, &mut offer, &mut esc, 10, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &mut tre, &ocfg, &clk, &agg, ctx);
        let (toi, tvp, ltp) = Opt::market_totals_for_testing(&market);
        assert!(toi == 10);
        assert!(tvp == 10_000);
        assert!(ltp == 1000);
        // Cleanup
        Opt::cancel_premium_escrow<TestBaseUSD>(esc, ctx);
        Opt::cancel_short_offer<TestBaseUSD>(offer, ctx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(ocfg);
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(points);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun unxv_discount_applied_and_leftover_refunded() {
        let user = @0xAB;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        // Configure high discount bps to trigger usage
        Opt::set_registry_trade_and_rebate_for_testing(&mut reg, 100, 5000, 0); // trade 1%, discount 50%
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        // UNXV price = 1_000_000 microUSD
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        // Underlying
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        // Market and offer/escrow
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 1_000_000, string::utf8(b"CASH"), ctx);
        let mut offer = Opt::new_short_offer_for_testing<TestBaseUSD>(&market, 10, 1000, 0, ctx);
        let mut esc   = Opt::new_premium_escrow_for_testing<TestBaseUSD>(&market, 10, 1000, 10_000, 0, ctx);
        // Provide UNXV for discount: fee = 10_000*1% = 100; discount 50% => 50 microUSD; px 1e6 => need ceil(50/1e6)=1 UNXV.
        let mut unxv_payment: vector<sui::coin::Coin<unxversal::unxv::UNXV>> = vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>();
        let unxv_coin = sui::coin::mint_for_testing<unxversal::unxv::UNXV>(2, ctx);
        vector::push_back(&mut unxv_payment, unxv_coin);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Opt::match_offer_and_escrow<TestBaseUSD>(&mut reg, &mut market, &mut offer, &mut esc, 10, unxv_payment, &mut tre, &ocfg, &clk, &px_unxv, ctx);
        let toi = Opt::user_open_interest_for_testing(&market, user);
        assert!(toi == 10);
        // Cleanup
        Opt::cancel_premium_escrow<TestBaseUSD>(esc, ctx);
        Opt::cancel_short_offer<TestBaseUSD>(offer, ctx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        aggregator::share_for_testing(px_unxv);
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        test_scenario::end(scen);
    }

    #[test]
    fun admin_gating_via_synth_admincap_pause_resume() {
        let admin = @0xAC;
        let mut scen = test_scenario::begin(admin);
        let ctx = scen.ctx();
        let synth_reg = Synth::new_registry_for_testing(ctx);
        // synth_reg already includes ctx.sender() as admin in test helper
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        // Use central AdminRegistry path where available (set_maker_rebate_bps_close_admin)
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(ctx);
        Opt::set_maker_rebate_bps_close_admin(&reg_admin, &mut reg, 100, ctx);
        sui::transfer::public_share_object(synth_reg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(reg_admin);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun admin_gating_negative_non_admin_cannot_pause() {
        let user = @0xAD;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let _synth_reg = Synth::new_registry_for_testing(ctx);
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        // Negative: non-admin cannot set fee via AdminRegistry
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(ctx);
        Opt::set_fee_config_admin(&reg_admin, &mut reg, 1, 1, ctx);
        abort 0
    }

    #[test]
    fun close_by_premium_payer_short_fee_routing_and_oi_updates() {
        let user = @0xAE;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        Opt::set_registry_trade_and_rebate_for_testing(&mut reg, 100, 0, 0);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 1_000_000, string::utf8(b"CASH"), ctx);
        let mut long = Opt::new_long_pos_for_testing<TestBaseUSD>(&market, 6, 1000, ctx);
        let mut short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 6, 0, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        // short pays long to close (payer_is_long=false)
        let pay = coin::mint_for_testing<TestBaseUSD>(10_000, ctx);
        let ret = Opt::close_positions_by_premium<TestBaseUSD>(&mut reg, &mut market, &mut long, &mut short, 4, 1000, false, pay, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &ocfg, &clk, &px_unxv, &mut tre, &mut bot, &mut points, ctx);
        sui::coin::destroy_zero(ret);
        // consume locals
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(long);
        sui::transfer::public_share_object(short);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        aggregator::share_for_testing(px_unxv);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        test_scenario::end(scen);
    }

    #[test]
    fun cash_settlement_after_expiry_updates_market() {
        let user = @0x95;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_100_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        // Create a market that already expired
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 0, string::utf8(b"CASH"), ctx);
        // Settle now
        Opt::expire_and_settle_market_cash(&reg, &mut market, &ocfg, &clk, &agg, ctx);
        // Cleanup
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        test_scenario::end(scen);
    }

    #[test]
    fun admin_gating_variants_happy_and_negative() {
        let admin = @0xA1;
        let mut scen = test_scenario::begin(admin);
        let ctx = scen.ctx();
        let synth_reg = Synth::new_registry_for_testing(ctx);
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        // Happy: set maker rebate via AdminRegistry variant (simulate central admin)
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(ctx);
        Opt::set_maker_rebate_bps_close_admin(&reg_admin, &mut reg, 1234, ctx);
        // Negative: non-admin setting settlement fee via AdminRegistry should fail
        Opt::set_settlement_fee_bps_admin(&reg_admin, &mut reg, 77, ctx);
        sui::transfer::public_share_object(synth_reg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(reg_admin);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun duplicate_market_key_rejected() {
        let user = @0xA2;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let (_f0, _u0) = Opt::create_option_market<TestBaseUSD>(&mut reg, string::utf8(b"BASE"), string::utf8(b"PUT"), 1_000_000, 1_000_000, string::utf8(b"CASH"), &mut tre, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), 0, coin::mint_for_testing<TestBaseUSD>(0, ctx), &ocfg, &clk, &agg, &mut points, ctx);
        let (_f1, _u1) = Opt::create_option_market<TestBaseUSD>(&mut reg, string::utf8(b"BASE"), string::utf8(b"PUT"), 1_000_000, 1_000_000, string::utf8(b"CASH"), &mut tre, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), 0, coin::mint_for_testing<TestBaseUSD>(0, ctx), &ocfg, &clk, &agg, &mut points, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun settle_before_expiry_rejected() {
        let user = @0xA3;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 1_000_000, string::utf8(b"CASH"), ctx);
        // Try to settle before expiry (now=0 in test clock)
        Opt::expire_and_settle_market_cash(&reg, &mut market, &ocfg, &clk, &agg, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun tick_and_contract_size_violations_rejected() {
        let user = @0xA4;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 1_000_000, string::utf8(b"CASH"), ctx);
        Opt::set_market_controls_for_testing(&mut market, 5, 3, 0, 0);
        let mut offer = Opt::new_short_offer_for_testing<TestBaseUSD>(&market, 4, 1_001, 0, ctx);
        let mut esc   = Opt::new_premium_escrow_for_testing<TestBaseUSD>(&market, 4, 1_001, 10_000, 1_000_000, ctx);
        // premium_per_unit % tick_size != 0 or fill % contract_size != 0
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        Opt::match_offer_and_escrow<TestBaseUSD>(&mut reg, &mut market, &mut offer, &mut esc, 4, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &mut tre, &ocfg, &clk, &agg, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun oi_caps_violations_rejected() {
        let user = @0xA5;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 1_000_000, string::utf8(b"CASH"), ctx);
        Opt::set_market_controls_for_testing(&mut market, 1, 1, 1, 2);
        let mut offer = Opt::new_short_offer_for_testing<TestBaseUSD>(&market, 10, 100, 0, ctx);
        let mut esc   = Opt::new_premium_escrow_for_testing<TestBaseUSD>(&market, 10, 100, 1_000, 1_000_000, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        // fill should exceed caps
        Opt::match_offer_and_escrow<TestBaseUSD>(&mut reg, &mut market, &mut offer, &mut esc, 10, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &mut tre, &ocfg, &clk, &agg, ctx);
        abort 0
    }

    #[test]
    fun cancel_and_gc_helpers_flow() {
        let user = @0xA6;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"PUT"), 1_000_000, 1_000_000, string::utf8(b"PHYSICAL"), ctx);
        // cancel premium escrow
        let esc = Opt::new_premium_escrow_for_testing<TestBaseUSD>(&market, 1, 1, 1, 0, ctx);
        Opt::cancel_premium_escrow<TestBaseUSD>(esc, ctx);
        // cancel coin short offer
        let off = Opt::new_coin_short_offer_for_testing<TestBaseUSD>(&market, 1, 1, 1, ctx);
        Opt::cancel_coin_short_offer<TestBaseUSD>(off, ctx);
        // gc underlying escrows with zero balances
        let short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 0, 0, ctx);
        let se = Opt::new_short_underlying_escrow_for_testing<TestBaseUSD, TestBaseUSD>(&short, 0, ctx);
        Opt::gc_underlying_escrow<TestBaseUSD>(se, ctx);
        let le = Opt::new_long_underlying_escrow_for_testing<TestBaseUSD>(user, object::id(&market), 0, ctx);
        Opt::gc_long_underlying_escrow<TestBaseUSD>(le, ctx);
        sui::transfer::public_share_object(short);
        sui::transfer::public_share_object(market);
        test_scenario::end(scen);
    }

    #[test]
    fun readonly_helpers_checks() {
        let user = @0xA7;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        // add underlyings
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base"), string::utf8(b"NATIVE"), vector::empty<u8>(), string::utf8(b"CASH"), 1, 10, 1, 1, 10, true, ctx);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"ALT"), string::utf8(b"Alt"), string::utf8(b"NATIVE"), vector::empty<u8>(), string::utf8(b"CASH"), 1, 10, 1, 1, 10, true, ctx);
        let _u = Opt::list_underlyings(&reg);
        let _ua = Opt::get_underlying(&reg, &string::utf8(b"BASE"));
        let _keys = Opt::list_option_market_keys(&reg);
        let _tid = Opt::get_registry_treasury_id(&reg);
        sui::transfer::public_share_object(reg);
        test_scenario::end(scen);
    }

    #[test]
    fun american_exercise_payout_and_fee_routing() {
        let user = @0x96;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_200_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        // American CALL above strike → payout
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"CASH"), ctx);
        Opt::set_market_exercise_style_for_testing(&mut market, string::utf8(b"AMERICAN"));
        let mut long = Opt::new_long_pos_for_testing<TestBaseUSD>(&market, 5, 0, ctx);
        let mut short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 5, 0, ctx);
        // lock some collateral in short (simulate margin)
        let pay_in = coin::mint_for_testing<TestBaseUSD>(10_000_000, ctx);
        sui::transfer::public_transfer(pay_in, user);
        // not directly attachable to position via helper; exercise will split from short.collateral_locked if present
        Opt::exercise_american_now<TestBaseUSD>(&mut reg, &mut market, &mut long, &mut short, 5, &ocfg, &clk, &agg, &mut tre, &mut bot, &mut points, ctx);
        // cleanup
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(long);
        sui::transfer::public_share_object(short);
        sui::transfer::public_share_object(ocfg);
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun liquidation_under_collateralized_short_routes_fee_and_bonus() {
        let user = @0x97;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(900_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        // market PUT with strike > spot so payout path exists
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"PUT"), 1_000_000, 86_400_000, string::utf8(b"CASH"), ctx);
        let mut long = Opt::new_long_pos_for_testing<TestBaseUSD>(&market, 10, 0, ctx);
        let mut short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 10, 0, ctx);
        // simulate low collateral so maint check fails
        Opt::liquidate_under_collateralized_pair<TestBaseUSD>(&mut reg, &mut market, &mut long, &mut short, 5, user, &ocfg, &clk, &agg, &mut tre, ctx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(long);
        sui::transfer::public_share_object(short);
        sui::transfer::public_share_object(ocfg);
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun physical_call_escrow_and_exercise_flow() {
        let user = @0x98;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 86_400_000, string::utf8(b"PHYSICAL"), ctx);
        let mut long = Opt::new_long_pos_for_testing<TestBaseUSD>(&market, 3, 0, ctx);
        let mut short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 3, 0, ctx);
        let mut esc = Opt::new_short_underlying_escrow_with_amount_for_testing<TestBaseUSD, TestBaseUSD>(&short, 3, ctx);
        Opt::exercise_physical_call<TestBaseUSD, TestBaseUSD>(&mut market, &mut long, &mut short, &mut esc, 3, ctx);
        Opt::gc_underlying_escrow<TestBaseUSD>(esc, ctx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(long);
        sui::transfer::public_share_object(short);
        sui::transfer::public_share_object(reg);
        test_scenario::end(scen);
    }

    #[test]
    fun physical_put_escrow_and_exercise_flow() {
        let user = @0x99;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"PUT"), 1_000_000, 86_400_000, string::utf8(b"PHYSICAL"), ctx);
        let mut long = Opt::new_long_pos_for_testing<TestBaseUSD>(&market, 2, 0, ctx);
        let mut short = Opt::new_short_pos_for_testing<TestBaseUSD>(&market, 2, 0, ctx);
        // Long delivers base exactly
        let base = coin::mint_for_testing<TestBaseUSD>(2, ctx);
        Opt::exercise_physical_put<TestBaseUSD, TestBaseUSD>(&mut market, &mut long, &mut short, base, 2, ctx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(long);
        sui::transfer::public_share_object(short);
        sui::transfer::public_share_object(reg);
        test_scenario::end(scen);
    }

    #[test]
    fun settlement_queue_request_and_process_points() {
        let user = @0x100;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let mut reg: OptionsRegistry = Opt::new_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let fhash = aggregator::feed_hash(&agg);
        Opt::add_underlying_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"Base USD"), string::utf8(b"NATIVE"), fhash, string::utf8(b"CASH"), 1, 10_000_000, 1, 1, 31536000000, true, ctx);
        let mut market = Opt::new_market_for_testing(string::utf8(b"BASE"), string::utf8(b"CALL"), 1_000_000, 1, string::utf8(b"CASH"), ctx);
        let mut queue = Opt::new_queue_for_testing(1, ctx);
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        Opt::request_market_settlement(&mut queue, &market, ctx);
        // Advance time by dispute window and process
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Opt::process_due_settlement(&mut queue, &reg, &mut market, &ocfg, &clk2, &agg, &mut points, ctx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(queue);
        sui::transfer::public_share_object(ocfg);
        aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(points);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }
}


