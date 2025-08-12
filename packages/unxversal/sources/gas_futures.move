module unxversal::gas_futures {
    /*******************************
    * Unxversal Gas Futures – Cash‑settled on RGP×SUI
    * - Contract price unit: micro‑USD per gas unit
    * - Settlement uses on‑chain RGP (reference gas price) × SUI/USD oracle
    * - Orderbook/off‑chain matching; on‑chain record_fill + positions/margin
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

    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6}; // SUI/USD price in micro‑USD per 1 SUI
    use pyth::price_info::PriceInfoObject; // for SUI/USD
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{SynthRegistry, AdminCap};

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_MIN_INTERVAL: u64 = 3;
    const E_ALREADY_SETTLED: u64 = 4;

    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(VecSet::contains(&synth_reg.admin_addrs, addr), E_NOT_ADMIN); }

    /*******************************
    * Registry
    *******************************/
    public struct GasFuturesRegistry has key, store {
        id: UID,
        paused: bool,
        contracts: Table<String, ID>,
        trade_fee_bps: u64,
        maker_rebate_bps: u64,
        unxv_discount_bps: u64,
        trade_bot_reward_bps: u64,
        settlement_fee_bps: u64,
        settlement_bot_reward_bps: u64,
        min_list_interval_ms: u64,
        dispute_window_ms: u64,
        default_init_margin_bps: u64,
        default_maint_margin_bps: u64,
        last_list_ms: Table<String, u64>,
        treasury_id: ID,
    }

    /*******************************
    * Contract
    *******************************/
    public struct GasFuturesContract has key, store {
        id: UID,
        symbol: String,                 // e.g., "GAS-DEC24"
        contract_size_gas_units: u64,   // gas units per contract
        tick_size_micro_usd_per_gas: u64,
        expiry_ms: u64,
        paused: bool,
        is_active: bool,
        is_expired: bool,
        settlement_price_micro_usd_per_gas: u64,
        settled_at_ms: u64,
        init_margin_bps: u64,
        maint_margin_bps: u64,
        // Metrics
        open_interest: u64,
        volume_premium_usdc: u64,
        last_trade_premium_micro_usd_per_gas: u64,
    }

    /*******************************
    * Positions
    *******************************/
    public struct GasPosition<phantom C> has key, store {
        id: UID,
        owner: address,
        contract_id: ID,
        side: u8,                    // 0 long, 1 short
        size: u64,                   // in contracts
        avg_price_micro_usd_per_gas: u64,
        margin: Coin<C>,
        accumulated_pnl: i64,
        opened_at_ms: u64,
    }

    /*******************************
    * Events
    *******************************/
    public struct GasContractListed has copy, drop { symbol: String, contract_size_gas_units: u64, tick_size_micro_usd_per_gas: u64, expiry_ms: u64, timestamp: u64 }
    public struct GasSettled has copy, drop { symbol: String, settlement_price_micro_usd_per_gas: u64, timestamp: u64 }
    public struct GasFillRecorded has copy, drop { symbol: String, price_micro_usd_per_gas: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_paid: u64, unxv_discount_applied: bool, maker_rebate: u64, bot_reward: u64, timestamp: u64 }
    public struct GasPositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price_micro_usd_per_gas: u64, margin_locked: u64, sponsor: address, timestamp: u64 }
    public struct GasPositionClosed has copy, drop { symbol: String, account: address, qty: u64, price_micro_usd_per_gas: u64, margin_refund: u64, timestamp: u64 }
    public struct GasVariationMargin has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta: i64, new_margin: u64, timestamp: u64 }
    public struct GasLiquidated has copy, drop { symbol: String, account: address, size: u64, price_micro_usd_per_gas: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct GasMarginCall has copy, drop { symbol: String, account: address, equity_usdc: i64, maint_required_usdc: u64, timestamp: u64 }

    /*******************************
    * Init & display
    *******************************/
    public entry fun init_gas_registry(synth_reg: &SynthRegistry, ctx: &mut TxContext): GasFuturesRegistry {
        assert_is_admin(synth_reg, ctx.sender());
        let reg = GasFuturesRegistry {
            id: object::new(ctx),
            paused: false,
            contracts: Table::new<String, ID>(ctx),
            trade_fee_bps: 30,
            maker_rebate_bps: 100,
            unxv_discount_bps: 0,
            trade_bot_reward_bps: 0,
            settlement_fee_bps: 10,
            settlement_bot_reward_bps: 0,
            min_list_interval_ms: 60_000,
            dispute_window_ms: 60_000,
            default_init_margin_bps: 1_000,
            default_maint_margin_bps: 600,
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

    public entry fun set_gas_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    public entry fun set_gas_settlement_cfg(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, settlement_fee_bps: u64, settlement_bot_reward_bps: u64, dispute_window_ms: u64, min_list_interval_ms: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
        reg.dispute_window_ms = dispute_window_ms;
        reg.min_list_interval_ms = min_list_interval_ms;
    }

    public entry fun set_gas_treasury(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, treasury: &Treasury, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }
    public entry fun pause_gas_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = true; }
    public entry fun resume_gas_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = false; }

    /*******************************
    * Listing (permissionless with cooldown)
    *******************************/
    public entry fun list_gas_futures(reg: &mut GasFuturesRegistry, symbol: String, contract_size_gas_units: u64, tick_size_micro_usd_per_gas: u64, expiry_ms: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        let now = time::now_ms();
        let last = if (Table::contains(&reg.last_list_ms, &symbol)) { *Table::borrow(&reg.last_list_ms, &symbol) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        Table::insert(&mut reg.last_list_ms, symbol.clone(), now);

        let c = GasFuturesContract {
            id: object::new(ctx),
            symbol: symbol.clone(),
            contract_size_gas_units,
            tick_size_micro_usd_per_gas,
            expiry_ms,
            paused: false,
            is_active: true,
            is_expired: false,
            settlement_price_micro_usd_per_gas: 0,
            settled_at_ms: 0,
            init_margin_bps: if (init_margin_bps > 0) { init_margin_bps } else { reg.default_init_margin_bps },
            maint_margin_bps: if (maint_margin_bps > 0) { maint_margin_bps } else { reg.default_maint_margin_bps },
            open_interest: 0,
            volume_premium_usdc: 0,
            last_trade_premium_micro_usd_per_gas: 0,
        };
        let id = object::id(&c);
        transfer::share_object(c);
        Table::insert(&mut reg.contracts, symbol.clone(), id);
        event::emit(GasContractListed { symbol, contract_size_gas_units, tick_size_micro_usd_per_gas, expiry_ms, timestamp: now });
    }

    public entry fun pause_gas_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = true; }
    public entry fun resume_gas_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = false; }

    public entry fun set_contract_margins(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, init_margin_bps: u64, maint_margin_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        market.init_margin_bps = init_margin_bps;
        market.maint_margin_bps = maint_margin_bps;
    }

    /*******************************
    * Price math – convert RGP×SUI → micro‑USD per gas
    *******************************/
    fun compute_micro_usd_per_gas(ctx: &TxContext, oracle_cfg: &OracleConfig, clock: &Clock, sui_usd: &PriceInfoObject): u64 {
        let rgp_mist_per_gas = TxContext::reference_gas_price(ctx); // in MIST (1e9 MIST = 1 SUI)
        let sui_price_micro_usd = get_price_scaled_1e6(oracle_cfg, clock, sui_usd); // micro‑USD per 1 SUI
        // micro_usd_per_gas = (rgp_mist * sui_price_micro) / 1e9
        let num: u128 = (rgp_mist_per_gas as u128) * (sui_price_micro_usd as u128);
        let denom: u128 = 1_000_000_000u128; // 1e9
        let val = (num / denom) as u64;
        val
    }

    /// Public read-only helper for off-chain sanity checks
    public fun current_micro_usd_per_gas(
        ctx: &TxContext,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        sui_usd: &PriceInfoObject
    ): u64 {
        compute_micro_usd_per_gas(ctx, oracle_cfg, clock, sui_usd)
    }

    /*******************************
    * Positions: open/close
    *******************************/
    public entry fun open_gas_position<C>(
        market: &mut GasFuturesContract,
        side: u8,
        size: u64,
        entry_price_micro_usd_per_gas: u64,
        mut margin: Coin<C>,
        ctx: &mut TxContext
    ): GasPosition<C> {
        assert!(market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        // Initial margin as % of notional: notional = size * contract_size_gas_units * price
        let notional = size * market.contract_size_gas_units * entry_price_micro_usd_per_gas;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(Coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let locked = Coin::split(&mut margin, init_req, ctx);
        transfer::public_transfer(margin, ctx.sender());
        market.open_interest = market.open_interest + size;
        let pos = GasPosition<C> { id: object::new(ctx), owner: ctx.sender(), contract_id: object::id(market), side, size, avg_price_micro_usd_per_gas: entry_price_micro_usd_per_gas, margin: locked, accumulated_pnl: 0, opened_at_ms: time::now_ms() };
        let sponsor_addr = match sui::tx_context::sponsor(ctx) { option::Some(a) => a, option::None => 0x0 };
        event::emit(GasPositionOpened { symbol: market.symbol.clone(), account: pos.owner, side, size, price_micro_usd_per_gas: entry_price_micro_usd_per_gas, margin_locked: Coin::value(&pos.margin), sponsor: sponsor_addr, timestamp: time::now_ms() });
        pos
    }

    public entry fun close_gas_position<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        close_price_micro_usd_per_gas: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        let pnl_delta: i64 = if (pos.side == 0) {
            ((close_price_micro_usd_per_gas as i64 - pos.avg_price_micro_usd_per_gas as i64) * (quantity as i64) * (market.contract_size_gas_units as i64))
        } else {
            ((pos.avg_price_micro_usd_per_gas as i64 - close_price_micro_usd_per_gas as i64) * (quantity as i64) * (market.contract_size_gas_units as i64))
        };
        pos.accumulated_pnl = pos.accumulated_pnl + pnl_delta;
        // Refund proportional margin
        let total_margin = Coin::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) { let out = Coin::split(&mut pos.margin, margin_refund, ctx); transfer::public_transfer(out, pos.owner); }
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; }
        // Settlement fee on close (optional): use registry.settlement_fee_bps as generic close fee
        let notional = quantity * market.contract_size_gas_units * close_price_micro_usd_per_gas;
        let fee = (notional * reg.settlement_fee_bps) / 10_000;
        if (fee > 0) { let avail = Coin::value(&pos.margin); if (avail >= fee) { let fc = Coin::split(&mut pos.margin, fee, ctx); TreasuryMod::deposit_collateral(treasury, fc, b"gas_close".to_string(), pos.owner, ctx); } }
        let new_margin_val = Coin::value(&pos.margin);
        event::emit(GasVariationMargin { symbol: market.symbol.clone(), account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_price_micro_usd_per_gas, to_price: close_price_micro_usd_per_gas, pnl_delta, new_margin: new_margin_val, timestamp: time::now_ms() });
        event::emit(GasPositionClosed { symbol: market.symbol.clone(), account: pos.owner, qty: quantity, price_micro_usd_per_gas: close_price_micro_usd_per_gas, margin_refund: margin_refund, timestamp: time::now_ms() });
    }

    /*******************************
    * Record fill (off‑chain matching)
    *******************************/
    public entry fun record_gas_fill<C>(
        reg: &mut GasFuturesRegistry,
        market: &mut GasFuturesContract,
        price_micro_usd_per_gas: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        sui_usd_price: &PriceInfoObject,
        unxv_usd_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        oi_increase: bool,
        min_price_micro_usd_per_gas: u64,
        max_price_micro_usd_per_gas: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        // Enforce tick
        assert!(price_micro_usd_per_gas % market.tick_size_micro_usd_per_gas == 0, E_MIN_INTERVAL);
        // Slippage bounds
        assert!(price_micro_usd_per_gas >= min_price_micro_usd_per_gas && price_micro_usd_per_gas <= max_price_micro_usd_per_gas, E_MIN_INTERVAL);
        let notional = size * market.contract_size_gas_units * price_micro_usd_per_gas;
        // Fees
        let trade_fee = (notional * reg.trade_fee_bps) / 10_000;
        let discount_usdc = (trade_fee * reg.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && vector::length(&unxv_payment) > 0) {
        let sui_price = get_price_scaled_1e6(oracle_cfg, clock, sui_usd_price);
        let unxv_price_feed = get_price_scaled_1e6(oracle_cfg, clock, unxv_usd_price);
        if (sui_price > 0) {
            let unxv_price = if (unxv_price_feed > 0) { unxv_price_feed } else { sui_price };
            if (unxv_price > 0) {
                let unxv_needed = (discount_usdc + unxv_price - 1) / unxv_price;
                let mut merged = Coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); Coin::merge(&mut merged, c); i = i + 1; };
                let have = Coin::value(&merged);
                if (have >= unxv_needed) {
                    let exact = Coin::split(&mut merged, unxv_needed, ctx);
                    let mut vecu = vector::empty<Coin<unxversal::unxv::UNXV>>(); vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"gas_trade".to_string(), ctx.sender(), ctx);
                    transfer::public_transfer(merged, ctx.sender());
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, ctx.sender());
                }
            }
        }
        };
        let usdc_fee_after_discount = if (discount_applied) { if (discount_usdc <= trade_fee) { trade_fee - discount_usdc } else { 0 } } else { trade_fee };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        // Collect fee stream from taker: require caller to have prefunded fee coin via other legs; here we just create accumulator and deposit
        if (usdc_fee_after_discount > 0) {
            let mut fee_collector = Coin::zero<C>(ctx);
            if (maker_rebate > 0 && maker_rebate < usdc_fee_after_discount) { let to_maker = Coin::split(&mut fee_collector, maker_rebate, ctx); transfer::public_transfer(to_maker, maker); }
            if (reg.trade_bot_reward_bps > 0) { let bot_cut = (usdc_fee_after_discount * reg.trade_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bot = Coin::split(&mut fee_collector, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); } }
            TreasuryMod::deposit_collateral(treasury, fee_collector, b"gas_trade".to_string(), ctx.sender(), ctx);
        }
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; } }
        market.volume_premium_usdc = market.volume_premium_usdc + notional;
        market.last_trade_premium_micro_usd_per_gas = price_micro_usd_per_gas;
        event::emit(GasFillRecorded { symbol: market.symbol.clone(), price_micro_usd_per_gas, size, taker: ctx.sender(), maker, taker_is_buyer, fee_paid: usdc_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate: maker_rebate, bot_reward: if (reg.trade_bot_reward_bps > 0) { (usdc_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: time::now_ms() });
    }

    /*******************************
    * Liquidation
    *******************************/
    public entry fun liquidate_gas_position<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        mark_price_micro_usd_per_gas: u64,
        maint_margin_bps: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(object::id(&market) == pos.contract_id, E_MIN_INTERVAL);
        let margin_val = Coin::value(&pos.margin);
        let unrealized: i64 = if (pos.side == 0) { ((mark_price_micro_usd_per_gas as i64 - pos.avg_price_micro_usd_per_gas as i64) * (pos.size as i64) * (market.contract_size_gas_units as i64)) } else { ((pos.avg_price_micro_usd_per_gas as i64 - mark_price_micro_usd_per_gas as i64) * (pos.size as i64) * (market.contract_size_gas_units as i64)) };
        let equity: i128 = (margin_val as i128) + (unrealized as i128);
        let notional = pos.size * market.contract_size_gas_units * mark_price_micro_usd_per_gas;
        let maint_req = (notional * maint_margin_bps) / 10_000;
        if (!(equity < (maint_req as i128))) { return; }
        event::emit(GasMarginCall { symbol: market.symbol.clone(), account: pos.owner, equity_usdc: equity as i64, maint_required_usdc: maint_req, timestamp: time::now_ms() });
        let seized_total = Coin::value(&pos.margin);
        if (seized_total > 0) {
            let mut seized = Coin::split(&mut pos.margin, seized_total, ctx);
            let bot_cut = (seized_total * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let to_bot = Coin::split(&mut seized, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); }
            TreasuryMod::deposit_collateral(treasury, seized, b"gas_liquidation".to_string(), ctx.sender(), ctx);
        }
        let qty = pos.size; pos.size = 0;
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; }
        event::emit(GasLiquidated { symbol: market.symbol.clone(), account: pos.owner, size: qty, price_micro_usd_per_gas: mark_price_micro_usd_per_gas, seized_margin: seized_total, bot_reward: (seized_total * reg.settlement_bot_reward_bps) / 10_000, timestamp: time::now_ms() });
    }

    /*******************************
    * Settlement – compute RGP×SUI and record; per‑position settlement
    *******************************/
    public entry fun settle_gas_futures(reg: &mut GasFuturesRegistry, market: &mut GasFuturesContract, oracle_cfg: &OracleConfig, clock: &Clock, sui_usd: &PriceInfoObject, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(!market.is_expired, E_ALREADY_SETTLED);
        let now = time::now_ms();
        assert!(now >= market.expiry_ms, E_MIN_INTERVAL);
        let px = compute_micro_usd_per_gas(ctx, oracle_cfg, clock, sui_usd);
        market.settlement_price_micro_usd_per_gas = px;
        market.settled_at_ms = now;
        market.is_expired = true; market.is_active = false;
        event::emit(GasSettled { symbol: market.symbol.clone(), settlement_price_micro_usd_per_gas: px, timestamp: now });
    }

    public struct GasSettlementQueue has key, store { id: UID, entries: Table<ID, u64> }
    public entry fun init_gas_settlement_queue(ctx: &mut TxContext) { let q = GasSettlementQueue { id: object::new(ctx), entries: Table::new<ID, u64>(ctx) }; transfer::share_object(q); }
    public entry fun request_gas_settlement(reg: &GasFuturesRegistry, market: &GasFuturesContract, queue: &mut GasSettlementQueue, ctx: &TxContext) { assert!(!reg.paused, E_PAUSED); assert!(market.is_expired, E_MIN_INTERVAL); let ready = market.settled_at_ms + reg.dispute_window_ms; Table::insert(&mut queue.entries, object::id(market), ready); }
    public entry fun process_due_gas_settlements(reg: &GasFuturesRegistry, queue: &mut GasSettlementQueue, markets: vector<&mut GasFuturesContract>, ctx: &TxContext) { assert!(!reg.paused, E_PAUSED); let now = time::now_ms(); let mut i = 0; while (i < vector::length(&markets)) { let m = *vector::borrow_mut(&mut markets, i); if (Table::contains(&queue.entries, &object::id(m))) { let ready = *Table::borrow(&queue.entries, &object::id(m)); if (now >= ready) { Table::remove(&mut queue.entries, &object::id(m)); } }; i = i + 1; } }

    public entry fun settle_gas_position<C>(reg: &GasFuturesRegistry, market: &GasFuturesContract, pos: &mut GasPosition<C>, treasury: &mut Treasury<C>, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED); assert!(market.is_expired, E_MIN_INTERVAL); assert!(object::id(&market) == pos.contract_id, E_MIN_INTERVAL);
        let px = market.settlement_price_micro_usd_per_gas;
        let pnl_total: i64 = if (pos.side == 0) { ((px as i64 - pos.avg_price_micro_usd_per_gas as i64) * (pos.size as i64) * (market.contract_size_gas_units as i64)) } else { ((pos.avg_price_micro_usd_per_gas as i64 - px as i64) * (pos.size as i64) * (market.contract_size_gas_units as i64)) };
        let mut margin_val = Coin::value(&pos.margin);
        if (pnl_total >= 0) {
            let fee = ((pnl_total as u64) * reg.settlement_fee_bps) / 10_000;
            if (fee > 0 && margin_val >= fee) { let fee_coin = Coin::split(&mut pos.margin, fee, ctx); if (reg.settlement_bot_reward_bps > 0) { let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bot = Coin::split(&mut pos.margin, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); } } TreasuryMod::deposit_collateral(treasury, fee_coin, b"gas_settlement".to_string(), pos.owner, ctx); margin_val = Coin::value(&pos.margin); }
        } else {
            let loss = (-(pnl_total)) as u64; if (loss > 0) { let burn = if (margin_val >= loss) { loss } else { margin_val }; if (burn > 0) { let _ = Coin::split(&mut pos.margin, burn, ctx); } }
        }
        let rem = Coin::value(&pos.margin); pos.size = 0;
        if (rem > 0) { let out = Coin::split(&mut pos.margin, rem, ctx); transfer::public_transfer(out, pos.owner); }
    }

    /*******************************
    * Read-only
    *******************************/
    public fun gas_contract_id(reg: &GasFuturesRegistry, symbol: &String): ID { *Table::borrow(&reg.contracts, symbol) }
    public fun gas_market_metrics(m: &GasFuturesContract): (u64, u64, u64) { (m.open_interest, m.volume_premium_usdc, m.last_trade_premium_micro_usd_per_gas) }
    public fun gas_position_info<C>(p: &GasPosition<C>): (address, ID, u8, u64, u64, u64, i64, u64) { (p.owner, p.contract_id, p.side, p.size, p.avg_price_micro_usd_per_gas, Coin::value(&p.margin), p.accumulated_pnl, p.opened_at_ms) }
    public fun gas_registry_trade_fee_params(reg: &GasFuturesRegistry): (u64, u64, u64, u64) { (reg.trade_fee_bps, reg.maker_rebate_bps, reg.unxv_discount_bps, reg.trade_bot_reward_bps) }
    public fun gas_registry_settlement_params(reg: &GasFuturesRegistry): (u64, u64, u64, u64) { (reg.settlement_fee_bps, reg.settlement_bot_reward_bps, reg.min_list_interval_ms, reg.dispute_window_ms) }

    /// Consolidated runtime config for bots/clients
    public fun gas_registry_runtime_config(reg: &GasFuturesRegistry): (u64, u64, u64, u64, u64, u64, u64, u64) {
        (
            reg.trade_fee_bps,
            reg.maker_rebate_bps,
            reg.unxv_discount_bps,
            reg.trade_bot_reward_bps,
            reg.settlement_fee_bps,
            reg.settlement_bot_reward_bps,
            reg.default_init_margin_bps,
            reg.default_maint_margin_bps
        )
    }

    /*******************************
    * Displays
    *******************************/
    public entry fun init_gas_displays(publisher: &sui::package::Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<GasFuturesContract>(publisher, ctx);
        disp.add(b"name".to_string(), b"Gas Futures {symbol}".to_string());
        disp.add(b"description".to_string(), b"Unxversal Gas Futures contract".to_string());
        disp.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        disp.add(b"contract_size_gas_units".to_string(), b"{contract_size_gas_units}".to_string());
        disp.add(b"tick_size_micro_usd_per_gas".to_string(), b"{tick_size_micro_usd_per_gas}".to_string());
        disp.update_version();
        transfer::public_transfer(disp, ctx.sender());

        let mut rdisp = display::new<GasFuturesRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Gas Futures Registry".to_string());
        rdisp.add(b"description".to_string(), b"Registry for listing gas futures and global fee params".to_string());
        rdisp.update_version();
        transfer::public_transfer(rdisp, ctx.sender());
    }
}


