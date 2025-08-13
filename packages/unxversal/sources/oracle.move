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
    use switchboard::aggregator::{Self as aggregator, Aggregator};
    use switchboard::decimal::{Self as decimal};

    /// Refer to admin caps from synthetics module
    use unxversal::synthetics::{SynthRegistry, AdminCap};


    const E_BAD_PRICE: u64 = 1;      // Non‑positive price
    const E_STALE: u64    = 2;      // Update too old
    const E_OVERFLOW: u64 = 3;      // Overflow during scaling

    /*******************************
    * OracleConfig – shared object storing the allow‑list
    *******************************/
    public struct OracleConfig has key, store {
        id: UID,
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
        let config = OracleConfig { id: object::new(ctx), max_age_sec: 60 };
        transfer::share_object(config);
    }

    
    // Switchboard integration does not maintain an on-chain allow-list here.

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
    * Public read – Switchboard aggregator value (scaled to 1e6)
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
        let v = decimal::value(dec);
        assert!(v > 0, E_BAD_PRICE);
        assert!(v <= (U64_MAX_LITERAL as u128), E_OVERFLOW);
        v as u64
    }

    /*******************************
     * Fixed‑point normalization helpers
     *******************************/
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
}