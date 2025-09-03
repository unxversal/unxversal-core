/// Module: unxversal_fees
/// ------------------------------------------------------------
/// Centralized fee configuration and vault utilities used by Unxversal protocols.
/// - Stores global protocol fee params (bps), UNXV discount, and distribution splits
/// - Admin-gated updates via `unxversal::admin::AdminRegistry`
/// - Generic fee vault capable of holding balances of arbitrary coins
/// - Helper to accrue UNXV-denominated fees and split to stakers / treasury / burn-vault
module unxversal::fees {
    use std::type_name::{Self as type_name, TypeName};
    use sui::{
        balance::{Self as balance, Balance},
        bag::{Self as bag, Bag},
        coin::{Self as coin, Coin},
        event,
    };

    use unxversal::admin::{Self as AdminMod, AdminRegistry};
    use unxversal::unxv::UNXV;

    /// Errors
    const E_NOT_ADMIN: u64 = 1;
    const E_SPLIT_INVALID: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;

    /// Basis points denominator
    const BPS_DENOM: u64 = 10_000;

    /// Fee distribution parameters (in BPS, all must sum to BPS_DENOM)
    public struct FeeDistribution has copy, drop, store {
        stakers_share_bps: u64,
        treasury_share_bps: u64,
        burn_share_bps: u64,
    }

    /// Global fee configuration shared by protocols
    public struct FeeConfig has key, store {
        id: UID,
        /// DEX layer protocol fee in bps, applied to notional for direct coin swaps
        dex_fee_bps: u64,
        /// UNXV discount on Unxversal protocol fees, in bps (e.g. 3000 = 30%)
        unxv_discount_bps: u64,
        /// Address that receives the treasury share
        treasury: address,
        /// Preferred DeepBook backend fee token: true = DEEP, false = input token
        prefer_deep_backend: bool,
        /// Distribution percentages
        dist: FeeDistribution,
    }

    /// Generic key wrapper for storing balances in a Bag
    public struct FeeKey<phantom T> has copy, drop, store {}

    /// Fee vault that can hold balances of arbitrary assets
    public struct FeeVault has key, store {
        id: UID,
        store: Bag,
        /// Accumulated UNXV earmarked to be burned later by an authorized actor
        unxv_to_burn: Balance<UNXV>,
    }

    /// Events
    public struct FeeConfigUpdated has copy, drop {
        who: address,
        timestamp_ms: u64,
        dex_fee_bps: u64,
        unxv_discount_bps: u64,
        prefer_deep_backend: bool,
        stakers_bps: u64,
        treasury_bps: u64,
        burn_bps: u64,
        treasury: address,
    }

    public struct FeeAccrued has copy, drop {
        payer: address,
        asset: TypeName,
        amount: u64,
        timestamp_ms: u64,
    }

    public struct UnxvFeeSplit has copy, drop {
        payer: address,
        total_unxv: u64,
        stakers_unxv: u64,
        treasury_unxv: u64,
        burn_unxv: u64,
        timestamp_ms: u64,
    }

    /// One-time witness for module initialization
    public struct FEES has drop {}

    /// Initialize the fee manager objects (config + vault). Treasury defaults to publisher.
    fun init(_w: FEES, ctx: &mut TxContext) {
        let cfg = FeeConfig {
            id: object::new(ctx),
            dex_fee_bps: 100,                // 1 bps initial DEX protocol fee
            unxv_discount_bps: 3000,         // 30% discount
            treasury: ctx.sender(),
            prefer_deep_backend: true,
            dist: FeeDistribution { stakers_share_bps: 4000, treasury_share_bps: 3000, burn_share_bps: 3000 },
        };
        let vault = FeeVault { id: object::new(ctx), store: bag::new(ctx), unxv_to_burn: balance::zero<UNXV>() };
        transfer::share_object(cfg);
        transfer::share_object(vault);
    }

    /// Admin: update fee parameters (all-or-nothing)
    public fun set_params(
        reg_admin: &AdminRegistry,
        cfg: &mut FeeConfig,
        dex_fee_bps: u64,
        unxv_discount_bps: u64,
        prefer_deep_backend: bool,
        stakers_share_bps: u64,
        treasury_share_bps: u64,
        burn_share_bps: u64,
        treasury: address,
        clock: &sui::clock::Clock,
        ctx: &TxContext,
    ) {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        assert!(stakers_share_bps + treasury_share_bps + burn_share_bps == BPS_DENOM, E_SPLIT_INVALID);
        cfg.dex_fee_bps = dex_fee_bps;
        cfg.unxv_discount_bps = unxv_discount_bps;
        cfg.prefer_deep_backend = prefer_deep_backend;
        cfg.treasury = treasury;
        cfg.dist = FeeDistribution { stakers_share_bps, treasury_share_bps, burn_share_bps };
        event::emit(FeeConfigUpdated {
            who: ctx.sender(),
            timestamp_ms: sui::clock::timestamp_ms(clock),
            dex_fee_bps,
            unxv_discount_bps,
            prefer_deep_backend,
            stakers_bps: stakers_share_bps,
            treasury_bps: treasury_share_bps,
            burn_bps: burn_share_bps,
            treasury,
        });
    }

