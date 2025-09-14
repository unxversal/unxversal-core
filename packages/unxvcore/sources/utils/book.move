// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unxversal on-chain order book compatible with DeepBook v3 semantics.
/// Provides:
/// - `Book` with bids/asks BigVectors of `Order`
/// - Order creation with immediate matching and optional injection
/// - Mid-price and level2 views
/// - Cancel/Modify APIs
module unxvcore::book;

use unxvcore::big_vector::{Self, BigVector, slice_borrow, slice_borrow_mut};
use unxvcore::utils;

// Minimal constants needed locally. Integrate with UNXV constants later.
const MAX_SLICE_SIZE: u64 = 64; // tune per protocol
const MAX_FAN_OUT: u64 = 64; // tune per protocol
const MAX_FILLS: u64 = 100; // DOS guard per tx
const MIN_PRICE: u64 = 1;
const MAX_PRICE: u64 = ((1u128 << 63) - 1) as u64;

// === Errors ===
const EEmptyOrderbook: u64 = 2;
const EInvalidPriceRange: u64 = 3;
const EInvalidTicks: u64 = 4;
const EOrderBelowMinimumSize: u64 = 5;
const EOrderInvalidLotSize: u64 = 6;
const ENewQuantityMustBeLessThanOriginal: u64 = 7;

// === Structs ===
public struct Order has drop, store {
    // Encoded order id: side|price|local_id
    order_id: u128,
    client_order_id: u64,
    quantity: u64,
    filled_quantity: u64,
    expire_timestamp: u64,
}

public struct Book has store {
    tick_size: u64,
    lot_size: u64,
    min_size: u64,
    bids: BigVector<Order>,
    asks: BigVector<Order>,
    next_bid_order_id: u64,
    next_ask_order_id: u64,
}

/// A record describing a canceled order and its unfilled remaining quantity
public struct OrderCancel has copy, drop, store {
    order_id: u128,
    remaining_qty: u64,
}

// A single fill against a maker order
public struct Fill has copy, drop, store {
    maker_id: u128,
    price: u64,
    base_qty: u64,
}

// A non-mutating plan of fills for a taker order
public struct FillPlan has drop, store {
    is_bid: bool,
    price: u64,
    client_order_id: u64,
    expire_ts: u64,
    taker_requested: u64,
    taker_filled: u64,
    fills: vector<Fill>,
}

// === Public API ===
public fun empty(tick_size: u64, lot_size: u64, min_size: u64, ctx: &mut TxContext): Book {
    Book {
        tick_size,
        lot_size,
        min_size,
        bids: big_vector::empty(MAX_SLICE_SIZE, MAX_FAN_OUT, ctx),
        asks: big_vector::empty(MAX_SLICE_SIZE, MAX_FAN_OUT, ctx),
        next_bid_order_id: ((1u128 << 64) - 1) as u64,
        next_ask_order_id: 1,
    }
}

public fun bids(self: &Book): &BigVector<Order> { &self.bids }
public fun asks(self: &Book): &BigVector<Order> { &self.asks }
public fun tick_size(self: &Book): u64 { self.tick_size }
public fun lot_size(self: &Book): u64 { self.lot_size }
public fun min_size(self: &Book): u64 { self.min_size }

public fun set_tick_size(self: &mut Book, new_tick_size: u64) { self.tick_size = new_tick_size }
public fun set_lot_size(self: &mut Book, new_lot_size: u64) { self.lot_size = new_lot_size }
public fun set_min_size(self: &mut Book, new_min_size: u64) { self.min_size = new_min_size }

public fun create_order(self: &mut Book, order: &mut Order, timestamp: u64) {
    validate_order_inputs(order, self.tick_size, self.min_size, self.lot_size, timestamp);
    let (is_bid, price, _) = utils::decode_order_id(order.order_id);
    let encoded = utils::encode_order_id(is_bid, price, get_order_id(self, is_bid));
    order.order_id = encoded;
    match_against_book(self, order, timestamp);
    // If the order is fully executed, do not inject
    if (order.quantity - order.filled_quantity == 0) return;
    inject_limit_order(self, order);
}

