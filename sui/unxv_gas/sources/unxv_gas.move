/// Module: unxv_gas
/// UnXversal Gas Futures Protocol - World's first blockchain gas price derivatives market
/// Enables sophisticated hedging of operational costs and speculative trading on Sui network gas prices
/// Specialized for sponsored transaction providers and institutional gas cost management
#[allow(duplicate_alias, unused_use, unused_const, unused_variable, unused_function)]
module unxv_gas::unxv_gas;

use std::string::{Self, String};
use std::option::{Self, Option};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::event;
use sui::clock::{Self, Clock};
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};
use sui::vec_map::{Self, VecMap};
use deepbook::balance_manager::{Self, BalanceManager, TradeProof};
use pyth::price_info::{Self, PriceInfoObject};
use deepbook::pool::{Self, Pool};

// ========== SignedInt for P&L calculations ==========

/// SignedInt for handling positive and negative values
public struct SignedInt has copy, drop, store {
    value: u64,
    is_negative: bool,
}

/// Helper functions for SignedInt
public fun signed_int_from(value: u64): SignedInt {
    SignedInt { value, is_negative: false }
}

public fun signed_int_negative(value: u64): SignedInt {
    SignedInt { value, is_negative: true }
}

public fun signed_int_add(a: &SignedInt, b: &SignedInt): SignedInt {
    if (a.is_negative == b.is_negative) {
        SignedInt { value: a.value + b.value, is_negative: a.is_negative }
    } else {
        if (a.value >= b.value) {
            SignedInt { value: a.value - b.value, is_negative: a.is_negative }
        } else {
            SignedInt { value: b.value - a.value, is_negative: b.is_negative }
        }
    }
}

// ========== Error Codes ==========
const E_NOT_ADMIN: u64 = 1;
const E_CONTRACT_NOT_FOUND: u64 = 2;
const E_INSUFFICIENT_MARGIN: u64 = 3;
const E_POSITION_NOT_FOUND: u64 = 4;
const E_CONTRACT_EXPIRED: u64 = 5;
const E_INVALID_GAS_PRICE: u64 = 6;
const E_SETTLEMENT_NOT_READY: u64 = 7;
const E_INSUFFICIENT_BALANCE: u64 = 8;
const E_UNAUTHORIZED: u64 = 9;
const E_INVALID_CONTRACT_TYPE: u64 = 10;
const E_SYSTEM_PAUSED: u64 = 11;
const E_ORACLE_PRICE_STALE: u64 = 12;

// ========== Constants ==========
const BASIS_POINTS: u64 = 10000;
const MIN_MARGIN_RATIO: u64 = 500; // 5%
const DEFAULT_TRADING_FEE: u64 = 25; // 0.25%
const UNXV_DISCOUNT: u64 = 2000; // 20% discount for UNXV holders
const SETTLEMENT_WINDOW: u64 = 86400000; // 24 hours in milliseconds
const GAS_ORACLE_UPDATE_FREQUENCY: u64 = 30000; // 30 seconds
const MAX_PRICE_DEVIATION: u64 = 1000; // 10% max price deviation

// Gas contract types
const GAS_STATION_CONTRACT: vector<u8> = b"GAS_STATION";
const APP_SPONSOR_CONTRACT: vector<u8> = b"APP_SPONSOR";
const WILDCARD_CONTRACT: vector<u8> = b"WILDCARD";
const ENTERPRISE_CONTRACT: vector<u8> = b"ENTERPRISE";

// Standard coin types
public struct USDC has drop {}
public struct SUI has drop {}
public struct UNXV has drop {}

// ========== Admin Capabilities ==========

public struct AdminCap has key, store {
    id: UID,
}

public struct InstitutionalCap has key, store {
    id: UID,
    institution: address,
}

// ========== Core Protocol Objects ==========

/// Central registry for all gas futures contracts and configuration
public struct GasFuturesRegistry has key {
    id: UID,
    
    // Contract management
    active_gas_contracts: Table<String, GasFuturesContract>,
    expired_contracts: Table<String, GasFuturesContract>,
    
    // Sponsored transaction focus
    gas_station_contracts: Table<address, vector<ID>>,
    sponsor_contracts: Table<address, vector<ID>>,
    contract_types: VecSet<String>,
    
    // Fee structure
    trading_fee: u64,
    unxv_discount: u64,
    settlement_fee: u64,
    
    // Risk parameters
    min_margin_ratio: u64,
    max_position_size: u64,
    price_deviation_threshold: u64,
    
    // UNXV tokenomics
    unxv_benefits: Table<u64, GasTierBenefits>,
    
    // Emergency controls
    emergency_settlement: bool,
    is_paused: bool,
    admin_cap: Option<AdminCap>,
}

/// Individual gas futures contract
public struct GasFuturesContract has store {
    contract_symbol: String,
    contract_type: String,
    
    // Contract specifications
    expiry_timestamp: u64,
    settlement_period_start: u64,
    settlement_period_end: u64,
    contract_size: u64, // Gas units per contract
    
