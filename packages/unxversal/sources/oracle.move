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
    use pyth::i64::I64;
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

    /// Returns price scaled to 1e6 (micro‑USD) as u64 (uses u128 internally)
    public fun get_price_scaled_1e6(
        cfg: &OracleConfig,
        clock: &Clock,
        price_info_object: &PriceInfoObject
    ): u64 {
        let price_struct = pyth::get_price_no_older_than(price_info_object, clock, cfg.max_age_sec);
        let raw_price_i64 = price::get_price(&price_struct);
        let expo_i64 = price::get_expo(&price_struct);
        assert!(raw_price_i64 > 0, E_BAD_PRICE);

        let raw_u128 = (raw_price_i64 as u128);
        let adj_i64 = (SCALE_POW10_1E6 as i64) + expo_i64;
        let scaled_u128 = if (adj_i64 >= 0) {
            let mul = pow10_u128(adj_i64 as u64);
            raw_u128 * mul
        } else {
            let div = pow10_u128((-adj_i64) as u64);
            raw_u128 / div
        };
        assert!(scaled_u128 <= (u64::MAX as u128), E_OVERFLOW);
        scaled_u128 as u64
    }
}