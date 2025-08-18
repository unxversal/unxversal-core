/* unified vaults with protocol-managed manager stake */
module unxversal::vaults {
    use sui::event;
    use sui::clock::Clock;
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};
    use sui::table::{Self as table, Table};
    use sui::clock; // timestamp_ms
    
    use unxversal::unxv::UNXV;
    use unxversal::synthetics::{Self as SynthMod, SynthRegistry, CollateralVault, SynthMarket, SynthEscrow};
    use unxversal::treasury::{Self as TreasuryMod, Treasury};
    use unxversal::dex::{Self as Dex, DexConfig, DexMarket, DexEscrow};
    use unxversal::admin::{Self as AdminMod, AdminRegistry};

    const E_NOT_ADMIN: u64 = 1;
    const E_REGISTRY_PAUSED: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 4;
    const E_NOT_MANAGER: u64 = 5;
    const E_FROZEN: u64 = 6;
    const E_STAKE_TOO_LOW: u64 = 7;
    const E_ACTIVE_VAULTS: u64 = 10;

    fun assert_is_admin(reg_admin: &AdminRegistry, addr: address) { assert!(AdminMod::is_admin(reg_admin, addr), E_NOT_ADMIN); }

    public struct ManagerStakeRegistry has key, store {
        id: UID,
        paused: bool,
        min_stake_unxv: u64,
        stakes: Table<address, Balance<UNXV>>,
        active_vaults: Table<address, u64>,
        frozen: Table<address, bool>,
    }

    public struct StakeDeposited has copy, drop { manager: address, amount: u64, total_after: u64, timestamp: u64 }
    public struct StakeWithdrawn has copy, drop { manager: address, amount: u64, total_after: u64, timestamp: u64 }
    public struct StakeSlashed has copy, drop { manager: address, amount: u64, total_after: u64, timestamp: u64 }
    public struct ManagerFrozen has copy, drop { manager: address, frozen: bool, timestamp: u64 }

    public fun init_manager_stake_registry_admin(reg_admin: &AdminRegistry, min_stake_unxv: u64, ctx: &mut TxContext) {
        assert_is_admin(reg_admin, ctx.sender());
        let rs = ManagerStakeRegistry { id: object::new(ctx), paused: false, min_stake_unxv, stakes: table::new<address, Balance<UNXV>>(ctx), active_vaults: table::new<address, u64>(ctx), frozen: table::new<address, bool>(ctx) };
        transfer::share_object(rs);
    }
    public fun set_min_stake_admin(reg_admin: &AdminRegistry, rs: &mut ManagerStakeRegistry, min_stake_unxv: u64, ctx: &TxContext) { assert_is_admin(reg_admin, ctx.sender()); rs.min_stake_unxv = min_stake_unxv }
    public fun pause_stake_registry_admin(reg_admin: &AdminRegistry, rs: &mut ManagerStakeRegistry, ctx: &TxContext) { assert_is_admin(reg_admin, ctx.sender()); rs.paused = true }
    public fun resume_stake_registry_admin(reg_admin: &AdminRegistry, rs: &mut ManagerStakeRegistry, ctx: &TxContext) { assert_is_admin(reg_admin, ctx.sender()); rs.paused = false }

    public fun stake_unxv(rs: &mut ManagerStakeRegistry, mut coins: vector<Coin<UNXV>>, clock_obj: &Clock, ctx: &mut TxContext) {
        assert!(!rs.paused, E_REGISTRY_PAUSED);
        let mut merged = coin::zero<UNXV>(ctx);
        let mut i = 0u64; while (i < vector::length(&coins)) { let c = vector::pop_back(&mut coins); coin::join(&mut merged, c); i = i + 1; };
        vector::destroy_empty(coins);
        let amt = coin::value(&merged);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let bal = coin::into_balance(merged);
        if (table::contains(&rs.stakes, ctx.sender())) {
            let b = table::borrow_mut(&mut rs.stakes, ctx.sender());
            balance::join(b, bal);
        } else {
            table::add(&mut rs.stakes, ctx.sender(), bal);
        };
        let total_after = balance::value(table::borrow(&rs.stakes, ctx.sender()));
        event::emit(StakeDeposited { manager: ctx.sender(), amount: amt, total_after, timestamp: clock::timestamp_ms(clock_obj) });
    }
    public fun withdraw_stake(rs: &mut ManagerStakeRegistry, amount: u64, clock_obj: &Clock, ctx: &mut TxContext): Coin<UNXV> {
        assert!(!rs.paused, E_REGISTRY_PAUSED);
        let active = if (table::contains(&rs.active_vaults, ctx.sender())) { *table::borrow(&rs.active_vaults, ctx.sender()) } else { 0 };
        assert!(active == 0, E_ACTIVE_VAULTS);
        let b = table::borrow_mut(&mut rs.stakes, ctx.sender());
        let have = balance::value(b);
        assert!(amount > 0 && have >= amount, E_ZERO_AMOUNT);
        let out_bal = balance::split(b, amount);
        let out = coin::from_balance(out_bal, ctx);
        let total_after = balance::value(b);
        event::emit(StakeWithdrawn { manager: ctx.sender(), amount, total_after, timestamp: clock::timestamp_ms(clock_obj) });
        out
    }
    public fun slash_stake_admin(reg_admin: &AdminRegistry, rs: &mut ManagerStakeRegistry, treasury: &mut Treasury<UNXV>, manager: address, amount: u64, clock_obj: &Clock, ctx: &mut TxContext) {
        assert_is_admin(reg_admin, ctx.sender());
        if (!table::contains(&rs.stakes, manager)) { return };
        let b = table::borrow_mut(&mut rs.stakes, manager);
        let have = balance::value(b);
        let take = if (amount <= have) { amount } else { have };
        if (take > 0) {
            let out_bal = balance::split(b, take);
            let out = coin::from_balance(out_bal, ctx);
            let mut v = vector::empty<Coin<UNXV>>(); vector::push_back(&mut v, out);
            TreasuryMod::deposit_unxv(treasury, v, b"stake_slash".to_string(), manager, ctx);
            let total_after = balance::value(b);
            event::emit(StakeSlashed { manager, amount: take, total_after, timestamp: clock::timestamp_ms(clock_obj) });
        }
    }
    public fun set_frozen_admin(reg_admin: &AdminRegistry, rs: &mut ManagerStakeRegistry, manager: address, frozen: bool, clock_obj: &Clock, ctx: &TxContext) { assert_is_admin(reg_admin, ctx.sender()); if (table::contains(&rs.frozen, manager)) { let _ = table::remove(&mut rs.frozen, manager); }; table::add(&mut rs.frozen, manager, frozen); event::emit(ManagerFrozen { manager, frozen, timestamp: clock::timestamp_ms(clock_obj) }) }

    fun assert_manager_active(rs: &ManagerStakeRegistry, manager: address) { let staked = if (table::contains(&rs.stakes, manager)) { balance::value(table::borrow(&rs.stakes, manager)) } else { 0 }; let frozen = if (table::contains(&rs.frozen, manager)) { *table::borrow(&rs.frozen, manager) } else { false }; assert!(staked >= rs.min_stake_unxv, E_STAKE_TOO_LOW); assert!(!frozen, E_FROZEN) }
    fun inc_active(rs: &mut ManagerStakeRegistry, manager: address) { let c = if (table::contains(&rs.active_vaults, manager)) { *table::borrow(&rs.active_vaults, manager) } else { 0 }; if (table::contains(&rs.active_vaults, manager)) { let _ = table::remove(&mut rs.active_vaults, manager); }; table::add(&mut rs.active_vaults, manager, c + 1) }
    fun dec_active(rs: &mut ManagerStakeRegistry, manager: address) { let c = if (table::contains(&rs.active_vaults, manager)) { *table::borrow(&rs.active_vaults, manager) } else { 0 }; let nc = if (c == 0) { 0 } else { c - 1 }; if (table::contains(&rs.active_vaults, manager)) { let _ = table::remove(&mut rs.active_vaults, manager); }; table::add(&mut rs.active_vaults, manager, nc) }

    #[allow(lint(coin_field))]
    public struct Vault<phantom BaseUSD: store> has key, store {
        id: UID,
        manager: address,
        base: Coin<BaseUSD>,
        total_shares: u64,
        shares: Table<address, u64>,
        min_cash_bps: u64,
        // Optional caps & fees
        max_aum_base: u64,            // 0 = unlimited
        perf_fee_bps: u64,            // default 10%
        hwm_nav_per_share_1e6: u64,   // high-water mark
        frozen: bool,
        created_at_ms: u64,
    }
    #[allow(lint(coin_field))]
    public struct VaultAssetStore<phantom Asset: store, phantom BaseUSD: store> has key, store { id: UID, vault_id: ID, coin: Coin<Asset> }

    public struct VaultCreated has copy, drop { vault_id: ID, manager: address, min_cash_bps: u64, created_at: u64 }
    public struct VaultFrozen has copy, drop { vault_id: ID, frozen: bool, timestamp: u64 }
    public struct VaultDeposit has copy, drop { vault_id: ID, depositor: address, amount: u64, shares_issued: u64, total_shares_after: u64, timestamp: u64 }
    public struct VaultWithdrawal has copy, drop { vault_id: ID, owner: address, shares: u64, amount_paid: u64, timestamp: u64 }

    public fun create_vault<BaseUSD: store>(rs: &mut ManagerStakeRegistry, min_cash_bps: u64, clock_obj: &Clock, ctx: &mut TxContext) {
        assert_manager_active(rs, ctx.sender());
        let v = Vault<BaseUSD> {
            id: object::new(ctx), manager: ctx.sender(), base: coin::zero<BaseUSD>(ctx), total_shares: 0,
            shares: table::new<address, u64>(ctx), min_cash_bps,
            max_aum_base: 0, perf_fee_bps: 1000, hwm_nav_per_share_1e6: 1_000_000,
            frozen: false, created_at_ms: clock::timestamp_ms(clock_obj)
        };
        inc_active(rs, ctx.sender()); event::emit(VaultCreated { vault_id: object::id(&v), manager: v.manager, min_cash_bps, created_at: v.created_at_ms }); transfer::share_object(v)
    }
    public fun set_vault_frozen<BaseUSD: store>(rs: &ManagerStakeRegistry, v: &mut Vault<BaseUSD>, frozen: bool, clock_obj: &Clock, ctx: &TxContext) { assert!(v.manager == ctx.sender(), E_NOT_MANAGER); assert_manager_active(rs, v.manager); v.frozen = frozen; event::emit(VaultFrozen { vault_id: object::id(v), frozen, timestamp: clock::timestamp_ms(clock_obj) }) }
    public fun close_vault<BaseUSD: store>(rs: &mut ManagerStakeRegistry, v: Vault<BaseUSD>, ctx: &TxContext) {
        let Vault { id, manager, base, total_shares, shares, min_cash_bps: _, max_aum_base: _, perf_fee_bps: _, hwm_nav_per_share_1e6: _, frozen: _, created_at_ms: _ } = v;
        assert!(manager == ctx.sender(), E_NOT_MANAGER);
        assert!(total_shares == 0 && coin::value(&base) == 0, E_INSUFFICIENT_LIQUIDITY);
        coin::destroy_zero(base);
        table::destroy_empty(shares);
        dec_active(rs, manager);
        object::delete(id)
    }

    public fun deposit_base<BaseUSD: store>(v: &mut Vault<BaseUSD>, amount: Coin<BaseUSD>, clock_obj: &Clock, ctx: &mut TxContext) {
        assert!(!v.frozen, E_FROZEN);
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        // AUM cap check
        if (v.max_aum_base > 0) { let nav_before = coin::value(&v.base); assert!(nav_before + amt <= v.max_aum_base, E_INSUFFICIENT_LIQUIDITY); };
        let nav_before2 = coin::value(&v.base);
        coin::join(&mut v.base, amount);
        let shares_issued = if (v.total_shares == 0) { amt } else {
            let si_u128: u128 = (amt as u128) * (v.total_shares as u128) / (nav_before2 as u128);
            si_u128 as u64
        };
        v.total_shares = v.total_shares + shares_issued;
        let prev = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), prev + shares_issued);
        event::emit(VaultDeposit { vault_id: object::id(v), depositor: ctx.sender(), amount: amt, shares_issued, total_shares_after: v.total_shares, timestamp: clock::timestamp_ms(clock_obj) })
    }

    // Crystallize performance fee against HWM and accrue directly in base
    public fun crystallize_perf_fee<BaseUSD: store>(v: &mut Vault<BaseUSD>, _clock: &Clock, ctx: &mut TxContext) {
        if (v.total_shares == 0 || v.perf_fee_bps == 0) { return };
        let nav = coin::value(&v.base) as u128;
        let nav_per_share_1e6 = (nav * 1_000_000u128 / (v.total_shares as u128)) as u64;
        if (nav_per_share_1e6 <= v.hwm_nav_per_share_1e6) { return };
        let gain_per_share_1e6 = nav_per_share_1e6 - v.hwm_nav_per_share_1e6;
        let gain_total = (gain_per_share_1e6 as u128) * (v.total_shares as u128) / 1_000_000u128;
        let fee = (gain_total * (v.perf_fee_bps as u128)) / 10_000u128;
        if (fee > 0) { let out = coin::split(&mut v.base, fee as u64, ctx); transfer::public_transfer(out, v.manager); };
        v.hwm_nav_per_share_1e6 = nav_per_share_1e6;
    }

    // Admin knobs for caps/fees (AdminRegistry-gated)
    public fun set_vault_caps_and_fees_admin<BaseUSD: store>(reg_admin: &AdminRegistry, v: &mut Vault<BaseUSD>, max_aum_base: u64, perf_fee_bps: u64, ctx: &TxContext) {
        assert_is_admin(reg_admin, ctx.sender());
        v.max_aum_base = max_aum_base;
        v.perf_fee_bps = perf_fee_bps;
    }
    public fun withdraw_shares<BaseUSD: store>(v: &mut Vault<BaseUSD>, shares: u64, clock_obj: &Clock, ctx: &mut TxContext): Coin<BaseUSD> {
        let mut bal = if (table::contains(&v.shares, ctx.sender())) { *table::borrow(&v.shares, ctx.sender()) } else { 0 };
        assert!(shares > 0 && bal >= shares, E_ZERO_AMOUNT);
        let nav_u128: u128 = coin::value(&v.base) as u128;
        let payout: u64 = (nav_u128 * (shares as u128) / (v.total_shares as u128)) as u64;
        let available = coin::value(&v.base);
        assert!(available >= payout, E_INSUFFICIENT_LIQUIDITY);
        let out = coin::split(&mut v.base, payout, ctx);
        bal = bal - shares;
        if (table::contains(&v.shares, ctx.sender())) { let _ = table::remove(&mut v.shares, ctx.sender()); };
        table::add(&mut v.shares, ctx.sender(), bal);
        v.total_shares = v.total_shares - shares;
        event::emit(VaultWithdrawal { vault_id: object::id(v), owner: ctx.sender(), shares, amount_paid: payout, timestamp: clock::timestamp_ms(clock_obj) });
        out
    }

    public fun create_asset_store<Asset: store, BaseUSD: store>(rs: &ManagerStakeRegistry, v: &Vault<BaseUSD>, ctx: &mut TxContext): VaultAssetStore<Asset, BaseUSD> { assert_manager_active(rs, v.manager); assert!(v.manager == ctx.sender() && !v.frozen, E_NOT_MANAGER); VaultAssetStore<Asset, BaseUSD> { id: object::new(ctx), vault_id: object::id(v), coin: coin::zero<Asset>(ctx) } }
    public fun deposit_asset<Asset: store, BaseUSD: store>(rs: &ManagerStakeRegistry, v: &Vault<BaseUSD>, store: &mut VaultAssetStore<Asset, BaseUSD>, amt: Coin<Asset>, ctx: &TxContext) { assert_manager_active(rs, v.manager); assert!(v.manager == ctx.sender() && !v.frozen && store.vault_id == object::id(v), E_NOT_MANAGER); coin::join(&mut store.coin, amt) }
    public fun withdraw_asset<Asset: store, BaseUSD: store>(rs: &ManagerStakeRegistry, v: &Vault<BaseUSD>, store: &mut VaultAssetStore<Asset, BaseUSD>, amt: u64, ctx: &mut TxContext) { assert_manager_active(rs, v.manager); assert!(v.manager == ctx.sender() && !v.frozen && store.vault_id == object::id(v), E_NOT_MANAGER); let out_coin = coin::split(&mut store.coin, amt, ctx); transfer::public_transfer(out_coin, v.manager) }

    public fun vault_place_dex_bid<Base: store, BaseUSD: store>(rs: &ManagerStakeRegistry, cfg: &DexConfig, market: &mut DexMarket<Base, BaseUSD>, escrow: &mut DexEscrow<Base, BaseUSD>, v: &mut Vault<BaseUSD>, price: u64, size_base: u64, expiry_ms: u64, ctx: &mut TxContext) { assert_manager_active(rs, v.manager); assert!(v.manager == ctx.sender() && !v.frozen, E_NOT_MANAGER); let needed_u128: u128 = (price as u128) * (size_base as u128); let before = coin::value(&v.base) as u128; let after = if (before >= needed_u128) { before - needed_u128 } else { 0 }; let min_cash = (before * (v.min_cash_bps as u128)) / 10_000u128; assert!(after >= min_cash, E_INSUFFICIENT_LIQUIDITY); Dex::place_dex_limit_with_escrow_bid_pkg<Base, BaseUSD>(cfg, market, escrow, price, size_base, expiry_ms, &mut v.base, ctx) }
    public fun vault_place_dex_ask<Base: store, BaseUSD: store>(rs: &ManagerStakeRegistry, cfg: &DexConfig, market: &mut DexMarket<Base, BaseUSD>, escrow: &mut DexEscrow<Base, BaseUSD>, v: &Vault<BaseUSD>, store: &mut VaultAssetStore<Base, BaseUSD>, price: u64, size_base: u64, expiry_ms: u64, ctx: &mut TxContext) { assert_manager_active(rs, v.manager); assert!(v.manager == ctx.sender() && !v.frozen && store.vault_id == object::id(v), E_NOT_MANAGER); Dex::place_dex_limit_with_escrow_ask_pkg<Base, BaseUSD>(cfg, market, escrow, price, size_base, expiry_ms, &mut store.coin, ctx) }
    public fun vault_claim_dex_maker_fills<Base: store, BaseUSD: store>(
        market: &DexMarket<Base, BaseUSD>,
        escrow: &mut DexEscrow<Base, BaseUSD>,
        v: &mut Vault<BaseUSD>,
        maybe_store: &mut option::Option<VaultAssetStore<Base, BaseUSD>>,
        order_id: u128,
        ctx: &mut TxContext
    ) {
        assert!(v.manager == ctx.sender() && !v.frozen, E_NOT_MANAGER);
        if (option::is_some(maybe_store)) {
            let sref = option::borrow_mut(maybe_store);
            Dex::claim_dex_maker_fills_to_stores_pkg<Base, BaseUSD>(market, escrow, order_id, &mut sref.coin, &mut v.base, ctx);
        } else {
            let mut tmp_base: Coin<Base> = coin::zero<Base>(ctx);
            Dex::claim_dex_maker_fills_to_stores_pkg<Base, BaseUSD>(market, escrow, order_id, &mut tmp_base, &mut v.base, ctx);
            if (coin::value(&tmp_base) > 0) { transfer::public_transfer(tmp_base, v.manager); } else { coin::destroy_zero(tmp_base); }
        }
    }

    // Range ladder helpers: place many tick-aligned orders across [p_min, p_max]
    public fun vault_place_dex_range_bid<Base: store, BaseUSD: store>(
        rs: &ManagerStakeRegistry,
        cfg: &DexConfig,
        market: &mut DexMarket<Base, BaseUSD>,
        escrow: &mut DexEscrow<Base, BaseUSD>,
        v: &mut Vault<BaseUSD>,
        p_min: u64,
        p_max: u64,
        step_ticks: u64,
        total_size_base: u64,
        expiry_ms: u64,
        ctx: &mut TxContext
    ) {
        assert_manager_active(rs, v.manager);
        assert!(v.manager == ctx.sender() && !v.frozen && p_min > 0 && p_max >= p_min && step_ticks > 0, E_NOT_MANAGER);
        let (tick, lot, min_size) = Dex::get_book_params(market);
        let step = tick * step_ticks;
        let mut price = (p_min / tick) * tick;
        if (price < p_min) { price = price + tick; };
        // naive even split by level count
        let mut levels = 0u64; let mut p = price; while (p <= p_max) { levels = levels + 1; p = p + step; };
        if (levels == 0) { return };
        let mut per = total_size_base / levels;
        // align per level to lot/min
        if (per < min_size) { per = min_size };
        per = (per / lot) * lot;
        if (per == 0) { per = lot };
        p = price;
        while (p <= p_max) {
            // ensure min cash buffer per order
            let need = per * p;
            let before = coin::value(&v.base);
            if (before <= need) { break };
            let after = before - need;
            let min_cash = (before * v.min_cash_bps) / 10_000;
            if (after < min_cash) { break };
            Dex::place_dex_limit_with_escrow_bid_pkg<Base, BaseUSD>(cfg, market, escrow, p, per, expiry_ms, &mut v.base, ctx);
            p = p + step;
        }
    }

    public fun vault_place_dex_range_ask<Base: store, BaseUSD: store>(
        rs: &ManagerStakeRegistry,
        cfg: &DexConfig,
        market: &mut DexMarket<Base, BaseUSD>,
        escrow: &mut DexEscrow<Base, BaseUSD>,
        v: &Vault<BaseUSD>,
        store: &mut VaultAssetStore<Base, BaseUSD>,
        p_min: u64,
        p_max: u64,
        step_ticks: u64,
        total_size_base: u64,
        expiry_ms: u64,
        ctx: &mut TxContext
    ) {
        assert_manager_active(rs, v.manager);
        assert!(v.manager == ctx.sender() && !v.frozen && store.vault_id == object::id(v) && p_min > 0 && p_max >= p_min && step_ticks > 0, E_NOT_MANAGER);
        let (tick, lot, min_size) = Dex::get_book_params(market);
        let step = tick * step_ticks;
        let mut price = (p_min / tick) * tick;
        if (price < p_min) { price = price + tick; };
        let mut levels = 0u64; let mut p = price; while (p <= p_max) { levels = levels + 1; p = p + step; };
        if (levels == 0) { return };
        let mut per = total_size_base / levels;
        if (per < min_size) { per = min_size };
        per = (per / lot) * lot;
        if (per == 0) { per = lot };
        p = price;
        while (p <= p_max) {
            Dex::place_dex_limit_with_escrow_ask_pkg<Base, BaseUSD>(cfg, market, escrow, p, per, expiry_ms, &mut store.coin, ctx);
            p = p + step;
        }
    }

    // Cancel a vault order and deposit refunds directly into vault stores
    public fun vault_cancel_dex_order<Base: store, BaseUSD: store>(
        market: &mut DexMarket<Base, BaseUSD>,
        escrow: &mut DexEscrow<Base, BaseUSD>,
        v: &mut Vault<BaseUSD>,
        maybe_store: &mut option::Option<VaultAssetStore<Base, BaseUSD>>,
        order_id: u128,
        ctx: &mut TxContext
    ) {
        assert!(v.manager == ctx.sender() && !v.frozen, E_NOT_MANAGER);
        if (option::is_some(maybe_store)) {
            let sref = option::borrow_mut(maybe_store);
            Dex::cancel_dex_clob_with_escrow_to_stores_pkg<Base, BaseUSD>(market, escrow, order_id, &mut sref.coin, &mut v.base, ctx);
        } else {
            // If no base store provided, refund base (if any) to manager while keeping collateral in vault
            let mut tmp_base: Coin<Base> = coin::zero<Base>(ctx);
            Dex::cancel_dex_clob_with_escrow_to_stores_pkg<Base, BaseUSD>(market, escrow, order_id, &mut tmp_base, &mut v.base, ctx);
            if (coin::value(&tmp_base) > 0) { transfer::public_transfer(tmp_base, v.manager); } else { coin::destroy_zero(tmp_base); }
        }
    }

    public fun vault_place_synth_limit_with_escrow<BaseUSD: store>(
        _rs: &ManagerStakeRegistry,
        registry: &mut SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<BaseUSD>,
        clock_obj: &Clock,
        oracle_cfg: &unxversal::oracle::OracleConfig,
        price_info: &switchboard::aggregator::Aggregator,
        unxv_price: &switchboard::aggregator::Aggregator,
        taker_is_bid: bool,
        price: u64,
        size_units: u64,
        expiry_ms: u64,
        maker_vault: &mut CollateralVault<BaseUSD>,
        unxv_payment: vector<Coin<UNXV>>,
        treasury: &mut Treasury<BaseUSD>,
        ctx: &mut TxContext
    ) { SynthMod::place_synth_limit_with_escrow_baseusd_pkg(registry, market, escrow, clock_obj, oracle_cfg, price_info, unxv_price, taker_is_bid, price, size_units, expiry_ms, maker_vault, unxv_payment, treasury, ctx) }

    // Claim maker-side synth fills directly into the provided maker vault (no EOA hop). Manager-only wrapper.
    public fun vault_claim_synth_maker_fills<BaseUSD: store>(
        v: &Vault<BaseUSD>,
        registry: &SynthRegistry,
        market: &mut SynthMarket,
        escrow: &mut SynthEscrow<BaseUSD>,
        order_id: u128,
        maker_vault: &mut CollateralVault<BaseUSD>,
        ctx: &mut TxContext
    ) {
        assert!(v.manager == ctx.sender() && !v.frozen, E_NOT_MANAGER);
        SynthMod::claim_maker_fills_baseusd_pkg(registry, market, escrow, order_id, maker_vault, ctx);
    }
}


