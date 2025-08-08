module unxversal::dex {
    /*******************************
    * On-chain DEX (order objects, permissionless matching)
    * - Coin<Base> orderbook (escrowed buy/sell orders)
    * - Taker-only fees with optional UNXV discount
    *******************************/
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::coin::{Self as Coin, Coin};
    use sui::clock::Clock;
    use sui::event;
    use std::string::String;
    use std::vector;
    use std::time;

    use usdc::usdc::USDC;
    use pyth::price_info::PriceInfoObject;
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{SynthRegistry, AdminCap};
    use unxversal::oracle::{OracleConfig, get_latest_price};
    use unxversal::common::FeeCollected;
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use std::vec_set::{Self as VecSet};

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

    /// Escrowed sell order: user sells Base for USDC at price (USDC per 1 Base)
    public struct CoinOrderSell<Base> has key, store {
        id: UID,
        owner: address,
        price: u64,
        remaining_base: u64,
        created_at_ms: u64,
        expiry_ms: u64,
        escrow_base: Coin<Base>,
    }

    /// Escrowed buy order: user buys Base with USDC at price (USDC per 1 Base)
    /// size_base is implied by escrow_usdc / price (we also store remaining_base)
    public struct CoinOrderBuy<Base> has key, store {
        id: UID,
        owner: address,
        price: u64,
        remaining_base: u64,
        created_at_ms: u64,
        expiry_ms: u64,
        escrow_usdc: Coin<USDC>,
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
        assert!(VecSet::contains(&registry.admin_addrs, addr), E_NOT_ADMIN);
    }

    public entry fun init_dex(registry: &SynthRegistry, treasury: &Treasury, ctx: &mut TxContext): DexConfig {
        assert_is_admin(registry, ctx.sender());
        DexConfig {
            id: object::new(ctx),
            treasury_id: object::id(treasury),
            trade_fee_bps: 30,         // 0.30%
            unxv_discount_bps: 2000,   // 20% discount
            maker_rebate_bps: 0,
            paused: false,
        }
    }

    public entry fun set_trade_fee_bps(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, bps: u64) { assert_is_admin(registry, ctx.sender()); cfg.trade_fee_bps = bps; }
    public entry fun set_unxv_discount_bps(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, bps: u64) { assert_is_admin(registry, ctx.sender()); cfg.unxv_discount_bps = bps; }
    public entry fun set_maker_rebate_bps(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig, bps: u64) { assert_is_admin(registry, ctx.sender()); cfg.maker_rebate_bps = bps; }
    public entry fun pause(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig) { assert_is_admin(registry, ctx.sender()); cfg.paused = true; }
    public entry fun resume(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut DexConfig) { assert_is_admin(registry, ctx.sender()); cfg.paused = false; }

    /*******************************
    * Order placement / cancellation (escrow based)
    *******************************/
    public entry fun place_coin_sell_order<Base>(cfg: &DexConfig, price: u64, size_base: u64, mut base: Coin<Base>, expiry_ms: u64, ctx: &mut TxContext): CoinOrderSell<Base> {
        assert!(!cfg.paused, E_PAUSED);
        assert!(size_base > 0, E_ZERO_AMOUNT);
        let have = Coin::value(&base);
        assert!(have >= size_base, E_INSUFFICIENT_PAYMENT);
        let escrow = Coin::split(&mut base, size_base, ctx);
        transfer::public_transfer(base, ctx.sender());
        CoinOrderSell<Base> { id: object::new(ctx), owner: ctx.sender(), price, remaining_base: size_base, created_at_ms: time::now_ms(), expiry_ms, escrow_base: escrow }
    }

    public entry fun place_coin_buy_order<Base>(cfg: &DexConfig, price: u64, size_base: u64, mut usdc: Coin<USDC>, expiry_ms: u64, ctx: &mut TxContext): CoinOrderBuy<Base> {
        assert!(!cfg.paused, E_PAUSED);
        assert!(size_base > 0, E_ZERO_AMOUNT);
        let need_usdc = price * size_base;
        let have = Coin::value(&usdc);
        assert!(have >= need_usdc, E_INSUFFICIENT_PAYMENT);
        let escrow = Coin::split(&mut usdc, need_usdc, ctx);
        transfer::public_transfer(usdc, ctx.sender());
        CoinOrderBuy<Base> { id: object::new(ctx), owner: ctx.sender(), price, remaining_base: size_base, created_at_ms: time::now_ms(), expiry_ms, escrow_usdc: escrow }
    }

    public entry fun cancel_coin_sell_order<Base>(order: CoinOrderSell<Base>, ctx: &mut TxContext) {
        assert!(order.owner == ctx.sender(), E_NOT_ADMIN);
        transfer::public_transfer(order.escrow_base, order.owner);
        // delete object
        let CoinOrderSell<Base> { id, owner: _, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_base: _ } = order;
        object::delete(id);
    }

    public entry fun cancel_coin_buy_order<Base>(order: CoinOrderBuy<Base>, ctx: &mut TxContext) {
        assert!(order.owner == ctx.sender(), E_NOT_ADMIN);
        transfer::public_transfer(order.escrow_usdc, order.owner);
        let CoinOrderBuy<Base> { id, owner: _, price: _, remaining_base: _, created_at_ms: _, expiry_ms: _, escrow_usdc: _ } = order;
        object::delete(id);
    }

    /*******************************
    * Match coin orders (maker/taker); taker pays fee, optional UNXV discount
    *******************************/
    public entry fun match_coin_orders<Base>(
        cfg: &mut DexConfig,
        buy: &mut CoinOrderBuy<Base>,
        sell: &mut CoinOrderSell<Base>,
        max_fill_base: u64,
        taker_is_buyer: bool,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let now = time::now_ms();
        if (buy.expiry_ms != 0) { assert!(now <= buy.expiry_ms, E_PAUSED); };
        if (sell.expiry_ms != 0) { assert!(now <= sell.expiry_ms, E_PAUSED); };
        // Crossed
        assert!(buy.price >= sell.price, E_PAUSED);
        let trade_price = if taker_is_buyer { sell.price } else { buy.price };
        let fill = {
            let a = if buy.remaining_base < sell.remaining_base { buy.remaining_base } else { sell.remaining_base };
            if (a < max_fill_base) { a } else { max_fill_base }
        };
        assert!(fill > 0, E_ZERO_AMOUNT);

        // Move base from sell escrow to buyer
        let base_out = Coin::split(&mut sell.escrow_base, fill, ctx);
        // Deliver base to buyer immediately (escrow unlock)
        transfer::public_transfer(base_out, buy.owner);
        // Move USDC from buy escrow to seller minus fee
        let usdc_owed = trade_price * fill;
        // Fee
        let trade_fee = (usdc_owed * cfg.trade_fee_bps) / 10_000;
        let discount_usdc = (trade_fee * cfg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv_i64 = get_latest_price(&oracle_cfg, &clock, unxv_price);
            let price_unxv_u64 = price_unxv_i64 as u64;
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = Coin::zero<UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    Coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
                    let mut vec_unxv = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    let mut t = object::borrow_mut<Treasury>(cfg.treasury_id);
                    TreasuryMod::deposit_unxv(&mut t, vec_unxv, b"otc_match".to_string(), buy.owner, ctx);
                    transfer::public_transfer(merged, buy.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, buy.owner);
                }
            }
        }
        let usdc_fee_to_collect = if (discount_applied) { trade_fee - discount_usdc } else { trade_fee };
        let usdc_net_to_seller = if (usdc_fee_to_collect <= usdc_owed) { usdc_owed - usdc_fee_to_collect } else { 0 };
        if (usdc_net_to_seller > 0) {
            let to_seller = Coin::split(&mut buy.escrow_usdc, usdc_net_to_seller, ctx);
            transfer::public_transfer(to_seller, sell.owner);
        }
        if (usdc_fee_to_collect > 0) {
            let fee_coin = Coin::split(&mut buy.escrow_usdc, usdc_fee_to_collect, ctx);
            let mut t = object::borrow_mut<Treasury>(cfg.treasury_id);
            TreasuryMod::deposit_usdc(&mut t, fee_coin, b"otc_match".to_string(), buy.owner, ctx);
        }

        // Update remaining
        buy.remaining_base = buy.remaining_base - fill;
        sell.remaining_base = sell.remaining_base - fill;

        event::emit(FeeCollected { fee_type: b"otc_match".to_string(), amount: trade_fee, asset_type: b"USDC".to_string(), user: if (taker_is_buyer) { buy.owner } else { sell.owner }, unxv_discount_applied: discount_applied, timestamp: time::now_ms() });
    }

}


