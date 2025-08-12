module unxversal::options {
    /*******************************
    * Unxversal Options – Phase 1 (Registry & Market Listing)
    * - Admin‑whitelisted underlyings (native coins or synthetics)
    * - Permissionless option market creation on whitelisted underlyings
    * - Oracle feeds normalized to micro‑USD via core Oracle module
    * - Internal DEX/AutoSwap expected for execution in later phases
    * - Displays and read‑only helpers for indexers/bots
    *******************************/

    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::display;
    use sui::object;
    use sui::package;
    use sui::package::Publisher;
    use sui::types;
    use sui::event;
    use std::string::String;
    use sui::table::Table;
    use sui::vec_set::VecSet;
    use std::vector;
    use sui::clock; // timestamp helpers
    use sui::clock::Clock;
    use pyth::price_info::{Self as PriceInfo, PriceInfoObject};
    use pyth::price_identifier;
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;
    use sui::coin::{Self as Coin, Coin};
    use unxversal::synthetics::{SynthRegistry, AdminCap, DaddyCap};
    // AutoSwap removed; options integrates directly with on-chain orderbook in dex.move for execution paths.

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
    public struct ShortUnderlyingEscrow<Base> has key, store {
        id: UID,
        position_id: ID,
        escrow_base: Coin<Base>,
    }

    /// Coin-collateralized short offer (typed by Base)
    public struct CoinShortOffer<Base> has key, store {
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
    fun assert_is_admin(reg: &OptionsRegistry, addr: address) { /* deprecated local list – retained for compatibility */ addr; }
    fun assert_is_admin_via_synth(synth_reg: &SynthRegistry, addr: address) { assert!(VecSet::contains(&synth_reg.admin_addrs, addr), E_NOT_ADMIN); }

    /*******************************
    * INIT – executed once on package publish
    *******************************/
    fun init<C>(otw: OPTIONS, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let reg = OptionsRegistry {
            id: object::new(ctx),
            supported_underlyings: Table::new::<String, UnderlyingAsset>(ctx),
            option_markets: Table::new::<vector<u8>, ID>(ctx),
            paused: false,
            treasury_id: {
                let t = Treasury<C> { id: object::new(ctx), collateral: Coin::zero<C>(ctx), unxv: Coin::zero<UNXV>(ctx), cfg: unxversal::treasury::TreasuryCfg { unxv_burn_bps: 0 } };
                let id = object::id(&t);
                transfer::share_object(t);
                id
            },
            trade_fee_bps: 30,
            unxv_discount_bps: 2000,
            settlement_fee_bps: 10,
            liq_penalty_bps: 500,
            liq_bot_reward_bps: 1000,
            close_bot_reward_bps: 0,
            settlement_bot_reward_bps: 0,
            maker_rebate_bps_close: 100, // 1% default maker rebate on close
            owner_positions: Table::new<address, vector<ID>>(ctx),
            market_positions: Table::new<ID, vector<ID>>(ctx),
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
    public entry fun add_underlying(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut OptionsRegistry,
        symbol: String,
        asset: UnderlyingAsset,
        ctx: &TxContext
    ) {
        assert_is_admin_via_synth(synth_reg, ctx.sender());
        assert!(!reg.paused, E_PAUSED);
        assert!(!Table::contains(&reg.supported_underlyings, &symbol), E_UNDERLYING_EXISTS);
        Table::insert(&mut reg.supported_underlyings, symbol.clone(), asset);
        event::emit(UnderlyingAdded { symbol, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun remove_underlying(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut OptionsRegistry,
        symbol: String,
        ctx: &TxContext
    ) {
        assert_is_admin_via_synth(synth_reg, ctx.sender());
        assert!(!reg.paused, E_PAUSED);
        assert!(Table::contains(&reg.supported_underlyings, &symbol), E_UNDERLYING_UNKNOWN);
        Table::remove(&mut reg.supported_underlyings, symbol.clone());
        event::emit(UnderlyingRemoved { symbol, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun pause(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.paused = true; event::emit(PausedToggled { new_state: true, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }
    public entry fun resume(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.paused = false; event::emit(PausedToggled { new_state: false, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    public entry fun set_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }
    public entry fun set_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, trade_fee_bps: u64, unxv_discount_bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.trade_fee_bps = trade_fee_bps; reg.unxv_discount_bps = unxv_discount_bps; }
    public entry fun set_settlement_fee_bps(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.settlement_fee_bps = bps; }
    public entry fun set_liq_penalty_bps(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.liq_penalty_bps = bps; }
    public entry fun set_bot_reward_bps(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, liq_bot_bps: u64, close_bot_bps: u64, settle_bot_bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.liq_bot_reward_bps = liq_bot_bps; reg.close_bot_reward_bps = close_bot_bps; reg.settlement_bot_reward_bps = settle_bot_bps; }
    public entry fun set_maker_rebate_bps_close(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut OptionsRegistry, bps: u64, ctx: &TxContext) { assert_is_admin_via_synth(synth_reg, ctx.sender()); reg.maker_rebate_bps_close = bps; }
    public entry fun set_default_market_params(
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

    public entry fun set_market_params(
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

    public entry fun set_market_fee_overrides(
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

    public entry fun grant_admin_via_synth(daddy: &DaddyCap, synth_reg: &mut SynthRegistry, new_admin: address, ctx: &mut TxContext) { Synth::grant_admin(daddy, synth_reg, new_admin, ctx); }
    public entry fun revoke_admin_via_synth(daddy: &DaddyCap, synth_reg: &mut SynthRegistry, bad_admin: address) { Synth::revoke_admin(daddy, synth_reg, bad_admin); }

    /*******************************
    * Permissionless Market Creation (on whitelisted underlyings)
    *******************************/
    public entry fun create_option_market<C>(
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
    ) {
        assert!(!reg.paused, E_PAUSED);
        // Validate underlying
        assert!(Table::contains(&reg.supported_underlyings, &underlying), E_UNDERLYING_UNKNOWN);
        let u = Table::borrow(&reg.supported_underlyings, &underlying);
        assert!(u.is_active, E_UNDERLYING_INACTIVE);
        assert!(strike_price >= u.min_strike_price && strike_price <= u.max_strike_price, E_BAD_PARAMS);
        assert!(expiry_ms >= u.min_expiry_duration_ms && expiry_ms <= u.max_expiry_duration_ms, E_BAD_PARAMS);

        let key_bytes = market_key_bytes(&underlying, &option_type, strike_price, expiry_ms);
        assert!(!Table::contains(&reg.option_markets, &key_bytes), E_BAD_PARAMS);

        let market = OptionMarket {
            id: object::new(ctx),
            underlying: underlying.clone(),
            option_type: option_type.clone(),
            strike_price,
            expiry_ms,
            settlement_type,
            paused: false,
            is_active: true,
            is_expired: false,
            exercise_style: reg.default_exercise_style.clone(),
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
            user_open_interest: Table::new<address, u64>(ctx),
        };
        let mid = object::id(&market);
        transfer::share_object(market);
        Table::insert(&mut reg.option_markets, key_bytes.clone(), mid);

        // Optional creation fee collection with UNXV discount at source
        if (creation_fee > 0) {
            // Apply UNXV discount
            let discount_collateral = (creation_fee * reg.unxv_discount_bps) / 10_000;
            let mut discount_applied = false;
            if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
                // Require caller to pass an oracle‑priced UNXV cost off‑chain or integrate here later
                // For now, accept UNXV as is and deposit; creation fee reduced accordingly
                let mut merged = Coin::zero<UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); Coin::merge(&mut merged, c); i = i + 1; };
                if (Coin::value(&merged) > 0) {
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, merged);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"options_market_create".to_string(), ctx.sender(), ctx);
                    discount_applied = true;
                };
            };
            let fee_due = if (discount_applied && creation_fee > discount_collateral) { creation_fee - discount_collateral } else { creation_fee };
            if (fee_due > 0) {
                let pay = Coin::split(&mut creation_fee_coin, fee_due, ctx);
                TreasuryMod::deposit_collateral(treasury, pay, b"options_market_create".to_string(), ctx.sender(), ctx);
            };
            // refund any remainder
            transfer::public_transfer(creation_fee_coin, ctx.sender());
        } else {
            // refund any provided coin
            transfer::public_transfer(creation_fee_coin, ctx.sender());
        };

        event::emit(OptionMarketCreated { market_id: mid, market_key_bytes: key_bytes, underlying, option_type, strike_price, expiry_ms, settlement_type, creator: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun init_settlement_queue(dispute_window_ms: u64, ctx: &mut TxContext): SettlementQueue {
        SettlementQueue { id: object::new(ctx), dispute_window_ms, pending: vector::empty<ID>(), requested_at_ms: Table::new<ID, u64>(ctx) }
    }

    public entry fun request_market_settlement(queue: &mut SettlementQueue, market: &OptionMarket, ctx: &mut TxContext) {
        vector::push_back(&mut queue.pending, object::id(market));
        Table::insert(&mut queue.requested_at_ms, object::id(market), sui::tx_context::epoch_timestamp_ms(ctx));
    }

    public entry fun process_due_settlements(queue: &mut SettlementQueue, reg: &OptionsRegistry, markets: vector<&mut OptionMarket>, oracle_cfg: &OracleConfig, clocks: vector<&Clock>, prices: vector<&PriceInfoObject>, ctx: &mut TxContext) {
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let mut i = 0;
        while (i < vector::length(&markets)) {
            let mref = *vector::borrow(&markets, i);
            let clk = *vector::borrow(&clocks, i);
            let p = *vector::borrow(&prices, i);
            if (Table::contains(&queue.requested_at_ms, &object::id(mref))) {
                let t = *Table::borrow(&queue.requested_at_ms, &object::id(mref));
                if (now >= t + queue.dispute_window_ms) {
                    expire_and_settle_market_cash(reg, mref, oracle_cfg, clk, p, ctx);
                    // Remove from queue
                    Table::remove(&mut queue.requested_at_ms, object::id(mref));
                }
            };
            i = i + 1;
        }
        // Rebuild pending vector excluding already processed
        let mut new_pending = vector::empty<ID>();
        let mut j = 0; while (j < vector::length(&queue.pending)) { let mid = *vector::borrow(&queue.pending, j); if (Table::contains(&queue.requested_at_ms, &mid)) { vector::push_back(&mut new_pending, mid); }; j = j + 1; };
        queue.pending = new_pending;
    }

    /*******************************
    * Early/manual exercise (American)
    *******************************/
    public entry fun exercise_american_now<C>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        quantity: u64,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.exercise_style == b"AMERICAN".to_string(), E_PAUSED);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        // Oracle feed enforcement
        let pi = PriceInfo::get_price_info_from_price_info_object(price_info);
        let feed_id = price_identifier::get_bytes(&PriceInfo::get_price_identifier(&pi));
        let ua = Table::borrow(&reg.supported_underlyings, &market.underlying);
        assert!(feed_id == ua.oracle_feed, E_BAD_PARAMS);
        let spot = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        let mut payout = 0u64;
        if (long_pos.option_type == b"CALL".to_string()) {
            if (spot > market.strike_price) { payout = (spot - market.strike_price) * quantity; }
        } else {
            if (market.strike_price > spot) { payout = (market.strike_price - spot) * quantity; }
        };
        let fee_bps = if market.settlement_fee_bps_override > 0 { market.settlement_fee_bps_override } else { reg.settlement_fee_bps };
        let fee = (payout * fee_bps) / 10_000;
        let net_to_long = if (payout > fee) { payout - fee } else { 0 };
        let mut to_long = Coin::zero<C>(ctx);
        if (net_to_long > 0) { let p = Coin::split(&mut short_pos.collateral_locked, net_to_long, ctx); Coin::merge(&mut to_long, p); }
        transfer::public_transfer(to_long, long_pos.owner);
        if (fee > 0) {
            let fee_coin = Coin::split(&mut short_pos.collateral_locked, fee, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"options_exercise".to_string(), ctx.sender(), ctx);
        }
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; }
        // Decrement user OI for long owner
        if (Table::contains(&market.user_open_interest, &long_pos.owner)) {
            let cur = *Table::borrow(&market.user_open_interest, &long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            Table::insert(&mut market.user_open_interest, long_pos.owner, newv);
        }
        event::emit(EarlyExercised { market_id: object::id(market), long_owner: long_pos.owner, short_owner: short_pos.owner, quantity, payout_to_long: net_to_long, fee_paid: fee, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Pre‑expiry close/offset with fee; refunds short margin proportionally
    *******************************/
    public entry fun close_positions_by_premium<C>(
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
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        assert!(premium_per_unit % market.tick_size == 0 && quantity % market.contract_size == 0, E_BAD_PARAMS);
        let premium_total = quantity * premium_per_unit;
        let trade_fee_bps = if market.trade_fee_bps_override > 0 { market.trade_fee_bps_override } else { reg.trade_fee_bps };
        let taker_fee = (premium_total * trade_fee_bps) / 10_000;
        let maker_rebate = (taker_fee * reg.maker_rebate_bps_close) / 10_000;
        let fee_to_collect = taker_fee;
        let net_amount = if (premium_total > fee_to_collect) { premium_total - fee_to_collect } else { 0 };
        if (payer_is_long) {
            // Long pays short to close; transfer net to short and fee to treasury
            if (net_amount > 0) { let to_short = Coin::split(&mut usdc, net_amount, ctx); transfer::public_transfer(to_short, short_pos.owner); }
            if (fee_to_collect > 0) { let mut fee_all = Coin::split(&mut usdc, fee_to_collect, ctx); if (maker_rebate > 0 && maker_rebate < fee_to_collect) { let to_maker = Coin::split(&mut fee_all, maker_rebate, ctx); transfer::public_transfer(to_maker, short_pos.owner); } let bot_cut = (Coin::value(&fee_all) * reg.close_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bots = Coin::split(&mut fee_all, bot_cut, ctx); TreasuryMod::deposit_collateral(treasury, to_bots, b"options_close_bot".to_string(), long_pos.owner, ctx); } TreasuryMod::deposit_collateral(treasury, fee_all, b"options_close".to_string(), long_pos.owner, ctx); }
        } else {
            // Short pays long to close (buy-back)
            if (net_amount > 0) { let to_long = Coin::split(&mut usdc, net_amount, ctx); transfer::public_transfer(to_long, long_pos.owner); }
            if (fee_to_collect > 0) { let mut fee_all = Coin::split(&mut usdc, fee_to_collect, ctx); if (maker_rebate > 0 && maker_rebate < fee_to_collect) { let to_maker = Coin::split(&mut fee_all, maker_rebate, ctx); transfer::public_transfer(to_maker, long_pos.owner); } let bot_cut = (Coin::value(&fee_all) * reg.close_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bots = Coin::split(&mut fee_all, bot_cut, ctx); TreasuryMod::deposit_collateral(treasury, to_bots, b"options_close_bot".to_string(), short_pos.owner, ctx); } TreasuryMod::deposit_collateral(treasury, fee_all, b"options_close".to_string(), short_pos.owner, ctx); }
        }
        // Refund proportional initial margin to short for closed quantity
        let notional = quantity * market.strike_price;
        let refund = (notional * market.init_margin_bps_short) / 10_000;
        if (refund > 0) { let c = Coin::split(&mut short_pos.collateral_locked, refund, ctx); transfer::public_transfer(c, short_pos.owner); }
        // Update positions and market OI
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; }
        if (Table::contains(&market.user_open_interest, &long_pos.owner)) {
            let cur = *Table::borrow(&market.user_open_interest, &long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            Table::insert(&mut market.user_open_interest, long_pos.owner, newv);
        }
        // Refund any remainder of usdc source
        transfer::public_transfer(usdc, ctx.sender());
        event::emit(OptionClosed { market_id: object::id(market), closer: if (payer_is_long) { long_pos.owner } else { short_pos.owner }, counterparty: if (payer_is_long) { short_pos.owner } else { long_pos.owner }, quantity, premium_per_unit, fee_paid: fee_to_collect, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Liquidation: close pair at live price with penalty to liquidator
    *******************************/
    public entry fun liquidate_under_collateralized_pair(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition,
        short_pos: &mut OptionPosition,
        quantity: u64,
        liquidator: address,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        treasury: &mut Treasury,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= long_pos.quantity && quantity <= short_pos.quantity, E_AMOUNT);
        let pi = PriceInfo::get_price_info_from_price_info_object(price_info);
        let feed_id = price_identifier::get_bytes(&PriceInfo::get_price_identifier(&pi));
        let ua = Table::borrow(&reg.supported_underlyings, &market.underlying);
        assert!(feed_id == ua.oracle_feed, E_BAD_PARAMS);
        let spot = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        // Maintenance health
        let notional = quantity * market.strike_price;
        let maint_needed = (notional * market.maint_margin_bps_short) / 10_000;
        let cur_coll = Coin::value(&short_pos.collateral_locked);
        assert!(cur_coll < maint_needed, E_BAD_PARAMS);
        // Close at intrinsic
        let mut payout = 0u64;
        if (long_pos.option_type == b"CALL".to_string()) {
            if (spot > market.strike_price) { payout = (spot - market.strike_price) * quantity; }
        } else { if (market.strike_price > spot) { payout = (market.strike_price - spot) * quantity; } };
        let fee_bps = if market.settlement_fee_bps_override > 0 { market.settlement_fee_bps_override } else { reg.settlement_fee_bps };
        let fee = (payout * fee_bps) / 10_000;
        let net_to_long = if (payout > fee) { payout - fee } else { 0 };
        let mut to_long = Coin::zero<C>(ctx);
        if (net_to_long > 0) { let p = Coin::split(&mut short_pos.collateral_locked, net_to_long, ctx); Coin::merge(&mut to_long, p); }
        transfer::public_transfer(to_long, long_pos.owner);
        if (fee > 0) { let fc = Coin::split(&mut short_pos.collateral_locked, fee, ctx); TreasuryMod::deposit_collateral(treasury, fc, b"options_liquidation".to_string(), liquidator, ctx); }
        // Liquidator bonus from remaining collateral proportional to liq_penalty_bps
        let bonus = (Coin::value(&short_pos.collateral_locked) * reg.liq_penalty_bps) / 10_000;
        if (bonus > 0) { let b = Coin::split(&mut short_pos.collateral_locked, bonus, ctx); transfer::public_transfer(b, liquidator); }
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; }
        if (Table::contains(&market.user_open_interest, &long_pos.owner)) {
            let cur = *Table::borrow(&market.user_open_interest, &long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            Table::insert(&mut market.user_open_interest, long_pos.owner, newv);
        }
        event::emit(ShortLiquidated { market_id: object::id(market), short_owner: short_pos.owner, liquidator, quantity, collateral_seized: bonus, penalty_paid: bonus, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Physical settlement hooks (router stub)
    *******************************/
    // AutoSwap wrapper removed; physical settlement will create/cancel orders via dex.move off-chain orchestration

    /*******************************
    * Read‑only position helpers and health
    *******************************/
    public fun position_owner(pos: &OptionPosition): address { pos.owner }
    public fun position_market(pos: &OptionPosition): ID { pos.market_id }
    public fun position_info(pos: &OptionPosition): (u8, u64, u64, u64, u64) { (pos.side, pos.quantity, pos.premium_per_unit, pos.strike_price, pos.expiry_ms) }
    public fun short_health(short_pos: &OptionPosition, market: &OptionMarket): (u64, u64, bool) {
        let coll = Coin::value(&short_pos.collateral_locked);
        let maint = (short_pos.quantity * market.strike_price * market.maint_margin_bps_short) / 10_000;
        (coll, maint, coll >= maint)
    }

    fun market_key_bytes(underlying: &String, option_type: &String, strike: u64, expiry_ms: u64): vector<u8> {
        let mut out = vector::empty<u8>();
        let mut ub = underlying.clone().into_bytes();
        let mut tb = option_type.clone().into_bytes();
        // Append underlying bytes
        let mut i = 0; while (i < vector::length(&ub)) { vector::push_back(&mut out, *vector::borrow(&ub, i)); i = i + 1; };
        vector::push_back(&mut out, 0u8);
        // Append type bytes
        let mut j = 0; while (j < vector::length(&tb)) { vector::push_back(&mut out, *vector::borrow(&tb, j)); j = j + 1; };
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
    public entry fun init_market_display(publisher: &Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<OptionMarket>(publisher, ctx);
        disp.add(b"name".to_string(), b"Option Market {underlying} {option_type} {strike_price} @ {expiry_ms}".to_string());
        disp.add(b"description".to_string(), b"Unxversal Options market".to_string());
        disp.add(b"underlying".to_string(), b"{underlying}".to_string());
        disp.add(b"option_type".to_string(), b"{option_type}".to_string());
        disp.add(b"strike_price".to_string(), b"{strike_price}".to_string());
        disp.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());
    }

    public entry fun init_offer_and_position_displays(publisher: &Publisher, ctx: &mut TxContext) {
        let mut disp_offer = display::new<ShortOffer>(publisher, ctx);
        disp_offer.add(b"name".to_string(), b"Short Offer {option_type} {strike_price} exp {expiry_ms}".to_string());
        disp_offer.add(b"remaining_qty".to_string(), b"{remaining_qty}".to_string());
        disp_offer.add(b"min_premium_per_unit".to_string(), b"{min_premium_per_unit}".to_string());
        disp_offer.update_version();
        transfer::public_transfer(disp_offer, ctx.sender());

        let mut disp_esc = display::new<PremiumEscrow>(publisher, ctx);
        disp_esc.add(b"name".to_string(), b"Premium Escrow {option_type} {strike_price} exp {expiry_ms}".to_string());
        disp_esc.add(b"remaining_qty".to_string(), b"{remaining_qty}".to_string());
        disp_esc.add(b"premium_per_unit".to_string(), b"{premium_per_unit}".to_string());
        disp_esc.update_version();
        transfer::public_transfer(disp_esc, ctx.sender());

        let mut disp_pos = display::new<OptionPosition>(publisher, ctx);
        disp_pos.add(b"name".to_string(), b"Position {option_type} {strike_price} exp {expiry_ms}".to_string());
        disp_pos.add(b"side".to_string(), b"{side}".to_string());
        disp_pos.add(b"quantity".to_string(), b"{quantity}".to_string());
        disp_pos.add(b"premium_per_unit".to_string(), b"{premium_per_unit}".to_string());
        disp_pos.update_version();
        transfer::public_transfer(disp_pos, ctx.sender());
    }

    /*******************************
    * Read‑only helpers
    *******************************/
    public fun list_underlyings(reg: &OptionsRegistry): vector<String> { Table::keys(&reg.supported_underlyings) }
    public fun get_underlying(reg: &OptionsRegistry, symbol: &String): &UnderlyingAsset { Table::borrow(&reg.supported_underlyings, symbol) }
    public fun list_option_market_keys(reg: &OptionsRegistry): vector<vector<u8>> { Table::keys(&reg.option_markets) }
    public fun get_registry_treasury_id(reg: &OptionsRegistry): ID { reg.treasury_id }
    public fun get_market_by_key(reg: &OptionsRegistry, key: &vector<u8>): ID { *Table::borrow(&reg.option_markets, key) }

    /*******************************
    * Cash settlement at/after expiry (oracle normalized)
    *******************************/
    public entry fun expire_and_settle_market_cash(
        reg: &OptionsRegistry,
        market: &mut OptionMarket,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        ctx: &TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        // Allow settlement at or after expiry
        assert!(now >= market.expiry_ms, E_BAD_PARAMS);
        let pi = PriceInfo::get_price_info_from_price_info_object(price_info);
        let feed_id = price_identifier::get_bytes(&PriceInfo::get_price_identifier(&pi));
        let ua = Table::borrow(&reg.supported_underlyings, &market.underlying);
        assert!(feed_id == ua.oracle_feed, E_BAD_PARAMS);
        // Optional: add EMA/deviation checks here in future
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        market.settlement_price = px;
        market.settled_at_ms = now;
        market.is_expired = true;
        market.is_active = false;
        event::emit(OptionMarketSettled { market_id: object::id(market), underlying: market.underlying.clone(), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, settlement_price: px, timestamp: now });
    }

    /*******************************
    * OTC matching: Writer short offer and buyer premium escrow
    *******************************/
    public entry fun place_short_offer<C>(
        market: &OptionMarket,
        quantity: u64,
        min_premium_per_unit: u64,
        mut collateral: Coin<C>,
        ctx: &mut TxContext
    ): ShortOffer<C> {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(quantity > 0, E_AMOUNT);
        assert!(min_premium_per_unit > 0, E_PRICE);
        // Initial margin for shorts: notional * init_margin_bps_short
        let notional = quantity * market.strike_price;
        let needed = (notional * market.init_margin_bps_short) / 10_000;
        assert!(Coin::value(&collateral) >= needed, E_COLLATERAL);
        let locked = Coin::split(&mut collateral, needed, ctx);
        transfer::public_transfer(collateral, ctx.sender());
        ShortOffer<C> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, remaining_qty: quantity, min_premium_per_unit, collateral_locked: locked, created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx) }
    }

    /// Coin short offer for physical CALLs that deliver Base at exercise
    public entry fun place_coin_short_offer<Base>(
        market: &OptionMarket,
        quantity: u64,
        min_premium_per_unit: u64,
        mut base_in: Coin<Base>,
        ctx: &mut TxContext
    ): CoinShortOffer<Base> {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(market.option_type == b"CALL".to_string(), E_BAD_PARAMS);
        assert!(quantity > 0, E_AMOUNT);
        assert!(min_premium_per_unit > 0, E_PRICE);
        // Require exact quantity of underlying to be escrowed for delivery
        let have = Coin::value(&base_in);
        assert!(have >= quantity, E_COLLATERAL);
        let escrow = Coin::split(&mut base_in, quantity, ctx);
        transfer::public_transfer(base_in, ctx.sender());
        CoinShortOffer<Base> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, remaining_qty: quantity, min_premium_per_unit, escrow_base: escrow, created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx) }
    }

    public entry fun place_premium_escrow<C>(
        market: &OptionMarket,
        quantity: u64,
        premium_per_unit: u64,
        mut collateral: Coin<C>,
        expiry_cancel_ms: u64,
        ctx: &mut TxContext
    ): PremiumEscrow<C> {
        assert!(market.is_active && !market.is_expired, E_EXPIRED);
        assert!(quantity > 0, E_AMOUNT);
        assert!(premium_per_unit > 0, E_PRICE);
        let needed = quantity * premium_per_unit;
        assert!(Coin::value(&collateral) >= needed, E_PRICE);
        let escrow = Coin::split(&mut collateral, needed, ctx);
        transfer::public_transfer(collateral, ctx.sender());
        PremiumEscrow<C> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, remaining_qty: quantity, premium_per_unit, escrow_collateral: escrow, created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), expiry_cancel_ms }
    }

    public entry fun cancel_short_offer<C>(offer: ShortOffer<C>, ctx: &mut TxContext) {
        assert!(offer.owner == ctx.sender(), E_NOT_ADMIN);
        transfer::public_transfer(offer.collateral_locked, offer.owner);
        let ShortOffer<C> { id, owner: _, market_id: _, option_type: _, strike_price: _, expiry_ms: _, remaining_qty: _, min_premium_per_unit: _, collateral_locked: _, created_at_ms: _ } = offer;
        object::delete(id);
    }

    public entry fun cancel_coin_short_offer<Base>(offer: CoinShortOffer<Base>, ctx: &mut TxContext) {
        assert!(offer.owner == ctx.sender(), E_NOT_ADMIN);
        transfer::public_transfer(offer.escrow_base, offer.owner);
        let CoinShortOffer<Base> { id, owner: _, market_id: _, option_type: _, strike_price: _, expiry_ms: _, remaining_qty: _, min_premium_per_unit: _, escrow_base: _, created_at_ms: _ } = offer;
        object::delete(id);
    }

    public entry fun cancel_premium_escrow<C>(esc: PremiumEscrow<C>, ctx: &mut TxContext) {
        assert!(esc.owner == ctx.sender(), E_NOT_ADMIN);
        assert!(sui::tx_context::epoch_timestamp_ms(ctx) >= esc.expiry_cancel_ms, E_BAD_PARAMS);
        transfer::public_transfer(esc.escrow_collateral, esc.owner);
        let PremiumEscrow<C> { id, owner: _, market_id: _, option_type: _, strike_price: _, expiry_ms: _, remaining_qty: _, premium_per_unit: _, escrow_collateral: _, created_at_ms: _, expiry_cancel_ms: _ } = esc;
        object::delete(id);
    }

    public entry fun match_offer_and_escrow<C>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        mut offer: ShortOffer<C>,
        mut escrow: PremiumEscrow<C>,
        max_fill_qty: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        treasury: &mut Treasury<C>,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        unxv_price: &PriceInfoObject,
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
            let a = if offer.remaining_qty < escrow.remaining_qty { offer.remaining_qty } else { escrow.remaining_qty };
            if (a < max_fill_qty) { a } else { max_fill_qty }
        };
        assert!(fill > 0, E_AMOUNT);
        assert!(fill % market.contract_size == 0, E_BAD_PARAMS);
        // Per-market/user caps
        if (market.max_open_contracts_market > 0) { assert!(market.total_open_interest + fill <= market.max_open_contracts_market, E_BAD_PARAMS); }
        if (market.max_oi_per_user > 0) {
            let cur = if Table::contains(&market.user_open_interest, &escrow.owner) { *Table::borrow(&market.user_open_interest, &escrow.owner) } else { 0 };
            assert!(cur + fill <= market.max_oi_per_user, E_BAD_PARAMS);
        }

        // Premium owed
        let premium_total = fill * escrow.premium_per_unit;
        let trade_fee_bps = if market.trade_fee_bps_override > 0 { market.trade_fee_bps_override } else { reg.trade_fee_bps };
        let trade_fee = (premium_total * trade_fee_bps) / 10_000;
        let discount_collateral = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_collateral > 0 && vector::length(&unxv_payment) > 0) {
            let unxv_px = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (unxv_px > 0) {
                let unxv_needed = (discount_collateral + unxv_px - 1) / unxv_px;
                let mut merged = Coin::zero<UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); Coin::merge(&mut merged, c); i = i + 1; };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"options_premium_trade".to_string(), escrow.owner, ctx);
                    transfer::public_transfer(merged, escrow.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, escrow.owner);
                }
            }
        }
        let fee_to_collect = if (discount_applied) { if trade_fee > discount_collateral { trade_fee - discount_collateral } else { 0 } } else { trade_fee };

        // Move premium net of fee to writer, pay fee to treasury
        let net_to_writer = if (premium_total > fee_to_collect) { premium_total - fee_to_collect } else { 0 };
        if (net_to_writer > 0) {
            let to_writer = Coin::split(&mut escrow.escrow_collateral, net_to_writer, ctx);
            transfer::public_transfer(to_writer, offer.owner);
        }
        if (fee_to_collect > 0) {
            let fee_coin = Coin::split(&mut escrow.escrow_collateral, fee_to_collect, ctx);
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"options_premium_trade".to_string(), escrow.owner, ctx);
        }

        // Create positions
        let long_pos = OptionPosition<C> { id: object::new(ctx), owner: escrow.owner, market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 0, quantity: fill, premium_per_unit: escrow.premium_per_unit, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: Coin::zero<C>(ctx) };
        // Move proportional initial margin from offer to short position
        let notional_fill = fill * market.strike_price;
        let short_needed = (notional_fill * market.init_margin_bps_short) / 10_000;
        let short_locked = Coin::split(&mut offer.collateral_locked, short_needed, ctx);
        let short_pos = OptionPosition<C> { id: object::new(ctx), owner: offer.owner, market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 1, quantity: fill, premium_per_unit: 0, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: short_locked };
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
        let cur_buyer = if Table::contains(&market.user_open_interest, &escrow.owner) { *Table::borrow(&market.user_open_interest, &escrow.owner) } else { 0 };
        Table::insert(&mut market.user_open_interest, escrow.owner, cur_buyer + fill);
        event::emit(OptionMatched { market_id: object::id(market), buyer: escrow.owner, writer: offer.owner, option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, quantity: fill, premium_per_unit: escrow.premium_per_unit, fee_paid: fee_to_collect, unxv_discount_applied: discount_applied, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(OptionOpened { market_id: object::id(market), buyer: escrow.owner, writer: offer.owner, quantity: fill, premium_per_unit: escrow.premium_per_unit, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Match coin-escrowed CALL offer with premium escrow (physical delivery on exercise)
    public entry fun match_coin_offer_and_escrow<Base, C>(
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        mut offer: CoinShortOffer<Base>,
        mut escrow: PremiumEscrow<C>,
        max_fill_qty: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(offer.market_id == object::id(market) && escrow.market_id == object::id(market), E_MISMATCH);
        assert!(market.is_active && !market.is_expired && !market.paused, E_EXPIRED);
        assert!(market.option_type == b"CALL".to_string(), E_BAD_PARAMS);
        assert!(market.settlement_type == b"PHYSICAL".to_string() || market.settlement_type == b"BOTH".to_string(), E_BAD_PARAMS);
        assert!(escrow.premium_per_unit % market.tick_size == 0, E_PRICE);
        assert!(offer.remaining_qty % market.contract_size == 0 && escrow.remaining_qty % market.contract_size == 0, E_BAD_PARAMS);
        assert!(escrow.premium_per_unit >= offer.min_premium_per_unit, E_PRICE);
        let fill = { let a = if offer.remaining_qty < escrow.remaining_qty { offer.remaining_qty } else { escrow.remaining_qty }; if (a < max_fill_qty) { a } else { max_fill_qty } };
        assert!(fill > 0 && fill % market.contract_size == 0, E_AMOUNT);
        if (market.max_open_contracts_market > 0) { assert!(market.total_open_interest + fill <= market.max_open_contracts_market, E_BAD_PARAMS); }
        if (market.max_oi_per_user > 0) { let cur = if Table::contains(&market.user_open_interest, &escrow.owner) { *Table::borrow(&market.user_open_interest, &escrow.owner) } else { 0 }; assert!(cur + fill <= market.max_oi_per_user, E_BAD_PARAMS); }
        // Premium payment (no UNXV path here for brevity; can be added like match_offer_and_escrow)
        let collateral_owed = fill * escrow.premium_per_unit;
        let to_writer = Coin::split(&mut escrow.escrow_collateral, collateral_owed, ctx);
        transfer::public_transfer(to_writer, offer.owner);
        // Create positions: long receives standard long position; short remains coin-escrowed upon exercise
        let long_pos = OptionPosition<C> { id: object::new(ctx), owner: escrow.owner, market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 0, quantity: fill, premium_per_unit: escrow.premium_per_unit, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: Coin::zero<C>(ctx) };
        // Lock proportional base into a separate escrow tied to this short position ID
        let short_pos_id = object::new(ctx);
        let short_split = Coin::split(&mut offer.escrow_base, fill, ctx);
        let short_pos = OptionPosition<C> { id: short_pos_id, owner: offer.owner, market_id: object::id(market), option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, side: 1, quantity: fill, premium_per_unit: 0, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx), collateral_locked: Coin::zero<C>(ctx) };
        let escrow_obj = ShortUnderlyingEscrow<Base> { id: object::new(ctx), position_id: object::id(&short_pos), escrow_base: short_split };
        transfer::share_object(long_pos);
        transfer::share_object(short_pos);
        transfer::share_object(escrow_obj);
        // Update remaining
        offer.remaining_qty = offer.remaining_qty - fill;
        escrow.remaining_qty = escrow.remaining_qty - fill;
        market.total_open_interest = market.total_open_interest + fill;
        let cur_buyer = if Table::contains(&market.user_open_interest, &escrow.owner) { *Table::borrow(&market.user_open_interest, &escrow.owner) } else { 0 };
        Table::insert(&mut market.user_open_interest, escrow.owner, cur_buyer + fill);
        event::emit(OptionMatched { market_id: object::id(market), buyer: escrow.owner, writer: offer.owner, option_type: market.option_type.clone(), strike_price: market.strike_price, expiry_ms: market.expiry_ms, quantity: fill, premium_per_unit: escrow.premium_per_unit, fee_paid: 0, unxv_discount_applied: false, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(OptionOpened { market_id: object::id(market), buyer: escrow.owner, writer: offer.owner, quantity: fill, premium_per_unit: escrow.premium_per_unit, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Settle a matched long/short pair after market settlement (cash)
    *******************************/
    public entry fun settle_positions_cash<C>(
        reg: &mut OptionsRegistry,
        market: &OptionMarket,
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
        let fee_bps = if market.settlement_fee_bps_override > 0 { market.settlement_fee_bps_override } else { reg.settlement_fee_bps };
        let fee = (payout * fee_bps) / 10_000;
        let net_to_long = if (payout > fee) { payout - fee } else { 0 };

        // Maintenance margin check and liquidation path if undercollateralized
        let notional = quantity * market.strike_price;
        let maint_needed = (notional * market.maint_margin_bps_short) / 10_000;
        let cur_coll = Coin::value(&short_pos.collateral_locked);
        if (cur_coll < maint_needed) {
            event::emit(MarginCallTriggered { short_owner: short_pos.owner, market_id: object::id(market), required_collateral: maint_needed, current_collateral: cur_coll, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        }

        // Pay long from short collateral
        let mut to_long = Coin::zero<C>(ctx);
        if (net_to_long > 0) { let p = Coin::split(&mut short_pos.collateral_locked, net_to_long, ctx); Coin::merge(&mut to_long, p); }
        transfer::public_transfer(to_long, long_pos.owner);

        if (fee > 0) {
            let mut fee_coin = Coin::split(&mut short_pos.collateral_locked, fee, ctx);
            let bot_cut = (Coin::value(&fee_coin) * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let bot_coin = Coin::split(&mut fee_coin, bot_cut, ctx); TreasuryMod::deposit_collateral(treasury, bot_coin, b"options_settlement_bot".to_string(), ctx.sender(), ctx); }
            TreasuryMod::deposit_collateral(treasury, fee_coin, b"options_settlement".to_string(), ctx.sender(), ctx);
        }

        // Return remaining proportional collateral to short when fully settled externally (not handled here)
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (Table::contains(&market.user_open_interest, &long_pos.owner)) {
            let cur = *Table::borrow(&market.user_open_interest, &long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            Table::insert(&mut market.user_open_interest, long_pos.owner, newv);
        }

        event::emit(OptionSettled { market_id: object::id(market), long_owner: long_pos.owner, short_owner: short_pos.owner, option_type: long_pos.option_type.clone(), strike_price: long_pos.strike_price, expiry_ms: long_pos.expiry_ms, quantity, settlement_price: market.settlement_price, payout_to_long: net_to_long, fee_paid: fee, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Physical exercise for coin-escrowed CALLs
    *******************************/
    public entry fun exercise_physical_call<Base>(
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition,
        short_pos: &mut OptionPosition,
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
        let deliver = Coin::split(&mut escrow.escrow_base, quantity, ctx);
        transfer::public_transfer(deliver, long_pos.owner);
        // Update positions and OI
        long_pos.quantity = long_pos.quantity - quantity;
        short_pos.quantity = short_pos.quantity - quantity;
        if (market.total_open_interest >= quantity) { market.total_open_interest = market.total_open_interest - quantity; }
        if (Table::contains(&market.user_open_interest, &long_pos.owner)) {
            let cur = *Table::borrow(&market.user_open_interest, &long_pos.owner);
            let newv = if (cur > quantity) { cur - quantity } else { 0 };
            Table::insert(&mut market.user_open_interest, long_pos.owner, newv);
        }
        // If escrow empty, delete it
        if (Coin::value(&escrow.escrow_base) == 0) {
            let ShortUnderlyingEscrow<Base> { id, position_id: _, escrow_base: _ } = *escrow;
            object::delete(id);
        }
    }

    public entry fun emit_physical_delivery_completed(
        market: &OptionMarket,
        side: u8,
        quantity: u64,
        avg_settlement_price: u64,
        ctx: &TxContext
    ) { event::emit(PhysicalDeliveryCompleted { market_id: object::id(market), fulfiller: ctx.sender(), side, quantity, avg_settlement_price, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    /*******************************
    * Physical settlement intent events (bot-driven orchestration)
    *******************************/
    public entry fun request_physical_delivery_long(
        market: &OptionMarket,
        long_pos: &OptionPosition,
        quantity: u64,
        min_settlement_price: u64,
        ctx: &TxContext
    ) { assert!(quantity > 0 && quantity <= long_pos.quantity, E_AMOUNT); event::emit(PhysicalDeliveryRequested { market_id: object::id(market), requester: long_pos.owner, side: 0, quantity, min_settlement_price, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    public entry fun request_physical_delivery_short(
        market: &OptionMarket,
        short_pos: &OptionPosition,
        quantity: u64,
        min_settlement_price: u64,
        ctx: &TxContext
    ) { assert!(quantity > 0 && quantity <= short_pos.quantity, E_AMOUNT); event::emit(PhysicalDeliveryRequested { market_id: object::id(market), requester: short_pos.owner, side: 1, quantity, min_settlement_price, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }
}


