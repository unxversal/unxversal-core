module unxversal::lending {
    use sui::display;
    use sui::object::{UID, ID};
    use sui::package::{Self, Publisher};
    use sui::types;
    use sui::event;
    use sui::clock::Clock;
    use sui::balance::{Self as BalanceMod, Balance};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use std::string::String;
    use sui::table::{Self as table, Table};
    use sui::vec_set::{Self as vec_set, VecSet};
    use std::vector;

    use unxversal::oracle::{PriceInfoObject, OracleConfig, get_price_scaled_1e6};
    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{Self as Synth, SynthRegistry, CollateralVault, CollateralConfig};

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
    const E_VIOLATION: u64 = 11;
    const E_VAULT_NOT_HEALTHY: u64 = 12;
    const E_SYMBOL_MISMATCH: u64 = 13;

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
        reserve_factor_bps: u64,
        flash_loan_fee_bps: u64,
    }

    #[allow(unused_field)]
    public struct InterestRateModel has store {
        base_rate_bps: u64,
        slope_bps: u64,
        optimal_utilization_bps: u64,
    }

    public struct AssetConfig has store {
        symbol: String,
        is_collateral: bool,
        is_borrowable: bool,
        reserve_factor_bps: u64,
        ltv_bps: u64,
        liq_threshold_bps: u64,
        liq_penalty_bps: u64,
    }

    /*******************************
    * Registry - shared root
    *******************************/
    public struct LendingRegistry has key, store {
        id: UID,
        supported_assets: Table<String, AssetConfig>,
        coin_oracle_feeds: Table<String, vector<u8>>,
        lending_pools: Table<String, ID>,
        interest_rate_models: Table<String, InterestRateModel>,
        global_params: GlobalParams,
        admin_addrs: VecSet<address>,
        synth_markets: Table<String, SynthMarket>,
        paused: bool,
    }

    public struct SynthMarket has key, store {
        id: UID,
        symbol: String,
        reserve_factor_bps: u64,
        total_borrow_units: u64,
        total_liquidity_usdc: u64,
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
    public struct SynthLiquidated has copy, drop { symbol: String, repay_units: u64, usdc_seized: u64, bot_reward: u64, liquidator: address, timestamp: u64 }
    public struct SynthLiquiditySupplied has copy, drop { user: address, symbol: String, amount_usdc: u64, new_balance_usdc: u64, timestamp: u64 }
    public struct SynthLiquidityWithdrawn has copy, drop { user: address, symbol: String, amount_usdc: u64, remaining_balance_usdc: u64, timestamp: u64 }
    public struct SynthBorrowed has copy, drop { user: address, symbol: String, units: u64, new_borrow_units: u64, timestamp: u64 }
    public struct SynthRepaid has copy, drop { user: address, symbol: String, units: u64, remaining_borrow_units: u64, timestamp: u64 }

    /*******************************
    * User account
    *******************************/
    public struct UserAccount has key, store {
        id: UID,
        owner: address,
        supply_balances: Table<String, u64>,
        borrow_balances: Table<String, u64>,
        synth_liquidity_usdc: Table<String, u64>,
        synth_borrow_units: Table<String, u64>,
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
        supply_index: u64,
        borrow_index: u64,
        last_update_ms: u64,
        current_supply_rate_bps: u64,
        current_borrow_rate_bps: u64,
    }

    const INDEX_SCALE: u64 = 1_000_000;

    fun units_from_scaled(scaled: u64, index: u64): u64 {
        if (index == 0) { return 0 };
        let num = (scaled as u128) * (index as u128);
        let den = INDEX_SCALE as u128;
        let v = num / den;
        if (v > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { v as u64 }
    }

    fun scaled_from_units(units: u64, index: u64): u64 {
        if (index == 0) { return 0 };
        let num = (units as u128) * (INDEX_SCALE as u128);
        let den = index as u128;
        let v = num / den;
        if (v > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { v as u64 }
    }

    public struct FlashLoan<phantom T> { amount: u64, fee: u64, asset: String }
    public struct SynthFlashLoan has drop { symbol: String, amount_units: u64, fee_units: u64 }

    fun assert_is_admin(synth_reg: &SynthRegistry, addr: address) { assert!(Synth::check_is_admin(synth_reg, addr), E_NOT_ADMIN); }

    fun init(otw: LENDING, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let gp = GlobalParams { reserve_factor_bps: 1000, flash_loan_fee_bps: 9 };
        let mut admins = vec_set::empty();
        vec_set::insert(&mut admins, tx_context::sender(ctx));

        let reg = LendingRegistry {
            id: sui::object::new(ctx),
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

        transfer::public_transfer(LendingDaddyCap { id: sui::object::new(ctx) }, tx_context::sender(ctx));
        transfer::public_transfer(LendingAdminCap { id: sui::object::new(ctx) }, tx_context::sender(ctx));

        let mut disp_reg = display::new<LendingRegistry>(&publisher, ctx);
        disp_reg.add(b"name".to_string(),        b"Unxversal Lending Registry".to_string());
        disp_reg.add(b"description".to_string(), b"Controls supported assets, pools, and risk parameters".to_string());
        disp_reg.update_version();
        transfer::public_transfer(disp_reg, tx_context::sender(ctx));

        transfer::public_transfer(publisher, tx_context::sender(ctx));
    }

    public entry fun grant_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, new_admin: address) {
        vec_set::insert(&mut reg.admin_addrs, new_admin);
    }

    public entry fun revoke_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, bad: address) {
        vec_set::remove(&mut reg.admin_addrs, &bad);
    }

    public fun add_supported_asset(_admin: &LendingAdminCap, reg: &mut LendingRegistry, synth_reg: &SynthRegistry, symbol: String, is_collateral: bool, is_borrowable: bool, reserve_factor_bps: u64, ltv_bps: u64, liq_threshold_bps: u64, liq_penalty_bps: u64, irm: InterestRateModel, ctx: &mut TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        assert!(!reg.paused, 1000);
        assert!(!table::contains(&reg.supported_assets, symbol), E_ASSET_EXISTS);
        table::add(&mut reg.supported_assets, symbol, AssetConfig { symbol, is_collateral, is_borrowable, reserve_factor_bps, ltv_bps, liq_threshold_bps, liq_penalty_bps });
        table::add(&mut reg.interest_rate_models, symbol, irm);
    }

    public entry fun set_asset_params(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        synth_reg: &SynthRegistry,
        symbol: String,
        is_collateral: bool,
        is_borrowable: bool,
        reserve_factor_bps: u64,
        ltv_bps: u64,
        liq_threshold_bps: u64,
        liq_penalty_bps: u64,
        ctx: &mut TxContext
    ) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        assert!(!reg.paused, 1000);
        let a = table::borrow_mut(&mut reg.supported_assets, symbol);
        a.is_collateral = is_collateral;
        a.is_borrowable = is_borrowable;
        a.reserve_factor_bps = reserve_factor_bps;
        a.ltv_bps = ltv_bps;
        a.liq_threshold_bps = liq_threshold_bps;
        a.liq_penalty_bps = liq_penalty_bps;
    }

    public entry fun pause(_admin: &LendingAdminCap, reg: &mut LendingRegistry, synth_reg: &SynthRegistry, ctx: &mut TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.paused = true; }
    public entry fun resume(_admin: &LendingAdminCap, reg: &mut LendingRegistry, synth_reg: &SynthRegistry, ctx: &mut TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); reg.paused = false; }
    public fun set_global_params(_admin: &LendingAdminCap, reg: &mut LendingRegistry, synth_reg: &SynthRegistry, gp: GlobalParams, ctx: &mut TxContext) { assert_is_admin(synth_reg, tx_context::sender(ctx)); assert!(!reg.paused, 1000); reg.global_params = gp; }

    public entry fun create_pool<T>(_admin: &LendingAdminCap, reg: &mut LendingRegistry, synth_reg: &SynthRegistry, asset_symbol: String, ctx: &mut TxContext) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        assert!(!reg.paused, 1000);
        assert!(table::contains(&reg.supported_assets, asset_symbol), E_UNKNOWN_ASSET);
        assert!(!table::contains(&reg.lending_pools, asset_symbol), E_POOL_EXISTS);
        let pool = LendingPool<T> {
            id: sui::object::new(ctx),
            asset: asset_symbol,
            total_supply: 0,
            total_borrows: 0,
            total_reserves: 0,
            cash: BalanceMod::zero<T>(),
            supply_index: 1_000_000,
            borrow_index: 1_000_000,
            last_update_ms: 0u64,
            current_supply_rate_bps: 0,
            current_borrow_rate_bps: 0,
        };
        let id = sui::object::id(&pool);
        transfer::share_object(pool);
        table::add(&mut reg.lending_pools, asset_symbol, id);
    }

    public entry fun open_account(ctx: &mut TxContext) {
        let acct = UserAccount {
            id: sui::object::new(ctx),
            owner: tx_context::sender(ctx),
            supply_balances: table::new<String, u64>(ctx),
            borrow_balances: table::new<String, u64>(ctx),
            synth_liquidity_usdc: table::new<String, u64>(ctx),
            synth_borrow_units: table::new<String, u64>(ctx),
            last_update_ms: 0u64
        };
        transfer::share_object(acct);
    }

    public fun supply<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, mut coins: Coin<T>, amount: u64, ctx: &mut TxContext) {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool);
        let have = coins.value();
        assert!(have >= amount, E_ZERO_AMOUNT);
        let exact = coins.split(amount, ctx);
        transfer::public_transfer(coins, tx_context::sender(ctx));
        let bal = coin::into_balance(exact);
        BalanceMod::join(&mut pool.cash, bal);
        pool.total_supply = pool.total_supply + amount;
        let sym = &pool.asset;
        let cur_scaled = if (table::contains(&acct.supply_balances, *sym)) { *table::borrow(&acct.supply_balances, *sym) } else { 0 };
        let delta_scaled = scaled_from_units(amount, pool.supply_index);
        let new_scaled = cur_scaled + delta_scaled;
        table::add(&mut acct.supply_balances, *sym, new_scaled);
        acct.last_update_ms = 0u64;
        let new_units = units_from_scaled(new_scaled, pool.supply_index);
        event::emit(AssetSupplied { user: tx_context::sender(ctx), asset: *sym, amount, new_balance: new_units, timestamp: 0u64 });
    }

    public fun withdraw<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        acct: &mut UserAccount,
        amount: u64,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_self: &PriceInfoObject,
        symbols: &vector<String>,
        prices: &vector<PriceInfoObject>,
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool);
        let sym = &pool.asset;
        assert!(table::contains(&acct.supply_balances, *sym), E_UNKNOWN_ASSET);
        let cur_scaled = *table::borrow(&acct.supply_balances, *sym);
        let cur_units = units_from_scaled(cur_scaled, pool.supply_index);
        assert!(cur_units >= amount, E_ZERO_AMOUNT);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let new_units = cur_units - amount;
        let new_scaled = scaled_from_units(new_units, pool.supply_index);
        table::add(&mut acct.supply_balances, *sym, new_scaled);
        pool.total_supply = pool.total_supply - amount;
        if (table::contains(&reg.supported_assets, *sym)) {
            let a = table::borrow(&reg.supported_assets, *sym);
            if (a.is_collateral) {
                let (tot_coll, tot_debt, _) = check_account_health_coins(acct, reg, oracle_cfg, clock, symbols, prices);
                let px_self = get_price_scaled_1e6(oracle_cfg, clock, price_self) as u128;
                let reduce_cap = ((amount as u128) * px_self * (a.ltv_bps as u128)) / 10_000u128;
                let new_capacity = if (tot_coll > reduce_cap) { tot_coll - reduce_cap } else { 0 };
                assert!(tot_debt <= new_capacity, E_VIOLATION);
            }
        };

        acct.last_update_ms = 0u64;
        event::emit(AssetWithdrawn { user: tx_context::sender(ctx), asset: *sym, amount, remaining_balance: new_units, timestamp: 0u64 });
        out
    }

    public fun borrow<T>(
        reg: &LendingRegistry,
        pool: &mut LendingPool<T>,
        acct: &mut UserAccount,
        amount: u64,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_debt: &PriceInfoObject,
        symbols: &vector<String>,
        prices: &vector<PriceInfoObject>,
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(!reg.paused, 1000);
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        accrue_pool_interest(reg, pool);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);

        let (_, total_debt, _) = check_account_health_coins(acct, reg, oracle_cfg, clock, symbols, prices);
        let cap = compute_ltv_capacity_usd(acct, reg, oracle_cfg, clock, symbols, prices);
        
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_debt) as u128;
        let new_debt = total_debt + (amount as u128) * px;
        assert!(new_debt <= cap, E_VAULT_NOT_HEALTHY);
        
        let sym = &pool.asset;
        let cur_scaled = if (table::contains(&acct.borrow_balances, *sym)) { *table::borrow(&acct.borrow_balances, *sym) } else { 0 };
        let delta_scaled = scaled_from_units(amount, pool.borrow_index);
        let new_scaled = cur_scaled + delta_scaled;
        table::add(&mut acct.borrow_balances, *sym, new_scaled);
        pool.total_borrows = pool.total_borrows + amount;
        acct.last_update_ms = 0u64;
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let new_units = units_from_scaled(new_scaled, pool.borrow_index);
        event::emit(AssetBorrowed { user: tx_context::sender(ctx), asset: *sym, amount, new_borrow_balance: new_units, timestamp: 0u64 });
        out
    }

    public fun repay<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, payment: Coin<T>, ctx: &mut TxContext) {
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        accrue_pool_interest(_reg, pool);
        let amount = payment.value();
        assert!(amount > 0, E_ZERO_AMOUNT);
        let sym = &pool.asset;
        assert!(table::contains(&acct.borrow_balances, *sym), E_UNKNOWN_ASSET);
        let cur_scaled = *table::borrow(&acct.borrow_balances, *sym);
        let cur_units = units_from_scaled(cur_scaled, pool.borrow_index);
        assert!(amount <= cur_units, E_OVER_REPAY);
        let bal = coin::into_balance(payment);
        BalanceMod::join(&mut pool.cash, bal);
        let new_units = cur_units - amount;
        let new_scaled = scaled_from_units(new_units, pool.borrow_index);
        table::add(&mut acct.borrow_balances, *sym, new_scaled);
        pool.total_borrows = pool.total_borrows - amount;
        acct.last_update_ms = 0u64;
        event::emit(DebtRepaid { user: tx_context::sender(ctx), asset: *sym, amount, remaining_debt: new_units, timestamp: 0u64 });
    }

    fun get_reserve_factor_bps(reg: &LendingRegistry, sym: String): u64 {
        if (table::contains(&reg.supported_assets, sym)) {
            let a = table::borrow(&reg.supported_assets, sym);
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

    public entry fun update_pool_rates<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>) {
        assert!(!reg.paused, 1000);
        let u_bps = utilization_bps(pool);
        let irm = table::borrow(&reg.interest_rate_models, pool.asset);
        let borrow_rate = irm.base_rate_bps + (irm.slope_bps * u_bps) / 10_000;
        pool.current_borrow_rate_bps = borrow_rate;
        let rf = get_reserve_factor_bps(reg, pool.asset);
        let supply_rate = (borrow_rate * u_bps * (10_000 - rf)) / (10_000 * 10_000);
        pool.current_supply_rate_bps = supply_rate;
        event::emit(RateUpdated { asset: pool.asset, utilization_bps: u_bps, borrow_rate_bps: borrow_rate, supply_rate_bps: supply_rate, timestamp: 0u64 });
    }

    public entry fun accrue_pool_interest<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>) {
        let now = 0u64;
        if (now <= pool.last_update_ms) { return };
        let dt = now - pool.last_update_ms;
        let year_ms = 31_536_000_000;
        let borrow_factor = (pool.current_borrow_rate_bps as u128) * (dt as u128) / (10_000u128 * (year_ms as u128));
        let supply_factor = (pool.current_supply_rate_bps as u128) * (dt as u128) / (10_000u128 * (year_ms as u128));
        let bi = (pool.borrow_index as u128) + ((pool.borrow_index as u128) * borrow_factor);
        let si = (pool.supply_index as u128) + ((pool.supply_index as u128) * supply_factor);
        pool.borrow_index = if (bi > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { bi as u64 };
        pool.supply_index = if (si > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { si as u64 };
        let old_tb = pool.total_borrows as u128;
        let tb = old_tb + (old_tb * borrow_factor);
        let delta_borrows = if (tb > old_tb) { tb - old_tb } else { 0 };
        let rf_bps = get_reserve_factor_bps(reg, pool.asset) as u128;
        let reserves_added = (delta_borrows * rf_bps) / 10_000u128;
        pool.total_borrows = if (tb > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { tb as u64 };
        if (reserves_added > 0) {
            let add = if (reserves_added > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { reserves_added as u64 };
            pool.total_reserves = pool.total_reserves + add;
        };
        pool.last_update_ms = now;
        let emitted_delta = if (delta_borrows > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { delta_borrows as u64 };
        let emitted_res = if (reserves_added > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { reserves_added as u64 };
        event::emit(InterestAccrued { asset: pool.asset, dt_ms: dt, new_borrow_index: pool.borrow_index, new_supply_index: pool.supply_index, delta_borrows: emitted_delta, reserves_added: emitted_res, timestamp: now });
    }

    public fun compute_ltv_capacity_usd(
        acct: &UserAccount,
        reg: &LendingRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        symbols: &vector<String>,
        prices: &vector<PriceInfoObject>
    ): u128 {
        let mut cap: u128 = 0;
        let mut i = 0;
        while (i < vector::length(symbols)) {
            let sym = vector::borrow(symbols, i);
            if (table::contains(&acct.supply_balances, *sym) && table::contains(&reg.supported_assets, *sym)) {
                let a = table::borrow(&reg.supported_assets, *sym);
                if (a.is_collateral) {
                    let units = *table::borrow(&acct.supply_balances, *sym) as u128;
                    let p = vector::borrow(prices, i);
                    let px = get_price_scaled_1e6(oracle_cfg, clock, p) as u128;
                    cap = cap + (units * px * (a.ltv_bps as u128)) / 10_000u128;
                }
            };
            i = i + 1;
        };
        cap
    }

    public fun check_account_health_coins(
        acct: &UserAccount,
        reg: &LendingRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        symbols: &vector<String>,
        prices: &vector<PriceInfoObject>
    ): (u128, u128, bool) {
        let mut total_coll: u128 = 0;
        let mut total_debt: u128 = 0;
        let mut i = 0;
        while (i < vector::length(symbols)) {
            let sym = vector::borrow(symbols, i);
            let p = vector::borrow(prices, i);
            let px = get_price_scaled_1e6(oracle_cfg, clock, p) as u128;
            if (table::contains(&acct.supply_balances, *sym)) {
                let units = *table::borrow(&acct.supply_balances, *sym) as u128;
                if (table::contains(&reg.supported_assets, *sym)) {
                    let a = table::borrow(&reg.supported_assets, *sym);
                    if (a.is_collateral) { total_coll = total_coll + units * px; };
                }
            };
            if (table::contains(&acct.borrow_balances, *sym)) {
                let units = *table::borrow(&acct.borrow_balances, *sym) as u128;
                total_debt = total_debt + units * px;
            };
            i = i + 1;
        };
        (total_coll, total_debt, total_coll >= total_debt)
    }

    public fun list_supported_assets(_reg: &LendingRegistry): vector<String> { vector::empty<String>() }
    public fun get_asset_config(reg: &LendingRegistry, symbol: String): &AssetConfig { table::borrow(&reg.supported_assets, symbol) }
    public fun list_pools(_reg: &LendingRegistry): vector<String> { vector::empty<String>() }
    public fun get_coin_oracle_feed(reg: &LendingRegistry, symbol: String): vector<u8> {
        if (table::contains(&reg.coin_oracle_feeds, symbol)) { *table::borrow(&reg.coin_oracle_feeds, symbol) } else { vector::empty<u8>() }
    }
    public fun list_coin_oracle_feeds(_reg: &LendingRegistry): vector<String> {
        vector::empty<String>()
    }
    public fun protocol_metrics(_reg: &LendingRegistry): (u128, u128, u128) {
        (0, 0, 0)
    }

    public fun liquidate_coin_position<Debt, Coll>(
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
        ctx: &mut TxContext
    ): Coin<Coll> {
        assert!(debt_pool.asset == coll_pool.asset, E_SYMBOL_MISMATCH);
        assert!(repay_amount > 0, E_ZERO_AMOUNT);
        let have = payment.value();
        assert!(have >= repay_amount, E_INSUFFICIENT_LIQUIDITY);

        let empty_symbols = vector::empty<String>();
        let empty_prices = vector::empty<PriceInfoObject>();
        
        let (tot_coll, tot_debt, _) = check_account_health_coins(debtor, reg, oracle_cfg, clock, &empty_symbols, &empty_prices);
        
        vector::destroy_empty(empty_symbols);
        vector::destroy_empty(empty_prices);

        if (tot_debt > 0) {
            let ratio_bps = ((tot_coll * 10_000u128) / tot_debt) as u64;
            let coll_sym = &coll_pool.asset;
            let coll_cfg = table::borrow(&reg.supported_assets, *coll_sym);
            assert!(ratio_bps < coll_cfg.liq_threshold_bps, E_VIOLATION);
        };
        
        let debt_sym = &debt_pool.asset;
        assert!(table::contains(&debtor.borrow_balances, *debt_sym), E_UNKNOWN_ASSET);
        let cur_debt_scaled = *table::borrow(&debtor.borrow_balances, *debt_sym);
        let cur_debt_units = units_from_scaled(cur_debt_scaled, debt_pool.borrow_index);
        assert!(repay_amount <= cur_debt_units, E_OVER_REPAY);
        
        let exact_pay = payment.split(repay_amount, ctx);
        transfer::public_transfer(payment, tx_context::sender(ctx));

        let pay_bal = coin::into_balance(exact_pay);
        BalanceMod::join(&mut debt_pool.cash, pay_bal);
        
        debt_pool.total_borrows = debt_pool.total_borrows - repay_amount;
        let new_debt_units = cur_debt_units - repay_amount;
        let new_debt_scaled = scaled_from_units(new_debt_units, debt_pool.borrow_index);
        table::add(&mut debtor.borrow_balances, *debt_sym, new_debt_scaled);
        
        let pd = get_price_scaled_1e6(oracle_cfg, clock, debt_price) as u128;
        let pc = get_price_scaled_1e6(oracle_cfg, clock, coll_price) as u128;
        assert!(pd > 0 && pc > 0, E_BAD_PRICE);
        let repay_val = (repay_amount as u128) * pd;
        let coll_sym = &coll_pool.asset;
        let coll_cfg = table::borrow(&reg.supported_assets, *coll_sym);
        let bonus_bps = coll_cfg.liq_penalty_bps as u128;
        let seize_val = repay_val + (repay_val * bonus_bps) / 10_000u128;
        let mut seize_units = seize_val / pc;
        if (seize_units * pc < seize_val) { seize_units = seize_units + 1; };
        let seize_u64 = if (seize_units > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { seize_units as u64 };
        
        assert!(table::contains(&debtor.supply_balances, *coll_sym), E_NO_COLLATERAL);
        let cur_coll_scaled = *table::borrow(&debtor.supply_balances, *coll_sym);
        let cur_coll_units = units_from_scaled(cur_coll_scaled, coll_pool.supply_index);
        assert!(cur_coll_units >= seize_u64, E_INSUFFICIENT_LIQUIDITY);
        
        let cash_coll = BalanceMod::value(&coll_pool.cash);
        assert!(cash_coll >= seize_u64, E_INSUFFICIENT_LIQUIDITY);
        
        let new_coll_units = cur_coll_units - seize_u64;
        let new_coll_scaled = scaled_from_units(new_coll_units, coll_pool.supply_index);
        table::add(&mut debtor.supply_balances, *coll_sym, new_coll_scaled);
        coll_pool.total_supply = coll_pool.total_supply - seize_u64;
        
        let out_bal = BalanceMod::split(&mut coll_pool.cash, seize_u64);
        coin::from_balance(out_bal, ctx)
    }

    public entry fun skim_reserves_to_treasury<C>(
        _cfg: &CollateralConfig<C>,
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
        transfer::public_transfer(out, TreasuryMod::treasury_address(treasury));
        pool.total_reserves = pool.total_reserves - amount;
    }

    public fun initiate_flash_loan<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, amount: u64, ctx: &mut TxContext): (Coin<T>, FlashLoan<T>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let fee = (amount * reg.global_params.flash_loan_fee_bps) / 10_000;
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        event::emit(FlashLoanInitiated { asset: pool.asset, amount, fee, borrower: tx_context::sender(ctx), timestamp: 0u64 });
        (out, FlashLoan<T> { amount, fee, asset: pool.asset })
    }

    public fun repay_flash_loan<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, mut principal: Coin<T>, proof: FlashLoan<T>, ctx: &mut TxContext) {
        let FlashLoan { amount: proof_amount, fee: proof_fee, asset: proof_asset } = proof;
        let due = proof_amount + proof_fee;
        let have = principal.value();
        assert!(have >= due, E_INSUFFICIENT_LIQUIDITY);
        let fee_coin = principal.split(proof_fee, ctx);
        
        let fee_bal = coin::into_balance(fee_coin);
        BalanceMod::join(&mut pool.cash, fee_bal);
        pool.total_reserves = pool.total_reserves + proof_fee;
        
        let principal_bal = coin::into_balance(principal);
        BalanceMod::join(&mut pool.cash, principal_bal);
        event::emit(FlashLoanRepaid { asset: proof_asset, amount: proof_amount, fee: proof_fee, repayer: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun initiate_synth_flash_loan<C>(
        reg: &LendingRegistry,
        synth_reg: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
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
        Synth::mint_synthetic(
            vault,
            synth_reg,
            oracle_cfg,
            clock,
            price_info,
            &symbol,
            amount_units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let fee_units = (amount_units * reg.global_params.flash_loan_fee_bps) / 10_000;
        event::emit(SynthFlashLoanInitiated { symbol, amount_units, fee_units, borrower: tx_context::sender(ctx), timestamp: 0u64 });
        SynthFlashLoan { symbol, amount_units, fee_units }
    }

    public fun repay_synth_flash_loan<C>(
        _reg: &LendingRegistry,
        synth_reg: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        loan: SynthFlashLoan,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        let SynthFlashLoan { symbol, amount_units, fee_units } = loan;
        let total_burn = amount_units + fee_units;
        Synth::burn_synthetic(
            vault,
            synth_reg,
            oracle_cfg,
            clock,
            price_info,
            &symbol,
            total_burn,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        event::emit(SynthFlashLoanRepaid { symbol, amount_units, fee_units, repayer: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun create_synth_market(
        _admin: &LendingAdminCap,
        reg: &mut LendingRegistry,
        synth_reg: &SynthRegistry,
        symbol: String,
        reserve_factor_bps: u64,
        ctx: &mut TxContext
    ) {
        assert_is_admin(synth_reg, tx_context::sender(ctx));
        assert!(!table::contains(&reg.synth_markets, symbol), E_ASSET_EXISTS);
        let m = SynthMarket { id: sui::object::new(ctx), symbol, reserve_factor_bps, total_borrow_units: 0, total_liquidity_usdc: 0, reserve_units: 0 };
        table::add(&mut reg.synth_markets, symbol, m);
    }

    public entry fun supply_synth_liquidity<C>(
        _cfg: &CollateralConfig<C>,
        reg: &mut LendingRegistry,
        market_symbol: &String,
        pool: &mut LendingPool<C>,
        acct: &mut UserAccount,
        mut collateral: Coin<C>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(!reg.paused, 1000);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&reg.synth_markets, *market_symbol), E_UNKNOWN_ASSET);
        let have = collateral.value();
        assert!(have >= amount, E_ZERO_AMOUNT);
        
        let exact = collateral.split(amount, ctx);
        transfer::public_transfer(collateral, tx_context::sender(ctx));

        let bal = coin::into_balance(exact);
        BalanceMod::join(&mut pool.cash, bal);
        pool.total_supply = pool.total_supply + amount;
        let cur = if (table::contains(&acct.synth_liquidity_usdc, *market_symbol)) { *table::borrow(&acct.synth_liquidity_usdc, *market_symbol) } else { 0 };
        let newb = cur + amount;
        table::add(&mut acct.synth_liquidity_usdc, *market_symbol, newb);
        let m = table::borrow_mut(&mut reg.synth_markets, *market_symbol);
        m.total_liquidity_usdc = m.total_liquidity_usdc + amount;
        acct.last_update_ms = 0u64;
        event::emit(SynthLiquiditySupplied { user: tx_context::sender(ctx), symbol: *market_symbol, amount_usdc: amount, new_balance_usdc: newb, timestamp: 0u64 });
    }

    public fun withdraw_synth_liquidity<C>(
        _cfg: &CollateralConfig<C>,
        reg: &mut LendingRegistry,
        market_symbol: &String,
        pool: &mut LendingPool<C>,
        acct: &mut UserAccount,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!reg.paused, 1000);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(table::contains(&acct.synth_liquidity_usdc, *market_symbol), E_UNKNOWN_ASSET);
        let cur = *table::borrow(&acct.synth_liquidity_usdc, *market_symbol);
        assert!(cur >= amount, E_INSUFFICIENT_LIQUIDITY);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = coin::from_balance(out_bal, ctx);
        let newb = cur - amount;
        table::add(&mut acct.synth_liquidity_usdc, *market_symbol, newb);
        pool.total_supply = pool.total_supply - amount;
        let m = table::borrow_mut(&mut reg.synth_markets, *market_symbol);
        m.total_liquidity_usdc = m.total_liquidity_usdc - amount;
        acct.last_update_ms = 0u64;
        event::emit(SynthLiquidityWithdrawn { user: tx_context::sender(ctx), symbol: *market_symbol, amount_usdc: amount, remaining_balance_usdc: newb, timestamp: 0u64 });
        out
    }

    public entry fun borrow_synth<C>(
        synth_reg: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
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
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(table::contains(&reg.synth_markets, symbol), E_UNKNOWN_ASSET);
        Synth::mint_synthetic(
            vault,
            synth_reg,
            oracle_cfg,
            clock,
            price_info,
            &symbol,
            units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let cur = if (table::contains(&acct.synth_borrow_units, symbol)) { *table::borrow(&acct.synth_borrow_units, symbol) } else { 0 };
        let newb = cur + units;
        table::add(&mut acct.synth_borrow_units, symbol, newb);
        let m = table::borrow_mut(&mut reg.synth_markets, symbol);
        m.total_borrow_units = m.total_borrow_units + units;
        acct.last_update_ms = 0u64;
        event::emit(SynthBorrowed { user: tx_context::sender(ctx), symbol, units, new_borrow_units: newb, timestamp: 0u64 });
    }

    public entry fun repay_synth<C>(
        synth_reg: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
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
        assert!(acct.owner == tx_context::sender(ctx), E_NOT_OWNER);
        assert!(table::contains(&acct.synth_borrow_units, symbol), E_UNKNOWN_ASSET);
        let cur = *table::borrow(&acct.synth_borrow_units, symbol);
        assert!(units <= cur, E_OVER_REPAY);
        Synth::burn_synthetic(
            vault,
            synth_reg,
            oracle_cfg,
            clock,
            price_info,
            &symbol,
            units,
            unxv_payment,
            unxv_price,
            treasury,
            ctx
        );
        let newb = cur - units;
        table::add(&mut acct.synth_borrow_units, symbol, newb);
        let m = table::borrow_mut(&mut reg.synth_markets, symbol);
        m.total_borrow_units = m.total_borrow_units - units;
        acct.last_update_ms = 0u64;
        event::emit(SynthRepaid { user: tx_context::sender(ctx), symbol, units, remaining_borrow_units: newb, timestamp: 0u64 });
    }

    public entry fun accrue_synth_market(
        reg: &mut LendingRegistry,
        symbol: String,
        dt_ms: u64,
        apr_bps: u64
    ) {
        assert!(!reg.paused, 1000);
        let m = table::borrow_mut(&mut reg.synth_markets, symbol);
        if (m.total_borrow_units == 0 || dt_ms == 0 || apr_bps == 0) { return };
        let year_ms = 31_536_000_000u128;
        let delta = ((m.total_borrow_units as u128) * (apr_bps as u128) * (dt_ms as u128)) / (10_000u128 * year_ms);
        if (delta == 0) { return };
        let rf = m.reserve_factor_bps as u128;
        let to_reserve = (delta * rf) / 10_000u128;
        let to_debt = delta - to_reserve;
        m.total_borrow_units = m.total_borrow_units + (to_debt as u64);
        m.reserve_units = m.reserve_units + (to_reserve as u64);
        event::emit(SynthAccrued { symbol, delta_units: delta as u64, reserve_units: to_reserve as u64, timestamp: 0u64 });
    }

    public fun liquidate_synth<C>(
        _cfg: &CollateralConfig<C>,
        reg: &mut LendingRegistry,
        _synth_reg: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_synth: &PriceInfoObject,
        _vault: &mut CollateralVault<C>,
        pool: &mut LendingPool<C>,
        debtor: &mut UserAccount,
        symbol: String,
        repay_units: u64,
        bonus_bps: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!reg.paused, 1000);
        assert!(repay_units > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&debtor.synth_borrow_units, symbol), E_UNKNOWN_ASSET);
        let cur = *table::borrow(&debtor.synth_borrow_units, symbol);
        assert!(repay_units <= cur, E_OVER_REPAY);
        let newb = cur - repay_units;
        table::add(&mut debtor.synth_borrow_units, symbol, newb);
        let m = table::borrow_mut(&mut reg.synth_markets, symbol);
        m.total_borrow_units = m.total_borrow_units - repay_units;
        let px = get_price_scaled_1e6(oracle_cfg, clock, price_synth) as u128;
        let val = (repay_units as u128) * px;
        let seize_val = val + (val * (bonus_bps as u128)) / 10_000u128;
        let seize_units = if (seize_val > (18446744073709551615u64 as u128)) { 18446744073709551615u64 } else { seize_val as u64 };
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= seize_units, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, seize_units);
        let out = coin::from_balance(out_bal, ctx);
        event::emit(SynthLiquidated { symbol, repay_units, usdc_seized: seize_units, bot_reward: ((seize_units as u128) - val) as u64, liquidator: tx_context::sender(ctx), timestamp: 0u64 });
        out
    }
}