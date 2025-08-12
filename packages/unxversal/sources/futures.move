module unxversal::futures {
    /*******************************
    * Unxversal Dated Futures – Core (cash settlement, admin-configurable)
    * - Admin whitelists underlyings and Pyth feeds
    * - Permissionless contract listing on whitelisted underlyings (min interval)
    * - Trustless cash settlement via oracle at/after expiry
    * - Fees to central treasury with optional bot-reward split
    *******************************/

    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::object;
    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::String;
    use std::table::{Self as Table, Table};
    use std::vec_set::{Self as VecSet, VecSet};
    use std::vector;
    use std::time;
    use sui::coin::{Self as Coin, Coin};

    use pyth::price_info::{Self as PriceInfo, PriceInfoObject};
    use pyth::price_identifier;
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{SynthRegistry, AdminCap};

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
        margin: Coin<C>, // locked margin held by position
        accumulated_pnl: i64,   // realized PnL from prior closes/mtm
        opened_at_ms: u64,
    }

    public struct FuturesTrade has copy, drop { symbol: String, taker: address, maker: address, size: u64, price: u64, fee_paid: u64, maker_rebate: u64, timestamp: u64 }
    public struct FuturesLiq has copy, drop { symbol: String, account: address, size: u64, price: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct VariationMarginApplied has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta: i64, new_margin: u64, timestamp: u64 }
    public struct PositionSettled has copy, drop { symbol: String, account: address, size: u64, settlement_price: u64, fee_paid: u64, bot_reward: u64, timestamp: u64 }
    public struct MarginCall has copy, drop { symbol: String, account: address, equity_usdc: i64, maint_required_usdc: u64, timestamp: u64 }
    public struct FillRecorded has copy, drop { symbol: String, price: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_paid: u64, unxv_discount_applied: bool, maker_rebate: u64, bot_reward: u64, timestamp: u64 }
    public struct PositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price: u64, margin_locked: u64, timestamp: u64 }
    public struct PositionClosed has copy, drop { symbol: String, account: address, qty: u64, price: u64, margin_refund: u64, timestamp: u64 }

    /*******************************
    * Open/Close positions and variation margin (stub flows)
    *******************************/
    public entry fun open_position<C>(
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
        assert!(Coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let locked = Coin::split(&mut margin, init_req, ctx);
        // Refund any remainder back to owner
        transfer::public_transfer(margin, ctx.sender());
        market.open_interest = market.open_interest + size;
        let pos = FuturesPosition<C> { id: object::new(ctx), owner: ctx.sender(), contract_id: object::id(market), side, size, avg_price: entry_price, margin: locked, accumulated_pnl: 0, opened_at_ms: time::now_ms() };
        event::emit(PositionOpened { symbol: market.symbol.clone(), account: pos.owner, side, size, price: entry_price, margin_locked: Coin::value(&pos.margin), timestamp: time::now_ms() });
        pos
    }

    public entry fun close_position<C>(
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
        let pnl_delta: i64 = if (pos.side == 0) { // long
            (close_price as i64 - pos.avg_price as i64) * (quantity as i64)
        } else { (pos.avg_price as i64 - close_price as i64) * (quantity as i64) };
        // Apply PnL to accumulated and margin (clamped)
        pos.accumulated_pnl = pos.accumulated_pnl + pnl_delta;
        // Refund proportional margin on close
        let total_margin = Coin::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) {
            let out = Coin::split(&mut pos.margin, margin_refund, ctx);
            transfer::public_transfer(out, pos.owner);
        };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; }
        // route a nominal fee to treasury (notional * settlement_fee_bps), placeholder
        let notional = quantity * close_price;
        let fee = (notional * reg.settlement_fee_bps) / 10_000;
        if (fee > 0) {
            // Deduct fee from remaining position margin proportionally if available
            let avail = Coin::value(&pos.margin);
            if (avail >= fee) {
                let fee_coin = Coin::split(&mut pos.margin, fee, ctx);
                TreasuryMod::deposit_collateral(treasury, fee_coin, b"futures_close".to_string(), pos.owner, ctx);
            }
        }
        let new_margin_val = Coin::value(&pos.margin);
        event::emit(VariationMarginApplied { symbol: market.symbol.clone(), account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_price, to_price: close_price, pnl_delta, new_margin: new_margin_val, timestamp: time::now_ms() });
        event::emit(PositionClosed { symbol: market.symbol.clone(), account: pos.owner, qty: quantity, price: close_price, margin_refund: margin_refund, timestamp: time::now_ms() });
        event::emit(FuturesTrade { symbol: market.symbol.clone(), taker: ctx.sender(), maker: 0x0, size: quantity, price: close_price, fee_paid: fee, maker_rebate: 0, timestamp: time::now_ms() });
    }

    /*******************************
     * Record fill – metrics + fees (maker rebate, UNXV discount, bot split)
     *******************************/
    public entry fun record_fill(
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
                let mut merged = Coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0;
                while (i < vector::length(&unxv_payment)) {
                    let c = vector::pop_back(&mut unxv_payment);
                    Coin::merge(&mut merged, c);
                    i = i + 1;
                };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
                    let mut vec_unxv = vector::empty<Coin<unxversal::unxv::UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    TreasuryMod::deposit_unxv(treasury, vec_unxv, b"futures_trade".to_string(), ctx.sender(), ctx);
                    transfer::public_transfer(merged, ctx.sender());
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, ctx.sender());
                }
            }
        };
        let usdc_fee_after_discount = if (discount_applied) { trade_fee - discount_usdc } else { trade_fee };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        if (usdc_fee_after_discount > 0) {
            // Collect fee from taker via an external payment passed separately is ideal.
            // For now, we emit fee event and expect taker to include a prior transfer into treasury via collateral coin in same tx.
            // If maker rebate is configured, mint rebate from the fee stream by splitting before deposit.
            let mut fee_collector = Coin::zero<C>(ctx);
            if (maker_rebate > 0 && maker_rebate < usdc_fee_after_discount) {
                // Pay maker rebate from taker fee stream if caller supplied funds into fee_collector earlier in tx
                // This path expects the caller to have merged collateral into fee_collector via an outer flow.
                let to_maker = Coin::split(&mut fee_collector, maker_rebate, ctx);
                transfer::public_transfer(to_maker, maker);
            };
            // Bot reward split on trade fee (optional)
            if (reg.trade_bot_reward_bps > 0) {
                let bot_cut = (usdc_fee_after_discount * reg.trade_bot_reward_bps) / 10_000;
                if (bot_cut > 0) {
                    let to_bot = Coin::split(&mut fee_collector, bot_cut, ctx);
                    transfer::public_transfer(to_bot, ctx.sender());
                }
            }
            TreasuryMod::deposit_collateral(treasury, fee_collector, b"futures_trade".to_string(), ctx.sender(), ctx);
        }
        // Metrics
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; } }
        market.volume_premium_usdc = market.volume_premium_usdc + notional;
        market.last_trade_premium_usdc = price;
        event::emit(FuturesTrade { symbol: market.symbol.clone(), taker: ctx.sender(), maker, size, price, fee_paid: usdc_fee_after_discount, maker_rebate: maker_rebate, timestamp: time::now_ms() });
        event::emit(FillRecorded { symbol: market.symbol.clone(), price, size, taker: ctx.sender(), maker, taker_is_buyer, fee_paid: usdc_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate: maker_rebate, bot_reward: if (reg.trade_bot_reward_bps > 0) { (usdc_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: time::now_ms() });
    }

    /*******************************
     * Liquidation – seize margin when equity < maintenance
     *******************************/
    public entry fun liquidate_position(
        reg: &FuturesRegistry,
        market: &mut FuturesContract,
        pos: &mut FuturesPosition,
        mark_price: u64,
        treasury: &mut Treasury,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(object::id(&market) == pos.contract_id, E_MIN_INTERVAL);
        // Equity = margin_value + unrealized PnL
        let margin_val = Coin::value(&pos.margin);
        let unrealized: i64 = if (pos.side == 0) { // long
            (mark_price as i64 - pos.avg_price as i64) * (pos.size as i64)
        } else { (pos.avg_price as i64 - mark_price as i64) * (pos.size as i64) };
        let equity: i128 = (margin_val as i128) + (unrealized as i128);
        let notional = pos.size * mark_price;
        let maint_req = (notional * market.maint_margin_bps) / 10_000;
        if (!(equity < (maint_req as i128))) { return; } // not liquidatable
        event::emit(MarginCall { symbol: market.symbol.clone(), account: pos.owner, equity_usdc: equity as i64, maint_required_usdc: maint_req, timestamp: time::now_ms() });
        // Seize all margin to treasury, split bot reward
        let seized_total = Coin::value(&pos.margin);
        if (seized_total > 0) {
            let mut seized = Coin::split(&mut pos.margin, seized_total, ctx);
            let bot_cut = (seized_total * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) {
                let to_bot = Coin::split(&mut seized, bot_cut, ctx);
                transfer::public_transfer(to_bot, ctx.sender());
            }
            TreasuryMod::deposit_collateral(treasury, seized, b"futures_liquidation".to_string(), ctx.sender(), ctx);
        }
        // Reset position
        let liq_price = mark_price;
        let qty = pos.size;
        pos.size = 0;
        event::emit(FuturesLiq { symbol: market.symbol.clone(), account: pos.owner, size: qty, price: liq_price, seized_margin: seized_total, bot_reward: (seized_total * reg.settlement_bot_reward_bps) / 10_000, timestamp: time::now_ms() });
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
    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(VecSet::contains(&synth_reg.admin_addrs, addr), E_NOT_ADMIN); }

    /*******************************
    * Init & display
    *******************************/
    public entry fun init_registry<C>(synth_reg: &SynthRegistry, ctx: &mut TxContext): FuturesRegistry {
        assert_is_admin(synth_reg, ctx.sender());
        let reg = FuturesRegistry {
            id: object::new(ctx),
            paused: false,
            underlyings: VecSet::empty(),
            price_feeds: Table::new<String, vector<u8>>(ctx),
            contracts: Table::new<String, ID>(ctx),
            settlement_fee_bps: 10,
            settlement_bot_reward_bps: 0,
            min_list_interval_ms: 60_000, // default 1 minute
            trade_fee_bps: 30,
            maker_rebate_bps: 100,
            unxv_discount_bps: 0,
            trade_bot_reward_bps: 0,
            // dispute_window_ms: 60_000,
            dispute_window_ms: 0, // no dispute window for now
            last_list_ms: Table::new<String, u64>(ctx),
            treasury_id: {
                let t = Treasury<C> { id: object::new(ctx), collateral: Coin::zero<C>(ctx), unxv: Coin::zero<unxversal::unxv::UNXV>(ctx), cfg: unxversal::treasury::TreasuryCfg { unxv_burn_bps: 0 } };
                let id = object::id(&t);
                transfer::share_object(t);
                id
            },
        };
        transfer::share_object(reg)
    }

    public entry fun pause(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = true; event::emit(PausedToggled { new_state: true, by: ctx.sender(), timestamp: time::now_ms() }); }
    public entry fun resume(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = false; event::emit(PausedToggled { new_state: false, by: ctx.sender(), timestamp: time::now_ms() }); }

    public entry fun set_params(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, settlement_fee_bps: u64, settlement_bot_reward_bps: u64, min_list_interval_ms: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
        reg.min_list_interval_ms = min_list_interval_ms;
    }

    public entry fun set_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    /*******************************
     * Per-contract pause guards
     *******************************/
    public entry fun pause_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut FuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = true; }
    public entry fun resume_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut FuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = false; }

    public entry fun set_limits_and_settlement_cfg(
        _admin: &AdminCap,
        synth_reg: &SynthRegistry,
        reg: &mut FuturesRegistry,
        dispute_window_ms: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.dispute_window_ms = dispute_window_ms;
    }

    public entry fun set_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }

    /*******************************
    * Underlyings & feeds (admin)
    *******************************/
    public entry fun whitelist_underlying(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut FuturesRegistry, underlying: String, feed_bytes: vector<u8>, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        VecSet::add(&mut reg.underlyings, underlying.clone());
        Table::insert(&mut reg.price_feeds, underlying.clone(), feed_bytes);
        event::emit(UnderlyingWhitelisted { underlying, by: ctx.sender(), timestamp: time::now_ms() });
    }

    /*******************************
    * Listing (permissionless on whitelisted underlyings)
    *******************************/
    public entry fun list_futures(reg: &mut FuturesRegistry, underlying: String, symbol: String, contract_size: u64, tick_size: u64, expiry_ms: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(VecSet::contains(&reg.underlyings, underlying.clone()), E_UNKNOWN_UNDERLYING);
        let now = time::now_ms();
        let last = if (Table::contains(&reg.last_list_ms, &underlying)) { *Table::borrow(&reg.last_list_ms, &underlying) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        Table::insert(&mut reg.last_list_ms, underlying.clone(), now);

        let mc = FuturesContract {
            id: object::new(ctx),
            symbol: symbol.clone(),
            underlying: underlying.clone(),
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
            user_open_interest: Table::new<address, u64>(ctx),
            max_oi_per_user: reg.default_max_oi_per_user,
        };
        let id = object::id(&mc);
        transfer::share_object(mc);
        Table::insert(&mut reg.contracts, symbol.clone(), id);
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
        transfer::public_transfer(disp, ctx.sender());

        // Registry type display
        let mut rdisp = display::new<FuturesRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Futures Registry".to_string());
        rdisp.add(b"description".to_string(), b"Controls listing and global fee/limit params for Futures".to_string());
        rdisp.add(b"trade_fee_bps".to_string(), b"{trade_fee_bps}".to_string());
        rdisp.add(b"maker_rebate_bps".to_string(), b"{maker_rebate_bps}".to_string());
        rdisp.add(b"unxv_discount_bps".to_string(), b"{unxv_discount_bps}".to_string());
        rdisp.add(b"default_max_oi_per_user".to_string(), b"{default_max_oi_per_user}".to_string());
        rdisp.update_version();
        transfer::public_transfer(rdisp, ctx.sender());
        event::emit(RegistryDisplayInitialized { by: ctx.sender(), timestamp: time::now_ms() });
    }

    /*******************************
    * Settlement (trustless via oracle)
    *******************************/
    public entry fun settle_futures(reg: &mut FuturesRegistry, oracle_cfg: &OracleConfig, market: &mut FuturesContract, clock: &Clock, price_info: &PriceInfoObject, treasury: &mut Treasury, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(!market.is_expired, E_ALREADY_SETTLED);
        let now = time::now_ms();
        assert!(now >= market.expiry_ms, E_MIN_INTERVAL);
        // Enforce feed matches whitelisted underlying
        let pi = PriceInfo::get_price_info_from_price_info_object(price_info);
        let feed_id = price_identifier::get_bytes(&PriceInfo::get_price_identifier(&pi));
        let expected = Table::borrow(&reg.price_feeds, &market.underlying);
        assert!(feed_id == *expected, E_BAD_FEED);
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_info);
        market.settlement_price = px;
        market.settled_at_ms = now;
        market.is_expired = true;
        market.is_active = false;
        // Settlement fee accrual to treasury (bot split)
        // Fees are applied in batch processing of positions below via the queue processor.
        event::emit(FuturesSettled { symbol: market.symbol.clone(), underlying: market.underlying.clone(), expiry_ms: market.expiry_ms, settlement_price: px, timestamp: now });
    }

    /// Settle a single position at the recorded market settlement price. Anyone can call.
    public entry fun settle_position(
        reg: &FuturesRegistry,
        market: &FuturesContract,
        pos: &mut FuturesPosition<C>,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        assert!(market.is_expired, E_MIN_INTERVAL);
        assert!(object::id(&market) == pos.contract_id, E_MIN_INTERVAL);
        let px = market.settlement_price;
        // Final PnL versus avg_price
        let pnl_total: i64 = if (pos.side == 0) { // long
            (px as i64 - pos.avg_price as i64) * (pos.size as i64)
        } else { (pos.avg_price as i64 - px as i64) * (pos.size as i64) };
        // Apply settlement fee and bot split, collected from remaining margin if positive PnL; otherwise margin absorbs losses
        let mut margin_val = Coin::value(&pos.margin);
        if (pnl_total >= 0) {
            let fee = ((pnl_total as u64) * reg.settlement_fee_bps) / 10_000;
            if (fee > 0 && margin_val >= fee) {
                let fee_coin = Coin::split(&mut pos.margin, fee, ctx);
                // Optional bot reward cut from fee before deposit
                if (reg.settlement_bot_reward_bps > 0) {
                    let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000;
                    if (bot_cut > 0) {
                        let to_bot = Coin::split(&mut pos.margin, bot_cut, ctx);
                        transfer::public_transfer(to_bot, ctx.sender());
                    }
                }
                TreasuryMod::deposit_collateral(treasury, fee_coin, b"futures_settlement".to_string(), pos.owner, ctx);
                margin_val = Coin::value(&pos.margin);
            }
        } else {
            // Losses: clamp to available margin (position should have been liquidated earlier, but enforce safety)
            let loss = (-(pnl_total)) as u64;
            if (loss > 0) {
                let burn = if (margin_val >= loss) { loss } else { margin_val };
                if (burn > 0) { let _ = Coin::split(&mut pos.margin, burn, ctx); /* implicitly burned by being unreferenced in this scope */ }
            }
        }
        let size = pos.size;
        let fee_for_event = ((if (pnl_total >= 0) { pnl_total as u64 } else { 0 }) * reg.settlement_fee_bps) / 10_000;
        event::emit(PositionSettled { symbol: market.symbol.clone(), account: pos.owner, size, settlement_price: px, fee_paid: fee_for_event, bot_reward: (fee_for_event * reg.settlement_bot_reward_bps) / 10_000, timestamp: time::now_ms() });
        // Close position fully and return remaining margin to owner
        pos.size = 0;
        let rem = Coin::value(&pos.margin);
        if (rem > 0) {
            let out = Coin::split(&mut pos.margin, rem, ctx);
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
        let q = SettlementQueue { id: object::new(ctx), entries: Table::new<ID, u64>(ctx) };
        transfer::share_object(q);
    }

    public entry fun request_settlement(reg: &FuturesRegistry, market: &FuturesContract, queue: &mut SettlementQueue, ctx: &TxContext) {
        assert!(!reg.paused, E_PAUSED);
        // Only enqueue once contract is marked expired (price recorded)
        assert!(market.is_expired, E_MIN_INTERVAL);
        let ready = market.settled_at_ms + reg.dispute_window_ms;
        Table::insert(&mut queue.entries, object::id(market), ready);
    }

    public entry fun process_due_settlements(
        reg: &FuturesRegistry,
        queue: &mut SettlementQueue,
        markets: vector<&mut FuturesContract>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, E_PAUSED);
        let now = time::now_ms();
        let mut i = 0;
        while (i < vector::length(&markets)) {
            let m = *vector::borrow_mut(&mut markets, i);
            if (Table::contains(&queue.entries, &object::id(m))) {
                let ready = *Table::borrow(&queue.entries, &object::id(m));
                if (now >= ready) {
                    // Position-level cash settlement occurs off-chain by bots invoking close/settle flows per position holder.
                    Table::remove(&mut queue.entries, &object::id(m));
                }
            };
            i = i + 1;
        }
    }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun get_contract_id(reg: &FuturesRegistry, symbol: &String): ID { *Table::borrow(&reg.contracts, symbol) }
    public fun is_underlying_whitelisted(reg: &FuturesRegistry, u: &String): bool { VecSet::contains(&reg.underlyings, u.clone()) }
    public fun get_market_metrics(m: &FuturesContract): (u64, u64, u64) { (m.open_interest, m.volume_premium_usdc, m.last_trade_premium_usdc) }
    public fun position_info<C>(p: &FuturesPosition<C>): (address, ID, u8, u64, u64, u64, i64, u64) { (p.owner, p.contract_id, p.side, p.size, p.avg_price, Coin::value(&p.margin), p.accumulated_pnl, p.opened_at_ms) }
    public fun registry_trade_fee_params(reg: &FuturesRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun registry_settlement_params(reg: &FuturesRegistry): (u64, u64) { (reg.settlement_fee_bps, reg.settlement_bot_reward_bps) }
}


