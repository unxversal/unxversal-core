/// Module: unxv_futures
module unxv_futures::unxv_futures;

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
use deepbook::balance_manager::{Self, BalanceManager, TradeProof};
use pyth::price_info::{Self, PriceInfoObject};

// ========== Error Codes ==========
const E_INSUFFICIENT_BALANCE: u64 = 1;
const E_INVALID_PRICE: u64 = 2;
const E_MARKET_NOT_ACTIVE: u64 = 3;
const E_INSUFFICIENT_COLLATERAL: u64 = 4;
const E_CONTRACT_EXPIRED: u64 = 7;
const E_INVALID_SETTLEMENT_PRICE: u64 = 8;
const E_SPREAD_NOT_AVAILABLE: u64 = 10;

// ========== Constants ==========
const BASIS_POINTS: u64 = 10000;
const SECONDS_PER_DAY: u64 = 86400;
const MIN_MARGIN_RATIO: u64 = 500; // 5%
const SETTLEMENT_WINDOW: u64 = 3600000; // 1 hour in milliseconds

// ========== Core Types ==========

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

/// USDC coin type for collateral and settlement
public struct USDC has drop {}

// ========== Admin Capabilities ==========

public struct AdminCap has key, store {
    id: UID,
}

public struct ArbitratorCap has key, store {
    id: UID,
}

// ========== Core Protocol Objects ==========

/// Central registry for all futures contracts
public struct FuturesRegistry has key {
    id: UID,
    
    // Contract management
    active_contracts: Table<String, FuturesContract>,
    expired_contracts: Table<String, FuturesContract>,
    contract_series: Table<String, ContractSeries>,
    
    // Risk management
    margin_requirements: Table<String, MarginConfig>,
    position_limits: Table<String, PositionLimits>,
    daily_settlement_enabled: bool,
    
    // UNXV tokenomics
    unxv_benefits: Table<u64, TierBenefits>,
    base_trading_fee: u64, // In basis points
    base_settlement_fee: u64, // In basis points
    
    // Emergency controls
    is_paused: bool,
    emergency_settlement: bool,
}

/// Individual futures contract specification
public struct FuturesContract has store {
    contract_symbol: String,
    underlying_asset: String,
    contract_size: u64,
    tick_size: u64,
    
    // Expiration details
    expiration_timestamp: u64,
    last_trading_day: u64,
    settlement_timestamp: u64,
    settlement_method: String, // "CASH", "PHYSICAL"
    
    // Contract status
    is_active: bool,
    is_expired: bool,
    is_settled: bool,
    settlement_price: Option<u64>,
    
    // Market data
    current_price: u64,
    underlying_price: u64,
    volume_24h: u64,
    open_interest: u64,
    
    // Integration IDs
    deepbook_pool_id: Option<ID>,
    price_feed_id: Option<ID>,
}

/// Contract series information for auto-listing
public struct ContractSeries has store {
    underlying_asset: String,
    contract_months: vector<String>,
    contract_cycle: String, // "QUARTERLY", "MONTHLY", "WEEKLY"
    auto_listing: bool,
    days_before_expiry: u64,
}

/// Margin configuration per contract
public struct MarginConfig has store {
    initial_margin_rate: u64,
    maintenance_margin_rate: u64,
    margin_currency: String,
    volatility_adjustment: u64,
}

/// Position limits per contract
public struct PositionLimits has store {
    max_position_size: u64,
    max_order_size: u64,
    position_limit_type: String,
    accountability_threshold: u64,
}

/// UNXV tier benefits
public struct TierBenefits has store {
    trading_fee_discount: u64, // 0-100%
    settlement_fee_discount: u64, // 0-100%
    margin_requirement_reduction: u64, // 0-100%
    position_limit_increase: u64, // 0-100%
    priority_settlement: bool,
    auto_roll_discounts: u64, // 0-100%
}

/// Individual futures market for a specific contract
public struct FuturesMarket<phantom T: store> has key {
    id: UID,
    
