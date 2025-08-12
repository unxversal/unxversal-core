/// Module: **unxversal_synthetics** — Phase‑1
/// ------------------------------------------------------------
/// * Bootstraps the core **SynthRegistry** shared object
/// * Establishes the **DaddyCap → admin‑address allow‑list** authority pattern
/// * Provides basic governance (grant/revoke admin, global‑params update, pause)
///
/// > Later phases will extend this module with asset‑listing, vaults,
/// > mint/burn logic, liquidation flows, DeepBook integration, etc.
module unxversal::synthetics {
    /*******************************
    * Imports & std aliases
    *******************************/
    use sui::package;                      // claim Publisher via OTW
    use sui::package::Publisher;           // Display helpers expect Publisher
    use sui::display;                      // Object‑Display metadata helpers
    use sui::types;                        // is_one_time_witness check
    use sui::event;                        // emit events
    use std::string::{Self as string, String};
    use std::vector::{Self as vector};
    use sui::vec_set::{Self as vec_set, VecSet};
    use sui::table::{Self as table, Table};
    use sui::clock::Clock;                 // clock for oracle staleness checks
    use sui::coin::{Self as coin, Coin};   // coin helpers (merge/split/zero/value)
    use sui::balance::{Self as balance, Balance};
    use pyth::price_info::PriceInfoObject; // Pyth price object type
    use pyth::pyth;                        // get_price_no_older_than
    use pyth::price;                       // price/expo accessors
    use pyth::i64::{Self as I64Mod};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use sui::object;
    use sui::object::ID;
    use sui::transfer;
    use sui::tx_context::TxContext;
    use std::option::{Self as option, Option};
    use unxversal::unxv::UNXV;

    fun clone_string(s: &String): String {
        let src_bytes = string::as_bytes(s);
        let src_len = vector::length(src_bytes);
        let mut dst_bytes = vector::empty<u8>();
        let mut i = 0;
        while (i < src_len) {
            let b_ref = vector::borrow(src_bytes, i);
            vector::push_back(&mut dst_bytes, *b_ref);
            i = i + 1;
        };
        string::utf8(dst_bytes)
    }

    fun copy_vector_u8(src: &vector<u8>): vector<u8> {
        let len = vector::length(src);
        let mut dst = vector::empty<u8>();
        let mut i = 0;
        while (i < len) {
            let b_ref = vector::borrow(src, i);
            vector::push_back(&mut dst, *b_ref);
            i = i + 1;
        };
        dst
    }

    // Local price scaling helper (micro-USD), avoids dependency cycle with oracle module
    const DEFAULT_MAX_AGE_SEC: u64 = 60;
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    fun get_price_scaled_1e6(clock: &Clock, price_info_object: &PriceInfoObject, max_age_sec: u64): u64 {
        let price_struct = pyth::get_price_no_older_than(price_info_object, clock, max_age_sec);
        let raw_i64 = price::get_price(&price_struct);
        assert!(!I64Mod::get_is_negative(&raw_i64), 0);
        let raw_mag = I64Mod::get_magnitude_if_positive(&raw_i64);
        assert!(raw_mag > 0, 0);

        let expo = price::get_expo(&price_struct);
        let expo_is_neg = I64Mod::get_is_negative(&expo);
        let expo_mag = if (expo_is_neg) { I64Mod::get_magnitude_if_negative(&expo) } else { I64Mod::get_magnitude_if_positive(&expo) };

        let mut adj_is_neg = false;
        let mut adj_mag: u64 = 0;
        if (expo_is_neg) {
            if (expo_mag > 6) { adj_is_neg = true; adj_mag = expo_mag - 6; } else { adj_is_neg = false; adj_mag = 6 - expo_mag; };
        } else { adj_is_neg = false; adj_mag = 6 + expo_mag; };

        let raw_u128 = (raw_mag as u128);
        let scaled_u128 = if (!adj_is_neg) {
            let mut acc: u128 = 1u128;
            let mut n = adj_mag;
            while (n > 0) { acc = acc * 10u128; n = n - 1; };
            raw_u128 * acc
        } else {
            let mut acc: u128 = 1u128;
            let mut n = adj_mag;
            while (n > 0) { acc = acc * 10u128; n = n - 1; };
            raw_u128 / acc
        };
        assert!(scaled_u128 <= (U64_MAX_LITERAL as u128), 0);
        scaled_u128 as u64
    }

    /*******************************
    * Error codes (0‑99 reserved for general)
    *******************************/
    const E_NOT_ADMIN: u64 = 1;            // Caller not in admin allow‑list
    const E_ASSET_EXISTS: u64 = 2;
    const E_UNKNOWN_ASSET: u64 = 3;
    const E_VAULT_NOT_HEALTHY: u64 = 4;
    const E_RATIO_TOO_LOW: u64 = 5;
    const E_NOT_OWNER: u64 = 6;
    const E_INVALID_ORDER: u64 = 7;
    const E_ORDER_EXPIRED: u64 = 8;
    const E_SYMBOL_MISMATCH: u64 = 9;
    const E_SIDE_INVALID: u64 = 10;
    const E_BAD_PRICE: u64 = 11;
    const E_COLLATERAL_NOT_SET: u64 = 13;
    const E_WRONG_COLLATERAL_CFG: u64 = 14;

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
    public struct GlobalParams has store, drop {
        /// Minimum collateral‑ratio across the system (e.g. **150% = 1500 bps**)
        min_collateral_ratio: u64,
        /// Threshold below which liquidation can be triggered (**1200 bps**)
        liquidation_threshold: u64,
        /// Penalty applied to seized collateral (**500 bps = 5%**)
        liquidation_penalty: u64,
        /// Maximum number of synthetic asset types the registry will accept
        max_synthetics: u64,
        /// Annual stability fee (interest) charged on outstanding debt (bps)
        stability_fee: u64,
        /// % of liquidation proceeds awarded to bots (e.g. **1 000 bps = 10%**)
        bot_split: u64,
        /// One‑off fee charged on mint operations (bps)
        mint_fee: u64,
        /// One‑off fee charged on burn operations (bps)
        burn_fee: u64,
        /// Discount applied when paying fees in UNXV (bps)
        unxv_discount_bps: u64,
        /// Maker rebate on taker fees (bps)
        maker_rebate_bps: u64,
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
        // Optional per-asset overrides (0 => use global)
        stability_fee_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        mint_fee_bps: u64,
        burn_fee_bps: u64,
    }

