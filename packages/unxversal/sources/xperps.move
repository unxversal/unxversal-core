/// Module: unxversal_xperps
/// ------------------------------------------------------------
/// Synthetic perpetual swaps ("xperps") that do not rely on an external
/// oracle. Instead, they maintain an internal exponentially weighted moving
/// average (EMA) of the market's own mark prices and use that as the index
/// price for margin, liquidation, and funding.
///
/// Design highlights:
/// - On-chain orderbook (unxversal::book) for matching; taker-only protocol fee.
/// - Internal EMA-based index with two time scales:
///   - Short EMA (default ~8h, alpha = 1/480 per minute)
///   - Long EMA (default ~30d, alpha = 1/43200 per minute)
///   The effective index is min(short_ema, long_ema * cap_multiple).
/// - Funding is derived from the deviation between last mark and EMA, applied
///   at a configurable funding interval. Longs pay when mark > EMA, shorts pay
///   when mark < EMA. Funding is accounted per contract in 1e6 units similar to
///   unxversal::perpetuals.
/// - Full margin, liquidation, maker rebates, staking/UNXV fee discounts,
///   and trader rewards integration.
#[allow(lint(self_transfer))]
module unxversal::xperps {
    use sui::{
        clock::Clock,
        coin::{Self as coin, Coin},
        balance::{Self as balance, Balance},
        event,
        table::{Self as table, Table},
    };

    

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
    const E_INSUFFICIENT: u64 = 4;
    const E_UNDER_IM: u64 = 5;
    const E_UNDER_MM: u64 = 6;
    const E_EXPOSURE_CAP: u64 = 7;
    const E_INVALID_TIERS: u64 = 8;
    const E_MARK_GATE: u64 = 9;           // mark sample outside gate

    // ===== Synthetic index configuration =====
    /// Per-minute EMA smoothing factors represented as rational alpha = num/den.
    /// Defaults approximate an 8h time constant for short EMA and ~30d for long EMA.
    const DEFAULT_ALPHA_NUM: u64 = 1;          // alpha_short = 1/480 per minute
    const DEFAULT_ALPHA_DEN: u64 = 480;
    const DEFAULT_ALPHA_LONG_NUM: u64 = 1;     // alpha_long = 1/43200 per minute
    const DEFAULT_ALPHA_LONG_DEN: u64 = 43200; // 30 days of minutes
    /// Cap of short EMA to long EMA multiplier, in bps (e.g., 40000 = 4.0x)
    const DEFAULT_CAP_MULTIPLE_BPS: u64 = 40000;
    /// Mark sample change gating vs last_mark in bps (0 disables)
    const DEFAULT_MARK_GATE_BPS: u64 = 0;

    // ===== Market parameters =====
    public struct XPerpParams has copy, drop, store {
        /// Quote units per 1 contract per 1e6 price unit
        contract_size: u64,
        /// Target funding interval (ms) used by the keeper when auto-updating funding
        funding_interval_ms: u64,
        /// EMA smoothing factors (per minute)
        alpha_num: u64,
        alpha_den: u64,
        alpha_long_num: u64,
        alpha_long_den: u64,
        /// Cap of short EMA relative to long EMA (bps)
        cap_multiple_bps: u64,
        /// Mark sample gate (bps) vs last mark (0 disables)
        mark_gate_bps: u64,
    }

    /// Per-account state
    public struct XPerpAccount<phantom Collat> has store {
        collat: Balance<Collat>,
        long_qty: u64,
        short_qty: u64,
        avg_long_1e6: u64,
        avg_short_1e6: u64,
        last_cum_long_pay_1e6: u128,  // funding index snapshots
        last_cum_short_pay_1e6: u128,
        funding_credit: u64,          // accrued but unpaid credit
        locked_im: u64,
        /// Trader rewards accounting
        trader_reward_debt_1e18: u128,
        trader_pending_unxv: u64,
        trader_last_eligible: u64,
    }

    /// Market shared object
    public struct XPerpMarket<phantom Collat> has key, store {
        id: UID,
        params: XPerpParams,
        accounts: Table<address, XPerpAccount<Collat>>,
        // Risk params
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        keeper_incentive_bps: u64,
        /// Max notional caps (1e6 units). 0 disables.
        account_max_notional_1e6: u128,
        market_max_notional_1e6: u128,
        account_share_of_oi_bps: u64,
        /// Tiered IM
        tier_thresholds_notional_1e6: vector<u64>,
        tier_im_bps: vector<u64>,
        /// OI tracking
        total_long_qty: u64,
        total_short_qty: u64,
        /// Orderbook & maker ownership
        book: Book,
        owners: Table<u128, address>,
        // Funding indexes
        cum_long_pay_1e6: u128,
        cum_short_pay_1e6: u128,
        last_funding_ms: u64,
        funding_vault: Balance<Collat>,
        // Trader rewards state (UNXV-based)
        trader_acc_per_eligible_1e18: u128,
        trader_total_eligible: u128,
        trader_rewards_pot: Balance<UNXV>,
        trader_buffer_unxv: u64,
        // Synthetic index state
        initial_mark_1e6: u64,       // sticky until first real sample is taken
        ema_short_1e6: u64,
        ema_long_1e6: u64,
        last_mark_1e6: u64,
        last_sample_minute_ms: u64,   // floor(timestamp_ms / 60000) * 60000
    }

    // ===== Events =====
    public struct XPerpInitialized has copy, drop { market_id: ID, contract_size: u64, funding_interval_ms: u64, initial_mark_1e6: u64, alpha_num: u64, alpha_den: u64, alpha_long_num: u64, alpha_long_den: u64, cap_multiple_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct OrderPlaced has copy, drop { market_id: ID, order_id: u128, maker: address, is_bid: bool, price_1e6: u64, quantity: u64, expire_ts: u64 }
    public struct OrderCanceled has copy, drop { market_id: ID, order_id: u128, maker: address, remaining_qty: u64, timestamp_ms: u64 }
    public struct OrderFilled has copy, drop { market_id: ID, maker_order_id: u128, maker: address, taker: address, price_1e6: u64, base_qty: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, timestamp_ms: u64 }
    public struct FundingIndexUpdated has copy, drop { market_id: ID, longs_pay: bool, delta_1e6: u64, cum_long_pay_1e6: u128, cum_short_pay_1e6: u128, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_1e6: u128, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct TraderRewardsDeposited has copy, drop { market_id: ID, amount_unxv: u64, total_eligible: u128, acc_1e18: u128, timestamp_ms: u64 }
    public struct TraderRewardsClaimed has copy, drop { market_id: ID, who: address, amount_unxv: u64, pending_left: u64, timestamp_ms: u64 }
    public struct FundingSettled has copy, drop { market_id: ID, who: address, amount_paid: u64, amount_credited: u64, credit_left: u64, timestamp_ms: u64 }
    /// PnL credit lifecycle when PnL vault shortfall prevents full payout immediately
    public struct PnlCreditAccrued<phantom Collat> has copy, drop { market_id: ID, who: address, credited: u64, remaining_credit: u64, timestamp_ms: u64 }
    public struct PnlCreditPaid<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, remaining_credit: u64, timestamp_ms: u64 }