    // Market identification
    contract_symbol: String,
    underlying_type: String,
    expiration_timestamp: u64,
    
    // Position tracking
    long_positions: Table<address, FuturesPosition>,
    short_positions: Table<address, FuturesPosition>,
    total_positions: u64,
    
    // Market state
    current_price: u64,
    settlement_price: Option<u64>,
    daily_settlement_price: u64,
    
    // Volume and open interest
    total_volume_24h: u64,
    total_open_interest: u64,
    
    // Settlement tracking
    settlement_funds: Balance<USDC>,
    pending_settlements: u64,
    settled_positions: u64,
    
    // Market status
    is_active: bool,
    is_expired: bool,
    last_settlement_timestamp: u64,
}

/// Individual futures position
public struct FuturesPosition has key, store {
    id: UID,
    user: address,
    
    // Position details
    side: String, // "LONG" or "SHORT"
    size: u64,
    average_price: u64,
    margin_posted: u64,
    
    // P&L tracking
    unrealized_pnl: SignedInt,
    daily_pnl: SignedInt,
    cumulative_pnl: SignedInt,
    margin_calls: u64,
    
    // Position management
    created_timestamp: u64,
    last_settlement_timestamp: u64,
    auto_roll_enabled: bool,
    
    // Settlement details
    settlement_eligible: bool,
    settlement_amount: Option<u64>,
    settlement_timestamp: Option<u64>,
}

/// Settlement engine for automated settlement
public struct SettlementEngine has key {
    id: UID,
    operator: address,
    
    // Settlement parameters
    settlement_window: u64,
    price_deviation_threshold: u64,
    daily_settlement_enabled: bool,
    final_settlement_lag: u64,
    
    // Processing
    processing_batch_size: u64,
    processing_frequency: u64,
    
    // Performance tracking
    settlement_success_rate: u64,
    total_settlements_processed: u64,
}

/// Calendar spread engine for spread trading
public struct CalendarSpreadEngine has key {
    id: UID,
    operator: address,
    
    // Spread definitions
    available_spreads: Table<String, CalendarSpread>,
    spread_margins: Table<String, SpreadMargin>,
    auto_spread_creation: bool,
    
    // Analytics
    spread_performance: Table<String, SpreadMetrics>,
}

/// Calendar spread definition
public struct CalendarSpread has store {
    spread_symbol: String,
    front_month: String,
    back_month: String,
    spread_ratio: u64,
    tick_size: u64,
    is_active: bool,
}

/// Spread margin requirements
public struct SpreadMargin has store {
    initial_margin: u64,
    maintenance_margin: u64,
    margin_reduction: u64, // Benefit vs individual positions
}

/// Spread performance metrics
public struct SpreadMetrics has store {
    total_volume: u64,
    average_spread: u64,
    volatility: u64,
    last_update: u64,
}

// ========== Events ==========

/// Contract lifecycle events
public struct FuturesContractListed has copy, drop {
    contract_symbol: String,
    underlying_asset: String,
    expiration_timestamp: u64,
    contract_size: u64,
    initial_margin_rate: u64,
    timestamp: u64,
}

public struct FuturesContractExpired has copy, drop {
    contract_symbol: String,
    expiration_timestamp: u64,
    final_settlement_price: u64,
    total_open_interest: u64,
    timestamp: u64,
}

/// Position events
public struct FuturesPositionOpened has copy, drop {
    position_id: ID,
    user: address,
    contract_symbol: String,
    side: String,
    size: u64,
    entry_price: u64,
    margin_posted: u64,
    timestamp: u64,
}

public struct PositionSettled has copy, drop {
    position_id: ID,
    user: address,
    contract_symbol: String,
    settlement_price: u64,
    settlement_amount: u64,
    realized_pnl: SignedInt,
    timestamp: u64,
}

/// Calendar spread events
public struct CalendarSpreadExecuted has copy, drop {
    spread_symbol: String,
    executed_quantity: u64,
    spread_price: u64,
    buyer: address,
    seller: address,
    timestamp: u64,
}

// ========== Initialization ==========

