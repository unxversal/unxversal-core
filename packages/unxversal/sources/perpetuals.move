/// Module: unxversal_perpetuals
/// ------------------------------------------------------------
/// Linear perpetual swaps with cash settlement, oracle index pricing (Switchboard),
/// funding mechanism via cumulative funding index, margin & liquidation, and protocol fees
/// with UNXV or staking-tier discounts. All accounting in a single collateral coin type.
#[allow(lint(self_transfer))]
module unxversal::perpetuals {
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
    use unxversal::oracle::{Self as uoracle, OracleRegistry};
    use unxversal::book::{Self as ubk, Book};
    use switchboard::aggregator::Aggregator;

    // Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO: u64 = 2;
    const E_NO_ACCOUNT: u64 = 3;
    const E_INSUFFICIENT: u64 = 4;
    const E_UNDER_IM: u64 = 5;
    const E_UNDER_MM: u64 = 6;
    const E_EXPOSURE_CAP: u64 = 7;
    const E_INVALID_TIERS: u64 = 8;

    /// Market parameters
    public struct PerpParams has copy, drop, store {
        symbol: String,          // oracle symbol, e.g. "SUI/USDC"
        contract_size: u64,      // quote units per 1 contract per 1e6 of price
        funding_interval_ms: u64,// target interval for funding updates
    }

    /// Account state per market
    public struct PerpAccount<phantom Collat> has store {
        collat: Balance<Collat>,
        long_qty: u64,
        short_qty: u64,
        avg_long_1e6: u64,
        avg_short_1e6: u64,
        last_cum_long_pay_1e6: u128,
        last_cum_short_pay_1e6: u128,
        funding_credit: u64,
        locked_im: u64,
    }

    /// Perp market shared object
    public struct PerpMarket<phantom Collat> has key, store {
        id: UID,
        params: PerpParams,
        accounts: Table<address, PerpAccount<Collat>>,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        cum_long_pay_1e6: u128,      // cumulative funding longs owe per contract (1e6 scale)
        cum_short_pay_1e6: u128,     // cumulative funding shorts owe per contract (1e6 scale)
        last_funding_ms: u64,
        funding_vault: Balance<Collat>,
        keeper_incentive_bps: u64,
        /// Max account gross notional in 1e6 units (0 = unlimited)
        account_max_notional_1e6: u128,
        /// Max market gross notional in 1e6 units (0 = unlimited)
        market_max_notional_1e6: u128,
        /// Max share of OI per account in bps of total gross contracts (0 = disabled)
        account_share_of_oi_bps: u64,
        /// Tiered IM thresholds in 1e6 notional units (non-decreasing)
        tier_thresholds_notional_1e6: vector<u64>,
        /// Tiered IM bps (same length as thresholds, non-decreasing)
        tier_im_bps: vector<u64>,
        /// Open interest tracking (sum of outstanding contracts per side)
        total_long_qty: u64,
        total_short_qty: u64,
        book: Book,
        owners: Table<u128, address>,
    }

    // Events
    public struct PerpInitialized has copy, drop { market_id: ID, symbol: String, contract_size: u64, funding_interval_ms: u64, initial_margin_bps: u64, maintenance_margin_bps: u64, liquidation_fee_bps: u64, keeper_incentive_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, realized_gain: u64, realized_loss: u64, new_long: u64, new_short: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_1e6: u128, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct FundingIndexUpdated has copy, drop { market_id: ID, longs_pay: bool, delta_1e6: u64, cum_long_pay_1e6: u128, cum_short_pay_1e6: u128, timestamp_ms: u64 }
    public struct FundingSettled has copy, drop { market_id: ID, who: address, amount_paid: u64, amount_credited: u64, credit_left: u64, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }

