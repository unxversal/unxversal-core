/// UnXversal Spot DEX - Advanced trading aggregation layer built on DeepBook
/// Provides sophisticated order types, cross-asset routing, MEV protection, and 
/// seamless integration with the broader UnXversal ecosystem
module unxv_dex::unxv_dex {
    use std::string::{Self, String};
    use std::vector;
    use std::option::{Self, Option};
    
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    
    // use deepbook::pool::{Self as deepbook_pool, Pool};
    // use deepbook::registry::{Registry as DeepBookRegistry};
    // use pyth::price_info::{PriceInfoObject};
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const MAX_HOPS: u8 = 3;
    const DEFAULT_SLIPPAGE_TOLERANCE: u64 = 300; // 3%
    
    // ========== Error Codes ==========
    
    const E_NOT_ADMIN: u64 = 1;
    const E_POOL_NOT_FOUND: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_SLIPPAGE_EXCEEDED: u64 = 4;
    const E_INVALID_ROUTE: u64 = 5;
    const E_POOL_INACTIVE: u64 = 6;
    const E_INVALID_ORDER_TYPE: u64 = 7;
    const E_INSUFFICIENT_OUTPUT: u64 = 8;
    const E_ORDER_NOT_FOUND: u64 = 9;
    const E_UNAUTHORIZED: u64 = 10;
    const E_INVALID_ASSET_PAIR: u64 = 11;
    const E_MAX_HOPS_EXCEEDED: u64 = 12;
    const E_ROUTE_NOT_VIABLE: u64 = 13;
    const E_SYSTEM_PAUSED: u64 = 14;
    
    // ========== Core Data Structures ==========
    
    /// Central DEX registry for pool management and configuration
    public struct DEXRegistry has key {
        id: UID,
        supported_pools: Table<String, PoolInfo>,     // "ASSET1_ASSET2" -> pool info
        fee_structure: FeeStructure,                  // Basic fee configuration
        admin_cap: Option<AdminCap>,                  // Admin controls
        cross_asset_router: Option<ID>,               // Router service ID
        mev_protector: Option<ID>,                    // MEV protection service ID
        is_paused: bool,                              // Emergency pause
        total_volume: u64,                            // Total trading volume
        total_fees_collected: u64,                    // Total fees collected
    }
    
    /// Information about supported trading pools
    public struct PoolInfo has store {
        base_asset: String,           // Base asset symbol
        quote_asset: String,          // Quote asset symbol
        deepbook_pool_id: ID,         // DeepBook pool ID for this pair
        is_active: bool,              // Whether trading is enabled
        volume_24h: u64,              // 24-hour volume
        fees_collected_24h: u64,      // 24-hour fees
        last_price: u64,              // Last trade price
        price_change_24h: u64,        // 24-hour price change (absolute value)
    }
    
    /// Fee structure configuration
    public struct FeeStructure has store, drop {
        base_trading_fee: u64,        // 30 basis points (0.3%)
        unxv_discount: u64,           // 20% discount for UNXV payments
        routing_fee: u64,             // Additional fee for cross-asset routing
        maker_rebate: u64,            // Rebate for liquidity providers
        max_fee: u64,                 // Maximum fee cap
    }
    
    /// Admin capability for registry management
    public struct AdminCap has key, store {
        id: UID,
    }
    
    /// Individual trade order for immediate execution
    public struct SimpleTradeOrder has key {
        id: UID,
        trader: address,
        input_asset: String,          // Asset being sold
        output_asset: String,         // Asset being bought
        input_amount: u64,            // Amount of input asset
        min_output_amount: u64,       // Minimum acceptable output (slippage protection)
        fee_payment_asset: String,    // Asset used for fee payment
        order_type: String,           // "MARKET", "LIMIT", "STOP_LOSS", "TAKE_PROFIT"
        status: String,               // "PENDING", "EXECUTED", "CANCELLED"
        created_at: u64,              // Order creation timestamp
        expires_at: Option<u64>,      // Order expiration
    }
    
    /// Cross-asset execution for multi-hop trades
    public struct CrossAssetExecution has key {
        id: UID,
        trader: address,
        route_hops: vector<RouteHop>, // Pre-calculated route
        total_input: u64,             // Total input amount
        min_final_output: u64,        // Minimum acceptable final output
        fee_payment_asset: String,    // Asset used for fee payment
        status: String,               // "PENDING", "EXECUTING", "COMPLETED", "FAILED"
        hops_completed: u8,           // Number of hops executed
        actual_output: u64,           // Actual final output
        total_fees_paid: u64,         // Total fees paid
        slippage: u64,                // Actual slippage experienced
        created_at: u64,              // Execution timestamp
    }
    
