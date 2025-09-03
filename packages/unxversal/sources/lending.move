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
    use std::option::{Self as option, Option};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees};

    /// Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;
    const E_NO_BORROW: u64 = 4;
    const E_HEALTH_VIOLATION: u64 = 5;
    const E_OVERREPAY: u64 = 6;
    const E_NO_SHARES: u64 = 7;
    const E_INSUFFICIENT_SHARES: u64 = 8;

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
    public struct BorrowPosition has store {
        principal: u128,        // in asset units
        interest_index_snap: u128, // last snapshot of borrow_index
    }

    /// Main pool object per asset
    public struct LendingPool<phantom T> has key, store {
        id: UID,
        liquidity: Balance<T>,
        /// Total borrowed principal across borrowers (no interest)
        total_borrows_principal: u128,
        /// Accumulator index for borrow interest, scaled by WAD
        borrow_index: u128,
        /// Reserve factor portion of interest retained by pool (bps)
        reserve_factor_bps: u64,
        /// Collateral factor (bps) applied to depositor value for borrow limits
        collateral_factor_bps: u64,
        /// Liquidation bonus (bps) given to liquidator on seized shares
        liquidation_bonus_bps: u64,
        /// Interest model
        irm: InterestRateModel,
        /// Timestamp ms last accrual
        last_accrued_ms: u64,
        /// Total supplier shares
        total_supply_shares: u128,
        /// Per-account supplier shares
        supplier_shares: Table<address, u128>,
        /// Per-account borrow positions
        borrows: Table<address, BorrowPosition>,
        /// Reserves held by the pool (accrued portion of interest)
        reserves: Balance<T>,
    }

    /// Events
    public struct PoolInitialized has copy, drop { asset: vector<u8>, timestamp_ms: u64 }
    public struct Deposit has copy, drop { who: address, amount: u64, shares: u128, timestamp_ms: u64 }
    public struct Withdraw has copy, drop { who: address, amount: u64, shares: u128, timestamp_ms: u64 }
    public struct Borrow has copy, drop { who: address, amount: u64, new_principal: u128, timestamp_ms: u64 }
    public struct Repay has copy, drop { who: address, amount: u64, remaining_principal: u128, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { borrower: address, liquidator: address, repay_amount: u64, shares_seized: u128, bonus_bps: u64, timestamp_ms: u64 }
    public struct Accrued has copy, drop { interest_index: u128, dt_ms: u64, new_reserves: u64, timestamp_ms: u64 }
    public struct ParamsUpdated has copy, drop { reserve_bps: u64, collat_bps: u64, liq_bonus_bps: u64, timestamp_ms: u64 }

    /// Initialize a new lending pool for asset T
    entry fun init_pool<T>(reg_admin: &AdminRegistry, irm: InterestRateModel, reserve_factor_bps: u64, collateral_factor_bps: u64, liquidation_bonus_bps: u64, ctx: &mut TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let pool = LendingPool<T> {
            id: object::new(ctx),
            liquidity: balance::zero<T>(),
            total_borrows_principal: 0,
            borrow_index: WAD,
            reserve_factor_bps,
            collateral_factor_bps,
            liquidation_bonus_bps,
            irm,
            last_accrued_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            total_supply_shares: 0,
            supplier_shares: table::new<address, u128>(ctx),
            borrows: table::new<address, BorrowPosition>(ctx),
            reserves: balance::zero<T>(),
        };
        transfer::share_object(pool);
        event::emit(PoolInitialized { asset: b"T", timestamp_ms: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Admin: update general parameters
    entry fun set_params<T>(reg_admin: &AdminRegistry, pool: &mut LendingPool<T>, reserve_factor_bps: u64, collateral_factor_bps: u64, liquidation_bonus_bps: u64, clock: &Clock) {
        assert!(AdminMod::is_admin(reg_admin, sui::tx_context::sender()), E_NOT_ADMIN);
        pool.reserve_factor_bps = reserve_factor_bps;
        pool.collateral_factor_bps = collateral_factor_bps;
        pool.liquidation_bonus_bps = liquidation_bonus_bps;
        event::emit(ParamsUpdated { reserve_bps: reserve_factor_bps, collat_bps: collateral_factor_bps, liq_bonus_bps: liquidation_bonus_bps, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: update interest rate model
    entry fun set_interest_model<T>(reg_admin: &AdminRegistry, pool: &mut LendingPool<T>, irm: InterestRateModel) {
        assert!(AdminMod::is_admin(reg_admin, sui::tx_context::sender()), E_NOT_ADMIN);
        pool.irm = irm;
    }

    /// Public: deposit liquidity and receive shares (acts as collateral)
    entry fun deposit<T>(pool: &mut LendingPool<T>, amount: Coin<T>, clock: &Clock, ctx: &mut TxContext) {
        accrue<T>(pool, clock);
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        // shares = amount * total_shares / liquidity_amount; if first, 1:1
        let supply_liq = balance::value(&pool.liquidity);
        let shares = if (pool.total_supply_shares == 0 || supply_liq == 0) { amt as u128 } else { (amt as u128) * pool.total_supply_shares / (supply_liq as u128) };
        // update state
        pool.total_supply_shares = pool.total_supply_shares + shares;
        add_shares(&mut pool.supplier_shares, ctx.sender(), shares);
        // move funds
        let bal = coin::into_balance(amount);
        pool.liquidity.join(bal);
        event::emit(Deposit { who: ctx.sender(), amount: amt, shares, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Public: withdraw liquidity by specifying share amount
    entry fun withdraw<T>(pool: &mut LendingPool<T>, shares: u128, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        accrue<T>(pool, clock);
        assert!(shares > 0, E_NO_SHARES);
        // check user's shares
        let user_shares = get_shares(&pool.supplier_shares, ctx.sender());
        assert!(user_shares >= shares, E_INSUFFICIENT_SHARES);
        // compute amount = shares / total_shares * liquidity
        let liq = balance::value(&pool.liquidity);
        let amt: u64 = ((shares as u128) * (liq as u128) / (pool.total_supply_shares as u128)) as u64;
        assert!(amt > 0, E_ZERO_AMOUNT);
        // update shares and supply
        set_shares(&mut pool.supplier_shares, ctx.sender(), user_shares - shares);
        pool.total_supply_shares = pool.total_supply_shares - shares;
        // ensure liquidity availability (cannot withdraw reserves)
        assert!(balance::value(&pool.liquidity) >= amt, E_INSUFFICIENT_LIQUIDITY);
        let c = balance::into_coin(&mut pool.liquidity, amt, ctx);
        event::emit(Withdraw { who: ctx.sender(), amount: amt, shares, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Public: borrow asset from pool (uses caller's deposit as collateral)
    entry fun borrow<T>(pool: &mut LendingPool<T>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        accrue<T>(pool, clock);
        assert!(amount > 0, E_ZERO_AMOUNT);
        // check liquidity
        assert!(balance::value(&pool.liquidity) >= amount, E_INSUFFICIENT_LIQUIDITY);
        // health check based on collateral factor
        let max_borrow = max_borrowable_for<T>(pool, ctx.sender());
        assert!((current_borrow_balance<T>(pool, ctx.sender()) as u128) + (amount as u128) <= max_borrow as u128, E_HEALTH_VIOLATION);
        // update borrow position
        let mut pos = get_borrow_position(&pool.borrows, ctx.sender());
        pos.principal = pos.principal + (amount as u128);
        pos.interest_index_snap = pool.borrow_index;
        set_borrow_position(&mut pool.borrows, ctx.sender(), pos);
        pool.total_borrows_principal = pool.total_borrows_principal + (amount as u128);
        // transfer funds
        let c = balance::into_coin(&mut pool.liquidity, amount, ctx);
        event::emit(Borrow { who: ctx.sender(), amount, new_principal: pos.principal, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Public: repay debt (anyone can repay on behalf of borrower)
    entry fun repay<T>(pool: &mut LendingPool<T>, mut pay: Coin<T>, borrower: address, clock: &Clock, ctx: &mut TxContext) {
        accrue<T>(pool, clock);
        let amt = coin::value(&pay);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let mut pos = get_borrow_position(&pool.borrows, borrower);
        assert!(pos.principal > 0, E_NO_BORROW);
        let owed = current_borrow_balance_inner(pool.borrow_index, &pos);
        let pay_amt = if ((amt as u128) >= owed) { owed as u64 } else { amt };
        // Determine interest portion and reserve cut
        let interest_remaining: u64 = if ((owed as u128) > pos.principal) { (owed - pos.principal) as u64 } else { 0 };
        let interest_applied: u64 = if (pay_amt > interest_remaining) { interest_remaining } else { pay_amt };
        let reserve_cut: u64 = ((interest_applied as u128) * (pool.reserve_factor_bps as u128) / (fees::BPS_DENOM as u128)) as u64;
        // Split for reserve and liquidity
        let reserve_coin = coin::split(&mut pay, reserve_cut);
        let reserve_bal = coin::into_balance(reserve_coin);
        pool.reserves.join(reserve_bal);
        let _unused = coin::split(&mut pay, pay_amt - reserve_cut);
        let bal = coin::into_balance(pay);
        pool.liquidity.join(bal);
        // reduce principal and update snapshot
        let mut remaining: u128 = owed - (pay_amt as u128);
        // convert remaining to new principal using current index
        pos.principal = (remaining as u128) * WAD / pool.borrow_index;
        pos.interest_index_snap = pool.borrow_index;
        set_borrow_position(&mut pool.borrows, borrower, pos);
        // update totals
        let principal_reduction: u128 = if ((pay_amt as u128) > (interest_applied as u128)) { (pay_amt as u128) - (interest_applied as u128) } else { 0 };
        if (pool.total_borrows_principal >= principal_reduction) { pool.total_borrows_principal = pool.total_borrows_principal - principal_reduction; } else { pool.total_borrows_principal = 0; };
        event::emit(Repay { who: ctx.sender(), amount: pay_amt, remaining_principal: pos.principal, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Keeper: liquidate an undercollateralized borrower by repaying up to `repay_amount` and seizing shares with a bonus
    entry fun liquidate<T>(pool: &mut LendingPool<T>, borrower: address, repay_amount: Coin<T>, clock: &Clock, ctx: &mut TxContext): (Option<Coin<T>>, u128) {
        accrue<T>(pool, clock);
        let health_ok = is_healthy_for<T>(pool, borrower);
        assert!(!health_ok, E_HEALTH_VIOLATION);
        let mut pos = get_borrow_position(&pool.borrows, borrower);
        let owed = current_borrow_balance_inner(pool.borrow_index, &pos) as u64;
        let to_repay = if (coin::value(&repay_amount) < owed) { coin::value(&repay_amount) } else { owed };
        // Take repayment and split reserves
        let mut repay = repay_amount;
        let pay_part = coin::split(&mut repay, to_repay);
        let interest_remaining: u64 = if ((owed as u128) > pos.principal) { (owed - pos.principal) as u64 } else { 0 };
        let interest_applied: u64 = if (to_repay > interest_remaining) { interest_remaining } else { to_repay };
        let reserve_cut: u64 = ((interest_applied as u128) * (pool.reserve_factor_bps as u128) / (fees::BPS_DENOM as u128)) as u64;
        let reserve_coin = coin::split(&mut (pay_part), reserve_cut);
        let reserve_bal = coin::into_balance(reserve_coin);
        pool.reserves.join(reserve_bal);
        let bal = coin::into_balance(pay_part);
        pool.liquidity.join(bal);
        // new debt
        let remaining_u128 = (owed as u128) - (to_repay as u128);
        pos.principal = remaining_u128 * WAD / pool.borrow_index;
        pos.interest_index_snap = pool.borrow_index;
        set_borrow_position(&mut pool.borrows, borrower, pos);
        // seize shares (including liquidation bonus)
        let seize_value = (to_repay as u128) * (pool.total_supply_shares as u128) / (balance::value(&pool.liquidity) as u128);
        let bonus = (seize_value * (pool.liquidation_bonus_bps as u128)) / (fees::BPS_DENOM as u128);
        let seize_shares = seize_value + bonus;
        // move shares from borrower to liquidator up to borrower's shares
        let borrower_sh = get_shares(&pool.supplier_shares, borrower);
        let actual_seize = if (borrower_sh >= seize_shares) { seize_shares } else { borrower_sh };
        set_shares(&mut pool.supplier_shares, borrower, borrower_sh - actual_seize);
        add_shares(&mut pool.supplier_shares, ctx.sender(), actual_seize);
        event::emit(Liquidated { borrower, liquidator: ctx.sender(), repay_amount: to_repay, shares_seized: actual_seize, bonus_bps: pool.liquidation_bonus_bps, timestamp_ms: sui::clock::timestamp_ms(clock) });
        // return leftover of repay coin if any
        let leftover = if (coin::value(&repay) > 0) { option::some(repay) } else { option::none<Coin<T>>() };
        (leftover, actual_seize)
    }

    /// Accrue interest based on elapsed time and utilization. Updates borrow_index and moves reserve share.
    public fun accrue<T>(pool: &mut LendingPool<T>, clock: &Clock) {
        let now = sui::clock::timestamp_ms(clock);
        let dt = if (now > pool.last_accrued_ms) { now - pool.last_accrued_ms } else { 0 };
        if (dt == 0) return;
        let util_bps = utilization_bps<T>(pool);
        // compute borrow rate per year in bps using kinked model
        let rate_bps = borrow_rate_bps(util_bps, &pool.irm);
        // simple interest: interest_factor = rate_bps * dt / YEAR_MS
        let interest_factor_num: u128 = (rate_bps as u128) * (dt as u128) * (WAD as u128);
        let interest_factor_den: u128 = (fees::BPS_DENOM as u128) * (YEAR_MS as u128);
        let delta_index: u128 = interest_factor_num / interest_factor_den; // WAD-scaled delta
        let new_index: u128 = pool.borrow_index + delta_index;
        if (pool.total_borrows_principal > 0 && delta_index > 0) {
            // interest accrued in asset units = total_borrows * delta_index / WAD
            let interest_asset: u128 = (pool.total_borrows_principal * delta_index) / WAD;
            if (interest_asset > 0) {
                // split to reserves and liquidity growth (the portion not reserved increases total borrows notionally but funds sit in pool)
                let to_reserve: u64 = ((interest_asset as u128) * (pool.reserve_factor_bps as u128) / (fees::BPS_DENOM as u128)) as u64;
                let to_pool: u64 = (interest_asset as u64) - to_reserve;
                // credit interest to liquidity vault (simulates interest paid into pool)
                let mut tmp = balance::zero<T>();
                tmp = balance::supply<T>(to_pool);
                pool.liquidity.join(tmp);
                // credit reserves
                let mut rv = balance::zero<T>();
                rv = balance::supply<T>(to_reserve);
                pool.reserves.join(rv);
                event::emit(Accrued { interest_index: new_index, dt_ms: dt, new_reserves: to_reserve, timestamp_ms: now });
            };
        };
        pool.borrow_index = new_index;
        pool.last_accrued_ms = now;
    }

    /// View: current utilization in bps
    public fun utilization_bps<T>(pool: &LendingPool<T>): u64 {
        let borrows = pool.total_borrows_principal as u64;
        let cash = balance::value(&pool.liquidity);
        if (borrows == 0) return 0;
        let denom = cash + borrows;
        ((borrows as u128) * (fees::BPS_DENOM as u128) / (denom as u128)) as u64
    }

    /// View: compute borrow rate bps given utilization
    fun borrow_rate_bps(util_bps: u64, irm: &InterestRateModel): u64 {
        if (util_bps <= irm.kink_util_bps) {
            irm.base_rate_bps + ((irm.multiplier_bps as u128) * (util_bps as u128) / (irm.kink_util_bps as u128)) as u64
        } else {
            let over = util_bps - irm.kink_util_bps;
            irm.base_rate_bps + irm.multiplier_bps + ((irm.jump_multiplier_bps as u128) * (over as u128) / ((fees::BPS_DENOM - irm.kink_util_bps) as u128)) as u64
        }
    }

    /// View: compute user's maximum borrowable amount (in asset units) based on collateral factor and current shares
    public fun max_borrowable_for<T>(pool: &LendingPool<T>, who: address): u64 {
        let shares = get_shares(&pool.supplier_shares, who);
        if (pool.total_supply_shares == 0 || shares == 0) return 0;
        let liq = balance::value(&pool.liquidity) as u128;
        let val: u128 = liq * (shares as u128) / (pool.total_supply_shares as u128);
        ((val * (pool.collateral_factor_bps as u128) / (fees::BPS_DENOM as u128)) as u64)
    }

    /// View: true if borrower meets collateral requirement
    public fun is_healthy_for<T>(pool: &LendingPool<T>, who: address): bool {
        let maxb = max_borrowable_for<T>(pool, who) as u128;
        let owed = current_borrow_balance<T>(pool, who) as u128;
        maxb >= owed
    }

    /// View: current borrow balance including interest
    public fun current_borrow_balance<T>(pool: &LendingPool<T>, who: address): u64 {
        let pos = get_borrow_position(&pool.borrows, who);
        if (pos.principal == 0) return 0;
        let val = current_borrow_balance_inner(pool.borrow_index, &pos);
        val as u64
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
        if (table::contains(tbl, who)) { *table::borrow(tbl, who) } else { BorrowPosition { principal: 0, interest_index_snap: WAD } }
    }

    fun set_borrow_position(tbl: &mut Table<address, BorrowPosition>, who: address, v: BorrowPosition) {
        if (table::contains(tbl, who)) { let _ = table::remove(tbl, who); };
        table::add(tbl, who, v);
    }
}


