/// Module: unxversal_gas_futures
/// ------------------------------------------------------------
/// Futures product on Sui reference gas price (RGP). Similar to `unxversal::futures`
/// but price source is on-chain via `sui::tx_context::{reference_gas_price, gas_price}`.
/// Collateralized in a single coin type Collat, cash-settled. Supports staking/UNXV fee discounts.
#[allow(lint(self_transfer))]
module unxversal::gas_futures {
    use sui::{
        clock::Clock,
        coin::{Self as coin, Coin},
        balance::{Self as balance, Balance},
        event,
        table::{Self as table, Table},
    };

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::staking::{Self as staking, StakingPool};
    use unxversal::unxv::UNXV;

    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO: u64 = 2;
    const E_NO_ACCOUNT: u64 = 3;
    const E_INSUFF: u64 = 4;
    const E_UNDER_IM: u64 = 5;
    const E_UNDER_MM: u64 = 6;

    /// Price scaling: we take RGP (u64 in MIST per unit gas) and scale it to 1e6 by multiplying, then
    /// apply `contract_size` to convert to collateral units. For simplicity, let contract size be in units of MIST.
    public struct GasSeries has copy, drop, store {
        /// If >0, series expires at this ms; else perpetual-like
        expiry_ms: u64,
        /// Contract size in MIST per contract per 1e6 price unit
        contract_size: u64,
    }

    public struct Account<phantom Collat> has store { collat: Balance<Collat>, long_qty: u64, short_qty: u64, avg_long_1e6: u64, avg_short_1e6: u64 }

    public struct GasMarket<phantom Collat> has key, store {
        id: UID,
        series: GasSeries,
        accounts: Table<address, Account<Collat>>,
        initial_margin_bps: u64,
        maintenance_margin_bps: u64,
        liquidation_fee_bps: u64,
    }

    public struct MarketInitialized has copy, drop { market_id: ID, expiry_ms: u64, contract_size: u64, initial_margin_bps: u64, maintenance_margin_bps: u64, liquidation_fee_bps: u64 }
    public struct CollateralDeposited<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn<phantom Collat> has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct PositionChanged has copy, drop { market_id: ID, who: address, is_long: bool, qty_delta: u64, exec_price_1e6: u64, timestamp_ms: u64 }
    public struct FeeCharged has copy, drop { market_id: ID, who: address, notional_1e6: u128, fee_paid: u64, paid_in_unxv: bool, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { market_id: ID, who: address, qty_closed: u64, exec_price_1e6: u64, penalty_collat: u64, timestamp_ms: u64 }

    // === Init ===
    public fun init_market<Collat>(reg_admin: &AdminRegistry, expiry_ms: u64, contract_size: u64, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let m = GasMarket<Collat> { id: object::new(ctx), series: GasSeries { expiry_ms, contract_size }, accounts: table::new<address, Account<Collat>>(ctx), initial_margin_bps: im_bps, maintenance_margin_bps: mm_bps, liquidation_fee_bps: liq_fee_bps };
        event::emit(MarketInitialized { market_id: object::id(&m), expiry_ms, contract_size, initial_margin_bps: im_bps, maintenance_margin_bps: mm_bps, liquidation_fee_bps: liq_fee_bps });
        transfer::share_object(m);
    }

    public fun set_margins<Collat>(reg_admin: &AdminRegistry, market: &mut GasMarket<Collat>, im_bps: u64, mm_bps: u64, liq_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.initial_margin_bps = im_bps;
        market.maintenance_margin_bps = mm_bps;
        market.liquidation_fee_bps = liq_fee_bps;
    }

