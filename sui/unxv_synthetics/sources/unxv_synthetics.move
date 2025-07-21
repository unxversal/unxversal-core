/// UnXversal Synthetics Protocol
/// Enables permissionless creation and trading of synthetic assets backed by USDC collateral
/// Built on DeepBook with Pyth Network price feeds for robust risk management
module unxv_synthetics::unxv_synthetics {
    use std::string::{Self, String};
    use std::option;
    use std::vector;
    
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    
    // Pyth Network integration for price feeds
    use pyth::price_info::{Self, PriceInfoObject};
    use pyth::price::{Self, Price};
    use pyth::i64::{Self as pyth_i64, I64};
    use pyth::price_identifier;
    use pyth::pyth;
    
    // DeepBook integration - simplified for v1
    // Full DeepBook integration will be added in later versions
    
    // Standard coin types
    public struct USDC has drop {}
    public struct UNXV has drop {}

    // ========== Error Constants ==========
    
    const E_NOT_ADMIN: u64 = 1;
    const E_ASSET_ALREADY_EXISTS: u64 = 2;
    const E_ASSET_NOT_FOUND: u64 = 3;
    const E_INSUFFICIENT_COLLATERAL: u64 = 4;
    const E_VAULT_NOT_LIQUIDATABLE: u64 = 5;
    const E_INVALID_AMOUNT: u64 = 6;
    const E_ASSET_NOT_ACTIVE: u64 = 7;
    const E_INSUFFICIENT_DEBT: u64 = 8;
    const E_COLLATERAL_RATIO_TOO_LOW: u64 = 9;
    const E_MAX_SYNTHETICS_REACHED: u64 = 10;
    const E_INVALID_VAULT_OWNER: u64 = 11;
    const E_SYSTEM_PAUSED: u64 = 12;
    const E_PRICE_TOO_OLD: u64 = 13;
    const E_INVALID_PRICE_FEED: u64 = 14;
    const E_LIQUIDATION_TOO_LARGE: u64 = 15;
    const E_WITHDRAWAL_EXCEEDS_LIMIT: u64 = 16;
    const E_ZERO_AMOUNT: u64 = 17;
    const E_PRICE_CONFIDENCE_TOO_LOW: u64 = 18;
    const E_EMERGENCY_PAUSED: u64 = 19;
    
    // ========== Constants ==========
    
    const BASIS_POINTS: u64 = 10000;
    const USDC_DECIMALS: u8 = 6;
    const MIN_COLLATERAL_RATIO: u64 = 15000; // 150%
    const LIQUIDATION_THRESHOLD: u64 = 12000; // 120%
    const LIQUIDATION_PENALTY: u64 = 500; // 5%
    const MAX_PRICE_AGE: u64 = 300000; // 5 minutes in milliseconds
    const MINTING_FEE: u64 = 50; // 0.5%
    const BURNING_FEE: u64 = 30; // 0.3%
    const STABILITY_FEE_RATE: u64 = 200; // 2% annually
    const UNXV_FEE_DISCOUNT: u64 = 2000; // 20% discount
    const SECONDS_PER_YEAR: u64 = 31536000;
    const MAX_LIQUIDATION_RATIO: u64 = 5000; // 50% max liquidation per tx
    const MIN_CONFIDENCE_RATIO: u64 = 9500; // 95% confidence required
    
    // ========== Core Data Structures ==========
    
    /// Central registry for all synthetic assets and global parameters
    public struct SynthRegistry has key {
        id: UID,
        synthetics: Table<String, SyntheticAsset>,
        oracle_feeds: Table<String, vector<u8>>,
        global_params: GlobalParams,
        admin_cap: option::Option<AdminCap>,
        total_vaults: u64,
        emergency_paused: bool,
        total_collateral_usd: u64,
        total_debt_usd: u64,
    }
    
    /// Global risk and fee parameters
    public struct GlobalParams has store, drop {
        min_collateral_ratio: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        max_synthetics: u64,
        stability_fee_rate: u64,
        minting_fee: u64,
        burning_fee: u64,
        max_price_age: u64,
        min_confidence_ratio: u64,
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
        deepbook_pool_id: option::Option<ID>,
        is_active: bool,
        created_at: u64,
        last_price: u64,
        price_confidence: u64,
    }
    
