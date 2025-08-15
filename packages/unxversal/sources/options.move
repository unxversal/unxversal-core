/// Unxversal Options – Phase 1 (Registry & Market Listing)
/// - Admin‑whitelisted underlyings (native coins or synthetics)
/// - Permissionless option market creation on whitelisted underlyings
/// - Oracle feeds normalized to micro‑USD via core Oracle module
/// - Integrates directly with on-chain orderbook in `dex.move` for execution paths
/// - Displays and read‑only helpers for indexers/bots

module unxversal::options {

    // TxContext alias provided by default
    use sui::display;
    use sui::package;
    use sui::package::Publisher;
    use sui::types;
    use sui::event;
    use std::string::{Self as string, String};
    use sui::table::{Self as table, Table};
    // timestamp helpers via Clock type import below
    use sui::clock::Clock;
    use switchboard::aggregator::Aggregator;
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;
    use sui::coin::{Self as coin, Coin};
    use unxversal::synthetics::{Self as Synth, SynthRegistry, AdminCap, DaddyCap};

    /*******************************
    * Errors
    *******************************/
    const E_NOT_ADMIN: u64 = 1;
    const E_UNDERLYING_EXISTS: u64 = 2;
    const E_UNDERLYING_UNKNOWN: u64 = 3;
    const E_UNDERLYING_INACTIVE: u64 = 4;
    const E_BAD_PARAMS: u64 = 5;
    const E_PAUSED: u64 = 6;
    const E_SIDE: u64 = 7;
    const E_AMOUNT: u64 = 8;
    const E_PRICE: u64 = 9;
    const E_MISMATCH: u64 = 10;
    const E_EXPIRED: u64 = 11;
    const E_COLLATERAL: u64 = 12;

    /*******************************
    * One‑Time Witness & Caps
    *******************************/
    public struct OPTIONS has drop {}

    /*******************************
    * Underlying & Registry
    *******************************/
    public struct UnderlyingAsset has store {
        asset_name: String,
        asset_type: String,          // "NATIVE", "SYNTHETIC", "WRAPPED"
        oracle_feed: vector<u8>,     // Pyth feed bytes (normalized by Oracle module)
        default_settlement_type: String, // "CASH" | "PHYSICAL" | "BOTH"
        min_strike_price: u64,
        max_strike_price: u64,
        strike_increment: u64,
        min_expiry_duration_ms: u64,
        max_expiry_duration_ms: u64,
        is_active: bool,
    }

    public struct OptionsRegistry has key, store {
        id: UID,
        supported_underlyings: Table<String, UnderlyingAsset>,
        option_markets: Table<vector<u8>, ID>,   // composite key bytes -> market id
        /// Listing helpers for bots/indexers
        underlying_symbols: vector<String>,
        market_key_list: vector<vector<u8>>,
        paused: bool,
        treasury_id: ID,
        trade_fee_bps: u64,           // premium trade fee bps (applies on opens/closes later phases)
        unxv_discount_bps: u64,       // UNXV discount bps on fees
        settlement_fee_bps: u64,      // fee on settlement payout
        liq_penalty_bps: u64,         // liquidation bonus to liquidator from short collateral
        liq_bot_reward_bps: u64,      // portion of liquidation fee to bots
        close_bot_reward_bps: u64,    // portion of close taker fee to bots
        settlement_bot_reward_bps: u64, // portion of settlement fee to bots
        maker_rebate_bps_close: u64,  // maker rebate bps on closes
        owner_positions: Table<address, vector<ID>>, // optional on-chain enumeration
        market_positions: Table<ID, vector<ID>>,     // optional on-chain enumeration
        // Global defaults for new markets (admin-configurable)
        default_exercise_style: String,   // "EUROPEAN" or "AMERICAN"
        default_contract_size: u64,
        default_tick_size: u64,
        default_init_margin_bps_short: u64,
        default_maint_margin_bps_short: u64,
        default_max_oi_per_user: u64,
        default_max_open_contracts_market: u64,
    }

    /*******************************
    * Market & Position (Phase‑1: market only)
    *******************************/
    public struct OptionMarket has key, store {
        id: UID,
        underlying: String,
        option_type: String,    // "CALL" | "PUT"
        strike_price: u64,      // micro‑USD per unit
        expiry_ms: u64,
        settlement_type: String,// default or overridden per market
        paused: bool,
        is_active: bool,
        is_expired: bool,
        exercise_style: String, // "EUROPEAN" | "AMERICAN"
        contract_size: u64,     // units per contract
        tick_size: u64,         // min premium increment
        trade_fee_bps_override: u64,       // 0 => use registry
        settlement_fee_bps_override: u64,  // 0 => use registry
        init_margin_bps_short: u64,
        maint_margin_bps_short: u64,
        max_oi_per_user: u64,
        max_open_contracts_market: u64,
        creator: address,
        created_at_ms: u64,
        settlement_price: u64,  // micro-USD, 0 until settled
        settled_at_ms: u64,
        total_open_interest: u64,
        total_volume_premium: u64,
        last_trade_premium: u64,
        user_open_interest: Table<address, u64>,
    }

    /*******************************
    * Events
    *******************************/
    public struct UnderlyingAdded has copy, drop { symbol: String, by: address, timestamp: u64 }
    public struct UnderlyingRemoved has copy, drop { symbol: String, by: address, timestamp: u64 }
    public struct OptionMarketCreated has copy, drop {
        market_id: ID,
        market_key_bytes: vector<u8>,
        underlying: String,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        settlement_type: String,
        creator: address,
        timestamp: u64,
    }
    public struct OptionMarketSettled has copy, drop {
        market_id: ID,
        underlying: String,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        settlement_price: u64,
        timestamp: u64,
    }
    public struct OptionClosed has copy, drop {
        market_id: ID,
        closer: address,
        counterparty: address,
        quantity: u64,
        premium_per_unit: u64,
        fee_paid: u64,
        timestamp: u64,
    }
    public struct OptionOpened has copy, drop {
        market_id: ID,
        buyer: address,
        writer: address,
        quantity: u64,
        premium_per_unit: u64,
        timestamp: u64,
    }
    public struct MarginCallTriggered has copy, drop {
        short_owner: address,
        market_id: ID,
        required_collateral: u64,
        current_collateral: u64,
        timestamp: u64,
    }
    public struct ShortLiquidated has copy, drop {
        market_id: ID,
        short_owner: address,
        liquidator: address,
        quantity: u64,
        collateral_seized: u64,
        penalty_paid: u64,
        timestamp: u64,
    }
    public struct EarlyExercised has copy, drop {
        market_id: ID,
        long_owner: address,
        short_owner: address,
        quantity: u64,
        payout_to_long: u64,
        fee_paid: u64,
        timestamp: u64,
    }

    /*******************************
    * Settlement queue for batch processing with dispute window
    *******************************/
    public struct SettlementQueue has key, store {
        id: UID,
        dispute_window_ms: u64,
        pending: vector<ID>,
        requested_at_ms: Table<ID, u64>,
    }

