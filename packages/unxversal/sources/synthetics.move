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
    use sui::package::Publisher;           // Display helpers expect Publisher
    use sui::display;                      // Object‑Display metadata helpers
    use sui::object;                       // object::new / delete
    use sui::types;                        // is_one_time_witness check
    use sui::event;                        // emit events
    use std::string::String;
    use std::vec_set::{Self as VecSet, VecSet};
    use std::table::{Self as Table, Table};
    use std::time;                         // now_ms helper
    use std::vector;                       // basic vector ops
    use sui::clock::Clock;                 // clock for oracle staleness checks
    use sui::coin::{Self as Coin, Coin};   // coin helpers (merge/split/zero/value)
    use pyth::price_info::PriceInfoObject; // Pyth price object type
    use sui::sui::SUI;                     // default treasury coin to avoid external deps
    use unxversal::oracle::{OracleConfig, get_latest_price, get_price_scaled_1e6};
    use unxversal::common::{FeeCollected, calculate_fee_with_discount};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;

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
        /// Treasury reference (shared object)
        treasury_id: ID,
        /// Count of listed synthetic assets
        num_synthetics: u64,
        /// Flag to ensure collateral is set exactly once via set_collateral<C>
        collateral_set: bool,
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

    public struct SyntheticMinted has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_minted: u64,
        usdc_deposit: u64,
        minter: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }

    public struct SyntheticBurned has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_burned: u64,
        usdc_withdrawn: u64,
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
        usdc_collateral_seized: u64,
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
        collateral: Coin<C>,
        /// symbol → synthetic debt amount
        synthetic_debt: Table<String, u64>,
        last_update_ms: u64,
    }

    /// Marker object that binds the chosen collateral coin type C
    public struct CollateralConfig<phantom C> has key, store { id: UID }

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
    fun init_synth_display(publisher: &Publisher, _asset: &SyntheticAsset, ctx: &mut TxContext) {
        let mut disp = display::new<SyntheticAsset>(publisher, ctx);
        disp.add(b"name".to_string(),           b"{name}".to_string());
        disp.add(b"description".to_string(),    b"Synthetic {name} provided by Unxversal".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());
    }

    fun init_vault_display<C>(publisher: &Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<CollateralVault<C>>(publisher, ctx);
        disp.add(b"name".to_string(),          b"UNXV Synth Collateral Vault".to_string());
        disp.add(b"description".to_string(),   b"User-owned vault holding protocol collateral".to_string());
        disp.add(b"image_url".to_string(),     b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(), b"{thumbnail_url}".to_string());
        disp.add(b"creator".to_string(),       b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());
    }

    /*******************************
    * Phase‑2 – synthetic asset listing (admin‑only)
    *******************************/
    public entry fun create_synthetic_asset(
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
        assert!(!Table::contains(&registry.synthetics, &asset_symbol), E_ASSET_EXISTS);

        let asset = SyntheticAsset {
            name: asset_name.clone(),
            symbol: asset_symbol.clone(),
            decimals,
            pyth_feed_id: pyth_feed_id.clone(),
            min_collateral_ratio: min_coll_ratio,
            total_supply: 0,
            is_active: true,
            created_at: time::now_ms(),
            stability_fee_bps: 0,
            liquidation_threshold_bps: 0,
            liquidation_penalty_bps: 0,
            mint_fee_bps: 0,
            burn_fee_bps: 0,
        };

        // store metadata + oracle mapping
        Table::insert(&mut registry.synthetics, asset_symbol.clone(), asset);
        Table::insert(&mut registry.oracle_feeds, asset_symbol.clone(), pyth_feed_id);
        registry.num_synthetics = registry.num_synthetics + 1;
        assert!(registry.num_synthetics <= registry.global_params.max_synthetics, E_ASSET_EXISTS);

        // emit event
        event::emit(SyntheticAssetCreated {
            asset_name,
            asset_symbol,
            pyth_feed_id,
            creator: ctx.sender(),
            timestamp: time::now_ms(),
        });

        // optional: add Display metadata (publisher lives with deployer)
        // (Skip for brevity – could call init_synth_display here)
    }

    /*******************************
     * Per-asset parameter setters (admin-only)
     *******************************/
    public entry fun set_asset_stability_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &symbol);
        asset.stability_fee_bps = bps;
    }

    public entry fun set_asset_liquidation_threshold(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &symbol);
        asset.liquidation_threshold_bps = bps;
    }

    public entry fun set_asset_liquidation_penalty(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &symbol);
        asset.liquidation_penalty_bps = bps;
    }

    public entry fun set_asset_mint_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &symbol);
        asset.mint_fee_bps = bps;
    }

    public entry fun set_asset_burn_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &symbol);
        asset.burn_fee_bps = bps;
    }

    /*******************************
    * Phase‑2 – vault lifecycle
    *******************************/
    /// Anyone can open a fresh vault (zero‑collateral, zero‑debt).
    public entry fun create_vault<C>(
        _cfg: &CollateralConfig<C>,
        registry: &SynthRegistry,
        ctx: &mut TxContext
    ) {
        // registry.pause check
        assert!(!registry.paused, 1000);

        let coin_zero = Coin::zero<C>(ctx);
        let debt_table = Table::new::<String, u64>(ctx);
        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: ctx.sender(),
            collateral: coin_zero,
            synthetic_debt: debt_table,
            last_update_ms: time::now_ms(),
        };
        transfer::share_object(vault);
        event::emit(VaultCreated { vault_id: object::id(&vault), owner: ctx.sender(), timestamp: time::now_ms() });
    }

    /// Deposit collateral into caller‑owned vault
    public entry fun deposit_collateral<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        coins_in: Coin<C>,
        ctx: &mut TxContext
    ) {
        // owner-only for deposits on shared vault
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        Coin::merge(&mut vault.collateral, coins_in);
        vault.last_update_ms = time::now_ms();
        event::emit(CollateralDeposited { vault_id: object::id(vault), amount: Coin::value(&vault.collateral), depositor: ctx.sender(), timestamp: time::now_ms() });
    }

    /// Withdraw collateral if post‑withdraw health ≥ min_coll_ratio
    public entry fun withdraw_collateral<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);

        // health check BEFORE withdrawal
        let (ratio, _) = check_vault_health(vault, registry, oracle_cfg, clock, price);
        assert!(ratio >= registry.global_params.min_collateral_ratio, E_VAULT_NOT_HEALTHY);

        // split & return coin
        let coin_out = Coin::split(&mut vault.collateral, amount, ctx);
        vault.last_update_ms = time::now_ms();
        event::emit(CollateralWithdrawn { vault_id: object::id(vault), amount, withdrawer: ctx.sender(), timestamp: time::now_ms() });
        coin_out
    }

    /*******************************
    * Phase‑2 – mint / burn flows
    *******************************/
    fun mint_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &synthetic_symbol);
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let debt_table = &mut vault.synthetic_debt;
        let old_debt = if Table::contains(debt_table, &synthetic_symbol) { *Table::borrow(debt_table, &synthetic_symbol) } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_usd = Coin::value(&vault.collateral);
        let debt_usd = new_debt * price_u64;
        let new_ratio = if debt_usd == 0 { u64::MAX } else { (collateral_usd * 10_000) / debt_usd };
        let min_req = if asset.min_collateral_ratio > registry.global_params.min_collateral_ratio { asset.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);
        Table::insert(debt_table, synthetic_symbol.clone(), new_debt);
        asset.total_supply = asset.total_supply + amount;
        vault.last_update_ms = time::now_ms();
    }

    fun burn_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        _price: &PriceInfoObject,
        synthetic_symbol: String,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &synthetic_symbol);
        let debt_table = &mut vault.synthetic_debt;
        assert!(Table::contains(debt_table, &synthetic_symbol), E_UNKNOWN_ASSET);
        let old_debt = *Table::borrow(debt_table, &synthetic_symbol);
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        Table::insert(debt_table, synthetic_symbol.clone(), new_debt);
        asset.total_supply = asset.total_supply - amount;
        vault.last_update_ms = time::now_ms();
    }

    /*******************************
    * Stability fee accrual – simple linear accrual per call
    *******************************/
    public entry fun accrue_stability<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        ctx: &mut TxContext
    ) {
        // If no debt, nothing to accrue
        if (!Table::contains(&vault.synthetic_debt, &synthetic_symbol)) { return; };
        let mut debt_units = *Table::borrow(&vault.synthetic_debt, &synthetic_symbol);
        if (debt_units == 0) { return; };

        // Compute elapsed time since last update
        let now_ms = time::now_ms();
        let last_ms = vault.last_update_ms;
        if (now_ms <= last_ms) { return; };
        let elapsed_ms = now_ms - last_ms;

        // Annualized stability fee in bps applied to USD value of debt (per-asset override)
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let debt_value = debt_units * price_u64;
        let asset = Table::borrow(&registry.synthetics, &synthetic_symbol);
        let apr_bps = if asset.stability_fee_bps > 0 { asset.stability_fee_bps } else { registry.global_params.stability_fee };
        // prorated fee ≈ debt_value * apr_bps/10k * (elapsed_ms / 31_536_000_000)
        let prorated_numerator = debt_value * apr_bps * elapsed_ms;
        let year_ms = 31_536_000_000; // 365d
        let fee_value = prorated_numerator / (10_000 * year_ms);

        if (fee_value > 0 && price_u64 > 0) {
            // Convert fee_value (collateral USD) into synth units to add to debt
            let delta_units = fee_value / price_u64;
            if (delta_units > 0) {
                debt_units = debt_units + delta_units;
                Table::insert(&mut vault.synthetic_debt, synthetic_symbol.clone(), debt_units);
                event::emit(StabilityAccrued { vault_id: object::id(vault), synthetic_type: synthetic_symbol, delta_units, from_ms: last_ms, to_ms: now_ms });
            }
        }
        vault.last_update_ms = now_ms;
    }
    public entry fun mint_synthetic<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
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
        // asset must exist
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &synthetic_symbol);

        // price in USD (with oracle staleness check)
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);

        // compute new collateral ratio
        let debt_table = &mut vault.synthetic_debt;
        let old_debt = if Table::contains(debt_table, &synthetic_symbol) {
            *Table::borrow(debt_table, &synthetic_symbol)
        } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_usd = Coin::value(&vault.collateral); // collateral units (assumed $1 peg)
        let debt_usd = new_debt * price_u64;
        let new_ratio = if debt_usd == 0 { u64::MAX } else { (collateral_usd * 10_000) / debt_usd };

        // enforce ratio ≥ per‑asset min & global min
        let min_req = if asset.min_collateral_ratio > registry.global_params.min_collateral_ratio {
            asset.min_collateral_ratio
        } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);

        // Update debt, supply
        Table::insert(debt_table, synthetic_symbol.clone(), new_debt);
        asset.total_supply = asset.total_supply + amount;

        // Fee for mint: allow UNXV discount; remainder in collateral (per-asset override)
        let mint_bps = if asset.mint_fee_bps > 0 { asset.mint_fee_bps } else { registry.global_params.mint_fee };
        let base_fee = (debt_usd * mint_bps) / 10_000;
        let discount_usdc = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        // Try to cover discount portion with UNXV at oracle price
        if (discount_usdc > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price); // micro‑USD per 1 UNXV
            if (price_unxv_u64 > 0) {
                // ceil division
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = Coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    Coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
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

        let fee_to_collect = if (discount_applied) { base_fee - discount_usdc } else { base_fee };
        if (fee_to_collect > 0) {
            let fee_coin = Coin::split(&mut vault.collateral, fee_to_collect, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"mint".to_string(), ctx.sender(), ctx);
        };
        event::emit(FeeCollected {
            fee_type: b"mint".to_string(),
            amount: base_fee,
            asset_type: b"COLLATERAL".to_string(),
            user: ctx.sender(),
            unxv_discount_applied: discount_applied,
            timestamp: time::now_ms(),
        });

        event::emit(SyntheticMinted {
            vault_id: object::id(vault),
            synthetic_type: synthetic_symbol,
            amount_minted: amount,
            usdc_deposit: 0,
            minter: ctx.sender(),
            new_collateral_ratio: new_ratio,
            timestamp: time::now_ms(),
        });

        vault.last_update_ms = time::now_ms();
    }

    public entry fun burn_synthetic<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
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
        let mut asset = Table::borrow_mut(&mut registry.synthetics, &synthetic_symbol);
        let debt_table = &mut vault.synthetic_debt;
        assert!(Table::contains(debt_table, &synthetic_symbol), E_UNKNOWN_ASSET);

        let old_debt = *Table::borrow(debt_table, &synthetic_symbol);
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        Table::insert(debt_table, synthetic_symbol.clone(), new_debt);
        asset.total_supply = asset.total_supply - amount;

        // Fee for burn – allow UNXV discount; per-asset override
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let base_value = amount * price_u64;
        let burn_bps = if asset.burn_fee_bps > 0 { asset.burn_fee_bps } else { registry.global_params.burn_fee };
        let base_fee = (base_value * burn_bps) / 10_000;
        let discount_usdc = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        if (discount_usdc > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = Coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    Coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
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
        let fee_to_collect = if (discount_applied) { base_fee - discount_usdc } else { base_fee };
        if (fee_to_collect > 0) {
            let fee_coin = Coin::split(&mut vault.collateral, fee_to_collect, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"burn".to_string(), ctx.sender(), ctx);
        };
        event::emit(FeeCollected {
            fee_type: b"burn".to_string(),
            amount: base_fee,
            asset_type: b"COLLATERAL".to_string(),
            user: ctx.sender(),
            unxv_discount_applied: discount_applied,
            timestamp: time::now_ms(),
        });

        event::emit(SyntheticBurned {
            vault_id: object::id(vault),
            synthetic_type: synthetic_symbol,
            amount_burned: amount,
            usdc_withdrawn: 0,
            burner: ctx.sender(),
            new_collateral_ratio: 0,
            timestamp: time::now_ms(),
        });

        vault.last_update_ms = time::now_ms();
    }

    /*******************************
    * Phase‑2 – vault health helpers
    *******************************/
    /// returns (ratio_bps, is_liquidatable)
    public fun check_vault_health<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject
    ): (u64, bool) {
        // Backward-compatible single-asset check: picks first symbol if any
        let keys = Table::keys(&vault.synthetic_debt);
        if 0 == vector::length(&keys) { return (u64::MAX, false); };
        let sym = *vector::borrow(&keys, 0);
        let debt = *Table::borrow(&vault.synthetic_debt, sym);
        let price_i64 = get_latest_price(oracle_cfg, clock, price);
        assert!(price_i64 > 0, E_BAD_PRICE);
        let collateral_value = Coin::value(&vault.collateral);
        let debt_value = debt * (price_i64 as u64);
        let ratio = if debt_value == 0 { u64::MAX } else { (collateral_value * 10_000) / debt_value };
        let asset = Table::borrow(&registry.synthetics, sym);
        let threshold = if asset.liquidation_threshold_bps > 0 { asset.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
        let liq = ratio < threshold;
        (ratio, liq)
    }

    /// Multi-asset health: caller provides symbols and corresponding prices.
    /// Returns (ratio_bps, is_liquidatable). Uses max of per-asset liquidation thresholds for safety.
    public fun check_vault_health_multi<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        symbols: vector<String>,
        prices: vector<&PriceInfoObject>
    ): (u64, bool) {
        let collateral_value = Coin::value(&vault.collateral);
        let mut total_debt_value: u64 = 0;
        let mut i = 0;
        let mut max_threshold = registry.global_params.liquidation_threshold;
        while (i < vector::length(&symbols)) {
            let sym = *vector::borrow(&symbols, i);
            if (Table::contains(&vault.synthetic_debt, &sym)) {
                let debt_units = *Table::borrow(&vault.synthetic_debt, &sym);
                if (debt_units > 0) {
                    let p = *vector::borrow(&prices, i);
                    let px_i64 = get_latest_price(oracle_cfg, clock, p);
                    assert!(px_i64 > 0, E_BAD_PRICE);
                    let px = px_i64 as u64;
                    total_debt_value = total_debt_value + (debt_units * px);
                    // threshold override
                    let a = Table::borrow(&registry.synthetics, &sym);
                    let th = if a.liquidation_threshold_bps > 0 { a.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
                    if (th > max_threshold) { max_threshold = th; };
                }
            };
            i = i + 1;
        };
        let ratio = if total_debt_value == 0 { u64::MAX } else { (collateral_value * 10_000) / total_debt_value };
        let liq = ratio < max_threshold;
        (ratio, liq)
    }

    /// Helper getters for bots/indexers
    public fun list_vault_debt_symbols<C>(vault: &CollateralVault<C>): vector<String> { Table::keys(&vault.synthetic_debt) }
    public fun get_vault_debt<C>(vault: &CollateralVault<C>, symbol: &String): u64 { if (Table::contains(&vault.synthetic_debt, symbol)) { *Table::borrow(&vault.synthetic_debt, symbol) } else { 0 } }

    /*******************************
    * Vault-to-vault collateral transfer (settlement helper)
    *******************************/
    public entry fun transfer_between_vaults<C>(
        _cfg: &CollateralConfig<C>,
        from_vault: &mut CollateralVault<C>,
        to_vault: &mut CollateralVault<C>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let coin_out = Coin::split(&mut from_vault.collateral, amount, ctx);
        Coin::merge(&mut to_vault.collateral, coin_out);
        let now = time::now_ms();
        from_vault.last_update_ms = now;
        to_vault.last_update_ms = now;
    }

    /*******************************
    * Order lifecycle – place, cancel, match
    *******************************/
    public entry fun place_limit_order<C>(
        registry: &SynthRegistry,
        vault: &CollateralVault<C>,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        expiry_ms: u64,
        ctx: &mut TxContext
    ): Order {
        assert!(!registry.paused, 1000);
        assert!(side == 0 || side == 1, E_SIDE_INVALID);
        let asset = Table::borrow(&registry.synthetics, &symbol);
        assert!(asset.is_active, E_INVALID_ORDER);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);

        let now = time::now_ms();
        let order = Order {
            id: object::new(ctx),
            owner: ctx.sender(),
            vault_id: object::id(vault),
            symbol: symbol.clone(),
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

    public entry fun cancel_order(order: &mut Order, ctx: &TxContext) {
        assert!(order.owner == ctx.sender(), E_NOT_OWNER);
        order.remaining = 0;
        event::emit(OrderCancelled { order_id: object::id(order), owner: ctx.sender(), timestamp: time::now_ms() });
    }

    public entry fun match_orders<C>(
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
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
        let sym = buy_order.symbol.clone();
        let now = time::now_ms();
        if (buy_order.expiry_ms != 0) { assert!(now <= buy_order.expiry_ms, E_ORDER_EXPIRED); };
        if (sell_order.expiry_ms != 0) { assert!(now <= sell_order.expiry_ms, E_ORDER_EXPIRED); };
        assert!(buyer_vault.owner == buy_order.owner, E_NOT_OWNER);
        assert!(seller_vault.owner == sell_order.owner, E_NOT_OWNER);
        assert!(buy_order.price >= sell_order.price, E_INVALID_ORDER);
        let trade_price = sell_order.price;
        assert!(trade_price >= min_price && trade_price <= max_price, E_INVALID_ORDER);
        let fill = if buy_order.remaining < sell_order.remaining { buy_order.remaining } else { sell_order.remaining };
        assert!(fill > 0, E_INVALID_ORDER);

        let notional = fill * trade_price;
        let coin_to_pay = Coin::split(&mut buyer_vault.collateral, notional, ctx);

        // Buyer mints exposure (no fee inside match)
        mint_synthetic_internal(buyer_vault, registry, oracle_cfg, clock, price_info, sym.clone(), fill, ctx);

        // Seller burns exposure (no fee inside match)
        burn_synthetic_internal(seller_vault, registry, oracle_cfg, clock, price_info, sym.clone(), fill, ctx);

        // Settle collateral
        Coin::merge(&mut seller_vault.collateral, coin_to_pay);

        // Update orders
        buy_order.remaining = buy_order.remaining - fill;
        sell_order.remaining = sell_order.remaining - fill;

        // Fee for trade: allow UNXV discount; maker rebate (uses mint_fee bps as trade fee)
        let trade_fee = (notional * registry.global_params.mint_fee) / 10_000;
        let discount_usdc = (trade_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && taker_is_buyer && vector::length(&unxv_payment) > 0) {
            let price_unxv_i64 = get_latest_price(oracle_cfg, clock, unxv_price);
            let price_unxv_u64 = price_unxv_i64 as u64;
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = Coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    Coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
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
        let usdc_fee_after_discount = if (discount_applied) { trade_fee - discount_usdc } else { trade_fee };
        let maker_rebate = (trade_fee * registry.global_params.maker_rebate_bps) / 10_000;
        if (usdc_fee_after_discount > 0) {
            // Split fee from taker
            let fee_coin_all = if (taker_is_buyer) { Coin::split(&mut buyer_vault.collateral, usdc_fee_after_discount, ctx) } else { Coin::split(&mut seller_vault.collateral, usdc_fee_after_discount, ctx) };
            // From fee, pay maker rebate directly to maker, deposit remainder to treasury
            if (maker_rebate > 0 && maker_rebate < usdc_fee_after_discount) {
                let to_maker = Coin::split(&fee_coin_all, maker_rebate, ctx);
                let maker_addr = if (taker_is_buyer) { seller_vault.owner } else { buyer_vault.owner };
                transfer::public_transfer(to_maker, maker_addr);
                event::emit(MakerRebatePaid { amount: maker_rebate, taker: if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner }, maker: maker_addr, market: b"trade".to_string(), timestamp: time::now_ms() });
            };
            TreasuryMod::deposit_collateral(treasury, fee_coin_all, b"trade".to_string(), if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner }, ctx);
        };

        // Maker rebate is paid at source above; no treasury withdrawal here
        event::emit(FeeCollected {
            fee_type: b"trade".to_string(),
            amount: trade_fee,
            asset_type: b"COLLATERAL".to_string(),
            user: if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner },
            unxv_discount_applied: discount_applied,
            timestamp: time::now_ms(),
        });

        let t = time::now_ms();
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
        oracle_cfg: &OracleConfig,
        clocks: vector<&Clock>,
        prices: vector<&PriceInfoObject>
    ): (u64, u64, u64) {
        // NOTE: off‑chain indexer will provide better aggregate stats.
        let mut total_coll: u64 = 0;
        let mut total_debt: u64 = 0;
        let mut i = 0;
        while (i < vector::length(&vaults)) {
            let v = *vector::borrow(&vaults, i);
            total_coll = total_coll + Coin::value(&v.collateral);
            let keys = Table::keys(&v.synthetic_debt);
            if 0 != vector::length(&keys) {
                let sym = *vector::borrow(&keys, 0);
                let debt_amt = *Table::borrow(&v.synthetic_debt, sym);
                let clk = *vector::borrow(&clocks, i);
                let p = *vector::borrow(&prices, i);
                total_debt = total_debt + debt_amt * get_price_scaled_1e6(oracle_cfg, clk, p);
            };
            i = i + 1;
        }
        let gcr = if total_debt == 0 { u64::MAX } else { (total_coll * 10_000) / total_debt };
        (total_coll, total_debt, gcr)
    }

    /*******************************
    * Read-only helpers (bots/indexers)
    *******************************/
    /// List all listed synthetic symbols
    public fun list_synthetics(registry: &SynthRegistry): vector<String> { Table::keys(&registry.synthetics) }

    /// Get read-only reference to a listed synthetic asset
    public fun get_synthetic(registry: &SynthRegistry, symbol: &String): &SyntheticAsset { Table::borrow(&registry.synthetics, symbol) }

    /// Get oracle feed id bytes for a symbol (empty if missing)
    public fun get_oracle_feed_bytes(registry: &SynthRegistry, symbol: &String): vector<u8> {
        if (Table::contains(&registry.oracle_feeds, symbol)) { Table::borrow(&registry.oracle_feeds, symbol).clone() } else { b"".to_string().into_bytes() }
    }

    /// Compute collateral/debt values for a vault and return ratio bps
    public fun get_vault_values(
        vault: &CollateralVault,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject
    ): (u64, u64, u64) {
        let collateral_value = Coin::value(&vault.collateral); // collateral units
        let keys = Table::keys(&vault.synthetic_debt);
        if 0 == vector::length(&keys) { return (collateral_value, 0, u64::MAX); };
        let sym = *vector::borrow(&keys, 0);
        let debt_units = *Table::borrow(&vault.synthetic_debt, sym);
        let px = get_latest_price(oracle_cfg, clock, price) as u64;
        let debt_value = debt_units * px;
        let ratio = if debt_value == 0 { u64::MAX } else { (collateral_value * 10_000) / debt_value };
        (collateral_value, debt_value, ratio)
    }

    /// Get registry treasury ID
    public fun get_treasury_id(registry: &SynthRegistry): ID { registry.treasury_id }

    /*******************************
    * Liquidation – seize collateral when ratio < threshold
    *******************************/
    public entry fun liquidate_vault(
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        vault: &mut CollateralVault,
        synthetic_symbol: String,
        repay_amount: u64,
        liquidator: address,
        treasury: &mut Treasury,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        // Check health
        let (ratio, _) = check_vault_health(vault, registry, oracle_cfg, clock, price);
        assert!(ratio < registry.global_params.liquidation_threshold, E_VAULT_NOT_HEALTHY);

        // Determine repay (cap to outstanding debt)
        let outstanding = if (Table::contains(&vault.synthetic_debt, &synthetic_symbol)) { *Table::borrow(&vault.synthetic_debt, &synthetic_symbol) } else { 0 };
        let repay = if repay_amount > outstanding { outstanding } else { repay_amount };
        assert!(repay > 0, E_INVALID_ORDER);

        // Price in micro-USD units and penalty
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let notional = repay * price_u64;
        let liq_pen_bps = if asset_for_liq.liquidation_penalty_bps > 0 { asset_for_liq.liquidation_penalty_bps } else { registry.global_params.liquidation_penalty };
        let penalty = (notional * liq_pen_bps) / 10_000;
        let seize = notional + penalty;

        // Reduce debt
        let new_debt = outstanding - repay;
        Table::insert(&mut vault.synthetic_debt, synthetic_symbol.clone(), new_debt);

        // Seize collateral and split bot reward
        let mut seized_coin = Coin::split(&mut vault.collateral, seize, ctx);
        let bot_cut = (seize * registry.global_params.bot_split) / 10_000;
        let to_bot = Coin::split(&mut seized_coin, bot_cut, ctx);
        transfer::public_transfer(to_bot, liquidator);
        // Remainder to treasury
        TreasuryMod::deposit_collateral(treasury, seized_coin, b"liquidation".to_string(), liquidator, ctx);

        // Emit event
        event::emit(LiquidationExecuted {
            vault_id: object::id(vault),
            liquidator,
            liquidated_amount: repay,
            usdc_collateral_seized: seize,
            liquidation_penalty: penalty,
            synthetic_type: synthetic_symbol,
            timestamp: time::now_ms(),
        });
        vault.last_update_ms = time::now_ms();
    }
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
            unxv_discount_bps: 2_000,         // 20% discount when paying with UNXV
            maker_rebate_bps: 0,              // disabled by default
        };

        // 4️⃣ Create empty tables and admin allow‑list (deployer is first admin)
        let syn_table = Table::new::<String, SyntheticAsset>(ctx);
        let feed_table = Table::new::<String, vector<u8>>(ctx);
        let mut admins = VecSet::empty();
        VecSet::add(&mut admins, ctx.sender());

        // 5️⃣ Share the SynthRegistry object
        // For now, create a fresh Treasury and capture its ID
        let mut t = Treasury<SUI> { id: object::new(ctx), collateral: Coin::zero<SUI>(ctx), unxv: Coin::zero<UNXV>(ctx), cfg: unxversal::treasury::TreasuryCfg { unxv_burn_bps: 0 } };
        let treasury_id_local = object::id(&t);
        transfer::share_object(t);

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

        // 9️⃣ Register type display for SyntheticAsset (CollateralVault display is type-parametric)
        init_synth_display(&publisher, &SyntheticAsset {
            name: b"{name}".to_string(),
            symbol: b"{symbol}".to_string(),
            decimals: 9,
            pyth_feed_id: b"".to_string().into_bytes(),
            min_collateral_ratio: 0,
            total_supply: 0,
            is_active: true,
            created_at: 0,
        }, ctx);
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