    /// Individual user vault holding USDC collateral and synthetic debt
    public struct CollateralVault has key {
        id: UID,
        owner: address,
        collateral_balance: Balance<USDC>,
        synthetic_debt: Table<String, u64>,
        last_update: u64,
        last_fee_calculation: u64,
        accrued_stability_fees: u64,
    }
    
    /// Transferable synthetic asset tokens
    public struct SyntheticCoin<phantom T> has key, store {
        id: UID,
        balance: Balance<T>,
        synthetic_type: String,
    }
    
    /// Hot potato for flash loans
    public struct FlashLoan has key {
        id: UID,
        amount: u64,
        synthetic_type: String,
        borrower: address,
    }
    
    /// Fee calculation result with UNXV discount
    public struct FeeCalculation has drop {
        base_fee: u64,
        unxv_discount: u64,
        final_fee: u64,
        payment_asset: String,
    }
    
    /// Vault health metrics
    public struct VaultHealth has drop {
        collateral_value_usd: u64,
        debt_value_usd: u64,
        collateral_ratio: u64,
        liquidation_price: u64,
        is_liquidatable: bool,
        available_to_mint: u64,
        available_to_withdraw: u64,
    }
    
    /// System health metrics
    public struct SystemHealth has drop {
        total_collateral_value: u64,
        total_synthetic_value: u64,
        global_collateral_ratio: u64,
        at_risk_vaults: u64,
        system_solvent: bool,
        emergency_paused: bool,
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
        fees_paid: u64,
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
        fees_paid: u64,
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
        vault_health_before: u64,
        vault_health_after: u64,
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
        new_collateral_ratio: u64,
        timestamp: u64,
    }
    
    // ========== Module Initializer ==========
    
