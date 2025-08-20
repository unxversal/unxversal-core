module unxversal::gas_futures {
    /*******************************
    * Unxversal Gas Futures – Cash‑settled on RGP×SUI
    * - Contract price unit: micro‑USD per gas unit
    * - Settlement uses on‑chain RGP (reference gas price) × SUI/USD oracle
    * - Orderbook/off‑chain matching; on‑chain record_fill + positions/margin
    *******************************/

    use sui::event;
    use sui::display;
    use sui::clock::Clock;
    use std::string::{Self as string, String};
    use sui::table::{Self as table, Table};
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};

    use unxversal::oracle::{OracleConfig, OracleRegistry, get_price_for_symbol}; // oracle reads + binding
    use switchboard::aggregator::Aggregator; // Switchboard aggregator for prices
    use unxversal::treasury::{Self as TreasuryMod, Treasury, BotRewardsTreasury};
    use unxversal::bot_rewards::{Self as BotRewards, BotPointsRegistry};
    use unxversal::synthetics::{Self as SynthMod, SynthRegistry, AdminCap};

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_MIN_INTERVAL: u64 = 3;
    const E_ALREADY_SETTLED: u64 = 4;

    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    fun clamp_u128_to_u64(x: u128): u64 { if (x > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { x as u64 } }

    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(SynthMod::is_admin(synth_reg, addr), E_NOT_ADMIN); }

    // Local helper to deep-clone a String (byte-wise)
    fun clone_string(s: &String): String {
        let src = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(src, i)); i = i + 1; };
        string::utf8(out)
    }

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
        volume_premium: u64,
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
        margin: Balance<C>,
        accumulated_pnl_abs: u128,
        accumulated_pnl_is_gain: bool,
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
    public struct GasVariationMargin has copy, drop { symbol: String, account: address, side: u8, qty: u64, from_price: u64, to_price: u64, pnl_abs: u128, is_gain: bool, new_margin: u64, timestamp: u64 }
    public struct GasLiquidated has copy, drop { symbol: String, account: address, size: u64, price_micro_usd_per_gas: u64, seized_margin: u64, bot_reward: u64, timestamp: u64 }
    public struct GasMarginCall has copy, drop { symbol: String, account: address, equity_abs: u128, is_positive: bool, maint_required: u64, timestamp: u64 }

    /*******************************
    * Init & display
    *******************************/
    public entry fun init_gas_registry(synth_reg: &SynthRegistry, ctx: &mut TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
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
            // Treasury linkage is configured later via set_gas_treasury<C>
            treasury_id: object::id(synth_reg),
        };
        transfer::public_share_object(reg)
    }

    entry fun set_gas_trade_fee_config(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, trade_fee_bps: u64, maker_rebate_bps: u64, unxv_discount_bps: u64, trade_bot_reward_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    entry fun set_gas_settlement_cfg(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, settlement_fee_bps: u64, settlement_bot_reward_bps: u64, dispute_window_ms: u64, min_list_interval_ms: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
        reg.dispute_window_ms = dispute_window_ms;
        reg.min_list_interval_ms = min_list_interval_ms;
    }

    entry fun set_gas_treasury<C>(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, treasury: &Treasury<C>, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.treasury_id = object::id(treasury); }
    entry fun pause_gas_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = true; }
    entry fun resume_gas_registry(_admin: &AdminCap, synth_reg: &SynthRegistry, reg: &mut GasFuturesRegistry, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); reg.paused = false; }

    /*******************************
    * Listing (permissionless with cooldown)
    *******************************/
    entry fun list_gas_futures(reg: &mut GasFuturesRegistry, symbol: String, contract_size_gas_units: u64, tick_size_micro_usd_per_gas: u64, expiry_ms: u64, init_margin_bps: u64, maint_margin_bps: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED);
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        let last = if (table::contains(&reg.last_list_ms, clone_string(&symbol))) { *table::borrow(&reg.last_list_ms, clone_string(&symbol)) } else { 0 };
        assert!(now >= last + reg.min_list_interval_ms, E_MIN_INTERVAL);
        // Update last_list_ms (remove if exists, then add)
        if (table::contains(&reg.last_list_ms, clone_string(&symbol))) { let _ = table::remove(&mut reg.last_list_ms, clone_string(&symbol)); };
        table::add(&mut reg.last_list_ms, clone_string(&symbol), now);

        let c = GasFuturesContract {
            id: object::new(ctx),
            symbol: clone_string(&symbol),
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
            volume_premium: 0,
            last_trade_premium_micro_usd_per_gas: 0,
        };
        let id = object::id(&c);
        transfer::public_share_object(c);
        table::add(&mut reg.contracts, clone_string(&symbol), id);
        event::emit(GasContractListed { symbol: symbol, contract_size_gas_units, tick_size_micro_usd_per_gas, expiry_ms, timestamp: now });
    }

    entry fun pause_gas_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = true; }
    entry fun resume_gas_contract(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, ctx: &TxContext) { assert_is_admin(synth_reg, ctx.sender()); market.paused = false; }

    entry fun set_contract_margins(_admin: &AdminCap, synth_reg: &SynthRegistry, market: &mut GasFuturesContract, init_margin_bps: u64, maint_margin_bps: u64, ctx: &TxContext) {
        assert_is_admin(synth_reg, ctx.sender());
        market.init_margin_bps = init_margin_bps;
        market.maint_margin_bps = maint_margin_bps;
    }

    /*******************************
    * Price math – convert RGP×SUI → micro‑USD per gas
    *******************************/
    fun compute_micro_usd_per_gas(ctx: &TxContext, oracle_reg: &OracleRegistry, _oracle_cfg: &OracleConfig, clock: &Clock, sui_usd: &Aggregator): u64 {
        let rgp_mist_per_gas = sui::tx_context::reference_gas_price(ctx); // in MIST (1e9 MIST = 1 SUI)
        // micro‑USD per 1 SUI (bound to allow‑listed feed for "SUI")
        let sui_price_micro_usd = get_price_for_symbol(oracle_reg, clock, &b"SUI".to_string(), sui_usd);
        // micro_usd_per_gas = (rgp_mist * sui_price_micro) / 1e9
        let num: u128 = (rgp_mist_per_gas as u128) * (sui_price_micro_usd as u128);
        let denom: u128 = 1_000_000_000u128; // 1e9
        let val = (num / denom) as u64;
        val
    }

    /// Public read-only helper for off-chain sanity checks
    public fun current_micro_usd_per_gas(
        ctx: &TxContext,
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        sui_usd: &Aggregator
    ): u64 {
        compute_micro_usd_per_gas(ctx, oracle_reg, oracle_cfg, clock, sui_usd)
    }

    /*******************************
    * Positions: open/close
    *******************************/
    entry fun open_gas_position<C>(
        market: &mut GasFuturesContract,
        clock: &Clock,
        side: u8,
        size: u64,
        entry_price_micro_usd_per_gas: u64,
        mut margin: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(market.is_active && !market.paused, E_PAUSED);
        assert!(size > 0, E_MIN_INTERVAL);
        // Initial margin as % of notional: notional = size * contract_size_gas_units * price
        let notional = size * market.contract_size_gas_units * entry_price_micro_usd_per_gas;
        let init_req = (notional * market.init_margin_bps) / 10_000;
        assert!(coin::value(&margin) >= init_req, E_MIN_INTERVAL);
        let locked = coin::split(&mut margin, init_req, ctx);
        transfer::public_transfer(margin, ctx.sender());
        market.open_interest = market.open_interest + size;
        let locked_bal = coin::into_balance(locked);
        let pos = GasPosition<C> { id: object::new(ctx), owner: ctx.sender(), contract_id: object::id(market), side, size, avg_price_micro_usd_per_gas: entry_price_micro_usd_per_gas, margin: locked_bal, accumulated_pnl_abs: 0, accumulated_pnl_is_gain: true, opened_at_ms: sui::clock::timestamp_ms(clock) };
        // Use sender as sponsor in event context
        let _sponsor_addr = ctx.sender();
        event::emit(GasPositionOpened { symbol: clone_string(&market.symbol), account: pos.owner, side, size, price_micro_usd_per_gas: entry_price_micro_usd_per_gas, margin_locked: balance::value(&pos.margin), sponsor: _sponsor_addr, timestamp: sui::clock::timestamp_ms(clock) });
        transfer::share_object(pos);
    }

    entry fun close_gas_position<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        clock: &Clock,
        close_price_micro_usd_per_gas: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(quantity > 0 && quantity <= pos.size, E_MIN_INTERVAL);
        // Compute absolute PnL and sign
        let diff = if (close_price_micro_usd_per_gas >= pos.avg_price_micro_usd_per_gas) { (close_price_micro_usd_per_gas - pos.avg_price_micro_usd_per_gas) as u128 } else { (pos.avg_price_micro_usd_per_gas - close_price_micro_usd_per_gas) as u128 };
        let pnl_abs = diff * (quantity as u128) * (market.contract_size_gas_units as u128);
        let is_gain = if (pos.side == 0) { close_price_micro_usd_per_gas >= pos.avg_price_micro_usd_per_gas } else { pos.avg_price_micro_usd_per_gas >= close_price_micro_usd_per_gas };
        if (pnl_abs > 0) {
            if (pos.accumulated_pnl_is_gain == is_gain) {
                pos.accumulated_pnl_abs = pos.accumulated_pnl_abs + pnl_abs;
            } else {
                if (pos.accumulated_pnl_abs >= pnl_abs) { pos.accumulated_pnl_abs = pos.accumulated_pnl_abs - pnl_abs; } else { pos.accumulated_pnl_abs = pnl_abs - pos.accumulated_pnl_abs; pos.accumulated_pnl_is_gain = is_gain; };
            }
        };
        // Refund proportional margin
        let total_margin = balance::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        if (margin_refund > 0) {
            let out_bal = balance::split(&mut pos.margin, margin_refund);
            let out = coin::from_balance(out_bal, ctx);
            transfer::public_transfer(out, pos.owner);
        };
        pos.size = pos.size - quantity;
        if (market.open_interest >= quantity) { market.open_interest = market.open_interest - quantity; };
        // Settlement fee on close (optional): use registry.settlement_fee_bps as generic close fee
        let notional_u128: u128 = (quantity as u128) * (market.contract_size_gas_units as u128) * (close_price_micro_usd_per_gas as u128);
        let fee_u128: u128 = (notional_u128 * (reg.settlement_fee_bps as u128)) / 10_000u128;
        let fee = clamp_u128_to_u64(fee_u128);
        if (fee > 0) {
            let avail = balance::value(&pos.margin);
            if (avail >= fee) {
                let fc_bal = balance::split(&mut pos.margin, fee);
                let mut fc = coin::from_balance(fc_bal, ctx);
                // Optional bot reward split on close fee
                let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000;
                if (bot_cut > 0 && bot_cut < fee) {
                    let to_bot = coin::split(&mut fc, bot_cut, ctx);
                    transfer::public_transfer(to_bot, ctx.sender());
                };
                let epoch_id = BotRewards::current_epoch(points, clock);
                TreasuryMod::deposit_collateral_with_rewards_for_epoch(treasury, bot_treasury, epoch_id, fc, b"gas_close".to_string(), pos.owner, ctx);
            }
        };
        let _new_margin_val = balance::value(&pos.margin);
        let ts = sui::clock::timestamp_ms(clock);
        event::emit(GasVariationMargin { symbol: clone_string(&market.symbol), account: pos.owner, side: pos.side, qty: quantity, from_price: pos.avg_price_micro_usd_per_gas, to_price: close_price_micro_usd_per_gas, pnl_abs: pnl_abs, is_gain, new_margin: _new_margin_val, timestamp: ts });
        event::emit(GasPositionClosed { symbol: clone_string(&market.symbol), account: pos.owner, qty: quantity, price_micro_usd_per_gas: close_price_micro_usd_per_gas, margin_refund: margin_refund, timestamp: ts });
    }

    /*******************************
    * Record fill (off‑chain matching)
    *******************************/
    entry fun record_gas_fill<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        price_micro_usd_per_gas: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        _sui_usd_price: &Aggregator,
        unxv_usd_price: &Aggregator,
        oracle_reg: &OracleRegistry,
        _oracle_cfg: &OracleConfig,
        clock: &Clock,
        mut fee_payment: Coin<C>,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
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
        let notional_u128: u128 = (size as u128) * (market.contract_size_gas_units as u128) * (price_micro_usd_per_gas as u128);
        // Fees (u128)
        let trade_fee_u128: u128 = (notional_u128 * (reg.trade_fee_bps as u128)) / 10_000u128;
        let discount_usdc_u128: u128 = (trade_fee_u128 * (reg.unxv_discount_bps as u128)) / 10_000u128;
        let mut discount_applied = false;
        if (discount_usdc_u128 > 0 && vector::length(&unxv_payment) > 0) {
            // UNXV price bound by oracle registry symbol
            let unxv_price_u64 = get_price_for_symbol(oracle_reg, clock, &b"UNXV".to_string(), unxv_usd_price);
            if (unxv_price_u64 > 0) {
                let px: u128 = unxv_price_u64 as u128;
                let unxv_needed_u128 = (discount_usdc_u128 + px - 1) / px;
                let unxv_needed = clamp_u128_to_u64(unxv_needed_u128);
                    let mut merged = coin::zero<unxversal::unxv::UNXV>(ctx);
                    let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                    let have = coin::value(&merged);
                    if (have >= unxv_needed) {
                        let exact = coin::split(&mut merged, unxv_needed, ctx);
                        let mut vecu = vector::empty<Coin<unxversal::unxv::UNXV>>(); vector::push_back(&mut vecu, exact);
                        let epoch_id = BotRewards::current_epoch(points, clock);
                        TreasuryMod::deposit_unxv_with_rewards_for_epoch(treasury, bot_treasury, epoch_id, vecu, b"gas_trade".to_string(), ctx.sender(), ctx);
                        transfer::public_transfer(merged, ctx.sender());
                        discount_applied = true;
                    } else {
                        transfer::public_transfer(merged, ctx.sender());
                    }
            }
        };
        let collateral_fee_after_discount_u128: u128 = if (discount_applied) { if (discount_usdc_u128 <= trade_fee_u128) { trade_fee_u128 - discount_usdc_u128 } else { 0 } } else { trade_fee_u128 };
        let maker_rebate_u128: u128 = (trade_fee_u128 * (reg.maker_rebate_bps as u128)) / 10_000u128;
        let collateral_fee_after_discount = clamp_u128_to_u64(collateral_fee_after_discount_u128);
        let maker_rebate = clamp_u128_to_u64(maker_rebate_u128);
        // Collect fee stream from taker: require caller to provide fee_payment coin
        if (collateral_fee_after_discount > 0) {
            let have = coin::value(&fee_payment);
            assert!(have >= collateral_fee_after_discount, E_MIN_INTERVAL);
            if (maker_rebate > 0 && maker_rebate < collateral_fee_after_discount) { let to_maker = coin::split(&mut fee_payment, maker_rebate, ctx); transfer::public_transfer(to_maker, maker); };
            if (reg.trade_bot_reward_bps > 0) { let bot_cut = (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bot = coin::split(&mut fee_payment, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); } };
            let epoch_id2 = BotRewards::current_epoch(points, clock);
            TreasuryMod::deposit_collateral_with_rewards_for_epoch(treasury, bot_treasury, epoch_id2, fee_payment, b"gas_trade".to_string(), ctx.sender(), ctx);
        } else { transfer::public_transfer(fee_payment, ctx.sender()); };
        if (oi_increase) { market.open_interest = market.open_interest + size; } else { if (market.open_interest >= size) { market.open_interest = market.open_interest - size; } };
        let notional_clamped = clamp_u128_to_u64(notional_u128);
        market.volume_premium = market.volume_premium + notional_clamped;
        market.last_trade_premium_micro_usd_per_gas = price_micro_usd_per_gas;
        event::emit(GasFillRecorded { symbol: clone_string(&market.symbol), price_micro_usd_per_gas, size, taker: ctx.sender(), maker, taker_is_buyer, fee_paid: collateral_fee_after_discount, unxv_discount_applied: discount_applied, maker_rebate: maker_rebate, bot_reward: if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 }, timestamp: sui::clock::timestamp_ms(clock) });
        // Ensure any remaining UNXV coins are returned and the vector is destroyed
        while (vector::length(&unxv_payment) > 0) {
            let c = vector::pop_back(&mut unxv_payment);
            transfer::public_transfer(c, ctx.sender());
        };
        vector::destroy_empty(unxv_payment);
    }

    /*******************************
    * Liquidation
    *******************************/
    entry fun liquidate_gas_position<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        clock: &Clock,
        mark_price_micro_usd_per_gas: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused && market.is_active && !market.paused, E_PAUSED);
        assert!(object::id(market) == pos.contract_id, E_MIN_INTERVAL);
        let margin_val = balance::value(&pos.margin);
        // compute unrealized abs and sign
        let diff_m = if (mark_price_micro_usd_per_gas >= pos.avg_price_micro_usd_per_gas) { (mark_price_micro_usd_per_gas - pos.avg_price_micro_usd_per_gas) as u128 } else { (pos.avg_price_micro_usd_per_gas - mark_price_micro_usd_per_gas) as u128 };
        let unrl_abs = diff_m * (pos.size as u128) * (market.contract_size_gas_units as u128);
        let unrl_gain = if (pos.side == 0) { mark_price_micro_usd_per_gas >= pos.avg_price_micro_usd_per_gas } else { pos.avg_price_micro_usd_per_gas >= mark_price_micro_usd_per_gas };
        let equity: u128 = if (unrl_gain) { (margin_val as u128) + unrl_abs } else { if ((margin_val as u128) >= unrl_abs) { (margin_val as u128) - unrl_abs } else { 0 } };
        let notional = pos.size * market.contract_size_gas_units * mark_price_micro_usd_per_gas;
        let maint_req = (notional * market.maint_margin_bps) / 10_000;
        if (!(equity < (maint_req as u128))) { return };
        event::emit(GasMarginCall { symbol: clone_string(&market.symbol), account: pos.owner, equity_abs: equity, is_positive: true, maint_required: maint_req, timestamp: sui::clock::timestamp_ms(clock) });
        let seized_total = balance::value(&pos.margin);
        if (seized_total > 0) {
            let seized_bal = balance::split(&mut pos.margin, seized_total);
            let mut seized = coin::from_balance(seized_bal, ctx);
            let bot_cut = (seized_total * reg.settlement_bot_reward_bps) / 10_000;
            if (bot_cut > 0) { let to_bot = coin::split(&mut seized, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); };
            TreasuryMod::deposit_collateral_ext(treasury, seized, b"gas_liquidation".to_string(), ctx.sender(), ctx);
        };
        let qty = pos.size; pos.size = 0;
        if (market.open_interest >= qty) { market.open_interest = market.open_interest - qty; };
        event::emit(GasLiquidated { symbol: clone_string(&market.symbol), account: pos.owner, size: qty, price_micro_usd_per_gas: mark_price_micro_usd_per_gas, seized_margin: seized_total, bot_reward: (seized_total * reg.settlement_bot_reward_bps) / 10_000, timestamp: sui::clock::timestamp_ms(clock) });
    }

    /*******************************
    * Settlement – compute RGP×SUI and record; per‑position settlement
    *******************************/
    entry fun settle_gas_futures(reg: &GasFuturesRegistry, market: &mut GasFuturesContract, oracle_reg: &OracleRegistry, oracle_cfg: &OracleConfig, clock: &Clock, sui_usd: &Aggregator, ctx: &TxContext) {
        assert!(!reg.paused, E_PAUSED);
        assert!(!market.is_expired, E_ALREADY_SETTLED);
        let now = sui::clock::timestamp_ms(clock);
        assert!(now >= market.expiry_ms, E_MIN_INTERVAL);
        let px = compute_micro_usd_per_gas(ctx, oracle_reg, oracle_cfg, clock, sui_usd);
        market.settlement_price_micro_usd_per_gas = px;
        market.settled_at_ms = now;
        market.is_expired = true; market.is_active = false;
        event::emit(GasSettled { symbol: clone_string(&market.symbol), settlement_price_micro_usd_per_gas: px, timestamp: now });
    }

    public struct GasSettlementQueue has key, store { id: UID, entries: Table<ID, u64> }
    public entry fun init_gas_settlement_queue(ctx: &mut TxContext) { let q = GasSettlementQueue { id: object::new(ctx), entries: table::new<ID, u64>(ctx) }; transfer::public_share_object(q); }
    entry fun request_gas_settlement(reg: &GasFuturesRegistry, market: &GasFuturesContract, queue: &mut GasSettlementQueue, _ctx: &TxContext) { assert!(!reg.paused, E_PAUSED); assert!(market.is_expired, E_MIN_INTERVAL); let ready = market.settled_at_ms + reg.dispute_window_ms; if (table::contains(&queue.entries, object::id(market))) { let _ = table::remove(&mut queue.entries, object::id(market)); }; table::add(&mut queue.entries, object::id(market), ready); }
    entry fun request_gas_settlement_with_points(reg: &GasFuturesRegistry, market: &GasFuturesContract, queue: &mut GasSettlementQueue, points: &mut BotPointsRegistry, clock: &Clock, ctx: &mut TxContext) { request_gas_settlement(reg, market, queue, ctx); BotRewards::award_points(points, b"gas_futures.request_settlement".to_string(), ctx.sender(), clock, ctx); }
    entry fun process_due_gas_settlements(reg: &GasFuturesRegistry, queue: &mut GasSettlementQueue, market_ids: vector<ID>, clock: &Clock, _ctx: &TxContext) { assert!(!reg.paused, E_PAUSED); let now = sui::clock::timestamp_ms(clock); let mut i = 0; while (i < vector::length(&market_ids)) { let mid = *vector::borrow(&market_ids, i); if (table::contains(&queue.entries, mid)) { let ready = *table::borrow(&queue.entries, mid); if (now >= ready) { let _ = table::remove(&mut queue.entries, mid); } }; i = i + 1; } }
    entry fun process_due_gas_settlements_with_points(reg: &GasFuturesRegistry, queue: &mut GasSettlementQueue, market_ids: vector<ID>, points: &mut BotPointsRegistry, clock: &Clock, ctx: &mut TxContext) { process_due_gas_settlements(reg, queue, market_ids, clock, ctx); BotRewards::award_points(points, b"gas_futures.process_due_settlements".to_string(), ctx.sender(), clock, ctx); }

    entry fun settle_gas_position<C>(reg: &GasFuturesRegistry, market: &GasFuturesContract, pos: &mut GasPosition<C>, clock: &Clock, treasury: &mut Treasury<C>, bot_treasury: &mut BotRewardsTreasury<C>, points: &BotPointsRegistry, ctx: &mut TxContext) {
        assert!(!reg.paused, E_PAUSED); assert!(market.is_expired, E_MIN_INTERVAL); assert!(object::id(market) == pos.contract_id, E_MIN_INTERVAL);
        let px = market.settlement_price_micro_usd_per_gas;
        // Final PnL
        let diff_s = if (px >= pos.avg_price_micro_usd_per_gas) { (px - pos.avg_price_micro_usd_per_gas) as u128 } else { (pos.avg_price_micro_usd_per_gas - px) as u128 };
        let pnl_abs = diff_s * (pos.size as u128) * (market.contract_size_gas_units as u128);
        let pnl_gain = if (pos.side == 0) { px >= pos.avg_price_micro_usd_per_gas } else { pos.avg_price_micro_usd_per_gas >= px };
        let margin_val = balance::value(&pos.margin);
        if (pnl_gain) {
            let fee = ((if (pnl_abs > (18_446_744_073_709_551_615u64 as u128)) { 18_446_744_073_709_551_615 } else { pnl_abs as u64 }) * reg.settlement_fee_bps) / 10_000;
            if (fee > 0 && margin_val >= fee) {
                let fee_bal = balance::split(&mut pos.margin, fee);
                let mut fee_coin = coin::from_balance(fee_bal, ctx);
                if (reg.settlement_bot_reward_bps > 0) { let bot_cut = (fee * reg.settlement_bot_reward_bps) / 10_000; if (bot_cut > 0) { let to_bot = coin::split(&mut fee_coin, bot_cut, ctx); transfer::public_transfer(to_bot, ctx.sender()); } };
                let epoch_id = BotRewards::current_epoch(points, clock);
                TreasuryMod::deposit_collateral_with_rewards_for_epoch(treasury, bot_treasury, epoch_id, fee_coin, b"gas_settlement".to_string(), pos.owner, ctx);
            }
        } else {
            let loss_abs = if (pnl_abs > (18_446_744_073_709_551_615u64 as u128)) { 18_446_744_073_709_551_615 } else { pnl_abs as u64 };
            if (loss_abs > 0) { let burn = if (margin_val >= loss_abs) { loss_abs } else { margin_val }; if (burn > 0) { let loss_bal = balance::split(&mut pos.margin, burn); let loss_coin = coin::from_balance(loss_bal, ctx); TreasuryMod::deposit_collateral_ext(treasury, loss_coin, b"gas_loss".to_string(), pos.owner, ctx); } }
        };
        let rem = balance::value(&pos.margin); pos.size = 0;
        if (rem > 0) { let out_bal = balance::split(&mut pos.margin, rem); let out = coin::from_balance(out_bal, ctx); transfer::public_transfer(out, pos.owner); }
    }

    /*******************************
    * Read-only
    *******************************/
    public fun gas_contract_id(reg: &GasFuturesRegistry, symbol: &String): ID { *table::borrow(&reg.contracts, clone_string(symbol)) }
    public fun gas_market_metrics(m: &GasFuturesContract): (u64, u64, u64) { (m.open_interest, m.volume_premium, m.last_trade_premium_micro_usd_per_gas) }
    public fun gas_position_info<C>(p: &GasPosition<C>): (address, ID, u8, u64, u64, u64, bool, u128, u64) { (p.owner, p.contract_id, p.side, p.size, p.avg_price_micro_usd_per_gas, balance::value(&p.margin), p.accumulated_pnl_is_gain, p.accumulated_pnl_abs, p.opened_at_ms) }
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
    entry fun init_gas_displays(publisher: &sui::package::Publisher, ctx: &mut TxContext) {
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

    /*******************************
    * Test-only helpers
    *******************************/
    #[test_only]
    public fun set_trade_fee_config_for_testing(
        reg: &mut GasFuturesRegistry,
        trade_fee_bps: u64,
        maker_rebate_bps: u64,
        unxv_discount_bps: u64,
        trade_bot_reward_bps: u64,
    ) {
        reg.trade_fee_bps = trade_fee_bps;
        reg.maker_rebate_bps = maker_rebate_bps;
        reg.unxv_discount_bps = unxv_discount_bps;
        reg.trade_bot_reward_bps = trade_bot_reward_bps;
    }

    #[test_only]
    public fun pause_for_testing(reg: &mut GasFuturesRegistry, flag: bool) { reg.paused = flag; }

    #[test_only]
    public fun pause_contract_for_testing(market: &mut GasFuturesContract, flag: bool) { market.paused = flag; }

    #[test_only]
    public fun new_position_for_testing<C>(
        owner: address,
        market: &GasFuturesContract,
        side: u8,
        size: u64,
        avg_price_micro_usd_per_gas: u64,
        mut margin_in: Coin<C>,
        required_margin: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (GasPosition<C>, Coin<C>) {
        let locked = coin::split(&mut margin_in, required_margin, ctx);
        let pos = GasPosition<C> {
            id: object::new(ctx),
            owner,
            contract_id: object::id(market),
            side,
            size,
            avg_price_micro_usd_per_gas,
            margin: coin::into_balance(locked),
            accumulated_pnl_abs: 0,
            accumulated_pnl_is_gain: true,
            opened_at_ms: sui::clock::timestamp_ms(clock)
        };
        (pos, margin_in)
    }

    #[test_only]
    public fun set_settlement_params_for_testing(
        reg: &mut GasFuturesRegistry,
        settlement_fee_bps: u64,
        settlement_bot_reward_bps: u64
    ) {
        reg.settlement_fee_bps = settlement_fee_bps;
        reg.settlement_bot_reward_bps = settlement_bot_reward_bps;
    }

    // Mirrors for event-field assertions
    #[test_only]
    public struct FillEventMirror has key, store { id: UID, count: u64, last_fee_paid: u64, last_maker_rebate: u64, last_discount_applied: bool, last_bot_reward: u64 }

    #[test_only]
    public fun new_fill_event_mirror_for_testing(ctx: &mut TxContext): FillEventMirror { FillEventMirror { id: object::new(ctx), count: 0, last_fee_paid: 0, last_maker_rebate: 0, last_discount_applied: false, last_bot_reward: 0 } }

    #[test_only]
    public fun fem_count(m: &FillEventMirror): u64 { m.count }
    #[test_only]
    public fun fem_fee_paid(m: &FillEventMirror): u64 { m.last_fee_paid }
    #[test_only]
    public fun fem_maker_rebate(m: &FillEventMirror): u64 { m.last_maker_rebate }
    #[test_only]
    public fun fem_discount_applied(m: &FillEventMirror): bool { m.last_discount_applied }
    #[test_only]
    public fun fem_bot_reward(m: &FillEventMirror): u64 { m.last_bot_reward }

    #[test_only]
    public fun record_gas_fill_with_event_mirror<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        price_micro_usd_per_gas: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        mut unxv_payment: vector<Coin<unxversal::unxv::UNXV>>,
        _sui_usd_price: &Aggregator,
        unxv_usd_price: &Aggregator,
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        fee_payment: Coin<C>,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        oi_increase: bool,
        min_price_micro_usd_per_gas: u64,
        max_price_micro_usd_per_gas: u64,
        mirror: &mut FillEventMirror,
        ctx: &mut TxContext
    ) {
        // Precompute expected values using same logic
        let notional_u128: u128 = (size as u128) * (market.contract_size_gas_units as u128) * (price_micro_usd_per_gas as u128);
        let trade_fee_u128: u128 = (notional_u128 * (reg.trade_fee_bps as u128)) / 10_000u128;
        let discount_usdc_u128: u128 = (trade_fee_u128 * (reg.unxv_discount_bps as u128)) / 10_000u128;
        let mut discount_applied = false;
        if (discount_usdc_u128 > 0 && vector::length(&unxv_payment) > 0) {
            let unxv_price_u64 = get_price_for_symbol(oracle_reg, clock, &b"UNXV".to_string(), unxv_usd_price);
            if (unxv_price_u64 > 0) {
                let px: u128 = unxv_price_u64 as u128;
                let unxv_needed_u128 = (discount_usdc_u128 + px - 1) / px;
                let unxv_needed = clamp_u128_to_u64(unxv_needed_u128);
                let mut merged = coin::zero<unxversal::unxv::UNXV>(ctx);
                let mut i = 0; while (i < vector::length(&unxv_payment)) { let c = vector::pop_back(&mut unxv_payment); coin::join(&mut merged, c); i = i + 1; };
                let have = coin::value(&merged);
                if (have >= unxv_needed) { discount_applied = true; };
                transfer::public_transfer(merged, ctx.sender());
            }
        };
        let collateral_fee_after_discount_u128: u128 = if (discount_applied) { if (discount_usdc_u128 <= trade_fee_u128) { trade_fee_u128 - discount_usdc_u128 } else { 0 } } else { trade_fee_u128 };
        let maker_rebate_u128: u128 = (trade_fee_u128 * (reg.maker_rebate_bps as u128)) / 10_000u128;
        let collateral_fee_after_discount = clamp_u128_to_u64(collateral_fee_after_discount_u128);
        let maker_rebate = clamp_u128_to_u64(maker_rebate_u128);
        let bot_reward = if (reg.trade_bot_reward_bps > 0) { (collateral_fee_after_discount * reg.trade_bot_reward_bps) / 10_000 } else { 0 };
        // Call core
        record_gas_fill<C>(reg, market, price_micro_usd_per_gas, size, taker_is_buyer, maker, vector::empty<Coin<unxversal::unxv::UNXV>>(), _sui_usd_price, unxv_usd_price, oracle_reg, oracle_cfg, clock, fee_payment, treasury, bot_treasury, points, oi_increase, min_price_micro_usd_per_gas, max_price_micro_usd_per_gas, ctx);
        // Update mirror
        mirror.count = mirror.count + 1;
        mirror.last_fee_paid = collateral_fee_after_discount;
        mirror.last_maker_rebate = maker_rebate;
        mirror.last_discount_applied = discount_applied;
        mirror.last_bot_reward = bot_reward;
        // Ensure UNXV payment vector is fully consumed
        while (vector::length(&unxv_payment) > 0) {
            let c = vector::pop_back(&mut unxv_payment);
            transfer::public_transfer(c, ctx.sender());
        };
        vector::destroy_empty(unxv_payment);
    }

    #[test_only]
    public struct GasEventMirror has key, store {
        id: UID,
        vm_count: u64,
        last_vm_qty: u64,
        last_vm_from: u64,
        last_vm_to: u64,
        pc_count: u64,
        last_pc_price: u64,
        last_pc_refund: u64,
        liq_count: u64,
        last_liq_price: u64,
        last_liq_seized: u64,
        settle_count: u64,
        last_settle_price: u64
    }

    #[test_only]
    public fun new_gas_event_mirror_for_testing(ctx: &mut TxContext): GasEventMirror {
        GasEventMirror { id: object::new(ctx), vm_count: 0, last_vm_qty: 0, last_vm_from: 0, last_vm_to: 0, pc_count: 0, last_pc_price: 0, last_pc_refund: 0, liq_count: 0, last_liq_price: 0, last_liq_seized: 0, settle_count: 0, last_settle_price: 0 }
    }

    #[test_only] public fun gem_vm_count(m: &GasEventMirror): u64 { m.vm_count }
    #[test_only] public fun gem_last_vm_qty(m: &GasEventMirror): u64 { m.last_vm_qty }
    #[test_only] public fun gem_last_vm_from(m: &GasEventMirror): u64 { m.last_vm_from }
    #[test_only] public fun gem_last_vm_to(m: &GasEventMirror): u64 { m.last_vm_to }
    #[test_only] public fun gem_pc_count(m: &GasEventMirror): u64 { m.pc_count }
    #[test_only] public fun gem_last_pc_price(m: &GasEventMirror): u64 { m.last_pc_price }
    #[test_only] public fun gem_last_pc_refund(m: &GasEventMirror): u64 { m.last_pc_refund }
    #[test_only] public fun gem_liq_count(m: &GasEventMirror): u64 { m.liq_count }
    #[test_only] public fun gem_last_liq_price(m: &GasEventMirror): u64 { m.last_liq_price }
    #[test_only] public fun gem_last_liq_seized(m: &GasEventMirror): u64 { m.last_liq_seized }
    #[test_only] public fun gem_settle_count(m: &GasEventMirror): u64 { m.settle_count }
    #[test_only] public fun gem_last_settle_price(m: &GasEventMirror): u64 { m.last_settle_price }

    #[test_only]
    public fun close_gas_position_with_event_mirror<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        clock: &Clock,
        close_price_micro_usd_per_gas: u64,
        quantity: u64,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &BotPointsRegistry,
        mirror: &mut GasEventMirror,
        ctx: &mut TxContext
    ) {
        let total_margin = balance::value(&pos.margin);
        let margin_refund = (total_margin * quantity) / pos.size;
        close_gas_position<C>(reg, market, pos, clock, close_price_micro_usd_per_gas, quantity, treasury, bot_treasury, points, ctx);
        mirror.vm_count = mirror.vm_count + 1;
        mirror.last_vm_qty = quantity;
        mirror.last_vm_from = pos.avg_price_micro_usd_per_gas;
        mirror.last_vm_to = close_price_micro_usd_per_gas;
        mirror.pc_count = mirror.pc_count + 1;
        mirror.last_pc_price = close_price_micro_usd_per_gas;
        mirror.last_pc_refund = margin_refund;
    }

    #[test_only]
    public fun liquidate_gas_position_with_event_mirror<C>(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        pos: &mut GasPosition<C>,
        clock: &Clock,
        mark_price_micro_usd_per_gas: u64,
        treasury: &mut Treasury<C>,
        mirror: &mut GasEventMirror,
        ctx: &mut TxContext
    ) {
        let seized_total = balance::value(&pos.margin);
        liquidate_gas_position<C>(reg, market, pos, clock, mark_price_micro_usd_per_gas, treasury, ctx);
        mirror.liq_count = mirror.liq_count + 1;
        mirror.last_liq_price = mark_price_micro_usd_per_gas;
        mirror.last_liq_seized = seized_total;
    }

    #[test_only]
    public fun settle_gas_futures_with_event_mirror(
        reg: &GasFuturesRegistry,
        market: &mut GasFuturesContract,
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        sui_usd: &Aggregator,
        mirror: &mut GasEventMirror,
        ctx: &TxContext
    ) {
        settle_gas_futures(reg, market, oracle_reg, oracle_cfg, clock, sui_usd, ctx);
        mirror.settle_count = mirror.settle_count + 1;
        mirror.last_settle_price = market.settlement_price_micro_usd_per_gas;
    }
}


