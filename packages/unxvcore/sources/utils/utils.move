// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unxversal utilities for order id encoding/decoding compatible with DeepBook v3.
module unxvcore::utils;

/// first bit is 0 for bid, 1 for ask
/// next 63 bits are price
/// last 64 bits are order_id (per-side monotonic id)
public fun encode_order_id(is_bid: bool, price: u64, order_id: u64): u128 {
    if (is_bid) {
        ((price as u128) << 64) + (order_id as u128)
    } else {
        (1u128 << 127) + ((price as u128) << 64) + (order_id as u128)
    }
}

/// Decode order_id into (is_bid, price, order_id)
public fun decode_order_id(encoded_order_id: u128): (bool, u64, u64) {
    let is_bid = (encoded_order_id >> 127) == 0;
    let price = (encoded_order_id >> 64) as u64;
    let price = price & ((1u64 << 63) - 1);
    let order_id = (encoded_order_id & ((1u128 << 64) - 1)) as u64;

    (is_bid, price, order_id)
}

#[test]
fun test_encode_decode_order_id() {
    let is_bid = true;
    let price = 2371538230592318123;
    let order_id = 9211238512301581235;
    let encoded_order_id = encode_order_id(is_bid, price, order_id);
    let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(encoded_order_id);
    assert!(decoded_is_bid == is_bid, 0);
    assert!(decoded_price == price, 0);
    assert!(decoded_order_id == order_id, 0);

    let is_bid = false;
    let price = 1;
    let order_id = 1;
    let encoded_order_id = encode_order_id(is_bid, price, order_id);
    let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(encoded_order_id);
    assert!(decoded_is_bid == is_bid, 0);
    assert!(decoded_price == price, 0);
    assert!(decoded_order_id == order_id, 0);

    let is_bid = true;
    let price = ((1u128 << 63) - 1) as u64;
    let order_id = ((1u128 << 64) - 1) as u64;
    let encoded_order_id = encode_order_id(is_bid, price, order_id);
    let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(encoded_order_id);
    assert!(decoded_is_bid == is_bid, 0);
    assert!(decoded_price == price, 0);
    assert!(decoded_order_id == order_id, 0);

    let is_bid = false;
    let price = 0;
    let order_id = 0;
    let encoded_order_id = encode_order_id(is_bid, price, order_id);
    let (decoded_is_bid, decoded_price, decoded_order_id) = decode_order_id(encoded_order_id);
    assert!(decoded_is_bid == is_bid, 0);
    assert!(decoded_price == price, 0);
    assert!(decoded_order_id == order_id, 0);
}


