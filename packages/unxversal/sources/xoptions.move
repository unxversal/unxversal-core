/// Module: unxversal_xoptions
/// ------------------------------------------------------------
/// Synthetic European options ("xoptions") that do not rely on an external
/// oracle. Instead, each options series maintains its own synthetic mark index
/// using an exponentially weighted moving average (EMA) of the series' mark
/// prices. The EMA pseudo-spot is used to determine in/out-of-the-money (ITM)
/// for exercise, and a canonical settlement price is snapped after expiry using
/// the last valid pre-expiry print (LVP) or a pre-expiry TWAP window.
///
/// Design notes:
/// - One `XOptionsMarket<Base, Quote>` manages many series (expiry, strike, is_call).
/// - Each series has an internal `Book` with bids (buyers) / asks (writers).
/// - Writers lock collateral when placing sell (ask) orders.
/// - Buyers pay premium on matching fills directly to maker addresses.
/// - On exercise: physical delivery (Call: Base to buyer, buyer pays Quote at strike;
///   Put: Quote to buyer, buyer delivers Base).
/// - Proceeds are pooled and writers claim pro-rata via a proceeds index.
/// - Protocol fees via FeeConfig with optional UNXV discount and weekly staking split.
#[allow(lint(self_transfer))]
module unxversal::xoptions {
    use sui::{
        clock::Clock,
        coin::{Self as coin, Coin},
        balance::{Self as balance, Balance},
        event,
        table::{Self as table, Table},
    };

    use std::{
        string::{Self as string, String},
        hash,
    };
    use unxversal::book::{Self as ubk, Book};
    use unxversal::utils as uutils;
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::staking::{Self as staking, StakingPool};
    use unxversal::unxv::UNXV;
    use unxversal::rewards as rewards;

    // Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_INVALID_SERIES: u64 = 2;
    const E_ZERO: u64 = 3;
    const E_EXPIRED: u64 = 4;
    const E_NOT_OWNER: u64 = 5;
    const E_COLLATERAL_MISMATCH: u64 = 8;
    const E_PAST_EXPIRY_EXERCISE: u64 = 9;
    const E_SERIES_EXISTS: u64 = 11;
    const E_MARK_GATE: u64 = 12;

    // Settlement anchoring (pre-expiry sampling)
    const TWAP_MAX_SAMPLES: u64 = 64;
    const TWAP_WINDOW_MS: u64 = 300_000; // 5 minutes

    /// Fixed-point scale for proceeds per unit index (1e12)
    const PROCEEDS_INDEX_SCALE: u128 = 1_000_000_000_000;

    // EMA defaults (per-minute alphas)
    const DEFAULT_ALPHA_NUM: u64 = 1;          // 1/480 ≈ 8h
    const DEFAULT_ALPHA_DEN: u64 = 480;
    const DEFAULT_ALPHA_LONG_NUM: u64 = 1;     // 1/43200 ≈ 30d
    const DEFAULT_ALPHA_LONG_DEN: u64 = 43200;
    const DEFAULT_CAP_MULTIPLE_BPS: u64 = 40000; // 4.0x
    const DEFAULT_MARK_GATE_BPS: u64 = 0;       // disabled by default

    // Data
    public struct OptionSeries has copy, drop, store {
        expiry_ms: u64,     // epoch ms
        strike_1e6: u64,    // price in quote per base, scaled 1e6
        is_call: bool,
        underlying: String, // metadata name
        // EMA params
        alpha_num: u64,
        alpha_den: u64,
        alpha_long_num: u64,
        alpha_long_den: u64,
        cap_multiple_bps: u64,
        mark_gate_bps: u64,
        initial_mark_1e6: u64,
    }

    /// Writer state for claims and outstanding obligations
    public struct WriterInfo has store {
        sold_units: u64,              // matched outstanding units
        exercised_units: u64,         // legacy; kept for compatibility (unused)
        claimed_proceeds_quote: u64,  // claimed quote (calls)
        claimed_proceeds_base: u64,   // claimed base (puts)
        locked_base: u64,             // currently locked base collateral
        locked_quote: u64,            // currently locked quote collateral
        proceeds_index_snap_1e12: u128,
    }

    /// Per-series state and vaults
    public struct SeriesState<phantom Base, phantom Quote> has store {
        series: OptionSeries,
        book: Book,
        owners: Table<u128, address>,       // maker order_id → maker address
        writer: Table<address, WriterInfo>, // address → writer info
        // pooled vaults
        pooled_base: Balance<Base>,         // writers' base collateral for calls
        pooled_quote: Balance<Quote>,       // writers' quote collateral for puts and proceeds for calls
        // aggregated metrics
        total_sold_units: u64,              // total outstanding matched sell units
        total_exercised_units: u64,         // total units exercised
        /// Cumulative proceeds per sold unit scaled by PROCEEDS_INDEX_SCALE
        proceeds_index_1e12: u128,
        settled: bool,
        /// Frozen settlement price for the series (1e6 scale)
        settlement_price_1e6: u64,
        /// Last valid pre-expiry synthetic mark and timestamp
        lvp_price_1e6: u64,
        lvp_ts_ms: u64,
        /// Pre-expiry TWAP sample buffers
        twap_ts_ms: vector<u64>,
        twap_px_1e6: vector<u64>,
        /// Synthetic EMA state
        ema_short_1e6: u64,
        ema_long_1e6: u64,
        last_mark_1e6: u64,
        last_sample_minute_ms: u64,
    }

    public struct XOptionsMarket<phantom Base, phantom Quote> has key, store {
        id: UID,
        series: Table<u128, SeriesState<Base, Quote>>,
    }

    // Buyer long position (fungible by series within this object)
    public struct OptionPosition<phantom Base, phantom Quote> has key, store {
        id: UID,
        key: u128,
        amount: u64,
    }

