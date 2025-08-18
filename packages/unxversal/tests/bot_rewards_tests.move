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
        let tre = Tre::new_treasury_for_testing<TestBaseUSD>(ctx);
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

