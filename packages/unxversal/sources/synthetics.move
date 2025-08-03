/// Module: **unxversal_synthetics** — Phase‑1
/// ------------------------------------------------------------
/// * Bootstraps the core **SynthRegistry** shared object
/// * Establishes the **DaddyCap → admin‑address allow‑list** authority pattern
/// * Provides basic governance (grant/revoke admin, global‑params update, pause)
///
/// > Later phases will extend this module with asset‑listing, vaults,
/// > mint/burn logic, liquidation flows, DeepBook integration, etc.
module unxversal::synthetics {
    /*******************************
    * Imports & std aliases
    *******************************/
    use sui::tx_context::TxContext;         // build tx‑local objects / emit events
    use sui::transfer;                     // public_transfer, share_object helpers
    use sui::package;                      // claim Publisher via OTW
    use sui::display;                      // Object‑Display metadata helpers
    use sui::object;                       // object::new / delete
    use sui::types;                        // is_one_time_witness check
    use sui::event;                        // emit events
    use std::string::String;
    use std::vec_set::{Self as VecSet, VecSet};
    use std::table::{Self as Table, Table};
    use std::time;                         // now_ms helper

    /*******************************
    * Error codes (0‑99 reserved for general)
    *******************************/
    const E_NOT_ADMIN: u64 = 1;            // Caller not in admin allow‑list

    /*******************************
    * One‑Time Witness (OTW)
    * Guarantees `init` executes exactly once when the package is published.
    *******************************/
    public struct SYNTHETICS has drop {}

    /*******************************
    * Capability & authority objects
    *******************************/
    /// **DaddyCap** – the root capability.  Only one exists.
    /// Possession allows minting / revoking admin rights by modifying the
    /// `admin_addrs` allow‑list inside `SynthRegistry`.
    public struct DaddyCap has key, store { id: UID }

    /// **AdminCap** – a wallet‑visible token that proves the holder *should*
    /// be an admin **for UX purposes only**.  Effective authority is enforced
    /// by checking that the caller’s `address` is in `registry.admin_addrs`.
    /// If the DaddyCap holder removes an address from the allow‑list, any
    /// AdminCap tokens that address still holds become inert.
    public struct AdminCap has key, store { id: UID }

    /*******************************
    * Global‑parameter struct (basis‑points units for ratios/fees)
    *******************************/
    public struct GlobalParams has store {
        /// Minimum collateral‑ratio across the system (e.g. **150% = 1500 bps**)
        min_collateral_ratio: u64,
        /// Threshold below which liquidation can be triggered (**1200 bps**)
        liquidation_threshold: u64,
        /// Penalty applied to seized collateral (**500 bps = 5%**)
        liquidation_penalty: u64,
        /// Maximum number of synthetic asset types the registry will accept
        max_synthetics: u64,
        /// Annual stability fee (interest) charged on outstanding debt (bps)
        stability_fee: u64,
        /// % of liquidation proceeds awarded to bots (e.g. **1 000 bps = 10%**)
        bot_split: u64,
        /// One‑off fee charged on mint operations (bps)
        mint_fee: u64,
        /// One‑off fee charged on burn operations (bps)
        burn_fee: u64,
    }

    /*******************************
    * Synthetic‑asset placeholder (filled out in Phase‑2)
    * NOTE: only minimal fields kept for now so the table type is defined.
    *******************************/
    public struct SyntheticAsset has store {
        name: String,
        symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_collateral_ratio: u64,
        total_supply: u64,
        is_active: bool,
        created_at: u64,
    }

    /*******************************
    * Core shared object – **SynthRegistry**
    *******************************/
    public struct SynthRegistry has key, store {
        /// UID so we can share the object on‑chain.
        id: UID,
        /// Map **symbol → SyntheticAsset** definitions.
        synthetics: Table<String, SyntheticAsset>,
        /// Map **symbol → Pyth feed bytes** for oracle lookup.
        oracle_feeds: Table<String, vector<u8>>,
        /// System‑wide configurable risk / fee parameters.
        global_params: GlobalParams,
        /// Emergency‑circuit‑breaker flag.
        paused: bool,
        /// Addresses approved as admins (DaddyCap manages this set).
        admin_addrs: VecSet<address>,
    }

    /*******************************
    * Event structs for indexers / UI
    *******************************/
    public struct AdminGranted has copy, drop { admin_addr: address, timestamp: u64 }
    public struct AdminRevoked has copy, drop { admin_addr: address, timestamp: u64 }
    public struct ParamsUpdated has copy, drop { updater: address, timestamp: u64 }
    public struct EmergencyPauseToggled has copy, drop { new_state: bool, by: address, timestamp: u64 }

