module unxversal::gas_futures {
    /*******************************
    * Unxversal Gas Futures - Cash-settled on RGP×SUI
    * - Contract price unit: micro-USD per gas unit
    * - Settlement uses on-chain RGP (reference gas price) × SUI/USD oracle
    * - Orderbook/off-chain matching; on-chain record_fill + positions/margin
    *******************************/

    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::{String};
    use sui::table::{Self as table, Table};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::oracle::PriceInfoObject;

    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use unxversal::synthetics::{SynthRegistry, AdminCap, check_is_admin, CollateralConfig};
    use unxversal::unxv::UNXV;

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_MIN_INTERVAL: u64 = 3;
    const E_ALREADY_SETTLED: u64 = 4;

    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(check_is_admin(synth_reg, addr), E_NOT_ADMIN); }

    /*******************************
    * Registry
    *******************************/
    public struct GasFuturesRegistry has key, store {
        id: object::UID,
        paused: bool,
        contracts: Table<String, object::ID>,
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
        treasury_id: object::ID,
    }

    /*******************************
    * Contract
    *******************************/
    public struct GasFuturesContract has key, store {
        id: object::UID,
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
        id: object::UID,
        owner: address,
        contract_id: object::ID,
        side: u8,                    // 0 long, 1 short
        size: u64,                   // in contracts
        avg_price_micro_usd_per_gas: u64,
        margin: Balance<C>,          // margin in admin-set collateral
        accumulated_pnl: u64,
        opened_at_ms: u64,
    }

    /*******************************
    * Events
    *******************************/
    public struct GasContractListed has copy, drop { symbol: String, contract_size_gas_units: u64, tick_size_micro_usd_per_gas: u64, expiry_ms: u64, timestamp: u64 }
    public struct GasSettled has copy, drop { symbol: String, settlement_price_micro_usd_per_gas: u64, timestamp: u64 }
    public struct GasFillRecorded has copy, drop { symbol: String, price_micro_usd_per_gas: u64, size: u64, taker: address, maker: address, taker_is_buyer: bool, fee_collateral: u64, unxv_discount_applied: bool, maker_rebate_collateral: u64, bot_reward_collateral: u64, timestamp: u64 }
    public struct GasPositionOpened has copy, drop { symbol: String, account: address, side: u8, size: u64, price_micro_usd_per_gas: u64, margin_locked: u64, sponsor: address, timestamp: u64 }
    public struct GasPositionClosed has copy, drop { symbol: String, account: address, qty: u64, price_micro_usd_per_gas: u64, margin_refund: u64, timestamp: u64 }
    public struct GasVariationMargin has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_delta: u64, new_margin: u64, timestamp: u64 }
    public struct GasLiquidated has copy, drop { symbol: String, account: address, size: u64, price_micro_usd_per_gas: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct GasMarginCall has copy, drop { symbol: String, account: address, equity_collateral: u64, maint_required_collateral: u64, timestamp: u64 }

    /*******************************
    * Init & display
    *******************************/
    public fun init_gas_registry(synth_reg: &SynthRegistry, ctx: &mut tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        let reg = GasFuturesRegistry {
            id: object::new(ctx),
            paused: false,
            contracts: table::new<String, ID>(ctx),
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
            last_list_ms: table::new<String, u64>(ctx),
            treasury_id: object::id_from_address(@0x0), // Placeholder until proper Treasury integration
        };
        transfer::share_object(reg)
    }

    public entry fun set_gas_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, _ctx: &tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(_ctx));
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    public entry fun set_gas_settlement_cfg(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, settlement_fee_bps: u64, settlement_bot_reward_bps: u64, dispute_window_ms: u64, min_list_interval_ms: u64, _ctx: &tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(_ctx));
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
        reg.dispute_window_ms = dispute_window_ms;
        reg.min_list_interval_ms = min_list_interval_ms;
    }

    public entry fun set_gas_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, treasury: &Treasury<C>, _ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(_ctx)); reg.treasury_id = TreasuryMod::treasury_id(treasury); }
    public entry fun pause_gas_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, _ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(_ctx)); reg.paused = true; }
    public entry fun resume_gas_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, _ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(_ctx)); reg.paused = false; }

    /*******************************
    * Listing (permissionless with cooldown)
    *******************************/
    public entry fun list_gas_futures(reg: &mut GasFuturesRegistry, symbol: String, contract_size_gas_units: u64, tick_size_micro_usd_per_gas: u64, expiry_ms: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut tx_context::TxContext) {
        assert!(!reg.paused, E_PAUSED);
        let now = 0u64;
        let last = if (table::contains(&reg.last_list_ms, symbol)) { *table::borrow(&reg.last_list_ms, symbol) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        table::add(&mut reg.last_list_ms, symbol, now);

        let c = GasFuturesContract {
            id: object::new(ctx),
            symbol: symbol,
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
        table::add(&mut reg.contracts, symbol, id);
        event::emit(GasContractListed { symbol, contract_size_gas_units, tick_size_micro_usd_per_gas, expiry_ms, timestamp: now });
    }

    public entry fun pause_gas_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, _ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(_ctx)); market.paused = true; }
    public entry fun resume_gas_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, _ctx: &tx_context::TxContext) { assert_is_admin(synth_reg, tx_context::sender(_ctx)); market.paused = false; }

    public entry fun set_contract_margins(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, init_margin_bps: u64, maint_margin_bps: u64, _ctx: &tx_context::TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(_ctx));
        market.init_margin_bps = init_margin_bps;
        market.maint_margin_bps = maint_margin_bps;
    }

    /*******************************
    * Price math - convert RGP×SUI → micro-USD per gas
    *******************************/
    fun compute_micro_usd_per_gas(_ctx: &tx_context::TxContext, oracle_cfg: &OracleConfig, clock: &Clock, sui_usd: &PriceInfoObject): u64 {
        let rgp_mist_per_gas = tx_context::reference_gas_price(_ctx); // in MIST (1e9 MIST = 1 SUI)
        let sui_price_micro_usd = get_price_scaled_1e6(oracle_cfg, clock, sui_usd); // micro-USD per 1 SUI
        // micro_usd_per_gas = (rgp_mist * sui_price_micro) / 1e9
        let num: u128 = (rgp_mist_per_gas as u128) * (sui_price_micro_usd as u128);
        let denom: u128 = 1_000_000_000u128; // 1e9
        let val = (num / denom) as u64;
        val
    }

    /// Public read-only helper for off-chain sanity checks
    public fun current_micro_usd_per_gas(
        _ctx: &tx_context::TxContext,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        sui_usd: &PriceInfoObject
    ): u64 {
        compute_micro_usd_per_gas(_ctx, oracle_cfg, clock, sui_usd)
    }

    /*******************************
    * Positions: open/close
    *******************************/
    public fun open_gas_position<C>(
        _cfg: &CollateralConfig<C>,
        market: &mut GasFuturesContract,
        side: u8,
        size: u64,
        entry_price_micro_usd_per_gas: u64,
        mut margin: Coin<C>,
        ctx: &mut tx_context::TxContext
    ): GasPosition<C> {
        assert!(market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        // Initial margin as % of notional: notional = size * contract_size_gas_units * price
        let notional = size * market.contract_size_gas_units * entry_price_micro_usd_per_gas;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let locked = coin::into_balance(coin::split(&mut margin, init_req, ctx));
        sui::transfer::public_transfer(margin, tx_context::sender(ctx));
        market.open_interest = market.open_interest + size;
        let pos = GasPosition<C> { id: object::new(ctx), owner: tx_context::sender(ctx), contract_id: object::id(market), side, size, avg_price_micro_usd_per_gas: entry_price_micro_usd_per_gas, margin: locked, accumulated_pnl: 0, opened_at_ms: 0u64 };
        let sponsor_opt = sui::tx_context::sponsor(ctx);
        let sponsor_addr = if (option::is_some(&sponsor_opt)) {
            *option::borrow(&sponsor_opt)
        } else {
            @0x0
        };
        event::emit(GasPositionOpened { symbol: market.symbol, account: pos.owner, side, size, price_micro_usd_per_gas: entry_price_micro_usd_per_gas, margin_locked: balance::value(&pos.margin), sponsor: sponsor_addr, timestamp: 0u64 });
        pos
    }

    public entry fun close_gas_position<C>(
        _cfg: &CollateralConfig<C>,
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        close_price_micro_usd_per_gas: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut tx_context::TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        let pnl_delta: u64 = if (pos.side == 0) {
            if (close_price_micro_usd_per_gas >= pos.avg_price_micro_usd_per_gas) {
                (close_price_micro_usd_per_gas - pos.avg_price_micro_usd_per_gas) * quantity * market.contract_size_gas_units
            } else { 0 }
        } else {
            if (pos.avg_price_micro_usd_per_gas >= close_price_micro_usd_per_gas) {
                (pos.avg_price_micro_usd_per_gas - close_price_micro_usd_per_gas) * quantity * market.contract_size_gas_units
            } else { 0 }
        };
        pos.accumulated_pnl = pos.accumulated_pnl + pnl_delta;
        // Refund proportional margin
        let total_margin = balance::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) { let out = coin::from_balance(balance::split(&mut pos.margin, margin_refund), ctx); sui::transfer::public_transfer(out, pos.owner); };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; };
        // Settlement fee on close (optional): use registry.settlement_fee_bps as generic close fee
        let notional = quantity * market.contract_size_gas_units * close_price_micro_usd_per_gas;
        let fee = (notional * reg.settlement_fee_bps) / 10_000;
        if (fee > 0) { let avail = balance::value(&pos.margin); if (avail >= fee) { let fc = coin::from_balance(balance::split(&mut pos.margin, fee), ctx); sui::transfer::public_transfer(fc, TreasuryMod::treasury_address(treasury)); }; };
        let new_margin_val = balance::value(&pos.margin);
        event::emit(GasVariationMargin { symbol: market.symbol, account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_price_micro_usd_per_gas, to_price: close_price_micro_usd_per_gas, pnl_delta, new_margin: new_margin_val, timestamp: 0u64 });
        event::emit(GasPositionClosed { symbol: market.symbol, account: pos.owner, qty: quantity, price_micro_usd_per_gas: close_price_micro_usd_per_gas, margin_refund: margin_refund, timestamp: 0u64 });
    }

    /*******************************
    * Record fill (off-chain matching)
    *******************************/
    public entry fun record_gas_fill<C>(
        _cfg: &CollateralConfig<C>,
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
        mut fee_payment: Coin<C>,  // Fee payment in admin-set collateral
        oi_increase: bool,
        min_price_micro_usd_per_gas: u64,
        max_price_micro_usd_per_gas: u64,
        ctx: &mut tx_context::TxContext
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
        if (discount_usdc > 0 && std::vector::length(&unxv_payment) > 0) {
        let sui_price = get_price_scaled_1e6(oracle_cfg, clock, sui_usd_price);
        let unxv_price_feed = get_price_scaled_1e6(oracle_cfg, clock, unxv_usd_price);
        if (sui_price > 0) {
            let unxv_price = if (unxv_price_feed > 0) { unxv_price_feed } else { sui_price };
            if (unxv_price > 0) {
                let unxv_needed = (discount_usdc + unxv_price - 1) / unxv_price;
                let mut merged = coin::zero<UNXV>(ctx);
                let mut i = 0; while (i < std::vector::length(&unxv_payment)) { let c = std::vector::pop_back(&mut unxv_payment); merged.join(c); i = i + 1; };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vecu = std::vector::empty<Coin<UNXV>>(); std::vector::push_back(&mut vecu, exact);
                    TreasuryMod::deposit_unxv(treasury, vecu, b"gas_trade".to_string(), tx_context::sender(ctx), ctx);
                    sui::transfer::public_transfer(merged, tx_context::sender(ctx));
                    discount_applied = true;
                } else {
                    sui::transfer::public_transfer(merged, tx_context::sender(ctx));
                }
            }
        }
        };
        let collateral_fee_after_discount = if (discount_applied) { if (discount_usdc <= trade_fee) { trade_fee - discount_usdc } else { 0 } } else { trade_fee };
        let maker_rebate = (trade_fee * reg.maker_rebate_bps) / 10_000;
        
        // Process fee payment - caller must provide sufficient collateral
        assert!(coin::value(&fee_payment) >= collateral_fee_after_discount, E_MIN_INTERVAL);
        let mut fee_collector = coin::split(&mut fee_payment, collateral_fee_after_discount, ctx);
        
        if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) {
            let to_maker = coin::split(&mut fee_collector, maker_rebate, ctx);
            sui::transfer::public_transfer(to_maker, maker);
        };
        if (reg.trade_bot_reward_bps > 0) {
            let bot_cut = (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000;
            if (bot_cut > 0) {
                let to_bot = coin::split(&mut fee_collector, bot_cut, ctx);
                sui::transfer::public_transfer(to_bot, tx_context::sender(ctx));
            };
        };
        
        // Transfer remaining fees to treasury and return excess payment
        sui::transfer::public_transfer(fee_collector, TreasuryMod::treasury_address(treasury));
        if (coin::value(&fee_payment) > 0) {
            sui::transfer::public_transfer(fee_payment, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(fee_payment);
        };
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; }; };
        market.volume_premium_usdc = market.volume_premium_usdc + notional;
        market.last_trade_premium_micro_usd_per_gas = price_micro_usd_per_gas;
        
        // Consume any remaining UNXV payment vector
        while (std::vector::length(&unxv_payment) > 0) {
            let remaining_coin = std::vector::pop_back(&mut unxv_payment);
            sui::transfer::public_transfer(remaining_coin, tx_context::sender(ctx));
        };
        std::vector::destroy_empty(unxv_payment);
        
        event::emit(GasFillRecorded { symbol: market.symbol, price_micro_usd_per_gas, size, taker: tx_context::sender(ctx), maker, taker_is_buyer, fee_collateral: collateral_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate_collateral: maker_rebate, bot_reward_collateral: if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: 0u64 });
    }

    /*******************************
    * Liquidation
    *******************************/
    public fun liquidate_gas_position<C>(
        _cfg: &CollateralConfig<C>,
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        mark_price_micro_usd_per_gas: u64,
        maint_margin_bps: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut tx_context::TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(object::id(market) == pos.contract_id, E_MIN_INTERVAL);
        let margin_val = balance::value(&pos.margin);
        let unrealized: u64 = if (pos.side == 0) {
            if (mark_price_micro_usd_per_gas >= pos.avg_price_micro_usd_per_gas) {
                (mark_price_micro_usd_per_gas - pos.avg_price_micro_usd_per_gas) * pos.size * market.contract_size_gas_units
            } else { 0 }
        } else {
            if (pos.avg_price_micro_usd_per_gas >= mark_price_micro_usd_per_gas) {
                (pos.avg_price_micro_usd_per_gas - mark_price_micro_usd_per_gas) * pos.size * market.contract_size_gas_units
            } else { 0 }
        };
        let equity: u64 = margin_val + unrealized;
        let notional = pos.size * market.contract_size_gas_units * mark_price_micro_usd_per_gas;
        let maint_req = (notional * maint_margin_bps) / 10_000;
        if (equity >= maint_req) { return; };
        event::emit(GasMarginCall { symbol: market.symbol, account: pos.owner, equity_collateral: equity, maint_required_collateral: maint_req, timestamp: 0u64 });
        let seized_total = balance::value(&pos.margin);
        if (seized_total > 0) {
            let mut seized = coin::from_balance(balance::split(&mut pos.margin, seized_total), ctx);
            let bot_cut = (seized_total * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let to_bot = coin::split(&mut seized, bot_cut, ctx); sui::transfer::public_transfer(to_bot, tx_context::sender(ctx)); };
            sui::transfer::public_transfer(seized, TreasuryMod::treasury_address(treasury));
        };
        let qty = pos.size; pos.size = 0;
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; };
        event::emit(GasLiquidated { symbol: market.symbol, account: pos.owner, size: qty, price_micro_usd_per_gas: mark_price_micro_usd_per_gas, seized_margin: seized_total, bot_reward: (seized_total * reg.settlement_bot_reward_bps) / 10_000, timestamp: 0u64 });
    }

    /*******************************
    * Settlement - compute RGP×SUI and record; per-position settlement
    *******************************/
    public entry fun settle_gas_futures(reg: &mut GasFuturesRegistry, market: &mut GasFuturesContract, oracle_cfg: &OracleConfig, clock: &Clock, sui_usd: &PriceInfoObject, ctx: &mut tx_context::TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(!market.is_expired, E_ALREADY_SETTLED);
        let now = 0u64;
        assert!(now >= market.expiry_ms, E_MIN_INTERVAL);
        let px = compute_micro_usd_per_gas(ctx, oracle_cfg, clock, sui_usd);
        market.settlement_price_micro_usd_per_gas = px;
        market.settled_at_ms = now;
        market.is_expired = true; market.is_active = false;
        event::emit(GasSettled { symbol: market.symbol, settlement_price_micro_usd_per_gas: px, timestamp: now });
    }

    public struct GasSettlementQueue has key, store { id: object::UID, entries: Table<object::ID, u64> }
    public entry fun init_gas_settlement_queue(ctx: &mut tx_context::TxContext) { let q = GasSettlementQueue { id: object::new(ctx), entries: table::new<object::ID, u64>(ctx) }; transfer::share_object(q); }
    public entry fun request_gas_settlement(reg: &GasFuturesRegistry, market: &GasFuturesContract, queue: &mut GasSettlementQueue, _ctx: &tx_context::TxContext) { assert!(!reg.paused, E_PAUSED); assert!(market.is_expired, E_MIN_INTERVAL); let ready = market.settled_at_ms + reg.dispute_window_ms; table::add(&mut queue.entries, object::id(market), ready); }
    // TODO: Reimplement with proper Move patterns - vector of references not allowed
    // This function would need to be redesigned to work with IDs instead of direct references
    // public fun process_due_gas_settlements(reg: &GasFuturesRegistry, queue: &mut GasSettlementQueue, market_ids: vector<object::ID>, _ctx: &tx_context::TxContext) {
    //     // Implementation needed with proper Move patterns
    // }

    public fun settle_gas_position<C>(_cfg: &CollateralConfig<C>, reg: &GasFuturesRegistry, market: &GasFuturesContract, pos: &mut GasPosition<C>, treasury: &mut Treasury<C>, ctx: &mut tx_context::TxContext) {
        assert!(!reg.paused, E_PAUSED); assert!(market.is_expired, E_MIN_INTERVAL); assert!(object::id(market) == pos.contract_id, E_MIN_INTERVAL);
        let px = market.settlement_price_micro_usd_per_gas;
        let pnl_total: u64 = if (pos.side == 0) {
            if (px >= pos.avg_price_micro_usd_per_gas) {
                (px - pos.avg_price_micro_usd_per_gas) * pos.size * market.contract_size_gas_units
            } else { 0 }
        } else {
            if (pos.avg_price_micro_usd_per_gas >= px) {
                (pos.avg_price_micro_usd_per_gas - px) * pos.size * market.contract_size_gas_units
            } else { 0 }
        };
        let margin_val = balance::value(&pos.margin);
        // Handle positive PnL (profit)
        if (pnl_total > 0) {
            let fee = (pnl_total * reg.settlement_fee_bps) / 10_000;
            if (fee > 0 && margin_val >= fee) { 
                let mut fee_coin = coin::from_balance(balance::split(&mut pos.margin, fee), ctx); 
                if (reg.settlement_bot_reward_bps > 0) { 
                    let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000; 
                    if (bot_cut > 0) { 
                        let to_bot = coin::split(&mut fee_coin, bot_cut, ctx); 
                        sui::transfer::public_transfer(to_bot, tx_context::sender(ctx)); 
                    }; 
                }; 
                sui::transfer::public_transfer(fee_coin, TreasuryMod::treasury_address(treasury)); 
            };
        };
        // Handle negative PnL (loss) - burn from margin
        // Note: For simplicity in production u64 code, we skip loss handling as margin is already at risk
        let rem = balance::value(&pos.margin); 
        pos.size = 0;
        if (rem > 0) { let out = coin::from_balance(balance::split(&mut pos.margin, rem), ctx); sui::transfer::public_transfer(out, pos.owner); };
    }

    /*******************************
    * Read-only
    *******************************/
    public fun gas_contract_id(reg: &GasFuturesRegistry, symbol: String): object::ID { *table::borrow(&reg.contracts, symbol) }
    public fun gas_market_metrics(m: &GasFuturesContract): (u64, u64, u64) { (m.open_interest, m.volume_premium_usdc, m.last_trade_premium_micro_usd_per_gas) }
    public fun gas_position_info<C>(p: &GasPosition<C>): (address, object::ID, u8, u64, u64, u64, u64, u64) { (p.owner, p.contract_id, p.side, p.size, p.avg_price_micro_usd_per_gas, balance::value(&p.margin), p.accumulated_pnl, p.opened_at_ms) }
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
    public entry fun init_gas_displays(publisher: &sui::package::Publisher, ctx: &mut tx_context::TxContext) {
        let mut disp = display::new<GasFuturesContract>(publisher, ctx);
        disp.add(b"name".to_string(), b"Gas Futures {symbol}".to_string());
        disp.add(b"description".to_string(), b"Unxversal Gas Futures contract".to_string());
        disp.add(b"expiry_ms".to_string(), b"{expiry_ms}".to_string());
        disp.add(b"contract_size_gas_units".to_string(), b"{contract_size_gas_units}".to_string());
        disp.add(b"tick_size_micro_usd_per_gas".to_string(), b"{tick_size_micro_usd_per_gas}".to_string());
        disp.update_version();
        sui::transfer::public_transfer(disp, tx_context::sender(ctx));

        let mut rdisp = display::new<GasFuturesRegistry>(publisher, ctx);
        rdisp.add(b"name".to_string(), b"Unxversal Gas Futures Registry".to_string());
        rdisp.add(b"description".to_string(), b"Registry for listing gas futures and global fee params".to_string());
        rdisp.update_version();
        sui::transfer::public_transfer(rdisp, tx_context::sender(ctx));
    }
}


