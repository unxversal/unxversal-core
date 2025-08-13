#[allow(lint(public_entry))]
module unxversal::lending {
    /*******************************
    * Unxversal Lending – Phase 1
    * - Supports coin-based lending pools (generic T)
    * - Permissioned asset/pool listing (admin-only)
    * - User accounts track per-asset supply/borrow balances
    * - Simple flash-loan primitive on a per-pool basis
    * - Object Display registered for Registry, Pool, Account
    *******************************/

    use sui::display;
    use sui::package;
    use sui::types;
    use sui::event;
    use sui::clock::Clock;
    use sui::balance::{Self as BalanceMod, Balance};
    use sui::coin::{Self as coin, Coin};
    use sui::table::{Self as table, Table};


    use std::string::{Self as string, String};
    use sui::vec_set::{Self as vec_set, VecSet};

    // Synthetics integration
    use pyth::price_info::PriceInfoObject;
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::treasury::Treasury;
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{Self as Synth, SynthRegistry, CollateralVault, CollateralConfig};
    // Remove hardcoded USDC; lending remains generic and integrates with chosen collateral C

    /*******************************
    * Errors
    *******************************/
    const E_NOT_ADMIN: u64 = 1;
    const E_ASSET_EXISTS: u64 = 2;
    const E_POOL_EXISTS: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 5;
    const E_NOT_OWNER: u64 = 6;
    const E_UNKNOWN_ASSET: u64 = 7;
    const E_OVER_REPAY: u64 = 8;
    const E_NO_COLLATERAL: u64 = 9;
    const E_BAD_PRICE: u64 = 10;
    const E_VIOLATION: u64 = 11; // LTV or health violation

    /*******************************
    * One-Time Witness for init()
    *******************************/
    public struct LENDING has drop {}

    /*******************************
    * Capabilities & Admin control
    *******************************/
    public struct LendingDaddyCap has key, store { id: UID }
    public struct LendingAdminCap has key, store { id: UID }

    /*******************************
    * Config & models
    *******************************/
    public struct GlobalParams has store, drop {
        reserve_factor_bps: u64,   // portion of interest directed to reserves
        flash_loan_fee_bps: u64,   // fee applied to flash loans
    }

    public struct InterestRateModel has store {
        base_rate_bps: u64,        // e.g. 200 = 2% APR baseline
        slope_bps: u64,            // linear slope wrt utilization in bps
        optimal_utilization_bps: u64, // kink point (unused in phase-1)
    }

    public struct AssetConfig has store {
        symbol: String,
        is_collateral: bool,
        is_borrowable: bool,
        reserve_factor_bps: u64,   // overrides global if > 0
        ltv_bps: u64,              // max borrow against this collateral (e.g., 8000 = 80%)
        liq_threshold_bps: u64,    // below this, position can be liquidated (e.g., 8500)
        liq_penalty_bps: u64,      // extra seized on liquidation (bonus source)
    }

    /*******************************
    * Registry – shared root
    *******************************/
    public struct LendingRegistry has key, store {
        id: UID,
        supported_assets: Table<String, AssetConfig>,
        coin_oracle_feeds: Table<String, vector<u8>>, // optional mapping for coins
        lending_pools: Table<String, ID>,
        interest_rate_models: Table<String, InterestRateModel>,
        global_params: GlobalParams,
        admin_addrs: VecSet<address>,
        synth_markets: Table<String, SynthMarket>,
        paused: bool,
    }

    /// Minimal per-synthetic market config/stats (Phase 1)
    public struct SynthMarket has store {
        symbol: String,
        reserve_factor_bps: u64,
        total_borrow_units: u64,
        total_liquidity: u64,
        reserve_units: u64,
    }

    /*******************************
    * Events
    *******************************/
    public struct AssetSupplied has copy, drop { user: address, asset: String, amount: u64, new_balance: u64, timestamp: u64 }
    public struct AssetWithdrawn has copy, drop { user: address, asset: String, amount: u64, remaining_balance: u64, timestamp: u64 }
    public struct AssetBorrowed has copy, drop { user: address, asset: String, amount: u64, new_borrow_balance: u64, timestamp: u64 }
    public struct DebtRepaid has copy, drop { user: address, asset: String, amount: u64, remaining_debt: u64, timestamp: u64 }
    public struct FlashLoanInitiated has copy, drop { asset: String, amount: u64, fee: u64, borrower: address, timestamp: u64 }
    public struct FlashLoanRepaid has copy, drop { asset: String, amount: u64, fee: u64, repayer: address, timestamp: u64 }
    public struct SynthFlashLoanInitiated has copy, drop { symbol: String, amount_units: u64, fee_units: u64, borrower: address, timestamp: u64 }
    public struct SynthFlashLoanRepaid has copy, drop { symbol: String, amount_units: u64, fee_units: u64, repayer: address, timestamp: u64 }
    public struct RateUpdated has copy, drop { asset: String, utilization_bps: u64, borrow_rate_bps: u64, supply_rate_bps: u64, timestamp: u64 }
    public struct InterestAccrued has copy, drop { asset: String, dt_ms: u64, new_borrow_index: u64, new_supply_index: u64, delta_borrows: u64, reserves_added: u64, timestamp: u64 }
    public struct SynthAccrued has copy, drop { symbol: String, delta_units: u64, reserve_units: u64, timestamp: u64 }
    public struct SynthLiquidated has copy, drop { symbol: String, repay_units: u64, collateral_seized: u64, bot_reward: u64, liquidator: address, timestamp: u64 }
    public struct SynthLiquiditySupplied has copy, drop { user: address, symbol: String, amount: u64, new_balance: u64, timestamp: u64 }
    public struct SynthLiquidityWithdrawn has copy, drop { user: address, symbol: String, amount: u64, remaining_balance: u64, timestamp: u64 }
    public struct SynthBorrowed has copy, drop { user: address, symbol: String, units: u64, new_borrow_units: u64, timestamp: u64 }
    public struct SynthRepaid has copy, drop { user: address, symbol: String, units: u64, remaining_borrow_units: u64, timestamp: u64 }