    /*******************************
    * Internal helper – assert caller is in allow‑list
    *******************************/
    fun assert_is_admin(registry: &SynthRegistry, addr: address) {
        assert!(VecSet::contains(&registry.admin_addrs, addr), E_NOT_ADMIN);
    }

    /*******************************
    * INIT  – executed once on package publish
    *******************************/
    fun init(otw: SYNTHETICS, ctx: &mut TxContext) {
        // 1️⃣ Ensure we really received the one‑time witness
        assert!(types::is_one_time_witness(&otw), 0);

        // 2️⃣ Claim a Publisher object (needed for Display metadata)
        let publisher = package::claim(otw, ctx);

        // 3️⃣ Bootstrap default global parameters (tweak in upgrades)
        let params = GlobalParams {
            min_collateral_ratio: 1_500,      // 150 %
            liquidation_threshold: 1_200,     // 120 %
            liquidation_penalty: 500,         // 5 %
            max_synthetics: 100,
            stability_fee: 200,               // 2 % APY
            bot_split: 4_000,                 // 10 %
            mint_fee: 50,                     // 0.5 %
            burn_fee: 30,                     // 0.3 %
        };

        // 4️⃣ Create empty tables and admin allow‑list (deployer is first admin)
        let syn_table = Table::new::<String, SyntheticAsset>(ctx);
        let feed_table = Table::new::<String, vector<u8>>(ctx);
        let mut admins = VecSet::empty();
        VecSet::add(&mut admins, ctx.sender());

        // 5️⃣ Share the SynthRegistry object
        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: syn_table,
            oracle_feeds: feed_table,
            global_params: params,
            paused: false,
            admin_addrs: admins,
        };
        transfer::share_object(registry);

        // 6️⃣ Mint capabilities to deployer (DaddyCap + UX AdminCap token)
        transfer::public_transfer(DaddyCap { id: object::new(ctx) }, ctx.sender());
        transfer::public_transfer(AdminCap  { id: object::new(ctx) }, ctx.sender());

        // 7️⃣ Register Display metadata so wallets can render the registry nicely
        let mut disp = display::new<SynthRegistry>(&publisher, ctx);
        disp.add(b"name".to_string(),           b"Unxversal Synthetics Registry".to_string());
        disp.add(b"description".to_string(),    b"Central registry storing all synthetic assets listed by Unxversal".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(publisher, ctx.sender());
        transfer::public_transfer(disp, ctx.sender());
    }

    /*******************************
    * Daddy‑level admin management
    *******************************/
    /// Mint a new AdminCap **and** add `new_admin` to `admin_addrs`.
    /// Can only be invoked by the unique DaddyCap holder.
    public entry fun grant_admin(
        daddy: &DaddyCap,
        registry: &mut SynthRegistry,
        new_admin: address,
        ctx: &mut TxContext
    ) {
        VecSet::add(&mut registry.admin_addrs, new_admin);
        transfer::public_transfer(AdminCap { id: object::new(ctx) }, new_admin);
        event::emit(AdminGranted { admin_addr: new_admin, timestamp: time::now_ms() });
    }

    /// Remove an address from the allow‑list. Any AdminCap tokens that
    /// address still controls become decorative.
    public entry fun revoke_admin(
        daddy: &DaddyCap,
        registry: &mut SynthRegistry,
        bad_admin: address
    ) {
        VecSet::remove(&mut registry.admin_addrs, bad_admin);
        event::emit(AdminRevoked { admin_addr: bad_admin, timestamp: time::now_ms() });
    }

    /*******************************
    * Parameter updates & emergency pause – gated by allow‑list
    *******************************/
    /// Replace **all** global parameters. Consider granular setters in future.
    public entry fun update_global_params(
        registry: &mut SynthRegistry,
        new_params: GlobalParams,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        registry.global_params = new_params;
        event::emit(ParamsUpdated { updater: ctx.sender(), timestamp: time::now_ms() });
    }

    /// Flip the `paused` flag on. Prevents state‑changing funcs in later phases.
    public entry fun emergency_pause(registry: &mut SynthRegistry, ctx: &TxContext) {
        assert_is_admin(registry, ctx.sender());
        registry.paused = true;
        event::emit(EmergencyPauseToggled { new_state: true, by: ctx.sender(), timestamp: time::now_ms() });
    }

   /// Turn the circuit breaker **off**.
    public entry fun resume(registry: &mut SynthRegistry, ctx: &TxContext) {
        assert_is_admin(registry, ctx.sender());
        registry.paused = false;
        event::emit(EmergencyPauseToggled { new_state: false, by: ctx.sender(), timestamp: time::now_ms() });
    }
}
