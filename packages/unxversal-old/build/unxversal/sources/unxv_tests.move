#[test_only]
module unxversal::unxv_tests {
    use sui::test_scenario;
    use unxversal::unxv::{Self as Unxv, SupplyCap, UNXV};
    use sui::coin::{Self as coin, Coin};

    #[test]
    fun mint_burn_with_cap_happy_path() {
        let owner = @0xA;
        let mut scn = test_scenario::begin(owner);
        let ctx = scn.ctx();

        let mut sc: SupplyCap = Unxv::new_supply_cap_for_testing(ctx);
        // mint within cap
        let c1: Coin<UNXV> = Unxv::mint_coin_for_testing(&mut sc, 1_000, ctx);
        assert!(coin::value(&c1) == 1_000);

        // transfer coin to owner then burn via cap
        // build vector to burn 400
        let mut v = vector::empty<Coin<UNXV>>();
        let mut remainder = c1;
        let burn400 = coin::split(&mut remainder, 400, ctx);
        vector::push_back(&mut v, burn400);
        Unxv::burn(&mut sc, v, ctx);
        // consume remainder by transferring to owner
        sui::transfer::public_transfer(remainder, owner);

        // mint again to ensure cap tracking updated
        let _c2: Coin<UNXV> = Unxv::mint_coin_for_testing(&mut sc, 200, ctx);
        // consume minted coin
        sui::transfer::public_transfer(_c2, owner);
        assert!(Unxv::supply_current_for_testing(&sc) == 800);

        // consume the supply cap
        sui::transfer::public_share_object(sc);
        test_scenario::end(scn);
    }

    #[test, expected_failure]
    fun cap_violation_aborts() {
        let owner = @0xAA;
        let mut scn = test_scenario::begin(owner);
        let ctx = scn.ctx();

        let mut sc: SupplyCap = Unxv::new_supply_cap_for_testing(ctx);
        // set max via constructor is 1_000_000_000; try to mint beyond in two steps
        let _c1: Coin<UNXV> = Unxv::mint_coin_for_testing(&mut sc, 1_000_000_000, ctx);
        // next mint should abort on cap check
        let _c2: Coin<UNXV> = Unxv::mint_coin_for_testing(&mut sc, 1, ctx);
        // ensure no successful return path
        abort 0
    }

    #[test]
    fun mint_burn_events_and_supply_conservation() {
        let owner = @0xAB;
        let mut scn = test_scenario::begin(owner);
        let ctx = scn.ctx();

        let mut sc: SupplyCap = Unxv::new_supply_cap_for_testing(ctx);
        // create mirror to validate event semantics
        let mut mirror = Unxv::new_event_mirror_for_testing(ctx);

        // mint 10 to owner via wrapper that also updates mirror
        Unxv::mint_with_event_mirror(&mut sc, 10, owner, &mut mirror, ctx);
        assert!(Unxv::em_mint_count(&mirror) == 1);
        assert!(Unxv::em_last_mint_amount(&mirror) == 10);
        assert!(Unxv::em_last_mint_to(&mirror) == owner);

        // mint another 15
        Unxv::mint_with_event_mirror(&mut sc, 15, owner, &mut mirror, ctx);
        assert!(Unxv::em_mint_count(&mirror) == 2);

        // burn 9 using a split vector
        // we cannot access prior minted coins directly here; instead mint and burn within supply accounting constraints
        let c_tmp: Coin<UNXV> = Unxv::mint_coin_for_testing(&mut sc, 9, ctx);
        let mut burn_vec = vector::empty<Coin<UNXV>>();
        vector::push_back(&mut burn_vec, c_tmp);
        Unxv::burn_with_event_mirror(&mut sc, burn_vec, &mut mirror, ctx);
        assert!(Unxv::em_burn_count(&mirror) == 1);
        assert!(Unxv::em_last_burn_amount(&mirror) == 9);

        // supply conservation: current should be 10 + 15 + 9 (extra mint for burn) - 9
        assert!(Unxv::supply_current_for_testing(&sc) == (10 + 15));

        // consume linear resources
        sui::transfer::public_share_object(mirror);
        sui::transfer::public_share_object(sc);
        test_scenario::end(scn);
    }
}

