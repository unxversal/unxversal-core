module unxversal::dex {
    /*******************************
    * On-chain DEX (order objects, permissionless matching)
    * - Coin<Base> orderbook (escrowed buy/sell orders)
    * - Taker-only fees with optional UNXV discount
    *******************************/

    use sui::display;
    use sui::package::Publisher;
    use sui::coin::{Self as coin, Coin};
    use sui::clock::Clock;
    use sui::event;
    use sui::table::{Self as table, Table};
    use sui::balance::{Self as balance, Balance};
    use unxversal::book::{Self as Book, Book as ClobBook, Fill};
    use unxversal::utils;
    use std::string::String;

    // Collateral coin type is generic per market; no hard USDC dependency
    use switchboard::aggregator::Aggregator;
    use unxversal::unxv::UNXV;
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    // Removed cross-module FeeCollected emission; fees are accounted in Treasury
    use unxversal::treasury::{Self as TreasuryMod, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BotRewards, BotPointsRegistry};

    fun assert_is_admin(admin_reg: &AdminRegistry, addr: address) { assert!(AdminMod::is_admin(admin_reg, addr), E_NOT_ADMIN); }

    const E_INSUFFICIENT_PAYMENT: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_PAUSED: u64 = 3;
    const E_NOT_ADMIN: u64 = 4;
    const E_EXPIRED: u64 = 5;
    const E_NOT_CROSSED: u64 = 6;
    const E_BAD_BOUNDS: u64 = 7;
    

    // Arithmetic safety helpers
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    fun clamp_u128_to_u64(x: u128): u64 { if (x > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { x as u64 } }

    /*******************************
    * Events & Config
    *******************************/
    public struct SwapExecuted has copy, drop {
        market: String,         // e.g., "COIN/SYNTH", "UNXV/COLLATERAL"
        base: String,           // base symbol for context (e.g., coin symbol or synth symbol)
        quote: String,          // quote symbol for context
        price: u64,             // units of quote per 1 base
        size: u64,              // base size filled
        payer: address,
        receiver: address,
        timestamp: u64,
    }

    // New events for permissionless market lifecycle
    public struct MarketCreated has copy, drop {
        market_id: ID,
        base: String,
        quote: String,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        creator: address,
        timestamp: u64,
    }

    public struct MarketCreationFeePaid has copy, drop {
        base: String,
        quote: String,
        fee_units: u64,
        payer: address,
        timestamp: u64,
    }

    // Order lifecycle events for coin orders
    public struct CoinOrderPlaced has copy, drop {
        order_id: ID,
        owner: address,
        side: u8,               // 0 = buy, 1 = sell
        price: u64,
        size_base: u64,
        created_at_ms: u64,
        expiry_ms: u64,
    }
    public struct CoinOrderCancelled has copy, drop { order_id: ID, owner: address, timestamp: u64 }
    public struct CoinOrderMatched has copy, drop {
        buy_order_id: ID,
        sell_order_id: ID,
        price: u64,
        size_base: u64,
        taker_is_buyer: bool,
        fee_paid: u64,
        unxv_discount_applied: bool,
        maker_rebate: u64,
        timestamp: u64,
    }

    /// Escrowed sell order: user sells Base for collateral at price (collateral per 1 Base)
    #[allow(lint(coin_field))]
    public struct CoinOrderSell<phantom Base> has key, store {
        id: UID,
        owner: address,
        price: u64,
        remaining_base: u64,
        created_at_ms: u64,
        expiry_ms: u64,
        escrow_base: Coin<Base>,
    }

    /// Escrowed buy order: user buys Base with collateral at price (collateral per 1 Base)
    /// size_base is implied by escrow_collateral / price (we also store remaining_base)
    #[allow(lint(coin_field))]
    public struct CoinOrderBuy<phantom Base, phantom C> has key, store {
        id: UID,
        owner: address,
        price: u64,
        remaining_base: u64,
        created_at_ms: u64,
        expiry_ms: u64,
        escrow_collateral: Coin<C>,
    }

    public struct DexConfig has key, store {
        id: UID,
        treasury_id: ID,
        trade_fee_bps: u64,
        unxv_discount_bps: u64,
        maker_rebate_bps: u64,  // not used in OTC paths
        paused: bool,
        // CLOB extras
        keeper_reward_bps: u64,
        gc_reward_bps: u64,
        maker_bond_bps: u64,
        // Permissionless market creation params
        perm_market_fee_units: u64,
        perm_market_unxv_discount_bps: u64,
    }

    public fun init_dex<C>(admin_reg: &AdminRegistry, treasury: &Treasury<C>, ctx: &mut TxContext) {
        assert_is_admin(admin_reg, ctx.sender());
        let cfg = DexConfig {
            id: object::new(ctx),
            treasury_id: object::id(treasury),
            trade_fee_bps: 30,         // 0.30%
            unxv_discount_bps: 2000,   // 20% discount
            maker_rebate_bps: 0,
            paused: false,
            keeper_reward_bps: 100,    // 1%
            gc_reward_bps: 100,        // 1%
            maker_bond_bps: 10,        // 0.10%
            perm_market_fee_units: 0,
            perm_market_unxv_discount_bps: 0,
        };
        transfer::share_object(cfg);
    }

    // Display registration for better wallet/indexer UX
    public fun init_dex_displays<Base: store, C: store>(publisher: &Publisher, ctx: &mut TxContext) {
        let mut d_cfg = display::new<DexConfig>(publisher, ctx);
        d_cfg.add(b"name".to_string(), b"Unxversal DEX Config".to_string());
        d_cfg.add(b"description".to_string(), b"Global parameters for the Unxversal on-chain DEX".to_string());
        d_cfg.update_version();
        transfer::public_transfer(d_cfg, ctx.sender());

        let mut d_sell = display::new<CoinOrderSell<Base>>(publisher, ctx);
        d_sell.add(b"name".to_string(), b"Sell {remaining_base} @ {price}".to_string());
        d_sell.add(b"description".to_string(), b"Escrowed sell order".to_string());
        d_sell.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        d_sell.update_version();
        transfer::public_transfer(d_sell, ctx.sender());

        let mut d_buy = display::new<CoinOrderBuy<Base, C>>(publisher, ctx);
        d_buy.add(b"name".to_string(), b"Buy {remaining_base} @ {price}".to_string());
        d_buy.add(b"description".to_string(), b"Escrowed buy order".to_string());
        d_buy.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        d_buy.update_version();
        transfer::public_transfer(d_buy, ctx.sender());

        
    }

    

    // AdminRegistry-gated variants (centralized admin)
    public fun set_trade_fee_bps_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.trade_fee_bps = bps; }
    public fun set_unxv_discount_bps_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.unxv_discount_bps = bps; }
    public fun set_maker_rebate_bps_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.maker_rebate_bps = bps; }
    public fun set_keeper_reward_bps_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.keeper_reward_bps = bps; }
    public fun set_gc_reward_bps_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.gc_reward_bps = bps; }
    public fun set_maker_bond_bps_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.maker_bond_bps = bps; }
    public fun set_perm_market_params_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, fee_units: u64, unxv_discount_bps: u64, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.perm_market_fee_units = fee_units; cfg.perm_market_unxv_discount_bps = unxv_discount_bps; }
    public fun pause_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.paused = true; }
    public fun resume_admin(reg_admin: &AdminRegistry, cfg: &mut DexConfig, ctx: &TxContext) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN); cfg.paused = false; }

    // ------------------------
    // Test-only helpers
    // ------------------------
    #[test_only]
    public fun new_dex_config_for_testing<C>(treasury: &Treasury<C>, ctx: &mut TxContext): DexConfig {
        DexConfig {
            id: object::new(ctx),
            treasury_id: object::id(treasury),
            trade_fee_bps: 30,
            unxv_discount_bps: 2000,
            maker_rebate_bps: 0,
            paused: false,
            keeper_reward_bps: 100,
            gc_reward_bps: 100,
            maker_bond_bps: 10,
            perm_market_fee_units: 0,
            perm_market_unxv_discount_bps: 0,
        }
    }

    #[test_only]
    public fun is_paused_for_testing(cfg: &DexConfig): bool { cfg.paused }

    // Create a test-only DexMarket without admin gating
    #[test_only]
    public fun new_dex_market_for_testing<Base: store, C: store>(
        base_symbol: String,
        quote_symbol: String,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        ctx: &mut TxContext
    ): DexMarket<Base, C> {
        let book = Book::empty(tick_size, lot_size, min_size, ctx);
        let makers = table::new<u128, address>(ctx);
        let maker_sides = table::new<u128, u8>(ctx);
        let claimed = table::new<u128, u64>(ctx);
        let bonds = table::new<u128, balance::Balance<C>>(ctx);
        DexMarket<Base, C> { id: object::new(ctx), symbol_base: base_symbol, symbol_quote: quote_symbol, book, makers, maker_sides, claimed, bonds }
    }

    // Create a test-only DexEscrow for a given market
    #[test_only]
    public fun new_dex_escrow_for_testing<Base: store, C: store>(market: &DexMarket<Base, C>, ctx: &mut TxContext): DexEscrow<Base, C> {
        DexEscrow<Base, C> {
            id: object::new(ctx),
            market_id: object::id(market),
            pending_base: table::new<u128, balance::Balance<Base>>(ctx),
            pending_collateral: table::new<u128, balance::Balance<C>>(ctx),
            accrual_base: table::new<u128, balance::Balance<Base>>(ctx),
            accrual_collateral: table::new<u128, balance::Balance<C>>(ctx),
            bonds: table::new<u128, balance::Balance<C>>(ctx),
        }
    }

    /*******************************
    * Order placement / cancellation (escrow based)
    *******************************/
    #[allow(lint(self_transfer))]
    public fun place_coin_sell_order<Base: store>(cfg: &DexConfig, price: u64, size_base: u64, mut base: Coin<Base>, expiry_ms: u64, clock: &Clock, ctx: &mut TxContext): CoinOrderSell<Base> {
        assert!(!cfg.paused, E_PAUSED);
        assert!(size_base > 0, E_ZERO_AMOUNT);
        let have = coin::value(&base);
        assert!(have >= size_base, E_INSUFFICIENT_PAYMENT);
        let escrow = coin::split(&mut base, size_base, ctx);
        transfer::public_transfer(base, ctx.sender());
        let order = CoinOrderSell<Base> { id: object::new(ctx), owner: ctx.sender(), price, remaining_base: size_base, created_at_ms: sui::clock::timestamp_ms(clock), expiry_ms, escrow_base: escrow };
        event::emit(CoinOrderPlaced { order_id: object::id(&order), owner: order.owner, side: 1, price, size_base, created_at_ms: order.created_at_ms, expiry_ms });
        order
    }

    #[allow(lint(self_transfer))]
    public fun place_coin_buy_order<Base: store, C: store>(cfg: &DexConfig, price: u64, size_base: u64, mut collateral: Coin<C>, expiry_ms: u64, clock: &Clock, ctx: &mut TxContext): CoinOrderBuy<Base, C> {
        assert!(!cfg.paused, E_PAUSED);
        assert!(size_base > 0, E_ZERO_AMOUNT);
        let need_collateral = price * size_base;
        let have = coin::value(&collateral);
        assert!(have >= need_collateral, E_INSUFFICIENT_PAYMENT);
        let escrow = coin::split(&mut collateral, need_collateral, ctx);
        transfer::public_transfer(collateral, ctx.sender());
        let order = CoinOrderBuy<Base, C> { id: object::new(ctx), owner: ctx.sender(), price, remaining_base: size_base, created_at_ms: sui::clock::timestamp_ms(clock), expiry_ms, escrow_collateral: escrow };
        event::emit(CoinOrderPlaced { order_id: object::id(&order), owner: order.owner, side: 0, price, size_base, created_at_ms: order.created_at_ms, expiry_ms });
        order
    }

    // Entry wrappers that place and share coin orders in one call (matchable by others)
    #[allow(lint(share_owned))]
    public fun place_and_share_coin_sell_order<Base: store>(cfg: &DexConfig, price: u64, size_base: u64, base: Coin<Base>, expiry_ms: u64, clock: &Clock, ctx: &mut TxContext) {
        let order = place_coin_sell_order(cfg, price, size_base, base, expiry_ms, clock, ctx);
        transfer::share_object(order);
    }

    #[allow(lint(share_owned))]
    public fun place_and_share_coin_buy_order<Base: store, C: store>(cfg: &DexConfig, price: u64, size_base: u64, collateral: Coin<C>, expiry_ms: u64, clock: &Clock, ctx: &mut TxContext) {
        let order = place_coin_buy_order<Base, C>(cfg, price, size_base, collateral, expiry_ms, clock, ctx);
        transfer::share_object(order);
    }

    public fun cancel_coin_sell_order<Base: store>(order: CoinOrderSell<Base>, clock: &Clock, ctx: &TxContext) {
        assert!(order.owner == ctx.sender(), E_NOT_ADMIN);
        let order_id = object::id(&order);
        let CoinOrderSell<Base> { id, owner, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_base } = order;
        transfer::public_transfer(escrow_base, owner);
        event::emit(CoinOrderCancelled { order_id, owner: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
        object::delete(id);
    }

    public fun cancel_coin_buy_order<Base: store, C: store>(order: CoinOrderBuy<Base, C>, clock: &Clock, ctx: &TxContext) {
        assert!(order.owner == ctx.sender(), E_NOT_ADMIN);
        let order_id = object::id(&order);
        let CoinOrderBuy<Base, C> { id, owner, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_collateral } = order;
        transfer::public_transfer(escrow_collateral, owner);
        event::emit(CoinOrderCancelled { order_id, owner: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
        object::delete(id);
    }

    // Expiry lifecycle helpers – anyone can cancel expired orders to return funds
    public fun cancel_coin_sell_if_expired<Base: store>(order: CoinOrderSell<Base>, clock: &Clock, _ctx: &TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        assert!(order.expiry_ms != 0 && now > order.expiry_ms, E_EXPIRED);
        let order_id = object::id(&order);
        let CoinOrderSell<Base> { id, owner, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_base } = order;
        transfer::public_transfer(escrow_base, owner);
        event::emit(CoinOrderCancelled { order_id, owner, timestamp: now });
        object::delete(id);
    }

    public fun cancel_coin_buy_if_expired<Base: store, C: store>(order: CoinOrderBuy<Base, C>, clock: &Clock, _ctx: &TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        assert!(order.expiry_ms != 0 && now > order.expiry_ms, E_EXPIRED);
        let order_id = object::id(&order);
        let CoinOrderBuy<Base, C> { id, owner, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_collateral } = order;
        transfer::public_transfer(escrow_collateral, owner);
        event::emit(CoinOrderCancelled { order_id, owner, timestamp: now });
        object::delete(id);
    }

    /*******************************
    * Match coin orders (maker/taker); taker pays fee, optional UNXV discount
    *******************************/
    public fun match_coin_orders<Base: store, C: store>(
        cfg: &DexConfig,
        buy: &mut CoinOrderBuy<Base, C>,
        sell: &mut CoinOrderSell<Base>,
        max_fill_base: u64,
        taker_is_buyer: bool,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        min_price: u64,
        max_price: u64,
        market: String,
        base: String,
        quote: String,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        if (buy.expiry_ms != 0) { assert!(now <= buy.expiry_ms, E_EXPIRED); };
        if (sell.expiry_ms != 0) { assert!(now <= sell.expiry_ms, E_EXPIRED); };
        // Crossed
        assert!(buy.price >= sell.price, E_NOT_CROSSED);
        let trade_price = if (taker_is_buyer) { sell.price } else { buy.price };
        // Slippage bounds
        assert!(trade_price >= min_price && trade_price <= max_price, E_BAD_BOUNDS);
        let a = if (buy.remaining_base < sell.remaining_base) { buy.remaining_base } else { sell.remaining_base };
        let fill = if (a < max_fill_base) { a } else { max_fill_base };
        assert!(fill > 0, E_ZERO_AMOUNT);

        // Move base from sell escrow to buyer
        let base_out = coin::split(&mut sell.escrow_base, fill, ctx);
        // Deliver base to buyer immediately (escrow unlock)
        transfer::public_transfer(base_out, buy.owner);
        // Move collateral from buy escrow to seller minus fee
        let collateral_owed_u128: u128 = (trade_price as u128) * (fill as u128);
        // Fee
        let trade_fee_u128: u128 = (collateral_owed_u128 * (cfg.trade_fee_bps as u128)) / 10_000u128;
        let discount_collateral_u128: u128 = (trade_fee_u128 * (cfg.unxv_discount_bps as u128)) / 10_000u128;
        let mut discount_applied = false;
        if (discount_collateral_u128 > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let px_u128: u128 = price_unxv_u64 as u128;
                let unxv_needed_u128 = (discount_collateral_u128 + px_u128 - 1) / px_u128;
                let unxv_needed = clamp_u128_to_u64(unxv_needed_u128);
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    coin::join(&mut merged, c);
                    i = i + 1;
                };
                let have = coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged, unxv_needed, ctx);
                    let mut vec_unxv = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    let epoch_id = BotRewards::current_epoch(points, clock);
                    TreasuryMod::deposit_unxv_with_rewards_for_epoch(
                        treasury,
                        bot_treasury,
                        epoch_id,
                        vec_unxv,
                        b"dex_otc_match".to_string(),
                        buy.owner,
                        ctx
                    );
                    transfer::public_transfer(merged, buy.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, buy.owner);
                }
            }
        };
        let collateral_fee_to_collect_u128: u128 = if (discount_applied) { trade_fee_u128 - discount_collateral_u128 } else { trade_fee_u128 };
        let maker_rebate_u128: u128 = (trade_fee_u128 * (cfg.maker_rebate_bps as u128)) / 10_000u128;
        let collateral_net_to_seller_u128: u128 = if (collateral_fee_to_collect_u128 <= collateral_owed_u128) { collateral_owed_u128 - collateral_fee_to_collect_u128 } else { 0 };
        let collateral_net_to_seller = clamp_u128_to_u64(collateral_net_to_seller_u128);
        if (collateral_net_to_seller > 0) {
            let to_seller = coin::split(&mut buy.escrow_collateral, collateral_net_to_seller, ctx);
            transfer::public_transfer(to_seller, sell.owner);
        };
        let collateral_fee_to_collect = clamp_u128_to_u64(collateral_fee_to_collect_u128);
        let maker_rebate = clamp_u128_to_u64(maker_rebate_u128);
        if (collateral_fee_to_collect > 0) {
            let mut fee_coin_all = coin::split(&mut buy.escrow_collateral, collateral_fee_to_collect, ctx);
            if (maker_rebate > 0 && maker_rebate < collateral_fee_to_collect) {
                let to_maker = coin::split(&mut fee_coin_all, maker_rebate, ctx);
                let maker_addr = if (taker_is_buyer) { sell.owner } else { buy.owner };
                transfer::public_transfer(to_maker, maker_addr);
            };
            let epoch_id2 = BotRewards::current_epoch(points, clock);
            TreasuryMod::deposit_collateral_with_rewards_for_epoch(
                treasury,
                bot_treasury,
                epoch_id2,
                fee_coin_all,
                b"dex_otc_match".to_string(),
                if (taker_is_buyer) { buy.owner } else { sell.owner },
                ctx
            );
        };

        // Update remaining (orders can be GC'd by anyone using gc helpers when empty)
        buy.remaining_base = buy.remaining_base - fill;
        sell.remaining_base = sell.remaining_base - fill;

        // Ensure UNXV payment vector is fully consumed and destroyed
        if (vector::length(&unxv_payment) > 0) {
            let mut leftover_unxv2 = coin::zero<UNXV>(ctx);
            let mut k = 0;
            while (k < vector::length(&unxv_payment)) {
                let c3 = vector::pop_back(&mut unxv_payment);
                coin::join(&mut leftover_unxv2, c3);
                k = k + 1;
            };
            transfer::public_transfer(leftover_unxv2, buy.owner);
        };
        vector::destroy_empty(unxv_payment);

        // Fee details are tracked in Treasury; external FeeCollected emission removed
        let ts2 = sui::clock::timestamp_ms(clock);
        event::emit(CoinOrderMatched { buy_order_id: object::id(buy), sell_order_id: object::id(sell), price: trade_price, size_base: fill, taker_is_buyer, fee_paid: collateral_fee_to_collect, unxv_discount_applied: discount_applied, maker_rebate: maker_rebate, timestamp: ts2 });
        // Generic swap event
        let (payer2, receiver2) = if (taker_is_buyer) { (buy.owner, sell.owner) } else { (sell.owner, buy.owner) };
        event::emit(SwapExecuted { market, base, quote, price: trade_price, size: fill, payer: payer2, receiver: receiver2, timestamp: ts2 });
    }

    /*******************************
    * Read-only helpers (bots/indexers)
    *******************************/
    public fun get_config_treasury_id(cfg: &DexConfig): ID { cfg.treasury_id }

    public fun get_config_fees(cfg: &DexConfig): (u64, u64, u64, bool) { (cfg.trade_fee_bps, cfg.unxv_discount_bps, cfg.maker_rebate_bps, cfg.paused) }
    public fun get_config_extras(cfg: &DexConfig): (u64, u64, u64) { (cfg.keeper_reward_bps, cfg.gc_reward_bps, cfg.maker_bond_bps) }

    /// Expose book parameters for tick/lot/min-size alignment (for range helpers)
    public fun get_book_params<Base: store, C: store>(market: &DexMarket<Base, C>): (u64, u64, u64) {
        (Book::tick_size(&market.book), Book::lot_size(&market.book), Book::min_size(&market.book))
    }

    /*******************************
    * Minimal on-chain CLOB hooks (scaffold)
    * - Future work: define `DexMarket<Base, C>` with `ClobBook`, maker maps, bonds/escrow like synthetics
    * - Expose place/cancel/modify, match_step_auto, gc_step (escrow-only model)
    *******************************/
    public struct DexMarket<phantom Base, phantom C> has key, store {
        id: UID,
        symbol_base: String,
        symbol_quote: String,
        book: ClobBook,
        makers: Table<u128, address>,
        maker_sides: Table<u128, u8>,
        claimed: Table<u128, u64>,
        bonds: Table<u128, Balance<C>>,
    }

    #[allow(lint(coin_field))]
    public struct DexEscrow<phantom Base, phantom C> has key, store {
        id: UID,
        market_id: ID,
        pending_base: Table<u128, Balance<Base>>,         // maker_id -> base owed to takers
        pending_collateral: Table<u128, Balance<C>>,      // maker_id -> collateral owed to takers
        bonds: Table<u128, Balance<C>>,                   // maker_id -> GC bond (in quote)
    }

    public fun init_dex_market<Base: store, C: store>(admin_reg: &AdminRegistry, base_symbol: String, quote_symbol: String, tick_size: u64, lot_size: u64, min_size: u64, clock: &Clock, ctx: &mut TxContext) {
        assert_is_admin(admin_reg, ctx.sender());
        let book = Book::empty(tick_size, lot_size, min_size, ctx);
        let makers = table::new<u128, address>(ctx);
        let maker_sides = table::new<u128, u8>(ctx);
        let claimed = table::new<u128, u64>(ctx);
        let bonds = table::new<u128, Balance<C>>(ctx);
        let mkt = DexMarket<Base, C> { id: object::new(ctx), symbol_base: base_symbol, symbol_quote: quote_symbol, book, makers, maker_sides, claimed, bonds };
        let idm = object::id(&mkt);
        transfer::share_object(mkt);
        event::emit(MarketCreated { market_id: idm, base: base_symbol, quote: quote_symbol, tick_size, lot_size, min_size, creator: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) });
    }

    public fun init_dex_escrow_for_market<Base: store, C: store>(market: &DexMarket<Base, C>, ctx: &mut TxContext) {
        let esc = DexEscrow<Base, C> {
            id: object::new(ctx),
            market_id: object::id(market),
            pending_base: table::new<u128, Balance<Base>>(ctx),
            pending_collateral: table::new<u128, Balance<C>>(ctx),
            bonds: table::new<u128, Balance<C>>(ctx),
        };
        transfer::share_object(esc);
    }

    /// Taker buys Base with Collateral; settles immediately from maker base escrow, accrues maker collateral
    public fun place_dex_limit_with_escrow_bid<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_collateral: &mut Coin<C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let plan = Book::compute_fill_plan(&market.book, /*is_bid*/ true, price, size_base, 0, expiry_ms, now);
        let mut i = 0u64; let fills = Book::fillplan_num_fills(&plan);
        while (i < fills) {
            let f: Fill = Book::fillplan_get_fill(&plan, i);
            let maker_id = Book::fill_maker_id(&f);
            let qty = Book::fill_base_qty(&f);
            // pay collateral to maker accrual
            let notional = qty * price;
            if (notional > 0) {
                let coin_pay = coin::split(taker_collateral, notional, ctx);
                let maker_addr = if (table::contains(&market.makers, maker_id)) { *table::borrow(&market.makers, maker_id) } else { ctx.sender() };
                transfer::public_transfer(coin_pay, maker_addr);
            };
            // deliver base to taker from maker escrow
            if (table::contains(&escrow.pending_base, maker_id)) {
                let bbase = table::borrow_mut(&mut escrow.pending_base, maker_id);
                let available = balance::value(bbase);
                let take = if (available >= qty) { qty } else { available };
                if (take > 0) {
                    let bout = balance::split(bbase, take);
                    let coin_out = coin::from_balance(bout, ctx);
                    transfer::public_transfer(coin_out, ctx.sender());
                };
            };
            i = i + 1;
        };
        let maybe_id = Book::commit_fill_plan(&mut market.book, plan, now, true);
        if (option::is_some(&maybe_id)) {
            let oid = *option::borrow(&maybe_id);
            table::add(&mut market.makers, oid, ctx.sender());
            table::add(&mut market.maker_sides, oid, 0);
            // escrow collateral for remainder
            let (filled, total) = Book::order_progress(&market.book, oid);
            let rem = total - filled;
            let need = rem * price;
            if (need > 0) {
                let c = coin::split(taker_collateral, need, ctx);
                let bal = coin::into_balance(c);
                table::add(&mut escrow.pending_collateral, oid, bal);
            };
            // post bond
            let bond_amt = (need * cfg.maker_bond_bps) / 10_000;
            if (bond_amt > 0) {
                let cb = coin::split(taker_collateral, bond_amt, ctx);
                let bb = coin::into_balance(cb);
                table::add(&mut escrow.bonds, oid, bb);
            };
            // Explicit non-crossing guard for posted remainder
            if (rem > 0) {
                let (has_ask, ask_id) = Book::best_ask_id(&market.book, now);
                if (has_ask) {
                    let (_, apx, _) = utils::decode_order_id(ask_id);
                    // Best ask must be strictly greater than our bid price
                    assert!(apx > price, E_NOT_CROSSED);
                };
            };
        };
    }

    /// Taker-only variant: does not post leftover as maker order (useful in flash-loan PTBs)
    public fun place_dex_taker_only_bid<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_collateral: &mut Coin<C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let plan = Book::compute_fill_plan(&market.book, /*is_bid*/ true, price, size_base, 0, expiry_ms, now);
        let mut i = 0u64; let fills = Book::fillplan_num_fills(&plan);
        while (i < fills) {
            let f: Fill = Book::fillplan_get_fill(&plan, i);
            let maker_id = Book::fill_maker_id(&f);
            let qty = Book::fill_base_qty(&f);
            let notional = qty * price;
            if (notional > 0) {
                let coin_pay = coin::split(taker_collateral, notional, ctx);
                let bal_pay = coin::into_balance(coin_pay);
                if (table::contains(&escrow.accrual_collateral, maker_id)) {
                    let b = table::borrow_mut(&mut escrow.accrual_collateral, maker_id);
                    balance::join(b, bal_pay);
                } else { table::add(&mut escrow.accrual_collateral, maker_id, bal_pay); };
            };
            if (table::contains(&escrow.pending_base, maker_id)) {
                let bbase = table::borrow_mut(&mut escrow.pending_base, maker_id);
                let available = balance::value(bbase);
                let take = if (available >= qty) { qty } else { available };
                if (take > 0) { let bout = balance::split(bbase, take); let coin_out = coin::from_balance(bout, ctx); transfer::public_transfer(coin_out, ctx.sender()); };
            };
            i = i + 1;
        };
        // Commit without posting remainder
        let _ = Book::commit_fill_plan(&mut market.book, plan, now, false);
    }

    // package-visible wrappers for vault usage
    public(package) fun place_dex_limit_with_escrow_bid_pkg<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_collateral: &mut Coin<C>,
        clock: &Clock,
        ctx: &mut TxContext
    ) { place_dex_limit_with_escrow_bid<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_collateral, clock, ctx) }

    /// Taker sells Base; settles immediately from maker collateral escrow, accrues maker base
    public fun place_dex_limit_with_escrow_ask<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_base: &mut Coin<Base>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let plan = Book::compute_fill_plan(&market.book, /*is_bid*/ false, price, size_base, 0, expiry_ms, now);
        let mut i = 0u64; let fills = Book::fillplan_num_fills(&plan);
        while (i < fills) {
            let f: Fill = Book::fillplan_get_fill(&plan, i);
            let maker_id = Book::fill_maker_id(&f);
            let qty = Book::fill_base_qty(&f);
            // pay base to maker accrual
            if (qty > 0) {
                let coin_pay = coin::split(taker_base, qty, ctx);
                let maker_addr = if (table::contains(&market.makers, maker_id)) { *table::borrow(&market.makers, maker_id) } else { ctx.sender() };
                transfer::public_transfer(coin_pay, maker_addr);
            };
            // deliver collateral to taker from maker escrow
            if (table::contains(&escrow.pending_collateral, maker_id)) {
                let bcol = table::borrow_mut(&mut escrow.pending_collateral, maker_id);
                let available = balance::value(bcol);
                let need = qty * price;
                let take = if (available >= need) { need } else { available };
                if (take > 0) {
                    let bout = balance::split(bcol, take);
                    let coin_out = coin::from_balance(bout, ctx);
                    transfer::public_transfer(coin_out, ctx.sender());
                };
            };
            i = i + 1;
        };
        let maybe_id = Book::commit_fill_plan(&mut market.book, plan, now, true);
        if (option::is_some(&maybe_id)) {
            let oid = *option::borrow(&maybe_id);
            table::add(&mut market.makers, oid, ctx.sender());
            table::add(&mut market.maker_sides, oid, 1);
            // escrow base for remainder
            let (filled, total) = Book::order_progress(&market.book, oid);
            let rem = total - filled;
            if (rem > 0) {
                let b = coin::split(taker_base, rem, ctx);
                let bb = coin::into_balance(b);
                table::add(&mut escrow.pending_base, oid, bb);
            };
            // bond (use quote)
            let need_quote = rem * price;
            let bond_amt = (need_quote * cfg.maker_bond_bps) / 10_000;
            if (bond_amt > 0) {
                // Without taker collateral coin, skip bond here; recommend admin to top-up via separate flow
            };
            // Explicit non-crossing guard for posted remainder
            if (rem > 0) {
                let (has_bid, bid_id) = Book::best_bid_id(&market.book, now);
                if (has_bid) {
                    let (_, bpx, _) = utils::decode_order_id(bid_id);
                    // Best bid must be strictly less than our ask price
                    assert!(bpx < price, E_NOT_CROSSED);
                };
            };
        };
    }

    /// Order-type wrappers: order_type 0=DEFAULT(post remainder), 1=IOC(no remainder), 2=FOK(all or none)
    public fun place_dex_limit_with_tif_bid<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_collateral: &mut Coin<C>,
        order_type: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        if (order_type == 1) {
            place_dex_taker_only_bid<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_collateral, clock, ctx);
            return
        };
        if (order_type == 2) {
            let now = sui::clock::timestamp_ms(clock);
            let plan = Book::compute_fill_plan(&market.book, /*is_bid*/ true, price, size_base, 0, expiry_ms, now);
            let mut i = 0u64; let fills = Book::fillplan_num_fills(&plan);
            let mut sum: u64 = 0; while (i < fills) { let f: Fill = Book::fillplan_get_fill(&plan, i); sum = sum + Book::fill_base_qty(&f); i = i + 1; };
            assert!(sum == size_base, E_NOT_CROSSED);
            place_dex_taker_only_bid<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_collateral, clock, ctx);
            return
        };
        place_dex_limit_with_escrow_bid<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_collateral, clock, ctx);
    }

    public fun place_dex_limit_with_tif_ask<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_base: &mut Coin<Base>,
        order_type: u8,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        if (order_type == 1) {
            place_dex_taker_only_ask<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_base, clock, ctx);
            return
        };
        if (order_type == 2) {
            let now = sui::clock::timestamp_ms(clock);
            let plan = Book::compute_fill_plan(&market.book, /*is_bid*/ false, price, size_base, 0, expiry_ms, now);
            let mut i = 0u64; let fills = Book::fillplan_num_fills(&plan);
            let mut sum: u64 = 0; while (i < fills) { let f: Fill = Book::fillplan_get_fill(&plan, i); sum = sum + Book::fill_base_qty(&f); i = i + 1; };
            assert!(sum == size_base, E_NOT_CROSSED);
            place_dex_taker_only_ask<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_base, clock, ctx);
            return
        };
        place_dex_limit_with_escrow_ask<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_base, clock, ctx);
    }

    /// Taker-only variant: does not post leftover as maker order (useful in flash-loan PTBs)
    public fun place_dex_taker_only_ask<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_base: &mut Coin<Base>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let plan = Book::compute_fill_plan(&market.book, /*is_bid*/ false, price, size_base, 0, expiry_ms, now);
        let mut i = 0u64; let fills = Book::fillplan_num_fills(&plan);
        while (i < fills) {
            let f: Fill = Book::fillplan_get_fill(&plan, i);
            let maker_id = Book::fill_maker_id(&f);
            let qty = Book::fill_base_qty(&f);
            if (qty > 0) {
                let coin_pay = coin::split(taker_base, qty, ctx);
                let bal_pay = coin::into_balance(coin_pay);
                if (table::contains(&escrow.accrual_base, maker_id)) { let b = table::borrow_mut(&mut escrow.accrual_base, maker_id); balance::join(b, bal_pay); } else { table::add(&mut escrow.accrual_base, maker_id, bal_pay); };
            };
            if (table::contains(&escrow.pending_collateral, maker_id)) {
                let bcol = table::borrow_mut(&mut escrow.pending_collateral, maker_id);
                let available = balance::value(bcol);
                let need = qty * price;
                let take = if (available >= need) { need } else { available };
                if (take > 0) { let bout = balance::split(bcol, take); let coin_out = coin::from_balance(bout, ctx); transfer::public_transfer(coin_out, ctx.sender()); };
            };
            i = i + 1;
        };
        let _ = Book::commit_fill_plan(&mut market.book, plan, now, false);
    }

    public(package) fun place_dex_limit_with_escrow_ask_pkg<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        price: u64,
        size_base: u64,
        expiry_ms: u64,
        taker_base: &mut Coin<Base>,
        clock: &Clock,
        ctx: &mut TxContext
    ) { place_dex_limit_with_escrow_ask<Base, C>(cfg, market, escrow, price, size_base, expiry_ms, taker_base, clock, ctx) }

    // Removed accrual claim flows; settlement is instant

    /// Cancel and refund maker bond and pending escrow back to maker
    public fun cancel_dex_clob_with_escrow<Base: store, C: store>(
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        order_id: u128,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&market.makers, order_id), E_NOT_ADMIN);
        let maker = *table::borrow(&market.makers, order_id);
        assert!(maker == ctx.sender(), E_NOT_ADMIN);
        // refund escrow
        if (table::contains(&escrow.pending_base, order_id)) { let b = table::remove(&mut escrow.pending_base, order_id); let c = coin::from_balance(b, ctx); transfer::public_transfer(c, maker); };
        if (table::contains(&escrow.pending_collateral, order_id)) { let b = table::remove(&mut escrow.pending_collateral, order_id); let c = coin::from_balance(b, ctx); transfer::public_transfer(c, maker); };
        if (table::contains(&escrow.bonds, order_id)) { let b = table::remove(&mut escrow.bonds, order_id); let c = coin::from_balance(b, ctx); transfer::public_transfer(c, maker); };
        let _ = table::remove(&mut market.makers, order_id);
        if (table::contains(&market.maker_sides, order_id)) { let _ = table::remove(&mut market.maker_sides, order_id); };
        if (table::contains(&market.claimed, order_id)) { let _ = table::remove(&mut market.claimed, order_id); };
        Book::cancel_order_by_id(&mut market.book, order_id);
    }

    /// Cancel and refund maker bond and pending escrow into provided coin stores (vault-friendly)
    public fun cancel_dex_clob_with_escrow_to_stores<Base: store, C: store>(
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        order_id: u128,
        to_base_store: &mut Coin<Base>,
        to_coll_store: &mut Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(table::contains(&market.makers, order_id), E_NOT_ADMIN);
        let maker = *table::borrow(&market.makers, order_id);
        assert!(maker == ctx.sender(), E_NOT_ADMIN);
        if (table::contains(&escrow.pending_base, order_id)) {
            let b = table::remove(&mut escrow.pending_base, order_id);
            let c = coin::from_balance(b, ctx);
            coin::join(to_base_store, c);
        };
        if (table::contains(&escrow.pending_collateral, order_id)) {
            let b = table::remove(&mut escrow.pending_collateral, order_id);
            let c = coin::from_balance(b, ctx);
            coin::join(to_coll_store, c);
        };
        if (table::contains(&escrow.bonds, order_id)) {
            let b = table::remove(&mut escrow.bonds, order_id);
            let c = coin::from_balance(b, ctx);
            coin::join(to_coll_store, c);
        };
        let _ = table::remove(&mut market.makers, order_id);
        if (table::contains(&market.maker_sides, order_id)) { let _ = table::remove(&mut market.maker_sides, order_id); };
        if (table::contains(&market.claimed, order_id)) { let _ = table::remove(&mut market.claimed, order_id); };
        Book::cancel_order_by_id(&mut market.book, order_id);
    }

    public(package) fun cancel_dex_clob_with_escrow_to_stores_pkg<Base: store, C: store>(
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        order_id: u128,
        to_base_store: &mut Coin<Base>,
        to_coll_store: &mut Coin<C>,
        ctx: &mut TxContext
    ) { cancel_dex_clob_with_escrow_to_stores<Base, C>(market, escrow, order_id, to_base_store, to_coll_store, ctx) }

    /// Auto-match steps without settlement (advance book only)
    public fun match_step_auto<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        max_steps: u64,
        min_price: u64,
        max_price: u64,
        clock: &Clock,
        _ctx: &TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = sui::clock::timestamp_ms(clock);
        let mut steps = 0u64;
        while (steps < max_steps) {
            let (has_ask, ask_id) = Book::best_ask_id(&market.book, now);
            let (has_bid, bid_id) = Book::best_bid_id(&market.book, now);
            if (!has_ask || !has_bid) { break };
            let (_, apx, _) = utils::decode_order_id(ask_id);
            let (_, bpx, _) = utils::decode_order_id(bid_id);
            if (bpx < apx) { break };
            assert!(apx >= min_price && apx <= max_price, E_BAD_BOUNDS);
            let (af, at) = Book::order_progress(&market.book, ask_id);
            let (bf, bt) = Book::order_progress(&market.book, bid_id);
            let ar = at - af; let br = bt - bf; let q = if (ar < br) { ar } else { br };
            if (q == 0) { break };
            Book::commit_maker_fill(&mut market.book, ask_id, true, apx, q, now);
            Book::commit_maker_fill(&mut market.book, bid_id, false, apx, q, now);
            steps = steps + 1;
        }
    }

    /// GC expired orders and slash bonds
    public fun gc_step<Base: store, C: store>(
        cfg: &DexConfig,
        market: &mut DexMarket<Base, C>,
        escrow: &mut DexEscrow<Base, C>,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        clock: &Clock,
        now_ts: u64,
        max_removals: u64,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let ids = Book::remove_expired_collect(&mut market.book, now_ts, max_removals);
        let mut i = 0u64; let n = vector::length(&ids);
        while (i < n) {
            let oid = ids[i];
            if (table::contains(&escrow.bonds, oid)) {
                let bref = table::borrow_mut(&mut escrow.bonds, oid);
                let bval = balance::value(bref);
                if (bval > 0) {
                    let mut coin_all = coin::from_balance(balance::split(bref, bval), ctx);
                    let reward = (bval * cfg.keeper_reward_bps) / 10_000;
                    if (reward > 0) { let to_keeper = coin::split(&mut coin_all, reward, ctx); transfer::public_transfer(to_keeper, ctx.sender()); };
                    let epoch_id = BotRewards::current_epoch(points, clock);
                    TreasuryMod::deposit_collateral_with_rewards_for_epoch(
                        treasury,
                        bot_treasury,
                        epoch_id,
                        coin_all,
                        b"dex_gc_slash".to_string(),
                        ctx.sender(),
                        ctx
                    );
                };
            };
            if (table::contains(&market.makers, oid)) { let _ = table::remove(&mut market.makers, oid); };
            if (table::contains(&market.maker_sides, oid)) { let _ = table::remove(&mut market.maker_sides, oid); };
            if (table::contains(&market.claimed, oid)) { let _ = table::remove(&mut market.claimed, oid); };
            i = i + 1;
        };
    }

    public fun order_buy_info<Base: store, C: store>(o: &CoinOrderBuy<Base, C>): (address, u64, u64, u64, u64, u64) { (o.owner, o.price, o.remaining_base, o.created_at_ms, o.expiry_ms, coin::value(&o.escrow_collateral)) }

    public fun order_sell_info<Base: store>(o: &CoinOrderSell<Base>): (address, u64, u64, u64, u64, u64) { (o.owner, o.price, o.remaining_base, o.created_at_ms, o.expiry_ms, coin::value(&o.escrow_base)) }

}


