/// Module: unxversal_oracle
/// ------------------------------------------------------------
/// * Stores an on‑chain allow‑list of valid Pyth price‑feed IDs
/// * Admins (validated via `unxversal::synthetics::AdminCap` allow‑list) can
///   add / remove feeds
/// * `get_latest_price` returns a fresh `I64` price after staleness + ID checks
/// * Includes Display metadata so wallets can show a friendly label
module unxversal::oracle {
    /*******************************
    * Imports
    *******************************/
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::package;
    use sui::object;
    use sui::clock::Clock;          // block‑timestamp source
    use std::vec_set::{Self as VecSet, VecSet};
    use std::string::String;
    use std::time;                  // now_ms helper
    use pyth::price_info;
    use pyth::price_identifier;
    use pyth::price;
    use pyth::price_info::PriceInfoObject;
    use pyth::i64::{Self as I64Mod, I64};
    use pyth::pyth;                 // get_price_no_older_than

    /// Refer to admin allow‑list & caps from synthetics module
    use unxversal::synthetics::{SynthRegistry, AdminCap};

    /*******************************
    * Error codes
    *******************************/
    const E_INVALID_FEED: u64   = 1;   // Price‑feed ID not allowed
    const E_STALE_PRICE: u64    = 2;   // Price older than `max_age`
    const E_NOT_ADMIN: u64      = 3;   // Caller lacks admin rights
    const E_BAD_PRICE: u64      = 4;   // Non‑positive price
    const E_OVERFLOW: u64       = 5;   // Overflow during scaling

    /*******************************
    * OracleConfig – shared object storing the allow‑list
    *******************************/
    public struct OracleConfig has key, store {
        id: UID,
        allowed_feeds: VecSet<vector<u8>>,   // Set of raw feed‑ID bytes
        max_age_sec: u64,                    // Staleness tolerance (default 60)
    }

    /*******************************
    * Helper – assert caller is admin (reuse registry logic)
    *******************************/
    fun assert_is_admin(registry: &SynthRegistry, addr: address) {
        // `assert_is_admin` from synthetics is private, so inline equivalent
        use std::vec_set::{contains};
        assert!(contains(&registry.admin_addrs, addr), E_NOT_ADMIN);
    }

    /*******************************
    * INIT  – called once via synthetics deployment script
    * Creates OracleConfig shared object + Display metadata.
    *******************************/
    public fun init(registry: &SynthRegistry, ctx: &mut TxContext) {
        // Only run if OracleConfig doesn’t already exist (no strict OTW here)
        // Caller must be admin
        assert_is_admin(registry, ctx.sender());

        let config = OracleConfig {
            id: object::new(ctx),
            allowed_feeds: VecSet::empty(),
            max_age_sec: 60,
        };
        transfer::share_object(config);
    }

    /*******************************
    * Admin functions – mutate allow‑list or staleness window
    *******************************/
    public entry fun add_feed_id(
        _admin: &AdminCap,
        registry: &SynthRegistry,
        cfg: &mut OracleConfig,
        feed: vector<u8>,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        VecSet::add(&mut cfg.allowed_feeds, feed);
    }

    public entry fun remove_feed_id(
        _admin: &AdminCap,
        registry: &SynthRegistry,
        cfg: &mut OracleConfig,
        feed: vector<u8>,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        VecSet::remove(&mut cfg.allowed_feeds, feed);
    }

    /// Optional granular setter for staleness allowance
    public entry fun set_max_age(
        _admin: &AdminCap,
        registry: &SynthRegistry,
        cfg: &mut OracleConfig,
        new_max_age: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        cfg.max_age_sec = new_max_age;
    }

    /*******************************
    * Public read – validated price fetch
    *******************************/
    public fun get_latest_price(
        cfg: &OracleConfig,
        clock: &Clock,
        price_info_object: &PriceInfoObject
    ): I64 {
        // Enforce staleness
        let price_struct = pyth::get_price_no_older_than(
            price_info_object,
            clock,
            cfg.max_age_sec
        );

        // Verify feed ID in allow‑list
        let info = price_info::get_price_info_from_price_info_object(price_info_object);
        let pid  = price_identifier::get_bytes(&price_info::get_price_identifier(&info));
        assert!(VecSet::contains(&cfg.allowed_feeds, pid), E_INVALID_FEED);

        // Return price as signed‑64 integer (Pyth expo already encoded)
        price::get_price(&price_struct)
    }

    /*******************************
     * Fixed‑point normalization helpers
     *******************************/
    const SCALE_POW10_1E6: u64 = 6; // micro‑USD

    fun pow10_u128(mut n: u64): u128 {
        let mut acc: u128 = 1u128;
        while (n > 0) {
            acc = acc * 10u128;
            n = n - 1;
        };
        acc
    }

    /// Convert Pyth I64 (signed) to non‑negative u64 magnitude. Aborts if negative.
    fun i64_to_u64_non_negative(x: &I64): u64 {
        assert!(!I64Mod::get_is_negative(x), E_BAD_PRICE);
        I64Mod::get_magnitude_if_positive(x)
    }

    /// Returns price scaled to 1e6 (micro‑USD) as u64 (uses u128 internally)
    public fun get_price_scaled_1e6(
        cfg: &OracleConfig,
        clock: &Clock,
        price_info_object: &PriceInfoObject
    ): u64 {
        let price_struct = pyth::get_price_no_older_than(price_info_object, clock, cfg.max_age_sec);
        // Raw price is signed I64
        let raw_i64 = price::get_price(&price_struct);
        // Abort if negative or zero
        let raw_mag = i64_to_u64_non_negative(&raw_i64);
        assert!(raw_mag > 0, E_BAD_PRICE);

        // Exponent is signed I64
        let expo = price::get_expo(&price_struct);
        let expo_is_neg = I64Mod::get_is_negative(&expo);
        let expo_mag = if (expo_is_neg) { I64Mod::get_magnitude_if_negative(&expo) } else { I64Mod::get_magnitude_if_positive(&expo) };

        // Compute adjustment: adj = 6 (micro‑USD) + expo
        // Represent as sign + magnitude without relying on signed ints
        let mut adj_is_neg = false;
        let mut adj_mag: u64 = 0;
        if (expo_is_neg) {
            if (expo_mag > SCALE_POW10_1E6) {
                adj_is_neg = true;
                adj_mag = expo_mag - SCALE_POW10_1E6;
            } else {
                adj_is_neg = false;
                adj_mag = SCALE_POW10_1E6 - expo_mag;
            }
        } else {
            adj_is_neg = false;
            adj_mag = SCALE_POW10_1E6 + expo_mag;
        };

        let raw_u128 = (raw_mag as u128);
        let scaled_u128 = if (!adj_is_neg) {
            let mul = pow10_u128(adj_mag);
            raw_u128 * mul
        } else {
            let div = pow10_u128(adj_mag);
            raw_u128 / div
        };
        assert!(scaled_u128 <= (u64::MAX as u128), E_OVERFLOW);
        scaled_u128 as u64
    }
}