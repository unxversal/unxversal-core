/* legacy secondary module removed */
module unxversal::vaults {
    /*******************************
    * Unxversal Vaults – Liquidity and Trader Vaults
    * - Two separate registries: LiquidityRegistry and TraderVaultRegistry
    * - Admin gating via synthetics::SynthRegistry allow-list (AdminCap UX token)
    * - Treasury for fees is Collateral/UNXV
    * - All deposits/withdrawals use the chosen collateral
    * - LiquidityVault<Base, C>: holds Coin<C> and Base; places vault-safe orders on DEX
    * - TraderVault<C>: collateral-only, share accounting, manager stake, HWM performance fees
    * - Rich events and read-only helpers
    *******************************/
    
    use sui::event;
    use sui::clock::Clock;
    use sui::coin::{Self as coin, Coin};
    use std::string::{Self as string, String};
    use sui::table::{Self as table, Table};
    
    use sui::clock; // for timestamp_ms

    // Collateral coin is generic; avoid direct USDC dependency
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{Self as SynthMod, SynthRegistry, AdminCap};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::oracle::{OracleConfig, get_price_scaled_1e6};
    use switchboard::aggregator::Aggregator;
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
    fun assert_is_admin(registry: &SynthRegistry, addr: address) { assert!(SynthMod::is_admin(registry, addr), E_NOT_ADMIN); }

    fun clone_string(s: &String): String {
        let src = string::as_bytes(s);
        let mut out = vector::empty<u8>();
        let mut i = 0; let n = vector::length(src);
        while (i < n) { vector::push_back(&mut out, *vector::borrow(src, i)); i = i + 1; };
        string::utf8(out)
    }

    /*******************************
    * Liquidity Registry
    *******************************/
    public struct LiquidityRegistry has key, store {
        id: UID,
        treasury_id: ID,
        paused: bool,
        // Global default limits
        min_cash_bps: u64,              // e.g., 500 = 5% minimum collateral buffer
        default_management_fee_bps: u64, // reserved for future use
    }

    public struct LiquidityVaultCreated has copy, drop { vault_id: ID, manager: address, base_symbol: String, created_at: u64 }
    public struct LPDeposit has copy, drop { vault_id: ID, lp: address, collateral_amount: u64, shares_issued: u64, total_shares_after: u64, timestamp: u64 }
    public struct LPWithdrawal has copy, drop { vault_id: ID, lp: address, shares_redeemed: u64, collateral_paid: u64, base_paid: u64, pro_rata_mode: bool, timestamp: u64 }
    public struct LiquidityVaultShutdown has copy, drop { vault_id: ID, by: address, timestamp: u64 }
    // Removed unused VaultDexOrderTracked (order tracking handled via DEX events and active_orders IDs)

    public struct LiquidityVault<phantom Base: store, phantom C: store> has key, store {
        id: UID,
        manager: address,
        base_symbol: String,
        // Balances
        usdc: Coin<C>,
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
        protocol_perf_fee_bps: u64,     // protocol cut of perf fees (collateral) to Treasury
    }

    public struct TraderVaultCreated has copy, drop { vault_id: ID, manager: address, created_at: u64, initial_stake: u64, required_stake_bps: u64 }
    public struct InvestorDeposit has copy, drop { vault_id: ID, investor: address, collateral_amount: u64, shares_issued: u64, total_shares_after: u64, timestamp: u64 }
    public struct InvestorWithdrawal has copy, drop { vault_id: ID, investor: address, shares_redeemed: u64, collateral_paid: u64, timestamp: u64 }
    public struct StakeUpdated has copy, drop { vault_id: ID, manager: address, manager_shares: u64, total_shares: u64, stake_bps: u64, timestamp: u64 }
    public struct StakeDeficit has copy, drop { vault_id: ID, manager: address, required_bps: u64, current_bps: u64, timestamp: u64 }
    public struct PerformanceFeesCalculated has copy, drop { vault_id: ID, hwm_before_1e6: u64, hwm_after_1e6: u64, perf_fee_bps: u64, manager_fee_collateral: u64, protocol_fee_collateral: u64, timestamp: u64 }
    public struct TraderVaultShutdown has copy, drop { vault_id: ID, by: address, timestamp: u64 }

