#[test_only]
module unxversal::gas_futures_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use sui::coin::{Self as coin};

    use switchboard::aggregator;
    use unxversal::gas_futures::{Self as Gas, GasFuturesRegistry, GasFuturesContract};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::treasury::{Self as Tre, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::synthetics::{Self as Synth};
    use unxversal::test_coins::TestBaseUSD;


    #[test]
    fun gas_record_fill_fee_routing_and_metrics() {
        let user = @0xF1; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        // Init registry (gated by Synth admin)
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        // Price feeds
        let mut px_sui = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_sui, switchboard::decimal::new(2_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"SUI"), &px_sui, scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, scen.ctx());
        // List market: contract_size=1, tick=1, expiry soon
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-DEC24"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-DEC24"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let points: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        // No UNXV discount configured by default in gas_futures; provide empty UNXV payment
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(10_000_000, scen.ctx());
        let pre = Tre::tre_balance_collateral_for_testing(&tre);
        Gas::record_gas_fill<TestBaseUSD>(&reg, &mut market, 1_000_000, 10, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px_sui, &px_unxv, &orx, &ocfg, &clk, fee_pay, &mut tre, &mut bot, &points, true, 1, 2_000_000, scen.ctx());
        let post = Tre::tre_balance_collateral_for_testing(&tre);
        // trade_fee_bps=30 (0.3%), no discount, no bot split => treasury gains 0.003 * (10 * 1 * 1_000_000) = 30_000
        assert!(post - pre == 30_000);
        let (oi, vol, lastp) = Gas::gas_market_metrics(&market);
        assert!(oi == 10 && lastp == 1_000_000 && vol >= 10);
        // cleanup
        aggregator::share_for_testing(px_sui);
        aggregator::share_for_testing(px_unxv);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(reg_admin);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun gas_discount_and_maker_rebate_flow() {
        let user = @0xF4; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        // enable 1% fee, 50% rebate, 50% UNXV discount
        Gas::set_trade_fee_config_for_testing(&mut reg, 100, 5000, 5000, 0);
        // Oracles
        let mut px_sui = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_sui, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"SUI"), &px_sui, scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, scen.ctx());
        // list
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-DISC"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-DISC"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        // provide UNXV payment to cover 50% discount of trade fee
        let mut unxv_payment = vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>();
        vector::push_back(&mut unxv_payment, sui::coin::mint_for_testing<unxversal::unxv::UNXV>(10, scen.ctx()));
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(10_000_000, scen.ctx());
        let pre = Tre::tre_balance_collateral_for_testing(&tre);
        let (pre_ec, pre_eu) = Tre::epoch_reserves_for_testing(&bot, BR::current_epoch(&pts, &clk));
        // notional = 10 * 1 * 1_000_000; fee=100_000; maker_rebate=50_000; discount=50_000; fee_to_treasury=50_000
        Gas::record_gas_fill<TestBaseUSD>(&reg, &mut market, 1_000_000, 10, true, @0xBEEF, unxv_payment, &px_sui, &px_unxv, &orx, &ocfg, &clk, fee_pay, &mut tre, &mut bot, &pts, true, 900_000, 1_100_000, scen.ctx());
        let post = Tre::tre_balance_collateral_for_testing(&tre);
        assert!(post - pre == 50_000);
        let (epc, epu) = Tre::epoch_reserves_for_testing(&bot, BR::current_epoch(&pts, &clk));
        assert!(epc - pre_ec == 0 && epu - pre_eu >= 1);
        // cleanup
        aggregator::share_for_testing(px_sui);
        aggregator::share_for_testing(px_unxv);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(admin);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun gas_settle_rejects_wrong_aggregator() {
        let user = @0xF5; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        let px_ok = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        let px_bad = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"WRONG"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        let admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"SUI"), &px_ok, scen.ctx());
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-X"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-X"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Gas::settle_gas_futures(&reg, &mut market, &orx, &ocfg, &clk2, &px_bad, scen.ctx());
        abort 0
    }

    #[test, expected_failure]
    fun gas_paused_registry_blocks_ops() {
        let user = @0xF6; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        let admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"SUI"), &px, scen.ctx());
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-P"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-P"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        Gas::pause_for_testing(&mut reg, true);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, scen.ctx());
        Gas::record_gas_fill<TestBaseUSD>(&reg, &mut market, 1, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px, &px, &orx, &ocfg, &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx()), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx()), &BR::new_points_registry_for_testing(scen.ctx()), true, 1, 1, scen.ctx());
        abort 0
    }

    #[test, expected_failure]
    fun gas_paused_contract_blocks_ops() {
        let user = @0xF7; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        let px = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        let admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"SUI"), &px, scen.ctx());
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-P2"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-P2"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        Gas::pause_contract_for_testing(&mut market, true);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, scen.ctx());
        Gas::record_gas_fill<TestBaseUSD>(&reg, &mut market, 1, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px, &px, &orx, &ocfg, &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx()), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx()), &BR::new_points_registry_for_testing(scen.ctx()), true, 1, 1, scen.ctx());
        abort 0
    }

    #[test, expected_failure]
    fun gas_tick_and_slippage_guards() {
        let user = @0xF8; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        let mut px_sui = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_sui, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"SUI"), &px_sui, scen.ctx());
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-TICK"), 1, 10, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-TICK"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        let fee_pay = coin::mint_for_testing<TestBaseUSD>(1, scen.ctx());
        Gas::record_gas_fill<TestBaseUSD>(&reg, &mut market, 7, 1, true, user, vector::empty<sui::coin::Coin<unxversal::unxv::UNXV>>(), &px_sui, &px_sui, &orx, &ocfg, &clk, fee_pay, &mut Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx()), &mut Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx()), &BR::new_points_registry_for_testing(scen.ctx()), true, 1, 100, scen.ctx());
        abort 0
    }
    #[test]
    fun gas_settle_and_queue_points() {
        let user = @0xF2; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        let mut px_sui = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_sui, switchboard::decimal::new(2_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"SUI"), &px_sui, scen.ctx());
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-JAN25"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-JAN25"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        // advance time to expiry and settle
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Gas::settle_gas_futures(&reg, &mut market, &orx, &ocfg, &clk2, &px_sui, scen.ctx());
        // queue + points
        Gas::init_gas_settlement_queue(scen.ctx());
        let mut q: Gas::GasSettlementQueue = test_scenario::take_shared<Gas::GasSettlementQueue>(&scen);
        let mut pts = BR::new_points_registry_for_testing(scen.ctx());
        Gas::request_gas_settlement_with_points(&reg, &market, &mut q, &mut pts, &clk2, scen.ctx());
        let mids = vector::singleton(object::id(&market));
        Gas::process_due_gas_settlements(&reg, &mut q, mids, &clk2, scen.ctx());
        // assert points
        let ep = BR::current_epoch(&pts, &clk2);
        let tot = BR::total_points_for_epoch_for_testing(&pts, ep);
        assert!(tot > 0);
        // cleanup
        aggregator::share_for_testing(px_sui);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(q);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(reg_admin);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test]
    fun gas_open_close_liquidate_and_settle_position() {
        let user = @0xF3; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        let mut px_sui = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_sui, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let reg_admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"SUI"), &px_sui, scen.ctx());
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-MAR25"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-MAR25"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        // open position using helper
        let pay = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        let (mut pos, refund) = Gas::new_position_for_testing<TestBaseUSD>(user, &market, 0, 5, 1_000_000, pay, 500_000, &clk, scen.ctx());
        sui::transfer::public_transfer(refund, user);
        // close part with mirror
        let mut gem = Gas::new_gas_event_mirror_for_testing(scen.ctx());
        Gas::close_gas_position_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos, &clk, 900_000, 2, &mut tre, &mut bot, &pts, &mut gem, scen.ctx());
        assert!(Gas::gem_vm_count(&gem) == 1 && Gas::gem_last_vm_qty(&gem) == 2 && Gas::gem_last_vm_to(&gem) == 900_000);
        // liquidation path on a new position
        let pay2 = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        let (mut pos2, refund2) = Gas::new_position_for_testing<TestBaseUSD>(user, &market, 0, 3, 1_000_000, pay2, 300_000, &clk, scen.ctx());
        sui::transfer::public_transfer(refund2, user);
        Gas::liquidate_gas_position_with_event_mirror<TestBaseUSD>(&reg, &mut market, &mut pos2, &clk, 1, &mut tre, &mut gem, scen.ctx());
        assert!(Gas::gem_liq_count(&gem) == 1 && Gas::gem_last_liq_price(&gem) == 1);
        // settle futures and position with mirror
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 2);
        Gas::settle_gas_futures_with_event_mirror(&reg, &mut market, &orx, &ocfg, &clk2, &px_sui, &mut gem, scen.ctx());
        assert!(Gas::gem_settle_count(&gem) == 1 && Gas::gem_last_settle_price(&gem) > 0);
        Gas::settle_gas_position<TestBaseUSD>(&reg, &market, &mut pos2, &clk2, &mut tre, &mut bot, &pts, scen.ctx());
        // cleanup
        aggregator::share_for_testing(px_sui);
        sui::transfer::public_share_object(gem);
        sui::transfer::public_share_object(pos);
        sui::transfer::public_share_object(pos2);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test]
    fun gas_settlement_bot_split_close_fee_routes() {
        let user = @0xF9; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let synth_reg = Synth::new_registry_for_testing(scen.ctx());
        Gas::init_gas_registry(&synth_reg, scen.ctx());
        let mut reg: GasFuturesRegistry = test_scenario::take_shared<GasFuturesRegistry>(&scen);
        // Configure settlement fee = 1% and bot cut = 10%
        Gas::set_settlement_params_for_testing(&mut reg, 100, 1000);
        // Oracle for SUI (not used in close)
        let mut px_sui = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"SUI_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_sui, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let admin = unxversal::admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&admin, &mut orx, string::utf8(b"SUI"), &px_sui, scen.ctx());
        // List market
        Gas::list_gas_futures(&mut reg, string::utf8(b"GAS-BOT"), 1, 1, 1, 1_000, 600, scen.ctx());
        let gid = Gas::gas_contract_id(&reg, &string::utf8(b"GAS-BOT"));
        let mut market: GasFuturesContract = test_scenario::take_shared_by_id<GasFuturesContract>(&scen, gid);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut bot: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        // Create owned position with sufficient margin
        let pay = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        let (mut pos, refund) = Gas::new_position_for_testing<TestBaseUSD>(user, &market, 0, 10, 1_000_000, pay, 600_000, &clk, scen.ctx());
        sui::transfer::public_transfer(refund, user);
        let pre_tre = Tre::tre_balance_collateral_for_testing(&tre);
        // Close 4 @ 1_000_000 → notional=4,000,000; fee=1%→40,000; bot=10%→4,000; treasury delta=36,000
        Gas::close_gas_position<TestBaseUSD>(&reg, &mut market, &mut pos, &clk, 1_000_000, 4, &mut tre, &mut bot, &pts, scen.ctx());
        let post_tre = Tre::tre_balance_collateral_for_testing(&tre);
        assert!(post_tre - pre_tre == 36_000);
        // cleanup
        aggregator::share_for_testing(px_sui);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(admin);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(pos);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(synth_reg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
}


