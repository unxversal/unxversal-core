/// Module: unxversal_oracle
/// ------------------------------------------------------------
/// * Provides oracle staleness config and a symbol→aggregator allow‑list
/// * Admins (validated via `unxversal::synthetics::AdminCap` allow‑list) can
///   set/remove feeds and update staleness policy
/// * `get_price_scaled_1e6` reads a given aggregator with staleness/positivity checks
/// * `get_price_for_symbol` validates aggregator identity against the allow‑list for a symbol

module unxversal::oracle {
    // Default aliases for TxContext/object/transfer are available without explicit `use`
    use sui::clock::Clock;          // block‑timestamp source
    use switchboard::aggregator::{Self as aggregator, Aggregator};
    use switchboard::decimal::{Self as decimal};
    use sui::table::{Self as table, Table};
    use std::string::{Self as string, String};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use sui::event;

    // No cross-module admin types to avoid dependency cycles


    const E_BAD_PRICE: u64     = 1;      // Non‑positive price
    const E_STALE: u64        = 2;      // Update too old
    const E_OVERFLOW: u64     = 3;      // Overflow during scaling
    const E_SYMBOL_UNKNOWN: u64 = 4;    // Symbol not registered
    const E_FEED_MISMATCH: u64  = 5;    // Aggregator id does not match allow‑list
    const E_NOT_ADMIN: u64      = 6;    // Sender is not authorized admin

    /*******************************
    * Legacy OracleConfig – retained for compatibility (staleness policy only)
    *******************************/
    public struct OracleConfig has key, store {
        id: UID,
        max_age_sec: u64,                    // Staleness tolerance (default 60)
    }

    /*******************************
    * OracleRegistry – authoritative symbol→aggregator mapping + staleness policy
    *******************************/
    public struct OracleRegistry has key, store {
        id: UID,
        max_age_sec: u64,
        feeds: Table<String, ID>,            // symbol → aggregator object id
    }

    /*******************************
    * Events
    *******************************/
    public struct OracleRegistryInitialized has copy, drop { by: address, timestamp: u64 }
    public struct OracleFeedSet has copy, drop { symbol: String, aggregator_id: ID, by: address, timestamp: u64 }
    public struct OracleFeedRemoved has copy, drop { symbol: String, by: address, timestamp: u64 }
    public struct OracleMaxAgeUpdated has copy, drop { max_age_sec: u64, by: address, timestamp: u64 }

    /*******************************
    * INIT  – legacy config initializer (kept for backwards compatibility)
    *******************************/
    /// One‑Time Witness enforcing single‑run init
    public struct ORACLE has drop {}

    fun init(_otw: ORACLE, ctx: &mut TxContext) {
        let config = OracleConfig { id: object::new(ctx), max_age_sec: 60 };
        transfer::share_object(config);
    }
    
