/// Module: unxversal_xfutures
/// ------------------------------------------------------------
/// Synthetic linear futures ("xfutures") with cash settlement. Pricing/indexing
/// uses an internal exponentially weighted moving average (EMA) of the market's
/// own mark prices. No external oracle is required. Upon expiry, the market
/// snapshots a canonical settlement price based on the last valid pre-expiry
/// print (LVP) or a TWAP over a guarded window.
///
/// Design highlights:
/// - Matched orderbook (unxversal::book), taker-only protocol fee with maker rebates
/// - Single collateral coin per market; PnL realized into a FeeVault PnL bucket
/// - Tiered initial margin, account/market notional caps, share-of-OI cap
/// - EMA synthetic index with short and long EMAs and a multiple cap (short <= long*cap)
/// - Pre-expiry sampling buffers enable robust settlement (prefer LVP else TWAP)
/// - Trader rewards (UNXV) integrated similarly to perps/futures
#[allow(lint(self_transfer))]
module unxversal::xfutures {
    use sui::{
        clock::Clock,
        coin::{Self as coin, Coin},
        balance::{Self as balance, Balance},
        event,
        table::{Self as table, Table},
    };

    use std::string::{Self as string, String};

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::staking::{Self as staking, StakingPool};
    use unxversal::unxv::UNXV;
    use unxversal::book::{Self as ubk, Book};
    use unxversal::rewards as rewards;

    // ===== Errors =====
    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO: u64 = 2;
    const E_NO_ACCOUNT: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_UNDER_INITIAL_MARGIN: u64 = 5;
    const E_UNDER_MAINT_MARGIN: u64 = 6;
    const E_EXPIRED: u64 = 7;
    const E_PRICE_DEVIATION: u64 = 9;
    const E_EXPOSURE_CAP: u64 = 10;
    const E_ALREADY_SETTLED: u64 = 11;
    const E_INVALID_TIERS: u64 = 12;
    const E_NO_REWARDS: u64 = 13;
    const E_MARK_GATE: u64 = 14;

    // ===== TWAP window for settlement =====
    const TWAP_MAX_SAMPLES: u64 = 64;
    const TWAP_WINDOW_MS: u64 = 300_000; // 5 minutes

    // ===== EMA defaults (per minute) =====
    const DEFAULT_ALPHA_NUM: u64 = 1;          // 1/480 ≈ 8h
    const DEFAULT_ALPHA_DEN: u64 = 480;
    const DEFAULT_ALPHA_LONG_NUM: u64 = 1;     // 1/43200 ≈ 30d
    const DEFAULT_ALPHA_LONG_DEN: u64 = 43200;
    const DEFAULT_CAP_MULTIPLE_BPS: u64 = 40000; // 4.0x
    const DEFAULT_MARK_GATE_BPS: u64 = 0;       // off by default

    /// Futures series parameters
    public struct XSeries has copy, drop, store {
        expiry_ms: u64,              // epoch ms; >0 required for xfutures
        contract_size: u64,          // quote units per 1 contract when price is 1e6
        funding_interval_ms: u64,    // used only for sampling cadence hints (no funding in futures)
        alpha_num: u64,
        alpha_den: u64,
        alpha_long_num: u64,
        alpha_long_den: u64,
        cap_multiple_bps: u64,
        mark_gate_bps: u64,
    }

    /// Per-account state for a market
    public struct Account<phantom Collat> has store {
        collat: Balance<Collat>,
        long_qty: u64,
        short_qty: u64,
        avg_long_1e6: u64,
        avg_short_1e6: u64,
        pending_credit: u64,      // realized gain not yet paid due to vault shortfall
        locked_im: u64,           // margin locked for resting orders
        /// Trader rewards accounting (UNXV-funded)
        trader_reward_debt_1e18: u128,
        trader_pending_unxv: u64,
        trader_last_eligible: u64,
    }

    /// Market shared object
    public struct XFutureMarket<phantom Collat> has key, store {
        id: UID,
        series: XSeries,
        accounts: Table<address, Account<Collat>>,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        keeper_incentive_bps: u64,
        /// Notional caps (0 disables)
        account_max_notional_1e6: u128,
        market_max_notional_1e6: u128,
        account_share_of_oi_bps: u64,
        /// Tiered IM
        tier_thresholds_notional_1e6: vector<u64>,
        tier_im_bps: vector<u64>,
        /// OI
        total_long_qty: u64,
        total_short_qty: u64,
        /// Matched engine
        book: Book,
        owners: Table<u128, address>,
        /// PnL routing share from fees (bps of fee_amt) to PnL vault
        pnl_fee_share_bps: u64,
        /// Settlement state
        settlement_price_1e6: u64,
        is_settled: bool,
        lvp_price_1e6: u64,
        lvp_ts_ms: u64,
        twap_ts_ms: vector<u64>,
        twap_px_1e6: vector<u64>,
        /// Trader rewards state
        trader_acc_per_eligible_1e18: u128,
        trader_total_eligible: u128,
        trader_rewards_pot: Balance<UNXV>,
        trader_buffer_unxv: u64,
        /// Synthetic index state
        initial_mark_1e6: u64,
        ema_short_1e6: u64,
        ema_long_1e6: u64,
        last_mark_1e6: u64,
        last_sample_minute_ms: u64,
    }

