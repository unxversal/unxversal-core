#[test_only]
module unxversal::treasury_tests {
    use sui::test_scenario;
    use sui::coin::Coin;
    use unxversal::unxv::{Self as UNXVMod, UNXV};
    use unxversal::treasury::{Self as Tre, Treasury};
    use unxversal::test_coins::TestBaseUSD;

    #[test]
    fun unxv_deposit_auto_route_split() {
        let owner = @0xD;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);

        Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre, 2500); // 25%

        // Mint UNXV and deposit with auto routing
        let mut sc_cap = UNXVMod::new_supply_cap_for_testing(ctx);
        let c1: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut sc_cap, 1000, ctx);
        let mut vec_unxv = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut vec_unxv, c1);

        Tre::deposit_unxv_with_rewards<TestBaseUSD>(&mut tre, &mut bot, vec_unxv, b"test_unxv".to_string(), owner, ctx);

        // Expect 25% to bot, 75% to treasury
        assert!(Tre::bot_balance_unxv<TestBaseUSD>(&bot) == 250);
        assert!(Tre::tre_balance_unxv<TestBaseUSD>(&tre) == 750);

        // consume linear resources
        sui::transfer::public_share_object(sc_cap);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        test_scenario::end(scen);
    }

    #[test]
    fun epoch_reserves_and_payouts_unxv() {
        let owner = @0xE;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre, 5000); // 50%

        // Mint UNXV and make an epoch-aware deposit for epoch 1
        let mut sc_cap = UNXVMod::new_supply_cap_for_testing(ctx);
        let c1: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut sc_cap, 1000, ctx);
        let mut vec_unxv = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut vec_unxv, c1);

        Tre::deposit_unxv_with_rewards_for_epoch<TestBaseUSD>(&mut tre, &mut bot, 1, vec_unxv, b"epoch_unxv".to_string(), owner, ctx);

        let (_, unxv0) = Tre::epoch_reserves<TestBaseUSD>(&bot, 1);
        assert!(unxv0 == 500);

        // Pay out a portion of epoch reserves
        Tre::payout_epoch_shares<TestBaseUSD>(&mut bot, 1, 0, 200, owner, ctx);
        let (_, unxv1) = Tre::epoch_reserves<TestBaseUSD>(&bot, 1);
        assert!(unxv1 == 300);

        // consume linear resources
        sui::transfer::public_share_object(sc_cap);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        test_scenario::end(scen);
    }
}

#[test_only]
module unxversal::treasury_more_tests {
    use sui::test_scenario;
    use sui::coin::{Self as coin, Coin};
    use unxversal::treasury::{Self as Tre, Treasury};
    use unxversal::unxv::{Self as UNXVMod, UNXV};
    use unxversal::test_coins::TestBaseUSD;

    #[test, expected_failure]
    fun deposit_collateral_zero_amount_aborts() {
        let owner = @0xD1;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let zero = coin::mint_for_testing<TestBaseUSD>(0, ctx);
        Tre::deposit_collateral<TestBaseUSD>(&mut tre, zero, b"z".to_string(), owner, ctx);
        abort 0
    }

    #[test, expected_failure]
    fun deposit_unxv_zero_amount_aborts() {
        let owner = @0xD2;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut vec_unxv = vector::empty<Coin<UNXV>>();
        let zero_u: Coin<UNXV> = coin::mint_for_testing<UNXV>(0, ctx);
        vector::push_back(&mut vec_unxv, zero_u);
        Tre::deposit_unxv<TestBaseUSD>(&mut tre, vec_unxv, b"z".to_string(), owner, ctx);
        abort 0
    }

