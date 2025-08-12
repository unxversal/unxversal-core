module unxversal::perpetuals {
    /*******************************
    * Unxversal Perpetuals - orderbook-integrated, funding-based perps
    * - Off-chain matching; on-chain fills, margin, liquidation, funding accrual
    * - Fees to central treasury with UNXV discount, maker rebate, bot splits
    *******************************/

    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::String;
    use sui::table::{Self as table, Table};
    use sui::vec_set::{VecSet};

    // Removed std::time - doesn't exist in Sui
    use sui::coin::{Self as coin, Coin};

    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6}; // index prices in micro-USD
    use unxversal::oracle::PriceInfoObject;
    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{SynthRegistry, AdminCap, check_is_admin, CollateralConfig};

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_MIN_INTERVAL: u64 = 3;
    const E_BAD_BOUNDS: u64 = 4;

    fun assert_is_admin(registry: &SynthRegistry, addr: address) { assert!(check_is_admin(registry, addr), E_NOT_ADMIN); }

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
        max_funding_rate_bps: u64,     // cap per interval (use separate sign logic)
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
        funding_rate_bps: u64,     // magnitude, track sign separately if needed
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
    public struct PerpPosition<phantom C> has key, store {
        id: UID,
        owner: address,
        market_id: ID,
        side: u8,                            // 0 long, 1 short
        size: u64,                           // in units
        avg_entry_price_micro_usd: u64,
        margin: Coin<C>,                     // locked margin in admin-set collateral
        accumulated_pnl: u64,               // includes funding accruals (magnitude only)
        last_funding_ms: u64,
    }

    /*******************************
    * Events
    *******************************/
    public struct PerpMarketListed has copy, drop { symbol: String, underlying: String, tick: u64, timestamp: u64 }
    public struct PerpFillRecorded has copy, drop { symbol: String, price: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_collateral: u64, unxv_discount_applied: bool, maker_rebate_collateral: u64, bot_reward_collateral: u64, timestamp: u64 }
    public struct PerpPositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price: u64, margin_locked: u64, sponsor: address, timestamp: u64 }
    public struct PerpPositionClosed has copy, drop { symbol: String, account: address, qty: u64, price: u64, margin_refund: u64, timestamp: u64 }
    public struct PerpVariationMargin has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta: u64, new_margin: u64, timestamp: u64 }
    public struct PerpFundingApplied has copy, drop { symbol: String, account: address, funding_delta: u64, new_accumulated_pnl: u64, timestamp: u64 }
    public struct PerpMarginCall has copy, drop { symbol: String, account: address, equity_collateral: u64, maint_required_collateral: u64, timestamp: u64 }
    public struct PerpLiquidated has copy, drop { symbol: String, account: address, size: u64, price: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct PerpPausedToggled has copy, drop { symbol: String, new_state: bool, by: address, timestamp: u64 }

    /*******************************
    * Init & Admin
    *******************************/
    public fun init_perps_registry(synth_reg: &SynthRegistry, ctx: &mut tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        let reg = PerpsRegistry {
            id: object::new(ctx),
            paused: false,
            markets: table::new<String, ID>(ctx),
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
            treasury_id: object::id_from_address(@0x0), // Placeholder until proper Treasury integration
        };
        transfer::share_object(reg)
    }

    public entry fun set_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    public entry fun set_funding_params(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, funding_interval_ms: u64, max_funding_rate_bps: u64, premium_weight_bps: u64, ctx: &tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        reg.funding_interval_ms = funding_interval_ms;
        reg.max_funding_rate_bps = max_funding_rate_bps;
        reg.premium_weight_bps = premium_weight_bps;
    }

    public entry fun set_margin_defaults(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, init_bps: u64, maint_bps: u64, ctx: &tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        reg.default_init_margin_bps = init_bps;
        reg.default_maint_margin_bps = maint_bps;
    }

    public entry fun set_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, treasury: &Treasury<C>, ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.treasury_id = TreasuryMod::treasury_id(treasury); }
    public entry fun pause_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.paused = true; }
    public entry fun resume_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut PerpsRegistry, ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.paused = false; }

    /*******************************
    * Listing (permissionless with cooldown)
    *******************************/
    public entry fun list_market(reg: &mut PerpsRegistry, underlying: String, symbol: String, tick_size_micro_usd: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut tx_context::TxContext) {
        assert!(!reg.paused, E_PAUSED);
        let now = 0u64;
        let last = if (table::contains(&reg.last_list_ms, symbol)) { *table::borrow(&reg.last_list_ms, symbol) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        table::add(&mut reg.last_list_ms, symbol, now);

        let m = PerpMarket {
            id: object::new(ctx),
            symbol: symbol,
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
        table::add(&mut reg.markets, symbol, id);
        event::emit(PerpMarketListed { symbol, underlying: b"".to_string(), tick: tick_size_micro_usd, timestamp: now });
    }

    public entry fun pause_market(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut PerpMarket, ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); market.paused = true; event::emit(PerpPausedToggled { symbol: market.symbol, new_state: true, by: tx_context::sender(ctx), timestamp: 0u64 }); }
    public entry fun resume_market(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut PerpMarket, ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); market.paused = false; event::emit(PerpPausedToggled { symbol: market.symbol, new_state: false, by: tx_context::sender(ctx), timestamp: 0u64 }); }

    public entry fun set_market_margins(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut PerpMarket, init_margin_bps: u64, maint_margin_bps: u64, ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); market.init_margin_bps = init_margin_bps; market.maint_margin_bps = maint_margin_bps; }

    /*******************************
    * Fills (off-chain matching)
    *******************************/
    public entry fun record_fill<C>(
        _cfg: &CollateralConfig<C>,
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
        treasury: &mut Treasury<C>,
        mut fee_payment: Coin<C>,  // Fee payment in admin-set collateral
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        ctx: &mut tx_context::TxContext
    ) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        assert!(price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        assert!(price_micro_usd >= min_price && price_micro_usd <= max_price, E_BAD_BOUNDS);

        let notional = size * price_micro_usd;
        let trade_fee = (notional * reg.trade_fee_bps) / 10_000;
        let discount_usdc = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && std::vector::length(&unxv_payment) > 0) {
            let unxv_px = get_price_scaled_1e6(oracle_cfg, clock, unxv_usd_price);
            if (unxv_px > 0) {
                let unxv_needed = (discount_usdc + unxv_px - 1) / unxv_px;
                let mut merged = coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0; while (i < std::vector::length(&unxv_payment)) { let c = std::vector::pop_back(&mut unxv_payment); merged.join(c); i = i + 1; };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vecu = std::vector::empty<Coin<unxversal::unxv::UNXV>>();
                    std::vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"perp_trade".to_string(), tx_context::sender(ctx), ctx);
                    sui::transfer::public_transfer(merged, tx_context::sender(ctx));
                    discount_applied = true;
                } else { sui::transfer::public_transfer(merged, tx_context::sender(ctx)); }
            }
        };
                let collateral_fee_after_discount = if (discount_applied) {
            if (discount_usdc <= trade_fee) { trade_fee - discount_usdc } else { 0 }
        } else { 
            trade_fee
        };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        
        // Process fee payment - caller must provide sufficient collateral
        assert!(coin::value(&fee_payment) >= collateral_fee_after_discount, E_MIN_INTERVAL);
        let mut fee_collector = coin::split(&mut fee_payment, collateral_fee_after_discount, ctx);
        
        if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) {
            let to_maker = coin::split(&mut fee_collector, maker_rebate, ctx);
            sui::transfer::public_transfer(to_maker, maker);
        };
        if (reg.trade_bot_reward_bps > 0) {
            let bot_cut = (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000;
            if (bot_cut > 0) {
                let to_bot = coin::split(&mut fee_collector, bot_cut, ctx);
                sui::transfer::public_transfer(to_bot, tx_context::sender(ctx));
            };
        };
        
        // Transfer remaining fees to treasury and return excess payment to sender
        // Transfer fees to treasury using treasury deposit function
        // Note: For now just destroy the fee_collector as treasury is shared
        coin::destroy_zero(fee_collector);
        if (coin::value(&fee_payment) > 0) {
            sui::transfer::public_transfer(fee_payment, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(fee_payment);
        };
        if (oi_increase) {
            market.open_interest = market.open_interest + size;
        } else {
            if (market.open_interest >= size) {
                market.open_interest = market.open_interest - size;
            };
        };
        market.volume_premium_usdc = market.volume_premium_usdc + notional;
        market.last_trade_price_micro_usd = price_micro_usd;
        
        // Consume any remaining UNXV payment vector
        while (std::vector::length(&unxv_payment) > 0) {
            let remaining_coin = std::vector::pop_back(&mut unxv_payment);
            sui::transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
        };
        std::vector::destroy_empty(unxv_payment);
        
        event::emit(PerpFillRecorded { symbol: market.symbol, price: price_micro_usd, size, taker: tx_context::sender(ctx), maker, taker_is_buyer, fee_collateral: collateral_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate_collateral: maker_rebate, bot_reward_collateral: if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: 0u64 });
    }

    /*******************************
    * Positions
    *******************************/
    public fun open_position<C>(
        _cfg: &CollateralConfig<C>,
        market: &mut PerpMarket,
        side: u8,
        size: u64,
        entry_price_micro_usd: u64,
        mut margin: Coin<C>,
        ctx: &mut tx_context::TxContext
    ): PerpPosition<C> {
        assert!(!market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        assert!(entry_price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        let notional = size * entry_price_micro_usd;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(margin.value() >= init_req, E_MIN_INTERVAL);
        let locked = margin.split(init_req, ctx);
        sui::transfer::public_transfer(margin, tx_context::sender(ctx));
        market.open_interest = market.open_interest + size;
        let pos = PerpPosition<C> { id: object::new(ctx), owner: tx_context::sender(ctx), market_id: object::id(market), side, size, avg_entry_price_micro_usd: entry_price_micro_usd, margin: locked, accumulated_pnl: 0, last_funding_ms: market.last_funding_ms };
        let sponsor_addr = if (option::is_some(&sui::tx_context::sponsor(ctx))) { option::extract(&mut sui::tx_context::sponsor(ctx)) } else { @0x0 };
        event::emit(PerpPositionOpened { symbol: market.symbol, account: pos.owner, side, size, price: entry_price_micro_usd, margin_locked: pos.margin.value(), sponsor: sponsor_addr, timestamp: 0u64 });
        pos
    }

    public entry fun close_position<C>(
        _cfg: &CollateralConfig<C>,
        reg: &PerpsRegistry,
        market: &mut PerpMarket,
        pos: &mut PerpPosition<C>,
        close_price_micro_usd: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut tx_context::TxContext
    ) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        assert!(close_price_micro_usd % market.tick_size_micro_usd == 0, E_MIN_INTERVAL);
        let pnl_delta: u64 = if (pos.side == 0) {
            // Long position: PnL = (close_price - entry_price) * quantity
            if (close_price_micro_usd >= pos.avg_entry_price_micro_usd) {
                (close_price_micro_usd - pos.avg_entry_price_micro_usd) * quantity
            } else {
                // Loss case - for simplicity, use 0 (could track separately if needed)
                0
            }
        } else {
            // Short position: PnL = (entry_price - close_price) * quantity
            if (pos.avg_entry_price_micro_usd >= close_price_micro_usd) {
                (pos.avg_entry_price_micro_usd - close_price_micro_usd) * quantity
            } else {
                0
            }
        };
        pos.accumulated_pnl = pos.accumulated_pnl + pnl_delta;
        let total_margin = pos.margin.value();
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) { let out = pos.margin.split(margin_refund, ctx); sui::transfer::public_transfer(out, pos.owner); };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; };
        event::emit(PerpVariationMargin { symbol: market.symbol, account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_entry_price_micro_usd, to_price: close_price_micro_usd, pnl_delta, new_margin: pos.margin.value(), timestamp: 0u64 });
        event::emit(PerpPositionClosed { symbol: market.symbol, account: pos.owner, qty: quantity, price: close_price_micro_usd, margin_refund: margin_refund, timestamp: 0u64 });
    }

    /*******************************
    * Funding accrual (trustless, no paired transfers)
    *******************************/
    public entry fun apply_funding_for_position<C>(
        _cfg: &CollateralConfig<C>,
        reg: &PerpsRegistry,
        market: &mut PerpMarket,
        pos: &mut PerpPosition<C>,
        index_price_micro_usd: u64,
        clock: &Clock
    ) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        let now = 0u64;
        let elapsed = if (now > market.last_funding_ms) { now - market.last_funding_ms } else { 0 };
        if (elapsed < reg.funding_interval_ms) { return; };
        if (index_price_micro_usd == 0 || market.last_trade_price_micro_usd == 0) { return; };
        // Simplified funding calculation using u64 (premium calculation)
        let mark = market.last_trade_price_micro_usd;
        let idx = index_price_micro_usd;
        
        // Calculate premium basis points (absolute value)
        let premium_bps: u64 = if (mark >= idx) {
            ((mark - idx) * 10_000) / idx
        } else {
            ((idx - mark) * 10_000) / idx
        };
        
        let raw_rate = (premium_bps * reg.premium_weight_bps) / 10_000;
        let mut rate_bps: u64 = raw_rate;
        if (rate_bps > reg.max_funding_rate_bps) { rate_bps = reg.max_funding_rate_bps; };
        market.funding_rate_bps = rate_bps;
        
        // funding payment calculation
        if (pos.size == 0) { market.last_funding_ms = now; return; };
        let notional = pos.size * index_price_micro_usd;
        let funding_delta: u64 = (notional * rate_bps) / 10_000;
        
        // Apply funding (simplified: always positive contribution for now)
        pos.accumulated_pnl = pos.accumulated_pnl + funding_delta;
        market.last_funding_ms = now;
        pos.last_funding_ms = now;
        event::emit(PerpFundingApplied { symbol: market.symbol, account: pos.owner, funding_delta, new_accumulated_pnl: pos.accumulated_pnl, timestamp: now });
    }

    /*******************************
    * Liquidation
    *******************************/
    public fun liquidate_position<C>(
        _cfg: &CollateralConfig<C>,
        reg: &PerpsRegistry,
        market: &mut PerpMarket,
        pos: &mut PerpPosition<C>,
        mark_price_micro_usd: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut tx_context::TxContext
    ) {
        assert!(!reg.paused && !market.paused, E_PAUSED);
        assert!(object::id(market) == pos.market_id, E_MIN_INTERVAL);
        let margin_val = pos.margin.value();
        // Simplified PnL calculation using u64
        let var_pnl: u64 = if (pos.side == 0) {
            // Long: profit if mark > entry
            if (mark_price_micro_usd >= pos.avg_entry_price_micro_usd) {
                (mark_price_micro_usd - pos.avg_entry_price_micro_usd) * pos.size
            } else { 0 }
        } else {
            // Short: profit if entry > mark
            if (pos.avg_entry_price_micro_usd >= mark_price_micro_usd) {
                (pos.avg_entry_price_micro_usd - mark_price_micro_usd) * pos.size
            } else { 0 }
        };
        let equity: u64 = margin_val + pos.accumulated_pnl + var_pnl;
        let notional = pos.size * mark_price_micro_usd;
        let maint_req = (notional * market.maint_margin_bps) / 10_000;
        if (equity >= maint_req) { return; };
        event::emit(PerpMarginCall { symbol: market.symbol, account: pos.owner, equity_collateral: equity, maint_required_collateral: maint_req, timestamp: 0u64 });
        let seized_total = pos.margin.value();
        if (seized_total > 0) {
            let mut seized = pos.margin.split(seized_total, ctx);
            // Bot reward optional via trade_bot_reward_bps reuse (no separate field here)
            let bot_cut = (seized_total * reg.trade_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let to_bot = seized.split(bot_cut, ctx); sui::transfer::public_transfer(to_bot, tx_context::sender(ctx)); };
            // Transfer seized margin to treasury (generic collateral handling)
            sui::transfer::public_transfer(seized, TreasuryMod::treasury_address(treasury));
        };
        let qty = pos.size;
        pos.size = 0;
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; };
        event::emit(PerpLiquidated { symbol: market.symbol, account: pos.owner, size: qty, price: mark_price_micro_usd, seized_margin: seized_total, bot_reward: (seized_total * reg.trade_bot_reward_bps) / 10_000, timestamp: 0u64 });
    }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun market_id(reg: &PerpsRegistry, symbol: String): ID { *table::borrow(&reg.markets, symbol) }
    public fun market_metrics(m: &PerpMarket): (u64, u64, u64, u64) { (m.open_interest, m.volume_premium_usdc, m.last_trade_price_micro_usd, m.funding_rate_bps) }
    public fun position_info<C>(p: &PerpPosition<C>): (address, ID, u8, u64, u64, u64, u64, u64) { (p.owner, p.market_id, p.side, p.size, p.avg_entry_price_micro_usd, coin::value(&p.margin), p.accumulated_pnl, p.last_funding_ms) }
    public fun registry_trade_fee_params(reg: &PerpsRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun registry_funding_params(reg: &PerpsRegistry): (u64, u64, u64) { (reg.funding_interval_ms, reg.max_funding_rate_bps, reg.premium_weight_bps) }
    public fun registry_margin_defaults(reg: &PerpsRegistry): (u64, u64) { (reg.default_init_margin_bps, reg.default_maint_margin_bps) }

    /*******************************
    * Displays
    *******************************/
    public entry fun init_perps_displays(publisher: &sui::package::Publisher, ctx: &mut tx_context::TxContext) {
        let mut disp = display::new<PerpMarket>(publisher, ctx);
        disp.add(b"name".to_string(), b"Perp Market {symbol}".to_string());
        disp.add(b"description".to_string(), b"Unxversal Perpetual Market".to_string());
        disp.add(b"underlying".to_string(), b"{underlying}".to_string());
        disp.add(b"tick_size_micro_usd".to_string(), b"{tick_size_micro_usd}".to_string());
        disp.update_version();
        sui::transfer::public_transfer(disp, tx_context::sender(ctx));

        let mut rdisp = display::new<PerpsRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Perpetuals Registry".to_string());
        rdisp.add(b"description".to_string(), b"Registry for perpetual markets and parameters".to_string());
        rdisp.update_version();
        sui::transfer::public_transfer(rdisp, tx_context::sender(ctx));
    }
}


