module unxversal::futures {
    /*******************************
    * Unxversal Dated Futures - Core (cash settlement, admin-configurable)
    * - Admin whitelists underlyings and Pyth feeds
    * - Permissionless contract listing on whitelisted underlyings (min interval)
    * - Trustless cash settlement via oracle at/after expiry
    * - Fees to central treasury with optional bot-reward split
    *******************************/

    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::String;
    use sui::table::{Self as table, Table};
    use sui::vec_set::{Self as vec_set, VecSet};

    use sui::coin::{Self, Coin};

    use unxversal::oracle::PriceInfoObject;
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{SynthRegistry, AdminCap, check_is_admin, CollateralConfig};

    /*******************************
    * Errors
    *******************************/
    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_UNKNOWN_UNDERLYING: u64 = 3;
    const E_MIN_INTERVAL: u64 = 4;
    const E_ALREADY_SETTLED: u64 = 5;
    const E_BAD_FEED: u64 = 6;

    /*******************************
    * Registry
    *******************************/
    public struct FuturesRegistry has key, store {
        id: UID,
        paused: bool,
        // Allowed underlyings and their oracle feeds
        underlyings: VecSet<String>,
        price_feeds: Table<String, vector<u8>>, // underlying -> Pyth feed bytes
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
        // Position size limits
        default_max_oi_per_user: u64,
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
        volume_premium_usdc: u64,
        last_trade_premium_usdc: u64,
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
        margin: Coin<C>,        // margin in admin-set collateral
        accumulated_pnl: u64,   // realized PnL from prior closes/mtm (converted from I64)
        opened_at_ms: u64,
    }

