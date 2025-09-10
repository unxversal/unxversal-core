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
#[allow(lint(self_transfer))]
module unxversal::dex {
    use sui::{
        coin::{Self as coin, Coin},
        clock::Clock,
        event,
    };
    use std::type_name;
    // default aliases for option and transfer are available
    use deepbook::{
        pool::{Self as db_pool, Pool},
        balance_manager::{Self as bm, BalanceManager, TradeProof},
        registry::{Registry as DBRegistry},
    };
    use deepbook::order_info::OrderInfo;
    use deepbook::math;
    use token::deep::DEEP;
    use unxversal::unxv::UNXV;
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::staking::{Self as staking, StakingPool};
    use unxversal::rewards::{Self as rewards, Rewards};

    /// Errors
    const E_ZERO_AMOUNT: u64 = 1;
    const E_POOL_FEE_NOT_PAID: u64 = 2;
    const E_UNXV_REQUIRED: u64 = 3;
    const E_INJECTION_FEE_NOT_PAID: u64 = 4;

    /// Events
    public struct ProtocolFeeTaken has copy, drop {
        payer: address,
        base_fee_asset_unxv: bool,
        amount: u64,
        asset: type_name::TypeName,
        timestamp_ms: u64,
    }

    public struct PoolCreationFeePaid has copy, drop {
        payer: address,
        amount_unxv: u64,
        timestamp_ms: u64,
    }

    // maker rebates removed

