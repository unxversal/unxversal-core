/// Module: unxversal_strategies_vaults
/// ------------------------------------------------------------
/// Permissionless strategy vaults with share accounting, keeper registry,
/// and protocol-managed flag. A small UNXV fee is charged on creation
/// (re-using the FeeConfig pool_creation_fee_unxv parameter).
///
/// Notes
/// - Single-asset vault generic over T; users deposit/withdraw Coin<T>.
/// - Share accounting: shares track pro-rata claim on the asset balance.
/// - Vaults are permissionless; creator is the owner. A boolean flag marks
///   protocol-managed vaults (requires admin to set at creation).
/// - Owners can manage an allowlist of keeper addresses.
/// - Future extension: add multi-asset accounting and delegated spend with
///   on-chain risk caps for automated strategies.
module unxversal::vaults {
    use std::type_name::{Self as type_name, TypeName};
    use sui::vec_set::{Self as vec_set, VecSet};
    use sui::table::{Self as table, Table};
    use sui::balance::{Self as balance, Balance};
    use sui::coin::{Self as coin, Coin};
    use sui::event;

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::fees::{Self as fees, FeeConfig, FeeVault};
    use unxversal::unxv::UNXV;

    const E_NOT_OWNER: u64 = 1;
    const E_ZERO_AMOUNT: u64 = 2;
    const E_INVALID_CAPS: u64 = 3;
    // Reserved error codes if we later add on-chain guarded routing

    /// Strategy vault for a single asset T
    public struct Vault<phantom T> has key, store {
        id: UID,
        owner: address,
        protocol_managed: bool,
        /// Total shares outstanding
        total_shares: u128,
        /// Per-account shares
        shares: Table<address, u128>,
        /// Custodied asset
        asset: Balance<T>,
        /// Keeper allowlist
        keepers: VecSet<address>,
        created_ms: u64,
        /// On-chain risk caps for keeper actions
        risk_caps: RiskCaps,
    }

    /// Events
    public struct VaultCreated has copy, drop {
        vault_id: ID,
        asset: TypeName,
        owner: address,
        protocol_managed: bool,
        timestamp_ms: u64,
    }

    public struct KeeperUpdated has copy, drop {
        vault_id: ID,
        keeper: address,
        added: bool,
        by: address,
        timestamp_ms: u64,
    }

    public struct Deposit has copy, drop {
        vault_id: ID,
        who: address,
        amount: u64,
        shares: u128,
        timestamp_ms: u64,
    }

    public struct Withdraw has copy, drop {
        vault_id: ID,
        who: address,
        amount: u64,
        shares: u128,
        timestamp_ms: u64,
    }

    /// Risk guardrails for keeper actions
    public struct RiskCaps has copy, drop, store {
        /// Maximum per-order base size (applies to spot/perps/futures qty)
        max_order_size_base: u64,
        /// Maximum inventory tilt away from 50/50 in bps (e.g., 7000 = 70%)
        max_inventory_tilt_bps: u64,
        /// Minimum quote distance from mid in bps for maker quotes
        min_distance_bps: u64,
        /// Pause flag to halt keeper actions
        paused: bool,
    }

    public struct RiskCapsUpdated has copy, drop {
        vault_id: ID,
        caps: RiskCaps,
        by: address,
        timestamp_ms: u64,
    }

    // Removed on-chain guarded routing per design: keepers run under vault owner key

    fun default_caps(): RiskCaps {
        RiskCaps { max_order_size_base: 0, max_inventory_tilt_bps: 7000, min_distance_bps: 5, paused: false }
    }

