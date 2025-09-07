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
        account_max_gross_qty: u64,
        market_max_gross_qty: u64,
        total_long_qty: u64,
        total_short_qty: u64,
        imbalance_surcharge_bps_max: u64,
        imbalance_threshold_bps: u64,
        book: Book,
        owners: Table<u128, address>,
    }

    public struct MarketInitialized has copy, drop { market_id: ID, expiry_ms: u64, contract_size: u64, initial_margin_bps: u64, maintenance_margin_bps: u64, liquidation_fee_bps: u64, keeper_incentive_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_1e6: u128, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }
    public struct PnlCreditAccrued<phantom Collat> has copy, drop { market_id: ID, who: address, credited: u64, remaining_credit: u64, timestamp_ms: u64 }
    public struct PnlCreditPaid<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, remaining_credit: u64, timestamp_ms: u64 }

    // === Init ===
    public fun init_market<Collat>(reg_admin: &AdminRegistry, expiry_ms: u64, contract_size: u64, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, keeper_bps: u64, tick_size: u64, lot_size: u64, min_size: u64, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let m = GasMarket<Collat> { id: object::new(ctx), series: GasSeries { expiry_ms, contract_size }, accounts: table::new<address, Account<Collat>>(ctx), initial_margin_bps: im_bps, maintenance_margin_bps: mm_bps, liquidation_fee_bps: liq_fee_bps, keeper_incentive_bps: keeper_bps, close_only: false, max_deviation_bps: 0, last_price_1e6: 0, pnl_fee_share_bps: 0, liq_target_buffer_bps: 0, account_max_gross_qty: 0, market_max_gross_qty: 0, total_long_qty: 0, total_short_qty: 0, imbalance_surcharge_bps_max: 0, imbalance_threshold_bps: 0, book: ubk::empty(tick_size, lot_size, min_size, ctx), owners: table::new<u128, address>(ctx) };
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

    public fun set_exposure_caps<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, account_max_gross_qty: u64, market_max_gross_qty: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.account_max_gross_qty = account_max_gross_qty;
        market.market_max_gross_qty = market_max_gross_qty;
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
        let price_1e6 = gated_price_and_update<Collat>(market, ctx);
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

    // === Trading (oracle price is reference gas price) ===
    public fun open_long<Collat>(market: &mut GasMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        taker_trade_internal<Collat>(market, true, qty, ((1u128 << 63) - 1) as u64, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun open_short<Collat>(market: &mut GasMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        taker_trade_internal<Collat>(market, false, qty, 1, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    fun taker_trade_internal<Collat>(market: &mut GasMarket<Collat>, is_buy: bool, qty: u64, limit_price_1e6: u64, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, maybe_unxv: &mut Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        let now = clock.timestamp_ms();
        if (market.series.expiry_ms > 0) { assert!(now <= market.series.expiry_ms, E_EXPIRED); };
        let px_1e6 = gated_price_and_update<Collat>(market, ctx);
        // Overflow-safe notional: ((px * cs) / 1e6) * qty * 1e6
        let per_unit_1e6: u128 = ((px_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let notional_1e6 = (qty as u128) * per_unit_1e6 * 1_000_000u128;
        // fees
        let taker_bps = fees::gasfut_taker_fee_bps(cfg);
        let pay_with_unxv = option::is_some(maybe_unxv);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt = ((notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;

        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        if (market.close_only) { if (is_buy) { assert!(qty <= acc.short_qty, E_CLOSE_ONLY); } else { assert!(qty <= acc.long_qty, E_CLOSE_ONLY); }; };
        let mut realized_gain: u64 = 0; let mut realized_loss: u64 = 0;
        let mut reduced_long: u64 = 0; let mut reduced_short: u64 = 0; let mut add_long: u64 = 0; let mut add_short: u64 = 0;
        if (is_buy) {
            let r = if (acc.short_qty > 0) { if (qty <= acc.short_qty) { qty } else { acc.short_qty } } else { 0 };
            if (r > 0) { let (g,l) = realize_short_ul(acc.avg_short_1e6, px_1e6, r, market.series.contract_size); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.short_qty = acc.short_qty - r; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; reduced_short = r; };
            let a = if (qty > r) { qty - r } else { 0 };
            if (a > 0) { acc.avg_long_1e6 = wavg(acc.avg_long_1e6, acc.long_qty, px_1e6, a); acc.long_qty = acc.long_qty + a; add_long = a; };
        } else {
            let r2 = if (acc.long_qty > 0) { if (qty <= acc.long_qty) { qty } else { acc.long_qty } } else { 0 };
            if (r2 > 0) { let (g2,l2) = realize_long_ul(acc.avg_long_1e6, px_1e6, r2, market.series.contract_size); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.long_qty = acc.long_qty - r2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; reduced_long = r2; };
            let a2 = if (qty > r2) { qty - r2 } else { 0 };
            if (a2 > 0) { acc.avg_short_1e6 = wavg(acc.avg_short_1e6, acc.short_qty, px_1e6, a2); acc.short_qty = acc.short_qty + a2; add_short = a2; };
        };
        // exposure caps
        if (add_long > 0 || add_short > 0) {
            let gross_acc = acc.long_qty + acc.short_qty;
            if (market.account_max_gross_qty > 0) { assert!(gross_acc <= market.account_max_gross_qty, E_EXPOSURE_CAP); };
            let gross_market_before = market.total_long_qty + market.total_short_qty;
            let gross_market_after = gross_market_before - reduced_long - reduced_short + add_long + add_short;
            if (market.market_max_gross_qty > 0) { assert!(gross_market_after <= market.market_max_gross_qty, E_EXPOSURE_CAP); };
        };
        if (reduced_long > 0) { market.total_long_qty = market.total_long_qty - reduced_long; };
        if (reduced_short > 0) { market.total_short_qty = market.total_short_qty - reduced_short; };
        if (add_long > 0) { market.total_long_qty = market.total_long_qty + add_long; };
        if (add_short > 0) { market.total_short_qty = market.total_short_qty + add_short; };

        // charge fee
        if (pay_with_unxv) {
            let u = option::extract(maybe_unxv);
            let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6, fee_paid: 0, paid_in_unxv: true, timestamp_ms: clock.timestamp_ms() });
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
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: clock.timestamp_ms() });
        };

        // Apply realized PnL
        apply_realized_to_account<Collat>(market, &mut acc, realized_gain, realized_loss, vault, clock, ctx);

        // IM check (effective)
        let eq = equity(&acc, px_1e6, market.series.contract_size);
        let req_im = required_margin_effective<Collat>(market, &acc, px_1e6);
        assert!(eq >= req_im, E_UNDER_IM);

        event::emit(PositionChanged { market_id: object::id(market), who: ctx.sender(), is_long: is_buy, qty_delta: qty, exec_price_1e6: px_1e6, timestamp_ms: clock.timestamp_ms() });
        store_account<Collat>(market, ctx.sender(), acc);
    }

    public fun liquidate<Collat>(market: &mut GasMarket<Collat>, victim: address, qty: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        assert!(qty > 0, E_ZERO);
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
        cur
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
        let base = market.initial_margin_bps;
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
        let px = gated_price_and_update<Collat>(market, ctx);
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

