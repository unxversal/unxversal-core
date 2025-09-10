/// Module: unxversal_fees
/// ------------------------------------------------------------
/// Centralized fee configuration and vault utilities used by Unxversal protocols.
/// - Stores global protocol fee params (bps), UNXV discount, and distribution splits
/// - Admin-gated updates via `unxversal::admin::AdminRegistry`
/// - Generic fee vault capable of holding balances of arbitrary coins
/// - Helper to accrue UNXV-denominated fees and split to stakers / treasury / burn-vault
module unxversal::fees {
    use std::type_name::{Self as type_name, TypeName};
    use sui::{
        balance::{Self as balance, Balance},
        bag::{Self as bag, Bag},
        coin::{Self as coin, Coin},
        event,
        table::{Self as table, Table},
    };

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::unxv::UNXV;
    use unxversal::staking::{Self as staking, StakingPool};
    use deepbook::pool::{Self as db_pool, Pool};
    use token::deep::DEEP;

    /// Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_SPLIT_INVALID: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_FUNDS: u64 = 4;

    /// Basis points denominator
    const BPS_DENOM: u64 = 10_000;
    const KIND_SPOT: u8 = 0;
    const KIND_PERPS: u8 = 1;
    /// Minimum effective protocol fee (bps) for DEX after discounts
    const DEX_MIN_FEE_BPS: u64 = 20;

    /// Fee distribution parameters (in BPS, all must sum to BPS_DENOM)
    public struct FeeDistribution has copy, drop, store {
        stakers_share_bps: u64,
        treasury_share_bps: u64,
        burn_share_bps: u64,
    }

    /// Global fee configuration shared by protocols
    public struct FeeConfig has key, store {
        id: UID,
        /// Fallback DEX protocol fee in bps (used if specific maker/taker not set)
        dex_fee_bps: u64,
        /// Separate taker protocol fee in bps (0 = use dex_fee_bps)
        dex_taker_fee_bps: u64,
        /// Separate maker protocol fee in bps (0 = use dex_fee_bps)
        dex_maker_fee_bps: u64,
        /// Futures taker protocol fee in bps (0 = use dex_fee_bps)
        futures_taker_fee_bps: u64,
        /// Futures maker protocol fee in bps (0 = use dex_fee_bps)
        futures_maker_fee_bps: u64,
        /// Gas-futures taker protocol fee in bps (0 = use futures_taker_fee_bps)
        gasfut_taker_fee_bps: u64,
        /// Gas-futures maker protocol fee in bps (0 = use futures_maker_fee_bps)
        gasfut_maker_fee_bps: u64,
        /// UNXV discount on Unxversal protocol fees, in bps (e.g. 3000 = 30%)
        unxv_discount_bps: u64,
        /// Address that receives the treasury share
        treasury: address,
        /// Preferred DeepBook backend fee token: true = DEEP, false = input token
        prefer_deep_backend: bool,
        /// Distribution percentages
        dist: FeeDistribution,
        /// Unxversal fee (in UNXV units) for permissionless DeepBook pool creation
        pool_creation_fee_unxv: u64,
        /// Lending origination fee in bps (before discounts); applied on borrow_with_fee
        lending_borrow_fee_bps: u64,
        /// Max collateral-factor bonus in bps for stakers
        lending_collateral_bonus_bps_max: u64,
        /// Staking tier thresholds and discounts (admin-set)
        /// Tier 1 lowest, bps used for discount calculation for lending (max bonus off max stake), DEX fees, and gas-futures fees
        sd_t1_thr: u64, sd_t1_bps: u64,
        sd_t2_thr: u64, sd_t2_bps: u64,
        sd_t3_thr: u64, sd_t3_bps: u64,
        sd_t4_thr: u64, sd_t4_bps: u64,
        sd_t5_thr: u64, sd_t5_bps: u64,
        sd_t6_thr: u64, sd_t6_bps: u64,
    }

    /// Generic key wrapper for storing balances in a Bag
    public struct FeeKey<phantom T> has copy, drop, store {}

    /// PnL key wrapper for storing loser funds to pay winners (segregated from fee balances)
    public struct PnlKey<phantom T> has copy, drop, store {}