    public struct TraderVault<phantom C: store> has key, store {
        id: UID,
        manager: address,
        // Balances
        usdc: Coin<C>,
        // Shares
        total_shares: u64,
        shares: Table<address, u64>,
        manager_shares: u64,
        // Fees & HWM
        hwm_nav_per_share_1e6: u64,    // high water mark in micro-USD per share
        perf_fee_bps: u64,             // manager
        // Accrued fees payable when liquidity allows
        accrued_manager_fee_collateral: u64,
        accrued_protocol_fee_collateral: u64,
        // Status
        shutdown: bool,
        created_at_ms: u64,
    }

    /*******************************
    * Registry initialization
    *******************************/
    public fun init_liquidity_registry<C>(registry: &SynthRegistry, treasury: &Treasury<C>, ctx: &mut TxContext) {
        assert_is_admin(registry, ctx.sender());
        let r = LiquidityRegistry { id: object::new(ctx), treasury_id: object::id(treasury), paused: false, min_cash_bps: 500, default_management_fee_bps: 0 };
        transfer::share_object(r);
    }

    public fun init_trader_registry<C>(registry: &SynthRegistry, treasury: &Treasury<C>, ctx: &mut TxContext) {
        assert_is_admin(registry, ctx.sender());
        let r = TraderVaultRegistry { id: object::new(ctx), treasury_id: object::id(treasury), paused: false, min_manager_stake_bps: 500, default_perf_fee_bps: 1000, protocol_perf_fee_bps: 0 };
        transfer::share_object(r);
    }

    /*******************************
    * Admin setters (via SynthRegistry allow-list)
    *******************************/
    public fun set_liquidity_min_cash(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut LiquidityRegistry, bps: u64, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.min_cash_bps = bps; }
    public fun pause_liquidity(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut LiquidityRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = true; }
    public fun resume_liquidity(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut LiquidityRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = false; }

    public fun set_trader_params(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut TraderVaultRegistry, min_stake_bps: u64, perf_fee_bps: u64, protocol_fee_bps: u64, _ctx: &TxContext) {
        assert_is_admin(registry, _ctx.sender());
        cfg.min_manager_stake_bps = min_stake_bps;
        cfg.default_perf_fee_bps = perf_fee_bps;
        cfg.protocol_perf_fee_bps = protocol_fee_bps;
    }
    public fun pause_trader(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut TraderVaultRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = true; }
    public fun resume_trader(_admin: &AdminCap, registry: &SynthRegistry, cfg: &mut TraderVaultRegistry, _ctx: &TxContext) { assert_is_admin(registry, _ctx.sender()); cfg.paused = false; }

    /*******************************
    * LiquidityVault lifecycle
    *******************************/
    public fun create_liquidity_vault<Base: store, C: store>(
        cfg: &LiquidityRegistry,
        base_symbol: String,
        clock_obj: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let base_for_struct = clone_string(&base_symbol);
        let v = LiquidityVault<Base, C> {
            id: object::new(ctx),
            manager: ctx.sender(),
            base_symbol: base_for_struct,
            usdc: coin::zero<C>(ctx),
            base: coin::zero<Base>(ctx),
            total_shares: 0,
            shares: table::new<address, u64>(ctx),
            min_cash_bps: cfg.min_cash_bps,
            shutdown: false,
            active_orders: vector::empty<ID>(),
            last_rebalance_ms: clock::timestamp_ms(clock_obj),
            created_at_ms: clock::timestamp_ms(clock_obj),
        };
        event::emit(LiquidityVaultCreated { vault_id: object::id(&v), manager: v.manager, base_symbol, created_at: v.created_at_ms });
        transfer::share_object(v)
    }

    