    // Events (mirrors options.move)
    public struct SeriesCreated has copy, drop { key: u128, expiry_ms: u64, strike_1e6: u64, is_call: bool }
    public struct SeriesCreatedV2 has copy, drop { market_id: ID, key: u128, expiry_ms: u64, strike_1e6: u64, is_call: bool, underlying_bytes: vector<u8>, tick_size: u64, lot_size: u64, min_size: u64 }
    public struct OrderPlaced has copy, drop { key: u128, order_id: u128, maker: address, price: u64, quantity: u64, is_bid: bool, expire_ts: u64 }
    public struct OrderCanceled has copy, drop { key: u128, order_id: u128, maker: address, quantity: u64 }
    public struct OrderFilled has copy, drop { key: u128, maker_order_id: u128, maker: address, taker: address, price: u64, base_qty: u64, premium_quote: u64, maker_remaining_qty: u64, timestamp_ms: u64 }
    public struct OrderExpired has copy, drop { key: u128, order_id: u128, maker: address, timestamp_ms: u64 }
    public struct Matched has copy, drop { key: u128, taker: address, total_units: u64, total_premium_quote: u64 }
    public struct Exercised has copy, drop { key: u128, exerciser: address, amount: u64, spot_1e6: u64 }
    public struct CollateralLocked has copy, drop { key: u128, writer: address, is_call: bool, amount_base: u64, amount_quote: u64, timestamp_ms: u64 }
    public struct CollateralUnlocked has copy, drop { key: u128, writer: address, is_call: bool, amount_base: u64, amount_quote: u64, reason: u8, timestamp_ms: u64 }
    public struct OptionPositionUpdated has copy, drop { key: u128, owner: address, position_id: ID, increase: bool, delta_units: u64, new_amount: u64, timestamp_ms: u64 }
    public struct WriterClaimed has copy, drop { key: u128, writer: address, amount_base: u64, amount_quote: u64, timestamp_ms: u64 }
    public struct SeriesSettled has copy, drop { key: u128, price_1e6: u64, timestamp_ms: u64 }

    // === Init ===
    public fun init_market<Base, Quote>(reg_admin: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let m = XOptionsMarket<Base, Quote> { id: object::new(ctx), series: table::new<u128, SeriesState<Base, Quote>>(ctx) };
        transfer::share_object(m);
    }

    // === Admin: create series ===
    public fun create_option_series<Base, Quote>(
        reg_admin: &AdminRegistry,
        market: &mut XOptionsMarket<Base, Quote>,
        expiry_ms: u64,
        strike_1e6: u64,
        is_call: bool,
        underlying: String,
        initial_mark_1e6: u64,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(expiry_ms > sui::tx_context::epoch_timestamp_ms(ctx), E_INVALID_SERIES);
        let key = series_key(expiry_ms, strike_1e6, is_call, &underlying);
        assert!(!table::contains(&market.series, key), E_SERIES_EXISTS);
        let ser = SeriesState<Base, Quote> {
            series: OptionSeries { expiry_ms, strike_1e6, is_call, underlying, alpha_num: DEFAULT_ALPHA_NUM, alpha_den: DEFAULT_ALPHA_DEN, alpha_long_num: DEFAULT_ALPHA_LONG_NUM, alpha_long_den: DEFAULT_ALPHA_LONG_DEN, cap_multiple_bps: DEFAULT_CAP_MULTIPLE_BPS, mark_gate_bps: DEFAULT_MARK_GATE_BPS, initial_mark_1e6 },
            book: ubk::empty(tick_size, lot_size, min_size, ctx),
            owners: table::new<u128, address>(ctx),
            writer: table::new<address, WriterInfo>(ctx),
            pooled_base: balance::zero<Base>(),
            pooled_quote: balance::zero<Quote>(),
            total_sold_units: 0,
            total_exercised_units: 0,
            proceeds_index_1e12: 0,
            settled: false,
            settlement_price_1e6: 0,
            lvp_price_1e6: initial_mark_1e6,
            lvp_ts_ms: 0,
            twap_ts_ms: vector::empty<u64>(),
            twap_px_1e6: vector::empty<u64>(),
            ema_short_1e6: initial_mark_1e6,
            ema_long_1e6: initial_mark_1e6,
            last_mark_1e6: initial_mark_1e6,
            last_sample_minute_ms: 0,
        };
        table::add(&mut market.series, key, ser);
        event::emit(SeriesCreated { key, expiry_ms, strike_1e6, is_call });
        // Extended metadata
        let sb = string::as_bytes(&series_underlying(market, key));
        let mut sym: vector<u8> = vector::empty<u8>();
        let mut i = 0u64; let n = vector::length(sb);
        while (i < n) { vector::push_back(&mut sym, *vector::borrow(sb, i)); i = i + 1; };
        event::emit(SeriesCreatedV2 { market_id: object::id(market), key, expiry_ms, strike_1e6, is_call, underlying_bytes: sym, tick_size, lot_size, min_size });
    }

    // === Maker: place sell order with collateral locking ===
    public fun place_option_sell_order<Base, Quote>(
        market: &mut XOptionsMarket<Base, Quote>,
        key: u128,
        quantity: u64,
        limit_premium_quote: u64,
        expire_ts: u64,
        mut collateral: Option<Coin<Base>>,        // for calls
        mut collateral_q: Option<Coin<Quote>>,     // for puts
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(quantity > 0, E_ZERO);
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        assert!(clock.timestamp_ms() < ser.series.expiry_ms && clock.timestamp_ms() <= expire_ts, E_EXPIRED);
        let is_call = ser.series.is_call;
        if (is_call) {
            assert!(option::is_some(&collateral) && option::is_none(&collateral_q), E_COLLATERAL_MISMATCH);
            let base_in = option::extract(&mut collateral);
            // require exact base equal to quantity
            assert!(coin::value(&base_in) == quantity, E_COLLATERAL_MISMATCH);
            let bal = coin::into_balance(base_in);
            ser.pooled_base.join(bal);
            // update writer info
            upsert_writer_base_lock(ser, ctx.sender(), quantity, true);
            event::emit(CollateralLocked { key, writer: ctx.sender(), is_call: true, amount_base: quantity, amount_quote: 0, timestamp_ms: clock.timestamp_ms() });
            option::destroy_none(collateral);
            option::destroy_none(collateral_q);
        } else {
            assert!(option::is_none(&collateral) && option::is_some(&collateral_q), E_COLLATERAL_MISMATCH);
            let q_in = option::extract(&mut collateral_q);
            // require exact quote equal to strike * quantity
            let needed = mul_u64_u64(ser.series.strike_1e6, quantity);
            assert!(coin::value(&q_in) == needed, E_COLLATERAL_MISMATCH);
            let balq = coin::into_balance(q_in);
            ser.pooled_quote.join(balq);
            upsert_writer_quote_lock(ser, ctx.sender(), needed, true);
            event::emit(CollateralLocked { key, writer: ctx.sender(), is_call: false, amount_base: 0, amount_quote: needed, timestamp_ms: clock.timestamp_ms() });
            option::destroy_none(collateral);
            option::destroy_none(collateral_q);
        };
        // insert ask into book
        let mut order = ubk::new_order(false, limit_premium_quote, 0, quantity, expire_ts);
        ubk::create_order(&mut ser.book, &mut order, clock.timestamp_ms());
        let oid = ubk::order_id_of(&order);
        table::add(&mut ser.owners, oid, ctx.sender());
        event::emit(OrderPlaced { key, order_id: oid, maker: ctx.sender(), price: limit_premium_quote, quantity, is_bid: false, expire_ts });
    }

