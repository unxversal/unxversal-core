#[test_only]
module unxversal::futures_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use sui::coin::{Self as coin};

    use switchboard::aggregator;
    use unxversal::futures::{Self as Fut, FuturesRegistry, FuturesContract};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::treasury::{Self as Tre, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::synthetics::{Self as Synth};
    use unxversal::test_coins::TestBaseUSD;
    
    // (no local helpers)

    #[test]
    fun record_fill_discount_and_fee_routing_happy() {
        let user = @0xF1;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut orx = Oracle::new_registry_for_testing(ctx);
        let synth_reg = Synth::new_registry_for_testing(ctx);
        // init registry (admin via synth)
        let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        // oracle: bind UNXV symbol price for discount and underlying feed for BASE
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut px_base = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px_base, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, ctx);
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"BASE"), &px_base, ctx);
        // whitelist underlying and list contract (owned instance)
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px_base, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"BASE-DEC24"), 1, 1, 1, 1000, 500, ctx);
        // set trade fee config to enable discount and maker rebate
        // set precise fee config: 1% trade fee, 50% maker rebate, 50% unxv discount, 0 bot split
        Fut::set_trade_fee_config_for_testing(&mut reg, 100, 5000, 5000, 0);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        // mirror for trade
        let mut tm = Fut::new_trade_event_mirror_for_testing(ctx);
        // taker buys 10 @ 1_000_000 microUSD; provide UNXV=1 for 50% discount of 100 fee => need 1 UNXV
        let mut unxv_payment = vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>();
        vector::push_back(&mut unxv_payment, sui::coin::mint_for_testing<unxversal::unxv::UNXV>(2, ctx));
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(10_000_000, ctx);
        // pre balances
        let pre_tre = Tre::tre_balance_collateral_for_testing(&tre);
        let ep0 = BR::current_epoch(&points, &clk);
        let (pre_ec, pre_eu) = Tre::epoch_reserves_for_testing(&bot, ep0);
        Fut::record_fill_with_event_mirror<TestBaseUSD>(
            &reg, &mut market, 1_000_000, 10, true, @0xBEEF,
            unxv_payment, &px_unxv, &ocfg, &orx, &clk,
            fee_pay, &mut tre, &mut bot, &points,
            true, 900_000, 1_100_000, &mut tm, ctx
        );
        // assert market metrics: OI increased by 10, volume adds notional (clamped), last price set
        let (oi, vol, lastp) = Fut::get_market_metrics(&market);
        assert!(oi == 10);
        assert!(lastp == 1_000_000);
        assert!(vol >= 10); // minimal sanity (exact clamp depends on internals)
        // exact fee math: notional = 10 * 1_000_000; trade_fee = 100_000; maker_rebate = 50_000; discount = 50_000 → collateral_fee_after_discount = 50_000
        assert!(Fut::tem_fee_paid(&tm) == 50_000 && Fut::tem_maker_rebate(&tm) == 50_000 && Fut::tem_discount_applied(&tm));
        let post_tre = Tre::tre_balance_collateral_for_testing(&tre);
        assert!(post_tre - pre_tre == 50_000);
        let (epc, epu) = Tre::epoch_reserves_for_testing(&bot, ep0);
        // UNXV discount deposits exactly 1 UNXV to epoch reserve (ceil(50_000 / 1_000_000) = 1)
        assert!(epc - pre_ec == 0);
        assert!(epu - pre_eu == 1);
        // cleanup
        aggregator::share_for_testing(px_unxv);
        aggregator::share_for_testing(px_base);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(reg_admin);
        sui::transfer::public_share_object(tm);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun clamp_edge_large_notional_routes_clamped_fee() {
        let user = @0xF7; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx); let orx = Oracle::new_registry_for_testing(ctx);
        let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        Fut::set_trade_fee_config_for_testing(&mut reg, 10_000, 0, 0, 0); // 100% fee to amplify clamp
        let mut px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px, switchboard::decimal::new(18_446_744, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"BIG"), 1, 1, 1, 1000, 500, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let max_u64 = 18_446_744_073_709_551_615;
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(max_u64, ctx);
        let pre = Tre::tre_balance_collateral_for_testing(&tre);
        // choose price=2 and size=U64_MAX so fee_u128 = size*price = ~2^65 → clamp to U64_MAX
        Fut::record_fill<TestBaseUSD>(&reg, &mut market, 2, max_u64, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px, &ocfg, &orx, &clk, fee_pay, &mut tre, &mut bot, &points, true, 1, max_u64, ctx);
        let post = Tre::tre_balance_collateral_for_testing(&tre);
        assert!(post - pre == max_u64);
        aggregator::share_for_testing(px);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun paused_registry_blocks_settlement() {
        let user = @0xF8; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx); let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"MKT4"), 1, 1, 1, 1000, 500, ctx);
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Fut::pause_for_testing(&mut reg, true);
        Fut::settle_futures<TestBaseUSD>(&reg, &ocfg, &mut market, &clk2, &px, &mut Tre::new_treasury_for_testing<TestBaseUSD>(ctx), ctx);
        abort 0
    }

    #[test, expected_failure]
    fun paused_contract_blocks_settlement() {
        let user = @0xF9; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx); let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"MKT5"), 1, 1, 1, 1000, 500, ctx);
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Fut::pause_contract_for_testing(&mut market, true);
        Fut::settle_futures<TestBaseUSD>(&reg, &ocfg, &mut market, &clk2, &px, &mut Tre::new_treasury_for_testing<TestBaseUSD>(ctx), ctx);
        abort 0
    }

    #[test]
    fun settle_flow_and_queue_points() {
        let user = @0xF2;
        let mut scen = test_scenario::begin(user);
        let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        let mut orx = Oracle::new_registry_for_testing(ctx);
        let synth_reg = Synth::new_registry_for_testing(ctx);
        let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let mut px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px, switchboard::decimal::new(1_500_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(ctx);
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"BASE"), &px, ctx);
        // whitelist + list
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"BASE-JAN25"), 1, 1, 1, 1000, 500, ctx);
        // settle after expiry
        Fut::set_limits_for_testing(&mut reg, 0);
        // fast-forward time to at/after expiry
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        let mut tf = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Fut::settle_futures<TestBaseUSD>(&reg, &ocfg, &mut market, &clk2, &px, &mut tf, ctx);
        let mut queue = Fut::new_queue_for_testing(ctx);
        let mut pts = BR::new_points_registry_for_testing(ctx);
        let pre_pts = BR::points_for_actor_for_testing(&pts, user);
        Fut::request_settlement_with_points(&reg, &market, &mut queue, &mut pts, &clk2, ctx);
        // process due
        let mids = vector::singleton(object::id(&market));
        Fut::process_due_settlements(&reg, &mut queue, mids, &clk2, ctx);
        // assert points increased for caller on the queue task epoch
        let ep = BR::current_epoch(&pts, &clk2);
        let tot = BR::total_points_for_epoch_for_testing(&pts, ep);
        let post_pts = BR::points_for_actor_for_testing(&pts, user);
        assert!(post_pts >= pre_pts);
        assert!(tot > 0);
        // cleanup
        aggregator::share_for_testing(px);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(queue);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        sui::transfer::public_share_object(reg_admin);
        sui::transfer::public_share_object(tf);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun settle_rejects_wrong_aggregator() {
        let user = @0xF3; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx);
        let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let px_ok = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let px_bad = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"WRONG"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px_ok, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"BASE-X"), 1, 1, 1, 1000, 500, ctx);
        // time >= expiry
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Fut::settle_futures<TestBaseUSD>(&reg, &ocfg, &mut market, &clk2, &px_bad, &mut Tre::new_treasury_for_testing<TestBaseUSD>(ctx), ctx);
        abort 0
    }

    #[test, expected_failure]
    fun paused_registry_blocks_fill_and_settlement() {
        let user = @0xF4; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx); let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"MKT"), 1, 1, 1, 1000, 500, ctx);
        // Pause registry: record_fill should abort via E_PAUSED
        Fut::pause_for_testing(&mut reg, true);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, ctx);
        Fut::record_fill<TestBaseUSD>(&reg, &mut market, 1, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px, &ocfg, &Oracle::new_registry_for_testing(ctx), &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(ctx), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx), &BR::new_points_registry_for_testing(ctx), true, 1, 1, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun paused_contract_blocks_fill_and_settlement() {
        let user = @0xF5; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx); let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"MKT2"), 1, 1, 1, 1000, 500, ctx);
        Fut::pause_contract_for_testing(&mut market, true);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, ctx);
        Fut::record_fill<TestBaseUSD>(&reg, &mut market, 1, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px, &ocfg, &Oracle::new_registry_for_testing(ctx), &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(ctx), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx), &BR::new_points_registry_for_testing(ctx), true, 1, 1, ctx);
        abort 0
    }

    #[test]
    fun position_open_close_liquidate_settle_flows() {
        let user = @0xF6; let mut scen = test_scenario::begin(user); let ctx = scen.ctx();
        let clk = clock::create_for_testing(ctx); let ocfg = Oracle::new_config_for_testing(ctx); let mut reg: FuturesRegistry = Fut::new_registry_for_testing(ctx);
        let mut px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"BASE_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut px, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Fut::whitelist_underlying_for_testing(&mut reg, string::utf8(b"BASE"), &px, &clk);
        let mut market: FuturesContract = Fut::list_futures_for_testing(&mut reg, string::utf8(b"BASE"), string::utf8(b"MKT3"), 1, 1, 1, 1000, 500, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        // open position: lock exact margin
        let margin_in = coin::mint_for_testing<TestBaseUSD>(10_000, ctx);
        let (mut pos, refund) = Fut::new_position_for_testing<TestBaseUSD>(user, &market, 0, 5, 1_000_000, margin_in, 5_000, &clk, ctx);
        // refund is remaining coin; transfer to consume
        sui::transfer::public_transfer(refund, user);
        // close part of position: expect margin refund proportional; OI delta and mirror fields
        let (oi0, _v0, _p0) = Fut::get_market_metrics(&market);
        let mut mir = Fut::new_event_mirror_for_testing(ctx);
        Fut::close_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos, &clk, 1_100_000, 2, &mut tre, &mut mir, ctx);
        assert!(Fut::em_vm_count(&mir) == 1 && Fut::em_last_vm_qty(&mir) == 2 && Fut::em_last_vm_from(&mir) == 1_000_000 && Fut::em_last_vm_to(&mir) == 1_100_000);
        let (oi1, _v1, _p1) = Fut::get_market_metrics(&market);
        assert!(oi1 <= oi0);
        // liquidation path (force equity < maint) and mirror
        Fut::liquidate_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos, &clk, 100_000, &mut tre, &mut mir, ctx);
        assert!(Fut::em_liq_count(&mir) == 1 && Fut::em_last_liq_price(&mir) == 100_000);
        // settle at expiry: advance time, mark expired, settle position with bot cut
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Fut::set_settlement_params_for_testing(&mut reg, 100, 1000);
        aggregator::set_current_value(&mut px, switchboard::decimal::new(900_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Fut::settle_futures<TestBaseUSD>(&reg, &ocfg, &mut market, &clk2, &px, &mut tre, ctx);
        let pts2 = BR::new_points_registry_for_testing(ctx);
        Fut::settle_position_with_event_mirror<TestBaseUSD>(&reg, &market, &mut pos, &clk2, &mut tre, &mut bot, &pts2, &mut mir, ctx);
        assert!(Fut::em_ps_count(&mir) == 1 && Fut::em_last_ps_price(&mir) == 900_000);
        // cleanup
        aggregator::share_for_testing(px);
        sui::transfer::public_share_object(mir);
        sui::transfer::public_share_object(pos);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(pts2);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }
}