    /// Individual hop in a cross-asset route
    public struct RouteHop has store, drop {
        from_asset: String,           // Source asset for this hop
        to_asset: String,             // Destination asset for this hop
        deepbook_pool_id: ID,         // DeepBook pool for this hop
        expected_input: u64,          // Expected input amount for this hop
        min_output: u64,              // Minimum output for this hop
        executed: bool,               // Whether this hop has been executed
        actual_output: u64,           // Actual output from this hop
    }
    
    /// Cross-asset route calculation result
    public struct CrossAssetRoute has drop {
        path: vector<String>,          // ["sETH", "USDC", "sBTC"]
        pool_ids: vector<ID>,          // Corresponding DeepBook pool IDs
        estimated_output: u64,
        total_fees: u64,
        hops_required: u8,
        route_viability: u64,          // Confidence score (0-10000)
    }
    
    /// Trading session for managing user state
    public struct TradingSession has key {
        id: UID,
        trader: address,
        active_orders: VecSet<ID>,     // Active order IDs
        order_history: vector<ID>,     // Historical order IDs
        total_volume_traded: u64,      // Total volume traded
        total_fees_paid: u64,          // Total fees paid
        unxv_fees_saved: u64,          // UNXV discount savings
        session_start: u64,            // Session start time
        last_activity: u64,            // Last activity timestamp
    }
    
    /// Fee breakdown for transparency
    public struct FeeBreakdown has drop {
        base_trading_fee: u64,
        routing_fee: u64,
        order_type_fee: u64,
        total_fee_before_discount: u64,
        unxv_discount: u64,
        final_fee: u64,
        fee_asset: String,
    }
    
    /// Trade execution result
    public struct TradeResult has drop {
        success: bool,
        order_id: ID,
        input_amount: u64,
        output_amount: u64,
        fees_paid: u64,
        slippage: u64,
        execution_time_ms: u64,
        deepbook_fills: vector<ID>,    // Underlying DeepBook fill IDs
    }
    
    /// Arbitrage opportunity detection
    public struct ArbitrageOpportunity has drop {
        path: vector<String>,         // ["USDC", "sETH", "sBTC", "USDC"]
        pool_ids: vector<ID>,
        profit_amount: u64,
        profit_percentage: u64,
        required_capital: u64,
        time_sensitivity: u64,
        risk_score: u64,
    }
    
    // ========== Events ==========
    
    /// Order management events
    public struct OrderCreated has copy, drop {
        order_id: ID,
        trader: address,
        order_type: String,
        input_asset: String,
        output_asset: String,
        input_amount: u64,
        min_output_amount: u64,
        fee_payment_asset: String,
        routing_path: vector<String>,
        timestamp: u64,
    }
    
    public struct OrderExecuted has copy, drop {
        order_id: ID,
        trader: address,
        input_amount: u64,
        output_amount: u64,
        fees_paid: u64,
        fee_asset: String,
        slippage: u64,
        deepbook_fills: vector<ID>,
        timestamp: u64,
    }
    
    public struct OrderCancelled has copy, drop {
        order_id: ID,
        trader: address,
        reason: String,
        timestamp: u64,
    }
    
    /// Cross-asset routing events
    public struct CrossAssetRouteCalculated has copy, drop {
        request_id: ID,
        input_asset: String,
        output_asset: String,
        input_amount: u64,
        routing_path: vector<String>,
        estimated_output: u64,
        total_fees: u64,
        hops_required: u8,
        calculation_time_ms: u64,
        timestamp: u64,
    }
    
    public struct CrossAssetTradeExecuted has copy, drop {
        trade_id: ID,
        trader: address,
        input_asset: String,
        output_asset: String,
        input_amount: u64,
        output_amount: u64,
        routing_path: vector<String>,
        hops_executed: u64,
        total_fees: u64,
        slippage: u64,
        timestamp: u64,
    }
    
    /// Fee events
    public struct TradingFeesCollected has copy, drop {
        trader: address,
        base_fee: u64,
        unxv_discount: u64,
        routing_fee: u64,
        total_fee: u64,
        fee_asset: String,
        unxv_burned: u64,
        timestamp: u64,
    }
    
    /// Arbitrage events
    public struct ArbitrageOpportunityDetected has copy, drop {
        opportunity_id: ID,
        path: vector<String>,
        profit_amount: u64,
        profit_percentage: u64,
        required_capital: u64,
        timestamp: u64,
    }
    
    // ========== Initialization ==========
    
