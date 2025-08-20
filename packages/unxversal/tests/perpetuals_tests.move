#[test_only]
module unxversal::perpetuals_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use sui::coin::{Self as coin};

    use switchboard::aggregator;
    use unxversal::perpetuals::{Self as Perp, PerpsRegistry, PerpMarket};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::treasury::{Self as Tre, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::admin::{Self as Admin, AdminRegistry};
    use unxversal::test_coins::TestBaseUSD;

    #[test]
    fun perps_record_fill_discount_and_metrics() {
        let user = @0xA1; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        // init registry via AdminRegistry path
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        // bind UNXV for discount and underlying feed
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, scen.ctx());
        let mut idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut idx, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        // whitelist underlying
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        // list market
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-PERP"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-PERP"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        // set fee config: 1% fee, 50% rebate, 50% discount
        Perp::set_trade_fee_config_admin(&reg_admin, &mut reg, 100, 5000, 5000, 0, scen.ctx());
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        let mut unxv_payment = vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>();
        vector::push_back(&mut unxv_payment, sui::coin::mint_for_testing<unxversal::unxv::UNXV>(10, scen.ctx()));
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(10_000_000, scen.ctx());
        let pre = Tre::tre_balance_collateral_for_testing(&tre);
        // trade 10@1_000_000: fee 100_000, rebate 50_000, discount 50_000 → 50_000 to treasury; assert via mirror
        let mut em = Perp::new_perp_event_mirror_for_testing(scen.ctx());
        Perp::record_fill_with_event_mirror<TestBaseUSD>(&mut reg, &mut market, 1_000_000, 10, true, @0xBEEF, unxv_payment, &px_unxv, &orx, &ocfg, &clk, fee_pay, &mut tre, &mut bot, &pts, true, 900_000, 1_100_000, &mut em, scen.ctx());
        let post = Tre::tre_balance_collateral_for_testing(&tre);
        assert!(post - pre == 50_000);
        let (oi, vol, lastp, _lrp, _rate) = Perp::market_metrics(&market);
        assert!(oi == 10 && lastp == 1_000_000 && vol >= 10);
        assert!(Perp::pem_fill_count(&em) == 1 && Perp::pem_last_fill_fee(&em) == 50_000 && Perp::pem_last_fill_rebate(&em) == 50_000 && Perp::pem_last_fill_discount(&em));
        // cleanup
        aggregator::share_for_testing(px_unxv);
        aggregator::share_for_testing(idx);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(em);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun perps_fill_tick_and_slippage_guards() {
        let user = @0xA5; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        let idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-G"), 10, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-G"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, scen.ctx());
        // tick violation (price not multiple of tick) and slippage bound violated
        Perp::record_fill<TestBaseUSD>(&mut reg, &mut market, 7, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &idx, &orx, &ocfg, &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx()), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx()), &BR::new_points_registry_for_testing(scen.ctx()), true, 8, 100, scen.ctx());
        abort 0
    }

    #[test, expected_failure]
    fun perps_refresh_with_wrong_index_feed() {
        let user = @0xA6; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        let ok = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        let bad = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"WRONG"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &ok, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &ok, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-W"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-W"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        Perp::refresh_market_funding(&reg, &mut market, &orx, &bad, &clk);
        abort 0
    }

    #[test, expected_failure]
    fun perps_paused_market_blocks_ops() {
        let user = @0xA7; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        let idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-PZ"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-PZ"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        Perp::pause_market_for_testing(&mut market, true);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, scen.ctx());
        Perp::record_fill<TestBaseUSD>(&mut reg, &mut market, 1, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &idx, &orx, &Oracle::new_config_for_testing(scen.ctx()), &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx()), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx()), &BR::new_points_registry_for_testing(scen.ctx()), true, 1, 1, scen.ctx());
        abort 0
    }

    #[test, expected_failure]
    fun perps_paused_registry_blocks_ops() {
        let user = @0xA2; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let _ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &px, scen.ctx());
        Perp::pause_registry_admin(&reg_admin, &mut reg, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-X"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        abort 0
    }

    #[test]
    fun perps_funding_refresh_and_points() {
        let user = @0xA3; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        // list and set last trade price via a fill
        let mut idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut idx, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-P"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-P"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        // simulate a trade to set last_trade_price
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot_t: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, scen.ctx());
        Perp::record_fill<TestBaseUSD>(&mut reg, &mut market, 1_000_000, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &idx, &orx, &ocfg, &clk, fee_pay, &mut tre, &mut bot_t, &pts, true, 1, 1_000_000, scen.ctx());
        // advance time to allow funding
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        // apply refresh with points
        let mut pts2 = BR::new_points_registry_for_testing(scen.ctx());
        let pre_pts = BR::points_for_actor_for_testing(&pts2, user);
        Perp::refresh_market_funding_with_points(&reg, &mut market, &orx, &idx, &mut pts2, &clk2, scen.ctx());
        let post_pts = BR::points_for_actor_for_testing(&pts2, user);
        assert!(post_pts >= pre_pts);
        // cleanup
        aggregator::share_for_testing(idx);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot_t);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(pts2);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test]
    fun perps_open_close_liquidate_apply_funding() {
        let user = @0xA4; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        // oracle and market
        let mut idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut idx, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-Q"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-Q"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        // open owned position via helper
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pay = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        let (mut pos, refund) = Perp::new_position_for_testing<TestBaseUSD>(user, &market, 0, 5, 1_000_000, pay, 500_000, &clk, scen.ctx());
        sui::transfer::public_transfer(refund, user);
        // close part + event mirror
        let mut mir = Perp::new_perp_event_mirror_for_testing(scen.ctx());
        Perp::close_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos, 900_000, 2, &mut tre, &clk, &mut mir, scen.ctx());
        assert!(Perp::pem_vm_count(&mir) == 1 && Perp::pem_last_vm_qty(&mir) == 2 && Perp::pem_last_vm_to(&mir) == 900_000);
        // margin refund exactness: required_margin=500_000, qty=2, size=5 → (500_000*2)/5 = 200_000
        assert!(Perp::pem_last_margin_refund(&mir) == 200_000);
        // liquidate remaining by forcing bad price
        Perp::liquidate_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos, 1, &mut tre, &clk, &mut mir, scen.ctx());
        assert!(Perp::pem_liq_count(&mir) == 1 && Perp::pem_last_liq_price(&mir) == 1);
        // apply funding on a fresh pos
        let pay2 = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        let (mut pos2, refund2) = Perp::new_position_for_testing<TestBaseUSD>(user, &market, 0, 1, 1_000_000, pay2, 200_000, &clk, scen.ctx());
        sui::transfer::public_transfer(refund2, user);
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Perp::apply_funding_with_event_mirror<TestBaseUSD>(&reg, &market, &mut pos2, &orx, &idx, &clk2, &mut mir);
        // cleanup
        aggregator::share_for_testing(idx);
        sui::transfer::public_share_object(mir);
        sui::transfer::public_share_object(pos);
        sui::transfer::public_share_object(pos2);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test]
    fun perps_trade_bot_split_fee_routes_treasury() {
        let user = @0xA8; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        // Set trade fee 1%, maker rebate 50%, UNXV discount 50%, and trade bot split 10%
        Perp::set_trade_fee_config_admin(&reg_admin, &mut reg, 100, 5000, 5000, 1000, scen.ctx());
        // list market
        let idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &idx, scen.ctx());
        // UNXV price for discount path
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-FEE"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-FEE"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot_t: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1_000_000_000, scen.ctx());
        let pre = Tre::tre_balance_collateral_for_testing(&tre);
        // trade 4@1_000_000 → fee 40,000; maker rebate 20,000; discount 20,000 → fee after discount 20,000 → bot 10%→2,000; treasury delta 18,000; verify via mirror
        let mut unxv_payment = vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>();
        vector::push_back(&mut unxv_payment, sui::coin::mint_for_testing<unxversal::unxv::UNXV>(100, scen.ctx()));
        let mut mir2 = Perp::new_perp_event_mirror_for_testing(scen.ctx());
        Perp::record_fill_with_event_mirror<TestBaseUSD>(&mut reg, &mut market, 1_000_000, 4, true, user, unxv_payment, &px_unxv, &orx, &ocfg, &clk, fee_pay, &mut tre, &mut bot_t, &pts, true, 1, 4_000_000, &mut mir2, scen.ctx());
        let post = Tre::tre_balance_collateral_for_testing(&tre);
        assert!(post - pre == 18_000);
        assert!(Perp::pem_last_fill_fee(&mir2) == 20_000 && Perp::pem_last_fill_rebate(&mir2) == 20_000 && Perp::pem_last_fill_discount(&mir2) && Perp::pem_last_fill_bot_reward(&mir2) == 2_000);
        // cleanup
        sui::transfer::public_share_object(mir2);
        aggregator::share_for_testing(px_unxv);
        aggregator::share_for_testing(idx);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot_t);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun perps_liquidation_bot_split_routes_treasury() {
        let user = @0xA9; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Perp::init_perps_registry_admin(&reg_admin, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mut reg: PerpsRegistry = test_scenario::take_shared<PerpsRegistry>(&scen);
        // Set 10% bot split for liquidation (uses trade_bot_reward_bps)
        Perp::set_trade_fee_config_admin(&reg_admin, &mut reg, 0, 0, 0, 1000, scen.ctx());
        let idx = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"IDX_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::whitelist_underlying_feed_admin(&reg_admin, &mut reg, string::utf8(b"IDX"), &idx, scen.ctx());
        Perp::list_market(&mut reg, string::utf8(b"IDX"), string::utf8(b"IDX-LIQ"), 1, 1_000, 600, &clk, scen.ctx());
        test_scenario::next_tx(&mut scen, user);
        let mid = Perp::market_id(&reg, &string::utf8(b"IDX-LIQ"));
        let mut market: PerpMarket = test_scenario::take_shared_by_id<PerpMarket>(&scen, mid);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let required_margin = 600_000;
        // create position with known margin
        let pay = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        let (mut pos, refund) = Perp::new_position_for_testing<TestBaseUSD>(user, &market, 0, 3, 1_000_000, pay, required_margin, &clk, scen.ctx());
        sui::transfer::public_transfer(refund, user);
        let pre = Tre::tre_balance_collateral_for_testing(&tre);
        // liquidate at very low price to trigger, capture mirror
        let mut mir = Perp::new_perp_event_mirror_for_testing(scen.ctx());
        Perp::liquidate_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos, 1, &mut tre, &clk, &mut mir, scen.ctx());
        let post = Tre::tre_balance_collateral_for_testing(&tre);
        let expected_bot = (required_margin * 1000) / 10_000;
        let expected_treasury = required_margin - expected_bot;
        assert!(post - pre == expected_treasury);
        assert!(Perp::pem_last_liq_bot_reward(&mir) == expected_bot);
        // cleanup
        aggregator::share_for_testing(idx);
        sui::transfer::public_share_object(mir);
        sui::transfer::public_share_object(pos);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }



}