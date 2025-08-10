module unxversal::perpetuals {
    /*******************************
    * Unxversal Perpetuals – orderbook-integrated, funding-based perps
    * - Off-chain matching; on-chain fills, margin, liquidation, funding accrual
    * - Fees to central treasury with UNXV discount, maker rebate, bot splits
    *******************************/

    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::object;
    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::String;
    use std::table::{Self as Table, Table};
    use std::vec_set::{Self as VecSet, VecSet};
    use std::vector;
    use std::time;
    use sui::coin::{Self as Coin, Coin};

    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6}; // index prices in micro-USD
    use pyth::price_info::PriceInfoObject;
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{SynthRegistry, AdminCap};

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_MIN_INTERVAL: u64 = 3;
    const E_BAD_BOUNDS: u64 = 4;

    fun assert_is_admin(registry: &SynthRegistry, addr: address) { assert!(VecSet::contains(&registry.admin_addrs, addr), E_NOT_ADMIN); }

    /*******************************
    * Registry
    *******************************/
    public struct PerpsRegistry has key, store {
        id: UID,
        paused: bool,
        markets: Table<String, ID>,
        // Trade fee stack
        trade_fee_bps: u64,
        maker_rebate_bps: u64,
        unxv_discount_bps: u64,
        trade_bot_reward_bps: u64,
        // Funding config
        funding_interval_ms: u64,
        max_funding_rate_bps: i64,     // signed cap per interval
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
        funding_rate_bps: i64,
        // Margins
        init_margin_bps: u64,
        maint_margin_bps: u64,
        // Metrics
        open_interest: u64,
        volume_premium_usdc: u64,
        last_trade_price_micro_usd: u64,
    }

    /*******************************
    * Position (owned)
    *******************************/
    public struct PerpPosition has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        side: u8,                            // 0 long, 1 short
        size: u64,                           // in units
        avg_entry_price_micro_usd: u64,
        margin: Coin<usdc::usdc::USDC>,
        accumulated_pnl: i64,               // includes funding accruals
        last_funding_ms: u64,
    }

    /*******************************
    * Events
    *******************************/
    public struct PerpMarketListed has copy, drop { symbol: String, underlying: String, tick: u64, timestamp: u64 }
    public struct PerpFillRecorded has copy, drop { symbol: String, price: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_usdc: u64, unxv_discount_applied: bool, maker_rebate_usdc: u64, bot_reward_usdc: u64, timestamp: u64 }
    public struct PerpPositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price: u64, margin_locked: u64, sponsor: address, timestamp: u64 }
    public struct PerpPositionClosed has copy, drop { symbol: String, account: address, qty: u64, price: u64, margin_refund: u64, timestamp: u64 }
    public struct PerpVariationMargin has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta: i64, new_margin: u64, timestamp: u64 }
    public struct PerpFundingApplied has copy, drop { symbol: String, account: address, funding_delta: i64, new_accumulated_pnl: i64, timestamp: u64 }
    public struct PerpMarginCall has copy, drop { symbol: String, account: address, equity_usdc: i64, maint_required_usdc: u64, timestamp: u64 }
    public struct PerpLiquidated has copy, drop { symbol: String, account: address, size: u64, price: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct PerpPausedToggled has copy, drop { symbol: String, new_state: bool, by: address, timestamp: u64 }

    /*******************************
    * Init & Admin
    *******************************/
    public entry fun init_perps_registry(synth_reg: &SynthRegistry, ctx: &mut TxContext): PerpsRegistry {
        assert_is_admin(synth_reg, ctx.sender());
        let reg = PerpsRegistry {
            id: object::new(ctx),
            paused: false,
            markets: Table::new<String, ID>(ctx),
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
            last_list_ms: Table::new<String, u64>(ctx),
            treasury_id: object::id(&Treasury { id: object::new(ctx), usdc: Coin::zero<usdc::usdc::USDC>(ctx), unxv: Coin::zero<unxversal::unxv::UNXV>(ctx), cfg: unxversal::treasury::TreasuryCfg { unxv_burn_bps: 0 } }),
        };
        transfer::share_object(reg)
    }

    public entry fun set_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    public entry fun set_funding_params(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, funding_interval_ms: u64, max_funding_rate_bps: i64, premium_weight_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.funding_interval_ms = funding_interval_ms;
        reg.max_funding_rate_bps = max_funding_rate_bps;
        reg.premium_weight_bps = premium_weight_bps;
    }

    public entry fun set_margin_defaults(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, init_bps: u64, maint_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.default_init_margin_bps = init_bps;
        reg.default_maint_margin_bps = maint_bps;
    }

    public entry fun set_treasury(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, treasury: &Treasury, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }
    public entry fun pause_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = true; }
    public entry fun resume_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = false; }

    /*******************************
    * Listing (permissionless with cooldown)
    *******************************/
    public entry fun list_market(reg: &mut PerpsRegistry, underlying: String, symbol: String, tick_size_micro_usd: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        let now = time::now_ms();
        let last = if (Table::contains(&reg.last_list_ms, &symbol)) { *Table::borrow(&reg.last_list_ms, &symbol) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        Table::insert(&mut reg.last_list_ms, symbol.clone(), now);

        let m = PerpMarket {
            id: object::new(ctx),
            symbol: symbol.clone(),
            underlying: underlying,
            tick_size_micro_usd: tick_size_micro_usd,
            paused: false,
            last_funding_ms: now,
            funding_rate_bps: 0,
            init_margin_bps: if (init_margin_bps > 0) { init_margin_bps } else { reg.default_init_margin_bps },
            maint_margin_bps: if (maint_margin_bps > 0) { maint_margin_bps } else { reg.default_maint_margin_bps },
            open_interest: 0,
            volume_premium_usdc: 0,
            last_trade_price_micro_usd: 0,
        };
        let id = object::id(&m);
        transfer::share_object(m);
        Table::insert(&mut reg.markets, symbol.clone(), id);
        event::emit(PerpMarketListed { symbol, underlying: b"".to_string(), tick: tick_size_micro_usd, timestamp: now });
    }

    public entry fun pause_market(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut PerpMarket, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = true; event::emit(PerpPausedToggled { symbol: market.symbol.clone(), new_state: true, by: ctx.sender(), timestamp: time::now_ms() }); }
    public entry fun resume_market(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut PerpMarket, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = false; event::emit(PerpPausedToggled { symbol: market.symbol.clone(), new_state: false, by: ctx.sender(), timestamp: time::now_ms() }); }

    public entry fun set_market_margins(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut PerpMarket, init_margin_bps: u64, maint_margin_bps: u64, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.init_margin_bps = init_margin_bps; market.maint_margin_bps = maint_margin_bps; }

    /*******************************
    * Fills (off-chain matching)
    *******************************/
    public entry fun record_fill(
        reg: &mut PerpsRegistry,
        market: &mut PerpMarket,
        price_micro_usd: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        unxv_usd_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury,
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        assert!(price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        assert!(price_micro_usd >= min_price && price_micro_usd <= max_price, E_BAD_BOUNDS);

        let notional = size * price_micro_usd;
        let trade_fee = (notional * reg.trade_fee_bps) / 10_000;
        let discount_usdc = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && vector::length(&unxv_payment) > 0) {
            let unxv_px = get_price_scaled_1e6(oracle_cfg, clock, unxv_usd_price);
            if (unxv_px > 0) {
                let unxv_needed = (discount_usdc + unxv_px - 1) / unxv_px;
                let mut merged = Coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); Coin::merge(&mut merged, c); i = i + 1; };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<unxversal::unxv::UNXV>>();
                    vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"perp_trade".to_string(), ctx.sender(), ctx);
                    transfer::public_transfer(merged, ctx.sender());
                    discount_applied = true;
                } else { transfer::public_transfer(merged, ctx.sender()); }
            }
        }
        let usdc_fee_after_discount = if (discount_applied) { if (discount_usdc <= trade_fee) { trade_fee - discount_usdc } else { 0 } } else { trade_fee };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        if (usdc_fee_after_discount > 0) {
            let mut fee_collector = Coin::zero<usdc::usdc::USDC>(ctx);
            if (maker_rebate > 0 && maker_rebate < usdc_fee_after_discount) { let to_maker = Coin::split(&mut fee_collector, maker_rebate, ctx); transfer::public_transfer(to_maker, maker); }
            if (reg.trade_bot_reward_bps > 0) { let bot_cut = (usdc_fee_after_discount * reg.trade_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bot = Coin::split(&mut fee_collector, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); } }
            TreasuryMod::deposit_usdc(treasury, fee_collector, b"perp_trade".to_string(), ctx.sender(), ctx);
        }
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; } }
        market.volume_premium_usdc = market.volume_premium_usdc + notional;
        market.last_trade_price_micro_usd = price_micro_usd;
        event::emit(PerpFillRecorded { symbol: market.symbol.clone(), price: price_micro_usd, size, taker: ctx.sender(), maker, taker_is_buyer, fee_usdc: usdc_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate_usdc: maker_rebate, bot_reward_usdc: if (reg.trade_bot_reward_bps > 0) { (usdc_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: time::now_ms() });
    }

    /*******************************
    * Positions
    *******************************/
    public entry fun open_position(market: &mut PerpMarket, side: u8, size: u64, entry_price_micro_usd: u64, mut margin: Coin<usdc::usdc::USDC>, ctx: &mut TxContext): PerpPosition {
        assert!(!market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        assert!(entry_price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        let notional = size * entry_price_micro_usd;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(Coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let locked = Coin::split(&mut margin, init_req, ctx);
        transfer::public_transfer(margin, ctx.sender());
        market.open_interest = market.open_interest + size;
        let pos = PerpPosition { id: object::new(ctx), owner: ctx.sender(), market_id: object::id(market), side, size, avg_entry_price_micro_usd: entry_price_micro_usd, margin: locked, accumulated_pnl: 0, last_funding_ms: market.last_funding_ms };
        let sponsor_addr = match sui::tx_context::sponsor(ctx) { option::Some(a) => a, option::None => 0x0 };
        event::emit(PerpPositionOpened { symbol: market.symbol.clone(), account: pos.owner, side, size, price: entry_price_micro_usd, margin_locked: Coin::value(&pos.margin), sponsor: sponsor_addr, timestamp: time::now_ms() });
        pos
    }

    public entry fun close_position(reg: &PerpsRegistry, market: &mut PerpMarket, pos: &mut PerpPosition, close_price_micro_usd: u64, quantity: u64, treasury: &mut Treasury, ctx: &mut TxContext) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        assert!(close_price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        let pnl_delta: i64 = if (pos.side == 0) { ((close_price_micro_usd as i64 - pos.avg_entry_price_micro_usd as i64) * (quantity as i64)) } else { ((pos.avg_entry_price_micro_usd as i64 - close_price_micro_usd as i64) * (quantity as i64)) };
        pos.accumulated_pnl = pos.accumulated_pnl + pnl_delta;
        let total_margin = Coin::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) { let out = Coin::split(&mut pos.margin, margin_refund, ctx); transfer::public_transfer(out, pos.owner); }
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; }
        event::emit(PerpVariationMargin { symbol: market.symbol.clone(), account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_entry_price_micro_usd, to_price: close_price_micro_usd, pnl_delta, new_margin: Coin::value(&pos.margin), timestamp: time::now_ms() });
        event::emit(PerpPositionClosed { symbol: market.symbol.clone(), account: pos.owner, qty: quantity, price: close_price_micro_usd, margin_refund: margin_refund, timestamp: time::now_ms() });
    }

    /*******************************
    * Funding accrual (trustless, no paired transfers)
    *******************************/
    public entry fun apply_funding_for_position(reg: &PerpsRegistry, market: &mut PerpMarket, pos: &mut PerpPosition, index_price_micro_usd: u64, clock: &Clock) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        let now = time::now_ms();
        let elapsed = if (now > market.last_funding_ms) { now - market.last_funding_ms } else { 0 };
        if (elapsed < reg.funding_interval_ms) { return; }
        if (index_price_micro_usd == 0 || market.last_trade_price_micro_usd == 0) { return; }
        // premium_bps = (mark - index)/index * 10k
        let mark = market.last_trade_price_micro_usd as i128;
        let idx = index_price_micro_usd as i128;
        let premium_bps: i64 = (((mark - idx) * 10_000) / idx) as i64;
        let raw_rate = (premium_bps as i128 * reg.premium_weight_bps as i128) / 10_000;
        let mut rate_bps: i64 = raw_rate as i64;
        if (rate_bps > reg.max_funding_rate_bps) { rate_bps = reg.max_funding_rate_bps; }
        if (rate_bps < -reg.max_funding_rate_bps) { rate_bps = -reg.max_funding_rate_bps; }
        market.funding_rate_bps = rate_bps;
        // funding payment ~ size * index_price * rate
        if (pos.size == 0) { market.last_funding_ms = now; return; }
        let notional = (pos.size as i128) * (index_price_micro_usd as i128);
        let funding_delta: i64 = ((notional * (rate_bps as i128)) / 10_000) as i64;
        // Sign convention: positive premium -> longs pay (negative for longs), negative premium -> longs receive
        let signed_delta = if (pos.side == 0) { -funding_delta } else { funding_delta };
        pos.accumulated_pnl = pos.accumulated_pnl + signed_delta;
        market.last_funding_ms = now;
        pos.last_funding_ms = now;
        event::emit(PerpFundingApplied { symbol: market.symbol.clone(), account: pos.owner, funding_delta: signed_delta, new_accumulated_pnl: pos.accumulated_pnl, timestamp: now });
    }

    /*******************************
    * Liquidation
    *******************************/
    public entry fun liquidate_position(reg: &PerpsRegistry, market: &mut PerpMarket, pos: &mut PerpPosition, mark_price_micro_usd: u64, treasury: &mut Treasury, ctx: &mut TxContext) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(object::id(&market) == pos.market_id, E_MIN_INTERVAL);
        let margin_val = Coin::value(&pos.margin);
        let var_pnl: i64 = if (pos.side == 0) { ((mark_price_micro_usd as i64 - pos.avg_entry_price_micro_usd as i64) * (pos.size as i64)) } else { ((pos.avg_entry_price_micro_usd as i64 - mark_price_micro_usd as i64) * (pos.size as i64)) };
        let equity: i128 = (margin_val as i128) + (pos.accumulated_pnl as i128) + (var_pnl as i128);
        let notional = (pos.size as u128) * (mark_price_micro_usd as u128);
        let maint_req = ((notional * (market.maint_margin_bps as u128)) / 10_000) as u64;
        if (!(equity < (maint_req as i128))) { return; }
        event::emit(PerpMarginCall { symbol: market.symbol.clone(), account: pos.owner, equity_usdc: equity as i64, maint_required_usdc: maint_req, timestamp: time::now_ms() });
        let seized_total = Coin::value(&pos.margin);
        if (seized_total > 0) {
            let mut seized = Coin::split(&mut pos.margin, seized_total, ctx);
            // Bot reward optional via trade_bot_reward_bps reuse (no separate field here)
            let bot_cut = (seized_total * reg.trade_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let to_bot = Coin::split(&mut seized, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); }
            TreasuryMod::deposit_usdc(treasury, seized, b"perp_liquidation".to_string(), ctx.sender(), ctx);
        }
        let qty = pos.size; pos.size = 0;
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; }
        event::emit(PerpLiquidated { symbol: market.symbol.clone(), account: pos.owner, size: qty, price: mark_price_micro_usd, seized_margin: seized_total, bot_reward: (seized_total * reg.trade_bot_reward_bps) / 10_000, timestamp: time::now_ms() });
    }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun market_id(reg: &PerpsRegistry, symbol: &String): ID { *Table::borrow(&reg.markets, symbol) }
    public fun market_metrics(m: &PerpMarket): (u64, u64, u64, i64) { (m.open_interest, m.volume_premium_usdc, m.last_trade_price_micro_usd, m.funding_rate_bps) }
    public fun position_info(p: &PerpPosition): (address, ID, u8, u64, u64, u64, i64, u64) { (p.owner, p.market_id, p.side, p.size, p.avg_entry_price_micro_usd, Coin::value(&p.margin), p.accumulated_pnl, p.last_funding_ms) }
    public fun registry_trade_fee_params(reg: &PerpsRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun registry_funding_params(reg: &PerpsRegistry): (u64, i64, u64) { (reg.funding_interval_ms, reg.max_funding_rate_bps, reg.premium_weight_bps) }
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
}