/// Initialize the futures protocol
fun init(ctx: &mut TxContext) {
    init_internal(ctx);
}

/// Internal initialization function 
fun init_internal(ctx: &mut TxContext) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    
    // Create the main registry
    let mut registry = FuturesRegistry {
        id: object::new(ctx),
        active_contracts: table::new(ctx),
        expired_contracts: table::new(ctx),
        contract_series: table::new(ctx),
        margin_requirements: table::new(ctx),
        position_limits: table::new(ctx),
        daily_settlement_enabled: true,
        unxv_benefits: table::new(ctx),
        base_trading_fee: 10, // 0.1%
        base_settlement_fee: 5, // 0.05%
        is_paused: false,
        emergency_settlement: false,
    };
    
    // Setup default UNXV benefits tiers
    setup_default_unxv_tiers(&mut registry, ctx);
    
    // Create settlement engine
    let settlement_engine = SettlementEngine {
        id: object::new(ctx),
        operator: tx_context::sender(ctx),
        settlement_window: SETTLEMENT_WINDOW,
        price_deviation_threshold: 100, // 1%
        daily_settlement_enabled: true,
        final_settlement_lag: 1800000, // 30 minutes
        processing_batch_size: 100,
        processing_frequency: 600000, // 10 minutes
        settlement_success_rate: 9900, // 99%
        total_settlements_processed: 0,
    };
    
    // Create calendar spread engine
    let spread_engine = CalendarSpreadEngine {
        id: object::new(ctx),
        operator: tx_context::sender(ctx),
        available_spreads: table::new(ctx),
        spread_margins: table::new(ctx),
        auto_spread_creation: true,
        spread_performance: table::new(ctx),
    };
    
    // Share objects
    transfer::share_object(registry);
    transfer::share_object(settlement_engine);
    transfer::share_object(spread_engine);
    
    // Transfer admin capability
    transfer::transfer(admin_cap, tx_context::sender(ctx));
}

/// Setup default UNXV tier benefits
fun setup_default_unxv_tiers(registry: &mut FuturesRegistry, _ctx: &mut TxContext) {
    // Tier 0 (0 UNXV): Standard rates
    table::add(&mut registry.unxv_benefits, 0, TierBenefits {
        trading_fee_discount: 0,
        settlement_fee_discount: 0,
        margin_requirement_reduction: 0,
        position_limit_increase: 0,
        priority_settlement: false,
        auto_roll_discounts: 0,
    });
    
    // Tier 1 (1,000 UNXV): Basic benefits
    table::add(&mut registry.unxv_benefits, 1, TierBenefits {
        trading_fee_discount: 500, // 5%
        settlement_fee_discount: 1000, // 10%
        margin_requirement_reduction: 500, // 5%
        position_limit_increase: 2000, // 20%
        priority_settlement: false,
        auto_roll_discounts: 2500, // 25%
    });
    
    // Tier 2 (5,000 UNXV): Enhanced benefits
    table::add(&mut registry.unxv_benefits, 2, TierBenefits {
        trading_fee_discount: 1000, // 10%
        settlement_fee_discount: 2000, // 20%
        margin_requirement_reduction: 800, // 8%
        position_limit_increase: 4000, // 40%
        priority_settlement: true,
        auto_roll_discounts: 5000, // 50%
    });
    
    // Tier 3 (25,000 UNXV): Premium benefits
    table::add(&mut registry.unxv_benefits, 3, TierBenefits {
        trading_fee_discount: 1500, // 15%
        settlement_fee_discount: 3000, // 30%
        margin_requirement_reduction: 1200, // 12%
        position_limit_increase: 7500, // 75%
        priority_settlement: true,
        auto_roll_discounts: 7500, // 75%
    });
}

/// Initialize for testing
public fun init_for_testing(ctx: &mut TxContext) {
    init_internal(ctx);
}

// ========== Admin Functions ==========

