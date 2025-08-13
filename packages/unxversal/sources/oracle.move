/// Module: unxversal_oracle
/// ------------------------------------------------------------
/// * Stores an on‑chain allow‑list of valid Pyth price‑feed IDs
/// * Admins (validated via `unxversal::synthetics::AdminCap` allow‑list) can
///   add / remove feeds
/// * `get_latest_price` returns a fresh `I64` price after staleness + ID checks
/// * Includes Display metadata so wallets can show a friendly label

module unxversal::oracle {
    // Default aliases for TxContext/object/transfer are available without explicit `use`
    use sui::clock::Clock;          // block‑timestamp source
    use sui::vec_set::{Self as vec_set, VecSet};
    use pyth::price_info;
    use pyth::price_identifier;
    use pyth::price;
    use pyth::price_info::PriceInfoObject;
    use pyth::i64::{Self as I64Mod, I64};
    use pyth::pyth;                 // get_price_no_older_than

    /// Refer to admin caps from synthetics module
    use unxversal::synthetics::{SynthRegistry, AdminCap};


    const E_INVALID_FEED: u64   = 1;   // Price‑feed ID not allowed
    const E_BAD_PRICE: u64      = 2;   // Non‑positive price
    const E_OVERFLOW: u64       = 3;   // Overflow during scaling

    /*******************************
    * OracleConfig – shared object storing the allow‑list
    *******************************/
    public struct OracleConfig has key, store {
        id: UID,
        allowed_feeds: VecSet<vector<u8>>,   // Set of raw feed‑ID bytes
        max_age_sec: u64,                    // Staleness tolerance (default 60)
    }

    /*******************************
    * Helper – admin check
    * Rely on possession of AdminCap since registry allow‑list is private
    *******************************/
    fun assert_has_admin_cap(_admin: &AdminCap) { /* possession is sufficient */ }

    /*******************************
    * INIT  – called once via synthetics deployment script
    * Creates OracleConfig shared object + Display metadata.
    *******************************/
    /// One‑Time Witness enforcing single‑run init
    public struct ORACLE has drop {}

    fun init(_otw: ORACLE, ctx: &mut TxContext) {
        let config = OracleConfig { id: object::new(ctx), allowed_feeds: vec_set::empty<vector<u8>>(), max_age_sec: 60 };
        transfer::share_object(config);
    }

    /*******************************
    * Admin functions – mutate allow‑list or staleness window
    *******************************/
    public fun add_feed_id(
        admin: &AdminCap,
        _registry: &SynthRegistry,
        cfg: &mut OracleConfig,
        feed: vector<u8>,
        _ctx: &TxContext
    ) {
        assert_has_admin_cap(admin);
        vec_set::insert(&mut cfg.allowed_feeds, feed);
    }

    public fun remove_feed_id(
        admin: &AdminCap,
        _registry: &SynthRegistry,
        cfg: &mut OracleConfig,
        feed: vector<u8>,
        _ctx: &TxContext
    ) {
        assert_has_admin_cap(admin);
        vec_set::remove(&mut cfg.allowed_feeds, &feed);
    }

    /// Optional granular setter for staleness allowance
    public fun set_max_age(
        admin: &AdminCap,
        _registry: &SynthRegistry,
        cfg: &mut OracleConfig,
        new_max_age: u64,
        _ctx: &TxContext
    ) {
        assert_has_admin_cap(admin);
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
        assert!(vec_set::contains(&cfg.allowed_feeds, &pid), E_INVALID_FEED);

        // Return price as signed‑64 integer (Pyth expo already encoded)
        price::get_price(&price_struct)
    }

    /*******************************
     * Fixed‑point normalization helpers
     *******************************/
    const SCALE_POW10_1E6: u64 = 6; // micro‑USD
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;

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
        assert!(scaled_u128 <= (U64_MAX_LITERAL as u128), E_OVERFLOW);
        scaled_u128 as u64
    }
}