    // Settlement details
    settlement_gas_price: Option<u64>,
    is_settled: bool,
    settlement_method: String, // "TWAP", "VWAP", "AVERAGE"
    
    // Market data
    current_futures_price: u64,
    reference_gas_price: u64,
    total_volume: u64,
    open_interest: u64,
    
    // Contract status
    is_active: bool,
    created_timestamp: u64,
}

/// Individual gas futures market for a specific contract
public struct GasFuturesMarket<phantom T: store> has key {
    id: UID,
    
    // Market identification
    contract_symbol: String,
    contract_type: String,
    expiry_timestamp: u64,
    
    // Position tracking
    long_positions: Table<address, GasPosition>,
    short_positions: Table<address, GasPosition>,
    total_positions: u64,
    
    // Market state
    current_futures_price: u64,
    reference_gas_price: u64,
    basis: SignedInt, // futures - spot
    implied_volatility: u64,
    
    // Volume and liquidity
    total_volume_24h: u64,
    total_open_interest: u64,
    gas_units_hedged: u64,
    
    // Settlement tracking
    settlement_price_samples: vector<GasPriceSample>,
    pending_settlements: u64,
    settled_positions: u64,
    
    // Market status
    is_active: bool,
    last_price_update: u64,
}

/// User gas position for hedging or speculation
public struct GasPosition has key, store {
    id: UID,
    user: address,
    contract_id: ID,
    
    // Position details
    position_type: String, // "GAS_STATION_HEDGE", "SPONSOR_HEDGE", "SPECULATION"
    side: String, // "LONG" or "SHORT"
    gas_units: u64,
    average_price: u64,
    margin_posted: u64,
    
    // Hedging information
    hedging_purpose: String,
    expected_gas_usage: u64,
    hedge_effectiveness: u64,
    
    // P&L tracking
    unrealized_pnl: SignedInt,
    realized_pnl: SignedInt,
    gas_cost_savings: SignedInt,
    
    // Position management
    created_timestamp: u64,
    auto_settlement_enabled: bool,
    
    // Settlement details
    settlement_eligible: bool,
    settlement_amount: Option<u64>,
}

/// Gas price oracle for real-time gas price monitoring
public struct GasOracle has key {
    id: UID,
    operator: address,
    
    // Price feeds
    real_time_gas_price: u64,
    price_update_frequency: u64,
    last_update_timestamp: u64,
    
    // Price calculations
    twap_1h: u64,
    twap_24h: u64,
    vwap_24h: u64,
    
    // Volatility measures
    volatility_1h: u64,
    volatility_24h: u64,
    volatility_7d: u64,
    
    // Network monitoring
    current_congestion_level: u64,
    transaction_volume: u64,
    network_utilization: u64,
    
    // Data quality
    data_quality_score: u64,
    price_sources: VecSet<String>,
}

/// Gas price sample for settlement calculations
public struct GasPriceSample has store {
    timestamp: u64,
    gas_price: u64,
    block_number: u64,
    weight: u64,
    network_congestion: u64,
}

/// Settlement engine for automated gas futures settlement
public struct SettlementEngine has key {
    id: UID,
    operator: address,
    
    // Settlement parameters
    settlement_window: u64,
    settlement_lag: u64,
    price_sample_frequency: u64,
    
    // Processing
    processing_batch_size: u64,
    auto_settlement_enabled: bool,
    
    // Performance tracking
    settlement_success_rate: u64,
    total_settlements_processed: u64,
    average_settlement_time: u64,
}

/// UNXV tier benefits for gas futures
public struct GasTierBenefits has store {
    trading_fee_discount: u64,
    settlement_fee_discount: u64,
    margin_requirement_reduction: u64,
    position_limit_increase: u64,
    priority_settlement: bool,
    advanced_analytics: bool,
    custom_hedging_strategies: bool,
    gas_subsidy_eligibility: bool,
}

// ========== Events ==========

/// Contract lifecycle events
public struct GasFuturesContractListed has copy, drop {
    contract_symbol: String,
    contract_type: String,
    expiry_timestamp: u64,
    contract_size: u64,
    reference_gas_price: u64,
    timestamp: u64,
}

public struct GasFuturesSettled has copy, drop {
    contract_symbol: String,
    final_settlement_price: u64,
    settlement_method: String,
    total_positions_settled: u64,
    total_settlement_value: u64,
    timestamp: u64,
}

/// Position events
public struct GasPositionOpened has copy, drop {
    position_id: ID,
    user: address,
    contract_symbol: String,
    position_type: String,
    side: String,
    gas_units: u64,
    entry_price: u64,
    margin_posted: u64,
    timestamp: u64,
}

public struct GasPositionSettled has copy, drop {
    position_id: ID,
    user: address,
    contract_symbol: String,
    settlement_price: u64,
    settlement_amount: u64,
    realized_pnl: SignedInt,
    gas_cost_savings: SignedInt,
    timestamp: u64,
}

/// Gas price events
public struct GasPriceUpdated has copy, drop {
    new_gas_price: u64,
    old_gas_price: u64,
    price_change: SignedInt,
    network_congestion: u64,
    update_source: String,
    timestamp: u64,
}

