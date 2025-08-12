module unxversal::vaults {
    /*******************************
    * Unxversal Vaults – Liquidity and Trader Vaults
    * - Two separate registries: LiquidityRegistry and TraderVaultRegistry
    * - Admin gating via synthetics::SynthRegistry allow-list (AdminCap UX token)
    * - Treasury for fees is USDC/UNXV only
    * - All deposits/withdrawals are in USDC
    * - LiquidityVault<Base>: holds USDC and Base; places vault-safe orders on DEX
    * - TraderVault: USDC-only, share accounting, manager stake, HWM performance fees
    * - Rich events and read-only helpers
    *******************************/

    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::object;
    use sui::event;
    use sui::clock::Clock;
    use sui::display;
    use sui::coin::{Self as Coin, Coin};
    use std::string::String;
    use std::table::{Self as Table, Table};
    use std::vector;
    use std::time;

    use usdc::usdc::USDC;
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{SynthRegistry, AdminCap};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use unxversal::dex::{Self as Dex, DexConfig, VaultOrderBuy, VaultOrderSell};

    /*******************************
    * Errors
    *******************************/
    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 4;
    const E_NOT_MANAGER: u64 = 5;
    const E_SHUTDOWN: u64 = 6;
    const E_STAKE_DEFICIT: u64 = 7;
    const E_NOT_INVESTOR: u64 = 8;

    /*******************************
    * Internal admin helper (allow-list from SynthRegistry)
    *******************************/
    fun assert_is_admin(registry: &SynthRegistry, addr: address) {
        use std::vec_set::{contains};
        assert!(contains(&registry.admin_addrs, addr), E_NOT_ADMIN);
    }

    /*******************************
    * Liquidity Registry
    *******************************/
    public struct LiquidityRegistry has key, store {
        id: UID,
        treasury_id: ID,
        paused: bool,
        // Global default limits
        min_cash_bps: u64,              // e.g., 500 = 5% minimum USDC buffer
        default_management_fee_bps: u64, // reserved for future use
    }

    public struct LiquidityVaultCreated has copy, drop { vault_id: ID, manager: address, base_symbol: String, created_at: u64 }
    public struct LPDeposit has copy, drop { vault_id: ID, lp: address, usdc_amount: u64, shares_issued: u64, total_shares_after: u64, timestamp: u64 }
    public struct LPWithdrawal has copy, drop { vault_id: ID, lp: address, shares_redeemed: u64, usdc_paid: u64, base_paid: u64, pro_rata_mode: bool, timestamp: u64 }
    public struct LiquidityVaultShutdown has copy, drop { vault_id: ID, by: address, timestamp: u64 }
    public struct VaultDexOrderTracked has copy, drop { vault_id: ID, order_id: ID, side: u8, price: u64, size_base: u64, created_at_ms: u64, expiry_ms: u64 }

    public struct LiquidityVault<Base> has key, store {
        id: UID,
        manager: address,
        base_symbol: String,
        // Balances
        usdc: Coin<USDC>,
        base: Coin<Base>,
        // Share accounting
        total_shares: u64,
        shares: Table<address, u64>,
        // Risk & status
        min_cash_bps: u64,
        shutdown: bool,
        // Order tracking (IDs only; objects are shared externally)
        active_orders: vector<ID>,
        last_rebalance_ms: u64,
        created_at_ms: u64,
    }

    /*******************************
    * Trader Registry
    *******************************/
    public struct TraderVaultRegistry has key, store {
        id: UID,
        treasury_id: ID,
        paused: bool,
        min_manager_stake_bps: u64,     // e.g., 500 = 5%
        default_perf_fee_bps: u64,      // manager share of profits
        protocol_perf_fee_bps: u64,     // protocol cut of perf fees (USDC) to Treasury
    }

    public struct TraderVaultCreated has copy, drop { vault_id: ID, manager: address, created_at: u64, initial_stake: u64, required_stake_bps: u64 }
    public struct InvestorDeposit has copy, drop { vault_id: ID, investor: address, usdc_amount: u64, shares_issued: u64, total_shares_after: u64, timestamp: u64 }
    public struct InvestorWithdrawal has copy, drop { vault_id: ID, investor: address, shares_redeemed: u64, usdc_paid: u64, timestamp: u64 }
    public struct StakeUpdated has copy, drop { vault_id: ID, manager: address, manager_shares: u64, total_shares: u64, stake_bps: u64, timestamp: u64 }
    public struct StakeDeficit has copy, drop { vault_id: ID, manager: address, required_bps: u64, current_bps: u64, timestamp: u64 }
    public struct PerformanceFeesCalculated has copy, drop { vault_id: ID, hwm_before_1e6: u64, hwm_after_1e6: u64, perf_fee_bps: u64, manager_fee_usdc: u64, protocol_fee_usdc: u64, timestamp: u64 }
    public struct TraderVaultShutdown has copy, drop { vault_id: ID, by: address, timestamp: u64 }

    public struct TraderVault has key, store {
        id: UID,
        manager: address,
        // Balances
        usdc: Coin<USDC>,
        // Shares
        total_shares: u64,
        shares: Table<address, u64>,
        manager_shares: u64,
        // Fees & HWM
        hwm_nav_per_share_1e6: u64,    // high water mark in micro-USDC per share
        perf_fee_bps: u64,             // manager
        // Accrued fees payable when liquidity allows
        accrued_manager_fee_usdc: u64,
        accrued_protocol_fee_usdc: u64,
        // Status
        shutdown: bool,
        created_at_ms: u64,
    }

    /*******************************
    * Registry initialization
    *******************************/
    public entry fun init_liquidity_registry(registry: &SynthRegistry, treasury: &Treasury, ctx: &mut TxContext): LiquidityRegistry {
        assert_is_admin(registry, ctx.sender());
        LiquidityRegistry { id: object::new(ctx), treasury_id: object::id(treasury), paused: false, min_cash_bps: 500, default_management_fee_bps: 0 }
    }

    public entry fun init_trader_registry(registry: &SynthRegistry, treasury: &Treasury, ctx: &mut TxContext): TraderVaultRegistry {
        assert_is_admin(registry, ctx.sender());
        TraderVaultRegistry { id: object::new(ctx), treasury_id: object::id(treasury), paused: false, min_manager_stake_bps: 500, default_perf_fee_bps: 1000, protocol_perf_fee_bps: 0 }
    }

    /*******************************
    * Admin setters (via SynthRegistry allow-list)
    *******************************/
    public entry fun set_liquidity_min_cash(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut LiquidityRegistry, bps: u64, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.min_cash_bps = bps; }
    public entry fun pause_liquidity(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut LiquidityRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = true; }
    public entry fun resume_liquidity(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut LiquidityRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = false; }

    public entry fun set_trader_params(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut TraderVaultRegistry, min_stake_bps: u64, perf_fee_bps: u64, protocol_fee_bps: u64, _ctx: &TxContext) {
        assert_is_admin(registry, _ctx.sender());
        cfg.min_manager_stake_bps = min_stake_bps;
        cfg.default_perf_fee_bps = perf_fee_bps;
        cfg.protocol_perf_fee_bps = protocol_fee_bps;
    }
    public entry fun pause_trader(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut TraderVaultRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = true; }
    public entry fun resume_trader(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut TraderVaultRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = false; }

    /*******************************
    * LiquidityVault lifecycle
    *******************************/
    public entry fun create_liquidity_vault<Base>(
        cfg: &LiquidityRegistry,
        base_symbol: String,
        ctx: &mut TxContext
    ): LiquidityVault<Base> {
        assert!(!cfg.paused, E_PAUSED);
        let v = LiquidityVault<Base> {
            id: object::new(ctx),
            manager: ctx.sender(),
            base_symbol: base_symbol.clone(),
            usdc: Coin::zero<USDC>(ctx),
            base: Coin::zero<Base>(ctx),
            total_shares: 0,
            shares: Table::new<address, u64>(ctx),
            min_cash_bps: cfg.min_cash_bps,
            shutdown: false,
            active_orders: vector::empty<ID>(),
            last_rebalance_ms: 0,
            created_at_ms: time::now_ms(),
        };
        event::emit(LiquidityVaultCreated { vault_id: object::id(&v), manager: v.manager, base_symbol, created_at: v.created_at_ms });
        transfer::share_object(v)
    }

    /// Compute NAV in USDC (micro-USDC) using base price if base holdings > 0
    fun liquidity_nav_usdc_1e6<Base>(v: &LiquidityVault<Base>, oracle_cfg: &OracleConfig, clock: &Clock, base_price: &sui::object::ID): u128 {
        // Note: we cannot map symbol->feed on-chain here; the caller must provide the PriceInfoObject matching base_symbol
        use pyth::price_info::PriceInfoObject;
        let price_obj = unsafe_from_id_to_price_info_object(base_price);
        let usdc_v = Coin::value(&v.usdc) as u128;
        let base_amt = Coin::value(&v.base) as u128;
        if (base_amt == 0u128) { return usdc_v * 1_000_000u128; };
        let px = get_price_scaled_1e6(oracle_cfg, clock, &price_obj) as u128; // micro-USDC per 1 base
        usdc_v * 1_000_000u128 + (base_amt * px)
    }

    /// Unsafe helper to coerce an ID to a PriceInfoObject reference (caller must pass correct object)
    fun unsafe_from_id_to_price_info_object(id: &ID): &pyth::price_info::PriceInfoObject {
        // This is a type cast placeholder for referencing a shared object in entry functions.
        // In practice, callers will pass &PriceInfoObject directly in public entry functions below.
        abort 10
    }

    public entry fun lp_deposit_usdc<Base>(
        v: &mut LiquidityVault<Base>,
        cfg: &LiquidityRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        base_price: &pyth::price_info::PriceInfoObject,
        mut amount: Coin<USDC>,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused && !v.shutdown, E_PAUSED);
        let deposit_amt = Coin::value(&amount);
        assert!(deposit_amt > 0, E_ZERO_AMOUNT);
        // Pre-NAV
        let nav_before = nav_liquidity_usdc_1e6(v, oracle_cfg, clock, base_price);
        // Merge USDC
        Coin::merge(&mut v.usdc, amount);
        let nav_after = nav_liquidity_usdc_1e6(v, oracle_cfg, clock, base_price);
        let shares_issued = if (v.total_shares == 0) { deposit_amt } else { ((deposit_amt as u128) * (v.total_shares as u128) * 1_000_000u128 / (nav_before as u128)) as u64 };
        v.total_shares = v.total_shares + shares_issued;
        let prev = if (Table::contains(&v.shares, &ctx.sender())) { *Table::borrow(&v.shares, &ctx.sender()) } else { 0 };
        Table::insert(&mut v.shares, ctx.sender(), prev + shares_issued);
        event::emit(LPDeposit { vault_id: object::id(v), lp: ctx.sender(), usdc_amount: deposit_amt, shares_issued, total_shares_after: v.total_shares, timestamp: time::now_ms() });
    }

    fun nav_liquidity_usdc_1e6<Base>(v: &LiquidityVault<Base>, oracle_cfg: &OracleConfig, clock: &Clock, base_price: &pyth::price_info::PriceInfoObject): u64 {
        let usdc_v = Coin::value(&v.usdc) as u128;
        let base_amt = Coin::value(&v.base) as u128;
        if (base_amt == 0u128) { return (usdc_v * 1_000_000u128) as u64; };
        let px = get_price_scaled_1e6(oracle_cfg, clock, base_price) as u128;
        (usdc_v * 1_000_000u128 + base_amt * px) as u64
    }

    public entry fun lp_withdraw_usdc<Base>(
        v: &mut LiquidityVault<Base>,
        cfg: &LiquidityRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        base_price: &pyth::price_info::PriceInfoObject,
        shares_to_redeem: u64,
        ctx: &mut TxContext
    ): Coin<USDC> {
        assert!(!cfg.paused, E_PAUSED);
        let mut bal = if (Table::contains(&v.shares, &ctx.sender())) { *Table::borrow(&v.shares, &ctx.sender()) } else { 0 };
        assert!(bal >= shares_to_redeem && shares_to_redeem > 0, E_NOT_INVESTOR);
        let nav = nav_liquidity_usdc_1e6(v, oracle_cfg, clock, base_price) as u128;
        let payout_usdc = (nav * (shares_to_redeem as u128) / (v.total_shares as u128)) / 1_000_000u128;
        let available = Coin::value(&v.usdc) as u128;
        assert!(available >= payout_usdc, E_INSUFFICIENT_LIQUIDITY);
        let coin_out = Coin::split(&mut v.usdc, payout_usdc as u64, ctx);
        // Update shares
        bal = bal - shares_to_redeem;
        Table::insert(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares_to_redeem;
        event::emit(LPWithdrawal { vault_id: object::id(v), lp: ctx.sender(), shares_redeemed: shares_to_redeem, usdc_paid: payout_usdc as u64, base_paid: 0, pro_rata_mode: false, timestamp: time::now_ms() });
        coin_out
    }

    /// Emergency pro-rata withdrawal distributes current USDC and Base holdings proportionally
    public entry fun lp_emergency_withdraw_pro_rata<Base>(
        v: &mut LiquidityVault<Base>,
        shares_to_redeem: u64,
        ctx: &mut TxContext
    ): (Coin<USDC>, Coin<Base>) {
        assert!(v.shutdown, E_PAUSED);
        let mut bal = if (Table::contains(&v.shares, &ctx.sender())) { *Table::borrow(&v.shares, &ctx.sender()) } else { 0 };
        assert!(bal >= shares_to_redeem && shares_to_redeem > 0, E_NOT_INVESTOR);
        let usdc_total = Coin::value(&v.usdc);
        let base_total = Coin::value(&v.base);
        let usdc_pay = (usdc_total as u128) * (shares_to_redeem as u128) / (v.total_shares as u128);
        let base_pay = (base_total as u128) * (shares_to_redeem as u128) / (v.total_shares as u128);
        let out_usdc = if (usdc_pay > 0) { Coin::split(&mut v.usdc, usdc_pay as u64, ctx) } else { Coin::zero<USDC>(ctx) };
        let out_base = if (base_pay > 0) { Coin::split(&mut v.base, base_pay as u64, ctx) } else { Coin::zero<Base>(ctx) };
        bal = bal - shares_to_redeem;
        Table::insert(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares_to_redeem;
        event::emit(LPWithdrawal { vault_id: object::id(v), lp: ctx.sender(), shares_redeemed: shares_to_redeem, usdc_paid: Coin::value(&out_usdc), base_paid: Coin::value(&out_base), pro_rata_mode: true, timestamp: time::now_ms() });
        (out_usdc, out_base)
    }

    public entry fun shutdown_liquidity_vault<Base>(v: &mut LiquidityVault<Base>, ctx: &TxContext) { assert!(v.manager == ctx.sender(), E_NOT_MANAGER); v.shutdown = true; event::emit(LiquidityVaultShutdown { vault_id: object::id(v), by: ctx.sender(), timestamp: time::now_ms() }); }

    /*******************************
    * LiquidityVault – DEX integration (vault-safe)
    *******************************/
    public entry fun place_vault_sell<Base>(cfg: &DexConfig, v: &mut LiquidityVault<Base>, price: u64, size_base: u64, expiry_ms: u64, ctx: &mut TxContext): VaultOrderSell<Base> {
        assert!(!v.shutdown, E_SHUTDOWN);
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        let order = Dex::place_vault_sell_order::<Base>(cfg, price, size_base, &mut v.base, expiry_ms, ctx);
        vector::push_back(&mut v.active_orders, object::id(&order));
        event::emit(VaultDexOrderTracked { vault_id: object::id(v), order_id: object::id(&order), side: 1, price, size_base, created_at_ms: time::now_ms(), expiry_ms });
        transfer::share_object(order)
    }

    public entry fun place_vault_buy<Base>(cfg: &DexConfig, v: &mut LiquidityVault<Base>, price: u64, size_base: u64, expiry_ms: u64, ctx: &mut TxContext): VaultOrderBuy<Base> {
        assert!(!v.shutdown, E_SHUTDOWN);
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        // Enforce min cash buffer pre-escrow
        let usdc_before = Coin::value(&v.usdc);
        let usdc_needed = price * size_base;
        assert!(usdc_before >= usdc_needed, E_INSUFFICIENT_LIQUIDITY);
        let order = Dex::place_vault_buy_order::<Base>(cfg, price, size_base, &mut v.usdc, expiry_ms, ctx);
        vector::push_back(&mut v.active_orders, object::id(&order));
        event::emit(VaultDexOrderTracked { vault_id: object::id(v), order_id: object::id(&order), side: 0, price, size_base, created_at_ms: time::now_ms(), expiry_ms });
        transfer::share_object(order)
    }

    public entry fun cancel_vault_sell<Base>(v: &mut LiquidityVault<Base>, order: VaultOrderSell<Base>, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        Dex::cancel_vault_sell_order::<Base>(order, &mut v.base, ctx);
    }

    public entry fun cancel_vault_buy<Base>(v: &mut LiquidityVault<Base>, order: VaultOrderBuy<Base>, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        Dex::cancel_vault_buy_order::<Base>(order, &mut v.usdc, ctx);
    }

    public entry fun match_vault_orders<Base>(
        cfg: &mut DexConfig,
        v_buy: &mut LiquidityVault<Base>,
        v_sell: &mut LiquidityVault<Base>,
        buy: &mut VaultOrderBuy<Base>,
        sell: &mut VaultOrderSell<Base>,
        max_fill_base: u64,
        taker_is_buyer: bool,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &pyth::price_info::PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury,
        min_price: u64,
        max_price: u64,
        ctx: &mut TxContext
    ) {
        Dex::match_vault_orders::<Base>(
            cfg,
            buy,
            sell,
            max_fill_base,
            taker_is_buyer,
            unxv_payment,
            unxv_price,
            oracle_cfg,
            clock,
            treasury,
            min_price,
            max_price,
            &mut v_buy.base,
            &mut v_sell.usdc,
            ctx
        );
    }

    /*******************************
    * TraderVault lifecycle and accounting (USDC-only)
    *******************************/
    public entry fun create_trader_vault(
        cfg: &TraderVaultRegistry,
        initial_stake: Coin<USDC>,
        ctx: &mut TxContext
    ): TraderVault {
        assert!(!cfg.paused, E_PAUSED);
        let stake_amt = Coin::value(&initial_stake);
        assert!(stake_amt > 0, E_ZERO_AMOUNT);
        let mut shares_tbl = Table::new<address, u64>(ctx);
        let manager_addr = ctx.sender();
        let mut v = TraderVault {
            id: object::new(ctx),
            manager: manager_addr,
            usdc: Coin::zero<USDC>(ctx),
            total_shares: 0,
            shares: shares_tbl,
            manager_shares: 0,
            hwm_nav_per_share_1e6: 1_000_000,
            perf_fee_bps: cfg.default_perf_fee_bps,
            accrued_manager_fee_usdc: 0,
            accrued_protocol_fee_usdc: 0,
            shutdown: false,
            created_at_ms: time::now_ms(),
        };
        // Initial shares = stake amount
        Coin::merge(&mut v.usdc, initial_stake);
        v.total_shares = stake_amt;
        v.manager_shares = stake_amt;
        Table::insert(&mut v.shares, manager_addr, stake_amt);
        event::emit(TraderVaultCreated { vault_id: object::id(&v), manager: manager_addr, created_at: v.created_at_ms, initial_stake: stake_amt, required_stake_bps: cfg.min_manager_stake_bps });
        transfer::share_object(v)
    }

    fun manager_stake_bps(v: &TraderVault): u64 {
        if (v.total_shares == 0) { return 0; };
        (v.manager_shares * 10_000) / v.total_shares
    }

    /// Investors can deposit only if manager stake ≥ required bps
    public entry fun investor_deposit(
        v: &mut TraderVault,
        cfg: &TraderVaultRegistry,
        mut amount: Coin<USDC>,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused && !v.shutdown, E_PAUSED);
        // Check current stake before deposit
        let stake_bps = manager_stake_bps(v);
        if (stake_bps < cfg.min_manager_stake_bps) { event::emit(StakeDeficit { vault_id: object::id(v), manager: v.manager, required_bps: cfg.min_manager_stake_bps, current_bps: stake_bps, timestamp: time::now_ms() }); abort E_STAKE_DEFICIT; };
        let deposit_amt = Coin::value(&amount);
        assert!(deposit_amt > 0, E_ZERO_AMOUNT);
        let shares_issued = if (v.total_shares == 0) { deposit_amt } else { deposit_amt * v.total_shares / Coin::value(&v.usdc) };
        Coin::merge(&mut v.usdc, amount);
        v.total_shares = v.total_shares + shares_issued;
        let prev = if (Table::contains(&v.shares, &ctx.sender())) { *Table::borrow(&v.shares, &ctx.sender()) } else { 0 };
        Table::insert(&mut v.shares, ctx.sender(), prev + shares_issued);
        event::emit(InvestorDeposit { vault_id: object::id(v), investor: ctx.sender(), usdc_amount: deposit_amt, shares_issued, total_shares_after: v.total_shares, timestamp: time::now_ms() });
    }

    /// Manager can add stake anytime (increases manager_shares proportionally)
    public entry fun manager_add_stake(v: &mut TraderVault, mut stake: Coin<USDC>, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender() && !v.shutdown, E_NOT_MANAGER);
        let amt = Coin::value(&stake);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let shares = if (v.total_shares == 0) { amt } else { amt * v.total_shares / Coin::value(&v.usdc) };
        Coin::merge(&mut v.usdc, stake);
        v.total_shares = v.total_shares + shares;
        v.manager_shares = v.manager_shares + shares;
        let prev = if (Table::contains(&v.shares, &ctx.sender())) { *Table::borrow(&v.shares, &ctx.sender()) } else { 0 };
        Table::insert(&mut v.shares, ctx.sender(), prev + shares);
        let bps = manager_stake_bps(v);
        event::emit(StakeUpdated { vault_id: object::id(v), manager: v.manager, manager_shares: v.manager_shares, total_shares: v.total_shares, stake_bps: bps, timestamp: time::now_ms() });
    }

    /// Manager unstake: only allowed if remains ≥ required bps or vault is shutdown
    public entry fun manager_unstake(v: &mut TraderVault, cfg: &TraderVaultRegistry, shares_to_burn: u64, ctx: &mut TxContext): Coin<USDC> {
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        let mut mgr_pos = v.manager_shares;
        assert!(shares_to_burn > 0 && mgr_pos >= shares_to_burn, E_NOT_INVESTOR);
        if (!v.shutdown) {
            // ensure post-unstake >= required
            let total_post = v.total_shares - shares_to_burn;
            let mgr_post = v.manager_shares - shares_to_burn;
            let bps_post = if (total_post == 0) { 0 } else { (mgr_post * 10_000) / total_post };
            assert!(bps_post >= cfg.min_manager_stake_bps, E_STAKE_DEFICIT);
        }
        // redeem pro-rata USDC
        let payout = (Coin::value(&v.usdc) as u128) * (shares_to_burn as u128) / (v.total_shares as u128);
        let coin_out = Coin::split(&mut v.usdc, payout as u64, ctx);
        v.manager_shares = v.manager_shares - shares_to_burn;
        v.total_shares = v.total_shares - shares_to_burn;
        let prev = *Table::borrow(&v.shares, &ctx.sender());
        Table::insert(&mut v.shares, ctx.sender(), prev - shares_to_burn);
        let bps = manager_stake_bps(v);
        event::emit(StakeUpdated { vault_id: object::id(v), manager: v.manager, manager_shares: v.manager_shares, total_shares: v.total_shares, stake_bps: bps, timestamp: time::now_ms() });
        coin_out
    }

    public entry fun investor_withdraw(v: &mut TraderVault, shares_to_redeem: u64, ctx: &mut TxContext): Coin<USDC> {
        let mut bal = if (Table::contains(&v.shares, &ctx.sender())) { *Table::borrow(&v.shares, &ctx.sender()) } else { 0 };
        assert!(shares_to_redeem > 0 && bal >= shares_to_redeem, E_NOT_INVESTOR);
        let payout = (Coin::value(&v.usdc) as u128) * (shares_to_redeem as u128) / (v.total_shares as u128);
        let available = Coin::value(&v.usdc) as u128;
        assert!(available >= payout, E_INSUFFICIENT_LIQUIDITY);
        let coin_out = Coin::split(&mut v.usdc, payout as u64, ctx);
        bal = bal - shares_to_redeem;
        Table::insert(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares_to_redeem;
        if (ctx.sender() == v.manager) { v.manager_shares = v.manager_shares - shares_to_redeem; };
        event::emit(InvestorWithdrawal { vault_id: object::id(v), investor: ctx.sender(), shares_redeemed: shares_to_redeem, usdc_paid: payout as u64, timestamp: time::now_ms() });
        coin_out
    }

    /// Calculate performance fee vs HWM and accrue amounts (not paid out yet)
    public entry fun crystallize_performance_fee(v: &mut TraderVault, cfg: &TraderVaultRegistry, _ctx: &mut TxContext) {
        if (v.total_shares == 0) { return; }
        let nav = Coin::value(&v.usdc) as u128;
        let nav_per_share_1e6 = (nav * 1_000_000u128 / (v.total_shares as u128)) as u64;
        if (nav_per_share_1e6 <= v.hwm_nav_per_share_1e6) { return; }
        let gain_per_share_1e6 = nav_per_share_1e6 - v.hwm_nav_per_share_1e6;
        let gain_total_usdc = (gain_per_share_1e6 as u128) * (v.total_shares as u128) / 1_000_000u128;
        let manager_fee = (gain_total_usdc * (v.perf_fee_bps as u128)) / 10_000u128;
        let protocol_fee = (gain_total_usdc * (cfg.protocol_perf_fee_bps as u128)) / 10_000u128;
        v.accrued_manager_fee_usdc = v.accrued_manager_fee_usdc + (manager_fee as u64);
        v.accrued_protocol_fee_usdc = v.accrued_protocol_fee_usdc + (protocol_fee as u64);
        v.hwm_nav_per_share_1e6 = nav_per_share_1e6;
        event::emit(PerformanceFeesCalculated { vault_id: object::id(v), hwm_before_1e6: v.hwm_nav_per_share_1e6, hwm_after_1e6: nav_per_share_1e6, perf_fee_bps: v.perf_fee_bps, manager_fee_usdc: manager_fee as u64, protocol_fee_usdc: protocol_fee as u64, timestamp: time::now_ms() });
    }

    /// Attempt to pay accrued fees if liquidity allows; protocol fee goes to Treasury
    public entry fun pay_accrued_fees(v: &mut TraderVault, cfg: &TraderVaultRegistry, treasury: &mut Treasury, ctx: &mut TxContext) {
        let available = Coin::value(&v.usdc);
        let mut pay_manager = if (v.accrued_manager_fee_usdc > available) { available } else { v.accrued_manager_fee_usdc };
        let mut left = available - pay_manager;
        let pay_protocol = if (v.accrued_protocol_fee_usdc > left) { left } else { v.accrued_protocol_fee_usdc };
        if (pay_manager > 0) {
            let out = Coin::split(&mut v.usdc, pay_manager, ctx);
            transfer::public_transfer(out, v.manager);
            v.accrued_manager_fee_usdc = v.accrued_manager_fee_usdc - pay_manager;
        }
        if (pay_protocol > 0) {
            let outp = Coin::split(&mut v.usdc, pay_protocol, ctx);
            TreasuryMod::deposit_usdc(treasury, outp, b"perf_fee".to_string(), v.manager, ctx);
            v.accrued_protocol_fee_usdc = v.accrued_protocol_fee_usdc - pay_protocol;
        }
    }

    public entry fun shutdown_trader_vault(v: &mut TraderVault, ctx: &TxContext) { assert!(v.manager == ctx.sender(), E_NOT_MANAGER); v.shutdown = true; event::emit(TraderVaultShutdown { vault_id: object::id(v), by: ctx.sender(), timestamp: time::now_ms() }); }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun liquidity_vault_balances<Base>(v: &LiquidityVault<Base>): (u64, u64, u64, u64) {
        (Coin::value(&v.usdc), Coin::value(&v.base), v.total_shares, vector::length(&v.active_orders) as u64)
    }
    public fun liquidity_user_shares<Base>(v: &LiquidityVault<Base>, addr: address): u64 { if (Table::contains(&v.shares, &addr)) { *Table::borrow(&v.shares, &addr) } else { 0 } }
    public fun liquidity_is_shutdown<Base>(v: &LiquidityVault<Base>): bool { v.shutdown }

    public fun trader_nav(v: &TraderVault): (u64, u64, u64) { (Coin::value(&v.usdc), v.total_shares, v.hwm_nav_per_share_1e6) }
    public fun trader_user_shares(v: &TraderVault, addr: address): u64 { if (Table::contains(&v.shares, &addr)) { *Table::borrow(&v.shares, &addr) } else { 0 } }
    public fun trader_manager_stake_bps(v: &TraderVault): u64 { manager_stake_bps(v) }
}

