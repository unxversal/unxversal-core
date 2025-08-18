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
        let mut c_split = coin::split(&mut { let tmp = c1; tmp }, 400, ctx);
        // we consumed c1 by moving; reconstruct remainder with zero join for clarity
        // Note: above move pattern ensures we pass the split coin for burn
        vector::push_back(&mut v, c_split);
        Unxv::burn(&mut sc, v, ctx);

        // mint again to ensure cap tracking updated
        let _c2: Coin<UNXV> = Unxv::mint_coin_for_testing(&mut sc, 200, ctx);
        assert!(sc.current == 800 + 200);

        test_scenario::end(scn);
    }
}