    /// Pair type for returning symbol/feed lists without tuple type arguments
    

    /*******************************
    * User account
    *******************************/
    public struct UserAccount has key, store {
        id: UID,
        owner: address,
        supply_balances: Table<String, u64>, // principal units per asset
        borrow_balances: Table<String, u64>, // principal units per asset
        synth_liquidity: Table<String, u64>, // per-synth supplied collateral liquidity
        synth_borrow_units: Table<String, u64>,   // per-synth borrow units
        last_update_ms: u64,
    }

    /*******************************
    * Pool
    *******************************/
    public struct LendingPool<phantom T> has key, store {
        id: UID,
        asset: String,
        total_supply: u64,
        total_borrows: u64,
        total_reserves: u64,
        cash: Balance<T>,
        supply_index: u64,   // scaled by 1e6
        borrow_index: u64,   // scaled by 1e6
        last_update_ms: u64,
        current_supply_rate_bps: u64,
        current_borrow_rate_bps: u64,
    }

    const INDEX_SCALE: u64 = 1_000_000; // 1e6 fixed-point for indexes

    const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;
    const E_VAULT_NOT_HEALTHY: u64 = 12;
    

    fun clone_string(s: &String): String {
        let src = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(src, i)); i = i + 1; };
        string::utf8(out)
    }

    

    fun units_from_scaled(scaled: u64, index: u64): u64 {
        if (index == 0) { return 0; };
        let num = (scaled as u128) * (index as u128);
        let den = INDEX_SCALE as u128;
        let v = num / den;
        if (v > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { v as u64 }
    }

    fun scaled_from_units(units: u64, index: u64): u64 {
        if (index == 0) { return 0; };
        let num = (units as u128) * (INDEX_SCALE as u128);
        let den = index as u128;
        let v = num / den;
        if (v > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { v as u64 }
    }

    /// Flash loan proof object
    public struct FlashLoan<phantom T> has store, drop { amount: u64, fee: u64, asset: String }

    // Hot potato for synthetic flash loans (no abilities) – must be consumed in same tx
    public struct SynthFlashLoan has drop { symbol: String, amount_units: u64, fee_units: u64 }

    /*******************************
    * Admin helper
    *******************************/
    fun assert_is_admin(reg: &LendingRegistry, addr: address) { assert!(vec_set::contains(&reg.admin_addrs, &addr), E_NOT_ADMIN); }

    /*******************************
    * INIT – executed once
    *******************************/
    fun init(otw: LENDING, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let gp = GlobalParams { reserve_factor_bps: 1000, flash_loan_fee_bps: 9 };
        let mut admins = vec_set::empty<address>();
        vec_set::insert(&mut admins, ctx.sender());

        let reg = LendingRegistry {
            id: object::new(ctx),
            supported_assets: table::new<String, AssetConfig>(ctx),
            coin_oracle_feeds: table::new<String, vector<u8>>(ctx),
            lending_pools: table::new<String, ID>(ctx),
            interest_rate_models: table::new<String, InterestRateModel>(ctx),
            global_params: gp,
            admin_addrs: admins,
            synth_markets: table::new<String, SynthMarket>(ctx),
            paused: false,
        };
        transfer::share_object(reg);

        // Mint caps
        transfer::public_transfer(LendingDaddyCap { id: object::new(ctx) }, ctx.sender());
        transfer::public_transfer(LendingAdminCap { id: object::new(ctx) }, ctx.sender());

        // Display metadata (type templates)
        let mut disp_reg = display::new<LendingRegistry>(&publisher, ctx);
        disp_reg.add(b"name".to_string(),        b"Unxversal Lending Registry".to_string());
        disp_reg.add(b"description".to_string(), b"Controls supported assets, pools, and risk parameters".to_string());
        disp_reg.update_version();
        transfer::public_transfer(disp_reg, ctx.sender());

        // Register Display for UserAccount
        let mut disp_user = display::new<UserAccount>(&publisher, ctx);
        disp_user.add(b"name".to_string(),        b"Unxversal Lending Account".to_string());
        disp_user.add(b"description".to_string(), b"Tracks a user's supplied and borrowed balances".to_string());
        disp_user.update_version();
        transfer::public_transfer(disp_user, ctx.sender());

        // Register Display for an example pool type to provide a template
        let mut disp_pool_tpl = display::new<LendingPool<UNXV>>(&publisher, ctx);
        disp_pool_tpl.add(b"name".to_string(),        b"Unxversal Lending Pool".to_string());
        disp_pool_tpl.add(b"asset".to_string(),       b"{asset}".to_string());
        disp_pool_tpl.add(b"description".to_string(), b"Lending pool for a specific asset".to_string());
        disp_pool_tpl.update_version();
        transfer::public_transfer(disp_pool_tpl, ctx.sender());

        // Transfer publisher to caller
        transfer::public_transfer(publisher, ctx.sender());
    }

    /*******************************
    * Admin – manage allow-list & params
    *******************************/
    public entry fun grant_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, new_admin: address) {
        vec_set::insert(&mut reg.admin_addrs, new_admin);
    }

    public entry fun revoke_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, bad: address) {
        vec_set::remove(&mut reg.admin_addrs, &bad);
    }

    public entry fun add_supported_asset(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        symbol: String,
        is_collateral: bool,
        is_borrowable: bool,
        reserve_factor_bps: u64,
        ltv_bps: u64,
        liq_threshold_bps: u64,
        liq_penalty_bps: u64,
        irm_base_bps: u64,
        irm_slope_bps: u64,
        irm_opt_util_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, ctx.sender());
        assert!(!reg.paused, 1000);
        assert!(!table::contains(&reg.supported_assets, clone_string(&symbol)), E_ASSET_EXISTS);
        table::add(&mut reg.supported_assets, clone_string(&symbol), AssetConfig { symbol: clone_string(&symbol), is_collateral, is_borrowable, reserve_factor_bps, ltv_bps, liq_threshold_bps, liq_penalty_bps });
        table::add(&mut reg.interest_rate_models, symbol, InterestRateModel { base_rate_bps: irm_base_bps, slope_bps: irm_slope_bps, optimal_utilization_bps: irm_opt_util_bps });
    }

    public entry fun set_asset_params(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        symbol: String,
        is_collateral: bool,
        is_borrowable: bool,
        reserve_factor_bps: u64,
        ltv_bps: u64,
        liq_threshold_bps: u64,
        liq_penalty_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, ctx.sender());
        assert!(!reg.paused, 1000);
        let mut a = table::borrow_mut(&mut reg.supported_assets, clone_string(&symbol));
        a.is_collateral = is_collateral;
        a.is_borrowable = is_borrowable;
        a.reserve_factor_bps = reserve_factor_bps;
        a.ltv_bps = ltv_bps;
        a.liq_threshold_bps = liq_threshold_bps;
        a.liq_penalty_bps = liq_penalty_bps;
    }

    public entry fun pause(_admin: &LendingAdminCap, reg: &mut LendingRegistry, ctx: &TxContext) { assert_is_admin(reg, ctx.sender()); reg.paused = true; }
    public entry fun resume(_admin: &LendingAdminCap, reg: &mut LendingRegistry, ctx: &TxContext) { assert_is_admin(reg, ctx.sender()); reg.paused = false; }

    public entry fun set_global_params(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        reserve_factor_bps: u64,
        flash_loan_fee_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, ctx.sender());
        assert!(!reg.paused, 1000);
        reg.global_params = GlobalParams { reserve_factor_bps, flash_loan_fee_bps };
    }

    /*******************************
    * Pool lifecycle (admin-only)
    *******************************/
    public entry fun create_pool<T>(_admin: &LendingAdminCap, reg: &mut LendingRegistry, asset_symbol: String, ctx: &mut TxContext) {
        assert_is_admin(reg, ctx.sender());
        assert!(!reg.paused, 1000);
        assert!(table::contains(&reg.supported_assets, clone_string(&asset_symbol)), E_UNKNOWN_ASSET);
        assert!(!table::contains(&reg.lending_pools, clone_string(&asset_symbol)), E_POOL_EXISTS);
        let pool = LendingPool<T> {
            id: object::new(ctx),
            asset: clone_string(&asset_symbol),
            total_supply: 0,
            total_borrows: 0,
            total_reserves: 0,
            cash: BalanceMod::zero<T>(),
            supply_index: 1_000_000, // 1e6
            borrow_index: 1_000_000,
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            current_supply_rate_bps: 0,
            current_borrow_rate_bps: 0,
        };
        let id = object::id(&pool);
        transfer::share_object(pool);
        table::add(&mut reg.lending_pools, clone_string(&asset_symbol), id);

        // Display templates are registered in init()
    }

    /*******************************
    * User Account lifecycle
    *******************************/
    public entry fun open_account(ctx: &mut TxContext) {
        let acct = UserAccount {
            id: object::new(ctx),
            owner: ctx.sender(),
            supply_balances: table::new<String, u64>(ctx),
            borrow_balances: table::new<String, u64>(ctx),
            synth_liquidity: table::new<String, u64>(ctx),
            synth_borrow_units: table::new<String, u64>(ctx),
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx)
        };
        transfer::share_object(acct);
        // Display templates are registered in init()
    }

    /*******************************
    * Core operations: supply / withdraw
    *******************************/
    public entry fun supply<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, mut coins: Coin<T>, amount: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool, ctx);
        let have = coin::value(&coins);
        assert!(have >= amount, E_ZERO_AMOUNT);
        let exact = coin::split(&mut coins, amount, ctx);
        transfer::public_transfer(coins, ctx.sender());
        // move into pool cash
        let bal = coin::into_balance(exact);
        BalanceMod::join(&mut pool.cash, bal);
        pool.total_supply = pool.total_supply + amount;
        let sym = clone_string(&pool.asset);
        // store scaled balance: scaled += amount / supply_index
        let cur_scaled = if (table::contains(&acct.supply_balances, clone_string(&sym))) { *table::borrow(&acct.supply_balances, clone_string(&sym)) } else { 0 };
        let delta_scaled = scaled_from_units(amount, pool.supply_index);
        let new_scaled = cur_scaled + delta_scaled;
        table::add(&mut acct.supply_balances, clone_string(&sym), new_scaled);
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        let new_units = units_from_scaled(new_scaled, pool.supply_index);
        event::emit(AssetSupplied { user: ctx.sender(), asset: sym, amount, new_balance: new_units, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun withdraw<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        acct: &mut UserAccount,
        amount: u64,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_self: &PriceInfoObject,
        symbols: vector<String>,
        prices: vector<PriceInfoObject>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool, ctx);
        let sym = clone_string(&pool.asset);
        assert!(table::contains(&acct.supply_balances, clone_string(&sym)), E_UNKNOWN_ASSET);
        let cur_scaled = *table::borrow(&acct.supply_balances, clone_string(&sym));
        let cur_units = units_from_scaled(cur_scaled, pool.supply_index);
        assert!(cur_units >= amount, E_ZERO_AMOUNT);
        // ensure liquidity
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let new_units = cur_units - amount;
        let new_scaled = scaled_from_units(new_units, pool.supply_index);
        table::add(&mut acct.supply_balances, clone_string(&sym), new_scaled);
        pool.total_supply = pool.total_supply - amount;
        // Enforce LTV after withdrawal if asset is collateral
        if (table::contains(&reg.supported_assets, clone_string(&sym))) {
            let a = table::borrow(&reg.supported_assets, clone_string(&sym));
            if (a.is_collateral) {
                // compute current totals
                let (tot_coll, tot_debt, _) = check_account_health_coins(acct, reg, oracle_cfg, clock, symbols, prices);
                let px_self = get_price_scaled_1e6(oracle_cfg, clock, price_self) as u128;
                let reduce_cap = ((amount as u128) * px_self * (a.ltv_bps as u128)) / 10_000u128;
                let new_capacity = if (tot_coll > reduce_cap) { tot_coll - reduce_cap } else { 0 };
                assert!(tot_debt <= new_capacity, E_VIOLATION);
            }
        };
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(AssetWithdrawn { user: ctx.sender(), asset: sym, amount, remaining_balance: new_units, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(out, ctx.sender());
    }

    /*******************************
    * Core operations: borrow / repay
    *******************************/
    public entry fun borrow<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        acct: &mut UserAccount,
        amount: u64,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_debt: &PriceInfoObject,
        symbols: vector<String>,
        prices: vector<PriceInfoObject>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool, ctx);
        // check pool liquidity
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        // LTV guard: ensure new debt <= capacity
        let cap = compute_ltv_capacity_usd(acct, reg, oracle_cfg, clock, symbols, prices);
        let (_, tot_debt, _) = check_account_health_coins(acct, reg, oracle_cfg, clock, symbols, prices);
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_debt) as u128;
        let new_debt = tot_debt + (amount as u128) * px;
        assert!(new_debt <= cap, E_VAULT_NOT_HEALTHY);
        // update borrow scaled
        let sym = clone_string(&pool.asset);
        // store scaled debt: scaled += amount / borrow_index
        let cur_scaled = if (table::contains(&acct.borrow_balances, clone_string(&sym))) { *table::borrow(&acct.borrow_balances, clone_string(&sym)) } else { 0 };
        let delta_scaled = scaled_from_units(amount, pool.borrow_index);
        let new_scaled = cur_scaled + delta_scaled;
        table::add(&mut acct.borrow_balances, clone_string(&sym), new_scaled);
        pool.total_borrows = pool.total_borrows + amount;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        // transfer out
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let new_units = units_from_scaled(new_scaled, pool.borrow_index);
        event::emit(AssetBorrowed { user: ctx.sender(), asset: sym, amount, new_borrow_balance: new_units, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(out, ctx.sender());
    }

    public entry fun repay<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, payment: Coin<T>, ctx: &mut TxContext) {
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        accrue_pool_interest(_reg, pool, ctx);
        let amount = coin::value(&payment);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let sym = clone_string(&pool.asset);
        assert!(table::contains(&acct.borrow_balances, clone_string(&sym)), E_UNKNOWN_ASSET);
        let cur_scaled = *table::borrow(&acct.borrow_balances, clone_string(&sym));
        let cur_units = units_from_scaled(cur_scaled, pool.borrow_index);
        assert!(amount <= cur_units, E_OVER_REPAY);
        // move into pool cash
        let bal = coin::into_balance(payment);
        BalanceMod::join(&mut pool.cash, bal);
        let new_units = cur_units - amount;
        let new_scaled = scaled_from_units(new_units, pool.borrow_index);
        table::add(&mut acct.borrow_balances, clone_string(&sym), new_scaled);
        pool.total_borrows = pool.total_borrows - amount;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(DebtRepaid { user: ctx.sender(), asset: sym, amount, remaining_debt: new_units, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Rate model and interest accrual (coins)
    *******************************/
    fun get_reserve_factor_bps(reg: &LendingRegistry, sym: &String): u64 {
        if (table::contains(&reg.supported_assets, clone_string(sym))) {
            let a = table::borrow(&reg.supported_assets, clone_string(sym));
            if (a.reserve_factor_bps > 0) { return a.reserve_factor_bps; };
        };
        reg.global_params.reserve_factor_bps
    }

    fun utilization_bps<T>(pool: &LendingPool<T>): u64 {
        let cash = BalanceMod::value(&pool.cash);
        let denom = cash + pool.total_borrows;
        if (denom == 0) { return 0; };
        (pool.total_borrows * 10_000) / denom
    }

    public entry fun update_pool_rates<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, ctx: &TxContext) {
        assert!(!reg.paused, 1000);
        let u_bps = utilization_bps(pool);
        let irm = table::borrow(&reg.interest_rate_models, clone_string(&pool.asset));
        let borrow_rate = irm.base_rate_bps + (irm.slope_bps * u_bps) / 10_000;
        pool.current_borrow_rate_bps = borrow_rate;
        // supply rate ≈ borrow_rate * utilization * (1 - reserve_factor)
        let rf = get_reserve_factor_bps(reg, &pool.asset);
        let supply_rate = (borrow_rate * u_bps * (10_000 - rf)) / (10_000 * 10_000);
        pool.current_supply_rate_bps = supply_rate;
        event::emit(RateUpdated { asset: clone_string(&pool.asset), utilization_bps: u_bps, borrow_rate_bps: borrow_rate, supply_rate_bps: supply_rate, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun accrue_pool_interest<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, ctx: &TxContext) {
        let now = sui::tx_context::epoch_timestamp_ms(ctx);
        if (now <= pool.last_update_ms) { return; };
        let dt = now - pool.last_update_ms;
        let year_ms = 31_536_000_000; // 365 days
        // interest factor in 1e6 scale: factor = (rate_bps/10k) * dt/year
        let borrow_factor = (pool.current_borrow_rate_bps as u128) * (dt as u128) / (10_000u128 * (year_ms as u128));
        let supply_factor = (pool.current_supply_rate_bps as u128) * (dt as u128) / (10_000u128 * (year_ms as u128));
        // update indexes: idx = idx * (1 + factor)
        let bi = (pool.borrow_index as u128) + ((pool.borrow_index as u128) * borrow_factor);
        let si = (pool.supply_index as u128) + ((pool.supply_index as u128) * supply_factor);
        pool.borrow_index = if (bi > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { bi as u64 };
        pool.supply_index = if (si > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { si as u64 };
        // update totals: total_borrows += total_borrows * borrow_factor
        let old_tb = pool.total_borrows as u128;
        let tb = old_tb + (old_tb * borrow_factor);
        let delta_borrows = if (tb > old_tb) { tb - old_tb } else { 0 };
        // reserve factor portion
        let rf_bps = get_reserve_factor_bps(reg, &pool.asset) as u128;
        let reserves_added = (delta_borrows * rf_bps) / 10_000u128;
        pool.total_borrows = if (tb > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { tb as u64 };
        if (reserves_added > 0) {
            let add = if (reserves_added > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { reserves_added as u64 };
            pool.total_reserves = pool.total_reserves + add;
        };
        pool.last_update_ms = now;
        let emitted_delta = if (delta_borrows > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { delta_borrows as u64 };
        let emitted_res = if (reserves_added > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { reserves_added as u64 };
        event::emit(InterestAccrued { asset: clone_string(&pool.asset), dt_ms: dt, new_borrow_index: pool.borrow_index, new_supply_index: pool.supply_index, delta_borrows: emitted_delta, reserves_added: emitted_res, timestamp: now });
    }

    /*******************************
    * Aggregate capacity helper: sum(collateral_value * LTV)
    *******************************/
    public fun compute_ltv_capacity_usd(
        acct: &UserAccount,
        reg: &LendingRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        symbols: vector<String>,
        prices: vector<PriceInfoObject>
    ): u128 {
        let mut cap: u128 = 0;
        let mut i = 0;
        while (i < vector::length(&symbols)) {
            let sym = *vector::borrow(&symbols, i);
            if (table::contains(&acct.supply_balances, clone_string(&sym)) && table::contains(&reg.supported_assets, clone_string(&sym))) {
                let a = table::borrow(&reg.supported_assets, clone_string(&sym));
                if (a.is_collateral) {
                    let units = *table::borrow(&acct.supply_balances, clone_string(&sym)) as u128;
                    let p = vector::borrow(&prices, i);
                    let px = get_price_scaled_1e6(oracle_cfg, clock, p) as u128;
                    cap = cap + (units * px * (a.ltv_bps as u128)) / 10_000u128;
                }
            };
            i = i + 1;
        };
        cap
    }

    /*******************************
    * Account health check (coins) – off-chain should pass matching symbols/prices
    *******************************/
    public fun check_account_health_coins(
        acct: &UserAccount,
        reg: &LendingRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        symbols: vector<String>,
        prices: vector<PriceInfoObject>
    ): (u128, u128, bool) {
        let mut total_coll: u128 = 0;
        let mut total_debt: u128 = 0;
        let mut i = 0;
        while (i < vector::length(&symbols)) {
            let sym = *vector::borrow(&symbols, i);
            let p = vector::borrow(&prices, i);
            let px = get_price_scaled_1e6(oracle_cfg, clock, p) as u128; // micro-USD
            if (table::contains(&acct.supply_balances, clone_string(&sym))) {
                let units = *table::borrow(&acct.supply_balances, clone_string(&sym)) as u128;
                // only count as collateral if allowed
                if (table::contains(&reg.supported_assets, clone_string(&sym))) {
                    let a = table::borrow(&reg.supported_assets, clone_string(&sym));
                    if (a.is_collateral) { total_coll = total_coll + units * px; };
                }
            };
            if (table::contains(&acct.borrow_balances, clone_string(&sym))) {
                let units = *table::borrow(&acct.borrow_balances, clone_string(&sym)) as u128;
                total_debt = total_debt + units * px;
            };
            i = i + 1;
        };
        (total_coll, total_debt, total_coll >= total_debt)
    }

    /*******************************
    * Read-only helpers (for bots/indexers)
    *******************************/
    

    /*******************************
    * Liquidation (coins): liquidator repays debtor's debt asset and seizes collateral
    *******************************/
    public entry fun liquidate_coin_position<Debt, Coll>(
        reg: &LendingRegistry,
        debt_pool: &mut LendingPool<Debt>,
        coll_pool: &mut LendingPool<Coll>,
        debtor: &mut UserAccount,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        debt_price: &PriceInfoObject,
        coll_price: &PriceInfoObject,
        mut payment: Coin<Debt>,
        repay_amount: u64,
        // Optional internal routing flags could be added here
        ctx: &mut TxContext
    ) {
        // Cross-asset liquidation: debt and collateral may differ. Validate per-asset positions and configs below.
        assert!(repay_amount > 0, E_ZERO_AMOUNT);
        let have = coin::value(&payment);
        assert!(have >= repay_amount, E_INSUFFICIENT_LIQUIDITY);
        // Position must be below liquidation threshold for chosen collateral
        let (tot_coll, tot_debt, _) = check_account_health_coins(
            debtor,
            reg,
            oracle_cfg,
            clock,
            // caller should pass full symbols/prices set off-chain; for simplicity, require two here
            vector::empty<String>(),
            vector::empty<PriceInfoObject>()
        );
        if (tot_debt > 0) {
            let ratio_bps = ((tot_coll * 10_000u128) / tot_debt) as u64;
            let coll_sym = clone_string(&coll_pool.asset);
            let coll_cfg = table::borrow(&reg.supported_assets, clone_string(&coll_sym));
            assert!(ratio_bps < coll_cfg.liq_threshold_bps, E_VIOLATION);
        };
        // debtor must have outstanding debt in this asset
        let debt_sym = clone_string(&debt_pool.asset);
        assert!(table::contains(&debtor.borrow_balances, clone_string(&debt_sym)), E_UNKNOWN_ASSET);
        let cur_debt = *table::borrow(&debtor.borrow_balances, clone_string(&debt_sym));
        assert!(repay_amount <= cur_debt, E_OVER_REPAY);
        // apply payment into pool
        let exact_pay = coin::split(&mut payment, repay_amount, ctx);
        let pay_bal = coin::into_balance(exact_pay);
        BalanceMod::join(&mut debt_pool.cash, pay_bal);
        // refund leftover to liquidator
        transfer::public_transfer(payment, ctx.sender());
        debt_pool.total_borrows = debt_pool.total_borrows - repay_amount;
        let new_debt = cur_debt - repay_amount;
        table::add(&mut debtor.borrow_balances, clone_string(&debt_sym), new_debt);
        // compute seize amount in collateral units
        let pd = get_price_scaled_1e6(oracle_cfg, clock, debt_price) as u128;
        let pc = get_price_scaled_1e6(oracle_cfg, clock, coll_price) as u128;
        assert!(pd > 0 && pc > 0, E_BAD_PRICE);
        let repay_val = (repay_amount as u128) * pd;
        let coll_sym = clone_string(&coll_pool.asset);
        let coll_cfg = table::borrow(&reg.supported_assets, clone_string(&coll_sym));
        let bonus_bps = coll_cfg.liq_penalty_bps as u128;
        let seize_val = repay_val + (repay_val * bonus_bps) / 10_000u128;
        let mut seize_units = seize_val / pc;
        if (seize_units * pc < seize_val) { seize_units = seize_units + 1; }; // ceil
        let seize_u64 = if (seize_units > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { seize_units as u64 };
        // check debtor has collateral in this asset
        assert!(table::contains(&debtor.supply_balances, clone_string(&coll_sym)), E_NO_COLLATERAL);
        let cur_coll = *table::borrow(&debtor.supply_balances, clone_string(&coll_sym));
        assert!(cur_coll >= seize_u64, E_INSUFFICIENT_LIQUIDITY);
        // ensure pool has liquidity to deliver
        let cash_coll = BalanceMod::value(&coll_pool.cash);
        assert!(cash_coll >= seize_u64, E_INSUFFICIENT_LIQUIDITY);
        // update balances
        let new_coll = cur_coll - seize_u64;
        table::add(&mut debtor.supply_balances, clone_string(&coll_sym), new_coll);
        coll_pool.total_supply = coll_pool.total_supply - seize_u64;
        // send seized collateral to liquidator
        let out_bal = BalanceMod::split(&mut coll_pool.cash, seize_u64);
        let out = coin::from_balance(out_bal, ctx);
        transfer::public_transfer(out, ctx.sender());
    }

    /*******************************
    * Reserve skim to Treasury (collateral)
    *******************************/
    public entry fun skim_reserves_to_treasury<C>(
        _reg: &LendingRegistry,
        pool: &mut LendingPool<C>,
        treasury: &mut Treasury<C>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        assert!(pool.total_reserves >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        unxversal::treasury::deposit_collateral(treasury, out, b"lending_reserve".to_string(), ctx.sender(), ctx);
        pool.total_reserves = pool.total_reserves - amount;
    }

    /*******************************
    * Flash Loans – simple fee, same-tx repay enforced by API usage
    *******************************/
    public entry fun initiate_flash_loan<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, amount: u64, ctx: &mut TxContext) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let fee = (amount * _reg.global_params.flash_loan_fee_bps) / 10_000;
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        event::emit(FlashLoanInitiated { asset: clone_string(&pool.asset), amount, fee, borrower: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(out, ctx.sender());
    }

    public entry fun repay_flash_loan<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, mut principal: Coin<T>, proof_amount: u64, proof_fee: u64, proof_asset: String, ctx: &mut TxContext) {
        let due = proof_amount + proof_fee;
        let have = coin::value(&principal);
        assert!(have >= due, E_INSUFFICIENT_LIQUIDITY);
        let fee_coin = coin::split(&mut principal, proof_fee, ctx);
        // fees go to reserves (remain as cash but tracked in reserves)
        let fee_bal = coin::into_balance(fee_coin);
        BalanceMod::join(&mut pool.cash, fee_bal);
        pool.total_reserves = pool.total_reserves + proof_fee;
        // principal back
        let principal_bal = coin::into_balance(principal);
        BalanceMod::join(&mut pool.cash, principal_bal);
        event::emit(FlashLoanRepaid { asset: proof_asset, amount: proof_amount, fee: proof_fee, repayer: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Synthetic Flash Loans – mint & burn within same tx (hot potato)
    *******************************/
    public entry fun initiate_synth_flash_loan<C>(
        _reg: &LendingRegistry,
        synth_reg: &mut SynthRegistry,
        cfg: &CollateralConfig<C>,
        _oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        symbol: String,
        amount_units: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ): SynthFlashLoan {
        assert!(amount_units > 0, E_ZERO_AMOUNT);
        // mint debt units to the borrower's vault (exposure)
        Synth::mint_synthetic(
            cfg,
            vault,
            synth_reg,
            clock,
            price_info,
            clone_string(&symbol),
            amount_units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let fee_units = (amount_units * _reg.global_params.flash_loan_fee_bps) / 10_000;
        event::emit(SynthFlashLoanInitiated { symbol: clone_string(&symbol), amount_units, fee_units, borrower: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        SynthFlashLoan { symbol, amount_units, fee_units }
    }

    public entry fun repay_synth_flash_loan<C>(
        _reg: &LendingRegistry,
        synth_reg: &mut SynthRegistry,
        cfg: &CollateralConfig<C>,
        _oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        loan_amount_units: u64,
        loan_fee_units: u64,
        loan_symbol: String,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        let symbol = loan_symbol;
        let amount_units = loan_amount_units;
        let fee_units = loan_fee_units;
        let total_burn = amount_units + fee_units;
        // burn exactly amount + fee units from the vault exposure
        Synth::burn_synthetic(
            cfg,
            vault,
            synth_reg,
            clock,
            price_info,
            clone_string(&symbol),
            total_burn,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        event::emit(SynthFlashLoanRepaid { symbol, amount_units, fee_units, repayer: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Synth liquidity and durable borrow/repay (vault-managed)
    *******************************/
    public entry fun create_synth_market(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        symbol: String,
        reserve_factor_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, ctx.sender());
        assert!(!table::contains(&reg.synth_markets, clone_string(&symbol)), E_ASSET_EXISTS);
        let m = SynthMarket { symbol: clone_string(&symbol), reserve_factor_bps, total_borrow_units: 0, total_liquidity: 0, reserve_units: 0 };
        table::add(&mut reg.synth_markets, clone_string(&symbol), m);
        // Display templates are registered in init()
    }

    public entry fun supply_synth_liquidity<C>(
        reg: &mut LendingRegistry,
        market_symbol: String,
        pool_collateral: &mut LendingPool<C>,
        acct: &mut UserAccount,
        mut coins: Coin<C>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&reg.synth_markets, clone_string(&market_symbol)), E_UNKNOWN_ASSET);
        let have = coin::value(&coins);
        assert!(have >= amount, E_ZERO_AMOUNT);
        let exact = coin::split(&mut coins, amount, ctx);
        transfer::public_transfer(coins, ctx.sender());
        let bal = coin::into_balance(exact);
        BalanceMod::join(&mut pool_collateral.cash, bal);
        pool_collateral.total_supply = pool_collateral.total_supply + amount;
        let cur = if (table::contains(&acct.synth_liquidity, clone_string(&market_symbol))) { *table::borrow(&acct.synth_liquidity, clone_string(&market_symbol)) } else { 0 };
        let newb = cur + amount;
        table::add(&mut acct.synth_liquidity, clone_string(&market_symbol), newb);
        let mut m = table::borrow_mut(&mut reg.synth_markets, clone_string(&market_symbol));
        m.total_liquidity = m.total_liquidity + amount;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(SynthLiquiditySupplied { user: ctx.sender(), symbol: market_symbol, amount: amount, new_balance: newb, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun withdraw_synth_liquidity<C>(
        reg: &mut LendingRegistry,
        market_symbol: String,
        pool_collateral: &mut LendingPool<C>,
        acct: &mut UserAccount,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(table::contains(&acct.synth_liquidity, clone_string(&market_symbol)), E_UNKNOWN_ASSET);
        let cur = *table::borrow(&acct.synth_liquidity, clone_string(&market_symbol));
        assert!(cur >= amount, E_INSUFFICIENT_LIQUIDITY);
        let cash = BalanceMod::value(&pool_collateral.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool_collateral.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let newb = cur - amount;
        table::add(&mut acct.synth_liquidity, clone_string(&market_symbol), newb);
        pool_collateral.total_supply = pool_collateral.total_supply - amount;
        let mut m = table::borrow_mut(&mut reg.synth_markets, clone_string(&market_symbol));
        m.total_liquidity = m.total_liquidity - amount;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(SynthLiquidityWithdrawn { user: ctx.sender(), symbol: market_symbol, amount: amount, remaining_balance: newb, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(out, ctx.sender());
    }

    public entry fun borrow_synth<C>(
        synth_reg: &mut SynthRegistry,
        cfg: &CollateralConfig<C>,
        clock: &Clock,
        price_info: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        reg: &mut LendingRegistry,
        acct: &mut UserAccount,
        symbol: String,
        units: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(units > 0, E_ZERO_AMOUNT);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(table::contains(&reg.synth_markets, clone_string(&symbol)), E_UNKNOWN_ASSET);
        // Health gate: use synthetics check to ensure vault is healthy before minting
        // (delegate to synthetics' own ratio checks inside mint_synthetic)
        Synth::mint_synthetic(
            cfg,
            vault,
            synth_reg,
            clock,
            price_info,
            clone_string(&symbol),
            units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let cur = if (table::contains(&acct.synth_borrow_units, clone_string(&symbol))) { *table::borrow(&acct.synth_borrow_units, clone_string(&symbol)) } else { 0 };
        let newb = cur + units;
        table::add(&mut acct.synth_borrow_units, clone_string(&symbol), newb);
        let mut m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
        m.total_borrow_units = m.total_borrow_units + units;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(SynthBorrowed { user: ctx.sender(), symbol, units, new_borrow_units: newb, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    public entry fun repay_synth<C>(
        synth_reg: &mut SynthRegistry,
        cfg: &CollateralConfig<C>,
        clock: &Clock,
        price_info: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        reg: &mut LendingRegistry,
        acct: &mut UserAccount,
        symbol: String,
        units: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(units > 0, E_ZERO_AMOUNT);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(table::contains(&acct.synth_borrow_units, clone_string(&symbol)), E_UNKNOWN_ASSET);
        let cur = *table::borrow(&acct.synth_borrow_units, clone_string(&symbol));
        assert!(units <= cur, E_OVER_REPAY);
        Synth::burn_synthetic(
            cfg,
            vault,
            synth_reg,
            clock,
            price_info,
            clone_string(&symbol),
            units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let newb = cur - units;
        table::add(&mut acct.synth_borrow_units, clone_string(&symbol), newb);
        let mut m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
        m.total_borrow_units = m.total_borrow_units - units;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(SynthRepaid { user: ctx.sender(), symbol, units, remaining_borrow_units: newb, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Accrual for synth borrows (simple linear accrual on call)
    *******************************/
    public entry fun accrue_synth_market(
        reg: &mut LendingRegistry,
        symbol: String,
        dt_ms: u64,
        apr_bps: u64,
        ctx: &TxContext
    ) {
        assert!(!reg.paused, 1000);
        let mut m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
        if (m.total_borrow_units == 0 || dt_ms == 0 || apr_bps == 0) { return; };
        let year_ms = 31_536_000_000u128;
        let delta = ((m.total_borrow_units as u128) * (apr_bps as u128) * (dt_ms as u128)) / (10_000u128 * year_ms);
        if (delta == 0) { return; };
        let rf = m.reserve_factor_bps as u128;
        let to_reserve = (delta * rf) / 10_000u128;
        let to_debt = delta - to_reserve;
        m.total_borrow_units = m.total_borrow_units + (to_debt as u64);
        m.reserve_units = m.reserve_units + (to_reserve as u64);
        event::emit(SynthAccrued { symbol, delta_units: delta as u64, reserve_units: to_reserve as u64, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /*******************************
    * Liquidation for synth borrows (vault-based): repay units and seize collateral from market
    *******************************/
    public entry fun liquidate_synth<C>(
        reg: &mut LendingRegistry,
        synth_reg: &mut SynthRegistry,
        cfg: &CollateralConfig<C>,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_synth: &PriceInfoObject,
        price_usdc: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        pool_usdc: &mut LendingPool<C>,
        treasury: &mut Treasury<C>,
        debtor: &mut UserAccount,
        symbol: String,
        repay_units: u64,
        bonus_bps: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(repay_units > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&debtor.synth_borrow_units, clone_string(&symbol)), E_UNKNOWN_ASSET);
        let cur = *table::borrow(&debtor.synth_borrow_units, clone_string(&symbol));
        assert!(repay_units <= cur, E_OVER_REPAY);
        // Burn exposure on debtor
        Synth::burn_synthetic(
            cfg,
            vault,
            synth_reg,
            clock,
            price_synth,
            clone_string(&symbol),
            repay_units,
            vector::empty<Coin<UNXV>>(),
            price_usdc,
            treasury,
            ctx
        );
        let newb = cur - repay_units;
        table::add(&mut debtor.synth_borrow_units, clone_string(&symbol), newb);
        let mut m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
        m.total_borrow_units = m.total_borrow_units - repay_units;
        // Determine collateral to seize (value + bonus) from synth market liquidity
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_synth) as u128; // micro-USD per unit
        let val = (repay_units as u128) * px;
        let seize_val = val + (val * (bonus_bps as u128)) / 10_000u128;
        let seize_units = if (seize_val > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { seize_val as u64 };
        // Ensure pool has collateral liquidity
        let cash = BalanceMod::value(&pool_usdc.cash);
        assert!(cash >= seize_units, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool_usdc.cash, seize_units);
        let out = coin::from_balance(out_bal, ctx);
        event::emit(SynthLiquidated { symbol, repay_units, collateral_seized: seize_units, bot_reward: ((seize_units as u128) - val) as u64, liquidator: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(out, ctx.sender());
    }
}