    // === Collateral ===
    public fun deposit_collateral<Collat>(market: &mut GasMarket<Collat>, c: Coin<Collat>, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        acc.collat.join(coin::into_balance(c));
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralDeposited<Collat> { market_id: object::id(market), who: ctx.sender(), amount: amt, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun withdraw_collateral<Collat>(market: &mut GasMarket<Collat>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<Collat> {
        assert!(amount > 0, E_ZERO);
        let price_1e6 = current_gas_price_1e6(ctx);
        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        let eq = equity(&acc, price_1e6, market.series.contract_size);
        assert!(eq >= amount, E_INSUFF);
        let eq_after = eq - amount;
        let req_im = required_margin_bps(&acc, price_1e6, market.series.contract_size, market.initial_margin_bps);
        assert!(eq_after >= req_im, E_UNDER_IM);
        let part = balance::split(&mut acc.collat, amount);
        let out = coin::from_balance(part, ctx);
        store_account<Collat>(market, ctx.sender(), acc);
        event::emit(CollateralWithdrawn<Collat> { market_id: object::id(market), who: ctx.sender(), amount, timestamp_ms: clock.timestamp_ms() });
        out
    }

    // === Trading (oracle price is reference gas price) ===
    public fun open_long<Collat>(market: &mut GasMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        trade_internal<Collat>(market, true, qty, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    public fun open_short<Collat>(market: &mut GasMarket<Collat>, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, mut maybe_unxv: Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext, qty: u64) {
        trade_internal<Collat>(market, false, qty, cfg, vault, staking_pool, &mut maybe_unxv, clock, ctx);
        option::destroy_none(maybe_unxv);
    }

    fun trade_internal<Collat>(market: &mut GasMarket<Collat>, is_buy: bool, qty: u64, cfg: &FeeConfig, vault: &mut FeeVault, staking_pool: &mut StakingPool, maybe_unxv: &mut Option<Coin<UNXV>>, clock: &Clock, ctx: &mut TxContext) {
        assert!(qty > 0, E_ZERO);
        let now = clock.timestamp_ms();
        if (market.series.expiry_ms > 0) { assert!(now <= market.series.expiry_ms, E_ZERO); };
        let px_1e6 = current_gas_price_1e6(ctx);
        let notional_1e6 = (qty as u128) * (px_1e6 as u128) * (market.series.contract_size as u128);
        // fees
        let taker_bps = fees::gasfut_taker_fee_bps(cfg);
        let pay_with_unxv = option::is_some(maybe_unxv);
        let (t_eff, _) = fees::apply_discounts(taker_bps, 0, pay_with_unxv, staking_pool, ctx.sender(), cfg);
        let fee_amt = ((notional_1e6 * (t_eff as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;

        let mut acc = take_or_new_account<Collat>(market, ctx.sender());
        if (is_buy) {
            if (acc.short_qty > 0) { let reduce = if (qty <= acc.short_qty) { qty } else { acc.short_qty }; if (reduce > 0) { realize_short_into_collateral(&mut acc, px_1e6, reduce, market.series.contract_size, vault, clock, ctx); acc.short_qty = acc.short_qty - reduce; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; } } };
            let add = qty; if (add > 0) { acc.avg_long_1e6 = wavg(acc.avg_long_1e6, acc.long_qty, px_1e6, add); acc.long_qty = acc.long_qty + add; };
        } else {
            if (acc.long_qty > 0) { let reduce2 = if (qty <= acc.long_qty) { qty } else { acc.long_qty }; if (reduce2 > 0) { realize_long_into_collateral(&mut acc, px_1e6, reduce2, market.series.contract_size, vault, clock, ctx); acc.long_qty = acc.long_qty - reduce2; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; } } };
            let add2 = qty; if (add2 > 0) { acc.avg_short_1e6 = wavg(acc.avg_short_1e6, acc.short_qty, px_1e6, add2); acc.short_qty = acc.short_qty + add2; };
        };

        // charge fee
        if (pay_with_unxv) {
            let u = option::extract(maybe_unxv);
            let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, vault, u, clock, ctx);
            staking::add_weekly_reward(staking_pool, stakers_coin, clock);
            transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6, fee_paid: 0, paid_in_unxv: true, timestamp_ms: clock.timestamp_ms() });
        } else {
            assert!(balance::value(&acc.collat) >= fee_amt, E_INSUFF);
            let part = balance::split(&mut acc.collat, fee_amt);
            fees::accrue_generic<Collat>(vault, coin::from_balance(part, ctx), clock, ctx);
            event::emit(FeeCharged { market_id: object::id(market), who: ctx.sender(), notional_1e6, fee_paid: fee_amt, paid_in_unxv: false, timestamp_ms: clock.timestamp_ms() });
        };

        // IM check
        let eq = equity(&acc, px_1e6, market.series.contract_size);
        let req_im = required_margin_bps(&acc, px_1e6, market.series.contract_size, market.initial_margin_bps);
        assert!(eq >= req_im, E_UNDER_IM);

        event::emit(PositionChanged { market_id: object::id(market), who: ctx.sender(), is_long: is_buy, qty_delta: qty, exec_price_1e6: px_1e6, timestamp_ms: clock.timestamp_ms() });
        store_account<Collat>(market, ctx.sender(), acc);
    }

    public fun liquidate<Collat>(market: &mut GasMarket<Collat>, victim: address, qty: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        assert!(table::contains(&market.accounts, victim), E_NO_ACCOUNT);
        assert!(qty > 0, E_ZERO);
        let px = current_gas_price_1e6(ctx);
        let mut acc = table::remove(&mut market.accounts, victim);
        let eq = equity(&acc, px, market.series.contract_size);
        let req_mm = required_margin_bps(&acc, px, market.series.contract_size, market.maintenance_margin_bps);
        assert!(eq < req_mm, E_UNDER_MM);
        let mut closed = 0u64;
        if (acc.long_qty >= acc.short_qty) {
            let c = if (qty <= acc.long_qty) { qty } else { acc.long_qty };
            if (c > 0) { realize_long_into_collateral(&mut acc, px, c, market.series.contract_size, vault, clock, ctx); acc.long_qty = acc.long_qty - c; if (acc.long_qty == 0) { acc.avg_long_1e6 = 0; }; closed = c; };
        } else {
            let c2 = if (qty <= acc.short_qty) { qty } else { acc.short_qty };
            if (c2 > 0) { realize_short_into_collateral(&mut acc, px, c2, market.series.contract_size, vault, clock, ctx); acc.short_qty = acc.short_qty - c2; if (acc.short_qty == 0) { acc.avg_short_1e6 = 0; }; closed = c2; };
        };
        let notional_1e6 = (closed as u128) * (px as u128) * (market.series.contract_size as u128);
        let pen = ((notional_1e6 * (market.liquidation_fee_bps as u128)) / (fees::bps_denom() as u128) / (1_000_000u128)) as u64;
        let have = balance::value(&acc.collat);
        let pay = if (pen <= have) { pen } else { have };
        if (pay > 0) { let part = balance::split(&mut acc.collat, pay); fees::accrue_generic<Collat>(vault, coin::from_balance(part, ctx), clock, ctx); };
        store_account<Collat>(market, victim, acc);
        event::emit(Liquidated { market_id: object::id(market), who: victim, qty_closed: closed, exec_price_1e6: px, penalty_collat: pay, timestamp_ms: clock.timestamp_ms() });
    }

    // Views & helpers
    fun current_gas_price_1e6(ctx: &TxContext): u64 {
        // reference_gas_price is in MIST; treat MIST units directly as 1e6-scaled price units
        sui::tx_context::reference_gas_price(ctx)
    }

    fun equity<Collat>(acc: &Account<Collat>, price_1e6: u64, cs: u64): u64 {
        let coll = balance::value(&acc.collat);
        let (g_long, l_long) = if (acc.long_qty == 0) { (0, 0) } else { realize_long_ul(acc.avg_long_1e6, price_1e6, acc.long_qty, cs) };
        let (g_short, l_short) = if (acc.short_qty == 0) { (0, 0) } else { realize_short_ul(acc.avg_short_1e6, price_1e6, acc.short_qty, cs) };
        let gains: u128 = (g_long as u128) + (g_short as u128);
        let losses: u128 = (l_long as u128) + (l_short as u128);
        if (gains <= losses) {
            let net_loss = (losses - gains) as u64;
            if (coll > net_loss) { coll - net_loss } else { 0 }
        } else {
            let net_gain = (gains - losses) as u64;
            coll + net_gain
        }
    }

    fun required_margin_bps<Collat>(acc: &Account<Collat>, price_1e6: u64, cs: u64, bps: u64): u64 {
        let size_u128 = (acc.long_qty as u128) + (acc.short_qty as u128);
        let gross = size_u128 * (price_1e6 as u128) * (cs as u128);
        let im_1e6 = (gross * (bps as u128) / (fees::bps_denom() as u128));
        (im_1e6 / 1_000_000u128) as u64
    }

    fun realize_long_into_collateral<Collat>(acc: &mut Account<Collat>, exit_1e6: u64, qty: u64, cs: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        if (qty == 0) return;
        if (exit_1e6 < acc.avg_long_1e6) {
            let diff = (acc.avg_long_1e6 - exit_1e6) as u128;
            let loss_1e6 = diff * (qty as u128) * (cs as u128);
            let loss = (loss_1e6 / 1_000_000u128) as u64;
            if (loss > 0) {
                let have = balance::value(&acc.collat);
                let dec = if (loss <= have) { loss } else { have };
                if (dec > 0) {
                    let bal_loss = balance::split(&mut acc.collat, dec);
                    let coin_loss = coin::from_balance(bal_loss, ctx);
                    fees::accrue_generic<Collat>(vault, coin_loss, clock, ctx);
                };
            };
        };
    }

    fun realize_short_into_collateral<Collat>(acc: &mut Account<Collat>, exit_1e6: u64, qty: u64, cs: u64, vault: &mut FeeVault, clock: &Clock, ctx: &mut TxContext) {
        if (qty == 0) return;
        if (exit_1e6 > acc.avg_short_1e6) {
            let diff = (exit_1e6 - acc.avg_short_1e6) as u128;
            let loss_1e6 = diff * (qty as u128) * (cs as u128);
            let loss = (loss_1e6 / 1_000_000u128) as u64;
            if (loss > 0) {
                let have = balance::value(&acc.collat);
                let dec = if (loss <= have) { loss } else { have };
                if (dec > 0) {
                    let bal_loss2 = balance::split(&mut acc.collat, dec);
                    let coin_loss2 = coin::from_balance(bal_loss2, ctx);
                    fees::accrue_generic<Collat>(vault, coin_loss2, clock, ctx);
                };
            };
        };
    }

    fun realize_long_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (exit_1e6 >= entry_1e6) {
            let diff = (exit_1e6 - entry_1e6) as u128;
            let gain_1e6 = diff * (qty as u128) * (cs as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = (entry_1e6 - exit_1e6) as u128;
            let loss_1e6 = diff2 * (qty as u128) * (cs as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun realize_short_ul(entry_1e6: u64, exit_1e6: u64, qty: u64, cs: u64): (u64, u64) {
        if (qty == 0) return (0, 0);
        if (entry_1e6 >= exit_1e6) {
            let diff = (entry_1e6 - exit_1e6) as u128;
            let gain_1e6 = diff * (qty as u128) * (cs as u128);
            ((gain_1e6 / 1_000_000u128) as u64, 0)
        } else {
            let diff2 = (exit_1e6 - entry_1e6) as u128;
            let loss_1e6 = diff2 * (qty as u128) * (cs as u128);
            (0, (loss_1e6 / 1_000_000u128) as u64)
        }
    }

    fun wavg(prev_px: u64, prev_qty: u64, new_px: u64, new_qty: u64): u64 { if (prev_qty == 0) { new_px } else { (((prev_px as u128) * (prev_qty as u128) + (new_px as u128) * (new_qty as u128)) / ((prev_qty + new_qty) as u128)) as u64 } }

    fun take_or_new_account<Collat>(market: &mut GasMarket<Collat>, who: address): Account<Collat> { if (table::contains(&market.accounts, who)) { table::remove(&mut market.accounts, who) } else { Account { collat: balance::zero<Collat>(), long_qty: 0, short_qty: 0, avg_long_1e6: 0, avg_short_1e6: 0 } } }
    fun store_account<Collat>(market: &mut GasMarket<Collat>, who: address, acc: Account<Collat>) { table::add(&mut market.accounts, who, acc); }
}


