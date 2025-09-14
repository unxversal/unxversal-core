/// Module: unxversal_oracle
/// ------------------------------------------------------------
/// Pyth-backed oracle utilities for Unxversal protocols.
///
/// - Maintains staleness policy and a symbol → Pyth Price Identifier allow‑list
/// - Admins (validated via `unxversal::admin::AdminRegistry`) can set/remove feeds and
///   update staleness policy
/// - `get_price_scaled_1e6` reads a given Pyth `PriceInfoObject` with staleness & positivity checks
/// - `get_price_for_symbol` validates a provided `PriceInfoObject`'s identifier against the allow‑list

module unxvcore::oracle {
    // Default aliases for TxContext/object/transfer are available without explicit `use`
    use sui::clock::Clock;          // block‑timestamp source
    use sui::table::{Self as table, Table};
    use std::string::{Self as string, String};
    use sui::event;

    use unxvcore::admin::{Self as AdminMod, AdminRegistry};

    // Pyth imports
    use pyth::pyth;                                      // read helpers
    use pyth::price::{Self as price};                    // Price struct and accessors
    use pyth::i64::{Self as i64};                        // I64 helpers
    use pyth::price_info::{Self as price_info, PriceInfoObject};
    use pyth::price_identifier::{Self as price_identifier, PriceIdentifier};

    // No cross-module admin types to avoid dependency cycles

    const E_BAD_PRICE: u64       = 1;   // Non‑positive price
    const E_STALE: u64           = 2;   // Update too old
    const E_OVERFLOW: u64        = 3;   // Overflow during scaling
    const E_SYMBOL_UNKNOWN: u64  = 4;   // Symbol not registered
    const E_FEED_MISMATCH: u64   = 5;   // Price identifier mismatch
    const E_NOT_ADMIN: u64       = 6;   // Sender is not authorized admin

    /*******************************
    * Legacy OracleConfig – retained for compatibility (staleness policy only)
    *******************************/
    public struct OracleConfig has key, store {
        id: UID,
        max_age_sec: u64,                    // Staleness tolerance (default 60)
    }

    /*******************************
    * OracleRegistry – authoritative symbol→price identifier mapping + staleness policy
    *******************************/
    public struct OracleRegistry has key, store {
        id: UID,
        max_age_sec: u64,
        feeds: Table<String, PriceIdentifier>,   // symbol → expected Pyth price identifier
    }

    /*******************************
    * Events
    *******************************/
    public struct OracleRegistryInitialized has copy, drop { by: address, timestamp: u64 }
    public struct OracleFeedSet has copy, drop { symbol: String, price_id: vector<u8>, by: address, timestamp: u64 }
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
        let reg = OracleRegistry { id: object::new(ctx), max_age_sec: 30, feeds: table::new<String, PriceIdentifier>(ctx) };
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

