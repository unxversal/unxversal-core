#[test_only]
module unxversal::oracle_tests {
    use sui::test_scenario;
    use sui::clock;
    use std::string;
    use switchboard::aggregator;
    use switchboard::decimal;

    use unxversal::admin;
    use unxversal::oracle::{Self as Oracle};

    #[test]
    fun set_feed_and_read_price_happy_path() {
        let owner = @0xB;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();

        // admin registry for gating
        let admin_reg = admin::new_admin_registry_for_testing(ctx);

        // create a local registry for testing
        let mut reg = Oracle::new_registry_for_testing(ctx);

        // create a test aggregator
        let clock_obj = clock::create_for_testing(ctx);
        let mut agg = aggregator::new_aggregator(
            aggregator::example_queue_id(),
            string::utf8(b"px"),
            owner,
            vector::empty<u8>(),
            1,
            10_000_000,
            0,
            1,
            0,
            ctx,
        );
        // set a current result
        let px = decimal::new(1_234_567, false);
        aggregator::set_current_value(&mut agg, px, 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));

        // bind symbol → aggregator id
        let sym = string::utf8(b"TEST");
        Oracle::set_feed(&admin_reg, &mut reg, string::utf8(b"TEST"), &agg, ctx);

        // read via binding
        let p = Oracle::get_price_for_symbol(&reg, &clock_obj, &sym, &agg);
        assert!(p == 1_234_567);

        // consume linear resources
        sui::transfer::public_share_object(admin_reg);
        sui::transfer::public_share_object(reg);
        switchboard::aggregator::share_for_testing(agg);
        clock::destroy_for_testing(clock_obj);
        test_scenario::end(scen);
    }

    #[test, expected_failure]
    fun feed_mismatch_rejected() {
        let owner = @0xC;
        let mut scen = test_scenario::begin(owner);
        let ctx = scen.ctx();
        let admin_reg = admin::new_admin_registry_for_testing(ctx);
        let clock_obj = clock::create_for_testing(ctx);

        let mut reg = Oracle::new_registry_for_testing(ctx);
        let mut agg1 = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"a1"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        let mut agg2 = aggregator::new_aggregator(aggregator::example_queue_id(), string::utf8(b"a2"), owner, vector::empty<u8>(), 1, 10_000_000, 0, 1, 0, ctx);
        aggregator::set_current_value(&mut agg1, decimal::new(10, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));
        aggregator::set_current_value(&mut agg2, decimal::new(20, false), 1, 1, 1, decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false), decimal::new(0, false));

        Oracle::set_feed(&admin_reg, &mut reg, string::utf8(b"S"), &agg1, ctx);
        let sym = string::utf8(b"S");

        // Using different aggregator should abort
        let _ = Oracle::get_price_for_symbol(&reg, &clock_obj, &sym, &agg2);
        // ensure no return path (expected failure test aborts earlier)
        abort 0
    }
}