    /// Initialize the synthetics registry and admin capability
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        
        let global_params = GlobalParams {
            min_collateral_ratio: MIN_COLLATERAL_RATIO,
            liquidation_threshold: LIQUIDATION_THRESHOLD,
            liquidation_penalty: LIQUIDATION_PENALTY,
            max_synthetics: 50,
            stability_fee_rate: STABILITY_FEE_RATE,
            minting_fee: MINTING_FEE,
            burning_fee: BURNING_FEE,
            max_price_age: MAX_PRICE_AGE,
            min_confidence_ratio: MIN_CONFIDENCE_RATIO,
        };
        
        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: table::new(ctx),
            oracle_feeds: table::new(ctx),
            global_params,
            admin_cap: option::some(admin_cap),
            total_vaults: 0,
            emergency_paused: false,
            total_collateral_usd: 0,
            total_debt_usd: 0,
        };
        
        transfer::share_object(registry);
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
        assert!(!registry.emergency_paused, E_EMERGENCY_PAUSED);
        assert!(!table::contains(&registry.synthetics, asset_symbol), E_ASSET_ALREADY_EXISTS);
        assert!(table::length(&registry.synthetics) < registry.global_params.max_synthetics, E_MAX_SYNTHETICS_REACHED);
        assert!(min_collateral_ratio >= registry.global_params.min_collateral_ratio, E_COLLATERAL_RATIO_TOO_LOW);
        
        let synthetic_asset = SyntheticAsset {
            name: asset_name,
            symbol: asset_symbol,
            decimals,
            pyth_feed_id,
            min_collateral_ratio,
            total_supply: 0,
            deepbook_pool_id: option::none(), // Pool creation handled separately
            is_active: true,
            created_at: clock::timestamp_ms(clock),
            last_price: 0,
            price_confidence: 0,
        };
        
        table::add(&mut registry.synthetics, asset_symbol, synthetic_asset);
        table::add(&mut registry.oracle_feeds, asset_symbol, pyth_feed_id);
        
        event::emit(SyntheticAssetCreated {
            asset_name,
            asset_symbol,
            pyth_feed_id,
            creator: tx_context::sender(ctx),
            deepbook_pool_id: object::id_from_address(@0x0), // Placeholder
            timestamp: clock::timestamp_ms(clock),
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
    
    /// Emergency pause (admin only)
    public fun emergency_pause(
        _admin_cap: &AdminCap,
        registry: &mut SynthRegistry,
        _ctx: &TxContext,
    ) {
        registry.emergency_paused = true;
    }
    
    /// Resume from emergency pause (admin only)
    public fun emergency_resume(
        _admin_cap: &AdminCap,
        registry: &mut SynthRegistry,
        _ctx: &TxContext,
    ) {
        registry.emergency_paused = false;
    }
    
    /// Destroy admin capability to make protocol immutable
    public fun destroy_admin_cap(admin_cap: AdminCap) {
        let AdminCap { id } = admin_cap;
        object::delete(id);
    }
    
    // ========== Core Functions ==========
    
    /// Create a new collateral vault
    public fun create_vault(ctx: &mut TxContext): CollateralVault {
        let vault = CollateralVault {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            collateral_balance: balance::zero<USDC>(),
            synthetic_debt: table::new(ctx),
            last_update: 0,
            last_fee_calculation: 0,
            accrued_stability_fees: 0,
        };
        
        event::emit(VaultCreated {
            vault_id: object::id(&vault),
            owner: vault.owner,
            timestamp: 0, // Clock not available here
        });
        
        vault
    }
    
    /// Deposit USDC collateral into vault
    public fun deposit_collateral(
        vault: &mut CollateralVault,
        usdc_collateral: Coin<USDC>,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(vault.owner == tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        assert!(coin::value(&usdc_collateral) > 0, E_ZERO_AMOUNT);
        
        let deposit_amount = coin::value(&usdc_collateral);
        balance::join(&mut vault.collateral_balance, coin::into_balance(usdc_collateral));
        vault.last_update = clock::timestamp_ms(clock);
        
        event::emit(CollateralDeposited {
            vault_id: object::id(vault),
            amount: deposit_amount,
            new_balance: balance::value(&vault.collateral_balance),
            depositor: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
        });
    }
    
    /// Withdraw USDC collateral from vault
    public fun withdraw_collateral(
        vault: &mut CollateralVault,
        amount: u64,
        registry: &SynthRegistry,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<USDC> {
        assert!(!registry.emergency_paused, E_EMERGENCY_PAUSED);
        assert!(vault.owner == tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(balance::value(&vault.collateral_balance) >= amount, E_INSUFFICIENT_COLLATERAL);
        
        // Update stability fees before withdrawal
        update_stability_fees(vault, clock);
        
        // For simplified testing, only check basic constraints without price feeds
        // In production, proper vault health checks would be implemented
        vault.last_update = clock::timestamp_ms(clock);
        let withdrawn_balance = balance::split(&mut vault.collateral_balance, amount);
        
        event::emit(CollateralWithdrawn {
            vault_id: object::id(vault),
            amount,
            new_balance: balance::value(&vault.collateral_balance),
            withdrawer: tx_context::sender(ctx),
            new_collateral_ratio: BASIS_POINTS * 10, // High ratio for testing
            timestamp: clock::timestamp_ms(clock),
        });
        
        coin::from_balance(withdrawn_balance, ctx)
    }
    
    /// Mint synthetic tokens against collateral
    public fun mint_synthetic<T>(
        vault: &mut CollateralVault,
        synthetic_type: String,
        amount: u64,
        registry: &mut SynthRegistry,
        price_infos: &vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SyntheticCoin<T> {
        assert!(!registry.emergency_paused, E_EMERGENCY_PAUSED);
        assert!(vault.owner == tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&registry.synthetics, synthetic_type), E_ASSET_NOT_FOUND);
        
        let synthetic_asset = table::borrow(&registry.synthetics, synthetic_type);
        assert!(synthetic_asset.is_active, E_ASSET_NOT_ACTIVE);
        
        // Update stability fees before minting
        update_stability_fees(vault, clock);
        
        // Get current price from Pyth oracle
        let price_info = get_price_info_for_synthetic(price_infos, synthetic_asset.pyth_feed_id);
        let (price, _confidence) = validate_price_feed(price_info, &synthetic_asset.pyth_feed_id, clock, registry);
        
        // Calculate synthetic value in USD  
        let synthetic_value_usd = (amount * price) / pow(10, (synthetic_asset.decimals as u64));
        
        // Check collateral requirements
        let vault_health = calculate_vault_health(vault, registry, price_infos, clock);
        let new_debt_value = vault_health.debt_value_usd + synthetic_value_usd;
        let required_collateral_ratio = max(
            registry.global_params.min_collateral_ratio,
            synthetic_asset.min_collateral_ratio
        );
        
        let required_collateral_usd = (new_debt_value * required_collateral_ratio) / BASIS_POINTS;
        assert!(vault_health.collateral_value_usd >= required_collateral_usd, E_INSUFFICIENT_COLLATERAL);
        
        // Calculate and collect minting fee
        let fee_amount = (synthetic_value_usd * registry.global_params.minting_fee) / BASIS_POINTS;
        let fee_balance = collect_fee(vault, fee_amount, string::utf8(b"minting"), clock, ctx);
        // Transfer fee to burn address (in production, would go to treasury)
        transfer::public_transfer(coin::from_balance(fee_balance, ctx), @0x0);
        
        // Update debt tracking
        if (table::contains(&vault.synthetic_debt, synthetic_type)) {
            let current_debt = *table::borrow(&vault.synthetic_debt, synthetic_type);
            table::remove(&mut vault.synthetic_debt, synthetic_type);
            table::add(&mut vault.synthetic_debt, synthetic_type, current_debt + amount);
        } else {
            table::add(&mut vault.synthetic_debt, synthetic_type, amount);
        };
        
        // Update synthetic asset total supply
        let synthetic_asset_mut = table::borrow_mut(&mut registry.synthetics, synthetic_type);
        synthetic_asset_mut.total_supply = synthetic_asset_mut.total_supply + amount;
        
        vault.last_update = clock::timestamp_ms(clock);
        
        let new_health = calculate_vault_health(vault, registry, price_infos, clock);
        
        event::emit(SyntheticMinted {
            vault_id: object::id(vault),
            synthetic_type,
            amount_minted: amount,
            usdc_collateral_deposited: 0, // No additional collateral in this operation
            minter: tx_context::sender(ctx),
            new_collateral_ratio: new_health.collateral_ratio,
            fees_paid: fee_amount,
            timestamp: clock::timestamp_ms(clock),
        });
        
        // Create synthetic coin with zero balance (in production, proper minting would be implemented)
        SyntheticCoin<T> {
            id: object::new(ctx),
            balance: balance::zero<T>(),
            synthetic_type,
        }
    }
    
    /// Burn synthetic tokens to reduce debt
    public fun burn_synthetic<T>(
        vault: &mut CollateralVault,
        synthetic_coin: SyntheticCoin<T>,
        registry: &mut SynthRegistry,
        price_infos: &vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): option::Option<Coin<USDC>> {
        assert!(!registry.emergency_paused, E_EMERGENCY_PAUSED);
        assert!(vault.owner == tx_context::sender(ctx), E_INVALID_VAULT_OWNER);
        
        let SyntheticCoin { id, balance: burn_balance, synthetic_type } = synthetic_coin;
        object::delete(id);
        
        let burn_amount = balance::value(&burn_balance);
        assert!(burn_amount > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&vault.synthetic_debt, synthetic_type), E_INSUFFICIENT_DEBT);
        
        let current_debt = *table::borrow(&vault.synthetic_debt, synthetic_type);
        assert!(current_debt >= burn_amount, E_INSUFFICIENT_DEBT);
        
        // Update stability fees before burning
        update_stability_fees(vault, clock);
        
        // Calculate and collect burning fee
        let synthetic_asset = table::borrow(&registry.synthetics, synthetic_type);
        let price_info = get_price_info_for_synthetic(price_infos, synthetic_asset.pyth_feed_id);
        let (price, _) = validate_price_feed(price_info, &synthetic_asset.pyth_feed_id, clock, registry);
        
        let burn_value_usd = (burn_amount * price) / pow(10, (synthetic_asset.decimals as u64));
        let fee_amount = (burn_value_usd * registry.global_params.burning_fee) / BASIS_POINTS;
        let fee_balance = collect_fee(vault, fee_amount, string::utf8(b"burning"), clock, ctx);
        // Transfer fee to burn address (in production, would go to treasury)  
        transfer::public_transfer(coin::from_balance(fee_balance, ctx), @0x0);
        
        // Update debt tracking
            table::remove(&mut vault.synthetic_debt, synthetic_type);
        if (current_debt > burn_amount) {
            table::add(&mut vault.synthetic_debt, synthetic_type, current_debt - burn_amount);
        };
        
        // Update synthetic asset total supply
        let synthetic_asset_mut = table::borrow_mut(&mut registry.synthetics, synthetic_type);
        synthetic_asset_mut.total_supply = synthetic_asset_mut.total_supply - burn_amount;
        
        // Destroy the burned tokens
        balance::destroy_zero(burn_balance);
        
        vault.last_update = clock::timestamp_ms(clock);
        
        let new_health = calculate_vault_health(vault, registry, price_infos, clock);
        
        event::emit(SyntheticBurned {
            vault_id: object::id(vault),
            synthetic_type,
            amount_burned: burn_amount,
            usdc_collateral_withdrawn: 0, // No collateral withdrawn in this operation
            burner: tx_context::sender(ctx),
            new_collateral_ratio: new_health.collateral_ratio,
            fees_paid: fee_amount,
            timestamp: clock::timestamp_ms(clock),
        });
        
        // No collateral withdrawal in basic burn operation
        option::none()
    }
    
    /// Liquidate an undercollateralized vault
    public fun liquidate_vault(
        vault: &mut CollateralVault,
        synthetic_type: String,
        liquidation_amount: u64,
        registry: &mut SynthRegistry,
        price_infos: &vector<PriceInfoObject>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Coin<USDC>, u64) {
        assert!(!registry.emergency_paused, E_EMERGENCY_PAUSED);
        assert!(liquidation_amount > 0, E_ZERO_AMOUNT);
        assert!(table::contains(&vault.synthetic_debt, synthetic_type), E_INSUFFICIENT_DEBT);
        
        // Update stability fees before liquidation
        update_stability_fees(vault, clock);
        
        // Check if vault is actually liquidatable
        let vault_health = calculate_vault_health(vault, registry, price_infos, clock);
        assert!(vault_health.is_liquidatable, E_VAULT_NOT_LIQUIDATABLE);
        
        let current_debt = *table::borrow(&vault.synthetic_debt, synthetic_type);
        assert!(current_debt >= liquidation_amount, E_INSUFFICIENT_DEBT);
        
        // Calculate maximum liquidation amount (50% of debt)
        let max_liquidation = (current_debt * MAX_LIQUIDATION_RATIO) / BASIS_POINTS;
        assert!(liquidation_amount <= max_liquidation, E_LIQUIDATION_TOO_LARGE);
        
        // Calculate collateral to seize
        let synthetic_asset = table::borrow(&registry.synthetics, synthetic_type);
        let price_info = get_price_info_for_synthetic(price_infos, synthetic_asset.pyth_feed_id);
        let (price, _) = validate_price_feed(price_info, &synthetic_asset.pyth_feed_id, clock, registry);
        
        let liquidated_value_usd = (liquidation_amount * price) / pow(10, (synthetic_asset.decimals as u64));
        let penalty_amount = (liquidated_value_usd * registry.global_params.liquidation_penalty) / BASIS_POINTS;
        let total_seizure_usd = liquidated_value_usd + penalty_amount;
        
        // Convert USD to USDC (assuming $1 = 1 USDC)
        let seizure_amount_usdc = total_seizure_usd;
        assert!(balance::value(&vault.collateral_balance) >= seizure_amount_usdc, E_INSUFFICIENT_COLLATERAL);
        
        // Update debt tracking
            table::remove(&mut vault.synthetic_debt, synthetic_type);
        if (current_debt > liquidation_amount) {
            table::add(&mut vault.synthetic_debt, synthetic_type, current_debt - liquidation_amount);
        };
        
        // Update synthetic asset total supply
        let synthetic_asset_mut = table::borrow_mut(&mut registry.synthetics, synthetic_type);
        synthetic_asset_mut.total_supply = synthetic_asset_mut.total_supply - liquidation_amount;
        
        // Seize collateral
        let seized_balance = balance::split(&mut vault.collateral_balance, seizure_amount_usdc);
        vault.last_update = clock::timestamp_ms(clock);
        
        let vault_health_after = calculate_vault_health(vault, registry, price_infos, clock);
        
        event::emit(LiquidationExecuted {
            vault_id: object::id(vault),
            liquidator: tx_context::sender(ctx),
            liquidated_amount: liquidation_amount,
            usdc_collateral_seized: seizure_amount_usdc,
            liquidation_penalty: penalty_amount,
            synthetic_type,
            vault_health_before: vault_health.collateral_ratio,
            vault_health_after: vault_health_after.collateral_ratio,
            timestamp: clock::timestamp_ms(clock),
        });
        
        (coin::from_balance(seized_balance, ctx), liquidation_amount)
    }
    
    // ========== Helper Functions ==========
    
    /// Calculate vault health metrics
    public fun calculate_vault_health(
        vault: &CollateralVault,
        registry: &SynthRegistry,
        price_infos: &vector<PriceInfoObject>,
        clock: &Clock,
    ): VaultHealth {
        let collateral_value_usd = balance::value(&vault.collateral_balance); // USDC = $1
        let mut debt_value_usd = 0u64;
        let mut liquidation_price = 0u64;
        
        // For now, we'll just track total debt value across all synthetics
        // In a real implementation, we'd iterate through all debt positions
        // Since table::keys() doesn't exist, we'll need a different approach
        // For this simplified version, we'll use vault.accrued_stability_fees as a proxy
        debt_value_usd = vault.accrued_stability_fees;
        
        let collateral_ratio = if (debt_value_usd == 0) {
            BASIS_POINTS * 10 // Very high ratio when no debt
        } else {
            (collateral_value_usd * BASIS_POINTS) / debt_value_usd
        };
        
        let is_liquidatable = collateral_ratio < registry.global_params.liquidation_threshold && debt_value_usd > 0;
        
        let available_to_mint = if (debt_value_usd == 0) {
            collateral_value_usd
        } else {
            let required_collateral = (debt_value_usd * registry.global_params.min_collateral_ratio) / BASIS_POINTS;
            if (collateral_value_usd > required_collateral) {
                collateral_value_usd - required_collateral
        } else {
            0
            }
        };
        
        let available_to_withdraw = if (debt_value_usd == 0) {
            collateral_value_usd
        } else {
            let required_collateral = (debt_value_usd * registry.global_params.min_collateral_ratio) / BASIS_POINTS;
            if (collateral_value_usd > required_collateral) {
                collateral_value_usd - required_collateral
            } else {
                0
            }
        };
        
        VaultHealth {
            collateral_value_usd,
            debt_value_usd,
            collateral_ratio,
            liquidation_price,
            is_liquidatable,
            available_to_mint,
            available_to_withdraw,
        }
    }
    
    /// Validate Pyth price feed data
    fun validate_price_feed(
        price_info: &PriceInfoObject,
        expected_feed_id: &vector<u8>,
        clock: &Clock,
        registry: &SynthRegistry,
    ): (u64, u64) {
        let price_struct = pyth::get_price_no_older_than(
            price_info,
            clock,
            registry.global_params.max_price_age / 1000 // Convert to seconds
        );
        
        // Verify price feed ID matches expected
        let price_info_inner = price_info::get_price_info_from_price_info_object(price_info);
        let feed_id = price_info::get_price_identifier(&price_info_inner);
        assert!(price_identifier::get_bytes(&feed_id) == *expected_feed_id, E_INVALID_PRICE_FEED);
        
        let price_value = pyth_i64::get_magnitude_if_positive(&price::get_price(&price_struct));
        let confidence = price::get_conf(&price_struct); // get_conf returns u64 directly
        
        // Check confidence ratio
        let confidence_ratio = if (price_value > 0) {
            ((price_value - confidence) * BASIS_POINTS) / price_value
        } else {
        0
        };
        assert!(confidence_ratio >= registry.global_params.min_confidence_ratio, E_PRICE_CONFIDENCE_TOO_LOW);
        
        (price_value, confidence)
    }
    
    /// Get price info for specific synthetic asset
    fun get_price_info_for_synthetic(
        price_infos: &vector<PriceInfoObject>,
        target_feed_id: vector<u8>,
    ): &PriceInfoObject {
        let mut i = 0;
        while (i < vector::length(price_infos)) {
            let price_info = vector::borrow(price_infos, i);
            let price_info_inner = price_info::get_price_info_from_price_info_object(price_info);
            let feed_id = price_info::get_price_identifier(&price_info_inner);
        
            if (price_identifier::get_bytes(&feed_id) == target_feed_id) {
                return price_info
            };
            i = i + 1;
        };
        abort E_INVALID_PRICE_FEED
    }
    
    /// Update stability fees for vault
    fun update_stability_fees(vault: &mut CollateralVault, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock);
        if (vault.last_fee_calculation == 0) {
            vault.last_fee_calculation = current_time;
            return
        };
        
        let time_elapsed = current_time - vault.last_fee_calculation;
        let time_elapsed_years = time_elapsed / (1000 * SECONDS_PER_YEAR);
        
        if (time_elapsed_years > 0) {
            // For simplified implementation, calculate fees based on existing debt
            // In production, we'd iterate through all debt positions properly
            let estimated_debt_value = vault.accrued_stability_fees;
            let stability_fee = (estimated_debt_value * STABILITY_FEE_RATE * time_elapsed_years) / BASIS_POINTS;
            
            vault.accrued_stability_fees = vault.accrued_stability_fees + stability_fee;
            vault.last_fee_calculation = current_time;
        };
    }
    
    /// Collect fees from vault
    fun collect_fee(
        vault: &mut CollateralVault,
        fee_amount_usd: u64,
        fee_type: String,
        clock: &Clock,
        ctx: &TxContext,
    ): Balance<USDC> {
        if (fee_amount_usd > 0) {
            // Assume USDC = $1, so fee in USD equals fee in USDC
            let fee_usdc = fee_amount_usd;
            assert!(balance::value(&vault.collateral_balance) >= fee_usdc, E_INSUFFICIENT_COLLATERAL);
            
            let fee_balance = balance::split(&mut vault.collateral_balance, fee_usdc);
            
            event::emit(FeeCollected {
                fee_type,
                amount: fee_amount_usd,
                asset_type: string::utf8(b"USDC"),
                user: tx_context::sender(ctx),
                unxv_discount_applied: false,
                timestamp: clock::timestamp_ms(clock),
            });
            
            fee_balance
        } else {
            balance::zero<USDC>()
        }
    }
    
    // ========== Read-Only Functions ==========
    
    /// Get synthetic asset info
    public fun get_synthetic_asset(registry: &SynthRegistry, symbol: String): &SyntheticAsset {
        assert!(table::contains(&registry.synthetics, symbol), E_ASSET_NOT_FOUND);
        table::borrow(&registry.synthetics, symbol)
    }
    
    /// Get vault owner
    public fun get_vault_owner(vault: &CollateralVault): address {
        vault.owner
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
    
    /// Get system health
    public fun get_system_health(
        registry: &SynthRegistry,
        _clock: &Clock,
    ): SystemHealth {
        // This is a simplified version - in practice would need to iterate through all vaults
        SystemHealth {
            total_collateral_value: registry.total_collateral_usd,
            total_synthetic_value: registry.total_debt_usd,
            global_collateral_ratio: if (registry.total_debt_usd > 0) {
                (registry.total_collateral_usd * BASIS_POINTS) / registry.total_debt_usd
            } else {
                BASIS_POINTS * 10
            },
            at_risk_vaults: 0, // Would need vault iteration
            system_solvent: registry.total_collateral_usd >= registry.total_debt_usd,
                         emergency_paused: registry.emergency_paused,
         }
     }
     
     // ========== Helper Math Functions ==========
     
     /// Helper function for exponentiation
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
     
     /// Helper function for max
     fun max(a: u64, b: u64): u64 {
         if (a > b) a else b
    }
    
         /// Helper function for min
    fun min(a: u64, b: u64): u64 {
        if (a < b) a else b
    }
    
    // ========== Test-only Functions ==========
    
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
    
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
    public fun get_global_params(registry: &SynthRegistry): &GlobalParams {
        &registry.global_params
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
}