public fun cancel_order(self: &mut Book, order_id: u128): Order {
    book_side_mut(self, order_id).remove(order_id)
}

public fun modify_order(self: &mut Book, order_id: u128, new_quantity: u64, timestamp: u64): (u64, &Order) {
    assert!(new_quantity >= self.min_size, EOrderBelowMinimumSize);
    assert!(new_quantity % self.lot_size == 0, EOrderInvalidLotSize);
    let order = book_side_mut(self, order_id).borrow_mut(order_id);
    assert!(new_quantity < order.quantity, ENewQuantityMustBeLessThanOriginal);
    assert!(timestamp <= order.expire_timestamp, EInvalidPriceRange);
    let cancel_quantity = order.quantity - new_quantity;
    order.quantity = new_quantity;
    (cancel_quantity, order)
}

/// Compute a non-mutating fill plan for a taker order.
/// The plan lists the maker orders to fill (by id) and quantities, up to MAX_FILLS and taker size.
/// No mutations are applied to the book in this function.
public fun compute_fill_plan(
    self: &Book,
    taker_is_bid: bool,
    taker_price: u64,
    taker_qty: u64,
    client_order_id: u64,
    expire_ts: u64,
    now_ts: u64,
): FillPlan {
    // Validate taker input against book constraints
    assert!(taker_qty >= self.min_size, EOrderBelowMinimumSize);
    assert!(taker_qty % self.lot_size == 0, EOrderInvalidLotSize);
    assert!(taker_price >= MIN_PRICE && taker_price <= MAX_PRICE, EInvalidPriceRange);
    assert!(taker_price % self.tick_size == 0, EInvalidPriceRange);
    assert!(now_ts <= expire_ts, EInvalidPriceRange);

    let mut fills = vector[];
    let mut remaining = taker_qty;
    let mut current_fills = 0;

    if (taker_is_bid) {
        // Scan from best ask upwards
        let (mut r, mut off) = self.asks.min_slice();
        while (!r.is_null() && current_fills < MAX_FILLS && remaining > 0) {
            let maker = slice_borrow(self.asks.borrow_slice(r), off);
            let (_, maker_price, _) = utils::decode_order_id(maker.order_id);
            if (now_ts > maker.expire_timestamp) {
                // Skip expired maker in plan; GC later
            } else if (taker_price >= maker_price) {
                let maker_rem = maker.quantity - maker.filled_quantity;
                if (maker_rem > 0) {
                    let fill_qty = if (maker_rem < remaining) { maker_rem } else { remaining };
                    fills.push_back(Fill { maker_id: maker.order_id, price: maker_price, base_qty: fill_qty });
                    remaining = remaining - fill_qty;
                    current_fills = current_fills + 1;
                };
            } else {
                break
            };
            (r, off) = self.asks.next_slice(r, off);
        };
    } else {
        // Taker is ask: scan best bid downwards
        let (mut r, mut off) = self.bids.max_slice();
        while (!r.is_null() && current_fills < MAX_FILLS && remaining > 0) {
            let maker = slice_borrow(self.bids.borrow_slice(r), off);
            let (_, maker_price, _) = utils::decode_order_id(maker.order_id);
            if (now_ts > maker.expire_timestamp) {
                // Skip expired maker in plan; GC later
            } else if (taker_price <= maker_price) {
                let maker_rem = maker.quantity - maker.filled_quantity;
                if (maker_rem > 0) {
                    let fill_qty = if (maker_rem < remaining) { maker_rem } else { remaining };
                    fills.push_back(Fill { maker_id: maker.order_id, price: maker_price, base_qty: fill_qty });
                    remaining = remaining - fill_qty;
                    current_fills = current_fills + 1;
                };
            } else {
                break
            };
            (r, off) = self.bids.prev_slice(r, off);
        };
    };

    FillPlan {
        is_bid: taker_is_bid,
        price: taker_price,
        client_order_id,
        expire_ts,
        taker_requested: taker_qty,
        taker_filled: taker_qty - remaining,
        fills,
    }
}

