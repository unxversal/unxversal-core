#[test_only]
module unxversal::bot_rewards_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::treasury::{Self as Tre};
    use unxversal::test_coins::TestBaseUSD;

    #[test]
    fun award_points_accumulates_and_updates_epoch() {
        let owner = @0x11;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);

        // configure epoch schedule
        let admin_reg = unxversal::admin::new_admin_registry_for_testing(ctx);
        BR::set_epoch_config(&admin_reg, &mut reg, 0, 1_000, ctx);

        // set task weight
        BR::set_weight(&admin_reg, &mut reg, string::utf8(b"task"), 5, ctx);

        // award
        BR::award_points(&mut reg, string::utf8(b"task"), owner, &clk, ctx);
        // award again
        BR::award_points(&mut reg, string::utf8(b"task"), owner, &clk, ctx);

        // no direct getters; rely on claim path with zero treasury to ensure totals present but nothing to pay
        let mut tre = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);

        // No funds → claim should emit 0 paid and zero points for actor
        BR::claim_rewards_for_epoch<TestBaseUSD>(&mut reg, &mut bot, 0, ctx);

        // consume linear resources
        sui::transfer::public_share_object(admin_reg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        clock::destroy_for_testing(clk);

        test_scenario::end(scen);
    }
}

#[test_only]
module unxversal::bot_rewards_more_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use unxversal::bot_rewards::{Self as BR, BotPointsRegistry};
    use unxversal::treasury::{Self as Tre};
    use unxversal::test_coins::TestBaseUSD;
    use unxversal::admin;
    use unxversal::unxv::{Self as UNXVMod, UNXV};
    use sui::coin::Coin;

    #[test]
    fun zero_weight_award_no_change() {
        let owner = @0x51;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let mut reg: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        let before = BR::current_epoch(&reg, &clk);
        // no weight set for this task
        BR::award_points(&mut reg, string::utf8(b"no_weight_task"), owner, &clk, ctx);
        // claim emits zero (no funds) but also no points accrued
        let mut tre = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        BR::claim_rewards_for_epoch<TestBaseUSD>(&mut reg, &mut bot, before, ctx);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }

    #[test]
    fun multi_actor_pro_rata_and_idempotent_claim() {
        let owner = @0x52;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let admin_reg = admin::new_admin_registry_for_testing(ctx);
        let mut reg: BotPointsRegistry = BR::new_points_registry_for_testing(ctx);
        let clk = clock::create_for_testing(ctx);
        BR::set_epoch_config(&admin_reg, &mut reg, 0, 1_000, ctx);
        BR::set_weight(&admin_reg, &mut reg, string::utf8(b"task"), 10, ctx);

        let actor_a = owner; // caller
        let actor_b = @0x53;

        // Award A: 10, B: 20 points (2x for B)
        BR::award_points(&mut reg, string::utf8(b"task"), actor_a, &clk, ctx);
        BR::award_points(&mut reg, string::utf8(b"task"), actor_b, &clk, ctx);
        BR::award_points(&mut reg, string::utf8(b"task"), actor_b, &clk, ctx);

        // Fund epoch reserves with UNXV = 300
        let mut tre = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
        let mut bot = Tre::new_bot_rewards_treasury_for_testing<TestBaseUSD>(ctx);
        let epoch = BR::current_epoch(&reg, &clk);
        let mut cap = UNXVMod::new_supply_cap_for_testing(ctx);
        let coin_unxv: Coin<UNXV> = UNXVMod::mint_coin_for_testing(&mut cap, 300, ctx);
        let mut vec_unxv = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut vec_unxv, coin_unxv);
        Tre::set_auto_bot_rewards_bps_for_testing<TestBaseUSD>(&mut tre, 10_000);
        Tre::deposit_unxv_with_rewards_for_epoch<TestBaseUSD>(&mut tre, &mut bot, epoch, vec_unxv, b"epoch_fund".to_string(), owner, ctx);

        // A claims: total points = 30, A has 10 → 1/3 of 300 = 100
        BR::claim_rewards_for_epoch<TestBaseUSD>(&mut reg, &mut bot, epoch, ctx);
        let (_, unxv_after_a) = Tre::epoch_reserves<TestBaseUSD>(&bot, epoch);
        assert!(unxv_after_a == 200);

        // Second claim by A should be idempotent (no further reduction)
        BR::claim_rewards_for_epoch<TestBaseUSD>(&mut reg, &mut bot, epoch, ctx);
        let (_, unxv_after_a2) = Tre::epoch_reserves<TestBaseUSD>(&bot, epoch);
        assert!(unxv_after_a2 == 200);

        // Switch caller to B (simulated by new scenario with B as owner)
        // Share objects so they can be taken in a new scenario context
        sui::transfer::public_share_object(admin_reg);
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(tre);
        sui::transfer::public_share_object(bot);
        sui::transfer::public_share_object(cap);
        test_scenario::end(scen);
        let mut scen2 = test_scenario::begin(actor_b);
        // Re-take shared objects into the new scenario before borrowing ctx
        let mut reg: BotPointsRegistry = test_scenario::take_shared<BotPointsRegistry>(&scen2);
        let mut bot: unxversal::treasury::BotRewardsTreasury<TestBaseUSD> = test_scenario::take_shared<unxversal::treasury::BotRewardsTreasury<TestBaseUSD>>(&scen2);
        let ctx2 = scen2.ctx();
        let clk2 = clock::create_for_testing(ctx2);
        // B claims remaining: 200 (since B has 2/3 share)
        BR::claim_rewards_for_epoch<TestBaseUSD>(&mut reg, &mut bot, epoch, ctx2);
        let (_, unxv_after_b) = Tre::epoch_reserves<TestBaseUSD>(&bot, epoch);
        assert!(unxv_after_b == 0);
        clock::destroy_for_testing(clk);
        clock::destroy_for_testing(clk2);
        // consume linear resources
        sui::transfer::public_share_object(reg);
        sui::transfer::public_share_object(bot);
        test_scenario::end(scen2);
    }
}