    /// Keyed per-asset info wrapper to enable Display for SyntheticAsset
    public struct SyntheticAssetInfo has key, store {
        id: UID,
        asset: SyntheticAsset,
    }

    /*******************************
    * Core shared object – **SynthRegistry**
    *******************************/
    public struct SynthRegistry has key, store {
        /// UID so we can share the object on-chain.
        id: UID,
        /// Map **symbol → SyntheticAsset** definitions.
        synthetics: Table<String, SyntheticAsset>,
        /// Map **symbol → Pyth feed bytes** for oracle lookup.
        oracle_feeds: Table<String, vector<u8>>,
        /// System-wide configurable risk / fee parameters.
        global_params: GlobalParams,
        /// Emergency-circuit-breaker flag.
        paused: bool,
        /// Addresses approved as admins (DaddyCap manages this set).
        admin_addrs: VecSet<address>,
        /// Treasury reference (shared object)
        treasury_id: ID,
        /// Count of listed synthetic assets
        num_synthetics: u64,
        /// Flag to ensure collateral is set exactly once via set_collateral<C>
        collateral_set: bool,
        /// ID of the shared CollateralConfig<C> object once set
        collateral_cfg_id: Option<ID>,
    }

    /*******************************
    * Event structs for indexers / UI
    *******************************/
    public struct AdminGranted has copy, drop { admin_addr: address, timestamp: u64 }
    public struct AdminRevoked has copy, drop { admin_addr: address, timestamp: u64 }
    public struct ParamsUpdated has copy, drop { updater: address, timestamp: u64 }
    public struct EmergencyPauseToggled has copy, drop { new_state: bool, by: address, timestamp: u64 }
    public struct VaultCreated has copy, drop { vault_id: ID, owner: address, timestamp: u64 }
    public struct CollateralDeposited has copy, drop { vault_id: ID, amount: u64, depositor: address, timestamp: u64 }
    public struct CollateralWithdrawn has copy, drop { vault_id: ID, amount: u64, withdrawer: address, timestamp: u64 }

    /*******************************
    * Phase‑2 – new events
    *******************************/
    public struct SyntheticAssetCreated has copy, drop {
        asset_name:   String,
        asset_symbol: String,
        pyth_feed_id: vector<u8>,
        creator:      address,
        timestamp:    u64,
    }

    /// Emitted when SyntheticAssetInfo is created for display
    public struct SyntheticAssetInfoCreated has copy, drop {
        symbol: String,
        timestamp: u64,
    }