    /// Fee vault that can hold balances of arbitrary assets
    public struct FeeVault has key, store {
        id: UID,
        store: Bag,
        /// Accumulated UNXV earmarked to be burned later by an authorized actor
        unxv_to_burn: Balance<UNXV>,
    }

    /// Events
    public struct FeeConfigUpdated has copy, drop {
        who: address,
        timestamp_ms: u64,
        dex_fee_bps: u64,
        unxv_discount_bps: u64,
        prefer_deep_backend: bool,
        stakers_bps: u64,
        treasury_bps: u64,
        burn_bps: u64,
        treasury: address,
    }

    public struct FeeAccrued has copy, drop {
        payer: address,
        asset: TypeName,
        amount: u64,
        timestamp_ms: u64,
    }

    public struct UnxvFeeSplit has copy, drop {
        payer: address,
        total_unxv: u64,
        stakers_unxv: u64,
        treasury_unxv: u64,
        burn_unxv: u64,
        timestamp_ms: u64,
    }

    /// Emitted when admin withdraws fees from the FeeVault
    public struct FeeWithdrawn has copy, drop {
        who: address,
        to: address,
        asset: TypeName,
        amount: u64,
        timestamp_ms: u64,
    }

    // maker rebates removed

    /// One-time witness for module initialization
    public struct FEES has drop {}
    public struct VOLS has drop {}

    /// Initialize the fee manager objects (config + vault). Treasury defaults to publisher.
    fun init(_w: FEES, ctx: &mut TxContext) {
        let cfg = FeeConfig {
            id: object::new(ctx),
            dex_fee_bps: 7,                // 7 bps initial DEX protocol fee
            dex_taker_fee_bps: 7,
            dex_maker_fee_bps: 4,
            futures_taker_fee_bps: 5,       // default taker fee for futures 
            futures_maker_fee_bps: 2,       // default maker fee for futures
            gasfut_taker_fee_bps: 5,        // default equal to futures
            gasfut_maker_fee_bps: 2,
            unxv_discount_bps: 3000,         // 30% discount
            treasury: ctx.sender(),
            prefer_deep_backend: false,
            dist: FeeDistribution { stakers_share_bps: 4000, treasury_share_bps: 4000, burn_share_bps: 2000 },
            pool_creation_fee_unxv: 500,
            lending_borrow_fee_bps: 0,
            lending_collateral_bonus_bps_max: 500, // +5% max bonus by default
            sd_t1_thr: 10, sd_t1_bps: 500,
            sd_t2_thr: 100, sd_t2_bps: 1000,
            sd_t3_thr: 1_000, sd_t3_bps: 1500,
            sd_t4_thr: 10_000, sd_t4_bps: 2000,
            sd_t5_thr: 100_000, sd_t5_bps: 3000,
            sd_t6_thr: 500_000, sd_t6_bps: 4000,
        };
        let vault = FeeVault { id: object::new(ctx), store: bag::new(ctx), unxv_to_burn: balance::zero<UNXV>() };
        transfer::share_object(cfg);
        transfer::share_object(vault);
    }

    /// Admin: update fee parameters (all-or-nothing)
    public fun set_params(
        reg_admin: &AdminRegistry,
        cfg: &mut FeeConfig,
        dex_fee_bps: u64,
        unxv_discount_bps: u64,
        prefer_deep_backend: bool,
        stakers_share_bps: u64,
        treasury_share_bps: u64,
        burn_share_bps: u64,
        treasury: address,
        clock: &sui::clock::Clock,
        ctx: &TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(stakers_share_bps + treasury_share_bps + burn_share_bps == BPS_DENOM, E_SPLIT_INVALID);
        cfg.dex_fee_bps = dex_fee_bps;
        cfg.unxv_discount_bps = unxv_discount_bps;
        cfg.prefer_deep_backend = prefer_deep_backend;
        cfg.treasury = treasury;
        cfg.dist = FeeDistribution { stakers_share_bps, treasury_share_bps, burn_share_bps };
        event::emit(FeeConfigUpdated {
            who: ctx.sender(),
            timestamp_ms: sui::clock::timestamp_ms(clock),
            dex_fee_bps,
            unxv_discount_bps,
            prefer_deep_backend,
            stakers_bps: stakers_share_bps,
            treasury_bps: treasury_share_bps,
            burn_bps: burn_share_bps,
            treasury,
        });
    }

