module unxversal::lending {
    /*******************************
    * Unxversal Lending – Phase 1
    * - Supports coin-based lending pools (generic T)
    * - Permissioned asset/pool listing (admin-only)
    * - User accounts track per-asset supply/borrow balances
    * - Simple flash-loan primitive on a per-pool basis
    * - Object Display registered for Registry, Pool, Account
    *******************************/

    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::display;
    use sui::object;
    use sui::package;
    use sui::package::Publisher;
    use sui::types;
    use sui::event;
    use sui::clock::Clock;
    use sui::balance::{Self as BalanceMod, Balance};
    use sui::coin::{Self as Coin, Coin};

    use std::string::String;
    use std::table::{Self as Table, Table};
    use std::vec_set::{Self as VecSet, VecSet};
    use std::vector;
    use std::time;

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
    public struct GlobalParams has store {
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

    /*******************************
    * User account
    *******************************/
    public struct UserAccount has key, store {
        id: UID,
        owner: address,
        supply_balances: Table<String, u64>, // principal units per asset
        borrow_balances: Table<String, u64>, // principal units per asset
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

    /*******************************
    * FlashLoan proof object
    *******************************/
    public struct FlashLoan<phantom T> has drop { amount: u64, fee: u64, asset: String }

    /*******************************
    * Admin helper
    *******************************/
    fun assert_is_admin(reg: &LendingRegistry, addr: address) { assert!(VecSet::contains(&reg.admin_addrs, addr), E_NOT_ADMIN); }

    /*******************************
    * INIT – executed once
    *******************************/
    fun init(otw: LENDING, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let gp = GlobalParams { reserve_factor_bps: 1000, flash_loan_fee_bps: 9 };
        let mut admins = VecSet::empty();
        VecSet::add(&mut admins, ctx.sender());

        let reg = LendingRegistry {
            id: object::new(ctx),
            supported_assets: Table::new::<String, AssetConfig>(ctx),
            lending_pools: Table::new::<String, ID>(ctx),
            interest_rate_models: Table::new::<String, InterestRateModel>(ctx),
            global_params: gp,
            admin_addrs: admins,
        };
        transfer::share_object(reg);

        // Mint caps
        transfer::public_transfer(LendingDaddyCap { id: object::new(ctx) }, ctx.sender());
        transfer::public_transfer(LendingAdminCap { id: object::new(ctx) }, ctx.sender());

        // Display metadata
        let mut disp_reg = display::new<LendingRegistry>(&publisher, ctx);
        disp_reg.add(b"name".to_string(),        b"Unxversal Lending Registry".to_string());
        disp_reg.add(b"description".to_string(), b"Controls supported assets, pools, and risk parameters".to_string());
        disp_reg.update_version();
        transfer::public_transfer(disp_reg, ctx.sender());

        // Note: pool/account displays created on-demand below
        transfer::public_transfer(publisher, ctx.sender());
    }

    /*******************************
    * Admin – manage allow-list & params
    *******************************/
    public entry fun grant_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, new_admin: address) {
        VecSet::add(&mut reg.admin_addrs, new_admin);
    }

    public entry fun revoke_admin(_daddy: &LendingDaddyCap, reg: &mut LendingRegistry, bad: address) {
        VecSet::remove(&mut reg.admin_addrs, bad);
    }

    public entry fun add_supported_asset(_admin: &LendingAdminCap, reg: &mut LendingRegistry, symbol: String, is_collateral: bool, is_borrowable: bool, reserve_factor_bps: u64, irm: InterestRateModel, ctx: &TxContext) {
        assert_is_admin(reg, ctx.sender());
        assert!(!Table::contains(&reg.supported_assets, &symbol), E_ASSET_EXISTS);
        Table::insert(&mut reg.supported_assets, symbol.clone(), AssetConfig { symbol: symbol.clone(), is_collateral, is_borrowable, reserve_factor_bps });
        Table::insert(&mut reg.interest_rate_models, symbol, irm);
    }

    public entry fun set_global_params(_admin: &LendingAdminCap, reg: &mut LendingRegistry, gp: GlobalParams, ctx: &TxContext) {
        assert_is_admin(reg, ctx.sender());
        reg.global_params = gp;
    }

