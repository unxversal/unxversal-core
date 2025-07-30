/// Module: oracle
module unxversal::oracle;
 
use sui::clock::Clock;
use pyth::price_info;
use pyth::price_identifier;
use pyth::price;
use pyth::i64::I64;
use pyth::pyth;
use pyth::price_info::PriceInfoObject;
use std::string::String;
use std::vec_set::VecSet;
 
const E_INVALID_ID: u64 = 1;
 
public(package) fun get_token_price(
    // Other arguments
    clock: &Clock,
    price_info_object: &PriceInfoObject,
    price_ids: &VecSet<String>
): I64 {
    let max_age = 60;
 
    // Make sure the price is not older than max_age seconds
    let price_struct = pyth::get_price_no_older_than(price_info_object, clock, max_age);
 
    // Check the price feed ID
    let price_info = price_info::get_price_info_from_price_info_object(price_info_object);
    let price_id = price_identifier::get_bytes(&price_info::get_price_identifier(&price_info));
 
    // verify price feed ID
    // The complete list of feed IDs is available at https://pyth.network/developers/price-feed-ids
    assert!(price_ids.contains(&price_id), E_INVALID_ID);
 
    // Extract the price, decimal, and timestamp from the price struct and use them.
    let _decimal_i64 = price::get_expo(&price_struct);
    let price_i64 = price::get_price(&price_struct);
    let _timestamp_sec = price::get_timestamp(&price_struct);
 
    price_i64
}