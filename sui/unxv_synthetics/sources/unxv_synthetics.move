/// Module: unxv_synthetics
/// UnXversal Synthetics Protocol - Permissionless synthetic asset creation and trading
/// Built on DeepBook with USDC collateral and Pyth Network price feeds
#[allow(duplicate_alias)]
module unxv_synthetics::unxv_synthetics {
    use std::string::{Self, String};
    use std::option::{Option};
    
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{UID, ID};
    use sui::transfer;
    use sui::tx_context::{TxContext};
    use sui::event;
    use sui::clock::{Clock};
    use sui::table::{Self, Table};
    
    // Pyth Network integration for price feeds
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::price::{Self, Price};
    use pyth::i64;
    use pyth::pyth;
    
    // USDC type for collateral - this would be imported from actual USDC package
    public struct USDC has drop {}

    // ========== Error Constants ==========
    
    const E_ASSET_ALREADY_EXISTS: u64 = 2;
    const E_ASSET_NOT_FOUND: u64 = 3;
    const E_INSUFFICIENT_COLLATERAL: u64 = 4;
    const E_VAULT_NOT_LIQUIDATABLE: u64 = 5;
    const E_INVALID_AMOUNT: u64 = 6;
    const E_ASSET_NOT_ACTIVE: u64 = 9;
    const E_INSUFFICIENT_DEBT: u64 = 10;
    const E_COLLATERAL_RATIO_TOO_LOW: u64 = 11;
    const E_MAX_SYNTHETICS_REACHED: u64 = 12;
    const E_INVALID_VAULT_OWNER: u64 = 13;
    const E_SYSTEM_PAUSED: u64 = 14;
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const MIN_COLLATERAL_RATIO: u64 = 15000; // 150%
    const LIQUIDATION_THRESHOLD: u64 = 12000; // 120%
    const LIQUIDATION_PENALTY: u64 = 500; // 5%
    const MAX_PRICE_AGE: u64 = 300; // 5 minutes in seconds
    const MINTING_FEE: u64 = 50; // 0.5%
    const BURNING_FEE: u64 = 30; // 0.3%
    const STABILITY_FEE: u64 = 200; // 2% annually
    const UNXV_FEE_DISCOUNT: u64 = 2000; // 20% discount
    
    // ========== Core Data Structures ==========
    
    /// Central registry for all synthetic assets and global parameters
    public struct SynthRegistry has key {
        id: UID,
        synthetics: Table<String, SyntheticAsset>,
        oracle_feeds: Table<String, vector<u8>>,
        global_params: GlobalParams,
        admin_cap: Option<AdminCap>,
        total_vaults: u64,
        is_paused: bool,
    }
    
    /// Global risk and fee parameters
    public struct GlobalParams has store, drop {
        min_collateral_ratio: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        max_synthetics: u64,
        stability_fee: u64,
        minting_fee: u64,
        burning_fee: u64,
    }
    
    /// Admin capability for initial setup and emergency functions
    public struct AdminCap has key, store {
        id: UID,
    }
    
    /// Metadata for individual synthetic assets
    public struct SyntheticAsset has store {
        name: String,
        symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_collateral_ratio: u64,
        total_supply: u64,
        deepbook_pool_id: Option<ID>,
        is_active: bool,
        created_at: u64,
    }
    
    /// Individual user vault holding USDC collateral and synthetic debt
    public struct CollateralVault has key, store {
        id: UID,
        owner: address,
        collateral_balance: Balance<USDC>,
        synthetic_debt: Table<String, u64>,
        last_update: u64,
        liquidation_price: Table<String, u64>,
        health_factor: u64,
    }
    
    /// Transferable synthetic asset tokens
    public struct SyntheticCoin<phantom T> has key, store {
        id: UID,
        balance: Balance<T>,
        synthetic_type: String,
    }
    
    /// Fee calculation result with UNXV discount
    public struct FeeCalculation has drop {
        base_fee: u64,
        unxv_discount: u64,
        final_fee: u64,
        payment_asset: String,
    }
    
    /// System health metrics
    public struct SystemHealth has drop {
        total_collateral_value: u64,
        total_synthetic_value: u64,
        global_collateral_ratio: u64,
        at_risk_vaults: u64,
        system_solvent: bool,
    }
    
    // ========== Events ==========
    