    /// Place a limit order with Unxversal fee handling. The order itself pays DeepBook fees per its flags.
    /// We optionally assess a protocol fee on the input token notionals.
    public fun place_limit_order<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
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
        // Delegate to DeepBook; protocol fee for order placement is not charged.
        db_pool::place_limit_order(pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, is_bid, pay_with_deep, expire_timestamp, clock, ctx)
    }

    /// Place a market order with Unxversal fee handling.
    public fun place_market_order<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        db_pool::place_market_order(pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, is_bid, pay_with_deep, clock, ctx)
    }

    // === Order placement with Unxversal injection fee (input token) ===
    /// Limit BID: charge injection fee in Quote input token proportional to quantity * price.
    /// Supports UNXV discount as a flag (UNXV refunded).
    public fun place_limit_order_with_protocol_fee_bid<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut fee_payment_quote: Coin<Quote>,
        mut maybe_unxv: Option<Coin<UNXV>>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        // Notional in Quote units using DeepBook scaling
        let notional_quote = math::mul(quantity, price);
        let (_, maker_eff) = fees::apply_discounts_dex(
            fees::dex_taker_fee_bps(cfg),
            fees::dex_maker_fee_bps(cfg),
            option::is_some(&maybe_unxv),
            staking_pool,
            ctx.sender(),
            cfg,
        );
        let fee_amt = (notional_quote as u128 * (maker_eff as u128) / (fees::bps_denom() as u128)) as u64;
        let paid = coin::value(&fee_payment_quote);
        assert!(paid >= fee_amt, E_INJECTION_FEE_NOT_PAID);
        let fee_coin = coin::split(&mut fee_payment_quote, fee_amt, ctx);
        fees::accrue_generic<Quote>(vault, fee_coin, clock, ctx);
        if (option::is_some(&maybe_unxv)) {
            let unxv = option::extract(&mut maybe_unxv);
            transfer::public_transfer(unxv, ctx.sender());
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        option::destroy_none(maybe_unxv);
        // refund change
        transfer::public_transfer(fee_payment_quote, ctx.sender());
        db_pool::place_limit_order(pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, true /* is_bid */, pay_with_deep, expire_timestamp, clock, ctx)
    }

    /// Limit ASK: charge injection fee in Base input token proportional to quantity.
    /// Supports UNXV discount as a flag (UNXV refunded).
    public fun place_limit_order_with_protocol_fee_ask<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut fee_payment_base: Coin<Base>,
        mut maybe_unxv: Option<Coin<UNXV>>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        pay_with_deep: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        let (_, maker_eff) = fees::apply_discounts_dex(
            fees::dex_taker_fee_bps(cfg),
            fees::dex_maker_fee_bps(cfg),
            option::is_some(&maybe_unxv),
            staking_pool,
            ctx.sender(),
            cfg,
        );
        let fee_amt = ((quantity as u128) * (maker_eff as u128) / (fees::bps_denom() as u128)) as u64;
        let paid = coin::value(&fee_payment_base);
        assert!(paid >= fee_amt, E_INJECTION_FEE_NOT_PAID);
        let fee_coin = coin::split(&mut fee_payment_base, fee_amt, ctx);
        fees::accrue_generic<Base>(vault, fee_coin, clock, ctx);
        if (option::is_some(&maybe_unxv)) {
            let unxv = option::extract(&mut maybe_unxv);
            transfer::public_transfer(unxv, ctx.sender());
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        option::destroy_none(maybe_unxv);
        transfer::public_transfer(fee_payment_base, ctx.sender());
        db_pool::place_limit_order(pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, false /* is_bid */, pay_with_deep, expire_timestamp, clock, ctx)
    }

    /// Market BID: charge injection fee in Quote input token using mid-price.
    public fun place_market_order_with_protocol_fee_bid<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut fee_payment_quote: Coin<Quote>,
        mut maybe_unxv: Option<Coin<UNXV>>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        let mid = db_pool::mid_price<Base, Quote>(pool, clock);
        let notional_quote = math::mul(quantity, mid);
        let (_, maker_eff) = fees::apply_discounts_dex(
            fees::dex_taker_fee_bps(cfg),
            fees::dex_maker_fee_bps(cfg),
            option::is_some(&maybe_unxv),
            staking_pool,
            ctx.sender(),
            cfg,
        );
        let fee_amt = (notional_quote as u128 * (maker_eff as u128) / (fees::bps_denom() as u128)) as u64;
        let paid = coin::value(&fee_payment_quote);
        assert!(paid >= fee_amt, E_INJECTION_FEE_NOT_PAID);
        let fee_coin = coin::split(&mut fee_payment_quote, fee_amt, ctx);
        fees::accrue_generic<Quote>(vault, fee_coin, clock, ctx);
        if (option::is_some(&maybe_unxv)) {
            let unxv = option::extract(&mut maybe_unxv);
            transfer::public_transfer(unxv, ctx.sender());
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        option::destroy_none(maybe_unxv);
        transfer::public_transfer(fee_payment_quote, ctx.sender());
        db_pool::place_market_order(pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, true /* is_bid */, pay_with_deep, clock, ctx)
    }

    /// Market ASK: charge injection fee in Base input token.
    public fun place_market_order_with_protocol_fee_ask<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        mut fee_payment_base: Coin<Base>,
        mut maybe_unxv: Option<Coin<UNXV>>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        pay_with_deep: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        assert!(quantity > 0, E_ZERO_AMOUNT);
        let (_, maker_eff) = fees::apply_discounts_dex(
            fees::dex_taker_fee_bps(cfg),
            fees::dex_maker_fee_bps(cfg),
            option::is_some(&maybe_unxv),
            staking_pool,
            ctx.sender(),
            cfg,
        );
        let fee_amt = ((quantity as u128) * (maker_eff as u128) / (fees::bps_denom() as u128)) as u64;
        let paid = coin::value(&fee_payment_base);
        assert!(paid >= fee_amt, E_INJECTION_FEE_NOT_PAID);
        let fee_coin = coin::split(&mut fee_payment_base, fee_amt, ctx);
        fees::accrue_generic<Base>(vault, fee_coin, clock, ctx);
        if (option::is_some(&maybe_unxv)) {
            let unxv = option::extract(&mut maybe_unxv);
            transfer::public_transfer(unxv, ctx.sender());
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        option::destroy_none(maybe_unxv);
        transfer::public_transfer(fee_payment_base, ctx.sender());
        db_pool::place_market_order(pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, false /* is_bid */, pay_with_deep, clock, ctx)
    }

    // === Permissionless pool creation with Unxversal fee in UNXV ===
    /// Creates a new DeepBook pool and charges an Unxversal UNXV creation fee set in FeeConfig.
    public fun create_permissionless_pool<Base, Quote>(
        registry: &mut DBRegistry,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut fee_payment_unxv: Coin<UNXV>,
        tick_size: u64,
        lot_size: u64,
        min_size: u64,
        staking_pool: &mut StakingPool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let required = fees::pool_creation_fee_unxv(cfg);
        let paid = coin::value(&fee_payment_unxv);
        assert!(paid >= required, E_POOL_FEE_NOT_PAID);
        let pay_exact = coin::split(&mut fee_payment_unxv, required, ctx);
        // split UNXV fee to staking/treasury/burn and consume outputs
        let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, vault, pay_exact, clock, ctx);
        staking::add_weekly_reward(staking_pool, stakers_coin, clock);
        transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
        event::emit(PoolCreationFeePaid { payer: ctx.sender(), amount_unxv: required, timestamp_ms: sui::clock::timestamp_ms(clock) });
        // refund remainder
        let change = fee_payment_unxv;
        transfer::public_transfer(change, ctx.sender());
        // create DeepBook pool (DeepBook collects its own DEEP creation fee internally)
        db_pool::create_permissionless_pool<Base, Quote>(registry, tick_size, lot_size, min_size, coin::zero<DEEP>(ctx), ctx)
    }

    /// Swap exact base for quote with Unxversal protocol fee on input. Can accept UNXV for discounted fee and split.
    public fun swap_exact_base_for_quote<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut base_in: Coin<Base>,
        mut fee_unxv_in: Option<Coin<UNXV>>,
        staking_pool: &mut StakingPool,
        min_quote_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let base_amt = coin::value(&base_in);
        assert!(base_amt > 0, E_ZERO_AMOUNT);
        // Protocol taker fee from base_in with staking or UNXV discount (no volume tiers)
        let (taker_bps, _) = fees::apply_discounts_dex(fees::dex_taker_fee_bps(cfg), fees::dex_maker_fee_bps(cfg), option::is_some(&fee_unxv_in), staking_pool, ctx.sender(), cfg);
        let fee_amt = (base_amt as u128 * (taker_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let fee_coin = coin::split(&mut base_in, fee_amt, ctx);
        fees::accrue_generic<Base>(vault, fee_coin, clock, ctx);
        // Record spot volume (we proxy the USD 1e6 calc externally; here we just flag the path)
        // In production, pass oracle or pool mid-price to convert to USD 1e6 and call add_spot_volume_usd.

        // If UNXV provided, treat it purely as a discount flag and refund it
        if (option::is_some(&fee_unxv_in)) {
            let unxv = option::extract(&mut fee_unxv_in);
            transfer::public_transfer(unxv, ctx.sender());
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        // fee_unxv_in is now guaranteed to be None; destroy container
        option::destroy_none(fee_unxv_in);

        // Execute DeepBook swap using remaining base
        let deep_zero = coin::zero<DEEP>(ctx);
        let (base_left, quote_out, deep_back) = db_pool::swap_exact_base_for_quote(pool, base_in, deep_zero, min_quote_out, clock, ctx);
        // return any DEEP change to sender
        transfer::public_transfer(deep_back, ctx.sender());
        (base_left, quote_out)
    }

    /// Swap exact base for quote and accrue spot rewards using external USD 1e6 notional.
    /// Caller must provide the USD-normalized notional for the trade.
    public fun swap_exact_base_for_quote_with_rewards<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        base_in: Coin<Base>,
        fee_unxv_in: Option<Coin<UNXV>>,
        staking_pool: &mut StakingPool,
        min_quote_out: u64,
        notional_usd_1e6: u128,
        rew: &mut Rewards,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let (base_left, quote_out) = swap_exact_base_for_quote(pool, cfg, vault, base_in, fee_unxv_in, staking_pool, min_quote_out, clock, ctx);
        rewards::on_spot_swap(rew, ctx.sender(), notional_usd_1e6, clock);
        (base_left, quote_out)
    }

    /// Swap exact quote for base with Unxversal protocol fee.
    public fun swap_exact_quote_for_base<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut quote_in: Coin<Quote>,
        mut fee_unxv_in: Option<Coin<UNXV>>,
        staking_pool: &mut StakingPool,
        min_base_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Quote>, Coin<Base>) {
        let q_amt = coin::value(&quote_in);
        assert!(q_amt > 0, E_ZERO_AMOUNT);
        let (taker_bps, _) = fees::apply_discounts_dex(fees::dex_taker_fee_bps(cfg), fees::dex_maker_fee_bps(cfg), option::is_some(&fee_unxv_in), staking_pool, ctx.sender(), cfg);
        let fee_amt = (q_amt as u128 * (taker_bps as u128) / (fees::bps_denom() as u128)) as u64;
        // Collect taker protocol fee in quote
        let fee_coin = coin::split(&mut quote_in, fee_amt, ctx);
        fees::accrue_generic<Quote>(vault, fee_coin, clock, ctx);
        if (option::is_some(&fee_unxv_in)) {
            let unxv = option::extract(&mut fee_unxv_in);
            transfer::public_transfer(unxv, ctx.sender());
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        } else {
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: false, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
        };
        option::destroy_none(fee_unxv_in);
        let deep_zero = coin::zero<DEEP>(ctx);
        let (base_out, quote_left, deep_back) = db_pool::swap_exact_quote_for_base(pool, quote_in, deep_zero, min_base_out, clock, ctx);
        transfer::public_transfer(deep_back, ctx.sender());
        (quote_left, base_out)
    }

    /// Swap exact quote for base and accrue spot rewards using external USD 1e6 notional.
    /// Caller must provide the USD-normalized notional for the trade.
    public fun swap_exact_quote_for_base_with_rewards<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        quote_in: Coin<Quote>,
        fee_unxv_in: Option<Coin<UNXV>>,
        staking_pool: &mut StakingPool,
        min_base_out: u64,
        notional_usd_1e6: u128,
        rew: &mut Rewards,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Quote>, Coin<Base>) {
        let (quote_left, base_out) = swap_exact_quote_for_base(pool, cfg, vault, quote_in, fee_unxv_in, staking_pool, min_base_out, clock, ctx);
        rewards::on_spot_swap(rew, ctx.sender(), notional_usd_1e6, clock);
        (quote_left, base_out)
    }

    // === Advanced: Use UNXV to pay DeepBook fees (DEEP backend) ===
    /// Swap UNXV for DEEP using a UNXV/DEEP pool (UNXV as base), deposit DEEP to the caller's BalanceManager,
    /// then place a limit order with pay_with_deep=true.
    public fun place_limit_order_with_unxv_deep_backend<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_unxv_deep: &mut Pool<UNXV, DEEP>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        // Convert UNXV -> DEEP using input-token fee path (no DEEP required for this conversion)
        let deep_in = unxv_to_deep_via_unxv_deep_pool(fee_pool_unxv_deep, unxv_for_fees, 0, clock, ctx);
        // Deposit DEEP into the user's balance manager to cover DeepBook fees
        bm::deposit<DEEP>(balance_manager, deep_in, ctx);
        // Place order paying fees with DEEP for discount
        db_pool::place_limit_order(target_pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, is_bid, true, expire_timestamp, clock, ctx)
    }

    /// Swap UNXV for DEEP using a DEEP/UNXV pool (UNXV as quote), deposit DEEP to BalanceManager, and place market order.
    public fun place_market_order_with_unxv_deep_backend<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_deep_unxv: &mut Pool<DEEP, UNXV>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        let deep_in = unxv_to_deep_via_deep_unxv_pool(fee_pool_deep_unxv, unxv_for_fees, 0, clock, ctx);
        bm::deposit<DEEP>(balance_manager, deep_in, ctx);
        db_pool::place_market_order(target_pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, is_bid, true, clock, ctx)
    }

    /// Swap path helper: UNXV/DEEP pool with UNXV as base -> DEEP out.
    fun unxv_to_deep_via_unxv_deep_pool(
        pool: &mut Pool<UNXV, DEEP>,
        unxv_in: Coin<UNXV>,
        min_deep_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<DEEP> {
        let deep_zero = coin::zero<DEEP>(ctx);
        let (unxv_left, deep_out, deep_back) = db_pool::swap_exact_base_for_quote(pool, unxv_in, deep_zero, min_deep_out, clock, ctx);
        transfer::public_transfer(unxv_left, ctx.sender());
        transfer::public_transfer(deep_back, ctx.sender());
        deep_out
    }

    /// Swap path helper: DEEP/UNXV pool with UNXV as quote -> DEEP out.
    fun unxv_to_deep_via_deep_unxv_pool(
        pool: &mut Pool<DEEP, UNXV>,
        unxv_in: Coin<UNXV>,
        min_deep_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<DEEP> {
        let deep_zero = coin::zero<DEEP>(ctx);
        // We need to call quote->base variant: quote is UNXV, base is DEEP
        let (deep_out, unxv_left, deep_unused) = db_pool::swap_exact_quote_for_base(pool, unxv_in, deep_zero, min_deep_out, clock, ctx);
        transfer::public_transfer(unxv_left, ctx.sender());
        transfer::public_transfer(deep_unused, ctx.sender());
        deep_out
    }

    // === Advanced: Use UNXV to pay DeepBook fees (Swaps) ===
    /// Swap exact base for quote while supplying DEEP converted from UNXV to get discounted fees.
    public fun swap_exact_base_for_quote_with_unxv_deep_fee<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_unxv_deep: &mut Pool<UNXV, DEEP>,
        base_in: Coin<Base>,
        unxv_for_fees: Coin<UNXV>,
        min_quote_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let deep_in = unxv_to_deep_via_unxv_deep_pool(fee_pool_unxv_deep, unxv_for_fees, 0, clock, ctx);
        let (base_left, quote_out, deep_left) = db_pool::swap_exact_base_for_quote(target_pool, base_in, deep_in, min_quote_out, clock, ctx);
        transfer::public_transfer(deep_left, ctx.sender());
        (base_left, quote_out)
    }

    /// Swap exact quote for base while supplying DEEP converted from UNXV to get discounted fees.
    public fun swap_exact_quote_for_base_with_unxv_deep_fee<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_deep_unxv: &mut Pool<DEEP, UNXV>,
        quote_in: Coin<Quote>,
        unxv_for_fees: Coin<UNXV>,
        min_base_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Quote>, Coin<Base>) {
        let deep_in = unxv_to_deep_via_deep_unxv_pool(fee_pool_deep_unxv, unxv_for_fees, 0, clock, ctx);
        let (base_out, quote_left, deep_left) = db_pool::swap_exact_quote_for_base(target_pool, quote_in, deep_in, min_base_out, clock, ctx);
        transfer::public_transfer(deep_left, ctx.sender());
        (quote_left, base_out)
    }

    /// Cancel an order by id through DeepBook
    public fun cancel_order<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        order_id: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        db_pool::cancel_order(pool, balance_manager, trade_proof, order_id, clock, ctx);
    }

    /// Modify an order size through DeepBook
    public fun modify_order<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        order_id: u128,
        new_quantity: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        db_pool::modify_order(pool, balance_manager, trade_proof, order_id, new_quantity, clock, ctx);
    }

    /// Withdraw any settled amounts for the account from the pool vault
    public fun withdraw_settled_amounts<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
    ) {
        db_pool::withdraw_settled_amounts(pool, balance_manager, trade_proof);
    }

    // === Input-token backend (use input tokens to pay DeepBook fees, convert UNXV → input token first) ===
    /// Convert UNXV → Quote and place a limit bid (fees in Quote input token)
    public fun place_limit_order_with_unxv_input_quote_backend<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_unxv_quote: &mut Pool<UNXV, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        let quote_in = unxv_to_quote_via_unxv_quote_pool(fee_pool_unxv_quote, unxv_for_fees, 0, clock, ctx);
        bm::deposit<Quote>(balance_manager, quote_in, ctx);
        db_pool::place_limit_order(target_pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, true, false, expire_timestamp, clock, ctx)
    }

    /// Convert UNXV → Base and place a limit ask (fees in Base input token)
    public fun place_limit_order_with_unxv_input_base_backend<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_unxv_base: &mut Pool<UNXV, Base>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        let base_in = unxv_to_base_via_unxv_base_pool(fee_pool_unxv_base, unxv_for_fees, 0, clock, ctx);
        bm::deposit<Base>(balance_manager, base_in, ctx);
        db_pool::place_limit_order(target_pool, balance_manager, trade_proof, client_order_id, order_type, self_matching_option, price, quantity, false, false, expire_timestamp, clock, ctx)
    }

    /// Market bid (fees in Quote input token) with UNXV conversion
    public fun place_market_order_with_unxv_input_quote_backend<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_unxv_quote: &mut Pool<UNXV, Quote>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        let quote_in = unxv_to_quote_via_unxv_quote_pool(fee_pool_unxv_quote, unxv_for_fees, 0, clock, ctx);
        bm::deposit<Quote>(balance_manager, quote_in, ctx);
        db_pool::place_market_order(target_pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, true, false, clock, ctx)
    }

    /// Market ask (fees in Base input token) with UNXV conversion
    public fun place_market_order_with_unxv_input_base_backend<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        fee_pool_unxv_base: &mut Pool<UNXV, Base>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        _cfg: &FeeConfig,
        _vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        let base_in = unxv_to_base_via_unxv_base_pool(fee_pool_unxv_base, unxv_for_fees, 0, clock, ctx);
        bm::deposit<Base>(balance_manager, base_in, ctx);
        db_pool::place_market_order(target_pool, balance_manager, trade_proof, client_order_id, self_matching_option, quantity, false, false, clock, ctx)
    }

    /// Swap path helper: UNXV/Base pool (UNXV as base) -> Base out
    fun unxv_to_base_via_unxv_base_pool<Base>(
        pool: &mut Pool<UNXV, Base>,
        unxv_in: Coin<UNXV>,
        min_base_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Base> {
        let deep_zero = coin::zero<DEEP>(ctx);
        let (unxv_left, base_out, deep_back) = db_pool::swap_exact_base_for_quote(pool, unxv_in, deep_zero, min_base_out, clock, ctx);
        transfer::public_transfer(unxv_left, ctx.sender());
        transfer::public_transfer(deep_back, ctx.sender());
        base_out
    }

    /// Swap path helper: UNXV/Quote pool (UNXV as base) -> Quote out
    fun unxv_to_quote_via_unxv_quote_pool<Quote>(
        pool: &mut Pool<UNXV, Quote>,
        unxv_in: Coin<UNXV>,
        min_quote_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Quote> {
        let deep_zero = coin::zero<DEEP>(ctx);
        let (unxv_left, quote_out, deep_back) = db_pool::swap_exact_base_for_quote(pool, unxv_in, deep_zero, min_quote_out, clock, ctx);
        transfer::public_transfer(unxv_left, ctx.sender());
        transfer::public_transfer(deep_back, ctx.sender());
        quote_out
    }

    // === Auto-backend routing based on FeeConfig.prefer_deep_backend ===
    /// Place limit order; automatically choose backend based on cfg.prefer_deep_backend.
    /// Requires UNXV to fund backend fees in either path.
    public fun place_limit_order_auto<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        unxv_deep_pool: &mut Pool<UNXV, DEEP>,
        unxv_quote_pool: &mut Pool<UNXV, Quote>,
        unxv_base_pool: &mut Pool<UNXV, Base>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        order_type: u8,
        self_matching_option: u8,
        price: u64,
        quantity: u64,
        is_bid: bool,
        expire_timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        if (fees::prefer_deep_backend(cfg)) {
            place_limit_order_with_unxv_deep_backend(
                target_pool,
                unxv_deep_pool,
                balance_manager,
                trade_proof,
                cfg,
                vault,
                unxv_for_fees,
                client_order_id,
                order_type,
                self_matching_option,
                price,
                quantity,
                is_bid,
                expire_timestamp,
                clock,
                ctx,
            )
        } else {
            if (is_bid) {
                place_limit_order_with_unxv_input_quote_backend(
                    target_pool,
                    unxv_quote_pool,
                    balance_manager,
                    trade_proof,
                    cfg,
                    vault,
                    unxv_for_fees,
                    client_order_id,
                    order_type,
                    self_matching_option,
                    price,
                    quantity,
                    expire_timestamp,
                    clock,
                    ctx,
                )
            } else {
                place_limit_order_with_unxv_input_base_backend(
                    target_pool,
                    unxv_base_pool,
                    balance_manager,
                    trade_proof,
                    cfg,
                    vault,
                    unxv_for_fees,
                    client_order_id,
                    order_type,
                    self_matching_option,
                    price,
                    quantity,
                    expire_timestamp,
                    clock,
                    ctx,
                )
            }
        }
    }

    /// Place market order; automatically choose backend based on cfg.prefer_deep_backend.
    public fun place_market_order_auto<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        deep_unxv_pool: &mut Pool<DEEP, UNXV>,
        unxv_quote_pool: &mut Pool<UNXV, Quote>,
        unxv_base_pool: &mut Pool<UNXV, Base>,
        balance_manager: &mut BalanceManager,
        trade_proof: &TradeProof,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        unxv_for_fees: Coin<UNXV>,
        client_order_id: u64,
        self_matching_option: u8,
        quantity: u64,
        is_bid: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): OrderInfo {
        if (fees::prefer_deep_backend(cfg)) {
            place_market_order_with_unxv_deep_backend(
                target_pool,
                deep_unxv_pool,
                balance_manager,
                trade_proof,
                cfg,
                vault,
                unxv_for_fees,
                client_order_id,
                self_matching_option,
                quantity,
                is_bid,
                clock,
                ctx,
            )
        } else {
            if (is_bid) {
                place_market_order_with_unxv_input_quote_backend(
                    target_pool,
                    unxv_quote_pool,
                    balance_manager,
                    trade_proof,
                    cfg,
                    vault,
                    unxv_for_fees,
                    client_order_id,
                    self_matching_option,
                    quantity,
                    clock,
                    ctx,
                )
            } else {
                place_market_order_with_unxv_input_base_backend(
                    target_pool,
                    unxv_base_pool,
                    balance_manager,
                    trade_proof,
                    cfg,
                    vault,
                    unxv_for_fees,
                    client_order_id,
                    self_matching_option,
                    quantity,
                    clock,
                    ctx,
                )
            }
        }
    }

    /// Swap auto: base→quote. If prefer_deep_backend, convert UNXV→DEEP and use DeepBook DEEP fees.
    /// Else, apply Unxversal protocol fee with optional UNXV discount.
    public fun swap_exact_base_for_quote_auto<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        base_in: Coin<Base>,
        staking_pool: &mut StakingPool,
        // For prefer_deep_backend=true
        unxv_deep_pool: &mut Pool<UNXV, DEEP>,
        mut maybe_unxv: Option<Coin<UNXV>>,
        min_quote_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        if (fees::prefer_deep_backend(cfg)) {
            assert!(option::is_some(&maybe_unxv), E_UNXV_REQUIRED);
            // Charge protocol taker fee on input even when using DEEP backend
            let base_amt = coin::value(&base_in);
            let (taker_bps, _) = fees::apply_discounts_dex(
                fees::dex_taker_fee_bps(cfg),
                fees::dex_maker_fee_bps(cfg),
                true,
                staking_pool,
                ctx.sender(),
                cfg,
            );
            let fee_amt = (base_amt as u128 * (taker_bps as u128) / (fees::bps_denom() as u128)) as u64;
            let (mut base_in, fee_coin) = {
                let mut tmp = base_in;
                let fc = coin::split(&mut tmp, fee_amt, ctx);
                (tmp, fc)
            };
            fees::accrue_generic<Base>(vault, fee_coin, clock, ctx);
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Base>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
            let unxv = option::extract(&mut maybe_unxv);
            let deep_in = unxv_to_deep_via_unxv_deep_pool(unxv_deep_pool, unxv, 0, clock, ctx);
            option::destroy_none(maybe_unxv);
            let (base_left, quote_out, deep_left) = db_pool::swap_exact_base_for_quote(target_pool, base_in, deep_in, min_quote_out, clock, ctx);
            transfer::public_transfer(deep_left, ctx.sender());
            (base_left, quote_out)
        } else {
            swap_exact_base_for_quote(target_pool, cfg, vault, base_in, maybe_unxv, staking_pool, min_quote_out, clock, ctx)
        }
    }

    /// Auto route swap (base→quote) and accrue spot rewards with external USD 1e6 notional.
    public fun swap_exact_base_for_quote_auto_with_rewards<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        base_in: Coin<Base>,
        staking_pool: &mut StakingPool,
        // For prefer_deep_backend=true
        unxv_deep_pool: &mut Pool<UNXV, DEEP>,
        maybe_unxv: Option<Coin<UNXV>>,
        min_quote_out: u64,
        notional_usd_1e6: u128,
        rew: &mut Rewards,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let (base_left, quote_out) = swap_exact_base_for_quote_auto(target_pool, cfg, vault, base_in, staking_pool, unxv_deep_pool, maybe_unxv, min_quote_out, clock, ctx);
        rewards::on_spot_swap(rew, ctx.sender(), notional_usd_1e6, clock);
        (base_left, quote_out)
    }

    /// Swap auto: quote→base.
    public fun swap_exact_quote_for_base_auto<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        quote_in: Coin<Quote>,
        staking_pool: &mut StakingPool,
        // For prefer_deep_backend=true
        deep_unxv_pool: &mut Pool<DEEP, UNXV>,
        mut maybe_unxv: Option<Coin<UNXV>>,
        min_base_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Quote>, Coin<Base>) {
        if (fees::prefer_deep_backend(cfg)) {
            assert!(option::is_some(&maybe_unxv), E_UNXV_REQUIRED);
            // Charge protocol taker fee on input even when using DEEP backend
            let q_amt = coin::value(&quote_in);
            let (taker_bps, _) = fees::apply_discounts_dex(
                fees::dex_taker_fee_bps(cfg),
                fees::dex_maker_fee_bps(cfg),
                true,
                staking_pool,
                ctx.sender(),
                cfg,
            );
            let fee_amt = (q_amt as u128 * (taker_bps as u128) / (fees::bps_denom() as u128)) as u64;
            let (mut quote_in, fee_coin) = {
                let mut tmp = quote_in;
                let fc = coin::split(&mut tmp, fee_amt, ctx);
                (tmp, fc)
            };
            fees::accrue_generic<Quote>(vault, fee_coin, clock, ctx);
            event::emit(ProtocolFeeTaken { payer: ctx.sender(), base_fee_asset_unxv: true, amount: fee_amt, asset: type_name::get<Quote>(), timestamp_ms: sui::clock::timestamp_ms(clock) });
            let unxv = option::extract(&mut maybe_unxv);
            let deep_in = unxv_to_deep_via_deep_unxv_pool(deep_unxv_pool, unxv, 0, clock, ctx);
            option::destroy_none(maybe_unxv);
            let (base_out, quote_left, deep_left) = db_pool::swap_exact_quote_for_base(target_pool, quote_in, deep_in, min_base_out, clock, ctx);
            transfer::public_transfer(deep_left, ctx.sender());
            (quote_left, base_out)
        } else {
            swap_exact_quote_for_base(target_pool, cfg, vault, quote_in, maybe_unxv, staking_pool, min_base_out, clock, ctx)
        }
    }

    /// Auto route swap (quote→base) and accrue spot rewards with external USD 1e6 notional.
    public fun swap_exact_quote_for_base_auto_with_rewards<Base, Quote>(
        target_pool: &mut Pool<Base, Quote>,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        quote_in: Coin<Quote>,
        staking_pool: &mut StakingPool,
        // For prefer_deep_backend=true
        deep_unxv_pool: &mut Pool<DEEP, UNXV>,
        maybe_unxv: Option<Coin<UNXV>>,
        min_base_out: u64,
        notional_usd_1e6: u128,
        rew: &mut Rewards,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<Quote>, Coin<Base>) {
        let (quote_left, base_out) = swap_exact_quote_for_base_auto(target_pool, cfg, vault, quote_in, staking_pool, deep_unxv_pool, maybe_unxv, min_base_out, clock, ctx);
        rewards::on_spot_swap(rew, ctx.sender(), notional_usd_1e6, clock);
        (quote_left, base_out)
    }

    /// Internal: move UNXV fee into staking (weekly reward) and treasury per FeeConfig
    fun distribute_unxv_fee(
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        staking_pool: &mut StakingPool,
        unxv_fee: Coin<UNXV>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, vault, unxv_fee, clock, ctx);
        // deposit stakers share into weekly rewards
        staking::add_weekly_reward(staking_pool, stakers_coin, clock);
        // transfer treasury share
        transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
    }
}