    // === Taker: buy order with matching and premium settlement ===
    public fun place_option_buy_order<Base, Quote>(
        market: &mut XOptionsMarket<Base, Quote>,
        key: u128,
        quantity: u64,
        limit_premium_quote: u64,
        expire_ts: u64,
        mut premium_budget_quote: Coin<Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        rewards_obj: &mut rewards::Rewards,
        mut fee_unxv_in: Option<Coin<UNXV>>,  // optional payment of fees in UNXV
        clock: &Clock,
        ctx: &mut TxContext,
    ): OptionPosition<Base, Quote> {
        assert!(quantity > 0, E_ZERO);
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        assert!(clock.timestamp_ms() < ser.series.expiry_ms && clock.timestamp_ms() <= expire_ts, E_EXPIRED);
        // plan fills against asks
        let plan = ubk::compute_fill_plan(&ser.book, true, limit_premium_quote, quantity, 0, expire_ts, clock.timestamp_ms());
        let is_call_series = ser.series.is_call;
        let pay_with_unxv = option::is_some(&fee_unxv_in);
        let (taker_bps, _) = fees::apply_discounts(fees::dex_taker_fee_bps(cfg), fees::dex_maker_fee_bps(cfg), pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let rebate_bps = fees::options_maker_rebate_bps(cfg);
        let eff_rebate_bps: u64 = if (rebate_bps <= taker_bps) { rebate_bps } else { taker_bps };
        let mut total_units: u64 = 0;
        let mut total_premium: u64 = 0;
        let mut rb_makers: vector<address> = vector::empty<address>();
        let mut rb_weights_quote: vector<u128> = vector::empty<u128>();
        let fills_len = ubk::fillplan_num_fills(&plan);
        let mut i = 0;
        while (i < fills_len) {
            let f = ubk::fillplan_get_fill(&plan, i);
            let maker = *table::borrow(&ser.owners, ubk::fill_maker_id(&f));
            let qty = ubk::fill_base_qty(&f);
            let p = ubk::fill_price(&f);
            let prem = mul_u64_u64(p, qty);
            assert!(coin::value(&premium_budget_quote) >= prem, E_ZERO);
            let mut pay = coin::split(&mut premium_budget_quote, prem, ctx);
            // Apply taker protocol fee on premium
            let fee_amt: u64 = ((prem as u128) * (taker_bps as u128) / (fees::bps_denom() as u128)) as u64;
            if (!pay_with_unxv) {
                if (fee_amt > 0) {
                    let mut fee_coin = coin::split(&mut pay, fee_amt, ctx);
                    let reb_amt: u64 = ((prem as u128) * (eff_rebate_bps as u128) / (fees::bps_denom() as u128)) as u64;
                    if (reb_amt > 0 && reb_amt < fee_amt) {
                        let rb = coin::split(&mut fee_coin, reb_amt, ctx);
                        transfer::public_transfer(rb, maker);
                        fees::route_fee<Quote>(vault, fee_coin, clock, ctx);
                    } else if (reb_amt >= fee_amt) {
                        transfer::public_transfer(fee_coin, maker);
                    } else {
                        fees::route_fee<Quote>(vault, fee_coin, clock, ctx);
                    };
                };
            };
            // compute maker remaining after this fill (pre-commit) for UI
            let (filled0, qty0) = ubk::order_progress(&ser.book, ubk::fill_maker_id(&f));
            let maker_rem_before = qty0 - filled0;
            let maker_rem_after = if (maker_rem_before > qty) { maker_rem_before - qty } else { 0 };
            event::emit(OrderFilled { key, maker_order_id: ubk::fill_maker_id(&f), maker, taker: ctx.sender(), price: p, base_qty: qty, premium_quote: prem, maker_remaining_qty: maker_rem_after, timestamp_ms: clock.timestamp_ms() });
            // Rewards for options premium (USD assumed stable)
            rewards::on_option_fill(rewards_obj, ctx.sender(), maker, (prem as u128), clock);
            transfer::public_transfer(pay, maker);
            total_units = total_units + qty;
            total_premium = total_premium + prem;
            // accumulate rebate weight by premium
            let mut j: u64 = 0; let mut found: bool = false; let n_m = vector::length(&rb_makers);
            while (j < n_m) { if (*vector::borrow(&rb_makers, j) == maker) { let wref: &mut u128 = vector::borrow_mut(&mut rb_weights_quote, j); *wref = *wref + (prem as u128); found = true; break }; j = j + 1; };
            if (!found) { vector::push_back(&mut rb_makers, maker); vector::push_back(&mut rb_weights_quote, prem as u128); };
            // book-keeping for writer: increase sold_units and ensure collateral sufficiency remains
            writer_add_sold(ser, maker, qty, is_call_series);
            i = i + 1;
        };
        if (total_units == 0) {
            // refund any provided UNXV fee coin and premium budget
            if (option::is_some(&fee_unxv_in)) { let u = option::extract(&mut fee_unxv_in); sui::transfer::public_transfer(u, ctx.sender()); };
            option::destroy_none(fee_unxv_in);
            if (coin::value(&premium_budget_quote) > 0) { sui::transfer::public_transfer(premium_budget_quote, ctx.sender()); } else { coin::destroy_zero(premium_budget_quote); };
            return OptionPosition { id: object::new(ctx), key, amount: 0 }
        };
        // commit plan (no remainder injection)
        let _ = ubk::commit_fill_plan(&mut ser.book, plan, clock.timestamp_ms(), false);
        event::emit(Matched { key, taker: ctx.sender(), total_units, total_premium_quote: total_premium });
        // If paying with UNXV, split and distribute the UNXV fees now
        if (pay_with_unxv) {
            let mut unxv = option::extract(&mut fee_unxv_in);
            // Compute UNXV rebate from provided UNXV and distribute to makers by premium weight
            let total_unxv = coin::value(&unxv);
            let total_rebate_unxv: u64 = ((total_unxv as u128) * (eff_rebate_bps as u128) / (fees::bps_denom() as u128)) as u64;
            if (total_rebate_unxv > 0 && vector::length(&rb_makers) > 0) {
                let mut rb_pool = coin::split(&mut unxv, total_rebate_unxv, ctx);
                let wsum: u128 = (total_premium as u128);
                let n = vector::length(&rb_makers);
                let mut k: u64 = 0; let mut paid: u64 = 0;
                while (k < n) { let mk = *vector::borrow(&rb_makers, k); let w = *vector::borrow(&rb_weights_quote, k); let mut pay_i: u64 = if (k + 1 == n) { total_rebate_unxv - paid } else { (((w * (total_rebate_unxv as u128)) / wsum) as u64) }; if (pay_i > 0) { let c_i = coin::split(&mut rb_pool, pay_i, ctx); transfer::public_transfer(c_i, mk); paid = paid + pay_i; }; k = k + 1; };
                coin::destroy_zero(rb_pool);
            };
            // Split remaining UNXV per FeeDistribution (including traders share)
            let (stakers_coin, traders_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split_with_traders(cfg, vault, unxv, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            // Accumulate trader share centrally in FeeVault traders bank
            let t_amt = coin::value(&traders_coin);
            if (t_amt > 0) { fees::traders_bank_deposit(vault, traders_coin); } else { coin::destroy_zero(traders_coin); };
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
        };
        option::destroy_none(fee_unxv_in);
        // refund any leftover premium budget to sender
        if (coin::value(&premium_budget_quote) > 0) { sui::transfer::public_transfer(premium_budget_quote, ctx.sender()); } else { coin::destroy_zero(premium_budget_quote); };
        // create long position
        let pos = OptionPosition { id: object::new(ctx), key, amount: total_units };
        event::emit(OptionPositionUpdated { key, owner: ctx.sender(), position_id: object::id(&pos), increase: true, delta_units: total_units, new_amount: total_units, timestamp_ms: clock.timestamp_ms() });
        pos
    }

    // === Cancel order (maker only) ===
    public fun cancel_option_order<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, key: u128, order_id: u128, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        let owner = *table::borrow(&ser.owners, order_id);
        assert!(owner == ctx.sender(), E_NOT_OWNER);
        let order = ubk::cancel_order(&mut ser.book, order_id);
        table::remove(&mut ser.owners, order_id);
        // unlock remaining collateral if ask
        let (is_bid_side, _, _) = uutils::decode_order_id(ubk::order_id_of(&order));
        if (!is_bid_side) {
            let (filled, qty) = ubk::order_progress(&ser.book, ubk::order_id_of(&order));
            let rem = qty - filled;
            if (rem > 0) { unlock_excess_collateral(ser, owner, rem, clock, ctx); };
        };
        event::emit(OrderCanceled { key, order_id, maker: owner, quantity: ubk::order_quantity_of(&order) });
        let _ = clock;
    }

    // === Exercise (physical) ===
    public fun exercise_option<Base, Quote>(
        market: &mut XOptionsMarket<Base, Quote>,
        mut pos: OptionPosition<Base, Quote>,
        amount: u64,
        mut pay_quote: Option<Coin<Quote>>, // required for calls
        mut pay_base: Option<Coin<Base>>,   // required for puts
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Option<Coin<Base>>, Option<Coin<Quote>>) { // (base_out, quote_out)
        assert!(table::contains(&market.series, pos.key), E_INVALID_SERIES);
        assert!(amount > 0 && amount <= pos.amount, E_ZERO);
        let ser = table::borrow_mut(&mut market.series, pos.key);
        assert!(clock.timestamp_ms() <= ser.series.expiry_ms, E_PAST_EXPIRY_EXERCISE);
        let spot_1e6 = synthetic_spot_1e6(ser);
        let strike = ser.series.strike_1e6;
        event::emit(Exercised { key: pos.key, exerciser: ctx.sender(), amount, spot_1e6 });
        if (ser.series.is_call) {
            if (!(spot_1e6 > strike)) {
                // Not ITM, refund any provided payment coins and return position
                if (option::is_some(&pay_quote)) { let q = option::extract(&mut pay_quote); transfer::public_transfer(q, ctx.sender()); };
                option::destroy_none(pay_quote);
                if (option::is_some(&pay_base)) { let b = option::extract(&mut pay_base); transfer::public_transfer(b, ctx.sender()); };
                option::destroy_none(pay_base);
                transfer::public_transfer(pos, ctx.sender());
                return (option::none<Coin<Base>>(), option::none<Coin<Quote>>())
            };
            // Buyer pays strike * amount in Quote; receives Base amount
            let due_q = mul_u64_u64(strike, amount);
            assert!(option::is_some(&pay_quote), E_ZERO);
            let mut q_in = option::extract(&mut pay_quote);
            assert!(coin::value(&q_in) >= due_q, E_ZERO);
            let q_due = coin::split(&mut q_in, due_q, ctx);
            let qbal = coin::into_balance(q_due);
            ser.pooled_quote.join(qbal);
            // refund change if any
            sui::transfer::public_transfer(q_in, ctx.sender());
            // deliver base from pooled collateral
            let bsplit = balance::split(&mut ser.pooled_base, amount);
            let base_out = coin::from_balance(bsplit, ctx);
            // aggregate exercised units
            ser.total_exercised_units = ser.total_exercised_units + amount;
            // Update proceeds index for calls: quote collected per outstanding sold unit
            if (ser.total_sold_units > 0) { let delta_index: u128 = ((due_q as u128) * PROCEEDS_INDEX_SCALE) / (ser.total_sold_units as u128); ser.proceeds_index_1e12 = ser.proceeds_index_1e12 + delta_index; };
            // reduce outstanding
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            event::emit(OptionPositionUpdated { key: pos.key, owner: ctx.sender(), position_id: object::id(&pos), increase: false, delta_units: amount, new_amount: pos.amount, timestamp_ms: clock.timestamp_ms() });
            if (option::is_some(&pay_quote)) { let q = option::extract(&mut pay_quote); sui::transfer::public_transfer(q, ctx.sender()); };
            option::destroy_none(pay_quote);
            if (option::is_some(&pay_base)) { let b = option::extract(&mut pay_base); sui::transfer::public_transfer(b, ctx.sender()); };
            option::destroy_none(pay_base);
            transfer::public_transfer(pos, ctx.sender());
            (option::some(base_out), option::none<Coin<Quote>>())
        } else {
            if (!(spot_1e6 < strike)) {
                if (option::is_some(&pay_quote)) { let q2 = option::extract(&mut pay_quote); transfer::public_transfer(q2, ctx.sender()); };
                option::destroy_none(pay_quote);
                if (option::is_some(&pay_base)) { let b2 = option::extract(&mut pay_base); transfer::public_transfer(b2, ctx.sender()); };
                option::destroy_none(pay_base);
                transfer::public_transfer(pos, ctx.sender());
                return (option::none<Coin<Base>>(), option::none<Coin<Quote>>())
            };
            // Buyer delivers Base; receives Quote strike * amount
            assert!(option::is_some(&pay_base), E_ZERO);
            let mut b_in = option::extract(&mut pay_base);
            assert!(coin::value(&b_in) >= amount, E_ZERO);
            let b_due = coin::split(&mut b_in, amount, ctx);
            ser.pooled_base.join(coin::into_balance(b_due));
            // refund base change if any
            sui::transfer::public_transfer(b_in, ctx.sender());
            let due_q = mul_u64_u64(strike, amount);
            let qsplit = balance::split(&mut ser.pooled_quote, due_q);
            let q_out = coin::from_balance(qsplit, ctx);
            ser.total_exercised_units = ser.total_exercised_units + amount;
            // Update proceeds index for puts: base deposited per outstanding sold unit
            if (ser.total_sold_units > 0) { let delta_index2: u128 = ((amount as u128) * PROCEEDS_INDEX_SCALE) / (ser.total_sold_units as u128); ser.proceeds_index_1e12 = ser.proceeds_index_1e12 + delta_index2; };
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            event::emit(OptionPositionUpdated { key: pos.key, owner: ctx.sender(), position_id: object::id(&pos), increase: false, delta_units: amount, new_amount: pos.amount, timestamp_ms: clock.timestamp_ms() });
            if (option::is_some(&pay_quote)) { let q3 = option::extract(&mut pay_quote); sui::transfer::public_transfer(q3, ctx.sender()); };
            option::destroy_none(pay_quote);
            if (option::is_some(&pay_base)) { let b3 = option::extract(&mut pay_base); sui::transfer::public_transfer(b3, ctx.sender()); };
            option::destroy_none(pay_base);
            transfer::public_transfer(pos, ctx.sender());
            (option::none<Coin<Base>>(), option::some(q_out))
        }
    }

    // === Keeper utilities: pre-expiry sampling and snap ===
    /// Record a pre-expiry synthetic mark sample for a series (LVP + TWAP buffers)
    public fun record_series_mark<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, key: u128, sample_price_1e6: u64, clock: &Clock, _ctx: &mut TxContext) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        let now = clock.timestamp_ms();
        if (now > ser.series.expiry_ms) return;
        record_mark_internal(ser, sample_price_1e6, now);
    }

