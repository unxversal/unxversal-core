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
    
    use std::type_name::{Self as type_name};
    use std::string::String;
    // no option alias needed
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees};
    use unxversal::staking::StakingPool;
    use unxversal::rewards as rewards;
    use unxversal::oracle::{Self as uoracle, OracleRegistry};
    use switchboard::aggregator::Aggregator;
    
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
        /// Liquidation threshold (bps). Must be greater than or equal to collateral_factor_bps.
        liquidation_collateral_bps: u64,
        /// Liquidation bonus (bps) given to liquidator on seized shares
        liquidation_bonus_bps: u64,
        /// Flash loan fee in basis points (applied to principal, immediate repayment required)
        flash_fee_bps: u64,
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
    public struct PoolInitialized has copy, drop { asset: type_name::TypeName, timestamp_ms: u64 }
    public struct Deposit has copy, drop { who: address, amount: u64, shares: u128, timestamp_ms: u64 }
    public struct Withdraw has copy, drop { who: address, amount: u64, shares: u128, timestamp_ms: u64 }
    public struct Borrow has copy, drop { who: address, amount: u64, new_principal: u128, timestamp_ms: u64 }
    public struct Repay has copy, drop { who: address, amount: u64, remaining_principal: u128, timestamp_ms: u64 }
    public struct Liquidated has copy, drop { borrower: address, liquidator: address, repay_amount: u64, shares_seized: u128, bonus_bps: u64, timestamp_ms: u64 }
    public struct Accrued has copy, drop { interest_index: u128, dt_ms: u64, new_reserves: u64, timestamp_ms: u64 }
    public struct ParamsUpdated has copy, drop { reserve_bps: u64, collat_bps: u64, liq_bonus_bps: u64, timestamp_ms: u64 }
    public struct FlashFeeUpdated has copy, drop { flash_fee_bps: u64, timestamp_ms: u64 }
    public struct FlashLoan has copy, drop { who: address, amount: u64, fee: u64, timestamp_ms: u64 }
    public struct FlashRepaid has copy, drop { who: address, principal: u64, fee: u64, timestamp_ms: u64 }
    public struct ReservesSwept has copy, drop { asset: type_name::TypeName, amount: u64, vault_id: ID, timestamp_ms: u64 }
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

    /// Admin: update general parameters
    public fun set_params<T>(reg_admin: &AdminRegistry, pool: &mut LendingPool<T>, reserve_factor_bps: u64, collateral_factor_bps: u64, liquidation_bonus_bps: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(reserve_factor_bps <= fees::bps_denom(), E_NOT_ADMIN);
        // Liquidation threshold must remain >= LTV (collateral factor)
        assert!(collateral_factor_bps <= pool.liquidation_collateral_bps, E_HEALTH_VIOLATION);
        assert!(collateral_factor_bps < fees::bps_denom(), E_HEALTH_VIOLATION);
        pool.reserve_factor_bps = reserve_factor_bps;
        pool.collateral_factor_bps = collateral_factor_bps;
        pool.liquidation_bonus_bps = liquidation_bonus_bps;
        event::emit(ParamsUpdated { reserve_bps: reserve_factor_bps, collat_bps: collateral_factor_bps, liq_bonus_bps: liquidation_bonus_bps, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: update interest rate model
    public fun set_interest_model<T>(
        reg_admin: &AdminRegistry,
        pool: &mut LendingPool<T>,
        base_rate_bps: u64,
        multiplier_bps: u64,
        jump_multiplier_bps: u64,
        kink_util_bps: u64,
        ctx: &TxContext
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(kink_util_bps > 0 && kink_util_bps < fees::bps_denom(), E_NOT_ADMIN);
        pool.irm = InterestRateModel { base_rate_bps, multiplier_bps, jump_multiplier_bps, kink_util_bps };
    }

    /// Admin: raise or lower liquidation threshold; must stay >= collateral_factor_bps
    public fun set_liquidation_threshold<T>(reg_admin: &AdminRegistry, pool: &mut LendingPool<T>, new_liq_threshold_bps: u64, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(new_liq_threshold_bps >= pool.collateral_factor_bps, E_HEALTH_VIOLATION);
        assert!(new_liq_threshold_bps < fees::bps_denom(), E_HEALTH_VIOLATION);
        pool.liquidation_collateral_bps = new_liq_threshold_bps;
    }

    /// Admin: set flash loan fee (bps)
    public fun set_flash_fee<T>(reg_admin: &AdminRegistry, pool: &mut LendingPool<T>, flash_fee_bps: u64, clock: &Clock, ctx: &TxContext) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        pool.flash_fee_bps = flash_fee_bps;
        event::emit(FlashFeeUpdated { flash_fee_bps, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Admin: sweep a portion of accrued reserves into the global FeeVault.
    /// Reserves are held as Balance<T> inside the pool and are not supplier funds.
    /// This moves `amount` from pool.reserves to `fees::FeeVault` as Coin<T>.
    public fun sweep_reserves_to_fee_vault<T>(
        reg_admin: &AdminRegistry,
        pool: &mut LendingPool<T>,
        vault: &mut fees::FeeVault,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let avail = balance::value(&pool.reserves);
        assert!(avail >= amount, E_INSUFFICIENT_RESERVES);
        let part = balance::split(&mut pool.reserves, amount);
        let coin_out = coin::from_balance(part, ctx);
        fees::accrue_generic<T>(vault, coin_out, clock, ctx);
        event::emit(ReservesSwept { asset: type_name::get<T>(), amount, vault_id: object::id(vault), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Public: deposit liquidity and receive shares (acts as collateral)
    public fun deposit<T>(pool: &mut LendingPool<T>, amount: Coin<T>, clock: &Clock, ctx: &mut TxContext) {
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

    /// Deposit with rewards: computes USD internally via oracle and records lend-quality if util>kink.
    public fun deposit_with_rewards<T>(pool: &mut LendingPool<T>, amount: Coin<T>, symbol: String, reg: &unxversal::oracle::OracleRegistry, agg: &switchboard::aggregator::Aggregator, rewards_obj: &mut rewards::Rewards, clock: &Clock, ctx: &mut TxContext) {
        let util_before = utilization_bps<T>(pool);
        // read price in USD 1e6
        let px_1e6 = unxversal::oracle::get_price_for_symbol(reg, clock, &symbol, agg);
        let amt_units = coin::value(&amount);
        let usd_1e6: u128 = (amt_units as u128) * (px_1e6 as u128);
        if (util_before > pool.irm.kink_util_bps && usd_1e6 > 0u128) {
            rewards::on_supply_event(rewards_obj, ctx.sender(), usd_1e6, util_before, pool.irm.kink_util_bps, clock);
        };
        deposit<T>(pool, amount, clock, ctx);
    }

    // NOTE: Rewards for deposits should be computed using on-chain oracle pricing inside this module.
    // Intentionally no "deposit_with_rewards" that accepts caller-provided USD to avoid spoofing.

    /// Public: withdraw liquidity by specifying share amount
    public fun withdraw<T>(pool: &mut LendingPool<T>, shares: u128, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        accrue<T>(pool, clock);
        assert!(shares > 0, E_NO_SHARES);
        let user = ctx.sender();
        // check user's shares
        let user_shares = get_shares(&pool.supplier_shares, user);
        assert!(user_shares >= shares, E_INSUFFICIENT_SHARES);
        // compute amount = shares / total_shares * liquidity
        let liq = balance::value(&pool.liquidity);
        let amt: u64 = ((shares as u128) * (liq as u128) / (pool.total_supply_shares as u128)) as u64;
        assert!(amt > 0, E_ZERO_AMOUNT);
        // Health check simulation after withdrawal
        if (current_borrow_balance<T>(pool, user) > 0) {
            let new_user_shares = user_shares - shares;
            let new_total_shares = pool.total_supply_shares - shares;
            let new_val: u64 = if (new_total_shares == 0) { 0 } else { (((balance::value(&pool.liquidity) as u128) * (new_user_shares as u128) / (new_total_shares as u128)) as u64) };
            let maxb: u64 = (((new_val as u128) * (pool.collateral_factor_bps as u128) / (fees::bps_denom() as u128)) as u64);
            assert!((current_borrow_balance<T>(pool, user) as u128) <= (maxb as u128), E_HEALTH_VIOLATION);
        };
        // update shares and supply
        set_shares(&mut pool.supplier_shares, user, user_shares - shares);
        pool.total_supply_shares = pool.total_supply_shares - shares;
        // ensure liquidity availability (cannot withdraw reserves)
        assert!(balance::value(&pool.liquidity) >= amt, E_INSUFFICIENT_LIQUIDITY);
        let bal_part = balance::split(&mut pool.liquidity, amt);
        let c = coin::from_balance(bal_part, ctx);
        event::emit(Withdraw { who: user, amount: amt, shares, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Public: borrow asset from pool (uses caller's deposit as collateral)
    public fun borrow<T>(pool: &mut LendingPool<T>, amount: u64, clock: &Clock, ctx: &mut TxContext): Coin<T> {
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
        let new_principal = pos.principal;
        set_borrow_position(&mut pool.borrows, ctx.sender(), pos);
        pool.total_borrows_principal = pool.total_borrows_principal + (amount as u128);
        // transfer funds
        let bal_part = balance::split(&mut pool.liquidity, amount);
        let c = coin::from_balance(bal_part, ctx);
        event::emit(Borrow { who: ctx.sender(), amount, new_principal, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Borrow with rewards: computes USD via oracle at borrow time and records borrow usage proxy.
    public fun borrow_with_rewards<T>(pool: &mut LendingPool<T>, amount: u64, symbol: String, reg: &unxversal::oracle::OracleRegistry, agg: &switchboard::aggregator::Aggregator, rewards_obj: &mut rewards::Rewards, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        let util = utilization_bps<T>(pool);
        let px_1e6 = unxversal::oracle::get_price_for_symbol(reg, clock, &symbol, agg);
        let usd_1e6: u128 = (amount as u128) * (px_1e6 as u128);
        if (usd_1e6 > 0u128) { rewards::on_borrow(rewards_obj, ctx.sender(), usd_1e6, util, 0u128, clock); };
        borrow<T>(pool, amount, clock, ctx)
    }

    // NOTE: Rewards for borrow should be computed on-chain from oracle price within this module.
    // Intentionally no "borrow_with_rewards" that accepts caller-provided USD to avoid spoofing.

    /// Borrow with one-time fee and staking-tier collateral bonus
    public fun borrow_with_fee<T>(
        pool: &mut LendingPool<T>,
        amount: u64,
        staking_pool: &StakingPool,
        cfg: &fees::FeeConfig,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        accrue<T>(pool, clock);
        assert!(amount > 0, E_ZERO_AMOUNT);
        // effective collateral factor with staking bonus, but never below liquidation CR
        let eff_cf = effective_collateral_factor_bps(pool.collateral_factor_bps, pool.liquidation_collateral_bps, staking_pool, ctx.sender(), cfg);
        // health check with effective CF
        let max_borrow = max_borrowable_with_cf<T>(pool, ctx.sender(), eff_cf);
        assert!((current_borrow_balance<T>(pool, ctx.sender()) as u128) + (amount as u128) <= max_borrow as u128, E_HEALTH_VIOLATION);
        // apply origination fee
        let fee_bps = fees::lending_borrow_fee_bps(cfg);
        let fee_amt: u64 = ((amount as u128) * (fee_bps as u128) / (fees::bps_denom() as u128)) as u64;
        assert!(balance::value(&pool.liquidity) >= amount, E_INSUFFICIENT_LIQUIDITY);
        // Split amount from liquidity
        let part_bal = balance::split(&mut pool.liquidity, amount);
        let mut c = coin::from_balance(part_bal, ctx);
        if (fee_amt > 0) {
            let fee_coin = coin::split(&mut c, fee_amt, ctx);
            // For simplicity, accrue to reserves (or we could send to fees vault via an adapter)
            pool.reserves.join(coin::into_balance(fee_coin));
        };
        // record principal
        let mut pos = get_borrow_position(&pool.borrows, ctx.sender());
        pos.principal = pos.principal + (amount as u128);
        pos.interest_index_snap = pool.borrow_index;
        set_borrow_position(&mut pool.borrows, ctx.sender(), pos);
        pool.total_borrows_principal = pool.total_borrows_principal + (amount as u128);
        c
    }

    /// Public: repay debt (anyone can repay on behalf of borrower)
    public fun repay<T>(pool: &mut LendingPool<T>, mut pay: Coin<T>, borrower: address, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        accrue<T>(pool, clock);
        let amt = coin::value(&pay);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let mut pos = get_borrow_position(&pool.borrows, borrower);
        assert!(pos.principal > 0, E_NO_BORROW);
        let owed = current_borrow_balance_inner(pool.borrow_index, &pos);
        let pay_amt = if ((amt as u128) >= owed) { owed as u64 } else { amt };
        // Determine interest portion and reserve cut
        let interest_remaining: u64 = if (owed > pos.principal) { (owed - pos.principal) as u64 } else { 0 };
        let interest_applied: u64 = if (pay_amt > interest_remaining) { interest_remaining } else { pay_amt };
        let reserve_cut: u64 = ((interest_applied as u128) * (pool.reserve_factor_bps as u128) / (fees::bps_denom() as u128)) as u64;
        // Split desired payment out of pay
        let mut to_use = coin::split(&mut pay, pay_amt, ctx);
        // Split reserve from to_use
        let reserve_coin = coin::split(&mut to_use, reserve_cut, ctx);
        pool.reserves.join(coin::into_balance(reserve_coin));
        // Remainder of to_use to liquidity
        pool.liquidity.join(coin::into_balance(to_use));
        // Return leftover coin (consume 'pay')
        let leftover = pay;
        // reduce principal and update snapshot
        let remaining: u128 = owed - (pay_amt as u128);
        // convert remaining to new principal using current index
        pos.principal = (remaining as u128) * WAD / pool.borrow_index;
        pos.interest_index_snap = pool.borrow_index;
        let new_principal = pos.principal;
        set_borrow_position(&mut pool.borrows, borrower, pos);
        // update totals
        let principal_reduction: u128 = if ((pay_amt as u128) > (interest_applied as u128)) { (pay_amt as u128) - (interest_applied as u128) } else { 0 };
        if (pool.total_borrows_principal >= principal_reduction) { pool.total_borrows_principal = pool.total_borrows_principal - principal_reduction; } else { pool.total_borrows_principal = 0; };
        event::emit(Repay { who: ctx.sender(), amount: pay_amt, remaining_principal: new_principal, timestamp_ms: sui::clock::timestamp_ms(clock) });
        leftover
    }

    /// Repay with rewards: compute interest portion and convert to USD via oracle
    public fun repay_with_rewards<T>(pool: &mut LendingPool<T>, mut pay: Coin<T>, borrower: address, symbol: String, reg: &unxversal::oracle::OracleRegistry, agg: &switchboard::aggregator::Aggregator, rewards_obj: &mut rewards::Rewards, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        accrue<T>(pool, clock);
        let amt = coin::value(&pay);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let pos0 = get_borrow_position(&pool.borrows, borrower);
        assert!(pos0.principal > 0, E_NO_BORROW);
        let owed = current_borrow_balance_inner(pool.borrow_index, &pos0);
        let pay_amt = if ((amt as u128) >= owed) { owed as u64 } else { amt };
        let interest_remaining: u64 = if (owed > pos0.principal) { (owed - pos0.principal) as u64 } else { 0 };
        let interest_applied: u64 = if (pay_amt > interest_remaining) { interest_remaining } else { pay_amt };
        let px_1e6 = unxversal::oracle::get_price_for_symbol(reg, clock, &symbol, agg);
        let interest_usd_1e6: u128 = (interest_applied as u128) * (px_1e6 as u128);
        if (interest_usd_1e6 > 0u128) { rewards::on_repay_interest(rewards_obj, borrower, interest_usd_1e6, clock); };
        repay<T>(pool, pay, borrower, clock, ctx)
    }

    // NOTE: Rewards for repay interest should be computed via oracle; avoid trusting caller-provided USD.

    /// Keeper: liquidate an undercollateralized borrower by repaying up to `repay_amount` and seizing shares with a bonus
    public fun liquidate<T>(pool: &mut LendingPool<T>, borrower: address, repay_amount: Coin<T>, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        accrue<T>(pool, clock);
        let health_ok = is_healthy_for<T>(pool, borrower);
        assert!(!health_ok, E_HEALTH_VIOLATION);
        let mut pos = get_borrow_position(&pool.borrows, borrower);
        let owed = current_borrow_balance_inner(pool.borrow_index, &pos) as u64;
        let to_repay = if (coin::value(&repay_amount) < owed) { coin::value(&repay_amount) } else { owed };
        // Take repayment and split reserves
        let mut repay = repay_amount;
        let mut to_use = coin::split(&mut repay, to_repay, ctx);
        let interest_remaining: u64 = if ((owed as u128) > pos.principal) { ((owed as u128) - pos.principal) as u64 } else { 0 };
        let interest_applied: u64 = if (to_repay > interest_remaining) { interest_remaining } else { to_repay };
        let reserve_cut: u64 = ((interest_applied as u128) * (pool.reserve_factor_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let reserve_coin = coin::split(&mut to_use, reserve_cut, ctx);
        pool.reserves.join(coin::into_balance(reserve_coin));
        pool.liquidity.join(coin::into_balance(to_use));
        // new debt
        let remaining_u128 = (owed as u128) - (to_repay as u128);
        pos.principal = remaining_u128 * WAD / pool.borrow_index;
        pos.interest_index_snap = pool.borrow_index;
        set_borrow_position(&mut pool.borrows, borrower, pos);
        // seize shares (including liquidation bonus)
        let seize_value = (to_repay as u128) * (pool.total_supply_shares as u128) / (balance::value(&pool.liquidity) as u128);
        let bonus = (seize_value * (pool.liquidation_bonus_bps as u128)) / (fees::bps_denom() as u128);
        let seize_shares = seize_value + bonus;
        // move shares from borrower to liquidator up to borrower's shares
        let borrower_sh = get_shares(&pool.supplier_shares, borrower);
        let actual_seize = if (borrower_sh >= seize_shares) { seize_shares } else { borrower_sh };
        set_shares(&mut pool.supplier_shares, borrower, borrower_sh - actual_seize);
        add_shares(&mut pool.supplier_shares, ctx.sender(), actual_seize);
        event::emit(Liquidated { borrower, liquidator: ctx.sender(), repay_amount: to_repay, shares_seized: actual_seize, bonus_bps: pool.liquidation_bonus_bps, timestamp_ms: sui::clock::timestamp_ms(clock) });
        // return leftover of repay coin
        repay
    }

    /// Liquidate with rewards: compute repay notional in USD via oracle and credit liquidator
    public fun liquidate_with_rewards<T>(pool: &mut LendingPool<T>, borrower: address, repay_amount: Coin<T>, symbol: String, reg: &unxversal::oracle::OracleRegistry, agg: &switchboard::aggregator::Aggregator, rewards_obj: &mut rewards::Rewards, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        let amt = coin::value(&repay_amount);
        let px_1e6 = unxversal::oracle::get_price_for_symbol(reg, clock, &symbol, agg);
        let usd_1e6: u128 = (amt as u128) * (px_1e6 as u128);
        let out = liquidate<T>(pool, borrower, repay_amount, clock, ctx);
        if (usd_1e6 > 0u128) { rewards::on_liquidation(rewards_obj, ctx.sender(), usd_1e6, clock); };
        out
    }

    // NOTE: Rewards for liquidation should be computed from actual repay notional using oracle in-module.

    /// Flash loan: borrow `amount` with immediate same-transaction repayment requirement.
    /// Returns the borrowed coin and a capability that must be consumed by `flash_repay` in the same transaction.
    public fun flash_loan<T>(pool: &mut LendingPool<T>, amount: u64, clock: &Clock, ctx: &mut TxContext): (Coin<T>, FlashLoanCap<T>) {
        accrue<T>(pool, clock);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(balance::value(&pool.liquidity) >= amount, E_INSUFFICIENT_LIQUIDITY);
        let fee: u64 = ((amount as u128) * (pool.flash_fee_bps as u128) / (fees::bps_denom() as u128)) as u64;
        let part = balance::split(&mut pool.liquidity, amount);
        let loan = coin::from_balance(part, ctx);
        event::emit(FlashLoan { who: ctx.sender(), amount, fee, timestamp_ms: sui::clock::timestamp_ms(clock) });
        (loan, FlashLoanCap<T> { principal: amount, fee })
    }

    /// Repay a flash loan. Requires the capability returned by `flash_loan`.
    /// Returns any leftover of the provided repay coin.
    public fun flash_repay<T>(pool: &mut LendingPool<T>, mut repay: Coin<T>, cap: FlashLoanCap<T>, clock: &Clock, ctx: &mut TxContext): Coin<T> {
        let FlashLoanCap { principal, fee } = cap;
        let due: u64 = principal + fee;
        let have = coin::value(&repay);
        assert!(have >= due, E_FLASH_UNDERPAY);
        // Take exactly what is due
        let mut to_use = coin::split(&mut repay, due, ctx);
        if (fee > 0) {
            let fee_coin = coin::split(&mut to_use, fee, ctx);
            pool.reserves.join(coin::into_balance(fee_coin));
        };
        // Return principal to liquidity
        pool.liquidity.join(coin::into_balance(to_use));
        event::emit(FlashRepaid { who: ctx.sender(), principal, fee, timestamp_ms: sui::clock::timestamp_ms(clock) });
        // Return leftover
        repay
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
        let interest_factor_den: u128 = (fees::bps_denom() as u128) * (YEAR_MS as u128);
        let delta_index: u128 = interest_factor_num / interest_factor_den; // WAD-scaled delta
        let new_index: u128 = pool.borrow_index + delta_index;
        // We only update indices; reserves are realized upon repayment
        event::emit(Accrued { interest_index: new_index, dt_ms: dt, new_reserves: 0, timestamp_ms: now });
        pool.borrow_index = new_index;
        pool.last_accrued_ms = now;
    }

    /// View: current utilization in bps
    public fun utilization_bps<T>(pool: &LendingPool<T>): u64 {
        let borrows = pool.total_borrows_principal as u64;
        let cash = balance::value(&pool.liquidity);
        if (borrows == 0) return 0;
        let denom = cash + borrows;
        ((borrows as u128) * (fees::bps_denom() as u128) / (denom as u128)) as u64
    }

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

    /// View: exchange rate in WAD (1e18) of liquidity per share
    public fun exchange_rate_wad<T>(pool: &LendingPool<T>): u128 {
        let liq = balance::value(&pool.liquidity) as u128;
        if (pool.total_supply_shares == 0 || liq == 0) return WAD;
        (liq * WAD) / pool.total_supply_shares
    }

    /// View: compute user's maximum borrowable amount (in asset units) based on collateral factor and current shares
    public fun max_borrowable_for<T>(pool: &LendingPool<T>, who: address): u64 {
        let shares = get_shares(&pool.supplier_shares, who);
        if (pool.total_supply_shares == 0 || shares == 0) return 0;
        let liq = balance::value(&pool.liquidity) as u128;
        let val: u128 = liq * (shares as u128) / (pool.total_supply_shares as u128);
        ((val * (pool.collateral_factor_bps as u128) / (fees::bps_denom() as u128)) as u64)
    }

    fun max_borrowable_with_cf<T>(pool: &LendingPool<T>, who: address, eff_cf_bps: u64): u64 {
        let shares = get_shares(&pool.supplier_shares, who);
        if (pool.total_supply_shares == 0 || shares == 0) return 0;
        let liq = balance::value(&pool.liquidity) as u128;
        let val: u128 = liq * (shares as u128) / (pool.total_supply_shares as u128);
        ((val * (eff_cf_bps as u128) / (fees::bps_denom() as u128)) as u64)
    }

    /// View: true if borrower meets collateral requirement
    public fun is_healthy_for<T>(pool: &LendingPool<T>, who: address): bool {
        let maxb = max_borrowable_for<T>(pool, who) as u128;
        let owed = current_borrow_balance<T>(pool, who) as u128;
        maxb >= owed
    }

    public fun effective_collateral_factor_bps(base_cf_bps: u64, liq_cf_bps: u64, staking_pool: &StakingPool, user: address, cfg: &fees::FeeConfig): u64 {
        let bonus = fees::staking_discount_bps(staking_pool, user, cfg);
        let cap = fees::lending_collateral_bonus_bps_max(cfg);
        let add = if (bonus > cap) { cap } else { bonus };
        let mut eff = base_cf_bps + add;
        // Cap effective CF at liquidation threshold (borrowers should not be liquidatable at max LTV)
        if (eff > liq_cf_bps) { eff = liq_cf_bps; };
        if (eff > fees::bps_denom() - 100) { fees::bps_denom() - 100 } else { eff }
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
        if (table::contains(tbl, who)) {
            let p_ref = table::borrow(tbl, who);
            BorrowPosition { principal: p_ref.principal, interest_index_snap: p_ref.interest_index_snap }
        } else { BorrowPosition { principal: 0, interest_index_snap: WAD } }
    }

    fun set_borrow_position(tbl: &mut Table<address, BorrowPosition>, who: address, v: BorrowPosition) {
        if (table::contains(tbl, who)) { let _old = table::remove(tbl, who); };
        table::add(tbl, who, v);
    }
}