    /*******************************
    * INIT (new) – create OracleRegistry with default params
    *******************************/
    entry fun init_registry(reg_admin: &AdminRegistry, clock: &Clock, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let reg = OracleRegistry { id: object::new(ctx), max_age_sec: 30, feeds: table::new<String, ID>(ctx) };
        transfer::share_object(reg);
        event::emit(OracleRegistryInitialized { by: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
    }

    /// Optional granular setter for staleness allowance (legacy config)
    public fun set_max_age(cfg: &mut OracleConfig, new_max_age: u64, _ctx: &TxContext) { cfg.max_age_sec = new_max_age; }

    /// Set staleness allowance on the new registry (admin‑gated)
    public fun set_max_age_registry(reg_admin: &AdminRegistry, reg: &mut OracleRegistry, new_max_age: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        reg.max_age_sec = new_max_age;
        event::emit(OracleMaxAgeUpdated { max_age_sec: new_max_age, by: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: set or update the aggregator for a symbol in the allow‑list
    public fun set_feed(reg_admin: &AdminRegistry, reg: &mut OracleRegistry, symbol: String, agg: &Aggregator, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let key_contains = clone_string(&symbol);
        let key_remove = clone_string(&symbol);
        let key_add = clone_string(&symbol);
        let sym_event = clone_string(&symbol);
        if (table::contains(&reg.feeds, key_contains)) { let _ = table::remove(&mut reg.feeds, key_remove); };
        table::add(&mut reg.feeds, key_add, object::id(agg));
        event::emit(OracleFeedSet { symbol: sym_event, aggregator_id: object::id(agg), by: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: remove the aggregator mapping for a symbol
    public fun remove_feed(reg_admin: &AdminRegistry, reg: &mut OracleRegistry, symbol: String, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let key_contains = clone_string(&symbol);
        let key_remove = clone_string(&symbol);
        let sym_event = clone_string(&symbol);
        assert!(table::contains(&reg.feeds, key_contains), E_SYMBOL_UNKNOWN);
        let _ = table::remove(&mut reg.feeds, key_remove);
        event::emit(OracleFeedRemoved { symbol: sym_event, by: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
    }

    /*******************************
    * Public reads – Switchboard values (normalized from 1e18 → 1e6)
    *******************************/
    public fun get_price_scaled_1e6(
        cfg: &OracleConfig,
        clock: &Clock,
        aggregator_obj: &Aggregator
    ): u64 {
        let cur = aggregator::current_result(aggregator_obj);
        let latest_ms = aggregator::max_timestamp_ms(cur);
        let now_ms = sui::clock::timestamp_ms(clock);
        let age_ms = if (now_ms > latest_ms) { now_ms - latest_ms } else { 0 };
        assert!(age_ms <= cfg.max_age_sec * 1000, E_STALE);

        let dec = aggregator::result(cur);
        to_scale_1e6(dec)
    }

    /// Read price for a symbol using the allow‑listed aggregator id on the registry.
    /// Verifies: symbol exists, aggregator id matches, staleness and positivity.
    public fun get_price_for_symbol(
        reg: &OracleRegistry,
        clock: &Clock,
        symbol: &String,
        agg: &Aggregator
    ): u64 {
        let key_contains = clone_string(symbol);
        let key_borrow = clone_string(symbol);
        assert!(table::contains(&reg.feeds, key_contains), E_SYMBOL_UNKNOWN);
        let expected = *table::borrow(&reg.feeds, key_borrow);
        assert!(expected == object::id(agg), E_FEED_MISMATCH);
        let cur = aggregator::current_result(agg);
        let latest_ms = aggregator::max_timestamp_ms(cur);
        let now_ms = sui::clock::timestamp_ms(clock);
        let age_ms = if (now_ms > latest_ms) { now_ms - latest_ms } else { 0 };
        assert!(age_ms <= reg.max_age_sec * 1000, E_STALE);
        let dec = aggregator::result(cur);
        to_scale_1e6(dec)
    }

    /// Expose expected feed ID for a symbol for external validation
    public fun expected_feed_id(reg: &OracleRegistry, symbol: &String): ID {
        let key_contains = clone_string(symbol);
        let key_borrow = clone_string(symbol);
        assert!(table::contains(&reg.feeds, key_contains), E_SYMBOL_UNKNOWN);
        *table::borrow(&reg.feeds, key_borrow)
    }

    /// Expose max staleness in milliseconds for external validation
    public fun max_age_ms(reg: &OracleRegistry): u64 { reg.max_age_sec * 1000 }

    /*******************************
     * Fixed‑point normalization helpers
     *******************************/
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    const ONE_E12: u128 = 1_000_000_000_000;
    const HALF_ONE_E12: u128 = 500_000_000_000;

    /// Normalize Switchboard 1e18 fixed‑point Decimal to protocol 1e6 scale with half‑up rounding.
    public fun to_scale_1e6(dec: &decimal::Decimal): u64 {
        // prices must be non‑negative and non‑zero
        assert!(!decimal::neg(dec), E_BAD_PRICE);
        let v = decimal::value(dec);
        assert!(v > 0, E_BAD_PRICE);

        // half‑up rounding from 1e18 → 1e6 (divide by 1e12)
        let q = v / ONE_E12;
        let r = v % ONE_E12;
        let mut rounded = q;
        if (r >= HALF_ONE_E12) {
            assert!(q < (U64_MAX_LITERAL as u128), E_OVERFLOW);
            rounded = q + 1;
        };
        assert!(rounded <= (U64_MAX_LITERAL as u128), E_OVERFLOW);
        rounded as u64
    }

    /*******************************
    * Helpers
    *******************************/
    fun clone_string(s: &String): String {
        let bytes = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(bytes);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(bytes, i)); i = i + 1; };
        string::utf8(out)
    }

    #[test_only]
    public fun new_registry_for_testing(ctx: &mut TxContext): OracleRegistry {
        OracleRegistry { id: object::new(ctx), max_age_sec: 60, feeds: table::new<String, ID>(ctx) }
    }

    #[test_only]
    public fun new_config_for_testing(ctx: &mut TxContext): OracleConfig {
        OracleConfig { id: object::new(ctx), max_age_sec: 60 }
    }
}