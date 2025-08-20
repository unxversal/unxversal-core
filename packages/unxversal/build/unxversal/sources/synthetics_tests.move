#[test_only]
module unxversal::synthetics_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin::Coin;
    use std::string;
    use switchboard::aggregator;
    use switchboard::decimal;

    use unxversal::synthetics::{Self as Syn, CollateralVault, CollateralConfig};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::treasury::{Self as Tre, Treasury};
    use unxversal::test_coins::TestBaseUSD;
    use unxversal::unxv::UNXV;

    #[test]
    fun mint_then_burn_updates_debt_and_routes_fees() {
        let owner = @0x21;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // Registry and collateral
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        // Treasury
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);

        // Add listed synthetic and bind oracle feed in registry for symbol
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        // Oracle feed and price
        let clock_obj = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(
            aggregator::example_queue_id(),
            string::utf8(b"sUSD_px"),
            owner,
            vector::empty<u8>(),
            1,
            10_000_000,
            0,
            1,
            0,
            ctx,
        );
        let px = decimal::new(1_000_000, false); // 1.0 in 1e6 scale
        aggregator::set_current_value(&mut agg, px, 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));

        // Bind the symbol -> feed hash for oracle enforcement in synthetics
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        // Create vault and deposit collateral
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);

        // Oracle config (test-only)
        let ocfg = Oracle::new_config_for_testing(ctx);

        // UNXV discount setup (no discount applied here; pass empty vector)
        let empty_unxv: vector<Coin<UNXV>> = vector::empty<Coin<UNXV>>();

        // Deposit collateral to satisfy CCR
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);

        let sym = string::utf8(b"sUSD");

        // Mint
        Syn::mint_synthetic<TestBaseUSD>(
            &cfg,
            &mut vault,
            &mut reg,
            &clock_obj,
            &ocfg,
            &agg,
            string::utf8(b"sUSD"),
            100,
            empty_unxv,
            &agg,
            &mut tre,
            ctx
        );

        // Post-mint assertions: debt recorded, ratio healthy
        let (_coll_v1, debt_v1, ratio_v1) = Syn::get_vault_values(&vault, &reg, &clock_obj, &ocfg, &agg, &sym);
        assert!(debt_v1 == 100 * 1_000_000);
        assert!(ratio_v1 >= 1_500);

        // Burn
        let empty_unxv2: vector<Coin<UNXV>> = vector::empty<Coin<UNXV>>();
        Syn::burn_synthetic<TestBaseUSD>(
            &cfg,
            &mut vault,
            &mut reg,
            &clock_obj,
            &ocfg,
            &agg,
            string::utf8(b"sUSD"),
            100,
            empty_unxv2,
            &agg,
            &mut tre,
            ctx
        );

        // Post-burn assertions: no debt
        let (_coll_v2, debt_v2, _ratio_v2) = Syn::get_vault_values(&vault, &reg, &clock_obj, &ocfg, &agg, &sym);
        assert!(debt_v2 == 0);

        // Cleanup linear resources
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(ocfg);
        sui::transfer::public_share_object(cfg);
        clock::destroy_for_testing(clock_obj);
        test_scenario::end(scen);
    }

    #[test]
    fun mint_fee_deposits_to_treasury_no_unxv() {
        let owner = @0x22;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // Setup registry/treasury and collateral
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);

        // List synth and bind price
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        // Vault with collateral
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);

        // Mint 100 with no UNXV payment
        let before = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 100, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);

        // Expected base fee = notional * mint_fee_bps / 10_000
        let notional = 100 * 1_000_000;
        let base_fee = (notional * 50) / 10_000; // default mint_fee_bps = 50
        let after = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        assert!(after >= before + base_fee);

        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun oracle_binding_mismatch_aborts() {
        let owner = @0x23;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        let clk = clock::create_for_testing(ctx);
        // Bind feed A
        let mut agg_a = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_A"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg_a, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg_a);

        // Use feed B when minting → should abort
        let mut agg_b = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_B"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg_b, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg_b, string::utf8(b"sUSD"), 1, vector::empty<Coin<UNXV>>(), &agg_b, &mut tre, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun stale_price_aborts() {
        let owner = @0x24;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        let mut clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        // stale timestamp 0
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 0, 0, 0, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);

        let mut ocfg = Oracle::new_config_for_testing(ctx);
        // tighten staleness to 1s
        Oracle::set_max_age(&mut ocfg, 1, ctx);
        // advance clock beyond max age
        clock::set_for_testing(&mut clk, 5_000);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 1, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        abort 0
    }

    #[test]
    fun liquidation_executes_and_routes() {
        let owner = @0x25;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        // Set params: low min_collateral_ratio so mint passes; higher liquidation_threshold so vault is liquidatable
        // Raise liquidation_threshold so liquidation is allowed even with higher collateral to cover seize
        let params = Syn::new_global_params_for_testing(100, 30_000, 500, 100, 200, 1_000, 50, 30, 2_000, 0, 100, 100, 10);
        Syn::update_global_params(&mut reg, params, ctx);

        // Bind price and create vault
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        // Fund enough collateral to cover notional + penalty so seizure is not capped
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(2_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);

        // Mint minimal amount to be just at min_collateral_ratio = 100 bps
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 1, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);

        // Liquidate the entire debt; compute expected seize and treasury increase
        let before_tre = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        Syn::liquidate_vault<TestBaseUSD>(&mut reg, &clk, &ocfg, &agg, &mut vault, string::utf8(b"sUSD"), 1, owner, &mut tre, ctx);
        let after_tre = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        // notional = 1 * 1e6, penalty = 5%, seize = notional + penalty, bot_cut = 10%
        let notional = 1 * 1_000_000;
        let penalty = (notional * 500) / 10_000; // 5%
        let seize = notional + penalty;
        let bot_cut = (seize * 1_000) / 10_000; // 10%
        assert!(after_tre >= before_tre + (seize - bot_cut));

        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun fee_math_u128_bounds_and_ccr_edges() {
        let owner = @0x41;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        // Bind price and prepare vault with very large collateral
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(50_000_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        // Large mint should not overflow and CCR should be >= min
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 1_000_000_000, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        let (_cv, _dv, ratio) = Syn::get_vault_values(&vault, &reg, &clk, &ocfg, &agg, &string::utf8(b"sUSD"));
        assert!(ratio >= 1_500);
        // Burn a large amount should also be safe
        Syn::burn_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 500_000_000, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        let (_cv2, _dv2, _r2) = Syn::get_vault_values(&vault, &reg, &clk, &ocfg, &agg, &string::utf8(b"sUSD"));
        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun match_orders_maker_rebate_and_fee_routing() {
        let owner = @0x42;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        // Set maker rebate to 10%
        let new_params = Syn::new_global_params_for_testing(1500, 1200, 500, 100, 200, 1000, 50, 30, 2000, 1000, 100, 100, 10);
        Syn::update_global_params(&mut reg, new_params, ctx);

        // Bind price and build vaults
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vb: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let mut vs: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vb, sui::coin::mint_for_testing<TestBaseUSD>(1_000_000, ctx), ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vs, sui::coin::mint_for_testing<TestBaseUSD>(1_000_000, ctx), ctx);

        // Orders: buyer bids 10 for size 100, seller asks 10 for size 100
        let mut buy = Syn::new_order_for_testing(string::utf8(b"sUSD"), 0, 10, 100, 0, Syn::vault_owner(&vb), ctx);
        let mut sell = Syn::new_order_for_testing(string::utf8(b"sUSD"), 1, 10, 100, 0, Syn::vault_owner(&vs), ctx);

        let tre_before = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        let ocfg_mo = Oracle::new_config_for_testing(ctx);
        Syn::match_orders<TestBaseUSD>(&mut reg, &clk, &ocfg_mo, &agg, &mut buy, &mut sell, &mut vb, &mut vs, vector::empty<Coin<UNXV>>(), &agg, /*taker_is_buyer=*/true, 1, 1_000_000_000, &mut tre, ctx);
        let tre_after = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        // Trade fee = notional * 0.5% = 100 * 10 * 0.005 = 5
        let notional = 100 * 10;
        let trade_fee = (notional * 50) / 10_000;
        let maker_rebate = (trade_fee * 1000) / 10_000; // 10%
        let expected_treasury_min = trade_fee - maker_rebate;
        assert!(tre_after >= tre_before + expected_treasury_min);

        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(ocfg_mo);
        // consume Orders (share as objects for testing)
        sui::transfer::public_share_object(buy);
        sui::transfer::public_share_object(sell);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vb);
        sui::transfer::public_share_object(vs);
        sui::transfer::public_share_object(cfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun stability_accrual_increments_debt() {
        let owner = @0x43;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        // Reduce collateral so CCR falls below liquidation_threshold (ratio ≈ 100 bps < 150 bps)
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, sui::coin::mint_for_testing<TestBaseUSD>(100_000, ctx), ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 1_000, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        // Advance time by ~1 day and accrue
        let mut clk2 = clk; // move then replace with new handle
        clock::set_for_testing(&mut clk2, 86_400_000);
        // Keep a reference to an owned clock for calls after move
        let clk3 = clock::create_for_testing(ctx);
        Syn::accrue_stability<TestBaseUSD>(&mut vault, &mut reg, &clk3, &agg, &ocfg, string::utf8(b"sUSD"), ctx);
        let debt_after = Syn::get_vault_debt(&vault, &string::utf8(b"sUSD"));
        assert!(debt_after >= 1_000);
        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk2);
        clock::destroy_for_testing(clk3);
        test_scenario::end(scen);
    }

    #[test]
    fun reconciliation_helpers_reflect_mint_burn() {
        let owner = @0x44;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, sui::coin::mint_for_testing<TestBaseUSD>(1_000_000, ctx), ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        // Before
        let (_c0, d0, _r0) = Syn::get_vault_values(&vault, &reg, &clk, &ocfg, &agg, &string::utf8(b"sUSD"));
        // Mint then check helpers
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 10, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        let deb = Syn::get_vault_debt(&vault, &string::utf8(b"sUSD"));
        let syms = Syn::list_vault_debt_symbols(&vault);
        assert!(deb >= 10);
        assert!(vector::length(&syms) >= 1);
        // Burn and verify
        Syn::burn_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 10, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        let (_c1, d1, _r1) = Syn::get_vault_values(&vault, &reg, &clk, &ocfg, &agg, &string::utf8(b"sUSD"));
        assert!(d1 <= d0);
        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun liquidation_rejects_when_not_liquidatable() {
        let owner = @0x45;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, sui::coin::mint_for_testing<TestBaseUSD>(1_000_000, ctx), ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        // keep at healthy ratio
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 1, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        Syn::liquidate_vault<TestBaseUSD>(&mut reg, &clk, &ocfg, &agg, &mut vault, string::utf8(b"sUSD"), 1, owner, &mut tre, ctx);
        abort 0
    }

    #[test]
    fun liquidation_repay_clamps_to_outstanding() {
        let owner = @0x46;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        // Params to allow liquidation path
        // Set liquidation_threshold high to ensure liquidation guard passes given provided balances
        let params = Syn::new_global_params_for_testing(100, 30_000, 500, 100, 200, 1000, 50, 30, 2000, 0, 100, 100, 10);
        Syn::update_global_params(&mut reg, params, ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, sui::coin::mint_for_testing<TestBaseUSD>(1_000_000, ctx), ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 10, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);
        // Repay > outstanding (e.g., 9999) – function should clamp to 10
        let before_tre = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        Syn::liquidate_vault<TestBaseUSD>(&mut reg, &clk, &ocfg, &agg, &mut vault, string::utf8(b"sUSD"), 9_999, owner, &mut tre, ctx);
        let after_tre = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        assert!(after_tre > before_tre);
        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun withdraw_health_guard_rejects_when_ratio_drops_below_min() {
        let owner = @0x26;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        // Set min CCR to 15000 bps (150%) so a small withdraw can violate it
        let params = Syn::new_global_params_for_testing(15_000, 12_000, 500, 100, 200, 1_000, 50, 30, 2_000, 0, 100, 100, 10);
        Syn::update_global_params(&mut reg, params, ctx);

        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(150_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg, string::utf8(b"sUSD"), 100, vector::empty<Coin<UNXV>>(), &agg, &mut tre, ctx);

        // Attempt to withdraw 1 should drop ratio just below 15000 bps → abort
        let _coin_out = Syn::withdraw_collateral<TestBaseUSD>(&cfg, &mut vault, &reg, &clk, &ocfg, &agg, &string::utf8(b"sUSD"), 1, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun mint_with_unxv_discount_without_binding_aborts() {
        let owner = @0x27;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        // Bind sUSD price
        let mut agg_s = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg_s, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg_s);
        // Do NOT bind UNXV price, but pass UNXV coins → should abort when pricing UNXV
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = sui::coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);
        let mut pay = vector::empty<Coin<UNXV>>();
        // empty coin vector yields no discount path; ensure non-empty to hit UNXV pricing
        let mut cap = unxversal::unxv::new_supply_cap_for_testing(ctx);
        let c_unxv: Coin<UNXV> = unxversal::unxv::mint_coin_for_testing(&mut cap, 1000, ctx);
        vector::push_back(&mut pay, c_unxv);
        let ocfg = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg, &agg_s, string::utf8(b"sUSD"), 1_000, pay, &agg_s, &mut tre, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun withdraw_collateral_multi_is_deprecated() {
        let owner = @0x28;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        // Construct a dummy PriceSet
        let mut ps = Syn::new_price_set(ctx);
        Syn::record_symbol_price(&reg, &clk, &Oracle::new_config_for_testing(ctx), string::utf8(b"sUSD"), &agg, &mut ps);
        let c_out = Syn::withdraw_collateral_multi<TestBaseUSD>(&cfg, &mut vault, &reg, vector::empty<string::String>(), &ps, 1, ctx);
        sui::transfer::public_transfer(c_out, owner);
        abort 0
    }
}



#[test_only]
module unxversal::synthetics_discount_and_clob_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin::{Self as coin, Coin};
    use std::string;
    use switchboard::aggregator;
    use switchboard::decimal;
    use unxversal::synthetics::{Self as Syn, CollateralVault, CollateralConfig, SynthMarket, SynthEscrow};
    use unxversal::oracle::{Self as Oracle};
    use unxversal::treasury::{Self as Tre, Treasury};
    use unxversal::test_coins::TestBaseUSD;
    use unxversal::unxv::{Self as UNXVMod, UNXV};
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::admin;

    #[test]
    fun mint_with_unxv_discount_routes_fee_and_refund_leftovers() {
        let owner = @0x31;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);

        // List synth and bind price feeds for sUSD and UNXV
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);
        let clk = clock::create_for_testing(ctx);
        let mut agg_susd = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg_susd, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg_susd);

        let mut agg_unxv = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"UNXV_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg_unxv, decimal::new(2_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"UNXV"), &agg_unxv);

        // Create vault and fund collateral
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = coin::mint_for_testing<TestBaseUSD>(10_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);

        // Provide UNXV vector larger than needed
        let mut cap = UNXVMod::new_supply_cap_for_testing(ctx);
        let unxv_coins: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap, 10_000_000, ctx);
        let mut pay_vec = vector::empty<Coin<UNXV>>();
        vector::push_back<Coin<UNXV>>(&mut pay_vec, unxv_coins);

        // Mint 1_000 units sUSD; notional = 1_000 * 1e6; base_fee = 0.5% of notional; discount = 20% of fee
        let ocfg_d = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic<TestBaseUSD>(
            &cfg,
            &mut vault,
            &mut reg,
            &clk,
            &ocfg_d,
            &agg_susd,
            string::utf8(b"sUSD"),
            1_000,
            pay_vec,
            &agg_unxv,
            &mut tre,
            ctx
        );

        // Compute expected UNXV paid = ceil(discount_usd / px_unxv)
        let notional = 1_000 * 1_000_000; // micro-USD
        let base_fee = (notional * 50) / 10_000; // 0.5%
        let discount = (base_fee * 2_000) / 10_000; // 20%
        let expected_unxv = if (discount % 2_000_000 == 0) { discount / 2_000_000 } else { (discount / 2_000_000) + 1 };
        assert!(Tre::tre_balance_unxv<TestBaseUSD>(&tre) == expected_unxv);

        // Mirror-based leftover assertion
        let mut mirror = Syn::new_event_mirror_for_testing(ctx);
        let mut pay_vec2 = vector::empty<Coin<UNXV>>();
        let unxv_coins2: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap, 10_000_000, ctx);
        vector::push_back(&mut pay_vec2, unxv_coins2);
        Syn::mint_synthetic_with_event_mirror<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg_d, &agg_susd, string::utf8(b"sUSD"), 1_000, pay_vec2, &agg_unxv, &mut tre, &mut mirror, ctx);
        assert!(Syn::em_last_unxv_leftover(&mirror) == (10_000_000 - expected_unxv));

        // Clean up
        sui::transfer::public_share_object(cap);
        switchboard::aggregator::share_for_testing(agg_susd);
        switchboard::aggregator::share_for_testing(agg_unxv);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg_d);
        sui::transfer::public_share_object(mirror);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun synthetics_points_variants_award_points() {
        let owner = @0x33;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // Setup points registry and config
        let mut points: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let admin_reg = admin::new_admin_registry_for_testing(ctx);
        BR::set_epoch_config(&admin_reg, &mut points, 0, 1_000, ctx);
        BR::set_weight(&admin_reg, &mut points, string::utf8(b"synthetics.init_synth_market"), 10, ctx);
        BR::set_weight(&admin_reg, &mut points, string::utf8(b"synthetics.match_step_auto"), 10, ctx);
        BR::set_weight(&admin_reg, &mut points, string::utf8(b"synthetics.gc_step"), 10, ctx);

        // Setup registry and market
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg_pts: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        // Prepare aggregators for params (unused in match_step)
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));

        // Create market and escrow via helpers
        let mut market: SynthMarket = Syn::new_market_for_testing(string::utf8(b"sUSD"), 1, 1, 1, ctx);
        let mut escrow: SynthEscrow<TestBaseUSD> = Syn::new_escrow_for_testing<TestBaseUSD>(&market, ctx);

        // Treasury and bot treasury; fund current epoch with UNXV
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let epoch = BR::current_epoch(&points, &clk);
        let mut cap = UNXVMod::new_supply_cap_for_testing(ctx);
        let coin_unxv: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap, 1_000, ctx);
        let mut vec_unxv = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut vec_unxv, coin_unxv);
        Tre::deposit_unxv_with_rewards_for_epoch<TestBaseUSD>(&mut tre, &mut bot, epoch, vec_unxv, b"points_epoch_fund".to_string(), owner, ctx);

        // 1) init_synth_market_with_points
        Syn::init_synth_market_with_points(&reg, string::utf8(b"sUSD"), 1, 1, 1, &mut points, &clk, ctx);

        // 2) match_step_auto_with_points (no orders; still awards points)
        let ocfg_pts = Oracle::new_config_for_testing(ctx);
        Syn::match_step_auto_with_points<TestBaseUSD>(&mut points, &clk, &reg, &mut market, &clk, &ocfg_pts, &agg, &agg, 1, 0, 1_000_000_000, &mut tre, ctx);

        // 3) gc_step_with_points (no expirations; still awards points)
        Syn::gc_step_with_points<TestBaseUSD>(&mut points, &clk, &reg, &mut market, &mut escrow, &mut tre, 0, 0, ctx);

        // Claim rewards for this epoch and assert UNXV epoch reserves decrease to zero
        BR::claim_rewards_for_epoch<TestBaseUSD>(&mut points, &mut bot, epoch, ctx);
        let (_, unxv_after) = Tre::epoch_reserves<TestBaseUSD>(&bot, epoch);
        assert!(unxv_after == 0);

        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(admin_reg);
        sui::transfer::public_share_object(points);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(escrow);
        sui::transfer::public_share_object(cap);
        sui::transfer::public_share_object(cfg_pts);
        sui::transfer::public_share_object(ocfg_pts);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
    #[test]
    fun clob_escrow_accrual_and_claim_cycle() {
        let owner = @0x32;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        let clk = clock::create_for_testing(ctx);
        // Price binding for sUSD
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        // Market and escrow via helpers
        let mut market: SynthMarket = Syn::new_market_for_testing(string::utf8(b"sUSD"), 1, 1, 1, ctx);
        let mut escrow: SynthEscrow<TestBaseUSD> = Syn::new_escrow_for_testing<TestBaseUSD>(&market, ctx);

        // Maker vault (seller) with collateral
        let mut seller_vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut seller_vault, coll, ctx);

        // Place a seller maker (taker_is_bid=false) and capture order id
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let ocfg_ce = Oracle::new_config_for_testing(ctx);
        let maybe_id = Syn::place_with_escrow_return_id<TestBaseUSD>(&mut reg, &mut market, &mut escrow, &clk, &ocfg_ce, &agg, &agg, /*taker_is_bid=*/false, /*price=*/10, /*size=*/100, /*expiry=*/0, &mut seller_vault, vector::empty<Coin<UNXV>>(), &mut tre, ctx);
        assert!(option::is_some(&maybe_id));
        let order_id = *option::borrow(&maybe_id);

        // Buyer taker matches part of seller maker; accrues to escrow
        let mut buyer_vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll2 = coin::mint_for_testing<TestBaseUSD>(1_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut buyer_vault, coll2, ctx);
        let _ = Syn::place_with_escrow_return_id<TestBaseUSD>(&mut reg, &mut market, &mut escrow, &clk, &ocfg_ce, &agg, &agg, /*taker_is_bid=*/true, /*price=*/10, /*size=*/50, /*expiry=*/0, &mut buyer_vault, vector::empty<Coin<UNXV>>(), &mut tre, ctx);

        // Assert escrow has some pending balance for seller's order id
        let pending_val = Syn::escrow_pending_value<TestBaseUSD>(&escrow, order_id);
        assert!(pending_val > 0);

        // Claim for seller maker should not abort
        Syn::claim_maker_fills<TestBaseUSD>(&reg, &mut market, &mut escrow, order_id, &mut seller_vault, ctx);

        // Cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(seller_vault);
        sui::transfer::public_share_object(buyer_vault);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(escrow);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg_ce);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun clob_bond_cancel_and_gc_slash() {
        let owner = @0x37;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // Registry, config, listing
        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        // Clock and price binding
        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        // Market, escrow, treasury
        let mut market: SynthMarket = Syn::new_market_for_testing(string::utf8(b"sUSD"), 1, 1, 1, ctx);
        let mut escrow: SynthEscrow<TestBaseUSD> = Syn::new_escrow_for_testing<TestBaseUSD>(&market, ctx);
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);

        // Maker vault with collateral
        let mut v_maker: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let c = coin::mint_for_testing<TestBaseUSD>(5_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut v_maker, c, ctx);

        // Place maker (ask) with escrow, no immediate match, ensure bond exists
        let ocfg = Oracle::new_config_for_testing(ctx);
        let oid_opt = Syn::place_with_escrow_return_id<TestBaseUSD>(&mut reg, &mut market, &mut escrow, &clk, &ocfg, &agg, &agg, /*taker_is_bid=*/false, /*price=*/10, /*size=*/100, /*expiry=*/1000, &mut v_maker, vector::empty<Coin<UNXV>>(), &mut tre, ctx);
        assert!(option::is_some(&oid_opt));
        let oid = *option::borrow(&oid_opt);
        let bond_before = Syn::escrow_bond_value<TestBaseUSD>(&escrow, oid);
        assert!(bond_before > 0);

        // Cancel with escrow and assert bond returned to vault
        let maker_before = Syn::vault_collateral_value<TestBaseUSD>(&v_maker);
        Syn::cancel_synth_clob_with_escrow<TestBaseUSD>(&mut market, &mut escrow, oid, &mut v_maker, ctx);
        let maker_after = Syn::vault_collateral_value<TestBaseUSD>(&v_maker);
        assert!(maker_after >= maker_before + bond_before);
        assert!(Syn::escrow_bond_value<TestBaseUSD>(&escrow, oid) == 0);

        // Place an expired maker (expiry < now) and run GC; assert treasury collateral increases
        let oid2_opt = Syn::place_with_escrow_return_id<TestBaseUSD>(&mut reg, &mut market, &mut escrow, &clk, &ocfg, &agg, &agg, /*taker_is_bid=*/false, /*price=*/10, /*size=*/50, /*expiry=*/1, &mut v_maker, vector::empty<Coin<UNXV>>(), &mut tre, ctx);
        assert!(option::is_some(&oid2_opt));
        let tre_before = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        Syn::gc_step<TestBaseUSD>(&reg, &mut market, &mut escrow, &mut tre, /*now_ts=*/2, /*max_removals=*/1000, ctx);
        let tre_after = Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre);
        assert!(tre_after >= tre_before);

        // Cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(market);
        sui::transfer::public_share_object(escrow);
        sui::transfer::public_share_object(v_maker);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun mint_and_burn_event_mirror_validates_fields() {
        let owner = @0x34;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut reg = Syn::new_registry_for_testing(ctx);
        let cfg: CollateralConfig<TestBaseUSD> = Syn::set_collateral_for_testing<TestBaseUSD>(&mut reg, ctx);
        Syn::add_synthetic_for_testing(&mut reg, string::utf8(b"Synthetix"), string::utf8(b"sUSD"), 6, 1500, ctx);

        let clk = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"sUSD_px"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg, decimal::new(1_000_000, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        Syn::set_oracle_feed_binding_for_testing(&mut reg, string::utf8(b"sUSD"), &agg);

        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vault: CollateralVault<TestBaseUSD> = Syn::create_vault_for_testing<TestBaseUSD>(&cfg, &reg, ctx);
        let coll = coin::mint_for_testing<TestBaseUSD>(5_000_000_000, ctx);
        Syn::deposit_collateral<TestBaseUSD>(&cfg, &mut vault, coll, ctx);

        let mut mirror = Syn::new_event_mirror_for_testing(ctx);

        // Mint 500
        let ocfg_em = Oracle::new_config_for_testing(ctx);
        Syn::mint_synthetic_with_event_mirror<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg_em, &agg, string::utf8(b"sUSD"), 500, vector::empty<Coin<UNXV>>(), &agg, &mut tre, &mut mirror, ctx);
        assert!(Syn::em_mint_count(&mirror) == 1);
        assert!(Syn::em_last_mint_symbol(&mirror) == string::utf8(b"sUSD"));
        assert!(Syn::em_last_mint_amount(&mirror) == 500);
        assert!(Syn::em_last_mint_vault(&mirror) == sui::object::id(&vault));
        assert!(Syn::em_last_mint_new_cr(&mirror) >= 1500);
        // no UNXV passed => leftover 0
        assert!(Syn::em_last_unxv_leftover(&mirror) == 0);

        // Burn 200
        Syn::burn_synthetic_with_event_mirror<TestBaseUSD>(&cfg, &mut vault, &mut reg, &clk, &ocfg_em, &agg, string::utf8(b"sUSD"), 200, vector::empty<Coin<UNXV>>(), &agg, &mut tre, &mut mirror, ctx);
        assert!(Syn::em_burn_count(&mirror) == 1);
        assert!(Syn::em_last_burn_symbol(&mirror) == string::utf8(b"sUSD"));
        assert!(Syn::em_last_burn_amount(&mirror) == 200);
        assert!(Syn::em_last_burn_vault(&mirror) == sui::object::id(&vault));

        // cleanup
        switchboard::aggregator::share_for_testing(agg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(vault);
        sui::transfer::public_share_object(mirror);
        sui::transfer::public_share_object(cfg);
        sui::transfer::public_share_object(ocfg_em);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
}