    /// Emitted when a new synthetic asset is created
    public struct SyntheticAssetCreated has copy, drop {
        asset_name: String,
        asset_symbol: String,
        pyth_feed_id: vector<u8>,
        creator: address,
        deepbook_pool_id: ID,
        timestamp: u64,
    }
    
    /// Emitted when synthetic tokens are minted
    public struct SyntheticMinted has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_minted: u64,
        usdc_collateral_deposited: u64,
        minter: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }
    
    /// Emitted when synthetic tokens are burned
    public struct SyntheticBurned has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_burned: u64,
        usdc_collateral_withdrawn: u64,
        burner: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }
    
    /// Emitted when a vault is liquidated
    public struct LiquidationExecuted has copy, drop {
        vault_id: ID,
        liquidator: address,
        liquidated_amount: u64,
        usdc_collateral_seized: u64,
        liquidation_penalty: u64,
        synthetic_type: String,
        timestamp: u64,
    }
    
    /// Emitted when fees are collected
    public struct FeeCollected has copy, drop {
        fee_type: String,
        amount: u64,
        asset_type: String,
        user: address,
        unxv_discount_applied: bool,
        timestamp: u64,
    }
    
    /// Emitted when UNXV tokens are burned for fee discounts
    #[allow(unused_field)]
    public struct UnxvBurned has copy, drop {
        amount_burned: u64,
        fee_source: String,
        timestamp: u64,
    }
    
    /// Emitted when a vault is created
    public struct VaultCreated has copy, drop {
        vault_id: ID,
        owner: address,
        timestamp: u64,
    }
    
    /// Emitted when collateral is deposited
    public struct CollateralDeposited has copy, drop {
        vault_id: ID,
        amount: u64,
        new_balance: u64,
        depositor: address,
        timestamp: u64,
    }
    
    /// Emitted when collateral is withdrawn
    public struct CollateralWithdrawn has copy, drop {
        vault_id: ID,
        amount: u64,
        new_balance: u64,
        withdrawer: address,
        timestamp: u64,
    }
    
    // ========== Module Initializer ==========
    
    /// Initialize the synthetics registry and admin capability
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: sui::object::new(ctx),
        };
        
        let global_params = GlobalParams {
            min_collateral_ratio: MIN_COLLATERAL_RATIO,
            liquidation_threshold: LIQUIDATION_THRESHOLD,
            liquidation_penalty: LIQUIDATION_PENALTY,
            max_synthetics: 100,
            stability_fee: STABILITY_FEE,
            minting_fee: MINTING_FEE,
            burning_fee: BURNING_FEE,
        };
        
        let registry = SynthRegistry {
            id: sui::object::new(ctx),
            synthetics: table::new(ctx),
            oracle_feeds: table::new(ctx),
            global_params,
            admin_cap: std::option::none(),
            total_vaults: 0,
            is_paused: false,
        };
        
        transfer::share_object(registry);
        transfer::public_transfer(admin_cap, sui::tx_context::sender(ctx));
    }
    
    // ========== Admin Functions ==========
    
    /// Create a new synthetic asset (admin only)
    public fun create_synthetic_asset(
        _admin_cap: &AdminCap,
        registry: &mut SynthRegistry,
        asset_name: String,
        asset_symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_collateral_ratio: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(!table::contains(&registry.synthetics, asset_symbol), E_ASSET_ALREADY_EXISTS);
        assert!(table::length(&registry.synthetics) < registry.global_params.max_synthetics, E_MAX_SYNTHETICS_REACHED);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        let synthetic_asset = SyntheticAsset {
            name: asset_name,
            symbol: asset_symbol,
            decimals,
            pyth_feed_id,
            min_collateral_ratio,
            total_supply: 0,
            deepbook_pool_id: std::option::none(),
            is_active: true,
            created_at: sui::clock::timestamp_ms(clock),
        };
        
        table::add(&mut registry.synthetics, asset_symbol, synthetic_asset);
        table::add(&mut registry.oracle_feeds, asset_symbol, pyth_feed_id);
        
        // Emit event (pool ID will be set separately)
        event::emit(SyntheticAssetCreated {
            asset_name,
            asset_symbol,
            pyth_feed_id,
            creator: sui::tx_context::sender(ctx),
            deepbook_pool_id: sui::object::id_from_address(@0x0), // Placeholder
            timestamp: sui::clock::timestamp_ms(clock),
        });
    }
    
    /// Update global system parameters (admin only)
    public fun update_global_params(
        _admin_cap: &AdminCap,
        registry: &mut SynthRegistry,
        new_params: GlobalParams,
        _ctx: &TxContext,
    ) {
        registry.global_params = new_params;
    }
    
    /// Emergency pause the system (admin only)
    public fun emergency_pause(
        _admin_cap: &AdminCap,
        registry: &mut SynthRegistry,
        _ctx: &TxContext,
    ) {
        registry.is_paused = true;
    }
    
    /// Resume system operations (admin only)
    public fun resume_system(
        _admin_cap: &AdminCap,
        registry: &mut SynthRegistry,
        _ctx: &TxContext,
    ) {
        registry.is_paused = false;
    }
    
    /// Destroy admin capability to make protocol immutable
    public fun destroy_admin_cap(admin_cap: AdminCap) {
        let AdminCap { id } = admin_cap;
        sui::object::delete(id);
    }
    
    // ========== Vault Management ==========
    
    /// Create a new collateral vault
    public fun create_vault(ctx: &mut TxContext): CollateralVault {
        let vault = CollateralVault {
            id: sui::object::new(ctx),
            owner: sui::tx_context::sender(ctx),
            collateral_balance: balance::zero<USDC>(),
            synthetic_debt: table::new(ctx),
            last_update: 0,
            liquidation_price: table::new(ctx),
            health_factor: BASIS_POINTS,
        };
        
        event::emit(VaultCreated {
            vault_id: sui::object::uid_to_inner(&vault.id),
            owner: sui::tx_context::sender(ctx),
            timestamp: 0, // Clock not available here
        });
        
        vault
    }
    
    /// Deposit USDC collateral into a vault
    public fun deposit_collateral(
        vault: &mut CollateralVault,
        usdc_collateral: Coin<USDC>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(vault.owner == sui::tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        
        let amount = coin::value(&usdc_collateral);
        assert!(amount > 0, E_INVALID_AMOUNT);
        
        balance::join(&mut vault.collateral_balance, coin::into_balance(usdc_collateral));
        vault.last_update = sui::clock::timestamp_ms(clock);
        
        event::emit(CollateralDeposited {
            vault_id: sui::object::uid_to_inner(&vault.id),
            amount,
            new_balance: balance::value(&vault.collateral_balance),
            depositor: sui::tx_context::sender(ctx),
            timestamp: sui::clock::timestamp_ms(clock),
        });
    }
    
    /// Withdraw USDC collateral from a vault
    public fun withdraw_collateral(
        vault: &mut CollateralVault,
        amount: u64,
        registry: &SynthRegistry,
        price_info: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<USDC> {
        assert!(vault.owner == sui::tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(balance::value(&vault.collateral_balance) >= amount, E_INSUFFICIENT_COLLATERAL);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        // Check if withdrawal maintains safe collateral ratio
        let new_collateral_balance = balance::value(&vault.collateral_balance) - amount;
        
        // Calculate total debt value and ensure safe ratio after withdrawal
        let total_debt_value = calculate_total_debt_value(vault, registry, price_info, clock);
        if (total_debt_value > 0) {
            let new_ratio = (new_collateral_balance * BASIS_POINTS) / total_debt_value;
            assert!(new_ratio >= registry.global_params.min_collateral_ratio, E_COLLATERAL_RATIO_TOO_LOW);
        };
        
        let withdrawn_balance = balance::split(&mut vault.collateral_balance, amount);
        vault.last_update = sui::clock::timestamp_ms(clock);
        
        event::emit(CollateralWithdrawn {
            vault_id: sui::object::uid_to_inner(&vault.id),
            amount,
            new_balance: balance::value(&vault.collateral_balance),
            withdrawer: sui::tx_context::sender(ctx),
            timestamp: sui::clock::timestamp_ms(clock),
        });
        
        coin::from_balance(withdrawn_balance, ctx)
    }
    
    // ========== Synthetic Asset Management ==========
    
    /// Mint synthetic tokens against USDC collateral
    public fun mint_synthetic<T>(
        vault: &mut CollateralVault,
        synthetic_type: String,
        amount: u64,
        registry: &mut SynthRegistry,
        price_info: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SyntheticCoin<T> {
        assert!(vault.owner == sui::tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(table::contains(&registry.synthetics, synthetic_type), E_ASSET_NOT_FOUND);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        // Get synthetic asset data first
        let synthetic_asset = table::borrow(&registry.synthetics, synthetic_type);
        assert!(synthetic_asset.is_active, E_ASSET_NOT_ACTIVE);
        let decimals = synthetic_asset.decimals;
        let min_collateral_ratio = synthetic_asset.min_collateral_ratio;
        let pyth_feed_id = synthetic_asset.pyth_feed_id;
        
        // Validate price feed and extract price value
        let price = validate_price_feed(price_info, pyth_feed_id, clock);
        let price_i64 = price::get_price(&price);
        let price_value = i64::get_magnitude_if_positive(&price_i64);
        
        // Calculate required collateral for minting - using std::u64::pow
        let mint_value_usd = (amount * price_value) / pow(10, (decimals as u64));
        
        // Check current debt and collateral
        let current_debt = if (table::contains(&vault.synthetic_debt, synthetic_type)) {
            *table::borrow(&vault.synthetic_debt, synthetic_type)
        } else {
            0
        };
        
        let new_debt = current_debt + amount;
        let total_debt_value = calculate_total_debt_value(vault, registry, price_info, clock) + mint_value_usd;
        
        // Ensure sufficient collateral
        let collateral_value = balance::value(&vault.collateral_balance);
        let new_ratio = (collateral_value * BASIS_POINTS) / total_debt_value;
        assert!(new_ratio >= min_collateral_ratio, E_INSUFFICIENT_COLLATERAL);
        
        // Calculate and collect minting fee
        let fee = calculate_fee_with_discount_internal(mint_value_usd, registry.global_params.minting_fee, string::utf8(b"USDC"), 0);
        
        // Now update vault debt and synthetic asset supply
        if (table::contains(&vault.synthetic_debt, synthetic_type)) {
            let debt = table::borrow_mut(&mut vault.synthetic_debt, synthetic_type);
            *debt = new_debt;
        } else {
            table::add(&mut vault.synthetic_debt, synthetic_type, new_debt);
        };
        
        // Update synthetic asset supply
        let synthetic_asset_mut = table::borrow_mut(&mut registry.synthetics, synthetic_type);
        synthetic_asset_mut.total_supply = synthetic_asset_mut.total_supply + amount;
        vault.last_update = sui::clock::timestamp_ms(clock);
        
        // Create synthetic coin with zero balance (in real implementation, mint proper tokens)
        let synthetic_coin = SyntheticCoin<T> {
            id: sui::object::new(ctx),
            balance: balance::zero<T>(),
            synthetic_type,
        };
        
        // Emit events
        event::emit(SyntheticMinted {
            vault_id: sui::object::uid_to_inner(&vault.id),
            synthetic_type,
            amount_minted: amount,
            usdc_collateral_deposited: 0, // No additional collateral deposited in mint
            minter: sui::tx_context::sender(ctx),
            new_collateral_ratio: new_ratio,
            timestamp: sui::clock::timestamp_ms(clock),
        });
        
        event::emit(FeeCollected {
            fee_type: string::utf8(b"minting"),
            amount: fee.final_fee,
            asset_type: fee.payment_asset,
            user: sui::tx_context::sender(ctx),
            unxv_discount_applied: fee.unxv_discount > 0,
            timestamp: sui::clock::timestamp_ms(clock),
        });
        
        synthetic_coin
    }
    
    /// Burn synthetic tokens to reduce debt and potentially release collateral
    public fun burn_synthetic<T>(
        vault: &mut CollateralVault,
        synthetic_coin: SyntheticCoin<T>,
        registry: &mut SynthRegistry,
        price_info: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Option<Coin<USDC>> {
        assert!(vault.owner == sui::tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        
        let SyntheticCoin { id, balance: burn_balance, synthetic_type } = synthetic_coin;
        sui::object::delete(id);
        
        let burn_amount = balance::value(&burn_balance);
        assert!(burn_amount > 0, E_INVALID_AMOUNT);
        assert!(table::contains(&vault.synthetic_debt, synthetic_type), E_INSUFFICIENT_DEBT);
        
        let current_debt = table::borrow_mut(&mut vault.synthetic_debt, synthetic_type);
        assert!(*current_debt >= burn_amount, E_INSUFFICIENT_DEBT);
        
        // Calculate burning fee
        let synthetic_asset = table::borrow_mut(&mut registry.synthetics, synthetic_type);
        let price = validate_price_feed(price_info, synthetic_asset.pyth_feed_id, clock);
        let price_i64 = price::get_price(&price);
        let price_value = i64::get_magnitude_if_positive(&price_i64);
        let burn_value_usd = (burn_amount * price_value) / pow(10, (synthetic_asset.decimals as u64));
        
        let fee = calculate_fee_with_discount_internal(burn_value_usd, registry.global_params.burning_fee, string::utf8(b"USDC"), 0);
        
        // Update debt
        *current_debt = *current_debt - burn_amount;
        if (*current_debt == 0) {
            table::remove(&mut vault.synthetic_debt, synthetic_type);
        };
        
        // Update synthetic asset supply
        synthetic_asset.total_supply = synthetic_asset.total_supply - burn_amount;
        vault.last_update = sui::clock::timestamp_ms(clock);
        
        // Destroy the burned balance
        balance::destroy_zero(burn_balance);
        
        // Calculate new collateral ratio
        let total_debt_value = calculate_total_debt_value(vault, registry, price_info, clock);
        let collateral_value = balance::value(&vault.collateral_balance);
        let new_ratio = if (total_debt_value > 0) {
            (collateral_value * BASIS_POINTS) / total_debt_value
        } else {
            BASIS_POINTS * 10 // Very high ratio when no debt
        };
        
        // Emit events
        event::emit(SyntheticBurned {
            vault_id: sui::object::uid_to_inner(&vault.id),
            synthetic_type,
            amount_burned: burn_amount,
            usdc_collateral_withdrawn: 0, // No automatic collateral withdrawal
            burner: sui::tx_context::sender(ctx),
            new_collateral_ratio: new_ratio,
            timestamp: sui::clock::timestamp_ms(clock),
        });
        
        event::emit(FeeCollected {
            fee_type: string::utf8(b"burning"),
            amount: fee.final_fee,
            asset_type: fee.payment_asset,
            user: sui::tx_context::sender(ctx),
            unxv_discount_applied: fee.unxv_discount > 0,
            timestamp: sui::clock::timestamp_ms(clock),
        });
        
        std::option::none<Coin<USDC>>() // In real implementation, might return excess collateral
    }
    
    // ========== Liquidation Functions ==========
    
    /// Liquidate an undercollateralized vault
    public fun liquidate_vault<T>(
        vault: &mut CollateralVault,
        synthetic_type: String,
        liquidation_amount: u64,
        registry: &mut SynthRegistry,
        price_info: &PriceInfoObject,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (SyntheticCoin<T>, Coin<USDC>) {
        assert!(!registry.is_paused, E_SYSTEM_PAUSED);
        assert!(liquidation_amount > 0, E_INVALID_AMOUNT);
        assert!(table::contains(&vault.synthetic_debt, synthetic_type), E_INSUFFICIENT_DEBT);
        
        // Check if vault is liquidatable
        let (_current_ratio, is_liquidatable) = check_vault_health(vault, synthetic_type, registry, price_info, clock);
        assert!(is_liquidatable, E_VAULT_NOT_LIQUIDATABLE);
        
        let current_debt = table::borrow_mut(&mut vault.synthetic_debt, synthetic_type);
        let actual_liquidation_amount = min(liquidation_amount, *current_debt);
        
        // Calculate collateral to seize
        let synthetic_asset = table::borrow(&registry.synthetics, synthetic_type);
        let price = validate_price_feed(price_info, synthetic_asset.pyth_feed_id, clock);
        let price_i64 = price::get_price(&price);
        let price_value = i64::get_magnitude_if_positive(&price_i64);
        
        let liquidation_value = (actual_liquidation_amount * price_value) / pow(10, (synthetic_asset.decimals as u64));
        let penalty_amount = (liquidation_value * registry.global_params.liquidation_penalty) / BASIS_POINTS;
        let total_seizure = liquidation_value + penalty_amount;
        
        assert!(balance::value(&vault.collateral_balance) >= total_seizure, E_INSUFFICIENT_COLLATERAL);
        
        // Update vault state
        *current_debt = *current_debt - actual_liquidation_amount;
        if (*current_debt == 0) {
            table::remove(&mut vault.synthetic_debt, synthetic_type);
        };
        
        // Seize collateral
        let seized_balance = balance::split(&mut vault.collateral_balance, total_seizure);
        vault.last_update = sui::clock::timestamp_ms(clock);
        
        // Create synthetic tokens for liquidator to repay debt
        let synthetic_coin = SyntheticCoin<T> {
            id: sui::object::new(ctx),
            balance: balance::zero<T>(),
            synthetic_type,
        };
        
        // Emit liquidation event
        event::emit(LiquidationExecuted {
            vault_id: sui::object::uid_to_inner(&vault.id),
            liquidator: sui::tx_context::sender(ctx),
            liquidated_amount: actual_liquidation_amount,
            usdc_collateral_seized: total_seizure,
            liquidation_penalty: penalty_amount,
            synthetic_type,
            timestamp: sui::clock::timestamp_ms(clock),
        });
        
        (synthetic_coin, coin::from_balance(seized_balance, ctx))
    }
    
    // ========== Helper Functions ==========
    
    /// Calculate fee with UNXV discount
    fun calculate_fee_with_discount_internal(
        base_amount: u64,
        fee_rate: u64,
        payment_asset: String,
        unxv_balance: u64,
    ): FeeCalculation {
        let base_fee = (base_amount * fee_rate) / BASIS_POINTS;
        let unxv_discount = if (payment_asset == string::utf8(b"UNXV") && unxv_balance >= base_fee) {
            (base_fee * UNXV_FEE_DISCOUNT) / BASIS_POINTS
        } else {
            0
        };
        let final_fee = base_fee - unxv_discount;
        
        FeeCalculation {
            base_fee,
            unxv_discount,
            final_fee,
            payment_asset,
        }
    }
    
    #[test_only]
    /// Public version of calculate_fee_with_discount for testing
    public fun calculate_fee_with_discount(
        base_amount: u64,
        fee_rate: u64,
        payment_asset: String,
        unxv_balance: u64,
    ): FeeCalculation {
        calculate_fee_with_discount_internal(base_amount, fee_rate, payment_asset, unxv_balance)
    }
    
    /// Validate Pyth price feed
    fun validate_price_feed(
        price_info: &PriceInfoObject,
        _expected_feed_id: vector<u8>,
        clock: &Clock,
    ): Price {
        // Get price with staleness check
        let price = pyth::get_price_no_older_than(price_info, clock, MAX_PRICE_AGE);
        
        // Verify feed ID matches expected
        let price_feed = price_info::get_price_info_from_price_info_object(price_info);
        let _feed_id = price_info::get_price_identifier(&price_feed);
        // Note: In real implementation, compare feed_id with expected_feed_id
        
        price
    }
    
    /// Calculate total debt value across all synthetic assets in a vault
    fun calculate_total_debt_value(
        _vault: &CollateralVault,
        _registry: &SynthRegistry,
        _price_info: &PriceInfoObject,
        _clock: &Clock,
    ): u64 {
        // In real implementation, iterate through all debt positions
        // and calculate total value using current prices
        // For now, return placeholder
        0
    }
    
    /// Check vault health and liquidation status
    public fun check_vault_health(
        vault: &CollateralVault,
        _synthetic_type: String,
        registry: &SynthRegistry,
        price_info: &PriceInfoObject,
        clock: &Clock,
    ): (u64, bool) {
        let total_debt_value = calculate_total_debt_value(vault, registry, price_info, clock);
        let collateral_value = balance::value(&vault.collateral_balance);
        
        if (total_debt_value == 0) {
            return (BASIS_POINTS * 10, false) // Very high ratio, not liquidatable
        };
        
        let current_ratio = (collateral_value * BASIS_POINTS) / total_debt_value;
        let is_liquidatable = current_ratio < registry.global_params.liquidation_threshold;
        
        (current_ratio, is_liquidatable)
    }
    
    /// Get system health metrics
    public fun check_system_stability(
        _registry: &SynthRegistry,
    ): SystemHealth {
        // In real implementation, aggregate all vault data
        SystemHealth {
            total_collateral_value: 0,
            total_synthetic_value: 0,
            global_collateral_ratio: BASIS_POINTS,
            at_risk_vaults: 0,
            system_solvent: true,
        }
    }
    
    // ========== Utility Functions ==========
    
    /// Helper function for exponentiation (replaces deprecated math::pow)
    fun pow(base: u64, exp: u64): u64 {
        if (exp == 0) return 1;
        let mut result = 1;
        let mut b = base;
        let mut e = exp;
        while (e > 0) {
            if (e % 2 == 1) {
                result = result * b;
            };
            b = b * b;
            e = e / 2;
        };
        result
    }
    
    /// Helper function for min (replaces deprecated math::min)
    fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }
    
    // ========== Getter Functions ==========
    
    /// Get synthetic asset information
    public fun get_synthetic_asset(
        registry: &SynthRegistry,
        asset_symbol: String,
    ): &SyntheticAsset {
        table::borrow(&registry.synthetics, asset_symbol)
    }
    
    /// Get vault collateral balance
    public fun get_vault_collateral_balance(vault: &CollateralVault): u64 {
        balance::value(&vault.collateral_balance)
    }
    
    /// Get vault debt for specific synthetic
    public fun get_vault_debt(vault: &CollateralVault, synthetic_type: String): u64 {
        if (table::contains(&vault.synthetic_debt, synthetic_type)) {
            *table::borrow(&vault.synthetic_debt, synthetic_type)
        } else {
            0
        }
    }
    
    /// Get global parameters
    public fun get_global_params(registry: &SynthRegistry): &GlobalParams {
        &registry.global_params
    }
    
    /// Check if system is paused
    public fun is_system_paused(registry: &SynthRegistry): bool {
        registry.is_paused
    }
    
    /// Get synthetic coin balance
    public fun get_synthetic_balance<T>(coin: &SyntheticCoin<T>): u64 {
        balance::value(&coin.balance)
    }
    
    /// Get synthetic coin type
    public fun get_synthetic_type<T>(coin: &SyntheticCoin<T>): String {
        coin.synthetic_type
    }
    
    // ========== Test-only Functions ==========
    
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
    
    #[test_only]
    public fun create_test_usdc(amount: u64, ctx: &mut TxContext): Coin<USDC> {
        coin::from_balance(balance::create_for_testing<USDC>(amount), ctx)
    }
    
    // ========== Test-only Getter Functions ==========
    
    #[test_only]
    public fun get_asset_name(asset: &SyntheticAsset): String {
        asset.name
    }
    
    #[test_only]
    public fun get_asset_symbol(asset: &SyntheticAsset): String {
        asset.symbol
    }
    
    #[test_only]
    public fun get_asset_decimals(asset: &SyntheticAsset): u8 {
        asset.decimals
    }
    
    #[test_only]
    public fun get_asset_min_collateral_ratio(asset: &SyntheticAsset): u64 {
        asset.min_collateral_ratio
    }
    
    #[test_only]
    public fun get_asset_is_active(asset: &SyntheticAsset): bool {
        asset.is_active
    }
    
    #[test_only]
    public fun get_asset_total_supply(asset: &SyntheticAsset): u64 {
        asset.total_supply
    }
    
    #[test_only]
    public fun get_params_min_collateral_ratio(params: &GlobalParams): u64 {
        params.min_collateral_ratio
    }
    
    #[test_only]
    public fun get_params_liquidation_threshold(params: &GlobalParams): u64 {
        params.liquidation_threshold
    }
    
    #[test_only]
    public fun get_params_liquidation_penalty(params: &GlobalParams): u64 {
        params.liquidation_penalty
    }
    
    #[test_only]
    public fun get_health_system_solvent(health: &SystemHealth): bool {
        health.system_solvent
    }
    
    #[test_only]
    public fun get_health_at_risk_vaults(health: &SystemHealth): u64 {
        health.at_risk_vaults
    }
    
    #[test_only]
    public fun get_fee_base_fee(fee: &FeeCalculation): u64 {
        fee.base_fee
    }
    
    #[test_only]
    public fun get_fee_unxv_discount(fee: &FeeCalculation): u64 {
        fee.unxv_discount
    }
    
    #[test_only]
    public fun get_fee_final_fee(fee: &FeeCalculation): u64 {
        fee.final_fee
    }
    
    #[test_only]
    public fun get_fee_payment_asset(fee: &FeeCalculation): String {
        fee.payment_asset
    }
    
    #[test_only]
    public fun create_global_params_for_testing(
        min_collateral_ratio: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        max_synthetics: u64,
        stability_fee: u64,
        minting_fee: u64,
        burning_fee: u64,
    ): GlobalParams {
        GlobalParams {
            min_collateral_ratio,
            liquidation_threshold,
            liquidation_penalty,
            max_synthetics,
            stability_fee,
            minting_fee,
            burning_fee,
        }
    }
}


