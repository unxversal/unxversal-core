/// Module: **unxversal_synthetics** — Phase‑1
/// ------------------------------------------------------------
/// * Bootstraps the core **SynthRegistry** shared object
/// * Establishes the **DaddyCap → admin‑address allow‑list** authority pattern
/// * Provides basic governance (grant/revoke admin, global‑params update, pause)
///
/// > Later phases will extend this module with asset‑listing, vaults,
/// > mint/burn logic, liquidation flows, DeepBook integration, etc.
module unxversal::synthetics {
    /// Imports & std aliases
    use sui::package;                      // claim Publisher via OTW
    use sui::package::Publisher;           // Display helpers expect Publisher
    use sui::display;                      // Object‑Display metadata helpers
    use sui::types;                        // is_one_time_witness check
    use sui::event;                        // emit events
    use std::string::{Self as string, String};
    use sui::table::{Self as table, Table};
    use sui::clock::Clock;                 // clock for oracle staleness checks
    use sui::coin::{Self as coin, Coin};   // coin helpers (merge/split/zero/value)
    use sui::balance::{Self as balance, Balance};
    use sui::vec_set::{Self as vec_set, VecSet};
    
    
    use switchboard::aggregator::{Self as sb_agg, Aggregator};
    use unxversal::oracle::{Self as OracleMod, OracleConfig};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;
    // Legacy CLOB imports removed in V2
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    // bot_rewards not used in V2

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

    // Clone a vector<String> (deep copy)
    fun clone_string_vec(src: &vector<String>): vector<String> {
        let mut out = vector::empty<String>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { 
            let s = vector::borrow(src, i); 
            vector::push_back(&mut out, clone_string(s)); i = i + 1; 
        };
        out
    }

    // String equality by bytes
    fun eq_string(a: &String, b: &String): bool {
        let ab = string::as_bytes(a);
        let bb = string::as_bytes(b);
        let la = vector::length(ab);
        let lb = vector::length(bb);
        if (la != lb) { 
            return false 
        };
        let mut i = 0;
        while (i < la) {
            if (*vector::borrow(ab, i) != *vector::borrow(bb, i)) { 
                return false 
            };
            i = i + 1;
        };
        true
    }

    // Track a symbol in a vector<String> if it is not present
    fun push_symbol_if_missing(list: &mut vector<String>, sym: &String) {
        let mut i = 0; let n = vector::length(list);
        while (i < n) { 
            let cur = vector::borrow(list, i); 
            if (eq_string(cur, sym)) { 
                return 
            }; 
            i = i + 1; 
        };
        vector::push_back(list, clone_string(sym));
    }

    // Remove a symbol from a vector<String> if present (first occurrence)
    fun remove_symbol_if_present(list: &mut vector<String>, sym: &String) {
        let mut out = vector::empty<String>();
        let mut i = 0; let n = vector::length(list);
        while (i < n) {
            let cur = vector::borrow(list, i);
            if (!eq_string(cur, sym)) { vector::push_back(&mut out, clone_string(cur)); };
            i = i + 1;
        };
        *list = out;
    }

    // Local price scaling helper (micro-USD), avoids dependency cycle with oracle module
    // Using Switchboard's aggregator recency; no per-call max-age here
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;

    fun clamp_u128_to_u64(x: u128): u64 { if (x > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { x as u64 } }



    // Scale helpers for decimals-aware notional/debt calculations (unused helper removed)

    // Legacy debt_value_micro_usd removed

    // Vector<u8> equality by bytes (for oracle feed hash binding)
    fun eq_vec_u8(a: &vector<u8>, b: &vector<u8>): bool {
        let la = vector::length(a);
        let lb = vector::length(b);
        if (la != lb) { return false };
        let mut i = 0;
        while (i < la) {
            if (*vector::borrow(a, i) != *vector::borrow(b, i)) { return false };
            i = i + 1;
        };
        true
    }

    // Strict price read for a symbol: enforce aggregator feed binding to registry mapping
    fun assert_and_get_price_for_symbol(
        clock: &Clock,
        cfg: &OracleConfig,
        registry: &SynthRegistry,
        symbol: &String,
        agg: &Aggregator
    ): u64 {
        let k = clone_string(symbol);
        assert!(table::contains(&registry.oracle_feeds, k), E_PRICE_FEED_MISSING);
        let expected = table::borrow(&registry.oracle_feeds, clone_string(symbol));
        let actual = sb_agg::feed_hash(agg);
        assert!(eq_vec_u8(&actual, expected), E_ORACLE_MISMATCH);
        OracleMod::get_price_scaled_1e6(cfg, clock, agg)
    }

    
    /// Error codes (0‑99 reserved for general)
    const E_NOT_ADMIN: u64 = 1;            // Caller not in admin allow‑list
    const E_ASSET_EXISTS: u64 = 2;

    const E_VAULT_NOT_HEALTHY: u64 = 4;

    const E_NOT_OWNER: u64 = 6;
    const E_INVALID_ORDER: u64 = 7;

    const E_COLLATERAL_NOT_SET: u64 = 9;
    const E_WRONG_COLLATERAL_CFG: u64 = 10;

    const E_ORACLE_MISMATCH: u64 = 11;
    const E_ZERO_AMOUNT: u64 = 12;
    const E_PRICE_FEED_MISSING: u64 = 13;  // No bound oracle feed for symbol
    const E_NEED_PRICE_FEEDS: u64 = 14;    // Operation requires live prices for open positions
    const E_MM_NOT_BREACHED: u64 = 15;     // Liquidation attempted when MM not breached
    const E_TRADE_FUNC_DEPRECATED: u64 = 16; // Old trade function disabled
    const E_PRICE_VECTOR_MISMATCH: u64 = 17; // symbols/prices length mismatch
    const E_MISSING_FEED_FOR_SYMBOL: u64 = 18; // No aggregator/price provided for a required symbol

    /// One‑Time Witness (OTW)
    /// Guarantees `init` executes exactly once when the package is published.
    public struct SYNTHETICS has drop {}

    /// Capability & authority objects (compatibility with legacy callers)
    public struct AdminCap has key, store { id: UID }
    public struct DaddyCap has key, store { id: UID }

    /// Global‑parameter struct (basis‑points units for ratios/fees)
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
        /// GC reward on expired order cleanup (bps of a nominal unit; currently unused in Synth CLOB)
        gc_reward_bps: u64,
        /// Required bond (bps of notional) that a maker must post on order injection. Slashed on expiry.
        maker_bond_bps: u64,
    }

    // CLOB sizing constants removed in V2

    /// Synthetic‑asset object definition
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

    /// V2 Risk parameters per instrument (cash-settled, no minted supply)
    public struct RiskParams has store, drop {
        /// Initial margin requirement in basis points of notional
        im_bps: u64,
        /// Maintenance margin requirement in basis points of notional
        mm_bps: u64,
        /// Liquidation penalty applied to closed notional (bps)
        liq_penalty_bps: u64,
    }