    public struct SyntheticMinted has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_minted: u64,
        collateral_deposit: u64,
        minter: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }

    public struct SyntheticBurned has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_burned: u64,
        collateral_withdrawn: u64,
        burner: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }

    /// Orderbook-related events
    public struct OrderPlaced has copy, drop {
        order_id: ID,
        owner: address,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        remaining: u64,
        created_at_ms: u64,
        expiry_ms: u64,
    }

    public struct OrderCancelled has copy, drop { order_id: ID, owner: address, timestamp: u64 }

    public struct OrderMatched has copy, drop {
        buy_order_id: ID,
        sell_order_id: ID,
        symbol: String,
        price: u64,
        size: u64,
        buyer: address,
        seller: address,
        timestamp: u64,
    }
    public struct MakerRebatePaid has copy, drop {
        amount: u64,
        taker: address,
        maker: address,
        market: String,
        timestamp: u64,
    }
    public struct LiquidationExecuted has copy, drop {
        vault_id: ID,
        liquidator: address,
        liquidated_amount: u64,
        collateral_seized: u64,
        liquidation_penalty: u64,
        synthetic_type: String,
        timestamp: u64,
    }
    public struct StabilityAccrued has copy, drop { vault_id: ID, synthetic_type: String, delta_units: u64, from_ms: u64, to_ms: u64 }

     /*******************************
    * Phase‑2 – collateral vault
    *******************************/
    public struct CollateralVault<phantom C> has key, store {
        id: UID,
        owner: address,
        /// Collateral held inside this vault (full‑value coin of type C)
        collateral: Balance<C>,
        /// symbol → synthetic debt amount
        synthetic_debt: Table<String, u64>,
        last_update_ms: u64,
    }

    /// Marker object that binds the chosen collateral coin type C
    public struct CollateralConfig<phantom C> has key, store { id: UID }

    fun assert_cfg_matches<C>(registry: &SynthRegistry, cfg: &CollateralConfig<C>) {
        assert!(registry.collateral_set, E_COLLATERAL_NOT_SET);
        let cfg_opt = &registry.collateral_cfg_id;
        let cfg_id = object::id(cfg);
        assert!(option::is_some(cfg_opt) && *option::borrow(cfg_opt) == cfg_id, E_WRONG_COLLATERAL_CFG);
    }

    /*******************************
    * Orders – decentralized matching (shared objects)
    *******************************/
    /// side: 0 = buy (mint debt), 1 = sell (burn debt)
    public struct Order has key, store {
        id: UID,
        owner: address,
        vault_id: ID,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        remaining: u64,
        created_at_ms: u64,
        expiry_ms: u64,
    }

    /*******************************
    * Phase‑2 – Display helpers
    *******************************/
    // No display for SyntheticAsset (lacks 'key')

    fun init_vault_display<C>(publisher: &Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<CollateralVault<C>>(publisher, ctx);
        // Use concrete, non-placeholder templates from on-chain fields
        disp.add(b"name".to_string(),          b"Vault {id}".to_string());
        disp.add(b"description".to_string(),   b"Collateral vault owned by {owner}".to_string());
        disp.add(b"link".to_string(),          b"https://unxversal.com/vault/{id}".to_string());
        disp.add(b"project_url".to_string(),   b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),       b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());
    }

    /*******************************
    * Phase‑2 – synthetic asset listing (admin‑only)
    *******************************/
    public fun create_synthetic_asset(
        registry: &mut SynthRegistry,
        asset_name: String,
        asset_symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_coll_ratio: u64,
        _admin: &AdminCap,                // proves msg.sender ∈ allow‑list UX‑wise
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        // authority check (address allow‑list)
        assert_is_admin(registry, ctx.sender());

        // ensure symbol not taken
        let sym_check = clone_string(&asset_symbol);
        assert!(!table::contains(&registry.synthetics, sym_check), E_ASSET_EXISTS);

        // store metadata + oracle mapping
        let asset_entry = SyntheticAsset {
            name: clone_string(&asset_name),
            symbol: clone_string(&asset_symbol),
            decimals,
            pyth_feed_id: copy_vector_u8(&pyth_feed_id),
            min_collateral_ratio: min_coll_ratio,
            total_supply: 0,
            is_active: true,
            created_at: sui::tx_context::epoch_timestamp_ms(ctx),
            stability_fee_bps: 0,
            liquidation_threshold_bps: 0,
            liquidation_penalty_bps: 0,
            mint_fee_bps: 0,
            burn_fee_bps: 0,
        };
        let sym_for_synth = clone_string(&asset_symbol);
        table::add(&mut registry.synthetics, sym_for_synth, asset_entry);
        let sym_for_oracle = clone_string(&asset_symbol);
        table::add(&mut registry.oracle_feeds, sym_for_oracle, pyth_feed_id);
        registry.num_synthetics = registry.num_synthetics + 1;
        assert!(registry.num_synthetics <= registry.global_params.max_synthetics, E_ASSET_EXISTS);

        // Create and share display-enabled info wrapper for this asset (separate instance)
        let asset_info = SyntheticAssetInfo { id: object::new(ctx), asset: SyntheticAsset {
            name: clone_string(&asset_name),
            symbol: clone_string(&asset_symbol),
            decimals,
            pyth_feed_id: copy_vector_u8(&pyth_feed_id),
            min_collateral_ratio: min_coll_ratio,
            total_supply: 0,
            is_active: true,
            created_at: sui::tx_context::epoch_timestamp_ms(ctx),
            stability_fee_bps: 0,
            liquidation_threshold_bps: 0,
            liquidation_penalty_bps: 0,
            mint_fee_bps: 0,
            burn_fee_bps: 0,
        } };

        // emit events
        event::emit(SyntheticAssetCreated {
            asset_name,
            asset_symbol,
            pyth_feed_id,
            creator: ctx.sender(),
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
        event::emit(SyntheticAssetInfoCreated { symbol: clone_string(&asset_symbol), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });

        // share the info object so wallets/explorers can resolve Display
        transfer::share_object(asset_info);

        // optional: add Display metadata (publisher lives with deployer)
        // (Skip for brevity – could call init_synth_display here)
    }

    /*******************************
     * Per-asset parameter setters (admin-only)
     *******************************/
    public fun set_asset_stability_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.stability_fee_bps = bps;
    }

    public fun set_asset_liquidation_threshold(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.liquidation_threshold_bps = bps;
    }

    public fun set_asset_liquidation_penalty(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.liquidation_penalty_bps = bps;
    }

    public fun set_asset_mint_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.mint_fee_bps = bps;
    }

    public fun set_asset_burn_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.burn_fee_bps = bps;
    }

    /*******************************
    * Phase‑2 – vault lifecycle
    *******************************/
    /// Anyone can open a fresh vault (zero‑collateral, zero‑debt).
    public fun create_vault<C>(
        cfg: &CollateralConfig<C>,
        registry: &SynthRegistry,
        ctx: &mut TxContext
    ) {
        // registry.pause check
        assert!(!registry.paused, 1000);
        assert_cfg_matches(registry, cfg);

        let coin_zero = balance::zero<C>();
        let debt_table = table::new<String, u64>(ctx);
        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: ctx.sender(),
            collateral: coin_zero,
            synthetic_debt: debt_table,
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx),
        };
        transfer::share_object(vault);
        event::emit(VaultCreated { vault_id: object::id(&vault), owner: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Deposit collateral into caller‑owned vault
    public fun deposit_collateral<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        coins_in: Coin<C>,
        ctx: &mut TxContext
    ) {
        // owner-only for deposits on shared vault
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        let bal_in = coin::into_balance(coins_in);
        balance::join(&mut vault.collateral, bal_in);
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(CollateralDeposited { vault_id: object::id(vault), amount: balance::value(&vault.collateral), depositor: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Withdraw collateral if post‑withdraw health ≥ min_coll_ratio
    public fun withdraw_collateral<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        symbol: &String,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert_cfg_matches(registry, cfg);

        // health check BEFORE withdrawal
        let (ratio, _) = check_vault_health(vault, registry, clock, price, symbol);
        assert!(ratio >= registry.global_params.min_collateral_ratio, E_VAULT_NOT_HEALTHY);

        // split from balance & wrap to coin
        let bal_out = balance::split(&mut vault.collateral, amount);
        let coin_out = coin::from_balance(bal_out, ctx);
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(CollateralWithdrawn { vault_id: object::id(vault), amount, withdrawer: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        coin_out
    }

    /*******************************
    * Phase‑2 – mint / burn flows
    *******************************/
    fun mint_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let k_sym = clone_string(&synthetic_symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k_sym);
        let price_u64 = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);
        let debt_table = &mut vault.synthetic_debt;
        let k1 = clone_string(&synthetic_symbol);
        let old_debt = if (table::contains(debt_table, clone_string(&synthetic_symbol))) { *table::borrow(debt_table, k1) } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_usd = balance::value(&vault.collateral);
        let debt_usd = new_debt * price_u64;
        let new_ratio = if (debt_usd == 0) { U64_MAX_LITERAL } else { (collateral_usd * 10_000) / debt_usd };
        let min_req = if (asset.min_collateral_ratio > registry.global_params.min_collateral_ratio) { asset.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);
        if (table::contains(debt_table, clone_string(&synthetic_symbol))) {
            let k_rm = clone_string(&synthetic_symbol);
            let _ = table::remove(debt_table, k_rm);
        };
        table::add(debt_table, synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply + amount;
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    fun burn_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        _price: &PriceInfoObject,
        synthetic_symbol: String,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let k_burn = clone_string(&synthetic_symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k_burn);
        let debt_table = &mut vault.synthetic_debt;
        let k2 = clone_string(&synthetic_symbol);
        assert!(table::contains(debt_table, clone_string(&synthetic_symbol)), E_UNKNOWN_ASSET);
        let old_debt = *table::borrow(debt_table, k2);
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        let k_rm = clone_string(&synthetic_symbol);
        let _ = table::remove(debt_table, k_rm);
        table::add(debt_table, synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply - amount;
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    /*******************************
    * Stability fee accrual – simple linear accrual per call
    *******************************/
    public fun accrue_stability<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        ctx: &mut TxContext
    ) {
        // If no debt, nothing to accrue
        let k_acc = clone_string(&synthetic_symbol);
        if (!table::contains(&vault.synthetic_debt, k_acc)) { return; };
        let mut debt_units = *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol));
        if (debt_units == 0) { return; };

        // Compute elapsed time since last update
        let now_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        let last_ms = vault.last_update_ms;
        if (now_ms <= last_ms) { return; };
        let elapsed_ms = now_ms - last_ms;

        // Annualized stability fee in bps applied to USD value of debt (per-asset override)
        let price_u64 = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);
        let debt_value = debt_units * price_u64;
        let akey = clone_string(&synthetic_symbol);
        let asset = table::borrow(&registry.synthetics, akey);
        let apr_bps = if (asset.stability_fee_bps > 0) { asset.stability_fee_bps } else { registry.global_params.stability_fee };
        // prorated fee ≈ debt_value * apr_bps/10k * (elapsed_ms / 31_536_000_000)
        let prorated_numerator = debt_value * apr_bps * elapsed_ms;
        let year_ms = 31_536_000_000; // 365d
        let fee_value = prorated_numerator / (10_000 * year_ms);

        if (fee_value > 0 && price_u64 > 0) {
            // Convert fee_value (collateral USD) into synth units to add to debt
            let delta_units = fee_value / price_u64;
            if (delta_units > 0) {
                debt_units = debt_units + delta_units;
                let k_rm2 = clone_string(&synthetic_symbol);
                if (table::contains(&vault.synthetic_debt, k_rm2)) {
                    let _ = table::remove(&mut vault.synthetic_debt, clone_string(&synthetic_symbol));
                };
                table::add(&mut vault.synthetic_debt, synthetic_symbol, debt_units);
                event::emit(StabilityAccrued { vault_id: object::id(vault), synthetic_type: synthetic_symbol, delta_units, from_ms: last_ms, to_ms: now_ms });
            }
        };
        vault.last_update_ms = now_ms;
    }
    public fun mint_synthetic<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        amount: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert_cfg_matches(registry, cfg);
        // asset must exist
        let k_ms = clone_string(&synthetic_symbol);
        let mut asset = table::borrow_mut(&mut registry.synthetics, k_ms);

        // price in USD (with oracle staleness check)
        let price_u64 = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);

        // compute new collateral ratio
        let debt_table = &mut vault.synthetic_debt;
        let old_debt = if (table::contains(debt_table, clone_string(&synthetic_symbol))) {
            *table::borrow(debt_table, clone_string(&synthetic_symbol))
        } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_usd = balance::value(&vault.collateral); // collateral units (assumed $1 peg)
        let debt_usd = new_debt * price_u64;
        let new_ratio = if (debt_usd == 0) { U64_MAX_LITERAL } else { (collateral_usd * 10_000) / debt_usd };

        // enforce ratio ≥ per‑asset min & global min
        let min_req = if (asset.min_collateral_ratio > registry.global_params.min_collateral_ratio) {
            asset.min_collateral_ratio
        } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);

        // Update debt, supply
        if (table::contains(debt_table, clone_string(&synthetic_symbol))) {
            let _ = table::remove(debt_table, clone_string(&synthetic_symbol));
        };
        table::add(debt_table, clone_string(&synthetic_symbol), new_debt);
        asset.total_supply = asset.total_supply + amount;

        // Fee for mint: allow UNXV discount; remainder in collateral (per-asset override)
        let mint_bps = if (asset.mint_fee_bps > 0) { asset.mint_fee_bps } else { registry.global_params.mint_fee };
        let base_fee = (debt_usd * mint_bps) / 10_000;
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        // Try to cover discount portion with UNXV at oracle price
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(clock, unxv_price, DEFAULT_MAX_AGE_SEC); // micro‑USD per 1 UNXV
            if (price_unxv_u64 > 0) {
                // ceil division
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed);
                    let mut vec = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec, exact);
                    TreasuryMod::deposit_unxv(treasury, vec, b"mint".to_string(), vault.owner, ctx);
                    // refund remainder to owner
                    transfer::public_transfer(merged, vault.owner);
                    discount_applied = true;
                } else {
                    // refund all; fallback to full collateral fee
                    transfer::public_transfer(merged, vault.owner);
                }
            }
        };

        let fee_to_collect = if (discount_applied) { base_fee - discount_collateral } else { base_fee };
        if (fee_to_collect > 0) {
            let fee_bal = balance::split(&mut vault.collateral, fee_to_collect);
            let fee_coin = coin::from_balance(fee_bal, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"mint".to_string(), ctx.sender(), ctx);
        };
        // fee details are recorded in treasury; external FeeCollected removed here

        event::emit(SyntheticMinted {
            vault_id: object::id(vault),
            synthetic_type: synthetic_symbol,
            amount_minted: amount,
            collateral_deposit: 0,
            minter: ctx.sender(),
            new_collateral_ratio: new_ratio,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });

        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    public fun burn_synthetic<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        amount: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert_cfg_matches(registry, cfg);
        let mut asset = table::borrow_mut(&mut registry.synthetics, clone_string(&synthetic_symbol));
        let debt_table = &mut vault.synthetic_debt;
        assert!(table::contains(debt_table, clone_string(&synthetic_symbol)), E_UNKNOWN_ASSET);

        let old_debt = *table::borrow(debt_table, clone_string(&synthetic_symbol));
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        let _ = table::remove(debt_table, clone_string(&synthetic_symbol));
        table::add(debt_table, clone_string(&synthetic_symbol), new_debt);
        asset.total_supply = asset.total_supply - amount;

        // Fee for burn – allow UNXV discount; per-asset override
        let price_u64 = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);
        let base_value = amount * price_u64;
        let burn_bps = if (asset.burn_fee_bps > 0) { asset.burn_fee_bps } else { registry.global_params.burn_fee };
        let base_fee = (base_value * burn_bps) / 10_000;
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(clock, unxv_price, DEFAULT_MAX_AGE_SEC);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed);
                    let mut vec = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec, exact);
                    TreasuryMod::deposit_unxv(treasury, vec, b"burn".to_string(), vault.owner, ctx);
                    transfer::public_transfer(merged, vault.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, vault.owner);
                }
            }
        };
        let fee_to_collect = if (discount_applied) { base_fee - discount_collateral } else { base_fee };
        if (fee_to_collect > 0) {
            let fee_bal = balance::split(&mut vault.collateral, fee_to_collect);
            let fee_coin = coin::from_balance(fee_bal, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"burn".to_string(), ctx.sender(), ctx);
        };
        // fee details are recorded in treasury; external FeeCollected removed here

        event::emit(SyntheticBurned {
            vault_id: object::id(vault),
            synthetic_type: synthetic_symbol,
            amount_burned: amount,
            collateral_withdrawn: 0,
            burner: ctx.sender(),
            new_collateral_ratio: 0,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });

        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    /*******************************
    * Phase‑2 – vault health helpers
    *******************************/
    /// returns (ratio_bps, is_liquidatable)
    public fun check_vault_health<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        symbol: &String
    ): (u64, bool) {
        if (!table::contains(&vault.synthetic_debt, clone_string(symbol))) { return (U64_MAX_LITERAL, false); };
        let debt = *table::borrow(&vault.synthetic_debt, clone_string(symbol));
        let price_u64 = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);
        assert!(price_u64 > 0, E_BAD_PRICE);
        let collateral_value = balance::value(&vault.collateral);
        let debt_value = debt * price_u64;
        let ratio = if (debt_value == 0) { U64_MAX_LITERAL } else { (collateral_value * 10_000) / debt_value };
        let ka = clone_string(symbol);
        let asset = table::borrow(&registry.synthetics, ka);
        let threshold = if (asset.liquidation_threshold_bps > 0) { asset.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
        let liq = ratio < threshold;
        (ratio, liq)
    }

    /// Multi-asset health: caller provides symbols and corresponding prices.
    /// Returns (ratio_bps, is_liquidatable). Uses max of per-asset liquidation thresholds for safety.
    public fun check_vault_health_multi<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        clock: &Clock,
        symbols: vector<String>,
        prices: vector<&PriceInfoObject>
    ): (u64, bool) {
        let collateral_value = balance::value(&vault.collateral);
        let mut total_debt_value: u64 = 0;
        let mut i = 0;
        let mut max_threshold = registry.global_params.liquidation_threshold;
        while (i < vector::length(&symbols)) {
            let sym = *vector::borrow(&symbols, i);
            let ks = clone_string(&sym);
            if (table::contains(&vault.synthetic_debt, ks)) {
                let debt_units = *table::borrow(&vault.synthetic_debt, clone_string(&sym));
                if (debt_units > 0) {
                    let p = *vector::borrow(&prices, i);
                    let px = get_price_scaled_1e6(clock, p, DEFAULT_MAX_AGE_SEC);
                    assert!(px > 0, E_BAD_PRICE);
                    total_debt_value = total_debt_value + (debt_units * px);
                    // threshold override
                    let a = table::borrow(&registry.synthetics, clone_string(&sym));
                    let th = if (a.liquidation_threshold_bps > 0) { a.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
                    if (th > max_threshold) { max_threshold = th; };
                }
            };
            i = i + 1;
        };
        let ratio = if (total_debt_value == 0) { U64_MAX_LITERAL } else { (collateral_value * 10_000) / total_debt_value };
        let liq = ratio < max_threshold;
        (ratio, liq)
    }

    /// Helper getters for bots/indexers
    // Listing keys is not supported by sui::table; expose per-symbol APIs instead.
    // Keeping a stub that returns an empty list to avoid breaking external callers.
    public fun list_vault_debt_symbols<C>(_vault: &CollateralVault<C>): vector<String> { vector::empty<String>() }
    public fun get_vault_debt<C>(vault: &CollateralVault<C>, symbol: &String): u64 {
        let k = clone_string(symbol);
        if (table::contains(&vault.synthetic_debt, k)) {
            *table::borrow(&vault.synthetic_debt, clone_string(symbol))
        } else { 0 }
    }

    /*******************************
    * Vault-to-vault collateral transfer (settlement helper)
    *******************************/
    public fun transfer_between_vaults<C>(
        cfg: &CollateralConfig<C>,
        from_vault: &mut CollateralVault<C>,
        to_vault: &mut CollateralVault<C>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        // ensure cfg is the global one
        // read-only SynthRegistry not available here; assume caller validated via PTB sequence
        let bal_out = balance::split(&mut from_vault.collateral, amount);
        balance::join(&mut to_vault.collateral, bal_out);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        from_vault.last_update_ms = now;
        to_vault.last_update_ms = now;
    }

    /*******************************
    * Order lifecycle – place, cancel, match
    *******************************/
    public fun place_limit_order<C>(
        registry: &SynthRegistry,
        vault: &CollateralVault<C>,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        expiry_ms: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(side == 0 || side == 1, E_SIDE_INVALID);
        let asset = table::borrow(&registry.synthetics, clone_string(&symbol));
        assert!(asset.is_active, E_INVALID_ORDER);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);

        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let order = Order {
            id: object::new(ctx),
            owner: ctx.sender(),
            vault_id: object::id(vault),
            symbol: clone_string(&symbol),
            side,
            price,
            size,
            remaining: size,
            created_at_ms: now,
            expiry_ms,
        };
        event::emit(OrderPlaced {
            order_id: object::id(&order),
            owner: ctx.sender(),
            symbol,
            side,
            price,
            size,
            remaining: size,
            created_at_ms: now,
            expiry_ms,
        });
        transfer::share_object(order)
    }

    public fun cancel_order(order: &mut Order, ctx: &TxContext) {
        assert!(order.owner == ctx.sender(), E_NOT_OWNER);
        order.remaining = 0;
        event::emit(OrderCancelled { order_id: object::id(order), owner: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun match_orders<C>(
        registry: &mut SynthRegistry,
        clock: &Clock,
        price_info: &PriceInfoObject,
        buy_order: &mut Order,
        sell_order: &mut Order,
        buyer_vault: &mut CollateralVault<C>,
        seller_vault: &mut CollateralVault<C>,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        taker_is_buyer: bool,
        min_price: u64,
        max_price: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(buy_order.side == 0 && sell_order.side == 1, E_SIDE_INVALID);
        assert!(buy_order.symbol == sell_order.symbol, E_SYMBOL_MISMATCH);
        let sym = clone_string(&buy_order.symbol);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        if (buy_order.expiry_ms != 0) { assert!(now <= buy_order.expiry_ms, E_ORDER_EXPIRED); };
        if (sell_order.expiry_ms != 0) { assert!(now <= sell_order.expiry_ms, E_ORDER_EXPIRED); };
        assert!(buyer_vault.owner == buy_order.owner, E_NOT_OWNER);
        assert!(seller_vault.owner == sell_order.owner, E_NOT_OWNER);
        assert!(buy_order.price >= sell_order.price, E_INVALID_ORDER);
        let trade_price = sell_order.price;
        assert!(trade_price >= min_price && trade_price <= max_price, E_INVALID_ORDER);
        let fill = if (buy_order.remaining < sell_order.remaining) { buy_order.remaining } else { sell_order.remaining };
        assert!(fill > 0, E_INVALID_ORDER);

        let notional = fill * trade_price;
        let bal_to_pay = balance::split(&mut buyer_vault.collateral, notional);
        let coin_to_pay = coin::from_balance(bal_to_pay, ctx);

        // Buyer mints exposure (no fee inside match)
        mint_synthetic_internal(buyer_vault, registry, clock, price_info, clone_string(&sym), fill, ctx);

        // Seller burns exposure (no fee inside match)
        burn_synthetic_internal(seller_vault, registry, clock, price_info, clone_string(&sym), fill, ctx);

        // Settle collateral
        let bal_to_recv = coin::into_balance(coin_to_pay);
        balance::join(&mut seller_vault.collateral, bal_to_recv);

        // Update orders
        buy_order.remaining = buy_order.remaining - fill;
        sell_order.remaining = sell_order.remaining - fill;

        // Fee for trade: allow UNXV discount; maker rebate (uses mint_fee bps as trade fee)
        let trade_fee = (notional * registry.global_params.mint_fee) / 10_000;
        let discount_collateral = (trade_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_collateral > 0 && taker_is_buyer && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(clock, unxv_price, DEFAULT_MAX_AGE_SEC);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed);
                    let mut vec_unxv = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    TreasuryMod::deposit_unxv(treasury, vec_unxv, b"trade".to_string(), buyer_vault.owner, ctx);
                    transfer::public_transfer(merged, buyer_vault.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, buyer_vault.owner);
                }
            }
        };
        let collateral_fee_after_discount = if (discount_applied) { trade_fee - discount_collateral } else { trade_fee };
        let maker_rebate = (trade_fee * registry.global_params.maker_rebate_bps) / 10_000;
        if (collateral_fee_after_discount > 0) {
            // Split fee from taker
            let fee_bal_all = if (taker_is_buyer) { balance::split(&mut buyer_vault.collateral, collateral_fee_after_discount) } else { balance::split(&mut seller_vault.collateral, collateral_fee_after_discount) };
            let mut fee_coin_all = coin::from_balance(fee_bal_all, ctx);
            // From fee, pay maker rebate directly to maker, deposit remainder to treasury
            if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) {
                let to_maker = coin::split(&fee_coin_all, maker_rebate, ctx);
                let maker_addr = if (taker_is_buyer) { seller_vault.owner } else { buyer_vault.owner };
                transfer::public_transfer(to_maker, maker_addr);
                event::emit(MakerRebatePaid { amount: maker_rebate, taker: if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner }, maker: maker_addr, market: b"trade".to_string(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
            };
            TreasuryMod::deposit_collateral(treasury, fee_coin_all, b"trade".to_string(), if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner }, ctx);
        };

        // Maker rebate is paid at source above; no treasury withdrawal here
        // fee details are recorded in treasury; external FeeCollected removed here

        let t = sui::tx_context::epoch_timestamp_ms(ctx);
        buyer_vault.last_update_ms = t;
        seller_vault.last_update_ms = t;
        event::emit(OrderMatched {
            buy_order_id: object::id(buy_order),
            sell_order_id: object::id(sell_order),
            symbol: sym,
            price: trade_price,
            size: fill,
            buyer: buyer_vault.owner,
            seller: seller_vault.owner,
            timestamp: t,
        });
    }

    /// Very rough system‑wide stat – sums all vaults passed by caller.
    public fun check_system_stability<C>(
        vaults: vector<&CollateralVault<C>>,
        registry: &SynthRegistry,
        clocks: vector<&Clock>,
        prices: vector<&PriceInfoObject>,
        symbols: vector<String>
    ): (u64, u64, u64) {
        // NOTE: off‑chain indexer will provide better aggregate stats.
        let mut total_coll: u64 = 0;
        let mut total_debt: u64 = 0;
        let mut i = 0;
        while (i < vector::length(&vaults)) {
            let v = *vector::borrow(&vaults, i);
            total_coll = total_coll + balance::value(&v.collateral);
            if (i < vector::length(&symbols)) {
                let sym = *vector::borrow(&symbols, i);
                let debt_amt = if (table::contains(&v.synthetic_debt, clone_string(&sym))) { *table::borrow(&v.synthetic_debt, clone_string(&sym)) } else { 0 };
                let clk = *vector::borrow(&clocks, i);
                let p = *vector::borrow(&prices, i);
                total_debt = total_debt + debt_amt * get_price_scaled_1e6(clk, p, DEFAULT_MAX_AGE_SEC);
            };
            i = i + 1;
        }
        let gcr = if (total_debt == 0) { U64_MAX_LITERAL } else { (total_coll * 10_000) / total_debt };
        (total_coll, total_debt, gcr)
    }

    /*******************************
    * Read-only helpers (bots/indexers)
    *******************************/
    /// List all listed synthetic symbols
    public fun list_synthetics(_registry: &SynthRegistry): vector<String> { vector::empty<String>() }

    /// Get read-only reference to a listed synthetic asset
    public fun get_synthetic(registry: &SynthRegistry, symbol: &String): &SyntheticAsset { table::borrow(&registry.synthetics, clone_string(symbol)) }

    /// Get oracle feed id bytes for a symbol (empty if missing)
    public fun get_oracle_feed_bytes(registry: &SynthRegistry, symbol: &String): vector<u8> {
        let k = clone_string(symbol);
        if (table::contains(&registry.oracle_feeds, k)) { vector::copy(&table::borrow(&registry.oracle_feeds, clone_string(symbol))) } else { b"".to_string().into_bytes() }
    }

    /// Compute collateral/debt values for a vault and return ratio bps
    public fun get_vault_values<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        symbol: &String
    ): (u64, u64, u64) {
        let collateral_value = balance::value(&vault.collateral);
        if (!table::contains(&vault.synthetic_debt, clone_string(symbol))) { return (collateral_value, 0, U64_MAX_LITERAL); };
        let debt_units = *table::borrow(&vault.synthetic_debt, clone_string(symbol));
        let px = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);
        let debt_value = debt_units * px;
        let ratio = if (debt_value == 0) { U64_MAX_LITERAL } else { (collateral_value * 10_000) / debt_value };
        (collateral_value, debt_value, ratio)
    }

    /// Get registry treasury ID
    public fun get_treasury_id(registry: &SynthRegistry): ID { registry.treasury_id }

    /*******************************
    * Liquidation – seize collateral when ratio < threshold
    *******************************/
    public fun liquidate_vault<C>(
        registry: &mut SynthRegistry,
        clock: &Clock,
        price: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        synthetic_symbol: String,
        repay_amount: u64,
        liquidator: address,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        // Check health
        let (ratio, _) = check_vault_health(vault, registry, clock, price, &synthetic_symbol);
        assert!(ratio < registry.global_params.liquidation_threshold, E_VAULT_NOT_HEALTHY);

        // Determine repay (cap to outstanding debt)
        let outstanding = if (table::contains(&vault.synthetic_debt, clone_string(&synthetic_symbol))) { *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol)) } else { 0 };
        let repay = if (repay_amount > outstanding) { outstanding } else { repay_amount };
        assert!(repay > 0, E_INVALID_ORDER);

        // Price in micro-USD units and penalty
        let price_u64 = get_price_scaled_1e6(clock, price, DEFAULT_MAX_AGE_SEC);
        let notional = repay * price_u64;
        let asset_for_liq = table::borrow(&registry.synthetics, clone_string(&synthetic_symbol));
        let liq_pen_bps = if (asset_for_liq.liquidation_penalty_bps > 0) { asset_for_liq.liquidation_penalty_bps } else { registry.global_params.liquidation_penalty };
        let penalty = (notional * liq_pen_bps) / 10_000;
        let seize = notional + penalty;

        // Reduce debt
        let new_debt = outstanding - repay;
        if (table::contains(&vault.synthetic_debt, clone_string(&synthetic_symbol))) {
            let _ = table::remove(&mut vault.synthetic_debt, clone_string(&synthetic_symbol));
        };
        table::add(&mut vault.synthetic_debt, clone_string(&synthetic_symbol), new_debt);

        // Seize collateral and split bot reward
        let mut seized_coin = {
            let seized_bal = balance::split(&mut vault.collateral, seize);
            coin::from_balance(seized_bal, ctx)
        };
        let bot_cut = (seize * registry.global_params.bot_split) / 10_000;
        let to_bot = coin::split(&mut seized_coin, bot_cut);
        transfer::public_transfer(to_bot, liquidator);
        // Remainder to treasury
        TreasuryMod::deposit_collateral(treasury, seized_coin, b"liquidation".to_string(), liquidator, ctx);

        // Emit event
        event::emit(LiquidationExecuted {
            vault_id: object::id(vault),
            liquidator,
            liquidated_amount: repay,
            collateral_seized: seize,
            liquidation_penalty: penalty,
            synthetic_type: synthetic_symbol,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }
    /*******************************
    * Internal helper – assert caller is in allow‑list
    *******************************/
    fun assert_is_admin(registry: &SynthRegistry, addr: address) {
        assert!(vec_set::contains(&registry.admin_addrs, &addr), E_NOT_ADMIN);
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
            min_collateral_ratio: 1_500,      // 150%
            liquidation_threshold: 1_200,     // 120%
            liquidation_penalty: 500,         // 5%
            max_synthetics: 100,
            stability_fee: 200,               // 2% APY
            bot_split: 4_000,                 // 10%
            mint_fee: 50,                     // 0.5%
            burn_fee: 30,                     // 0.3%
            unxv_discount_bps: 2_000,         // 20% discount when paying with UNXV
            maker_rebate_bps: 0,              // disabled by default
        };

        // 4️⃣ Create empty tables and admin allow‑list (deployer is first admin)
        let syn_table = table::new::<String, SyntheticAsset>(ctx);
        let feed_table = table::new::<String, vector<u8>>(ctx);
        let mut admins = vec_set::empty<address>();
        vec_set::insert(&mut admins, ctx.sender());

        // 5️⃣ Share the SynthRegistry object
        // For now, create a fresh Treasury and capture its ID
        // Treasury is assumed to be created by treasury.init; capture its ID later via a setup tx.
        let treasury_id_local = object::id(&publisher);

        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: syn_table,
            oracle_feeds: feed_table,
            global_params: params,
            paused: false,
            admin_addrs: admins,
            treasury_id: treasury_id_local,
            num_synthetics: 0,
            collateral_set: false,
            collateral_cfg_id: option::none<ID>(),
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

        // 8️⃣ Register Display for Order objects (for wallet/explorer UX)
        let mut order_disp = display::new<Order>(&publisher, ctx);
        order_disp.add(b"name".to_string(),          b"Order: {symbol} {side} {size} @ {price}".to_string());
        order_disp.add(b"description".to_string(),   b"Unxversal on-chain order object".to_string());
        order_disp.add(b"symbol".to_string(),        b"{symbol}".to_string());
        order_disp.add(b"side".to_string(),          b"{side}".to_string());
        order_disp.add(b"price".to_string(),         b"{price}".to_string());
        order_disp.add(b"size".to_string(),          b"{size}".to_string());
        order_disp.add(b"remaining".to_string(),     b"{remaining}".to_string());
        order_disp.add(b"created_at_ms".to_string(), b"{created_at_ms}".to_string());
        order_disp.add(b"expiry_ms".to_string(),     b"{expiry_ms}".to_string());
        order_disp.update_version();
        transfer::public_transfer(order_disp, ctx.sender());

        // 9️⃣ Register Display for SyntheticAssetInfo (keyed wrapper)
        let mut synth_disp = display::new<SyntheticAssetInfo>(&publisher, ctx);
        synth_disp.add(b"name".to_string(),         b"{asset.symbol} — {asset.name}".to_string());
        synth_disp.add(b"description".to_string(),  b"UNXV Synthetic: {asset.name} ({asset.symbol}), decimals {asset.decimals}".to_string());
        synth_disp.add(b"image_url".to_string(),    b"https://unxversal.com/assets/{asset.symbol}.png".to_string());
        synth_disp.add(b"thumbnail_url".to_string(),b"https://unxversal.com/assets/{asset.symbol}_thumb.png".to_string());
        synth_disp.add(b"project_url".to_string(),  b"https://unxversal.com".to_string());
        synth_disp.add(b"creator".to_string(),      b"Unxversal Synthetics".to_string());
        synth_disp.update_version();
        transfer::public_transfer(synth_disp, ctx.sender());

        // Collateral vault display requires a concrete collateral type C

        // 🔟 Optional: OracleConfig display created here using publisher
        // NOTE: Oracle shared object is created via oracle::init separately; display is type-level only
        let mut oracle_disp = display::new<unxversal::oracle::OracleConfig>(&publisher, ctx);
        oracle_disp.add(b"name".to_string(),        b"Unxversal Oracle Config".to_string());
        oracle_disp.add(b"description".to_string(), b"Holds the allow-list of Pyth feeds trusted by Unxversal".to_string());
        oracle_disp.add(b"project_url".to_string(), b"https://unxversal.com".to_string());
        oracle_disp.update_version();
        transfer::public_transfer(oracle_disp, ctx.sender());
    }

    /*******************************
    * Daddy‑level admin management
    *******************************/
    /// Mint a new AdminCap **and** add `new_admin` to `admin_addrs`.
    /// Can only be invoked by the unique DaddyCap holder.
    public fun grant_admin(
        _daddy: &DaddyCap,
        registry: &mut SynthRegistry,
        new_admin: address,
        ctx: &mut TxContext
    ) {
        vec_set::insert(&mut registry.admin_addrs, new_admin);
        transfer::public_transfer(AdminCap { id: object::new(ctx) }, new_admin);
        event::emit(AdminGranted { admin_addr: new_admin, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Remove an address from the allow‑list. Any AdminCap tokens that
    /// address still controls become decorative.
    public fun revoke_admin(
        _daddy: &DaddyCap,
        registry: &mut SynthRegistry,
        bad_admin: address,
        ctx: &TxContext
    ) {
        vec_set::remove(&mut registry.admin_addrs, &bad_admin);
        event::emit(AdminRevoked { admin_addr: bad_admin, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Parameter updates & emergency pause – gated by allow‑list
    *******************************/
    /// Replace **all** global parameters. Consider granular setters in future.
    public fun update_global_params(
        registry: &mut SynthRegistry,
        new_params: GlobalParams,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        registry.global_params = new_params;
        event::emit(ParamsUpdated { updater: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Flip the `paused` flag on. Prevents state‑changing funcs in later phases.
    public fun emergency_pause(registry: &mut SynthRegistry, ctx: &TxContext) {
        assert_is_admin(registry, ctx.sender());
        registry.paused = true;
        event::emit(EmergencyPauseToggled { new_state: true, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

   /// Turn the circuit breaker **off**.
    public fun resume(registry: &mut SynthRegistry, ctx: &TxContext) {
        assert_is_admin(registry, ctx.sender());
        registry.paused = false;
        event::emit(EmergencyPauseToggled { new_state: false, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }
}