    #[test]
    fun auto_route_bps_cases_unxv() {
        let owner = @0xD3;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // bps = 0 → all to treasury
        {
            let mut tre0: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
            let mut bot0 = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
            Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre0, 0);
            let mut cap0 = UNXVMod::new_supply_cap_for_testing(ctx);
            let c0: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap0, 1000, ctx);
            let mut v0 = vector::empty<Coin<UNXV>>(); vector::push_back(&mut v0, c0);
            Tre::deposit_unxv_with_rewards<TestBaseUSD>(&mut tre0, &mut bot0, v0, b"t0".to_string(), owner, ctx);
            assert!(Tre::bot_balance_unxv<TestBaseUSD>(&bot0) == 0);
            assert!(Tre::tre_balance_unxv<TestBaseUSD>(&tre0) == 1000);
            sui::transfer::public_share_object(cap0);
            sui::transfer::public_share_object(tre0);
            sui::transfer::public_share_object(bot0);
        };

        // bps = 100 (1%) → 10 to bot, 990 to treasury
        {
            let mut tre1: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
            let mut bot1 = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
            Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre1, 100);
            let mut cap1 = UNXVMod::new_supply_cap_for_testing(ctx);
            let c1: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap1, 1000, ctx);
            let mut v1 = vector::empty<Coin<UNXV>>(); vector::push_back(&mut v1, c1);
            Tre::deposit_unxv_with_rewards<TestBaseUSD>(&mut tre1, &mut bot1, v1, b"t1".to_string(), owner, ctx);
            assert!(Tre::bot_balance_unxv<TestBaseUSD>(&bot1) == 10);
            assert!(Tre::tre_balance_unxv<TestBaseUSD>(&tre1) == 990);
            sui::transfer::public_share_object(cap1);
            sui::transfer::public_share_object(tre1);
            sui::transfer::public_share_object(bot1);
        };

        // bps = 10000 (100%) → all to bot
        {
            let mut tre2: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
            let mut bot2 = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
            Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre2, 10_000);
            let mut cap2 = UNXVMod::new_supply_cap_for_testing(ctx);
            let c2: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap2, 1000, ctx);
            let mut v2 = vector::empty<Coin<UNXV>>(); vector::push_back(&mut v2, c2);
            Tre::deposit_unxv_with_rewards<TestBaseUSD>(&mut tre2, &mut bot2, v2, b"t2".to_string(), owner, ctx);
            assert!(Tre::bot_balance_unxv<TestBaseUSD>(&bot2) == 1000);
            assert!(Tre::tre_balance_unxv<TestBaseUSD>(&tre2) == 0);
            sui::transfer::public_share_object(cap2);
            sui::transfer::public_share_object(tre2);
            sui::transfer::public_share_object(bot2);
        };

        test_scenario::end(scen);
    }

    #[test]
    fun auto_route_bps_cases_collateral_and_epoch() {
        let owner = @0xD4;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // bps = 10000 → all collateral to bot via deposit_collateral_with_rewards
        let mut tre: Treasury<TestBaseUSD> = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre, 10_000);
        let c = coin::mint_for_testing<TestBaseUSD>(500, ctx);
        Tre::deposit_collateral_with_rewards<TestBaseUSD>(&mut tre, &mut bot, c, b"c_all_bot".to_string(), owner, ctx);
        assert!(Tre::bot_balance_collateral<TestBaseUSD>(&bot) == 500);
        assert!(Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre) == 0);

        // epoch-aware collateral deposit with bps=50%
        Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre, 5_000);
        let c2 = coin::mint_for_testing<TestBaseUSD>(1_000, ctx);
        Tre::deposit_collateral_with_rewards_for_epoch<TestBaseUSD>(&mut tre, &mut bot, 7, c2, b"c_epoch".to_string(), owner, ctx);
        let (ecoll, _) = Tre::epoch_reserves<TestBaseUSD>(&bot, 7);
        assert!(ecoll == 500);
        assert!(Tre::bot_balance_collateral<TestBaseUSD>(&bot) >= ecoll);
        assert!(Tre::tre_balance_collateral_for_testing<TestBaseUSD>(&tre) == 500);

        // Full payout of epoch collateral
        Tre::payout_epoch_shares<TestBaseUSD>(&mut bot, 7, 500, 0, owner, ctx);
        let (ecoll_after, _) = Tre::epoch_reserves<TestBaseUSD>(&bot, 7);
        assert!(ecoll_after == 0);

        // Dust handling: fund epoch 9 with 101, pay 50 then 25, leaving 26
        Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre, 10_000);
        let c3 = coin::mint_for_testing<TestBaseUSD>(101, ctx);
        Tre::deposit_collateral_with_rewards_for_epoch<TestBaseUSD>(&mut tre, &mut bot, 9, c3, b"dust".to_string(), owner, ctx);
        Tre::payout_epoch_shares<TestBaseUSD>(&mut bot, 9, 50, 0, owner, ctx);
        Tre::payout_epoch_shares<TestBaseUSD>(&mut bot, 9, 25, 0, owner, ctx);
        let (ecoll9, _) = Tre::epoch_reserves<TestBaseUSD>(&bot, 9);
        assert!(ecoll9 == 26);

        // cleanup
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        test_scenario::end(scen);
    }
}

