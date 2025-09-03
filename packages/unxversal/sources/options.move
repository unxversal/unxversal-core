/// Module: unxversal_options
/// ------------------------------------------------------------
/// European options with per-series orderbooks, physical settlement,
/// Switchboard oracle price checks, and fee distribution via FeeConfig.
///
/// Design notes:
/// - One `OptionsMarket<Base, Quote>` manages many series (expiry, strike, is_call).
/// - Each series has an internal `Book` with bids (buyers) / asks (writers).
/// - Writers lock collateral when placing sell (ask) orders.
/// - Buyers pay premium on matching fills directly to maker addresses.
/// - On exercise: physical delivery (Call: Base to buyer, buyer pays Quote at strike; Put: Quote to buyer, buyer delivers Base).
/// - Proceeds are pooled and writers claim pro-rata based on exercised units attributed to them.
/// - Protocol fees are collected per FeeConfig, with optional UNXV discount and weekly staking split.
#[allow(lint(self_transfer))]
module unxversal::options {
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
    use unxversal::oracle::{Self as uoracle, OracleRegistry};
    use switchboard::aggregator::Aggregator;

    // Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_INVALID_SERIES: u64 = 2;
    const E_ZERO: u64 = 3;
    const E_EXPIRED: u64 = 4;
    const E_NOT_OWNER: u64 = 5;
    // removed unused E_NOT_ASK and E_NOT_BID
    // const E_NOT_ASK: u64 = 6;
    // const E_NOT_BID: u64 = 7;
    const E_COLLATERAL_MISMATCH: u64 = 8;
    const E_PAST_EXPIRY_EXERCISE: u64 = 9;
    // removed unused E_NOT_ITM
    // const E_NOT_ITM: u64 = 10;
    const E_SERIES_EXISTS: u64 = 11;

    // Data
    public struct OptionSeries has copy, drop, store {
        expiry_ms: u64,     // epoch ms
        strike_1e6: u64,    // price in quote per base, scaled 1e6
        is_call: bool,
        symbol: String,     // oracle symbol, e.g., "SUI/USDC"
    }

    /// Writer state for claims and outstanding obligations
    public struct WriterInfo has store {
        sold_units: u64,          // matched outstanding units
        exercised_units: u64,     // portion exercised (for claim calc)
        claimed_proceeds_quote: u64, // claimed quote (calls)
        claimed_proceeds_base: u64,  // claimed base (puts)
        locked_base: u64,         // currently locked base collateral
        locked_quote: u64,        // currently locked quote collateral
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
        settled: bool,
    }

    public struct OptionsMarket<phantom Base, phantom Quote> has key, store {
        id: UID,
        series: Table<u128, SeriesState<Base, Quote>>,
    }

    // Buyer long position (fungible by series within this object)
    public struct OptionPosition<phantom Base, phantom Quote> has key, store {
        id: UID,
        key: u128,
        amount: u64,
    }

    // Events
    public struct SeriesCreated has copy, drop { key: u128, expiry_ms: u64, strike_1e6: u64, is_call: bool }
    public struct OrderPlaced has copy, drop { key: u128, order_id: u128, maker: address, price: u64, quantity: u64, is_bid: bool, expire_ts: u64 }
    public struct OrderCanceled has copy, drop { key: u128, order_id: u128, maker: address, quantity: u64 }
    public struct Matched has copy, drop { key: u128, taker: address, total_units: u64, total_premium_quote: u64 }
    public struct Exercised has copy, drop { key: u128, exerciser: address, amount: u64, spot_1e6: u64 }

    // === Init ===
    public fun init_market<Base, Quote>(reg_admin: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let m = OptionsMarket<Base, Quote> { id: object::new(ctx), series: table::new<u128, SeriesState<Base, Quote>>(ctx) };
        transfer::share_object(m);
    }

    // === Admin: create series ===
    public fun create_option_series<Base, Quote>(
        reg_admin: &AdminRegistry,
        market: &mut OptionsMarket<Base, Quote>,
        expiry_ms: u64,
        strike_1e6: u64,
        is_call: bool,
        symbol: String,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(expiry_ms > sui::tx_context::epoch_timestamp_ms(ctx), E_INVALID_SERIES);
        let key = series_key(expiry_ms, strike_1e6, is_call, &symbol);
        assert!(!table::contains(&market.series, key), E_SERIES_EXISTS);
        let ser = SeriesState<Base, Quote> {
            series: OptionSeries { expiry_ms, strike_1e6, is_call, symbol },
            book: ubk::empty(tick_size, lot_size, min_size, ctx),
            owners: table::new<u128, address>(ctx),
            writer: table::new<address, WriterInfo>(ctx),
            pooled_base: balance::zero<Base>(),
            pooled_quote: balance::zero<Quote>(),
            total_sold_units: 0,
            total_exercised_units: 0,
            settled: false,
        };
        table::add(&mut market.series, key, ser);
        event::emit(SeriesCreated { key, expiry_ms, strike_1e6, is_call });
    }

