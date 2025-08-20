#[allow(lint(public_entry))]
module unxversal::perpetuals {
    /*******************************
    * Unxversal Perpetuals – orderbook-integrated, funding-based perps
    * - Off-chain matching; on-chain fills, margin, liquidation, funding accrual
    * - Fees to central treasury with UNXV discount, maker rebate, bot splits
    *******************************/

    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::String;
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};

    use unxversal::oracle::{OracleConfig, OracleRegistry, get_price_for_symbol}; // bound prices in micro-USD
    use switchboard::aggregator::Aggregator;
    use unxversal::treasury::{Self as TreasuryMod, Treasury, BotRewardsTreasury};
    // Removed AdminCap/SynthRegistry dependency; centralize on AdminRegistry
    use sui::table::{Self as table, Table};
    use unxversal::bot_rewards::{Self as BotRewards, BotPointsRegistry};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_MIN_INTERVAL: u64 = 3;
    const E_BAD_BOUNDS: u64 = 4;

    // Admin gating centralized to AdminRegistry variants

    // String helpers (clone semantics)
    fun clone_string(s: &String): String {
        let bytes = std::string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(bytes);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(bytes, i)); i = i + 1; };
        std::string::utf8(out)
    }

    /*******************************
    * Signed value utility – store sign + magnitude
    *******************************/
    public struct Signed has copy, drop, store {
        is_positive: bool,
        magnitude: u64,
    }

    fun signed_zero(): Signed { Signed { is_positive: true, magnitude: 0 } }

    fun add_signed_in_place(base: &mut Signed, delta: &Signed) {
        if (base.is_positive == delta.is_positive) {
            base.magnitude = base.magnitude + delta.magnitude;
        } else {
            if (base.magnitude >= delta.magnitude) {
                base.magnitude = base.magnitude - delta.magnitude;
            } else {
                base.magnitude = delta.magnitude - base.magnitude;
                base.is_positive = delta.is_positive;
            }
        }
    }

    fun from_diff_u64(a: u64, b: u64): Signed {
        if (a >= b) { Signed { is_positive: true, magnitude: a - b } } else { Signed { is_positive: false, magnitude: b - a } }
    }

    /*******************************
    * Registry
    *******************************/
    public struct PerpsRegistry has key, store {
        id: UID,
        paused: bool,
        markets: Table<String, ID>,
        price_feeds: Table<String, ID>,
        // Trade fee stack
        trade_fee_bps: u64,
        maker_rebate_bps: u64,
        unxv_discount_bps: u64,
        trade_bot_reward_bps: u64,
        // Funding config
        funding_interval_ms: u64,
        max_funding_rate_bps: u64,     // cap per interval (sign handled separately)
        premium_weight_bps: u64,       // scales premium into funding
        // Margin defaults
        default_init_margin_bps: u64,
        default_maint_margin_bps: u64,
        // Ops
        min_list_interval_ms: u64,
        last_list_ms: Table<String, u64>,
        treasury_id: ID,
    }

    /*******************************
    * Market (shared)
    *******************************/
    public struct PerpMarket has key, store {
        id: UID,
        symbol: String,
        underlying: String,
        tick_size_micro_usd: u64,
        paused: bool,
        // Funding state
        last_funding_ms: u64,
        funding_rate_bps: u64,
        funding_rate_longs_pay: bool,  // true => longs pay shorts
        // Margins
        init_margin_bps: u64,
        maint_margin_bps: u64,
        // Metrics
        open_interest: u64,
        volume_premium: u64,
        last_trade_price_micro_usd: u64,
    }

    /*******************************
    * Position (owned)
    *******************************/
    public struct PerpPosition<phantom C> has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        side: u8,                            // 0 long, 1 short
        size: u64,                           // in units
        avg_entry_price_micro_usd: u64,
        margin: Balance<C>,
        accumulated_pnl: Signed,             // includes funding accruals (signed)
        last_funding_ms: u64,
    }

    /*******************************
    * Events
    *******************************/
    public struct PerpMarketListed has copy, drop { symbol: String, underlying: String, tick: u64, timestamp: u64 }
    public struct PerpFillRecorded has copy, drop { symbol: String, price: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_paid: u64, unxv_discount_applied: bool, maker_rebate: u64, bot_reward: u64, timestamp: u64 }
    public struct PerpPositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price: u64, margin_locked: u64, sponsor: address, timestamp: u64 }
    public struct PerpPositionClosed has copy, drop { symbol: String, account: address, qty: u64, price: u64, margin_refund: u64, timestamp: u64 }
    public struct PerpVariationMargin has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta_positive: bool, pnl_delta_abs: u64, new_margin: u64, timestamp: u64 }
    public struct PerpFundingApplied has copy, drop { symbol: String, account: address, funding_delta_positive: bool, funding_delta_abs: u64, new_pnl_positive: bool, new_pnl_abs: u64, timestamp: u64 }
    public struct PerpMarginCall has copy, drop { symbol: String, account: address, equity_positive: bool, equity_abs: u128, maint_required: u64, timestamp: u64 }
    public struct PerpLiquidated has copy, drop { symbol: String, account: address, size: u64, price: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    // Removed PerpPausedToggled (unused event)

    /*******************************
    * Init & Admin
    *******************************/
    public entry fun init_perps_registry_admin(reg_admin: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let reg = PerpsRegistry {
            id: object::new(ctx),
            paused: false,
            markets: table::new<String, ID>(ctx),
            price_feeds: table::new<String, ID>(ctx),
            trade_fee_bps: 30,
            maker_rebate_bps: 100,
            unxv_discount_bps: 0,
            trade_bot_reward_bps: 0,
            funding_interval_ms: 28_800_000, // 8h
            max_funding_rate_bps: 100,       // 1% per interval cap
            premium_weight_bps: 100,
            default_init_margin_bps: 1_000,
            default_maint_margin_bps: 600,
            min_list_interval_ms: 60_000,
            last_list_ms: table::new<String, u64>(ctx),
            treasury_id: object::id_from_address(ctx.sender()),
        };
        transfer::public_share_object(reg);
    }

    /// Whitelist an underlying's index price feed (admin via SynthRegistry)
    public entry fun whitelist_underlying_feed_admin(
        reg_admin: &AdminRegistry,
        reg: &mut PerpsRegistry,
        underlying: String,
        agg: &Aggregator,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        if (table::contains(&reg.price_feeds, clone_string(&underlying))) { let _ = table::remove(&mut reg.price_feeds, clone_string(&underlying)); };
        table::add(&mut reg.price_feeds, underlying, object::id(agg));
    }

    /// AdminRegistry-gated variants (migration bridge)
    public entry fun set_trade_fee_config_admin(
        reg_admin: &AdminRegistry,
        reg: &mut PerpsRegistry,
        trade_fee_bps: u64,
        maker_rebate_bps: u64,
        unxv_discount_bps: u64,
        trade_bot_reward_bps: u64,
        ctx: &TxContext
    ) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); reg.trade_fee_bps = trade_fee_bps; reg.maker_rebate_bps = maker_rebate_bps; reg.unxv_discount_bps = unxv_discount_bps; reg.trade_bot_reward_bps = trade_bot_reward_bps; }

    public entry fun set_funding_params_admin(
        reg_admin: &AdminRegistry,
        reg: &mut PerpsRegistry,
        funding_interval_ms: u64,
        max_funding_rate_bps: u64,
        premium_weight_bps: u64,
        ctx: &TxContext
    ) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); reg.funding_interval_ms = funding_interval_ms; reg.max_funding_rate_bps = max_funding_rate_bps; reg.premium_weight_bps = premium_weight_bps; }

    public entry fun set_margin_defaults_admin(
        reg_admin: &AdminRegistry,
        reg: &mut PerpsRegistry,
        init_bps: u64,
        maint_bps: u64,
        ctx: &TxContext
    ) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); reg.default_init_margin_bps = init_bps; reg.default_maint_margin_bps = maint_bps; }

    public entry fun set_treasury_admin<C>(reg_admin: &AdminRegistry, reg: &mut PerpsRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); reg.treasury_id = object::id(treasury); }

    public entry fun pause_registry_admin(reg_admin: &AdminRegistry, reg: &mut PerpsRegistry, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); reg.paused = true; }
    public entry fun resume_registry_admin(reg_admin: &AdminRegistry, reg: &mut PerpsRegistry, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); reg.paused = false; }

    

    

    

    

    /*******************************
    * Listing (permissionless with cooldown)
    *******************************/
    public entry fun list_market(reg: &mut PerpsRegistry, underlying: String, symbol: String, tick_size_micro_usd: u64, init_margin_bps: u64, maint_margin_bps: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let last = if (table::contains(&reg.last_list_ms, clone_string(&symbol))) { *table::borrow(&reg.last_list_ms, clone_string(&symbol)) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        table::add(&mut reg.last_list_ms, clone_string(&symbol), now);

        let sym_for_market = clone_string(&symbol);
        let underlying_for_event = clone_string(&underlying);
        let m = PerpMarket {
            id: object::new(ctx),
            symbol: sym_for_market,
            underlying: underlying,
            tick_size_micro_usd: tick_size_micro_usd,
            paused: false,
            last_funding_ms: now,
            funding_rate_bps: 0,
            funding_rate_longs_pay: false,
            init_margin_bps: if (init_margin_bps > 0) { init_margin_bps } else { reg.default_init_margin_bps },
            maint_margin_bps: if (maint_margin_bps > 0) { maint_margin_bps } else { reg.default_maint_margin_bps },
            open_interest: 0,
            volume_premium: 0,
            last_trade_price_micro_usd: 0,
        };
        let id = object::id(&m);
        transfer::share_object(m);
        table::add(&mut reg.markets, clone_string(&symbol), id);
        event::emit(PerpMarketListed { symbol, underlying: underlying_for_event, tick: tick_size_micro_usd, timestamp: now });
    }

    

    /*******************************
    * Fills (off-chain matching)
    *******************************/
    public entry fun record_fill<C>(
        reg: &mut PerpsRegistry,
        market: &mut PerpMarket,
        price_micro_usd: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        unxv_usd_price: &Aggregator,
        oracle_reg: &OracleRegistry,
        _oracle_cfg: &OracleConfig,
        clock: &Clock,
        mut fee_payment: Coin<C>,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        assert!(price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        assert!(price_micro_usd >= min_price && price_micro_usd <= max_price, E_BAD_BOUNDS);
        let notional_u128: u128 = (size as u128) * (price_micro_usd as u128);
        let trade_fee_u128: u128 = (notional_u128 * (reg.trade_fee_bps as u128)) / 10_000u128;
        let discount_usdc_u128: u128 = (trade_fee_u128 * (reg.unxv_discount_bps as u128)) / 10_000u128;
        let mut discount_applied = false;
        if (discount_usdc_u128 > 0 && vector::length(&unxv_payment) > 0) {
            let unxv_px_u64 = get_price_for_symbol(oracle_reg, clock, &b"UNXV".to_string(), unxv_usd_price);
            if (unxv_px_u64 > 0) {
                let px: u128 = unxv_px_u64 as u128;
                let unxv_needed_u128 = (discount_usdc_u128 + px - 1) / px;
                let unxv_needed = if (unxv_needed_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { unxv_needed_u128 as u64 };
                let mut merged = coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<unxversal::unxv::UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    let epoch_id = BotRewards::current_epoch(points, clock);
                    TreasuryMod::deposit_unxv_with_rewards_for_epoch(treasury, bot_treasury, epoch_id, vecu, b"perp_trade".to_string(), ctx.sender(), ctx);
                    transfer::public_transfer(merged, ctx.sender());
                    discount_applied = true;
                } else { transfer::public_transfer(merged, ctx.sender()); }
            }
        };
        let collateral_fee_after_discount_u128: u128 = if (discount_applied) { if (discount_usdc_u128 <= trade_fee_u128) { trade_fee_u128 - discount_usdc_u128 } else { 0 } } else { trade_fee_u128 };
        let maker_rebate_u128: u128 = (trade_fee_u128 * (reg.maker_rebate_bps as u128)) / 10_000u128;
        let collateral_fee_after_discount = if (collateral_fee_after_discount_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { collateral_fee_after_discount_u128 as u64 };
        let maker_rebate = if (maker_rebate_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { maker_rebate_u128 as u64 };
        if (collateral_fee_after_discount > 0) {
            let have = coin::value(&fee_payment);
            assert!(have >= collateral_fee_after_discount, E_MIN_INTERVAL);
            if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) {
                let to_maker = coin::split(&mut fee_payment, maker_rebate, ctx);
                transfer::public_transfer(to_maker, maker);
            };
            if (reg.trade_bot_reward_bps > 0) {
                let bot_cut = (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000;
                if (bot_cut > 0) { let to_bot = coin::split(&mut fee_payment, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); }
            };
            let epoch_id2 = BotRewards::current_epoch(points, clock);
            TreasuryMod::deposit_collateral_with_rewards_for_epoch(treasury, bot_treasury, epoch_id2, fee_payment, b"perp_trade".to_string(), ctx.sender(), ctx);
        } else {
            transfer::public_transfer(fee_payment, ctx.sender());
        };
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; } };
        let notional = if (notional_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { notional_u128 as u64 };
        market.volume_premium = market.volume_premium + notional;
        market.last_trade_price_micro_usd = price_micro_usd;
        event::emit(PerpFillRecorded { symbol: clone_string(&market.symbol), price: price_micro_usd, size, taker: ctx.sender(), maker, taker_is_buyer, fee_paid: collateral_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate: maker_rebate, bot_reward: if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: sui::clock::timestamp_ms(clock) });
        // Ensure any remaining UNXV payment coins are refunded to the sender and the vector is consumed
        if (!vector::is_empty(&unxv_payment)) {
            let mut refund_unxv = coin::zero<unxversal::unxv::UNXV>(ctx);
            while (!vector::is_empty(&unxv_payment)) {
                let c = vector::pop_back(&mut unxv_payment);
                coin::join(&mut refund_unxv, c);
            };
            transfer::public_transfer(refund_unxv, ctx.sender());
        };
        vector::destroy_empty(unxv_payment);
    }

    /*******************************
    * Positions
    *******************************/
    public entry fun open_position<C>(market: &mut PerpMarket, side: u8, size: u64, entry_price_micro_usd: u64, mut margin: Coin<C>, clock: &Clock, ctx: &mut TxContext) {
        assert!(!market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        assert!(entry_price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        let notional = size * entry_price_micro_usd;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let exact = coin::split(&mut margin, init_req, ctx);
        let locked = coin::into_balance(exact);
        transfer::public_transfer(margin, ctx.sender());
        market.open_interest = market.open_interest + size;
        let pos = PerpPosition<C> { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), side, size, avg_entry_price_micro_usd: entry_price_micro_usd, margin: locked, accumulated_pnl: signed_zero(), last_funding_ms: market.last_funding_ms };
        let sponsor_addr = ctx.sender();
        event::emit(PerpPositionOpened { symbol: clone_string(&market.symbol), account: pos.owner, side, size, price: entry_price_micro_usd, margin_locked: balance::value(&pos.margin), sponsor: sponsor_addr, timestamp: sui::clock::timestamp_ms(clock) });
        transfer::share_object(pos);
    }

    public entry fun close_position<C>(reg: &PerpsRegistry, market: &mut PerpMarket, pos: &mut PerpPosition<C>, close_price_micro_usd: u64, quantity: u64, _treasury: &mut Treasury<C>, clock: &Clock, ctx: &mut TxContext) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        assert!(close_price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        let price_diff = from_diff_u64(close_price_micro_usd, pos.avg_entry_price_micro_usd);
        let pnl_delta = if (pos.side == 0) { price_diff } else { Signed { is_positive: !price_diff.is_positive, magnitude: price_diff.magnitude } };
        add_signed_in_place(&mut pos.accumulated_pnl, &pnl_delta);
        let total_margin = balance::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) { let out_bal = balance::split(&mut pos.margin, margin_refund); let out = coin::from_balance(out_bal, ctx); transfer::public_transfer(out, pos.owner); };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; };
        event::emit(PerpVariationMargin { symbol: clone_string(&market.symbol), account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_entry_price_micro_usd, to_price: close_price_micro_usd, pnl_delta_positive: pnl_delta.is_positive, pnl_delta_abs: pnl_delta.magnitude, new_margin: balance::value(&pos.margin), timestamp: sui::clock::timestamp_ms(clock) });
        event::emit(PerpPositionClosed { symbol: clone_string(&market.symbol), account: pos.owner, qty: quantity, price: close_price_micro_usd, margin_refund: margin_refund, timestamp: sui::clock::timestamp_ms(clock) });
    }

    /*******************************
    * Funding accrual (trustless, no paired transfers)
    *******************************/
    public entry fun apply_funding_for_position<C>(reg: &PerpsRegistry, market: &PerpMarket, pos: &mut PerpPosition<C>, oracle_reg: &OracleRegistry, index_price: &Aggregator, clock: &Clock) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let elapsed = if (now > pos.last_funding_ms) { now - pos.last_funding_ms } else { 0 };
        if (elapsed < reg.funding_interval_ms) { return };
        let index_price_micro_usd = get_price_for_symbol(oracle_reg, clock, &market.underlying, index_price);
        if (index_price_micro_usd == 0 || market.last_trade_price_micro_usd == 0) { return };
        if (pos.size == 0) { pos.last_funding_ms = now; return };
        // Use current market funding parameters (should be refreshed by a bot via refresh_market_funding)
        let rate_abs_u64 = market.funding_rate_bps;
        let notional = (pos.size as u128) * (index_price_micro_usd as u128);
        let delta_abs_u128 = (notional * (rate_abs_u64 as u128)) / 10_000u128;
        let delta_abs = if (delta_abs_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { delta_abs_u128 as u64 };
        let delta_for_long_is_negative = market.funding_rate_longs_pay;
        let funding_delta = if (pos.side == 0) { Signed { is_positive: !delta_for_long_is_negative, magnitude: delta_abs } } else { Signed { is_positive: delta_for_long_is_negative, magnitude: delta_abs } };
        add_signed_in_place(&mut pos.accumulated_pnl, &funding_delta);
        pos.last_funding_ms = now;
        event::emit(PerpFundingApplied { symbol: clone_string(&market.symbol), account: pos.owner, funding_delta_positive: funding_delta.is_positive, funding_delta_abs: funding_delta.magnitude, new_pnl_positive: pos.accumulated_pnl.is_positive, new_pnl_abs: pos.accumulated_pnl.magnitude, timestamp: now });
    }

    /// Refresh market funding rate and direction based on current premium vs index; called by bots periodically
    public entry fun refresh_market_funding(reg: &PerpsRegistry, market: &mut PerpMarket, oracle_reg: &OracleRegistry, index_price: &Aggregator, clock: &Clock) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let index_price_micro_usd = get_price_for_symbol(oracle_reg, clock, &market.underlying, index_price);
        if (index_price_micro_usd == 0 || market.last_trade_price_micro_usd == 0) { return };
        let mark = market.last_trade_price_micro_usd as u128;
        let idx = index_price_micro_usd as u128;
        let premium_pos = mark >= idx;
        let premium_abs = if (premium_pos) { ((mark - idx) * 10_000u128) / idx } else { ((idx - mark) * 10_000u128) / idx };
        let raw_rate_abs = (premium_abs * (reg.premium_weight_bps as u128)) / 10_000u128;
        let rate_abs_u64 = if (raw_rate_abs > (reg.max_funding_rate_bps as u128)) { reg.max_funding_rate_bps } else { raw_rate_abs as u64 };
        market.funding_rate_bps = rate_abs_u64;
        market.funding_rate_longs_pay = premium_pos;
        market.last_funding_ms = now;
    }

    /// Variant that awards points for non-fee maintenance
    public entry fun refresh_market_funding_with_points(
        reg: &PerpsRegistry,
        market: &mut PerpMarket,
        oracle_reg: &OracleRegistry,
        index_price: &Aggregator,
        points: &mut BotPointsRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        refresh_market_funding(reg, market, oracle_reg, index_price, clock);
        BotRewards::award_points(points, b"perps.refresh_market_funding".to_string(), ctx.sender(), clock, ctx);
    }

    /*******************************
    * Liquidation
    *******************************/
    public entry fun liquidate_position<C>(reg: &PerpsRegistry, market: &mut PerpMarket, pos: &mut PerpPosition<C>, mark_price_micro_usd: u64, treasury: &mut Treasury<C>, clock: &Clock, ctx: &mut TxContext) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(object::id(market) == pos.market_id, E_MIN_INTERVAL);
        let margin_val = balance::value(&pos.margin);
        let price_diff = from_diff_u64(mark_price_micro_usd, pos.avg_entry_price_micro_usd);
        let var_pnl = if (pos.side == 0) { price_diff } else { Signed { is_positive: !price_diff.is_positive, magnitude: price_diff.magnitude } };
        // equity = margin (+) accumulated_pnl (+) var_pnl
        let mut equity_signed = Signed { is_positive: true, magnitude: margin_val };
        add_signed_in_place(&mut equity_signed, &pos.accumulated_pnl);
        add_signed_in_place(&mut equity_signed, &var_pnl);
        let equity_abs_u128 = equity_signed.magnitude as u128;
        let notional = (pos.size as u128) * (mark_price_micro_usd as u128);
        let maint_req = ((notional * (market.maint_margin_bps as u128)) / 10_000) as u64;
        if (equity_signed.is_positive && (equity_abs_u128 >= (maint_req as u128))) { return };
        event::emit(PerpMarginCall { symbol: clone_string(&market.symbol), account: pos.owner, equity_positive: equity_signed.is_positive, equity_abs: equity_abs_u128, maint_required: maint_req, timestamp: sui::clock::timestamp_ms(clock) });
        let seized_total = balance::value(&pos.margin);
        if (seized_total > 0) {
            let seized_bal = balance::split(&mut pos.margin, seized_total);
            let mut seized = coin::from_balance(seized_bal, ctx);
            // Bot reward optional via trade_bot_reward_bps reuse (no separate field here)
            let bot_cut = (seized_total * reg.trade_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let to_bot = coin::split(&mut seized, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); };
            TreasuryMod::deposit_collateral_ext(treasury, seized, b"perp_liquidation".to_string(), ctx.sender(), ctx);
        };
        let qty = pos.size; pos.size = 0;
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; };
        event::emit(PerpLiquidated { symbol: clone_string(&market.symbol), account: pos.owner, size: qty, price: mark_price_micro_usd, seized_margin: seized_total, bot_reward: (seized_total * reg.trade_bot_reward_bps) / 10_000, timestamp: sui::clock::timestamp_ms(clock) });
    }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun market_id(reg: &PerpsRegistry, symbol: &String): ID { *table::borrow(&reg.markets, clone_string(symbol)) }
    public fun market_metrics(m: &PerpMarket): (u64, u64, u64, bool, u64) { (m.open_interest, m.volume_premium, m.last_trade_price_micro_usd, m.funding_rate_longs_pay, m.funding_rate_bps) }
    public fun position_info<C>(p: &PerpPosition<C>): (address, ID, u8, u64, u64, u64, bool, u64, u64) { (p.owner, p.market_id, p.side, p.size, p.avg_entry_price_micro_usd, balance::value(&p.margin), p.accumulated_pnl.is_positive, p.accumulated_pnl.magnitude, p.last_funding_ms) }
    public fun registry_trade_fee_params(reg: &PerpsRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun registry_funding_params(reg: &PerpsRegistry): (u64, u64, u64) { (reg.funding_interval_ms, reg.max_funding_rate_bps, reg.premium_weight_bps) }
    public fun registry_margin_defaults(reg: &PerpsRegistry): (u64, u64) { (reg.default_init_margin_bps, reg.default_maint_margin_bps) }

    /*******************************
    * Displays
    *******************************/
    public entry fun init_perps_displays(publisher: &sui::package::Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<PerpMarket>(publisher, ctx);
        disp.add(b"name".to_string(), b"Perp Market {symbol}".to_string());
        disp.add(b"description".to_string(), b"Unxversal Perpetual Market".to_string());
        disp.add(b"underlying".to_string(), b"{underlying}".to_string());
        disp.add(b"tick_size_micro_usd".to_string(), b"{tick_size_micro_usd}".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());

        let mut rdisp = display::new<PerpsRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Perpetuals Registry".to_string());
        rdisp.add(b"description".to_string(), b"Registry for perpetual markets and parameters".to_string());
        rdisp.update_version();
        transfer::public_transfer(rdisp, ctx.sender());
    }

    /*******************************
    * Test-only helpers
    *******************************/
    #[test_only]
    public fun new_position_for_testing<C>(
        owner: address,
        market: &PerpMarket,
        side: u8,
        size: u64,
        avg_entry_price_micro_usd: u64,
        mut margin: Coin<C>,
        required_margin: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (PerpPosition<C>, Coin<C>) {
        let exact = coin::split(&mut margin, required_margin, ctx);
        let locked = coin::into_balance(exact);
        let pos = PerpPosition<C> {
            id: object::new(ctx),
            owner,
            market_id: object::id(market),
            side,
            size,
            avg_entry_price_micro_usd,
            margin: locked,
            accumulated_pnl: signed_zero(),
            last_funding_ms: market.last_funding_ms
        };
        event::emit(PerpPositionOpened { symbol: clone_string(&market.symbol), account: owner, side, size, price: avg_entry_price_micro_usd, margin_locked: balance::value(&pos.margin), sponsor: owner, timestamp: sui::clock::timestamp_ms(clock) });
        (pos, margin)
    }

    #[test_only]
    public fun pause_market_for_testing(market: &mut PerpMarket, flag: bool) { market.paused = flag; }

    #[test_only]
    public struct PerpEventMirror has key, store {
        id: UID,
        fill_count: u64,
        last_fill_fee_paid: u64,
        last_fill_maker_rebate: u64,
        last_fill_discount_applied: bool,
        last_fill_bot_reward: u64,
        vm_count: u64,
        last_vm_qty: u64,
        last_vm_from: u64,
        last_vm_to: u64,
        last_margin_refund: u64,
        funding_count: u64,
        last_funding_delta_abs: u64,
        last_new_pnl_abs: u64,
        liq_count: u64,
        last_liq_price: u64,
        last_liq_seized: u64,
        last_liq_bot_reward: u64
    }

    #[test_only]
    public fun new_perp_event_mirror_for_testing(ctx: &mut TxContext): PerpEventMirror {
        PerpEventMirror { id: object::new(ctx), fill_count: 0, last_fill_fee_paid: 0, last_fill_maker_rebate: 0, last_fill_discount_applied: false, last_fill_bot_reward: 0, vm_count: 0, last_vm_qty: 0, last_vm_from: 0, last_vm_to: 0, last_margin_refund: 0, funding_count: 0, last_funding_delta_abs: 0, last_new_pnl_abs: 0, liq_count: 0, last_liq_price: 0, last_liq_seized: 0, last_liq_bot_reward: 0 }
    }

    #[test_only] public fun pem_fill_count(m: &PerpEventMirror): u64 { m.fill_count }
    #[test_only] public fun pem_last_fill_fee(m: &PerpEventMirror): u64 { m.last_fill_fee_paid }
    #[test_only] public fun pem_last_fill_rebate(m: &PerpEventMirror): u64 { m.last_fill_maker_rebate }
    #[test_only] public fun pem_last_fill_discount(m: &PerpEventMirror): bool { m.last_fill_discount_applied }
    #[test_only] public fun pem_last_fill_bot_reward(m: &PerpEventMirror): u64 { m.last_fill_bot_reward }
    #[test_only] public fun pem_vm_count(m: &PerpEventMirror): u64 { m.vm_count }
    #[test_only] public fun pem_last_vm_qty(m: &PerpEventMirror): u64 { m.last_vm_qty }
    #[test_only] public fun pem_last_vm_from(m: &PerpEventMirror): u64 { m.last_vm_from }
    #[test_only] public fun pem_last_vm_to(m: &PerpEventMirror): u64 { m.last_vm_to }
    #[test_only] public fun pem_last_margin_refund(m: &PerpEventMirror): u64 { m.last_margin_refund }
    #[test_only] public fun pem_funding_count(m: &PerpEventMirror): u64 { m.funding_count }
    #[test_only] public fun pem_last_funding_abs(m: &PerpEventMirror): u64 { m.last_funding_delta_abs }
    #[test_only] public fun pem_last_new_pnl_abs(m: &PerpEventMirror): u64 { m.last_new_pnl_abs }
    #[test_only] public fun pem_liq_count(m: &PerpEventMirror): u64 { m.liq_count }
    #[test_only] public fun pem_last_liq_price(m: &PerpEventMirror): u64 { m.last_liq_price }
    #[test_only] public fun pem_last_liq_seized(m: &PerpEventMirror): u64 { m.last_liq_seized }
    #[test_only] public fun pem_last_liq_bot_reward(m: &PerpEventMirror): u64 { m.last_liq_bot_reward }

    #[test_only]
    public fun record_fill_with_event_mirror<C>(
        reg: &mut PerpsRegistry,
        market: &mut PerpMarket,
        price_micro_usd: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        unxv_usd_price: &Aggregator,
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        fee_payment: Coin<C>,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        mirror: &mut PerpEventMirror,
        ctx: &mut TxContext
    ) {
        // expected math replicate
        let notional_u128: u128 = (size as u128) * (price_micro_usd as u128);
        let trade_fee_u128: u128 = (notional_u128 * (reg.trade_fee_bps as u128)) / 10_000u128;
        let discount_usdc_u128: u128 = (trade_fee_u128 * (reg.unxv_discount_bps as u128)) / 10_000u128;
        let mut discount_applied = false;
        if (discount_usdc_u128 > 0 && vector::length(&unxv_payment) > 0) {
            let unxv_px_u64 = get_price_for_symbol(oracle_reg, clock, &b"UNXV".to_string(), unxv_usd_price);
            if (unxv_px_u64 > 0) { discount_applied = true; };
        };
        let collateral_fee_after_discount_u128: u128 = if (discount_applied) { if (discount_usdc_u128 <= trade_fee_u128) { trade_fee_u128 - discount_usdc_u128 } else { 0 } } else { trade_fee_u128 };
        let maker_rebate_u128: u128 = (trade_fee_u128 * (reg.maker_rebate_bps as u128)) / 10_000u128;
        let fee_paid = if (collateral_fee_after_discount_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { collateral_fee_after_discount_u128 as u64 };
        let maker_rebate = if (maker_rebate_u128 > (18_446_744_073_709_551_615u128)) { 18_446_744_073_709_551_615u64 } else { maker_rebate_u128 as u64 };
        let bot_reward = if (reg.trade_bot_reward_bps > 0) { (fee_paid * reg.trade_bot_reward_bps) / 10_000 } else { 0 };
        record_fill<C>(reg, market, price_micro_usd, size, taker_is_buyer, maker, vector::empty<Coin<unxversal::unxv::UNXV>>(), unxv_usd_price, oracle_reg, oracle_cfg, clock, fee_payment, treasury, bot_treasury, points, oi_increase, min_price, max_price, ctx);
        mirror.fill_count = mirror.fill_count + 1;
        mirror.last_fill_fee_paid = fee_paid;
        mirror.last_fill_maker_rebate = maker_rebate;
        mirror.last_fill_discount_applied = discount_applied;
        mirror.last_fill_bot_reward = bot_reward;
        // ensure unxv_payment is consumed
        while (!vector::is_empty(&unxv_payment)) {
            let c = vector::pop_back(&mut unxv_payment);
            transfer::public_transfer(c, ctx.sender());
        };
        vector::destroy_empty(unxv_payment);
    }

    #[test_only]
    public fun close_with_event_mirror<C>(
        reg: &PerpsRegistry,
        market: &mut PerpMarket,
        pos: &mut PerpPosition<C>,
        close_price_micro_usd: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        clock: &Clock,
        mirror: &mut PerpEventMirror,
        ctx: &mut TxContext
    ) {
        let total_margin = balance::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        close_position<C>(reg, market, pos, close_price_micro_usd, quantity, treasury, clock, ctx);
        mirror.vm_count = mirror.vm_count + 1;
        mirror.last_vm_qty = quantity;
        mirror.last_vm_from = pos.avg_entry_price_micro_usd;
        mirror.last_vm_to = close_price_micro_usd;
        mirror.last_margin_refund = margin_refund;
    }

    #[test_only]
    public fun apply_funding_with_event_mirror<C>(
        reg: &PerpsRegistry,
        market: &PerpMarket,
        pos: &mut PerpPosition<C>,
        oracle_reg: &OracleRegistry,
        index_price: &Aggregator,
        clock: &Clock,
        mirror: &mut PerpEventMirror
    ) {
        let before_abs = pos.accumulated_pnl.magnitude;
        apply_funding_for_position<C>(reg, market, pos, oracle_reg, index_price, clock);
        let after_abs = pos.accumulated_pnl.magnitude;
        mirror.funding_count = mirror.funding_count + 1;
        if (after_abs >= before_abs) { mirror.last_funding_delta_abs = after_abs - before_abs; } else { mirror.last_funding_delta_abs = before_abs - after_abs; };
        mirror.last_new_pnl_abs = after_abs;
    }

    #[test_only]
    public fun liquidate_with_event_mirror<C>(
        reg: &PerpsRegistry,
        market: &mut PerpMarket,
        pos: &mut PerpPosition<C>,
        mark_price_micro_usd: u64,
        treasury: &mut Treasury<C>,
        clock: &Clock,
        mirror: &mut PerpEventMirror,
        ctx: &mut TxContext
    ) {
        let seized_total = balance::value(&pos.margin);
        liquidate_position<C>(reg, market, pos, mark_price_micro_usd, treasury, clock, ctx);
        mirror.liq_count = mirror.liq_count + 1;
        mirror.last_liq_price = mark_price_micro_usd;
        mirror.last_liq_seized = seized_total;
        mirror.last_liq_bot_reward = (seized_total * reg.trade_bot_reward_bps) / 10_000;
    }
}


