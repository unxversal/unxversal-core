// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unxversal on-chain order book compatible with DeepBook v3 semantics.
///
/// Provides:
/// - `Book` with bids/asks BigVectors of `Order`
/// - Order creation with immediate matching and optional injection
/// - Mid-price and level2 views
/// - Cancel/Modify APIs
module unxversal::book;

use unxversal::big_vector::{Self, BigVector, slice_borrow, slice_borrow_mut};
use unxversal::utils;

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