    /// Admin: set or update the expected Pyth Price Identifier for a symbol in the allow‑list
    public fun set_feed(reg_admin: &AdminRegistry, reg: &mut OracleRegistry, symbol: String, price_id: PriceIdentifier, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let key_contains = clone_string(&symbol);
        let key_remove = clone_string(&symbol);
        let key_add = clone_string(&symbol);
        let sym_event = clone_string(&symbol);
        if (table::contains(&reg.feeds, key_contains)) { let _ = table::remove(&mut reg.feeds, key_remove); };
        table::add(&mut reg.feeds, key_add, price_id);
        let bytes = price_identifier::get_bytes(&price_id);
        event::emit(OracleFeedSet { symbol: sym_event, price_id: bytes, by: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
    }

    /// Admin convenience: set expected Price Identifier from 32‑byte hex (vector<u8>)
    public fun set_feed_from_bytes(reg_admin: &AdminRegistry, reg: &mut OracleRegistry, symbol: String, price_id_bytes: vector<u8>, clock: &Clock, ctx: &TxContext) {
        let price_id = price_identifier::from_byte_vec(price_id_bytes);
        set_feed(reg_admin, reg, symbol, price_id, clock, ctx);
    }

    /// Admin: remove the mapping for a symbol
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
    * Public reads – Pyth values (scaled to 1e6)
    *******************************/
    public fun get_price_scaled_1e6(
        cfg: &OracleConfig,
        clock: &Clock,
        price_info_object: &PriceInfoObject
    ): u64 {
        let p = pyth::get_price_no_older_than(price_info_object, clock, cfg.max_age_sec);
        price_to_scale_1e6(&p)
    }

    /// Read price for a symbol using the allow‑listed Pyth price identifier on the registry.
    /// Verifies: symbol exists, identifier matches, staleness and positivity.
    public fun get_price_for_symbol(
        reg: &OracleRegistry,
        clock: &Clock,
        symbol: &String,
        price_info_object: &PriceInfoObject
    ): u64 {
        let key_contains = clone_string(symbol);
        let key_borrow = clone_string(symbol);
        assert!(table::contains(&reg.feeds, key_contains), E_SYMBOL_UNKNOWN);
        let expected = *table::borrow(&reg.feeds, key_borrow);

        // Validate the provided PriceInfoObject belongs to the expected identifier
        let info = price_info::get_price_info_from_price_info_object(price_info_object);
        let actual_id = price_info::get_price_identifier(&info);
        assert!(expected == actual_id, E_FEED_MISMATCH);

        // Freshness and price checks via Pyth helper
        let p = pyth::get_price_no_older_than(price_info_object, clock, reg.max_age_sec);
        price_to_scale_1e6(&p)
    }

    /// Expose expected price identifier for a symbol
    public fun expected_feed_id(reg: &OracleRegistry, symbol: &String): PriceIdentifier {
        let key_contains = clone_string(symbol);
        let key_borrow = clone_string(symbol);
        assert!(table::contains(&reg.feeds, key_contains), E_SYMBOL_UNKNOWN);
        *table::borrow(&reg.feeds, key_borrow)
    }

    /// Expose expected price identifier bytes for a symbol
    public fun expected_feed_id_bytes(reg: &OracleRegistry, symbol: &String): vector<u8> {
        let pid = expected_feed_id(reg, symbol);
        price_identifier::get_bytes(&pid)
    }

    /// Expose max staleness in milliseconds for external validation
    public fun max_age_ms(reg: &OracleRegistry): u64 { reg.max_age_sec * 1000 }

    /*******************************
     * Price scaling helpers (to protocol 1e6 scale)
     *******************************/
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;

    /// Compute 10^k as u128. Intended for small k.
    fun pow10_u128(k: u64): u128 {
        let mut acc: u128 = 1;
        let mut i = 0;
        while (i < k) { acc = acc * 10; i = i + 1; };
        acc
    }

    /// Convert a Pyth `Price` to protocol 1e6 scale with half‑up rounding.
    /// Aborts if price is non‑positive or scaling would overflow u64.
    public fun price_to_scale_1e6(p: &price::Price): u64 {
        // Non‑negative, non‑zero price enforced
        let raw = price::get_price(p);
        assert!(!i64::get_is_negative(&raw), E_BAD_PRICE);
        let mag = i64::get_magnitude_if_positive(&raw);
        assert!(mag > 0, E_BAD_PRICE);

        let expo_i64 = price::get_expo(p);
        if (i64::get_is_negative(&expo_i64)) {
            // expo < 0 → divide by 10^(|expo| - 6) or multiply if |expo| <= 6
            let e = i64::get_magnitude_if_negative(&expo_i64);
            if (6 >= e) {
                let mul_exp = 6 - e;                     // safe: 0..6
                let mul = pow10_u128(mul_exp);
                let prod = (mag as u128) * mul;
                assert!(prod <= (U64_MAX_LITERAL as u128), E_OVERFLOW);
                prod as u64
            } else {
                // Divide with half‑up rounding by 10^(e - 6)
                let div_exp = e - 6;
                let div = pow10_u128(div_exp);
                let num = (mag as u128);
                let q = num / div;
                let r = num % div;
                let mut rounded = q;
                if (r * 2 >= div) { rounded = q + 1; };
                assert!(rounded <= (U64_MAX_LITERAL as u128), E_OVERFLOW);
                rounded as u64
            }
        } else {
            // expo >= 0 → multiply by 10^(expo + 6)
            let e = i64::get_magnitude_if_positive(&expo_i64);
            let mul_exp = 6 + e;
            let mul = pow10_u128(mul_exp);
            let prod = (mag as u128) * mul;
            assert!(prod <= (U64_MAX_LITERAL as u128), E_OVERFLOW);
            prod as u64
        }
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
        OracleRegistry { id: object::new(ctx), max_age_sec: 60, feeds: table::new<String, PriceIdentifier>(ctx) }
    }

    #[test_only]
    public fun new_config_for_testing(ctx: &mut TxContext): OracleConfig {
        OracleConfig { id: object::new(ctx), max_age_sec: 60 }
    }
}