    public fun lp_deposit_collateral<Base: store, C: store>(
        v: &mut LiquidityVault<Base, C>,
        cfg: &LiquidityRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        base_price: &Aggregator,
        amount: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused && !v.shutdown, E_PAUSED);
        let deposit_amt = coin::value(&amount);
        assert!(deposit_amt > 0, E_ZERO_AMOUNT);
        // Pre-NAV
        let nav_before = nav_liquidity_collateral_1e6(v, oracle_cfg, clock, base_price);
        // Merge collateral
        coin::join(&mut v.usdc, amount);
        let _nav_after = nav_liquidity_collateral_1e6(v, oracle_cfg, clock, base_price);
        let shares_issued = if (v.total_shares == 0) { deposit_amt } else { ((deposit_amt as u128) * (v.total_shares as u128) * 1_000_000u128 / (nav_before as u128)) as u64 };
        v.total_shares = v.total_shares + shares_issued;
        let prev = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), prev + shares_issued);
        event::emit(LPDeposit { vault_id: object::id(v), lp: ctx.sender(), collateral_amount: deposit_amt, shares_issued, total_shares_after: v.total_shares, timestamp: clock::timestamp_ms(clock) });
    }

    fun nav_liquidity_collateral_1e6<Base: store, C: store>(v: &LiquidityVault<Base, C>, oracle_cfg: &OracleConfig, clock: &Clock, base_price: &Aggregator): u64 {
        let collateral_v = coin::value(&v.usdc) as u128;
        let base_amt = coin::value(&v.base) as u128;
        let px: u128 = if (base_amt == 0u128) { 0u128 } else { get_price_scaled_1e6(oracle_cfg, clock, base_price) as u128 };
        let nav_u128 = (collateral_v * 1_000_000u128) + (base_amt * px);
        nav_u128 as u64
    }

    public fun lp_withdraw_collateral<Base: store, C: store>(
        v: &mut LiquidityVault<Base, C>,
        cfg: &LiquidityRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        base_price: &Aggregator,
        shares_to_redeem: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!cfg.paused, E_PAUSED);
        let mut bal = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        assert!(bal >= shares_to_redeem && shares_to_redeem > 0, E_NOT_INVESTOR);
        let nav = nav_liquidity_collateral_1e6(v, oracle_cfg, clock, base_price) as u128;
        let payout_collateral = (nav * (shares_to_redeem as u128) / (v.total_shares as u128)) / 1_000_000u128;
        let available = coin::value(&v.usdc) as u128;
        assert!(available >= payout_collateral, E_INSUFFICIENT_LIQUIDITY);
        let coin_out = coin::split(&mut v.usdc, payout_collateral as u64, ctx);
        // Update shares
        bal = bal - shares_to_redeem;
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares_to_redeem;
        event::emit(LPWithdrawal { vault_id: object::id(v), lp: ctx.sender(), shares_redeemed: shares_to_redeem, collateral_paid: payout_collateral as u64, base_paid: 0, pro_rata_mode: false, timestamp: clock::timestamp_ms(clock) });
        coin_out
    }

    /// Emergency pro-rata withdrawal distributes current collateral and Base holdings proportionally
    public fun lp_emergency_withdraw_pro_rata<Base: store, C: store>(
        v: &mut LiquidityVault<Base, C>,
        shares_to_redeem: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<C>, Coin<Base>) {
        assert!(v.shutdown, E_PAUSED);
        let mut bal = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        assert!(bal >= shares_to_redeem && shares_to_redeem > 0, E_NOT_INVESTOR);
        let collateral_total = coin::value(&v.usdc);
        let base_total = coin::value(&v.base);
        let collateral_pay = (collateral_total as u128) * (shares_to_redeem as u128) / (v.total_shares as u128);
        let base_pay = (base_total as u128) * (shares_to_redeem as u128) / (v.total_shares as u128);
        let out_collateral = if (collateral_pay > 0) { coin::split(&mut v.usdc, collateral_pay as u64, ctx) } else { coin::zero<C>(ctx) };
        let out_base = if (base_pay > 0) { coin::split(&mut v.base, base_pay as u64, ctx) } else { coin::zero<Base>(ctx) };
        bal = bal - shares_to_redeem;
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares_to_redeem;
        event::emit(LPWithdrawal { vault_id: object::id(v), lp: ctx.sender(), shares_redeemed: shares_to_redeem, collateral_paid: coin::value(&out_collateral), base_paid: coin::value(&out_base), pro_rata_mode: true, timestamp: clock::timestamp_ms(clock) });
        (out_collateral, out_base)
    }

    public fun shutdown_liquidity_vault<Base: store, C: store>(v: &mut LiquidityVault<Base, C>, clock: &Clock, ctx: &TxContext) { assert!(v.manager == ctx.sender(), E_NOT_MANAGER); v.shutdown = true; event::emit(LiquidityVaultShutdown { vault_id: object::id(v), by: ctx.sender(), timestamp: clock::timestamp_ms(clock) }); }

    /*******************************
    * LiquidityVault – DEX integration (vault-safe)
    *******************************/
    public fun place_vault_sell<Base: store, C: store>(cfg: &DexConfig, v: &mut LiquidityVault<Base, C>, price: u64, size_base: u64, expiry_ms: u64, _clock: &Clock, ctx: &mut TxContext) {
        assert!(!v.shutdown, E_SHUTDOWN);
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        Dex::place_vault_sell_order<Base>(cfg, price, size_base, &mut v.base, expiry_ms, ctx);
    }

    public fun place_vault_buy<Base: store, C: store>(cfg: &DexConfig, v: &mut LiquidityVault<Base, C>, price: u64, size_base: u64, expiry_ms: u64, _clock: &Clock, ctx: &mut TxContext) {
        assert!(!v.shutdown, E_SHUTDOWN);
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        // Enforce min cash buffer pre-escrow
        let collateral_before = coin::value(&v.usdc);
        let collateral_needed = price * size_base;
        assert!(collateral_before >= collateral_needed, E_INSUFFICIENT_LIQUIDITY);
        Dex::place_vault_buy_order<Base, C>(cfg, price, size_base, &mut v.usdc, expiry_ms, ctx);
    }

    public fun cancel_vault_sell<Base: store, C: store>(v: &mut LiquidityVault<Base, C>, order: VaultOrderSell<Base>, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        Dex::cancel_vault_sell_order<Base>(order, &mut v.base, ctx);
    }

    public fun cancel_vault_buy<Base: store, C: store>(v: &mut LiquidityVault<Base, C>, order: VaultOrderBuy<Base, C>, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        Dex::cancel_vault_buy_order<Base, C>(order, &mut v.usdc, ctx);
    }

    public fun match_vault_orders<Base: store, C: store>(
        cfg: &mut DexConfig,
        v_buy: &mut LiquidityVault<Base, C>,
        v_sell: &mut LiquidityVault<Base, C>,
        buy: &mut VaultOrderBuy<Base, C>,
        sell: &mut VaultOrderSell<Base>,
        max_fill_base: u64,
        taker_is_buyer: bool,
        unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &Aggregator,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        treasury: &mut Treasury<C>,
        min_price: u64,
        max_price: u64,
        ctx: &mut TxContext
    ) {
        Dex::match_vault_orders<Base, C>(
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
            b"VAULT".to_string(),
            clone_string(&v_buy.base_symbol),
            b"COLLATERAL".to_string(),
            ctx
        );
    }

    /*******************************
    * TraderVault lifecycle and accounting (collateral-only)
    *******************************/
    public fun create_trader_vault<C: store>(
        cfg: &TraderVaultRegistry,
        initial_stake: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused, E_PAUSED);
        let stake_amt = coin::value(&initial_stake);
        assert!(stake_amt > 0, E_ZERO_AMOUNT);
        let shares_tbl = table::new<address, u64>(ctx);
        let manager_addr = ctx.sender();
        let mut v = TraderVault<C> {
            id: object::new(ctx),
            manager: manager_addr,
            usdc: coin::zero<C>(ctx),
            total_shares: 0,
            shares: shares_tbl,
            manager_shares: 0,
            hwm_nav_per_share_1e6: 1_000_000,
            perf_fee_bps: cfg.default_perf_fee_bps,
            accrued_manager_fee_collateral: 0,
            accrued_protocol_fee_collateral: 0,
            shutdown: false,
            created_at_ms: sui::tx_context::epoch_timestamp_ms(ctx),
        };
        // Initial shares = stake amount
        coin::join(&mut v.usdc, initial_stake);
        v.total_shares = stake_amt;
        v.manager_shares = stake_amt;
        if (table::contains(&v.shares, manager_addr)) { let _ = table::remove(&mut v.shares, manager_addr); };
        table::add(&mut v.shares, manager_addr, stake_amt);
        event::emit(TraderVaultCreated { vault_id: object::id(&v), manager: manager_addr, created_at: v.created_at_ms, initial_stake: stake_amt, required_stake_bps: cfg.min_manager_stake_bps });
        transfer::share_object(v)
    }

    fun manager_stake_bps<C: store>(v: &TraderVault<C>): u64 {
        if (v.total_shares == 0) { return 0 };
        return (v.manager_shares * 10_000) / v.total_shares
    }

    /// Investors can deposit only if manager stake ≥ required bps
    public fun investor_deposit<C: store>(
        v: &mut TraderVault<C>,
        cfg: &TraderVaultRegistry,
        amount: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(!cfg.paused && !v.shutdown, E_PAUSED);
        // Check current stake before deposit
        let stake_bps = manager_stake_bps(v);
        if (stake_bps < cfg.min_manager_stake_bps) { event::emit(StakeDeficit { vault_id: object::id(v), manager: v.manager, required_bps: cfg.min_manager_stake_bps, current_bps: stake_bps, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); abort E_STAKE_DEFICIT };
        let deposit_amt = coin::value(&amount);
        assert!(deposit_amt > 0, E_ZERO_AMOUNT);
        let shares_issued = if (v.total_shares == 0) { deposit_amt } else { deposit_amt * v.total_shares / coin::value(&v.usdc) };
        coin::join(&mut v.usdc, amount);
        v.total_shares = v.total_shares + shares_issued;
        let prev = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), prev + shares_issued);
        event::emit(InvestorDeposit { vault_id: object::id(v), investor: ctx.sender(), collateral_amount: deposit_amt, shares_issued, total_shares_after: v.total_shares, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Manager can add stake anytime (increases manager_shares proportionally)
    public fun manager_add_stake<C: store>(v: &mut TraderVault<C>, stake: Coin<C>, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender() && !v.shutdown, E_NOT_MANAGER);
        let amt = coin::value(&stake);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let shares = if (v.total_shares == 0) { amt } else { amt * v.total_shares / coin::value(&v.usdc) };
        coin::join(&mut v.usdc, stake);
        v.total_shares = v.total_shares + shares;
        v.manager_shares = v.manager_shares + shares;
        let prev = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), prev + shares);
        let bps = manager_stake_bps(v);
        event::emit(StakeUpdated { vault_id: object::id(v), manager: v.manager, manager_shares: v.manager_shares, total_shares: v.total_shares, stake_bps: bps, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
    }

    /// Manager unstake: only allowed if remains ≥ required bps or vault is shutdown
    public fun manager_unstake<C: store>(v: &mut TraderVault<C>, cfg: &TraderVaultRegistry, shares_to_burn: u64, ctx: &mut TxContext) {
        assert!(v.manager == ctx.sender(), E_NOT_MANAGER);
        let mgr_pos = v.manager_shares;
        assert!(shares_to_burn > 0 && mgr_pos >= shares_to_burn, E_NOT_INVESTOR);
        if (!v.shutdown) {
            // ensure post-unstake >= required
            let total_post = v.total_shares - shares_to_burn;
            let mgr_post = v.manager_shares - shares_to_burn;
            let bps_post = if (total_post == 0) { 0 } else { (mgr_post * 10_000) / total_post };
            assert!(bps_post >= cfg.min_manager_stake_bps, E_STAKE_DEFICIT);
        };
        // redeem pro-rata collateral
        let payout = (coin::value(&v.usdc) as u128) * (shares_to_burn as u128) / (v.total_shares as u128);
        let coin_out = coin::split(&mut v.usdc, payout as u64, ctx);
        v.manager_shares = v.manager_shares - shares_to_burn;
        v.total_shares = v.total_shares - shares_to_burn;
        let prev = *table::borrow(&v.shares, ctx.sender());
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), prev - shares_to_burn);
        let bps = manager_stake_bps(v);
        event::emit(StakeUpdated { vault_id: object::id(v), manager: v.manager, manager_shares: v.manager_shares, total_shares: v.total_shares, stake_bps: bps, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        transfer::public_transfer(coin_out, ctx.sender());
    }

    public fun investor_withdraw<C: store>(v: &mut TraderVault<C>, shares_to_redeem: u64, ctx: &mut TxContext): Coin<C> {
        let mut bal = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        assert!(shares_to_redeem > 0 && bal >= shares_to_redeem, E_NOT_INVESTOR);
        let payout = (coin::value(&v.usdc) as u128) * (shares_to_redeem as u128) / (v.total_shares as u128);
        let available = coin::value(&v.usdc) as u128;
        assert!(available >= payout, E_INSUFFICIENT_LIQUIDITY);
        let coin_out = coin::split(&mut v.usdc, payout as u64, ctx);
        bal = bal - shares_to_redeem;
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares_to_redeem;
        if (ctx.sender() == v.manager) { v.manager_shares = v.manager_shares - shares_to_redeem; };
        event::emit(InvestorWithdrawal { vault_id: object::id(v), investor: ctx.sender(), shares_redeemed: shares_to_redeem, collateral_paid: payout as u64, timestamp: sui::tx_context::epoch_timestamp_ms(ctx) });
        coin_out
    }

    /// Calculate performance fee vs HWM and accrue amounts (not paid out yet)
    public fun crystallize_performance_fee<C: store>(v: &mut TraderVault<C>, cfg: &TraderVaultRegistry, _ctx: &mut TxContext) {
        if (v.total_shares == 0) { return };
        let nav = coin::value(&v.usdc) as u128;
        let nav_per_share_1e6 = (nav * 1_000_000u128 / (v.total_shares as u128)) as u64;
        if (nav_per_share_1e6 <= v.hwm_nav_per_share_1e6) { return };
        let gain_per_share_1e6 = nav_per_share_1e6 - v.hwm_nav_per_share_1e6;
        let gain_total_collateral = (gain_per_share_1e6 as u128) * (v.total_shares as u128) / 1_000_000u128;
        let manager_fee = (gain_total_collateral * (v.perf_fee_bps as u128)) / 10_000u128;
        let protocol_fee = (gain_total_collateral * (cfg.protocol_perf_fee_bps as u128)) / 10_000u128;
        v.accrued_manager_fee_collateral = v.accrued_manager_fee_collateral + (manager_fee as u64);
        v.accrued_protocol_fee_collateral = v.accrued_protocol_fee_collateral + (protocol_fee as u64);
        v.hwm_nav_per_share_1e6 = nav_per_share_1e6;
        event::emit(PerformanceFeesCalculated { vault_id: object::id(v), hwm_before_1e6: v.hwm_nav_per_share_1e6, hwm_after_1e6: nav_per_share_1e6, perf_fee_bps: v.perf_fee_bps, manager_fee_collateral: manager_fee as u64, protocol_fee_collateral: protocol_fee as u64, timestamp: sui::tx_context::epoch_timestamp_ms(_ctx) });
    }

    /// Attempt to pay accrued fees if liquidity allows; protocol fee goes to Treasury
    public fun pay_accrued_fees<C: store>(v: &mut TraderVault<C>, _cfg: &TraderVaultRegistry, treasury: &mut Treasury<C>, ctx: &mut TxContext) {
        let available = coin::value(&v.usdc);
        let pay_manager = if (v.accrued_manager_fee_collateral > available) { available } else { v.accrued_manager_fee_collateral };
        let left = available - pay_manager;
        let pay_protocol = if (v.accrued_protocol_fee_collateral > left) { left } else { v.accrued_protocol_fee_collateral };
        if (pay_manager > 0) {
            let out = coin::split(&mut v.usdc, pay_manager, ctx);
            transfer::public_transfer(out, v.manager);
            v.accrued_manager_fee_collateral = v.accrued_manager_fee_collateral - pay_manager;
        };
        if (pay_protocol > 0) {
            let outp = coin::split(&mut v.usdc, pay_protocol, ctx);
            TreasuryMod::deposit_collateral_ext(treasury, outp, b"perf_fee".to_string(), v.manager, ctx);
            v.accrued_protocol_fee_collateral = v.accrued_protocol_fee_collateral - pay_protocol;
        }
    }

    public fun shutdown_trader_vault<C: store>(v: &mut TraderVault<C>, ctx: &TxContext) { assert!(v.manager == ctx.sender(), E_NOT_MANAGER); v.shutdown = true; event::emit(TraderVaultShutdown { vault_id: object::id(v), by: ctx.sender(), timestamp: sui::tx_context::epoch_timestamp_ms(ctx) }); }

    /*******************************
    * Read-only helpers
    *******************************/
    public fun liquidity_vault_balances<Base: store, C: store>(v: &LiquidityVault<Base, C>): (u64, u64, u64, u64) {
        (coin::value(&v.usdc), coin::value(&v.base), v.total_shares, vector::length(&v.active_orders) as u64)
    }
    public fun liquidity_user_shares<Base: store, C: store>(v: &LiquidityVault<Base, C>, addr: address): u64 { if (table::contains(&v.shares, addr)) { *table::borrow(&v.shares, addr) } else { 0 } }
    public fun liquidity_is_shutdown<Base: store, C: store>(v: &LiquidityVault<Base, C>): bool { v.shutdown }

    public fun trader_nav<C: store>(v: &TraderVault<C>): (u64, u64, u64) { (coin::value(&v.usdc), v.total_shares, v.hwm_nav_per_share_1e6) }
    public fun trader_user_shares<C: store>(v: &TraderVault<C>, addr: address): u64 { if (table::contains(&v.shares, addr)) { *table::borrow(&v.shares, addr) } else { 0 } }
    public fun trader_manager_stake_bps<C: store>(v: &TraderVault<C>): u64 { manager_stake_bps(v) }
}