    // ===== Init =====
    public fun init_market<Collat>(
        reg_admin: &AdminRegistry,
        contract_size: u64,
        funding_interval_ms: u64,
        initial_mark_1e6: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        im_bps: u64,
        mm_bps: u64,
        liq_fee_bps: u64,
        keeper_bps: u64,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
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

        let params = XPerpParams {
            contract_size,
            funding_interval_ms,
            alpha_num: DEFAULT_ALPHA_NUM,
            alpha_den: DEFAULT_ALPHA_DEN,
            alpha_long_num: DEFAULT_ALPHA_LONG_NUM,
            alpha_long_den: DEFAULT_ALPHA_LONG_DEN,
            cap_multiple_bps: DEFAULT_CAP_MULTIPLE_BPS,
            mark_gate_bps: DEFAULT_MARK_GATE_BPS,
        };

        let m = XPerpMarket<Collat> {
            id: object::new(ctx),
            params: params,
            accounts: table::new<address, XPerpAccount<Collat>>(ctx),
            initial_margin_bps: im_bps,
            maintenance_margin_bps: mm_bps,
            liquidation_fee_bps: liq_fee_bps,
            keeper_incentive_bps: keeper_bps,
            account_max_notional_1e6: 0,
            market_max_notional_1e6: 0,
            account_share_of_oi_bps: 300,
            tier_thresholds_notional_1e6: tier_thresholds,
            tier_im_bps: tier_bps,
            total_long_qty: 0,
            total_short_qty: 0,
            book: ubk::empty(tick_size, lot_size, min_size, ctx),
            owners: table::new<u128, address>(ctx),
            cum_long_pay_1e6: 0,
            cum_short_pay_1e6: 0,
            last_funding_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            funding_vault: balance::zero<Collat>(),
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
        event::emit(XPerpInitialized {
            market_id: object::id(&m),
            contract_size,
            funding_interval_ms,
            initial_mark_1e6,
            alpha_num: DEFAULT_ALPHA_NUM,
            alpha_den: DEFAULT_ALPHA_DEN,
            alpha_long_num: DEFAULT_ALPHA_LONG_NUM,
            alpha_long_den: DEFAULT_ALPHA_LONG_DEN,
            cap_multiple_bps: DEFAULT_CAP_MULTIPLE_BPS,
        });
        transfer::share_object(m);
    }

    // ===== Admin updates =====
    public fun set_margins<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.initial_margin_bps = im_bps;
        market.maintenance_margin_bps = mm_bps;
        market.liquidation_fee_bps = liq_fee_bps;
    }

    public fun set_keeper_incentive_bps<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, keeper_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.keeper_incentive_bps = keeper_bps;
    }