    /// Admin: set separate maker/taker protocol fees (bps)
    public fun set_trade_fees(reg_admin: &AdminRegistry, cfg: &mut FeeConfig, taker_bps: u64, maker_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        cfg.dex_taker_fee_bps = taker_bps;
        cfg.dex_maker_fee_bps = maker_bps;
    }

    /// Admin: set futures maker/taker protocol fees (bps)
    public fun set_futures_trade_fees(reg_admin: &AdminRegistry, cfg: &mut FeeConfig, taker_bps: u64, maker_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        cfg.futures_taker_fee_bps = taker_bps;
        cfg.futures_maker_fee_bps = maker_bps;
    }

    /// Admin: set gas-futures maker/taker protocol fees (bps)
    public fun set_gasfutures_trade_fees(reg_admin: &AdminRegistry, cfg: &mut FeeConfig, taker_bps: u64, maker_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        cfg.gasfut_taker_fee_bps = taker_bps;
        cfg.gasfut_maker_fee_bps = maker_bps;
    }

    // maker rebates removed

    /// Admin: set UNXV fee amount for permissionless pool creation
    public fun set_pool_creation_fee_unxv(reg_admin: &AdminRegistry, cfg: &mut FeeConfig, fee_unxv: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        cfg.pool_creation_fee_unxv = fee_unxv;
    }

    /// Admin: set lending fee and collateral bonus max (bps)
    public fun set_lending_params(reg_admin: &AdminRegistry, cfg: &mut FeeConfig, borrow_fee_bps: u64, cf_bonus_max_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        cfg.lending_borrow_fee_bps = borrow_fee_bps;
        cfg.lending_collateral_bonus_bps_max = cf_bonus_max_bps;
    }

    /// Admin: set staking tier table (6 tiers)
    public fun set_staking_tiers(
        reg_admin: &AdminRegistry,
        cfg: &mut FeeConfig,
        t1: u64, b1: u64,
        t2: u64, b2: u64,
        t3: u64, b3: u64,
        t4: u64, b4: u64,
        t5: u64, b5: u64,
        t6: u64, b6: u64,
        ctx: &TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        cfg.sd_t1_thr = t1; cfg.sd_t1_bps = b1;
        cfg.sd_t2_thr = t2; cfg.sd_t2_bps = b2;
        cfg.sd_t3_thr = t3; cfg.sd_t3_bps = b3;
        cfg.sd_t4_thr = t4; cfg.sd_t4_bps = b4;
        cfg.sd_t5_thr = t5; cfg.sd_t5_bps = b5;
        cfg.sd_t6_thr = t6; cfg.sd_t6_bps = b6;
    }

    /// Calculate discounted fee amount using UNXV discount
    public fun apply_unxv_discount(base_amount: u64, cfg: &FeeConfig): u64 {
        let discount = cfg.unxv_discount_bps;
        // base_amount * (1 - discount/BPS_DENOM)
        let num = (BPS_DENOM - discount) as u128 * (base_amount as u128);
        (num / (BPS_DENOM as u128)) as u64
    }

