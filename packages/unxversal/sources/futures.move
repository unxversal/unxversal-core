/// Module: unxversal_futures
/// ------------------------------------------------------------
/// Linear futures engine with cash settlement, oracle pricing (Switchboard),
/// per-market collateral coin, staking/UNXV fee discounts, admin-gated params,
/// deposit/withdraw collateral, open/close long & short, liquidation, and expiry settlement.
///
/// Design choices:
/// - Market trades execute at oracle mid price (no internal orderbook).
/// - Fees: taker-only protocol fee on notional using `fees::futures_taker_fee_bps`.
///   Discount path: either UNXV payment discount or staking-tier discount, configurable in `FeeConfig`.
/// - Collateral is a single coin type Collat for the market. PnL and fees accrue in Collat.
/// - Positions use netting logic: opening against existing opposite reduces that side first (realizes PnL),
///   then adds to same-side with weighted average entry price.
/// - Liquidation at maintenance margin; penalty is sent to FeeVault (admin can later convert to USDC via DeepBook).
#[allow(lint(self_transfer))]
module unxversal::futures {
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
    use switchboard::aggregator::Aggregator;

    // Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO: u64 = 2;
    const E_NO_ACCOUNT: u64 = 3;
    const E_INSUFFICIENT_BALANCE: u64 = 4;
    const E_UNDER_INITIAL_MARGIN: u64 = 5;
    const E_UNDER_MAINT_MARGIN: u64 = 6;
    const E_EXPIRED: u64 = 7;
    const E_CLOSE_ONLY: u64 = 8;
    const E_PRICE_DEVIATION: u64 = 9;
    const E_EXPOSURE_CAP: u64 = 10;

    /// Futures series parameters
    public struct FuturesSeries has copy, drop, store {
        expiry_ms: u64,              // epoch ms; 0 means perpetual-style (no expiry) but used only for clamp
        symbol: String,              // oracle symbol, e.g., "SUI/USDC"
        contract_size: u64,          // quote units per 1 contract when price is scaled 1e6
    }

    /// Per-account state for a market
    public struct Account<phantom Collat> has store {
        collat: Balance<Collat>,
        long_qty: u64,
        short_qty: u64,
        avg_long_1e6: u64,
        avg_short_1e6: u64,
        /// Realized gains that could not be paid immediately due to PnL vault shortfall
        /// These are denominated in Collat units and can be claimed later
        pending_credit: u64,
    }

    /// Market shared object
    public struct FuturesMarket<phantom Collat> has key, store {
        id: UID,
        series: FuturesSeries,
        accounts: Table<address, Account<Collat>>,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        keeper_incentive_bps: u64,
        /// Close-only mode toggle (true allows only trades that reduce exposure for the account)
        close_only: bool,
        /// Max allowed price deviation vs last accepted price, in bps (0 disables gating)
        max_deviation_bps: u64,
        /// Last accepted oracle price (1e6); 0 until first update
        last_price_1e6: u64,
        /// Portion of Collat fees routed to PnL reserve, in bps of fee_amt (0 = all to fee bucket)
        pnl_fee_share_bps: u64,
        /// Target buffer over initial margin when liquidating (in bps)
        liq_target_buffer_bps: u64,
        /// Per-account gross contract cap (0 = unlimited)
        account_max_gross_qty: u64,
        /// Per-market gross contract cap across all users (0 = unlimited)
        market_max_gross_qty: u64,
        /// Open interest tracking (sum of outstanding contracts per side)
        total_long_qty: u64,
        total_short_qty: u64,
        /// Imbalance surcharge parameters (bps). If abs(netOI)/OI > threshold, add up to max bps to IM
        imbalance_surcharge_bps_max: u64,
        imbalance_threshold_bps: u64,
    }