/// Commit a previously computed fill plan to the orderbook.
/// Applies maker fills, removes fully filled/expired makers, and optionally injects the taker remainder.
public fun commit_fill_plan(
    self: &mut Book,
    plan: FillPlan,
    now_ts: u64,
    inject_remainder: bool,
): Option<u128> {
    let FillPlan { is_bid, price, client_order_id, expire_ts, taker_requested, taker_filled, fills } = plan;

    // Apply fills to makers
    let mut i = 0;
    while (i < fills.length()) {
        let f = fills[i];
        let maker_side = book_side_mut(self, f.maker_id);
        // If maker was canceled between plan and commit, skip silently
        if (!maker_side.contains_key(f.maker_id)) { i = i + 1; continue };
        let maker = maker_side.borrow_mut(f.maker_id);
        // Validate still matchable and not expired
        if (now_ts > maker.expire_timestamp) {
            // remove expired maker
            maker_side.remove(f.maker_id);
            i = i + 1;
            continue
        };
        let (_, maker_price, _) = utils::decode_order_id(maker.order_id);
        if (!( (is_bid && price >= maker_price) || (!is_bid && price <= maker_price) )) {
            // Price no longer crosses; stop committing further fills on this side
            // Safe to break since plan is price-ordered
            break
        };
        // Apply fill
        let maker_rem = maker.quantity - maker.filled_quantity;
        let apply_qty = if (f.base_qty < maker_rem) { f.base_qty } else { maker_rem };
        maker.filled_quantity = maker.filled_quantity + apply_qty;
        // Remove fully filled orders
        if (maker.filled_quantity >= maker.quantity) {
            maker_side.remove(f.maker_id);
        };
        i = i + 1;
    };

    // Inject taker remainder if requested and valid
    if (inject_remainder) {
        let remaining = taker_requested - taker_filled;
        if (remaining >= self.min_size && remaining % self.lot_size == 0 && now_ts <= expire_ts) {
            let mut order = Order { order_id: 0, client_order_id, quantity: remaining, filled_quantity: 0, expire_timestamp: expire_ts };
            // Assign order id and insert at correct side without matching
            let encoded = utils::encode_order_id(is_bid, price, get_order_id(self, is_bid));
            order.order_id = encoded;
            inject_limit_order(self, &order);
            return option::some<u128>(encoded)
        }
    };
    option::none<u128>()
}

// === FillPlan / Fill accessors ===
public fun fillplan_num_fills(self: &FillPlan): u64 { self.fills.length() }
public fun fillplan_get_fill(self: &FillPlan, ix: u64): Fill { self.fills[ix] }
public fun fillplan_taker_requested(self: &FillPlan): u64 { self.taker_requested }
public fun fillplan_taker_filled(self: &FillPlan): u64 { self.taker_filled }
public fun fillplan_is_bid(self: &FillPlan): bool { self.is_bid }
public fun fillplan_price(self: &FillPlan): u64 { self.price }
public fun fillplan_client_order_id(self: &FillPlan): u64 { self.client_order_id }
public fun fillplan_expire_ts(self: &FillPlan): u64 { self.expire_ts }

public fun fill_maker_id(self: &Fill): u128 { self.maker_id }
public fun fill_price(self: &Fill): u64 { self.price }
public fun fill_base_qty(self: &Fill): u64 { self.base_qty }

/// Check if an order_id currently exists in the book (any side)
public fun has_order(self: &Book, order_id: u128): bool {
    let (is_bid, _, _) = utils::decode_order_id(order_id);
    if (is_bid) { self.bids.contains_key(order_id) } else { self.asks.contains_key(order_id) }
}