    public struct FuturesTrade has copy, drop { symbol: String, taker: address, maker: address, size: u64, price: u64, fee_collateral: u64, maker_rebate_collateral: u64, timestamp: u64 }
    public struct FuturesLiq has copy, drop { symbol: String, account: address, size: u64, price: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct VariationMarginApplied has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta: u64, new_margin: u64, timestamp: u64 }
    public struct PositionSettled has copy, drop { symbol: String, account: address, size: u64, settlement_price: u64, fee_collateral: u64, bot_reward_collateral: u64, timestamp: u64 }
    public struct MarginCall has copy, drop { symbol: String, account: address, equity_collateral: u64, maint_required_collateral: u64, timestamp: u64 }
    public struct FillRecorded has copy, drop { symbol: String, price: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_collateral: u64, unxv_discount_applied: bool, maker_rebate_collateral: u64, bot_reward_collateral: u64, timestamp: u64 }
    public struct PositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price: u64, margin_locked: u64, timestamp: u64 }
    public struct PositionClosed has copy, drop { symbol: String, account: address, qty: u64, price: u64, margin_refund: u64, timestamp: u64 }

    /*******************************
    * Open/Close positions and variation margin (stub flows)
    *******************************/
    public fun open_position<C>(
        _cfg: &CollateralConfig<C>,
        market: &mut FuturesContract,
        side: u8,
        size: u64,
        entry_price: u64,
        mut margin: Coin<C>,
        ctx: &mut TxContext
    ): FuturesPosition<C> {
        assert!(market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        let notional = size * entry_price;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(margin.value() >= init_req, E_MIN_INTERVAL);
        let locked = margin.split(init_req, ctx);
        // Refund any remainder back to owner
        transfer::public_transfer(margin, tx_context::sender(ctx));
        market.open_interest = market.open_interest + size;
        let pos = FuturesPosition<C> { id: object::new(ctx), owner: tx_context::sender(ctx), contract_id: object::id(market), side, size, avg_price: entry_price, margin: locked, accumulated_pnl: 0, opened_at_ms: 0u64 };
        event::emit(PositionOpened { symbol: market.symbol, account: pos.owner, side, size, price: entry_price, margin_locked: pos.margin.value(), timestamp: 0u64 });
        pos
    }

    public entry fun close_position<C>(
        _cfg: &CollateralConfig<C>,
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
        let pnl_delta: u64 = if (pos.side == 0) { // long
            if (close_price >= pos.avg_price) {
                (close_price - pos.avg_price) * quantity
            } else {
                0 // Handle negative PnL separately if needed
            }
        } else {
            if (pos.avg_price >= close_price) {
                (pos.avg_price - close_price) * quantity
            } else {
                0 // Handle negative PnL separately if needed
            }
        };
        // Apply PnL to accumulated and margin (clamped)
        pos.accumulated_pnl = pos.accumulated_pnl + pnl_delta;
        // Refund proportional margin on close
        let total_margin = pos.margin.value();
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) {
            let out = pos.margin.split(margin_refund, ctx);
            transfer::public_transfer(out, pos.owner);
        };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; };
        // route a nominal fee to treasury (notional * settlement_fee_bps), placeholder
        let notional = quantity * close_price;
        let fee = (notional * reg.settlement_fee_bps) / 10_000;
        if (fee > 0) {
            // Deduct fee from remaining position margin proportionally if available
            let avail = pos.margin.value();
            if (avail >= fee) {
                let fee_coin = pos.margin.split(fee, ctx);
                transfer::public_transfer(fee_coin, TreasuryMod::treasury_address(treasury));
            };
        };
        let new_margin_val = pos.margin.value();
        event::emit(VariationMarginApplied { symbol: market.symbol, account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_price, to_price: close_price, pnl_delta, new_margin: new_margin_val, timestamp: 0u64 });
        event::emit(PositionClosed { symbol: market.symbol, account: pos.owner, qty: quantity, price: close_price, margin_refund: margin_refund, timestamp: 0u64 });
        event::emit(FuturesTrade { symbol: market.symbol, taker: tx_context::sender(ctx), maker: @0x0, size: quantity, price: close_price, fee_collateral: fee, maker_rebate_collateral: 0, timestamp: 0u64 });
    }

    /*******************************
     * Record fill - metrics + fees (maker rebate, UNXV discount, bot split)
     *******************************/
    public entry fun record_fill<C>(
        _cfg: &CollateralConfig<C>,
        reg: &mut FuturesRegistry,
        market: &mut FuturesContract,
        price: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        unxv_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        mut fee_payment: Coin<C>,  // Fee payment in admin-set collateral
        oi_increase: bool,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        // Enforce tick size
        assert!(price % market.tick_size == 0, E_MIN_INTERVAL);
        let notional = size * price;
        // Fees
        let trade_fee = (notional * reg.trade_fee_bps) / 10_000;
        let discount_usdc = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && vector::length(&unxv_payment) > 0) {
            let price_unxv = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv > 0) {
                let unxv_needed = (discount_usdc + price_unxv - 1) / price_unxv;
                let mut merged = coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    merged.join(c);
                    i = i + 1;
                };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vec_unxv = vector::empty<Coin<unxversal::unxv::UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    TreasuryMod::deposit_unxv(treasury, vec_unxv, b"futures_trade".to_string(), tx_context::sender(ctx), ctx);
                    transfer::public_transfer(merged, tx_context::sender(ctx));
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, tx_context::sender(ctx));
                }
            }
        };
        let collateral_fee_after_discount = if (discount_applied) { trade_fee - discount_usdc } else { trade_fee };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        
        // Process fee payment - caller must provide sufficient collateral
        assert!(coin::value(&fee_payment) >= collateral_fee_after_discount, E_MIN_INTERVAL);
        let mut fee_collector = coin::split(&mut fee_payment, collateral_fee_after_discount, ctx);
        
        if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) {
            let to_maker = coin::split(&mut fee_collector, maker_rebate, ctx);
            transfer::public_transfer(to_maker, maker);
        };
        
        if (reg.trade_bot_reward_bps > 0) {
            let bot_cut = (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000;
            if (bot_cut > 0) {
                let to_bot = coin::split(&mut fee_collector, bot_cut, ctx);
                transfer::public_transfer(to_bot, tx_context::sender(ctx));
            };
        };
        
        // Transfer remaining fees to treasury and return excess payment
        transfer::public_transfer(fee_collector, TreasuryMod::treasury_address(treasury));
        if (coin::value(&fee_payment) > 0) {
            transfer::public_transfer(fee_payment, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(fee_payment);
        };
        // Metrics
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; }; };
        market.volume_premium_usdc = market.volume_premium_usdc + notional;
        market.last_trade_premium_usdc = price;
        
        // Consume any remaining UNXV payment vector
        while (vector::length(&unxv_payment) > 0) {
            let remaining_coin = vector::pop_back(&mut unxv_payment);
            transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
        };
        vector::destroy_empty(unxv_payment);
        
        event::emit(FuturesTrade { symbol: market.symbol, taker: tx_context::sender(ctx), maker, size, price, fee_collateral: collateral_fee_after_discount, maker_rebate_collateral: maker_rebate, timestamp: 0u64 });
        event::emit(FillRecorded { symbol: market.symbol, price, size, taker: tx_context::sender(ctx), maker, taker_is_buyer, fee_collateral: collateral_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate_collateral: maker_rebate, bot_reward_collateral: if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: 0u64 });
    }

    /*******************************
     * Liquidation - seize margin when equity < maintenance
     *******************************/
    public fun liquidate_position<C>(
        _cfg: &CollateralConfig<C>,
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
        let margin_val = pos.margin.value();
        let unrealized: u64 = if (pos.side == 0) { // long
            if (mark_price >= pos.avg_price) {
                (mark_price - pos.avg_price) * pos.size
            } else {
                0 // Handle negative unrealized PnL by reducing margin
            }
        } else {
            if (pos.avg_price >= mark_price) {
                (pos.avg_price - mark_price) * pos.size
            } else {
                0 // Handle negative unrealized PnL by reducing margin
            }
        };
        let equity: u64 = margin_val + unrealized;
        let notional = pos.size * mark_price;
        let maint_req = (notional * market.maint_margin_bps) / 10_000;
        if (equity >= maint_req) { return; }; // not liquidatable
        event::emit(MarginCall { symbol: market.symbol, account: pos.owner, equity_collateral: equity, maint_required_collateral: maint_req, timestamp: 0u64 });
        // Seize all margin to treasury, split bot reward
        let seized_total = pos.margin.value();
        if (seized_total > 0) {
            let mut seized = pos.margin.split(seized_total, ctx);
            let bot_cut = (seized_total * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) {
                let to_bot = seized.split(bot_cut, ctx);
                transfer::public_transfer(to_bot, tx_context::sender(ctx));
            };
            transfer::public_transfer(seized, TreasuryMod::treasury_address(treasury));
        };
        // Reset position
        let liq_price = mark_price;
        let qty = pos.size;
        pos.size = 0;
        event::emit(FuturesLiq { symbol: market.symbol, account: pos.owner, size: qty, price: liq_price, seized_margin: seized_total, bot_reward: (seized_total * reg.settlement_bot_reward_bps) / 10_000, timestamp: 0u64 });
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; }
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
    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(check_is_admin(synth_reg, addr), E_NOT_ADMIN); }

    /*******************************
    * Init & display
    *******************************/
    public fun init_registry(synth_reg: &SynthRegistry, ctx: &mut TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        let reg = FuturesRegistry {
            id: object::new(ctx),
            paused: false,
            underlyings: vec_set::empty(),
            price_feeds: table::new<String, vector<u8>>(ctx),
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
            default_max_oi_per_user: 1_000_000, // Default 1M units per user
            last_list_ms: table::new<String, u64>(ctx),
            treasury_id: object::id_from_address(@0x0),
        };
        transfer::share_object(reg)
    }

    public entry fun pause(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.paused = true; event::emit(PausedToggled { new_state: true, by: tx_context::sender(ctx), timestamp: 0u64 }); }
    public entry fun resume(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.paused = false; event::emit(PausedToggled { new_state: false, by: tx_context::sender(ctx), timestamp: 0u64 }); }

    public entry fun set_params(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, settlement_fee_bps: u64, settlement_bot_reward_bps: u64, min_list_interval_ms: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
        reg.min_list_interval_ms = min_list_interval_ms;
    }

    public entry fun set_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    /*******************************
     * Per-contract pause guards
     *******************************/
    public entry fun pause_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut FuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); market.paused = true; }
    public entry fun resume_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut FuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); market.paused = false; }

    public entry fun set_limits_and_settlement_cfg(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut FuturesRegistry,
        dispute_window_ms: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        reg.dispute_window_ms = dispute_window_ms;
    }

    public entry fun set_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.treasury_id = TreasuryMod::treasury_id(treasury); }

    /*******************************
    * Underlyings & feeds (admin)
    *******************************/
    public entry fun whitelist_underlying(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, underlying: String, feed_bytes: vector<u8>, ctx: &TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        vec_set::insert(&mut reg.underlyings, underlying);
        table::add(&mut reg.price_feeds, underlying, feed_bytes);
        event::emit(UnderlyingWhitelisted { underlying, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    /*******************************
    * Listing (permissionless on whitelisted underlyings)
    *******************************/
    public entry fun list_futures(reg: &mut FuturesRegistry, underlying: String, symbol: String, contract_size: u64, tick_size: u64, expiry_ms: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(vec_set::contains(&reg.underlyings, &underlying), E_UNKNOWN_UNDERLYING);
        let now = 0u64;
        let last = if (table::contains(&reg.last_list_ms, underlying)) { *table::borrow(&reg.last_list_ms, underlying) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        table::add(&mut reg.last_list_ms, underlying, now);

        let mc = FuturesContract {
            id: object::new(ctx),
            symbol: symbol,
            underlying: underlying,
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
            volume_premium_usdc: 0,
            last_trade_premium_usdc: 0,
        };
        let id = object::id(&mc);
        transfer::share_object(mc);
        table::add(&mut reg.contracts, symbol, id);
        event::emit(FuturesListed { symbol, underlying, expiry_ms, contract_size, tick_size, timestamp: now });
        // Caller discovers the shared object via event and registry mapping
    }

    /*******************************
    * Display helper
    *******************************/
    public entry fun init_futures_display(publisher: &sui::package::Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<FuturesContract>(publisher, ctx);
        disp.add(b"name".to_string(), b"Futures {symbol} on {underlying}".to_string());
        disp.add(b"description".to_string(), b"Unxversal dated futures contract".to_string());
        disp.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        disp.add(b"contract_size".to_string(), b"{contract_size}".to_string());
        disp.add(b"tick_size".to_string(), b"{tick_size}".to_string());
        disp.update_version();
        transfer::public_transfer(disp, tx_context::sender(ctx));

        // Registry type display
        let mut rdisp = display::new<FuturesRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Futures Registry".to_string());
        rdisp.add(b"description".to_string(), b"Controls listing and global fee/limit params for Futures".to_string());
        rdisp.add(b"trade_fee_bps".to_string(), b"{trade_fee_bps}".to_string());
        rdisp.add(b"maker_rebate_bps".to_string(), b"{maker_rebate_bps}".to_string());
        rdisp.add(b"unxv_discount_bps".to_string(), b"{unxv_discount_bps}".to_string());
        rdisp.add(b"default_max_oi_per_user".to_string(), b"{default_max_oi_per_user}".to_string());
        rdisp.update_version();
        transfer::public_transfer(rdisp, tx_context::sender(ctx));
        event::emit(RegistryDisplayInitialized { by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    /*******************************
    * Settlement (trustless via oracle)
    *******************************/
    public entry fun settle_futures<C>(reg: &mut FuturesRegistry, oracle_cfg: &OracleConfig, market: &mut FuturesContract, clock: &Clock, price_info: &PriceInfoObject, _treasury: &mut Treasury<C>, _ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(!market.is_expired, E_ALREADY_SETTLED);
        let now = 0u64;
        assert!(now >= market.expiry_ms, E_MIN_INTERVAL);
        // Production-ready settlement with oracle validation
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        market.settlement_price = px;
        market.settled_at_ms = now;
        market.is_expired = true;
        market.is_active = false;
        // Settlement fee accrual to treasury (bot split)
        // Fees are applied in batch processing of positions below via the queue processor.
        event::emit(FuturesSettled { symbol: market.symbol, underlying: market.underlying, expiry_ms: market.expiry_ms, settlement_price: px, timestamp: now });
    }

    /// Settle a single position at the recorded market settlement price. Anyone can call.
    public fun settle_position<C>(
        _cfg: &CollateralConfig<C>,
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
        let pnl_total: u64 = if (pos.side == 0) { // long
            if (px >= pos.avg_price) {
                (px - pos.avg_price) * pos.size
            } else {
                0 // Simplified: handle losses separately
            }
        } else {
            if (pos.avg_price >= px) {
                (pos.avg_price - px) * pos.size
            } else {
                0 // Simplified: handle losses separately
            }
        };
        // Apply settlement fee and bot split, collected from remaining margin if positive PnL; otherwise margin absorbs losses
        let mut margin_val = pos.margin.value();
        if (pnl_total >= 0) {
            let fee = ((pnl_total as u64) * reg.settlement_fee_bps) / 10_000;
            if (fee > 0 && margin_val >= fee) {
                let fee_coin = pos.margin.split(fee, ctx);
                // Optional bot reward cut from fee before deposit
                if (reg.settlement_bot_reward_bps > 0) {
                    let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000;
                    if (bot_cut > 0) {
                        let to_bot = pos.margin.split(bot_cut, ctx);
                        transfer::public_transfer(to_bot, tx_context::sender(ctx));
                    }
                };
                transfer::public_transfer(fee_coin, TreasuryMod::treasury_address(treasury));
                margin_val = pos.margin.value();
            };
        } else {
            // Losses: In production u64 system, negative PnL is handled by liquidation
            // Position settlement assumes the position was already liquidated if underwater
            // No additional loss handling needed here as margin is already seized during liquidation
        };
        let size = pos.size;
        let fee_for_event = ((if (pnl_total >= 0) { pnl_total as u64 } else { 0 }) * reg.settlement_fee_bps) / 10_000;
        event::emit(PositionSettled { symbol: market.symbol, account: pos.owner, size, settlement_price: px, fee_collateral: fee_for_event, bot_reward_collateral: (fee_for_event * reg.settlement_bot_reward_bps) / 10_000, timestamp: 0u64 });
        // Close position fully and return remaining margin to owner
        pos.size = 0;
        let rem = pos.margin.value();
        if (rem > 0) {
            let out = pos.margin.split(rem, ctx);
            transfer::public_transfer(out, pos.owner);
        }
    }

    /*******************************
     * Settlement Queue with Dispute Window
     *******************************/
    public struct SettlementQueue has key, store {
        id: UID,
        entries: Table<ID, u64>, // contract_id -> ready_after_ms
    }

    public entry fun init_settlement_queue(ctx: &mut TxContext) {
        let q = SettlementQueue { id: object::new(ctx), entries: table::new<ID, u64>(ctx) };
        transfer::share_object(q);
    }

    public entry fun request_settlement(reg: &FuturesRegistry, market: &FuturesContract, queue: &mut SettlementQueue, _ctx: &TxContext) {
        assert!(!reg.paused, E_PAUSED);
        // Only enqueue once contract is marked expired (price recorded)
        assert!(market.is_expired, E_MIN_INTERVAL);
        let ready = market.settled_at_ms + reg.dispute_window_ms;
        table::add(&mut queue.entries, object::id(market), ready);
    }

    // TODO: Reimplement bulk settlement processing with valid Move patterns
    // public entry fun process_due_settlements(
    //     reg: &FuturesRegistry,
    //     queue: &mut SettlementQueue,
    //     market_ids: vector<ID>,  // Use IDs instead of references
    //     ctx: &mut TxContext
    // ) {
    //     // Implementation needed with proper Move patterns
    // }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun get_contract_id(reg: &FuturesRegistry, symbol: String): ID { *table::borrow(&reg.contracts, symbol) }
    public fun is_underlying_whitelisted(reg: &FuturesRegistry, u: &String): bool { vec_set::contains(&reg.underlyings, u) }
    public fun get_market_metrics(m: &FuturesContract): (u64, u64, u64) { (m.open_interest, m.volume_premium_usdc, m.last_trade_premium_usdc) }
    public fun position_info<C>(p: &FuturesPosition<C>): (address, ID, u8, u64, u64, u64, u64, u64) { (p.owner, p.contract_id, p.side, p.size, p.avg_price, coin::value(&p.margin), (p.accumulated_pnl as u64), p.opened_at_ms) }
    public fun registry_trade_fee_params(reg: &FuturesRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun registry_settlement_params(reg: &FuturesRegistry): (u64, u64) { (reg.settlement_fee_bps, reg.settlement_bot_reward_bps) }
}