    /// Snap canonical settlement price once after expiry (LVP preferred, else TWAP, else synthetic)
    public fun snap_series_settlement<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, key: u128, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        let now = clock.timestamp_ms();
        assert!(now >= ser.series.expiry_ms, E_EXPIRED);
        assert!(!ser.settled, E_EXPIRED);
        let px = if (ser.lvp_ts_ms > 0 && ser.lvp_ts_ms <= ser.series.expiry_ms) {
            ser.lvp_price_1e6
        } else {
            let tw = compute_twap_in_window(&ser.twap_ts_ms, &ser.twap_px_1e6, ser.series.expiry_ms, TWAP_WINDOW_MS);
            if (tw > 0) { tw } else { synthetic_spot_1e6(ser) }
        };
        ser.settlement_price_1e6 = px;
        ser.settled = true;
        // Drain all resting orders and unlock remaining collateral for asks
        let cancels = ubk::drain_all_collect(&mut ser.book, 1_000_000);
        let mut i = 0u64; let n = vector::length(&cancels);
        while (i < n) {
            let c = *vector::borrow(&cancels, i);
            let oid = ubk::cancel_order_id(&c);
            if (table::contains(&ser.owners, oid)) {
                let maker = *table::borrow(&ser.owners, oid);
                // Only unlock for asks
                let (is_bid_side, _, _) = uutils::decode_order_id(oid);
                if (!is_bid_side) {
                    let rem = ubk::cancel_remaining_qty(&c);
                    if (rem > 0) { unlock_excess_collateral(ser, maker, rem, clock, ctx); };
                };
                let _ = table::remove(&mut ser.owners, oid);
            };
            i = i + 1;
        };
        event::emit(SeriesSettled { key, price_1e6: px, timestamp_ms: now });
    }

    /// Settle a long position after expiry at frozen price (physical settlement using provided coins)
    public fun settle_position_after_expiry<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, mut pos: OptionPosition<Base, Quote>, amount: u64, mut pay_quote: Option<Coin<Quote>>, mut pay_base: Option<Coin<Base>>, clock: &Clock, ctx: &mut TxContext): (Option<Coin<Base>>, Option<Coin<Quote>>) {
        assert!(table::contains(&market.series, pos.key), E_INVALID_SERIES);
        assert!(amount > 0 && amount <= pos.amount, E_ZERO);
        let ser = table::borrow_mut(&mut market.series, pos.key);
        assert!(clock.timestamp_ms() >= ser.series.expiry_ms && ser.settled, E_EXPIRED);
        let spot_1e6 = ser.settlement_price_1e6;
        let strike = ser.series.strike_1e6;
        if (ser.series.is_call) {
            if (!(spot_1e6 > strike)) {
                if (option::is_some(&pay_quote)) { let q = option::extract(&mut pay_quote); transfer::public_transfer(q, ctx.sender()); };
                option::destroy_none(pay_quote);
                if (option::is_some(&pay_base)) { let b = option::extract(&mut pay_base); transfer::public_transfer(b, ctx.sender()); };
                option::destroy_none(pay_base);
                transfer::public_transfer(pos, ctx.sender());
                return (option::none<Coin<Base>>(), option::none<Coin<Quote>>())
            };
            let due_q = mul_u64_u64(strike, amount);
            assert!(option::is_some(&pay_quote), E_ZERO);
            let mut q_in = option::extract(&mut pay_quote);
            assert!(coin::value(&q_in) >= due_q, E_ZERO);
            let q_due = coin::split(&mut q_in, due_q, ctx);
            let qbal = coin::into_balance(q_due);
            ser.pooled_quote.join(qbal);
            transfer::public_transfer(q_in, ctx.sender());
            let bsplit = balance::split(&mut ser.pooled_base, amount);
            let base_out = coin::from_balance(bsplit, ctx);
            ser.total_exercised_units = ser.total_exercised_units + amount;
            if (ser.total_sold_units > 0) { let delta_index: u128 = ((due_q as u128) * PROCEEDS_INDEX_SCALE) / (ser.total_sold_units as u128); ser.proceeds_index_1e12 = ser.proceeds_index_1e12 + delta_index; };
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            event::emit(OptionPositionUpdated { key: pos.key, owner: ctx.sender(), position_id: object::id(&pos), increase: false, delta_units: amount, new_amount: pos.amount, timestamp_ms: clock.timestamp_ms() });
            option::destroy_none(pay_quote);
            if (option::is_some(&pay_base)) { let b2 = option::extract(&mut pay_base); transfer::public_transfer(b2, ctx.sender()); };
            option::destroy_none(pay_base);
            transfer::public_transfer(pos, ctx.sender());
            (option::some(base_out), option::none<Coin<Quote>>())
        } else {
            if (!(spot_1e6 < strike)) {
                if (option::is_some(&pay_quote)) { let q2 = option::extract(&mut pay_quote); transfer::public_transfer(q2, ctx.sender()); };
                option::destroy_none(pay_quote);
                if (option::is_some(&pay_base)) { let b2 = option::extract(&mut pay_base); transfer::public_transfer(b2, ctx.sender()); };
                option::destroy_none(pay_base);
                transfer::public_transfer(pos, ctx.sender());
                return (option::none<Coin<Base>>(), option::none<Coin<Quote>>())
            };
            assert!(option::is_some(&pay_base), E_ZERO);
            let mut b_in = option::extract(&mut pay_base);
            assert!(coin::value(&b_in) >= amount, E_ZERO);
            let b_due = coin::split(&mut b_in, amount, ctx);
            ser.pooled_base.join(coin::into_balance(b_due));
            transfer::public_transfer(b_in, ctx.sender());
            let due_q = mul_u64_u64(strike, amount);
            let qsplit = balance::split(&mut ser.pooled_quote, due_q);
            let q_out = coin::from_balance(qsplit, ctx);
            ser.total_exercised_units = ser.total_exercised_units + amount;
            if (ser.total_sold_units > 0) { let delta_index2: u128 = ((amount as u128) * PROCEEDS_INDEX_SCALE) / (ser.total_sold_units as u128); ser.proceeds_index_1e12 = ser.proceeds_index_1e12 + delta_index2; };
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            event::emit(OptionPositionUpdated { key: pos.key, owner: ctx.sender(), position_id: object::id(&pos), increase: false, delta_units: amount, new_amount: pos.amount, timestamp_ms: clock.timestamp_ms() });
            if (option::is_some(&pay_quote)) { let q3 = option::extract(&mut pay_quote); transfer::public_transfer(q3, ctx.sender()); };
            option::destroy_none(pay_quote);
            option::destroy_none(pay_base);
            transfer::public_transfer(pos, ctx.sender());
            (option::none<Coin<Base>>(), option::some(q_out))
        }
    }

    /// Writer unlock after expiry for OTM series (returns remaining locked collateral)
    public fun writer_unlock_after_expiry<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, key: u128, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        assert!(clock.timestamp_ms() >= ser.series.expiry_ms && ser.settled, E_EXPIRED);
        let strike = ser.series.strike_1e6; let spot = ser.settlement_price_1e6;
        let mut wi = if (table::contains(&ser.writer, ctx.sender())) { table::remove(&mut ser.writer, ctx.sender()) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0, proceeds_index_snap_1e12: ser.proceeds_index_1e12 } };
        if (ser.series.is_call) { if (spot <= strike && wi.locked_base > 0) { let amt = wi.locked_base; wi.locked_base = 0; let bsplit = balance::split(&mut ser.pooled_base, amt); let c = coin::from_balance(bsplit, ctx); transfer::public_transfer(c, ctx.sender()); event::emit(CollateralUnlocked { key, writer: ctx.sender(), is_call: true, amount_base: amt, amount_quote: 0, reason: 1, timestamp_ms: clock.timestamp_ms() }); };
        } else { if (spot >= strike) { let need_q = wi.locked_quote; if (need_q > 0) { let qsplit = balance::split(&mut ser.pooled_quote, need_q); let cq = coin::from_balance(qsplit, ctx); wi.locked_quote = 0; transfer::public_transfer(cq, ctx.sender()); event::emit(CollateralUnlocked { key, writer: ctx.sender(), is_call: false, amount_base: 0, amount_quote: need_q, reason: 1, timestamp_ms: clock.timestamp_ms() }); };
        } };
        table::add(&mut ser.writer, ctx.sender(), wi);
    }

    // === TWAP / EMA helpers ===
    fun record_mark_internal<Base, Quote>(ser: &mut SeriesState<Base, Quote>, sample_price_1e6: u64, now: u64) {
        // Gate vs last mark if configured
        let gate = ser.series.mark_gate_bps; let last = ser.last_mark_1e6;
        if (gate > 0 && last > 0) { let hi = if (sample_price_1e6 >= last) { sample_price_1e6 } else { last }; let lo = if (sample_price_1e6 >= last) { last } else { sample_price_1e6 }; let diff = hi - lo; let dev_bps: u64 = ((diff as u128) * (fees::bps_denom() as u128) / (last as u128)) as u64; assert!(dev_bps <= gate, E_MARK_GATE); };
        // minute bucket idempotence
        let minute_ms = (now / 60_000) * 60_000;
        if (ser.last_sample_minute_ms != 0 && minute_ms == ser.last_sample_minute_ms) { ser.last_mark_1e6 = sample_price_1e6; return; };
        ser.last_sample_minute_ms = minute_ms; ser.last_mark_1e6 = sample_price_1e6;
        // EMA update
        let es = ema_update(ser.ema_short_1e6, sample_price_1e6, ser.series.alpha_num, ser.series.alpha_den);
        let el = ema_update(ser.ema_long_1e6, sample_price_1e6, ser.series.alpha_long_num, ser.series.alpha_long_den);
        ser.ema_short_1e6 = es; ser.ema_long_1e6 = el;
        // Pre-expiry buffers
        if (now <= ser.series.expiry_ms) { ser.lvp_price_1e6 = sample_price_1e6; ser.lvp_ts_ms = now; twap_append(&mut ser.twap_ts_ms, &mut ser.twap_px_1e6, now, sample_price_1e6, ser.series.expiry_ms); };
    }

    fun ema_update(prev: u64, sample: u64, alpha_num: u64, alpha_den: u64): u64 { if (alpha_den == 0) { sample } else { let den = alpha_den as u128; let num = alpha_num as u128; let prev_part = (prev as u128) * (den - num); let samp_part = (sample as u128) * num; ((prev_part + samp_part) / den) as u64 } }

    fun twap_append(ts: &mut vector<u64>, px: &mut vector<u64>, now: u64, price_1e6: u64, expiry_ms: u64) {
        vector::push_back(ts, now); vector::push_back(px, price_1e6);
        let mut n = vector::length(ts);
        if (n > TWAP_MAX_SAMPLES) { let remove = n - TWAP_MAX_SAMPLES; let mut i = 0; while (i < remove) { let _ = vector::remove(ts, 0); let _2 = vector::remove(px, 0); i = i + 1; }; };
        let window_start = if (TWAP_WINDOW_MS < expiry_ms) { expiry_ms - TWAP_WINDOW_MS } else { 0 };
        while (vector::length(ts) > 0) { let t0 = *vector::borrow(ts, 0); if (t0 >= window_start) break; let _ = vector::remove(ts, 0); let _3 = vector::remove(px, 0); };
    }

    fun compute_twap_in_window(ts: &vector<u64>, px: &vector<u64>, end_ms: u64, window_ms: u64): u64 {
        let n = vector::length(ts); if (n == 0) return 0;
        let start_ms = if (window_ms < end_ms) { end_ms - window_ms } else { 0 };
        let mut i = 0; let mut sum_weighted: u128 = 0; let mut sum_dt: u128 = 0; let mut prev_t = start_ms; let mut prev_px = *vector::borrow(px, 0);
        while (i < n) { let t = *vector::borrow(ts, i); let p = *vector::borrow(px, i); if (t < start_ms) { i = i + 1; prev_t = t; prev_px = p; continue }; let dt = if (t > prev_t) { (t - prev_t) as u128 } else { 0u128 }; sum_weighted = sum_weighted + dt * (prev_px as u128); sum_dt = sum_dt + dt; prev_t = t; prev_px = p; i = i + 1; };
        let tail_dt = if (end_ms > prev_t) { (end_ms - prev_t) as u128 } else { 0u128 }; sum_weighted = sum_weighted + tail_dt * (prev_px as u128); sum_dt = sum_dt + tail_dt; if (sum_dt == 0) return *vector::borrow(px, n - 1); (sum_weighted / sum_dt) as u64
    }

    // === Writer claims ===
    public fun writer_claim_proceeds<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, key: u128, clock: &Clock, ctx: &mut TxContext): (Coin<Base>, Coin<Quote>) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        // take writer info to avoid borrow conflicts
        let mut wi = if (table::contains(&ser.writer, ctx.sender())) { table::remove(&mut ser.writer, ctx.sender()) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0, proceeds_index_snap_1e12: ser.proceeds_index_1e12 } };
        let cur_index = ser.proceeds_index_1e12; let snap = wi.proceeds_index_snap_1e12;
        if (cur_index > snap && wi.sold_units > 0) {
            let delta_index = cur_index - snap;
            let gross: u128 = (delta_index * (wi.sold_units as u128)) / PROCEEDS_INDEX_SCALE;
            if (gross > 0) {
                if (ser.series.is_call) {
                    let pool_q = balance::value(&ser.pooled_quote) as u128; let to_pay_u128 = if (gross <= pool_q) { gross } else { pool_q };
                    if (to_pay_u128 > 0) { let to_pay: u64 = (to_pay_u128 as u64); let qsplit = balance::split(&mut ser.pooled_quote, to_pay); let qout = coin::from_balance(qsplit, ctx); wi.claimed_proceeds_quote = wi.claimed_proceeds_quote + to_pay; wi.proceeds_index_snap_1e12 = cur_index; table::add(&mut ser.writer, ctx.sender(), wi); let _ = clock; event::emit(WriterClaimed { key, writer: ctx.sender(), amount_base: 0, amount_quote: to_pay, timestamp_ms: clock.timestamp_ms() }); return (coin::zero<Base>(ctx), qout) };
                } else {
                    let pool_b = balance::value(&ser.pooled_base) as u128; let to_pay_b_u128 = if (gross <= pool_b) { gross } else { pool_b };
                    if (to_pay_b_u128 > 0) { let to_pay_b: u64 = (to_pay_b_u128 as u64); let bsplit = balance::split(&mut ser.pooled_base, to_pay_b); let bout = coin::from_balance(bsplit, ctx); wi.claimed_proceeds_base = wi.claimed_proceeds_base + to_pay_b; wi.proceeds_index_snap_1e12 = cur_index; table::add(&mut ser.writer, ctx.sender(), wi); let _ = clock; event::emit(WriterClaimed { key, writer: ctx.sender(), amount_base: to_pay_b, amount_quote: 0, timestamp_ms: clock.timestamp_ms() }); return (bout, coin::zero<Quote>(ctx)) };
                };
            };
        };
        wi.proceeds_index_snap_1e12 = cur_index; table::add(&mut ser.writer, ctx.sender(), wi); let _ = clock; (coin::zero<Base>(ctx), coin::zero<Quote>(ctx))
    }

    // === Views & helpers ===
    public fun series_key(expiry_ms: u64, strike_1e6: u64, is_call: bool, underlying: &String): u128 {
        let mut s = vector::empty<u8>();
        push_u64(&mut s, expiry_ms); push_u64(&mut s, strike_1e6); vector::push_back(&mut s, if (is_call) { 1 } else { 0 });
        let sb = string::as_bytes(underlying); let mut i = 0; let n = vector::length(sb); while (i < n) { vector::push_back(&mut s, *vector::borrow(sb, i)); i = i + 1; };
        let h = hash::sha3_256(s);
        let mut acc: u128 = 0; let mut i2 = 0; let n2 = vector::length(&h);
        while (i2 < 16 && i2 < n2) { acc = (acc << 8) + (*vector::borrow(&h, i2) as u128); i2 = i2 + 1; };
        acc
    }

    fun series_underlying<Base, Quote>(market: &XOptionsMarket<Base, Quote>, key: u128): String {
        let ser = table::borrow(&market.series, key); clone_string(&ser.series.underlying)
    }

    fun push_u64(buf: &mut vector<u8>, v: u64) { let mut x = v; let mut i = 0; while (i < 8) { vector::push_back(buf, (x & 0xFF) as u8); x = x >> 8; i = i + 1; } }
    fun mul_u64_u64(a: u64, b: u64): u64 { ((a as u128) * (b as u128) / 1_000_000) as u64 }

    /// Sweep expired orders for a series and emit events; removes owner mapping
    public fun sweep_expired_orders<Base, Quote>(market: &mut XOptionsMarket<Base, Quote>, key: u128, max: u64, clock: &Clock, _ctx: &mut TxContext) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        let now = clock.timestamp_ms();
        let removed = ubk::remove_expired_collect(&mut ser.book, now, max);
        let mut i = 0u64; let len = vector::length(&removed);
        while (i < len) { let oid = *vector::borrow(&removed, i); let maker = if (table::contains(&ser.owners, oid)) { table::remove(&mut ser.owners, oid) } else { @0x0 }; event::emit(OrderExpired { key, order_id: oid, maker, timestamp_ms: now }); i = i + 1; };
    }

    /// Synthetic spot = min(ema_short, ema_long*cap)
    fun synthetic_spot_1e6<Base, Quote>(ser: &SeriesState<Base, Quote>): u64 {
        let short = ser.ema_short_1e6; let long = ser.ema_long_1e6;
        if (long == 0) { return short; };
        let cap = ((long as u128) * (ser.series.cap_multiple_bps as u128) / (fees::bps_denom() as u128)) as u64;
        if (short <= cap) { short } else { cap }
    }

    // === Writer helpers ===
    fun upsert_writer_base_lock<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, amount: u64, inc: bool) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0, proceeds_index_snap_1e12: ser.proceeds_index_1e12 } };
        if (inc) { wi.locked_base = wi.locked_base + amount; } else { wi.locked_base = if (wi.locked_base >= amount) { wi.locked_base - amount } else { 0 }; };
        table::add(&mut ser.writer, who, wi);
    }

    fun upsert_writer_quote_lock<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, amount: u64, inc: bool) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0, proceeds_index_snap_1e12: ser.proceeds_index_1e12 } };
        if (inc) { wi.locked_quote = wi.locked_quote + amount; } else { wi.locked_quote = if (wi.locked_quote >= amount) { wi.locked_quote - amount } else { 0 }; };
        table::add(&mut ser.writer, who, wi);
    }

    fun writer_add_sold<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, qty: u64, is_call: bool) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0, proceeds_index_snap_1e12: ser.proceeds_index_1e12 } };
        wi.sold_units = wi.sold_units + qty;
        // Ensure collateral stays >= sold_units (call: base units; put: quote strike*units)
        if (is_call) { assert!(wi.locked_base >= wi.sold_units, E_COLLATERAL_MISMATCH); } else { let need_q = mul_u64_u64(ser.series.strike_1e6, wi.sold_units); assert!(wi.locked_quote >= need_q, E_COLLATERAL_MISMATCH); };
        ser.total_sold_units = ser.total_sold_units + qty;
        table::add(&mut ser.writer, who, wi);
    }

    fun unlock_excess_collateral<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, qty_unfilled: u64, clock: &Clock, ctx: &mut TxContext) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0, proceeds_index_snap_1e12: ser.proceeds_index_1e12 } };
        if (ser.series.is_call) {
            // cancel returns base for unfilled qty
            let amt = qty_unfilled;
            if (wi.locked_base >= amt) { wi.locked_base = wi.locked_base - amt; } else { wi.locked_base = 0; };
            let bsplit = balance::split(&mut ser.pooled_base, amt);
            let c = coin::from_balance(bsplit, ctx);
            transfer::public_transfer(c, who);
            event::emit(CollateralUnlocked { key: series_key(ser.series.expiry_ms, ser.series.strike_1e6, ser.series.is_call, &ser.series.underlying), writer: who, is_call: true, amount_base: amt, amount_quote: 0, reason: 0, timestamp_ms: clock.timestamp_ms() });
        } else {
            let need_q = mul_u64_u64(ser.series.strike_1e6, qty_unfilled);
            if (wi.locked_quote >= need_q) { wi.locked_quote = wi.locked_quote - need_q; } else { wi.locked_quote = 0; };
            let qsplit = balance::split(&mut ser.pooled_quote, need_q);
            let cq = coin::from_balance(qsplit, ctx);
            transfer::public_transfer(cq, who);
            event::emit(CollateralUnlocked { key: series_key(ser.series.expiry_ms, ser.series.strike_1e6, ser.series.is_call, &ser.series.underlying), writer: who, is_call: false, amount_base: 0, amount_quote: need_q, reason: 0, timestamp_ms: clock.timestamp_ms() });
        };
        table::add(&mut ser.writer, who, wi);
    }

    // === Helpers ===
    fun clone_string(s: &String): String { let b = string::as_bytes(s); let mut out = vector::empty<u8>(); let mut i = 0; let n = vector::length(b); while (i < n) { vector::push_back(&mut out, *vector::borrow(b, i)); i = i + 1; }; string::utf8(out) }
}