    /// Create a new vault for asset T.
    /// - Charges a UNXV creation fee as per FeeConfig.pool_creation_fee_unxv
    /// - If `protocol_managed` is true, only admins can set it
    #[allow(lint(self_transfer))]
    public fun create_vault<T>(
        reg_admin: &AdminRegistry,
        cfg: &FeeConfig,
        fee_vault: &mut FeeVault,
        protocol_managed: bool,
        mut fee_unxv: Coin<UNXV>,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ) {
        if (protocol_managed) { assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_OWNER); };
        // Enforce fee
        let required = fees::pool_creation_fee_unxv(cfg);
        let paid = coin::value(&fee_unxv);
        assert!(paid >= required, E_ZERO_AMOUNT);
        if (required > 0) {
            if (paid > required) {
                // Split out exactly the required amount; return leftover to sender after accrual
                let pay_exact = coin::split(&mut fee_unxv, required, ctx);
                let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, fee_vault, pay_exact, clock, ctx);
                fees::accrue_generic<UNXV>(fee_vault, stakers_coin, clock, ctx);
                sui::transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
                // Return leftover UNXV (consumes fee_unxv)
                sui::transfer::public_transfer(fee_unxv, ctx.sender());
            } else {
                // paid == required (given assert), move the entire coin
                let pay_exact = fee_unxv;
                let (stakers_coin, treasury_coin, _burn) = fees::accrue_unxv_and_split(cfg, fee_vault, pay_exact, clock, ctx);
                fees::accrue_generic<UNXV>(fee_vault, stakers_coin, clock, ctx);
                sui::transfer::public_transfer(treasury_coin, fees::treasury_address(cfg));
                // fee_unxv fully consumed above; nothing left to do
            };
        } else {
            // No fee required: return any provided coin back or destroy zero
            if (paid > 0) { sui::transfer::public_transfer(fee_unxv, ctx.sender()); } else { coin::destroy_zero(fee_unxv); };
        };

        let v = Vault<T> {
            id: object::new(ctx),
            owner: ctx.sender(),
            protocol_managed,
            total_shares: 0,
            shares: table::new<address, u128>(ctx),
            asset: balance::zero<T>(),
            keepers: vec_set::empty<address>(),
            created_ms: sui::clock::timestamp_ms(clock),
            risk_caps: default_caps(),
        };
        event::emit(VaultCreated { vault_id: object::id(&v), asset: type_name::get<T>(), owner: ctx.sender(), protocol_managed, timestamp_ms: v.created_ms });
        transfer::share_object(v);
    }

    /// Owner or admin can add a keeper address
    public fun add_keeper<T>(reg_admin: &AdminRegistry, v: &mut Vault<T>, keeper: address, clock: &sui::clock::Clock, ctx: &TxContext) {
        assert!(ctx.sender() == v.owner || AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_OWNER);
        vec_set::insert(&mut v.keepers, keeper);
        event::emit(KeeperUpdated { vault_id: object::id(v), keeper, added: true, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Owner or admin can remove a keeper address
    public fun remove_keeper<T>(reg_admin: &AdminRegistry, v: &mut Vault<T>, keeper: address, clock: &sui::clock::Clock, ctx: &TxContext) {
        assert!(ctx.sender() == v.owner || AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_OWNER);
        vec_set::remove(&mut v.keepers, &keeper);
        event::emit(KeeperUpdated { vault_id: object::id(v), keeper, added: false, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Deposit funds and receive shares
    public fun deposit<T>(v: &mut Vault<T>, amount: Coin<T>, clock: &sui::clock::Clock, ctx: &mut TxContext) {
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        let tvl = balance::value(&v.asset);
        let minted: u128 = if (v.total_shares == 0 || tvl == 0) { amt as u128 } else { ((amt as u128) * v.total_shares) / (tvl as u128) };
        v.total_shares = v.total_shares + minted;
        let who = ctx.sender();
        add_shares(&mut v.shares, who, minted);
        v.asset.join(coin::into_balance(amount));
        event::emit(Deposit { vault_id: object::id(v), who, amount: amt, shares: minted, timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    /// Withdraw by specifying share amount
    public fun withdraw<T>(v: &mut Vault<T>, shares: u128, clock: &sui::clock::Clock, ctx: &mut TxContext): Coin<T> {
        assert!(shares > 0, E_ZERO_AMOUNT);
        let who = ctx.sender();
        let user_sh = get_shares(&v.shares, who);
        assert!(user_sh >= shares, E_NOT_OWNER);
        let tvl = balance::value(&v.asset) as u128;
        let amt_u128 = (tvl * shares) / v.total_shares;
        let amt: u64 = amt_u128 as u64;
        // update shares
        set_shares(&mut v.shares, who, user_sh - shares);
        v.total_shares = v.total_shares - shares;
        // split and return coin
        let part = balance::split(&mut v.asset, amt);
        let c = coin::from_balance(part, ctx);
        event::emit(Withdraw { vault_id: object::id(v), who, amount: amt, shares, timestamp_ms: sui::clock::timestamp_ms(clock) });
        c
    }

    /// Views
    public fun is_keeper<T>(v: &Vault<T>, who: address): bool { vec_set::contains(&v.keepers, &who) }
    public fun owner<T>(v: &Vault<T>): address { v.owner }
    public fun protocol_managed<T>(v: &Vault<T>): bool { v.protocol_managed }
    public fun total_assets<T>(v: &Vault<T>): u64 { balance::value(&v.asset) }
    public fun total_shares<T>(v: &Vault<T>): u128 { v.total_shares }
    public fun user_shares<T>(v: &Vault<T>, who: address): u128 { get_shares(&v.shares, who) }
    public fun risk_caps<T>(v: &Vault<T>): &RiskCaps { &v.risk_caps }

    /// Admin/owner functions to manage caps and pause
    public fun set_risk_caps<T>(reg_admin: &AdminRegistry, v: &mut Vault<T>, caps: RiskCaps, clock: &sui::clock::Clock, ctx: &TxContext) {
        assert!(ctx.sender() == v.owner || AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_OWNER);
        assert!(caps.max_inventory_tilt_bps <= 10_000, E_INVALID_CAPS);
        v.risk_caps = caps;
        event::emit(RiskCapsUpdated { vault_id: object::id(v), caps, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    public fun pause<T>(reg_admin: &AdminRegistry, v: &mut Vault<T>, clock: &sui::clock::Clock, ctx: &TxContext) { set_pause_internal(reg_admin, v, true, clock, ctx); }
    public fun unpause<T>(reg_admin: &AdminRegistry, v: &mut Vault<T>, clock: &sui::clock::Clock, ctx: &TxContext) { set_pause_internal(reg_admin, v, false, clock, ctx); }

    fun set_pause_internal<T>(reg_admin: &AdminRegistry, v: &mut Vault<T>, p: bool, clock: &sui::clock::Clock, ctx: &TxContext) {
        assert!(ctx.sender() == v.owner || AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_OWNER);
        v.risk_caps.paused = p;
        event::emit(RiskCapsUpdated { vault_id: object::id(v), caps: v.risk_caps, by: ctx.sender(), timestamp_ms: sui::clock::timestamp_ms(clock) });
    }

    // (Guarded DEX wrappers removed per design; client-side checks + owner-only execution suffice.)

    /// Internal share helpers
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
}