    // === Maker: place sell order with collateral locking ===
    public fun place_option_sell_order<Base, Quote>(
        market: &mut OptionsMarket<Base, Quote>,
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
            // consume options
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
        market: &mut OptionsMarket<Base, Quote>,
        key: u128,
        quantity: u64,
        limit_premium_quote: u64,
        expire_ts: u64,
        mut premium_budget_quote: Coin<Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut fee_unxv_in: Option<Coin<UNXV>>,
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
        let mut total_units: u64 = 0;
        let mut total_premium: u64 = 0;
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
                    let fee_coin = coin::split(&mut pay, fee_amt, ctx);
                    fees::accrue_generic<Quote>(vault, fee_coin, clock, ctx);
                };
            };
            transfer::public_transfer(pay, maker);
            total_units = total_units + qty;
            total_premium = total_premium + prem;
            // book-keeping for writer: increase sold_units and reduce locked collateral if needed (locked remains for sold outstanding)
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
            let unxv = option::extract(&mut fee_unxv_in);
            distribute_unxv_fee(cfg, vault, staking_pool, unxv, clock, ctx);
        };
        option::destroy_none(fee_unxv_in);
        // refund any leftover premium budget to sender
        if (coin::value(&premium_budget_quote) > 0) { sui::transfer::public_transfer(premium_budget_quote, ctx.sender()); } else { coin::destroy_zero(premium_budget_quote); };
        // create long position
        OptionPosition { id: object::new(ctx), key, amount: total_units }
    }

    // === Cancel order (maker only) ===
    public fun cancel_option_order<Base, Quote>(market: &mut OptionsMarket<Base, Quote>, key: u128, order_id: u128, clock: &Clock, ctx: &mut TxContext) {
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
            if (rem > 0) { unlock_excess_collateral(ser, owner, rem, ctx); };
        };
        event::emit(OrderCanceled { key, order_id, maker: owner, quantity: ubk::order_quantity_of(&order) });
        // silence unused parameter warning
        let _ = clock;
    }

    // === Exercise (physical) ===
    public fun exercise_option<Base, Quote>(
        market: &mut OptionsMarket<Base, Quote>,
        mut pos: OptionPosition<Base, Quote>,
        amount: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
        mut pay_quote: Option<Coin<Quote>>, // required for calls
        mut pay_base: Option<Coin<Base>>,   // required for puts
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Option<Coin<Base>>, Option<Coin<Quote>>) { // (base_out, quote_out)
        assert!(table::contains(&market.series, pos.key), E_INVALID_SERIES);
        assert!(amount > 0 && amount <= pos.amount, E_ZERO);
        let ser = table::borrow_mut(&mut market.series, pos.key);
        assert!(clock.timestamp_ms() <= ser.series.expiry_ms, E_PAST_EXPIRY_EXERCISE);
        let spot_1e6 = uoracle::get_price_for_symbol(reg, clock, &ser.series.symbol, agg);
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
            // reduce outstanding
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
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
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            if (option::is_some(&pay_quote)) { let q3 = option::extract(&mut pay_quote); sui::transfer::public_transfer(q3, ctx.sender()); };
            option::destroy_none(pay_quote);
            if (option::is_some(&pay_base)) { let b3 = option::extract(&mut pay_base); sui::transfer::public_transfer(b3, ctx.sender()); };
            option::destroy_none(pay_base);
            transfer::public_transfer(pos, ctx.sender());
            (option::none<Coin<Base>>(), option::some(q_out))
        }
    }

    // === Writer claims ===
    public fun writer_claim_proceeds<Base, Quote>(market: &mut OptionsMarket<Base, Quote>, key: u128, clock: &Clock, ctx: &mut TxContext): (Coin<Base>, Coin<Quote>) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        // take writer info to avoid borrow conflicts
        let mut wi = if (table::contains(&ser.writer, ctx.sender())) { table::remove(&mut ser.writer, ctx.sender()) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0 } };
        if (ser.series.is_call) {
            let total_ex = ser.total_exercised_units;
            if (total_ex > 0 && wi.exercised_units > wi.claimed_proceeds_quote) {
                let unclaimed = wi.exercised_units - wi.claimed_proceeds_quote;
                let pool_q = balance::value(&ser.pooled_quote);
                let share = (pool_q as u128) * (unclaimed as u128) / (total_ex as u128);
                if (share > 0) {
                    let qsplit = balance::split(&mut ser.pooled_quote, share as u64);
                    let qout = coin::from_balance(qsplit, ctx);
                    wi.claimed_proceeds_quote = wi.claimed_proceeds_quote + unclaimed;
                    table::add(&mut ser.writer, ctx.sender(), wi);
                    let _ = clock;
                    return (coin::zero<Base>(ctx), qout)
                };
            };
            table::add(&mut ser.writer, ctx.sender(), wi);
            let _ = clock;
            (coin::zero<Base>(ctx), coin::zero<Quote>(ctx))
        } else {
            let total_ex2 = ser.total_exercised_units;
            if (total_ex2 > 0 && wi.exercised_units > wi.claimed_proceeds_base) {
                let unclaimed2 = wi.exercised_units - wi.claimed_proceeds_base;
                let pool_b = balance::value(&ser.pooled_base);
                let share2 = (pool_b as u128) * (unclaimed2 as u128) / (total_ex2 as u128);
                if (share2 > 0) {
                    let bsplit = balance::split(&mut ser.pooled_base, share2 as u64);
                    let bout = coin::from_balance(bsplit, ctx);
                    wi.claimed_proceeds_base = wi.claimed_proceeds_base + unclaimed2;
                    table::add(&mut ser.writer, ctx.sender(), wi);
                    let _ = clock;
                    return (bout, coin::zero<Quote>(ctx))
                };
            };
            table::add(&mut ser.writer, ctx.sender(), wi);
            let _ = clock;
            (coin::zero<Base>(ctx), coin::zero<Quote>(ctx))
        }
    }

    // === Views & helpers ===
    public fun series_key(expiry_ms: u64, strike_1e6: u64, is_call: bool, symbol: &String): u128 {
        let mut s = vector::empty<u8>();
        // concat expiry, strike, is_call, symbol bytes
        push_u64(&mut s, expiry_ms);
        push_u64(&mut s, strike_1e6);
        vector::push_back(&mut s, if (is_call) { 1 } else { 0 });
        let sb = string::as_bytes(symbol); let mut i = 0; let n = vector::length(sb); while (i < n) { vector::push_back(&mut s, *vector::borrow(sb, i)); i = i + 1; };
        let h = hash::sha3_256(s);
        // fold first 16 bytes into u128
        let mut acc: u128 = 0;
        let mut i2 = 0; let n2 = vector::length(&h);
        while (i2 < 16 && i2 < n2) { acc = (acc << 8) + (*vector::borrow(&h, i2) as u128); i2 = i2 + 1; };
        acc
    }

    fun push_u64(buf: &mut vector<u8>, v: u64) { let mut x = v; let mut i = 0; while (i < 8) { vector::push_back(buf, (x & 0xFF) as u8); x = x >> 8; i = i + 1; } }

    fun mul_u64_u64(a: u64, b: u64): u64 { ((a as u128) * (b as u128) / 1_000_000) as u64 }

    fun upsert_writer_base_lock<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, amount: u64, inc: bool) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0 } };
        if (inc) { wi.locked_base = wi.locked_base + amount; } else { wi.locked_base = if (wi.locked_base >= amount) { wi.locked_base - amount } else { 0 }; };
        table::add(&mut ser.writer, who, wi);
    }

    fun upsert_writer_quote_lock<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, amount: u64, inc: bool) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0 } };
        if (inc) { wi.locked_quote = wi.locked_quote + amount; } else { wi.locked_quote = if (wi.locked_quote >= amount) { wi.locked_quote - amount } else { 0 }; };
        table::add(&mut ser.writer, who, wi);
    }

    fun writer_add_sold<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, qty: u64, is_call: bool) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0 } };
        wi.sold_units = wi.sold_units + qty;
        // Ensure collateral stays >= sold_units (call: base units; put: quote strike*units)
        if (is_call) {
            assert!(wi.locked_base >= wi.sold_units, E_COLLATERAL_MISMATCH);
        } else {
            let need_q = mul_u64_u64(ser.series.strike_1e6, wi.sold_units);
            assert!(wi.locked_quote >= need_q, E_COLLATERAL_MISMATCH);
        };
        ser.total_sold_units = ser.total_sold_units + qty;
        table::add(&mut ser.writer, who, wi);
    }

    fun unlock_excess_collateral<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, qty_unfilled: u64, ctx: &mut TxContext) {
        let mut wi = if (table::contains(&ser.writer, who)) { table::remove(&mut ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0 } };
        if (ser.series.is_call) {
            // cancel returns base for unfilled qty
            let amt = qty_unfilled;
            if (wi.locked_base >= amt) { wi.locked_base = wi.locked_base - amt; } else { wi.locked_base = 0; };
            let bsplit = balance::split(&mut ser.pooled_base, amt);
            let c = coin::from_balance(bsplit, ctx);
            transfer::public_transfer(c, who);
        } else {
            let need_q = mul_u64_u64(ser.series.strike_1e6, qty_unfilled);
            if (wi.locked_quote >= need_q) { wi.locked_quote = wi.locked_quote - need_q; } else { wi.locked_quote = 0; };
            let qsplit = balance::split(&mut ser.pooled_quote, need_q);
            let cq = coin::from_balance(qsplit, ctx);
            transfer::public_transfer(cq, who);
        };
        table::add(&mut ser.writer, who, wi);
    }
    // removed ensure_writer helper to avoid borrow conflicts

    /// Internal: distribute UNXV fee to staking pool / treasury / burn via FeeConfig
    fun distribute_unxv_fee(
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        unxv_fee: Coin<UNXV>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, vault, unxv_fee, clock, ctx);
        staking::add_weekly_reward(staking_pool, stakers_coin, clock);
        transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
    }
}