    /// Calculate discounted fee amount using UNXV discount
    public fun apply_unxv_discount(base_amount: u64, cfg: &FeeConfig): u64 {
        let discount = cfg.unxv_discount_bps;
        // base_amount * (1 - discount/BPS_DENOM)
        let num = (BPS_DENOM - discount) as u128 * (base_amount as u128);
        (num / (BPS_DENOM as u128)) as u64
    }

    /// Accrue a generic asset fee into the vault (no distribution). Intended for "paid in input token" path.
    public fun accrue_generic<T>(vault: &mut FeeVault, amount: Coin<T>, clock: &sui::clock::Clock, ctx: &TxContext) {
        let amt = coin::value(&amount);
        assert!(amt > 0, E_ZERO_AMOUNT);
        event::emit(FeeAccrued { payer: ctx.sender(), asset: type_name::get<T>(), amount: amt, timestamp_ms: sui::clock::timestamp_ms(clock) });
        // Convert to Balance and join into Bag
        let key = FeeKey<T> {};
        let bal = coin::into_balance(amount);
        if (bag::contains(&vault.store, key)) {
            let b: &mut Balance<T> = &mut vault.store[key];
            b.join(bal);
        } else {
            vault.store.add(key, bal);
        };
    }

    /// Accrue UNXV-denominated fee and split to stakers / treasury / burn buckets.
    /// - stakers_unxv is expected to be deposited into a staking pool by the caller.
    /// - treasury_unxv is transferred to `cfg.treasury`.
    /// - burn_unxv is retained inside `vault.unxv_to_burn` for a later explicit burn call.
    public fun accrue_unxv_and_split(
        cfg: &FeeConfig,
        vault: &mut FeeVault,
        mut unxv_fee: Coin<UNXV>,
        clock: &sui::clock::Clock,
        ctx: &mut TxContext,
    ): (Coin<UNXV>, Coin<UNXV>, u64) {
        let total = coin::value(&unxv_fee);
        assert!(total > 0, E_ZERO_AMOUNT);
        let stakers_part = (total as u128 * (cfg.dist.stakers_share_bps as u128) / (BPS_DENOM as u128)) as u64;
        let treasury_part = (total as u128 * (cfg.dist.treasury_share_bps as u128) / (BPS_DENOM as u128)) as u64;
        let burn_part = total - stakers_part - treasury_part;

        let stakers_coin = coin::split(&mut unxv_fee, stakers_part, ctx);
        let treasury_coin = coin::split(&mut unxv_fee, treasury_part, ctx);
        let burn_coin = unxv_fee; // remainder

        // Accumulate burn share inside the vault (as Balance)
        let burn_bal = coin::into_balance(burn_coin);
        vault.unxv_to_burn.join(burn_bal);

        // Emit split event
        event::emit(UnxvFeeSplit {
            payer: ctx.sender(),
            total_unxv: total,
            stakers_unxv: stakers_part,
            treasury_unxv: treasury_part,
            burn_unxv: burn_part,
            timestamp_ms: sui::clock::timestamp_ms(clock),
        });

        (stakers_coin, treasury_coin, burn_part)
    }

    /// Admin: transfer UNXV accumulated in vault for burning to the provided SupplyCap.burn (owner-controlled).
    /// This function converts the retained `unxv_to_burn` Balance into a Coin and returns it to the caller
    /// to execute the burn using their `unxversal::unxv::SupplyCap`.
    public fun withdraw_unxv_to_burn(reg_admin: &AdminRegistry, vault: &mut FeeVault, ctx: &mut TxContext): Coin<UNXV> {
        assert!(AdminMod::is_admin(reg_admin, ctx.sender()), E_NOT_ADMIN);
        let amt = balance::value(&vault.unxv_to_burn);
        assert!(amt > 0, E_ZERO_AMOUNT);
        // Split out the requested amount and convert to a Coin
        let bal_out = balance::split(&mut vault.unxv_to_burn, amt);
        let c = coin::from_balance(bal_out, ctx);
        c
    }

    /// View helpers
    public fun dex_fee_bps(cfg: &FeeConfig): u64 { cfg.dex_fee_bps }
    public fun unxv_discount_bps(cfg: &FeeConfig): u64 { cfg.unxv_discount_bps }
    public fun prefer_deep_backend(cfg: &FeeConfig): bool { cfg.prefer_deep_backend }
    public fun treasury_address(cfg: &FeeConfig): address { cfg.treasury }
    public fun shares(cfg: &FeeConfig): (u64, u64, u64) { (cfg.dist.stakers_share_bps, cfg.dist.treasury_share_bps, cfg.dist.burn_share_bps) }
    public fun bps_denom(): u64 { BPS_DENOM }
}