    // Events
    public struct MarketInitialized has copy, drop { market_id: ID, symbol: String, expiry_ms: u64, contract_size: u64, initial_margin_bps: u64, maintenance_margin_bps: u64, liquidation_fee_bps: u64, keeper_incentive_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, realized_gain: u64, realized_loss: u64, new_long: u64, new_short: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_units: u64, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }
    public struct Settled has copy, drop { market_id: ID, who: address, price_1e6: u64, timestamp_ms: u64 }
    /// Emitted when realized gain cannot be fully paid and is recorded as a credit
    public struct PnlCreditAccrued<phantom Collat> has copy, drop { market_id: ID, who: address, credited: u64, remaining_credit: u64, timestamp_ms: u64 }
    /// Emitted when realized gain is paid from the PnL vault to user collateral (either during trade/liq or via claim)
    public struct PnlCreditPaid<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, remaining_credit: u64, timestamp_ms: u64 }

    // === Init ===
    public fun init_market<Collat>(
        reg_admin: &AdminRegistry,
        expiry_ms: u64,
        symbol: String,
        contract_size: u64,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
        keeper_incentive_bps: u64,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let m = FuturesMarket<Collat> {
            id: object::new(ctx),
            series: FuturesSeries { expiry_ms, symbol, contract_size },
            accounts: table::new<address, Account<Collat>>(ctx),
            initial_margin_bps,
            maintenance_margin_bps,
            liquidation_fee_bps,
            keeper_incentive_bps,
            close_only: false,
            max_deviation_bps: 0,
            last_price_1e6: 0,
            pnl_fee_share_bps: 0,
            liq_target_buffer_bps: 0,
            account_max_gross_qty: 0,
            market_max_gross_qty: 0,
            total_long_qty: 0,
            total_short_qty: 0,
            imbalance_surcharge_bps_max: 0,
            imbalance_threshold_bps: 0,
        };
        event::emit(MarketInitialized { market_id: object::id(&m), symbol: clone_string(&m.series.symbol), expiry_ms, contract_size, initial_margin_bps, maintenance_margin_bps, liquidation_fee_bps, keeper_incentive_bps });
        transfer::share_object(m);
    }

    // === Admin updaters ===
    public fun set_margins<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, initial_bps: u64, maint_bps: u64, liq_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.initial_margin_bps = initial_bps;
        market.maintenance_margin_bps = maint_bps;
        market.liquidation_fee_bps = liq_fee_bps;
    }

    public fun set_keeper_incentive_bps<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, keeper_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.keeper_incentive_bps = keeper_bps;
    }

    /// Admin: set close-only mode
    public fun set_close_only<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, enabled: bool, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.close_only = enabled;
    }

    /// Admin: set price deviation gate in bps (0 disables)
    public fun set_price_deviation_bps<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, max_dev_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.max_deviation_bps = max_dev_bps;
    }

    /// Admin: set PnL reserve fee share (portion of Collat fees allocated to PnL bucket)
    public fun set_pnl_fee_share_bps<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, share_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(share_bps <= fees::bps_denom(), E_EXPOSURE_CAP);
        market.pnl_fee_share_bps = share_bps;
    }

    /// Admin: set liquidation target buffer over IM in bps
    public fun set_liq_target_buffer_bps<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, buffer_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.liq_target_buffer_bps = buffer_bps;
    }

    /// Admin: set exposure caps
    public fun set_exposure_caps<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, account_max_gross_qty: u64, market_max_gross_qty: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.account_max_gross_qty = account_max_gross_qty;
        market.market_max_gross_qty = market_max_gross_qty;
    }

    /// Admin: set imbalance surcharge parameters
    public fun set_imbalance_params<Collat>(reg_admin: &AdminRegistry, market: &mut FuturesMarket<Collat>, surcharge_max_bps: u64, threshold_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.imbalance_surcharge_bps_max = surcharge_max_bps;
        market.imbalance_threshold_bps = threshold_bps;
    }

    // === Collateral management ===
    public fun deposit_collateral<Collat>(market: &mut FuturesMarket<Collat>, c: Coin<Collat>, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        let bal = coin::into_balance(c);
        acc.collat.join(bal);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralDeposited<Collat> { market_id: object::id(market), who: ctx.sender(), amount: amt, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun withdraw_collateral<Collat>(
        market: &mut FuturesMarket<Collat>,
        amount: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Collat> {
        assert!(amount > 0, E_ZERO);
        let price_1e6 = gated_price_and_update<Collat>(market, reg, agg, clock);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        // compute equity and required initial margin after withdrawal
        let equity_before = equity_collat(&acc, price_1e6, market.series.contract_size);
        assert!(equity_before >= amount, E_INSUFFICIENT_BALANCE);
        // simulate withdrawal
        let eq_after = equity_before - amount;
        let req_im = required_initial_margin_bps(&acc, price_1e6, market.series.contract_size, market.initial_margin_bps);
        assert!(eq_after >= req_im, E_UNDER_INITIAL_MARGIN);
        let part = balance::split(&mut acc.collat, amount);
        let coin_out = coin::from_balance(part, ctx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralWithdrawn<Collat> { market_id: object::id(market), who: ctx.sender(), amount, timestamp_ms: clock.timestamp_ms() });
        coin_out
    }

    // === Trading ===
    /// Open or increase a long position by `qty` contracts at oracle price; closes shorts first.
    public fun open_long<Collat>(
        market: &mut FuturesMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        trade_internal<Collat>(market, /*is_buy=*/true, qty, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv_fee, clock, ctx);
        option::destroy_none(maybe_unxv_fee);
    }

    /// Open or increase a short position by `qty` contracts at oracle price; closes longs first.
    public fun open_short<Collat>(
        market: &mut FuturesMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        trade_internal<Collat>(market, /*is_buy=*/false, qty, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv_fee, clock, ctx);
        option::destroy_none(maybe_unxv_fee);
    }

    /// Close part of an existing long position (sell) at oracle price.
    public fun close_long<Collat>(
        market: &mut FuturesMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        // closing long is equivalent to opening short for qty
        trade_internal<Collat>(market, /*is_buy=*/false, qty, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv_fee, clock, ctx);
        option::destroy_none(maybe_unxv_fee);
    }

    /// Close part of an existing short position (buy) at oracle price.
    public fun close_short<Collat>(
        market: &mut FuturesMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut maybe_unxv_fee: Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
        qty: u64,
    ) {
        // closing short is equivalent to opening long for qty
        trade_internal<Collat>(market, /*is_buy=*/true, qty, reg, agg, cfg, vault, staking_pool, &mut maybe_unxv_fee, clock, ctx);
        option::destroy_none(maybe_unxv_fee);
    }

    // Unified trade entry
    fun trade_internal<Collat>(
        market: &mut FuturesMarket<Collat>,
        is_buy: bool,
        qty: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        maybe_unxv_fee: &mut Option<Coin<UNXV>>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(qty > 0, E_ZERO);
        let now = clock.timestamp_ms();
        if (market.series.expiry_ms > 0) { assert!(now <= market.series.expiry_ms, E_EXPIRED); };
        let px_1e6 = gated_price_and_update<Collat>(market, reg, agg, clock);
        // Overflow-safe notional: ((px * cs)/1e6) * qty * 1e6
        let per_unit_1e6: u128 = ((px_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let notional_1e6 = (qty as u128) * per_unit_1e6 * 1_000_000u128;
        // compute fee in Collat terms
        let taker_bps = fees::futures_taker_fee_bps(cfg);
        let pay_with_unxv = option::is_some(maybe_unxv_fee);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt = ((notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64; // convert from 1e6 to whole units

        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        // Close-only mode enforcement: only allow reducing opposing side without adding new exposure
        if (market.close_only) {
            if (is_buy) { assert!(qty <= acc.short_qty, E_CLOSE_ONLY); } else { assert!(qty <= acc.long_qty, E_CLOSE_ONLY); };
        };

        // Realize PnL if crossing sides
        let mut realized_gain: u64 = 0;
        let mut realized_loss: u64 = 0;
        let mut reduced_long: u64 = 0; let mut reduced_short: u64 = 0; let mut add_long: u64 = 0; let mut add_short: u64 = 0;
        if (is_buy) {
            let r = if (acc.short_qty > 0) { if (qty <= acc.short_qty) { qty } else { acc.short_qty } } else { 0 };
            if (r > 0) { let (g,l) = realize_short_ul(acc.avg_short_1e6, px_1e6, r, market.series.contract_size); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.short_qty = acc.short_qty - r; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; reduced_short = r; };
            let a = if (qty > r) { qty - r } else { 0 };
            if (a > 0) { acc.avg_long_1e6 = weighted_avg_price(acc.avg_long_1e6, acc.long_qty, px_1e6, a); acc.long_qty = acc.long_qty + a; add_long = a; };
        } else {
            let r2 = if (acc.long_qty > 0) { if (qty <= acc.long_qty) { qty } else { acc.long_qty } } else { 0 };
            if (r2 > 0) { let (g2,l2) = realize_long_ul(acc.avg_long_1e6, px_1e6, r2, market.series.contract_size); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.long_qty = acc.long_qty - r2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; reduced_long = r2; };
            let a2 = if (qty > r2) { qty - r2 } else { 0 };
            if (a2 > 0) { acc.avg_short_1e6 = weighted_avg_price(acc.avg_short_1e6, acc.short_qty, px_1e6, a2); acc.short_qty = acc.short_qty + a2; add_short = a2; };
        };

        // Enforce exposure caps before finalizing adds
        if (add_long > 0 || add_short > 0) {
            let gross_acc = acc.long_qty + acc.short_qty;
            if (market.account_max_gross_qty > 0) { assert!(gross_acc <= market.account_max_gross_qty, E_EXPOSURE_CAP); };
            let gross_market_before = market.total_long_qty + market.total_short_qty;
            let gross_market_after = gross_market_before - reduced_long - reduced_short + add_long + add_short;
            if (market.market_max_gross_qty > 0) { assert!(gross_market_after <= market.market_max_gross_qty, E_EXPOSURE_CAP); };
        };

        // Update market OI totals (reductions first, then adds)
        if (reduced_long > 0) { market.total_long_qty = market.total_long_qty - reduced_long; };
        if (reduced_short > 0) { market.total_short_qty = market.total_short_qty - reduced_short; };
        if (add_long > 0) { market.total_long_qty = market.total_long_qty + add_long; };
        if (add_short > 0) { market.total_short_qty = market.total_short_qty + add_short; };

        // Apply realized PnL to account (deposit losses to PnL vault; pay gains up to vault availability; credit remainder)
        apply_realized_to_account<Collat>(market, &mut acc, realized_gain, realized_loss, vault, clock, ctx);

        // Charge protocol fee either in UNXV or Collat
        if (pay_with_unxv) {
            let u = option::extract(maybe_unxv_fee);
            // Replace fee_amt with UNXV-specific discounted payment amount already captured via t_eff; here we just split UNXV in full amount provided.
            // Caller supplies sufficient UNXV to cover; split exact fee_amt-equivalent UNXV outside scope is non-trivial without price; we accept full provided and split into shares.
            let (stakers_coin, treasury_coin, _burn_amt) = fees::accrue_unxv_and_split(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_units: (notional_1e6 / 1_000_000u128) as u64, fee_paid: 0, paid_in_unxv: true, timestamp_ms: clock.timestamp_ms() });
        } else {
            // Deduct from collateral balance
            assert!(balance::value(&acc.collat) >= fee_amt, E_INSUFFICIENT_BALANCE);
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
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_units: (notional_1e6 / 1_000_000u128) as u64, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: clock.timestamp_ms() });
        };

        // Margin check post-trade
        let eq = equity_collat(&acc, px_1e6, market.series.contract_size);
        let req_im = required_initial_margin_effective<Collat>(market, &acc, px_1e6);
        assert!(eq >= req_im, E_UNDER_INITIAL_MARGIN);

        event::emit(PositionChanged { market_id: object::id(market), who: ctx.sender(), is_long: is_buy, qty_delta: qty, exec_price_1e6: px_1e6, realized_gain: realized_gain, realized_loss: realized_loss, new_long: acc.long_qty, new_short: acc.short_qty, timestamp_ms: clock.timestamp_ms() });
        store_account<Collat>(market, ctx.sender(), acc);
    }

    // === Liquidation ===
    public fun liquidate<Collat>(
        market: &mut FuturesMarket<Collat>,
        victim: address,
        qty: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        vault: &mut FeeVault,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        assert!(qty > 0, E_ZERO);
        let px_1e6 = current_price_1e6(&market.series, reg, agg, clock);
        let mut acc = table::remove(&mut market.accounts, victim);
        // Check maintenance margin
        let eq = equity_collat(&acc, px_1e6, market.series.contract_size);
        let req_mm = required_initial_margin_bps(&acc, px_1e6, market.series.contract_size, market.maintenance_margin_bps);
        assert!(eq < req_mm, E_UNDER_MAINT_MARGIN);

        // Compute target IM bps = initial_margin_bps + buffer
        let target_bps = market.initial_margin_bps + market.liq_target_buffer_bps;

        // Determine minimal close qty to restore eq >= req_im(target)
        let gross_before = ((acc.long_qty as u128) + (acc.short_qty as u128)) * (px_1e6 as u128) * (market.series.contract_size as u128) / 1_000_000u128;
        let req0: u128 = (gross_before * (target_bps as u128)) / (fees::bps_denom() as u128);
        let eq0: u128 = (eq as u128);
        let shortfall: u128 = if (eq0 >= req0) { 0u128 } else { req0 - eq0 };

        let per_contract_val: u64 = ((px_1e6 as u128) * (market.series.contract_size as u128) / 1_000_000u128) as u64;
        let req_pc: u64 = ((per_contract_val as u128) * (target_bps as u128) / (fees::bps_denom() as u128)) as u64;
        // Prefer closing the larger side to reduce gross exposure fastest
        let close_long_pref = acc.long_qty >= acc.short_qty;

        let mut closed: u64 = 0; let mut realized_gain: u64 = 0; let mut realized_loss: u64 = 0;
        if (shortfall == 0) {
            // Already above target; close min(qty, larger side) as safety noop
            if (acc.long_qty >= acc.short_qty) {
                let c = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
                if (c > 0) { let (g,l) = realize_long_ul(acc.avg_long_1e6, px_1e6, c, market.series.contract_size); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
            } else {
                let c2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
                if (c2 > 0) { let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px_1e6, c2, market.series.contract_size); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
            };
        } else {
            // conservative: assume margin freed per closed contract ≈ req_pc; ceil_div(shortfall, req_pc)
            let need_c: u64 = if (req_pc > 0) {
                let den = req_pc as u128;
                let num = shortfall + den - 1u128;
                (num / den) as u64
            } else { qty };
            if (close_long_pref && acc.long_qty > 0) {
                let cmax = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
                let c = if (need_c > 0 && need_c <= cmax) { need_c } else { cmax };
                if (c > 0) { let (g,l) = realize_long_ul(acc.avg_long_1e6, px_1e6, c, market.series.contract_size); realized_gain = realized_gain + g; realized_loss = realized_loss + l; acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; market.total_long_qty = market.total_long_qty - c; closed = c; };
            } else if (acc.short_qty > 0) {
                let cmax2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
                let c2 = if (need_c > 0 && need_c <= cmax2) { need_c } else { cmax2 };
                if (c2 > 0) { let (g2,l2) = realize_short_ul(acc.avg_short_1e6, px_1e6, c2, market.series.contract_size); realized_gain = realized_gain + g2; realized_loss = realized_loss + l2; acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; market.total_short_qty = market.total_short_qty - c2; closed = c2; };
            };
        };

        apply_realized_to_account<Collat>(market, &mut acc, realized_gain, realized_loss, vault, clock, ctx);

        // Penalty taken from victim remaining collateral; split keeper incentive and deposit remainder to PnL bucket
        // Overflow-safe notional: ((px * cs)/1e6) * qty * 1e6
        let per_unit_1e6: u128 = ((px_1e6 as u128) * (market.series.contract_size as u128)) / 1_000_000u128;
        let notional_1e6 = (closed as u128) * per_unit_1e6 * 1_000_000u128;
        let pen = ((notional_1e6 * (market.liquidation_fee_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let available = balance::value(&acc.collat);
        let pay = if (pen <= available) { pen } else { available };
        if (pay > 0) {
            let keeper_bps: u64 = market.keeper_incentive_bps;
            let keeper_cut: u64 = ((pay as u128) * (keeper_bps as u128) / (fees::bps_denom() as u128)) as u64;
            let mut pen_coin = coin::from_balance(balance::split(&mut acc.collat, pay), ctx);
            if (keeper_cut > 0) { let kc = coin::split(&mut pen_coin, keeper_cut, ctx); transfer::public_transfer(kc, ctx.sender()); };
            fees::pnl_deposit<Collat>(vault, pen_coin);
        };

        store_account<Collat>(market, victim, acc);
        event::emit(Liquidated { market_id: object::id(market), who: victim, qty_closed: closed, exec_price_1e6: px_1e6, penalty_collat: pay, timestamp_ms: clock.timestamp_ms() });
    }

    // === Expiry settlement ===
    public fun settle_after_expiry<Collat>(
        market: &mut FuturesMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now = clock.timestamp_ms();
        assert!(market.series.expiry_ms > 0 && now >= market.series.expiry_ms, E_EXPIRED);
        // Users call withdraw/adjust explicitly; here we only emit a marker and do nothing heavy
        event::emit(Settled { market_id: object::id(market), who: ctx.sender(), price_1e6: current_price_1e6(&market.series, reg, agg, clock), timestamp_ms: clock.timestamp_ms() });
        let _ = ctx; // silence
    }

    /// User-triggered settlement to flatten positions and realize PnL with credit fallback
    public fun settle_self<Collat>(
        market: &mut FuturesMarket<Collat>,
        reg: &OracleRegistry,
        agg: &Aggregator,
        vault: &mut FeeVault,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(table::contains(&market.accounts, ctx.sender()), E_NO_ACCOUNT);
        let px = gated_price_and_update<Collat>(market, reg, agg, clock);
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

    // === Views & helpers ===
    public fun account_equity_1e6<Collat>(market: &FuturesMarket<Collat>, who: address, reg: &OracleRegistry, agg: &Aggregator, clock: &Clock): u128 {
        if (!table::contains(&market.accounts, who)) return 0;
        let acc = table::borrow(&market.accounts, who);
        let px = current_price_1e6(&market.series, reg, agg, clock);
        let eq = equity_collat(acc, px, market.series.contract_size);
        (eq as u128) * 1_000_000u128
    }

    /// View: account pending credit in Collat units
    public fun account_pending_credit<Collat>(market: &FuturesMarket<Collat>, who: address): u64 {
        if (!table::contains(&market.accounts, who)) return 0;
        let acc = table::borrow(&market.accounts, who);
        acc.pending_credit
    }

    /// View: market open interest
    public fun market_open_interest<Collat>(market: &FuturesMarket<Collat>): (u64, u64) {
        (market.total_long_qty, market.total_short_qty)
    }

    fun equity_collat<Collat>(acc: &Account<Collat>, price_1e6: u64, contract_size: u64): u64 {
        let coll = balance::value(&acc.collat);
        let (g_long, l_long) = if (acc.long_qty == 0) { (0, 0) } else { realize_long_ul(acc.avg_long_1e6, price_1e6, acc.long_qty, contract_size) };
        let (g_short, l_short) = if (acc.short_qty == 0) { (0, 0) } else { realize_short_ul(acc.avg_short_1e6, price_1e6, acc.short_qty, contract_size) };
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

    fun required_initial_margin_bps<Collat>(acc: &Account<Collat>, price_1e6: u64, contract_size: u64, bps: u64): u64 {
        let size_u128 = (acc.long_qty as u128) + (acc.short_qty as u128);
        let gross = size_u128 * (price_1e6 as u128) * (contract_size as u128);
        let im_1e6 = (gross * (bps as u128) / (fees::bps_denom() as u128));
        (im_1e6 / 1_000_000u128) as u64
    }

    fun required_initial_margin_effective<Collat>(market: &FuturesMarket<Collat>, acc: &Account<Collat>, price_1e6: u64): u64 {
        let base = market.initial_margin_bps;
        let total_long = market.total_long_qty as u128;
        let total_short = market.total_short_qty as u128;
        let oi = (market.total_long_qty as u128) + (market.total_short_qty as u128);
        if (market.imbalance_surcharge_bps_max == 0 || oi == 0) {
            return required_initial_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, base);
        };
        let net = if (total_long >= total_short) { total_long - total_short } else { total_short - total_long };
        let dev_bps: u64 = ((net * (fees::bps_denom() as u128) / oi) as u64);
        if (dev_bps <= market.imbalance_threshold_bps) {
            return required_initial_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, base);
        };
        let excess_bps: u64 = dev_bps - market.imbalance_threshold_bps;
        // scale surcharge proportionally up to max at 100% imbalance
        let add_bps: u64 = ((excess_bps as u128) * (market.imbalance_surcharge_bps_max as u128) / (fees::bps_denom() as u128)) as u64;
        let eff_bps = base + add_bps;
        required_initial_margin_bps<Collat>(acc, price_1e6, market.series.contract_size, eff_bps)
    }

    fun realize_long_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, contract_size: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (exit_1e6 >= entry_1e6) {
            let diff = exit_1e6 - entry_1e6;
            let gain_1e6 = (diff as u128) * (qty as u128) * (contract_size as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = entry_1e6 - exit_1e6;
            let loss_1e6 = (diff2 as u128) * (qty as u128) * (contract_size as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun realize_short_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, contract_size: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (entry_1e6 >= exit_1e6) {
            let diff = entry_1e6 - exit_1e6;
            let gain_1e6 = (diff as u128) * (qty as u128) * (contract_size as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = exit_1e6 - entry_1e6;
            let loss_1e6 = (diff2 as u128) * (qty as u128) * (contract_size as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun weighted_avg_price(prev_px_1e6: u64, prev_qty: u64, new_px_1e6: u64, new_qty: u64): u64 {
        if (prev_qty == 0) { return new_px_1e6 };
        let num = (prev_px_1e6 as u128) * (prev_qty as u128) + (new_px_1e6 as u128) * (new_qty as u128);
        let den = (prev_qty as u128) + (new_qty as u128);
        (num / den) as u64
    }

    fun apply_realized_to_account<Collat>(market: &FuturesMarket<Collat>, acc: &mut Account<Collat>, gain: u64, loss: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        if (loss > 0) {
            let have = balance::value(&acc.collat);
            let pay_loss = if (loss <= have) { loss } else { have };
            if (pay_loss > 0) {
                let bal_loss = balance::split(&mut acc.collat, pay_loss);
                let coin_loss = coin::from_balance(bal_loss, ctx);
                // route realized losses to PnL bucket
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

    fun take_or_new_account<Collat>(market: &mut FuturesMarket<Collat>, who: address): Account<Collat> {
        if (table::contains(&market.accounts, who)) { table::remove(&mut market.accounts, who) } else { Account { collat: balance::zero<Collat>(), long_qty: 0, short_qty: 0, avg_long_1e6: 0, avg_short_1e6: 0, pending_credit: 0 } }
    }

    fun store_account<Collat>(market: &mut FuturesMarket<Collat>, who: address, acc: Account<Collat>) {
        table::add(&mut market.accounts, who, acc);
    }

    /// Claim pending realized PnL credits up to `max_amount` (0 = claim all available)
    public fun claim_pnl_credit<Collat>(
        market: &mut FuturesMarket<Collat>,
        vault: &mut FeeVault,
        clock: &Clock,
        ctx: &mut TxContext,
        max_amount: u64,
    ) {
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

    fun current_price_1e6(series: &FuturesSeries, reg: &OracleRegistry, agg: &Aggregator, clock: &Clock): u64 {
        uoracle::get_price_for_symbol(reg, clock, &series.symbol, agg)
    }

    fun gated_price_and_update<Collat>(market: &mut FuturesMarket<Collat>, reg: &OracleRegistry, agg: &Aggregator, clock: &Clock): u64 {
        let cur = current_price_1e6(&market.series, reg, agg, clock);
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

    fun clone_string(s: &String): String {
        let b = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(b);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(b, i)); i = i + 1; };
        string::utf8(out)
    }
}



