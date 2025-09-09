/// Module: unxversal_lending
/// ------------------------------------------------------------
/// Isolated single-asset lending pool with:
/// - Time-based interest accrual using utilization model
/// - Share-based supplier accounting (supply/ redeem)
/// - Borrow positions per address using interest index
/// - Admin-configurable interest model, reserve factor, collateral factor
/// - UNXV fee integration hooks for weekly staker rewards (optional, via caller)
///
/// Notes:
/// - Each pool is isolated for one asset T
/// - Collateral and borrow are the same asset; health check uses collateral_factor against deposit value
/// - Liquidation allows repaying debt in exchange for seizing supplier shares with a bonus set via admin
module unxversal::lending {
    use sui::{
        balance::{Self as balance, Balance},
        coin::{Self as coin, Coin},
        event,
        table::{Self as table, Table},
        clock::Clock,
    };
    
    use std::string::String;
    // no option alias needed
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees};
    use unxversal::oracle::{Self as uoracle, OracleRegistry};
    use pyth::price_info::PriceInfoObject;
    
    /// Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;
    const E_NO_BORROW: u64 = 4;
    const E_HEALTH_VIOLATION: u64 = 5;
    const E_NO_SHARES: u64 = 6;
    const E_INSUFFICIENT_SHARES: u64 = 7;
    const E_FLASH_UNDERPAY: u64 = 8;
    const E_INSUFFICIENT_RESERVES: u64 = 9;

    /// 1e18 scalar for indices
    const WAD: u128 = 1_000_000_000_000_000_000;
    /// Milliseconds in (approx) one year (365 days)
    const YEAR_MS: u64 = 365 * 24 * 60 * 60 * 1000;

    /// Interest rate model parameters (per year, in basis points)
    public struct InterestRateModel has copy, drop, store {
        base_rate_bps: u64,
        multiplier_bps: u64,
        jump_multiplier_bps: u64,
        kink_util_bps: u64, // 0..10000
    }

    /// Per-borrower position
    public struct BorrowPosition has drop, store {
        principal: u128,        // in asset units
        interest_index_snap: u128, // last snapshot of borrow_index
    }

    /// Two-asset isolated lending market: Collateral asset -> borrow USDU (stablecoin)
    public struct LendingMarket<phantom Collat, phantom Debt> has key, store {
        id: UID,
        /// Oracle symbol for Collat pricing vs USD, e.g. "SUI/USDC" (1e6 scale)
        symbol: String,
        /// Debt-side liquidity and reserves (in USDU)
        debt_liquidity: Balance<Debt>,
        debt_reserves: Balance<Debt>,
        /// Supplier shares for USDU providers
        total_supply_shares: u128,
        supplier_shares: Table<address, u128>,
        /// Collateral vault for pooled Collat and per-user balances
        collateral_vault: Balance<Collat>,
        collateral_of: Table<address, u64>,
        /// Per-account borrow positions in USDU
        borrows: Table<address, BorrowPosition>,
        /// Interest model and index for USDU borrows
        irm: InterestRateModel,
        borrow_index: u128,
        total_borrows_principal: u128,
        last_accrued_ms: u64,
        /// Risk params
        reserve_factor_bps: u64,
        collateral_factor_bps: u64,           // LTV
        liquidation_threshold_bps: u64,       // >= LTV
        liquidation_bonus_bps: u64,
        flash_fee_bps: u64,
    }

    /// Events for dual-asset markets (Collateral → Debt)
    public struct StringClone has copy, drop {}

    /// Events for dual-asset markets (Collateral → USDU debt)
    public struct MarketInitialized2 has copy, drop { market_id: ID, symbol: String, ltv_bps: u64, liq_threshold_bps: u64, reserve_bps: u64, liq_bonus_bps: u64, timestamp_ms: u64 }
    public struct DebtSupplied has copy, drop { market_id: ID, who: address, amount: u64, shares: u128, timestamp_ms: u64 }
    public struct DebtWithdrawn has copy, drop { market_id: ID, who: address, amount: u64, shares: u128, timestamp_ms: u64 }
    public struct CollateralDeposited2 has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct CollateralWithdrawn2 has copy, drop { market_id: ID, who: address, amount: u64, timestamp_ms: u64 }
    public struct DebtBorrowed has copy, drop { market_id: ID, who: address, amount: u64, principal_after: u128, timestamp_ms: u64 }
    public struct DebtRepaid has copy, drop { market_id: ID, who: address, amount: u64, remaining_principal: u128, timestamp_ms: u64 }

    /// Non-storable, non-droppable capability enforcing same-transaction flash repay
    public struct FlashLoanCap<phantom T> { principal: u64, fee: u64 }

    /// Initialize a new dual-asset market: Collat supplied as collateral, borrow USDU
    public fun init_market<Collat, Debt>(
        reg_admin: &AdminRegistry,
        symbol: String,
        base_rate_bps: u64,
        multiplier_bps: u64,
        jump_multiplier_bps: u64,
        kink_util_bps: u64,
        reserve_factor_bps: u64,
        collateral_factor_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_bonus_bps: u64,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(liquidation_threshold_bps >= collateral_factor_bps, E_NOT_ADMIN);
        assert!(kink_util_bps > 0 && kink_util_bps < fees::bps_denom(), E_NOT_ADMIN);
        let irm = InterestRateModel { base_rate_bps, multiplier_bps, jump_multiplier_bps, kink_util_bps };
        let m = LendingMarket<Collat, Debt> {
            id: object::new(ctx),
            symbol,
            debt_liquidity: balance::zero<Debt>(),
            debt_reserves: balance::zero<Debt>(),
            total_supply_shares: 0,
            supplier_shares: table::new<address, u128>(ctx),
            collateral_vault: balance::zero<Collat>(),
            collateral_of: table::new<address, u64>(ctx),
            borrows: table::new<address, BorrowPosition>(ctx),
            irm,
            borrow_index: WAD,
            total_borrows_principal: 0,
            last_accrued_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            reserve_factor_bps,
            collateral_factor_bps,
            liquidation_threshold_bps,
            liquidation_bonus_bps,
            flash_fee_bps: 0,
        };
        event::emit(MarketInitialized2 { market_id: object::id(&m), symbol: clone_string(&m.symbol), ltv_bps: collateral_factor_bps, liq_threshold_bps: liquidation_threshold_bps, reserve_bps: reserve_factor_bps, liq_bonus_bps: liquidation_bonus_bps, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::share_object(m);
    }

    fun clone_string(s: &String): String {
        let bytes = std::string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(bytes);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(bytes, i)); i = i + 1; };
        std::string::utf8(out)
    }

    // legacy single-asset admin utilities removed

    // legacy single-asset flows removed

    /// Deposit with rewards: computes USD internally via oracle and records lend-quality if util>kink.
    

    // NOTE: Rewards for deposits should be computed using on-chain oracle pricing inside this module.
    // Intentionally no "deposit_with_rewards" that accepts caller-provided USD to avoid spoofing.

    

    

    

    // NOTE: Rewards for borrow should be computed on-chain from oracle price within this module.
    // Intentionally no "borrow_with_rewards" that accepts caller-provided USD to avoid spoofing.

    

    

    

    // NOTE: Rewards for repay interest should be computed via oracle; avoid trusting caller-provided USD.

    

    

    // NOTE: Rewards for liquidation should be computed from actual repay notional using oracle in-module.

    

    

    

    

    /// View: compute borrow rate bps given utilization
    fun borrow_rate_bps(util_bps: u64, irm: &InterestRateModel): u64 {
        let kink = if (irm.kink_util_bps == 0) { 1 } else { irm.kink_util_bps };
        if (util_bps <= kink) {
            let inc: u64 = (((irm.multiplier_bps as u128) * (util_bps as u128)) / (kink as u128)) as u64;
            irm.base_rate_bps + inc
        } else {
            let over = util_bps - kink;
            let denom: u64 = fees::bps_denom() - kink;
            let jump_inc: u64 = (((irm.jump_multiplier_bps as u128) * (over as u128)) / (denom as u128)) as u64;
            irm.base_rate_bps + irm.multiplier_bps + jump_inc
        }
    }

    

    

    

    

    

    

    fun current_borrow_balance_inner(cur_index: u128, pos: &BorrowPosition): u128 {
        (pos.principal * cur_index) / WAD
    }

    /// Supplier shares util
    fun get_shares(tbl: &Table<address, u128>, who: address): u128 {
        if (table::contains(tbl, who)) { *table::borrow(tbl, who) } else { 0 }
    }

    fun set_shares(tbl: &mut Table<address, u128>, who: address, v: u128) {
        if (table::contains(tbl, who)) { let _ = table::remove(tbl, who); };
        table::add(tbl, who, v);
    }

    fun add_shares(tbl: &mut Table<address, u128>, who: address, add: u128) {
        let cur = get_shares(tbl, who);
        set_shares(tbl, who, cur + add);
    }

    fun get_borrow_position(tbl: &Table<address, BorrowPosition>, who: address): BorrowPosition {
        if (table::contains(tbl, who)) {
            let p_ref = table::borrow(tbl, who);
            BorrowPosition { principal: p_ref.principal, interest_index_snap: p_ref.interest_index_snap }
        } else { BorrowPosition { principal: 0, interest_index_snap: WAD } }
    }

    fun set_borrow_position(tbl: &mut Table<address, BorrowPosition>, who: address, v: BorrowPosition) {
        if (table::contains(tbl, who)) { let _old = table::remove(tbl, who); };
        table::add(tbl, who, v);
    }
    // ===== Dual-asset admin (market) =====
    public fun set_market_params<Collat, Debt>(
        reg_admin: &AdminRegistry,
        market: &mut LendingMarket<Collat, Debt>,
        reserve_factor_bps: u64,
        collateral_factor_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_bonus_bps: u64,
        ctx: &TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(reserve_factor_bps <= fees::bps_denom(), E_NOT_ADMIN);
        assert!(collateral_factor_bps < fees::bps_denom(), E_HEALTH_VIOLATION);
        assert!(liquidation_threshold_bps >= collateral_factor_bps, E_HEALTH_VIOLATION);
        market.reserve_factor_bps = reserve_factor_bps;
        market.collateral_factor_bps = collateral_factor_bps;
        market.liquidation_threshold_bps = liquidation_threshold_bps;
        market.liquidation_bonus_bps = liquidation_bonus_bps;
    }

    public fun set_interest_model_market<Collat, Debt>(
        reg_admin: &AdminRegistry,
        market: &mut LendingMarket<Collat, Debt>,
        base_rate_bps: u64,
        multiplier_bps: u64,
        jump_multiplier_bps: u64,
        kink_util_bps: u64,
        ctx: &TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(kink_util_bps > 0 && kink_util_bps < fees::bps_denom(), E_NOT_ADMIN);
        market.irm = InterestRateModel { base_rate_bps, multiplier_bps, jump_multiplier_bps, kink_util_bps };
    }

    public fun set_flash_fee_market<Collat, Debt>(reg_admin: &AdminRegistry, market: &mut LendingMarket<Collat, Debt>, flash_fee_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        market.flash_fee_bps = flash_fee_bps;
    }

    public fun sweep_debt_reserves_to_fee_vault<Collat, Debt>(
        reg_admin: &AdminRegistry,
        market: &mut LendingMarket<Collat, Debt>,
        vault: &mut fees::FeeVault,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let avail = balance::value(&market.debt_reserves);
        assert!(avail >= amount, E_INSUFFICIENT_RESERVES);
        let part = balance::split(&mut market.debt_reserves, amount);
        let coin_out = coin::from_balance(part, ctx);
        fees::accrue_generic<Debt>(vault, coin_out, clock, ctx);
    }

    // ===== Accrual & utilization (market) =====
    public fun accrue_market<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, clock: &Clock) {
        let now = sui::clock::timestamp_ms(clock);
        let dt = if (now > market.last_accrued_ms) { now - market.last_accrued_ms } else { 0 };
        if (dt == 0) return;
        let util_bps = utilization_bps_market<Collat, Debt>(market);
        let rate_bps = borrow_rate_bps(util_bps, &market.irm);
        let interest_factor_num: u128 = (rate_bps as u128) * (dt as u128) * (WAD as u128);
        let interest_factor_den: u128 = (fees::bps_denom() as u128) * (YEAR_MS as u128);
        let delta_index: u128 = interest_factor_num / interest_factor_den;
        market.borrow_index = market.borrow_index + delta_index;
        market.last_accrued_ms = now;
    }

    public fun utilization_bps_market<Collat, Debt>(market: &LendingMarket<Collat, Debt>): u64 {
        let borrows = market.total_borrows_principal as u64;
        let cash = balance::value(&market.debt_liquidity);
        if (borrows == 0) return 0;
        let denom = cash + borrows;
        ((borrows as u128) * (fees::bps_denom() as u128) / (denom as u128)) as u64
    }

    // ===== Borrow views (market) =====
    public fun current_borrow_balance_market<Collat, Debt>(market: &LendingMarket<Collat, Debt>, who: address): u64 {
        let pos = get_borrow_position(&market.borrows, who);
        if (pos.principal == 0) return 0;
        current_borrow_balance_inner(market.borrow_index, &pos) as u64
    }

    // ===== Supplier shares (Debt side) =====
    public fun exchange_rate_wad_debt<Collat, Debt>(market: &LendingMarket<Collat, Debt>): u128 {
        let liq = balance::value(&market.debt_liquidity) as u128;
        if (market.total_supply_shares == 0 || liq == 0) return WAD;
        (liq * WAD) / market.total_supply_shares
    }

    fun collat_of_get(tbl: &Table<address, u64>, who: address): u64 { if (table::contains(tbl, who)) { *table::borrow(tbl, who) } else { 0 } }
    fun collat_of_set(tbl: &mut Table<address, u64>, who: address, v: u64) { if (table::contains(tbl, who)) { let _ = table::remove(tbl, who); }; table::add(tbl, who, v); }

    // ===== Debt supplier flows =====
    public fun supply_debt<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, amount: Coin<Debt>, clock: &Clock, ctx: &mut TxContext) {
        accrue_market<Collat, Debt>(market, clock);
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let liq = balance::value(&market.debt_liquidity);
        let shares = if (market.total_supply_shares == 0 || liq == 0) { amt as u128 } else { (amt as u128) * market.total_supply_shares / (liq as u128) };
        market.total_supply_shares = market.total_supply_shares + shares;
        add_shares(&mut market.supplier_shares, ctx.sender(), shares);
        market.debt_liquidity.join(coin::into_balance(amount));
        event::emit(DebtSupplied { market_id: object::id(market), who: ctx.sender(), amount: amt, shares, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun withdraw_debt<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, shares: u128, clock: &Clock, ctx: &mut TxContext): Coin<Debt> {
        accrue_market<Collat, Debt>(market, clock);
        assert!(shares > 0, E_NO_SHARES);
        let user = ctx.sender();
        let user_sh = get_shares(&market.supplier_shares, user);
        assert!(user_sh >= shares, E_INSUFFICIENT_SHARES);
        let liq = balance::value(&market.debt_liquidity);
        let amt: u64 = ((shares as u128) * (liq as u128) / (market.total_supply_shares as u128)) as u64;
        assert!(amt > 0, E_ZERO_AMOUNT);
        assert!(balance::value(&market.debt_liquidity) >= amt, E_INSUFFICIENT_LIQUIDITY);
        set_shares(&mut market.supplier_shares, user, user_sh - shares);
        market.total_supply_shares = market.total_supply_shares - shares;
        let part = balance::split(&mut market.debt_liquidity, amt);
        let out = coin::from_balance(part, ctx);
        event::emit(DebtWithdrawn { market_id: object::id(market), who: user, amount: amt, shares, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
        out
    }

    // ===== Collateral flows =====
    public fun deposit_collateral2<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, c: Coin<Collat>, ctx: &mut TxContext) {
        let amt = coin::value(&c);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let who = ctx.sender();
        let cur = collat_of_get(&market.collateral_of, who);
        market.collateral_vault.join(coin::into_balance(c));
        collat_of_set(&mut market.collateral_of, who, cur + amt);
        event::emit(CollateralDeposited2 { market_id: object::id(market), who, amount: amt, timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public fun withdraw_collateral2<Collat, Debt>(
        market: &mut LendingMarket<Collat, Debt>,
        amount: u64,
        reg: &OracleRegistry,
        price_info_object: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Collat> {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let who = ctx.sender();
        let cur = collat_of_get(&market.collateral_of, who);
        assert!(cur >= amount, E_INSUFFICIENT_LIQUIDITY);
        accrue_market<Collat, Debt>(market, clock);
        let px_1e6 = uoracle::get_price_for_symbol(reg, clock, &market.symbol, price_info_object);
        let new_coll: u64 = cur - amount;
        let coll_usd_after_1e6: u128 = (new_coll as u128) * (px_1e6 as u128);
        let max_debt_after_1e6: u128 = (coll_usd_after_1e6 * (market.collateral_factor_bps as u128)) / (fees::bps_denom() as u128);
        let owed_1e6: u128 = current_borrow_balance_market<Collat, Debt>(market, who) as u128;
        assert!(owed_1e6 <= max_debt_after_1e6, E_HEALTH_VIOLATION);
        collat_of_set(&mut market.collateral_of, who, new_coll);
        let part = balance::split(&mut market.collateral_vault, amount);
        let out = coin::from_balance(part, ctx);
        event::emit(CollateralWithdrawn2 { market_id: object::id(market), who, amount, timestamp_ms: sui::clock::timestamp_ms(clock) });
        out
    }

    // ===== Borrow / Repay =====
    public fun borrow_debt<Collat, Debt>(
        market: &mut LendingMarket<Collat, Debt>,
        amount: u64,
        reg: &OracleRegistry,
        price_info_object: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Debt> {
        accrue_market<Collat, Debt>(market, clock);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(balance::value(&market.debt_liquidity) >= amount, E_INSUFFICIENT_LIQUIDITY);
        let px_1e6 = uoracle::get_price_for_symbol(reg, clock, &market.symbol, price_info_object);
        let coll_units = collat_of_get(&market.collateral_of, ctx.sender());
        let coll_usd_1e6: u128 = (coll_units as u128) * (px_1e6 as u128);
        let max_debt_1e6: u128 = (coll_usd_1e6 * (market.collateral_factor_bps as u128)) / (fees::bps_denom() as u128);
        let cur_owed_1e6: u128 = current_borrow_balance_market<Collat, Debt>(market, ctx.sender()) as u128;
        assert!(cur_owed_1e6 + (amount as u128) <= max_debt_1e6, E_HEALTH_VIOLATION);
        let mut pos = get_borrow_position(&market.borrows, ctx.sender());
        pos.principal = pos.principal + (amount as u128);
        pos.interest_index_snap = market.borrow_index;
        let new_p = pos.principal;
        set_borrow_position(&mut market.borrows, ctx.sender(), pos);
        market.total_borrows_principal = market.total_borrows_principal + (amount as u128);
        let part = balance::split(&mut market.debt_liquidity, amount);
        let out = coin::from_balance(part, ctx);
        event::emit(DebtBorrowed { market_id: object::id(market), who: ctx.sender(), amount, principal_after: new_p, timestamp_ms: sui::clock::timestamp_ms(clock) });
        out
    }

    public fun repay_debt<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, mut pay: Coin<Debt>, borrower: address, clock: &Clock, ctx: &mut TxContext): Coin<Debt> {
        accrue_market<Collat, Debt>(market, clock);
        let amt = coin::value(&pay);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let mut pos = get_borrow_position(&market.borrows, borrower);
        assert!(pos.principal > 0, E_NO_BORROW);
        let owed = current_borrow_balance_inner(market.borrow_index, &pos);
        let pay_amt = if ((amt as u128) >= owed) { owed as u64 } else { amt };
        let interest_remaining: u64 = if (owed > pos.principal) { (owed - pos.principal) as u64 } else { 0 };
        let interest_applied: u64 = if (pay_amt > interest_remaining) { interest_remaining } else { pay_amt };
        let reserve_cut: u64 = ((interest_applied as u128) * (market.reserve_factor_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let mut to_use = coin::split(&mut pay, pay_amt, ctx);
        if (reserve_cut > 0) { let res_coin = coin::split(&mut to_use, reserve_cut, ctx); market.debt_reserves.join(coin::into_balance(res_coin)); };
        market.debt_liquidity.join(coin::into_balance(to_use));
        let leftover = pay;
        let remaining: u128 = owed - (pay_amt as u128);
        pos.principal = (remaining as u128) * WAD / market.borrow_index;
        pos.interest_index_snap = market.borrow_index;
        let new_principal = pos.principal;
        set_borrow_position(&mut market.borrows, borrower, pos);
        let principal_reduction: u128 = if ((pay_amt as u128) > (interest_applied as u128)) { (pay_amt as u128) - (interest_applied as u128) } else { 0 };
        if (market.total_borrows_principal >= principal_reduction) { market.total_borrows_principal = market.total_borrows_principal - principal_reduction; } else { market.total_borrows_principal = 0; };
        event::emit(DebtRepaid { market_id: object::id(market), who: ctx.sender(), amount: pay_amt, remaining_principal: new_principal, timestamp_ms: sui::clock::timestamp_ms(clock) });
        leftover
    }

    // ===== Liquidation =====
    public fun liquidate2<Collat, Debt>(
        market: &mut LendingMarket<Collat, Debt>,
        borrower: address,
        repay_amount: Coin<Debt>,
        reg: &OracleRegistry,
        price_info_object: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<Debt> {
        accrue_market<Collat, Debt>(market, clock);
        let px_1e6 = uoracle::get_price_for_symbol(reg, clock, &market.symbol, price_info_object);
        let coll = collat_of_get(&market.collateral_of, borrower) as u128;
        let coll_usd_1e6: u128 = coll * (px_1e6 as u128);
        let liq_max_debt_1e6: u128 = (coll_usd_1e6 * (market.liquidation_threshold_bps as u128)) / (fees::bps_denom() as u128);
        let owed_1e6: u128 = current_borrow_balance_market<Collat, Debt>(market, borrower) as u128;
        assert!(owed_1e6 > liq_max_debt_1e6, E_HEALTH_VIOLATION);

        let owed_u64: u64 = owed_1e6 as u64;
        let mut repay = repay_amount;
        let to_repay: u64 = if (coin::value(&repay) < owed_u64) { coin::value(&repay) } else { owed_u64 };
        let mut pos = get_borrow_position(&market.borrows, borrower);
        let owed_full = current_borrow_balance_inner(market.borrow_index, &pos) as u64;
        let interest_remaining: u64 = if ((owed_full as u128) > pos.principal) { (owed_full - (pos.principal as u64)) } else { 0 };
        let interest_applied: u64 = if (to_repay > interest_remaining) { interest_remaining } else { to_repay };
        let reserve_cut: u64 = ((interest_applied as u128) * (market.reserve_factor_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let mut to_use = coin::split(&mut repay, to_repay, ctx);
        if (reserve_cut > 0) { let rc = coin::split(&mut to_use, reserve_cut, ctx); market.debt_reserves.join(coin::into_balance(rc)); };
        market.debt_liquidity.join(coin::into_balance(to_use));
        let remaining_u128 = (owed_full as u128) - (to_repay as u128);
        pos.principal = remaining_u128 * WAD / market.borrow_index;
        pos.interest_index_snap = market.borrow_index;
        set_borrow_position(&mut market.borrows, borrower, pos);
        // Seize collateral at liquidation bonus
        let bonus_bps = market.liquidation_bonus_bps;
        let seize_usd_1e6: u128 = (to_repay as u128) + (((to_repay as u128) * (bonus_bps as u128)) / (fees::bps_denom() as u128));
        let mut seize_units: u64 = (seize_usd_1e6 / (px_1e6 as u128)) as u64;
        let borrower_coll = coll as u64;
        if (seize_units > borrower_coll) { seize_units = borrower_coll; };
        if (seize_units > 0) {
            collat_of_set(&mut market.collateral_of, borrower, borrower_coll - seize_units);
            let part = balance::split(&mut market.collateral_vault, seize_units);
            let seized = coin::from_balance(part, ctx);
            transfer::public_transfer(seized, ctx.sender());
        };
        repay
    }

    // ===== Flash loan (Debt) =====
    public fun flash_loan_debt<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, amount: u64, clock: &Clock, ctx: &mut TxContext): (Coin<Debt>, FlashLoanCap<Debt>) {
        accrue_market<Collat, Debt>(market, clock);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(balance::value(&market.debt_liquidity) >= amount, E_INSUFFICIENT_LIQUIDITY);
        let fee: u64 = ((amount as u128) * (market.flash_fee_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let part = balance::split(&mut market.debt_liquidity, amount);
        let loan = coin::from_balance(part, ctx);
        (loan, FlashLoanCap<Debt> { principal: amount, fee })
    }

    public fun flash_repay_debt<Collat, Debt>(market: &mut LendingMarket<Collat, Debt>, mut repay: Coin<Debt>, cap: FlashLoanCap<Debt>, _clock: &Clock, ctx: &mut TxContext): Coin<Debt> {
        let FlashLoanCap { principal, fee } = cap;
        let due: u64 = principal + fee;
        let have = coin::value(&repay);
        assert!(have >= due, E_FLASH_UNDERPAY);
        let mut to_use = coin::split(&mut repay, due, ctx);
        if (fee > 0) { let fee_coin = coin::split(&mut to_use, fee, ctx); market.debt_reserves.join(coin::into_balance(fee_coin)); };
        market.debt_liquidity.join(coin::into_balance(to_use));
        repay
    }

    // ===== Views =====
    public fun max_borrowable_debt<Collat, Debt>(market: &LendingMarket<Collat, Debt>, who: address, reg: &OracleRegistry, price_info_object: &PriceInfoObject, clock: &Clock): u64 {
        let px_1e6 = uoracle::get_price_for_symbol(reg, clock, &market.symbol, price_info_object);
        let coll = collat_of_get(&market.collateral_of, who) as u128;
        let coll_usd_1e6: u128 = coll * (px_1e6 as u128);
        let cap_1e6: u128 = (coll_usd_1e6 * (market.collateral_factor_bps as u128)) / (fees::bps_denom() as u128);
        let owed_1e6: u128 = current_borrow_balance_market<Collat, Debt>(market, who) as u128;
        if (cap_1e6 <= owed_1e6) { 0 } else { (cap_1e6 - owed_1e6) as u64 }
    }

    public fun is_healthy_market<Collat, Debt>(market: &LendingMarket<Collat, Debt>, who: address, reg: &OracleRegistry, price_info_object: &PriceInfoObject, clock: &Clock): bool {
        let px_1e6 = uoracle::get_price_for_symbol(reg, clock, &market.symbol, price_info_object);
        let coll = collat_of_get(&market.collateral_of, who) as u128;
        let coll_usd_1e6: u128 = coll * (px_1e6 as u128);
        let max_1e6: u128 = (coll_usd_1e6 * (market.collateral_factor_bps as u128)) / (fees::bps_denom() as u128);
        let owed_1e6: u128 = current_borrow_balance_market<Collat, Debt>(market, who) as u128;
        max_1e6 >= owed_1e6
    }
}


