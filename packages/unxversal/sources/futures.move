module unxversal::futures {
    /*******************************
    * Unxversal Dated Futures – Core (cash settlement, admin-configurable)
    * - Admin whitelists underlyings and Pyth feeds
    * - Permissionless contract listing on whitelisted underlyings (min interval)
    * - Trustless cash settlement via oracle at/after expiry
    * - Fees to central treasury with optional bot-reward split
    *******************************/

    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use sui::table::{Self as table, Table};
    use sui::vec_set::{Self as vec_set, VecSet};
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};

    use switchboard::aggregator::Aggregator;
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{Self as SynthMod, SynthRegistry, AdminCap};
    use std::string::{Self as string, String};

    /*******************************
    * Errors
    *******************************/
    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_UNKNOWN_UNDERLYING: u64 = 3;
    const E_MIN_INTERVAL: u64 = 4;
    const E_ALREADY_SETTLED: u64 = 5;
    const E_BAD_FEED: u64 = 6;
    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;

    /*******************************
    * Registry
    *******************************/
    public struct FuturesRegistry has key, store {
        id: UID,
        paused: bool,
        // Allowed underlyings and their oracle feeds
        underlyings: VecSet<String>,
        price_feeds: Table<String, ID>,
        // Contracts indexed by symbol
        contracts: Table<String, ID>,
        // Admin-configurable params
        settlement_fee_bps: u64,
        settlement_bot_reward_bps: u64,
        min_list_interval_ms: u64,
        trade_fee_bps: u64,
        maker_rebate_bps: u64,
        unxv_discount_bps: u64,
        trade_bot_reward_bps: u64,
        // Settlement behavior
        dispute_window_ms: u64,
        // Throttle contract listing by underlying
        last_list_ms: Table<String, u64>,
        // Treasury linkage
        treasury_id: ID,
    }

    /*******************************
    * Contract
    *******************************/
    public struct FuturesContract has key, store {
        id: UID,
        symbol: String,           // e.g., "sBTC-DEC24"
        underlying: String,       // e.g., "sBTC"
        contract_size: u64,
        tick_size: u64,
        expiry_ms: u64,
        paused: bool,
        is_active: bool,
        is_expired: bool,
        settlement_price: u64,    // micro-USD; 0 until settled
        settled_at_ms: u64,
        init_margin_bps: u64,
        maint_margin_bps: u64,
        // Lightweight metrics
        open_interest: u64,
        volume_premium: u64,
        last_trade_premium: u64,
    }

    /*******************************
    * Minimal position stubs (margin later)
    *******************************/
    public struct FuturesPosition<phantom C> has key, store {
        id: UID,
        owner: address,
        contract_id: ID,
        side: u8,               // 0 long, 1 short
        size: u64,              // in contracts
        avg_price: u64,         // micro-USD per contract
        margin: Balance<C>,     // locked margin held by position
        accumulated_pnl_abs: u128,     // magnitude of realized PnL
        accumulated_pnl_is_gain: bool, // true if net gain; false if net loss
        opened_at_ms: u64,
    }

    public struct FuturesTrade has copy, drop { symbol: String, taker: address, maker: address, size: u64, price: u64, fee_paid: u64, maker_rebate: u64, timestamp: u64 }
    public struct FuturesLiq has copy, drop { symbol: String, account: address, size: u64, price: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct VariationMarginApplied has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_abs: u128, is_gain: bool, new_margin: u64, timestamp: u64 }
    public struct PositionSettled has copy, drop { symbol: String, account: address, size: u64, settlement_price: u64, fee_paid: u64, bot_reward: u64, timestamp: u64 }
    public struct MarginCall has copy, drop { symbol: String, account: address, equity_abs: u128, is_positive: bool, maint_required: u64, timestamp: u64 }
    public struct FillRecorded has copy, drop { symbol: String, price: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_paid: u64, unxv_discount_applied: bool, maker_rebate: u64, bot_reward: u64, timestamp: u64 }
    public struct PositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price: u64, margin_locked: u64, timestamp: u64 }
    public struct PositionClosed has copy, drop { symbol: String, account: address, qty: u64, price: u64, margin_refund: u64, timestamp: u64 }

    /*******************************
    * Open/Close positions and variation margin (stub flows)
    *******************************/
    entry fun open_position<C>(
        market: &mut FuturesContract,
        side: u8,
        size: u64,
        entry_price: u64,
        mut margin: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        let notional = size * entry_price;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let locked_coin = coin::split(&mut margin, init_req, ctx);
        let locked = coin::into_balance(locked_coin);
        // Refund any remainder back to owner
        transfer::public_transfer(margin, ctx.sender());
        market.open_interest = market.open_interest + size;
        let pos = FuturesPosition<C> { id: object::new(ctx), owner: ctx.sender(), contract_id: object::id(market), side, size, avg_price: entry_price, margin: locked, accumulated_pnl_abs: 0, accumulated_pnl_is_gain: true, opened_at_ms: sui::tx_context::epoch_timestamp_ms(ctx) };
        event::emit(PositionOpened { symbol: clone_string(&market.symbol), account: pos.owner, side, size, price: entry_price, margin_locked: balance::value(&pos.margin), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::share_object(pos);
    }

    entry fun close_position<C>(
        reg: &FuturesRegistry,
        market: &mut FuturesContract,
        pos: &mut FuturesPosition<C>,
        close_price: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        // Variation margin: PnL = (close - avg) * qty * sign
        let (is_gain, pnl_abs) = if (pos.side == 0) {
            // long
            if (close_price >= pos.avg_price) {
                (true, ((close_price - pos.avg_price) as u128) * (quantity as u128))
            } else {
                (false, ((pos.avg_price - close_price) as u128) * (quantity as u128))
            }
        } else {
            // short
            if (pos.avg_price >= close_price) {
                (true, ((pos.avg_price - close_price) as u128) * (quantity as u128))
            } else {
                (false, ((close_price - pos.avg_price) as u128) * (quantity as u128))
            }
        };
        // Apply PnL to accumulated sign/magnitude
        if (pnl_abs > 0) {
            if (pos.accumulated_pnl_is_gain == is_gain) {
                pos.accumulated_pnl_abs = pos.accumulated_pnl_abs + pnl_abs;
            } else {
                if (pos.accumulated_pnl_abs >= pnl_abs) {
                    pos.accumulated_pnl_abs = pos.accumulated_pnl_abs - pnl_abs;
                    // sign remains as previous
                } else {
                    pos.accumulated_pnl_abs = pnl_abs - pos.accumulated_pnl_abs;
                    pos.accumulated_pnl_is_gain = is_gain;
                };
            }
        };
        // Refund proportional margin on close
        let total_margin = balance::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) {
            let out_bal = balance::split(&mut pos.margin, margin_refund);
            let out = coin::from_balance(out_bal, ctx);
            transfer::public_transfer(out, pos.owner);
        };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; };
        // route a nominal fee to treasury (notional * settlement_fee_bps), placeholder
        let notional = quantity * close_price;
        let fee = (notional * reg.settlement_fee_bps) / 10_000;
        if (fee > 0) {
            // Deduct fee from remaining position margin proportionally if available
            let avail = balance::value(&pos.margin);
            if (avail >= fee) {
                let fee_bal = balance::split(&mut pos.margin, fee);
                let fee_coin = coin::from_balance(fee_bal, ctx);
                TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"futures_close".to_string(), pos.owner, ctx);
            }
        };
        let new_margin_val = balance::value(&pos.margin);
        event::emit(VariationMarginApplied { symbol: clone_string(&market.symbol), account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_price, to_price: close_price, pnl_abs: pnl_abs, is_gain, new_margin: new_margin_val, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(PositionClosed { symbol: clone_string(&market.symbol), account: pos.owner, qty: quantity, price: close_price, margin_refund: margin_refund, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(FuturesTrade { symbol: clone_string(&market.symbol), taker: ctx.sender(), maker: pos.owner, size: quantity, price: close_price, fee_paid: fee, maker_rebate: 0, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
     * Record fill – metrics + fees (maker rebate, UNXV discount, bot split)
     *******************************/
    entry fun record_fill<C>(
        reg: &FuturesRegistry,
        market: &mut FuturesContract,
        price: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        unxv_price: &Aggregator,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        mut fee_payment: Coin<C>,
        treasury: &mut Treasury<C>,
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        // Enforce tick size
        assert!(price % market.tick_size == 0, E_MIN_INTERVAL);
        // Slippage bounds (caller-provided)
        assert!(price >= min_price && price <= max_price, E_MIN_INTERVAL);
        let notional = size * price;
        // Fees
        let trade_fee = (notional * reg.trade_fee_bps) / 10_000;
        let discount_collateral = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        // Always drain the UNXV payment vector into a single coin and destroy the vector
        let mut merged_unxv = coin::zero<unxversal::unxv::UNXV>(ctx);
        let mut i = 0;
        while (i < vector::length(&unxv_payment)) {
            let c = vector::pop_back(&mut unxv_payment);
            coin::join(&mut merged_unxv, c);
            i = i + 1;
        };
        vector::destroy_empty(unxv_payment);
        if (discount_collateral > 0) {
            let price_unxv = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv > 0) {
                let unxv_needed = (discount_collateral + price_unxv - 1) / price_unxv;
                let have = coin::value(&merged_unxv);
                if (have >= unxv_needed) {
                    let exact = coin::split(&mut merged_unxv, unxv_needed, ctx);
                    let mut vec_unxv = vector::empty<Coin<unxversal::unxv::UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    TreasuryMod::deposit_unxv_ext(treasury, vec_unxv, b"futures_trade".to_string(), ctx.sender(), ctx);
                    discount_applied = true;
                }
            }
        };
        // Refund any remaining UNXV (including zero) to sender
        transfer::public_transfer(merged_unxv, ctx.sender());
        let collateral_fee_after_discount = if (discount_applied) { trade_fee - discount_collateral } else { trade_fee };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        if (collateral_fee_after_discount > 0) {
            let have = coin::value(&fee_payment);
            assert!(have >= collateral_fee_after_discount, E_MIN_INTERVAL);
            // maker rebate first
            if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) {
                let to_maker = coin::split(&mut fee_payment, maker_rebate, ctx);
                transfer::public_transfer(to_maker, maker);
            };
            // bot reward split on trade fee (optional)
            if (reg.trade_bot_reward_bps > 0) {
                let bot_cut = (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000;
                if (bot_cut > 0) {
                    let to_bot = coin::split(&mut fee_payment, bot_cut, ctx);
                    transfer::public_transfer(to_bot, ctx.sender());
                };
            };
            TreasuryMod::deposit_collateral_ext(treasury, fee_payment, b"futures_trade".to_string(), ctx.sender(), ctx);
        } else {
            // No fee due: refund any provided fee payment
            transfer::public_transfer(fee_payment, ctx.sender());
        };
        // Metrics
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; } };
        market.volume_premium = market.volume_premium + notional;
        market.last_trade_premium = price;
        event::emit(FuturesTrade { symbol: clone_string(&market.symbol), taker: ctx.sender(), maker, size, price, fee_paid: collateral_fee_after_discount, maker_rebate: maker_rebate, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        event::emit(FillRecorded { symbol: clone_string(&market.symbol), price, size, taker: ctx.sender(), maker, taker_is_buyer, fee_paid: collateral_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate: maker_rebate, bot_reward: if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
     * Liquidation – seize margin when equity < maintenance
     *******************************/
    entry fun liquidate_position<C>(
        reg: &FuturesRegistry,
        market: &mut FuturesContract,
        pos: &mut FuturesPosition<C>,
        mark_price: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(object::id(market) == pos.contract_id, E_MIN_INTERVAL);
        // Equity = margin_value + unrealized PnL
        let margin_val = balance::value(&pos.margin);
        // compute unrealized abs and sign
        let (unrl_abs, unrl_gain) = if (pos.side == 0) {
            if (mark_price >= pos.avg_price) { (((mark_price - pos.avg_price) as u128) * (pos.size as u128), true) }
            else { (((pos.avg_price - mark_price) as u128) * (pos.size as u128), false) }
        } else {
            if (pos.avg_price >= mark_price) { (((pos.avg_price - mark_price) as u128) * (pos.size as u128), true) }
            else { (((mark_price - pos.avg_price) as u128) * (pos.size as u128), false) }
        };
        let equity_val: u128 = if (unrl_gain) { (margin_val as u128) + unrl_abs } else { if ((margin_val as u128) >= unrl_abs) { (margin_val as u128) - unrl_abs } else { 0 } };
        let notional = pos.size * mark_price;
        let maint_req = (notional * market.maint_margin_bps) / 10_000;
        if (!(equity_val < (maint_req as u128))) { return }; // not liquidatable
        event::emit(MarginCall { symbol: clone_string(&market.symbol), account: pos.owner, equity_abs: equity_val, is_positive: true, maint_required: maint_req, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        // Seize all margin to treasury, split bot reward
        let seized_total = balance::value(&pos.margin);
        if (seized_total > 0) {
            let seized_bal = balance::split(&mut pos.margin, seized_total);
            let mut seized = coin::from_balance(seized_bal, ctx);
            let bot_cut = (seized_total * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) {
                let to_bot = coin::split(&mut seized, bot_cut, ctx);
                transfer::public_transfer(to_bot, ctx.sender());
            };
            TreasuryMod::deposit_collateral_ext(treasury, seized, b"futures_liquidation".to_string(), ctx.sender(), ctx);
        };
        // Reset position
        let liq_price = mark_price;
        let qty = pos.size;
        pos.size = 0;
        event::emit(FuturesLiq { symbol: clone_string(&market.symbol), account: pos.owner, size: qty, price: liq_price, seized_margin: seized_total, bot_reward: (seized_total * reg.settlement_bot_reward_bps) / 10_000, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; };
    }

    /*******************************
    * Events
    *******************************/
    public struct UnderlyingWhitelisted has copy, drop { underlying: String, by: address, timestamp: u64 }
    public struct FuturesListed has copy, drop { symbol: String, underlying: String, expiry_ms: u64, contract_size: u64, tick_size: u64, timestamp: u64 }
    public struct FuturesSettled has copy, drop { symbol: String, underlying: String, expiry_ms: u64, settlement_price: u64, timestamp: u64 }
    public struct PausedToggled has copy, drop { new_state: bool, by: address, timestamp: u64 }
    public struct RegistryDisplayInitialized has copy, drop { by: address, timestamp: u64 }

    /*******************************
    * Admin helper via synthetics registry
    *******************************/
    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(SynthMod::is_admin(synth_reg, addr), E_NOT_ADMIN); }

    /*******************************
    * Init & display
    *******************************/
    entry fun init_registry(synth_reg: &SynthRegistry, ctx: &mut TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        let reg = FuturesRegistry {
            id: object::new(ctx),
            paused: false,
            underlyings: vec_set::empty<String>(),
            price_feeds: table::new<String, ID>(ctx),
            contracts: table::new<String, ID>(ctx),
            settlement_fee_bps: 10,
            settlement_bot_reward_bps: 0,
            min_list_interval_ms: 60_000, // default 1 minute
            trade_fee_bps: 30,
            maker_rebate_bps: 100,
            unxv_discount_bps: 0,
            trade_bot_reward_bps: 0,
            // dispute_window_ms: 60_000,
            dispute_window_ms: 0, // no dispute window for now
            last_list_ms: table::new<String, u64>(ctx),
            treasury_id: object::id(synth_reg),
        };
        transfer::share_object(reg);
    }

    entry fun pause(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = true; event::emit(PausedToggled { new_state: true, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }
    entry fun resume(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = false; event::emit(PausedToggled { new_state: false, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    entry fun set_params(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, settlement_fee_bps: u64, settlement_bot_reward_bps: u64, min_list_interval_ms: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
        reg.min_list_interval_ms = min_list_interval_ms;
    }

    entry fun set_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    /*******************************
     * Per-contract pause guards
     *******************************/
    entry fun pause_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut FuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = true; }
    entry fun resume_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut FuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = false; }

    entry fun set_limits_and_settlement_cfg(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut FuturesRegistry,
        dispute_window_ms: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.dispute_window_ms = dispute_window_ms;
    }

    entry fun set_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }

    /*******************************
    * Underlyings & feeds (admin)
    *******************************/
    entry fun whitelist_underlying(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut FuturesRegistry,
        underlying: String,
        aggregator: &Aggregator,
        ctx: &TxContext
    ) {
        assert_is_admin(synth_reg, ctx.sender());
        vec_set::insert(&mut reg.underlyings, clone_string(&underlying));
        table::add(&mut reg.price_feeds, clone_string(&underlying), object::id(aggregator));
        event::emit(UnderlyingWhitelisted { underlying, by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Listing (permissionless on whitelisted underlyings)
    *******************************/
    entry fun list_futures(reg: &mut FuturesRegistry, underlying: String, symbol: String, contract_size: u64, tick_size: u64, expiry_ms: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(vec_set::contains(&reg.underlyings, &underlying), E_UNKNOWN_UNDERLYING);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let last = if (table::contains(&reg.last_list_ms, clone_string(&underlying))) { *table::borrow(&reg.last_list_ms, clone_string(&underlying)) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        table::add(&mut reg.last_list_ms, clone_string(&underlying), now);

        let mc = FuturesContract {
            id: object::new(ctx),
            symbol: clone_string(&symbol),
            underlying: clone_string(&underlying),
            contract_size,
            tick_size,
            expiry_ms,
            paused: false,
            is_active: true,
            is_expired: false,
            settlement_price: 0,
            settled_at_ms: 0,
            init_margin_bps,
            maint_margin_bps,
            open_interest: 0,
            volume_premium: 0,
            last_trade_premium: 0,
        };
        let id = object::id(&mc);
        transfer::share_object(mc);
        table::add(&mut reg.contracts, clone_string(&symbol), id);
        event::emit(FuturesListed { symbol, underlying, expiry_ms, contract_size, tick_size, timestamp: now });
        // Caller discovers the shared object via event and registry mapping
    }

    /*******************************
    * Display helper
    *******************************/
    entry fun init_futures_display(publisher: &sui::package::Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<FuturesContract>(publisher, ctx);
        disp.add(b"name".to_string(), b"Futures {symbol} on {underlying}".to_string());
        disp.add(b"description".to_string(), b"Unxversal dated futures contract".to_string());
        disp.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        disp.add(b"contract_size".to_string(), b"{contract_size}".to_string());
        disp.add(b"tick_size".to_string(), b"{tick_size}".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());

        // Registry type display
        let mut rdisp = display::new<FuturesRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Futures Registry".to_string());
        rdisp.add(b"description".to_string(), b"Controls listing and global fee/limit params for Futures".to_string());
        rdisp.add(b"trade_fee_bps".to_string(), b"{trade_fee_bps}".to_string());
        rdisp.add(b"maker_rebate_bps".to_string(), b"{maker_rebate_bps}".to_string());
        rdisp.add(b"unxv_discount_bps".to_string(), b"{unxv_discount_bps}".to_string());
        rdisp.update_version();
        transfer::public_transfer(rdisp, ctx.sender());
        event::emit(RegistryDisplayInitialized { by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Settlement (trustless via oracle)
    *******************************/
    entry fun settle_futures<C>(reg: &FuturesRegistry, oracle_cfg: &OracleConfig, market: &mut FuturesContract, clock: &Clock, aggregator: &Aggregator, _treasury: &mut Treasury<C>, ctx: &TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(!market.is_expired, E_ALREADY_SETTLED);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        assert!(now >= market.expiry_ms, E_MIN_INTERVAL);
        // Enforce feed matches whitelisted underlying by aggregator object ID
        let expected = table::borrow(&reg.price_feeds, clone_string(&market.underlying));
        assert!(*expected == object::id(aggregator), E_BAD_FEED);
        let px = get_price_scaled_1e6(oracle_cfg, clock, aggregator);
        market.settlement_price = px;
        market.settled_at_ms = now;
        market.is_expired = true;
        market.is_active = false;
        // Settlement fee accrual to treasury (bot split)
        // Fees are applied in batch processing of positions below via the queue processor.
        event::emit(FuturesSettled { symbol: clone_string(&market.symbol), underlying: clone_string(&market.underlying), expiry_ms: market.expiry_ms, settlement_price: px, timestamp: now });
    }

    /// Settle a single position at the recorded market settlement price. Anyone can call.
    entry fun settle_position<C>(
        reg: &FuturesRegistry,
        market: &FuturesContract,
        pos: &mut FuturesPosition<C>,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(market.is_expired, E_MIN_INTERVAL);
        assert!(object::id(market) == pos.contract_id, E_MIN_INTERVAL);
        let px = market.settlement_price;
        // Final PnL versus avg_price
        let (pnl_abs, pnl_gain) = if (pos.side == 0) {
            if (px >= pos.avg_price) { (((px - pos.avg_price) as u128) * (pos.size as u128), true) } else { (((pos.avg_price - px) as u128) * (pos.size as u128), false) }
        } else {
            if (pos.avg_price >= px) { (((pos.avg_price - px) as u128) * (pos.size as u128), true) } else { (((px - pos.avg_price) as u128) * (pos.size as u128), false) }
        };
        // Apply settlement fee and bot split, collected from remaining margin if positive PnL; otherwise margin absorbs losses
        let margin_val = balance::value(&pos.margin);
        if (pnl_gain) {
            let fee = ((if (pnl_abs > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { pnl_abs as u64 }) * reg.settlement_fee_bps) / 10_000;
            if (fee > 0 && margin_val >= fee) {
                let fee_bal = balance::split(&mut pos.margin, fee);
                let fee_coin = coin::from_balance(fee_bal, ctx);
                // Optional bot reward cut from fee before deposit
                if (reg.settlement_bot_reward_bps > 0) {
                    let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000;
                    if (bot_cut > 0) {
                        let bot_bal = balance::split(&mut pos.margin, bot_cut);
                        let to_bot = coin::from_balance(bot_bal, ctx);
                        transfer::public_transfer(to_bot, ctx.sender());
                    };
                };
                TreasuryMod::deposit_collateral_ext(treasury, fee_coin, b"futures_settlement".to_string(), pos.owner, ctx);
            }
        } else {
            // Losses: clamp to available margin, route to treasury as sink
            let loss_abs = if (pnl_abs > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { pnl_abs as u64 };
            if (loss_abs > 0) {
                let burn = if (margin_val >= loss_abs) { loss_abs } else { margin_val };
                if (burn > 0) {
                    let loss_bal = balance::split(&mut pos.margin, burn);
                    let loss_coin = coin::from_balance(loss_bal, ctx);
                    TreasuryMod::deposit_collateral_ext(treasury, loss_coin, b"futures_loss".to_string(), pos.owner, ctx);
                }
            }
        };
        let size = pos.size;
        let fee_for_event = ((if (pnl_gain) { if (pnl_abs > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { pnl_abs as u64 } } else { 0 }) * reg.settlement_fee_bps) / 10_000;
        event::emit(PositionSettled { symbol: clone_string(&market.symbol), account: pos.owner, size, settlement_price: px, fee_paid: fee_for_event, bot_reward: (fee_for_event * reg.settlement_bot_reward_bps) / 10_000, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        // Close position fully and return remaining margin to owner
        pos.size = 0;
        let rem = balance::value(&pos.margin);
        if (rem > 0) {
            let out_bal = balance::split(&mut pos.margin, rem);
            let out = coin::from_balance(out_bal, ctx);
            transfer::public_transfer(out, pos.owner);
        };
    }

    /*******************************
     * Settlement Queue with Dispute Window
     *******************************/
    public struct SettlementQueue has key, store {
        id: UID,
        entries: Table<ID, u64>, // contract_id -> ready_after_ms
    }

    entry fun init_settlement_queue(ctx: &mut TxContext) {
        let q = SettlementQueue { id: object::new(ctx), entries: table::new<ID, u64>(ctx) };
        transfer::share_object(q);
    }

    entry fun request_settlement(reg: &FuturesRegistry, market: &FuturesContract, queue: &mut SettlementQueue, _ctx: &TxContext) {
        assert!(!reg.paused, E_PAUSED);
        // Only enqueue once contract is marked expired (price recorded)
        assert!(market.is_expired, E_MIN_INTERVAL);
        let ready = market.settled_at_ms + reg.dispute_window_ms;
        table::add(&mut queue.entries, object::id(market), ready);
    }

    entry fun process_due_settlements(
        reg: &FuturesRegistry,
        queue: &mut SettlementQueue,
        market_ids: vector<ID>,
        ctx: &TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let mut i = 0;
        while (i < vector::length(&market_ids)) {
            let mid = *vector::borrow(&market_ids, i);
            if (table::contains(&queue.entries, mid)) {
                let ready = *table::borrow(&queue.entries, mid);
                if (now >= ready) {
                    // Position-level cash settlement occurs off-chain by bots invoking close/settle flows per position holder.
                    let _ = table::remove(&mut queue.entries, mid);
                }
            };
            i = i + 1;
        }
    }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun get_contract_id(reg: &FuturesRegistry, symbol: &String): ID { *table::borrow(&reg.contracts, clone_string(symbol)) }
    public fun is_underlying_whitelisted(reg: &FuturesRegistry, u: &String): bool { vec_set::contains(&reg.underlyings, u) }
    public fun get_market_metrics(m: &FuturesContract): (u64, u64, u64) { (m.open_interest, m.volume_premium, m.last_trade_premium) }
    public fun position_info<C>(p: &FuturesPosition<C>): (address, ID, u8, u64, u64, u64, bool, u128, u64) { (p.owner, p.contract_id, p.side, p.size, p.avg_price, balance::value(&p.margin), p.accumulated_pnl_is_gain, p.accumulated_pnl_abs, p.opened_at_ms) }
    public fun registry_trade_fee_params(reg: &FuturesRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun registry_settlement_params(reg: &FuturesRegistry): (u64, u64) { (reg.settlement_fee_bps, reg.settlement_bot_reward_bps) }

    /*******************************
     * Local helpers
     *******************************/
    fun clone_string(s: &String): String {
        let src = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(src, i)); i = i + 1; };
        string::utf8(out)
    }
}


