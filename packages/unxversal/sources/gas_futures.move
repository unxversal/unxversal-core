/// Module: unxversal_gas_futures
/// ------------------------------------------------------------
/// Futures product on Sui reference gas price (RGP). Similar to `unxversal::futures`
/// but price source is on-chain via `sui::tx_context::{reference_gas_price, gas_price}`.
/// Collateralized in a single coin type Collat, cash-settled. Supports staking/UNXV fee discounts.
#[allow(lint(self_transfer))]
module unxversal::gas_futures {
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

    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO: u64 = 2;
    const E_EXPIRED: u64 = 7;
    const E_NO_ACCOUNT: u64 = 3;
    const E_INSUFF: u64 = 4;
    const E_UNDER_IM: u64 = 5;
    const E_UNDER_MM: u64 = 6;
    const E_CLOSE_ONLY: u64 = 8;
    const E_PRICE_DEVIATION: u64 = 9;
    const E_EXPOSURE_CAP: u64 = 10;
    const E_ALREADY_SETTLED: u64 = 11;
    const E_INVALID_TIERS: u64 = 12;

    const TWAP_MAX_SAMPLES: u64 = 64;
    const TWAP_WINDOW_MS: u64 = 300_000; // 5 minutes

    /// Price scaling: treat reference gas price (MIST) as 1e6-scaled units for simplicity,
    /// and divide by 1_000_000 when converting notional to whole collateral units via `contract_size`.
    public struct GasSeries has copy, drop, store {
        /// If >0, series expires at this ms; else perpetual-like
        expiry_ms: u64,
        /// Contract size in MIST per contract per 1e6 price unit
        contract_size: u64,
    }

    public struct Account<phantom Collat> has store { collat: Balance<Collat>, long_qty: u64, short_qty: u64, avg_long_1e6: u64, avg_short_1e6: u64, pending_credit: u64, locked_im: u64 }

    public struct GasMarket<phantom Collat> has key, store {
        id: UID,
        series: GasSeries,
        accounts: Table<address, Account<Collat>>,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        keeper_incentive_bps: u64,
        close_only: bool,
        max_deviation_bps: u64,
        last_price_1e6: u64,
        pnl_fee_share_bps: u64,
        liq_target_buffer_bps: u64,
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
        total_long_qty: u64,
        total_short_qty: u64,
        imbalance_surcharge_bps_max: u64,
        imbalance_threshold_bps: u64,
        book: Book,
        owners: Table<u128, address>,
        settlement_price_1e6: u64,
        is_settled: bool,
        lvp_price_1e6: u64,
        lvp_ts_ms: u64,
        twap_ts_ms: vector<u64>,
        twap_px_1e6: vector<u64>,
    }

