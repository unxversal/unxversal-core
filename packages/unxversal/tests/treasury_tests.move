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

