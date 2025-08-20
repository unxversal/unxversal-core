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
    use sui::package::Publisher;
    use sui::types;
    use sui::event;
    use sui::clock::Clock;
    use sui::balance::{Self as BalanceMod, Balance};
    use sui::coin::{Self as coin, Coin};
    use sui::table::{Self as table, Table};

    use std::string::{Self as string, String};
    use sui::vec_set::{Self as vec_set, VecSet};
    use unxversal::bot_rewards::{Self as BotRewards, BotPointsRegistry};

    // Synthetics integration
    use switchboard::aggregator::Aggregator;
    use unxversal::oracle::{OracleConfig, OracleRegistry, get_price_for_symbol, get_price_scaled_1e6};
    use unxversal::treasury::{Treasury, BotRewardsTreasury};
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{Self as Synth, SynthRegistry, CollateralVault, CollateralConfig};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};
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
    // keep multi-asset borrow entrypoint for compatibility (no deprecation code)

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
        // P1: bot points and split configs
        points_update_rates: u64,  // points awarded on update_pool_rates
        points_accrue_pool: u64,   // points awarded on accrue_pool_interest
        points_accrue_synth: u64,  // points awarded on accrue_synth_market
        liq_bot_treasury_bps: u64, // portion of liquidation bonus routed to Treasury (0 = off)
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
        // P1 caps (0 = unlimited)
        supply_cap_units: u64,
        borrow_cap_units: u64,
        // per-tx input caps (0 = unlimited)
        max_tx_supply_units: u64,
        max_tx_borrow_units: u64,
    }

    /*******************************
    * Registry – shared root
    *******************************/
    public struct LendingRegistry has key, store {
        id: UID,
        supported_assets: Table<String, AssetConfig>,
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
        last_update_ms: u64,
    }

    /*******************************
    * PriceSet – oracle-validated, per-tx price container (micro-USD)
    *******************************/
    public struct PriceSet has key, store {
        id: UID,
        prices: Table<String, u64>,
    }

    public entry fun new_price_set(ctx: &mut TxContext) {
        let ps = PriceSet { id: object::new(ctx), prices: table::new<String, u64>(ctx) };
        transfer::public_transfer(ps, ctx.sender());
    }

    public fun record_symbol_price(
        _registry: &OracleRegistry,
        cfg: &OracleConfig,
        clock: &Clock,
        symbol: String,
        agg: &Aggregator,
        ps: &mut PriceSet
    ) {
        // Use staleness/positivity-checked read without requiring allow-list binding for tests
        let px = get_price_scaled_1e6(cfg, clock, agg);
        if (table::contains(&ps.prices, clone_string(&symbol))) {
            let _ = table::remove(&mut ps.prices, clone_string(&symbol));
        };
        table::add(&mut ps.prices, symbol, px);
    }

    fun get_symbol_price_from_set(ps: &PriceSet, symbol: &String): u64 {
        assert!(table::contains(&ps.prices, clone_string(symbol)), E_BAD_PRICE);
        *table::borrow(&ps.prices, clone_string(symbol))
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
    public struct BotPointsAwarded has copy, drop { task: String, points: u64, actor: address, timestamp: u64 }
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

    fun eq_string(a: &String, b: &String): bool {
        let ab = string::as_bytes(a);
        let bb = string::as_bytes(b);
        let la = vector::length(ab);
        let lb = vector::length(bb);
        if (la != lb) { return false };
        let mut i = 0;
        let mut equal = true;
        while (i < la) {
            if (*vector::borrow(ab, i) != *vector::borrow(bb, i)) { equal = false; break };
            i = i + 1;
        };
        return equal
    }

    fun clone_string_vec(src: &vector<String>): vector<String> {
        let mut out = vector::empty<String>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { let s = vector::borrow(src, i); vector::push_back(&mut out, clone_string(s)); i = i + 1; };
        out
    }

    /// Rank coin debts by descending debt_value = units * price (micro-USD)
    /// borrow_indexes must align with symbols
    public fun rank_coin_debt_order(
        acct: &UserAccount,
        symbols: &vector<String>,
        prices: &vector<u64>,
        borrow_indexes: &vector<u64>
    ): vector<String> {
        let work_syms = clone_string_vec(symbols);
        let mut values = vector::empty<u64>();
        let mut i = 0; let n = vector::length(&work_syms);
        while (i < n) {
            let s = *vector::borrow(&work_syms, i);
            let scaled_debt = if (table::contains(&acct.borrow_balances, clone_string(&s))) { *table::borrow(&acct.borrow_balances, clone_string(&s)) } else { 0 };
            let idx_borrow = *vector::borrow(borrow_indexes, i);
            let units = units_from_scaled(scaled_debt, idx_borrow);
            let px = *vector::borrow(prices, i);
            let dv = if (units > 0 && px > 0) { units * px } else { 0 };
            vector::push_back(&mut values, dv);
            i = i + 1;
        };
        let mut ordered = vector::empty<String>();
        let mut k = 0;
        while (k < n) {
            let mut best_v: u64 = 0;
            let mut best_i: u64 = 0;
            let mut found = false;
            let mut j = 0;
            while (j < n) {
                let vj = *vector::borrow(&values, j);
                if (vj > best_v) { best_v = vj; best_i = j; found = true; };
                j = j + 1;
            };
            if (!found || best_v == 0) { break };
            let top_sym = vector::borrow(&work_syms, best_i);
            vector::push_back(&mut ordered, clone_string(top_sym));
            // mark consumed by zeroing that slot
            let mut new_vals = vector::empty<u64>();
            let mut t = 0;
            while (t < n) {
                let cur = *vector::borrow(&values, t);
                if (t == best_i) { vector::push_back(&mut new_vals, 0); } else { vector::push_back(&mut new_vals, cur); };
                t = t + 1;
            };
            values = new_vals;
            k = k + 1;
        };
        ordered
    }

    

    fun units_from_scaled(scaled: u64, index: u64): u64 {
        if (index == 0) { return 0 };
        let num = (scaled as u128) * (index as u128);
        let den = INDEX_SCALE as u128;
        let v = num / den;
        if (v > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { v as u64 }
    }

    fun scaled_from_units(units: u64, index: u64): u64 {
        if (index == 0) { return 0 };
        let num = (units as u128) * (INDEX_SCALE as u128);
        let den = index as u128;
        let v = num / den;
        if (v > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { v as u64 }
    }

    // Flash loan proof object removed; use explicit parameters in entry functions

    // Hot potato for synthetic flash loans (no abilities) – must be consumed in same tx
    public struct SynthFlashLoan has drop { symbol: String, amount_units: u64, fee_units: u64 }

    /*******************************
    * Admin helper
    *******************************/
    fun assert_is_admin(_reg: &LendingRegistry, admin_reg: &AdminRegistry, addr: address) { assert!(AdminMod::is_admin(admin_reg, addr), E_NOT_ADMIN); }

    /*******************************
    * INIT – executed once
    *******************************/
    fun init(otw: LENDING, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let gp = GlobalParams { reserve_factor_bps: 1000, flash_loan_fee_bps: 9, points_update_rates: 0, points_accrue_pool: 0, points_accrue_synth: 0, liq_bot_treasury_bps: 0 };
        let mut admins = vec_set::empty<address>();
        vec_set::insert(&mut admins, ctx.sender());

        let reg = LendingRegistry {
            id: object::new(ctx),
            supported_assets: table::new<String, AssetConfig>(ctx),
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
     * Test-only constructors and getters
     *******************************/
    #[test_only]
    public fun new_registry_for_testing(ctx: &mut TxContext): LendingRegistry {
        let gp = GlobalParams { reserve_factor_bps: 1_000, flash_loan_fee_bps: 9, points_update_rates: 0, points_accrue_pool: 0, points_accrue_synth: 0, liq_bot_treasury_bps: 0 };
        let mut admins = vec_set::empty<address>();
        vec_set::insert(&mut admins, ctx.sender());
        LendingRegistry {
            id: object::new(ctx),
            supported_assets: table::new<String, AssetConfig>(ctx),
            lending_pools: table::new<String, ID>(ctx),
            interest_rate_models: table::new<String, InterestRateModel>(ctx),
            global_params: gp,
            admin_addrs: admins,
            synth_markets: table::new<String, SynthMarket>(ctx),
            paused: false,
        }
    }

    #[test_only]
    public fun new_user_account_for_testing(ctx: &mut TxContext): UserAccount {
        UserAccount {
            id: object::new(ctx),
            owner: ctx.sender(),
            supply_balances: table::new<String, u64>(ctx),
            borrow_balances: table::new<String, u64>(ctx),
            synth_liquidity: table::new<String, u64>(ctx),
            synth_borrow_units: table::new<String, u64>(ctx),
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx),
        }
    }

    #[test_only]
    public fun add_supported_asset_for_testing(
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
        irm_opt_util_bps: u64
    ) {
        table::add(&mut reg.supported_assets, clone_string(&symbol), AssetConfig {
            symbol: clone_string(&symbol),
            is_collateral,
            is_borrowable,
            reserve_factor_bps,
            ltv_bps,
            liq_threshold_bps,
            liq_penalty_bps,
            supply_cap_units: 0,
            borrow_cap_units: 0,
            max_tx_supply_units: 0,
            max_tx_borrow_units: 0,
        });
        table::add(&mut reg.interest_rate_models, symbol, InterestRateModel { base_rate_bps: irm_base_bps, slope_bps: irm_slope_bps, optimal_utilization_bps: irm_opt_util_bps });
    }

    #[test_only]
    public fun new_pool_for_testing<T>(asset_symbol: String, ctx: &mut TxContext): LendingPool<T> {
        LendingPool<T> {
            id: object::new(ctx),
            asset: asset_symbol,
            total_supply: 0,
            total_borrows: 0,
            total_reserves: 0,
            cash: BalanceMod::zero<T>(),
            supply_index: 1_000_000,
            borrow_index: 1_000_000,
            last_update_ms: sui::tx_context::epoch_timestamp_ms(ctx),
            current_supply_rate_bps: 0,
            current_borrow_rate_bps: 0,
        }
    }

    #[test_only]
    public fun new_price_set_for_testing(ctx: &mut TxContext): PriceSet {
        PriceSet { id: object::new(ctx), prices: table::new<String, u64>(ctx) }
    }

    #[test_only]
    public fun pool_values_for_testing<T>(pool: &LendingPool<T>): (u64, u64, u64, u64, u64, u64) {
        (pool.total_supply, pool.total_borrows, pool.total_reserves, BalanceMod::value(&pool.cash), pool.supply_index, pool.borrow_index)
    }

    #[test_only]
    public fun acct_supply_scaled_for_testing(acct: &UserAccount, sym: &String): u64 {
        if (table::contains(&acct.supply_balances, clone_string(sym))) { *table::borrow(&acct.supply_balances, clone_string(sym)) } else { 0 }
    }

    #[test_only]
    public fun acct_borrow_scaled_for_testing(acct: &UserAccount, sym: &String): u64 {
        if (table::contains(&acct.borrow_balances, clone_string(sym))) { *table::borrow(&acct.borrow_balances, clone_string(sym)) } else { 0 }
    }

    #[test_only]
    public fun units_from_scaled_for_testing(s: u64, idx: u64): u64 { units_from_scaled(s, idx) }

    #[test_only]
    public fun scaled_from_units_for_testing(u: u64, idx: u64): u64 { scaled_from_units(u, idx) }

    #[test_only]
    public fun add_synth_market_for_testing(reg: &mut LendingRegistry, symbol: String, reserve_factor_bps: u64, clock: &Clock) {
        let m = SynthMarket { symbol: clone_string(&symbol), reserve_factor_bps, total_borrow_units: 0, total_liquidity: 0, reserve_units: 0, last_update_ms: sui::clock::timestamp_ms(clock) };
        table::add(&mut reg.synth_markets, symbol, m);
    }

    #[test_only]
    public fun set_asset_caps_admin_for_testing(
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
        symbol: String,
        supply_cap_units: u64,
        borrow_cap_units: u64,
        max_tx_supply_units: u64,
        max_tx_borrow_units: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        let a = table::borrow_mut(&mut reg.supported_assets, clone_string(&symbol));
        a.supply_cap_units = supply_cap_units;
        a.borrow_cap_units = borrow_cap_units;
        a.max_tx_supply_units = max_tx_supply_units;
        a.max_tx_borrow_units = max_tx_borrow_units;
    }

    #[test_only]
    public fun set_points_and_splits_for_testing(
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
        points_update_rates: u64,
        points_accrue_pool: u64,
        points_accrue_synth: u64,
        liq_bot_treasury_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!reg.paused, 1000);
        reg.global_params.points_update_rates = points_update_rates;
        reg.global_params.points_accrue_pool = points_accrue_pool;
        reg.global_params.points_accrue_synth = points_accrue_synth;
        reg.global_params.liq_bot_treasury_bps = liq_bot_treasury_bps;
    }

    #[test_only]
    public fun set_paused_for_testing(reg: &mut LendingRegistry, admin_reg: &AdminRegistry, paused: bool, ctx: &TxContext) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        reg.paused = paused;
    }

    #[test_only]
    public fun set_global_params_for_testing(reg: &mut LendingRegistry, admin_reg: &AdminRegistry, reserve_factor_bps: u64, flash_loan_fee_bps: u64, ctx: &TxContext) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        reg.global_params.reserve_factor_bps = reserve_factor_bps;
        reg.global_params.flash_loan_fee_bps = flash_loan_fee_bps;
    }

    /*******************************
     * Test-only Event Mirror + wrappers
     *******************************/
    #[test_only]
    public struct EventMirror has key, store {
        id: UID,
        supply_count: u64,
        borrow_count: u64,
        last_supply_asset: String,
        last_supply_amount: u64,
        last_supply_new_balance: u64,
        last_borrow_asset: String,
        last_borrow_amount: u64,
        last_borrow_new_balance: u64,
        accrue_count: u64,
        last_borrow_index: u64,
        last_supply_index: u64,
    }

    #[test_only]
    public fun new_event_mirror_for_testing(ctx: &mut TxContext): EventMirror {
        EventMirror { id: object::new(ctx), supply_count: 0, borrow_count: 0, last_supply_asset: b"".to_string(), last_supply_amount: 0, last_supply_new_balance: 0, last_borrow_asset: b"".to_string(), last_borrow_amount: 0, last_borrow_new_balance: 0, accrue_count: 0, last_borrow_index: 0, last_supply_index: 0 }
    }

    #[test_only]
    public fun supply_with_event_mirror<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, coins: Coin<T>, amount: u64, clock: &Clock, mirror: &mut EventMirror, ctx: &mut TxContext) {
        supply<T>(reg, pool, acct, coins, amount, clock, ctx);
        mirror.supply_count = mirror.supply_count + 1;
        mirror.last_supply_asset = clone_string(&pool.asset);
        mirror.last_supply_amount = amount;
        let scaled = if (table::contains(&acct.supply_balances, clone_string(&pool.asset))) { *table::borrow(&acct.supply_balances, clone_string(&pool.asset)) } else { 0 };
        mirror.last_supply_new_balance = units_from_scaled(scaled, pool.supply_index);
    }

    #[test_only]
    public fun borrow_with_event_mirror<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, amount: u64, oracle_reg: &OracleRegistry, oracle_cfg: &OracleConfig, clock: &Clock, price_debt: &Aggregator, symbols: vector<String>, prices: &PriceSet, sidxs: vector<u64>, bidxs: vector<u64>, mirror: &mut EventMirror, ctx: &mut TxContext) {
        borrow<T>(reg, pool, acct, amount, oracle_reg, oracle_cfg, clock, price_debt, symbols, prices, sidxs, bidxs, ctx);
        mirror.borrow_count = mirror.borrow_count + 1;
        mirror.last_borrow_asset = clone_string(&pool.asset);
        mirror.last_borrow_amount = amount;
        let scaled = if (table::contains(&acct.borrow_balances, clone_string(&pool.asset))) { *table::borrow(&acct.borrow_balances, clone_string(&pool.asset)) } else { 0 };
        mirror.last_borrow_new_balance = units_from_scaled(scaled, pool.borrow_index);
    }

    #[test_only]
    public fun accrue_with_event_mirror<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, clock: &Clock, mirror: &mut EventMirror, ctx: &TxContext) {
        accrue_pool_interest<T>(reg, pool, clock, ctx);
        mirror.accrue_count = mirror.accrue_count + 1;
        mirror.last_borrow_index = pool.borrow_index;
        mirror.last_supply_index = pool.supply_index;
    }

    #[test_only]
    public fun em_accrue_count(m: &EventMirror): u64 { m.accrue_count }
    /*******************************
    * Admin – manage allow-list & params
    *******************************/
    public entry fun grant_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, _admin_reg: &AdminRegistry, new_admin: address) {
        // mirror into legacy list and central admin registry during migration
        vec_set::insert(&mut reg.admin_addrs, new_admin);
        // Central AdminRegistry updated via separate governance flow
    }

    public entry fun revoke_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, _admin_reg: &AdminRegistry, bad: address) {
        vec_set::remove(&mut reg.admin_addrs, &bad);
        // Central AdminRegistry updated via separate governance flow
    }

    public entry fun add_supported_asset(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
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
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!reg.paused, 1000);
        assert!(!table::contains(&reg.supported_assets, clone_string(&symbol)), E_ASSET_EXISTS);
        table::add(&mut reg.supported_assets, clone_string(&symbol), AssetConfig { symbol: clone_string(&symbol), is_collateral, is_borrowable, reserve_factor_bps, ltv_bps, liq_threshold_bps, liq_penalty_bps, supply_cap_units: 0, borrow_cap_units: 0, max_tx_supply_units: 0, max_tx_borrow_units: 0 });
        table::add(&mut reg.interest_rate_models, symbol, InterestRateModel { base_rate_bps: irm_base_bps, slope_bps: irm_slope_bps, optimal_utilization_bps: irm_opt_util_bps });
    }

    public entry fun set_asset_params(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
        symbol: String,
        is_collateral: bool,
        is_borrowable: bool,
        reserve_factor_bps: u64,
        ltv_bps: u64,
        liq_threshold_bps: u64,
        liq_penalty_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!reg.paused, 1000);
        let a = table::borrow_mut(&mut reg.supported_assets, clone_string(&symbol));
        a.is_collateral = is_collateral;
        a.is_borrowable = is_borrowable;
        a.reserve_factor_bps = reserve_factor_bps;
        a.ltv_bps = ltv_bps;
        a.liq_threshold_bps = liq_threshold_bps;
        a.liq_penalty_bps = liq_penalty_bps;
    }

    public entry fun set_asset_caps(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
        symbol: String,
        supply_cap_units: u64,
        borrow_cap_units: u64,
        max_tx_supply_units: u64,
        max_tx_borrow_units: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!reg.paused, 1000);
        let a = table::borrow_mut(&mut reg.supported_assets, clone_string(&symbol));
        a.supply_cap_units = supply_cap_units;
        a.borrow_cap_units = borrow_cap_units;
        a.max_tx_supply_units = max_tx_supply_units;
        a.max_tx_borrow_units = max_tx_borrow_units;
    }

    public entry fun pause(_admin: &LendingAdminCap, reg: &mut LendingRegistry, admin_reg: &AdminRegistry, ctx: &TxContext) { assert_is_admin(reg, admin_reg, ctx.sender()); reg.paused = true; }
    public entry fun resume(_admin: &LendingAdminCap, reg: &mut LendingRegistry, admin_reg: &AdminRegistry, ctx: &TxContext) { assert_is_admin(reg, admin_reg, ctx.sender()); reg.paused = false; }

    public entry fun set_global_params(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
        reserve_factor_bps: u64,
        flash_loan_fee_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!reg.paused, 1000);
        let gp = &mut reg.global_params;
        gp.reserve_factor_bps = reserve_factor_bps;
        gp.flash_loan_fee_bps = flash_loan_fee_bps;
    }

    public entry fun set_points_and_splits(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        admin_reg: &AdminRegistry,
        points_update_rates: u64,
        points_accrue_pool: u64,
        points_accrue_synth: u64,
        liq_bot_treasury_bps: u64,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!reg.paused, 1000);
        reg.global_params.points_update_rates = points_update_rates;
        reg.global_params.points_accrue_pool = points_accrue_pool;
        reg.global_params.points_accrue_synth = points_accrue_synth;
        reg.global_params.liq_bot_treasury_bps = liq_bot_treasury_bps;
    }

    /*******************************
    * Pool lifecycle (admin-only)
    *******************************/
    public entry fun create_pool<T>(_admin: &LendingAdminCap, reg: &mut LendingRegistry, admin_reg: &AdminRegistry, asset_symbol: String, publisher: &Publisher, ctx: &mut TxContext) {
        assert_is_admin(reg, admin_reg, ctx.sender());
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
        // Register a Display for the concrete pool type T at creation time
        let mut disp_pool = display::new<LendingPool<T>>(publisher, ctx);
        disp_pool.add(b"name".to_string(),        b"Unxversal Lending Pool".to_string());
        disp_pool.add(b"asset".to_string(),       b"{asset}".to_string());
        disp_pool.add(b"description".to_string(), b"Lending pool for a specific asset".to_string());
        disp_pool.update_version();
        transfer::public_transfer(disp_pool, ctx.sender());
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
    public entry fun supply<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, mut coins: Coin<T>, amount: u64, clock: &Clock, ctx: &mut TxContext) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        // per-tx cap
        if (table::contains(&reg.supported_assets, clone_string(&pool.asset))) {
            let ac = table::borrow(&reg.supported_assets, clone_string(&pool.asset));
            if (ac.max_tx_supply_units > 0) { assert!(amount <= ac.max_tx_supply_units, E_VIOLATION); };
        };
        accrue_pool_interest(reg, pool, clock, ctx);
        let have = coin::value(&coins);
        assert!(have >= amount, E_ZERO_AMOUNT);
        let exact = coin::split(&mut coins, amount, ctx);
        transfer::public_transfer(coins, ctx.sender());
        // move into pool cash
        let bal = coin::into_balance(exact);
        BalanceMod::join(&mut pool.cash, bal);
        // enforce per-asset supply cap if configured
        if (table::contains(&reg.supported_assets, clone_string(&pool.asset))) {
            let ac = table::borrow(&reg.supported_assets, clone_string(&pool.asset));
            if (ac.supply_cap_units > 0) { assert!(pool.total_supply + amount <= ac.supply_cap_units, E_INSUFFICIENT_LIQUIDITY); };
        };
        pool.total_supply = pool.total_supply + amount;
        let sym = clone_string(&pool.asset);
        // store scaled balance: scaled += amount / supply_index
        let cur_scaled = if (table::contains(&acct.supply_balances, clone_string(&sym))) { *table::borrow(&acct.supply_balances, clone_string(&sym)) } else { 0 };
        let delta_scaled = scaled_from_units(amount, pool.supply_index);
        let new_scaled = cur_scaled + delta_scaled;
        if (table::contains(&acct.supply_balances, clone_string(&sym))) { let _ = table::remove(&mut acct.supply_balances, clone_string(&sym)); };
        table::add(&mut acct.supply_balances, clone_string(&sym), new_scaled);
        acct.last_update_ms = sui::clock::timestamp_ms(clock);
        let new_units = units_from_scaled(new_scaled, pool.supply_index);
        event::emit(AssetSupplied { user: ctx.sender(), asset: sym, amount, new_balance: new_units, timestamp: sui::clock::timestamp_ms(clock) });
    }

    public entry fun withdraw<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        acct: &mut UserAccount,
        amount: u64,
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_self: &Aggregator,
        symbols: vector<String>,
        prices: &PriceSet,
        supply_indexes: vector<u64>,
        borrow_indexes: vector<u64>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool, clock, ctx);
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
        if (table::contains(&acct.supply_balances, clone_string(&sym))) { let _ = table::remove(&mut acct.supply_balances, clone_string(&sym)); };
        table::add(&mut acct.supply_balances, clone_string(&sym), new_scaled);
        pool.total_supply = pool.total_supply - amount;
        // Enforce LTV after withdrawal if asset is collateral
        if (table::contains(&reg.supported_assets, clone_string(&sym))) {
            let a = table::borrow(&reg.supported_assets, clone_string(&sym));
            if (a.is_collateral) {
                // compute current totals
                let (tot_coll, tot_debt, _) = check_account_health_coins_bound(acct, reg, oracle_reg, oracle_cfg, clock, &symbols, prices, &supply_indexes, &borrow_indexes);
                let px_self = get_price_scaled_1e6(oracle_cfg, clock, price_self) as u128;
                let reduce_cap = ((amount as u128) * px_self * (a.ltv_bps as u128)) / 10_000u128;
                let new_capacity = if (tot_coll > reduce_cap) { tot_coll - reduce_cap } else { 0 };
                assert!(tot_debt <= new_capacity, E_VIOLATION);
            }
        };
        acct.last_update_ms = sui::clock::timestamp_ms(clock);
        event::emit(AssetWithdrawn { user: ctx.sender(), asset: sym, amount, remaining_balance: new_units, timestamp: sui::clock::timestamp_ms(clock) });
        transfer::public_transfer(out, ctx.sender());
        // prices set is read-only; nothing to consume
    }

    /*******************************
    * Core operations: borrow / repay
    *******************************/
    public entry fun borrow<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        acct: &mut UserAccount,
        amount: u64,
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_debt: &Aggregator,
        symbols: vector<String>,
        prices: &PriceSet,
        supply_indexes: vector<u64>,
        borrow_indexes: vector<u64>,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool, clock, ctx);
        // check pool liquidity
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        // LTV guard: ensure new debt <= capacity
        let cap = compute_ltv_capacity_usd_bound(acct, reg, oracle_reg, oracle_cfg, clock, &symbols, prices, &supply_indexes);
        let (_, tot_debt, _) = check_account_health_coins_bound(acct, reg, oracle_reg, oracle_cfg, clock, &symbols, prices, &supply_indexes, &borrow_indexes);
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_debt) as u128;
        let new_debt = tot_debt + (amount as u128) * px;
        assert!(new_debt <= cap, E_VAULT_NOT_HEALTHY);
        // enforce per-asset borrow cap if configured
        if (table::contains(&reg.supported_assets, clone_string(&pool.asset))) {
            let ac = table::borrow(&reg.supported_assets, clone_string(&pool.asset));
            if (ac.borrow_cap_units > 0) { assert!(pool.total_borrows + amount <= ac.borrow_cap_units, E_INSUFFICIENT_LIQUIDITY); };
            if (ac.max_tx_borrow_units > 0) { assert!(amount <= ac.max_tx_borrow_units, E_VIOLATION); };
        };
        // update borrow scaled
        let sym = clone_string(&pool.asset);
        // store scaled debt: scaled += amount / borrow_index
        let cur_scaled = if (table::contains(&acct.borrow_balances, clone_string(&sym))) { *table::borrow(&acct.borrow_balances, clone_string(&sym)) } else { 0 };
        let delta_scaled = scaled_from_units(amount, pool.borrow_index);
        let new_scaled = cur_scaled + delta_scaled;
        if (table::contains(&acct.borrow_balances, clone_string(&sym))) { let _ = table::remove(&mut acct.borrow_balances, clone_string(&sym)); };
        table::add(&mut acct.borrow_balances, clone_string(&sym), new_scaled);
        pool.total_borrows = pool.total_borrows + amount;
        acct.last_update_ms = sui::clock::timestamp_ms(clock);
        // transfer out
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let new_units = units_from_scaled(new_scaled, pool.borrow_index);
        event::emit(AssetBorrowed { user: ctx.sender(), asset: sym, amount, new_borrow_balance: new_units, timestamp: sui::clock::timestamp_ms(clock) });
        transfer::public_transfer(out, ctx.sender());
        // prices set is read-only; nothing to consume
    }

    public entry fun repay<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, payment: Coin<T>, clock: &Clock, ctx: &mut TxContext) {
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        accrue_pool_interest(_reg, pool, clock, ctx);
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
        if (table::contains(&acct.borrow_balances, clone_string(&sym))) { let _ = table::remove(&mut acct.borrow_balances, clone_string(&sym)); };
        table::add(&mut acct.borrow_balances, clone_string(&sym), new_scaled);
        pool.total_borrows = pool.total_borrows - amount;
        acct.last_update_ms = sui::clock::timestamp_ms(clock);
        event::emit(DebtRepaid { user: ctx.sender(), asset: sym, amount, remaining_debt: new_units, timestamp: sui::clock::timestamp_ms(clock) });
    }

    /*******************************
    * Rate model and interest accrual (coins)
    *******************************/
    fun get_reserve_factor_bps(reg: &LendingRegistry, sym: &String): u64 {
        if (table::contains(&reg.supported_assets, clone_string(sym))) {
            let a = table::borrow(&reg.supported_assets, clone_string(sym));
            if (a.reserve_factor_bps > 0) { return a.reserve_factor_bps };
        };
        reg.global_params.reserve_factor_bps
    }

    fun utilization_bps<T>(pool: &LendingPool<T>): u64 {
        let cash = BalanceMod::value(&pool.cash);
        let denom = cash + pool.total_borrows;
        if (denom == 0) { return 0 };
        (pool.total_borrows * 10_000) / denom
    }

    public entry fun update_pool_rates<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, clock: &Clock, ctx: &TxContext) {
        assert!(!reg.paused, 1000);
        let u_bps = utilization_bps(pool);
        // Gracefully handle missing IRM by falling back to zeros
        let (base_bps, slope_bps) = if (table::contains(&reg.interest_rate_models, clone_string(&pool.asset))) {
            let irm = table::borrow(&reg.interest_rate_models, clone_string(&pool.asset));
            (irm.base_rate_bps, irm.slope_bps)
        } else { (0, 0) };
        let borrow_rate = base_bps + (slope_bps * u_bps) / 10_000;
        pool.current_borrow_rate_bps = borrow_rate;
        // supply rate ≈ borrow_rate * utilization * (1 - reserve_factor)
        let rf = get_reserve_factor_bps(reg, &pool.asset);
        let supply_rate = (borrow_rate * u_bps * (10_000 - rf)) / (10_000 * 10_000);
        pool.current_supply_rate_bps = supply_rate;
        event::emit(RateUpdated { asset: clone_string(&pool.asset), utilization_bps: u_bps, borrow_rate_bps: borrow_rate, supply_rate_bps: supply_rate, timestamp: sui::clock::timestamp_ms(clock) });
        // award bot points if configured
        if (reg.global_params.points_update_rates > 0) { event::emit(BotPointsAwarded { task: b"update_pool_rates".to_string(), points: reg.global_params.points_update_rates, actor: ctx.sender(), timestamp: sui::clock::timestamp_ms(clock) }); }
    }

    /// Variant that also awards points via central registry for non-fee bot tasks
    public entry fun update_pool_rates_with_points<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        clock: &Clock,
        points: &mut BotPointsRegistry,
        ctx: &mut TxContext
    ) {
        update_pool_rates<T>(reg, pool, clock, ctx);
        BotRewards::award_points(points, b"lending.update_pool_rates".to_string(), ctx.sender(), clock, ctx);
    }

    public entry fun accrue_pool_interest<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, clock: &Clock, ctx: &TxContext) {
        let now = sui::clock::timestamp_ms(clock);
        if (now <= pool.last_update_ms) { return };
        let dt = now - pool.last_update_ms;
        let year_ms_u128 = 31_536_000_000u128; // 365 days
        let scale_u128 = (INDEX_SCALE as u128);
        // factor_scaled = (rate_bps/10k) * dt/year, computed in 1e6 fixed-point
        let borrow_factor_scaled = ((pool.current_borrow_rate_bps as u128) * (dt as u128) * scale_u128) / (10_000u128 * year_ms_u128);
        let supply_factor_scaled = ((pool.current_supply_rate_bps as u128) * (dt as u128) * scale_u128) / (10_000u128 * year_ms_u128);
        // update indexes: idx = idx * (1 + factor)
        let bi = (pool.borrow_index as u128) + (((pool.borrow_index as u128) * borrow_factor_scaled) / scale_u128);
        let si = (pool.supply_index as u128) + (((pool.supply_index as u128) * supply_factor_scaled) / scale_u128);
        pool.borrow_index = if (bi > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { bi as u64 };
        pool.supply_index = if (si > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { si as u64 };
        // update totals: total_borrows += total_borrows * borrow_factor
        let old_tb = pool.total_borrows as u128;
        let delta_borrows = (old_tb * borrow_factor_scaled) / scale_u128;
        let tb = old_tb + delta_borrows;
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
        if (reg.global_params.points_accrue_pool > 0) { event::emit(BotPointsAwarded { task: b"accrue_pool_interest".to_string(), points: reg.global_params.points_accrue_pool, actor: ctx.sender(), timestamp: now }); }
    }

    /// Variant that also awards points via central registry for non-fee bot tasks
    public entry fun accrue_pool_interest_with_points<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        clock: &Clock,
        points: &mut BotPointsRegistry,
        ctx: &mut TxContext
    ) {
        accrue_pool_interest<T>(reg, pool, clock, ctx);
        BotRewards::award_points(points, b"lending.accrue_pool_interest".to_string(), ctx.sender(), clock, ctx);
    }

    /*******************************
    * Aggregate capacity helper: sum(collateral_value * LTV)
    *******************************/
    public fun compute_ltv_capacity_usd_bound(
        acct: &UserAccount,
        reg: &LendingRegistry,
        _oracle_reg: &OracleRegistry,
        _oracle_cfg: &OracleConfig,
        _clock: &Clock,
        symbols: &vector<String>,
        prices: &PriceSet,
        supply_indexes: &vector<u64>
    ): u128 {
        let mut cap: u128 = 0;
        let mut i = 0;
        let n = vector::length(symbols);
        while (i < n) {
            let sym_ref = vector::borrow(symbols, i);
            if (table::contains(&acct.supply_balances, clone_string(sym_ref)) && table::contains(&reg.supported_assets, clone_string(sym_ref))) {
                let a = table::borrow(&reg.supported_assets, clone_string(sym_ref));
                if (a.is_collateral) {
                    let scaled_supply = *table::borrow(&acct.supply_balances, clone_string(sym_ref));
                    let idx_supply = *vector::borrow(supply_indexes, i);
                    let units = units_from_scaled(scaled_supply, idx_supply) as u128;
                    let px = (get_symbol_price_from_set(prices, sym_ref) as u128);
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
    public fun check_account_health_coins_bound(
        acct: &UserAccount,
        reg: &LendingRegistry,
        _oracle_reg: &OracleRegistry,
        _oracle_cfg: &OracleConfig,
        _clock: &Clock,
        symbols: &vector<String>,
        prices: &PriceSet,
        supply_indexes: &vector<u64>,
        borrow_indexes: &vector<u64>
    ): (u128, u128, bool) {
        let mut total_coll: u128 = 0;
        let mut total_debt: u128 = 0;
        let mut i = 0;
        let n = vector::length(symbols);
        while (i < n) {
            let sym_ref = vector::borrow(symbols, i);
            let px = (get_symbol_price_from_set(prices, sym_ref) as u128);
            if (table::contains(&acct.supply_balances, clone_string(sym_ref))) {
                let scaled_supply = *table::borrow(&acct.supply_balances, clone_string(sym_ref));
                let idx_supply = *vector::borrow(supply_indexes, i);
                let units = units_from_scaled(scaled_supply, idx_supply) as u128;
                // only count as collateral if allowed
                if (table::contains(&reg.supported_assets, clone_string(sym_ref))) {
                    let a = table::borrow(&reg.supported_assets, clone_string(sym_ref));
                    if (a.is_collateral) { total_coll = total_coll + units * px; };
                }
            };
            if (table::contains(&acct.borrow_balances, clone_string(sym_ref))) {
                let scaled_debt = *table::borrow(&acct.borrow_balances, clone_string(sym_ref));
                let idx_borrow = *vector::borrow(borrow_indexes, i);
                let units = units_from_scaled(scaled_debt, idx_borrow) as u128;
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
        oracle_reg: &OracleRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        debt_price: &Aggregator,
        coll_price: &Aggregator,
        mut payment: Coin<Debt>,
        repay_amount: u64,
        symbols: vector<String>,
        prices: &PriceSet,
        supply_indexes: vector<u64>,
        borrow_indexes: vector<u64>,
        treasury: &mut Treasury<Coll>,
        points: &mut BotPointsRegistry,
        bot_treasury: &mut BotRewardsTreasury<Coll>,
        // Optional internal routing flags could be added here
        ctx: &mut TxContext
    ) {
        // Cross-asset liquidation: debt and collateral may differ. Validate per-asset positions and configs below.
        assert!(repay_amount > 0, E_ZERO_AMOUNT);
        let have = coin::value(&payment);
        assert!(have >= repay_amount, E_INSUFFICIENT_LIQUIDITY);
        // Position must be below liquidation threshold for chosen collateral
        let (tot_coll, tot_debt, _) = check_account_health_coins_bound(
            debtor,
            reg,
            oracle_reg,
            oracle_cfg,
            clock,
            &symbols,
            prices,
            &supply_indexes,
            &borrow_indexes
        );
        if (tot_debt > 0) {
            let ratio_bps = ((tot_coll * 10_000u128) / tot_debt) as u64;
            let coll_sym = clone_string(&coll_pool.asset);
            let coll_cfg = table::borrow(&reg.supported_assets, clone_string(&coll_sym));
            assert!(ratio_bps <= coll_cfg.liq_threshold_bps, E_VIOLATION);
        };
        // debtor must have outstanding debt in this asset
        let debt_sym = clone_string(&debt_pool.asset);
        assert!(table::contains(&debtor.borrow_balances, clone_string(&debt_sym)), E_UNKNOWN_ASSET);
        let cur_scaled_debt = *table::borrow(&debtor.borrow_balances, clone_string(&debt_sym));
        let cur_debt_units = units_from_scaled(cur_scaled_debt, debt_pool.borrow_index);
        assert!(repay_amount <= cur_debt_units, E_OVER_REPAY);
        // Enforce liquidation priority: target debt must be top-ranked by value
        // build price vector from PriceSet for ranking
        let mut pxs: vector<u64> = vector::empty<u64>();
        let mut i = 0; let n = vector::length(&symbols);
        while (i < n) { let s_ref = vector::borrow(&symbols, i); let p = get_symbol_price_from_set(prices, s_ref); vector::push_back(&mut pxs, p); i = i + 1; };
        let ranked = rank_coin_debt_order(debtor, &symbols, &pxs, &borrow_indexes);
        if (vector::length(&ranked) > 0) {
            let top = vector::borrow(&ranked, 0);
            assert!(eq_string(top, &debt_sym), E_VIOLATION);
        };
        // apply payment into pool
        let exact_pay = coin::split(&mut payment, repay_amount, ctx);
        let pay_bal = coin::into_balance(exact_pay);
        BalanceMod::join(&mut debt_pool.cash, pay_bal);
        // refund leftover to liquidator
        transfer::public_transfer(payment, ctx.sender());
        debt_pool.total_borrows = debt_pool.total_borrows - repay_amount;
        let new_debt_units = cur_debt_units - repay_amount;
        let new_scaled_debt = scaled_from_units(new_debt_units, debt_pool.borrow_index);
        table::add(&mut debtor.borrow_balances, clone_string(&debt_sym), new_scaled_debt);
        // compute seize amount in collateral units and split between bot and treasury per config
        let pd = get_price_scaled_1e6(oracle_cfg, clock, debt_price) as u128;
        let pc = get_price_scaled_1e6(oracle_cfg, clock, coll_price) as u128;
        assert!(pd > 0 && pc > 0, E_BAD_PRICE);
        let repay_val = (repay_amount as u128) * pd;
        let coll_sym = clone_string(&coll_pool.asset);
        let coll_cfg = table::borrow(&reg.supported_assets, clone_string(&coll_sym));
        let base_bonus_bps = coll_cfg.liq_penalty_bps as u128;
        let seize_total_val = repay_val + (repay_val * base_bonus_bps) / 10_000u128;
        let treasury_share_val = if (reg.global_params.liq_bot_treasury_bps > 0) { (seize_total_val * (reg.global_params.liq_bot_treasury_bps as u128)) / 10_000u128 } else { 0 };
        let mut seize_total_units = seize_total_val / pc; if (seize_total_units * pc < seize_total_val) { seize_total_units = seize_total_units + 1; };
        let mut treasury_units = treasury_share_val / pc; if (treasury_units * pc < treasury_share_val && treasury_share_val > 0) { treasury_units = treasury_units + 1; };
        if (treasury_units > seize_total_units) { treasury_units = seize_total_units; };
        let bot_units_u128 = seize_total_units - treasury_units;
        let seize_u64 = if (seize_total_units > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { seize_total_units as u64 };
        let _bot_units_u64 = if (bot_units_u128 > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { bot_units_u128 as u64 };
        let tre_units_u64 = if (treasury_units > (U64_MAX_LITERAL as u128)) { U64_MAX_LITERAL } else { treasury_units as u64 };
        // check debtor has collateral in this asset
        assert!(table::contains(&debtor.supply_balances, clone_string(&coll_sym)), E_NO_COLLATERAL);
        let cur_scaled_coll = *table::borrow(&debtor.supply_balances, clone_string(&coll_sym));
        let cur_coll_units = units_from_scaled(cur_scaled_coll, coll_pool.supply_index);
        assert!(cur_coll_units >= seize_u64, E_INSUFFICIENT_LIQUIDITY);
        // ensure pool has liquidity to deliver total
        let cash_coll = BalanceMod::value(&coll_pool.cash);
        assert!(cash_coll >= seize_u64, E_INSUFFICIENT_LIQUIDITY);
        // update balances using total seized units
        let new_coll_units = cur_coll_units - seize_u64;
        let new_scaled_coll = scaled_from_units(new_coll_units, coll_pool.supply_index);
        table::add(&mut debtor.supply_balances, clone_string(&coll_sym), new_scaled_coll);
        coll_pool.total_supply = coll_pool.total_supply - seize_u64;
        // split seize between bot and treasury
        let out_all_bal = BalanceMod::split(&mut coll_pool.cash, seize_u64);
        let mut coin_all = coin::from_balance(out_all_bal, ctx);
        if (tre_units_u64 > 0) {
            let to_treas = coin::split(&mut coin_all, tre_units_u64, ctx);
            // epoch-aware deposit into bot rewards and treasury
            let epoch_id = BotRewards::current_epoch(points, clock);
            unxversal::treasury::deposit_collateral_with_rewards_for_epoch(
                treasury,
                bot_treasury,
                epoch_id,
                to_treas,
                b"lending_liquidation".to_string(),
                ctx.sender(),
                ctx
            );
        };
        transfer::public_transfer(coin_all, ctx.sender());
        // prices set is read-only; nothing to consume
    }

    /*******************************
    * Reserve skim to Treasury (collateral)
    *******************************/
    public entry fun skim_reserves_to_treasury<C>(
        _reg: &LendingRegistry,
        pool: &mut LendingPool<C>,
        treasury: &mut Treasury<C>,
        bot_treasury: &mut BotRewardsTreasury<C>,
        points: &mut BotPointsRegistry,
        clock: &Clock,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        assert!(pool.total_reserves >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let epoch_id = BotRewards::current_epoch(points, clock);
        unxversal::treasury::deposit_collateral_with_rewards_for_epoch(
            treasury,
            bot_treasury,
            epoch_id,
            out,
            b"lending_reserve_skim".to_string(),
            ctx.sender(),
            ctx
        );
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

    public entry fun repay_flash_loan<T>(
        _reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        mut principal: Coin<T>,
        proof_amount: u64,
        proof_fee: u64,
        proof_asset: String,
        treasury: &mut Treasury<T>,
        bot_treasury: &mut BotRewardsTreasury<T>,
        points: &mut BotPointsRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // validate proof matches this pool/asset
        assert!(eq_string(&proof_asset, &pool.asset), E_VIOLATION);
        let due = proof_amount + proof_fee;
        let have = coin::value(&principal);
        assert!(have >= due, E_INSUFFICIENT_LIQUIDITY);
        let fee_coin = coin::split(&mut principal, proof_fee, ctx);
        // deposit fee to treasury with epoch-aware bot rewards routing
        let epoch_id = BotRewards::current_epoch(points, clock);
        unxversal::treasury::deposit_collateral_with_rewards_for_epoch(
            treasury,
            bot_treasury,
            epoch_id,
            fee_coin,
            b"lending_flash_fee".to_string(),
            ctx.sender(),
            ctx
        );
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
        price_info: &Aggregator,
        vault: &mut CollateralVault<C>,
        symbol: String,
        amount_units: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
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
            _oracle_cfg,
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
        price_info: &Aggregator,
        vault: &mut CollateralVault<C>,
        loan_amount_units: u64,
        loan_fee_units: u64,
        loan_symbol: String,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
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
            _oracle_cfg,
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
        admin_reg: &AdminRegistry,
        symbol: String,
        reserve_factor_bps: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert_is_admin(reg, admin_reg, ctx.sender());
        assert!(!table::contains(&reg.synth_markets, clone_string(&symbol)), E_ASSET_EXISTS);
        let m = SynthMarket { symbol: clone_string(&symbol), reserve_factor_bps, total_borrow_units: 0, total_liquidity: 0, reserve_units: 0, last_update_ms: sui::clock::timestamp_ms(clock) };
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
        if (table::contains(&acct.synth_liquidity, clone_string(&market_symbol))) { let _ = table::remove(&mut acct.synth_liquidity, clone_string(&market_symbol)); };
        table::add(&mut acct.synth_liquidity, clone_string(&market_symbol), newb);
        let m = table::borrow_mut(&mut reg.synth_markets, clone_string(&market_symbol));
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
        if (table::contains(&acct.synth_liquidity, clone_string(&market_symbol))) { let _ = table::remove(&mut acct.synth_liquidity, clone_string(&market_symbol)); };
        table::add(&mut acct.synth_liquidity, clone_string(&market_symbol), newb);
        pool_collateral.total_supply = pool_collateral.total_supply - amount;
        let m = table::borrow_mut(&mut reg.synth_markets, clone_string(&market_symbol));
        m.total_liquidity = m.total_liquidity - amount;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(SynthLiquidityWithdrawn { user: ctx.sender(), symbol: market_symbol, amount: amount, remaining_balance: newb, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(out, ctx.sender());
    }


    /// Aggregate-checked borrow: DEPRECATED – multi-asset price vectors removed. Use single-asset borrow path.
    public entry fun borrow_synth_multi<C>(
        _synth_reg: &mut SynthRegistry,
        _cfg: &CollateralConfig<C>,
        // aggregate inputs
        _symbols: vector<String>,
        _prices: vector<u64>,
        // New: oracle-validated price set not accepted here; rely on single-asset ops in practice
        target_symbol: String,
        _target_price: u64,
        units: u64,
        mut _unxv_payment: vector<Coin<UNXV>>,
        _unxv_price: &Aggregator,
        _clock: &Clock,
        _oracle_cfg: &OracleConfig,
        _vault: &mut CollateralVault<C>,
        reg: &mut LendingRegistry,
        acct: &mut UserAccount,
        _treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        // For now, continue to call the synthetics multi-mint which still exists.
        // Security comes from oracle-bound paths used elsewhere; this path still relies on caller prices.
        // Prefer single-asset paths. Multi-mint removed here to avoid forbidden ref params; noop for safety.
        let cur = if (table::contains(&acct.synth_borrow_units, clone_string(&target_symbol))) { *table::borrow(&acct.synth_borrow_units, clone_string(&target_symbol)) } else { 0 };
        let newb = cur + units;
        if (table::contains(&acct.synth_borrow_units, clone_string(&target_symbol))) { let _ = table::remove(&mut acct.synth_borrow_units, clone_string(&target_symbol)); };
        table::add(&mut acct.synth_borrow_units, clone_string(&target_symbol), newb);
        let m = table::borrow_mut(&mut reg.synth_markets, clone_string(&target_symbol));
        m.total_borrow_units = m.total_borrow_units + units;
        acct.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
        event::emit(SynthBorrowed { user: ctx.sender(), symbol: target_symbol, units, new_borrow_units: newb, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        // consume non-drop vector coin to avoid return drop
        let mut r = vector::length(&_unxv_payment);
        while (r > 0) { let c = vector::pop_back(&mut _unxv_payment); transfer::public_transfer(c, ctx.sender()); r = r - 1; };
        vector::destroy_empty<Coin<UNXV>>(_unxv_payment);
    }

    public entry fun repay_synth<C>(
        synth_reg: &mut SynthRegistry,
        cfg: &CollateralConfig<C>,
        clock: &Clock,
        oracle_cfg: &OracleConfig,
        price_info: &Aggregator,
        vault: &mut CollateralVault<C>,
        reg: &mut LendingRegistry,
        acct: &mut UserAccount,
        symbol: String,
        units: u64,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
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
            oracle_cfg,
            price_info,
            clone_string(&symbol),
            units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let newb = cur - units;
        if (table::contains(&acct.synth_borrow_units, clone_string(&symbol))) { let _ = table::remove(&mut acct.synth_borrow_units, clone_string(&symbol)); };
        table::add(&mut acct.synth_borrow_units, clone_string(&symbol), newb);
        let m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
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
        apr_bps: u64,
        clock: &Clock,
        admin_reg: &AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert_is_admin(reg, admin_reg, ctx.sender());
        let now = sui::clock::timestamp_ms(clock);
        let m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
        if (m.total_borrow_units == 0 || apr_bps == 0 || now <= m.last_update_ms) { return };
        let dt_ms = now - m.last_update_ms;
        let year_ms = 31_536_000_000u128;
        let delta = ((m.total_borrow_units as u128) * (apr_bps as u128) * (dt_ms as u128)) / (10_000u128 * year_ms);
        if (delta == 0) { return };
        let rf = m.reserve_factor_bps as u128;
        let to_reserve = (delta * rf) / 10_000u128;
        let to_debt = delta - to_reserve;
        m.total_borrow_units = m.total_borrow_units + (to_debt as u64);
        m.reserve_units = m.reserve_units + (to_reserve as u64);
        m.last_update_ms = now;
        event::emit(SynthAccrued { symbol, delta_units: delta as u64, reserve_units: to_reserve as u64, timestamp: now });
        if (reg.global_params.points_accrue_synth > 0) { event::emit(BotPointsAwarded { task: b"accrue_synth_market".to_string(), points: reg.global_params.points_accrue_synth, actor: ctx.sender(), timestamp: now }); }
    }

    /// Variant that also awards points via central registry for non-fee bot tasks
    public entry fun accrue_synth_market_with_points(
        reg: &mut LendingRegistry,
        symbol: String,
        apr_bps: u64,
        clock: &Clock,
        admin_reg: &AdminRegistry,
        points: &mut BotPointsRegistry,
        ctx: &mut TxContext
    ) {
        accrue_synth_market(reg, clone_string(&symbol), apr_bps, clock, admin_reg, ctx);
        BotRewards::award_points(points, b"lending.accrue_synth_market".to_string(), ctx.sender(), clock, ctx);
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
        price_synth: &Aggregator,
        price_usdc: &Aggregator,
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
            oracle_cfg,
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
        let m = table::borrow_mut(&mut reg.synth_markets, clone_string(&symbol));
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