/// Commit a single maker fill without planning. Updates maker's filled quantity and removes
/// the order if fully filled or expired. No taker remainder injection.
public fun commit_maker_fill(
    self: &mut Book,
    maker_id: u128,
    taker_is_bid: bool,
    taker_price: u64,
    qty: u64,
    now_ts: u64,
) {
    assert!(qty > 0, EOrderBelowMinimumSize);
    let side = book_side_mut(self, maker_id);
    assert!(side.contains_key(maker_id), EEmptyOrderbook);
    let maker = side.borrow_mut(maker_id);
    // Expiry
    if (maker.expire_timestamp < now_ts) { side.remove(maker_id); return };
    // Price cross check
    let (_, maker_price, _) = utils::decode_order_id(maker.order_id);
    assert!((taker_is_bid && taker_price >= maker_price) || (!taker_is_bid && taker_price <= maker_price), EInvalidPriceRange);
    let remaining = maker.quantity - maker.filled_quantity;
    let apply_qty = if (qty < remaining) { qty } else { remaining };
    maker.filled_quantity = maker.filled_quantity + apply_qty;
    if (maker.filled_quantity >= maker.quantity) { side.remove(maker_id); };
}

/// Cancel a resting order by its id if present
public fun cancel_order_by_id(self: &mut Book, order_id: u128) {
    let side = book_side_mut(self, order_id);
    if (side.contains_key(order_id)) { side.remove(order_id); };
}

/// Read-only accessor for an order's filled and total quantities
public fun order_progress(self: &Book, order_id: u128): (u64, u64) {
    let side = book_side(self, order_id);
    let o = side.borrow(order_id);
    (o.filled_quantity, o.quantity)
}

/// Read-only accessor for an order's expiry timestamp
public fun order_expiry(self: &Book, order_id: u128): u64 {
    let side = book_side(self, order_id);
    let o = side.borrow(order_id);
    o.expire_timestamp
}

/// Drain up to `max_removals` resting orders from both sides and collect their ids and remaining quantities
public fun drain_all_collect(self: &mut Book, max_removals: u64): vector<OrderCancel> {
    let mut removed = vector[];
    let mut count = 0u64;
    // Drain asks from best towards worse
    let (mut ar, mut ao) = self.asks.min_slice();
    while (!ar.is_null() && count < max_removals) {
        let ord = slice_borrow(self.asks.borrow_slice(ar), ao);
        let oid = ord.order_id;
        let rem = ord.quantity - ord.filled_quantity;
        // Compute next BEFORE removal
        let (next_ar, next_ao) = self.asks.next_slice(ar, ao);
        self.asks.remove(oid);
        removed.push_back(OrderCancel { order_id: oid, remaining_qty: rem });
        (ar, ao) = (next_ar, next_ao);
        count = count + 1;
    };
    // Drain bids from best towards worse
    let (mut br, mut bo) = self.bids.max_slice();
    while (!br.is_null() && count < max_removals) {
        let ord2 = slice_borrow(self.bids.borrow_slice(br), bo);
        let oid2 = ord2.order_id;
        let rem2 = ord2.quantity - ord2.filled_quantity;
        // Compute prev BEFORE removal
        let (prev_br, prev_bo) = self.bids.prev_slice(br, bo);
        self.bids.remove(oid2);
        removed.push_back(OrderCancel { order_id: oid2, remaining_qty: rem2 });
        (br, bo) = (prev_br, prev_bo);
        count = count + 1;
    };
    removed
}

/// Accessor: get canceled order id
public fun cancel_order_id(c: &OrderCancel): u128 { c.order_id }
/// Accessor: get remaining unfilled quantity
public fun cancel_remaining_qty(c: &OrderCancel): u64 { c.remaining_qty }

