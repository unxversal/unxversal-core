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