    /// Initialize the DEX registry
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        let registry = DEXRegistry {
            id: object::new(ctx),
            supported_pools: table::new(ctx),
            fee_structure: FeeStructure {
                base_trading_fee: 30,         // 0.3%
                unxv_discount: 2000,          // 20% discount
                routing_fee: 10,              // 0.1% additional for routing
                maker_rebate: 5,              // 0.05% rebate
                max_fee: 100,                 // 1% maximum fee
            },
            admin_cap: option::some(admin_cap),
            cross_asset_router: option::none(),
            mev_protector: option::none(),
            is_paused: false,
            total_volume: 0,
            total_fees_collected: 0,
        };
        
        transfer::share_object(registry);
    }
    
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
    
    // ========== Admin Functions ==========
    
    /// Add a supported trading pool
    public fun add_supported_pool(
        registry: &mut DEXRegistry,
        base_asset: String,
        quote_asset: String,
        deepbook_pool_id: ID,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        let pool_key = create_pool_key(base_asset, quote_asset);
        let pool_info = PoolInfo {
            base_asset,
            quote_asset,
            deepbook_pool_id,
            is_active: true,
            volume_24h: 0,
            fees_collected_24h: 0,
            last_price: 0,
            price_change_24h: 0,
        };
        
        table::add(&mut registry.supported_pools, pool_key, pool_info);
    }
    
    /// Update fee structure
    public fun update_fee_structure(
        registry: &mut DEXRegistry,
        new_fee_structure: FeeStructure,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        registry.fee_structure = new_fee_structure;
    }
    
    /// Pause/unpause the system
    public fun set_system_pause(
        registry: &mut DEXRegistry,
        paused: bool,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        registry.is_paused = paused;
    }
    
    /// Toggle pool active status
    public fun set_pool_active(
        registry: &mut DEXRegistry,
        base_asset: String,
        quote_asset: String,
        active: bool,
        _ctx: &TxContext,
    ) {
        assert!(option::is_some(&registry.admin_cap), E_NOT_ADMIN);
        
        let pool_key = create_pool_key(base_asset, quote_asset);
        assert!(table::contains(&registry.supported_pools, pool_key), E_POOL_NOT_FOUND);
        
        let pool_info = table::borrow_mut(&mut registry.supported_pools, pool_key);
        pool_info.is_active = active;
    }
    
    // ========== Trading Session Management ==========
    
    /// Create a new trading session
    public fun create_trading_session(ctx: &mut TxContext): TradingSession {
        TradingSession {
            id: object::new(ctx),
            trader: tx_context::sender(ctx),
            active_orders: vec_set::empty(),
            order_history: vector::empty(),
            total_volume_traded: 0,
            total_fees_paid: 0,
            unxv_fees_saved: 0,
            session_start: 0, // Would use clock in production
            last_activity: 0,
        }
    }
    
    // ========== Direct Trading ==========
    
    /// Execute a direct trade on a single DeepBook pool
    public fun execute_direct_trade<T, U>(
        registry: &mut DEXRegistry,
        session: &mut TradingSession,
        base_asset: String,
        quote_asset: String,
        side: String, // "BUY" or "SELL"
        amount: u64,
        input_coin: Coin<T>,
        min_output: u64,
        fee_payment_asset: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<U>, TradeResult) {
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(session.trader == tx_context::sender(ctx), E_UNAUTHORIZED);
        
        let pool_key = create_pool_key(base_asset, quote_asset);
        assert!(table::contains(&registry.supported_pools, pool_key), E_POOL_NOT_FOUND);
        
        let pool_info = table::borrow(&registry.supported_pools, pool_key);
        assert!(pool_info.is_active, E_POOL_INACTIVE);
        
        // Calculate fees
        let fee_breakdown = calculate_trading_fees(
            amount, 0, string::utf8(b"MARKET"), 0, fee_payment_asset, registry
        );
        
        // Create order
        let order = SimpleTradeOrder {
            id: object::new(ctx),
            trader: tx_context::sender(ctx),
            input_asset: base_asset,
            output_asset: quote_asset,
            input_amount: amount,
            min_output_amount: min_output,
            fee_payment_asset,
            order_type: string::utf8(b"MARKET"),
            status: string::utf8(b"PENDING"),
            created_at: clock::timestamp_ms(clock),
            expires_at: option::none(),
        };
        
        let order_id = object::uid_to_inner(&order.id);
        
        // Simulate trade execution (in production this would integrate with DeepBook)
        let output_amount = simulate_trade_execution(amount, min_output);
        assert!(output_amount >= min_output, E_INSUFFICIENT_OUTPUT);
        
        // Update order status
        order.status = string::utf8(b"EXECUTED");
        
        // Update session
        vec_set::insert(&mut session.active_orders, order_id);
        session.total_volume_traded = session.total_volume_traded + amount;
        session.total_fees_paid = session.total_fees_paid + fee_breakdown.final_fee;
        session.last_activity = clock::timestamp_ms(clock);
        
        // Update registry stats
        registry.total_volume = registry.total_volume + amount;
        registry.total_fees_collected = registry.total_fees_collected + fee_breakdown.final_fee;
        
        // Create mock output coin (in production this would be from DeepBook)
        let output_coin = create_mock_coin<U>(output_amount, ctx);
        
        let trade_result = TradeResult {
            success: true,
            order_id,
            input_amount: amount,
            output_amount,
            fees_paid: fee_breakdown.final_fee,
            slippage: calculate_slippage(amount, output_amount),
            execution_time_ms: 100, // Mock execution time
            deepbook_fills: vector::empty(),
        };
        
        // Emit events
        event::emit(OrderCreated {
            order_id,
            trader: tx_context::sender(ctx),
            order_type: string::utf8(b"MARKET"),
            input_asset: base_asset,
            output_asset: quote_asset,
            input_amount: amount,
            min_output_amount: min_output,
            fee_payment_asset,
            routing_path: vector::empty(),
            timestamp: clock::timestamp_ms(clock),
        });
        
        event::emit(OrderExecuted {
            order_id,
            trader: tx_context::sender(ctx),
            input_amount: amount,
            output_amount,
            fees_paid: fee_breakdown.final_fee,
            fee_asset: fee_payment_asset,
            slippage: trade_result.slippage,
            deepbook_fills: vector::empty(),
            timestamp: clock::timestamp_ms(clock),
        });
        
        // Clean up order object
        let SimpleTradeOrder { id, trader: _, input_asset: _, output_asset: _, 
                             input_amount: _, min_output_amount: _, fee_payment_asset: _, 
                             order_type: _, status: _, created_at: _, expires_at: _ } = order;
        object::delete(id);
        
        (output_coin, trade_result)
    }
    
    // ========== Cross-Asset Routing ==========
    
    /// Calculate optimal cross-asset route
    public fun calculate_cross_asset_route(
        registry: &DEXRegistry,
        input_asset: String,
        output_asset: String,
        input_amount: u64,
        max_hops: Option<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): CrossAssetRoute {
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        let max_hops_value = if (option::is_some(&max_hops)) {
            *option::borrow(&max_hops)
        } else {
            MAX_HOPS
        };
        
        // Try direct route first
        let direct_pool_key = create_pool_key(input_asset, output_asset);
        if (table::contains(&registry.supported_pools, direct_pool_key)) {
            let pool_info = table::borrow(&registry.supported_pools, direct_pool_key);
            if (pool_info.is_active) {
                return CrossAssetRoute {
                    path: vector[input_asset, output_asset],
                    pool_ids: vector[pool_info.deepbook_pool_id],
                    estimated_output: simulate_direct_output(input_amount),
                    total_fees: calculate_direct_fees(input_amount, registry),
                    hops_required: 1,
                    route_viability: 9500, // High viability for direct routes
                }
            }
        };
        
        // Calculate multi-hop route through common intermediaries
        let intermediaries = vector[string::utf8(b"USDC"), string::utf8(b"SUI"), string::utf8(b"USDT")];
        let best_route = find_best_multi_hop_route(
            registry, input_asset, output_asset, input_amount, intermediaries, max_hops_value
        );
        
        // Emit route calculation event
        let request_id = object::new(ctx);
        event::emit(CrossAssetRouteCalculated {
            request_id: object::uid_to_inner(&request_id),
            input_asset,
            output_asset,
            input_amount,
            routing_path: best_route.path,
            estimated_output: best_route.estimated_output,
            total_fees: best_route.total_fees,
            hops_required: best_route.hops_required,
            calculation_time_ms: 50, // Mock calculation time
            timestamp: clock::timestamp_ms(clock),
        });
        object::delete(request_id);
        
        best_route
    }
    
    /// Execute cross-asset trade using calculated route
    public fun execute_cross_asset_trade<T, U>(
        registry: &mut DEXRegistry,
        session: &mut TradingSession,
        route: CrossAssetRoute,
        input_coin: Coin<T>,
        min_final_output: u64,
        fee_payment_asset: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<U>, TradeResult) {
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(session.trader == tx_context::sender(ctx), E_UNAUTHORIZED);
        assert!(route.hops_required <= MAX_HOPS, E_MAX_HOPS_EXCEEDED);
        assert!(route.estimated_output >= min_final_output, E_SLIPPAGE_EXCEEDED);
        
        let input_amount = coin::value(&input_coin);
        
        // Create cross-asset execution object
        let route_hops = create_route_hops_from_path(route.path, route.pool_ids, input_amount);
        let execution = CrossAssetExecution {
            id: object::new(ctx),
            trader: tx_context::sender(ctx),
            route_hops,
            total_input: input_amount,
            min_final_output,
            fee_payment_asset,
            status: string::utf8(b"EXECUTING"),
            hops_completed: 0,
            actual_output: 0,
            total_fees_paid: route.total_fees,
            slippage: 0,
            created_at: clock::timestamp_ms(clock),
        };
        
        let execution_id = object::uid_to_inner(&execution.id);
        
        // Execute each hop atomically
        let current_amount = input_amount;
        let mut hop_index = 0;
        
        while (hop_index < vector::length(&execution.route_hops)) {
            let hop = vector::borrow_mut(&mut execution.route_hops, hop_index);
            
            // Simulate hop execution
            let hop_output = simulate_hop_execution(hop.expected_input, hop.min_output);
            assert!(hop_output >= hop.min_output, E_INSUFFICIENT_OUTPUT);
            
            hop.executed = true;
            hop.actual_output = hop_output;
            current_amount = hop_output;
            execution.hops_completed = execution.hops_completed + 1;
            
            hop_index = hop_index + 1;
        };
        
        execution.actual_output = current_amount;
        execution.status = string::utf8(b"COMPLETED");
        execution.slippage = calculate_slippage(route.estimated_output, current_amount);
        
        assert!(current_amount >= min_final_output, E_INSUFFICIENT_OUTPUT);
        
        // Update session
        session.total_volume_traded = session.total_volume_traded + input_amount;
        session.total_fees_paid = session.total_fees_paid + route.total_fees;
        session.last_activity = clock::timestamp_ms(clock);
        
        // Update registry stats
        registry.total_volume = registry.total_volume + input_amount;
        registry.total_fees_collected = registry.total_fees_collected + route.total_fees;
        
        // Create mock output coin
        let output_coin = create_mock_coin<U>(current_amount, ctx);
        
        let trade_result = TradeResult {
            success: true,
            order_id: execution_id,
            input_amount,
            output_amount: current_amount,
            fees_paid: route.total_fees,
            slippage: execution.slippage,
            execution_time_ms: (route.hops_required as u64) * 150, // Mock execution time
            deepbook_fills: vector::empty(),
        };
        
        // Emit events
        event::emit(CrossAssetTradeExecuted {
            trade_id: execution_id,
            trader: tx_context::sender(ctx),
            input_asset: *vector::borrow(&route.path, 0),
            output_asset: *vector::borrow(&route.path, vector::length(&route.path) - 1),
            input_amount,
            output_amount: current_amount,
            routing_path: route.path,
            hops_executed: (execution.hops_completed as u64),
            total_fees: route.total_fees,
            slippage: execution.slippage,
            timestamp: clock::timestamp_ms(clock),
        });
        
        // Clean up execution object
        let CrossAssetExecution { id, trader: _, route_hops: _, total_input: _, 
                                min_final_output: _, fee_payment_asset: _, status: _, 
                                hops_completed: _, actual_output: _, total_fees_paid: _, 
                                slippage: _, created_at: _ } = execution;
        object::delete(id);
        
        (output_coin, trade_result)
    }
    
    // ========== Fee Management ==========
    
    /// Calculate trading fees with UNXV discount
    public fun calculate_trading_fees(
        amount: u64,
        quote_amount: u64,
        order_type: String,
        routing_hops: u64,
        fee_payment_asset: String,
        registry: &DEXRegistry,
    ): FeeBreakdown {
        let fee_structure = &registry.fee_structure;
        
        // Base trading fee
        let base_fee = (amount * fee_structure.base_trading_fee) / BASIS_POINTS;
        
        // Routing fee for multi-hop trades
        let routing_fee = if (routing_hops > 1) {
            (amount * fee_structure.routing_fee * routing_hops) / BASIS_POINTS
        } else {
            0
        };
        
        // Order type fee (advanced orders may have additional fees)
        let order_type_fee = if (order_type == string::utf8(b"STOP_LOSS") || 
                                order_type == string::utf8(b"TAKE_PROFIT") ||
                                order_type == string::utf8(b"TRAILING_STOP")) {
            (amount * 5) / BASIS_POINTS // 0.05% for advanced orders
        } else {
            0
        };
        
        let total_before_discount = base_fee + routing_fee + order_type_fee;
        
        // Apply UNXV discount
        let (unxv_discount, final_fee) = if (fee_payment_asset == string::utf8(b"UNXV")) {
            let discount = (total_before_discount * fee_structure.unxv_discount) / BASIS_POINTS;
            (discount, total_before_discount - discount)
        } else {
            (0, total_before_discount)
        };
        
        // Apply maximum fee cap
        let capped_fee = if (final_fee > fee_structure.max_fee) {
            fee_structure.max_fee
        } else {
            final_fee
        };
        
        FeeBreakdown {
            base_trading_fee: base_fee,
            routing_fee,
            order_type_fee,
            total_fee_before_discount: total_before_discount,
            unxv_discount,
            final_fee: capped_fee,
            fee_asset: fee_payment_asset,
        }
    }
    
    /// Process fees with AutoSwap integration (placeholder)
    public fun process_fees_with_autoswap(
        fee_breakdown: FeeBreakdown,
        trader: address,
        clock: &Clock,
    ) {
        // Emit fee collection event
        event::emit(TradingFeesCollected {
            trader,
            base_fee: fee_breakdown.base_trading_fee,
            unxv_discount: fee_breakdown.unxv_discount,
            routing_fee: fee_breakdown.routing_fee,
            total_fee: fee_breakdown.final_fee,
            fee_asset: fee_breakdown.fee_asset,
            unxv_burned: if (fee_breakdown.fee_asset == string::utf8(b"UNXV")) {
                fee_breakdown.final_fee
            } else {
                0
            },
            timestamp: clock::timestamp_ms(clock),
        });
    }
    
    // ========== Arbitrage Detection ==========
    
    /// Detect triangular arbitrage opportunities
    public fun detect_triangular_arbitrage(
        registry: &DEXRegistry,
        base_assets: vector<String>,
        min_profit_threshold: u64,
        clock: &Clock,
        _ctx: &mut TxContext,
    ): vector<ArbitrageOpportunity> {
        let opportunities = vector::empty<ArbitrageOpportunity>();
        let asset_count = vector::length(&base_assets);
        
        let mut i = 0;
        while (i < asset_count) {
            let asset_a = *vector::borrow(&base_assets, i);
            
            let mut j = i + 1;
            while (j < asset_count) {
                let asset_b = *vector::borrow(&base_assets, j);
                
                let mut k = j + 1;
                while (k < asset_count) {
                    let asset_c = *vector::borrow(&base_assets, k);
                    
                    // Check triangular arbitrage: A -> B -> C -> A
                    let opportunity = calculate_triangular_arbitrage(
                        registry, asset_a, asset_b, asset_c, 1000000, // 1M base units
                    );
                    
                    if (option::is_some(&opportunity)) {
                        let opp = option::extract(&mut opportunity);
                        if (opp.profit_amount >= min_profit_threshold) {
                            vector::push_back(&mut opportunities, opp);
                            
                            // Emit arbitrage opportunity event  
                            event::emit(ArbitrageOpportunityDetected {
                                opportunity_id: object::id_from_address(@0x0), // Mock ID
                                path: opp.path,
                                profit_amount: opp.profit_amount,
                                profit_percentage: opp.profit_percentage,
                                required_capital: opp.required_capital,
                                timestamp: clock::timestamp_ms(clock),
                            });
                        }
                    };
                    
                    k = k + 1;
                };
                j = j + 1;
            };
            i = i + 1;
        };
        
        opportunities
    }
    
    // ========== Helper Functions ==========
    
    /// Create pool key from asset pair
    fun create_pool_key(base_asset: String, quote_asset: String): String {
        let mut key = base_asset;
        string::append(&mut key, string::utf8(b"_"));
        string::append(&mut key, quote_asset);
        key
    }
    
    /// Simulate trade execution (mock function for testing)
    fun simulate_trade_execution(input_amount: u64, min_output: u64): u64 {
        // Simple simulation: assume 0.1% slippage
        let output = (input_amount * 9990) / 10000;
        if (output >= min_output) output else min_output
    }
    
    /// Simulate direct output for route calculation
    fun simulate_direct_output(input_amount: u64): u64 {
        (input_amount * 9985) / 10000 // 0.15% slippage simulation
    }
    
    /// Calculate direct trading fees
    fun calculate_direct_fees(input_amount: u64, registry: &DEXRegistry): u64 {
        (input_amount * registry.fee_structure.base_trading_fee) / BASIS_POINTS
    }
    
    /// Find best multi-hop route
    fun find_best_multi_hop_route(
        registry: &DEXRegistry,
        input_asset: String,
        output_asset: String,
        input_amount: u64,
        intermediaries: vector<String>,
        max_hops: u8,
    ): CrossAssetRoute {
        let mut best_route = CrossAssetRoute {
            path: vector::empty(),
            pool_ids: vector::empty(),
            estimated_output: 0,
            total_fees: 0,
            hops_required: 0,
            route_viability: 0,
        };
        
        // Try 2-hop routes through each intermediary
        let mut i = 0;
        while (i < vector::length(&intermediaries)) {
            let intermediary = *vector::borrow(&intermediaries, i);
            
            // Check if both legs exist
            let leg1_key = create_pool_key(input_asset, intermediary);
            let leg2_key = create_pool_key(intermediary, output_asset);
            
            if (table::contains(&registry.supported_pools, leg1_key) && 
                table::contains(&registry.supported_pools, leg2_key)) {
                
                let pool1 = table::borrow(&registry.supported_pools, leg1_key);
                let pool2 = table::borrow(&registry.supported_pools, leg2_key);
                
                if (pool1.is_active && pool2.is_active) {
                    // Simulate 2-hop execution
                    let intermediate_amount = simulate_trade_execution(input_amount, 0);
                    let final_amount = simulate_trade_execution(intermediate_amount, 0);
                    let total_fees = calculate_direct_fees(input_amount, registry) * 2;
                    
                    if (final_amount > best_route.estimated_output) {
                        best_route = CrossAssetRoute {
                            path: vector[input_asset, intermediary, output_asset],
                            pool_ids: vector[pool1.deepbook_pool_id, pool2.deepbook_pool_id],
                            estimated_output: final_amount,
                            total_fees,
                            hops_required: 2,
                            route_viability: 8000, // Good viability for 2-hop routes
                        };
                    }
                }
            };
            
            i = i + 1;
        };
        
        // If no good route found, return empty route
        if (vector::is_empty(&best_route.path)) {
            best_route.route_viability = 0;
        };
        
        best_route
    }
    
    /// Create route hops from path
    fun create_route_hops_from_path(
        path: vector<String>,
        pool_ids: vector<ID>,
        input_amount: u64,
    ): vector<RouteHop> {
        let hops = vector::empty<RouteHop>();
        let path_length = vector::length(&path);
        
        if (path_length < 2) {
            return hops
        };
        
        let mut current_amount = input_amount;
        let mut i = 0;
        
        while (i < path_length - 1) {
            let from_asset = *vector::borrow(&path, i);
            let to_asset = *vector::borrow(&path, i + 1);
            let pool_id = *vector::borrow(&pool_ids, i);
            
            let expected_output = simulate_trade_execution(current_amount, 0);
            let min_output = (expected_output * 97) / 100; // 3% slippage tolerance
            
            let hop = RouteHop {
                from_asset,
                to_asset,
                deepbook_pool_id: pool_id,
                expected_input: current_amount,
                min_output,
                executed: false,
                actual_output: 0,
            };
            
            vector::push_back(&mut hops, hop);
            current_amount = expected_output;
            i = i + 1;
        };
        
        hops
    }
    
    /// Simulate hop execution
    fun simulate_hop_execution(input_amount: u64, min_output: u64): u64 {
        let output = (input_amount * 9980) / 10000; // 0.2% slippage
        if (output >= min_output) output else min_output
    }
    
    /// Calculate slippage percentage
    fun calculate_slippage(expected: u64, actual: u64): u64 {
        if (expected == 0) return 0;
        if (actual >= expected) return 0;
        
        ((expected - actual) * BASIS_POINTS) / expected
    }
    
    /// Calculate triangular arbitrage opportunity
    fun calculate_triangular_arbitrage(
        registry: &DEXRegistry,
        asset_a: String,
        asset_b: String,
        asset_c: String,
        capital: u64,
    ): Option<ArbitrageOpportunity> {
        // Check if all required pools exist
        let ab_key = create_pool_key(asset_a, asset_b);
        let bc_key = create_pool_key(asset_b, asset_c);
        let ca_key = create_pool_key(asset_c, asset_a);
        
        if (!table::contains(&registry.supported_pools, ab_key) ||
            !table::contains(&registry.supported_pools, bc_key) ||
            !table::contains(&registry.supported_pools, ca_key)) {
            return option::none()
        };
        
        // Simulate arbitrage execution
        let amount_b = simulate_trade_execution(capital, 0);
        let amount_c = simulate_trade_execution(amount_b, 0);
        let final_amount = simulate_trade_execution(amount_c, 0);
        
        if (final_amount > capital) {
            let profit = final_amount - capital;
            let profit_percentage = (profit * BASIS_POINTS) / capital;
            
            option::some(ArbitrageOpportunity {
                path: vector[asset_a, asset_b, asset_c, asset_a],
                pool_ids: vector[
                    table::borrow(&registry.supported_pools, ab_key).deepbook_pool_id,
                    table::borrow(&registry.supported_pools, bc_key).deepbook_pool_id,
                    table::borrow(&registry.supported_pools, ca_key).deepbook_pool_id,
                ],
                profit_amount: profit,
                profit_percentage,
                required_capital: capital,
                time_sensitivity: 30000, // 30 seconds
                risk_score: 3000, // 30% risk score
            })
        } else {
            option::none()
        }
    }
    
    // ========== Getter Functions ==========
    
    /// Get pool information
    public fun get_pool_info(
        registry: &DEXRegistry,
        base_asset: String,
        quote_asset: String,
    ): &PoolInfo {
        let pool_key = create_pool_key(base_asset, quote_asset);
        table::borrow(&registry.supported_pools, pool_key)
    }
    
    /// Check if pool is supported
    public fun is_pool_supported(
        registry: &DEXRegistry,
        base_asset: String,
        quote_asset: String,
    ): bool {
        let pool_key = create_pool_key(base_asset, quote_asset);
        table::contains(&registry.supported_pools, pool_key)
    }
    
    /// Get fee structure
    public fun get_fee_structure(registry: &DEXRegistry): &FeeStructure {
        &registry.fee_structure
    }
    
    /// Get registry stats
    public fun get_registry_stats(registry: &DEXRegistry): (u64, u64, bool) {
        (registry.total_volume, registry.total_fees_collected, registry.is_paused)
    }
    
    /// Get trading session summary
    public fun get_session_summary(session: &TradingSession): (u64, u64, u64, u64) {
        (
            session.total_volume_traded,
            session.total_fees_paid,
            session.unxv_fees_saved,
            vector::length(&session.order_history)
        )
    }
    
    // ========== Getter Functions ==========
    
    /// Get TradeResult fields
    public fun get_trade_result_info(result: &TradeResult): (bool, u64, u64, u64, u64) {
        (result.success, result.input_amount, result.output_amount, result.fees_paid, result.slippage)
    }
    
    /// Get CrossAssetRoute fields  
    public fun get_route_info(route: &CrossAssetRoute): (u8, u64, u64, u64, &vector<String>) {
        (route.hops_required, route.estimated_output, route.total_fees, route.route_viability, &route.path)
    }
    
    /// Get FeeBreakdown fields
    public fun get_fee_breakdown_info(breakdown: &FeeBreakdown): (u64, u64, u64, u64) {
        (breakdown.unxv_discount, breakdown.final_fee, breakdown.routing_fee, breakdown.total_fee_before_discount)
    }
    
    /// Get ArbitrageOpportunity fields
    public fun get_arbitrage_info(opportunity: &ArbitrageOpportunity): (u64, u64, &vector<String>) {
        (opportunity.profit_amount, opportunity.profit_percentage, &opportunity.path)
    }
    
    // ========== Test-Only Functions ==========
    
    #[test_only]
    public fun create_mock_coin<T>(amount: u64, ctx: &mut TxContext): Coin<T> {
        coin::from_balance(balance::create_for_testing<T>(amount), ctx)
    }
    
    #[test_only]
    public fun create_test_pool_info(
        base_asset: String,
        quote_asset: String,
        deepbook_pool_id: ID,
    ): PoolInfo {
        PoolInfo {
            base_asset,
            quote_asset,
            deepbook_pool_id,
            is_active: true,
            volume_24h: 0,
            fees_collected_24h: 0,
            last_price: 100000000, // $1.00 in 8 decimals
            price_change_24h: 0,
        }
    }
    
    #[test_only]
    public fun create_test_fee_structure(): FeeStructure {
        FeeStructure {
            base_trading_fee: 30,     // 0.3%
            unxv_discount: 2000,      // 20%
            routing_fee: 10,          // 0.1%
            maker_rebate: 5,          // 0.05%
            max_fee: 100,             // 1%
        }
    }
    
    #[test_only]
    public fun create_test_admin_cap(ctx: &mut TxContext): AdminCap {
        AdminCap {
            id: object::new(ctx),
        }
    }
}