/// Remove up to `max_removals` expired orders from both sides and return their order_ids
public fun remove_expired_collect(self: &mut Book, now_ts: u64, max_removals: u64): vector<u128> {
    let mut removed = vector[];
    let mut count = 0u64;
    // Scan asks from best
    let (mut ar, mut ao) = self.asks.min_slice();
    while (!ar.is_null() && count < max_removals) {
        let ord = slice_borrow(self.asks.borrow_slice(ar), ao);
        if (ord.expire_timestamp > now_ts) { break };
        let oid = ord.order_id;
        // Compute next slice BEFORE removal to avoid borrowing a removed child slice
        let (next_ar, next_ao) = self.asks.next_slice(ar, ao);
        self.asks.remove(oid);
        removed.push_back(oid);
        (ar, ao) = (next_ar, next_ao);
        count = count + 1;
    };
    // Scan bids from best
    let (mut br, mut bo) = self.bids.max_slice();
    while (!br.is_null() && count < max_removals) {
        let ord2 = slice_borrow(self.bids.borrow_slice(br), bo);
        if (ord2.expire_timestamp > now_ts) { break };
        let oid2 = ord2.order_id;
        // Compute previous slice BEFORE removal (since iteration goes from best bid downwards)
        let (prev_br, prev_bo) = self.bids.prev_slice(br, bo);
        self.bids.remove(oid2);
        removed.push_back(oid2);
        (br, bo) = (prev_br, prev_bo);
        count = count + 1;
    };
    removed
}

/// Return the current best ask order id if any non-expired exists
public fun best_ask_id(self: &Book, now_ts: u64): (bool, u128) {
    let (mut r, mut off) = self.asks.min_slice();
    while (!r.is_null()) {
        let ord = slice_borrow(self.asks.borrow_slice(r), off);
        if (ord.expire_timestamp >= now_ts) { return (true, ord.order_id) };
        (r, off) = self.asks.next_slice(r, off);
    };
    (false, 0)
}

/// Return the current best bid order id if any non-expired exists
public fun best_bid_id(self: &Book, now_ts: u64): (bool, u128) {
    let (mut r, mut off) = self.bids.max_slice();
    while (!r.is_null()) {
        let ord = slice_borrow(self.bids.borrow_slice(r), off);
        if (ord.expire_timestamp >= now_ts) { return (true, ord.order_id) };
        (r, off) = self.bids.prev_slice(r, off);
    };
    (false, 0)
}

public fun mid_price(self: &Book, current_timestamp: u64): u64 {
    let (mut ask_ref, mut ask_offset) = self.asks.min_slice();
    let (mut bid_ref, mut bid_offset) = self.bids.max_slice();
    let mut best_ask_price = 0;
    let mut best_bid_price = 0;

    while (!ask_ref.is_null()) {
        let best_ask_order = slice_borrow(self.asks.borrow_slice(ask_ref), ask_offset);
        best_ask_price = price_of(best_ask_order.order_id);
        if (current_timestamp <= best_ask_order.expire_timestamp) break;
        (ask_ref, ask_offset) = self.asks.next_slice(ask_ref, ask_offset);
    };

    while (!bid_ref.is_null()) {
        let best_bid_order = slice_borrow(self.bids.borrow_slice(bid_ref), bid_offset);
        best_bid_price = price_of(best_bid_order.order_id);
        if (current_timestamp <= best_bid_order.expire_timestamp) break;
        (bid_ref, bid_offset) = self.bids.prev_slice(bid_ref, bid_offset);
    };

    assert!(!ask_ref.is_null() && !bid_ref.is_null(), EEmptyOrderbook);
    ((best_ask_price + best_bid_price) / 2)
}