    /// Accrue a generic asset fee into the vault (no distribution). Intended for "paid in input token" path.
    public fun accrue_generic<T>(vault: &mut FeeVault, amount: Coin<T>, clock: &sui::clock::Clock, ctx: &TxContext) {
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        event::emit(FeeAccrued { payer: ctx.sender(), asset: type_name::get<T>(), amount: amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
        // Convert to Balance and join into Bag
        let key = FeeKey<T> {};
        let bal = coin::into_balance(amount);
        if (bag::contains(&vault.store, key)) {
            let b: &mut Balance<T> = &mut vault.store[key];
            b.join(bal);
        } else {
            vault.store.add(key, bal);
        };
    }
    
    /// Deposit realized PnL losses into the vault under the PnL bucket for asset T.
    public fun pnl_deposit<T>(vault: &mut FeeVault, amount: Coin<T>) {
        let key = PnlKey<T> {};
        let bal = coin::into_balance(amount);
        if (bag::contains(&vault.store, key)) {
            let b: &mut Balance<T> = &mut vault.store[key];
            b.join(bal);
        } else {
            vault.store.add(key, bal);
        };
    }

    /// Return available PnL balance for asset T in the vault
    public fun pnl_available<T>(vault: &FeeVault): u64 {
        let key = PnlKey<T> {};
        if (bag::contains(&vault.store, key)) {
            let b: &Balance<T> = &vault.store[key];
            balance::value(b)
        } else { 0 }
    }

    /// Withdraw PnL to pay realized gains to winners. Aborts if insufficient funds.
    public fun pnl_withdraw<T>(vault: &mut FeeVault, amount: u64, ctx: &mut TxContext): Coin<T> {
        let key = PnlKey<T> {};
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(bag::contains(&vault.store, key), E_ZERO_AMOUNT);
        let b: &mut Balance<T> = &mut vault.store[key];
        let avail = balance::value(b);
        assert!(avail >= amount, E_ZERO_AMOUNT);
        let part = balance::split(b, amount);
        coin::from_balance(part, ctx)
    }
    
    /// Accrue UNXV-denominated fee and split to stakers / treasury / burn buckets.
    /// - stakers_unxv is expected to be deposited into a staking pool by the caller.
    /// - treasury_unxv is transferred to `cfg.treasury`.
    /// - burn_unxv is retained inside `vault.unxv_to_burn` for a later explicit burn call.
    public fun accrue_unxv_and_split(
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut unxv_fee: Coin<UNXV>,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ): (Coin<UNXV>, Coin<UNXV>, u64) {
        let total = coin::value(&unxv_fee);
        assert!(total > 0, E_ZERO_AMOUNT);
        let stakers_part = (total as u128 * (cfg.dist.stakers_share_bps as u128) / (BPS_DENOM as u128)) as u64;
        let treasury_part = (total as u128 * (cfg.dist.treasury_share_bps as u128) / (BPS_DENOM as u128)) as u64;
        let burn_part = total - stakers_part - treasury_part;

        let stakers_coin = coin::split(&mut unxv_fee, stakers_part, ctx);
        let treasury_coin = coin::split(&mut unxv_fee, treasury_part, ctx);
        let burn_coin = unxv_fee; // remainder

        // Accumulate burn share inside the vault (as Balance)
        let burn_bal = coin::into_balance(burn_coin);
        vault.unxv_to_burn.join(burn_bal);

        // Emit split event
        event::emit(UnxvFeeSplit {
            payer: ctx.sender(),
            total_unxv: total,
            stakers_unxv: stakers_part,
            treasury_unxv: treasury_part,
            burn_unxv: burn_part,
            timestamp_ms: sui::clock::timestamp_ms(clock),
        });

        (stakers_coin, treasury_coin, burn_part)
    }

    /// Admin: transfer UNXV accumulated in vault for burning to the provided SupplyCap.burn (owner-controlled).
    /// This function converts the retained `unxv_to_burn` Balance into a Coin and returns it to the caller
    /// to execute the burn using their `unxversal::unxv::SupplyCap`.
    public fun withdraw_unxv_to_burn(reg_admin: &AdminRegistry, vault: &mut FeeVault, ctx: &mut TxContext): Coin<UNXV> {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let amt = balance::value(&vault.unxv_to_burn);
        assert!(amt > 0, E_ZERO_AMOUNT);
        // Split out the requested amount and convert to a Coin
        let bal_out = balance::split(&mut vault.unxv_to_burn, amt);
        let c = coin::from_balance(bal_out, ctx);
        c
    }

    /// View helpers
    public fun dex_fee_bps(cfg: &FeeConfig): u64 { cfg.dex_fee_bps }
    public fun unxv_discount_bps(cfg: &FeeConfig): u64 { cfg.unxv_discount_bps }
    public fun prefer_deep_backend(cfg: &FeeConfig): bool { cfg.prefer_deep_backend }
    public fun treasury_address(cfg: &FeeConfig): address { cfg.treasury }
    public fun shares(cfg: &FeeConfig): (u64, u64, u64) { (cfg.dist.stakers_share_bps, cfg.dist.treasury_share_bps, cfg.dist.burn_share_bps) }
    public fun bps_denom(): u64 { BPS_DENOM }
    public fun dex_taker_fee_bps(cfg: &FeeConfig): u64 { if (cfg.dex_taker_fee_bps > 0) { cfg.dex_taker_fee_bps } else { cfg.dex_fee_bps } }
    public fun dex_maker_fee_bps(cfg: &FeeConfig): u64 { if (cfg.dex_maker_fee_bps > 0) { cfg.dex_maker_fee_bps } else { cfg.dex_fee_bps } }
    public fun futures_taker_fee_bps(cfg: &FeeConfig): u64 { if (cfg.futures_taker_fee_bps > 0) { cfg.futures_taker_fee_bps } else { cfg.dex_fee_bps } }
    public fun futures_maker_fee_bps(cfg: &FeeConfig): u64 { if (cfg.futures_maker_fee_bps > 0) { cfg.futures_maker_fee_bps } else { cfg.dex_fee_bps } }
    public fun gasfut_taker_fee_bps(cfg: &FeeConfig): u64 { let base = futures_taker_fee_bps(cfg); if (cfg.gasfut_taker_fee_bps > 0) { cfg.gasfut_taker_fee_bps } else { base } }
    public fun gasfut_maker_fee_bps(cfg: &FeeConfig): u64 { let base = futures_maker_fee_bps(cfg); if (cfg.gasfut_maker_fee_bps > 0) { cfg.gasfut_maker_fee_bps } else { base } }
    public fun pool_creation_fee_unxv(cfg: &FeeConfig): u64 { cfg.pool_creation_fee_unxv }
    public fun lending_borrow_fee_bps(cfg: &FeeConfig): u64 { cfg.lending_borrow_fee_bps }
    public fun lending_collateral_bonus_bps_max(cfg: &FeeConfig): u64 { cfg.lending_collateral_bonus_bps_max }
    // maker rebates removed

    /***********************
     * Fee schedule (HL-like)
     ***********************/
    public fun compute_tier_bps_spot(total_weighted_usd_1e6: u128): (u64, u64, u8) {
        let (taker_bps, maker_bps, tier) = if (total_weighted_usd_1e6 > 7_000_000_000u128 * 1_000_000u128) { (25, 0, 6) }
        else if (total_weighted_usd_1e6 > 2_000_000_000u128 * 1_000_000u128) { (30, 0, 5) }
        else if (total_weighted_usd_1e6 > 500_000_000u128 * 1_000_000u128) { (35, 0, 4) }
        else if (total_weighted_usd_1e6 > 100_000_000u128 * 1_000_000u128) { (40, 10, 3) }
        else if (total_weighted_usd_1e6 > 25_000_000u128 * 1_000_000u128) { (50, 20, 2) }
        else if (total_weighted_usd_1e6 > 5_000_000u128 * 1_000_000u128) { (60, 30, 1) }
        else { (70, 40, 0) };
        (taker_bps, maker_bps, tier)
    }

    public fun compute_tier_bps_perps(total_weighted_usd_1e6: u128): (u64, u64, u8) {
        let (taker_bps, maker_bps, tier) = if (total_weighted_usd_1e6 > 7_000_000_000u128 * 1_000_000u128) { (24, 0, 6) }
        else if (total_weighted_usd_1e6 > 2_000_000_000u128 * 1_000_000u128) { (26, 0, 5) }
        else if (total_weighted_usd_1e6 > 500_000_000u128 * 1_000_000u128) { (28, 0, 4) }
        else if (total_weighted_usd_1e6 > 100_000_000u128 * 1_000_000u128) { (30, 4, 3) }
        else if (total_weighted_usd_1e6 > 25_000_000u128 * 1_000_000u128) { (35, 8, 2) }
        else if (total_weighted_usd_1e6 > 5_000_000u128 * 1_000_000u128) { (40, 12, 1) }
        else { (45, 15, 0) };
        (taker_bps, maker_bps, tier)
    }

    /// Staking discount in bps of the fee (not absolute), based on UNXV active stake and admin-set tiers
    public fun staking_discount_bps(pool: &StakingPool, user: address, cfg: &FeeConfig): u64 {
        let amt = staking::active_stake_of(pool, user);
        if (amt > cfg.sd_t6_thr) { cfg.sd_t6_bps }
        else if (amt > cfg.sd_t5_thr) { cfg.sd_t5_bps }
        else if (amt > cfg.sd_t4_thr) { cfg.sd_t4_bps }
        else if (amt > cfg.sd_t3_thr) { cfg.sd_t3_bps }
        else if (amt > cfg.sd_t2_thr) { cfg.sd_t2_bps }
        else if (amt > cfg.sd_t1_thr) { cfg.sd_t1_bps }
        else { 0 }
    }

    /// Final taker/maker bps after applying either UNXV-payment discount OR staking discount
    public fun apply_discounts(taker_bps: u64, maker_bps: u64, pay_with_unxv: bool, pool: &StakingPool, user: address, cfg: &FeeConfig): (u64, u64) {
        let disc_bps = if (pay_with_unxv) { cfg.unxv_discount_bps } else { staking_discount_bps(pool, user, cfg) };
        let taker_eff = ((taker_bps as u128) * ((BPS_DENOM - disc_bps) as u128) / (BPS_DENOM as u128)) as u64;
        let maker_eff = ((maker_bps as u128) * ((BPS_DENOM - disc_bps) as u128) / (BPS_DENOM as u128)) as u64;
        (taker_eff, maker_eff)
    }

    /// DEX-only: apply discounts, then enforce a minimum floor so the most discounted fee is 20 bps.
    public fun apply_discounts_dex(
        taker_bps: u64,
        maker_bps: u64,
        pay_with_unxv: bool,
        pool: &StakingPool,
        user: address,
        cfg: &FeeConfig,
    ): (u64, u64) {
        let (taker_eff, maker_eff) = apply_discounts(taker_bps, maker_bps, pay_with_unxv, pool, user, cfg);
        let taker_floored = if (taker_eff < DEX_MIN_FEE_BPS) { DEX_MIN_FEE_BPS } else { taker_eff };
        let maker_floored = if (maker_eff < DEX_MIN_FEE_BPS) { DEX_MIN_FEE_BPS } else { maker_eff };
        (taker_floored, maker_floored)
    }

    // compute_taker_bps_for_user removed along with volume tracking

    public fun kind_spot(): u8 { KIND_SPOT }
    public fun kind_perps(): u8 { KIND_PERPS }

    /***********************
     * Admin conversion to USDC (generic quote)
     ***********************/
    public fun admin_convert_fee_balance_via_pool<Base, Quote>(
        reg_admin: &AdminRegistry,
        vault: &mut FeeVault,
        amount: u64,
        pool: &mut Pool<Base, Quote>,
        is_base_to_quote: bool,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let key = FeeKey<Base> {};
        assert!(bag::contains(&vault.store, key), E_ZERO_AMOUNT);
        let bal: &mut Balance<Base> = &mut vault.store[key];
        let bal_out = balance::split(bal, amount);
        let coin_base = coin::from_balance(bal_out, ctx);
        let deep_zero = coin::zero<DEEP>(ctx);
        if (is_base_to_quote) {
            let (base_left, quote_out, deep_left) = db_pool::swap_exact_base_for_quote(pool, coin_base, deep_zero, 0, clock, ctx);
            // deposit all outputs back to the vault (consume coins): Base change, Quote proceeds, DEEP change
            deposit_generic<Base>(vault, base_left);
            deposit_generic<Quote>(vault, quote_out);
            deposit_generic<DEEP>(vault, deep_left);
        } else {
            // If fee asset is actually Quote, we need a different key; keep Base path only for simplicity
            abort 1338
        }
    }

    fun deposit_generic<T>(vault: &mut FeeVault, coin_in: Coin<T>) {
        let key = FeeKey<T> {};
        let bal = coin::into_balance(coin_in);
        if (bag::contains(&vault.store, key)) { let b: &mut Balance<T> = &mut vault.store[key]; b.join(bal); } else { vault.store.add(key, bal); };
    }

    /***********************
     * Admin withdrawals
     ***********************/
    /// View: available balance for asset T in FeeVault
    public fun fee_available<T>(vault: &FeeVault): u64 {
        let key = FeeKey<T> {};
        if (bag::contains(&vault.store, key)) { let b: &Balance<T> = &vault.store[key]; balance::value(b) } else { 0 }
    }

    /// Admin: withdraw a specific amount of asset T from FeeVault to a recipient address
    public fun admin_withdraw_generic<T>(
        reg_admin: &AdminRegistry,
        vault: &mut FeeVault,
        amount: u64,
        to: address,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let key = FeeKey<T> {};
        assert!(bag::contains(&vault.store, key), E_ZERO_AMOUNT);
        let b: &mut Balance<T> = &mut vault.store[key];
        let avail = balance::value(b);
        assert!(avail >= amount, E_INSUFFICIENT_FUNDS);
        let part = balance::split(b, amount);
        let c = coin::from_balance(part, ctx);
        transfer::public_transfer(c, to);
        event::emit(FeeWithdrawn { who: ctx.sender(), to, asset: type_name::get<T>(), amount, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: withdraw the full available balance of asset T from FeeVault to a recipient address
    public fun admin_withdraw_generic_all<T>(
        reg_admin: &AdminRegistry,
        vault: &mut FeeVault,
        to: address,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let key = FeeKey<T> {};
        assert!(bag::contains(&vault.store, key), E_ZERO_AMOUNT);
        let b: &mut Balance<T> = &mut vault.store[key];
        let amt = balance::value(b);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let part = balance::split(b, amt);
        let c = coin::from_balance(part, ctx);
        transfer::public_transfer(c, to);
        event::emit(FeeWithdrawn { who: ctx.sender(), to, asset: type_name::get<T>(), amount: amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: convenience to withdraw asset T to FeeConfig.treasury
    public fun admin_withdraw_generic_to_treasury<T>(
        reg_admin: &AdminRegistry,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        amount: u64,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) { admin_withdraw_generic<T>(reg_admin, vault, amount, cfg.treasury, clock, ctx) }

    /// Admin: withdraw UNXV accumulated in burn bucket to a recipient (e.g., treasury)
    public fun admin_withdraw_unxv_burn_to(
        reg_admin: &AdminRegistry,
        vault: &mut FeeVault,
        amount: u64,
        to: address,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let avail = balance::value(&vault.unxv_to_burn);
        assert!(avail >= amount, E_INSUFFICIENT_FUNDS);
        let bal_out = balance::split(&mut vault.unxv_to_burn, amount);
        let c = coin::from_balance(bal_out, ctx);
        transfer::public_transfer(c, to);
        event::emit(FeeWithdrawn { who: ctx.sender(), to, asset: type_name::get<UNXV>(), amount, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: convenience to withdraw UNXV burn bucket to FeeConfig.treasury
    public fun admin_withdraw_unxv_burn_to_treasury(
        reg_admin: &AdminRegistry,
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        amount: u64,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) { admin_withdraw_unxv_burn_to(reg_admin, vault, amount, cfg.treasury, clock, ctx) }

    #[test_only]
    public fun new_fee_config_for_testing(ctx: &mut TxContext): FeeConfig {
        FeeConfig {
            id: object::new(ctx),
            dex_fee_bps: 100,
            dex_taker_fee_bps: 100,
            dex_maker_fee_bps: 0,
            futures_taker_fee_bps: 45,
            futures_maker_fee_bps: 15,
            gasfut_taker_fee_bps: 45,
            gasfut_maker_fee_bps: 15,
            unxv_discount_bps: 3000,
            treasury: ctx.sender(),
            prefer_deep_backend: true,
            dist: FeeDistribution { stakers_share_bps: 4000, treasury_share_bps: 3000, burn_share_bps: 3000 },
            pool_creation_fee_unxv: 0,
            lending_borrow_fee_bps: 0,
            lending_collateral_bonus_bps_max: 500,
            sd_t1_thr: 10, sd_t1_bps: 500,
            sd_t2_thr: 100, sd_t2_bps: 1000,
            sd_t3_thr: 1_000, sd_t3_bps: 1500,
            sd_t4_thr: 10_000, sd_t4_bps: 2000,
            sd_t5_thr: 100_000, sd_t5_bps: 3000,
            sd_t6_thr: 500_000, sd_t6_bps: 4000,
        }
    }

    #[test_only]
    public fun new_fee_vault_for_testing(ctx: &mut TxContext): FeeVault {
        FeeVault { id: object::new(ctx), store: bag::new(ctx), unxv_to_burn: balance::zero<UNXV>() }
    }
    
}