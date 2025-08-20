#[test_only]
module unxversal::vaults_tests {
    use sui::test_scenario;
    use sui::clock;
    use sui::coin::{Self as coin};
    use unxversal::vaults::{Self as V, ManagerStakeRegistry, Vault, VaultAssetStore};
    use unxversal::admin::{Self as Admin, AdminRegistry};
    use unxversal::unxv::UNXV;
    use unxversal::treasury::{Self as Tre, Treasury};
    use unxversal::test_coins::TestBaseUSD;

    #[test]
    fun vaults_stake_registry_and_vault_lifecycle() {
        let user = @0x31; let mut scen = test_scenario::begin(user);
        let clk = clock::create_for_testing(scen.ctx());
        let reg_admin: AdminRegistry = Admin::new_admin_registry_for_testing(scen.ctx());
        V::init_manager_stake_registry_admin(&reg_admin, 10, scen.ctx());
        let mut rs: ManagerStakeRegistry = test_scenario::take_shared<ManagerStakeRegistry>(&scen);
        // stake UNXV to reach min
        let mut v_unxv = vector::empty<sui::coin::Coin<UNXV>>();
        vector::push_back(&mut v_unxv, sui::coin::mint_for_testing<UNXV>(20, scen.ctx()));
        V::stake_unxv(&mut rs, v_unxv, &clk, scen.ctx());
        // create vault, deposit, withdraw, set frozen
        V::create_vault<TestBaseUSD>(&mut rs, 1000, &clk, scen.ctx());
        let mut v: Vault<TestBaseUSD> = test_scenario::take_shared<Vault<TestBaseUSD>>(&scen);
        V::set_vault_frozen(&rs, &mut v, false, &clk, scen.ctx());
        let pay = coin::mint_for_testing<TestBaseUSD>(1_000_000, scen.ctx());
        V::deposit_base(&mut v, pay, &clk, scen.ctx());
        let out = V::withdraw_shares(&mut v, 1000, &clk, scen.ctx());
        sui::transfer::public_transfer(out, user);
        // asset store flows
        let mut store: VaultAssetStore<TestBaseUSD, TestBaseUSD> = V::create_asset_store<TestBaseUSD, TestBaseUSD>(&rs, &v, scen.ctx());
        let asset = sui::coin::mint_for_testing<TestBaseUSD>(5, scen.ctx());
        V::deposit_asset<TestBaseUSD, TestBaseUSD>(&rs, &v, &mut store, asset, scen.ctx());
        V::withdraw_asset<TestBaseUSD, TestBaseUSD>(&rs, &v, &mut store, 2, scen.ctx());
        // slash stake
        let mut tre_unxv: Treasury<UNXV> = Tre::new_treasury_for_testing<UNXV>(scen.ctx());
        V::slash_stake_admin(&reg_admin, &mut rs, &mut tre_unxv, user, 5, &clk, scen.ctx());
        // cleanup
        sui::transfer::public_share_object(rs);
        sui::transfer::public_share_object(v);
        sui::transfer::public_share_object(store);
        sui::transfer::public_share_object(tre_unxv);
        sui::transfer::public_share_object(reg_admin);
        clock::destroy_for_testing(clk);
        test_scenario::end(scen);
    }
}