    // === Init ===
    public fun init_market<Collat>(
        reg_admin: &AdminRegistry,
        symbol: String,
        contract_size: u64,
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
        // Defaults: tiered IM thresholds and bps
        let mut tier_thresholds: vector<u64> = vector::empty<u64>();
        vector::push_back(&mut tier_thresholds, 5_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 25_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 100_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 250_000_000_000_000);
        vector::push_back(&mut tier_thresholds, 1_000_000_000_000_000);

        let mut tier_bps: vector<u64> = vector::empty<u64>();
        vector::push_back(&mut tier_bps, 800);
        vector::push_back(&mut tier_bps, 1000);
        vector::push_back(&mut tier_bps, 1500);
        vector::push_back(&mut tier_bps, 2000);
        vector::push_back(&mut tier_bps, 3000);

        let m = PerpMarket<Collat> {
            id: object::new(ctx),
            params: PerpParams { symbol, contract_size, funding_interval_ms },
            accounts: table::new<address, PerpAccount<Collat>>(ctx),
            initial_margin_bps,
            maintenance_margin_bps,
            liquidation_fee_bps,
            cum_long_pay_1e6: 0,
            cum_short_pay_1e6: 0,
            last_funding_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            funding_vault: balance::zero<Collat>(),
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
        };
        event::emit(PerpInitialized { market_id: object::id(&m), symbol: clone_string(&m.params.symbol), contract_size, funding_interval_ms, initial_margin_bps, maintenance_margin_bps, liquidation_fee_bps, keeper_incentive_bps });
        transfer::share_object(m);
    }

    // === Admin updates ===
    public fun set_margins<Collat>(reg_admin: &AdminRegistry, market: &mut PerpMarket<Collat>, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.initial_margin_bps = im_bps;
        market.maintenance_margin_bps = mm_bps;
        market.liquidation_fee_bps = liq_fee_bps;
    }

    public fun set_keeper_incentive_bps<Collat>(reg_admin: &AdminRegistry, market: &mut PerpMarket<Collat>, keeper_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.keeper_incentive_bps = keeper_bps;
    }

    // contract caps removed (deprecated)

    /// Admin: set notional caps (1e6 units). 0 disables a cap.
    public fun set_notional_caps<Collat>(reg_admin: &AdminRegistry, market: &mut PerpMarket<Collat>, account_max_notional_1e6: u128, market_max_notional_1e6: u128, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.account_max_notional_1e6 = account_max_notional_1e6;
        market.market_max_notional_1e6 = market_max_notional_1e6;
    }

    /// Admin: set account share-of-OI cap in bps (0 disables)
    public fun set_share_of_oi_bps<Collat>(reg_admin: &AdminRegistry, market: &mut PerpMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.account_share_of_oi_bps = share_bps;
    }

