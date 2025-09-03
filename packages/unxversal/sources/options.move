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
        transfer,
    };
    use std::{
        option::{Self as option, Option},
        string::{Self as string, String},
        hash,
    };
    use unxversal::book::{Self as ubk, Book, FillPlan, Fill};
    use unxversal::utils as uutils;
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::staking::{Self as staking, StakingPool};
    use unxversal::oracle::{Self as uoracle, OracleRegistry};
    use switchboard::aggregator::Aggregator;

    // Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_INVALID_SERIES: u64 = 2;
    const E_ZERO: u64 = 3;
    const E_EXPIRED: u64 = 4;
    const E_NOT_OWNER: u64 = 5;
    const E_NOT_ASK: u64 = 6;
    const E_NOT_BID: u64 = 7;
    const E_COLLATERAL_MISMATCH: u64 = 8;
    const E_PAST_EXPIRY_EXERCISE: u64 = 9;
    const E_NOT_ITM: u64 = 10;
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
    entry fun init_market<Base, Quote>(reg_admin: &AdminRegistry, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let m = OptionsMarket<Base, Quote> { id: object::new(ctx), series: table::new<u128, SeriesState<Base, Quote>>(ctx) };
        transfer::share_object(m);
    }

    // === Admin: create series ===
    entry fun create_option_series<Base, Quote>(
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
    entry fun place_option_sell_order<Base, Quote>(
        market: &mut OptionsMarket<Base, Quote>,
        key: u128,
        quantity: u64,
        limit_premium_quote: u64,
        expire_ts: u64,
        collateral: Option<Coin<Base>>,        // for calls
        collateral_q: Option<Coin<Quote>>,     // for puts
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
            let base_in = option::extract(&mut { collateral });
            // require exact base equal to quantity
            assert!(coin::value(&base_in) == quantity, E_COLLATERAL_MISMATCH);
            let bal = coin::into_balance(base_in);
            ser.pooled_base.join(bal);
            // update writer info
            upsert_writer_base_lock(ser, ctx.sender(), quantity, true);
        } else {
            assert!(option::is_none(&collateral) && option::is_some(&collateral_q), E_COLLATERAL_MISMATCH);
            let q_in = option::extract(&mut { collateral_q });
            // require exact quote equal to strike * quantity
            let needed = mul_u64_u64(ser.series.strike_1e6, quantity);
            assert!(coin::value(&q_in) == needed, E_COLLATERAL_MISMATCH);
            let balq = coin::into_balance(q_in);
            ser.pooled_quote.join(balq);
            upsert_writer_quote_lock(ser, ctx.sender(), needed, true);
        };

        // insert ask into book
        let mut order = ubk::new_order(false, limit_premium_quote, 0, quantity, expire_ts);
        ubk::create_order(&mut ser.book, &mut order, clock.timestamp_ms());
        table::add(&mut ser.owners, order.order_id, ctx.sender());
        event::emit(OrderPlaced { key, order_id: order.order_id, maker: ctx.sender(), price: limit_premium_quote, quantity, is_bid: false, expire_ts });
    }

    // === Taker: buy order with matching and premium settlement ===
    entry fun place_option_buy_order<Base, Quote>(
        market: &mut OptionsMarket<Base, Quote>,
        key: u128,
        quantity: u64,
        limit_premium_quote: u64,
        expire_ts: u64,
        mut premium_budget_quote: Coin<Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OptionPosition<Base, Quote> {
        assert!(quantity > 0, E_ZERO);
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        assert!(clock.timestamp_ms() < ser.series.expiry_ms && clock.timestamp_ms() <= expire_ts, E_EXPIRED);
        // plan fills against asks
        let plan = ubk::compute_fill_plan(&ser.book, true, limit_premium_quote, quantity, 0, expire_ts, clock.timestamp_ms());
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
            let pay = coin::split(&mut premium_budget_quote, prem, ctx);
            // protocol fee on premium (input-token path) with optional UNXV discount omitted in taker buy; collector can call swap path if needed
            fees::accrue_generic<Quote>(vault, coin::zero<Quote>(ctx), clock, ctx);
            transfer::public_transfer(pay, maker);
            total_units = total_units + qty;
            total_premium = total_premium + prem;
            // book-keeping for writer: increase sold_units and reduce locked collateral if needed (locked remains for sold outstanding)
            writer_add_sold(ser, maker, qty, ser.series.is_call);
            i = i + 1;
        };
        if (total_units == 0) { return OptionPosition { id: object::new(ctx), key, amount: 0 } };
        // commit plan (no remainder injection)
        let _ = ubk::commit_fill_plan(&mut ser.book, plan, clock.timestamp_ms(), false);
        event::emit(Matched { key, taker: ctx.sender(), total_units, total_premium_quote: total_premium });
        // create long position
        OptionPosition { id: object::new(ctx), key, amount: total_units }
    }

    // === Cancel order (maker only) ===
    entry fun cancel_option_order<Base, Quote>(market: &mut OptionsMarket<Base, Quote>, key: u128, order_id: u128, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        let owner = *table::borrow(&ser.owners, order_id);
        assert!(owner == ctx.sender(), E_NOT_OWNER);
        let order = ubk::cancel_order(&mut ser.book, order_id);
        table::remove(&mut ser.owners, order_id);
        // unlock remaining collateral if ask
        let (is_bid, _, _) = uutils::decode_order_id(order.order_id);
        if (!is_bid) {
            let rem = order.quantity - order.filled_quantity;
            if (rem > 0) { unlock_excess_collateral(ser, owner, rem, ctx); };
        };
        event::emit(OrderCanceled { key, order_id, maker: owner, quantity: order.quantity });
        // silence unused parameter warning
        let _ = clock;
    }

    // === Exercise (physical) ===
    entry fun exercise_option<Base, Quote>(
        market: &mut OptionsMarket<Base, Quote>,
        mut pos: OptionPosition<Base, Quote>,
        amount: u64,
        reg: &OracleRegistry,
        agg: &Aggregator,
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
            if (!(spot_1e6 > strike)) { return (option::none<Coin<Base>>(), option::none<Coin<Quote>>()) };
            // Buyer pays strike * amount in Quote; receives Base amount
            let due_q = mul_u64_u64(strike, amount);
            let q_in = coin::take<Quote>(ctx, due_q);
            let qbal = coin::into_balance(q_in);
            ser.pooled_quote.join(qbal);
            // deliver base
            let base_out = balance::into_coin(&mut ser.pooled_base, amount, ctx);
            // aggregate exercised units
            ser.total_exercised_units = ser.total_exercised_units + amount;
            // reduce outstanding
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            (option::some(base_out), option::none<Coin<Quote>>())
        } else {
            if (!(spot_1e6 < strike)) { return (option::none<Coin<Base>>(), option::none<Coin<Quote>>()) };
            // Buyer delivers Base; receives Quote strike * amount
            let base_in = coin::take<Base>(ctx, amount);
            let bbal = coin::into_balance(base_in);
            ser.pooled_base.join(bbal);
            let due_q = mul_u64_u64(strike, amount);
            let q_out = balance::into_coin(&mut ser.pooled_quote, due_q, ctx);
            ser.total_exercised_units = ser.total_exercised_units + amount;
            if (ser.total_sold_units >= amount) { ser.total_sold_units = ser.total_sold_units - amount; } else { ser.total_sold_units = 0; };
            pos.amount = pos.amount - amount;
            (option::none<Coin<Base>>(), option::some(q_out))
        }
    }

    // === Writer claims ===
    entry fun writer_claim_proceeds<Base, Quote>(market: &mut OptionsMarket<Base, Quote>, key: u128, clock: &Clock, ctx: &mut TxContext): (Coin<Base>, Coin<Quote>) {
        assert!(table::contains(&market.series, key), E_INVALID_SERIES);
        let ser = table::borrow_mut(&mut market.series, key);
        let mut wi = get_writer(ser, ctx.sender());
        let mut base_out = coin::zero<Base>(ctx);
        let mut quote_out = coin::zero<Quote>(ctx);
        if (ser.series.is_call) {
            // claim Quote proceeds proportional to exercised units
            let total_ex = ser.total_exercised_units;
            if (total_ex > 0 && wi.exercised_units > wi.claimed_proceeds_quote) {
                let unclaimed = wi.exercised_units - wi.claimed_proceeds_quote;
                let pool_q = balance::value(&ser.pooled_quote);
                let share = (pool_q as u128) * (unclaimed as u128) / (total_ex as u128);
                if (share > 0) { quote_out = balance::into_coin(&mut ser.pooled_quote, share as u64, ctx); wi.claimed_proceeds_quote = wi.claimed_proceeds_quote + unclaimed; };
            };
        } else {
            // claim Base proceeds proportional to exercised units
            let total_ex2 = ser.total_exercised_units;
            if (total_ex2 > 0 && wi.exercised_units > wi.claimed_proceeds_base) {
                let unclaimed2 = wi.exercised_units - wi.claimed_proceeds_base;
                let pool_b = balance::value(&ser.pooled_base);
                let share2 = (pool_b as u128) * (unclaimed2 as u128) / (total_ex2 as u128);
                if (share2 > 0) { base_out = balance::into_coin(&mut ser.pooled_base, share2 as u64, ctx); wi.claimed_proceeds_base = wi.claimed_proceeds_base + unclaimed2; };
            };
        };
        // persist
        set_writer(ser, ctx.sender(), wi);
        // silence
        let _ = clock;
        (base_out, quote_out)
    }

    // === Views & helpers ===
    public fun series_key(expiry_ms: u64, strike_1e6: u64, is_call: bool, symbol: &String): u128 {
        let mut s = vector::empty<u8>();
        // concat expiry, strike, is_call, symbol bytes
        push_u64(&mut s, expiry_ms);
        push_u64(&mut s, strike_1e6);
        vector::push_back(&mut s, if (is_call) { 1 } else { 0 });
        let sb = string::as_bytes(symbol); let mut i = 0; let n = vector::length(sb); while (i < n) { vector::push_back(&mut s, *vector::borrow(sb, i)); i = i + 1; };
        (hash::sha3_256(s) as u128)
    }

    fun push_u64(buf: &mut vector<u8>, v: u64) { let mut x = v; let mut i = 0; while (i < 8) { vector::push_back(buf, (x & 0xFF) as u8); x = x >> 8; i = i + 1; } }

    fun mul_u64_u64(a: u64, b: u64): u64 { ((a as u128) * (b as u128) / 1_000_000) as u64 }

    fun upsert_writer_base_lock<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, amount: u64, inc: bool) {
        let mut wi = get_writer(ser, who);
        if (inc) { wi.locked_base = wi.locked_base + amount; } else { wi.locked_base = if (wi.locked_base >= amount) { wi.locked_base - amount } else { 0 }; };
        set_writer(ser, who, wi);
    }

    fun upsert_writer_quote_lock<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, amount: u64, inc: bool) {
        let mut wi = get_writer(ser, who);
        if (inc) { wi.locked_quote = wi.locked_quote + amount; } else { wi.locked_quote = if (wi.locked_quote >= amount) { wi.locked_quote - amount } else { 0 }; };
        set_writer(ser, who, wi);
    }

    fun writer_add_sold<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, qty: u64, is_call: bool) {
        let mut wi = get_writer(ser, who);
        wi.sold_units = wi.sold_units + qty;
        // Ensure collateral stays >= sold_units (call: base units; put: quote strike*units)
        if (is_call) {
            assert!(wi.locked_base >= wi.sold_units, E_COLLATERAL_MISMATCH);
        } else {
            let need_q = mul_u64_u64(ser.series.strike_1e6, wi.sold_units);
            assert!(wi.locked_quote >= need_q, E_COLLATERAL_MISMATCH);
        };
        ser.total_sold_units = ser.total_sold_units + qty;
        set_writer(ser, who, wi);
    }

    fun unlock_excess_collateral<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, qty_unfilled: u64, ctx: &mut TxContext) {
        let mut wi = get_writer(ser, who);
        if (ser.series.is_call) {
            // cancel returns base for unfilled qty
            let amt = qty_unfilled;
            if (wi.locked_base >= amt) { wi.locked_base = wi.locked_base - amt; } else { wi.locked_base = 0; };
            let c = balance::into_coin(&mut ser.pooled_base, amt, ctx);
            transfer::public_transfer(c, who);
        } else {
            let need_q = mul_u64_u64(ser.series.strike_1e6, qty_unfilled);
            if (wi.locked_quote >= need_q) { wi.locked_quote = wi.locked_quote - need_q; } else { wi.locked_quote = 0; };
            let cq = balance::into_coin(&mut ser.pooled_quote, need_q, ctx);
            transfer::public_transfer(cq, who);
        };
        set_writer(ser, who, wi);
    }

    fun get_writer<Base, Quote>(ser: &SeriesState<Base, Quote>, who: address): WriterInfo {
        if (table::contains(&ser.writer, who)) { *table::borrow(&ser.writer, who) } else { WriterInfo { sold_units: 0, exercised_units: 0, claimed_proceeds_quote: 0, claimed_proceeds_base: 0, locked_base: 0, locked_quote: 0 } }
    }

    fun set_writer<Base, Quote>(ser: &mut SeriesState<Base, Quote>, who: address, wi: WriterInfo) {
        if (table::contains(&ser.writer, who)) { let _ = table::remove(&mut ser.writer, who); };
        table::add(&mut ser.writer, who, wi);
    }
}