    /*******************************
    * Pool lifecycle (admin-only)
    *******************************/
    public entry fun create_pool<T>(_admin: &LendingAdminCap, reg: &mut LendingRegistry, asset_symbol: String, ctx: &mut TxContext) {
        assert_is_admin(reg, ctx.sender());
        assert!(Table::contains(&reg.supported_assets, &asset_symbol), E_UNKNOWN_ASSET);
        assert!(!Table::contains(&reg.lending_pools, &asset_symbol), E_POOL_EXISTS);
        let pool = LendingPool<T> {
            id: object::new(ctx),
            asset: asset_symbol.clone(),
            total_supply: 0,
            total_borrows: 0,
            total_reserves: 0,
            cash: BalanceMod::zero<T>(),
            supply_index: 1_000_000, // 1e6
            borrow_index: 1_000_000,
            last_update_ms: time::now_ms(),
            current_supply_rate_bps: 0,
            current_borrow_rate_bps: 0,
        };
        let id = object::id(&pool);
        transfer::share_object(pool);
        Table::insert(&mut reg.lending_pools, asset_symbol.clone(), id);

        // Display for pool type
        let publisher = package::claim(package::Publisher { id: object::new(ctx) }, ctx);
        let mut disp_pool = display::new<LendingPool<T>>(&publisher, ctx);
        disp_pool.add(b"name".to_string(),        b"Unxversal Lending Pool".to_string());
        disp_pool.add(b"asset".to_string(),       b"{asset}".to_string());
        disp_pool.add(b"description".to_string(), b"Lending pool for a specific asset".to_string());
        disp_pool.update_version();
        transfer::public_transfer(disp_pool, ctx.sender());
        transfer::public_transfer(publisher, ctx.sender());
    }

    /*******************************
    * User Account lifecycle
    *******************************/
    public entry fun open_account(ctx: &mut TxContext) {
        let acct = UserAccount { id: object::new(ctx), owner: ctx.sender(), supply_balances: Table::new::<String, u64>(ctx), borrow_balances: Table::new::<String, u64>(ctx), last_update_ms: time::now_ms() };
        transfer::share_object(acct);
        // Display for account
        let publisher = package::claim(package::Publisher { id: object::new(ctx) }, ctx);
        let mut disp_acct = display::new<UserAccount>(&publisher, ctx);
        disp_acct.add(b"name".to_string(),        b"Unxversal Lending Account".to_string());
        disp_acct.add(b"description".to_string(), b"Tracks a user's supplied and borrowed balances".to_string());
        disp_acct.update_version();
        transfer::public_transfer(disp_acct, ctx.sender());
        transfer::public_transfer(publisher, ctx.sender());
    }

    /*******************************
    * Core operations: supply / withdraw
    *******************************/
    public entry fun supply<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, mut coins: Coin<T>, amount: u64, ctx: &mut TxContext) {
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let have = Coin::value(&coins);
        assert!(have >= amount, E_ZERO_AMOUNT);
        let exact = Coin::split(&mut coins, amount, ctx);
        transfer::public_transfer(coins, ctx.sender());
        // move into pool cash
        let bal = Coin::into_balance(exact);
        BalanceMod::join(&mut pool.cash, bal);
        pool.total_supply = pool.total_supply + amount;
        let sym = pool.asset.clone();
        let cur = if Table::contains(&acct.supply_balances, &sym) { *Table::borrow(&acct.supply_balances, &sym) } else { 0 };
        let newb = cur + amount;
        Table::insert(&mut acct.supply_balances, sym.clone(), newb);
        acct.last_update_ms = time::now_ms();
        event::emit(AssetSupplied { user: ctx.sender(), asset: sym, amount, new_balance: newb, timestamp: time::now_ms() });
    }