    public fun set_notional_caps<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, account_max_notional_1e6: u128, market_max_notional_1e6: u128, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.account_max_notional_1e6 = account_max_notional_1e6;
        market.market_max_notional_1e6 = market_max_notional_1e6;
    }

    public fun set_share_of_oi_bps<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.account_share_of_oi_bps = share_bps;
    }

    public fun set_risk_tiers<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, thresholds_1e6: vector<u64>, im_bps: vector<u64>, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let n = vector::length(&thresholds_1e6);
        assert!(n == vector::length(&im_bps), E_INVALID_TIERS);
        if (n > 1) {
            let mut i: u64 = 1;
            while (i < n) {
                let prev_t = *vector::borrow(&thresholds_1e6, i - 1);
                let cur_t = *vector::borrow(&thresholds_1e6, i);
                let prev_b = *vector::borrow(&im_bps, i - 1);
                let cur_b = *vector::borrow(&im_bps, i);
                assert!(cur_t >= prev_t && cur_b >= prev_b, E_INVALID_TIERS);
                i = i + 1;
            };
        };
        market.tier_thresholds_notional_1e6 = thresholds_1e6;
        market.tier_im_bps = im_bps;
    }

    /// Admin: set EMA parameters and caps
    public fun set_ema_params<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, alpha_num: u64, alpha_den: u64, alpha_long_num: u64, alpha_long_den: u64, cap_multiple_bps: u64, mark_gate_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.params.alpha_num = alpha_num;
        market.params.alpha_den = alpha_den;
        market.params.alpha_long_num = alpha_long_num;
        market.params.alpha_long_den = alpha_long_den;
        market.params.cap_multiple_bps = cap_multiple_bps;
        market.params.mark_gate_bps = mark_gate_bps;
    }

    // ===== Collateral =====
    public fun deposit_collateral<Collat>(market: &mut XPerpMarket<Collat>, c: Coin<Collat>, clock: &Clock, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        // settle trader rewards and funding snapshots first
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        let (_paid, _credited) = settle_funding_user_internal<Collat>(market, &mut acc, ctx);
        acc.collat.join(coin::into_balance(c));
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralDeposited<Collat> { market_id: object::id(market), who: ctx.sender(), amount: amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    public fun withdraw_collateral<Collat>(market: &mut XPerpMarket<Collat>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<Collat> {
        assert!(amount > 0, E_ZERO);
        let px = synthetic_index_price_1e6(market);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let (_paid1, _cred1) = settle_funding_user_internal<Collat>(market, &mut acc, ctx);
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        let eq = equity_collat(&acc, px, market.params.contract_size);
        assert!(eq >= amount, E_INSUFFICIENT);
        let eq_after = eq - amount;
        let free_after = if (eq_after > acc.locked_im) { eq_after - acc.locked_im } else { 0 };
        let req_im = required_margin_effective<Collat>(market, &acc, px);
        assert!(free_after >= req_im, E_UNDER_IM);
        let part = balance::split(&mut acc.collat, amount);
        let out = coin::from_balance(part, ctx);
        update_trader_rewards_after_change<Collat>(market, &mut acc, px);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralWithdrawn<Collat> { market_id: object::id(market), who: ctx.sender(), amount, timestamp_ms: sui::clock::timestamp_ms(clock) });
        out
    }

    // ===== Trading (matched orderbook) =====
    public fun open_long<Collat>(market: &mut XPerpMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, rewards_obj: &mut rewards::Rewards, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        taker_trade_internal<Collat>(market, true, qty, ((1u128 << 63) - 1) as u64, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun open_short<Collat>(market: &mut XPerpMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, rewards_obj: &mut rewards::Rewards, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        taker_trade_internal<Collat>(market, false, qty, 1, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun close_long<Collat>(market: &mut XPerpMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, rewards_obj: &mut rewards::Rewards, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        taker_trade_internal<Collat>(market, false, qty, 1, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun close_short<Collat>(market: &mut XPerpMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, rewards_obj: &mut rewards::Rewards, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        taker_trade_internal<Collat>(market, true, qty, ((1u128 << 63) - 1) as u64, cfg, vault, staking_pool, rewards_obj, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    fun taker_trade_internal<Collat>(
        market: &mut XPerpMarket<Collat>,
        is_buy: bool,
        qty: u64,
        limit_price_1e6: u64,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        maybe_unxv: &mut Option<Coin<UNXV>>, 
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(qty > 0, E_ZERO);
        // Plan fills
        let now = sui::clock::timestamp_ms(clock);
        let plan = ubk::compute_fill_plan(&market.book, is_buy, limit_price_1e6, qty, 0, now + 60_000, now);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        // settle funding & trader rewards before mutations
        let (_paid, _cred) = settle_funding_user_internal<Collat>(market, &mut acc, ctx);
        settle_trader_rewards_eligible<Collat>(market, &mut acc);

        let mut total_notional_1e6: u128 = 0u128;
        let mut rb_makers: vector<address> = vector::empty<address>();
        let mut rb_weights_1e6: vector<u128> = vector::empty<u128>();
        let mut total_qty: u64 = 0; let mut wsum_px_qty: u128 = 0u128;
        let idx_before = synthetic_index_price_1e6(market);
        let fills_len = ubk::fillplan_num_fills(&plan);
        let mut i: u64 = 0;
        while (i < fills_len) {
            let f = ubk::fillplan_get_fill(&plan, i);
            let maker_id = ubk::fill_maker_id(&f);
            let px = ubk::fill_price(&f);
            let req_qty = ubk::fill_base_qty(&f);
            let (filled0, qty0) = ubk::order_progress(&market.book, maker_id);
            let maker_rem_before = if (qty0 > filled0) { qty0 - filled0 } else { 0 };
            let fqty = if (req_qty <= maker_rem_before) { req_qty } else { maker_rem_before };
            if (fqty == 0) { i = i + 1; continue };
            ubk::commit_maker_fill(&mut market.book, maker_id, is_buy, limit_price_1e6, fqty, now);
            let maker_addr = *table::borrow(&market.owners, maker_id);
            let mut maker_acc = load_or_new_account<Collat>(market, maker_addr);
            settle_trader_rewards_eligible<Collat>(market, &mut maker_acc);
            if (is_buy) {
                // taker reduce short then add long
                let r = if (acc.short_qty > 0) { if (fqty <= acc.short_qty) { fqty } else { acc.short_qty } } else { 0 };
                if (r > 0) { let (g,l) = realize_short_ul(acc.avg_short_1e6, px, r, market.params.contract_size); rewards::on_realized_pnl(rewards_obj, ctx.sender(), (g as u128), (l as u128), clock); apply_realized_to_account<Collat>(market, &mut acc, g, l, vault, clock, ctx); acc.short_qty = acc.short_qty - r; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r; };
                let a = if (fqty > r) { fqty - r } else { 0 };
                if (a > 0) { acc.avg_long_1e6 = wavg(acc.avg_long_1e6, acc.long_qty, px, a); acc.long_qty = acc.long_qty + a; market.total_long_qty = market.total_long_qty + a; };
                // maker reduce long then add short
                let r_m = if (maker_acc.long_qty > 0) { if (fqty <= maker_acc.long_qty) { fqty } else { maker_acc.long_qty } } else { 0 };
                if (r_m > 0) { let (g_m,l_m) = realize_long_ul(maker_acc.avg_long_1e6, px, r_m, market.params.contract_size); rewards::on_realized_pnl(rewards_obj, maker_addr, (g_m as u128), (l_m as u128), clock); apply_realized_to_account<Collat>(market, &mut maker_acc, g_m, l_m, vault, clock, ctx); maker_acc.long_qty = maker_acc.long_qty - r_m; if (maker_acc.long_qty == 0) { maker_acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r_m; };
                let a_m = if (fqty > r_m) { fqty - r_m } else { 0 };
                if (a_m > 0) { maker_acc.avg_short_1e6 = wavg(maker_acc.avg_short_1e6, maker_acc.short_qty, px, a_m); maker_acc.short_qty = maker_acc.short_qty + a_m; market.total_short_qty = market.total_short_qty + a_m; };
            } else {
                // taker sell: reduce long then add short
                let r2 = if (acc.long_qty > 0) { if (fqty <= acc.long_qty) { fqty } else { acc.long_qty } } else { 0 };
                if (r2 > 0) { let (g2,l2) = realize_long_ul(acc.avg_long_1e6, px, r2, market.params.contract_size); rewards::on_realized_pnl(rewards_obj, ctx.sender(), (g2 as u128), (l2 as u128), clock); apply_realized_to_account<Collat>(market, &mut acc, g2, l2, vault, clock, ctx); acc.long_qty = acc.long_qty - r2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r2; };
                let a2 = if (fqty > r2) { fqty - r2 } else { 0 };
                if (a2 > 0) { acc.avg_short_1e6 = wavg(acc.avg_short_1e6, acc.short_qty, px, a2); acc.short_qty = acc.short_qty + a2; market.total_short_qty = market.total_short_qty + a2; };
                // maker reduce short then add long
                let r_m2 = if (maker_acc.short_qty > 0) { if (fqty <= maker_acc.short_qty) { fqty } else { maker_acc.short_qty } } else { 0 };
                if (r_m2 > 0) { let (g_m2,l_m2) = realize_short_ul(maker_acc.avg_short_1e6, px, r_m2, market.params.contract_size); rewards::on_realized_pnl(rewards_obj, maker_addr, (g_m2 as u128), (l_m2 as u128), clock); apply_realized_to_account<Collat>(market, &mut maker_acc, g_m2, l_m2, vault, clock, ctx); maker_acc.short_qty = maker_acc.short_qty - r_m2; if (maker_acc.short_qty == 0) { maker_acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r_m2; };
                let a_m2 = if (fqty > r_m2) { fqty - r_m2 } else { 0 };
                if (a_m2 > 0) { maker_acc.avg_long_1e6 = wavg(maker_acc.avg_long_1e6, maker_acc.long_qty, px, a_m2); maker_acc.long_qty = maker_acc.long_qty + a_m2; market.total_long_qty = market.total_long_qty + a_m2; };
            };
            // Notional and rewards
            let per_unit_1e6: u128 = ((px as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
            let f_notional_1e6: u128 = (fqty as u128) * per_unit_1e6 * 1_000_000u128;
            total_notional_1e6 = total_notional_1e6 + f_notional_1e6;
            let idx_px = idx_before; // for maker improvement calc use pre-trade index
            let improve_bps: u64 = if (is_buy) {
                if (idx_px >= px) { ((((idx_px as u128) - (px as u128)) * 10_000u128) / (idx_px as u128)) as u64 } else { 0 }
            } else {
                if (px >= idx_px) { ((((px as u128) - (idx_px as u128)) * 10_000u128) / (idx_px as u128)) as u64 } else { 0 }
            };
            rewards::on_perp_fill(rewards_obj, ctx.sender(), maker_addr, f_notional_1e6, false, 0, clock);
            rewards::on_perp_fill(rewards_obj, maker_addr, ctx.sender(), f_notional_1e6, true, improve_bps, clock);
            // Accumulate for maker rebates
            let mut j: u64 = 0; let mut found: bool = false; let n_m = vector::length(&rb_makers);
            while (j < n_m) { if (*vector::borrow(&rb_makers, j) == maker_addr) { let wref = vector::borrow_mut(&mut rb_weights_1e6, j); *wref = *wref + f_notional_1e6; found = true; break }; j = j + 1; };
            if (!found) { vector::push_back(&mut rb_makers, maker_addr); vector::push_back(&mut rb_weights_1e6, f_notional_1e6); };
            // Persist maker account
            update_trader_rewards_after_change<Collat>(market, &mut maker_acc, idx_before);
            store_account<Collat>(market, maker_addr, maker_acc);
            if (!ubk::has_order(&market.book, maker_id)) { let _ = table::remove(&mut market.owners, maker_id); };
            // VWAP aggregates
            total_qty = total_qty + fqty;
            wsum_px_qty = wsum_px_qty + (px as u128) * (fqty as u128);
            event::emit(OrderFilled { market_id: object::id(market), maker_order_id: maker_id, maker: maker_addr, taker: ctx.sender(), price_1e6: px, base_qty: fqty, timestamp_ms: now });
            i = i + 1;
        };

        // Enforce caps
        let px_index = synthetic_index_price_1e6(market);
        let gross_acc_post: u64 = acc.long_qty + acc.short_qty;
        let gross_mkt_post: u64 = market.total_long_qty + market.total_short_qty;
        let per_unit_1e6_post: u128 = ((px_index as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
        let acc_notional_post_1e6: u128 = (gross_acc_post as u128) * per_unit_1e6_post * 1_000_000u128;
        let mkt_notional_post_1e6: u128 = (gross_mkt_post as u128) * per_unit_1e6_post * 1_000_000u128;
        if (market.account_max_notional_1e6 > 0) { assert!(acc_notional_post_1e6 <= market.account_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.market_max_notional_1e6 > 0) { assert!(mkt_notional_post_1e6 <= market.market_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.account_share_of_oi_bps > 0 && gross_mkt_post > 0) {
            let allowed_u128: u128 = ((gross_mkt_post as u128) * (market.account_share_of_oi_bps as u128)) / (fees::bps_denom() as u128);
            let allowed: u64 = allowed_u128 as u64;
            assert!(gross_acc_post <= allowed, E_EXPOSURE_CAP);
        };

        // Fees & maker rebates
        let taker_bps = fees::futures_taker_fee_bps(cfg); // reuse futures taker schedule
        let pay_with_unxv = option::is_some(maybe_unxv);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt: u64 = ((total_notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let rebate_bps_cfg = fees::perps_maker_rebate_bps(cfg);
        let eff_rebate_bps: u64 = if (rebate_bps_cfg <= t_eff) { rebate_bps_cfg } else { t_eff };
        if (pay_with_unxv) {
            let mut u = option::extract(maybe_unxv);
            let total_fee_unxv = coin::value(&u);
            let total_rebate_unxv: u64 = ((total_fee_unxv as u128) * (eff_rebate_bps as u128) / (fees::bps_denom() as u128)) as u64;
            if (total_rebate_unxv > 0 && vector::length(&rb_makers) > 0) {
                let mut rb_pool = coin::split(&mut u, total_rebate_unxv, ctx);
                let wsum: u128 = total_notional_1e6; let n = vector::length(&rb_makers);
                let mut k: u64 = 0; let mut paid: u64 = 0;
                while (k < n) { let mk = *vector::borrow(&rb_makers, k); let w = *vector::borrow(&rb_weights_1e6, k); let mut pay_i: u64 = if (k + 1 == n) { total_rebate_unxv - paid } else { (((w * (total_rebate_unxv as u128)) / wsum) as u64) }; if (pay_i > 0) { let c_i = coin::split(&mut rb_pool, pay_i, ctx); transfer::public_transfer(c_i, mk); paid = paid + pay_i; }; k = k + 1; };
                coin::destroy_zero(rb_pool);
            };
            let (stakers_coin, traders_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split_with_traders(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            let t_amt = coin::value(&traders_coin);
            if (t_amt > 0) { fees::traders_bank_deposit(vault, traders_coin); } else { coin::destroy_zero(traders_coin); };
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6: total_notional_1e6, fee_paid: 0, paid_in_unxv: true, timestamp_ms: now });
        } else {
            assert!(balance::value(&acc.collat) >= fee_amt, E_INSUFFICIENT);
            let part = balance::split(&mut acc.collat, fee_amt);
            let mut c = coin::from_balance(part, ctx);
            let total_rebate_collat: u64 = ((total_notional_1e6 * (eff_rebate_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
            if (total_rebate_collat > 0 && vector::length(&rb_makers) > 0) {
                let mut rb_pool = coin::split(&mut c, total_rebate_collat, ctx);
                let wsum2: u128 = total_notional_1e6; let n2 = vector::length(&rb_makers); let mut k2: u64 = 0; let mut paid2: u64 = 0;
                while (k2 < n2) { let mk2 = *vector::borrow(&rb_makers, k2); let w2 = *vector::borrow(&rb_weights_1e6, k2); let mut pay2: u64 = if (k2 + 1 == n2) { total_rebate_collat - paid2 } else { (((w2 * (total_rebate_collat as u128)) / wsum2) as u64) }; if (pay2 > 0) { let c_i2 = coin::split(&mut rb_pool, pay2, ctx); transfer::public_transfer(c_i2, mk2); paid2 = paid2 + pay2; }; k2 = k2 + 1; };
                coin::destroy_zero(rb_pool);
            };
            fees::route_fee<Collat>(vault, c, clock, ctx);
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6: total_notional_1e6, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: now });
        };

        // Margin check after fills
        let px_mark = synthetic_index_price_1e6(market);
        let eq = equity_collat(&acc, px_mark, market.params.contract_size);
        let req_im = required_margin_effective<Collat>(market, &acc, px_mark);
        let free = if (eq > acc.locked_im) { eq - acc.locked_im } else { 0 };
        assert!(free >= req_im, E_UNDER_IM);

        // Emit PositionChanged with VWAP if any fill
        if (total_qty > 0) {
            let vwap: u64 = (wsum_px_qty / (total_qty as u128)) as u64;
            event::emit(PositionChanged { market_id: object::id(market), who: ctx.sender(), is_long: is_buy, qty_delta: total_qty, exec_price_1e6: vwap, timestamp_ms: now });
            // Record mark sample from trade VWAP
            record_mark_internal(market, vwap, now);
        };

        update_trader_rewards_after_change<Collat>(market, &mut acc, px_mark);
        store_account<Collat>(market, ctx.sender(), acc);
    }

    // ===== Funding =====
    /// Keeper/admin: apply funding delta directly (per contract, 1e6 scale)
    public fun apply_funding_update<Collat>(reg_admin: &AdminRegistry, market: &mut XPerpMarket<Collat>, longs_pay: bool, delta_1e6: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        if (longs_pay) { market.cum_long_pay_1e6 = market.cum_long_pay_1e6 + (delta_1e6 as u128); } else { market.cum_short_pay_1e6 = market.cum_short_pay_1e6 + (delta_1e6 as u128); };
        market.last_funding_ms = sui::clock::timestamp_ms(clock);
        event::emit(FundingIndexUpdated { market_id: object::id(market), longs_pay, delta_1e6, cum_long_pay_1e6: market.cum_long_pay_1e6, cum_short_pay_1e6: market.cum_short_pay_1e6, timestamp_ms: market.last_funding_ms });
    }

    /// Keeper: compute and apply funding based on mark vs EMA for elapsed intervals.
    /// premium_per_interval_bps: maximum absolute bps applied per funding interval.
    public fun update_funding_auto<Collat>(market: &mut XPerpMarket<Collat>, premium_per_interval_bps: u64, clock: &Clock, _ctx: &mut TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        let last = market.last_funding_ms;
        let fim = market.params.funding_interval_ms;
        if (fim == 0) { return; };
        if (now <= last) { return; };
        let elapsed = now - last;
        let mut intervals: u64 = elapsed / fim;
        if (intervals == 0) { intervals = 1; };
        let mark = market.last_mark_1e6;
        let ema = synthetic_index_price_1e6(market);
        if (ema == 0) { market.last_funding_ms = now; return; };
        let mut diff_abs: u128 = if (mark >= ema) { (mark as u128) - (ema as u128) } else { (ema as u128) - (mark as u128) };
        let prem_bps: u64 = ((diff_abs * (premium_per_interval_bps as u128) / (ema as u128)) as u64);
        let mut applied_bps: u64 = prem_bps;
        // clamp to configured per-call cap
        if (applied_bps > premium_per_interval_bps) { applied_bps = premium_per_interval_bps; };
        let per_interval_delta_1e6: u64 = (((ema as u128) * (applied_bps as u128) / (fees::bps_denom() as u128)) as u64);
        let delta_total: u64 = (per_interval_delta_1e6 as u128 * (intervals as u128)) as u64;
        if (delta_total > 0) {
            let longs_pay = mark > ema;
            if (longs_pay) { market.cum_long_pay_1e6 = market.cum_long_pay_1e6 + (delta_total as u128); } else { market.cum_short_pay_1e6 = market.cum_short_pay_1e6 + (delta_total as u128); };
            event::emit(FundingIndexUpdated { market_id: object::id(market), longs_pay, delta_1e6: delta_total, cum_long_pay_1e6: market.cum_long_pay_1e6, cum_short_pay_1e6: market.cum_short_pay_1e6, timestamp_ms: now });
        };
        market.last_funding_ms = now;
    }

    /// Settle funding for caller and optionally pull from funding vault if available.
    public fun settle_funding_for_caller<Collat>(market: &mut XPerpMarket<Collat>, clock: &Clock, ctx: &mut TxContext): u64 {
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let (paid_long, credited_short) = settle_funding_user_internal<Collat>(market, &mut acc, ctx);
        let mut paid_out: u64 = 0;
        if (acc.funding_credit > 0) {
            let avail = balance::value(&market.funding_vault);
            let pay = if (acc.funding_credit <= avail) { acc.funding_credit } else { avail };
            if (pay > 0) { let part = balance::split(&mut market.funding_vault, pay); acc.collat.join(part); acc.funding_credit = acc.funding_credit - pay; paid_out = pay; };
        };
        let final_credit = acc.funding_credit;
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(FundingSettled { market_id: object::id(market), who: ctx.sender(), amount_paid: paid_long, amount_credited: credited_short + paid_out, credit_left: final_credit, timestamp_ms: sui::clock::timestamp_ms(clock) });
        credited_short + paid_out
    }

    // ===== Liquidation =====
    public fun liquidate<Collat>(market: &mut XPerpMarket<Collat>, victim: address, cfg: &FeeConfig, vault: &mut FeeVault, rewards_obj: &mut rewards::Rewards, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        let px = synthetic_index_price_1e6(market);
        let mut acc = table::remove(&mut market.accounts, victim);
        // settle funding first for fairness
        let (_p,_c) = settle_funding_user_internal<Collat>(market, &mut acc, ctx);
        // stop trader rewards accrual
        let prev_el: u128 = eligible_amount_usd_approx<Collat>(market, &acc, px) as u128;
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        acc.trader_pending_unxv = 0; acc.trader_last_eligible = 0; acc.trader_reward_debt_1e18 = market.trader_acc_per_eligible_1e18;
        if (prev_el > 0 && market.trader_total_eligible >= prev_el) { market.trader_total_eligible = market.trader_total_eligible - prev_el; };
        let eq = equity_collat(&acc, px, market.params.contract_size);
        let req_mm = required_margin_bps(&acc, px, market.params.contract_size, market.maintenance_margin_bps);
        assert!(eq < req_mm, E_UNDER_MM);
        // Close from larger side up to qty
        let mut closed: u64 = 0;
        if (acc.long_qty >= acc.short_qty) {
            let c = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
            if (c > 0) { let (_g,_l) = realize_long_ul(acc.avg_long_1e6, px, c, market.params.contract_size); acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
        } else {
            let c2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
            if (c2 > 0) { let (_g2,_l2) = realize_short_ul(acc.avg_short_1e6, px, c2, market.params.contract_size); acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
        };
        // Penalty: split keeper & treasury via FeeVault, remainder to PnL bucket
        let notional_1e6 = (closed as u128) * (px as u128) * (market.params.contract_size as u128);
        let pen = ((notional_1e6 * (market.liquidation_fee_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let have = balance::value(&acc.collat);
        let pay = if (pen <= have) { pen } else { have };
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
        event::emit(Liquidated { market_id: object::id(market), who: victim, qty_closed: closed, exec_price_1e6: px, penalty_collat: pay, timestamp_ms: sui::clock::timestamp_ms(clock) });
        let notional_liq_1e6: u128 = (closed as u128) * (px as u128) * (market.params.contract_size as u128);
        rewards::on_liquidation(rewards_obj, ctx.sender(), notional_liq_1e6, clock);
    }

    // ===== Maker order APIs =====
    public fun place_limit_bid<Collat>(market: &mut XPerpMarket<Collat>, price_1e6: u64, qty: u64, expire_ts: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        let now = sui::clock::timestamp_ms(clock);
        assert!(expire_ts > now, E_ZERO);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let idx = synthetic_index_price_1e6(market);
        let need = im_for_qty_tiered<Collat>(market, &acc, qty, idx);
        let eq = equity_collat(&acc, idx, market.params.contract_size);
        let free = if (eq > acc.locked_im) { eq - acc.locked_im } else { 0 };
        assert!(free >= need, E_UNDER_IM);
        acc.locked_im = acc.locked_im + need;
        store_account<Collat>(market, ctx.sender(), acc);
        let mut order = ubk::new_order(true, price_1e6, 0, qty, expire_ts);
        ubk::create_order(&mut market.book, &mut order, now);
        let oid = ubk::order_id_of(&order);
        table::add(&mut market.owners, oid, ctx.sender());
        event::emit(OrderPlaced { market_id: object::id(market), order_id: oid, maker: ctx.sender(), is_bid: true, price_1e6, quantity: qty, expire_ts });
    }

    public fun place_limit_ask<Collat>(market: &mut XPerpMarket<Collat>, price_1e6: u64, qty: u64, expire_ts: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        let now = sui::clock::timestamp_ms(clock);
        assert!(expire_ts > now, E_ZERO);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let idx = synthetic_index_price_1e6(market);
        let need = im_for_qty_tiered<Collat>(market, &acc, qty, idx);
        let eq = equity_collat(&acc, idx, market.params.contract_size);
        let free = if (eq > acc.locked_im) { eq - acc.locked_im } else { 0 };
        assert!(free >= need, E_UNDER_IM);
        acc.locked_im = acc.locked_im + need;
        store_account<Collat>(market, ctx.sender(), acc);
        let mut order = ubk::new_order(false, price_1e6, 0, qty, expire_ts);
        ubk::create_order(&mut market.book, &mut order, now);
        let oid = ubk::order_id_of(&order);
        table::add(&mut market.owners, oid, ctx.sender());
        event::emit(OrderPlaced { market_id: object::id(market), order_id: oid, maker: ctx.sender(), is_bid: false, price_1e6, quantity: qty, expire_ts });
    }

    public fun cancel_order<Collat>(market: &mut XPerpMarket<Collat>, order_id: u128, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.owners, order_id), E_NO_ACCOUNT);
        let owner = *table::borrow(&market.owners, order_id);
        assert!(owner == ctx.sender(), E_NOT_ADMIN);
        let (filled, qty) = ubk::order_progress(&market.book, order_id);
        let remaining = if (qty > filled) { qty - filled } else { 0 };
        let idx = synthetic_index_price_1e6(market);
        let unlock = im_for_qty(&market.params, remaining, idx, market.initial_margin_bps);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        if (acc.locked_im >= unlock) { acc.locked_im = acc.locked_im - unlock; } else { acc.locked_im = 0; };
        let _ord = ubk::cancel_order(&mut market.book, order_id);
        table::remove(&mut market.owners, order_id);
        update_trader_rewards_after_change<Collat>(market, &mut acc, idx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(OrderCanceled { market_id: object::id(market), order_id, maker: owner, remaining_qty: remaining, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    // ===== Keeper utilities: synthetic mark sampling =====
    /// Keeper/public: record a new mark sample for EMA update.
    /// Applies mark gate if configured and ensures minute-bucket idempotence.
    public fun record_mark_sample<Collat>(market: &mut XPerpMarket<Collat>, sample_price_1e6: u64, clock: &Clock, _ctx: &mut TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        record_mark_internal(market, sample_price_1e6, now);
    }

    fun record_mark_internal<Collat>(market: &mut XPerpMarket<Collat>, sample_price_1e6: u64, now_ms: u64) {
        // mark gating vs last_mark
        let gate = market.params.mark_gate_bps;
        let last = market.last_mark_1e6;
        if (gate > 0 && last > 0) {
            let hi = if (sample_price_1e6 >= last) { sample_price_1e6 } else { last };
            let lo = if (sample_price_1e6 >= last) { last } else { sample_price_1e6 };
            let diff = hi - lo;
            let dev_bps: u64 = ((diff as u128) * (fees::bps_denom() as u128) / (last as u128)) as u64;
            assert!(dev_bps <= gate, E_MARK_GATE);
        };
        // minute bucket
        let minute_ms = (now_ms / 60_000) * 60_000;
        if (market.last_sample_minute_ms != 0 && minute_ms == market.last_sample_minute_ms) {
            // Same minute: update last_mark only (avoid double-counting EMA within bucket)
            market.last_mark_1e6 = sample_price_1e6;
            return;
        };
        market.last_sample_minute_ms = minute_ms;
        market.last_mark_1e6 = sample_price_1e6;
        // EMA update: ema_new = ema_old*(1-alpha) + sample*alpha
        let a_n = market.params.alpha_num; let a_d = market.params.alpha_den;
        let al_n = market.params.alpha_long_num; let al_d = market.params.alpha_long_den;
        let es = ema_update(market.ema_short_1e6, sample_price_1e6, a_n, a_d);
        let el = ema_update(market.ema_long_1e6, sample_price_1e6, al_n, al_d);
        market.ema_short_1e6 = es; market.ema_long_1e6 = el;
    }

    fun ema_update(prev: u64, sample: u64, alpha_num: u64, alpha_den: u64): u64 {
        if (alpha_den == 0) { return sample; };
        // (prev*(den-num) + sample*num) / den
        let den = alpha_den as u128; let num = alpha_num as u128;
        let prev_part = (prev as u128) * (den - num);
        let samp_part = (sample as u128) * num;
        let sum = prev_part + samp_part;
        (sum / den) as u64
    }

    // ===== Views & helpers =====
    public fun synthetic_index_price_1e6<Collat>(market: &XPerpMarket<Collat>): u64 {
        let short = market.ema_short_1e6;
        let long = market.ema_long_1e6;
        if (long == 0) { return short; };
        // cap = long * cap_multiple
        let cap = ((long as u128) * (market.params.cap_multiple_bps as u128) / (fees::bps_denom() as u128)) as u64;
        if (short <= cap) { short } else { cap }
    }

    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    fun equity_collat<Collat>(acc: &XPerpAccount<Collat>, px_1e6: u64, cs: u64): u64 {
        let mut eq: u64 = balance::value(&acc.collat);
        if (acc.long_qty > 0) {
            if (px_1e6 >= acc.avg_long_1e6) {
                let diff: u64 = px_1e6 - acc.avg_long_1e6;
                let gain_1e6: u128 = (diff as u128) * (acc.long_qty as u128) * (cs as u128);
                let gain: u64 = (gain_1e6 / 1_000_000u128) as u64;
                let room: u64 = if (U64_MAX_LITERAL > eq) { U64_MAX_LITERAL - eq } else { 0 };
                eq = if (gain > room) { U64_MAX_LITERAL } else { eq + gain };
            } else {
                let diff2: u64 = acc.avg_long_1e6 - px_1e6;
                let loss_1e6: u128 = (diff2 as u128) * (acc.long_qty as u128) * (cs as u128);
                let loss: u64 = (loss_1e6 / 1_000_000u128) as u64;
                eq = if (eq > loss) { eq - loss } else { 0 };
            };
        };
        if (acc.short_qty > 0) {
            if (acc.avg_short_1e6 >= px_1e6) {
                let diff3: u64 = acc.avg_short_1e6 - px_1e6;
                let gain2_1e6: u128 = (diff3 as u128) * (acc.short_qty as u128) * (cs as u128);
                let gain2: u64 = (gain2_1e6 / 1_000_000u128) as u64;
                let room2: u64 = if (U64_MAX_LITERAL > eq) { U64_MAX_LITERAL - eq } else { 0 };
                eq = if (gain2 > room2) { U64_MAX_LITERAL } else { eq + gain2 };
            } else {
                let diff4: u64 = px_1e6 - acc.avg_short_1e6;
                let loss2_1e6: u128 = (diff4 as u128) * (acc.short_qty as u128) * (cs as u128);
                let loss2: u64 = (loss2_1e6 / 1_000_000u128) as u64;
                eq = if (eq > loss2) { eq - loss2 } else { 0 };
            };
        };
        eq
    }

    fun required_margin_bps<Collat>(acc: &XPerpAccount<Collat>, px_1e6: u64, cs: u64, bps: u64): u64 {
        let qty_sum: u128 = (acc.long_qty as u128) + (acc.short_qty as u128);
        let gross: u128 = qty_sum * (px_1e6 as u128) * (cs as u128);
        let im_1e6: u128 = (gross * (bps as u128)) / (fees::bps_denom() as u128);
        let im: u128 = im_1e6 / 1_000_000u128;
        if (im > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { im as u64 }
    }

    fun required_margin_effective<Collat>(market: &XPerpMarket<Collat>, acc: &XPerpAccount<Collat>, px_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((px_1e6 as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
        let gross_contracts: u64 = acc.long_qty + acc.short_qty;
        let acc_notional_1e6: u128 = (gross_contracts as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, acc_notional_1e6);
        let mut base = market.initial_margin_bps;
        if (tier_bps > base) { base = tier_bps; };
        required_margin_bps<Collat>(acc, px_1e6, market.params.contract_size, base)
    }

    fun tier_bps_for_notional<Collat>(market: &XPerpMarket<Collat>, notional_1e6: u128): u64 {
        let n = vector::length(&market.tier_thresholds_notional_1e6);
        if (n == 0) return market.initial_margin_bps;
        let mut i: u64 = 0; let mut out: u64 = market.initial_margin_bps;
        while (i < n) { let th_1e6 = *vector::borrow(&market.tier_thresholds_notional_1e6, i); if (notional_1e6 >= (th_1e6 as u128)) { out = *vector::borrow(&market.tier_im_bps, i); }; i = i + 1; };
        out
    }

    fun realize_long_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (exit_1e6 >= entry_1e6) { let diff = exit_1e6 - entry_1e6; let gain_1e6: u128 = (diff as u128) * (qty as u128) * (cs as u128); ((gain_1e6 / 1_000_000u128) as u64, 0) } else { let diff2 = entry_1e6 - exit_1e6; let loss_1e6: u128 = (diff2 as u128) * (qty as u128) * (cs as u128); (0, (loss_1e6 / 1_000_000u128) as u64) }
    }

    fun realize_short_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (entry_1e6 >= exit_1e6) { let diff = entry_1e6 - exit_1e6; let gain_1e6: u128 = (diff as u128) * (qty as u128) * (cs as u128); ((gain_1e6 / 1_000_000u128) as u64, 0) } else { let diff2 = exit_1e6 - entry_1e6; let loss_1e6: u128 = (diff2 as u128) * (qty as u128) * (cs as u128); (0, (loss_1e6 / 1_000_000u128) as u64) }
    }

    fun wavg(prev_px: u64, prev_qty: u64, new_px: u64, new_qty: u64): u64 { if (prev_qty == 0) { new_px } else { (((prev_px as u128) * (prev_qty as u128) + (new_px as u128) * (new_qty as u128)) / ((prev_qty + new_qty) as u128)) as u64 } }

    fun im_for_qty(params: &XPerpParams, qty: u64, price_1e6: u64, im_bps: u64): u64 {
        let gross_1e6: u128 = (qty as u128) * (price_1e6 as u128) * (params.contract_size as u128);
        let im_1e6: u128 = (gross_1e6 * (im_bps as u128)) / (fees::bps_denom() as u128);
        (im_1e6 / 1_000_000u128) as u64
    }

    fun im_for_qty_tiered<Collat>(market: &XPerpMarket<Collat>, acc: &XPerpAccount<Collat>, qty: u64, price_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((price_1e6 as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
        let gross_after: u64 = acc.long_qty + acc.short_qty + qty;
        let notional_after_1e6: u128 = (gross_after as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, notional_after_1e6);
        let mut eff_bps = market.initial_margin_bps;
        if (tier_bps > eff_bps) { eff_bps = tier_bps; };
        im_for_qty(&market.params, qty, price_1e6, eff_bps)
    }

    // ===== Funding settlement internals =====
    fun settle_funding_user_internal<Collat>(market: &mut XPerpMarket<Collat>, acc: &mut XPerpAccount<Collat>, _ctx: &mut TxContext): (u64, u64) {
        // longs pay index
        let delta_long = market.cum_long_pay_1e6 - acc.last_cum_long_pay_1e6;
        let mut paid_long: u64 = 0;
        if (delta_long > 0 && acc.long_qty > 0) {
            let owe_1e6 = (delta_long as u128) * (acc.long_qty as u128) * (market.params.contract_size as u128);
            let owe = (owe_1e6 / 1_000_000u128) as u64;
            if (owe > 0) {
                let have = balance::value(&acc.collat);
                let pay = if (owe <= have) { owe } else { have };
                if (pay > 0) { let part = balance::split(&mut acc.collat, pay); market.funding_vault.join(part); paid_long = pay; };
            };
        };
        let delta_short = market.cum_short_pay_1e6 - acc.last_cum_short_pay_1e6;
        let mut credit_short: u64 = 0;
        if (delta_short > 0 && acc.short_qty > 0) {
            let due_1e6 = (delta_short as u128) * (acc.short_qty as u128) * (market.params.contract_size as u128);
            let due = (due_1e6 / 1_000_000u128) as u64;
            if (due > 0) {
                let avail = balance::value(&market.funding_vault);
                let pay2 = if (due <= avail) { due } else { avail };
                if (pay2 > 0) { let part2 = balance::split(&mut market.funding_vault, pay2); acc.collat.join(part2); credit_short = pay2; };
                if (due > pay2) { acc.funding_credit = acc.funding_credit + (due - pay2); };
            };
        };
        acc.last_cum_long_pay_1e6 = market.cum_long_pay_1e6;
        acc.last_cum_short_pay_1e6 = market.cum_short_pay_1e6;
        (paid_long, credit_short)
    }

    /// Apply realized PnL to the account's collateral using the FeeVault PnL bucket for gains,
    /// mirroring the futures engine behavior.
    fun apply_realized_to_account<Collat>(market: &XPerpMarket<Collat>, acc: &mut XPerpAccount<Collat>, gain: u64, loss: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        if (loss > 0) {
            let have = balance::value(&acc.collat);
            let pay_loss = if (loss <= have) { loss } else { have };
            if (pay_loss > 0) {
                let bal_loss = balance::split(&mut acc.collat, pay_loss);
                let coin_loss = coin::from_balance(bal_loss, ctx);
                fees::pnl_deposit<Collat>(vault, coin_loss);
            };
        };
        if (gain > 0) {
            let avail = fees::pnl_available<Collat>(vault);
            let pay = if (gain <= avail) { gain } else { avail };
            if (pay > 0) {
                let coin_gain = fees::pnl_withdraw<Collat>(vault, pay, ctx);
                acc.collat.join(coin::into_balance(coin_gain));
                let rem_after = if (acc.funding_credit > 0) { acc.funding_credit } else { 0 };
                event::emit(PnlCreditPaid<Collat> { market_id: object::id(market), who: ctx.sender(), amount: pay, remaining_credit: rem_after, timestamp_ms: sui::clock::timestamp_ms(clock) });
            };
            if (gain > pay) {
                let credit = gain - pay;
                acc.funding_credit = acc.funding_credit + credit;
                event::emit(PnlCreditAccrued<Collat> { market_id: object::id(market), who: ctx.sender(), credited: credit, remaining_credit: acc.funding_credit, timestamp_ms: sui::clock::timestamp_ms(clock) });
            };
        };
    }

    // ===== Trader rewards helpers (copy of perps variants) =====
    fun eligible_amount_usd_approx<Collat>(market: &XPerpMarket<Collat>, acc: &XPerpAccount<Collat>, index_1e6: u64): u64 {
        let eq = equity_collat(acc, index_1e6, market.params.contract_size);
        let req = required_margin_effective<Collat>(market, acc, index_1e6);
        if (eq <= req) { eq } else { req }
    }

    fun settle_trader_rewards_eligible<Collat>(market: &mut XPerpMarket<Collat>, acc: &mut XPerpAccount<Collat>) {
        let eligible_prev = (acc.trader_last_eligible as u128);
        if (eligible_prev > 0) {
            let accu = market.trader_acc_per_eligible_1e18;
            let debt = acc.trader_reward_debt_1e18;
            if (accu > debt) {
                let delta_1e18: u128 = accu - debt;
                let earn_u128: u128 = (eligible_prev * delta_1e18) / 1_000_000_000_000_000_000u128;
                let max_u64: u128 = 18_446_744_073_709_551_615u128;
                let add: u64 = if (earn_u128 > max_u64) { 18_446_744_073_709_551_615u64 } else { earn_u128 as u64 };
                acc.trader_pending_unxv = acc.trader_pending_unxv + add;
            };
        };
    }

    fun update_trader_rewards_after_change<Collat>(market: &mut XPerpMarket<Collat>, acc: &mut XPerpAccount<Collat>, index_1e6: u64) {
        let old_el = acc.trader_last_eligible as u128;
        if (old_el > 0 && market.trader_total_eligible >= old_el) { market.trader_total_eligible = market.trader_total_eligible - old_el; };
        let new_el_u64 = eligible_amount_usd_approx<Collat>(market, acc, index_1e6);
        let new_el = new_el_u64 as u128;
        if (new_el > 0) { market.trader_total_eligible = market.trader_total_eligible + new_el; acc.trader_reward_debt_1e18 = market.trader_acc_per_eligible_1e18; } else { acc.trader_reward_debt_1e18 = market.trader_acc_per_eligible_1e18; };
        if (market.trader_buffer_unxv > 0 && market.trader_total_eligible > 0) {
            let buf = market.trader_buffer_unxv as u128;
            let delta = (buf * 1_000_000_000_000_000_000u128) / market.trader_total_eligible;
            market.trader_acc_per_eligible_1e18 = market.trader_acc_per_eligible_1e18 + delta;
            market.trader_buffer_unxv = 0;
        };
        acc.trader_last_eligible = new_el_u64;
    }

    /// Claim trader rewards in UNXV up to `max_amount` (0 = all)
    public fun claim_trader_rewards<Collat>(market: &mut XPerpMarket<Collat>, clock: &Clock, ctx: &mut TxContext, max_amount: u64): Coin<UNXV> {
        assert!(table::contains(&market.accounts, ctx.sender()), E_NO_ACCOUNT);
        let mut acc = table::remove(&mut market.accounts, ctx.sender());
        settle_trader_rewards_eligible<Collat>(market, &mut acc);
        let want = if (max_amount == 0 || max_amount > acc.trader_pending_unxv) { acc.trader_pending_unxv } else { max_amount };
        assert!(want > 0, 9); // reuse E_NO_REWARDS value from perps implicitly
        let pot_avail = balance::value(&market.trader_rewards_pot);
        let pay = if (want <= pot_avail) { want } else { pot_avail };
        if (pay > 0) {
            let part = balance::split(&mut market.trader_rewards_pot, pay);
            let out = coin::from_balance(part, ctx);
            acc.trader_pending_unxv = acc.trader_pending_unxv - pay;
            event::emit(TraderRewardsClaimed { market_id: object::id(market), who: ctx.sender(), amount_unxv: pay, pending_left: acc.trader_pending_unxv, timestamp_ms: sui::clock::timestamp_ms(clock) });
            store_account<Collat>(market, ctx.sender(), acc);
            out
        } else { store_account<Collat>(market, ctx.sender(), acc); coin::zero<UNXV>(ctx) }
    }

    /// Keeper/public: deposit UNXV into trader rewards pot
    public fun deposit_trader_rewards<Collat>(market: &mut XPerpMarket<Collat>, mut unxv: Coin<UNXV>, clock: &Clock, _ctx: &mut TxContext) {
        let amt = coin::value(&unxv);
        assert!(amt > 0, E_ZERO);
        let bal = coin::into_balance(unxv);
        market.trader_rewards_pot.join(bal);
        if (market.trader_total_eligible > 0) {
            let delta: u128 = ((amt as u128) * 1_000_000_000_000_000_000u128) / market.trader_total_eligible;
            market.trader_acc_per_eligible_1e18 = market.trader_acc_per_eligible_1e18 + delta;
        } else { market.trader_buffer_unxv = market.trader_buffer_unxv + amt; };
        event::emit(TraderRewardsDeposited { market_id: object::id(market), amount_unxv: amt, total_eligible: market.trader_total_eligible, acc_1e18: market.trader_acc_per_eligible_1e18, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    // ===== Account IO =====
    fun load_or_new_account<Collat>(market: &mut XPerpMarket<Collat>, who: address): XPerpAccount<Collat> {
        if (table::contains(&market.accounts, who)) { table::remove(&mut market.accounts, who) } else { XPerpAccount { collat: balance::zero<Collat>(), long_qty: 0, short_qty: 0, avg_long_1e6: 0, avg_short_1e6: 0, last_cum_long_pay_1e6: market.cum_long_pay_1e6, last_cum_short_pay_1e6: market.cum_short_pay_1e6, funding_credit: 0, locked_im: 0, trader_reward_debt_1e18: 0, trader_pending_unxv: 0, trader_last_eligible: 0 } }
    }

    fun store_account<Collat>(market: &mut XPerpMarket<Collat>, who: address, acc: XPerpAccount<Collat>) { table::add(&mut market.accounts, who, acc) }
}