    public struct MarketInitialized has copy, drop { market_id: ID, expiry_ms: u64, contract_size: u64, initial_margin_bps: u64, maintenance_margin_bps: u64, liquidation_fee_bps: u64, keeper_incentive_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_1e6: u128, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }
    public struct PnlCreditAccrued<phantom Collat> has copy, drop { market_id: ID, who: address, credited: u64, remaining_credit: u64, timestamp_ms: u64 }
    public struct PnlCreditPaid<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, remaining_credit: u64, timestamp_ms: u64 }

    // Order lifecycle events for matched engine
    public struct OrderPlaced has copy, drop { market_id: ID, order_id: u128, maker: address, is_bid: bool, price_1e6: u64, quantity: u64, expire_ts: u64 }
    public struct OrderCanceled has copy, drop { market_id: ID, order_id: u128, maker: address, remaining_qty: u64, timestamp_ms: u64 }
    public struct OrderFilled has copy, drop { market_id: ID, maker_order_id: u128, maker: address, taker: address, price_1e6: u64, base_qty: u64, timestamp_ms: u64 }

    // === Init ===
    public fun init_market<Collat>(reg_admin: &AdminRegistry, expiry_ms: u64, contract_size: u64, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, keeper_bps: u64, tick_size: u64, lot_size: u64, min_size: u64, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        // Defaults: tiered IM for gas futures
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

        let m = GasMarket<Collat> { id: object::new(ctx), series: GasSeries { expiry_ms, contract_size }, accounts: table::new<address, Account<Collat>>(ctx), initial_margin_bps: im_bps, maintenance_margin_bps: mm_bps, liquidation_fee_bps: liq_fee_bps, keeper_incentive_bps: keeper_bps, close_only: false, max_deviation_bps: 0, last_price_1e6: 0, pnl_fee_share_bps: 0, liq_target_buffer_bps: 0, account_max_notional_1e6: 0, market_max_notional_1e6: 0, account_share_of_oi_bps: 300, tier_thresholds_notional_1e6: tier_thresholds, tier_im_bps: tier_bps, total_long_qty: 0, total_short_qty: 0, imbalance_surcharge_bps_max: 0, imbalance_threshold_bps: 0, book: ubk::empty(tick_size, lot_size, min_size, ctx), owners: table::new<u128, address>(ctx), settlement_price_1e6: 0, is_settled: false, lvp_price_1e6: 0, lvp_ts_ms: 0, twap_ts_ms: vector::empty<u64>(), twap_px_1e6: vector::empty<u64>() };
        event::emit(MarketInitialized { market_id: object::id(&m), expiry_ms, contract_size, initial_margin_bps: im_bps, maintenance_margin_bps: mm_bps, liquidation_fee_bps: liq_fee_bps, keeper_incentive_bps: keeper_bps });
        transfer::share_object(m);
    }

    public fun set_margins<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.initial_margin_bps = im_bps;
        market.maintenance_margin_bps = mm_bps;
        market.liquidation_fee_bps = liq_fee_bps;
    }

    // Admin: set keeper incentive in bps (paid from liquidation penalty to liquidator)
    public fun set_keeper_incentive_bps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, keeper_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.keeper_incentive_bps = keeper_bps;
    }

    public fun set_close_only<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, enabled: bool, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.close_only = enabled;
    }

    public fun set_price_deviation_bps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, max_dev_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.max_deviation_bps = max_dev_bps;
    }

    public fun set_pnl_fee_share_bps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.pnl_fee_share_bps = share_bps;
    }

    public fun set_liq_target_buffer_bps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, buffer_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.liq_target_buffer_bps = buffer_bps;
    }

    /// Admin: set notional caps (1e6 units). 0 disables a cap.
    public fun set_notional_caps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, account_max_notional_1e6: u128, market_max_notional_1e6: u128, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.account_max_notional_1e6 = account_max_notional_1e6;
        market.market_max_notional_1e6 = market_max_notional_1e6;
    }

    /// Admin: set account share-of-OI cap in bps (0 disables)
    public fun set_share_of_oi_bps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.account_share_of_oi_bps = share_bps;
    }

    /// Admin: set tiered IM schedule. thresholds_1e6 and im_bps must have same length; lists must be non-decreasing.
    public fun set_risk_tiers<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, thresholds_1e6: vector<u64>, im_bps: vector<u64>, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let n = vector::length(&thresholds_1e6);
        assert!(n == vector::length(&im_bps), E_INVALID_TIERS);
        if (n > 1) { let mut i: u64 = 1; while (i < n) { let prev_t = *vector::borrow(&thresholds_1e6, i - 1); let cur_t = *vector::borrow(&thresholds_1e6, i); let prev_b = *vector::borrow(&im_bps, i - 1); let cur_b = *vector::borrow(&im_bps, i); assert!(cur_t >= prev_t && cur_b >= prev_b, E_INVALID_TIERS); i = i + 1; }; };
        market.tier_thresholds_notional_1e6 = thresholds_1e6;
        market.tier_im_bps = im_bps;
    }

    public fun set_imbalance_params<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, surcharge_max_bps: u64, threshold_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.imbalance_surcharge_bps_max = surcharge_max_bps;
        market.imbalance_threshold_bps = threshold_bps;
    }

    // === Collateral ===
    public fun deposit_collateral<Collat>(market: &mut GasMarket<Collat>, c: Coin<Collat>, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        acc.collat.join(coin::into_balance(c));
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralDeposited<Collat> { market_id: object::id(market), who: ctx.sender(), amount: amt, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun withdraw_collateral<Collat>(market: &mut GasMarket<Collat>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<Collat> {
        assert!(amount > 0, E_ZERO);
        let price_1e6 = if (market.is_settled) { market.settlement_price_1e6 } else { gated_price_and_update<Collat>(market, ctx) };
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        let eq = equity(&acc, price_1e6, market.series.contract_size);
        assert!(eq >= amount, E_INSUFF);
        let eq_after = eq - amount;
        let free_after = if (eq_after > acc.locked_im) { eq_after - acc.locked_im } else { 0 };
        let req_im = required_margin_effective<Collat>(market, &acc, price_1e6);
        assert!(free_after >= req_im, E_UNDER_IM);
        let part = balance::split(&mut acc.collat, amount);
        let out = coin::from_balance(part, ctx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralWithdrawn<Collat> { market_id: object::id(market), who: ctx.sender(), amount, timestamp_ms: clock.timestamp_ms() });
        out
    }

    // === Trading via matched orderbook (index = reference gas price) ===
    public fun open_long<Collat>(market: &mut GasMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        taker_limit_trade<Collat>(market, /*is_buy=*/true, /*limit_price=*/max_order_price(), qty, /*expire_ts=*/clock.timestamp_ms() + 60_000, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun open_short<Collat>(market: &mut GasMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        taker_limit_trade<Collat>(market, /*is_buy=*/false, /*limit_price=*/min_order_price(), qty, /*expire_ts=*/clock.timestamp_ms() + 60_000, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    fun taker_limit_trade<Collat>(market: &mut GasMarket<Collat>, is_buy: bool, limit_price_1e6: u64, qty: u64, expire_ts: u64, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, maybe_unxv: &mut Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let now = clock.timestamp_ms();
        if (market.series.expiry_ms > 0) { assert!(now <= market.series.expiry_ms, E_EXPIRED); };
        // Price gate on index only
        let _ = gated_price_and_update<Collat>(market, ctx);
        // Plan fills
        let plan = ubk::compute_fill_plan(&market.book, is_buy, limit_price_1e6, qty, /*client_order_id*/0, expire_ts, now);
        // Taker account & index for margin
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        let index_px = current_gas_price_1e6(ctx);
        let mut total_notional_1e6: u128 = 0u128;
        let mut total_qty: u64 = 0;
        let mut wsum_px_qty: u128 = 0u128;
        let fills_len = ubk::fillplan_num_fills(&plan);
        let mut i: u64 = 0;
        while (i < fills_len) {
            let f = ubk::fillplan_get_fill(&plan, i);
            let maker_id = ubk::fill_maker_id(&f);
            let px = ubk::fill_price(&f);
            let req_qty = ubk::fill_base_qty(&f);
            // Maker remaining sanity before committing
            let (filled0, qty0) = ubk::order_progress(&market.book, maker_id);
            let maker_rem_before = if (qty0 > filled0) { qty0 - filled0 } else { 0 };
            let fqty = if (req_qty <= maker_rem_before) { req_qty } else { maker_rem_before };
            if (fqty == 0) { i = i + 1; continue };
            // Commit maker fill
            ubk::commit_maker_fill(&mut market.book, maker_id, is_buy, limit_price_1e6, fqty, now);
            let maker_addr = *table::borrow(&market.owners, maker_id);
            let mut maker_acc = take_or_new_account<Collat>(market, maker_addr);
            if (is_buy) {
                // Taker: reduce short then add long
                let r = if (acc.short_qty > 0) { if (fqty <= acc.short_qty) { fqty } else { acc.short_qty } } else { 0 };
                if (r > 0) { let (g,l) = realize_short_ul(acc.avg_short_1e6, px, r, market.series.contract_size); apply_realized_to_account<Collat>(market, &mut acc, g, l, vault, clock, ctx); acc.short_qty = acc.short_qty - r; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r; };
                let a = if (fqty > r) { fqty - r } else { 0 };
                if (a > 0) { acc.avg_long_1e6 = wavg(acc.avg_long_1e6, acc.long_qty, px, a); acc.long_qty = acc.long_qty + a; market.total_long_qty = market.total_long_qty + a; };
                // Maker: reduce long then add short
                let r_m = if (maker_acc.long_qty > 0) { if (fqty <= maker_acc.long_qty) { fqty } else { maker_acc.long_qty } } else { 0 };
                if (r_m > 0) { let (g_m,l_m) = realize_long_ul(maker_acc.avg_long_1e6, px, r_m, market.series.contract_size); apply_realized_to_account<Collat>(market, &mut maker_acc, g_m, l_m, vault, clock, ctx); maker_acc.long_qty = maker_acc.long_qty - r_m; if (maker_acc.long_qty == 0) { maker_acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r_m; };
                let a_m = if (fqty > r_m) { fqty - r_m } else { 0 };
                if (a_m > 0) { maker_acc.avg_short_1e6 = wavg(maker_acc.avg_short_1e6, maker_acc.short_qty, px, a_m); maker_acc.short_qty = maker_acc.short_qty + a_m; market.total_short_qty = market.total_short_qty + a_m; unlock_locked_im_for_fill<Collat>(market, &mut maker_acc, index_px, a_m); };
            } else {
                // Taker sell: reduce long then add short
                let r2 = if (acc.long_qty > 0) { if (fqty <= acc.long_qty) { fqty } else { acc.long_qty } } else { 0 };
                if (r2 > 0) { let (g2,l2) = realize_long_ul(acc.avg_long_1e6, px, r2, market.series.contract_size); apply_realized_to_account<Collat>(market, &mut acc, g2, l2, vault, clock, ctx); acc.long_qty = acc.long_qty - r2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - r2; };
                let a2 = if (fqty > r2) { fqty - r2 } else { 0 };
                if (a2 > 0) { acc.avg_short_1e6 = wavg(acc.avg_short_1e6, acc.short_qty, px, a2); acc.short_qty = acc.short_qty + a2; market.total_short_qty = market.total_short_qty + a2; };
                // Maker: reduce short then add long
                let r_m2 = if (maker_acc.short_qty > 0) { if (fqty <= maker_acc.short_qty) { fqty } else { maker_acc.short_qty } } else { 0 };
                if (r_m2 > 0) { let (g_m2,l_m2) = realize_short_ul(maker_acc.avg_short_1e6, px, r_m2, market.series.contract_size); apply_realized_to_account<Collat>(market, &mut maker_acc, g_m2, l_m2, vault, clock, ctx); maker_acc.short_qty = maker_acc.short_qty - r_m2; if (maker_acc.short_qty == 0) { maker_acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - r_m2; };
                let a_m2 = if (fqty > r_m2) { fqty - r_m2 } else { 0 };
                if (a_m2 > 0) { maker_acc.avg_long_1e6 = wavg(maker_acc.avg_long_1e6, maker_acc.long_qty, px, a_m2); maker_acc.long_qty = maker_acc.long_qty + a_m2; market.total_long_qty = market.total_long_qty + a_m2; unlock_locked_im_for_fill<Collat>(market, &mut maker_acc, index_px, a_m2); };
            };
            // Update notional and VWAP for event
            let per_unit_1e6: u128 = ((px as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
            total_notional_1e6 = total_notional_1e6 + (fqty as u128) * per_unit_1e6 * 1_000_000u128;
            total_qty = total_qty + fqty;
            wsum_px_qty = wsum_px_qty + (px as u128) * (fqty as u128);
            // Persist maker
            store_account<Collat>(market, maker_addr, maker_acc);
            if (!ubk::has_order(&market.book, maker_id)) { let _ = table::remove(&mut market.owners, maker_id); };
            // Per-fill event
            event::emit(OrderFilled { market_id: object::id(market), maker_order_id: maker_id, maker: maker_addr, taker: ctx.sender(), price_1e6: px, base_qty: fqty, timestamp_ms: now });
            i = i + 1;
        };

        // Enforce close-only intent
        if (market.close_only) {
            if (is_buy) { assert!(total_qty <= acc.short_qty, E_CLOSE_ONLY); } else { assert!(total_qty <= acc.long_qty, E_CLOSE_ONLY); };
        };

        // Enforce notional caps and share-of-OI caps (contract caps removed)
        let gross_acc_post = acc.long_qty + acc.short_qty;
        let gross_mkt_post = market.total_long_qty + market.total_short_qty;
        let per_unit_1e6: u128 = ((index_px as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let acc_notional_post_1e6: u128 = (gross_acc_post as u128) * per_unit_1e6 * 1_000_000u128;
        let mkt_notional_post_1e6: u128 = (gross_mkt_post as u128) * per_unit_1e6 * 1_000_000u128;
        if (market.account_max_notional_1e6 > 0) { assert!(acc_notional_post_1e6 <= market.account_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.market_max_notional_1e6 > 0) { assert!(mkt_notional_post_1e6 <= market.market_max_notional_1e6, E_EXPOSURE_CAP); };
        if (market.account_share_of_oi_bps > 0 && gross_mkt_post > 0) {
            let allowed_u128: u128 = ((gross_mkt_post as u128) * (market.account_share_of_oi_bps as u128)) / (fees::bps_denom() as u128);
            let allowed: u64 = allowed_u128 as u64;
            assert!(gross_acc_post <= allowed, E_EXPOSURE_CAP);
        };

        // Protocol taker fee
        let taker_bps = fees::gasfut_taker_fee_bps(cfg);
        let pay_with_unxv = option::is_some(maybe_unxv);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt: u64 = ((total_notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        if (pay_with_unxv) {
            let u = option::extract(maybe_unxv);
            let (stakers_coin, treasury_coin, _burn_amt) = fees::accrue_unxv_and_split(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6: total_notional_1e6, fee_paid: 0, paid_in_unxv: true, timestamp_ms: clock.timestamp_ms() });
        } else {
            assert!(balance::value(&acc.collat) >= fee_amt, E_INSUFF);
            let part = balance::split(&mut acc.collat, fee_amt);
            let mut c = coin::from_balance(part, ctx);
            let share_bps = market.pnl_fee_share_bps;
            if (share_bps > 0) {
                let share_amt: u64 = ((fee_amt as u128) * (share_bps as u128) / (fees::bps_denom() as u128)) as u64;
                if (share_amt > 0 && share_amt < fee_amt) {
                    let pnl_part = coin::split(&mut c, share_amt, ctx);
                    fees::pnl_deposit<Collat>(vault, pnl_part);
                    fees::accrue_generic<Collat>(vault, c, clock, ctx);
                } else if (share_amt >= fee_amt) {
                    fees::pnl_deposit<Collat>(vault, c);
                } else {
                    fees::accrue_generic<Collat>(vault, c, clock, ctx);
                };
            } else {
                fees::accrue_generic<Collat>(vault, c, clock, ctx);
            };
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6: total_notional_1e6, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: clock.timestamp_ms() });
        };

        // Margin check (index)
        let eq = equity(&acc, index_px, market.series.contract_size);
        let req = required_margin_effective<Collat>(market, &acc, index_px);
        let free = if (eq > acc.locked_im) { eq - acc.locked_im } else { 0 };
        assert!(free >= req, E_UNDER_IM);

        // Optional position changed event (VWAP of fills if any)
        if (total_qty > 0) {
            let vwap: u64 = (wsum_px_qty / (total_qty as u128)) as u64;
            event::emit(PositionChanged { market_id: object::id(market), who: ctx.sender(), is_long: is_buy, qty_delta: total_qty, exec_price_1e6: vwap, timestamp_ms: clock.timestamp_ms() });
        };
        store_account<Collat>(market, ctx.sender(), acc);
    }

    // === Maker order APIs ===
    public fun place_limit_bid<Collat>(market: &mut GasMarket<Collat>, price_1e6: u64, qty: u64, expire_ts: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let now = clock.timestamp_ms();
        assert!(expire_ts > now, E_EXPIRED);
        if (market.series.expiry_ms > 0) { assert!(now <= market.series.expiry_ms, E_EXPIRED); };
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        let idx = current_gas_price_1e6(ctx);
        let need = im_for_qty_tiered<Collat>(market, &acc, qty, idx);
        let eq = equity(&acc, idx, market.series.contract_size);
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

    public fun place_limit_ask<Collat>(market: &mut GasMarket<Collat>, price_1e6: u64, qty: u64, expire_ts: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let now = clock.timestamp_ms();
        assert!(expire_ts > now, E_EXPIRED);
        if (market.series.expiry_ms > 0) { assert!(now <= market.series.expiry_ms, E_EXPIRED); };
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        let idx = current_gas_price_1e6(ctx);
        let need = im_for_qty_tiered<Collat>(market, &acc, qty, idx);
        let eq = equity(&acc, idx, market.series.contract_size);
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

    public fun cancel_order<Collat>(market: &mut GasMarket<Collat>, order_id: u128, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.owners, order_id), E_NO_ACCOUNT);
        let owner = *table::borrow(&market.owners, order_id);
        assert!(owner == ctx.sender(), E_NOT_ADMIN);
        let (filled, qty) = ubk::order_progress(&market.book, order_id);
        let remaining = if (qty > filled) { qty - filled } else { 0 };
        let idx = if (market.is_settled) { market.settlement_price_1e6 } else { current_gas_price_1e6(ctx) };
        let unlock = im_for_qty(&market.series, remaining, idx, market.initial_margin_bps);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        if (acc.locked_im >= unlock) { acc.locked_im = acc.locked_im - unlock; } else { acc.locked_im = 0; };
        let _ord = ubk::cancel_order(&mut market.book, order_id);
        table::remove(&mut market.owners, order_id);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(OrderCanceled { market_id: object::id(market), order_id, maker: owner, remaining_qty: remaining, timestamp_ms: clock.timestamp_ms() });
    }

    public fun liquidate<Collat>(market: &mut GasMarket<Collat>, victim: address, qty: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        assert!(qty > 0, E_ZERO);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let now = clock.timestamp_ms();
        if (market.series.expiry_ms > 0) { assert!(now < market.series.expiry_ms, E_EXPIRED); };
        let px = current_gas_price_1e6(ctx);
        let mut acc = table::remove(&mut market.accounts, victim);
        let eq = equity(&acc, px, market.series.contract_size);
        let req_mm = required_margin_bps(&acc, px, market.series.contract_size, market.maintenance_margin_bps);
        assert!(eq < req_mm, E_UNDER_MM);
        // target IM + buffer (u128-only arithmetic)
        let target_bps = market.initial_margin_bps + market.liq_target_buffer_bps;
        let per_contract_val: u128 = ((px as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let mut closed = 0u64; let mut realized_gain: u64 = 0; let mut realized_loss: u64 = 0;
        if (target_bps == 0 || per_contract_val == 0) {
            // Fallback: close from larger side up to qty
            if (acc.long_qty >= acc.short_qty) {
                let c = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
                if (c > 0) { let (g,l) = realize_long_ul(acc.avg_long_1e6, px, c, market.series.contract_size); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
            } else {
                let c2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
                if (c2 > 0) { let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px, c2, market.series.contract_size); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
            };
        } else {
            let gross_before: u128 = ((acc.long_qty as u128) + (acc.short_qty as u128)) * per_contract_val;
            let rhs: u128 = ((eq as u128) * (fees::bps_denom() as u128)) / (target_bps as u128);
            let diff: u128 = if (gross_before > rhs) { gross_before - rhs } else { 0 };
            let need_u128: u128 = if (diff == 0) { 0 } else { (diff + per_contract_val - 1) / per_contract_val };
            let choose_long = acc.long_qty >= acc.short_qty;
            if (choose_long) {
                let cmax = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
                let need_u64 = if (need_u128 > (cmax as u128)) { cmax } else { (need_u128 as u64) };
                let c = if (need_u64 > 0) { need_u64 } else { cmax };
                if (c > 0) { let (g,l) = realize_long_ul(acc.avg_long_1e6, px, c, market.series.contract_size); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
            } else {
                let cmax2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
                let need_u64_b = if (need_u128 > (cmax2 as u128)) { cmax2 } else { (need_u128 as u64) };
                let c2 = if (need_u64_b > 0) { need_u64_b } else { cmax2 };
                if (c2 > 0) { let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px, c2, market.series.contract_size); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
            };
        };
        apply_realized_to_account<Collat>(market, &mut acc, realized_gain, realized_loss, vault, clock, ctx);
        // penalty
        let notional_1e6 = (closed as u128) * (px as u128) * (market.series.contract_size as u128);
        let pen = ((notional_1e6 * (market.liquidation_fee_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let have = balance::value(&acc.collat);
        let pay = if (pen <= have) { pen } else { have };
        if (pay > 0) { let keeper_bps: u64 = market.keeper_incentive_bps; let keeper_cut: u64 = ((pay as u128) * (keeper_bps as u128) / (fees::bps_denom() as u128)) as u64; let mut pen_coin = coin::from_balance(balance::split(&mut acc.collat, pay), ctx); if (keeper_cut > 0) { let kc = coin::split(&mut pen_coin, keeper_cut, ctx); transfer::public_transfer(kc, ctx.sender()); }; fees::pnl_deposit<Collat>(vault, pen_coin); };
        store_account<Collat>(market, victim, acc);
        event::emit(Liquidated { market_id: object::id(market), who: victim, qty_closed: closed, exec_price_1e6: px, penalty_collat: pay, timestamp_ms: clock.timestamp_ms() });
    }

    // Views & helpers
    fun current_gas_price_1e6(ctx: &TxContext): u64 {
        // reference_gas_price is in MIST; treat MIST units directly as 1e6-scaled price units
        sui::tx_context::reference_gas_price(ctx)
    }

    fun gated_price_and_update<Collat>(market: &mut GasMarket<Collat>, ctx: &TxContext): u64 {
        let cur = current_gas_price_1e6(ctx);
        let last = market.last_price_1e6;
        if (last > 0 && market.max_deviation_bps > 0) {
            let hi = if (cur >= last) { cur } else { last };
            let lo = if (cur >= last) { last } else { cur };
            let diff = hi - lo;
            let dev_bps: u64 = ((diff as u128) * (fees::bps_denom() as u128) / (last as u128)) as u64;
            assert!(dev_bps <= market.max_deviation_bps, E_PRICE_DEVIATION);
        };
        market.last_price_1e6 = cur;
        // Record LVP and TWAP sample pre-expiry
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        if (market.series.expiry_ms == 0 || now <= market.series.expiry_ms) {
            market.lvp_price_1e6 = cur; market.lvp_ts_ms = now;
            twap_append(&mut market.twap_ts_ms, &mut market.twap_px_1e6, now, cur, market.series.expiry_ms);
        };
        cur
    }

    fun twap_append(ts: &mut vector<u64>, px: &mut vector<u64>, now: u64, price_1e6: u64, expiry_ms: u64) {
        vector::push_back(ts, now); vector::push_back(px, price_1e6);
        let mut n = vector::length(ts);
        if (n > TWAP_MAX_SAMPLES) { let remove = n - TWAP_MAX_SAMPLES; let mut i = 0; while (i < remove) { let _ = vector::remove(ts, 0); let _2 = vector::remove(px, 0); i = i + 1; }; n = vector::length(ts); };
        let window_start = if (expiry_ms > 0) { if (TWAP_WINDOW_MS < expiry_ms) { expiry_ms - TWAP_WINDOW_MS } else { 0 } } else { if (TWAP_WINDOW_MS < now) { now - TWAP_WINDOW_MS } else { 0 } };
        while (vector::length(ts) > 0) { let oldest = *vector::borrow(ts, 0); if (oldest >= window_start) break; let _ = vector::remove(ts, 0); let _3 = vector::remove(px, 0); };
    }

    fun compute_twap_in_window(ts: &vector<u64>, px: &vector<u64>, end_ms: u64, window_ms: u64): u64 {
        let n = vector::length(ts); if (n == 0) return 0;
        let start_ms = if (window_ms < end_ms) { end_ms - window_ms } else { 0 };
        let mut i = 0; let mut sum_weighted: u128 = 0; let mut sum_dt: u128 = 0; let mut prev_t = start_ms; let mut prev_px = *vector::borrow(px, 0);
        while (i < n) { let t = *vector::borrow(ts, i); let p = *vector::borrow(px, i); if (t < start_ms) { i = i + 1; prev_t = t; prev_px = p; continue }; let dt = if (t > prev_t) { (t - prev_t) as u128 } else { 0u128 }; sum_weighted = sum_weighted + dt * (prev_px as u128); sum_dt = sum_dt + dt; prev_t = t; prev_px = p; i = i + 1; };
        let tail_dt = if (end_ms > prev_t) { (end_ms - prev_t) as u128 } else { 0u128 }; sum_weighted = sum_weighted + tail_dt * (prev_px as u128); sum_dt = sum_dt + tail_dt; if (sum_dt == 0) return *vector::borrow(px, n - 1); (sum_weighted / sum_dt) as u64
    }

    // === Keeper utilities ===
    /// Entry: update last observed gas price without trading
    public fun update_index_price<Collat>(market: &mut GasMarket<Collat>, _clock: &Clock, ctx: &mut TxContext) {
        let _ = gated_price_and_update<Collat>(market, ctx);
    }

    /// Entry: snap settlement price after expiry and cancel all resting orders, unlocking IM
    /// Settlement selection: prefer LVP (<= expiry). If missing, fall back to pre-expiry TWAP over TWAP_WINDOW_MS.
    public fun snap_settlement_price<Collat>(market: &mut GasMarket<Collat>, clock: &Clock, ctx: &mut TxContext) {
        let now = clock.timestamp_ms();
        assert!(market.series.expiry_ms > 0 && now >= market.series.expiry_ms, E_EXPIRED);
        assert!(!market.is_settled, E_ALREADY_SETTLED);
        let px = if (market.lvp_ts_ms > 0 && market.lvp_ts_ms <= market.series.expiry_ms) { market.lvp_price_1e6 } else { let tw = compute_twap_in_window(&market.twap_ts_ms, &market.twap_px_1e6, market.series.expiry_ms, TWAP_WINDOW_MS); if (tw > 0) { tw } else { current_gas_price_1e6(ctx) } };
        market.settlement_price_1e6 = px;
        market.is_settled = true;
        market.close_only = true;
        // Drain all orders and unlock IM
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

    fun equity<Collat>(acc: &Account<Collat>, price_1e6: u64, cs: u64): u64 {
        let coll = balance::value(&acc.collat);
        let (g_long, l_long) = if (acc.long_qty == 0) { (0, 0) } else { realize_long_ul(acc.avg_long_1e6, price_1e6, acc.long_qty, cs) };
        let (g_short, l_short) = if (acc.short_qty == 0) { (0, 0) } else { realize_short_ul(acc.avg_short_1e6, price_1e6, acc.short_qty, cs) };
        let gains: u128 = (g_long as u128) + (g_short as u128);
        let losses: u128 = (l_long as u128) + (l_short as u128);
        if (gains <= losses) {
            let net_loss = (losses - gains) as u64;
            if (coll > net_loss) { coll - net_loss } else { 0 }
        } else {
            let net_gain = (gains - losses) as u64;
            coll + net_gain
        }
    }

    fun required_margin_bps<Collat>(acc: &Account<Collat>, price_1e6: u64, cs: u64, bps: u64): u64 {
        let size_u128 = (acc.long_qty as u128) + (acc.short_qty as u128);
        let gross = size_u128 * (price_1e6 as u128) * (cs as u128);
        let im_1e6 = (gross * (bps as u128) / (fees::bps_denom() as u128));
        (im_1e6 / 1_000_000u128) as u64
    }

    fun required_margin_effective<Collat>(market: &GasMarket<Collat>, acc: &Account<Collat>, price_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((price_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let gross_contracts: u64 = acc.long_qty + acc.short_qty;
        let acc_notional_1e6: u128 = (gross_contracts as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, acc_notional_1e6);
        let mut base = market.initial_margin_bps;
        if (tier_bps > base) { base = tier_bps; };
        let oi = (market.total_long_qty as u128) + (market.total_short_qty as u128);
        if (market.imbalance_surcharge_bps_max == 0 || oi == 0) { return required_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, base) };
        let tl = market.total_long_qty as u128; let ts = market.total_short_qty as u128;
        let net = if (tl >= ts) { tl - ts } else { ts - tl };
        let dev_bps: u64 = ((net * (fees::bps_denom() as u128) / oi) as u64);
        if (dev_bps <= market.imbalance_threshold_bps) { return required_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, base) };
        let excess_bps: u64 = dev_bps - market.imbalance_threshold_bps;
        let add_bps: u64 = ((excess_bps as u128) * (market.imbalance_surcharge_bps_max as u128) / (fees::bps_denom() as u128)) as u64;
        required_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, base + add_bps)
    }

    fun apply_realized_to_account<Collat>(market: &GasMarket<Collat>, acc: &mut Account<Collat>, gain: u64, loss: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
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
                let rem_after = if (acc.pending_credit > 0) { acc.pending_credit } else { 0 };
                event::emit(PnlCreditPaid<Collat> { market_id: object::id(market), who: ctx.sender(), amount: pay, remaining_credit: rem_after, timestamp_ms: clock.timestamp_ms() });
            };
            if (gain > pay) {
                let credit = gain - pay;
                acc.pending_credit = acc.pending_credit + credit;
                event::emit(PnlCreditAccrued<Collat> { market_id: object::id(market), who: ctx.sender(), credited: credit, remaining_credit: acc.pending_credit, timestamp_ms: clock.timestamp_ms() });
            };
        };
    }

    fun realize_long_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (exit_1e6 >= entry_1e6) {
            let diff = (exit_1e6 - entry_1e6) as u128;
            let gain_1e6 = diff * (qty as u128) * (cs as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = (entry_1e6 - exit_1e6) as u128;
            let loss_1e6 = diff2 * (qty as u128) * (cs as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun realize_short_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (entry_1e6 >= exit_1e6) {
            let diff = (entry_1e6 - exit_1e6) as u128;
            let gain_1e6 = diff * (qty as u128) * (cs as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = (exit_1e6 - entry_1e6) as u128;
            let loss_1e6 = diff2 * (qty as u128) * (cs as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun wavg(prev_px: u64, prev_qty: u64, new_px: u64, new_qty: u64): u64 { if (prev_qty == 0) { new_px } else { (((prev_px as u128) * (prev_qty as u128) + (new_px as u128) * (new_qty as u128)) / ((prev_qty + new_qty) as u128)) as u64 } }
    fun take_or_new_account<Collat>(market: &mut GasMarket<Collat>, who: address): Account<Collat> { if (table::contains(&market.accounts, who)) { table::remove(&mut market.accounts, who) } else { Account { collat: balance::zero<Collat>(), long_qty: 0, short_qty: 0, avg_long_1e6: 0, avg_short_1e6: 0, pending_credit: 0, locked_im: 0 } } }
    fun store_account<Collat>(market: &mut GasMarket<Collat>, who: address, acc: Account<Collat>) { table::add(&mut market.accounts, who, acc); }

    fun im_for_qty(series: &GasSeries, qty: u64, price_1e6: u64, im_bps: u64): u64 {
        let gross_1e6: u128 = (qty as u128) * (price_1e6 as u128) * (series.contract_size as u128);
        let im_1e6: u128 = (gross_1e6 * (im_bps as u128)) / (fees::bps_denom() as u128);
        (im_1e6 / 1_000_000u128) as u64
    }

    fun im_for_qty_tiered<Collat>(market: &GasMarket<Collat>, acc: &Account<Collat>, qty: u64, price_1e6: u64): u64 {
        let per_unit_1e6: u128 = ((price_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let gross_after: u64 = acc.long_qty + acc.short_qty + qty;
        let notional_after_1e6: u128 = (gross_after as u128) * per_unit_1e6 * 1_000_000u128;
        let tier_bps = tier_bps_for_notional<Collat>(market, notional_after_1e6);
        let mut eff_bps = market.initial_margin_bps;
        if (tier_bps > eff_bps) { eff_bps = tier_bps; };
        im_for_qty(&market.series, qty, price_1e6, eff_bps)
    }

    fun tier_bps_for_notional<Collat>(market: &GasMarket<Collat>, notional_1e6: u128): u64 {
        let n = vector::length(&market.tier_thresholds_notional_1e6);
        if (n == 0) return market.initial_margin_bps;
        let mut i: u64 = 0; let mut out: u64 = market.initial_margin_bps;
        while (i < n) { let th_1e6 = *vector::borrow(&market.tier_thresholds_notional_1e6, i); if (notional_1e6 >= (th_1e6 as u128)) { out = *vector::borrow(&market.tier_im_bps, i); }; i = i + 1; };
        out
    }

    fun unlock_locked_im_for_fill<Collat>(market: &GasMarket<Collat>, acc: &mut Account<Collat>, price_1e6: u64, added_qty: u64) {
        if (added_qty == 0) return;
        let im = im_for_qty(&market.series, added_qty, price_1e6, market.initial_margin_bps);
        if (acc.locked_im >= im) { acc.locked_im = acc.locked_im - im; } else { acc.locked_im = 0; };
    }

    fun max_order_price(): u64 { ((1u128 << 63) - 1) as u64 }
    fun min_order_price(): u64 { 1 }

    public fun claim_pnl_credit<Collat>(market: &mut GasMarket<Collat>, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext, max_amount: u64) {
        assert!(table::contains(&market.accounts, ctx.sender()), E_NO_ACCOUNT);
        let mut acc = table::remove(&mut market.accounts, ctx.sender());
        let want = if (max_amount == 0 || max_amount > acc.pending_credit) { acc.pending_credit } else { max_amount };
        if (want > 0) {
            let avail = fees::pnl_available<Collat>(vault);
            let pay = if (want <= avail) { want } else { avail };
            if (pay > 0) {
                let coin_gain = fees::pnl_withdraw<Collat>(vault, pay, ctx);
                acc.collat.join(coin::into_balance(coin_gain));
                acc.pending_credit = acc.pending_credit - pay;
                event::emit(PnlCreditPaid<Collat> { market_id: object::id(market), who: ctx.sender(), amount: pay, remaining_credit: acc.pending_credit, timestamp_ms: clock.timestamp_ms() });
            };
        };
        store_account<Collat>(market, ctx.sender(), acc);
    }

    public fun settle_self<Collat>(market: &mut GasMarket<Collat>, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
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
    }

    // Test-only views
    #[test_only]
    public fun view_params<Collat>(market: &GasMarket<Collat>): (u64, u64, u64, u64, u64) {
        (market.series.expiry_ms, market.series.contract_size, market.initial_margin_bps, market.maintenance_margin_bps, market.liquidation_fee_bps)
    }

    #[test_only]
    public fun account_collateral<Collat>(market: &GasMarket<Collat>, who: address): u64 {
        if (!table::contains(&market.accounts, who)) { 0 } else { let a = table::borrow(&market.accounts, who); balance::value(&a.collat) }
    }

    #[test_only]
    public fun account_position<Collat>(market: &GasMarket<Collat>, who: address): (u64, u64, u64, u64) {
        if (!table::contains(&market.accounts, who)) { (0, 0, 0, 0) } else { let a = table::borrow(&market.accounts, who); (a.long_qty, a.short_qty, a.avg_long_1e6, a.avg_short_1e6) }
    }

    /// Views
    public fun account_pending_credit<Collat>(market: &GasMarket<Collat>, who: address): u64 { if (!table::contains(&market.accounts, who)) { 0 } else { let a = table::borrow(&market.accounts, who); a.pending_credit } }
    public fun market_open_interest<Collat>(market: &GasMarket<Collat>): (u64, u64) { (market.total_long_qty, market.total_short_qty) }
}