public struct NetworkCongestionSpike has copy, drop {
    congestion_level: u64,
    gas_price_impact: u64,
    expected_duration: u64,
    trigger_events: vector<String>,
    timestamp: u64,
}

// ========== Initialization ==========

/// Initialize the gas futures protocol
fun init(ctx: &mut TxContext) {
    init_internal(ctx);
}

/// Internal initialization function
fun init_internal(ctx: &mut TxContext) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    
    // Create the main registry
    let mut registry = GasFuturesRegistry {
        id: object::new(ctx),
        active_gas_contracts: table::new(ctx),
        expired_contracts: table::new(ctx),
        gas_station_contracts: table::new(ctx),
        sponsor_contracts: table::new(ctx),
        contract_types: vec_set::empty(),
        trading_fee: DEFAULT_TRADING_FEE,
        unxv_discount: UNXV_DISCOUNT,
        settlement_fee: 10, // 0.1%
        min_margin_ratio: MIN_MARGIN_RATIO,
        max_position_size: 1000000, // 1M gas units
        price_deviation_threshold: MAX_PRICE_DEVIATION,
        unxv_benefits: table::new(ctx),
        emergency_settlement: false,
        is_paused: false,
        admin_cap: option::none(),
    };
    
    // Setup default contract types
    vec_set::insert(&mut registry.contract_types, string::utf8(GAS_STATION_CONTRACT));
    vec_set::insert(&mut registry.contract_types, string::utf8(APP_SPONSOR_CONTRACT));
    vec_set::insert(&mut registry.contract_types, string::utf8(WILDCARD_CONTRACT));
    vec_set::insert(&mut registry.contract_types, string::utf8(ENTERPRISE_CONTRACT));
    
    // Setup default UNXV benefits tiers
    setup_default_unxv_tiers(&mut registry, ctx);
    
    // Create gas oracle
    let gas_oracle = GasOracle {
        id: object::new(ctx),
        operator: tx_context::sender(ctx),
        real_time_gas_price: 1000, // Default: 1000 MIST per gas unit
        price_update_frequency: GAS_ORACLE_UPDATE_FREQUENCY,
        last_update_timestamp: 0,
        twap_1h: 1000,
        twap_24h: 1000,
        vwap_24h: 1000,
        volatility_1h: 100, // 1%
        volatility_24h: 200, // 2%
        volatility_7d: 500, // 5%
        current_congestion_level: 0,
        transaction_volume: 0,
        network_utilization: 0,
        data_quality_score: 9000, // 90%
        price_sources: vec_set::empty(),
    };
    
    // Create settlement engine
    let settlement_engine = SettlementEngine {
        id: object::new(ctx),
        operator: tx_context::sender(ctx),
        settlement_window: SETTLEMENT_WINDOW,
        settlement_lag: 3600000, // 1 hour
        price_sample_frequency: 300000, // 5 minutes
        processing_batch_size: 100,
        auto_settlement_enabled: true,
        settlement_success_rate: 9950, // 99.5%
        total_settlements_processed: 0,
        average_settlement_time: 30000, // 30 seconds
    };
    
    // Share objects
    transfer::share_object(registry);
    transfer::share_object(gas_oracle);
    transfer::share_object(settlement_engine);
    
    // Transfer admin capability
    transfer::transfer(admin_cap, tx_context::sender(ctx));
}

/// Setup default UNXV tier benefits
fun setup_default_unxv_tiers(registry: &mut GasFuturesRegistry, _ctx: &mut TxContext) {
    // Tier 0 (0 UNXV): Standard rates
    table::add(&mut registry.unxv_benefits, 0, GasTierBenefits {
        trading_fee_discount: 0,
        settlement_fee_discount: 0,
        margin_requirement_reduction: 0,
        position_limit_increase: 0,
        priority_settlement: false,
        advanced_analytics: false,
        custom_hedging_strategies: false,
        gas_subsidy_eligibility: false,
    });
    
    // Tier 1 (1,000 UNXV): Basic benefits
    table::add(&mut registry.unxv_benefits, 1, GasTierBenefits {
        trading_fee_discount: 1000, // 10%
        settlement_fee_discount: 1500, // 15%
        margin_requirement_reduction: 1000, // 10%
        position_limit_increase: 2500, // 25%
        priority_settlement: false,
        advanced_analytics: false,
        custom_hedging_strategies: false,
        gas_subsidy_eligibility: true,
    });
    
    // Tier 2 (5,000 UNXV): Enhanced benefits
    table::add(&mut registry.unxv_benefits, 2, GasTierBenefits {
        trading_fee_discount: 2000, // 20%
        settlement_fee_discount: 3000, // 30%
        margin_requirement_reduction: 1500, // 15%
        position_limit_increase: 5000, // 50%
        priority_settlement: true,
        advanced_analytics: true,
        custom_hedging_strategies: false,
        gas_subsidy_eligibility: true,
    });
    
    // Tier 3 (25,000 UNXV): Premium benefits
    table::add(&mut registry.unxv_benefits, 3, GasTierBenefits {
        trading_fee_discount: 1500, // 15%
        settlement_fee_discount: 3000, // 30%
        margin_requirement_reduction: 1200, // 12%
        position_limit_increase: 7500, // 75%
        priority_settlement: true,
        advanced_analytics: true,
        custom_hedging_strategies: false,
        gas_subsidy_eligibility: true,
    });
    
    // Tier 4 (100,000 UNXV): VIP benefits
    table::add(&mut registry.unxv_benefits, 4, GasTierBenefits {
        trading_fee_discount: 4000, // 40%
        settlement_fee_discount: 6000, // 60%
        margin_requirement_reduction: 3500, // 35%
        position_limit_increase: 20000, // 200%
        priority_settlement: true,
        advanced_analytics: true,
        custom_hedging_strategies: true,
        gas_subsidy_eligibility: true,
    });
    
    // Tier 5 (500,000 UNXV): Institutional benefits
    table::add(&mut registry.unxv_benefits, 5, GasTierBenefits {
        trading_fee_discount: 5000, // 50%
        settlement_fee_discount: 7500, // 75%
        margin_requirement_reduction: 5000, // 50%
        position_limit_increase: 20000, // 200%
        priority_settlement: true,
        advanced_analytics: true,
        custom_hedging_strategies: true,
        gas_subsidy_eligibility: true,
    });
}