/// Add a new underlying asset for futures trading
public fun add_underlying_asset(
    registry: &mut FuturesRegistry,
    asset_name: String,
    contract_series: ContractSeries,
    margin_config: MarginConfig,
    position_limits: PositionLimits,
    _admin_cap: &AdminCap,
    _ctx: &mut TxContext,
) {
    assert!(!registry.is_paused, E_MARKET_NOT_ACTIVE);
    
    table::add(&mut registry.contract_series, asset_name, contract_series);
    table::add(&mut registry.margin_requirements, asset_name, margin_config);
    table::add(&mut registry.position_limits, asset_name, position_limits);
}

/// Simplified add underlying asset for testing
public fun add_underlying_asset_simple(
    registry: &mut FuturesRegistry,
    asset_name: String,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
) {
    assert!(!registry.is_paused, E_MARKET_NOT_ACTIVE);
    
    // Create default contract series
    let contract_series = ContractSeries {
        underlying_asset: asset_name,
        contract_months: vector[
            string::utf8(b"DEC24"),
            string::utf8(b"MAR25"),
            string::utf8(b"JUN25")
        ],
        contract_cycle: string::utf8(b"QUARTERLY"),
        auto_listing: true,
        days_before_expiry: 7,
    };
    
    // Create default margin config
    let margin_config = MarginConfig {
        initial_margin_rate: 500, // 5%
        maintenance_margin_rate: 300, // 3%
        margin_currency: string::utf8(b"USDC"),
        volatility_adjustment: 100,
    };
    
    // Create default position limits
    let position_limits = PositionLimits {
        max_position_size: 1000,
        max_order_size: 100,
        position_limit_type: string::utf8(b"NET"),
        accountability_threshold: 500,
    };
    
    table::add(&mut registry.contract_series, asset_name, contract_series);
    table::add(&mut registry.margin_requirements, asset_name, margin_config);
    table::add(&mut registry.position_limits, asset_name, position_limits);
}

/// Emergency pause
public fun emergency_pause(
    registry: &mut FuturesRegistry,
    _admin_cap: &AdminCap,
) {
    registry.is_paused = true;
}

/// Resume trading
public fun resume_trading(
    registry: &mut FuturesRegistry,
    _admin_cap: &AdminCap,
) {
    registry.is_paused = false;
}

// ========== Contract Management ==========