    /// V2 Instrument registry entry (replaces supply-bearing SyntheticAsset for trading)
    /// kind: 0 = spot-like cash exposure, 1 = perpetual-like, 2 = dated future (cash-settled)
    public struct Instrument has store, drop {
        symbol: String,
        decimals: u8,
        kind: u8,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        fee_bps: u64,
        /// Risk caps (bps of equity)
        max_leverage_bps: u64,
        max_concentration_bps: u64,
        risk: RiskParams,
    }

    /// V2 position record kept inside the user's CollateralVault
    public struct Position has store, drop {
        /// Position side: 0 = long, 1 = short
        side: u8,
        /// Absolute quantity in instrument units
        qty: u64,
        /// Entry price in micro-USD (VWAP for current side)
        entry_px_u64: u64,
        /// Last observed mark price in micro-USD (for UI; not used for accounting authority)
        last_px_u64: u64,
        created_at_ms: u64,
        updated_at_ms: u64,
    }

    /// Core shared object – SynthRegistry
    public struct SynthRegistry has key, store {
        /// UID so we can share the object on-chain.
        id: UID,
        /// Map **symbol → SyntheticAsset** definitions.
        synthetics: Table<String, SyntheticAsset>,
        /// V2: Map **symbol → Instrument** definitions (cash-settled exposure)
        instruments: Table<String, Instrument>,
        /// Map **symbol → Pyth feed bytes** for oracle lookup.
        oracle_feeds: Table<String, vector<u8>>,
        /// Listing helper – list of all listed synthetic symbols
        listed_symbols: vector<String>,
        /// System-wide configurable risk / fee parameters.
        global_params: GlobalParams,
        /// Emergency-circuit-breaker flag.
        paused: bool,
        /// Treasury reference (shared object)
        treasury_id: ID,
        /// Count of listed synthetic assets
        num_synthetics: u64,
        /// Flag to ensure collateral is set exactly once via set_collateral<C>
        collateral_set: bool,
        /// ID of the shared CollateralConfig<C> object once set
        collateral_cfg_id: Option<ID>,
        /// Admin allow-list (compat for modules that query Synth::is_admin)
        admins: VecSet<address>,
    }

    /// Event structs for indexers / UI
    public struct ParamsUpdated has copy, drop { 
        updater: address, 
        timestamp: u64 
    }

    

    // Legacy order events removed

    public struct EmergencyPauseToggled has copy, drop { 
        new_state: bool, 
        by: address, 
        timestamp: u64 
    }

    public struct VaultCreated has copy, drop { 
        vault_id: ID, 
        owner: address, 
        timestamp: u64 
    }

    public struct CollateralDeposited has copy, drop { 
        vault_id: ID, 
        amount: u64, 
        depositor: address, 
        timestamp: u64 
    }

    public struct CollateralWithdrawn has copy, drop { 
        vault_id: ID, 
        amount: u64, 
        withdrawer: address, 
        timestamp: u64 
    }

    public struct SyntheticAssetCreated has copy, drop {
        asset_name:   String,
        asset_symbol: String,
        pyth_feed_id: vector<u8>,
        creator:      address,
        timestamp:    u64,
    }

    public struct SyntheticAssetInfoCreated has copy, drop {
        symbol: String,
        timestamp: u64,
    }

    

    /// Prefunding-related events for instant taker-sell settlement
    

    public struct FeeCollected has copy, drop {
        amount: u64,
        payer: address,
        market: String,
        reason: String,
        timestamp: u64,
    }

    /// Additional CLOB/escrow lifecycle events
    

    

    public struct LiquidationExecuted has copy, drop {
        vault_id: ID,
        liquidator: address,
        liquidated_amount: u64,
        collateral_seized: u64,
        liquidation_penalty: u64,
        synthetic_type: String,
        timestamp: u64,
    }

    /// New settlement/diagnostic events
    public struct CollateralLossDebited has copy, drop { amount: u64, reason: String, owner: address, timestamp: u64 }
    public struct CollateralGainCredited has copy, drop { amount: u64, reason: String, owner: address, timestamp: u64 }
    public struct LiquidationTriggered has copy, drop { mm_required: u64, collateral: u64, symbol: String, qty_closed: u64, timestamp: u64 }

    /// V2 – cash-settled position lifecycle events
    public struct PositionTrade has copy, drop {
        symbol: String,
        side: u8,              // 0 = buy/long add, 1 = sell/short add
        qty: u64,
        price: u64,            // micro-USD
        realized_gain: u64,    // realized profit on this trade (micro-USD)
        realized_loss: u64,    // realized loss on this trade (micro-USD)
        fee_paid: u64,         // fee paid in collateral micro-USD after UNXV discount
        owner: address,
        timestamp: u64,
    }

    public struct PositionClosed has copy, drop {
        symbol: String,
        owner: address,
        timestamp: u64,
    }

    public struct PositionOpened has copy, drop { symbol: String, side: u8, qty: u64, price: u64, owner: address, timestamp: u64 }
    public struct PositionIncreased has copy, drop { symbol: String, side: u8, qty: u64, price: u64, owner: address, timestamp: u64 }
    public struct PositionReduced has copy, drop { symbol: String, qty: u64, price: u64, owner: address, timestamp: u64 }
    public struct MarginCheckFailed has copy, drop { owner: address, required_im: u64, collateral: u64, attempted_withdraw: u64, timestamp: u64 }
    public struct InstrumentListed has copy, drop { symbol: String, kind: u8, fee_bps: u64, im_bps: u64, mm_bps: u64, liq_penalty_bps: u64, timestamp: u64 }

    

    /// Collateral vault
    public struct CollateralVault<phantom C> has key, store {
        id: UID,
        owner: address,
        /// Collateral held inside this vault (full‑value coin of type C)
        collateral: Balance<C>,
        /// V2: symbol → position record (cash-settled exposure)
        positions: Table<String, Position>,
        /// V2: helper list to enumerate symbols with open positions
        position_symbols: vector<String>,
        last_update_ms: u64,
    }

    /// Marker object that binds the chosen collateral coin type C
    public struct CollateralConfig<phantom C> has key, store { id: UID }

    /// Package-visible function for lending module to seize collateral during liquidation
    public(package) fun seize_collateral<C>(vault: &mut CollateralVault<C>, amount: u64): Balance<C> {
        balance::split(&mut vault.collateral, amount)
    }

    /// Package-visible function for lending module to get collateral value
    public(package) fun get_collateral_value<C>(vault: &CollateralVault<C>): u64 {
        balance::value(&vault.collateral)
    }

    fun assert_cfg_matches<C>(registry: &SynthRegistry, cfg: &CollateralConfig<C>) {
        assert!(registry.collateral_set, E_COLLATERAL_NOT_SET);
        let cfg_opt = &registry.collateral_cfg_id;
        let cfg_id = object::id(cfg);
        assert!(option::is_some(cfg_opt) && *option::borrow(cfg_opt) == cfg_id, E_WRONG_COLLATERAL_CFG);
    }

    

    // Legacy claim functions removed

    

    // Legacy cancel removed

    // Legacy modify removed

    // Legacy match step removed

    // Legacy GC step removed

    // Legacy match and GC step functions removed

