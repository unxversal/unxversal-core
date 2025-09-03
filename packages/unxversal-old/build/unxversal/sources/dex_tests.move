#[test_only]
module unxversal::dex_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin::{Self as coin};
    use std::string;

    use switchboard::aggregator;
    use unxversal::dex::{Self as Dex, DexConfig};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::admin::{Self as Admin, AdminRegistry};
    use unxversal::treasury::{Self as Tre, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::test_coins::TestBaseUSD;
    use unxversal::unxv::UNXV;

    #[test]
    fun dex_admin_setters_and_pause_resume() {
        let user = @0x11; let mut scen = test_scenario::begin(user);
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        let tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let mut cfg: DexConfig = Dex::new_dex_config_for_testing<TestBaseUSD>(&tre, scen.ctx());
        // Admin variants should succeed
        Dex::set_trade_fee_bps_admin(&reg_admin, &mut cfg, 100, scen.ctx());
        Dex::set_unxv_discount_bps_admin(&reg_admin, &mut cfg, 5000, scen.ctx());
        Dex::set_maker_rebate_bps_admin(&reg_admin, &mut cfg, 2500, scen.ctx());
        Dex::pause_admin(&reg_admin, &mut cfg, scen.ctx());
        assert!(Dex::is_paused_for_testing(&cfg));
        Dex::resume_admin(&reg_admin, &mut cfg, scen.ctx());
        assert!(!Dex::is_paused_for_testing(&cfg));
        // cleanup
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(reg_admin);
        test_scenario::end(scen);
    }

    #[test]
    fun dex_vault_mode_place_cancel_match_and_getters() {
        let user = @0x21; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        Tre::set_auto_bot_rewards_bps_for_testing(&mut tre, 0);
        let mut bot_t: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        let cfg: DexConfig = Dex::new_dex_config_for_testing<TestBaseUSD>(&tre, scen.ctx());
        // Market and escrow via test helpers
        let mkt = Dex::new_dex_market_for_testing<TestBaseUSD, TestBaseUSD>(b"B".to_string(), b"Q".to_string(), 1, 1, 1, scen.ctx());
        let esc = Dex::new_dex_escrow_for_testing<TestBaseUSD, TestBaseUSD>(&mkt, scen.ctx());
        // Vault-mode sell/buy orders via test helpers using coin stores
        let mut base_store = coin::mint_for_testing<TestBaseUSD>(10, scen.ctx());
        let mut coll_store = coin::mint_for_testing<TestBaseUSD>(1_000_000_000, scen.ctx());
        // Create vault-mode orders using test helpers (kept local)
        let mut sell = Dex::new_vault_sell_order_for_testing<TestBaseUSD>(1_000_000, 5, &mut base_store, 100, scen.ctx());
        let mut buy = Dex::new_vault_buy_order_for_testing<TestBaseUSD, TestBaseUSD>(1_000_000, 5, &mut coll_store, 100, scen.ctx());
        // Match to stores
        let unxv_payment = vector::empty<sui::coin::Coin<UNXV>>();
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, scen.ctx());
        let mut buyer_base_store = coin::zero<TestBaseUSD>(scen.ctx());
        let mut seller_coll_store = coin::zero<TestBaseUSD>(scen.ctx());
        let ocfg2 = Oracle::new_config_for_testing(scen.ctx());
        Dex::match_vault_orders<TestBaseUSD, TestBaseUSD>(&cfg, &mut buy, &mut sell, 5, true, unxv_payment, &px_unxv, &orx, &ocfg2, &clk, &mut tre, &mut bot_t, &pts, 1_000_000, 1_000_000, &mut buyer_base_store, &mut seller_coll_store, b"B/Q".to_string(), b"B".to_string(), b"Q".to_string(), scen.ctx());
        // Assert config getters
        let (_tf, _ud, _mr, paused) = Dex::get_config_fees(&cfg);
        assert!(!paused);
        let (_k, _g, _m) = Dex::get_config_extras(&cfg);
        // Place coin orders to exercise order_*_info getters
        let cs = Dex::place_coin_sell_order<TestBaseUSD>(&cfg, 1, 1, coin::mint_for_testing<TestBaseUSD>(1, scen.ctx()), 0, scen.ctx());
        let cb = Dex::place_coin_buy_order<TestBaseUSD, TestBaseUSD>(&cfg, 1, 1, coin::mint_for_testing<TestBaseUSD>(1, scen.ctx()), 0, scen.ctx());
        let (_owner_b, _price_b, _rem_b, _created_b, _expiry_b, _escrow_quote) = Dex::order_buy_info<TestBaseUSD, TestBaseUSD>(&cb);
        let (_owner_s, _price_s, _rem_s, _created_s, _expiry_s, _escrow_base) = Dex::order_sell_info<TestBaseUSD>(&cs);
        // Cancel-if-expired paths (set now > expiry) using clock-aware helpers
        let mut clk2 = clk; clock::set_for_testing(&mut clk2, 1_000_001);
        Dex::cancel_vault_sell_if_expired_with_clock<TestBaseUSD>(sell, &mut base_store, &clk2, scen.ctx());
        Dex::cancel_vault_buy_if_expired_with_clock<TestBaseUSD, TestBaseUSD>(buy, &mut coll_store, &clk2, scen.ctx());
        // Consume coin stores from match
        sui::transfer::public_transfer(buyer_base_store, user);
        sui::transfer::public_transfer(seller_coll_store, user);
        // Any remaining stores
        sui::transfer::public_transfer(base_store, user);
        sui::transfer::public_transfer(coll_store, user);
        // cleanup
        aggregator::share_for_testing(px_unxv);
        sui::transfer::public_share_object(mkt);
        sui::transfer::public_share_object(esc);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg2);
        sui::transfer::public_share_object(reg_admin);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot_t);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(cs);
        sui::transfer::public_share_object(cb);
        clock::destroy_for_testing(clk2);
        test_scenario::end(scen);
    }

    #[test]
    fun dex_match_coin_orders_with_unxv_discount_and_rebate() {
        let user = @0x12; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let mut orx = Oracle::new_registry_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        // Treasury and bot treasuries
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(scen.ctx());
        Tre::set_auto_bot_rewards_bps_for_testing(&mut tre, 0);
        let mut bot_t: BotRewardsTreasury<TestBaseUSD> = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(scen.ctx());
        let pts: BotPointsRegistry = BR::new_points_registry_for_testing(scen.ctx());
        // Dex config: 1% fee, 50% discount, 50% rebate
        let mut cfg: DexConfig = Dex::new_dex_config_for_testing<TestBaseUSD>(&tre, scen.ctx());
        Dex::set_trade_fee_bps_admin(&reg_admin, &mut cfg, 100, scen.ctx());
        Dex::set_unxv_discount_bps_admin(&reg_admin, &mut cfg, 5000, scen.ctx());
        Dex::set_maker_rebate_bps_admin(&reg_admin, &mut cfg, 5000, scen.ctx());
        // Oracle prices
        let mut px_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), user, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, scen.ctx());
        aggregator::set_current_value(&mut px_unxv, switchboard::decimal::new(1_000_000, false), 1, 1, 1, switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false), switchboard::decimal::new(0, false));
        Oracle::set_feed(&reg_admin, &mut orx, string::utf8(b"UNXV"), &px_unxv, scen.ctx());
        // Construct a simple buy/sell order pair using coin orders
        // Sell: owner S escrows 4 base units at price 1_000_000
        let mut sell = Dex::place_coin_sell_order<TestBaseUSD>(&cfg, 1_000_000, 4, coin::mint_for_testing<TestBaseUSD>(4, scen.ctx()), 0, scen.ctx());
        // Buy: owner B escrows enough quote to buy 4 base at 1_000_000
        let mut buy = Dex::place_coin_buy_order<TestBaseUSD, TestBaseUSD>(&cfg, 1_000_000, 4, coin::mint_for_testing<TestBaseUSD>(4_000_000, scen.ctx()), 0, scen.ctx());
        // UNXV payment to fully cover discount on fee
        let mut unxv_payment = vector::empty<sui::coin::Coin<UNXV>>();
        vector::push_back(&mut unxv_payment, sui::coin::mint_for_testing<UNXV>(100, scen.ctx()));
        // Pre balances
        let pre_tre = Tre::tre_balance_collateral_for_testing(&tre);
        // Match with taker=buyer, min/max bounds exactly
        let ocfg = Oracle::new_config_for_testing(scen.ctx());
        Dex::match_coin_orders<TestBaseUSD, TestBaseUSD>(&cfg, &mut buy, &mut sell, 4, true, unxv_payment, &px_unxv, &orx, &ocfg, &clk, &mut tre, &mut bot_t, &pts, 1_000_000, 1_000_000, b"COIN/COIN".to_string(), b"BASE".to_string(), b"QUOTE".to_string(), scen.ctx());
        let post_tre = Tre::tre_balance_collateral_for_testing(&tre);
        // Fee math: notional=4_000_000; fee=40_000; rebate=20_000; discount=20_000 => fee to treasury after discount 20_000 minus rebate to maker => 20_000
        assert!(post_tre - pre_tre == 20_000);
        // cleanup (consume resources)
        aggregator::share_for_testing(px_unxv);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(orx);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot_t);
        sui::transfer::public_share_object(pts);
        sui::transfer::public_share_object(sell);
        sui::transfer::public_share_object(buy);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
}