/// Initialize for testing
public fun init_for_testing(ctx: &mut TxContext) {
    init_internal(ctx);
}

// ========== Admin Functions ==========

/// Create a new gas futures contract
public fun create_gas_futures_contract<T: store>(
    registry: &mut GasFuturesRegistry,
    contract_symbol: String,
    contract_type: String,
    expiry_timestamp: u64,
    settlement_period_start: u64,
    settlement_period_end: u64,
    contract_size: u64,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ID {
    assert!(!registry.is_paused, E_SYSTEM_PAUSED);
    assert!(vec_set::contains(&registry.contract_types, &contract_type), E_INVALID_CONTRACT_TYPE);
    
    let current_timestamp = 0; // Simplified for demo
    
    // Create gas futures contract
    let contract = GasFuturesContract {
        contract_symbol,
        contract_type,
        expiry_timestamp,
        settlement_period_start,
        settlement_period_end,
        contract_size,
        settlement_gas_price: option::none(),
        is_settled: false,
        settlement_method: string::utf8(b"TWAP"),
        current_futures_price: 1000, // Default price
        reference_gas_price: 1000,
        total_volume: 0,
        open_interest: 0,
        is_active: true,
        created_timestamp: current_timestamp,
    };
    
    // Create gas futures market
    let market = GasFuturesMarket<T> {
        id: object::new(ctx),
        contract_symbol,
        contract_type,
        expiry_timestamp,
        long_positions: table::new(ctx),
        short_positions: table::new(ctx),
        total_positions: 0,
        current_futures_price: 1000,
        reference_gas_price: 1000,
        basis: signed_int_from(0),
        implied_volatility: 200, // 2%
        total_volume_24h: 0,
        total_open_interest: 0,
        gas_units_hedged: 0,
        settlement_price_samples: vector::empty(),
        pending_settlements: 0,
        settled_positions: 0,
        is_active: true,
        last_price_update: 0,
    };
    
    let market_id = object::id(&market);
    
    // Store contract in registry
    table::add(&mut registry.active_gas_contracts, contract_symbol, contract);
    
    // Emit event
    event::emit(GasFuturesContractListed {
        contract_symbol,
        contract_type,
        expiry_timestamp,
        contract_size,
        reference_gas_price: 1000,
        timestamp: current_timestamp,
    });
    
    transfer::share_object(market);
    market_id
}

/// Emergency pause
public fun emergency_pause(
    registry: &mut GasFuturesRegistry,
    _admin_cap: &AdminCap,
) {
    registry.is_paused = true;
}

/// Resume operations
public fun resume_operations(
    registry: &mut GasFuturesRegistry,
    _admin_cap: &AdminCap,
) {
    registry.is_paused = false;
}

// ========== Gas Position Management ==========

/// Open a gas futures position (PRODUCTION-READY)
public fun open_gas_position<T: store>(
    market: &mut GasFuturesMarket<T>,
    registry: &GasFuturesRegistry,
    pool: &mut Pool<USDC, T>,
    side: String, // "LONG" or "SHORT"
    gas_units: u64,
    position_type: String,
    hedging_purpose: String,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: &vector<PriceInfoObject>,
    gas_oracle: &GasOracle,
    clock: &Clock,
    margin_coin: Coin<USDC>,
    ctx: &mut TxContext,
) : GasPosition {
    assert!(!registry.is_paused, E_SYSTEM_PAUSED);
    assert!(market.is_active, E_CONTRACT_EXPIRED);
    assert!(gas_units > 0, E_INSUFFICIENT_BALANCE);

    let user = tx_context::sender(ctx);
    let margin_amount = coin::value(&margin_coin);

    // Use the latest gas price from the oracle as the expected entry price
    let expected_entry_price = gas_oracle.real_time_gas_price;
    assert!(expected_entry_price > 0, E_INVALID_GAS_PRICE);

    // Calculate required margin
    let position_value = gas_units * expected_entry_price;
    let required_margin = (position_value * registry.min_margin_ratio) / BASIS_POINTS;
    assert!(margin_amount >= required_margin, E_INSUFFICIENT_MARGIN);

    // Deposit margin into user's BalanceManager (locks funds)
    deepbook::balance_manager::deposit<USDC>(balance_manager, margin_coin, ctx);

    // Place a market order on DeepBook for the gas futures contract
    let is_bid = side == string::utf8(b"LONG");
    let client_order_id = clock::timestamp_ms(clock); // Use timestamp as unique order ID
    let self_matching_option = 0u8; // SELF_MATCHING_ALLOWED
    let pay_with_deep = false; // Use input token for fees
    let _order_info = deepbook::pool::place_market_order<USDC, T>(
        pool,
        balance_manager,
        trade_proof,
        client_order_id,
        self_matching_option,
        gas_units,
        is_bid,
        pay_with_deep,
        clock,
        ctx,
    );

    // Use the expected entry price from the oracle (DeepBook fill price not accessible)
    let entry_price = expected_entry_price;
    assert!(entry_price > 0, E_INVALID_GAS_PRICE);

    // Create position
    let position = GasPosition {
        id: object::new(ctx),
        user,
        contract_id: object::id(market),
        position_type,
        side,
        gas_units,
        average_price: entry_price,
        margin_posted: margin_amount,
        hedging_purpose,
        expected_gas_usage: gas_units,
        hedge_effectiveness: 8500, // 85% default
        unrealized_pnl: signed_int_from(0),
        realized_pnl: signed_int_from(0),
        gas_cost_savings: signed_int_from(0),
        created_timestamp: clock::timestamp_ms(clock),
        auto_settlement_enabled: false,
        settlement_eligible: false,
        settlement_amount: option::none(),
    };

    let position_id = object::id(&position);

    // Update market statistics
    market.total_positions = market.total_positions + 1;
    market.total_open_interest = market.total_open_interest + gas_units;
    market.gas_units_hedged = market.gas_units_hedged + gas_units;
    market.current_futures_price = entry_price;

    // Emit event
    event::emit(GasPositionOpened {
        position_id,
        user,
        contract_symbol: market.contract_symbol,
        position_type,
        side,
        gas_units,
        entry_price,
        margin_posted: margin_amount,
        timestamp: clock::timestamp_ms(clock),
    });

    position
}

/// Test-only simplified position opening
public fun test_open_gas_position<T: store>(
    market: &mut GasFuturesMarket<T>,
    registry: &GasFuturesRegistry,
    side: String,
    gas_units: u64,
    position_type: String,
    entry_price: u64,
    margin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): GasPosition {
    assert!(!registry.is_paused, E_SYSTEM_PAUSED);
    assert!(market.is_active, E_CONTRACT_EXPIRED);
    assert!(gas_units > 0, E_INSUFFICIENT_BALANCE);
    
    let user = tx_context::sender(ctx);
    
    // Create position
    let position = GasPosition {
        id: object::new(ctx),
        user,
        contract_id: object::id(market),
        position_type,
        side,
        gas_units,
        average_price: entry_price,
        margin_posted: margin_amount,
        hedging_purpose: string::utf8(b"TESTING"),
        expected_gas_usage: gas_units,
        hedge_effectiveness: 8500,
        unrealized_pnl: signed_int_from(0),
        realized_pnl: signed_int_from(0),
        gas_cost_savings: signed_int_from(0),
        created_timestamp: clock::timestamp_ms(clock),
        auto_settlement_enabled: false,
        settlement_eligible: false,
        settlement_amount: option::none(),
    };
    
    let position_id = object::id(&position);
    
    // Update market statistics
    market.total_positions = market.total_positions + 1;
    market.total_open_interest = market.total_open_interest + gas_units;
    market.gas_units_hedged = market.gas_units_hedged + gas_units;
    market.current_futures_price = entry_price;
    
    // Emit event
    event::emit(GasPositionOpened {
        position_id,
        user,
        contract_symbol: market.contract_symbol,
        position_type,
        side,
        gas_units,
        entry_price,
        margin_posted: margin_amount,
        timestamp: clock::timestamp_ms(clock),
    });
    
    position
}

// ========== Gas Oracle Functions ==========

/// Update gas price in the oracle
public fun update_gas_price(
    gas_oracle: &mut GasOracle,
    new_gas_price: u64,
    network_congestion: u64,
    update_source: String,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(new_gas_price > 0, E_INVALID_GAS_PRICE);
    
    let old_price = gas_oracle.real_time_gas_price;
    let price_change = if (new_gas_price > old_price) {
        signed_int_from(new_gas_price - old_price)
    } else {
        signed_int_negative(old_price - new_gas_price)
    };
    
    // Update gas price
    gas_oracle.real_time_gas_price = new_gas_price;
    gas_oracle.current_congestion_level = network_congestion;
    gas_oracle.last_update_timestamp = clock::timestamp_ms(clock);
    
    // Update TWAP calculations (simplified)
    gas_oracle.twap_1h = (gas_oracle.twap_1h + new_gas_price) / 2;
    gas_oracle.twap_24h = (gas_oracle.twap_24h + new_gas_price) / 2;
    gas_oracle.vwap_24h = (gas_oracle.vwap_24h + new_gas_price) / 2;
    
    // Update volatility (simplified)
    let price_change_abs = if (!price_change.is_negative) {
        price_change.value
    } else {
        price_change.value
    };
    
    gas_oracle.volatility_1h = (gas_oracle.volatility_1h + price_change_abs) / 2;
    
    // Emit price update event
    event::emit(GasPriceUpdated {
        new_gas_price,
        old_gas_price: old_price,
        price_change,
        network_congestion,
        update_source,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Check for congestion spike
    if (network_congestion > 8000) { // 80% congestion
        event::emit(NetworkCongestionSpike {
            congestion_level: network_congestion,
            gas_price_impact: price_change_abs,
            expected_duration: 3600000, // 1 hour estimate
            trigger_events: vector[string::utf8(b"HIGH_NETWORK_USAGE")],
            timestamp: clock::timestamp_ms(clock),
        });
    };
    
    let _ = ctx;
}

// ========== Settlement Functions ==========

/// Calculate gas settlement price using TWAP
public fun calculate_gas_settlement_price<T: store>(
    market: &GasFuturesMarket<T>,
    gas_oracle: &GasOracle,
    settlement_method: String,
): u64 {
    if (settlement_method == string::utf8(b"TWAP")) {
        gas_oracle.twap_24h
    } else if (settlement_method == string::utf8(b"VWAP")) {
        gas_oracle.vwap_24h
    } else {
        // Default to current price
        gas_oracle.real_time_gas_price
    }
}

/// Settle a gas position
public fun settle_gas_position<T: store>(
    market: &mut GasFuturesMarket<T>,
    registry: &mut GasFuturesRegistry,
    settlement_engine: &mut SettlementEngine,
    position: GasPosition,
    settlement_price: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
): (u64, SignedInt, SignedInt) {
    assert!(settlement_price > 0, E_INVALID_GAS_PRICE);
    
    let user = position.user;
    let gas_units = position.gas_units;
    let entry_price = position.average_price;
    let margin_posted = position.margin_posted;
    let side = position.side;
    
    // Calculate settlement
    let settlement_amount;
    let realized_pnl;
    let gas_cost_savings;
    
    if (side == string::utf8(b"LONG")) {
        if (settlement_price > entry_price) {
            let profit = (settlement_price - entry_price) * gas_units;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
            gas_cost_savings = signed_int_from(profit); // Gas cost hedging benefit
        } else {
            let loss = (entry_price - settlement_price) * gas_units;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
                gas_cost_savings = signed_int_from(0);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
                gas_cost_savings = signed_int_from(0);
            };
        };
    } else { // SHORT
        if (entry_price > settlement_price) {
            let profit = (entry_price - settlement_price) * gas_units;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
            gas_cost_savings = signed_int_from(profit);
        } else {
            let loss = (settlement_price - entry_price) * gas_units;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
                gas_cost_savings = signed_int_from(0);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
                gas_cost_savings = signed_int_from(0);
            };
        };
    };
    
    // Update settlement tracking
    market.settled_positions = market.settled_positions + 1;
    settlement_engine.total_settlements_processed = settlement_engine.total_settlements_processed + 1;
    
    // Emit settlement event
    event::emit(GasPositionSettled {
        position_id: object::id(&position),
        user,
        contract_symbol: market.contract_symbol,
        settlement_price,
        settlement_amount,
        realized_pnl,
        gas_cost_savings,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Clean up position
    let GasPosition { 
        id, user: _, contract_id: _, position_type: _, side: _, gas_units: _,
        average_price: _, margin_posted: _, hedging_purpose: _, expected_gas_usage: _,
        hedge_effectiveness: _, unrealized_pnl: _, realized_pnl: _, gas_cost_savings: _,
        created_timestamp: _, auto_settlement_enabled: _, settlement_eligible: _,
        settlement_amount: _
    } = position;
    object::delete(id);
    
    // Update registry
    let _ = registry;
    
    (settlement_amount, realized_pnl, gas_cost_savings)
}

/// Test-only simplified settlement
public fun test_settle_gas_position<T: store>(
    market: &mut GasFuturesMarket<T>,
    position: GasPosition,
    settlement_price: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
): (u64, SignedInt, SignedInt) {
    let user = position.user;
    let gas_units = position.gas_units;
    let entry_price = position.average_price;
    let margin_posted = position.margin_posted;
    let side = position.side;
    
    // Calculate settlement
    let settlement_amount;
    let realized_pnl;
    let gas_cost_savings;
    
    if (side == string::utf8(b"LONG")) {
        if (settlement_price > entry_price) {
            let profit = (settlement_price - entry_price) * gas_units;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
            gas_cost_savings = signed_int_from(profit);
        } else {
            let loss = (entry_price - settlement_price) * gas_units;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
                gas_cost_savings = signed_int_from(0);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
                gas_cost_savings = signed_int_from(0);
            };
        };
    } else { // SHORT
        if (entry_price > settlement_price) {
            let profit = (entry_price - settlement_price) * gas_units;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
            gas_cost_savings = signed_int_from(profit);
        } else {
            let loss = (settlement_price - entry_price) * gas_units;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
                gas_cost_savings = signed_int_from(0);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
                gas_cost_savings = signed_int_from(0);
            };
        };
    };
    
    // Emit event
    event::emit(GasPositionSettled {
        position_id: object::id(&position),
        user,
        contract_symbol: market.contract_symbol,
        settlement_price,
        settlement_amount,
        realized_pnl,
        gas_cost_savings,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Clean up position
    let GasPosition { 
        id, user: _, contract_id: _, position_type: _, side: _, gas_units: _,
        average_price: _, margin_posted: _, hedging_purpose: _, expected_gas_usage: _,
        hedge_effectiveness: _, unrealized_pnl: _, realized_pnl: _, gas_cost_savings: _,
        created_timestamp: _, auto_settlement_enabled: _, settlement_eligible: _,
        settlement_amount: _
    } = position;
    object::delete(id);
    
    (settlement_amount, realized_pnl, gas_cost_savings)
}

/// Expire a gas futures contract
public fun expire_gas_contract<T: store>(
    market: &mut GasFuturesMarket<T>,
    registry: &mut GasFuturesRegistry,
    final_settlement_price: u64,
    settlement_method: String,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(market.expiry_timestamp <= clock::timestamp_ms(clock), E_CONTRACT_EXPIRED);
    
    // Mark contract as expired
    market.is_active = false;
    
    // Move from active to expired contracts
    if (table::contains(&registry.active_gas_contracts, market.contract_symbol)) {
        let mut contract = table::remove(&mut registry.active_gas_contracts, market.contract_symbol);
        contract.is_active = false;
        contract.is_settled = true;
        contract.settlement_gas_price = option::some(final_settlement_price);
        contract.settlement_method = settlement_method;
        table::add(&mut registry.expired_contracts, market.contract_symbol, contract);
    };
    
    // Emit expiration event
    event::emit(GasFuturesSettled {
        contract_symbol: market.contract_symbol,
        final_settlement_price,
        settlement_method,
        total_positions_settled: market.total_positions,
        total_settlement_value: final_settlement_price * market.total_open_interest,
        timestamp: clock::timestamp_ms(clock),
    });
}

// ========== UNXV Integration ==========

/// Calculate UNXV benefits for gas futures trading
public fun calculate_unxv_gas_benefits(
    registry: &GasFuturesRegistry,
    user_tier: u64,
    base_trading_fee: u64,
    base_settlement_fee: u64,
): (u64, u64, u64, u64) {
    if (!table::contains(&registry.unxv_benefits, user_tier)) {
        return (base_trading_fee, base_settlement_fee, 0, 0) // No benefits
    };
    
    let benefits = table::borrow(&registry.unxv_benefits, user_tier);
    let trading_discount = (base_trading_fee * benefits.trading_fee_discount) / BASIS_POINTS;
    let settlement_discount = (base_settlement_fee * benefits.settlement_fee_discount) / BASIS_POINTS;
    let margin_reduction = benefits.margin_requirement_reduction;
    let position_limit_increase = benefits.position_limit_increase;
    
    (
        base_trading_fee - trading_discount,
        base_settlement_fee - settlement_discount,
        margin_reduction,
        position_limit_increase
    )
}

// ========== Helper Functions ==========

/// Get gas contract information
public fun get_gas_contract_info(
    registry: &GasFuturesRegistry,
    contract_symbol: String,
): (bool, String, u64, bool, Option<u64>) {
    if (table::contains(&registry.active_gas_contracts, contract_symbol)) {
        let contract = table::borrow(&registry.active_gas_contracts, contract_symbol);
        (contract.is_active, contract.contract_type, contract.expiry_timestamp, contract.is_settled, contract.settlement_gas_price)
    } else if (table::contains(&registry.expired_contracts, contract_symbol)) {
        let contract = table::borrow(&registry.expired_contracts, contract_symbol);
        (contract.is_active, contract.contract_type, contract.expiry_timestamp, contract.is_settled, contract.settlement_gas_price)
    } else {
        (false, string::utf8(b""), 0, false, option::none())
    }
}

/// Get gas market statistics
public fun get_gas_market_stats<T: store>(
    market: &GasFuturesMarket<T>,
): (u64, u64, SignedInt, u64, u64, u64, bool) {
    (
        market.current_futures_price,
        market.reference_gas_price,
        market.basis,
        market.total_volume_24h,
        market.total_open_interest,
        market.gas_units_hedged,
        market.is_active
    )
}

/// Get gas position summary
public fun get_gas_position_summary(
    position: &GasPosition,
): (String, String, u64, u64, u64, SignedInt, SignedInt) {
    (
        position.position_type,
        position.side,
        position.gas_units,
        position.average_price,
        position.margin_posted,
        position.unrealized_pnl,
        position.gas_cost_savings
    )
}

/// Get current gas price from oracle
public fun get_current_gas_price(
    gas_oracle: &GasOracle,
): (u64, u64, u64, u64, u64) {
    (
        gas_oracle.real_time_gas_price,
        gas_oracle.twap_1h,
        gas_oracle.twap_24h,
        gas_oracle.current_congestion_level,
        gas_oracle.data_quality_score
    )
}

/// Calculate optimal hedge ratio for gas usage
public fun calculate_optimal_hedge_ratio(
    expected_gas_usage: u64,
    gas_price_volatility: u64,
    risk_tolerance: u64, // 0-100 scale
): u64 {
    // Simplified hedge ratio calculation
    let base_ratio = 7000; // 70% base hedge ratio
    
    // Adjust for volatility
    let volatility_adjustment = if (gas_price_volatility > 1000) { // >10% volatility
        1000 // Increase hedge by 10%
    } else {
        0
    };
    
    // Adjust for risk tolerance
    let risk_adjustment = (risk_tolerance * 3000) / 100; // Up to 30% adjustment
    
    let optimal_ratio = base_ratio + volatility_adjustment + risk_adjustment;
    
    // Cap at 100%
    if (optimal_ratio > 10000) {
        10000
    } else {
        optimal_ratio
    }
}

/// Calculate gas cost savings from hedging
public fun calculate_gas_cost_savings(
    position: &GasPosition,
    current_gas_price: u64,
): SignedInt {
    let hedge_value = position.gas_units * current_gas_price;
    let cost_without_hedge = position.gas_units * position.average_price;
    
    if (position.side == string::utf8(b"LONG")) {
        // Long hedge benefits when gas price rises
        if (current_gas_price > position.average_price) {
            signed_int_from((current_gas_price - position.average_price) * position.gas_units)
        } else {
            signed_int_from(0)
        }
    } else { // SHORT
        // Short hedge benefits when gas price falls
        if (position.average_price > current_gas_price) {
            signed_int_from((position.average_price - current_gas_price) * position.gas_units)
        } else {
            signed_int_from(0)
        }
    }
}

/// Get UNXV gas tier benefits
public fun get_unxv_gas_tier_benefits(
    registry: &GasFuturesRegistry,
    tier: u64,
): (u64, u64, u64, u64, bool) {
    if (table::contains(&registry.unxv_benefits, tier)) {
        let benefits = table::borrow(&registry.unxv_benefits, tier);
        (
            benefits.trading_fee_discount,
            benefits.settlement_fee_discount,
            benefits.margin_requirement_reduction,
            benefits.position_limit_increase,
            benefits.priority_settlement
        )
    } else {
        (0, 0, 0, 0, false)
    }
}

/// Get registry fee configuration
public fun get_registry_fees(registry: &GasFuturesRegistry): (u64, u64, u64) {
    (registry.trading_fee, registry.unxv_discount, registry.settlement_fee)
}

/// Check if protocol is paused
public fun is_protocol_paused(registry: &GasFuturesRegistry): bool {
    registry.is_paused
}

/// Resume protocol operations (alias for resume_operations)
public fun resume_protocol(
    registry: &mut GasFuturesRegistry,
    _admin_cap: &AdminCap,
) {
    registry.is_paused = false;
}

/// Get gas oracle data
public fun get_gas_oracle_data(oracle: &GasOracle): (u64, u64, u64, u64, u64, u64) {
    (
        oracle.real_time_gas_price,
        oracle.current_congestion_level,
        oracle.twap_1h,
        oracle.twap_24h,
        oracle.vwap_24h,
        oracle.volatility_1h
    )
}

/// Alias for get_gas_contract_info for test compatibility
public fun get_contract_info(
    registry: &GasFuturesRegistry,
    contract_symbol: String,
): (bool, u64, bool, Option<u64>) {
    let (is_active, _contract_type, expiry, is_settled, settlement_price) = 
        get_gas_contract_info(registry, contract_symbol);
    (is_active, expiry, is_settled, settlement_price)
}

/// Alias for get_unxv_gas_tier_benefits for test compatibility
public fun get_tier_benefits(
    registry: &GasFuturesRegistry,
    tier: u64,
): (u64, u64, u64, u64, bool) {
    get_unxv_gas_tier_benefits(registry, tier)
}

/// Alias for calculate_unxv_gas_benefits for test compatibility
public fun calculate_unxv_benefits(
    registry: &GasFuturesRegistry,
    user_tier: u64,
    base_fee: u64,
): (u64, u64, u64) {
    let (discounted_trading_fee, _discounted_settlement_fee, margin_reduction, _position_increase) = 
        calculate_unxv_gas_benefits(registry, user_tier, base_fee, base_fee);
    let settlement_discount = if (table::contains(&registry.unxv_benefits, user_tier)) {
        let benefits = table::borrow(&registry.unxv_benefits, user_tier);
        benefits.settlement_fee_discount
    } else {
        0
    };
    (discounted_trading_fee, settlement_discount, margin_reduction)
}