    // No display for SyntheticAsset (lacks 'key')
    /// Phase‑2 – Display helpers
    public fun init_vault_display<C>(publisher: &Publisher, ctx: &mut TxContext): display::Display<CollateralVault<C>> {
        let mut disp = display::new<CollateralVault<C>>(publisher, ctx);
        // Use concrete, non-placeholder templates from on-chain fields
        disp.add(b"name".to_string(),          b"Vault {id}".to_string());
        disp.add(b"description".to_string(),   b"Collateral vault owned by {owner}".to_string());
        disp.add(b"link".to_string(),          b"https://unxversal.com/vault/{id}".to_string());
        disp.add(b"project_url".to_string(),   b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),       b"Unxversal Synthetics".to_string());
        disp.update_version();
        disp
    }

    /// Phase‑2 – synthetic asset listing (admin‑only, legacy compatibility)
    /// In cash-settled v2, this only registers metadata in `synthetics` and adds oracle feed mapping.
    public fun create_synthetic_asset<C>(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        asset_name: String,
        asset_symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_coll_ratio: u64,
        _cfg: &CollateralConfig<C>,
        ctx: &mut TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&asset_symbol);
        assert!(!table::contains(&registry.synthetics, clone_string(&k)), E_ASSET_EXISTS);
        let asset = SyntheticAsset {
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
        table::add(&mut registry.synthetics, clone_string(&asset_symbol), asset);
        if (table::contains(&registry.oracle_feeds, clone_string(&asset_symbol))) { let _ = table::remove(&mut registry.oracle_feeds, clone_string(&asset_symbol)); };
        table::add(&mut registry.oracle_feeds, clone_string(&asset_symbol), pyth_feed_id);
        push_symbol_if_missing(&mut registry.listed_symbols, &asset_symbol);
        registry.num_synthetics = registry.num_synthetics + 1;
        event::emit(SyntheticAssetInfoCreated { symbol: clone_string(&asset_symbol), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// AdminRegistry-gated variant (migration bridge)
    public fun set_asset_stability_fee_admin(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.stability_fee_bps = bps;
    }

    public fun set_asset_liquidation_threshold_admin(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.liquidation_threshold_bps = bps;
    }

    public fun set_asset_liquidation_penalty_admin(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.liquidation_penalty_bps = bps;
    }

    public fun set_asset_mint_fee_admin(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.mint_fee_bps = bps;
    }

    public fun set_asset_burn_fee_admin(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.burn_fee_bps = bps;
    }

    /// Phase‑2 – vault lifecycle
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
        let pos_tbl = table::new<String, Position>(ctx);
        let pos_syms = vector::empty<String>();
        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: ctx.sender(),
            collateral: coin_zero,
            positions: pos_tbl,
            position_symbols: pos_syms,
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx),

        };
        let vid = object::id(&vault);
        transfer::share_object(vault);
        event::emit(VaultCreated { 
            vault_id: vid, 
            owner: ctx.sender(), 
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx) 
        });
    }

    #[test_only]
    public fun create_vault_for_testing<C>(
        cfg: &CollateralConfig<C>,
        registry: &SynthRegistry,
        ctx: &mut TxContext
    ): CollateralVault<C> {
        assert!(!registry.paused, 1000);
        assert_cfg_matches(registry, cfg);
        let coin_zero = balance::zero<C>();
        let pos_tbl = table::new<String, Position>(ctx);
        let pos_syms = vector::empty<String>();
        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: ctx.sender(),
            collateral: coin_zero,
            positions: pos_tbl,
            position_symbols: pos_syms,
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx),

        };
        vault
    }

    #[test_only]
    public fun set_oracle_feed_binding_for_testing(
        registry: &mut SynthRegistry,
        symbol: String,
        agg: &Aggregator
    ) {
        let fh = sb_agg::feed_hash(agg);
        let key = clone_string(&symbol);
        if (table::contains(&registry.oracle_feeds, key)) {
            let _ = table::remove(&mut registry.oracle_feeds, clone_string(&symbol));
        };
        table::add(&mut registry.oracle_feeds, symbol, copy_vector_u8(&fh));
    }

    // Legacy test market constructor removed

    // Legacy new_escrow_for_testing removed

    // Legacy test place_with_escrow_return_id removed

    // Legacy escrow helper removed

    // Legacy escrow helper removed

    /*******************************
     * Test-only Event Mirrors
     *******************************/
    #[test_only]
    public struct EventMirror has key, store {
        id: UID,
        mint_count: u64,
        burn_count: u64,
        last_mint_symbol: String,
        last_mint_amount: u64,
        last_mint_vault: ID,
        last_mint_new_cr: u64,
        last_burn_symbol: String,
        last_burn_amount: u64,
        last_burn_vault: ID,
        last_burn_new_cr: u64,
        last_unxv_leftover: u64,
    }

    #[test_only]
    public fun new_event_mirror_for_testing(ctx: &mut TxContext): EventMirror {
        EventMirror {
            id: object::new(ctx),
            mint_count: 0,
            burn_count: 0,
            last_mint_symbol: b"".to_string(),
            last_mint_amount: 0,
            last_mint_vault: object::id_from_address(@0x0),
            last_mint_new_cr: 0,
            last_burn_symbol: b"".to_string(),
            last_burn_amount: 0,
            last_burn_vault: object::id_from_address(@0x0),
            last_burn_new_cr: 0,
            last_unxv_leftover: 0,
        }
    }

    // Legacy mint_synthetic_with_event_mirror removed

    // Legacy burn_synthetic_with_event_mirror removed

    // Test-only accessors for EventMirror (fields are private outside module)
    #[test_only] public fun em_mint_count(m: &EventMirror): u64 { m.mint_count }
    #[test_only] public fun em_burn_count(m: &EventMirror): u64 { m.burn_count }
    #[test_only] public fun em_last_mint_symbol(m: &EventMirror): String { clone_string(&m.last_mint_symbol) }
    #[test_only] public fun em_last_mint_amount(m: &EventMirror): u64 { m.last_mint_amount }
    #[test_only] public fun em_last_mint_vault(m: &EventMirror): ID { m.last_mint_vault }
    #[test_only] public fun em_last_mint_new_cr(m: &EventMirror): u64 { m.last_mint_new_cr }
    #[test_only] public fun em_last_burn_symbol(m: &EventMirror): String { clone_string(&m.last_burn_symbol) }
    #[test_only] public fun em_last_burn_amount(m: &EventMirror): u64 { m.last_burn_amount }
    #[test_only] public fun em_last_burn_vault(m: &EventMirror): ID { m.last_burn_vault }
    #[test_only] public fun em_last_burn_new_cr(m: &EventMirror): u64 { m.last_burn_new_cr }
    #[test_only] public fun em_last_unxv_leftover(m: &EventMirror): u64 { m.last_unxv_leftover }

    // Legacy escrow helper removed

    #[test_only]
    public fun vault_collateral_value<C>(vault: &CollateralVault<C>): u64 { balance::value(&vault.collateral) }

    /// Deposit collateral into caller‑owned vault
    public fun deposit_collateral<C>(
        vault: &mut CollateralVault<C>,
        coins_in: Coin<C>,
        ctx: &mut TxContext
    ) {
        // owner-only for deposits on shared vault
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        let value_in = coin::value(&coins_in);
        let bal_in = coin::into_balance(coins_in);
        balance::join(&mut vault.collateral, bal_in);
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(CollateralDeposited { 
            vault_id: object::id(vault), 
            amount: value_in, 
            depositor: ctx.sender(), 
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx) 
        });
    }

    /// Withdraw collateral: allowed only if remaining collateral ≥ portfolio IM (based on last mark)
    public fun withdraw_collateral<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert_cfg_matches(registry, cfg);

        // Without supplied live prices, only allow withdrawal if no open positions exist.
        let has_positions = vector::length(&vault.position_symbols) > 0;
        assert!(!has_positions, E_NEED_PRICE_FEEDS);
        let im_total = 0;
        let coll_val = balance::value(&vault.collateral);
        assert!(coll_val >= im_total && amount <= (coll_val - im_total), E_VAULT_NOT_HEALTHY);

        let bal_out = balance::split(&mut vault.collateral, amount);
        let coin_out = coin::from_balance(bal_out, ctx);
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(CollateralWithdrawn { 
            vault_id: object::id(vault), 
            amount, 
            withdrawer: ctx.sender(), 
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx) 
        });
        coin_out
    }

    /// Withdraw with supplied live prices (caller-verified). Enforces IM after withdrawal.
    public fun withdraw_collateral_with_prices<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        amount: u64,
        symbols: vector<String>,
        prices: vector<u64>,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert_cfg_matches(registry, cfg);
        let (im_total, _, _) = compute_portfolio_im_mm_with_prices(vault, registry, &symbols, &prices);
        let coll_val = balance::value(&vault.collateral);
        assert!(coll_val >= im_total && amount <= (coll_val - im_total), E_VAULT_NOT_HEALTHY);
        let bal_out = balance::split(&mut vault.collateral, amount);
        let coin_out = coin::from_balance(bal_out, ctx);
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(CollateralWithdrawn { 
            vault_id: object::id(vault), 
            amount, 
            withdrawer: ctx.sender(), 
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx) 
        });
        coin_out
    }

    /// Compute portfolio initial margin across all open positions in a vault.
    /// Caller must supply aggregator references for all open symbols in `vault.position_symbols`.
    public fun compute_portfolio_im<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry
    ): u64 {
        let mut im_u128: u128 = 0u128;
        let ps_len = vector::length(&vault.position_symbols);
        let mut i = 0; while (i < ps_len) {
            let sym = vector::borrow(&vault.position_symbols, i);
            if (table::contains(&vault.positions, clone_string(sym)) && table::contains(&registry.instruments, clone_string(sym))) {
                let pos = table::borrow(&vault.positions, clone_string(sym));
                let inst = table::borrow(&registry.instruments, clone_string(sym));
                if (pos.qty > 0) {
                    let notional: u128 = (pos.qty as u128) * (pos.last_px_u64 as u128);
                    let im = (notional * (inst.risk.im_bps as u128)) / 10_000u128;
                    im_u128 = im_u128 + im;
                };
            };
                    i = i + 1;
                };
        clamp_u128_to_u64(im_u128)
    }

    // Lookup helper: find price for a symbol in (symbols, prices) lists; returns (price, found)
    fun find_price(symbols: &vector<String>, prices: &vector<u64>, sym: &String): (u64, bool) {
        let n = vector::length(symbols);
        let mut i = 0;
        while (i < n) {
            let s = vector::borrow(symbols, i);
            if (eq_string(s, sym)) {
                return (*vector::borrow(prices, i), true)
            };
            i = i + 1;
        };
        (0, false)
    }

    // (Removed) compute_portfolio_im_mm_with_feeds: callers should mark positions per symbol in the same PTB
    // Compute IM/MM totals and portfolio notional using supplied live prices; fallback to last mark if missing
    public fun compute_portfolio_im_mm_with_prices<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        symbols: &vector<String>,
        prices: &vector<u64>
    ): (u64, u64, u64) {
        assert!(vector::length(symbols) == vector::length(prices), E_PRICE_VECTOR_MISMATCH);
        let mut im_u128: u128 = 0u128;
        let mut mm_u128: u128 = 0u128;
        let mut notion_u128: u128 = 0u128;
        let ps_len = vector::length(&vault.position_symbols);
        let mut i = 0; while (i < ps_len) {
            let sym = vector::borrow(&vault.position_symbols, i);
            if (table::contains(&vault.positions, clone_string(sym)) && table::contains(&registry.instruments, clone_string(sym))) {
                let pos = table::borrow(&vault.positions, clone_string(sym));
                if (pos.qty > 0) {
                    let inst = table::borrow(&registry.instruments, clone_string(sym));
                    let (p, ok) = find_price(symbols, prices, sym);
                    let px = if (ok && p > 0) { p } else { pos.last_px_u64 };
                    let notional: u128 = (pos.qty as u128) * (px as u128);
                    notion_u128 = notion_u128 + notional;
                    let im = (notional * (inst.risk.im_bps as u128)) / 10_000u128;
                    let mm = (notional * (inst.risk.mm_bps as u128)) / 10_000u128;
                    im_u128 = im_u128 + im;
                    mm_u128 = mm_u128 + mm;
                };
            };
            i = i + 1;
        };
        (clamp_u128_to_u64(im_u128), clamp_u128_to_u64(mm_u128), clamp_u128_to_u64(notion_u128))
    }


    // Legacy mint_synthetic_internal removed

    // Legacy burn_synthetic_internal removed

    /// Stability fee accrual is disabled in cash-settled v2 (no supply-bearing debt positions)
    public fun accrue_stability<C>(
        _vault: &mut CollateralVault<C>,
        _registry: &mut SynthRegistry,
        _clock: &Clock,
        _price: &Aggregator,
        _oracle_cfg: &OracleConfig,
        _synthetic_symbol: String,
        _ctx: &mut TxContext
    ) { }

    // Legacy accrue_stability_with_points removed
    
    // Legacy mint_synthetic removed

    // Legacy burn_synthetic removed





    /// Phase‑2 – vault health helpers
    /// returns (ratio_bps, is_liquidatable)
    public fun check_vault_health<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        _price: &Aggregator,
        _symbol: &String
    ): (u64, bool) {
        // Uses last marks; for production health checks, prefer with live prices helper
        let (_, maint, notion) = {
            let mut maint_u128: u128 = 0u128;
            let mut notion_u128: u128 = 0u128;
            let ps_len = vector::length(&vault.position_symbols);
            let mut i = 0; while (i < ps_len) {
                let sym = vector::borrow(&vault.position_symbols, i);
                if (table::contains(&vault.positions, clone_string(sym)) && table::contains(&registry.instruments, clone_string(sym))) {
                    let pos = table::borrow(&vault.positions, clone_string(sym));
                    if (pos.qty > 0) {
                        let inst = table::borrow(&registry.instruments, clone_string(sym));
                        let notional: u128 = (pos.qty as u128) * (pos.last_px_u64 as u128);
                        let mm = (notional * (inst.risk.mm_bps as u128)) / 10_000u128;
                        maint_u128 = maint_u128 + mm;
                        notion_u128 = notion_u128 + notional;
                    };
                };
                i = i + 1;
            };
            (0u64, clamp_u128_to_u64(maint_u128), clamp_u128_to_u64(notion_u128))
        };
        let collateral = balance::value(&vault.collateral);
        let ratio_bps = if (notion > 0) { (collateral * 10_000) / notion } else { U64_MAX_LITERAL };
        (ratio_bps, collateral < maint)
    }

    // Legacy allocation helper removed

    /// Vault-to-vault collateral transfer (settlement helper)
    public fun transfer_between_vaults<C>(
        _cfg: &CollateralConfig<C>,
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

    // Test-only helper to construct GlobalParams for update tests
    #[test_only]
    public fun new_global_params_for_testing(
        min_collateral_ratio: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        max_synthetics: u64,
        stability_fee: u64,
        bot_split: u64,
        mint_fee: u64,
        burn_fee: u64,
        unxv_discount_bps: u64,
        maker_rebate_bps: u64,
        gc_reward_bps: u64,
        maker_bond_bps: u64
    ): GlobalParams {
        GlobalParams {
            min_collateral_ratio,
            liquidation_threshold,
            liquidation_penalty,
            max_synthetics,
            stability_fee,
            bot_split,
            mint_fee,
            burn_fee,
            unxv_discount_bps,
            maker_rebate_bps,
            gc_reward_bps,
            maker_bond_bps,
        }
    }

    // Test-only updater for GlobalParams
    #[test_only]
    public fun update_global_params(
        registry: &mut SynthRegistry,
        new_params: GlobalParams,
        _ctx: &TxContext
    ) {
        registry.global_params = new_params;
    }

    // Test-only getter for vault owner
    #[test_only]
    public fun vault_owner<C>(v: &CollateralVault<C>): address { v.owner }

    


    /// Read-only helpers (bots/indexers)
    /// List all listed synthetic symbols
    public fun list_synthetics(registry: &SynthRegistry): vector<String> { clone_string_vec(&registry.listed_symbols) }

    /// Get read-only reference to a listed synthetic asset
    public fun get_synthetic(registry: &SynthRegistry, symbol: &String): &SyntheticAsset { table::borrow(&registry.synthetics, clone_string(symbol)) }

    /// V2: Get read-only reference to an instrument
    public fun get_instrument(registry: &SynthRegistry, symbol: &String): &Instrument { table::borrow(&registry.instruments, clone_string(symbol)) }

    /// Get oracle feed id bytes for a symbol (empty if missing)
    public fun get_oracle_feed_bytes(registry: &SynthRegistry, symbol: &String): vector<u8> {
        let k = clone_string(symbol);
        if (table::contains(&registry.oracle_feeds, k)) { copy_vector_u8(table::borrow(&registry.oracle_feeds, clone_string(symbol))) } else { b"".to_string().into_bytes() }
    }

    // removed: rank_vault_liquidation_order (unused after multi removal)

    /// Compute collateral/debt values for a vault and return ratio bps
    public fun get_vault_values<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        _price: &Aggregator,
        _symbol: &String
    ): (u64, u64, u64) {
        // Minimal implementation using last marks for now; callers should prefer with live prices
        let mut notion_u128: u128 = 0u128;
        let ps_len = vector::length(&vault.position_symbols);
        let mut i = 0; while (i < ps_len) {
            let sym = vector::borrow(&vault.position_symbols, i);
            if (table::contains(&vault.positions, clone_string(sym)) && table::contains(&registry.instruments, clone_string(sym))) {
                let pos = table::borrow(&vault.positions, clone_string(sym));
                if (pos.qty > 0) {
                    let n = (pos.qty as u128) * (pos.last_px_u64 as u128);
                    notion_u128 = notion_u128 + n;
                };
            };
            i = i + 1;
        };
        let notion = clamp_u128_to_u64(notion_u128);
        let coll = balance::value(&vault.collateral);
        let ratio_bps = if (notion > 0) { (coll * 10_000) / notion } else { U64_MAX_LITERAL };
        (coll, notion, ratio_bps)
    }

    /// Get registry treasury ID
    public fun get_treasury_id(registry: &SynthRegistry): ID { registry.treasury_id }

    /// Owner-only: update last marks for positions (UI only)
    public fun mark_positions<C>(
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        symbols: vector<String>,
        prices: vector<u64>,
        ctx: &mut TxContext
    ) {
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert!(vector::length(&symbols) == vector::length(&prices), E_PRICE_VECTOR_MISMATCH);
        let ps_len = vector::length(&vault.position_symbols);
        let mut i = 0; while (i < ps_len) {
            let sym = vector::borrow(&vault.position_symbols, i);
            if (table::contains(&vault.positions, clone_string(sym)) && table::contains(&registry.instruments, clone_string(sym))) {
                let (px, ok) = find_price(&symbols, &prices, sym);
                if (ok && px > 0) {
                    let p = table::borrow_mut(&mut vault.positions, clone_string(sym));
                    p.last_px_u64 = px;
                    p.updated_at_ms = sui::tx_context::epoch_timestamp_ms(ctx);
                }
            };
            i = i + 1;
        };
    }

    /// Convenience: compute portfolio values using caller-supplied live prices
    public fun get_portfolio_live<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        symbols: vector<String>,
        prices: vector<u64>
    ): (u64, u64, u64, u64, u64) {
        let (im, mm, notion) = compute_portfolio_im_mm_with_prices(vault, registry, &symbols, &prices);
        let coll = balance::value(&vault.collateral);
        let ratio_bps = if (notion > 0) { (coll * 10_000) / notion } else { U64_MAX_LITERAL };
        (coll, notion, im, mm, ratio_bps)
    }

    /// V2 – open/increase or reduce/close a cash-settled position (buy/sell)
    /// side: 0 = buy (increase long / reduce short), 1 = sell (increase short / reduce long)
    public fun trade_cash<C: store>(
        _cfg: &CollateralConfig<C>,
        _registry: &mut SynthRegistry,
        _treasury: &mut Treasury<C>,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        _price: &Aggregator,
        _unxv_price: &Aggregator,
        _vault: &mut CollateralVault<C>,
        _symbol: String,
        _side: u8,
        _qty: u64,
        _unxv_payment: vector<Coin<UNXV>>,
        _ctx: &mut TxContext
    ) { abort E_TRADE_FUNC_DEPRECATED }

    /// Apply a matched fill at a specific trade price; enforces IM before/after
    /// side: 0 = buy (increase long / reduce short), 1 = sell (increase short / reduce long)
    public fun apply_fill<C: store>(
        cfg: &CollateralConfig<C>,
        registry: &mut SynthRegistry,
        treasury: &mut Treasury<C>,
        clock: &Clock,
        _oracle_cfg: &OracleConfig,
        live_symbols: vector<String>,
        live_prices: vector<u64>,
        vault: &mut CollateralVault<C>,
        symbol: String,
        side: u8,
        qty: u64,
        fill_price_u64: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert!(qty > 0, E_ZERO_AMOUNT);
        assert_cfg_matches(registry, cfg);
        // instrument must exist
        let inst = table::borrow(&registry.instruments, clone_string(&symbol));
        assert!(qty >= inst.min_size, E_INVALID_ORDER);

        // Pre-trade IM check using provided live prices
        let (im_before, _, _) = compute_portfolio_im_mm_with_prices(vault, registry, &live_symbols, &live_prices);
        let collateral_before = balance::value(&vault.collateral);
        assert!(collateral_before >= im_before, E_VAULT_NOT_HEALTHY);

        // load or create position
        let has_pos = table::contains(&vault.positions, clone_string(&symbol));
        let now = sui::clock::timestamp_ms(clock);
        let mut realized_gain: u64 = 0;
        let mut realized_loss: u64 = 0;

        if (!has_pos) {
            // Creating new position always increases on this side
            let pos = Position { side, qty, entry_px_u64: fill_price_u64, last_px_u64: fill_price_u64, created_at_ms: now, updated_at_ms: now };
            table::add(&mut vault.positions, clone_string(&symbol), pos);
            push_symbol_if_missing(&mut vault.position_symbols, &symbol);
            event::emit(PositionOpened { symbol: clone_string(&symbol), side, qty, price: fill_price_u64, owner: vault.owner, timestamp: now });
        } else {
            let p = table::borrow_mut(&mut vault.positions, clone_string(&symbol));
            // If same side: update VWAP and qty; If opposite: realize PnL up to qty
            if (p.qty > 0 && p.side == side) {
                // same side increase: new_vwap = (old_qty*old_px + qty*px) / (old_qty+qty)
                let old_notional: u128 = (p.qty as u128) * (p.entry_px_u64 as u128);
                let add_notional: u128 = (qty as u128) * (fill_price_u64 as u128);
                let new_qty = p.qty + qty;
                let new_entry_u128 = (old_notional + add_notional) / (new_qty as u128);
                p.qty = new_qty;
                p.entry_px_u64 = clamp_u128_to_u64(new_entry_u128);
                p.last_px_u64 = fill_price_u64;
                p.updated_at_ms = now;
                event::emit(PositionIncreased { symbol: clone_string(&symbol), side, qty, price: fill_price_u64, owner: vault.owner, timestamp: now });
            } else {
                // opposite side: close against existing up to qty
                let close_qty = if (qty <= p.qty) { qty } else { p.qty };
                if (close_qty > 0) {
                    // PnL sign depends on position side
                    if (p.side == 0) {
                        // closing long at px: pnl = (px - entry) * close_qty
                        if (fill_price_u64 >= p.entry_px_u64) {
                            let diff = fill_price_u64 - p.entry_px_u64;
                            realized_gain = realized_gain + (diff * close_qty);
                        } else {
                            let diff = p.entry_px_u64 - fill_price_u64;
                            realized_loss = realized_loss + (diff * close_qty);
                        }
                    } else {
                        // closing short at px: pnl = (entry - px) * close_qty
                        if (p.entry_px_u64 >= fill_price_u64) {
                            let diff = p.entry_px_u64 - fill_price_u64;
                            realized_gain = realized_gain + (diff * close_qty);
                        } else {
                            let diff = fill_price_u64 - p.entry_px_u64;
                            realized_loss = realized_loss + (diff * close_qty);
                        }
                    };
                    p.qty = p.qty - close_qty;
                    event::emit(PositionReduced { symbol: clone_string(&symbol), qty: close_qty, price: fill_price_u64, owner: vault.owner, timestamp: now });
                };
                // If remaining qty to flip side
                let remain = if (qty > close_qty) { qty - close_qty } else { 0 };
                if (p.qty == 0 && remain == 0) {
                    // fully closed
                    let _ = table::remove(&mut vault.positions, clone_string(&symbol));
                    remove_symbol_if_present(&mut vault.position_symbols, &symbol);
                    event::emit(PositionClosed { symbol: clone_string(&symbol), owner: vault.owner, timestamp: now });
                } else {
                    if (p.qty == 0 && remain > 0) {
                        // flip side with fresh entry
                        p.side = side;
                        p.qty = remain;
                        p.entry_px_u64 = fill_price_u64;
                        p.last_px_u64 = fill_price_u64;
                        p.updated_at_ms = now;
                        event::emit(PositionOpened { symbol: clone_string(&symbol), side, qty: remain, price: fill_price_u64, owner: vault.owner, timestamp: now });
                    } else {
                        // partial close only
                        p.last_px_u64 = fill_price_u64;
                        p.updated_at_ms = now;
                    }
                }
            }
        };

        // Apply realized PnL to collateral immediately (zero-trust)
        if (realized_loss > 0) {
            let bal_loss = balance::split(&mut vault.collateral, realized_loss);
            let coin_loss = coin::from_balance(bal_loss, ctx);
            TreasuryMod::deposit_collateral(treasury, coin_loss, b"trade_loss".to_string(), vault.owner, ctx);
            event::emit(CollateralLossDebited { amount: realized_loss, reason: b"trade_loss".to_string(), owner: vault.owner, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        };
        if (realized_gain > 0) {
            // Protocol requires settlement coin from counterparty/venue
            // For now, treat fee_after as separate; realized gain must be delivered via external transfer path
            // Here we assert that realized gain settlement is not handled implicitly
            let _ = realized_gain; // reserved for explicit settlement in DEX layer
        };

        // Fees in collateral with optional UNXV discount
        let fee_bps = inst.fee_bps;
        let notional_u128: u128 = (qty as u128) * (fill_price_u64 as u128);
        let base_fee = clamp_u128_to_u64((notional_u128 * (fee_bps as u128)) / 10_000u128);
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut fee_after = base_fee;
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let (price_unxv_u64, ok_unxv) = find_price(&live_symbols, &live_prices, &b"UNXV".to_string());
            if (ok_unxv && price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0; let m = vector::length(&unxv_payment);
                while (i < m) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"trade".to_string(), vault.owner, ctx);
                    transfer::public_transfer(merged, vault.owner);
                    if (base_fee > discount_collateral) { fee_after = base_fee - discount_collateral; } else { fee_after = 0; }
                } else { transfer::public_transfer(merged, vault.owner); }
            }
        };
        if (vector::length(&unxv_payment) > 0) { let mut leftover = coin::zero<UNXV>(ctx); while (vector::length(&unxv_payment) > 0) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut leftover, c); }; transfer::public_transfer(leftover, vault.owner); };
        vector::destroy_empty(unxv_payment);

        if (fee_after > 0) {
            let fee_bal = balance::split(&mut vault.collateral, fee_after);
            let fee_coin = coin::from_balance(fee_bal, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"trade".to_string(), vault.owner, ctx);
            event::emit(FeeCollected { amount: fee_after, payer: vault.owner, market: clone_string(&symbol), reason: b"trade".to_string(), timestamp: sui::clock::timestamp_ms(clock) });
        };

        event::emit(PositionTrade { symbol: clone_string(&symbol), side, qty, price: fill_price_u64, realized_gain, realized_loss, fee_paid: fee_after, owner: vault.owner, timestamp: now });
        vault.last_update_ms = now;

        // Post-trade IM check using provided live prices; also enforce instrument-level caps
        let (im_after, _, notion_after) = compute_portfolio_im_mm_with_prices(vault, registry, &live_symbols, &live_prices);
        let collateral_after = balance::value(&vault.collateral);
        assert!(collateral_after >= im_after, E_VAULT_NOT_HEALTHY);
        // Portfolio max leverage and per-instrument concentration
        let max_lev_bps = inst.max_leverage_bps;
        assert!(notion_after <= ((collateral_after as u128) * (max_lev_bps as u128) / 10_000u128) as u64, E_VAULT_NOT_HEALTHY);
        // Concentration: ensure this instrument's notional share is within cap
        let mut px_here = fill_price_u64;
        let pos_here = table::borrow(&vault.positions, clone_string(&symbol));
        let notion_here: u128 = (pos_here.qty as u128) * (px_here as u128);
        let conc_cap_bps = inst.max_concentration_bps;
        assert!(notion_here <= ((collateral_after as u128) * (conc_cap_bps as u128) / 10_000u128) as u128, E_VAULT_NOT_HEALTHY);
    }
    /// Liquidation – seize collateral when ratio < threshold
    public fun liquidate_vault<C>(
        registry: &mut SynthRegistry,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        symbols: vector<String>,
        prices: vector<u64>,
        vault: &mut CollateralVault<C>,
        synthetic_symbol: String,
        _repay_amount: u64,
        liquidator: address,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        // V2: Liquidation only if portfolio collateral < maintenance margin using live oracles for all symbols
        let k = clone_string(&synthetic_symbol);
        assert!(table::contains(&vault.positions, clone_string(&k)), E_INVALID_ORDER);
        let (_im, maint, _notion) = compute_portfolio_im_mm_with_prices(vault, registry, &symbols, &prices);
        let collateral = balance::value(&vault.collateral);
        assert!(collateral < maint, E_MM_NOT_BREACHED);

        // Close as much of the target position as needed to restore maintenance margin (partial liq)
        let p = table::borrow_mut(&mut vault.positions, clone_string(&k));
        let inst = table::borrow(&registry.instruments, clone_string(&synthetic_symbol));
        let qty_total = p.qty;
        if (qty_total == 0) { return };

        // Live price for target symbol
        let (px_live, ok) = find_price(&symbols, &prices, &synthetic_symbol);
        assert!(ok && px_live > 0, E_MISSING_FEED_FOR_SYMBOL);

        // Determine required reduction fraction; conservative: close entire position if calc underflows
        let notional_target_u128: u128 = (qty_total as u128) * (px_live as u128);
        let mm_target_u128: u128 = (notional_target_u128 * (inst.risk.mm_bps as u128)) / 10_000u128;
        let deficit = if (maint > collateral) { (maint - collateral) as u128 } else { 0u128 };
        let close_notional = if (mm_target_u128 > 0u128) { if (deficit < notional_target_u128) { deficit } else { notional_target_u128 } } else { 0u128 };
        let close_qty = if (close_notional > 0u128) { clamp_u128_to_u64((close_notional + (px_live as u128) - 1u128) / (px_live as u128)) } else { qty_total };
        let close_qty_final = if (close_qty > qty_total) { qty_total } else { close_qty };
        if (close_qty_final == 0) { return };

        // Liquidation penalty on closed notional
        let liq_notional_u128: u128 = (close_qty_final as u128) * (px_live as u128);
        let pen = clamp_u128_to_u64((liq_notional_u128 * (inst.risk.liq_penalty_bps as u128)) / 10_000u128);
        let mut coin_pen = { let bal = balance::split(&mut vault.collateral, pen); coin::from_balance(bal, ctx) };
        let bot_cut = (pen * registry.global_params.bot_split) / 10_000;
        let to_keeper = coin::split(&mut coin_pen, bot_cut, ctx);
        transfer::public_transfer(to_keeper, liquidator);
        TreasuryMod::deposit_collateral(treasury, coin_pen, b"liq_penalty".to_string(), liquidator, ctx);

        // Realized loss on the closed quantity is seized from collateral immediately
        let mut loss_seized: u64 = 0;
        if (p.side == 0) {
            // closing long at px_live: loss if px_live < entry
            if (px_live < p.entry_px_u64) {
                let diff = p.entry_px_u64 - px_live;
                loss_seized = diff * close_qty_final;
            }
        } else {
            // closing short at px_live: loss if px_live > entry
            if (px_live > p.entry_px_u64) {
                let diff = px_live - p.entry_px_u64;
                loss_seized = diff * close_qty_final;
            }
        };
        if (loss_seized > 0) {
            let bal_loss = balance::split(&mut vault.collateral, loss_seized);
            let coin_loss = coin::from_balance(bal_loss, ctx);
            TreasuryMod::deposit_collateral(treasury, coin_loss, b"liq_loss".to_string(), liquidator, ctx);
            event::emit(CollateralLossDebited { amount: loss_seized, reason: b"liq_loss".to_string(), owner: vault.owner, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        };

        // Reduce position
        p.qty = p.qty - close_qty_final;
        if (p.qty == 0) {
            let _ = table::remove(&mut vault.positions, clone_string(&synthetic_symbol));
            remove_symbol_if_present(&mut vault.position_symbols, &synthetic_symbol);
        } else {
            p.last_px_u64 = px_live;
            p.updated_at_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        };
        event::emit(LiquidationExecuted { vault_id: object::id(vault), liquidator, liquidated_amount: close_qty_final, collateral_seized: pen, liquidation_penalty: pen, synthetic_type: synthetic_symbol, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(LiquidationTriggered { mm_required: maint, collateral, symbol: clone_string(&k), qty_closed: close_qty_final, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    // removed: liquidate_vault_multi (unused)

    /// INIT – executed once on package publish
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
            bot_split: 1_000,                 // 10%
            mint_fee: 50,                     // 0.5%
            burn_fee: 30,                     // 0.3%
            unxv_discount_bps: 2_000,         // 20% discount when paying with UNXV
            maker_rebate_bps: 0,              // disabled by default
            gc_reward_bps: 100,               // 1% of slashed bond to keeper
            maker_bond_bps: 10,               // 0.10% bond of notional required
        };

        // 4️⃣ Create empty tables and admin allow‑list (deployer is first admin)
        let syn_table = table::new<String, SyntheticAsset>(ctx);
        let feed_table = table::new<String, vector<u8>>(ctx);
        let instr_table = table::new<String, Instrument>(ctx);
        let listed_symbols = vector::empty<String>();

        // 5️⃣ Share the SynthRegistry object
        // For now, create a fresh Treasury and capture its ID
        // Treasury is assumed to be created by treasury.init; capture its ID later via a setup tx.
        let treasury_id_local = object::id(&publisher);

        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: syn_table,
            instruments: instr_table,
            oracle_feeds: feed_table,
            listed_symbols,
            global_params: params,
            paused: false,
            treasury_id: treasury_id_local,
            num_synthetics: 0,
            collateral_set: false,
            collateral_cfg_id: option::none<ID>(),
            admins: vec_set::empty<address>(),
        };
        transfer::share_object(registry);

        // Legacy caps removed in favor of centralized AdminRegistry

        // 7️⃣ Register Display metadata so wallets can render the registry nicely
        let mut disp = display::new<SynthRegistry>(&publisher, ctx);
        disp.add(b"name".to_string(),           b"Unxversal Synthetics Registry".to_string());
        disp.add(b"description".to_string(),    b"Central registry storing all synthetic assets listed by Unxversal".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Synthetics".to_string());
        disp.update_version();
        // Keep publisher alive until all display objects are initialized
        transfer::public_transfer(disp, ctx.sender());

        // 8️⃣ Register Display for Order objects (for wallet/explorer UX)
        // 9️⃣ Register Display for SyntheticAssetInfo (keyed wrapper)

        // Finally transfer publisher after all displays are initialized

        // CollateralVault display is registered when governance binds the concrete collateral via set_collateral<C>()

        // OracleConfig display is registered within the oracle module to avoid dependency cycles.
    }

    // Legacy admin cap flows removed in favor of centralized AdminRegistry

    /// Bind the system to a specific collateral coin type C exactly once.
    /// Creates and shares a `CollateralConfig<C>` object and records its ID in the registry.
    /// Also registers Display metadata for `CollateralVault<C>` using a provided `Publisher`.
    public fun set_collateral_admin<C>(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        publisher: &Publisher,
        ctx: &mut TxContext
    ): display::Display<CollateralVault<C>> {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        // One‑time only
        assert!(!registry.collateral_set, E_COLLATERAL_NOT_SET);
        let cfg = CollateralConfig<C> { id: object::new(ctx) };
        let cfg_id = object::id(&cfg);
        registry.collateral_set = true;
        registry.collateral_cfg_id = option::some<ID>(cfg_id);
        // Expose the config as a shared object so other modules can reference it
        transfer::share_object(cfg);
        // Register display for the concrete collateral type now that C is bound
        let disp = init_vault_display<C>(publisher, ctx);
        disp
    }

    /// Admin: list a cash-settled instrument for trading (no minted supply)
    public fun admin_list_instrument(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        symbol: String,
        decimals: u8,
        kind: u8,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        fee_bps: u64,
        im_bps: u64,
        mm_bps: u64,
        liq_penalty_bps: u64,
        feed_id: vector<u8>,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let k = clone_string(&symbol);
        assert!(!table::contains(&registry.instruments, clone_string(&k)), E_ASSET_EXISTS);
        let inst = Instrument { symbol: clone_string(&symbol), decimals, kind, tick_size, lot_size, min_size, fee_bps, max_leverage_bps: 100_000, max_concentration_bps: 100_000, risk: RiskParams { im_bps, mm_bps, liq_penalty_bps } };
        table::add(&mut registry.instruments, clone_string(&symbol), inst);
        if (table::contains(&registry.oracle_feeds, clone_string(&symbol))) { let _ = table::remove(&mut registry.oracle_feeds, clone_string(&symbol)); };
        table::add(&mut registry.oracle_feeds, clone_string(&symbol), feed_id);
        push_symbol_if_missing(&mut registry.listed_symbols, &symbol);
        registry.num_synthetics = registry.num_synthetics + 1;
        event::emit(InstrumentListed { symbol: clone_string(&symbol), kind, fee_bps, im_bps, mm_bps, liq_penalty_bps, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    // Legacy admin function removed

    /// Update the registry's treasury reference to the concrete `Treasury<C>` selected by governance.
    public fun set_registry_treasury_admin<C>(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        treasury: &Treasury<C>,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        registry.treasury_id = object::id(treasury);
        event::emit(ParamsUpdated { updater: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Compatibility: expose is_admin view using our embedded set (seeded via AdminRegistry operations)
    public fun is_admin(registry: &SynthRegistry, who: address): bool { vec_set::contains(&registry.admins, &who) }

    /// Compatibility: grant/revoke admin via AdminRegistry to keep single source of truth.
    /// These functions mirror legacy signatures used by other modules, but delegate to AdminRegistry.
    public fun grant_admin(daddy: &DaddyCap, registry: &mut SynthRegistry, new_admin: address, ctx: &TxContext) {
        // any holder of DaddyCap can add; in practice, governance should hold it
        let _ = daddy; let _ = ctx; // suppress warnings
        vec_set::insert(&mut registry.admins, new_admin);
    }

    public fun revoke_admin(daddy: &DaddyCap, registry: &mut SynthRegistry, bad_admin: address, _ctx: &TxContext) {
        let _ = daddy; // suppress warnings
        if (vec_set::contains(&registry.admins, &bad_admin)) { vec_set::remove(&mut registry.admins, &bad_admin); };
    }

    public fun update_global_params_admin(
        reg_admin: &AdminRegistry,
        registry: &mut SynthRegistry,
        new_params: GlobalParams,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        registry.global_params = new_params;
        event::emit(ParamsUpdated { updater: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

   /// Turn the circuit breaker **off**.
    public fun emergency_pause_admin(reg_admin: &AdminRegistry, registry: &mut SynthRegistry, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        registry.paused = true;
        event::emit(EmergencyPauseToggled { new_state: true, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun resume_admin(reg_admin: &AdminRegistry, registry: &mut SynthRegistry, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        registry.paused = false;
        event::emit(EmergencyPauseToggled { new_state: false, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    // ------------------------
    // Test-only constructors/helpers
    // ------------------------
    #[test_only]
    public fun new_registry_for_testing(ctx: &mut TxContext): SynthRegistry {
        SynthRegistry {
            id: object::new(ctx),
            synthetics: table::new<String, SyntheticAsset>(ctx),
            instruments: table::new<String, Instrument>(ctx),
            oracle_feeds: table::new<String, vector<u8>>(ctx),
            listed_symbols: vector::empty<String>(),
            global_params: GlobalParams {
                min_collateral_ratio: 1_500,
                liquidation_threshold: 1_200,
                liquidation_penalty: 500,
                max_synthetics: 100,
                stability_fee: 200,
                bot_split: 1_000,
                mint_fee: 50,
                burn_fee: 30,
                unxv_discount_bps: 2_000,
                maker_rebate_bps: 0,
                gc_reward_bps: 100,
                maker_bond_bps: 10,
            },
            paused: false,
            treasury_id: object::id_from_address(ctx.sender()),
            num_synthetics: 0,
            collateral_set: false,
            collateral_cfg_id: option::none<ID>(),
            admins: vec_set::empty<address>(),
        }
    }

    #[test_only]
    public fun set_collateral_for_testing<C>(registry: &mut SynthRegistry, ctx: &mut TxContext): CollateralConfig<C> {
        let cfg = CollateralConfig<C> { id: object::new(ctx) };
        registry.collateral_set = true;
        registry.collateral_cfg_id = option::some<ID>(object::id(&cfg));
        cfg
    }

    #[test_only]
    public fun add_synthetic_for_testing(
        registry: &mut SynthRegistry,
        asset_name: String,
        asset_symbol: String,
        decimals: u8,
        min_coll_ratio: u64,
        ctx: &TxContext
    ) {
        let asset = SyntheticAsset {
            name: clone_string(&asset_name),
            symbol: clone_string(&asset_symbol),
            decimals,
            pyth_feed_id: b"".to_string().into_bytes(),
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
        table::add(&mut registry.synthetics, clone_string(&asset_symbol), asset);
        vector::push_back(&mut registry.listed_symbols, asset_symbol);
        registry.num_synthetics = registry.num_synthetics + 1;
    }
}