    /// Admin: set tiered IM schedule. thresholds_1e6 and im_bps must have same length; lists must be non-decreasing.
    public fun set_risk_tiers<Collat>(reg_admin: &AdminRegistry, market: &mut PerpMarket<Collat>, thresholds_1e6: vector<u64>, im_bps: vector<u64>, ctx: &TxContext) {
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

    /// Admin/keeper: apply funding update (per contract, 1e6 scale).
    /// If longs_pay is true, longs owe shorts by delta_1e6; else shorts owe longs.
    public fun apply_funding_update<Collat>(reg_admin: &AdminRegistry, market: &mut PerpMarket<Collat>, longs_pay: bool, delta_1e6: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        if (longs_pay) { market.cum_long_pay_1e6 = market.cum_long_pay_1e6 + (delta_1e6 as u128); } else { market.cum_short_pay_1e6 = market.cum_short_pay_1e6 + (delta_1e6 as u128); };
        market.last_funding_ms = sui::clock::timestamp_ms(clock);
        event::emit(FundingIndexUpdated { market_id: object::id(market), longs_pay, delta_1e6, cum_long_pay_1e6: market.cum_long_pay_1e6, cum_short_pay_1e6: market.cum_short_pay_1e6, timestamp_ms: market.last_funding_ms });
    }

    // === Collateral ===
    public fun deposit_collateral<Collat>(market: &mut PerpMarket<Collat>, c: Coin<Collat>, clock: &Clock, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let (_paid0, _cred0) = settle_funding_user_internal<Collat>(market, &mut acc, clock, ctx);
        acc.collat.join(coin::into_balance(c));
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralDeposited<Collat> { market_id: object::id(market), who: ctx.sender(), amount: amt, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun withdraw_collateral<Collat>(
        market: &mut PerpMarket<Collat>,
        amount: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Collat> {
        assert!(amount > 0, E_ZERO);
        let px = current_price_1e6(&market.params, reg, agg, clock);
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let (_paid1, _cred1) = settle_funding_user_internal<Collat>(market, &mut acc, clock, ctx);
        let eq = equity_collat(&acc, px, market.params.contract_size);
        assert!(eq >= amount, E_INSUFFICIENT);
        let eq_after = eq - amount;
        let free_after = if (eq_after > acc.locked_im) { eq_after - acc.locked_im } else { 0 };
        let req_im = required_margin_bps(&acc, px, market.params.contract_size, market.initial_margin_bps);
        assert!(free_after >= req_im, E_UNDER_IM);
        let part = balance::split(&mut acc.collat, amount);
        let out = coin::from_balance(part, ctx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralWithdrawn<Collat> { market_id: object::id(market), who: ctx.sender(), amount, timestamp_ms: clock.timestamp_ms() });
        out
    }

    // === Trading ===
    public fun open_long<Collat>(
        market: &mut PerpMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        taker_trade_internal<Collat>(market, true, qty, ((1u128 << 63) - 1) as u64, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun open_short<Collat>(
        market: &mut PerpMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        taker_trade_internal<Collat>(market, false, qty, 1, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun close_long<Collat>(
        market: &mut PerpMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        taker_trade_internal<Collat>(market, false, qty, 1, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun close_short<Collat>(
        market: &mut PerpMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        taker_trade_internal<Collat>(market, true, qty, ((1u128 << 63) - 1) as u64, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    fun trade_internal<Collat>(
        market: &mut PerpMarket<Collat>,
        is_buy: bool,
        qty: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        maybe_unxv: &mut Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let limit = if (is_buy) { ((1u128 << 63) - 1) as u64 } else { 1 };
        taker_trade_internal<Collat>(market, is_buy, qty, limit, reg, agg, cfg, vault, staking_pool, maybe_unxv, clock, ctx);
    }

    fun taker_trade_internal<Collat>(
        market: &mut PerpMarket<Collat>,
        is_buy: bool,
        qty: u64,
        limit_price_1e6: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        maybe_unxv: &mut Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(qty > 0, E_ZERO);
        let now = clock.timestamp_ms();
        let plan = ubk::compute_fill_plan(&market.book, is_buy, limit_price_1e6, qty, 0, now + 60_000, now);
        // Settle funding first
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let (_paid2, _cred2) = settle_funding_user_internal<Collat>(market, &mut acc, clock, ctx);
        let mut total_notional_1e6: u128 = 0u128;
        let fills_len = ubk::fillplan_num_fills(&plan);
        let mut i = 0u64;
        while (i < fills_len) {
            let f = ubk::fillplan_get_fill(&plan, i);
            let maker_id = ubk::fill_maker_id(&f);
            let px = ubk::fill_price(&f);
            let req_qty = ubk::fill_base_qty(&f);
            let (filled0, qty0) = ubk::order_progress(&market.book, maker_id);
            let maker_rem = if (qty0 > filled0) { qty0 - filled0 } else { 0 };
            let fqty = if (req_qty <= maker_rem) { req_qty } else { maker_rem };
            if (fqty == 0) { i = i + 1; continue };
            ubk::commit_maker_fill(&mut market.book, maker_id, is_buy, limit_price_1e6, fqty, now);
            let maker_addr = *table::borrow(&market.owners, maker_id);
            let mut maker_acc = load_or_new_account<Collat>(market, maker_addr);
            if (is_buy) {
                let r = if (acc.short_qty > 0) { if (fqty <= acc.short_qty) { fqty } else { acc.short_qty } } else { 0 };
                if (r > 0) { let (g,l) = realize_short_ul(acc.avg_short_1e6, px, r, market.params.contract_size); apply_realized_to_collat(&mut acc.collat, g, l, vault, clock, ctx); acc.short_qty = acc.short_qty - r; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r; };
                let a = if (fqty > r) { fqty - r } else { 0 };
                if (a > 0) { acc.avg_long_1e6 = wavg(acc.avg_long_1e6, acc.long_qty, px, a); acc.long_qty = acc.long_qty + a; market.total_long_qty = market.total_long_qty + a; };
                let r_m = if (maker_acc.long_qty > 0) { if (fqty <= maker_acc.long_qty) { fqty } else { maker_acc.long_qty } } else { 0 };
                if (r_m > 0) { let (g_m,l_m) = realize_long_ul(maker_acc.avg_long_1e6, px, r_m, market.params.contract_size); apply_realized_to_collat(&mut maker_acc.collat, g_m, l_m, vault, clock, ctx); maker_acc.long_qty = maker_acc.long_qty - r_m; if (maker_acc.long_qty == 0) { maker_acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r_m; };
                let a_m = if (fqty > r_m) { fqty - r_m } else { 0 };
                if (a_m > 0) { maker_acc.avg_short_1e6 = wavg(maker_acc.avg_short_1e6, maker_acc.short_qty, px, a_m); maker_acc.short_qty = maker_acc.short_qty + a_m; market.total_short_qty = market.total_short_qty + a_m; };
            } else {
                let r2 = if (acc.long_qty > 0) { if (fqty <= acc.long_qty) { fqty } else { acc.long_qty } } else { 0 };
                if (r2 > 0) { let (g2,l2) = realize_long_ul(acc.avg_long_1e6, px, r2, market.params.contract_size); apply_realized_to_collat(&mut acc.collat, g2, l2, vault, clock, ctx); acc.long_qty = acc.long_qty - r2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r2; };
                let a2 = if (fqty > r2) { fqty - r2 } else { 0 };
                if (a2 > 0) { acc.avg_short_1e6 = wavg(acc.avg_short_1e6, acc.short_qty, px, a2); acc.short_qty = acc.short_qty + a2; market.total_short_qty = market.total_short_qty + a2; };
                let r_m2 = if (maker_acc.short_qty > 0) { if (fqty <= maker_acc.short_qty) { fqty } else { maker_acc.short_qty } } else { 0 };
                if (r_m2 > 0) { let (g_m2,l_m2) = realize_short_ul(maker_acc.avg_short_1e6, px, r_m2, market.params.contract_size); apply_realized_to_collat(&mut maker_acc.collat, g_m2, l_m2, vault, clock, ctx); maker_acc.short_qty = maker_acc.short_qty - r_m2; if (maker_acc.short_qty == 0) { maker_acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r_m2; };
                let a_m2 = if (fqty > r_m2) { fqty - r_m2 } else { 0 };
                if (a_m2 > 0) { maker_acc.avg_long_1e6 = wavg(maker_acc.avg_long_1e6, maker_acc.long_qty, px, a_m2); maker_acc.long_qty = maker_acc.long_qty + a_m2; market.total_long_qty = market.total_long_qty + a_m2; };
            };
            let per_unit_1e6: u128 = ((px as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
            total_notional_1e6 = total_notional_1e6 + (fqty as u128) * per_unit_1e6 * 1_000_000u128;
            store_account<Collat>(market, maker_addr, maker_acc);
            if (!ubk::has_order(&market.book, maker_id)) { let _ = table::remove(&mut market.owners, maker_id); };
            i = i + 1;
        };

        // Enforce notional caps and share-of-OI caps after applying all fills
        let px_index = current_price_1e6(&market.params, reg, agg, clock);
        let gross_acc_post: u64 = acc.long_qty + acc.short_qty;
        let gross_mkt_post: u64 = market.total_long_qty + market.total_short_qty;
        let per_unit_1e6: u128 = ((px_index as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
        let acc_notional_post_1e6: u128 = (gross_acc_post as u128) * per_unit_1e6 * 1_000_000u128;
        let mkt_notional_post_1e6: u128 = (gross_mkt_post as u128) * per_unit_1e6 * 1_000_000u128;
        if (market.account_max_notional_1e6 > 0) { assert!(acc_notional_post_1e6 <= market.account_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.market_max_notional_1e6 > 0) { assert!(mkt_notional_post_1e6 <= market.market_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.account_share_of_oi_bps > 0 && gross_mkt_post > 0) {
            let allowed_u128: u128 = ((gross_mkt_post as u128) * (market.account_share_of_oi_bps as u128)) / (fees::bps_denom() as u128);
            let allowed: u64 = allowed_u128 as u64;
            assert!(gross_acc_post <= allowed, E_EXPOSURE_CAP);
        };

        let taker_bps = fees::futures_taker_fee_bps(cfg);
        let pay_with_unxv = option::is_some(maybe_unxv);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt = ((total_notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        if (pay_with_unxv) {
            let u = option::extract(maybe_unxv);
            let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6: total_notional_1e6, fee_paid: 0, paid_in_unxv: true, timestamp_ms: clock.timestamp_ms() });
        } else {
            assert!(balance::value(&acc.collat) >= fee_amt, E_INSUFFICIENT);
            let part = balance::split(&mut acc.collat, fee_amt);
            fees::accrue_generic<Collat>(vault, coin::from_balance(part, ctx), clock, ctx);
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6: total_notional_1e6, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: clock.timestamp_ms() });
        };

        let px_mark = current_price_1e6(&market.params, reg, agg, clock);
        let eq = equity_collat(&acc, px_mark, market.params.contract_size);
        let req_im = required_margin_effective<Collat>(market, &acc, px_mark);
        let free = if (eq > acc.locked_im) { eq - acc.locked_im } else { 0 };
        assert!(free >= req_im, E_UNDER_IM);

        store_account<Collat>(market, ctx.sender(), acc);
    }

    // === Funding settlement ===
    /// Settle funding for caller and optionally claim available credit from vault.
    public fun settle_funding_for_caller<Collat>(market: &mut PerpMarket<Collat>, clock: &Clock, ctx: &mut TxContext): u64 {
        let mut acc = load_or_new_account<Collat>(market, ctx.sender());
        let (paid_long, credited_short) = settle_funding_user_internal<Collat>(market, &mut acc, clock, ctx);
        // attempt to satisfy existing credit
        let mut paid_out: u64 = 0;
        if (acc.funding_credit > 0) {
            let avail = balance::value(&market.funding_vault);
            let pay = if (acc.funding_credit <= avail) { acc.funding_credit } else { avail };
            if (pay > 0) { let part = balance::split(&mut market.funding_vault, pay); acc.collat.join(part); acc.funding_credit = acc.funding_credit - pay; paid_out = pay; };
        };
        // Capture value for event before moving acc
        let final_funding_credit = acc.funding_credit;
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(FundingSettled { market_id: object::id(market), who: ctx.sender(), amount_paid: paid_long, amount_credited: credited_short + paid_out, credit_left: final_funding_credit, timestamp_ms: sui::clock::timestamp_ms(clock) });
        credited_short + paid_out
    }

    fun settle_funding_user_internal<Collat>(market: &mut PerpMarket<Collat>, acc: &mut PerpAccount<Collat>, _clock: &Clock, _ctx: &mut TxContext): (u64, u64) {
        // compute owed from long side
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
        // compute credit from short side
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

    // === Liquidation ===
    public fun liquidate<Collat>(
        market: &mut PerpMarket<Collat>,
        victim: address,
        reg: &OracleRegistry,
        agg: &Aggregator,
        vault: &mut FeeVault,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        let px = current_price_1e6(&market.params, reg, agg, clock);
        let mut acc = table::remove(&mut market.accounts, victim);
        // settle funding first for fairness
        let (_paid, _credited) = settle_funding_user_internal<Collat>(market, &mut acc, clock, ctx);
        let eq = equity_collat(&acc, px, market.params.contract_size);
        let req_mm = required_margin_bps(&acc, px, market.params.contract_size, market.maintenance_margin_bps);
        assert!(eq < req_mm, E_UNDER_MM);

        // Close qty from larger side
        let mut closed = 0u64;
        if (acc.long_qty >= acc.short_qty) {
            let c = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
            if (c > 0) { let (_g,_l) = realize_long_ul(acc.avg_long_1e6, px, c, market.params.contract_size); /* only losses applied below */ acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
        } else {
            let c2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
            if (c2 > 0) { let (_g2,_l2) = realize_short_ul(acc.avg_short_1e6, px, c2, market.params.contract_size); acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
        };
        // re-evaluate equity losses are implicitly realized via later checks; liquidation penalty still applied
        // Penalty -> fee vault
        let notional_1e6 = (closed as u128) * (px as u128) * (market.params.contract_size as u128);
        let pen = ((notional_1e6 * (market.liquidation_fee_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let have = balance::value(&acc.collat);
        let pay = if (pen <= have) { pen } else { have };
        if (pay > 0) {
            // Split keeper incentive and deposit remainder into PnL bucket
            let keeper_bps: u64 = market.keeper_incentive_bps;
            let keeper_cut: u64 = ((pay as u128) * (keeper_bps as u128) / (fees::bps_denom() as u128)) as u64;
            let mut pen_coin = coin::from_balance(balance::split(&mut acc.collat, pay), ctx);
            if (keeper_cut > 0) { let kc = coin::split(&mut pen_coin, keeper_cut, ctx); transfer::public_transfer(kc, ctx.sender()); };
            fees::pnl_deposit<Collat>(vault, pen_coin);
        };

        store_account<Collat>(market, victim, acc);
        event::emit(Liquidated { market_id: object::id(market), who: victim, qty_closed: closed, exec_price_1e6: px, penalty_collat: pay, timestamp_ms: clock.timestamp_ms() });
    }

    // === Views & helpers ===
    fun current_price_1e6(params: &PerpParams, reg: &OracleRegistry, agg: &Aggregator, clock: &Clock): u64 { uoracle::get_price_for_symbol(reg, clock, &params.symbol, agg) }

    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    fun equity_collat<Collat>(acc: &PerpAccount<Collat>, px_1e6: u64, cs: u64): u64 {
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

    fun required_margin_bps<Collat>(acc: &PerpAccount<Collat>, px_1e6: u64, cs: u64, bps: u64): u64 {
        let qty_sum: u128 = (acc.long_qty as u128) + (acc.short_qty as u128);
        let gross: u128 = qty_sum * (px_1e6 as u128) * (cs as u128);
        let im_1e6: u128 = (gross * (bps as u128)) / (fees::bps_denom() as u128);
        let im: u128 = im_1e6 / 1_000_000u128;
        if (im > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { im as u64 }
    }

    fun required_margin_effective<Collat>(market: &PerpMarket<Collat>, acc: &PerpAccount<Collat>, px_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((px_1e6 as u128) * (market.params.contract_size as u128)) / 1_000_000u128;
        let gross_contracts: u64 = acc.long_qty + acc.short_qty;
        let acc_notional_1e6: u128 = (gross_contracts as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, acc_notional_1e6);
        let mut base = market.initial_margin_bps;
        if (tier_bps > base) { base = tier_bps; };
        required_margin_bps<Collat>(acc, px_1e6, market.params.contract_size, base)
    }

    fun tier_bps_for_notional<Collat>(market: &PerpMarket<Collat>, notional_1e6: u128): u64 {
        let n = vector::length(&market.tier_thresholds_notional_1e6);
        if (n == 0) return market.initial_margin_bps;
        let mut i: u64 = 0; let mut out: u64 = market.initial_margin_bps;
        while (i < n) {
            let th_1e6 = *vector::borrow(&market.tier_thresholds_notional_1e6, i);
            if (notional_1e6 >= (th_1e6 as u128)) { out = *vector::borrow(&market.tier_im_bps, i); };
            i = i + 1;
        };
        out
    }

    fun realize_long_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (exit_1e6 >= entry_1e6) {
            let diff = exit_1e6 - entry_1e6;
            let gain_1e6: u128 = (diff as u128) * (qty as u128) * (cs as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = entry_1e6 - exit_1e6;
            let loss_1e6: u128 = (diff2 as u128) * (qty as u128) * (cs as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun realize_short_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (entry_1e6 >= exit_1e6) {
            let diff = entry_1e6 - exit_1e6;
            let gain_1e6: u128 = (diff as u128) * (qty as u128) * (cs as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = exit_1e6 - entry_1e6;
            let loss_1e6: u128 = (diff2 as u128) * (qty as u128) * (cs as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }
    fun wavg(prev_px: u64, prev_qty: u64, new_px: u64, new_qty: u64): u64 { if (prev_qty == 0) { new_px } else { (((prev_px as u128) * (prev_qty as u128) + (new_px as u128) * (new_qty as u128)) / ((prev_qty + new_qty) as u128)) as u64 } }

    fun apply_realized_to_collat<Collat>(balc: &mut Balance<Collat>, gain: u64, loss: u64, vault: &mut FeeVault, _clock: &Clock, ctx: &mut TxContext) {
        if (loss > 0) {
            let have = balance::value(balc);
            let pay_loss = if (loss <= have) { loss } else { have };
            if (pay_loss > 0) {
                let bal_loss = balance::split(balc, pay_loss);
                let coin_loss = coin::from_balance(bal_loss, ctx);
                fees::pnl_deposit<Collat>(vault, coin_loss);
            };
        };
        if (gain > 0) {
            let coin_gain = fees::pnl_withdraw<Collat>(vault, gain, ctx);
            balc.join(coin::into_balance(coin_gain));
        };
    }

    fun load_or_new_account<Collat>(market: &mut PerpMarket<Collat>, who: address): PerpAccount<Collat> {
        if (table::contains(&market.accounts, who)) { table::remove(&mut market.accounts, who) } else { PerpAccount { collat: balance::zero<Collat>(), long_qty: 0, short_qty: 0, avg_long_1e6: 0, avg_short_1e6: 0, last_cum_long_pay_1e6: market.cum_long_pay_1e6, last_cum_short_pay_1e6: market.cum_short_pay_1e6, funding_credit: 0, locked_im: 0 } }
    }

    fun store_account<Collat>(market: &mut PerpMarket<Collat>, who: address, acc: PerpAccount<Collat>) { table::add(&mut market.accounts, who, acc) }

    fun clone_string(s: &String): String {
        let b = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(b);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(b, i)); i = i + 1; };
        string::utf8(out)
    }
}