public fun get_level2_range_and_ticks(
    self: &Book,
    price_low: u64,
    price_high: u64,
    ticks: u64,
    is_bid: bool,
    current_timestamp: u64,
): (vector<u64>, vector<u64>) {
    assert!(price_low <= price_high, EInvalidPriceRange);
    assert!(price_low >= MIN_PRICE && price_low <= MAX_PRICE, EInvalidPriceRange);
    assert!(price_high >= MIN_PRICE && price_high <= MAX_PRICE, EInvalidPriceRange);
    assert!(ticks > 0, EInvalidTicks);

    let mut price_vec = vector[];
    let mut quantity_vec = vector[];

    let msb = if (is_bid) { (0 as u128) } else { (1 as u128) << 127 };
    let key_low = ((price_low as u128) << 64) + msb;
    let key_high = ((price_high as u128) << 64) + (((1u128 << 64) - 1) as u128) + msb;
    let book_side = if (is_bid) &self.bids else &self.asks;
    let (mut r, mut offset) = if (is_bid) { book_side.slice_before(key_high) } else { book_side.slice_following(key_low) };
    let mut ticks_left = ticks;
    let mut cur_price = 0;
    let mut cur_qty = 0;

    while (!r.is_null() && ticks_left > 0) {
        let order = slice_borrow(book_side.borrow_slice(r), offset);
        if (current_timestamp <= order.expire_timestamp) {
            let (_is_bid_local, order_price, _) = utils::decode_order_id(order.order_id);
            if ((is_bid && order_price < price_low) || (!is_bid && order_price > price_high)) break;
            if (cur_price == 0 && ((is_bid && order_price <= price_high) || (!is_bid && order_price >= price_low))) {
                cur_price = order_price
            };
            if (cur_price != 0 && order_price != cur_price) {
                price_vec.push_back(cur_price);
                quantity_vec.push_back(cur_qty);
                cur_price = order_price;
                cur_qty = 0;
                ticks_left = ticks_left - 1;
                if (ticks_left == 0) break;
            };
            if (cur_price != 0) {
                cur_qty = cur_qty + (order.quantity - order.filled_quantity);
            };
        };
        (r, offset) = if (is_bid) { book_side.prev_slice(r, offset) } else { book_side.next_slice(r, offset) };
    };

    if (cur_price != 0 && ticks_left > 0) {
        price_vec.push_back(cur_price);
        quantity_vec.push_back(cur_qty);
    };

    (price_vec, quantity_vec)
}

public fun get_order(self: &Book, order_id: u128): Order {
    let order = book_side(self, order_id).borrow(order_id);
    order_copy(order)
}

/// Public accessors for Order fields to support external integrations
public fun order_id_of(order: &Order): u128 { order.order_id }
public fun order_quantity_of(order: &Order): u64 { order.quantity }
public fun order_filled_quantity_of(order: &Order): u64 { order.filled_quantity }
public fun order_expire_ts_of(order: &Order): u64 { order.expire_timestamp }

// === Internal matching ===
fun match_against_book(self: &mut Book, taker: &mut Order, timestamp: u64) {
    let is_bid = is_bid(taker.order_id);
    let book_side = if (is_bid) &mut self.asks else &mut self.bids;
    let (mut r, mut offset) = if (is_bid) { book_side.min_slice() } else { book_side.max_slice() };
    let mut current_fills = 0;

    while (!r.is_null() && current_fills < MAX_FILLS) {
        let maker = slice_borrow_mut(book_side.borrow_slice_mut(r), offset);
        if (!can_match(taker, maker)) break;
        apply_fill(taker, maker, timestamp);
        (r, offset) = if (is_bid) { book_side.next_slice(r, offset) } else { book_side.prev_slice(r, offset) };
        current_fills = current_fills + 1;
    };

    // Remove fully filled or expired makers
    // Note: simple second pass using the same side reference to avoid borrow conflicts
    let (mut r2, mut off2) = if (is_bid) { book_side.min_slice() } else { book_side.max_slice() };
    let max_scan = MAX_FILLS;
    let mut scanned = 0;
    while (!r2.is_null() && scanned < max_scan) {
        let (maker_id, should_remove) = {
            let maker = slice_borrow(book_side.borrow_slice(r2), off2);
            let mid = maker.order_id;
            let sr = maker.filled_quantity >= maker.quantity || maker.expire_timestamp < timestamp;
            (mid, sr)
        };
        if (should_remove) { book_side.remove(maker_id); };
        (r2, off2) = if (is_bid) { book_side.next_slice(r2, off2) } else { book_side.prev_slice(r2, off2) };
        scanned = scanned + 1;
    };
}

