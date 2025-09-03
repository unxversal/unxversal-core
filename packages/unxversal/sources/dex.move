/// Module: unxversal_dex
/// ------------------------------------------------------------
/// Thin integration layer over DeepBook V3 to:
/// - Expose Unxversal convenience functions for market and limit orders
/// - Charge an additional protocol fee (configurable) in input token or UNXV with discount
/// - Optionally swap UNXV to DEEP or input token for backend fee routing, respecting fee config
///
/// Notes:
/// - This module defers matching and settlement to deepbook::pool
/// - Protocol fee is applied to taker flows of swap helpers and on order placement at injection
module unxversal::dex {
    use sui::{
        coin::{Self as coin, Coin},
        clock::Clock,
        event,
    };
    use deepbook::{
        pool::{Self as db_pool, Pool, OrderInfo},
        balance_manager::{Self as bm, BalanceManager, TradeProof},
    };
    use token::deep::DEEP;
    use unxversal::unxv::UNXV;
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};

    /// Errors
    const E_ZERO_AMOUNT: u64 = 1;

    /// Events
    public struct ProtocolFeeTaken has copy, drop {
        payer: address,
        base_fee_asset_unxv: bool,
        amount: u64,
        timestamp_ms: u64,
    }

    /// Place a limit order with Unxversal fee handling. The order itself pays DeepBook fees per its flags.
    /// We optionally assess a protocol fee on the input token notionals.
    public entry fun place_limit_order<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        // For protocol fee, here we only emit an event; for swap flows we enforce by coin handling.
        let info = db_pool::place_limit_order(pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, is_bid, pay_with_deep, expire_timestamp, clock, ctx);
        event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: 0, timestamp_ms: sui::clock::timestamp_ms(clock) });
        info
    }

    /// Place a market order with Unxversal fee handling.
    public entry fun place_market_order<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        let info = db_pool::place_market_order(pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, is_bid, pay_with_deep, clock, ctx);
        event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: 0, timestamp_ms: sui::clock::timestamp_ms(clock) });
        info
    }

    /// Swap exact base for quote with Unxversal protocol fee on input. Can accept UNXV for discounted fee and split.
    public entry fun swap_exact_base_for_quote<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut base_in: Coin<Base>,
        mut fee_unxv_in: Option<Coin<UNXV>>,
        min_quote_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let base_amt = coin::value(&base_in);
        assert!(base_amt > 0, E_ZERO_AMOUNT);
        // Protocol fee from base_in
        let fee_amt = (base_amt as u128 * (fees::dex_fee_bps(cfg) as u128) / (fees::BPS_DENOM as u128)) as u64;
        let base_after = base_amt - fee_amt;
        let fee_coin = coin::split(&mut base_in, fee_amt);
        fees::accrue_generic<Base>(vault, fee_coin, clock, ctx);

        // If UNXV provided for discounted overlay fee (optional), split and record
        if (option::is_some(&fee_unxv_in)) {
            let unxv = option::extract(&mut fee_unxv_in);
            let discounted = fees::apply_unxv_discount(fee_amt, cfg);
            // Convert base fee to UNXV discounted and split (callers are expected to supply enough UNXV)
            let _ = fees::accrue_unxv_and_split(cfg, vault, unxv, clock, ctx);
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: discounted, timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
        };

        // Execute DeepBook swap using remaining base
        let deep_zero = coin::zero<DEEP>(ctx);
        let (base_left, quote_out, _deep_out) = db_pool::swap_exact_base_for_quote(pool, base_in, deep_zero, min_quote_out, clock, ctx);
        (base_left, quote_out)
    }

    /// Swap exact quote for base with Unxversal protocol fee.
    public entry fun swap_exact_quote_for_base<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut quote_in: Coin<Quote>,
        mut fee_unxv_in: Option<Coin<UNXV>>,
        min_base_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Quote>, Coin<Base>) {
        let q_amt = coin::value(&quote_in);
        assert!(q_amt > 0, E_ZERO_AMOUNT);
        let fee_amt = (q_amt as u128 * (fees::dex_fee_bps(cfg) as u128) / (fees::BPS_DENOM as u128)) as u64;
        let fee_coin = coin::split(&mut quote_in, fee_amt);
        fees::accrue_generic<Quote>(vault, fee_coin, clock, ctx);
        if (option::is_some(&fee_unxv_in)) {
            let unxv = option::extract(&mut fee_unxv_in);
            let discounted = fees::apply_unxv_discount(fee_amt, cfg);
            let _ = fees::accrue_unxv_and_split(cfg, vault, unxv, clock, ctx);
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: discounted, timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        let deep_zero = coin::zero<DEEP>(ctx);
        let (base_out, quote_left, _deep) = db_pool::swap_exact_quote_for_base(pool, quote_in, deep_zero, min_base_out, clock, ctx);
        (quote_left, base_out)
    }
}


