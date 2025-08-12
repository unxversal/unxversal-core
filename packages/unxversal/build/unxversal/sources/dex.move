module unxversal::dex {
    /*******************************
    * On-chain DEX (order objects, permissionless matching)
    * - Coin<Base> orderbook (escrowed buy/sell orders)
    * - Taker-only fees with optional UNXV discount
    *******************************/
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;
    use std::string::String;

    // Removed std::time as it doesn't exist

    // Removed USDC dependency - using admin-set collateral pattern instead
    use unxversal::oracle::PriceInfoObject;
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{SynthRegistry, AdminCap};
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::common::{Self as CommonMod};
    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use sui::vec_set::{VecSet};

    const E_INSUFFICIENT_PAYMENT: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_PAUSED: u64 = 3;
    const E_NOT_ADMIN: u64 = 4;

    /*******************************
    * Events & Config
    *******************************/
    public struct SwapExecuted has copy, drop {
        market: String,         // e.g., "COIN/SYNTH", "UNXV/USDC"
        base: String,           // base symbol for context (e.g., coin symbol or synth symbol)
        quote: String,          // quote symbol for context
        price: u64,             // units of quote per 1 base
        size: u64,              // base size filled
        payer: address,
        receiver: address,
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
        fee_paid_usdc: u64,
        unxv_discount_applied: bool,
        maker_rebate_usdc: u64,
        timestamp: u64,
    }

    /// Escrowed sell order: user sells Base for USDC at price (USDC per 1 Base)
    public struct CoinOrderSell<phantom Base> has key, store {
        id: UID,
        owner: address,
        price: u64,
        remaining_base: u64,
        created_at_ms: u64,
        expiry_ms: u64,
        escrow_base: Coin<Base>,
    }

    /// Escrowed buy order: user buys Base with admin-set collateral at price (collateral per 1 Base)
    /// size_base is implied by escrow_collateral / price (we also store remaining_base)
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
    }

    fun assert_is_admin(registry: &SynthRegistry, addr: address) {
        assert!(unxversal::synthetics::check_is_admin(registry, addr), E_NOT_ADMIN);
    }

    public fun init_dex(registry: &SynthRegistry, treasury_id: ID, ctx: &mut tx_context::TxContext): DexConfig {
        assert_is_admin(registry, tx_context::sender(ctx));
        DexConfig {
            id: sui::object::new(ctx),
            treasury_id,
            trade_fee_bps: 30,         // 0.30%
            unxv_discount_bps: 2000,   // 20% discount
            maker_rebate_bps: 0,
            paused: false,
        }
    }

    public entry fun set_trade_fee_bps(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, bps: u64, ctx: &tx_context::TxContext) { assert_is_admin(registry, tx_context::sender(ctx)); cfg.trade_fee_bps = bps; }
    public entry fun set_unxv_discount_bps(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, bps: u64, ctx: &tx_context::TxContext) { assert_is_admin(registry, tx_context::sender(ctx)); cfg.unxv_discount_bps = bps; }
    public entry fun set_maker_rebate_bps(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, bps: u64, ctx: &tx_context::TxContext) { assert_is_admin(registry, tx_context::sender(ctx)); cfg.maker_rebate_bps = bps; }
    public entry fun pause(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, ctx: &tx_context::TxContext) { assert_is_admin(registry, tx_context::sender(ctx)); cfg.paused = true; }
    public entry fun resume(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, ctx: &tx_context::TxContext) { assert_is_admin(registry, tx_context::sender(ctx)); cfg.paused = false; }

    /*******************************
    * Order placement / cancellation (escrow based)
    *******************************/
    public fun place_coin_sell_order<Base>(cfg: &DexConfig, price: u64, size_base: u64, mut base: Coin<Base>, expiry_ms: u64, ctx: &mut tx_context::TxContext): CoinOrderSell<Base> {
        assert!(!cfg.paused, E_PAUSED);
        assert!(size_base > 0, E_ZERO_AMOUNT);
        let have = base.value();
        assert!(have >= size_base, E_INSUFFICIENT_PAYMENT);
        let escrow = base.split(size_base, ctx);
        sui::transfer::public_transfer(base, tx_context::sender(ctx));
        let order = CoinOrderSell<Base> { id: sui::object::new(ctx), owner: tx_context::sender(ctx), price, remaining_base: size_base, created_at_ms: 0u64, expiry_ms, escrow_base: escrow };
        event::emit(CoinOrderPlaced { order_id: sui::object::id(&order), owner: order.owner, side: 1, price, size_base, created_at_ms: order.created_at_ms, expiry_ms });
        order
    }

    public fun place_coin_buy_order<C, Base>(cfg: &DexConfig, price: u64, size_base: u64, mut collateral: Coin<C>, expiry_ms: u64, ctx: &mut tx_context::TxContext): CoinOrderBuy<Base, C> {
        assert!(!cfg.paused, E_PAUSED);
        assert!(size_base > 0, E_ZERO_AMOUNT);
        let need_collateral = price * size_base;
        let have = collateral.value();
        assert!(have >= need_collateral, E_INSUFFICIENT_PAYMENT);
        let escrow = collateral.split(need_collateral, ctx);
        sui::transfer::public_transfer(collateral, tx_context::sender(ctx));
        let order = CoinOrderBuy<Base, C> { id: sui::object::new(ctx), owner: tx_context::sender(ctx), price, remaining_base: size_base, created_at_ms: 0u64, expiry_ms, escrow_collateral: escrow };
        event::emit(CoinOrderPlaced { order_id: sui::object::id(&order), owner: order.owner, side: 0, price, size_base, created_at_ms: order.created_at_ms, expiry_ms });
        order
    }

    public entry fun cancel_coin_sell_order<Base>(order: CoinOrderSell<Base>, ctx: &mut tx_context::TxContext) {
        assert!(order.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        let order_id = sui::object::id(&order);
        let CoinOrderSell<Base> { id, owner, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_base } = order;
        sui::transfer::public_transfer(escrow_base, owner);
        object::delete(id);
        event::emit(CoinOrderCancelled { order_id, owner: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun cancel_coin_buy_order<Base, C>(order: CoinOrderBuy<Base, C>, ctx: &mut tx_context::TxContext) {
        assert!(order.owner == tx_context::sender(ctx), E_NOT_ADMIN);
        let order_id = sui::object::id(&order);
        let CoinOrderBuy<Base, C> { id, owner, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_collateral } = order;
        sui::transfer::public_transfer(escrow_collateral, owner);
        event::emit(CoinOrderCancelled { order_id, owner: tx_context::sender(ctx), timestamp: 0u64 });
        object::delete(id);
    }

    /*******************************
    * Match coin orders (maker/taker); taker pays fee, optional UNXV discount
    *******************************/
    public fun match_coin_orders<Base, C>(
        cfg: &DexConfig,
        buy: &mut CoinOrderBuy<Base, C>,
        sell: &mut CoinOrderSell<Base>,
        max_fill_base: u64,
        taker_is_buyer: bool,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        min_price: u64,
        max_price: u64,
        ctx: &mut tx_context::TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = 0u64;
        if (buy.expiry_ms != 0) { assert!(now <= buy.expiry_ms, E_PAUSED); };
        if (sell.expiry_ms != 0) { assert!(now <= sell.expiry_ms, E_PAUSED); };
        // Crossed
        assert!(buy.price >= sell.price, E_PAUSED);
        let trade_price = if (taker_is_buyer) { sell.price } else { buy.price };
        // Slippage bounds
        assert!(trade_price >= min_price && trade_price <= max_price, E_PAUSED);
        let fill = {
            let a = if (buy.remaining_base < sell.remaining_base) { buy.remaining_base } else { sell.remaining_base };
            if (a < max_fill_base) { a } else { max_fill_base }
        };
        assert!(fill > 0, E_ZERO_AMOUNT);
        
        // TODO: Complete implementation with proper fee handling and settlement
        // Placeholder - actual implementation would handle the order matching
        buy.remaining_base = buy.remaining_base - fill;
        sell.remaining_base = sell.remaining_base - fill;

        // Move base from sell escrow to buyer
        let base_out = sell.escrow_base.split(fill, ctx);
        // Deliver base to buyer immediately (escrow unlock)
        sui::transfer::public_transfer(base_out, buy.owner);
        // Move USDC from buy escrow to seller minus fee
        let usdc_owed = trade_price * fill;
        // Fee
        let trade_fee = (usdc_owed * cfg.trade_fee_bps) / 10_000;
        let discount_usdc = (trade_fee * cfg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && std::vector::length(&unxv_payment) > 0) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < std::vector::length(&unxv_payment)) {
                    let c = std::vector::pop_back(&mut unxv_payment);
                    merged.join(c);
                    i = i + 1;
                };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vec_unxv = std::vector::empty<Coin<UNXV>>();
                    std::vector::push_back(&mut vec_unxv, exact);
                    TreasuryMod::deposit_unxv(treasury, vec_unxv, b"otc_match".to_string(), buy.owner, ctx);
                    sui::transfer::public_transfer(merged, buy.owner);
                    discount_applied = true;
                } else {
                    sui::transfer::public_transfer(merged, buy.owner);
                }
            };
        };
        
        // Consume any remaining UNXV payment vector
        while (std::vector::length(&unxv_payment) > 0) {
            let remaining_coin = std::vector::pop_back(&mut unxv_payment);
            sui::transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
        };
        std::vector::destroy_empty(unxv_payment);
        let usdc_fee_to_collect = if (discount_applied) { trade_fee - discount_usdc } else { trade_fee };
        let maker_rebate = (trade_fee * cfg.maker_rebate_bps) / 10_000;
        let usdc_net_to_seller = if (usdc_fee_to_collect <= usdc_owed) { usdc_owed - usdc_fee_to_collect } else { 0 };
        if (usdc_net_to_seller > 0) {
            let to_seller = buy.escrow_collateral.split(usdc_net_to_seller, ctx);
            sui::transfer::public_transfer(to_seller, sell.owner);
        };
        if (usdc_fee_to_collect > 0) {
            let mut fee_coin_all = buy.escrow_collateral.split(usdc_fee_to_collect, ctx);
            if (maker_rebate > 0 && maker_rebate < usdc_fee_to_collect) {
                let to_maker = fee_coin_all.split(maker_rebate, ctx);
                let maker_addr = if (taker_is_buyer) { sell.owner } else { buy.owner };
                sui::transfer::public_transfer(to_maker, maker_addr);
            };
            TreasuryMod::deposit_usdc(treasury, fee_coin_all, b"otc_match".to_string(), if (taker_is_buyer) { buy.owner } else { sell.owner }, ctx);
        };

        // Update remaining
        buy.remaining_base = buy.remaining_base - fill;
        sell.remaining_base = sell.remaining_base - fill;

        CommonMod::emit_fee_collected_event(b"otc_match".to_string(), trade_fee, b"USDC".to_string(), if (taker_is_buyer) { buy.owner } else { sell.owner }, discount_applied, 0u64);
        event::emit(CoinOrderMatched { buy_order_id: sui::object::id(buy), sell_order_id: sui::object::id(sell), price: trade_price, size_base: fill, taker_is_buyer, fee_paid_usdc: usdc_fee_to_collect, unxv_discount_applied: discount_applied, maker_rebate_usdc: maker_rebate, timestamp: 0u64 });
    }

    /*******************************
    * Read-only helpers (bots/indexers)
    *******************************/
    public fun get_config_treasury_id(cfg: &DexConfig): ID { cfg.treasury_id }

    public fun get_config_fees(cfg: &DexConfig): (u64, u64, u64, bool) { (cfg.trade_fee_bps, cfg.unxv_discount_bps, cfg.maker_rebate_bps, cfg.paused) }

    public fun order_buy_info<Base, C>(o: &CoinOrderBuy<Base, C>): (address, u64, u64, u64, u64, u64) { (o.owner, o.price, o.remaining_base, o.created_at_ms, o.expiry_ms, coin::value(&o.escrow_collateral)) }

    public fun order_sell_info<Base>(o: &CoinOrderSell<Base>): (address, u64, u64, u64, u64, u64) { (o.owner, o.price, o.remaining_base, o.created_at_ms, o.expiry_ms, o.escrow_base.value()) }

}