module unxversal::vaults {
    /*******************************
    * UnXversal Vaults - Unified Liquidity & Managed Vaults
    *******************************/
    use sui::event;
    use sui::display;
    use sui::package::Publisher;
    use sui::clock::Clock;
    use std::string::String;
    use sui::table::{Self as table, Table};
    use sui::vec_set::{Self as vec_set, VecSet};
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};

    use unxversal::synthetics::{Self as Synth, SynthRegistry, AdminCap, Order, CollateralVault, CollateralConfig};
    use unxversal::dex::{Self as Dex, DexConfig, CoinOrderBuy, CoinOrderSell};
    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use unxversal::oracle::{OracleConfig, PriceInfoObject};
    use unxversal::unxv::UNXV;
    use unxversal::options::{Self as Opt, OptionsRegistry, OptionMarket, ShortOffer, PremiumEscrow, OptionPosition};
    use unxversal::perpetuals::{Self as Perps, PerpsRegistry, PerpMarket};
    use unxversal::futures::{Self as Futures, FuturesRegistry, FuturesContract};
    use unxversal::gas_futures::{Self as GasFutures, GasFuturesRegistry, GasFuturesContract};

    /*******************************
    * Errors
    *******************************/
    const E_PAUSED: u64 = 1;
    const E_NOT_MANAGER: u64 = 2;
    const E_NOT_EXECUTOR: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;
    const E_OVER_CAP: u64 = 6;
    const E_MANAGED_ONLY: u64 = 7;
    const E_BAD_SHARES: u64 = 8;
    const E_TOO_SOON: u64 = 9;
    const E_COLLATERAL_ALREADY_SET: u64 = 900;

    /*******************************
    * Common config structs
    *******************************/
    public struct Timelocks has store, drop, copy { withdraw_notice_sec: u64, param_cooldown_sec: u64 }
    public struct FeeConfig has store, drop, copy { performance_bps: u64, management_bps: u64, protocol_skim_bps: u64, max_performance_bps: u64 }
    public struct VaultRiskCaps has store, drop, copy { max_trade_notional_usd: u64, max_slippage_bps: u64 }

    /*******************************
    * MANAGED mode: Investor shares and withdrawals
    *******************************/
    public struct InvestorShares has key, store {
        id: UID,
        vault_id: ID,
        investor: address,
        shares_owned: u64,
        avg_cost_micro_usd_per_share: u64,
        created_at_ms: u64,
    }

    public struct WithdrawalRequest has key, store {
        id: UID,
        vault_id: ID,
        investor: address,
        shares: u64,
        ready_at_ms: u64,
        created_at_ms: u64,
    }

    /*******************************
    * Registry (shared)
    *******************************/
    public struct VaultsRegistry has key, store {
        id: UID,
        treasury_id: ID,
        paused: bool,
        collateral_set: bool,
        default_timelocks: Timelocks,
        default_fee_cfg: FeeConfig,
        global_caps: VaultRiskCaps,
        tier_thresholds_unxv: vector<u64>,
        tier_perf_ceiling_bps: vector<u64>,
    }

    /*******************************
    * Vault (shared)
    *******************************/
    public struct Vault<phantom C> has key, store {
        id: UID,
        manager: address,
        vault_type: u8,
        balance: Balance<C>,
        executor_addrs: VecSet<address>,
        status: u8,
        template_id: String,
        risk_caps: VaultRiskCaps,
        timelocks: Timelocks,
        fee_cfg: FeeConfig,
        last_nav_update_ms: u64,
        last_fee_calc_ms: u64,
        total_shares: u64,
        manager_shares: u64,
        required_stake_bps: u64,
        high_water_mark_micro_usd_per_share: u64,
        last_param_update_ms: u64,
        staked_unxv: Balance<UNXV>,
        dex_caps_usd: Table<String, u64>,
        synth_caps_usd: Table<String, u64>,
        perps_caps_usd: Table<String, u64>,
        futures_caps_usd: Table<String, u64>,
        gas_caps_usd: Table<String, u64>,
        options_caps_usd: Table<String, u64>,
    }

    /*******************************
    * Events
    *******************************/
    public struct VaultsRegistryInitialized has copy, drop { registry_id: ID, treasury_id: ID, by: address, timestamp: u64 }
    public struct VaultCreated has copy, drop { vault_id: ID, vault_type: u8, manager: address, template_id: String, timestamp: u64 }
    public struct VaultDeposit has copy, drop { vault_id: ID, asset: String, amount: u64, depositor: address, timestamp: u64 }
    public struct VaultWithdrawn has copy, drop { vault_id: ID, asset: String, amount: u64, receiver: address, timestamp: u64 }
    public struct VaultPaused has copy, drop { vault_id: ID, by: address, timestamp: u64 }
    public struct VaultResumed has copy, drop { vault_id: ID, by: address, timestamp: u64 }
    public struct ExecutorUpdated has copy, drop { vault_id: ID, executor: address, allowed: bool, by: address, timestamp: u64 }
    public struct StrategyExecuted has copy, drop { vault_id: ID, template_id: String, op: String, notional_usd: u64, success: bool, timestamp: u64 }
    public struct InvestorSharesIssued has copy, drop { vault_id: ID, investor: address, shares: u64, price_micro_usd_per_share: u64, timestamp: u64 }
    public struct InvestorSharesBurned has copy, drop { vault_id: ID, investor: address, shares: u64, price_micro_usd_per_share: u64, amount_usdc: u64, timestamp: u64 }
    public struct WithdrawalRequested has copy, drop { vault_id: ID, investor: address, shares: u64, ready_at_ms: u64, timestamp: u64 }
    public struct VaultNavUpdated has copy, drop { vault_id: ID, nav_micro_usd_per_share: u64, total_assets_usdc: u64, timestamp: u64 }
    public struct PerformanceFeesSettled has copy, drop { vault_id: ID, manager: address, fees_usdc: u64, protocol_usdc: u64, new_hwm_micro_usd_per_share: u64, timestamp: u64 }
    public struct ManagementFeesAccrued has copy, drop { vault_id: ID, manager: address, fees_usdc: u64, protocol_usdc: u64, timestamp: u64 }
    public struct VaultParamsUpdated has copy, drop { vault_id: ID, by: address, timestamp: u64 }
    public struct VaultClosingStarted has copy, drop { vault_id: ID, by: address, timestamp: u64 }
    public struct VaultClosed has copy, drop { vault_id: ID, by: address, timestamp: u64 }

    /*******************************
    * Helpers
    *******************************/
    fun assert_registry_active(r: &VaultsRegistry) { assert!(!r.paused, E_PAUSED); }
    fun assert_vault_executor<C>(v: &Vault<C>, caller: address) {
        if (caller == v.manager) { return };
        assert!(vec_set::contains(&v.executor_addrs, &caller), E_NOT_EXECUTOR);
    }

    /*******************************
    * Init & Display
    *******************************/
    public fun init_vaults_registry<C>(_registry: &SynthRegistry, treasury: &Treasury<C>, ctx: &mut TxContext): VaultsRegistry {
        let r = VaultsRegistry {
            id: object::new(ctx),
            treasury_id: object::id(treasury),
            paused: false,
            collateral_set: false,
            default_timelocks: Timelocks { withdraw_notice_sec: 0, param_cooldown_sec: 0 },
            default_fee_cfg: FeeConfig { performance_bps: 0, management_bps: 0, protocol_skim_bps: 0, max_performance_bps: 2_000 },
            global_caps: VaultRiskCaps { max_trade_notional_usd: 0, max_slippage_bps: 0 },
            tier_thresholds_unxv: vector::empty<u64>(),
            tier_perf_ceiling_bps: vector::empty<u64>(),
        };
        let registry_id = object::id(&r);
        let treasury_id = object::id(treasury);
        event::emit(VaultsRegistryInitialized { registry_id, treasury_id, by: tx_context::sender(ctx), timestamp: 0u64 });
        r
    }

    public fun init_vaults_registry_with_display<C>(registry: &SynthRegistry, treasury: &Treasury<C>, publisher: &Publisher, ctx: &mut TxContext): VaultsRegistry {
        let r = init_vaults_registry(registry, treasury, ctx);
        let mut disp = display::new<VaultsRegistry>(publisher, ctx);
        disp.add(b"name".to_string(), b"Unxversal Vaults Registry".to_string());
        disp.add(b"description".to_string(), b"Unified vaults for liquidity and managed strategies".to_string());
        disp.update_version();
        transfer::public_transfer(disp, tx_context::sender(ctx));
        r
    }

    /*******************************
    * Registry controls (admin via SynthRegistry)
    *******************************/
    fun assert_is_admin(sr: &SynthRegistry, addr: address) {
        assert!(Synth::check_is_admin(sr, addr), E_NOT_MANAGER);
    }

    public entry fun set_collateral(
        _admin: &AdminCap,
        registry: &mut VaultsRegistry,
        sr: &SynthRegistry,
        ctx: &mut TxContext
    ) {
        assert_is_admin(sr, tx_context::sender(ctx));
        assert!(!registry.collateral_set, E_COLLATERAL_ALREADY_SET);
        registry.collateral_set = true;
    }

    public entry fun pause_registry(_admin: &AdminCap, sr: &SynthRegistry, r: &mut VaultsRegistry, ctx: &TxContext) { assert_is_admin(sr, tx_context::sender(ctx)); r.paused = true; }
    public entry fun resume_registry(_admin: &AdminCap, sr: &SynthRegistry, r: &mut VaultsRegistry, ctx: &TxContext) { assert_is_admin(sr, tx_context::sender(ctx)); r.paused = false; }
    public fun set_default_timelocks(_admin: &AdminCap, sr: &SynthRegistry, r: &mut VaultsRegistry, t: Timelocks, ctx: &TxContext) { assert_is_admin(sr, tx_context::sender(ctx)); r.default_timelocks = t; }
    public fun set_default_fee_cfg(_admin: &AdminCap, sr: &SynthRegistry, r: &mut VaultsRegistry, f: FeeConfig, ctx: &TxContext) { assert_is_admin(sr, tx_context::sender(ctx)); r.default_fee_cfg = f; }
    public fun set_global_caps(_admin: &AdminCap, sr: &SynthRegistry, r: &mut VaultsRegistry, c: VaultRiskCaps, ctx: &TxContext) { assert_is_admin(sr, tx_context::sender(ctx)); r.global_caps = c; }
    public entry fun set_unxv_tiers(_admin: &AdminCap, sr: &SynthRegistry, r: &mut VaultsRegistry, thresholds: vector<u64>, perf_caps_bps: vector<u64>, ctx: &TxContext) {
        assert_is_admin(sr, tx_context::sender(ctx));
        assert!(vector::length(&thresholds) == vector::length(&perf_caps_bps), E_ZERO_AMOUNT);
        r.tier_thresholds_unxv = thresholds;
        r.tier_perf_ceiling_bps = perf_caps_bps;
    }

    /*******************************
    * Vault lifecycle (permissionless creation)
    *******************************/
    public entry fun create_vault<C>(
        _cfg: &CollateralConfig<C>,
        r: &VaultsRegistry,
        vault_type: u8,
        template_id: String,
        ctx: &mut TxContext
    ) {
        assert_registry_active(r);
        let v = Vault<C> {
            id: object::new(ctx),
            manager: tx_context::sender(ctx),
            vault_type,
            balance: balance::zero<C>(),
            executor_addrs: vec_set::empty(),
            status: 0,
            template_id,
            risk_caps: r.global_caps,
            timelocks: r.default_timelocks,
            fee_cfg: r.default_fee_cfg,
            last_nav_update_ms: 0u64,
            last_fee_calc_ms: 0u64,
            total_shares: 0,
            manager_shares: 0,
            required_stake_bps: 500,
            high_water_mark_micro_usd_per_share: 1_000_000,
            last_param_update_ms: 0,
            staked_unxv: balance::zero<UNXV>(),
            dex_caps_usd: table::new<String, u64>(ctx),
            synth_caps_usd: table::new<String, u64>(ctx),
            perps_caps_usd: table::new<String, u64>(ctx),
            futures_caps_usd: table::new<String, u64>(ctx),
            gas_caps_usd: table::new<String, u64>(ctx),
            options_caps_usd: table::new<String, u64>(ctx),
        };
        let vault_id = object::id(&v);
        transfer::share_object(v);
        event::emit(VaultCreated { vault_id, vault_type, manager: tx_context::sender(ctx), template_id, timestamp: 0u64 });
    }

    public fun deposit<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        coins: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(v.status == 0, E_PAUSED);
        let amount = coins.value();
        balance::join(&mut v.balance, coin::into_balance(coins));
        event::emit(VaultDeposit { vault_id: object::id(v), asset: b"COLLATERAL".to_string(), amount, depositor: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun withdraw<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(v.status == 0 || v.status == 2, E_PAUSED);
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let out_balance = balance::split(&mut v.balance, amount);
        let out_coin = coin::from_balance(out_balance, ctx);
        event::emit(VaultWithdrawn { vault_id: object::id(v), asset: b"COLLATERAL".to_string(), amount, receiver: v.manager, timestamp: 0u64 });
        out_coin
    }

    public fun set_executor<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        exec: address,
        allowed: bool,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        if (allowed) { vec_set::insert(&mut v.executor_addrs, exec); } else { vec_set::remove(&mut v.executor_addrs, &exec); };
        event::emit(ExecutorUpdated { vault_id: object::id(v), executor: exec, allowed, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun pause_vault<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        v.status = 1;
        event::emit(VaultPaused { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }
    
    public fun resume_vault<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        v.status = 0;
        event::emit(VaultResumed { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    fun assert_active_and_executor<C>(v: &Vault<C>, ctx: &TxContext) {
        assert!(v.status == 0, E_PAUSED);
        assert_vault_executor(v, tx_context::sender(ctx));
    }

    fun assert_managed<C>(v: &Vault<C>) {
        assert!(v.vault_type == 1, E_MANAGED_ONLY);
    }

    fun aum<C>(v: &Vault<C>): u64 {
        balance::value(&v.balance)
    }

    fun nav_micro_usd_per_share<C>(v: &Vault<C>): u64 {
        if (v.total_shares == 0) { return 1_000_000 };
        let total = aum(v) as u128;
        let per = (total * 1_000_000u128) / (v.total_shares as u128);
        per as u64
    }

    fun stake_ok<C>(v: &Vault<C>): bool {
        if (v.vault_type != 1) { return true };
        if (v.total_shares == 0) { return true };
        let stake_bps = (v.manager_shares as u128) * 10_000u128 / (v.total_shares as u128);
        (stake_bps as u64) >= v.required_stake_bps
    }

    public fun deposit_managed<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        collateral: Coin<C>,
        as_manager_stake: bool,
        ctx: &mut TxContext
    ): InvestorShares {
        assert_managed(v);
        assert!(v.status == 0, E_PAUSED);
        let amount = coin::value(&collateral);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let shares: u64 = if (v.total_shares == 0) { amount } else { ((amount as u128) * (v.total_shares as u128) / (aum(v) as u128)) as u64 };
        assert!(shares > 0, E_BAD_SHARES);
        balance::join(&mut v.balance, coin::into_balance(collateral));
        v.total_shares = v.total_shares + shares;
        if (as_manager_stake) { v.manager_shares = v.manager_shares + shares; };
        let nav_ps = nav_micro_usd_per_share(v);
        event::emit(InvestorSharesIssued { vault_id: object::id(v), investor: tx_context::sender(ctx), shares, price_micro_usd_per_share: nav_ps, timestamp: 0u64 });
        InvestorShares { id: object::new(ctx), vault_id: object::id(v), investor: tx_context::sender(ctx), shares_owned: shares, avg_cost_micro_usd_per_share: nav_ps, created_at_ms: 0u64 }
    }

    public fun request_withdrawal_managed<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        shares: u64,
        inv: &mut InvestorShares,
        ctx: &mut TxContext
    ): WithdrawalRequest {
        assert_managed(v);
        assert!(inv.investor == tx_context::sender(ctx) && inv.vault_id == object::id(v), E_NOT_MANAGER);
        assert!(shares > 0 && shares <= inv.shares_owned, E_BAD_SHARES);
        let ready = 0u64 + v.timelocks.withdraw_notice_sec * 1000;
        event::emit(WithdrawalRequested { vault_id: object::id(v), investor: tx_context::sender(ctx), shares, ready_at_ms: ready, timestamp: 0u64 });
        WithdrawalRequest { id: object::new(ctx), vault_id: object::id(v), investor: tx_context::sender(ctx), shares, ready_at_ms: ready, created_at_ms: 0u64 }
    }

    public fun execute_withdrawal_managed<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        req: WithdrawalRequest,
        inv: &mut InvestorShares,
        ctx: &mut TxContext
    ) {
        assert_managed(v);
        assert!(v.status == 0 || v.status == 2, E_PAUSED);
        assert!(req.vault_id == object::id(v) && req.investor == inv.investor, E_NOT_MANAGER);
        assert!(0u64 >= req.ready_at_ms, E_TOO_SOON);
        let shares = req.shares;
        assert!(shares > 0 && shares <= inv.shares_owned && shares <= v.total_shares, E_BAD_SHARES);
        let total = aum(v) as u128;
        let amount = ((total * (shares as u128)) / (v.total_shares as u128)) as u64;
        if (amount > 0) {
            let out_balance = balance::split(&mut v.balance, amount);
            transfer::public_transfer(coin::from_balance(out_balance, ctx), inv.investor);
        };
        let nav_ps = nav_micro_usd_per_share(v);
        inv.shares_owned = inv.shares_owned - shares;
        v.total_shares = v.total_shares - shares;
        if (inv.investor == v.manager) {
            let ms = v.manager_shares;
            v.manager_shares = if (ms >= shares) { ms - shares } else { 0 };
        };
        event::emit(InvestorSharesBurned { vault_id: object::id(v), investor: inv.investor, shares, price_micro_usd_per_share: nav_ps, amount_usdc: amount, timestamp: 0u64 });
        let WithdrawalRequest { id, vault_id: _, investor: _, shares: _, ready_at_ms: _, created_at_ms: _ } = req;
        object::delete(id);
    }

    public fun start_closing_vault<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        assert!(v.status == 0 || v.status == 1, E_PAUSED);
        v.status = 2;
        event::emit(VaultClosingStarted { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun finalize_close_vault<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        ctx: &TxContext
    ) {
        assert!(v.status == 2, E_PAUSED);
        let bal = balance::value(&v.balance);
        assert!(v.total_shares == 0 && bal == 0, E_BAD_SHARES);
        v.status = 3;
        event::emit(VaultClosed { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun update_nav_and_hwm<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        _ctx: &TxContext
    ) {
        if (v.vault_type != 1) { return };
        let nav_ps = nav_micro_usd_per_share(v);
        v.high_water_mark_micro_usd_per_share = if (nav_ps > v.high_water_mark_micro_usd_per_share) { nav_ps } else { v.high_water_mark_micro_usd_per_share };
        v.last_nav_update_ms = 0u64;
        event::emit(VaultNavUpdated { vault_id: object::id(v), nav_micro_usd_per_share: nav_ps, total_assets_usdc: aum(v), timestamp: 0u64 });
    }

    public fun settle_performance_fees<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert_managed(v);
        let nav_ps = nav_micro_usd_per_share(v);
        if (v.total_shares == 0) { return };
        if (nav_ps <= v.high_water_mark_micro_usd_per_share) { return };
        let profit_collateral = ((((nav_ps as u128) - (v.high_water_mark_micro_usd_per_share as u128)) * (v.total_shares as u128)) / 1_000_000u128) as u64;
        if (profit_collateral == 0) { v.high_water_mark_micro_usd_per_share = nav_ps; return };
        let fee = (profit_collateral * v.fee_cfg.performance_bps) / 10_000;
        let protocol_cut = (fee * v.fee_cfg.protocol_skim_bps) / 10_000;
        let manager_cut = if (fee >= protocol_cut) { fee - protocol_cut } else { 0 };
        if (fee > 0) {
            if (manager_cut > 0) {
                let c_balance = balance::split(&mut v.balance, manager_cut);
                transfer::public_transfer(coin::from_balance(c_balance, ctx), v.manager);
            };
            if (protocol_cut > 0) {
                let c2_balance = balance::split(&mut v.balance, protocol_cut);
                transfer::public_transfer(coin::from_balance(c2_balance, ctx), TreasuryMod::treasury_address(treasury));
            };
            event::emit(PerformanceFeesSettled { vault_id: object::id(v), manager: v.manager, fees_usdc: manager_cut, protocol_usdc: protocol_cut, new_hwm_micro_usd_per_share: nav_ps, timestamp: 0u64 });
        };
        v.high_water_mark_micro_usd_per_share = nav_ps;
        v.last_fee_calc_ms = 0u64;
    }

    public fun accrue_management_fees<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        if (v.fee_cfg.management_bps == 0) { return };
        let now = 0u64;
        let last = v.last_fee_calc_ms;
        if (now <= last) { return };
        let elapsed = now - last;
        let aum_value = balance::value(&v.balance);
        if (aum_value == 0) { v.last_fee_calc_ms = now; return };
        let year_ms = 31_536_000_000;
        let fee = ((aum_value as u128) * (v.fee_cfg.management_bps as u128) * (elapsed as u128) / (10_000u128 * (year_ms as u128))) as u64;
        if (fee == 0) { v.last_fee_calc_ms = now; return };
        let protocol_cut = (fee * v.fee_cfg.protocol_skim_bps) / 10_000;
        let manager_cut = if (fee >= protocol_cut) { fee - protocol_cut } else { 0 };
        if (manager_cut > 0) {
            let c_balance = balance::split(&mut v.balance, manager_cut);
            transfer::public_transfer(coin::from_balance(c_balance, ctx), v.manager);
        };
        if (protocol_cut > 0) {
            let c2_balance = balance::split(&mut v.balance, protocol_cut);
            transfer::public_transfer(coin::from_balance(c2_balance, ctx), TreasuryMod::treasury_address(treasury));
        };
        v.last_fee_calc_ms = now;
        event::emit(ManagementFeesAccrued { vault_id: object::id(v), manager: v.manager, fees_usdc: manager_cut, protocol_usdc: protocol_cut, timestamp: now });
    }

    public fun stake_unxv<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        mut unxv: vector<Coin<UNXV>>,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        let mut merged = coin::zero<UNXV>(ctx);
        while (!vector::is_empty(&unxv)) {
            coin::join(&mut merged, vector::pop_back(&mut unxv));
        };
        balance::join(&mut v.staked_unxv, coin::into_balance(merged));
        vector::destroy_empty(unxv);
    }
    
    public fun unstake_unxv<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        if (amount == 0) { return };
        let out_balance = balance::split(&mut v.staked_unxv, amount);
        transfer::public_transfer(coin::from_balance(out_balance, ctx), v.manager);
    }
    
    public fun current_unxv_stake<C>(v: &Vault<C>): u64 { balance::value(&v.staked_unxv) }

    fun current_tier_index<C>(r: &VaultsRegistry, v: &Vault<C>): u64 {
        let staked = balance::value(&v.staked_unxv);
        let mut tier: u64 = 0;
        let n = vector::length(&r.tier_thresholds_unxv);
        let mut i = 0; while (i < n) { let th = *vector::borrow(&r.tier_thresholds_unxv, i); if (staked >= th) { tier = i as u64; }; i = i + 1; };
        tier
    }

    fun enforce_param_cooldown<C>(v: &Vault<C>) {
        let now = 0u64;
        let next = v.last_param_update_ms + v.timelocks.param_cooldown_sec * 1000;
        assert!(now >= next, E_TOO_SOON);
    }
    
    fun mark_param_update<C>(v: &mut Vault<C>) {
        v.last_param_update_ms = 0u64;
    }

    public fun set_fee_cfg<C>(
        _cfg: &CollateralConfig<C>,
        r: &VaultsRegistry,
        v: &mut Vault<C>,
        fee: FeeConfig,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        enforce_param_cooldown(v);
        let tier = current_tier_index(r, v);
        if (vector::length(&r.tier_perf_ceiling_bps) > 0) {
            let cap = *vector::borrow(&r.tier_perf_ceiling_bps, tier);
            assert!(fee.performance_bps <= cap, E_OVER_CAP);
        };
        v.fee_cfg = fee;
        mark_param_update(v);
        event::emit(VaultParamsUpdated { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun set_risk_caps<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        caps: VaultRiskCaps,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        enforce_param_cooldown(v);
        v.risk_caps = caps;
        mark_param_update(v);
        event::emit(VaultParamsUpdated { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }
    
    public fun set_timelocks<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        t: Timelocks,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        enforce_param_cooldown(v);
        v.timelocks = t;
        mark_param_update(v);
        event::emit(VaultParamsUpdated { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }
    
    public fun set_required_stake_bps<C>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        bps: u64,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER);
        enforce_param_cooldown(v);
        v.required_stake_bps = bps;
        mark_param_update(v);
        event::emit(VaultParamsUpdated { vault_id: object::id(v), by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun set_cap_dex<C>(_cfg: &CollateralConfig<C>, v: &mut Vault<C>, key: String, cap_usd: u64, ctx: &TxContext) { assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER); enforce_param_cooldown(v); table::add(&mut v.dex_caps_usd, key, cap_usd); mark_param_update(v); }
    public fun set_cap_synth<C>(_cfg: &CollateralConfig<C>, v: &mut Vault<C>, key: String, cap_usd: u64, ctx: &TxContext) { assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER); enforce_param_cooldown(v); table::add(&mut v.synth_caps_usd, key, cap_usd); mark_param_update(v); }
    public fun set_cap_perps<C>(_cfg: &CollateralConfig<C>, v: &mut Vault<C>, key: String, cap_usd: u64, ctx: &TxContext) { assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER); enforce_param_cooldown(v); table::add(&mut v.perps_caps_usd, key, cap_usd); mark_param_update(v); }
    public fun set_cap_futures<C>(_cfg: &CollateralConfig<C>, v: &mut Vault<C>, key: String, cap_usd: u64, ctx: &TxContext) { assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER); enforce_param_cooldown(v); table::add(&mut v.futures_caps_usd, key, cap_usd); mark_param_update(v); }
    public fun set_cap_gas<C>(_cfg: &CollateralConfig<C>, v: &mut Vault<C>, key: String, cap_usd: u64, ctx: &TxContext) { assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER); enforce_param_cooldown(v); table::add(&mut v.gas_caps_usd, key, cap_usd); mark_param_update(v); }
    public fun set_cap_options<C>(_cfg: &CollateralConfig<C>, v: &mut Vault<C>, key: String, cap_usd: u64, ctx: &TxContext) { assert!(tx_context::sender(ctx) == v.manager, E_NOT_MANAGER); enforce_param_cooldown(v); table::add(&mut v.options_caps_usd, key, cap_usd); mark_param_update(v); }

    fun enforce_cap_key<C>(v: &Vault<C>, table: &Table<String, u64>, key: &String, notional_usd: u64) {
        let cap = if (table::contains(table, *key)) { *table::borrow(table, *key) } else { v.risk_caps.max_trade_notional_usd };
        if (cap > 0) { assert!(notional_usd <= cap, E_OVER_CAP); }
    }

    public fun exec_dex_place_buy<C, Base>(
        _cfg: &CollateralConfig<C>,
        v: &mut Vault<C>,
        _dex_cfg: &DexConfig,
        price: u64,
        size_base: u64,
        cap_key: String,
        _expiry_ms: u64,
        _ctx: &mut TxContext
    ): CoinOrderBuy<Base, C> {
        assert_active_and_executor(v, _ctx);
        let need = price * size_base;
        enforce_cap_key(v, &v.dex_caps_usd, &cap_key, need);
        let _escrow_balance = balance::split(&mut v.balance, need);
        event::emit(StrategyExecuted { vault_id: object::id(v), template_id: v.template_id, op: b"dex_place_buy".to_string(), notional_usd: need, success: true, timestamp: 0u64 });
        abort 999
    }

    public fun exec_dex_place_sell<Base>(
        v: &mut Vault<Base>,
        dex_cfg: &DexConfig,
        price: u64,
        size_base: u64,
        cap_key: String,
        expiry_ms: u64,
        ctx: &mut TxContext
    ): CoinOrderSell<Base> {
        assert_active_and_executor(v, ctx);
        let notional = price * size_base;
        enforce_cap_key(v, &v.dex_caps_usd, &cap_key, notional);
        let have = balance::value(&v.balance);
        assert!(have >= size_base, E_ZERO_AMOUNT);
        let escrow_balance = balance::split(&mut v.balance, size_base);
        let order = Dex::place_coin_sell_order<Base>(dex_cfg, price, size_base, coin::from_balance(escrow_balance, ctx), expiry_ms, ctx);
        event::emit(StrategyExecuted { vault_id: object::id(v), template_id: v.template_id, op: b"dex_place_sell".to_string(), notional_usd: notional, success: true, timestamp: 0u64 });
        order
    }

    public fun exec_dex_cancel_buy<C, Base>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        order: Dex::CoinOrderBuy<Base, C>,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        Dex::cancel_coin_buy_order<Base, C>(order, ctx);
        event::emit(StrategyExecuted { vault_id: object::id(v), template_id: v.template_id, op: b"dex_cancel_buy".to_string(), notional_usd: 0, success: true, timestamp: 0u64 });
    }

    public fun exec_dex_cancel_sell<Base>(
        v: &Vault<Base>,
        order: Dex::CoinOrderSell<Base>,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        Dex::cancel_coin_sell_order<Base>(order, ctx);
        event::emit(StrategyExecuted { vault_id: object::id(v), template_id: v.template_id, op: b"dex_cancel_sell".to_string(), notional_usd: 0, success: true, timestamp: 0u64 });
    }

    public fun exec_dex_match<C, Base>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        dex_cfg: &mut DexConfig,
        buy: &mut Dex::CoinOrderBuy<Base, C>,
        sell: &mut Dex::CoinOrderSell<Base>,
        max_fill_base: u64,
        taker_is_buyer: bool,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        min_price: u64,
        max_price: u64,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let worst_notional = max_price * max_fill_base;
        enforce_cap_key(v, &v.dex_caps_usd, &cap_key, worst_notional);
        Dex::match_coin_orders<Base, C>(dex_cfg, buy, sell, max_fill_base, taker_is_buyer, unxv_payment, unxv_price, oracle_cfg, clock, treasury, min_price, max_price, ctx);
        event::emit(StrategyExecuted { vault_id: object::id(v), template_id: v.template_id, op: b"dex_match".to_string(), notional_usd: worst_notional, success: true, timestamp: 0u64 });
    }

    public fun exec_synth_place_order<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &SynthRegistry,
        synth_vault: &CollateralVault<C>,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        cap_key: String,
        expiry_ms: u64,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let notional = price * size; enforce_cap_key(v, &v.synth_caps_usd, &cap_key, notional);
        Synth::place_limit_order(reg, synth_vault, symbol, side, price, size, expiry_ms, ctx);
    }

    public fun exec_synth_cancel_order<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        order: &mut Order,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        Synth::cancel_order(order, ctx);
    }

    public fun exec_synth_match<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        buy: &mut Order,
        sell: &mut Order,
        buyer_vault: &mut CollateralVault<C>,
        seller_vault: &mut CollateralVault<C>,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        taker_is_buyer: bool,
        min_price: u64,
        max_price: u64,
        treasury: &mut Treasury<C>,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let worst_notional = max_price * (if (Synth::get_order_remaining(buy) < Synth::get_order_remaining(sell)) { Synth::get_order_remaining(buy) } else { Synth::get_order_remaining(sell) });
        enforce_cap_key(v, &v.synth_caps_usd, &cap_key, worst_notional);
        Synth::match_orders(reg, oracle_cfg, clock, price_info, buy, sell, buyer_vault, seller_vault, unxv_payment, unxv_price, taker_is_buyer, min_price, max_price, treasury, ctx);
    }

    public fun exec_perps_record_fill<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &mut PerpsRegistry,
        market: &mut PerpMarket,
        price_micro_usd: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_usd_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        fee_payment: Coin<C>,
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let notional = size * price_micro_usd;
        enforce_cap_key(v, &v.perps_caps_usd, &cap_key, notional);
        Perps::record_fill(_cfg, reg, market, price_micro_usd, size, taker_is_buyer, maker, unxv_payment, unxv_usd_price, oracle_cfg, clock, treasury, fee_payment, oi_increase, min_price, max_price, ctx);
    }

    public fun exec_futures_record_fill<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &mut FuturesRegistry,
        market: &mut FuturesContract,
        price_micro_usd: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        fee_payment: Coin<C>,
        oi_increase: bool,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let notional = size * price_micro_usd;
        enforce_cap_key(v, &v.futures_caps_usd, &cap_key, notional);
        Futures::record_fill(_cfg, reg, market, price_micro_usd, size, taker_is_buyer, maker, unxv_payment, unxv_price, oracle_cfg, clock, treasury, fee_payment, oi_increase, ctx);
    }

    public fun exec_gas_record_fill<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &mut GasFuturesRegistry,
        market: &mut GasFuturesContract,
        price_micro_usd_per_gas: u64,
        size: u64,
        taker_is_buyer: bool,
        maker: address,
        unxv_payment: vector<Coin<UNXV>>,
        sui_usd_price: &PriceInfoObject,
        unxv_usd_price: &PriceInfoObject,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        fee_payment: Coin<C>,
        oi_increase: bool,
        min_price: u64,
        max_price: u64,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let notional = size * price_micro_usd_per_gas;
        enforce_cap_key(v, &v.gas_caps_usd, &cap_key, notional);
        GasFutures::record_gas_fill(_cfg, reg, market, price_micro_usd_per_gas, size, taker_is_buyer, maker, unxv_payment, sui_usd_price, unxv_usd_price, oracle_cfg, clock, treasury, fee_payment, oi_increase, min_price, max_price, ctx);
    }

    public fun exec_options_place_short_offer<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        market: &OptionMarket,
        quantity: u64,
        _min_premium_per_unit: u64,
        _collateral: Coin<C>,
        cap_key: String,
        ctx: &mut TxContext
    ): ShortOffer<C> {
        assert_active_and_executor(v, ctx);
        let notional = quantity * Opt::get_market_strike_price(market);
        enforce_cap_key(v, &v.options_caps_usd, &cap_key, notional);
        abort 999
    }

    public fun exec_options_place_premium_escrow<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        _market: &mut OptionMarket,
        quantity: u64,
        premium_per_unit: u64,
        _premium_payment: Coin<C>,
        _expiry_cancel_ms: u64,
        cap_key: String,
        ctx: &mut TxContext
    ): PremiumEscrow<C> {
        assert_active_and_executor(v, ctx);
        let notional = quantity * premium_per_unit;
        enforce_cap_key(v, &v.options_caps_usd, &cap_key, notional);
        abort 999
    }

    public fun exec_options_match_offer_and_escrow<C>(
        cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        offer: &mut ShortOffer<C>,
        escrow: &mut PremiumEscrow<C>,
        max_fill_qty: u64,
        unxv_payment: Coin<UNXV>,
        treasury: &mut Treasury<C>,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        unxv_price: &PriceInfoObject,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let notional = max_fill_qty * Opt::get_market_strike_price(market);
        enforce_cap_key(v, &v.options_caps_usd, &cap_key, notional);
        Opt::match_offer_and_escrow_public(cfg, reg, market, offer, escrow, max_fill_qty, unxv_payment, treasury, oracle_cfg, clock, unxv_price, ctx);
    }

    public fun exec_options_close_by_premium<C>(
        _cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        _reg: &mut OptionsRegistry,
        _market: &mut OptionMarket,
        _long_pos: &mut OptionPosition<C>,
        _short_pos: &mut OptionPosition<C>,
        quantity: u64,
        premium_per_unit: u64,
        _payer_is_long: bool,
        _premium_payment: Coin<C>,
        _unxv_payment: vector<Coin<UNXV>>,
        _oracle_cfg: &OracleConfig,
        _clock: &Clock,
        _unxv_price: &PriceInfoObject,
        _treasury: &mut Treasury<C>,
        cap_key: String,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        let notional = quantity * premium_per_unit;
        enforce_cap_key(v, &v.options_caps_usd, &cap_key, notional);
        abort 999
    }

    public fun exec_options_settle_cash<C>(
        cfg: &CollateralConfig<C>,
        v: &Vault<C>,
        reg: &mut OptionsRegistry,
        market: &mut OptionMarket,
        long_pos: &mut OptionPosition<C>,
        short_pos: &mut OptionPosition<C>,
        quantity: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert_active_and_executor(v, ctx);
        Opt::settle_positions_cash(cfg, reg, market, long_pos, short_pos, quantity, treasury, ctx);
    }

    public fun vault_status<C>(v: &Vault<C>): (u8, address, u8, String) { (v.vault_type, v.manager, v.status, v.template_id) }
    public fun vault_caps<C>(v: &Vault<C>): (u64, u64) { (v.risk_caps.max_trade_notional_usd, v.risk_caps.max_slippage_bps) }
    public fun vault_fee_cfg<C>(v: &Vault<C>): (u64, u64, u64, u64) { (v.fee_cfg.performance_bps, v.fee_cfg.management_bps, v.fee_cfg.protocol_skim_bps, v.fee_cfg.max_performance_bps) }
    public fun vault_executors<C>(v: &Vault<C>): &VecSet<address> { &v.executor_addrs }
    public fun vault_balance<C>(v: &Vault<C>): u64 { balance::value(&v.balance) }
    public fun managed_stats<C>(v: &Vault<C>): (u64, u64, u64, u64, bool) { (v.total_shares, v.manager_shares, v.required_stake_bps, v.high_water_mark_micro_usd_per_share, stake_ok(v)) }
    public fun vault_nav_micro_usd_per_share<C>(v: &Vault<C>): u64 { nav_micro_usd_per_share(v) }
    public fun vault_current_tier_index<C>(r: &VaultsRegistry, v: &Vault<C>): u64 { current_tier_index(r, v) }
    public fun vault_timelocks<C>(v: &Vault<C>): (u64, u64) { (v.timelocks.withdraw_notice_sec, v.timelocks.param_cooldown_sec) }
    public fun vault_param_cooldown_next_ms<C>(v: &Vault<C>): u64 { v.last_param_update_ms + v.timelocks.param_cooldown_sec * 1000 }
    public fun vault_hwm<C>(v: &Vault<C>): u64 { v.high_water_mark_micro_usd_per_share }
    public fun vault_required_stake_bps<C>(v: &Vault<C>): u64 { v.required_stake_bps }
    public fun get_cap_dex_key<C>(v: &Vault<C>, _key: &String): u64 { v.risk_caps.max_trade_notional_usd }
    public fun get_cap_synth_key<C>(v: &Vault<C>, _key: &String): u64 { v.risk_caps.max_trade_notional_usd }
    public fun get_cap_perps_key<C>(v: &Vault<C>, _key: &String): u64 { v.risk_caps.max_trade_notional_usd }
    public fun get_cap_futures_key<C>(v: &Vault<C>, _key: &String): u64 { v.risk_caps.max_trade_notional_usd }
    public fun get_cap_gas_key<C>(v: &Vault<C>, _key: &String): u64 { v.risk_caps.max_trade_notional_usd }
    public fun get_cap_options_key<C>(v: &Vault<C>, _key: &String): u64 { v.risk_caps.max_trade_notional_usd }
    public fun tier_config_lengths(r: &VaultsRegistry): u64 { vector::length(&r.tier_thresholds_unxv) as u64 }
    public fun tier_threshold_at(r: &VaultsRegistry, idx: u64): u64 { *vector::borrow(&r.tier_thresholds_unxv, idx) }
    public fun tier_perf_ceiling_at(r: &VaultsRegistry, idx: u64): u64 { *vector::borrow(&r.tier_perf_ceiling_bps, idx) }

    public entry fun init_vault_display<C>(publisher: &Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<Vault<C>>(publisher, ctx);
        disp.add(b"name".to_string(), b"Unxversal Vault".to_string());
        disp.add(b"description".to_string(), b"Unified vault for liquidity and managed strategies".to_string());
        disp.update_version();
        transfer::public_transfer(disp, tx_context::sender(ctx));
    }
}