fun inject_limit_order(self: &mut Book, order: &Order) {
    if (is_bid(order.order_id)) { self.bids.insert(order.order_id, order_copy(order)); } else { self.asks.insert(order.order_id, order_copy(order)); };
}

// === Order helpers ===
public fun new_order(is_bid: bool, price: u64, client_order_id: u64, quantity: u64, expire_timestamp: u64): Order {
    Order { order_id: utils::encode_order_id(is_bid, price, 0), client_order_id, quantity, filled_quantity: 0, expire_timestamp }
}

fun order_copy(order: &Order): Order {
    Order { order_id: order.order_id, client_order_id: order.client_order_id, quantity: order.quantity, filled_quantity: order.filled_quantity, expire_timestamp: order.expire_timestamp }
}

fun is_bid(order_id: u128): bool { let (is_bid, _, _) = utils::decode_order_id(order_id); is_bid }
fun price_of(order_id: u128): u64 { let (_, price, _) = utils::decode_order_id(order_id); price }

fun validate_order_inputs(order: &Order, tick_size: u64, min_size: u64, lot_size: u64, timestamp: u64) {
    assert!(order.quantity >= min_size, EOrderBelowMinimumSize);
    assert!(order.quantity % lot_size == 0, EOrderInvalidLotSize);
    assert!(timestamp <= order.expire_timestamp, EInvalidPriceRange);
    let (_, price, _) = utils::decode_order_id(order.order_id);
    assert!(price >= MIN_PRICE && price <= MAX_PRICE, EInvalidPriceRange);
    assert!(price % tick_size == 0, EInvalidPriceRange);
}

fun get_order_id(self: &mut Book, is_bid: bool): u64 {
    if (is_bid) { self.next_bid_order_id = self.next_bid_order_id - 1; self.next_bid_order_id } else { self.next_ask_order_id = self.next_ask_order_id + 1; self.next_ask_order_id }
}

fun book_side_mut(self: &mut Book, order_id: u128): &mut BigVector<Order> {
    let (is_bid, _, _) = utils::decode_order_id(order_id);
    if (is_bid) { &mut self.bids } else { &mut self.asks }
}

fun book_side(self: &Book, order_id: u128): &BigVector<Order> {
    let (is_bid, _, _) = utils::decode_order_id(order_id);
    if (is_bid) { &self.bids } else { &self.asks }
}

fun can_match(taker: &Order, maker: &Order): bool {
    let (_, maker_price, _) = utils::decode_order_id(maker.order_id);
    let (taker_is_bid, taker_price, _) = utils::decode_order_id(taker.order_id);
    taker.quantity - taker.filled_quantity > 0 && ((taker_is_bid && taker_price >= maker_price) || (!taker_is_bid && taker_price <= maker_price))
}

fun apply_fill(taker: &mut Order, maker: &mut Order, timestamp: u64) {
    let remaining_maker = maker.quantity - maker.filled_quantity;
    let remaining_taker = taker.quantity - taker.filled_quantity;
    let expired = timestamp > maker.expire_timestamp;
    let base_qty = if (expired) { remaining_maker } else { if (remaining_taker < remaining_maker) { remaining_taker } else { remaining_maker } };
    if (expired) {
        maker.filled_quantity = maker.quantity; // expire maker fully
    } else {
        maker.filled_quantity = maker.filled_quantity + base_qty;
        taker.filled_quantity = taker.filled_quantity + base_qty;
    };
}