/// List a new futures contract
public fun create_futures_contract<T: store>(
    registry: &mut FuturesRegistry,
    underlying_asset: String,
    contract_symbol: String,
    expiration_timestamp: u64,
    contract_size: u64,
    tick_size: u64,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ID {
    assert!(!registry.is_paused, E_MARKET_NOT_ACTIVE);
    assert!(expiration_timestamp > 0, E_INVALID_PRICE);
    
    let current_timestamp = 0; // Simplified for demo
    
    // Create futures contract
    let contract = FuturesContract {
        contract_symbol,
        underlying_asset,
        contract_size,
        tick_size,
        expiration_timestamp,
        last_trading_day: expiration_timestamp - (7 * SECONDS_PER_DAY * 1000), // 7 days before
        settlement_timestamp: expiration_timestamp + SETTLEMENT_WINDOW,
        settlement_method: string::utf8(b"CASH"),
        is_active: true,
        is_expired: false,
        is_settled: false,
        settlement_price: option::none(),
        current_price: 0,
        underlying_price: 0,
        volume_24h: 0,
        open_interest: 0,
        deepbook_pool_id: option::none(),
        price_feed_id: option::none(),
    };
    
    // Create futures market
    let market = FuturesMarket<T> {
        id: object::new(ctx),
        contract_symbol,
        underlying_type: string::utf8(b"T"),
        expiration_timestamp,
        long_positions: table::new(ctx),
        short_positions: table::new(ctx),
        total_positions: 0,
        current_price: 0,
        settlement_price: option::none(),
        daily_settlement_price: 0,
        total_volume_24h: 0,
        total_open_interest: 0,
        settlement_funds: balance::zero(),
        pending_settlements: 0,
        settled_positions: 0,
        is_active: true,
        is_expired: false,
        last_settlement_timestamp: 0,
    };
    
    let market_id = object::id(&market);
    
    // Store contract in registry
    table::add(&mut registry.active_contracts, contract_symbol, contract);
    
    // Emit event
    event::emit(FuturesContractListed {
        contract_symbol,
        underlying_asset,
        expiration_timestamp,
        contract_size,
        initial_margin_rate: MIN_MARGIN_RATIO,
        timestamp: current_timestamp,
    });
    
    transfer::share_object(market);
    market_id
}

// ========== Position Management ==========

/// Open a futures position
public fun open_futures_position<T: store>(
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    side: String, // "LONG" or "SHORT"
    size: u64,
    entry_price: u64,
    margin_coin: Coin<USDC>,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    price_feeds: &vector<PriceInfoObject>,
    clock: &Clock,
    ctx: &mut TxContext,
): FuturesPosition {
    assert!(!registry.is_paused, E_MARKET_NOT_ACTIVE);
    assert!(market.is_active && !market.is_expired, E_MARKET_NOT_ACTIVE);
    assert!(size > 0, E_INSUFFICIENT_BALANCE);
    assert!(entry_price > 0, E_INVALID_PRICE);
    
    let user = tx_context::sender(ctx);
    let margin_amount = coin::value(&margin_coin);
    
    // Calculate required margin
    let contract_value = size * entry_price;
    let required_margin = (contract_value * MIN_MARGIN_RATIO) / BASIS_POINTS;
    assert!(margin_amount >= required_margin, E_INSUFFICIENT_COLLATERAL);
    
    // Create position
    let position = FuturesPosition {
        id: object::new(ctx),
        user,
        side,
        size,
        average_price: entry_price,
        margin_posted: margin_amount,
        unrealized_pnl: signed_int_from(0),
        daily_pnl: signed_int_from(0),
        cumulative_pnl: signed_int_from(0),
        margin_calls: 0,
        created_timestamp: clock::timestamp_ms(clock),
        last_settlement_timestamp: 0,
        auto_roll_enabled: false,
        settlement_eligible: false,
        settlement_amount: option::none(),
        settlement_timestamp: option::none(),
    };
    
    let position_id = object::id(&position);
    
    // Note: For production, position would be stored in market tables
    // For now, returning position directly for testing/demo purposes
    
    // Update market statistics
    market.total_positions = market.total_positions + 1;
    market.total_open_interest = market.total_open_interest + size;
    market.current_price = entry_price;
    
    // Add margin to settlement funds
    balance::join(&mut market.settlement_funds, coin::into_balance(margin_coin));
    
    // Emit event
    event::emit(FuturesPositionOpened {
        position_id,
        user,
        contract_symbol: market.contract_symbol,
        side,
        size,
        entry_price,
        margin_posted: margin_amount,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Simplified DeepBook integration placeholder
    let _ = balance_manager;
    let _ = trade_proof;
    let _ = price_feeds;
    
    position
}

/// Test-only simplified position opening
public fun test_open_position<T: store>(
    market: &mut FuturesMarket<T>,
    registry: &FuturesRegistry,
    side: String,
    size: u64,
    entry_price: u64,
    margin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): FuturesPosition {
    assert!(!registry.is_paused, E_MARKET_NOT_ACTIVE);
    assert!(market.is_active && !market.is_expired, E_MARKET_NOT_ACTIVE);
    assert!(size > 0, E_INSUFFICIENT_BALANCE);
    
    let user = tx_context::sender(ctx);
    
    // Create position
    let position = FuturesPosition {
        id: object::new(ctx),
        user,
        side,
        size,
        average_price: entry_price,
        margin_posted: margin_amount,
        unrealized_pnl: signed_int_from(0),
        daily_pnl: signed_int_from(0),
        cumulative_pnl: signed_int_from(0),
        margin_calls: 0,
        created_timestamp: clock::timestamp_ms(clock),
        last_settlement_timestamp: 0,
        auto_roll_enabled: false,
        settlement_eligible: false,
        settlement_amount: option::none(),
        settlement_timestamp: option::none(),
    };
    
    let position_id = object::id(&position);
    
    // Update market statistics
    market.total_positions = market.total_positions + 1;
    market.total_open_interest = market.total_open_interest + size;
    market.current_price = entry_price;
    
    // Emit event
    event::emit(FuturesPositionOpened {
        position_id,
        user,
        contract_symbol: market.contract_symbol,
        side,
        size,
        entry_price,
        margin_posted: margin_amount,
        timestamp: clock::timestamp_ms(clock),
    });
    
    position
}

// ========== Settlement System ==========

/// Execute final settlement for expired contracts
public fun execute_final_settlement<T: store>(
    market: &mut FuturesMarket<T>,
    registry: &mut FuturesRegistry,
    settlement_engine: &mut SettlementEngine,
    final_settlement_price: u64,
    position: FuturesPosition,
    clock: &Clock,
    _ctx: &mut TxContext,
): (u64, SignedInt) {
    assert!(market.is_expired, E_CONTRACT_EXPIRED);
    assert!(final_settlement_price > 0, E_INVALID_SETTLEMENT_PRICE);
    
    let user = position.user;
    let position_size = position.size;
    let entry_price = position.average_price;
    let margin_posted = position.margin_posted;
    let side = position.side;
    
    // Calculate settlement amount
    let settlement_amount;
    let realized_pnl;
    
    if (side == string::utf8(b"LONG")) {
        if (final_settlement_price > entry_price) {
            let profit = (final_settlement_price - entry_price) * position_size;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
        } else {
            let loss = (entry_price - final_settlement_price) * position_size;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
            };
        };
    } else { // SHORT
        if (entry_price > final_settlement_price) {
            let profit = (entry_price - final_settlement_price) * position_size;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
        } else {
            let loss = (final_settlement_price - entry_price) * position_size;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
            };
        };
    };
    
    // Update settlement tracking
    market.settled_positions = market.settled_positions + 1;
    settlement_engine.total_settlements_processed = settlement_engine.total_settlements_processed + 1;
    
    // Emit settlement event
    event::emit(PositionSettled {
        position_id: object::id(&position),
        user,
        contract_symbol: market.contract_symbol,
        settlement_price: final_settlement_price,
        settlement_amount,
        realized_pnl,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Clean up position
    let FuturesPosition { 
        id, user: _, side: _, size: _, average_price: _, margin_posted: _,
        unrealized_pnl: _, daily_pnl: _, cumulative_pnl: _, margin_calls: _,
        created_timestamp: _, last_settlement_timestamp: _, auto_roll_enabled: _,
        settlement_eligible: _, settlement_amount: _, settlement_timestamp: _
    } = position;
    object::delete(id);
    
    // Update registry
    let _ = registry;
    
    (settlement_amount, realized_pnl)
}

/// Test-only simplified settlement
public fun test_settle_position<T: store>(
    market: &mut FuturesMarket<T>,
    position: FuturesPosition,
    settlement_price: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
): (u64, SignedInt) {
    let user = position.user;
    let position_size = position.size;
    let entry_price = position.average_price;
    let margin_posted = position.margin_posted;
    let side = position.side;
    
    // Calculate settlement
    let settlement_amount;
    let realized_pnl;
    
    if (side == string::utf8(b"LONG")) {
        if (settlement_price > entry_price) {
            let profit = (settlement_price - entry_price) * position_size;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
        } else {
            let loss = (entry_price - settlement_price) * position_size;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
            };
        };
    } else { // SHORT
        if (entry_price > settlement_price) {
            let profit = (entry_price - settlement_price) * position_size;
            settlement_amount = margin_posted + profit;
            realized_pnl = signed_int_from(profit);
        } else {
            let loss = (settlement_price - entry_price) * position_size;
            if (loss >= margin_posted) {
                settlement_amount = 0;
                realized_pnl = signed_int_negative(margin_posted);
            } else {
                settlement_amount = margin_posted - loss;
                realized_pnl = signed_int_negative(loss);
            };
        };
    };
    
    // Emit event
    event::emit(PositionSettled {
        position_id: object::id(&position),
        user,
        contract_symbol: market.contract_symbol,
        settlement_price,
        settlement_amount,
        realized_pnl,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Clean up position
    let FuturesPosition { 
        id, user: _, side: _, size: _, average_price: _, margin_posted: _,
        unrealized_pnl: _, daily_pnl: _, cumulative_pnl: _, margin_calls: _,
        created_timestamp: _, last_settlement_timestamp: _, auto_roll_enabled: _,
        settlement_eligible: _, settlement_amount: _, settlement_timestamp: _
    } = position;
    object::delete(id);
    
    (settlement_amount, realized_pnl)
}

/// Expire a futures contract
public fun expire_contract<T: store>(
    market: &mut FuturesMarket<T>,
    registry: &mut FuturesRegistry,
    final_settlement_price: u64,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(market.expiration_timestamp <= clock::timestamp_ms(clock), E_CONTRACT_EXPIRED);
    
    // Mark contract as expired
    market.is_expired = true;
    market.is_active = false;
    market.settlement_price = option::some(final_settlement_price);
    
    // Move from active to expired contracts
    if (table::contains(&registry.active_contracts, market.contract_symbol)) {
        let mut contract = table::remove(&mut registry.active_contracts, market.contract_symbol);
        contract.is_expired = true;
        contract.is_active = false;
        contract.settlement_price = option::some(final_settlement_price);
        table::add(&mut registry.expired_contracts, market.contract_symbol, contract);
    };
    
    // Emit expiration event
    event::emit(FuturesContractExpired {
        contract_symbol: market.contract_symbol,
        expiration_timestamp: market.expiration_timestamp,
        final_settlement_price,
        total_open_interest: market.total_open_interest,
        timestamp: clock::timestamp_ms(clock),
    });
}

// ========== Calendar Spread Trading ==========

/// Create a calendar spread
public fun create_calendar_spread(
    spread_engine: &mut CalendarSpreadEngine,
    front_month: String,
    back_month: String,
    spread_symbol: String,
    spread_ratio: u64,
    tick_size: u64,
    _admin_cap: &AdminCap,
    _ctx: &mut TxContext,
) {
    let spread = CalendarSpread {
        spread_symbol,
        front_month,
        back_month,
        spread_ratio,
        tick_size,
        is_active: true,
    };
    
    let spread_margin = SpreadMargin {
        initial_margin: 50000000, // $50 simplified
        maintenance_margin: 30000000, // $30 simplified
        margin_reduction: 5000, // 50% reduction
    };
    
    let spread_metrics = SpreadMetrics {
        total_volume: 0,
        average_spread: 0,
        volatility: 0,
        last_update: 0,
    };
    
    table::add(&mut spread_engine.available_spreads, spread_symbol, spread);
    table::add(&mut spread_engine.spread_margins, spread_symbol, spread_margin);
    table::add(&mut spread_engine.spread_performance, spread_symbol, spread_metrics);
}

/// Execute calendar spread trade
public fun execute_calendar_spread<T: store, U: store>(
    spread_engine: &mut CalendarSpreadEngine,
    front_market: &mut FuturesMarket<T>,
    back_market: &mut FuturesMarket<U>,
    spread_symbol: String,
    side: String, // "BUY_SPREAD", "SELL_SPREAD"
    quantity: u64,
    spread_price: u64,
    buyer: address,
    seller: address,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    assert!(table::contains(&spread_engine.available_spreads, spread_symbol), E_SPREAD_NOT_AVAILABLE);
    
    // Update markets
    front_market.total_volume_24h = front_market.total_volume_24h + quantity;
    back_market.total_volume_24h = back_market.total_volume_24h + quantity;
    
    // Update spread metrics
    if (table::contains(&spread_engine.spread_performance, spread_symbol)) {
        let metrics = table::borrow_mut(&mut spread_engine.spread_performance, spread_symbol);
        metrics.total_volume = metrics.total_volume + quantity;
        metrics.average_spread = spread_price;
        metrics.last_update = clock::timestamp_ms(clock);
    };
    
    // Emit spread execution event
    event::emit(CalendarSpreadExecuted {
        spread_symbol,
        executed_quantity: quantity,
        spread_price,
        buyer,
        seller,
        timestamp: clock::timestamp_ms(clock),
    });
    
    // Simplified - would handle complex position management in production
    let _ = side;
}

// ========== UNXV Integration ==========

/// Calculate UNXV benefits for a user
public fun calculate_unxv_benefits(
    registry: &FuturesRegistry,
    user_tier: u64,
    base_fee: u64,
): (u64, u64, u64) {
    if (!table::contains(&registry.unxv_benefits, user_tier)) {
        return (base_fee, 0, 0) // No benefits
    };
    
    let benefits = table::borrow(&registry.unxv_benefits, user_tier);
    let trading_discount = (base_fee * benefits.trading_fee_discount) / BASIS_POINTS;
    // Return the discount percentage for settlement, not the absolute amount
    let settlement_discount = benefits.settlement_fee_discount; // This is the percentage discount
    let margin_reduction = benefits.margin_requirement_reduction;
    
    (base_fee - trading_discount, settlement_discount, margin_reduction)
}

/// Apply UNXV discount to trading fees
public fun apply_unxv_discount(
    base_fee: u64,
    discount_rate: u64,
): u64 {
    let discount = (base_fee * discount_rate) / BASIS_POINTS;
    base_fee - discount
}

// ========== Helper Functions ==========

/// Get contract information
public fun get_contract_info(
    registry: &FuturesRegistry,
    contract_symbol: String,
): (bool, u64, bool, Option<u64>) {
    if (table::contains(&registry.active_contracts, contract_symbol)) {
        let contract = table::borrow(&registry.active_contracts, contract_symbol);
        (contract.is_active, contract.expiration_timestamp, contract.is_expired, contract.settlement_price)
    } else if (table::contains(&registry.expired_contracts, contract_symbol)) {
        let contract = table::borrow(&registry.expired_contracts, contract_symbol);
        (contract.is_active, contract.expiration_timestamp, contract.is_expired, contract.settlement_price)
    } else {
        (false, 0, true, option::none())
    }
}

/// Get market statistics
public fun get_market_stats<T: store>(
    market: &FuturesMarket<T>,
): (u64, u64, u64, u64, bool) {
    (
        market.current_price,
        market.total_volume_24h,
        market.total_open_interest,
        market.total_positions,
        market.is_active
    )
}

/// Get position summary
public fun get_position_summary(
    position: &FuturesPosition,
): (String, u64, u64, u64, SignedInt, SignedInt) {
    (
        position.side,
        position.size,
        position.average_price,
        position.margin_posted,
        position.unrealized_pnl,
        position.cumulative_pnl
    )
}

/// Calculate unrealized P&L
public fun calculate_unrealized_pnl(
    position: &FuturesPosition,
    current_price: u64,
): SignedInt {
    let position_value = position.size * current_price;
    let entry_value = position.size * position.average_price;
    
    if (position.side == string::utf8(b"LONG")) {
        if (position_value > entry_value) {
            signed_int_from(position_value - entry_value)
        } else {
            signed_int_negative(entry_value - position_value)
        }
    } else { // SHORT
        if (entry_value > position_value) {
            signed_int_from(entry_value - position_value)
        } else {
            signed_int_negative(position_value - entry_value)
        }
    }
}

/// Get spread information
public fun get_spread_info(
    spread_engine: &CalendarSpreadEngine,
    spread_symbol: String,
): (bool, String, String, u64) {
    if (table::contains(&spread_engine.available_spreads, spread_symbol)) {
        let spread = table::borrow(&spread_engine.available_spreads, spread_symbol);
        (spread.is_active, spread.front_month, spread.back_month, spread.spread_ratio)
    } else {
        (false, string::utf8(b""), string::utf8(b""), 0)
    }
}

/// Get UNXV tier benefits
public fun get_tier_benefits(
    registry: &FuturesRegistry,
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