    // Escrow and Offers for OTC matching (shared objects)
    public struct ShortOffer<phantom C> has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        remaining_qty: u64,
        min_premium_per_unit: u64, // collateral units per 1 qty
        collateral_locked: Coin<C>,
        created_at_ms: u64,
    }

    public struct PremiumEscrow<phantom C> has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        remaining_qty: u64,
        premium_per_unit: u64, // collateral per 1 qty
        escrow_collateral: Coin<C>,
        created_at_ms: u64,
        expiry_cancel_ms: u64,
    }

    /// Short underlying escrow for coin-physical CALLs (typed by Base)
    public struct ShortUnderlyingEscrow<phantom Base> has key, store {
        id: UID,
        position_id: ID,
        escrow_base: Coin<Base>,
    }

    /// Long underlying escrow for coin-physical PUTs (typed by Base)
    public struct LongUnderlyingEscrow<phantom Base> has key, store {
        id: UID,
        owner: address,
        position_id: ID,
        escrow_base: Coin<Base>,
    }

    /// Coin-collateralized short offer (typed by Base)
    public struct CoinShortOffer<phantom Base> has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        remaining_qty: u64,
        min_premium_per_unit: u64,
        escrow_base: Coin<Base>,
        created_at_ms: u64,
    }

    // Shared Position object so bots can settle post-expiry
    // side: 0 = LONG, 1 = SHORT
    public struct OptionPosition<phantom C> has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        side: u8,
        quantity: u64,
        premium_per_unit: u64, // only meaningful for long; 0 for short
        opened_at_ms: u64,
        // For short only: locked collateral held here
        collateral_locked: Coin<C>,
    }

    public struct OptionMatched has copy, drop {
        market_id: ID,
        buyer: address,
        writer: address,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        quantity: u64,
        premium_per_unit: u64,
        fee_paid: u64,
        unxv_discount_applied: bool,
        timestamp: u64,
    }
    public struct OptionSettled has copy, drop {
        market_id: ID,
        long_owner: address,
        short_owner: address,
        option_type: String,
        strike_price: u64,
        expiry_ms: u64,
        quantity: u64,
        settlement_price: u64,
        payout_to_long: u64,
        fee_paid: u64,
        timestamp: u64,
    }
    public struct PhysicalDeliveryRequested has copy, drop { market_id: ID, requester: address, side: u8, quantity: u64, min_settlement_price: u64, timestamp: u64 }
    public struct PhysicalDeliveryCompleted has copy, drop { market_id: ID, fulfiller: address, side: u8, quantity: u64, avg_settlement_price: u64, timestamp: u64 }
    public struct PausedToggled has copy, drop { new_state: bool, by: address, timestamp: u64 }

    /*******************************
    * Admin helper
    *******************************/
    fun assert_is_admin_via_synth(synth_reg: &SynthRegistry, addr: address) { assert!(Synth::is_admin(synth_reg, addr), E_NOT_ADMIN); }

    fun clone_string(s: &String): String {
        let bytes = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(bytes);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(bytes, i)); i = i + 1; };
        string::utf8(out)
    }

    fun clone_bytes(src: &vector<u8>): vector<u8> {
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(src, i)); i = i + 1; };
        out
    }

    /*******************************
    * INIT – executed once on package publish
    *******************************/
    fun init(otw: OPTIONS, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let reg = OptionsRegistry {
            id: object::new(ctx),
            supported_underlyings: table::new<String, UnderlyingAsset>(ctx),
            option_markets: table::new<vector<u8>, ID>(ctx),
            underlying_symbols: vector::empty<String>(),
            market_key_list: vector::empty<vector<u8>>(),
            paused: false,
            treasury_id: object::id(&publisher),
            trade_fee_bps: 30,
            unxv_discount_bps: 2000,
            settlement_fee_bps: 10,
            liq_penalty_bps: 500,
            liq_bot_reward_bps: 1000,
            close_bot_reward_bps: 0,
            settlement_bot_reward_bps: 0,
            maker_rebate_bps_close: 100, // 1% default maker rebate on close
            owner_positions: table::new<address, vector<ID>>(ctx),
            market_positions: table::new<ID, vector<ID>>(ctx),
            default_exercise_style: b"EUROPEAN".to_string(),
            default_contract_size: 1,
            default_tick_size: 1,
            default_init_margin_bps_short: 10_000,
            default_maint_margin_bps_short: 8_000,
            default_max_oi_per_user: 0,
            default_max_open_contracts_market: 0,
        };
        transfer::share_object(reg);

        // Displays
        let mut disp_reg = display::new<OptionsRegistry>(&publisher, ctx);
        disp_reg.add(b"name".to_string(),        b"Unxversal Options Registry".to_string());
        disp_reg.add(b"description".to_string(), b"Admin‑whitelisted underlyings and permissionless options markets".to_string());
        disp_reg.update_version();
        transfer::public_transfer(disp_reg, ctx.sender());
        transfer::public_transfer(publisher, ctx.sender());
    }

    /*******************************
    * Admin – Underlyings & pause
    *******************************/
    public fun add_underlying(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut OptionsRegistry,
        symbol: String,
        asset_name: String,
        asset_type: String,
        oracle_feed: vector<u8>,
        default_settlement_type: String,
        min_strike_price: u64,
        max_strike_price: u64,
        strike_increment: u64,
        min_expiry_duration_ms: u64,
        max_expiry_duration_ms: u64,
        is_active: bool,
        ctx: &TxContext
    ) {
        assert_is_admin_via_synth(synth_reg, ctx.sender());
        assert!(!reg.paused, E_PAUSED);
        assert!(!table::contains(&reg.supported_underlyings, clone_string(&symbol)), E_UNDERLYING_EXISTS);
        let asset = UnderlyingAsset { asset_name, asset_type, oracle_feed, default_settlement_type, min_strike_price, max_strike_price, strike_increment, min_expiry_duration_ms, max_expiry_duration_ms, is_active };
        table::add(&mut reg.supported_underlyings, clone_string(&symbol), asset);
        // push to listing set
        vector::push_back(&mut reg.underlying_symbols, clone_string(&symbol));
        event::emit(UnderlyingAdded { symbol, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun remove_underlying(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut OptionsRegistry,
        symbol: String,
        ctx: &TxContext
    ) {
        assert_is_admin_via_synth(synth_reg, ctx.sender());
        assert!(!reg.paused, E_PAUSED);
        assert!(table::contains(&reg.supported_underlyings, clone_string(&symbol)), E_UNDERLYING_UNKNOWN);
        let ua = table::borrow_mut(&mut reg.supported_underlyings, clone_string(&symbol));
        ua.is_active = false;
        event::emit(UnderlyingRemoved { symbol, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun pause(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.paused = true; event::emit(PausedToggled { new_state: true, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }
    public fun resume(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.paused = false; event::emit(PausedToggled { new_state: false, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    public fun set_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }
    public fun set_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, trade_fee_bps: u64, unxv_discount_bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.trade_fee_bps = trade_fee_bps; reg.unxv_discount_bps = unxv_discount_bps; }
    public fun set_settlement_fee_bps(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.settlement_fee_bps = bps; }
    public fun set_liq_penalty_bps(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.liq_penalty_bps = bps; }
    public fun set_bot_reward_bps(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, liq_bot_bps: u64, close_bot_bps: u64, settle_bot_bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.liq_bot_reward_bps = liq_bot_bps; reg.close_bot_reward_bps = close_bot_bps; reg.settlement_bot_reward_bps = settle_bot_bps; }
    public fun set_maker_rebate_bps_close(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.maker_rebate_bps_close = bps; }
    public fun set_default_market_params(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut OptionsRegistry,
        exercise_style: String,
        contract_size: u64,
        tick_size: u64,
        init_margin_bps_short: u64,
        maint_margin_bps_short: u64,
        max_oi_per_user: u64,
        max_open_contracts_market: u64,
        ctx: &TxContext
    ) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.default_exercise_style = exercise_style; reg.default_contract_size = contract_size; reg.default_tick_size = tick_size; reg.default_init_margin_bps_short = init_margin_bps_short; reg.default_maint_margin_bps_short = maint_margin_bps_short; reg.default_max_oi_per_user = max_oi_per_user; reg.default_max_open_contracts_market = max_open_contracts_market; }

    public fun set_market_params(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        market: &mut OptionMarket,
        exercise_style: String,
        contract_size: u64,
        tick_size: u64,
        init_margin_bps_short: u64,
        maint_margin_bps_short: u64,
        ctx: &TxContext
    ) {
        assert_is_admin_via_synth(synth_reg, ctx.sender());
        market.exercise_style = exercise_style;
        market.contract_size = contract_size;
        market.tick_size = tick_size;
        market.init_margin_bps_short = init_margin_bps_short;
        market.maint_margin_bps_short = maint_margin_bps_short;
    }

    public fun set_market_fee_overrides(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        market: &mut OptionMarket,
        trade_fee_bps_override: u64,
        settlement_fee_bps_override: u64,
        ctx: &TxContext
    ) {
        assert_is_admin_via_synth(synth_reg, ctx.sender());
        market.trade_fee_bps_override = trade_fee_bps_override;
        market.settlement_fee_bps_override = settlement_fee_bps_override;
    }

    public fun grant_admin_via_synth(daddy: &DaddyCap, synth_reg: &mut SynthRegistry, new_admin: address, ctx: &mut TxContext) { Synth::grant_admin(daddy, synth_reg, new_admin, ctx); }
    public fun revoke_admin_via_synth(daddy: &DaddyCap, synth_reg: &mut SynthRegistry, bad_admin: address, ctx: &TxContext) { Synth::revoke_admin(daddy, synth_reg, bad_admin, ctx); }

    /*******************************
    * Permissionless Market Creation (on whitelisted underlyings)
    *******************************/
    public fun create_option_market<C>(
        reg: &mut OptionsRegistry,
        underlying: String,
        option_type: String,     // "CALL" | "PUT"
        strike_price: u64,       // micro‑USD
        expiry_ms: u64,
        settlement_type: String, // "CASH" | "PHYSICAL" | "BOTH"
        treasury: &mut Treasury<C>,
        mut unxv_payment: vector<Coin<UNXV>>,
        creation_fee: u64,
        mut creation_fee_coin: Coin<C>,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!reg.paused, E_PAUSED);
        // Validate underlying
        assert!(table::contains(&reg.supported_underlyings, clone_string(&underlying)), E_UNDERLYING_UNKNOWN);
        let u = table::borrow(&reg.supported_underlyings, clone_string(&underlying));
        assert!(u.is_active, E_UNDERLYING_INACTIVE);
        assert!(strike_price >= u.min_strike_price && strike_price <= u.max_strike_price, E_BAD_PARAMS);
        assert!(expiry_ms >= u.min_expiry_duration_ms && expiry_ms <= u.max_expiry_duration_ms, E_BAD_PARAMS);
        // Both CALL and PUT markets can be CASH, PHYSICAL or BOTH

        let key_bytes = market_key_bytes(&underlying, &option_type, strike_price, expiry_ms);
        assert!(!table::contains(&reg.option_markets, clone_bytes(&key_bytes)), E_BAD_PARAMS);

        let market = OptionMarket {
            id: object::new(ctx),
            underlying: clone_string(&underlying),
            option_type: clone_string(&option_type),
            strike_price,
            expiry_ms,
            settlement_type,
            paused: false,
            is_active: true,
            is_expired: false,
            exercise_style: clone_string(&reg.default_exercise_style),
            contract_size: reg.default_contract_size,
            tick_size: reg.default_tick_size,
            trade_fee_bps_override: 0,
            settlement_fee_bps_override: 0,
            init_margin_bps_short: reg.default_init_margin_bps_short,
            maint_margin_bps_short: reg.default_maint_margin_bps_short,
            max_oi_per_user: reg.default_max_oi_per_user,
            max_open_contracts_market: reg.default_max_open_contracts_market,
            creator: ctx.sender(),
            created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            settlement_price: 0,
            settled_at_ms: 0,
            total_open_interest: 0,
            total_volume_premium: 0,
            last_trade_premium: 0,
            user_open_interest: table::new<address, u64>(ctx),
        };
        let mid = object::id(&market);
        transfer::share_object(market);
        table::add(&mut reg.option_markets, clone_bytes(&key_bytes), mid);
        // track market key for listing
        vector::push_back(&mut reg.market_key_list, clone_bytes(&key_bytes));

        // Optional creation fee collection with UNXV discount at source
        if (creation_fee > 0) {
            // Apply UNXV discount
            let discount_collateral = (creation_fee * reg.unxv_discount_bps) / 10_000;
            let mut discount_applied = false;
            if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
                // Require caller to pass an oracle‑priced UNXV cost off‑chain or integrate here later
                // For now, accept UNXV as is and deposit; creation fee reduced accordingly
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                if (coin::value(&merged) > 0) {
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, merged);
                    TreasuryMod::deposit_unxv_ext(treasury, vecu, b"options_market_create".to_string(), ctx.sender(), ctx);
                    discount_applied = true;
                } else { coin::destroy_zero(merged); };
            };
            let fee_due = if (discount_applied && creation_fee > discount_collateral) { creation_fee - discount_collateral } else { creation_fee };
            if (fee_due > 0) {
                let pay = coin::split(&mut creation_fee_coin, fee_due, ctx);
                TreasuryMod::deposit_collateral_ext(treasury, pay, b"options_market_create".to_string(), ctx.sender(), ctx);
            };
            // drain any leftover UNXV back to sender and consume vector
            let mut j = 0; while (j < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); transfer::public_transfer(c, ctx.sender()); j = j + 1; };
            vector::destroy_empty(unxv_payment);
        } else {
            // drain and consume UNXV vector if provided
            let mut j = 0; while (j < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); transfer::public_transfer(c, ctx.sender()); j = j + 1; };
            vector::destroy_empty(unxv_payment);
        };

        event::emit(OptionMarketCreated { market_id: mid, market_key_bytes: key_bytes, underlying, option_type, strike_price, expiry_ms, settlement_type, creator: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        // Return leftover creation fee coin to caller for composability
        creation_fee_coin
    }

    public fun init_settlement_queue(dispute_window_ms: u64, ctx: &mut TxContext) {
        let q = SettlementQueue { id: object::new(ctx), dispute_window_ms, pending: vector::empty<ID>(), requested_at_ms: table::new<ID, u64>(ctx) };
        transfer::share_object(q);
    }

    public fun request_market_settlement(queue: &mut SettlementQueue, market: &OptionMarket, ctx: &mut TxContext) {
        vector::push_back(&mut queue.pending, object::id(market));
        table::add(&mut queue.requested_at_ms, object::id(market), sui::tx_context::epoch_timestamp_ms(ctx));
    }

    public fun process_due_settlement(queue: &mut SettlementQueue, reg: &OptionsRegistry, market: &mut OptionMarket, oracle_cfg: &OracleConfig, clock: &Clock, price: &Aggregator, ctx: &mut TxContext) {
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let mid = object::id(market);
        if (table::contains(&queue.requested_at_ms, mid)) {
            let t = *table::borrow(&queue.requested_at_ms, mid);
            if (now >= t + queue.dispute_window_ms) {
                expire_and_settle_market_cash(reg, market, oracle_cfg, clock, price, ctx);
                let _ = table::remove(&mut queue.requested_at_ms, mid);
                // rebuild pending without mid
                let mut new_pending = vector::empty<ID>();
                let mut j = 0;
                while (j < vector::length(&queue.pending)) {
                    let idj = *vector::borrow(&queue.pending, j);
                    if (!(idj == mid)) { vector::push_back(&mut new_pending, idj); };
                    j = j + 1;
                };
                queue.pending = new_pending;
            };
        };
    }

    /*******************************
    * Early/manual exercise (American)
    *******************************/
    public fun exercise_american_now<C>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        quantity: u64,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &Aggregator,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && (market.exercise_style == b"AMERICAN".to_string()), E_PAUSED);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        // Oracle price (symbol existence checked at market creation)
        let spot = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        let mut payout = 0u64;
        if (long_pos.option_type == b"CALL".to_string()) {
            if (spot > market.strike_price) { payout = (spot - market.strike_price) * quantity; }
        } else {
            if (market.strike_price > spot) { payout = (market.strike_price - spot) * quantity; }
        };
        let fee_bps = if (market.settlement_fee_bps_override > 0) { market.settlement_fee_bps_override } else { reg.settlement_fee_bps };
        let fee = (payout * fee_bps) / 10_000;
        let net_to_long = if (payout > fee) { payout - fee } else { 0 };
        let mut to_long = coin::zero<C>(ctx);
        if (net_to_long > 0) { let p = coin::split(&mut short_pos.collateral_locked, net_to_long, ctx); coin::join(&mut to_long, p); };
        transfer::public_transfer(to_long, long_pos.owner);
        if (fee > 0) {
            let fee_coin = coin::split(&mut short_pos.collateral_locked, fee, ctx);
            TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"options_exercise".to_string(), ctx.sender(), ctx);
        };
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; };
        // Decrement user OI for long owner
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let old = table::remove(&mut market.user_open_interest, long_pos.owner);
            let newv = if (old > quantity) { old - quantity } else { 0 };
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };
        event::emit(EarlyExercised { market_id: object::id(market), long_owner: long_pos.owner, short_owner: short_pos.owner, quantity, payout_to_long: net_to_long, fee_paid: fee, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Pre‑expiry close/offset with fee; refunds short margin proportionally
    *******************************/
    public fun close_positions_by_premium<C>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        quantity: u64,
        premium_per_unit: u64,
        payer_is_long: bool,
        mut usdc: Coin<C>,
        mut unxv_payment: vector<Coin<UNXV>>,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        unxv_price: &Aggregator,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        assert!(premium_per_unit % market.tick_size == 0 && quantity % market.contract_size == 0, E_BAD_PARAMS);
        let premium_total = quantity * premium_per_unit;
        let trade_fee_bps = if (market.trade_fee_bps_override > 0) { market.trade_fee_bps_override } else { reg.trade_fee_bps };
        let taker_fee = (premium_total * trade_fee_bps) / 10_000;
        let maker_rebate = (taker_fee * reg.maker_rebate_bps_close) / 10_000;
        // Optional UNXV discount on taker fee
        let discount_collateral = (taker_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_collateral + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                let have = coin::value(&merged);
                let payer_addr = if (payer_is_long) { long_pos.owner } else { short_pos.owner };
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv_ext(treasury, vecu, b"options_close".to_string(), payer_addr, ctx);
                    transfer::public_transfer(merged, payer_addr);
                    discount_applied = true;
                } else { transfer::public_transfer(merged, payer_addr); }
            } else { let mut k = 0; while (k < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); transfer::public_transfer(c, payer_addr); k = k + 1; }; }
        };
        vector::destroy_empty(unxv_payment);
        let fee_to_collect = if (discount_applied) { if (taker_fee > discount_collateral) { taker_fee - discount_collateral } else { 0 } } else { taker_fee };
        let net_amount = if (premium_total > fee_to_collect) { premium_total - fee_to_collect } else { 0 };
        if (payer_is_long) {
            // Long pays short to close; transfer net to short and fee to treasury
            if (net_amount > 0) {
                let to_short = coin::split(&mut usdc, net_amount, ctx);
                transfer::public_transfer(to_short, short_pos.owner);
            };
            if (fee_to_collect > 0) {
                let mut fee_all = coin::split(&mut usdc, fee_to_collect, ctx);
                if (maker_rebate > 0 && maker_rebate < fee_to_collect) {
                    let to_maker = coin::split(&mut fee_all, maker_rebate, ctx);
                    transfer::public_transfer(to_maker, short_pos.owner);
                };
                let bot_cut = (coin::value(&fee_all) * reg.close_bot_reward_bps) / 10_000;
                if (bot_cut > 0) {
                    let to_bots = coin::split(&mut fee_all, bot_cut, ctx);
                    TreasuryMod::deposit_collateral_ext(treasury, to_bots, b"options_close_bot".to_string(), long_pos.owner, ctx);
                };
                TreasuryMod::deposit_collateral_ext(treasury, fee_all, b"options_close".to_string(), long_pos.owner, ctx);
            };
        } else {
            // Short pays long to close (buy-back)
            if (net_amount > 0) {
                let to_long = coin::split(&mut usdc, net_amount, ctx);
                transfer::public_transfer(to_long, long_pos.owner);
            };
            if (fee_to_collect > 0) {
                let mut fee_all = coin::split(&mut usdc, fee_to_collect, ctx);
                if (maker_rebate > 0 && maker_rebate < fee_to_collect) {
                    let to_maker = coin::split(&mut fee_all, maker_rebate, ctx);
                    transfer::public_transfer(to_maker, long_pos.owner);
                };
                let bot_cut = (coin::value(&fee_all) * reg.close_bot_reward_bps) / 10_000;
                if (bot_cut > 0) {
                    let to_bots = coin::split(&mut fee_all, bot_cut, ctx);
                    TreasuryMod::deposit_collateral_ext(treasury, to_bots, b"options_close_bot".to_string(), short_pos.owner, ctx);
                };
                TreasuryMod::deposit_collateral_ext(treasury, fee_all, b"options_close".to_string(), short_pos.owner, ctx);
            };
        };
        // Refund proportional initial margin to short for closed quantity
        let notional = quantity * market.strike_price;
        let refund = (notional * market.init_margin_bps_short) / 10_000;
        if (refund > 0) { let c = coin::split(&mut short_pos.collateral_locked, refund, ctx); transfer::public_transfer(c, short_pos.owner); };
        // Update positions and market OI
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; };
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let cur = *table::borrow(&market.user_open_interest, long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            let _ = table::remove(&mut market.user_open_interest, long_pos.owner);
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };
        // Emit and return any remainder of usdc source
        event::emit(OptionClosed { market_id: object::id(market), closer: if (payer_is_long) { long_pos.owner } else { short_pos.owner }, counterparty: if (payer_is_long) { short_pos.owner } else { long_pos.owner }, quantity, premium_per_unit, fee_paid: fee_to_collect, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        usdc
    }

    /*******************************
    * Liquidation: close pair at live price with penalty to liquidator
    *******************************/
    public fun liquidate_under_collateralized_pair<C: store>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        quantity: u64,
        liquidator: address,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &Aggregator,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        // Underlying exists check done implicitly at market creation; keep logic local
        let spot = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        // Maintenance health
        let notional = quantity * market.strike_price;
        let maint_needed = (notional * market.maint_margin_bps_short) / 10_000;
        let cur_coll = coin::value(&short_pos.collateral_locked);
        assert!(cur_coll < maint_needed, E_BAD_PARAMS);
        // Close at intrinsic
        let mut payout = 0u64;
        if (long_pos.option_type == b"CALL".to_string()) {
            if (spot > market.strike_price) { payout = (spot - market.strike_price) * quantity; }
        } else { if (market.strike_price > spot) { payout = (market.strike_price - spot) * quantity; } };
        let fee_bps = if (market.settlement_fee_bps_override > 0) { market.settlement_fee_bps_override } else { reg.settlement_fee_bps };
        let fee = (payout * fee_bps) / 10_000;
        let net_to_long = if (payout > fee) { payout - fee } else { 0 };
        let mut to_long = coin::zero<C>(ctx);
        if (net_to_long > 0) { let p = coin::split(&mut short_pos.collateral_locked, net_to_long, ctx); coin::join(&mut to_long, p); };
        transfer::public_transfer(to_long, long_pos.owner);
        if (fee > 0) { let fc = coin::split(&mut short_pos.collateral_locked, fee, ctx); TreasuryMod::deposit_collateral_ext(treasury, fc, b"options_liquidation".to_string(), liquidator, ctx); };
        // Liquidator bonus from remaining collateral proportional to liq_penalty_bps
        let bonus = (coin::value(&short_pos.collateral_locked) * reg.liq_penalty_bps) / 10_000;
        if (bonus > 0) { let b = coin::split(&mut short_pos.collateral_locked, bonus, ctx); transfer::public_transfer(b, liquidator); };
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; };
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let cur = *table::borrow(&market.user_open_interest, long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };
        event::emit(ShortLiquidated { market_id: object::id(market), short_owner: short_pos.owner, liquidator, quantity, collateral_seized: bonus, penalty_paid: bonus, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    // AutoSwap wrapper removed; physical settlement will create/cancel orders via dex.move off-chain orchestration

    /*******************************
    * Read‑only position helpers and health
    *******************************/
    public fun position_owner<C>(pos: &OptionPosition<C>): address { pos.owner }
    public fun position_market<C>(pos: &OptionPosition<C>): ID { pos.market_id }
    public fun position_info<C>(pos: &OptionPosition<C>): (u8, u64, u64, u64, u64) { (pos.side, pos.quantity, pos.premium_per_unit, pos.strike_price, pos.expiry_ms) }
    public fun short_health<C>(short_pos: &OptionPosition<C>, market: &OptionMarket): (u64, u64, bool) {
        let coll = coin::value(&short_pos.collateral_locked);
        let maint = (short_pos.quantity * market.strike_price * market.maint_margin_bps_short) / 10_000;
        (coll, maint, coll >= maint)
    }

    /// Risk score for a short: maint - coll (0 if healthy). Higher means more at risk.
    public fun short_risk_score<C>(short_pos: &OptionPosition<C>, market: &OptionMarket): u64 {
        let (coll, maint, _) = short_health(short_pos, market);
        if (coll >= maint) { 0 } else { maint - coll }
    }

    /// Rank a set of short position IDs by provided risk scores (descending).
    /// Off-chain callers should compute scores via short_risk_score and pass parallel vectors.
    public fun rank_short_ids_by_score(ids: vector<ID>, scores: vector<u64>): vector<ID> {
        let work_ids = ids;
        let mut work_scores = scores;
        let n = vector::length(&work_ids);
        let mut ordered = vector::empty<ID>();
        let mut k = 0;
        while (k < n) {
            let mut best_v: u64 = 0; let mut best_i: u64 = 0; let mut found = false;
            let mut j = 0; while (j < n) { let vj = *vector::borrow(&work_scores, j); if (vj > best_v) { best_v = vj; best_i = j; found = true; }; j = j + 1; };
            if (!found || best_v == 0) { break; }
            let top_id = *vector::borrow(&work_ids, best_i);
            vector::push_back(&mut ordered, top_id);
            // zero out consumed slot
            let mut new_scores = vector::empty<u64>();
            let mut t = 0; while (t < n) { let cur = *vector::borrow(&work_scores, t); if (t == best_i) { vector::push_back(&mut new_scores, 0); } else { vector::push_back(&mut new_scores, cur); }; t = t + 1; };
            work_scores = new_scores;
            k = k + 1;
        };
        ordered
    }

    fun market_key_bytes(underlying: &String, option_type: &String, strike: u64, expiry_ms: u64): vector<u8> {
        let mut out = vector::empty<u8>();
        // Append underlying bytes
        let ub = string::as_bytes(underlying);
        let mut i = 0; let n_ub = vector::length(ub);
        while (i < n_ub) { vector::push_back(&mut out, *vector::borrow(ub, i)); i = i + 1; };
        vector::push_back(&mut out, 0u8);
        // Append type bytes
        let tb = string::as_bytes(option_type);
        let mut j = 0; let n_tb = vector::length(tb);
        while (j < n_tb) { vector::push_back(&mut out, *vector::borrow(tb, j)); j = j + 1; };
        vector::push_back(&mut out, 0u8);
        // Append strike (u64) big-endian
        append_u64_be(&mut out, strike);
        // Append expiry
        append_u64_be(&mut out, expiry_ms);
        out
    }

    fun append_u64_be(out: &mut vector<u8>, x: u64) {
        let b7 = ((x >> 56) & 0xFF) as u8; vector::push_back(out, b7);
        let b6 = ((x >> 48) & 0xFF) as u8; vector::push_back(out, b6);
        let b5 = ((x >> 40) & 0xFF) as u8; vector::push_back(out, b5);
        let b4 = ((x >> 32) & 0xFF) as u8; vector::push_back(out, b4);
        let b3 = ((x >> 24) & 0xFF) as u8; vector::push_back(out, b3);
        let b2 = ((x >> 16) & 0xFF) as u8; vector::push_back(out, b2);
        let b1 = ((x >> 8) & 0xFF) as u8; vector::push_back(out, b1);
        let b0 = (x & 0xFF) as u8; vector::push_back(out, b0);
    }

    /*******************************
    * Displays for Market (type-level)
    *******************************/
    public fun init_market_display(publisher: &Publisher, ctx: &mut TxContext): display::Display<OptionMarket> {
        let mut disp = display::new<OptionMarket>(publisher, ctx);
        disp.add(b"name".to_string(), b"Option Market {underlying} {option_type} {strike_price} @ {expiry_ms}".to_string());
        disp.add(b"description".to_string(), b"Unxversal Options market".to_string());
        disp.add(b"underlying".to_string(), b"{underlying}".to_string());
        disp.add(b"option_type".to_string(), b"{option_type}".to_string());
        disp.add(b"strike_price".to_string(), b"{strike_price}".to_string());
        disp.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        disp.update_version();
        disp
    }

    public fun init_offer_and_position_displays<C: store>(publisher: &Publisher, ctx: &mut TxContext): (
        display::Display<ShortOffer<C>>,
        display::Display<PremiumEscrow<C>>,
        display::Display<OptionPosition<C>>,
        display::Display<LongUnderlyingEscrow<C>>
    ) {
        let mut disp_offer = display::new<ShortOffer<C>>(publisher, ctx);
        disp_offer.add(b"name".to_string(), b"Short Offer {option_type} {strike_price} exp {expiry_ms}".to_string());
        disp_offer.add(b"remaining_qty".to_string(), b"{remaining_qty}".to_string());
        disp_offer.add(b"min_premium_per_unit".to_string(), b"{min_premium_per_unit}".to_string());
        disp_offer.update_version();

        let mut disp_esc = display::new<PremiumEscrow<C>>(publisher, ctx);
        disp_esc.add(b"name".to_string(), b"Premium Escrow {option_type} {strike_price} exp {expiry_ms}".to_string());
        disp_esc.add(b"remaining_qty".to_string(), b"{remaining_qty}".to_string());
        disp_esc.add(b"premium_per_unit".to_string(), b"{premium_per_unit}".to_string());
        disp_esc.update_version();

        let mut disp_pos = display::new<OptionPosition<C>>(publisher, ctx);
        disp_pos.add(b"name".to_string(), b"Position {option_type} {strike_price} exp {expiry_ms}".to_string());
        disp_pos.add(b"side".to_string(), b"{side}".to_string());
        disp_pos.add(b"quantity".to_string(), b"{quantity}".to_string());
        disp_pos.add(b"premium_per_unit".to_string(), b"{premium_per_unit}".to_string());
        disp_pos.update_version();

        let mut disp_long_esc = display::new<LongUnderlyingEscrow<C>>(publisher, ctx);
        disp_long_esc.add(b"name".to_string(), b"Long Underlying Escrow {position_id}".to_string());
        disp_long_esc.update_version();
        (disp_offer, disp_esc, disp_pos, disp_long_esc)
    }

    /*******************************
    * Read‑only helpers
    *******************************/
    public fun list_underlyings(reg: &OptionsRegistry): vector<String> {
        // deep-clone vector<String>
        let mut out = vector::empty<String>();
        let mut i = 0; let n = vector::length(&reg.underlying_symbols);
        while (i < n) { let s = vector::borrow(&reg.underlying_symbols, i); vector::push_back(&mut out, clone_string(s)); i = i + 1; };
        out
    }
    public fun get_underlying(reg: &OptionsRegistry, symbol: &String): &UnderlyingAsset { table::borrow(&reg.supported_underlyings, clone_string(symbol)) }
    public fun list_option_market_keys(reg: &OptionsRegistry): vector<vector<u8>> {
        let mut out = vector::empty<vector<u8>>();
        let mut i = 0; let n = vector::length(&reg.market_key_list);
        while (i < n) { let kb = vector::borrow(&reg.market_key_list, i); vector::push_back(&mut out, clone_bytes(kb)); i = i + 1; };
        out
    }
    public fun get_registry_treasury_id(reg: &OptionsRegistry): ID { reg.treasury_id }
    public fun get_market_by_key(reg: &OptionsRegistry, key: &vector<u8>): ID { *table::borrow(&reg.option_markets, clone_bytes(key)) }

    /*******************************
    * Cash settlement at/after expiry (oracle normalized)
    *******************************/
    public fun expire_and_settle_market_cash(
        reg: &OptionsRegistry,
        market: &mut OptionMarket,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &Aggregator,
        ctx: &TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        // Allow settlement at or after expiry
        assert!(now >= market.expiry_ms, E_BAD_PARAMS);
        assert!(table::contains(&reg.supported_underlyings, clone_string(&market.underlying)), E_UNDERLYING_UNKNOWN);
        // Optional: add EMA/deviation checks here in future
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        market.settlement_price = px;
        market.settled_at_ms = now;
        market.is_expired = true;
        market.is_active = false;
        event::emit(OptionMarketSettled { market_id: object::id(market), underlying: clone_string(&market.underlying), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, settlement_price: px, timestamp: now });
    }

    /*******************************
    * OTC matching: Writer short offer and buyer premium escrow
    *******************************/
    public fun place_short_offer<C: store>(
        market: &OptionMarket,
        quantity: u64,
        min_premium_per_unit: u64,
        mut collateral: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(quantity > 0, E_AMOUNT);
        assert!(min_premium_per_unit > 0, E_PRICE);
        // Initial margin for shorts: notional * init_margin_bps_short
        let notional = quantity * market.strike_price;
        let needed = (notional * market.init_margin_bps_short) / 10_000;
        assert!(coin::value(&collateral) >= needed, E_COLLATERAL);
        let locked = coin::split(&mut collateral, needed, ctx);
        transfer::public_transfer(collateral, ctx.sender());
        let offer = ShortOffer<C> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, remaining_qty: quantity, min_premium_per_unit, collateral_locked: locked, created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx) };
        transfer::share_object(offer);
    }

    /// Coin short offer for physical CALLs that deliver Base at exercise
    public fun place_coin_short_offer<Base: store>(
        market: &OptionMarket,
        quantity: u64,
        min_premium_per_unit: u64,
        mut base_in: Coin<Base>,
        ctx: &mut TxContext
    ) {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(market.option_type == b"CALL".to_string(), E_BAD_PARAMS);
        assert!(quantity > 0, E_AMOUNT);
        assert!(min_premium_per_unit > 0, E_PRICE);
        // Require exact quantity of underlying to be escrowed for delivery
        let have = coin::value(&base_in);
        assert!(have >= quantity, E_COLLATERAL);
        let escrow = coin::split(&mut base_in, quantity, ctx);
        transfer::public_transfer(base_in, ctx.sender());
        let offer = CoinShortOffer<Base> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, remaining_qty: quantity, min_premium_per_unit, escrow_base: escrow, created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx) };
        transfer::share_object(offer);
    }

    public fun place_premium_escrow<C: store>(
        market: &OptionMarket,
        quantity: u64,
        premium_per_unit: u64,
        mut collateral: Coin<C>,
        expiry_cancel_ms: u64,
        ctx: &mut TxContext
    ) {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(quantity > 0, E_AMOUNT);
        assert!(premium_per_unit > 0, E_PRICE);
        let needed = quantity * premium_per_unit;
        assert!(coin::value(&collateral) >= needed, E_PRICE);
        let escrow = coin::split(&mut collateral, needed, ctx);
        transfer::public_transfer(collateral, ctx.sender());
        let esc = PremiumEscrow<C> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, remaining_qty: quantity, premium_per_unit, escrow_collateral: escrow, created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), expiry_cancel_ms };
        transfer::share_object(esc);
    }

    /// Long underlying escrow for physical PUTs: buyer deposits Base they will deliver on exercise
    public fun place_long_underlying_escrow<Base: store>(
        market: &OptionMarket,
        quantity: u64,
        mut base_in: Coin<Base>,
        ctx: &mut TxContext
    ) {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(market.option_type == b"PUT".to_string(), E_BAD_PARAMS);
        assert!(quantity > 0, E_AMOUNT);
        let have = coin::value(&base_in);
        assert!(have >= quantity, E_COLLATERAL);
        let escrow = coin::split(&mut base_in, quantity, ctx);
        transfer::public_transfer(base_in, ctx.sender());
        // Position will be created on match; bind owner now
        let esc = LongUnderlyingEscrow<Base> { id: object::new(ctx), owner: ctx.sender(), position_id: object::id(market), escrow_base: escrow };
        transfer::share_object(esc);
    }

    public fun cancel_long_underlying_escrow<Base: store>(market: &OptionMarket, esc: LongUnderlyingEscrow<Base>, ctx: &mut TxContext) {
        assert!(esc.owner == ctx.sender(), E_NOT_ADMIN);
        // Allow cancel only if escrow is unbound (still tied to market placeholder id)
        assert!(esc.position_id == object::id(market), E_BAD_PARAMS);
        let LongUnderlyingEscrow<Base> { id, owner, position_id: _, escrow_base } = esc;
        transfer::public_transfer(escrow_base, owner);
        object::delete(id);
    }

    /// GC for long PUT escrow: delete when empty (anyone can call; no funds)
    public fun gc_long_underlying_escrow<Base: store>(esc: LongUnderlyingEscrow<Base>, _ctx: &mut TxContext) {
        assert!(coin::value(&esc.escrow_base) == 0, E_BAD_PARAMS);
        let LongUnderlyingEscrow<Base> { id, owner: _, position_id: _, escrow_base } = esc;
        coin::destroy_zero(escrow_base);
        object::delete(id);
    }

    public fun cancel_short_offer<C: store>(offer: ShortOffer<C>, ctx: &mut TxContext) {
        assert!(offer.owner == ctx.sender(), E_NOT_ADMIN);
        let ShortOffer<C> { id, owner, market_id: _, option_type: _, strike_price: _, expiry_ms: _, remaining_qty: _, min_premium_per_unit: _, collateral_locked, created_at_ms: _ } = offer;
        transfer::public_transfer(collateral_locked, owner);
        object::delete(id);
    }

    public fun cancel_coin_short_offer<Base: store>(offer: CoinShortOffer<Base>, ctx: &mut TxContext) {
        assert!(offer.owner == ctx.sender(), E_NOT_ADMIN);
        let CoinShortOffer<Base> { id, owner, market_id: _, option_type: _, strike_price: _, expiry_ms: _, remaining_qty: _, min_premium_per_unit: _, escrow_base, created_at_ms: _ } = offer;
        transfer::public_transfer(escrow_base, owner);
        object::delete(id);
    }

    public fun cancel_premium_escrow<C: store>(esc: PremiumEscrow<C>, ctx: &mut TxContext) {
        assert!(esc.owner == ctx.sender(), E_NOT_ADMIN);
        assert!(sui::tx_context::epoch_timestamp_ms(ctx) >= esc.expiry_cancel_ms, E_BAD_PARAMS);
        let PremiumEscrow<C> { id, owner, market_id: _, option_type: _, strike_price: _, expiry_ms: _, remaining_qty: _, premium_per_unit: _, escrow_collateral, created_at_ms: _, expiry_cancel_ms: _ } = esc;
        transfer::public_transfer(escrow_collateral, owner);
        object::delete(id);
    }

    public fun match_offer_and_escrow<C: store>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        mut offer: ShortOffer<C>,
        mut escrow: PremiumEscrow<C>,
        max_fill_qty: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        treasury: &mut Treasury<C>,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        unxv_price: &Aggregator,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(offer.market_id == object::id(market) && escrow.market_id == object::id(market), E_MISMATCH);
        assert!(market.is_active && !market.is_expired && !market.paused, E_EXPIRED);
        // Enforce tick and contract size
        assert!(escrow.premium_per_unit % market.tick_size == 0, E_PRICE);
        assert!(offer.remaining_qty % market.contract_size == 0 && escrow.remaining_qty % market.contract_size == 0, E_BAD_PARAMS);
        // crossed condition
        assert!(escrow.premium_per_unit >= offer.min_premium_per_unit, E_PRICE);
        let fill = {
        let a = if (offer.remaining_qty < escrow.remaining_qty) { offer.remaining_qty } else { escrow.remaining_qty };
            if (a < max_fill_qty) { a } else { max_fill_qty }
        };
        assert!(fill > 0, E_AMOUNT);
        assert!(fill % market.contract_size == 0, E_BAD_PARAMS);
        // Per-market/user caps
        if (market.max_open_contracts_market > 0) { assert!(market.total_open_interest + fill <= market.max_open_contracts_market, E_BAD_PARAMS); };
        if (market.max_oi_per_user > 0) {
            let cur = if (table::contains(&market.user_open_interest, escrow.owner)) { *table::borrow(&market.user_open_interest, escrow.owner) } else { 0 };
            assert!(cur + fill <= market.max_oi_per_user, E_BAD_PARAMS);
        };

        // Premium owed
        let premium_total = fill * escrow.premium_per_unit;
        let trade_fee_bps = if (market.trade_fee_bps_override > 0) { market.trade_fee_bps_override } else { reg.trade_fee_bps };
        let trade_fee = (premium_total * trade_fee_bps) / 10_000;
        let discount_collateral = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let unxv_px = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (unxv_px > 0) {
                let unxv_needed = (discount_collateral + unxv_px - 1) / unxv_px;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv_ext(treasury, vecu, b"options_premium_trade".to_string(), escrow.owner, ctx);
                    transfer::public_transfer(merged, escrow.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, escrow.owner);
                }
            }
        };
        let fee_to_collect = if (discount_applied) { if (trade_fee > discount_collateral) { trade_fee - discount_collateral } else { 0 } } else { trade_fee };

        // Move premium net of fee to writer, pay fee to treasury
        let net_to_writer = if (premium_total > fee_to_collect) { premium_total - fee_to_collect } else { 0 };
        if (net_to_writer > 0) {
            let to_writer = coin::split(&mut escrow.escrow_collateral, net_to_writer, ctx);
            transfer::public_transfer(to_writer, offer.owner);
        };
        if (fee_to_collect > 0) {
            let fee_coin = coin::split(&mut escrow.escrow_collateral, fee_to_collect, ctx);
            TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"options_premium_trade".to_string(), escrow.owner, ctx);
        };

        // Create positions
        let long_pos = OptionPosition<C> { id: object::new(ctx), owner: escrow.owner, market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 0, quantity: fill, premium_per_unit: escrow.premium_per_unit, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: coin::zero<C>(ctx) };
        // Move proportional initial margin from offer to short position
        let notional_fill = fill * market.strike_price;
        let short_needed = (notional_fill * market.init_margin_bps_short) / 10_000;
        let short_locked = coin::split(&mut offer.collateral_locked, short_needed, ctx);
        let short_pos = OptionPosition<C> { id: object::new(ctx), owner: offer.owner, market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 1, quantity: fill, premium_per_unit: 0, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: short_locked };
        transfer::share_object(long_pos);
        transfer::share_object(short_pos);

        // Update offers
        offer.remaining_qty = offer.remaining_qty - fill;
        escrow.remaining_qty = escrow.remaining_qty - fill;

        // Update market stats
        market.total_open_interest = market.total_open_interest + fill;
        market.total_volume_premium = market.total_volume_premium + premium_total;
        market.last_trade_premium = escrow.premium_per_unit;
        // Update user OI
        let cur_buyer = if (table::contains(&market.user_open_interest, escrow.owner)) { *table::borrow(&market.user_open_interest, escrow.owner) } else { 0 };
        if (table::contains(&market.user_open_interest, escrow.owner)) { let _ = table::remove(&mut market.user_open_interest, escrow.owner); };
        table::add(&mut market.user_open_interest, escrow.owner, cur_buyer + fill);
        event::emit(OptionMatched { market_id: object::id(market), buyer: escrow.owner, writer: offer.owner, option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, quantity: fill, premium_per_unit: escrow.premium_per_unit, fee_paid: fee_to_collect, unxv_discount_applied: discount_applied, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(OptionOpened { market_id: object::id(market), buyer: escrow.owner, writer: offer.owner, quantity: fill, premium_per_unit: escrow.premium_per_unit, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Match coin-escrowed CALL offer with premium escrow (physical delivery on exercise)
    public fun match_coin_offer_and_escrow<Base: store, C: store>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        mut offer_or_long: CoinShortOffer<Base>,
        mut escrow: PremiumEscrow<C>,
        max_fill_qty: u64,
        // UNXV discount support (optional). Pass empty vector to skip.
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(offer_or_long.market_id == object::id(market) && escrow.market_id == object::id(market), E_MISMATCH);
        assert!(market.is_active && !market.is_expired && !market.paused, E_EXPIRED);
        assert!(market.option_type == b"CALL".to_string(), E_BAD_PARAMS);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(escrow.premium_per_unit % market.tick_size == 0, E_PRICE);
        assert!(offer_or_long.remaining_qty % market.contract_size == 0 && escrow.remaining_qty % market.contract_size == 0, E_BAD_PARAMS);
        assert!(escrow.premium_per_unit >= offer_or_long.min_premium_per_unit, E_PRICE);
        let fill = { let a = if (offer_or_long.remaining_qty < escrow.remaining_qty) { offer_or_long.remaining_qty } else { escrow.remaining_qty }; if (a < max_fill_qty) { a } else { max_fill_qty } };
        assert!(fill > 0 && fill % market.contract_size == 0, E_AMOUNT);
        if (market.max_open_contracts_market > 0) { assert!(market.total_open_interest + fill <= market.max_open_contracts_market, E_BAD_PARAMS); };
        if (market.max_oi_per_user > 0) { let cur = if (table::contains(&market.user_open_interest, escrow.owner)) { *table::borrow(&market.user_open_interest, escrow.owner) } else { 0 }; assert!(cur + fill <= market.max_oi_per_user, E_BAD_PARAMS); };
        // Premium payment with UNXV discount parity
        let premium_total = fill * escrow.premium_per_unit;
        let trade_fee_bps = if (market.trade_fee_bps_override > 0) { market.trade_fee_bps_override } else { reg.trade_fee_bps };
        let trade_fee = (premium_total * trade_fee_bps) / 10_000;
        let discount_collateral = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        // Try UNXV discount (optional)
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
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
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv_ext(treasury, vecu, b"options_premium_trade".to_string(), escrow.owner, ctx);
                    transfer::public_transfer(merged, escrow.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, escrow.owner);
                }
            }
        };
        let fee_to_collect = if (discount_applied) { if (trade_fee > discount_collateral) { trade_fee - discount_collateral } else { 0 } } else { trade_fee };
        // Move premium net of fee to writer, pay fee to treasury
        let net_to_writer = if (premium_total > fee_to_collect) { premium_total - fee_to_collect } else { 0 };
        if (net_to_writer > 0) { let to_writer = coin::split(&mut escrow.escrow_collateral, net_to_writer, ctx); transfer::public_transfer(to_writer, offer_or_long.owner); };
        if (fee_to_collect > 0) { let fee_coin = coin::split(&mut escrow.escrow_collateral, fee_to_collect, ctx); TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"options_premium_trade".to_string(), escrow.owner, ctx); };
        // Create positions: long receives standard long position; short remains coin-escrowed upon exercise
        let long_pos = OptionPosition<C> { id: object::new(ctx), owner: escrow.owner, market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 0, quantity: fill, premium_per_unit: escrow.premium_per_unit, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: coin::zero<C>(ctx) };
        if (market.option_type == b"CALL".to_string()) {
        let short_pos_id = object::new(ctx);
            let short_split = coin::split(&mut offer_or_long.escrow_base, fill, ctx);
            let short_pos = OptionPosition<C> { id: short_pos_id, owner: offer_or_long.owner, market_id: object::id(market), option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 1, quantity: fill, premium_per_unit: 0, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: coin::zero<C>(ctx) };
        let escrow_obj = ShortUnderlyingEscrow<Base> { id: object::new(ctx), position_id: object::id(&short_pos), escrow_base: short_split };
        transfer::share_object(short_pos);
        transfer::share_object(escrow_obj);
        };
        transfer::share_object(long_pos);
        // Update remaining
        offer_or_long.remaining_qty = offer_or_long.remaining_qty - fill;
        escrow.remaining_qty = escrow.remaining_qty - fill;
        market.total_open_interest = market.total_open_interest + fill;
        let cur_buyer = if (table::contains(&market.user_open_interest, escrow.owner)) { *table::borrow(&market.user_open_interest, escrow.owner) } else { 0 };
        if (table::contains(&market.user_open_interest, escrow.owner)) { let _ = table::remove(&mut market.user_open_interest, escrow.owner); };
        table::add(&mut market.user_open_interest, escrow.owner, cur_buyer + fill);
        event::emit(OptionMatched { market_id: object::id(market), buyer: escrow.owner, writer: offer_or_long.owner, option_type: clone_string(&market.option_type), strike_price: market.strike_price, expiry_ms: market.expiry_ms, quantity: fill, premium_per_unit: escrow.premium_per_unit, fee_paid: fee_to_collect, unxv_discount_applied: discount_applied, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(OptionOpened { market_id: object::id(market), buyer: escrow.owner, writer: offer_or_long.owner, quantity: fill, premium_per_unit: escrow.premium_per_unit, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Settle a matched long/short pair after market settlement (cash)
    *******************************/
    public fun settle_positions_cash<C>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        quantity: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(market.is_expired && market.settlement_price > 0, E_BAD_PARAMS);
        assert!(long_pos.market_id == object::id(market) && short_pos.market_id == object::id(market), E_MISMATCH);
        assert!(long_pos.side == 0 && short_pos.side == 1, E_SIDE);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);

        // payout = max(0, (settlement - strike)) for calls; max(0, (strike - settlement)) for puts
        let mut payout = 0u64;
        if (long_pos.option_type == b"CALL".to_string()) {
            if (market.settlement_price > long_pos.strike_price) { payout = (market.settlement_price - long_pos.strike_price) * quantity; } else { payout = 0; }
        } else {
            // PUT
            if (long_pos.strike_price > market.settlement_price) { payout = (long_pos.strike_price - market.settlement_price) * quantity; } else { payout = 0; }
        };

        // Apply settlement fee (per-market override)
        let fee_bps = if (market.settlement_fee_bps_override > 0) { market.settlement_fee_bps_override } else { reg.settlement_fee_bps };
        let fee = (payout * fee_bps) / 10_000;
        let net_to_long = if (payout > fee) { payout - fee } else { 0 };

        // Maintenance margin check and liquidation path if undercollateralized
        let notional = quantity * market.strike_price;
        let maint_needed = (notional * market.maint_margin_bps_short) / 10_000;
        let cur_coll = coin::value(&short_pos.collateral_locked);
        if (cur_coll < maint_needed) {
            event::emit(MarginCallTriggered { short_owner: short_pos.owner, market_id: object::id(market), required_collateral: maint_needed, current_collateral: cur_coll, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        };

        // Pay long from short collateral
        let mut to_long = coin::zero<C>(ctx);
        if (net_to_long > 0) { let p = coin::split(&mut short_pos.collateral_locked, net_to_long, ctx); coin::join(&mut to_long, p); };
        transfer::public_transfer(to_long, long_pos.owner);

        if (fee > 0) {
            let mut fee_coin = coin::split(&mut short_pos.collateral_locked, fee, ctx);
            let bot_cut = (coin::value(&fee_coin) * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let bot_coin = coin::split(&mut fee_coin, bot_cut, ctx); TreasuryMod::deposit_collateral_ext(treasury, bot_coin, b"options_settlement_bot".to_string(), ctx.sender(), ctx); };
            TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"options_settlement".to_string(), ctx.sender(), ctx);
        };

        // Return remaining proportional collateral to short when fully settled externally (not handled here)
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let cur = *table::borrow(&market.user_open_interest, long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            let _ = table::remove(&mut market.user_open_interest, long_pos.owner);
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };

        event::emit(OptionSettled { market_id: object::id(market), long_owner: long_pos.owner, short_owner: short_pos.owner, option_type: clone_string(&long_pos.option_type), strike_price: long_pos.strike_price, expiry_ms: long_pos.expiry_ms, quantity, settlement_price: market.settlement_price, payout_to_long: net_to_long, fee_paid: fee, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Physical exercise for coin-escrowed CALLs
    *******************************/
    public fun exercise_physical_call<Base: store, C: store>(
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        escrow: &mut ShortUnderlyingEscrow<Base>,
        quantity: u64,
        ctx: &mut TxContext
    ) {
        assert!(market.option_type == b"CALL".to_string(), E_BAD_PARAMS);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        // Verify escrow belongs to this short position
        assert!(escrow.position_id == object::id(short_pos), E_MISMATCH);
        // Deliver underlying
        let deliver = coin::split(&mut escrow.escrow_base, quantity, ctx);
        transfer::public_transfer(deliver, long_pos.owner);
        // Update positions and OI
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; };
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let _old = table::remove(&mut market.user_open_interest, long_pos.owner);
            let newv = if (_old > quantity) { _old - quantity } else { 0 };
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };
        // If escrow empty, leave object to be cleaned up by a separate GC path
        // (cannot move out of &mut reference here)
    }

    /*******************************
    * Physical exercise for PUTs (long delivers Base, short pays Quote)
    *******************************/
    public fun exercise_physical_put<Base: store, C: store>(
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        mut base_from_long: Coin<Base>,
        quantity: u64,
        ctx: &mut TxContext
    ) {
        assert!(market.option_type == b"PUT".to_string(), E_BAD_PARAMS);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        // Long must deliver exactly the underlying base units for the exercised quantity
        let have_base = coin::value(&base_from_long);
        assert!(have_base == quantity, E_AMOUNT);
        // Short pays strike * quantity in quote collateral to long
        let quote_owed = market.strike_price * quantity;
        if (quote_owed > 0) {
            let to_long = coin::split(&mut short_pos.collateral_locked, quote_owed, ctx);
            transfer::public_transfer(to_long, long_pos.owner);
        };
        // Deliver base to short
        transfer::public_transfer(base_from_long, short_pos.owner);

        // Update positions and OI
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; };
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let _old = table::remove(&mut market.user_open_interest, long_pos.owner);
            let newv = if (_old > quantity) { _old - quantity } else { 0 };
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };
        // No fee charged on physical PUT exercise to match CALL behavior
    }

    /// Exercise PUT from bound long escrow (symmetric to CALL escrow path)
    public fun exercise_physical_put_from_escrow<Base: store, C: store>(
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        escrow: &mut LongUnderlyingEscrow<Base>,
        quantity: u64,
        ctx: &mut TxContext
    ) {
        assert!(market.option_type == b"PUT".to_string(), E_BAD_PARAMS);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        assert!(escrow.position_id == object::id(long_pos), E_MISMATCH);
        // Short pays strike * quantity to long
        let quote_owed = market.strike_price * quantity;
        if (quote_owed > 0) { let pay = coin::split(&mut short_pos.collateral_locked, quote_owed, ctx); transfer::public_transfer(pay, long_pos.owner); };
        // Deliver base from escrow to short
        let deliver = coin::split(&mut escrow.escrow_base, quantity, ctx);
        transfer::public_transfer(deliver, short_pos.owner);
        // Update positions and OI
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; };
        if (table::contains(&market.user_open_interest, long_pos.owner)) {
            let _old = table::remove(&mut market.user_open_interest, long_pos.owner);
            let newv = if (_old > quantity) { _old - quantity } else { 0 };
            table::add(&mut market.user_open_interest, long_pos.owner, newv);
        };
    }

    /// Match physical PUT: consume long's Base escrow and short's cash offer; premium paid from PremiumEscrow<C>
    public fun match_put_long_escrow_and_offer<Base: store, C: store>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        mut long_escrow: LongUnderlyingEscrow<Base>,
        mut offer: ShortOffer<C>,
        mut prem: PremiumEscrow<C>,
        max_fill_qty: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(market.is_active && !market.is_expired && !market.paused, E_EXPIRED);
        assert!(market.option_type == b"PUT".to_string(), E_BAD_PARAMS);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(offer.market_id == object::id(market) && prem.market_id == object::id(market), E_MISMATCH);
        let long_owner_base = coin::value(&long_escrow.escrow_base);
        assert!(prem.premium_per_unit % market.tick_size == 0, E_PRICE);
        assert!(offer.remaining_qty % market.contract_size == 0 && prem.remaining_qty % market.contract_size == 0, E_BAD_PARAMS);
        assert!(prem.premium_per_unit >= offer.min_premium_per_unit, E_PRICE);
        let a = if (offer.remaining_qty < prem.remaining_qty) { offer.remaining_qty } else { prem.remaining_qty };
        let b = if (a < long_owner_base) { a } else { long_owner_base };
        let fill = if (b < max_fill_qty) { b } else { max_fill_qty };
        assert!(fill > 0 && fill % market.contract_size == 0, E_AMOUNT);
        if (market.max_open_contracts_market > 0) { assert!(market.total_open_interest + fill <= market.max_open_contracts_market, E_BAD_PARAMS); };
        if (market.max_oi_per_user > 0) { let cur = if (table::contains(&market.user_open_interest, prem.owner)) { *table::borrow(&market.user_open_interest, prem.owner) } else { 0 }; assert!(cur + fill <= market.max_oi_per_user, E_BAD_PARAMS); };

        // Premium payment with optional UNXV discount
        let premium_total = fill * prem.premium_per_unit;
        let trade_fee_bps = if (market.trade_fee_bps_override > 0) { market.trade_fee_bps_override } else { reg.trade_fee_bps };
        let trade_fee = (premium_total * trade_fee_bps) / 10_000;
        let discount_collateral = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
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
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv_ext(treasury, vecu, b"options_premium_trade".to_string(), prem.owner, ctx);
                    transfer::public_transfer(merged, prem.owner);
                    discount_applied = true;
                } else { transfer::public_transfer(merged, prem.owner); }
            }
        };
        let fee_to_collect = if (discount_applied) { if (trade_fee > discount_collateral) { trade_fee - discount_collateral } else { 0 } } else { trade_fee };
        let net_to_writer = if (premium_total > fee_to_collect) { premium_total - fee_to_collect } else { 0 };
        if (net_to_writer > 0) { let to_writer = coin::split(&mut prem.escrow_collateral, net_to_writer, ctx); transfer::public_transfer(to_writer, offer.owner); };
        if (fee_to_collect > 0) { let fee_coin = coin::split(&mut prem.escrow_collateral, fee_to_collect, ctx); TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"options_premium_trade".to_string(), prem.owner, ctx); };

        // Create positions
        let long_pos = OptionPosition<C> { id: object::new(ctx), owner: prem.owner, market_id: object::id(market), option_type: b"PUT".to_string(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 0, quantity: fill, premium_per_unit: prem.premium_per_unit, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: coin::zero<C>(ctx) };
        let notional_fill = fill * market.strike_price;
        let short_needed = (notional_fill * market.init_margin_bps_short) / 10_000;
        let short_locked = coin::split(&mut offer.collateral_locked, short_needed, ctx);
        let short_pos = OptionPosition<C> { id: object::new(ctx), owner: offer.owner, market_id: object::id(market), option_type: b"PUT".to_string(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 1, quantity: fill, premium_per_unit: 0, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: short_locked };

        // Bind exactly 'fill' Base to long position
        let LongUnderlyingEscrow<Base> { id: old_id, owner: _, position_id: _, mut escrow_base } = long_escrow;
        let deliver = coin::split(&mut escrow_base, fill, ctx);
        // refund remainder to long owner
        transfer::public_transfer(escrow_base, prem.owner);
        object::delete(old_id);
        let bound = LongUnderlyingEscrow<Base> { id: object::new(ctx), owner: prem.owner, position_id: object::id(&long_pos), escrow_base: deliver };

        // Share created/updated objects
        transfer::share_object(long_pos);
        transfer::share_object(short_pos);
        transfer::share_object(bound);

        // Update remainders and stats
        offer.remaining_qty = offer.remaining_qty - fill;
        prem.remaining_qty = prem.remaining_qty - fill;
        market.total_open_interest = market.total_open_interest + fill;
        market.total_volume_premium = market.total_volume_premium + premium_total;
        market.last_trade_premium = prem.premium_per_unit;
        let cur_long = if (table::contains(&market.user_open_interest, prem.owner)) { *table::borrow(&market.user_open_interest, prem.owner) } else { 0 };
        if (table::contains(&market.user_open_interest, prem.owner)) { let _ = table::remove(&mut market.user_open_interest, prem.owner); };
        table::add(&mut market.user_open_interest, prem.owner, cur_long + fill);
        event::emit(OptionMatched { market_id: object::id(market), buyer: prem.owner, writer: offer.owner, option_type: b"PUT".to_string(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, quantity: fill, premium_per_unit: prem.premium_per_unit, fee_paid: fee_to_collect, unxv_discount_applied: discount_applied, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(OptionOpened { market_id: object::id(market), buyer: prem.owner, writer: offer.owner, quantity: fill, premium_per_unit: prem.premium_per_unit, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// GC function to delete an empty ShortUnderlyingEscrow<Base> object once fully delivered
    public fun gc_underlying_escrow<Base: store>(escrow: ShortUnderlyingEscrow<Base>, _ctx: &mut TxContext) {
        assert!(coin::value(&escrow.escrow_base) == 0, E_BAD_PARAMS);
        let ShortUnderlyingEscrow<Base> { id, position_id: _, escrow_base } = escrow;
        coin::destroy_zero(escrow_base);
        object::delete(id);
    }

    public fun emit_physical_delivery_completed(
        market: &OptionMarket,
        side: u8,
        quantity: u64,
        avg_settlement_price: u64,
        ctx: &TxContext
    ) { event::emit(PhysicalDeliveryCompleted { market_id: object::id(market), fulfiller: ctx.sender(), side, quantity, avg_settlement_price, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    /*******************************
    * Physical settlement intent events (bot-driven orchestration)
    *******************************/
    public fun request_physical_delivery_long<C>(
        market: &OptionMarket,
        long_pos: &OptionPosition<C>,
        quantity: u64,
        min_settlement_price: u64,
        ctx: &TxContext
    ) { assert!(quantity > 0 && quantity <= long_pos.quantity, E_AMOUNT); event::emit(PhysicalDeliveryRequested { market_id: object::id(market), requester: long_pos.owner, side: 0, quantity, min_settlement_price, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    public fun request_physical_delivery_short<C>(
        market: &OptionMarket,
        short_pos: &OptionPosition<C>,
        quantity: u64,
        min_settlement_price: u64,
        ctx: &TxContext
    ) { assert!(quantity > 0 && quantity <= short_pos.quantity, E_AMOUNT); event::emit(PhysicalDeliveryRequested { market_id: object::id(market), requester: short_pos.owner, side: 1, quantity, min_settlement_price, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }
}


