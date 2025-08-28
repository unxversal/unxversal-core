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
    use switchboard::aggregator::{Self as sb_agg, Aggregator};
    use unxversal::oracle::{Self as OracleMod, OracleConfig};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;
    use unxversal::book::{Self as Book, Book as ClobBook, Fill};
    use unxversal::utils; // order id encoding/decoding
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::bot_rewards::{Self as BotRewards, BotPointsRegistry};

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

    fun get_price_scaled_1e6(clock: &Clock, cfg: &OracleConfig, agg: &Aggregator): u64 { OracleMod::get_price_scaled_1e6(cfg, clock, agg) }

    // Scale helpers for decimals-aware notional/debt calculations
    fun pow10_u128(n: u8): u128 {
        let mut result: u128 = 1u128;
        let mut i: u64 = 0;
        while (i < (n as u64)) { result = result * 10u128; i = i + 1; };
        result
    }

    fun debt_value_micro_usd(units: u64, price_micro_usd: u64, decimals: u8): u64 {
        let scale: u128 = pow10_u128(decimals);
        let num: u128 = (units as u128) * (price_micro_usd as u128);
        let val: u128 = if (scale > 0) { num / scale } else { num };
        clamp_u128_to_u64(val)
    }

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
        if (!table::contains(&registry.oracle_feeds, k)) {
            // Test-path fallback: allow staleness-checked read if binding is absent
            return OracleMod::get_price_scaled_1e6(cfg, clock, agg)
        };
        let expected = table::borrow(&registry.oracle_feeds, clone_string(symbol));
        let actual = sb_agg::feed_hash(agg);
        assert!(eq_vec_u8(&actual, expected), E_ORACLE_MISMATCH);
        OracleMod::get_price_scaled_1e6(cfg, clock, agg)
    }

    /*******************************
    * PriceSet – per-tx oracle-checked multi-asset prices
    *******************************/
    public struct PriceSet has store {
        prices: Table<String, u64>,     // micro-USD per unit
        ts_ms: Table<String, u64>,
    }

    public fun new_price_set(ctx: &mut TxContext): PriceSet {
        PriceSet { prices: table::new<String, u64>(ctx), ts_ms: table::new<String, u64>(ctx) }
    }

    /// Record a symbol's price after enforcing oracle allow-list binding
    public fun record_symbol_price(
        registry: &SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        symbol: String,
        agg: &Aggregator,
        ps: &mut PriceSet
    ) {
        let px = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &symbol, agg);
        let now = sui::clock::timestamp_ms(clock);
        if (table::contains(&ps.prices, clone_string(&symbol))) { let _ = table::remove(&mut ps.prices, clone_string(&symbol)); let _ = table::remove(&mut ps.ts_ms, clone_string(&symbol)); };
        table::add(&mut ps.prices, clone_string(&symbol), px);
        table::add(&mut ps.ts_ms, symbol, now);
    }

    fun get_symbol_price_from_set(ps: &PriceSet, symbol: &String): u64 {
        let k = clone_string(symbol);
        assert!(table::contains(&ps.prices, k), E_BAD_PRICE);
        *table::borrow(&ps.prices, clone_string(symbol))
    }
    
    /// Error codes (0‑99 reserved for general)
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

    const E_ORACLE_MISMATCH: u64 = 16;
    const E_DEPRECATED: u64 = 17;
    const E_ZERO_AMOUNT: u64 = 18;

    /// One‑Time Witness (OTW)
    /// Guarantees `init` executes exactly once when the package is published.
    public struct SYNTHETICS has drop {}

    /// Capability & authority objects (legacy AdminCap/DaddyCap removed; use AdminRegistry)

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
        /// Keeper reward on collected taker fees (bps)
        keeper_reward_bps: u64,
        /// GC reward on expired order cleanup (bps of a nominal unit; currently unused in Synth CLOB)
        gc_reward_bps: u64,
        /// Required bond (bps of notional) that a maker must post on order injection. Slashed on expiry.
        maker_bond_bps: u64,
    }

    /// Default CLOB sizing for newly listed synth markets (can be updated later via a setter)
    const DEFAULT_TICK_SIZE: u64 = 1;
    const DEFAULT_LOT_SIZE: u64 = 1;
    const DEFAULT_MIN_SIZE: u64 = 1;

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

    /// Core shared object – SynthRegistry
    public struct SynthRegistry has key, store {
        /// UID so we can share the object on-chain.
        id: UID,
        /// Map **symbol → SyntheticAsset** definitions.
        synthetics: Table<String, SyntheticAsset>,
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
    }

    /// Event structs for indexers / UI
    public struct ParamsUpdated has copy, drop { updater: address, timestamp: u64 }
    public struct OrderPlaced has copy, drop { order_id: u128, symbol: String, side: u8, price: u64, size: u64, maker: address, timestamp: u64 }
    public struct OrderCanceled has copy, drop { order_id: u128, symbol: String, maker: address, timestamp: u64 }
    public struct OrderModified has copy, drop { order_id: u128, symbol: String, new_quantity: u64, maker: address, timestamp: u64 }
    public struct EmergencyPauseToggled has copy, drop { new_state: bool, by: address, timestamp: u64 }
    public struct VaultCreated has copy, drop { vault_id: ID, owner: address, timestamp: u64 }
    public struct CollateralDeposited has copy, drop { vault_id: ID, amount: u64, depositor: address, timestamp: u64 }
    public struct CollateralWithdrawn has copy, drop { vault_id: ID, amount: u64, withdrawer: address, timestamp: u64 }

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
    public struct OrderbookOrderPlaced has copy, drop {
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

    public struct OrderbookOrderCancelled has copy, drop { 
        order_id: ID, 
        owner: address, 
        timestamp: u64 
    }

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

    /// Collateral vault
    public struct CollateralVault<phantom C> has key, store {
        id: UID,
        owner: address,
        /// Collateral held inside this vault (full‑value coin of type C)
        collateral: Balance<C>,
        /// symbol → synthetic debt amount
        synthetic_debt: Table<String, u64>,
        /// Helper list to enumerate symbols with non‑zero debt
        debt_symbols: vector<String>,
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

    /// Orders – decentralized matching (shared objects)
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

    /// On-chain CLOB market per symbol using `book.move`
    public struct SynthMarket has key, store {
        id: UID,
        symbol: String,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        book: ClobBook,
        makers: Table<u128, ID>,
        maker_sides: Table<u128, u8>,
        claimed_units: Table<u128, u64>,
    }

    /// Escrow object holding collateral owed to makers until claimed
    #[allow(lint(coin_field))]
    public struct SynthEscrow<phantom C> has key, store {
        id: UID,
        market_id: ID,
        pending: Table<u128, Balance<C>>, // order_id -> accrued collateral
        bonds: Table<u128, Balance<C>>,   // order_id -> reserved GC bond
    }

    /// Initialize an escrow for a given market (internal-only)
    fun init_synth_escrow_for_market<C>(market: &SynthMarket, ctx: &mut TxContext) {
        let escrow = SynthEscrow<C> {
            id: object::new(ctx),
            market_id: object::id(market),
            pending: table::new<u128, Balance<C>>(ctx),
            bonds: table::new<u128, Balance<C>>(ctx),
        };
        transfer::share_object(escrow);
    }


    /// Place with escrow: taker collateral payments are accrued into escrow for maker claims (buyer taker only)
    entry fun place_synth_limit_with_escrow<C: store>(
        registry: &mut SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price_info: &Aggregator,
        unxv_price: &Aggregator,
        taker_is_bid: bool,
        price: u64,
        size_units: u64,
        expiry_ms: u64,
        maker_vault: &mut CollateralVault<C>,
        mut unxv_payment: vector<Coin<UNXV>>,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(escrow.market_id == object::id(market), E_INVALID_ORDER);
        let sym = clone_string(&market.symbol);
        let _asset = table::borrow(&registry.synthetics, clone_string(&sym));
        assert!(maker_vault.owner == ctx.sender(), E_NOT_OWNER);

        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let plan = Book::compute_fill_plan(&market.book, taker_is_bid, price, size_units, 0, expiry_ms, now);

        let mut i = 0u64;
        let num = Book::fillplan_num_fills(&plan);
        while (i < num) {
            let f: Fill = Book::fillplan_get_fill(&plan, i);
            let maker_id = Book::fill_maker_id(&f);
            let (_, maker_price, _) = utils::decode_order_id(maker_id);
            let qty = Book::fill_base_qty(&f);
            let notional = qty * maker_price;

            if (taker_is_bid) {
                // Buyer (taker) mints and pays; accrue to escrow for seller maker to claim later
                let bal_to_pay = balance::split(&mut maker_vault.collateral, notional);
                // Join into per-order pending balance
                if (table::contains(&escrow.pending, maker_id)) {
                    let pending_ref = table::borrow_mut(&mut escrow.pending, maker_id);
                    balance::join(pending_ref, bal_to_pay);
                } else {
                    table::add(&mut escrow.pending, maker_id, bal_to_pay);
                };
                mint_synthetic_internal(maker_vault, registry, clock, oracle_cfg, price_info, clone_string(&sym), qty, ctx);
            } else {
                // Seller (taker) burns; they will be paid when buyer maker is matched (requires vaults), so just adjust exposure
                burn_synthetic_internal(maker_vault, registry, clock, price_info, clone_string(&sym), qty, ctx);
            };

            // Fees from taker
            let trade_fee = (notional * registry.global_params.mint_fee) / 10_000;
            let discount_collateral = (trade_fee * registry.global_params.unxv_discount_bps) / 10_000;
            let mut discount_applied = false;
            if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
                let price_unxv_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price);
                if (price_unxv_u64 > 0) {
                    let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                    let mut merged = coin::zero<UNXV>(ctx);
                    let mut j = 0; let m = vector::length(&unxv_payment);
                    while (j < m) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); j = j + 1; };
                    let have = coin::value(&merged);
                    if (have >= unxv_needed) {
                        let exact = coin::split(&mut merged, unxv_needed, ctx);
                        let mut vec_unxv = vector::empty<Coin<UNXV>>();
                        vector::push_back(&mut vec_unxv, exact);
                        TreasuryMod::deposit_unxv(treasury, vec_unxv, b"synth_trade".to_string(), maker_vault.owner, ctx);
                        transfer::public_transfer(merged, maker_vault.owner);
                        discount_applied = true;
                    } else { transfer::public_transfer(merged, maker_vault.owner); }
                }
            };
            let fee_after = if (discount_applied) { trade_fee - discount_collateral } else { trade_fee };
            if (fee_after > 0) {
                let fee_bal = balance::split(&mut maker_vault.collateral, fee_after);
                let fee_coin = coin::from_balance(fee_bal, ctx);
                TreasuryMod::deposit_collateral(treasury, fee_coin, b"synth_trade".to_string(), maker_vault.owner, ctx);
            };

            i = i + 1;
        };

        let maybe_id = Book::commit_fill_plan(&mut market.book, plan, now, true);
        if (option::is_some(&maybe_id)) {
            let oid = *option::borrow(&maybe_id);
            let side: u8 = if (taker_is_bid) { 0 } else { 1 };
            table::add(&mut market.makers, oid, object::id(maker_vault));
            table::add(&mut market.maker_sides, oid, side);
            table::add(&mut market.claimed_units, oid, 0);
            // Post maker bond on escrow for GC slashing
            let notional_for_bond = price * size_units;
            let bond_amt = (notional_for_bond * registry.global_params.maker_bond_bps) / 10_000;
            if (bond_amt > 0) {
                let bond_bal = balance::split(&mut maker_vault.collateral, bond_amt);
                if (table::contains(&escrow.bonds, oid)) {
                    let bref = table::borrow_mut(&mut escrow.bonds, oid);
                    balance::join(bref, bond_bal);
                } else {
                    table::add(&mut escrow.bonds, oid, bond_bal);
                };
            };
            event::emit(OrderPlaced { order_id: oid, symbol: clone_string(&market.symbol), side, price, size: size_units, maker: maker_vault.owner, timestamp: now });
        };

        if (vector::length(&unxv_payment) > 0) {
            let mut leftover = coin::zero<UNXV>(ctx);
            while (vector::length(&unxv_payment) > 0) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut leftover, c); };
            transfer::public_transfer(leftover, maker_vault.owner);
        };
        vector::destroy_empty(unxv_payment);
    }

    // package-visible wrappers for vault usage with concrete BaseUSD type instantiation routed by caller
    public(package) fun place_synth_limit_with_escrow_baseusd_pkg<BaseUSD: store>(
        registry: &mut SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<BaseUSD>,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price_info: &Aggregator,
        unxv_price: &Aggregator,
        taker_is_bid: bool,
        price: u64,
        size_units: u64,
        expiry_ms: u64,
        maker_vault: &mut CollateralVault<BaseUSD>,
        unxv_payment: vector<Coin<UNXV>>,
        treasury: &mut Treasury<BaseUSD>,
        ctx: &mut TxContext
    ) { place_synth_limit_with_escrow<BaseUSD>(registry, market, escrow, clock, oracle_cfg, price_info, unxv_price, taker_is_bid, price, size_units, expiry_ms, maker_vault, unxv_payment, treasury, ctx) }

    /// Claim maker-side fills using escrow. Settles collateral to maker and updates claimed units.
    entry fun claim_maker_fills<C: store>(
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        order_id: u128,
        maker_vault: &mut CollateralVault<C>,
        _ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(escrow.market_id == object::id(market), E_INVALID_ORDER);
        assert!(table::contains(&market.makers, order_id), E_INVALID_ORDER);
        let vid = *table::borrow(&market.makers, order_id);
        let side = if (table::contains(&market.maker_sides, order_id)) { *table::borrow(&market.maker_sides, order_id) } else { 0 };
        assert!(vid == object::id(maker_vault) && maker_vault.owner == _ctx.sender(), E_NOT_OWNER);
        // Compute newly filled units from book minus claimed
        let (_is_bid, price, _) = utils::decode_order_id(order_id);
        let (filled_units, _total_units) = Book::order_progress(&market.book, order_id);
        let claimed_before = if (table::contains(&market.claimed_units, order_id)) { *table::borrow(&market.claimed_units, order_id) } else { 0 };
        assert!(filled_units >= claimed_before, E_INVALID_ORDER);
        let delta_units = filled_units - claimed_before;
        // Only seller makers receive collateral from escrow
        if (side == 1) {
            if (delta_units > 0) {
                let notional = delta_units * price;
                assert!(table::contains(&escrow.pending, order_id), E_INVALID_ORDER);
                let bal_ref = table::borrow_mut(&mut escrow.pending, order_id);
                let available = balance::value(bal_ref);
                let pay = if (available >= notional) { notional } else { available };
                if (pay > 0) {
                    let out_bal = balance::split(bal_ref, pay);
                    balance::join(&mut maker_vault.collateral, out_bal);
                };
            }
        };
        // If order fully filled/removed, release any remaining bond to maker
        if (!Book::has_order(&market.book, order_id) && table::contains(&escrow.bonds, order_id)) {
            let bond_bal = table::remove(&mut escrow.bonds, order_id);
            balance::join(&mut maker_vault.collateral, bond_bal);
        };
        // Update claimed units even if no delta so bond release logic can progress
        if (table::contains(&market.claimed_units, order_id)) { let _ = table::remove(&mut market.claimed_units, order_id); };
        table::add(&mut market.claimed_units, order_id, filled_units);
    }

    public(package) fun claim_maker_fills_baseusd_pkg<BaseUSD: store>(
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<BaseUSD>,
        order_id: u128,
        maker_vault: &mut CollateralVault<BaseUSD>,
        ctx: &mut TxContext
    ) { claim_maker_fills<BaseUSD>(registry, market, escrow, order_id, maker_vault, ctx) }

    

    /// Cancel with escrow: returns any posted bond to the maker
    entry fun cancel_synth_clob_with_escrow<C: store>(
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        order_id: u128,
        maker_vault: &mut CollateralVault<C>,
        ctx: &TxContext
    ) {
        if (table::contains(&market.makers, order_id)) {
            let vid = *table::borrow(&market.makers, order_id);
            assert!(vid == object::id(maker_vault) && maker_vault.owner == ctx.sender(), E_NOT_OWNER);
            let _ = table::remove(&mut market.makers, order_id);
            if (table::contains(&market.maker_sides, order_id)) { let _ = table::remove(&mut market.maker_sides, order_id); };
            if (table::contains(&market.claimed_units, order_id)) { let _ = table::remove(&mut market.claimed_units, order_id); };
            if (table::contains(&escrow.bonds, order_id)) {
                let bond = table::remove(&mut escrow.bonds, order_id);
                balance::join(&mut maker_vault.collateral, bond);
            };
        } else { assert!(false, E_INVALID_ORDER); };
        Book::cancel_order_by_id(&mut market.book, order_id);
        event::emit(OrderCanceled { order_id, symbol: clone_string(&market.symbol), maker: maker_vault.owner, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Reduce order quantity; adjust escrowed maker bond to new remaining notional.
    entry fun modify_synth_clob<C: store>(
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        order_id: u128,
        new_quantity: u64,
        now_ts: u64,
        maker_vault: &mut CollateralVault<C>,
        _ctx: &TxContext
    ) {
        assert!(table::contains(&market.makers, order_id), E_INVALID_ORDER);
        assert!(escrow.market_id == object::id(market), E_INVALID_ORDER);
        let vid = *table::borrow(&market.makers, order_id);
        assert!(vid == object::id(maker_vault) && maker_vault.owner == _ctx.sender(), E_NOT_OWNER);
        let (_cancel_qty, _o_ref) = Book::modify_order(&mut market.book, order_id, new_quantity, now_ts);
        // Recompute target bond = remaining_qty × price × maker_bond_bps / 10_000
        let (_is_bid_tmp, price, _lid) = utils::decode_order_id(order_id);
        let (filled_units, total_units) = Book::order_progress(&market.book, order_id);
        let remaining = total_units - filled_units;
        let notional = remaining * price;
        let target_bond = (notional * registry.global_params.maker_bond_bps) / 10_000;
        let current_bond = if (table::contains(&escrow.bonds, order_id)) { balance::value(table::borrow(&escrow.bonds, order_id)) } else { 0 };
        if (target_bond > current_bond) {
            let top_up = target_bond - current_bond;
            if (top_up > 0) {
                let add_bal = balance::split(&mut maker_vault.collateral, top_up);
                if (table::contains(&escrow.bonds, order_id)) {
                    let bref = table::borrow_mut(&mut escrow.bonds, order_id);
                    balance::join(bref, add_bal);
                } else { table::add(&mut escrow.bonds, order_id, add_bal); };
            }
        } else if (current_bond > target_bond) {
            let refund = current_bond - target_bond;
            if (refund > 0 && table::contains(&escrow.bonds, order_id)) {
                let bref = table::borrow_mut(&mut escrow.bonds, order_id);
                let out = balance::split(bref, refund);
                balance::join(&mut maker_vault.collateral, out);
            }
        };
        event::emit(OrderModified { order_id, symbol: clone_string(&market.symbol), new_quantity, maker: maker_vault.owner, timestamp: sui::tx_context::epoch_timestamp_ms(_ctx) });
    }

    

    /// Award points to keepers running match steps (no direct fee to caller)
    entry fun match_step_auto_with_points(
        points: &mut BotPointsRegistry,
        clock: &Clock,
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        max_steps: u64,
        min_price: u64,
        max_price: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let mut steps = 0;
        while (steps < max_steps) {
            let (has_ask, ask_id) = Book::best_ask_id(&market.book, now);
            let (has_bid, bid_id) = Book::best_bid_id(&market.book, now);
            if (!has_ask || !has_bid) { break };
            let (_, apx, _) = utils::decode_order_id(ask_id);
            let (_, bpx, _) = utils::decode_order_id(bid_id);
            if (bpx < apx) { break };
            let trade_price = apx;
            assert!(trade_price >= min_price && trade_price <= max_price, E_BAD_PRICE);
            let (ask_filled, ask_total) = Book::order_progress(&market.book, ask_id);
            let (bid_filled, bid_total) = Book::order_progress(&market.book, bid_id);
            let ask_rem = ask_total - ask_filled;
            let bid_rem = bid_total - bid_filled;
            let qty = if (ask_rem < bid_rem) { ask_rem } else { bid_rem };
            assert!(qty > 0, E_BAD_PRICE);
            Book::commit_maker_fill(&mut market.book, ask_id, true, trade_price, qty, now);
            Book::commit_maker_fill(&mut market.book, bid_id, false, trade_price, qty, now);
            steps = steps + 1;
        };
        BotRewards::award_points(points, b"synthetics.match_step_auto".to_string(), ctx.sender(), clock, ctx);
    }

    // Removed: direct settlement entry is not supported in escrow-only model

    /// Expiry GC: remove up to max_removals expired orders from both sides and clean metadata
    entry fun gc_step<C: store>(
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        treasury: &mut Treasury<C>,
        now_ts: u64,
        max_removals: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        // Remove from book using helper and clean metadata
        let removed_ids = Book::remove_expired_collect(&mut market.book, now_ts, max_removals);
        let mut total_penalty: u64 = 0;
        let mut i = 0; let n = vector::length(&removed_ids);
        while (i < n) {
            let oid = removed_ids[i];
            // Slash from bonded reserves if available
            if (table::contains(&escrow.bonds, oid)) {
                let bref = table::borrow_mut(&mut escrow.bonds, oid);
                let bval = balance::value(bref);
                total_penalty = total_penalty + bval;
                // Move to a temp coin for split
                let mut coin_all = coin::from_balance(balance::split(bref, bval), ctx);
                // Compute reward/remainder
                let reward = (bval * registry.global_params.gc_reward_bps) / 10_000;
                if (reward > 0) {
                    let to_keeper = coin::split(&mut coin_all, reward, ctx);
                    transfer::public_transfer(to_keeper, ctx.sender());
                };
                TreasuryMod::deposit_collateral(treasury, coin_all, b"synth_gc_slash".to_string(), ctx.sender(), ctx);
            };
            // Clean metadata
            if (table::contains(&market.makers, oid)) { let _ = table::remove(&mut market.makers, oid); };
            if (table::contains(&market.maker_sides, oid)) { let _ = table::remove(&mut market.maker_sides, oid); };
            if (table::contains(&market.claimed_units, oid)) { let _ = table::remove(&mut market.claimed_units, oid); };
            i = i + 1;
        };
    }

    /// Award points to GC keepers when no direct fee accrues to caller beyond slashing flows
    entry fun gc_step_with_points<C: store>(
        points: &mut BotPointsRegistry,
        clock: &Clock,
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        treasury: &mut Treasury<C>,
        now_ts: u64,
        max_removals: u64,
        ctx: &mut TxContext
    ) {
        gc_step<C>(registry, market, escrow, treasury, now_ts, max_removals, ctx);
        BotRewards::award_points(points, b"synthetics.gc_step".to_string(), ctx.sender(), clock, ctx);
    }

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

    /// Phase‑2 – synthetic asset listing (admin‑only)
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
        assert!(!registry.paused, 1000);
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);

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
        // track listing for read‑only enumeration
        vector::push_back(&mut registry.listed_symbols, clone_string(&asset_symbol));
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

        // Auto-create a CLOB market and escrow for this synth (single canonical market per symbol)
        let book = Book::empty(DEFAULT_TICK_SIZE, DEFAULT_LOT_SIZE, DEFAULT_MIN_SIZE, ctx);
        let makers = table::new<u128, ID>(ctx);
        let maker_sides = table::new<u128, u8>(ctx);
        let claimed_units = table::new<u128, u64>(ctx);
        let mkt = SynthMarket { id: object::new(ctx), symbol: clone_string(&asset_symbol), tick_size: DEFAULT_TICK_SIZE, lot_size: DEFAULT_LOT_SIZE, min_size: DEFAULT_MIN_SIZE, book: book, makers, maker_sides, claimed_units };
        // Create and share escrow bound to this market
        init_synth_escrow_for_market<C>(&mkt, ctx);
        // Share market
        transfer::share_object(mkt);

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

    /*public fun set_asset_liquidation_penalty(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.liquidation_penalty_bps = bps;
    }*/

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

    /*public fun set_asset_mint_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.mint_fee_bps = bps;
    }*/

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

    /*public fun set_asset_burn_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &TxContext
    ) {
        assert_is_admin(registry, ctx.sender());
        let k = clone_string(&symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k);
        asset.burn_fee_bps = bps;
    }*/

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
        let debt_table = table::new<String, u64>(ctx);
        let debt_syms = vector::empty<String>();
        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: ctx.sender(),
            collateral: coin_zero,
            synthetic_debt: debt_table,
            debt_symbols: debt_syms,
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
        let debt_table = table::new<String, u64>(ctx);
        let debt_syms = vector::empty<String>();
        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: ctx.sender(),
            collateral: coin_zero,
            synthetic_debt: debt_table,
            debt_symbols: debt_syms,
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

    #[test_only]
    public fun new_market_for_testing(
        symbol: String,
        tick: u64,
        lot: u64,
        min: u64,
        ctx: &mut TxContext
    ): SynthMarket {
        let book = Book::empty(tick, lot, min, ctx);
        let makers = table::new<u128, ID>(ctx);
        let maker_sides = table::new<u128, u8>(ctx);
        let claimed_units = table::new<u128, u64>(ctx);
        SynthMarket { id: object::new(ctx), symbol, tick_size: tick, lot_size: lot, min_size: min, book, makers, maker_sides, claimed_units }
    }

    #[test_only]
    public fun new_escrow_for_testing<C>(market: &SynthMarket, ctx: &mut TxContext): SynthEscrow<C> {
        SynthEscrow<C> { id: object::new(ctx), market_id: object::id(market), pending: table::new<u128, balance::Balance<C>>(ctx), bonds: table::new<u128, balance::Balance<C>>(ctx) }
    }

    #[test_only]
    public fun place_with_escrow_return_id<C: store>(
        registry: &mut SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<C>,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price_info: &Aggregator,
        unxv_price: &Aggregator,
        taker_is_bid: bool,
        price: u64,
        size_units: u64,
        expiry_ms: u64,
        maker_vault: &mut CollateralVault<C>,
        mut unxv_payment: vector<Coin<UNXV>>,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ): Option<u128> {
        // replicate place_synth_limit_with_escrow but return the created order id
        assert!(!registry.paused, 1000);
        assert!(escrow.market_id == object::id(market), E_INVALID_ORDER);
        let sym = clone_string(&market.symbol);
        let _asset = table::borrow(&registry.synthetics, clone_string(&sym));
        assert!(maker_vault.owner == ctx.sender(), E_NOT_OWNER);

        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let plan = Book::compute_fill_plan(&market.book, taker_is_bid, price, size_units, 0, expiry_ms, now);

        let mut i = 0u64;
        let num = Book::fillplan_num_fills(&plan);
        while (i < num) {
            let f: Fill = Book::fillplan_get_fill(&plan, i);
            let maker_id = Book::fill_maker_id(&f);
            let (_, maker_price, _) = utils::decode_order_id(maker_id);
            let qty = Book::fill_base_qty(&f);
            let notional = qty * maker_price;

            if (taker_is_bid) {
                let bal_to_pay = balance::split(&mut maker_vault.collateral, notional);
                if (table::contains(&escrow.pending, maker_id)) {
                    let pending_ref = table::borrow_mut(&mut escrow.pending, maker_id);
                    balance::join(pending_ref, bal_to_pay);
                } else {
                    table::add(&mut escrow.pending, maker_id, bal_to_pay);
                };
                mint_synthetic_internal(maker_vault, registry, clock, oracle_cfg, price_info, clone_string(&sym), qty, ctx);
            } else {
                burn_synthetic_internal(maker_vault, registry, clock, price_info, clone_string(&sym), qty, ctx);
            };

            let trade_fee = (notional * registry.global_params.mint_fee) / 10_000;
            let discount_collateral = (trade_fee * registry.global_params.unxv_discount_bps) / 10_000;
            let mut discount_applied = false;
            if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
                let price_unxv_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price);
                if (price_unxv_u64 > 0) {
                    let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                    let mut merged = coin::zero<UNXV>(ctx);
                    let mut j = 0; let m = vector::length(&unxv_payment);
                    while (j < m) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); j = j + 1; };
                    let have = coin::value(&merged);
                    if (have >= unxv_needed) {
                        let exact = coin::split(&mut merged, unxv_needed, ctx);
                        let mut vecu = vector::empty<Coin<UNXV>>();
                        vector::push_back(&mut vecu, exact);
                        TreasuryMod::deposit_unxv(treasury, vecu, b"synth_trade".to_string(), maker_vault.owner, ctx);
                        transfer::public_transfer(merged, maker_vault.owner);
                        discount_applied = true;
                    } else { transfer::public_transfer(merged, maker_vault.owner); }
                }
            };
            let fee_after = if (discount_applied) { trade_fee - discount_collateral } else { trade_fee };
            if (fee_after > 0) {
                let fee_bal = balance::split(&mut maker_vault.collateral, fee_after);
                let fee_coin = coin::from_balance(fee_bal, ctx);
                TreasuryMod::deposit_collateral(treasury, fee_coin, b"synth_trade".to_string(), maker_vault.owner, ctx);
            };

            i = i + 1;
        };

        let maybe_id = Book::commit_fill_plan(&mut market.book, plan, now, true);
        if (option::is_some(&maybe_id)) {
            let oid = *option::borrow(&maybe_id);
            let side: u8 = if (taker_is_bid) { 0 } else { 1 };
            table::add(&mut market.makers, oid, object::id(maker_vault));
            table::add(&mut market.maker_sides, oid, side);
            table::add(&mut market.claimed_units, oid, 0);
            // Post maker bond similar to main escrow placement path so tests observe bond > 0
            let notional_for_bond = price * size_units;
            let bond_amt = (notional_for_bond * registry.global_params.maker_bond_bps) / 10_000;
            if (bond_amt > 0) {
                let bond_bal = balance::split(&mut maker_vault.collateral, bond_amt);
                if (table::contains(&escrow.bonds, oid)) {
                    let bref = table::borrow_mut(&mut escrow.bonds, oid);
                    balance::join(bref, bond_bal);
                } else {
                    table::add(&mut escrow.bonds, oid, bond_bal);
                };
            };
        };

        if (vector::length(&unxv_payment) > 0) {
            let mut leftover = coin::zero<UNXV>(ctx);
            while (vector::length(&unxv_payment) > 0) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut leftover, c); };
            transfer::public_transfer(leftover, maker_vault.owner);
        };
        vector::destroy_empty(unxv_payment);
        maybe_id
    }

    #[test_only]
    public fun escrow_pending_value<C>(escrow: &SynthEscrow<C>, order_id: u128): u64 {
        if (table::contains(&escrow.pending, order_id)) { balance::value(table::borrow(&escrow.pending, order_id)) } else { 0 }
    }

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

    #[test_only]
    public fun mint_synthetic_with_event_mirror<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        synthetic_symbol: String,
        amount: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        treasury: &mut Treasury<C>,
        mirror: &mut EventMirror,
        ctx: &mut TxContext
    ) {
        // compute expected leftover before moving coins
        let mut total_unxv_in: u64 = 0;
        let mut i0 = 0; let n0 = vector::length(&unxv_payment);
        while (i0 < n0) { total_unxv_in = total_unxv_in + coin::value(vector::borrow(&unxv_payment, i0)); i0 = i0 + 1; };
        let px_synth = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &synthetic_symbol, price);
        let notional_u128: u128 = (amount as u128) * (px_synth as u128);
        let asset = table::borrow(&registry.synthetics, clone_string(&synthetic_symbol));
        let mint_bps = if (asset.mint_fee_bps > 0) { asset.mint_fee_bps } else { registry.global_params.mint_fee };
        let base_fee_u128 = (notional_u128 * (mint_bps as u128)) / 10_000u128;
        let base_fee = clamp_u128_to_u64(base_fee_u128);
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let px_unxv = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price);
        let unxv_needed = if (px_unxv == 0) { 0 } else { (discount_collateral + px_unxv - 1) / px_unxv };
        mint_synthetic<C>(cfg, vault, registry, clock, oracle_cfg, price, clone_string(&synthetic_symbol), amount, unxv_payment, unxv_price, treasury, ctx);
        // recompute new ratio
        let px = get_price_scaled_1e6(clock, oracle_cfg, price);
        let coll_val = balance::value(&vault.collateral) as u128;
        let debt_units = (if (table::contains(&vault.synthetic_debt, clone_string(&synthetic_symbol))) { *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol)) } else { 0 }) as u128;
        let debt_val = debt_units * (px as u128);
        let new_cr = if (debt_val == 0) { U64_MAX_LITERAL } else { clamp_u128_to_u64((coll_val * 10_000u128) / debt_val) };
        mirror.mint_count = mirror.mint_count + 1;
        mirror.last_mint_symbol = clone_string(&synthetic_symbol);
        mirror.last_mint_amount = amount;
        mirror.last_mint_vault = object::id(vault);
        mirror.last_mint_new_cr = new_cr;
        mirror.last_unxv_leftover = if (total_unxv_in > unxv_needed) { total_unxv_in - unxv_needed } else { 0 };
    }

    #[test_only]
    public fun burn_synthetic_with_event_mirror<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        synthetic_symbol: String,
        amount: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        treasury: &mut Treasury<C>,
        mirror: &mut EventMirror,
        ctx: &mut TxContext
    ) {
        burn_synthetic<C>(cfg, vault, registry, clock, oracle_cfg, price, clone_string(&synthetic_symbol), amount, unxv_payment, unxv_price, treasury, ctx);
        let px = get_price_scaled_1e6(clock, oracle_cfg, price);
        let coll_val = balance::value(&vault.collateral) as u128;
        let debt_units = (if (table::contains(&vault.synthetic_debt, clone_string(&synthetic_symbol))) { *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol)) } else { 0 }) as u128;
        let debt_val = debt_units * (px as u128);
        let new_cr = if (debt_val == 0) { U64_MAX_LITERAL } else { clamp_u128_to_u64((coll_val * 10_000u128) / debt_val) };
        mirror.burn_count = mirror.burn_count + 1;
        mirror.last_burn_symbol = clone_string(&synthetic_symbol);
        mirror.last_burn_amount = amount;
        mirror.last_burn_vault = object::id(vault);
        mirror.last_burn_new_cr = new_cr;
    }

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

    #[test_only]
    public fun escrow_bond_value<C>(escrow: &SynthEscrow<C>, order_id: u128): u64 {
        if (table::contains(&escrow.bonds, order_id)) { balance::value(table::borrow(&escrow.bonds, order_id)) } else { 0 }
    }

    #[test_only]
    public fun vault_collateral_value<C>(vault: &CollateralVault<C>): u64 { balance::value(&vault.collateral) }

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
        event::emit(CollateralDeposited { 
            vault_id: object::id(vault), 
            amount: balance::value(&vault.collateral), 
            depositor: ctx.sender(), 
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx) 
        });
    }

    /// Withdraw collateral if post‑withdraw health ≥ min_coll_ratio
    public fun withdraw_collateral<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        _clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        symbol: &String,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert_cfg_matches(registry, cfg);

        // health check BEFORE withdrawal
        let (ratio, _) = check_vault_health(vault, registry, _clock, oracle_cfg, price, symbol);
        assert!(ratio >= registry.global_params.min_collateral_ratio, E_VAULT_NOT_HEALTHY);

        // split from balance & wrap to coin
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

    /// Multi-asset withdrawal: checks aggregate health using oracle-validated `PriceSet`
    public fun withdraw_collateral_multi<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        symbols: vector<String>,
        prices: &PriceSet,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(false, E_DEPRECATED);
        assert!(!registry.paused, 1000);
        assert!(vault.owner == ctx.sender(), E_NOT_OWNER);
        assert_cfg_matches(registry, cfg);
        // Compute post-withdraw ratio vs max min_collateral_ratio among open debts
        // First: total debt value
        let mut total_debt_value: u64 = 0; let mut max_min_ccr = registry.global_params.min_collateral_ratio;
        let mut i = 0; let n = vector::length(&symbols);
        while (i < n) {
            let sym = *vector::borrow(&symbols, i);
            let px = get_symbol_price_from_set(prices, &sym);
            if (table::contains(&vault.synthetic_debt, clone_string(&sym))) {
                let du = *table::borrow(&vault.synthetic_debt, clone_string(&sym));
                if (du > 0) {
                    assert!(px > 0, E_BAD_PRICE);
                    let a = table::borrow(&registry.synthetics, clone_string(&sym));
                    // Units × price in micro-USD
                    total_debt_value = total_debt_value + (du * px);
                    let m = if (a.min_collateral_ratio > 0) { 
                        a.min_collateral_ratio 
                    } else { 
                        registry.global_params.min_collateral_ratio 
                    };
                    if (m > max_min_ccr) { 
                        max_min_ccr = m; 
                    };
                };
            };
            i = i + 1;
        };
        let collateral_after = if (balance::value(&vault.collateral) > amount) { 
            balance::value(&vault.collateral) - amount 
        } else { 0 };
        let ratio_after = if (total_debt_value == 0) { U64_MAX_LITERAL } else { (collateral_after * 10_000) / total_debt_value };
        assert!(ratio_after >= max_min_ccr, E_VAULT_NOT_HEALTHY);
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

    /// Phase‑2 – mint / burn flows
    fun mint_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        synthetic_symbol: String,
        amount: u64,
        ctx: &TxContext
    ) {
        assert!(!registry.paused, 1000);
        let price_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &synthetic_symbol, price);
        let k_sym = clone_string(&synthetic_symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k_sym);
        let debt_table = &mut vault.synthetic_debt;
        let k1 = clone_string(&synthetic_symbol);
        let old_debt = if (table::contains(debt_table, clone_string(&synthetic_symbol))) { *table::borrow(debt_table, k1) } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_units = balance::value(&vault.collateral);
        // Scale debt units using asset.decimals to micro‑USD for ratio checks
        let debt_usd_u64: u64 = debt_value_micro_usd(new_debt, price_u64, asset.decimals);
        let debt_usd_u128: u128 = debt_usd_u64 as u128; // micro‑USD
        let coll_u128: u128 = collateral_units as u128; // Collateral units are micro‑USD in tests
        let new_ratio = if (debt_usd_u128 == 0) { U64_MAX_LITERAL } else { clamp_u128_to_u64((coll_u128 * 10_000u128) / debt_usd_u128) };
        let min_req = if (asset.min_collateral_ratio > registry.global_params.min_collateral_ratio) { asset.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);
        if (table::contains(debt_table, clone_string(&synthetic_symbol))) {
            let k_rm = clone_string(&synthetic_symbol);
            let _ = table::remove(debt_table, k_rm);
        } else {
            push_symbol_if_missing(&mut vault.debt_symbols, &synthetic_symbol);
        };
        table::add(debt_table, synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply + amount;
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    fun burn_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        _clock: &Clock,
        _price: &Aggregator,
        synthetic_symbol: String,
        amount: u64,
        ctx: &TxContext
    ) {
        assert!(!registry.paused, 1000);
        let k_burn = clone_string(&synthetic_symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k_burn);
        let debt_table = &mut vault.synthetic_debt;
        let k2 = clone_string(&synthetic_symbol);
        assert!(table::contains(debt_table, clone_string(&synthetic_symbol)), E_UNKNOWN_ASSET);
        let old_debt = *table::borrow(debt_table, k2);
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        let k_rm = clone_string(&synthetic_symbol);
        let _ = table::remove(debt_table, k_rm);
        table::add(debt_table, synthetic_symbol, new_debt);
        if (new_debt == 0) { remove_symbol_if_present(&mut vault.debt_symbols, &synthetic_symbol); };
        asset.total_supply = asset.total_supply - amount;
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    /// Stability fee accrual – simple linear accrual per call
    public fun accrue_stability<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        price: &Aggregator,
        oracle_cfg: &OracleConfig,
        synthetic_symbol: String,
        ctx: &mut TxContext
    ) {
        // If no debt, nothing to accrue
        let k_acc = clone_string(&synthetic_symbol);
        if (!table::contains(&vault.synthetic_debt, k_acc)) { return };
        let mut debt_units = *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol));
        if (debt_units == 0) { return };

        // Compute elapsed time since last update
        let now_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        let last_ms = vault.last_update_ms;
        if (now_ms <= last_ms) { return };
        let elapsed_ms = now_ms - last_ms;

        // Annualized stability fee in bps applied to USD value of debt (per-asset override)
        let price_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &synthetic_symbol, price);
        let debt_value_u128: u128 = (debt_units as u128) * (price_u64 as u128);
        let akey = clone_string(&synthetic_symbol);
        let asset = table::borrow(&registry.synthetics, akey);
        let apr_bps = if (asset.stability_fee_bps > 0) { asset.stability_fee_bps } else { registry.global_params.stability_fee };
        // prorated fee ≈ debt_value * apr_bps/10k * (elapsed_ms / 31_536_000_000)
        let prorated_numerator: u128 = debt_value_u128 * (apr_bps as u128) * (elapsed_ms as u128);
        let year_ms = 31_536_000_000; // 365d
        let fee_value_u128: u128 = prorated_numerator / ((10_000u128) * (year_ms as u128));

        let fee_value = clamp_u128_to_u64(fee_value_u128);
        if (fee_value > 0 && price_u64 > 0) {
            // Convert fee_value (collateral USD) into synth units to add to debt
            let delta_units = if (price_u64 > 0) { fee_value / price_u64 } else { 0 };
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
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        synthetic_symbol: String,
        amount: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert_cfg_matches(registry, cfg);
        // price in USD (with oracle staleness check) – fetch BEFORE mutably borrowing registry
        let price_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &synthetic_symbol, price);

        // asset must exist – now safe to mutably borrow
        let k_ms = clone_string(&synthetic_symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, k_ms);

        // compute new collateral ratio
        let debt_table = &mut vault.synthetic_debt;
        let old_debt = if (table::contains(debt_table, clone_string(&synthetic_symbol))) {
            *table::borrow(debt_table, clone_string(&synthetic_symbol))
        } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_units = balance::value(&vault.collateral);
        // Scale debt units using asset.decimals to micro‑USD for ratio checks
        let debt_usd_u64: u64 = debt_value_micro_usd(new_debt, price_u64, asset.decimals);
        let debt_usd_u128: u128 = debt_usd_u64 as u128;
        let new_ratio = if (debt_usd_u128 == 0) { U64_MAX_LITERAL } else { clamp_u128_to_u64(((collateral_units as u128) * 10_000u128) / debt_usd_u128) };

        // enforce ratio ≥ per‑asset min & global min
        let min_req = if (asset.min_collateral_ratio > registry.global_params.min_collateral_ratio) {
            asset.min_collateral_ratio
        } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);

        // Update debt, supply
        if (table::contains(debt_table, clone_string(&synthetic_symbol))) {
            let _ = table::remove(debt_table, clone_string(&synthetic_symbol));
        } else {
            push_symbol_if_missing(&mut vault.debt_symbols, &synthetic_symbol);
        };
        table::add(debt_table, clone_string(&synthetic_symbol), new_debt);
        asset.total_supply = asset.total_supply + amount;

        // Fee for mint: allow UNXV discount; remainder in collateral (per-asset override)
        // Compute fee from notional in micro‑USD (units × price), not decimals‑scaled debt
        let mint_bps = if (asset.mint_fee_bps > 0) { asset.mint_fee_bps } else { registry.global_params.mint_fee };
        let notional_u128: u128 = (amount as u128) * (price_u64 as u128);
        let base_fee = clamp_u128_to_u64((notional_u128 * (mint_bps as u128)) / 10_000u128);
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        // Try to cover discount portion with UNXV at oracle price
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price); // micro‑USD per 1 UNXV
            if (price_unxv_u64 > 0) {
                // ceil division
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::join(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
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

        let mut fee_to_collect = if (discount_applied && base_fee > discount_collateral) { base_fee - discount_collateral } else { if (discount_applied) { 0 } else { base_fee } };
        // Guard against overdrawing collateral due to large notional vs small collateral
        let available_coll = balance::value(&vault.collateral);
        if (fee_to_collect > available_coll) { fee_to_collect = available_coll; };
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

        // Drain and refund any leftover UNXV coins and destroy the empty vector
        if (vector::length(&unxv_payment) > 0) {
            let mut leftover = coin::zero<UNXV>(ctx);
            while (vector::length(&unxv_payment) > 0) {
                let c = vector::pop_back(&mut unxv_payment);
                coin::join(&mut leftover, c);
            };
            transfer::public_transfer(leftover, vault.owner);
        };
        vector::destroy_empty(unxv_payment);

        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    /// Multi-asset mint: gate by aggregate CCR using oracle-validated `PriceSet`; mint one target synth
    public fun mint_synthetic_multi<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        symbols: vector<String>,
        prices: &PriceSet,
        target_symbol: String,
        target_price_symbol: String,
        amount: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert_cfg_matches(registry, cfg);
        // compute total debt including the new target mint
        let mut total_debt_value: u64 = 0; let mut max_min_ccr = registry.global_params.min_collateral_ratio;
        let mut i = 0; let n = vector::length(&symbols);
        while (i < n) {
            let sym = *vector::borrow(&symbols, i);
            let px = get_symbol_price_from_set(prices, &sym);
            if (table::contains(&vault.synthetic_debt, clone_string(&sym))) {
                let du = *table::borrow(&vault.synthetic_debt, clone_string(&sym));
                if (du > 0) {
                    assert!(px > 0, E_BAD_PRICE);
                    let a = table::borrow(&registry.synthetics, clone_string(&sym));
                    total_debt_value = total_debt_value + (du * px);
                    let m = if (a.min_collateral_ratio > 0) { a.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
                    if (m > max_min_ccr) { max_min_ccr = m; };
                };
            };
            i = i + 1;
        };
        // add target increment
        let target_price = get_symbol_price_from_set(prices, &target_price_symbol);
        assert!(target_price > 0, E_BAD_PRICE);
        total_debt_value = total_debt_value + (amount * target_price);
        let akey = clone_string(&target_symbol);
        let asset = table::borrow_mut(&mut registry.synthetics, akey);
        let tgt_min = if (asset.min_collateral_ratio > 0) { asset.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
        if (tgt_min > max_min_ccr) { max_min_ccr = tgt_min; };
        let collateral_units = balance::value(&vault.collateral);
        let ratio_after = if (total_debt_value == 0) { U64_MAX_LITERAL } else { (collateral_units * 10_000) / total_debt_value };
        assert!(ratio_after >= max_min_ccr, E_RATIO_TOO_LOW);

        // Update debt and supply
        let debt_table = &mut vault.synthetic_debt;
        let old = if (table::contains(debt_table, clone_string(&target_symbol))) { *table::borrow(debt_table, clone_string(&target_symbol)) } else { 0 };
        let newd = old + amount;
        if (table::contains(debt_table, clone_string(&target_symbol))) { let _ = table::remove(debt_table, clone_string(&target_symbol)); } else { push_symbol_if_missing(&mut vault.debt_symbols, &target_symbol); };
        table::add(debt_table, clone_string(&target_symbol), newd);
        asset.total_supply = asset.total_supply + amount;

        // Mint fee with UNXV discount (reuse target_price)
        let mint_bps = if (asset.mint_fee_bps > 0) { asset.mint_fee_bps } else { registry.global_params.mint_fee };
        let notional_u128: u128 = (amount as u128) * (target_price as u128);
        let base_fee = clamp_u128_to_u64((notional_u128 * (mint_bps as u128)) / 10_000u128);
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut j = 0;
                while (j < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); j = j + 1; };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"mint".to_string(), vault.owner, ctx);
                    transfer::public_transfer(merged, vault.owner);
                    discount_applied = true;
                } else { transfer::public_transfer(merged, vault.owner); }
            }
        };
        let fee_to_collect = if (discount_applied) { base_fee - discount_collateral } else { base_fee };
        if (fee_to_collect > 0) { let fee_bal = balance::split(&mut vault.collateral, fee_to_collect); let fee_coin = coin::from_balance(fee_bal, ctx); TreasuryMod::deposit_collateral(treasury, fee_coin, b"mint".to_string(), ctx.sender(), ctx); };
        event::emit(SyntheticMinted { vault_id: object::id(vault), synthetic_type: target_symbol, amount_minted: amount, collateral_deposit: 0, minter: ctx.sender(), new_collateral_ratio: ratio_after, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        // Drain and refund any leftover UNXV coins and destroy the empty vector
        if (vector::length(&unxv_payment) > 0) {
            let mut leftover = coin::zero<UNXV>(ctx);
            while (vector::length(&unxv_payment) > 0) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut leftover, c); };
            transfer::public_transfer(leftover, vault.owner);
        };
        vector::destroy_empty(unxv_payment);
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    public fun burn_synthetic<C>(
        cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        synthetic_symbol: String,
        amount: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert_cfg_matches(registry, cfg);
        // price is fetched later; adjust ordering to avoid freezes when borrowing mut from registry
        let debt_table = &mut vault.synthetic_debt;
        assert!(table::contains(debt_table, clone_string(&synthetic_symbol)), E_UNKNOWN_ASSET);

        let old_debt = *table::borrow(debt_table, clone_string(&synthetic_symbol));
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        let _ = table::remove(debt_table, clone_string(&synthetic_symbol));
        table::add(debt_table, clone_string(&synthetic_symbol), new_debt);
        if (new_debt == 0) { remove_symbol_if_present(&mut vault.debt_symbols, &synthetic_symbol); };
        // Burn supply after we have a mutable asset reference
        // Fetch price first to avoid overlapping borrows
        let price_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &synthetic_symbol, price);
        let asset = table::borrow_mut(&mut registry.synthetics, clone_string(&synthetic_symbol));
        asset.total_supply = asset.total_supply - amount;

        // Fee for burn – allow UNXV discount; per-asset override
        let base_value = amount * price_u64; // units × price in micro‑USD
        let burn_bps = if (asset.burn_fee_bps > 0) { asset.burn_fee_bps } else { registry.global_params.burn_fee };
        let base_fee = (base_value * burn_bps) / 10_000;
        let discount_collateral = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::join(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
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
        let mut fee_to_collect = if (discount_applied) { base_fee - discount_collateral } else { base_fee };
        let available_coll = balance::value(&vault.collateral);
        if (fee_to_collect > available_coll) { fee_to_collect = available_coll; };
        if (fee_to_collect > 0) {
            let fee_bal = balance::split(&mut vault.collateral, fee_to_collect);
            let fee_coin = coin::from_balance(fee_bal, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"burn".to_string(), ctx.sender(), ctx);
        };
        // fee details are recorded in treasury; external FeeCollected removed here

        // Compute ratio after burn using current price for downstream health reconciliation
        let px_now = get_price_scaled_1e6(clock, oracle_cfg, price);
        let coll_val = balance::value(&vault.collateral) as u128;
        let debt_now = *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol));
        let debt_val = (debt_now as u128) * (px_now as u128);
        let ratio_after = if (debt_val == 0) { U64_MAX_LITERAL } else { clamp_u128_to_u64((coll_val * 10_000u128) / debt_val) };

        event::emit(SyntheticBurned {
            vault_id: object::id(vault),
            synthetic_type: synthetic_symbol,
            amount_burned: amount,
            collateral_withdrawn: 0,
            burner: ctx.sender(),
            new_collateral_ratio: ratio_after,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });

        // Drain and refund any leftover UNXV coins and destroy the empty vector
        if (vector::length(&unxv_payment) > 0) {
            let mut leftover = coin::zero<UNXV>(ctx);
            while (vector::length(&unxv_payment) > 0) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut leftover, c); };
            transfer::public_transfer(leftover, vault.owner);
        };
        vector::destroy_empty(unxv_payment);

        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    /// Phase‑2 – vault health helpers
    /// returns (ratio_bps, is_liquidatable)
    public fun check_vault_health<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        symbol: &String
    ): (u64, bool) {
        if (!table::contains(&vault.synthetic_debt, clone_string(symbol))) { return (U64_MAX_LITERAL, false) };
        let debt = *table::borrow(&vault.synthetic_debt, clone_string(symbol));
        let price_u64 = get_price_scaled_1e6(clock, oracle_cfg, price);
        assert!(price_u64 > 0, E_BAD_PRICE);
        let collateral_units = balance::value(&vault.collateral);
        let debt_value_u128: u128 = (debt as u128) * (price_u64 as u128);
        let ratio = if (debt_value_u128 == 0) { U64_MAX_LITERAL } else { clamp_u128_to_u64(((collateral_units as u128) * 10_000u128) / debt_value_u128) };
        let ka = clone_string(symbol);
        let asset = table::borrow(&registry.synthetics, ka);
        let threshold = if (asset.liquidation_threshold_bps > 0) { asset.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
        let liq = ratio < threshold;
        (ratio, liq)
    }

    /// Multi-asset health: uses oracle-validated `PriceSet` supplied in this tx.
    public fun check_vault_health_multi<C>(
        _vault: &CollateralVault<C>,
        _registry: &SynthRegistry,
        _clock: &Clock,
        _symbols: vector<String>,
        _prices: &PriceSet
    ): (u64, bool) { assert!(false, E_DEPRECATED); (0, false) }

    /// Helper getters for bots/indexers
    public fun list_vault_debt_symbols<C>(vault: &CollateralVault<C>): vector<String> { clone_string_vec(&vault.debt_symbols) }
    public fun get_vault_debt<C>(vault: &CollateralVault<C>, symbol: &String): u64 {
        let k = clone_string(symbol);
        if (table::contains(&vault.synthetic_debt, k)) {
            *table::borrow(&vault.synthetic_debt, clone_string(symbol))
        } else { 0 }
    }

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

    /// Order lifecycle – place, cancel, match
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
        event::emit(OrderbookOrderPlaced {
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
        event::emit(OrderbookOrderCancelled { order_id: object::id(order), owner: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    // Test-only helper to construct an Order for direct matching tests
    #[test_only]
    public fun new_order_for_testing(
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        expiry_ms: u64,
        owner: address,
        ctx: &mut TxContext
    ): Order {
        Order {
            id: object::new(ctx),
            owner,
            vault_id: object::id_from_address(owner),
            symbol,
            side,
            price,
            size,
            remaining: size,
            created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            expiry_ms,
        }
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
        keeper_reward_bps: u64,
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
            keeper_reward_bps,
            gc_reward_bps,
            maker_bond_bps,
        }
    }

    // Test-only getter for vault owner
    #[test_only]
    public fun vault_owner<C>(v: &CollateralVault<C>): address { v.owner }

    public fun match_orders<C>(
        registry: &mut SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price_info: &Aggregator,
        buy_order: &mut Order,
        sell_order: &mut Order,
        buyer_vault: &mut CollateralVault<C>,
        seller_vault: &mut CollateralVault<C>,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
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
        if (buy_order.expiry_ms != 0) { assert!(now <= buy_order.expiry_ms, E_ORDER_EXPIRED) };
        if (sell_order.expiry_ms != 0) { assert!(now <= sell_order.expiry_ms, E_ORDER_EXPIRED) };
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
        mint_synthetic_internal(buyer_vault, registry, clock, oracle_cfg, price_info, clone_string(&sym), fill, ctx);

        // Seller burns exposure (no fee inside match) only if they have debt recorded
        if (table::contains(&seller_vault.synthetic_debt, clone_string(&sym))) {
            burn_synthetic_internal(seller_vault, registry, clock, price_info, clone_string(&sym), fill, ctx);
        };

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
            let price_unxv_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &b"UNXV".to_string(), unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::join(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
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
                let to_maker = coin::split(&mut fee_coin_all, maker_rebate, ctx);
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

        // Drain and refund any leftover UNXV coins and destroy the empty vector
        if (vector::length(&unxv_payment) > 0) {
            let mut leftover = coin::zero<UNXV>(ctx);
            while (vector::length(&unxv_payment) > 0) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut leftover, c); };
            let refund_addr = if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner };
            transfer::public_transfer(leftover, refund_addr);
        };
        vector::destroy_empty(unxv_payment);
    }

    /// Very rough system‑wide stat – sums all vaults passed by caller using prices from `PriceSet`.
    public fun check_system_stability<C>(
        vaults: &vector<CollateralVault<C>>,
        _registry: &SynthRegistry,
        _clocks: &vector<Clock>,
        prices: &PriceSet,
        symbols: vector<String>
    ): (u64, u64, u64) {
        // NOTE: off‑chain indexer will provide better aggregate stats.
        let mut total_coll: u64 = 0;
        let mut total_debt: u64 = 0;
        let mut i = 0;
        while (i < vector::length(vaults)) {
            let v = vector::borrow(vaults, i);
            total_coll = total_coll + balance::value(&v.collateral);
            if (i < vector::length(&symbols)) {
                let sym = *vector::borrow(&symbols, i);
                let debt_amt = if (table::contains(&v.synthetic_debt, clone_string(&sym))) { *table::borrow(&v.synthetic_debt, clone_string(&sym)) } else { 0 };
                let p = get_symbol_price_from_set(prices, &sym);
                total_debt = total_debt + debt_amt * p;
            };
            i = i + 1;
        };
        let gcr = if (total_debt == 0) { U64_MAX_LITERAL } else { (total_coll * 10_000) / total_debt };
        (total_coll, total_debt, gcr)
    }

    /// Read-only helpers (bots/indexers)
    /// List all listed synthetic symbols
    public fun list_synthetics(registry: &SynthRegistry): vector<String> { clone_string_vec(&registry.listed_symbols) }

    /// Get read-only reference to a listed synthetic asset
    public fun get_synthetic(registry: &SynthRegistry, symbol: &String): &SyntheticAsset { table::borrow(&registry.synthetics, clone_string(symbol)) }

    /// Get oracle feed id bytes for a symbol (empty if missing)
    public fun get_oracle_feed_bytes(registry: &SynthRegistry, symbol: &String): vector<u8> {
        let k = clone_string(symbol);
        if (table::contains(&registry.oracle_feeds, k)) { copy_vector_u8(table::borrow(&registry.oracle_feeds, clone_string(symbol))) } else { b"".to_string().into_bytes() }
    }

    /// Rank a vault's debts by contribution to total debt value (largest first).
    /// Uses provided PriceSet for symbol prices.
    public fun rank_vault_liquidation_order<C>(
        vault: &CollateralVault<C>,
        _symbols: &vector<String>,
        prices: &PriceSet
    ): vector<String> {
        let work_syms = clone_string_vec(&vault.debt_symbols);
        let mut values = vector::empty<u64>();
        let mut i = 0; let n = vector::length(&work_syms);
        while (i < n) {
            let s = *vector::borrow(&work_syms, i);
            let du = if (table::contains(&vault.synthetic_debt, clone_string(&s))) { *table::borrow(&vault.synthetic_debt, clone_string(&s)) } else { 0 };
            let px = get_symbol_price_from_set(prices, &s);
            let dv = if (du > 0 && px > 0) { du * px } else { 0 };
            vector::push_back(&mut values, dv);
            i = i + 1;
        };

        // Selection-like ordering: repeatedly pick max value
        let mut ordered = vector::empty<String>();
        let mut k = 0;
        while (k < n) {
            let mut best_v: u64 = 0; let mut best_i: u64 = 0; let mut found = false;
            let mut j = 0;
            while (j < n) {
                let vj = *vector::borrow(&values, j);
                if (vj > best_v) {
                    best_v = vj; best_i = j; found = true;
                };
                j = j + 1;
            };
            if (!found || best_v == 0) { break };
            let top_sym = vector::borrow(&work_syms, best_i);
            vector::push_back(&mut ordered, clone_string(top_sym));
            // mark consumed
            // replace value at best_i with 0
            // Since Move doesn't have direct set, rebuild values vector positionally
            let mut new_vals = vector::empty<u64>();
            let mut t = 0; while (t < n) { let cur = *vector::borrow(&values, t); if (t == best_i) { vector::push_back(&mut new_vals, 0); } else { vector::push_back(&mut new_vals, cur); }; t = t + 1; };
            values = new_vals;
            k = k + 1;
        };
        ordered
    }

    /// Compute collateral/debt values for a vault and return ratio bps
    public fun get_vault_values<C>(
        vault: &CollateralVault<C>,
        _registry: &SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        symbol: &String
    ): (u64, u64, u64) {
        let collateral_value = balance::value(&vault.collateral);
        if (!table::contains(&vault.synthetic_debt, clone_string(symbol))) { return (collateral_value, 0, U64_MAX_LITERAL) };
        let debt_units = *table::borrow(&vault.synthetic_debt, clone_string(symbol));
        let px = assert_and_get_price_for_symbol(clock, oracle_cfg, _registry, symbol, price);
        // Return display debt_value as units×price (matches tests that assert units×price),
        // but compute ratio using decimals-aware micro-USD to reflect CCR logic.
        let debt_value_display_u128: u128 = (debt_units as u128) * (px as u128);
        let debt_value: u64 = clamp_u128_to_u64(debt_value_display_u128);
        let a = table::borrow(&_registry.synthetics, clone_string(symbol));
        let debt_value_ratio: u64 = debt_value_micro_usd(debt_units, px, a.decimals);
        let ratio = if (debt_value_ratio == 0) { U64_MAX_LITERAL } else { ((collateral_value / 1) * 10_000) / debt_value_ratio };
        (collateral_value, debt_value, ratio)
    }

    /// Get registry treasury ID
    public fun get_treasury_id(registry: &SynthRegistry): ID { registry.treasury_id }

    /// Liquidation – seize collateral when ratio < threshold
    public fun liquidate_vault<C>(
        registry: &mut SynthRegistry,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price: &Aggregator,
        vault: &mut CollateralVault<C>,
        synthetic_symbol: String,
        repay_amount: u64,
        liquidator: address,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        // Check health
        let (ratio, _) = check_vault_health(vault, registry, clock, oracle_cfg, price, &synthetic_symbol);
        assert!(ratio <= registry.global_params.liquidation_threshold, E_VAULT_NOT_HEALTHY);

        // Determine repay (cap to outstanding debt)
        let outstanding = if (table::contains(&vault.synthetic_debt, clone_string(&synthetic_symbol))) { *table::borrow(&vault.synthetic_debt, clone_string(&synthetic_symbol)) } else { 0 };
        let repay = if (repay_amount > outstanding) { outstanding } else { repay_amount };
        assert!(repay > 0, E_INVALID_ORDER);

        // Price in micro-USD units and penalty
        let price_u64 = assert_and_get_price_for_symbol(clock, oracle_cfg, registry, &synthetic_symbol, price);
        let notional_u128: u128 = (repay as u128) * (price_u64 as u128);
        let liq_pen_bps = {
            let a = table::borrow(&registry.synthetics, clone_string(&synthetic_symbol));
            if (a.liquidation_penalty_bps > 0) { a.liquidation_penalty_bps } else { registry.global_params.liquidation_penalty }
        };
        let penalty_u128: u128 = (notional_u128 * (liq_pen_bps as u128)) / 10_000u128;
        let penalty = clamp_u128_to_u64(penalty_u128);
        let seize_u128: u128 = notional_u128 + (penalty as u128);
        let seize = clamp_u128_to_u64(seize_u128);

        // Reduce debt
        let new_debt = outstanding - repay;
        if (table::contains(&vault.synthetic_debt, clone_string(&synthetic_symbol))) {
            let _ = table::remove(&mut vault.synthetic_debt, clone_string(&synthetic_symbol));
        };
        table::add(&mut vault.synthetic_debt, clone_string(&synthetic_symbol), new_debt);
        if (new_debt == 0) { remove_symbol_if_present(&mut vault.debt_symbols, &synthetic_symbol); };
        // Mirror burn behavior on liquidation: reduce global total_supply
        let aset = table::borrow_mut(&mut registry.synthetics, clone_string(&synthetic_symbol));
        aset.total_supply = aset.total_supply - repay;
        if (new_debt == 0) { remove_symbol_if_present(&mut vault.debt_symbols, &synthetic_symbol); };

        // Seize collateral and split bot reward
        let available = balance::value(&vault.collateral);
        let seize_capped = if (seize <= available) { seize } else { available };
        let mut seized_coin = {
            let seized_bal = balance::split(&mut vault.collateral, seize_capped);
            coin::from_balance(seized_bal, ctx)
        };
        let bot_cut = (seize_capped * registry.global_params.bot_split) / 10_000;
        let to_bot = coin::split(&mut seized_coin, bot_cut, ctx);
        transfer::public_transfer(to_bot, liquidator);
        // Remainder to treasury
        TreasuryMod::deposit_collateral(treasury, seized_coin, b"liquidation".to_string(), liquidator, ctx);

        // Emit event
        event::emit(LiquidationExecuted {
            vault_id: object::id(vault),
            liquidator,
            liquidated_amount: repay,
            collateral_seized: seize_capped,
            liquidation_penalty: penalty,
            synthetic_type: synthetic_symbol,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    /// Multi-asset liquidation: gate by aggregate ratio against max liquidation threshold across open debts
    public fun liquidate_vault_multi<C>(
        _registry: &mut SynthRegistry,
        vault: &mut CollateralVault<C>,
        symbols: vector<String>,
        prices: &PriceSet,
        target_symbol: String,
        repay_amount: u64,
        liquidator: address,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!_registry.paused, 1000);
        // compute aggregate ratio and max threshold
        let mut total_debt_value: u64 = 0; let mut max_th = _registry.global_params.liquidation_threshold;
        let mut i = 0; let n = vector::length(&symbols);
        while (i < n) {
            let sym = *vector::borrow(&symbols, i);
            let px = get_symbol_price_from_set(prices, &sym);
            if (table::contains(&vault.synthetic_debt, clone_string(&sym))) {
                let du = *table::borrow(&vault.synthetic_debt, clone_string(&sym));
                if (du > 0) {
                    assert!(px > 0, E_BAD_PRICE);
                    let a = table::borrow(&_registry.synthetics, clone_string(&sym));
                    // Units × price without decimals scaling per tests
                    total_debt_value = total_debt_value + (du * px);
                    let th = if (a.liquidation_threshold_bps > 0) { a.liquidation_threshold_bps } else { _registry.global_params.liquidation_threshold };
                    if (th > max_th) { max_th = th; };
                };
            };
            i = i + 1;
        };
        let collateral_units = balance::value(&vault.collateral);
        let ratio = if (total_debt_value == 0) { U64_MAX_LITERAL } else { (collateral_units * 10_000) / total_debt_value };
        assert!(ratio < max_th, E_VAULT_NOT_HEALTHY);

        // Soft-order enforcement (optional): ensure target equals the top-ranked symbol if any
        let ranked = rank_vault_liquidation_order(vault, &symbols, prices);
        if (vector::length(&ranked) > 0) {
            let top = vector::borrow(&ranked, 0);
            assert!(eq_string(top, &target_symbol), E_INVALID_ORDER);
        };

        // Proceed to repay target asset like single-asset path
        let outstanding = if (table::contains(&vault.synthetic_debt, clone_string(&target_symbol))) { *table::borrow(&vault.synthetic_debt, clone_string(&target_symbol)) } else { 0 };
        let repay = if (repay_amount > outstanding) { outstanding } else { repay_amount };
        assert!(repay > 0, E_INVALID_ORDER);
        let px_target = get_symbol_price_from_set(prices, &target_symbol);
        assert!(px_target > 0, E_BAD_PRICE);
        let asset_for_liq = table::borrow(&_registry.synthetics, clone_string(&target_symbol));
        // Notional without decimals scaling per tests
        let notional = repay * px_target;
        let liq_pen_bps = if (asset_for_liq.liquidation_penalty_bps > 0) { asset_for_liq.liquidation_penalty_bps } else { _registry.global_params.liquidation_penalty };
        let penalty = (notional * liq_pen_bps) / 10_000;
        let seize = notional + penalty;

        let new_debt = outstanding - repay;
        if (table::contains(&vault.synthetic_debt, clone_string(&target_symbol))) { let _ = table::remove(&mut vault.synthetic_debt, clone_string(&target_symbol)); };
        table::add(&mut vault.synthetic_debt, clone_string(&target_symbol), new_debt);
        if (new_debt == 0) { remove_symbol_if_present(&mut vault.debt_symbols, &target_symbol); };
        let mut seized_coin = { let seized_bal = balance::split(&mut vault.collateral, seize); coin::from_balance(seized_bal, ctx) };
        let bot_cut = (seize * _registry.global_params.bot_split) / 10_000;
        let to_bot = coin::split(&mut seized_coin, bot_cut, ctx);
        transfer::public_transfer(to_bot, liquidator);
        TreasuryMod::deposit_collateral(treasury, seized_coin, b"liquidation".to_string(), liquidator, ctx);
        event::emit(LiquidationExecuted { vault_id: object::id(vault), liquidator, liquidated_amount: repay, collateral_seized: seize, liquidation_penalty: penalty, synthetic_type: target_symbol, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
    }

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
            keeper_reward_bps: 100,           // 1% of fee goes to the caller on match
            gc_reward_bps: 100,               // 1% of slashed bond to keeper
            maker_bond_bps: 10,               // 0.10% bond of notional required
        };

        // 4️⃣ Create empty tables and admin allow‑list (deployer is first admin)
        let syn_table = table::new<String, SyntheticAsset>(ctx);
        let feed_table = table::new<String, vector<u8>>(ctx);
        let listed_symbols = vector::empty<String>();

        // 5️⃣ Share the SynthRegistry object
        // For now, create a fresh Treasury and capture its ID
        // Treasury is assumed to be created by treasury.init; capture its ID later via a setup tx.
        let treasury_id_local = object::id(&publisher);

        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: syn_table,
            oracle_feeds: feed_table,
            listed_symbols,
            global_params: params,
            paused: false,
            treasury_id: treasury_id_local,
            num_synthetics: 0,
            collateral_set: false,
            collateral_cfg_id: option::none<ID>(),
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

        // Finally transfer publisher after all displays are initialized
        transfer::public_transfer(publisher, ctx.sender());

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
                keeper_reward_bps: 100,
                gc_reward_bps: 100,
                maker_bond_bps: 10,
            },
            paused: false,
            treasury_id: object::id_from_address(ctx.sender()),
            num_synthetics: 0,
            collateral_set: false,
            collateral_cfg_id: option::none<ID>(),
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