    public entry fun withdraw<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, amount: u64, ctx: &mut TxContext): Coin<T> {
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let sym = pool.asset.clone();
        assert!(Table::contains(&acct.supply_balances, &sym), E_UNKNOWN_ASSET);
        let cur = *Table::borrow(&acct.supply_balances, &sym);
        assert!(cur >= amount, E_ZERO_AMOUNT);
        // ensure liquidity
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = Coin::from_balance(out_bal, ctx);
        let newb = cur - amount;
        Table::insert(&mut acct.supply_balances, sym.clone(), newb);
        pool.total_supply = pool.total_supply - amount;
        acct.last_update_ms = time::now_ms();
        event::emit(AssetWithdrawn { user: ctx.sender(), asset: sym, amount, remaining_balance: newb, timestamp: time::now_ms() });
        out
    }

    /*******************************
    * Core operations: borrow / repay
    *******************************/
    public entry fun borrow<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, amount: u64, ctx: &mut TxContext): Coin<T> {
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        // check pool liquidity
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        // update borrow
        let sym = pool.asset.clone();
        let cur = if Table::contains(&acct.borrow_balances, &sym) { *Table::borrow(&acct.borrow_balances, &sym) } else { 0 };
        let newb = cur + amount;
        Table::insert(&mut acct.borrow_balances, sym.clone(), newb);
        pool.total_borrows = pool.total_borrows + amount;
        acct.last_update_ms = time::now_ms();
        // transfer out
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = Coin::from_balance(out_bal, ctx);
        event::emit(AssetBorrowed { user: ctx.sender(), asset: sym, amount, new_borrow_balance: newb, timestamp: time::now_ms() });
        out
    }

    public entry fun repay<T>(_reg: &LendingRegistry, pool: &mut LendingPool<T>, acct: &mut UserAccount, payment: Coin<T>, ctx: &mut TxContext) {
        assert!(acct.owner == ctx.sender(), E_NOT_OWNER);
        let amount = Coin::value(&payment);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let sym = pool.asset.clone();
        assert!(Table::contains(&acct.borrow_balances, &sym), E_UNKNOWN_ASSET);
        let cur = *Table::borrow(&acct.borrow_balances, &sym);
        assert!(amount <= cur, E_OVER_REPAY);
        // move into pool cash
        let bal = Coin::into_balance(payment);
        BalanceMod::join(&mut pool.cash, bal);
        let newb = cur - amount;
        Table::insert(&mut acct.borrow_balances, sym.clone(), newb);
        pool.total_borrows = pool.total_borrows - amount;
        acct.last_update_ms = time::now_ms();
        event::emit(DebtRepaid { user: ctx.sender(), asset: sym, amount, remaining_debt: newb, timestamp: time::now_ms() });
    }

    /*******************************
    * Flash Loans – simple fee, same-tx repay enforced by API usage
    *******************************/
    public entry fun initiate_flash_loan<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, amount: u64, ctx: &mut TxContext): (Coin<T>, FlashLoan<T>) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        let cash = BalanceMod::value(&pool.cash);
        assert!(cash >= amount, E_INSUFFICIENT_LIQUIDITY);
        let fee = (amount * reg.global_params.flash_loan_fee_bps) / 10_000;
        let out_bal = BalanceMod::split(&mut pool.cash, amount);
        let out = Coin::from_balance(out_bal, ctx);
        event::emit(FlashLoanInitiated { asset: pool.asset.clone(), amount, fee, borrower: ctx.sender(), timestamp: time::now_ms() });
        (out, FlashLoan<T> { amount, fee, asset: pool.asset.clone() })
    }

    public entry fun repay_flash_loan<T>(reg: &LendingRegistry, pool: &mut LendingPool<T>, mut principal: Coin<T>, proof: FlashLoan<T>, ctx: &mut TxContext) {
        let due = proof.amount + proof.fee;
        let have = Coin::value(&principal);
        assert!(have >= due, E_INSUFFICIENT_LIQUIDITY);
        let fee_coin = Coin::split(&mut principal, proof.fee, ctx);
        // fees go to reserves (remain as cash but tracked in reserves)
        let fee_bal = Coin::into_balance(fee_coin);
        BalanceMod::join(&mut pool.cash, fee_bal);
        pool.total_reserves = pool.total_reserves + proof.fee;
        // principal back
        let principal_bal = Coin::into_balance(principal);
        BalanceMod::join(&mut pool.cash, principal_bal);
        event::emit(FlashLoanRepaid { asset: proof.asset, amount: proof.amount, fee: proof.fee, repayer: ctx.sender(), timestamp: time::now_ms() });
    }
}


