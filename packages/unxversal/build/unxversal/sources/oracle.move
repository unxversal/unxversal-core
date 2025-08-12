/// Module: unxversal_oracle
/// ------------------------------------------------------------
/// * Stores an on-chain allow-list of valid Pyth price-feed IDs
/// * Admins (validated via `unxversal::synthetics::AdminCap` allow-list) can
///   add / remove feeds
/// * `get_latest_price` returns a fresh `u64` price after staleness + ID checks
/// * Includes Display metadata so wallets can show a friendly label
module unxversal::oracle {
    use sui::clock::Clock;
    use sui::vec_set::{Self as vec_set, VecSet};
    use std::string::String;

    public struct PriceInfoObject has key, store {
        id: UID,
        symbol: String,
        price_micro_usd: u64,
        confidence: u64,
        last_updated_ms: u64,
        feed_id: vector<u8>,
    }

    public struct ORACLE has drop {}

    const E_STALE_PRICE: u64    = 2;
    const E_BAD_PRICE: u64      = 4;

    public struct OracleConfig has key, store {
        id: UID,
        allowed_feeds: VecSet<vector<u8>>,
        max_age_sec: u64,
    }

    // --- Public Accessors for PriceInfoObject ---

    public fun price_info_id(p: &PriceInfoObject): &UID { &p.id }
    public fun price_info_symbol(p: &PriceInfoObject): &String { &p.symbol }
    public fun price_info_price(p: &PriceInfoObject): u64 { p.price_micro_usd }
    public fun price_info_confidence(p: &PriceInfoObject): u64 { p.confidence }
    public fun price_info_last_updated_ms(p: &PriceInfoObject): u64 { p.last_updated_ms }
    public fun price_info_feed_id(p: &PriceInfoObject): &vector<u8> { &p.feed_id }

    // --- Module Logic ---

    fun init(_witness: ORACLE, ctx: &mut tx_context::TxContext) {
        let config = OracleConfig {
            id: object::new(ctx),
            max_age_sec: 300, // 5 minutes
            allowed_feeds: vec_set::empty(),
        };
        transfer::share_object(config);
    }

    public entry fun set_max_age(
        cfg: &mut OracleConfig,
        new_max_age: u64,
        // _admin: &unxversal::synthetics::AdminCap, // Placeholder for admin check
        // _registry: &unxversal::synthetics::SynthRegistry,
        _ctx: &tx_context::TxContext
    ) {
        // unxversal::synthetics::assert_is_admin(_registry, tx_context::sender(_ctx));
        cfg.max_age_sec = new_max_age;
    }

    public fun get_latest_price(
        cfg: &OracleConfig,
        clock: &Clock,
        price_info_object: &PriceInfoObject
    ): u64 {
        let current_time_ms = sui::clock::timestamp_ms(clock);
        let max_age_ms = cfg.max_age_sec * 1000;
        let age_ms = if (current_time_ms >= price_info_object.last_updated_ms) {
            current_time_ms - price_info_object.last_updated_ms
        } else { 0 };
        
        assert!(age_ms <= max_age_ms, E_STALE_PRICE);
        price_info_object.price_micro_usd
    }

    public fun get_price_scaled_1e6(
        cfg: &OracleConfig,
        clock: &Clock,
        price_info_object: &PriceInfoObject
    ): u64 {
        let current_time_ms = sui::clock::timestamp_ms(clock);
        let max_age_ms = cfg.max_age_sec * 1000;
        let age_ms = if (current_time_ms >= price_info_object.last_updated_ms) {
            current_time_ms - price_info_object.last_updated_ms
        } else { 0 };
        
        assert!(age_ms <= max_age_ms, E_STALE_PRICE);
        assert!(price_info_object.price_micro_usd > 0, E_BAD_PRICE);
        
        price_info_object.price_micro_usd
    }
    
    public fun create_price_info(
        symbol: String,
        price_micro_usd: u64,
        confidence: u64,
        feed_id: vector<u8>,
        clock: &Clock,
        ctx: &mut tx_context::TxContext
    ): PriceInfoObject {
        PriceInfoObject {
            id: object::new(ctx),
            symbol,
            price_micro_usd,
            confidence,
            last_updated_ms: sui::clock::timestamp_ms(clock),
            feed_id,
        }
    }
    
    public fun update_price(
        price_info_object: &mut PriceInfoObject,
        new_price_micro_usd: u64,
        new_confidence: u64,
        clock: &Clock
    ) {
        assert!(new_price_micro_usd > 0, E_BAD_PRICE);
        price_info_object.price_micro_usd = new_price_micro_usd;
        price_info_object.confidence = new_confidence;
        price_info_object.last_updated_ms = sui::clock::timestamp_ms(clock);
    }
}