    // ===== Events =====
    public struct MarketInitialized has copy, drop { market_id: ID, expiry_ms: u64, contract_size: u64, initial_margin_bps: u64, maintenance_margin_bps: u64, liquidation_fee_bps: u64, keeper_incentive_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_units: u64, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }
    public struct Settled has copy, drop { market_id: ID, who: address, price_1e6: u64, timestamp_ms: u64 }
    public struct PnlCreditAccrued<phantom Collat> has copy, drop { market_id: ID, who: address, credited: u64, remaining_credit: u64, timestamp_ms: u64 }
    public struct PnlCreditPaid<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, remaining_credit: u64, timestamp_ms: u64 }
    public struct TraderRewardsDeposited has copy, drop { market_id: ID, amount_unxv: u64, total_eligible: u128, acc_1e18: u128, timestamp_ms: u64 }
    public struct TraderRewardsClaimed has copy, drop { market_id: ID, who: address, amount_unxv: u64, pending_left: u64, timestamp_ms: u64 }
    public struct OrderPlaced has copy, drop { market_id: ID, order_id: u128, maker: address, is_bid: bool, price_1e6: u64, quantity: u64, expire_ts: u64 }
    public struct OrderCanceled has copy, drop { market_id: ID, order_id: u128, maker: address, remaining_qty: u64, timestamp_ms: u64 }
    public struct OrderFilled has copy, drop { market_id: ID, maker_order_id: u128, maker: address, taker: address, price_1e6: u64, base_qty: u64, timestamp_ms: u64 }

    // ===== Init =====
    public fun init_market<Collat>(
        reg_admin: &AdminRegistry,
        expiry_ms: u64,
        contract_size: u64,
        initial_mark_1e6: u64,
        funding_interval_ms: u64,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        keeper_incentive_bps: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(expiry_ms > sui::tx_context::epoch_timestamp_ms(ctx), E_EXPIRED);
        let mut tier_thresholds: vector<u64> = vector::empty<u64>();
        vector::push_back(&mut tier_thresholds, 1_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 5_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 25_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 100_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 250_000_000_000_000);

        let mut tier_bps: vector<u64> = vector::empty<u64>();
        vector::push_back(&mut tier_bps, 250);
        vector::push_back(&mut tier_bps, 300);
        vector::push_back(&mut tier_bps, 500);
        vector::push_back(&mut tier_bps, 800);
        vector::push_back(&mut tier_bps, 1200);

        let series = XSeries { expiry_ms, contract_size, funding_interval_ms, alpha_num: DEFAULT_ALPHA_NUM, alpha_den: DEFAULT_ALPHA_DEN, alpha_long_num: DEFAULT_ALPHA_LONG_NUM, alpha_long_den: DEFAULT_ALPHA_LONG_DEN, cap_multiple_bps: DEFAULT_CAP_MULTIPLE_BPS, mark_gate_bps: DEFAULT_MARK_GATE_BPS };

        let m = XFutureMarket<Collat> {
            id: object::new(ctx),
            series: series,
            accounts: table::new<address, Account<Collat>>(ctx),
            initial_margin_bps,
            maintenance_margin_bps,
            liquidation_fee_bps,
            keeper_incentive_bps,
            account_max_notional_1e6: 0,
            market_max_notional_1e6: 0,
            account_share_of_oi_bps: 300,
            tier_thresholds_notional_1e6: tier_thresholds,
            tier_im_bps: tier_bps,
            total_long_qty: 0,
            total_short_qty: 0,
            book: ubk::empty(tick_size, lot_size, min_size, ctx),
            owners: table::new<u128, address>(ctx),
            pnl_fee_share_bps: 0,
            settlement_price_1e6: 0,
            is_settled: false,
            lvp_price_1e6: 0,
            lvp_ts_ms: 0,
            twap_ts_ms: vector::empty<u64>(),
            twap_px_1e6: vector::empty<u64>(),
            trader_acc_per_eligible_1e18: 0,
            trader_total_eligible: 0,
            trader_rewards_pot: balance::zero<UNXV>(),
            trader_buffer_unxv: 0,
            initial_mark_1e6: initial_mark_1e6,
            ema_short_1e6: initial_mark_1e6,
            ema_long_1e6: initial_mark_1e6,
            last_mark_1e6: initial_mark_1e6,
            last_sample_minute_ms: 0,
        };
        event::emit(MarketInitialized { market_id: object::id(&m), expiry_ms, contract_size, initial_margin_bps, maintenance_margin_bps, liquidation_fee_bps, keeper_incentive_bps });
        transfer::share_object(m);
    }

    // ===== Admin updates =====
    public fun set_margins<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, initial_bps: u64, maint_bps: u64, liq_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.initial_margin_bps = initial_bps;
        market.maintenance_margin_bps = maint_bps;
        market.liquidation_fee_bps = liq_fee_bps;
    }

    public fun set_keeper_incentive_bps<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, keeper_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.keeper_incentive_bps = keeper_bps;
    }

    public fun set_notional_caps<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, account_max_notional_1e6: u128, market_max_notional_1e6: u128, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.account_max_notional_1e6 = account_max_notional_1e6;
        market.market_max_notional_1e6 = market_max_notional_1e6;
    }

    public fun set_share_of_oi_bps<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.account_share_of_oi_bps = share_bps;
    }

    public fun set_risk_tiers<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, thresholds_1e6: vector<u64>, im_bps: vector<u64>, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let n = vector::length(&thresholds_1e6);
        assert!(n == vector::length(&im_bps), E_INVALID_TIERS);
        if (n > 1) { let mut i: u64 = 1; while (i < n) { let prev_t = *vector::borrow(&thresholds_1e6, i - 1); let cur_t = *vector::borrow(&thresholds_1e6, i); let prev_b = *vector::borrow(&im_bps, i - 1); let cur_b = *vector::borrow(&im_bps, i); assert!(cur_t >= prev_t && cur_b >= prev_b, E_INVALID_TIERS); i = i + 1; }; };
        market.tier_thresholds_notional_1e6 = thresholds_1e6;
        market.tier_im_bps = im_bps;
    }

    /// Admin: set PnL reserve fee share (portion of Collat fees allocated to PnL bucket)
    public fun set_pnl_fee_share_bps<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.pnl_fee_share_bps = share_bps;
    }

    /// Admin: set EMA parameters on the synthetic index
    public fun set_ema_params<Collat>(reg_admin: &AdminRegistry, market: &mut XFutureMarket<Collat>, alpha_num: u64, alpha_den: u64, alpha_long_num: u64, alpha_long_den: u64, cap_multiple_bps: u64, mark_gate_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.series.alpha_num = alpha_num;
        market.series.alpha_den = alpha_den;
        market.series.alpha_long_num = alpha_long_num;
        market.series.alpha_long_den = alpha_long_den;
        market.series.cap_multiple_bps = cap_multiple_bps;
        market.series.mark_gate_bps = mark_gate_bps;
    }

    // ===== Collateral management =====
    public fun deposit_collateral<Collat>(market: &mut XFutureMarket<Collat>, c: Coin<Collat>, clock: &Clock, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        // Settle trader rewards before state change
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        acc.collat.join(coin::into_balance(c));
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralDeposited<Collat> { market_id: object::id(market), who: ctx.sender(), amount: amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    public fun withdraw_collateral<Collat>(market: &mut XFutureMarket<Collat>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<Collat> {
        assert!(amount > 0, E_ZERO);
        let price_1e6 = if (market.is_settled) { market.settlement_price_1e6 } else { synthetic_index_price_1e6(market) };
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        // Settle trader rewards before computing equity change
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        // compute equity and required initial margin after withdrawal
        let equity_before = equity_collat(&acc, price_1e6, market.series.contract_size);
        assert!(equity_before >= amount, E_INSUFFICIENT_BALANCE);
        let eq_after = equity_before - amount;
        let free_after = if (eq_after > acc.locked_im) { eq_after - acc.locked_im } else { 0 };
        let req_im = required_initial_margin_effective<Collat>(market, &acc, price_1e6);
        assert!(free_after >= req_im, E_UNDER_INITIAL_MARGIN);
        let part = balance::split(&mut acc.collat, amount);
        let coin_out = coin::from_balance(part, ctx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralWithdrawn<Collat> { market_id: object::id(market), who: ctx.sender(), amount, timestamp_ms: clock.timestamp_ms() });
        coin_out
    }

    // ===== Trading =====
    public fun open_long<Collat>(
        market: &mut XFutureMarket<Collat>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        taker_limit_trade<Collat>(market, /*is_buy=*/true, /*limit_price=*/max_order_price(), qty, /*expire_ts=*/clock.timestamp_ms() + 60_000, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv_fee, clock, ctx);
        option::destroy_none(maybe_unxv_fee);
    }

    public fun open_short<Collat>(
        market: &mut XFutureMarket<Collat>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        taker_limit_trade<Collat>(market, /*is_buy=*/false, /*limit_price=*/min_order_price(), qty, /*expire_ts=*/clock.timestamp_ms() + 60_000, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv_fee, clock, ctx);
        option::destroy_none(maybe_unxv_fee);
    }

    public fun close_long<Collat>(
        market: &mut XFutureMarket<Collat>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) { taker_limit_trade<Collat>(market, /*is_buy=*/false, /*limit_price=*/min_order_price(), qty, /*expire_ts=*/clock.timestamp_ms() + 60_000, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv_fee, clock, ctx); option::destroy_none(maybe_unxv_fee); }

    public fun close_short<Collat>(
        market: &mut XFutureMarket<Collat>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) { taker_limit_trade<Collat>(market, /*is_buy=*/true, /*limit_price=*/max_order_price(), qty, /*expire_ts=*/clock.timestamp_ms() + 60_000, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv_fee, clock, ctx); option::destroy_none(maybe_unxv_fee); }

    fun taker_limit_trade<Collat>(
        market: &mut XFutureMarket<Collat>,
        is_buy: bool,
        limit_price_1e6: u64,
        qty: u64,
        expire_ts: u64,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        maybe_unxv_fee: &mut Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(qty > 0, E_ZERO);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let now = clock.timestamp_ms();
        assert!(now <= market.series.expiry_ms, E_EXPIRED);
        // ensure we have a current index sample
        let _ = synthetic_index_price_1e6(market);
        // Plan fills
        let plan = ubk::compute_fill_plan(&market.book, is_buy, limit_price_1e6, qty, /*client_order_id*/0, expire_ts, now);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        // Settle trader rewards pre-trade
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        let index_px = synthetic_index_price_1e6(market);
        let mut total_notional_1e6: u128 = 0u128;
        // Maker rebates weights
        let mut rb_makers: vector<address> = vector::empty<address>();
        let mut rb_weights_1e6: vector<u128> = vector::empty<u128>();
        let fills_len = ubk::fillplan_num_fills(&plan);
        let mut total_qty: u64 = 0; let mut wsum_px_qty: u128 = 0u128;
        let mut i: u64 = 0;
        while (i < fills_len) {
            let f = ubk::fillplan_get_fill(&plan, i);
            let maker_id = ubk::fill_maker_id(&f);
            let px = ubk::fill_price(&f);
            let req_qty = ubk::fill_base_qty(&f);
            // Maker remaining pre-commit
            let (filled0, qty0) = ubk::order_progress(&market.book, maker_id);
            let maker_rem_before = if (qty0 > filled0) { qty0 - filled0 } else { 0 };
            let fqty = if (req_qty <= maker_rem_before) { req_qty } else { maker_rem_before };
            if (fqty == 0) { i = i + 1; continue };
            // Commit maker fill
            ubk::commit_maker_fill(&mut market.book, maker_id, is_buy, limit_price_1e6, fqty, now);
            let maker_addr = *table::borrow(&market.owners, maker_id);
            let mut maker_acc = take_or_new_account<Collat>(market, maker_addr);
            settle_trader_rewards_eligible<Collat>(market, &mut maker_acc);
            if (is_buy) {
                // Taker reduce short then add long
                let r = if (acc.short_qty > 0) { if (fqty <= acc.short_qty) { fqty } else { acc.short_qty } } else { 0 };
                if (r > 0) { let (g,l) = realize_short_ul(acc.avg_short_1e6, px, r, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, ctx.sender(), (g as u128), (l as u128), clock); apply_realized_to_account<Collat>(market, &mut acc, g, l, vault, clock, ctx); acc.short_qty = acc.short_qty - r; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r; };
                let a = if (fqty > r) { fqty - r } else { 0 };
                if (a > 0) { acc.avg_long_1e6 = weighted_avg_price(acc.avg_long_1e6, acc.long_qty, px, a); acc.long_qty = acc.long_qty + a; market.total_long_qty = market.total_long_qty + a; };
                // Maker reduce long then add short
                let r_m = if (maker_acc.long_qty > 0) { if (fqty <= maker_acc.long_qty) { fqty } else { maker_acc.long_qty } } else { 0 };
                if (r_m > 0) { let (g_m,l_m) = realize_long_ul(maker_acc.avg_long_1e6, px, r_m, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, maker_addr, (g_m as u128), (l_m as u128), clock); apply_realized_to_account<Collat>(market, &mut maker_acc, g_m, l_m, vault, clock, ctx); maker_acc.long_qty = maker_acc.long_qty - r_m; if (maker_acc.long_qty == 0) { maker_acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r_m; };
                let a_m = if (fqty > r_m) { fqty - r_m } else { 0 };
                if (a_m > 0) { maker_acc.avg_short_1e6 = weighted_avg_price(maker_acc.avg_short_1e6, maker_acc.short_qty, px, a_m); maker_acc.short_qty = maker_acc.short_qty + a_m; market.total_short_qty = market.total_short_qty + a_m; unlock_locked_im_for_fill<Collat>(market, &mut maker_acc, index_px, a_m); };
            } else {
                // Taker sell: reduce long then add short
                let r2 = if (acc.long_qty > 0) { if (fqty <= acc.long_qty) { fqty } else { acc.long_qty } } else { 0 };
                if (r2 > 0) { let (g2,l2) = realize_long_ul(acc.avg_long_1e6, px, r2, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, ctx.sender(), (g2 as u128), (l2 as u128), clock); apply_realized_to_account<Collat>(market, &mut acc, g2, l2, vault, clock, ctx); acc.long_qty = acc.long_qty - r2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r2; };
                let a2 = if (fqty > r2) { fqty - r2 } else { 0 };
                if (a2 > 0) { acc.avg_short_1e6 = weighted_avg_price(acc.avg_short_1e6, acc.short_qty, px, a2); acc.short_qty = acc.short_qty + a2; market.total_short_qty = market.total_short_qty + a2; };
                // Maker reduce short then add long
                let r_m2 = if (maker_acc.short_qty > 0) { if (fqty <= maker_acc.short_qty) { fqty } else { maker_acc.short_qty } } else { 0 };
                if (r_m2 > 0) { let (g_m2,l_m2) = realize_short_ul(maker_acc.avg_short_1e6, px, r_m2, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, maker_addr, (g_m2 as u128), (l_m2 as u128), clock); apply_realized_to_account<Collat>(market, &mut maker_acc, g_m2, l_m2, vault, clock, ctx); maker_acc.short_qty = maker_acc.short_qty - r_m2; if (maker_acc.short_qty == 0) { maker_acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r_m2; };
                let a_m2 = if (fqty > r_m2) { fqty - r_m2 } else { 0 };
                if (a_m2 > 0) { maker_acc.avg_long_1e6 = weighted_avg_price(maker_acc.avg_long_1e6, maker_acc.long_qty, px, a_m2); maker_acc.long_qty = maker_acc.long_qty + a_m2; market.total_long_qty = market.total_long_qty + a_m2; unlock_locked_im_for_fill<Collat>(market, &mut maker_acc, index_px, a_m2); };
            };
            // Update notional and rewards
            let per_unit_1e6: u128 = ((px as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
            total_notional_1e6 = total_notional_1e6 + (fqty as u128) * per_unit_1e6 * 1_000_000u128;
            let f_notional_1e6: u128 = (fqty as u128) * per_unit_1e6 * 1_000_000u128;
            // accumulate maker rebate weight
            let mut j: u64 = 0; let mut found: bool = false; let n_m = vector::length(&rb_makers);
            while (j < n_m) { if (*vector::borrow(&rb_makers, j) == maker_addr) { let w_ref: &mut u128 = vector::borrow_mut(&mut rb_weights_1e6, j); *w_ref = *w_ref + f_notional_1e6; found = true; break }; j = j + 1; };
            if (!found) { vector::push_back(&mut rb_makers, maker_addr); vector::push_back(&mut rb_weights_1e6, f_notional_1e6); };
            // maker improvement metric vs index
            let improve_bps: u64 = if (is_buy) { if (index_px >= px) { ((((index_px as u128) - (px as u128)) * 10_000u128) / (index_px as u128)) as u64 } else { 0 } } else { if (px >= index_px) { ((((px as u128) - (index_px as u128)) * 10_000u128) / (index_px as u128)) as u64 } else { 0 } };
            rewards::on_perp_fill(rewards_obj, ctx.sender(), maker_addr, f_notional_1e6, false, 0, clock);
            rewards::on_perp_fill(rewards_obj, maker_addr, ctx.sender(), f_notional_1e6, true, improve_bps, clock);
            // Persist maker
            update_trader_rewards_after_change<Collat>(market, &mut maker_acc, index_px);
            store_account<Collat>(market, maker_addr, maker_acc);
            if (!ubk::has_order(&market.book, maker_id)) { let _ = table::remove(&mut market.owners, maker_id); };
            // aggregates for VWAP
            total_qty = total_qty + fqty; wsum_px_qty = wsum_px_qty + (px as u128) * (fqty as u128);
            // per-fill event
            event::emit(OrderFilled { market_id: object::id(market), maker_order_id: maker_id, maker: maker_addr, taker: ctx.sender(), price_1e6: px, base_qty: fqty, timestamp_ms: now });
            i = i + 1;
        };

        // Caps enforcement
        let gross_acc_post: u64 = acc.long_qty + acc.short_qty;
        let gross_mkt_post: u64 = market.total_long_qty + market.total_short_qty;
        let per_unit_1e6_post: u128 = ((index_px as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let acc_notional_post_1e6: u128 = (gross_acc_post as u128) * per_unit_1e6_post * 1_000_000u128;
        let mkt_notional_post_1e6: u128 = (gross_mkt_post as u128) * per_unit_1e6_post * 1_000_000u128;
        if (market.account_max_notional_1e6 > 0) { assert!(acc_notional_post_1e6 <= market.account_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.market_max_notional_1e6 > 0) { assert!(mkt_notional_post_1e6 <= market.market_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.account_share_of_oi_bps > 0 && gross_mkt_post > 0) {
            let allowed_u128: u128 = ((gross_mkt_post as u128) * (market.account_share_of_oi_bps as u128)) / (fees::bps_denom() as u128);
            let allowed: u64 = allowed_u128 as u64;
            assert!(gross_acc_post <= allowed, E_EXPOSURE_CAP);
        };

        // Protocol fee + maker rebates
        let taker_bps = fees::futures_taker_fee_bps(cfg);
        let pay_with_unxv = option::is_some(maybe_unxv_fee);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt: u64 = ((total_notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let rebate_bps_cfg = fees::futures_maker_rebate_bps(cfg);
        let eff_rebate_bps: u64 = if (rebate_bps_cfg <= t_eff) { rebate_bps_cfg } else { t_eff };
        let total_rebate_collat: u64 = ((total_notional_1e6 * (eff_rebate_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        if (pay_with_unxv) {
            let mut u = option::extract(maybe_unxv_fee);
            let total_fee_unxv = coin::value(&u);
            let total_rebate_unxv: u64 = ((total_fee_unxv as u128) * (eff_rebate_bps as u128) / (fees::bps_denom() as u128)) as u64;
            if (total_rebate_unxv > 0 && vector::length(&rb_makers) > 0) {
                let mut rb_pool = coin::split(&mut u, total_rebate_unxv, ctx);
                let weights_sum: u128 = total_notional_1e6;
                let nmk = vector::length(&rb_makers);
                let mut k: u64 = 0; let mut paid_sum: u64 = 0;
                while (k < nmk) { let maker = *vector::borrow(&rb_makers, k); let w = *vector::borrow(&rb_weights_1e6, k); let mut pay_i: u64 = if (k + 1 == nmk) { total_rebate_unxv - paid_sum } else { (((w * (total_rebate_unxv as u128)) / weights_sum) as u64) }; if (pay_i > 0) { let c_i = coin::split(&mut rb_pool, pay_i, ctx); transfer::public_transfer(c_i, maker); paid_sum = paid_sum + pay_i; }; k = k + 1; };
                coin::destroy_zero(rb_pool);
            };
            let (stakers_coin, traders_coin, treasury_coin, _burn_amt) = fees::accrue_unxv_and_split_with_traders(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            let traders_amt = coin::value(&traders_coin);
            if (traders_amt > 0) {
                // accumulate centrally in FeeVault traders bank
                fees::traders_bank_deposit(vault, traders_coin);
            } else { coin::destroy_zero(traders_coin); };
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_units: (total_notional_1e6 / 1_000_000u128) as u64, fee_paid: 0, paid_in_unxv: true, timestamp_ms: clock.timestamp_ms() });
        } else {
            assert!(balance::value(&acc.collat) >= fee_amt, E_INSUFFICIENT_BALANCE);
            let part = balance::split(&mut acc.collat, fee_amt);
            let mut c = coin::from_balance(part, ctx);
            if (total_rebate_collat > 0 && vector::length(&rb_makers) > 0) {
                let mut rb_pool = coin::split(&mut c, total_rebate_collat, ctx);
                let weights_sum2: u128 = total_notional_1e6;
                let nmk2 = vector::length(&rb_makers);
                let mut k2: u64 = 0; let mut paid2: u64 = 0;
                while (k2 < nmk2) { let maker2 = *vector::borrow(&rb_makers, k2); let w2 = *vector::borrow(&rb_weights_1e6, k2); let mut pay2: u64 = if (k2 + 1 == nmk2) { total_rebate_collat - paid2 } else { (((w2 * (total_rebate_collat as u128)) / weights_sum2) as u64) }; if (pay2 > 0) { let c_i2 = coin::split(&mut rb_pool, pay2, ctx); transfer::public_transfer(c_i2, maker2); paid2 = paid2 + pay2; }; k2 = k2 + 1; };
                coin::destroy_zero(rb_pool);
            };
            let share_bps = market.pnl_fee_share_bps;
            if (share_bps > 0) {
                let share_amt: u64 = ((fee_amt as u128) * (share_bps as u128) / (fees::bps_denom() as u128)) as u64;
                if (share_amt > 0 && share_amt < fee_amt) {
                    let pnl_part = coin::split(&mut c, share_amt, ctx);
                    fees::pnl_deposit<Collat>(vault, pnl_part);
                    fees::route_fee<Collat>(vault, c, clock, ctx);
                } else if (share_amt >= fee_amt) {
                    fees::pnl_deposit<Collat>(vault, c);
                } else {
                    fees::route_fee<Collat>(vault, c, clock, ctx);
                };
            } else {
                fees::route_fee<Collat>(vault, c, clock, ctx);
            };
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_units: (total_notional_1e6 / 1_000_000u128) as u64, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: clock.timestamp_ms() });
        };

        // Margin check post-trade (use index)
        let eq = equity_collat(&acc, index_px, market.series.contract_size);
        let req = required_initial_margin_effective<Collat>(market, &acc, index_px);
        let free = if (eq > acc.locked_im) { eq - acc.locked_im } else { 0 };
        assert!(free >= req, E_UNDER_INITIAL_MARGIN);
        // Update taker eligible after changes
        update_trader_rewards_after_change<Collat>(market, &mut acc, index_px);
        // Record VWAP as mark sample for EMA & settlement buffers
        if (total_qty > 0) {
            let vwap: u64 = (wsum_px_qty / (total_qty as u128)) as u64;
            record_mark_internal(market, vwap, now);
            event::emit(PositionChanged { market_id: object::id(market), who: ctx.sender(), is_long: is_buy, qty_delta: total_qty, exec_price_1e6: vwap, timestamp_ms: now });
        };
        store_account<Collat>(market, ctx.sender(), acc);
    }

    // ===== Liquidation =====
    public fun liquidate<Collat>(
        market: &mut XFutureMarket<Collat>,
        victim: address,
        qty: u64,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        rewards_obj: &mut rewards::Rewards,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        assert!(qty > 0, E_ZERO);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let now = clock.timestamp_ms();
        assert!(now < market.series.expiry_ms, E_EXPIRED);
        let px_1e6 = synthetic_index_price_1e6(market);
        let mut acc = table::remove(&mut market.accounts, victim);
        // Hard-stop trader rewards under MM: settle, zero pending, and remove eligibility from total
        let prev_el: u128 = eligible_amount_usd_approx<Collat>(market, &acc, px_1e6) as u128;
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        acc.trader_pending_unxv = 0;
        if (prev_el > 0 && market.trader_total_eligible >= prev_el) { market.trader_total_eligible = market.trader_total_eligible - prev_el; };
        acc.trader_last_eligible = 0; acc.trader_reward_debt_1e18 = market.trader_acc_per_eligible_1e18;
        // Check maintenance margin
        let eq = equity_collat(&acc, px_1e6, market.series.contract_size);
        let req_mm = required_initial_margin_bps(&acc, px_1e6, market.series.contract_size, market.maintenance_margin_bps);
        assert!(eq < req_mm, E_UNDER_MAINT_MARGIN);

        // Determine minimal close qty to restore margin (approximate)
        let per_contract_val: u64 = ((px_1e6 as u128) * (market.series.contract_size as u128) / 1_000_000u128) as u64;
        let req_pc: u64 = ((per_contract_val as u128) * (market.initial_margin_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let close_long_pref = acc.long_qty >= acc.short_qty;

        let mut closed: u64 = 0; let mut realized_gain: u64 = 0; let mut realized_loss: u64 = 0;
        if (req_pc == 0) {
            // Close up to qty on larger side
            if (acc.long_qty >= acc.short_qty) {
                let c = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
                if (c > 0) { let (g,l) = realize_long_ul(acc.avg_long_1e6, px_1e6, c, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, victim, (g as u128), (l as u128), clock); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
            } else {
                let c2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
                if (c2 > 0) { let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px_1e6, c2, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, victim, (g2 as u128), (l2 as u128), clock); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
            };
        } else {
            // Conservative ceil_div of shortfall by per-contract margin
            let gross_before = ((acc.long_qty as u128) + (acc.short_qty as u128)) * (px_1e6 as u128) * (market.series.contract_size as u128) / 1_000_000u128;
            let req0: u128 = (gross_before * (market.initial_margin_bps as u128)) / (fees::bps_denom() as u128);
            let eq0: u128 = (eq as u128);
            let shortfall: u128 = if (eq0 >= req0) { 0u128 } else { req0 - eq0 };
            let need_c: u64 = if (req_pc > 0) { let den = req_pc as u128; let num = shortfall + den - 1u128; (num / den) as u64 } else { qty };
            if (close_long_pref && acc.long_qty > 0) {
                let cmax = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
                let c = if (need_c > 0 && need_c <= cmax) { need_c } else { cmax };
                if (c > 0) { let (g,l) = realize_long_ul(acc.avg_long_1e6, px_1e6, c, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, victim, (g as u128), (l as u128), clock); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
            } else if (acc.short_qty > 0) {
                let cmax2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
                let c2 = if (need_c > 0 && need_c <= cmax2) { need_c } else { cmax2 };
                if (c2 > 0) { let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px_1e6, c2, market.series.contract_size); rewards::on_realized_pnl(rewards_obj, victim, (g2 as u128), (l2 as u128), clock); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
            };
        };

        apply_realized_to_account<Collat>(market, &mut acc, realized_gain, realized_loss, vault, clock, ctx);

        // Penalty and routing
        let per_unit_1e6: u128 = ((px_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let notional_1e6 = (closed as u128) * per_unit_1e6 * 1_000_000u128;
        let pen = ((notional_1e6 * (market.liquidation_fee_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let available = balance::value(&acc.collat);
        let pay = if (pen <= available) { pen } else { available };
        if (pay > 0) {
            let keeper_bps: u64 = market.keeper_incentive_bps;
            let keeper_cut: u64 = ((pay as u128) * (keeper_bps as u128) / (fees::bps_denom() as u128)) as u64;
            let treasury_bps: u64 = fees::liq_treasury_bps(cfg);
            let treasury_cut: u64 = ((pay as u128) * (treasury_bps as u128) / (fees::bps_denom() as u128)) as u64;
            let mut pen_coin = coin::from_balance(balance::split(&mut acc.collat, pay), ctx);
            if (keeper_cut > 0) { let kc = coin::split(&mut pen_coin, keeper_cut, ctx); transfer::public_transfer(kc, ctx.sender()); };
            if (treasury_cut > 0) { let tc = coin::split(&mut pen_coin, treasury_cut, ctx); fees::route_fee<Collat>(vault, tc, clock, ctx); };
            fees::pnl_deposit<Collat>(vault, pen_coin);
        };

        store_account<Collat>(market, victim, acc);
        event::emit(Liquidated { market_id: object::id(market), who: victim, qty_closed: closed, exec_price_1e6: px_1e6, penalty_collat: pay, timestamp_ms: clock.timestamp_ms() });
        let notional_liq_1e6: u128 = (closed as u128) * per_unit_1e6 * 1_000_000u128;
        rewards::on_liquidation(rewards_obj, ctx.sender(), notional_liq_1e6, clock);
    }

    // ===== Expiry settlement =====
    /// Entry: snap canonical settlement price once after expiry; cancels resting orders and unlocks maker IM
    /// Settlement selection: prefer Last Valid Print (<= expiry). If missing, fall back to pre-expiry TWAP.
    public fun snap_settlement_price<Collat>(market: &mut XFutureMarket<Collat>, clock: &Clock, _ctx: &mut TxContext) {
        let now = clock.timestamp_ms();
        assert!(market.series.expiry_ms > 0 && now >= market.series.expiry_ms, E_EXPIRED);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        // Compute settlement from recorded pre-expiry synthetic samples
        let px = if (market.lvp_ts_ms > 0 && market.lvp_ts_ms <= market.series.expiry_ms) {
            market.lvp_price_1e6
        } else {
            let tw = compute_twap_in_window(&market.twap_ts_ms, &market.twap_px_1e6, market.series.expiry_ms, TWAP_WINDOW_MS);
            if (tw > 0) { tw } else { synthetic_index_price_1e6(market) }
        };
        market.settlement_price_1e6 = px;
        market.is_settled = true;
        // Drain all orders and unlock IM to makers
        let cancels = ubk::drain_all_collect(&mut market.book, 1_000_000);
        let mut i: u64 = 0; let n = vector::length(&cancels);
        while (i < n) {
            let c = *vector::borrow(&cancels, i);
            let oid = ubk::cancel_order_id(&c);
            if (table::contains(&market.owners, oid)) {
                let maker = *table::borrow(&market.owners, oid);
                let rem = ubk::cancel_remaining_qty(&c);
                if (rem > 0) {
                    let mut acc = take_or_new_account<Collat>(market, maker);
                    let unlock = im_for_qty(&market.series, rem, px, market.initial_margin_bps);
                    if (acc.locked_im >= unlock) { acc.locked_im = acc.locked_im - unlock; } else { acc.locked_im = 0; };
                    store_account<Collat>(market, maker, acc);
                };
                let _ = table::remove(&mut market.owners, oid);
            };
            i = i + 1;
        };
    }

    /// User-triggered settlement to flatten positions and realize PnL with credit fallback
    public fun settle_self<Collat>(market: &mut XFutureMarket<Collat>, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.accounts, ctx.sender()), E_NO_ACCOUNT);
        assert!(market.is_settled, E_ALREADY_SETTLED);
        let px = market.settlement_price_1e6;
        let mut acc = table::remove(&mut market.accounts, ctx.sender());
        let lq = acc.long_qty; let sq = acc.short_qty;
        let (g1,l1) = realize_long_ul(acc.avg_long_1e6, px, lq, market.series.contract_size);
        let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px, sq, market.series.contract_size);
        let g = g1 + g2; let l = l1 + l2;
        if (lq > 0) { market.total_long_qty = market.total_long_qty - lq; acc.long_qty = 0; acc.avg_long_1e6 = 0; };
        if (sq > 0) { market.total_short_qty = market.total_short_qty - sq; acc.short_qty = 0; acc.avg_short_1e6 = 0; };
        apply_realized_to_account<Collat>(market, &mut acc, g, l, vault, clock, ctx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(Settled { market_id: object::id(market), who: ctx.sender(), price_1e6: px, timestamp_ms: clock.timestamp_ms() });
    }

    // ===== Keeper utilities: synthetic index sampling =====
    /// Record a synthetic mark sample and push to LVP/TWAP buffers pre-expiry
    public fun record_mark_sample<Collat>(market: &mut XFutureMarket<Collat>, sample_price_1e6: u64, clock: &Clock, _ctx: &mut TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        record_mark_internal(market, sample_price_1e6, now);
    }

    /// Update last index price without trading, for off-chain keepers
    public fun update_index_price<Collat>(market: &mut XFutureMarket<Collat>, sample_price_1e6: u64, clock: &Clock, _ctx: &mut TxContext) {
        let now = clock.timestamp_ms();
        record_mark_internal(market, sample_price_1e6, now);
    }

    // ===== Views & helpers =====
    fun equity_collat<Collat>(acc: &Account<Collat>, price_1e6: u64, contract_size: u64): u64 {
        let coll = balance::value(&acc.collat);
        let (g_long, l_long) = if (acc.long_qty == 0) { (0, 0) } else { realize_long_ul(acc.avg_long_1e6, price_1e6, acc.long_qty, contract_size) };
        let (g_short, l_short) = if (acc.short_qty == 0) { (0, 0) } else { realize_short_ul(acc.avg_short_1e6, price_1e6, acc.short_qty, contract_size) };
        let gains: u128 = (g_long as u128) + (g_short as u128);
        let losses: u128 = (l_long as u128) + (l_short as u128);
        if (gains <= losses) { let net_loss = (losses - gains) as u64; if (coll > net_loss) { coll - net_loss } else { 0 } } else { let net_gain = (gains - losses) as u64; coll + net_gain }
    }

    fun required_initial_margin_bps<Collat>(acc: &Account<Collat>, price_1e6: u64, contract_size: u64, bps: u64): u64 {
        let size_u128 = (acc.long_qty as u128) + (acc.short_qty as u128);
        let gross = size_u128 * (price_1e6 as u128) * (contract_size as u128);
        let im_1e6 = (gross * (bps as u128) / (fees::bps_denom() as u128));
        (im_1e6 / 1_000_000u128) as u64
    }

    fun required_initial_margin_effective<Collat>(market: &XFutureMarket<Collat>, acc: &Account<Collat>, price_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((price_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let gross_contracts: u64 = acc.long_qty + acc.short_qty;
        let acc_notional_1e6: u128 = (gross_contracts as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, acc_notional_1e6);
        let mut base = market.initial_margin_bps;
        if (tier_bps > base) { base = tier_bps; };
        required_initial_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, base)
    }

    fun tier_bps_for_notional<Collat>(market: &XFutureMarket<Collat>, notional_1e6: u128): u64 {
        let n = vector::length(&market.tier_thresholds_notional_1e6);
        if (n == 0) return market.initial_margin_bps;
        let mut i: u64 = 0; let mut out: u64 = market.initial_margin_bps;
        while (i < n) { let th_1e6 = *vector::borrow(&market.tier_thresholds_notional_1e6, i); if (notional_1e6 >= (th_1e6 as u128)) { out = *vector::borrow(&market.tier_im_bps, i); }; i = i + 1; };
        out
    }

    fun realize_long_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, contract_size: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (exit_1e6 >= entry_1e6) { let diff = exit_1e6 - entry_1e6; let gain_1e6 = (diff as u128) * (qty as u128) * (contract_size as u128); ((gain_1e6 / 1_000_000u128) as u64, 0) } else { let diff2 = entry_1e6 - exit_1e6; let loss_1e6 = (diff2 as u128) * (qty as u128) * (contract_size as u128); (0, (loss_1e6 / 1_000_000u128) as u64) }
    }

    fun realize_short_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, contract_size: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (entry_1e6 >= exit_1e6) { let diff = entry_1e6 - exit_1e6; let gain_1e6 = (diff as u128) * (qty as u128) * (contract_size as u128); ((gain_1e6 / 1_000_000u128) as u64, 0) } else { let diff2 = exit_1e6 - entry_1e6; let loss_1e6 = (diff2 as u128) * (qty as u128) * (contract_size as u128); (0, (loss_1e6 / 1_000_000u128) as u64) }
    }

    fun weighted_avg_price(prev_px_1e6: u64, prev_qty: u64, new_px_1e6: u64, new_qty: u64): u64 {
        if (prev_qty == 0) { return new_px_1e6 };
        let num = (prev_px_1e6 as u128) * (prev_qty as u128) + (new_px_1e6 as u128) * (new_qty as u128);
        let den = (prev_qty as u128) + (new_qty as u128);
        (num / den) as u64
    }

    fun max_order_price(): u64 { ((1u128 << 63) - 1) as u64 }
    fun min_order_price(): u64 { 1 }

    fun apply_realized_to_account<Collat>(market: &XFutureMarket<Collat>, acc: &mut Account<Collat>, gain: u64, loss: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        if (loss > 0) {
            let have = balance::value(&acc.collat);
            let pay_loss = if (loss <= have) { loss } else { have };
            if (pay_loss > 0) { let bal_loss = balance::split(&mut acc.collat, pay_loss); let coin_loss = coin::from_balance(bal_loss, ctx); fees::pnl_deposit<Collat>(vault, coin_loss); };
        };
        if (gain > 0) {
            let avail = fees::pnl_available<Collat>(vault);
            let pay = if (gain <= avail) { gain } else { avail };
            if (pay > 0) { let coin_gain = fees::pnl_withdraw<Collat>(vault, pay, ctx); acc.collat.join(coin::into_balance(coin_gain)); let rem_after = if (acc.pending_credit > 0) { acc.pending_credit } else { 0 }; event::emit(PnlCreditPaid<Collat> { market_id: object::id(market), who: ctx.sender(), amount: pay, remaining_credit: rem_after, timestamp_ms: clock.timestamp_ms() }); };
            if (gain > pay) { let credit = gain - pay; acc.pending_credit = acc.pending_credit + credit; event::emit(PnlCreditAccrued<Collat> { market_id: object::id(market), who: ctx.sender(), credited: credit, remaining_credit: acc.pending_credit, timestamp_ms: clock.timestamp_ms() }); };
        };
    }

    fun take_or_new_account<Collat>(market: &mut XFutureMarket<Collat>, who: address): Account<Collat> {
        if (table::contains(&market.accounts, who)) { table::remove(&mut market.accounts, who) } else { Account { collat: balance::zero<Collat>(), long_qty: 0, short_qty: 0, avg_long_1e6: 0, avg_short_1e6: 0, pending_credit: 0, locked_im: 0, trader_reward_debt_1e18: 0, trader_pending_unxv: 0, trader_last_eligible: 0 } }
    }

    fun store_account<Collat>(market: &mut XFutureMarket<Collat>, who: address, acc: Account<Collat>) { table::add(&mut market.accounts, who, acc); }

    fun im_for_qty(series: &XSeries, qty: u64, price_1e6: u64, im_bps: u64): u64 {
        let gross_1e6: u128 = (qty as u128) * (price_1e6 as u128) * (series.contract_size as u128);
        let im_1e6: u128 = (gross_1e6 * (im_bps as u128)) / (fees::bps_denom() as u128);
        (im_1e6 / 1_000_000u128) as u64
    }

    fun im_for_qty_tiered<Collat>(market: &XFutureMarket<Collat>, acc: &Account<Collat>, qty: u64, price_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((price_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let gross_after: u64 = acc.long_qty + acc.short_qty + qty;
        let notional_after_1e6: u128 = (gross_after as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, notional_after_1e6);
        let mut eff_bps = market.initial_margin_bps;
        if (tier_bps > eff_bps) { eff_bps = tier_bps; };
        im_for_qty(&market.series, qty, price_1e6, eff_bps)
    }

    fun unlock_locked_im_for_fill<Collat>(market: &XFutureMarket<Collat>, acc: &mut Account<Collat>, price_1e6: u64, added_qty: u64) {
        if (added_qty == 0) return;
        let im = im_for_qty(&market.series, added_qty, price_1e6, market.initial_margin_bps);
        if (acc.locked_im >= im) { acc.locked_im = acc.locked_im - im; } else { acc.locked_im = 0; };
    }

    // ===== Synthetic index helpers =====
    public fun synthetic_index_price_1e6<Collat>(market: &XFutureMarket<Collat>): u64 {
        let short = market.ema_short_1e6;
        let long = market.ema_long_1e6;
        if (long == 0) { return short; };
        let cap = ((long as u128) * (market.series.cap_multiple_bps as u128) / (fees::bps_denom() as u128)) as u64;
        if (short <= cap) { short } else { cap }
    }

    fun record_mark_internal<Collat>(market: &mut XFutureMarket<Collat>, sample_price_1e6: u64, now_ms: u64) {
        // Gate vs last_mark if configured
        let gate = market.series.mark_gate_bps; let last = market.last_mark_1e6;
        if (gate > 0 && last > 0) { let hi = if (sample_price_1e6 >= last) { sample_price_1e6 } else { last }; let lo = if (sample_price_1e6 >= last) { last } else { sample_price_1e6 }; let diff = hi - lo; let dev_bps: u64 = ((diff as u128) * (fees::bps_denom() as u128) / (last as u128)) as u64; assert!(dev_bps <= gate, E_MARK_GATE); };
        // minute bucket idempotence
        let minute_ms = (now_ms / 60_000) * 60_000;
        if (market.last_sample_minute_ms != 0 && minute_ms == market.last_sample_minute_ms) { market.last_mark_1e6 = sample_price_1e6; return; };
        market.last_sample_minute_ms = minute_ms; market.last_mark_1e6 = sample_price_1e6;
        // EMA update
        let es = ema_update(market.ema_short_1e6, sample_price_1e6, market.series.alpha_num, market.series.alpha_den);
        let el = ema_update(market.ema_long_1e6, sample_price_1e6, market.series.alpha_long_num, market.series.alpha_long_den);
        market.ema_short_1e6 = es; market.ema_long_1e6 = el;
        // Pre-expiry buffers for settlement
        if (market.series.expiry_ms == 0 || now_ms <= market.series.expiry_ms) {
            market.lvp_price_1e6 = sample_price_1e6; market.lvp_ts_ms = now_ms;
            twap_append(&mut market.twap_ts_ms, &mut market.twap_px_1e6, now_ms, sample_price_1e6, market.series.expiry_ms);
        };
    }

    fun ema_update(prev: u64, sample: u64, alpha_num: u64, alpha_den: u64): u64 {
        if (alpha_den == 0) { return sample; };
        let den = alpha_den as u128; let num = alpha_num as u128;
        let prev_part = (prev as u128) * (den - num);
        let samp_part = (sample as u128) * num;
        let sum = prev_part + samp_part;
        (sum / den) as u64
    }

    fun twap_append(ts: &mut vector<u64>, px: &mut vector<u64>, now: u64, price_1e6: u64, expiry_ms: u64) {
        // push sample
        vector::push_back(ts, now); vector::push_back(px, price_1e6);
        // trim by count
        let mut n = vector::length(ts);
        if (n > TWAP_MAX_SAMPLES) { let remove = n - TWAP_MAX_SAMPLES; let mut i: u64 = 0; while (i < remove) { let _ = vector::remove(ts, 0); let _2 = vector::remove(px, 0); i = i + 1; }; n = vector::length(ts); };
        // trim by window (pre-expiry only)
        let window_start = if (expiry_ms > 0) { if (TWAP_WINDOW_MS < expiry_ms) { expiry_ms - TWAP_WINDOW_MS } else { 0 } } else { if (TWAP_WINDOW_MS < now) { now - TWAP_WINDOW_MS } else { 0 } };
        while (vector::length(ts) > 0) { let oldest = *vector::borrow(ts, 0); if (oldest >= window_start) break; let _ = vector::remove(ts, 0); let _3 = vector::remove(px, 0); };
    }

    fun compute_twap_in_window(ts: &vector<u64>, px: &vector<u64>, end_ms: u64, window_ms: u64): u64 {
        let n = vector::length(ts); if (n == 0) return 0;
        let start_ms = if (window_ms < end_ms) { end_ms - window_ms } else { 0 };
        let mut i: u64 = 0; let mut sum_weighted: u128 = 0; let mut sum_dt: u128 = 0; let mut prev_t = start_ms; let mut prev_px = *vector::borrow(px, 0);
        while (i < n) { let t = *vector::borrow(ts, i); let p = *vector::borrow(px, i); if (t < start_ms) { i = i + 1; prev_t = t; prev_px = p; continue }; let dt = if (t > prev_t) { (t - prev_t) as u128 } else { 0u128 }; sum_weighted = sum_weighted + dt * (prev_px as u128); sum_dt = sum_dt + dt; prev_t = t; prev_px = p; i = i + 1; };
        let tail_dt = if (end_ms > prev_t) { (end_ms - prev_t) as u128 } else { 0u128 }; sum_weighted = sum_weighted + tail_dt * (prev_px as u128); sum_dt = sum_dt + tail_dt; if (sum_dt == 0) return *vector::borrow(px, n - 1); (sum_weighted / sum_dt) as u64
    }

    // ===== Trader rewards helpers =====
    fun eligible_amount_usd_approx<Collat>(market: &XFutureMarket<Collat>, acc: &Account<Collat>, index_1e6: u64): u64 {
        let eq = equity_collat(acc, index_1e6, market.series.contract_size);
        let req = required_initial_margin_effective<Collat>(market, acc, index_1e6);
        if (eq <= req) { eq } else { req }
    }

    fun settle_trader_rewards_eligible<Collat>(market: &mut XFutureMarket<Collat>, acc: &mut Account<Collat>) {
        let eligible_prev = (acc.trader_last_eligible as u128);
        if (eligible_prev > 0) {
            let accu = market.trader_acc_per_eligible_1e18;
            let debt = acc.trader_reward_debt_1e18;
            if (accu > debt) { let delta_1e18: u128 = accu - debt; let earn_u128: u128 = (eligible_prev * delta_1e18) / 1_000_000_000_000_000_000u128; let max_u64: u128 = 18_446_744_073_709_551_615u128; let add: u64 = if (earn_u128 > max_u64) { 18_446_744_073_709_551_615u64 } else { earn_u128 as u64 }; acc.trader_pending_unxv = acc.trader_pending_unxv + add; };
        };
    }

    fun update_trader_rewards_after_change<Collat>(market: &mut XFutureMarket<Collat>, acc: &mut Account<Collat>, index_1e6: u64) {
        let old_el = acc.trader_last_eligible as u128;
        if (old_el > 0 && market.trader_total_eligible >= old_el) { market.trader_total_eligible = market.trader_total_eligible - old_el; };
        let new_el_u64 = eligible_amount_usd_approx<Collat>(market, acc, index_1e6);
        let new_el = new_el_u64 as u128;
        if (new_el > 0) { market.trader_total_eligible = market.trader_total_eligible + new_el; acc.trader_reward_debt_1e18 = market.trader_acc_per_eligible_1e18; } else { acc.trader_reward_debt_1e18 = market.trader_acc_per_eligible_1e18; };
        if (market.trader_buffer_unxv > 0 && market.trader_total_eligible > 0) { let buf = market.trader_buffer_unxv as u128; let delta = (buf * 1_000_000_000_000_000_000u128) / market.trader_total_eligible; market.trader_acc_per_eligible_1e18 = market.trader_acc_per_eligible_1e18 + delta; market.trader_buffer_unxv = 0; };
        acc.trader_last_eligible = new_el_u64;
    }

    /// Claim trader rewards in UNXV up to `max_amount` (0 = all)
    public fun claim_trader_rewards<Collat>(market: &mut XFutureMarket<Collat>, clock: &Clock, ctx: &mut TxContext, max_amount: u64): Coin<UNXV> {
        assert!(table::contains(&market.accounts, ctx.sender()), E_NO_ACCOUNT);
        let mut acc = table::remove(&mut market.accounts, ctx.sender());
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        let want = if (max_amount == 0 || max_amount > acc.trader_pending_unxv) { acc.trader_pending_unxv } else { max_amount };
        assert!(want > 0, E_NO_REWARDS);
        let pot_avail = balance::value(&market.trader_rewards_pot);
        let pay = if (want <= pot_avail) { want } else { pot_avail };
        if (pay > 0) {
            let part = balance::split(&mut market.trader_rewards_pot, pay);
            let out = coin::from_balance(part, ctx);
            acc.trader_pending_unxv = acc.trader_pending_unxv - pay;
            event::emit(TraderRewardsClaimed { market_id: object::id(market), who: ctx.sender(), amount_unxv: pay, pending_left: acc.trader_pending_unxv, timestamp_ms: clock.timestamp_ms() });
            store_account<Collat>(market, ctx.sender(), acc);
            out
        } else { store_account<Collat>(market, ctx.sender(), acc); coin::zero<UNXV>(ctx) }
    }

    /// Keeper/public: deposit UNXV into the trader rewards pot and update accumulator
    public fun deposit_trader_rewards<Collat>(market: &mut XFutureMarket<Collat>, mut unxv: Coin<UNXV>, clock: &Clock, _ctx: &mut TxContext) {
        let amt = coin::value(&unxv);
        assert!(amt > 0, E_ZERO);
        let bal = coin::into_balance(unxv);
        market.trader_rewards_pot.join(bal);
        if (market.trader_total_eligible > 0) { let delta: u128 = ((amt as u128) * 1_000_000_000_000_000_000u128) / market.trader_total_eligible; market.trader_acc_per_eligible_1e18 = market.trader_acc_per_eligible_1e18 + delta; } else { market.trader_buffer_unxv = market.trader_buffer_unxv + amt; };
        event::emit(TraderRewardsDeposited { market_id: object::id(market), amount_unxv: amt, total_eligible: market.trader_total_eligible, acc_1e18: market.trader_acc_per_eligible_1e18, timestamp_ms: clock.timestamp_ms() });
    }
}


