/// Module: **unxversal_synthetics** -
module unxversal::synthetics {
    /*******************************
    * Imports & std aliases
    *******************************/
    use sui::package::{Self, Publisher};
    use sui::display;
    use sui::types;
    use sui::event;
    use std::string::String;
    use sui::vec_set::{Self as vec_set, VecSet};
    use sui::table::{Self as table, Table};
    use sui::clock::Clock;
    use sui::coin::{Self as coin, Coin};
    use sui::balance::{Self as balance, Balance};

    use unxversal::oracle::{PriceInfoObject, OracleConfig, get_latest_price, get_price_scaled_1e6};
    use unxversal::unxv_treasury::{Self as TreasuryMod, Treasury};
    use unxversal::unxv::UNXV;

    /*******************************
    * Error codes (0-99 reserved for general)
    *******************************/
    const E_NOT_ADMIN: u64 = 1;
    const E_ASSET_EXISTS: u64 = 2;
    const E_UNKNOWN_ASSET: u64 = 3;
    const E_VAULT_NOT_HEALTHY: u64 = 4;
    const E_RATIO_TOO_LOW: u64 = 5;
    const E_NOT_OWNER: u64 = 6;
    const E_INVALID_ORDER: u64 = 7;
    const E_ORDER_EXPIRED: u64 = 8;
    const E_SYMBOL_MISMATCH: u64 = 9;
    const E_SIDE_INVALID: u64 = 10;
    const E_BAD_PRICE: u64 = 11;

    /*******************************
    * One-Time Witness (OTW)
    *******************************/
    public struct SYNTHETICS has drop {}

    /*******************************
    * Capability & authority objects
    *******************************/
    public struct DaddyCap has key, store { id: UID }
    public struct AdminCap has key, store { id: UID }

    /*******************************
    * Admin-Set Collateral Pattern
    *******************************/
    public struct CollateralConfig<phantom C> has key, store {
        id: UID,
    }

    /*******************************
    * Global-parameter struct (basis-points units for ratios/fees)
    *******************************/
    public struct GlobalParams has store, drop {
        min_collateral_ratio: u64,
        liquidation_threshold: u64,
        liquidation_penalty: u64,
        max_synthetics: u64,
        stability_fee: u64,
        bot_split: u64,
        mint_fee: u64,
        burn_fee: u64,
        unxv_discount_bps: u64,
        maker_rebate_bps: u64,
    }

    /*******************************
    * Synthetic-asset placeholder (filled out in Phase-2)
    *******************************/
    public struct SyntheticAsset has key, store {
        id: UID,
        name: String,
        symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_collateral_ratio: u64,
        total_supply: u64,
        is_active: bool,
        created_at: u64,
        stability_fee_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_penalty_bps: u64,
        mint_fee_bps: u64,
        burn_fee_bps: u64,
    }

    /*******************************
    * Core shared object - **SynthRegistry**
    *******************************/
    public struct SynthRegistry has key, store {
        id: UID,
        synthetics: Table<String, SyntheticAsset>,
        oracle_feeds: Table<String, vector<u8>>,
        global_params: GlobalParams,
        paused: bool,
        admin_addrs: VecSet<address>,
        treasury_id: ID,
        num_synthetics: u64,
        collateral_set: bool,
    }

    /*******************************
    * Event structs for indexers / UI
    *******************************/
    public struct AdminGranted has copy, drop { admin_addr: address, timestamp: u64 }
    public struct AdminRevoked has copy, drop { admin_addr: address, timestamp: u64 }
    public struct ParamsUpdated has copy, drop { updater: address, timestamp: u64 }
    public struct EmergencyPauseToggled has copy, drop { new_state: bool, by: address, timestamp: u64 }
    public struct VaultCreated has copy, drop { vault_id: ID, owner: address, timestamp: u64 }
    public struct CollateralDeposited has copy, drop { vault_id: ID, amount: u64, depositor: address, timestamp: u64 }
    public struct CollateralWithdrawn has copy, drop { vault_id: ID, amount: u64, withdrawer: address, timestamp: u64 }

    public struct SyntheticAssetCreated has copy, drop {
        asset_name:   String,
        asset_symbol: String,
        pyth_feed_id: vector<u8>,
        creator:      address,
        timestamp:    u64,
    }

    public struct SyntheticMinted has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_minted: u64,
        collateral_deposit: u64,
        minter: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }

    public struct SyntheticBurned has copy, drop {
        vault_id: ID,
        synthetic_type: String,
        amount_burned: u64,
        collateral_withdrawn: u64,
        burner: address,
        new_collateral_ratio: u64,
        timestamp: u64,
    }

    public struct OrderPlaced has copy, drop {
        order_id: ID,
        owner: address,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        remaining: u64,
        created_at_ms: u64,
        expiry_ms: u64,
    }

    public struct OrderCancelled has copy, drop { order_id: ID, owner: address, timestamp: u64 }

    public struct OrderMatched has copy, drop {
        buy_order_id: ID,
        sell_order_id: ID,
        symbol: String,
        price: u64,
        size: u64,
        buyer: address,
        seller: address,
        timestamp: u64,
    }
    public struct MakerRebatePaid has copy, drop {
        amount: u64,
        taker: address,
        maker: address,
        market: String,
        timestamp: u64,
    }
    public struct LiquidationExecuted has copy, drop {
        vault_id: ID,
        liquidator: address,
        liquidated_amount: u64,
        collateral_seized: u64,
        liquidation_penalty: u64,
        synthetic_type: String,
        timestamp: u64,
    }
    public struct StabilityAccrued has copy, drop { vault_id: ID, synthetic_type: String, delta_units: u64, from_ms: u64, to_ms: u64 }

     /*******************************
    * Phase-2 - collateral vault
    *******************************/
    public struct CollateralVault<phantom C> has key, store {
        id: UID,
        owner: address,
        collateral: Balance<C>,
        synthetic_debt: Table<String, u64>,
        last_update_ms: u64,
    }

    /*******************************
    * Orders - decentralized matching (shared objects)
    *******************************/
    public struct Order has key, store {
        id: UID,
        owner: address,
        vault_id: ID,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        remaining: u64,
        created_at_ms: u64,
        expiry_ms: u64,
    }

    /*******************************
    * Phase-2 - Display helpers
    *******************************/
    fun init_synth_display(publisher: &Publisher, _asset: &SyntheticAsset, ctx: &mut TxContext) {
        let mut disp = display::new<SyntheticAsset>(publisher, ctx);
        disp.add(b"name".to_string(),           b"{name}".to_string());
        disp.add(b"description".to_string(),    b"Synthetic {name} provided by Unxversal".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(disp, tx_context::sender(ctx));
    }

    #[allow(unused_function)]
    fun init_vault_display<C>(publisher: &Publisher, ctx: &mut TxContext) {
        let mut disp = display::new<CollateralVault<C>>(publisher, ctx);
        disp.add(b"name".to_string(),          b"UNXV Synth Collateral Vault".to_string());
        disp.add(b"description".to_string(),   b"User-owned vault holding collateral".to_string());
        disp.add(b"image_url".to_string(),     b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(), b"{thumbnail_url}".to_string());
        disp.add(b"creator".to_string(),       b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(disp, tx_context::sender(ctx));
    }

    /*******************************
    * Phase-2 - synthetic asset listing (admin-only)
    *******************************/
    public entry fun create_synthetic_asset(
        registry: &mut SynthRegistry,
        asset_name: String,
        asset_symbol: String,
        decimals: u8,
        pyth_feed_id: vector<u8>,
        min_coll_ratio: u64,
        _admin: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert_is_admin(registry, tx_context::sender(ctx));
        assert!(!table::contains(&registry.synthetics, asset_symbol), E_ASSET_EXISTS);

        let asset = SyntheticAsset {
            id: object::new(ctx),
            name: asset_name,
            symbol: asset_symbol,
            decimals,
            pyth_feed_id,
            min_collateral_ratio: min_coll_ratio,
            total_supply: 0,
            is_active: true,
            created_at: 0u64,
            stability_fee_bps: 0,
            liquidation_threshold_bps: 0,
            liquidation_penalty_bps: 0,
            mint_fee_bps: 0,
            burn_fee_bps: 0,
        };

        table::add(&mut registry.oracle_feeds, asset_symbol, asset.pyth_feed_id);
        table::add(&mut registry.synthetics, asset_symbol, asset);
        registry.num_synthetics = registry.num_synthetics + 1;
        assert!(registry.num_synthetics <= registry.global_params.max_synthetics, E_ASSET_EXISTS);

        event::emit(SyntheticAssetCreated {
            asset_name,
            asset_symbol,
            pyth_feed_id,
            creator: tx_context::sender(ctx),
            timestamp: 0u64,
        });
    }

    /*******************************
     * Per-asset parameter setters (admin-only)
     *******************************/
    public entry fun set_asset_stability_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        let asset = table::borrow_mut(&mut registry.synthetics, symbol);
        asset.stability_fee_bps = bps;
    }

    public entry fun set_asset_liquidation_threshold(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        let asset = table::borrow_mut(&mut registry.synthetics, symbol);
        asset.liquidation_threshold_bps = bps;
    }

    public entry fun set_asset_liquidation_penalty(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        let asset = table::borrow_mut(&mut registry.synthetics, symbol);
        asset.liquidation_penalty_bps = bps;
    }

    public entry fun set_asset_mint_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        let asset = table::borrow_mut(&mut registry.synthetics, symbol);
        asset.mint_fee_bps = bps;
    }

    public entry fun set_asset_burn_fee(
        registry: &mut SynthRegistry,
        symbol: String,
        bps: u64,
        _admin: &AdminCap,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        let asset = table::borrow_mut(&mut registry.synthetics, symbol);
        asset.burn_fee_bps = bps;
    }

    /*******************************
    * Phase-2 - vault lifecycle
    *******************************/
    public entry fun create_vault<C>(
        _cfg: &CollateralConfig<C>,
        registry: &SynthRegistry,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);

        let vault = CollateralVault<C> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            collateral: balance::zero<C>(),
            synthetic_debt: table::new<String, u64>(ctx),
            last_update_ms: 0u64,
        };
        let vault_id = object::id(&vault);
        event::emit(VaultCreated { vault_id, owner: tx_context::sender(ctx), timestamp: 0u64 });
        transfer::share_object(vault);
    }

    public entry fun deposit_collateral<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        coins_in: Coin<C>,
        ctx: &mut TxContext
    ) {
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
        let amount = coins_in.value();
        balance::join(&mut vault.collateral, coin::into_balance(coins_in));
        vault.last_update_ms = 0u64;
        event::emit(CollateralDeposited { vault_id: object::id(vault), amount, depositor: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public fun withdraw_collateral<C>(
        _cfg: &CollateralConfig<C>,
        vault: &mut CollateralVault<C>,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(!registry.paused, 1000);
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);

        let (ratio, _) = check_vault_health(vault, registry, oracle_cfg, clock, price);
        assert!(ratio >= registry.global_params.min_collateral_ratio, E_VAULT_NOT_HEALTHY);

        let coin_out = coin::from_balance(balance::split(&mut vault.collateral, amount), ctx);
        vault.last_update_ms = 0u64;
        event::emit(CollateralWithdrawn { vault_id: object::id(vault), amount, withdrawer: tx_context::sender(ctx), timestamp: 0u64 });
        coin_out
    }

    /*******************************
    * Phase-2 - mint / burn flows
    *******************************/
    fun mint_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: &String,
        amount: u64,
        _ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let asset = table::borrow_mut(&mut registry.synthetics, *synthetic_symbol);
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let debt_table = &mut vault.synthetic_debt;
        let old_debt = if (table::contains(debt_table, *synthetic_symbol)) { *table::borrow(debt_table, *synthetic_symbol) } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_usd = balance::value(&vault.collateral);
        let debt_usd = new_debt * price_u64;
        let new_ratio = if (debt_usd == 0) { 18446744073709551615u64 } else { (collateral_usd * 10_000) / debt_usd };
        let min_req = if (asset.min_collateral_ratio > registry.global_params.min_collateral_ratio) { asset.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);
        table::add(debt_table, *synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply + amount;
        vault.last_update_ms = 0u64;
    }

    fun burn_synthetic_internal<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        _oracle_cfg: &OracleConfig,
        _clock: &Clock,
        _price: &PriceInfoObject,
        synthetic_symbol: &String,
        amount: u64,
        _ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let asset = table::borrow_mut(&mut registry.synthetics, *synthetic_symbol);
        let debt_table = &mut vault.synthetic_debt;
        assert!(table::contains(debt_table, *synthetic_symbol), E_UNKNOWN_ASSET);
        let old_debt = *table::borrow(debt_table, *synthetic_symbol);
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        table::add(debt_table, *synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply - amount;
        vault.last_update_ms = 0u64;
    }

    /*******************************
    * Stability fee accrual - simple linear accrual per call
    *******************************/
    public entry fun accrue_stability<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: String,
        _ctx: &mut TxContext
    ) {
        if (!table::contains(&vault.synthetic_debt, synthetic_symbol)) { return };
        let debt_units = *table::borrow(&vault.synthetic_debt, synthetic_symbol);
        if (debt_units == 0) { return };

        let now_ms = 0u64;
        let last_ms = vault.last_update_ms;
        if (now_ms <= last_ms) { return };
        let elapsed_ms = now_ms - last_ms;

        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let debt_value = debt_units * price_u64;
        let asset = table::borrow(&registry.synthetics, synthetic_symbol);
        let apr_bps = if (asset.stability_fee_bps > 0) { asset.stability_fee_bps } else { registry.global_params.stability_fee };
        let prorated_numerator = debt_value * apr_bps * elapsed_ms;
        let year_ms = 31_536_000_000; // 365d
        let fee_value = prorated_numerator / (10_000 * year_ms);

        if (fee_value > 0 && price_u64 > 0) {
            let delta_units = fee_value / price_u64;
            if (delta_units > 0) {
                let new_debt_units = debt_units + delta_units;
                table::add(&mut vault.synthetic_debt, synthetic_symbol, new_debt_units);
                event::emit(StabilityAccrued { vault_id: object::id(vault), synthetic_type: synthetic_symbol, delta_units, from_ms: last_ms, to_ms: now_ms });
            }
        };
        vault.last_update_ms = now_ms;
    }
    public entry fun mint_synthetic<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: &String,
        amount: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let asset = table::borrow_mut(&mut registry.synthetics, *synthetic_symbol);
        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);

        let debt_table = &mut vault.synthetic_debt;
        let old_debt = if (table::contains(debt_table, *synthetic_symbol)) { *table::borrow(debt_table, *synthetic_symbol) } else { 0 };
        let new_debt = old_debt + amount;
        let collateral_usd = balance::value(&vault.collateral);
        let debt_usd = new_debt * price_u64;
        let new_ratio = if (debt_usd == 0) { 18446744073709551615u64 } else { (collateral_usd * 10_000) / debt_usd };

        let min_req = if (asset.min_collateral_ratio > registry.global_params.min_collateral_ratio) { asset.min_collateral_ratio } else { registry.global_params.min_collateral_ratio };
        assert!(new_ratio >= min_req, E_RATIO_TOO_LOW);

        table::add(debt_table, *synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply + amount;

        let mint_bps = if (asset.mint_fee_bps > 0) { asset.mint_fee_bps } else { registry.global_params.mint_fee };
        let base_fee = (debt_usd * mint_bps) / 10_000;
        let discount_usdc = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        if (discount_usdc > 0 && !vector::is_empty(&unxv_payment)) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                while (!vector::is_empty(&unxv_payment)) {
                    coin::join(&mut merged, vector::pop_back(&mut unxv_payment));
                };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vec = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec, exact);
                    TreasuryMod::deposit_unxv(treasury, vec, b"mint".to_string(), vault.owner, ctx);
                    transfer::public_transfer(merged, vault.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, vault.owner);
                }
            }
        };

        // Consume any remaining unxv_payment
        while (!vector::is_empty(&unxv_payment)) {
            let c = vector::pop_back(&mut unxv_payment);
            if (c.value() > 0) { transfer::public_transfer(c, vault.owner) } else { coin::destroy_zero(c) };
        };
        vector::destroy_empty(unxv_payment);

        let usdc_fee_to_collect = if (discount_applied) { base_fee - discount_usdc } else { base_fee };
        if (usdc_fee_to_collect > 0) {
            let fee_balance = balance::split(&mut vault.collateral, usdc_fee_to_collect);
            TreasuryMod::deposit_usdc(treasury, coin::from_balance(fee_balance, ctx), b"mint".to_string(), tx_context::sender(ctx), ctx);
        };
        unxversal::common::emit_fee_collected_event(
            b"mint".to_string(),
            base_fee,
            *synthetic_symbol,
            tx_context::sender(ctx),
            discount_applied,
            0u64
        );

        event::emit(SyntheticMinted {
            vault_id: object::id(vault),
            synthetic_type: *synthetic_symbol,
            amount_minted: amount,
            collateral_deposit: 0,
            minter: tx_context::sender(ctx),
            new_collateral_ratio: new_ratio,
            timestamp: 0u64,
        });
        vault.last_update_ms = 0u64;
    }

    public entry fun burn_synthetic<C>(
        vault: &mut CollateralVault<C>,
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        synthetic_symbol: &String,
        amount: u64,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let asset = table::borrow_mut(&mut registry.synthetics, *synthetic_symbol);
        let debt_table = &mut vault.synthetic_debt;
        assert!(table::contains(debt_table, *synthetic_symbol), E_UNKNOWN_ASSET);

        let old_debt = *table::borrow(debt_table, *synthetic_symbol);
        assert!(amount <= old_debt, 2000);
        let new_debt = old_debt - amount;
        table::add(debt_table, *synthetic_symbol, new_debt);
        asset.total_supply = asset.total_supply - amount;

        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let base_value = amount * price_u64;
        let burn_bps = if (asset.burn_fee_bps > 0) { asset.burn_fee_bps } else { registry.global_params.burn_fee };
        let base_fee = (base_value * burn_bps) / 10_000;
        let discount_usdc = (base_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;

        if (discount_usdc > 0 && !vector::is_empty(&unxv_payment)) {
            let price_unxv_u64 = get_price_scaled_1e6(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                while (!vector::is_empty(&unxv_payment)) {
                    coin::join(&mut merged, vector::pop_back(&mut unxv_payment));
                };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vec = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec, exact);
                    TreasuryMod::deposit_unxv(treasury, vec, b"burn".to_string(), vault.owner, ctx);
                    transfer::public_transfer(merged, vault.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, vault.owner);
                }
            }
        };
        
        // Consume any remaining unxv_payment
        while (!vector::is_empty(&unxv_payment)) {
            let c = vector::pop_back(&mut unxv_payment);
            if (c.value() > 0) { transfer::public_transfer(c, vault.owner) } else { coin::destroy_zero(c) };
        };
        vector::destroy_empty(unxv_payment);

        let usdc_fee_to_collect = if (discount_applied) { base_fee - discount_usdc } else { base_fee };
        if (usdc_fee_to_collect > 0) {
            let fee_balance = balance::split(&mut vault.collateral, usdc_fee_to_collect);
            TreasuryMod::deposit_usdc(treasury, coin::from_balance(fee_balance, ctx), b"burn".to_string(), tx_context::sender(ctx), ctx);
        };
        unxversal::common::emit_fee_collected_event(
            b"burn".to_string(),
            base_fee,
            *synthetic_symbol,
            tx_context::sender(ctx),
            discount_applied,
            0u64
        );

        event::emit(SyntheticBurned {
            vault_id: object::id(vault),
            synthetic_type: *synthetic_symbol,
            amount_burned: amount,
            collateral_withdrawn: 0,
            burner: tx_context::sender(ctx),
            new_collateral_ratio: 0, // Placeholder
            timestamp: 0u64,
        });

        vault.last_update_ms = 0u64;
    }

    /*******************************
    * Phase-2 - vault health helpers
    *******************************/
    public fun check_vault_health<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject
    ): (u64, bool) {
        let keys = vector::empty<String>(); // TODO: table::keys not available(&vault.synthetic_debt);
        if (vector::is_empty(&keys)) { 
            vector::destroy_empty(keys);
            return (18446744073709551615u64, false)
        };
        let sym = vector::borrow(&keys, 0);
        let debt = *table::borrow(&vault.synthetic_debt, *sym);
        let price_i64 = get_latest_price(oracle_cfg, clock, price);
        assert!(price_i64 > 0, E_BAD_PRICE);
        let collateral_value = balance::value(&vault.collateral);
        let debt_value = debt * (price_i64 as u64);
        let ratio = if (debt_value == 0) { 18446744073709551615u64 } else { (collateral_value * 10_000) / debt_value };
        let asset = table::borrow(&registry.synthetics, *sym);
        let threshold = if (asset.liquidation_threshold_bps > 0) { asset.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
        let liq = ratio < threshold;
        vector::destroy_empty(keys);
        (ratio, liq)
    }

    public fun check_vault_health_multi<C>(
        vault: &CollateralVault<C>,
        registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        symbols: &vector<String>,
        prices: &vector<PriceInfoObject>
    ): (u64, bool) {
        let collateral_value = balance::value(&vault.collateral);
        let mut total_debt_value: u64 = 0;
        let mut i = 0;
        let mut max_threshold = registry.global_params.liquidation_threshold;
        while (i < vector::length(symbols)) {
            let sym = vector::borrow(symbols, i);
            if (table::contains(&vault.synthetic_debt, *sym)) {
                let debt_units = *table::borrow(&vault.synthetic_debt, *sym);
                if (debt_units > 0) {
                    let p = vector::borrow(prices, i);
                    let px_i64 = get_latest_price(oracle_cfg, clock, p);
                    assert!(px_i64 > 0, E_BAD_PRICE);
                    let px = px_i64 as u64;
                    total_debt_value = total_debt_value + (debt_units * px);
                    let a = table::borrow(&registry.synthetics, *sym);
                    let th = if (a.liquidation_threshold_bps > 0) { a.liquidation_threshold_bps } else { registry.global_params.liquidation_threshold };
                    if (th > max_threshold) { max_threshold = th; };
                }
            };
            i = i + 1;
        };
        let ratio = if (total_debt_value == 0) { 18446744073709551615u64 } else { (collateral_value * 10_000) / total_debt_value };
        let liq = ratio < max_threshold;
        (ratio, liq)
    }

    public fun list_vault_debt_symbols<C>(_vault: &CollateralVault<C>): vector<String> { 
        vector::empty<String>()
    }
    public fun get_vault_debt<C>(vault: &CollateralVault<C>, symbol: String): u64 { if (table::contains(&vault.synthetic_debt, symbol)) { *table::borrow(&vault.synthetic_debt, symbol) } else { 0 } }

    /*******************************
    * Vault-to-vault USDC transfer (settlement helper)
    *******************************/
    public entry fun transfer_between_vaults<C>(
        from_vault: &mut CollateralVault<C>,
        to_vault: &mut CollateralVault<C>,
        amount: u64,
        _ctx: &mut TxContext
    ) {
        let balance_out = balance::split(&mut from_vault.collateral, amount);
        balance::join(&mut to_vault.collateral, balance_out);
        let now = 0u64;
        from_vault.last_update_ms = now;
        to_vault.last_update_ms = now;
    }

    /*******************************
    * Order lifecycle - place, cancel, match
    *******************************/
    public entry fun place_limit_order<C>(
        registry: &SynthRegistry,
        vault: &CollateralVault<C>,
        symbol: String,
        side: u8,
        price: u64,
        size: u64,
        expiry_ms: u64,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(side == 0 || side == 1, E_SIDE_INVALID);
        let asset = table::borrow(&registry.synthetics, symbol);
        assert!(asset.is_active, E_INVALID_ORDER);
        assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);

        let now = 0u64;
        let order = Order {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            vault_id: object::id(vault),
            symbol,
            side,
            price,
            size,
            remaining: size,
            created_at_ms: now,
            expiry_ms,
        };
        event::emit(OrderPlaced {
            order_id: object::id(&order),
            owner: tx_context::sender(ctx),
            symbol,
            side,
            price,
            size,
            remaining: size,
            created_at_ms: now,
            expiry_ms,
        });
        transfer::share_object(order);
    }

    public entry fun cancel_order(order: &mut Order, ctx: &mut TxContext) {
        assert!(order.owner == tx_context::sender(ctx), E_NOT_OWNER);
        order.remaining = 0;
        event::emit(OrderCancelled { order_id: object::id(order), owner: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun match_orders<C>(
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price_info: &PriceInfoObject,
        buy_order: &mut Order,
        sell_order: &mut Order,
        buyer_vault: &mut CollateralVault<C>,
        seller_vault: &mut CollateralVault<C>,
        mut unxv_payment: vector<Coin<UNXV>>,
        unxv_price: &PriceInfoObject,
        taker_is_buyer: bool,
        min_price: u64,
        max_price: u64,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        assert!(buy_order.side == 0 && sell_order.side == 1, E_SIDE_INVALID);
        assert!(buy_order.symbol == sell_order.symbol, E_SYMBOL_MISMATCH);
        let sym = &buy_order.symbol;
        let now = 0u64;
        if (buy_order.expiry_ms != 0) { assert!(now <= buy_order.expiry_ms, E_ORDER_EXPIRED) };
        if (sell_order.expiry_ms != 0) { assert!(now <= sell_order.expiry_ms, E_ORDER_EXPIRED) };
        assert!(buyer_vault.owner == buy_order.owner, E_NOT_OWNER);
        assert!(seller_vault.owner == sell_order.owner, E_NOT_OWNER);
        assert!(buy_order.price >= sell_order.price, E_INVALID_ORDER);
        let trade_price = sell_order.price;
        assert!(trade_price >= min_price && trade_price <= max_price, E_INVALID_ORDER);
        let fill = if (buy_order.remaining < sell_order.remaining) { buy_order.remaining } else { sell_order.remaining };
        assert!(fill > 0, E_INVALID_ORDER);

        let notional = fill * trade_price;
        let balance_to_pay = balance::split(&mut buyer_vault.collateral, notional);

        mint_synthetic_internal(buyer_vault, registry, oracle_cfg, clock, price_info, sym, fill, ctx);
        burn_synthetic_internal(seller_vault, registry, oracle_cfg, clock, price_info, sym, fill, ctx);
        balance::join(&mut seller_vault.collateral, balance_to_pay);

        buy_order.remaining = buy_order.remaining - fill;
        sell_order.remaining = sell_order.remaining - fill;

        let trade_fee = (notional * registry.global_params.mint_fee) / 10_000;
        let discount_usdc = (trade_fee * registry.global_params.unxv_discount_bps) / 10_000;
        let mut discount_applied = false;
        if (discount_usdc > 0 && taker_is_buyer && !vector::is_empty(&unxv_payment)) {
            let price_unxv_u64 = get_latest_price(oracle_cfg, clock, unxv_price);
            if (price_unxv_u64 > 0) {
                let unxv_needed = (discount_usdc + price_unxv_u64 - 1) / price_unxv_u64;
                let mut merged = coin::zero<UNXV>(ctx);
                while (!vector::is_empty(&unxv_payment)) {
                    coin::join(&mut merged, vector::pop_back(&mut unxv_payment));
                };
                let have = merged.value();
                if (have >= unxv_needed) {
                    let exact = merged.split(unxv_needed, ctx);
                    let mut vec_unxv = vector::empty<Coin<UNXV>>();
                    vector::push_back(&mut vec_unxv, exact);
                    TreasuryMod::deposit_unxv(treasury, vec_unxv, b"trade".to_string(), buyer_vault.owner, ctx);
                    transfer::public_transfer(merged, buyer_vault.owner);
                    discount_applied = true;
                } else {
                    transfer::public_transfer(merged, buyer_vault.owner);
                }
            }
        };

        while (!vector::is_empty(&unxv_payment)) {
            let c = vector::pop_back(&mut unxv_payment);
            if (c.value() > 0) { transfer::public_transfer(c, tx_context::sender(ctx)) } else { coin::destroy_zero(c) };
        };
        vector::destroy_empty(unxv_payment);
        
        let usdc_fee_after_discount = if (discount_applied) { trade_fee - discount_usdc } else { trade_fee };
        let maker_rebate = (trade_fee * registry.global_params.maker_rebate_bps) / 10_000;
        if (usdc_fee_after_discount > 0) {
            let mut fee_balance_all = if (taker_is_buyer) { balance::split(&mut buyer_vault.collateral, usdc_fee_after_discount) } else { balance::split(&mut seller_vault.collateral, usdc_fee_after_discount) };
            if (maker_rebate > 0 && maker_rebate < usdc_fee_after_discount) {
                let to_maker_balance = balance::split(&mut fee_balance_all, maker_rebate);
                let maker_addr = if (taker_is_buyer) { seller_vault.owner } else { buyer_vault.owner };
                transfer::public_transfer(coin::from_balance(to_maker_balance, ctx), maker_addr);
                event::emit(MakerRebatePaid { amount: maker_rebate, taker: if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner }, maker: maker_addr, market: b"trade".to_string(), timestamp: 0u64 });
            };
            TreasuryMod::deposit_usdc(treasury, coin::from_balance(fee_balance_all, ctx), b"trade".to_string(), if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner }, ctx);
        };

        unxversal::common::emit_fee_collected_event(
            b"trade".to_string(),
            trade_fee,
            b"USDC".to_string(),
            if (taker_is_buyer) { buyer_vault.owner } else { seller_vault.owner },
            discount_applied,
            0u64
        );

        let t = 0u64;
        buyer_vault.last_update_ms = t;
        seller_vault.last_update_ms = t;
        event::emit(OrderMatched {
            buy_order_id: object::id(buy_order),
            sell_order_id: object::id(sell_order),
            symbol: *sym,
            price: trade_price,
            size: fill,
            buyer: buyer_vault.owner,
            seller: seller_vault.owner,
            timestamp: t,
        });
    }

    public fun check_system_stability<C>(
        vaults: &vector<CollateralVault<C>>,
        _registry: &SynthRegistry,
        _oracle_cfg: &OracleConfig,
        _clocks: &vector<Clock>,
        _prices: &vector<PriceInfoObject>
    ): (u64, u64, u64) {
        let mut total_coll: u64 = 0;
        let mut total_debt: u64 = 0;
        let mut i = 0;
        while (i < vector::length(vaults)) {
            let v = vector::borrow(vaults, i);
            total_coll = total_coll + balance::value(&v.collateral);
            i = i + 1;
        };
        let gcr = if (total_debt == 0) { 18446744073709551615u64 } else { (total_coll * 10_000) / total_debt };
        (total_coll, total_debt, gcr)
    }

    /*******************************
    * Read-only helpers (bots/indexers)
    *******************************/
    public fun list_synthetics(_registry: &SynthRegistry): vector<String> {
        vector::empty<String>()
    }

    public fun get_synthetic(registry: &SynthRegistry, symbol: String): &SyntheticAsset { table::borrow(&registry.synthetics, symbol) }

    public fun get_oracle_feed_bytes(registry: &SynthRegistry, symbol: String): vector<u8> {
        if (table::contains(&registry.oracle_feeds, symbol)) { 
            *table::borrow(&registry.oracle_feeds, symbol) 
        } else { 
            vector::empty<u8>()
        }
    }

    public fun get_vault_values<C>(
        vault: &CollateralVault<C>,
        _registry: &SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject
    ): (u64, u64, u64) {
        let collateral_value = balance::value(&vault.collateral);
        let debt_units = 0u64; 
        if (debt_units == 0) { return (collateral_value, 0, 18446744073709551615u64) };
        let px = get_latest_price(oracle_cfg, clock, price) as u64;
        let debt_value = debt_units * px;
        let ratio = if (debt_value == 0) { 18446744073709551615u64 } else { (collateral_value * 10_000) / debt_value };
        (collateral_value, debt_value, ratio)
    }

    public fun get_treasury_id(registry: &SynthRegistry): ID { registry.treasury_id }

    /*******************************
    * Liquidation - seize collateral when ratio < threshold
    *******************************/
    public entry fun liquidate_vault<C>(
        registry: &mut SynthRegistry,
        oracle_cfg: &OracleConfig,
        clock: &Clock,
        price: &PriceInfoObject,
        vault: &mut CollateralVault<C>,
        synthetic_symbol: String,
        repay_amount: u64,
        liquidator: address,
        treasury: &mut Treasury<C>,
        ctx: &mut TxContext
    ) {
        assert!(!registry.paused, 1000);
        let (ratio, _) = check_vault_health(vault, registry, oracle_cfg, clock, price);
        assert!(ratio < registry.global_params.liquidation_threshold, E_VAULT_NOT_HEALTHY);

        let outstanding = if (table::contains(&vault.synthetic_debt, synthetic_symbol)) { *table::borrow(&vault.synthetic_debt, synthetic_symbol) } else { 0 };
        let repay = if (repay_amount > outstanding) { outstanding } else { repay_amount };
        assert!(repay > 0, E_INVALID_ORDER);

        let price_u64 = get_price_scaled_1e6(oracle_cfg, clock, price);
        let notional = repay * price_u64;
        let asset_for_liq = table::borrow(&registry.synthetics, synthetic_symbol);
        let liq_pen_bps = if (asset_for_liq.liquidation_penalty_bps > 0) { asset_for_liq.liquidation_penalty_bps } else { registry.global_params.liquidation_penalty };
        let penalty = (notional * liq_pen_bps) / 10_000;
        let seize = notional + penalty;

        let new_debt = outstanding - repay;
        if (table::contains(&vault.synthetic_debt, synthetic_symbol)) {
            table::remove(&mut vault.synthetic_debt, synthetic_symbol);
        };
        table::add(&mut vault.synthetic_debt, synthetic_symbol, new_debt);

        let mut seized_balance = balance::split(&mut vault.collateral, seize);
        let bot_cut = (seize * registry.global_params.bot_split) / 10_000;
        let to_bot_balance = balance::split(&mut seized_balance, bot_cut);
        transfer::public_transfer(coin::from_balance(to_bot_balance, ctx), liquidator);
        TreasuryMod::deposit_usdc(treasury, coin::from_balance(seized_balance, ctx), b"liquidation".to_string(), liquidator, ctx);

        event::emit(LiquidationExecuted {
            vault_id: object::id(vault),
            liquidator,
            liquidated_amount: repay,
            collateral_seized: seize,
            liquidation_penalty: penalty,
            synthetic_type: synthetic_symbol,
            timestamp: 0u64,
        });
        vault.last_update_ms = 0u64;
    }

    /*******************************
    * Internal helper - assert caller is in allow-list
    *******************************/
    fun assert_is_admin(registry: &SynthRegistry, addr: address) {
        assert!(vec_set::contains(&registry.admin_addrs, &addr), E_NOT_ADMIN);
    }

    public fun check_is_admin(registry: &SynthRegistry, addr: address): bool {
        vec_set::contains(&registry.admin_addrs, &addr)
    }

    public entry fun set_collateral<C>(
        _admin: &AdminCap,
        registry: &mut SynthRegistry,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        assert!(!registry.collateral_set, 999);
        
        transfer::share_object(CollateralConfig<C> { id: object::new(ctx) });
        registry.collateral_set = true;
    }

    /*******************************
    * INIT  - executed once on package publish
    *******************************/
    fun init(otw: SYNTHETICS, ctx: &mut TxContext) {
        assert!(types::is_one_time_witness(&otw), 0);
        let publisher = package::claim(otw, ctx);

        let params = GlobalParams {
            min_collateral_ratio: 1_500,
            liquidation_threshold: 1_200,
            liquidation_penalty: 500,
            max_synthetics: 100,
            stability_fee: 200,
            bot_split: 4_000,
            mint_fee: 50,
            burn_fee: 30,
            unxv_discount_bps: 2_000,
            maker_rebate_bps: 0,
        };

        let syn_table = table::new<String, SyntheticAsset>(ctx);
        let feed_table = table::new<String, vector<u8>>(ctx);
        let mut admins = vec_set::empty();
        vec_set::insert(&mut admins, tx_context::sender(ctx));

        let treasury_id_local = object::id_from_address(@0x0);

        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: syn_table,
            oracle_feeds: feed_table,
            global_params: params,
            paused: false,
            admin_addrs: admins,
            treasury_id: treasury_id_local,
            num_synthetics: 0,
            collateral_set: false,
        };
        transfer::share_object(registry);

        transfer::public_transfer(DaddyCap { id: object::new(ctx) }, tx_context::sender(ctx));
        transfer::public_transfer(AdminCap  { id: object::new(ctx) }, tx_context::sender(ctx));

        let mut disp = display::new<SynthRegistry>(&publisher, ctx);
        disp.add(b"name".to_string(),           b"Unxversal Synthetics Registry".to_string());
        disp.add(b"description".to_string(),    b"Central registry storing all synthetic assets listed by Unxversal".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string());
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Synthetics".to_string());
        disp.update_version();
        transfer::public_transfer(disp, tx_context::sender(ctx));

        let mut order_disp = display::new<Order>(&publisher, ctx);
        order_disp.add(b"name".to_string(),          b"Order: {symbol} {side} {size} @ {price}".to_string());
        order_disp.add(b"description".to_string(),   b"Unxversal on-chain order object".to_string());
        order_disp.add(b"symbol".to_string(),        b"{symbol}".to_string());
        order_disp.add(b"side".to_string(),          b"{side}".to_string());
        order_disp.add(b"price".to_string(),         b"{price}".to_string());
        order_disp.add(b"size".to_string(),          b"{size}".to_string());
        order_disp.add(b"remaining".to_string(),     b"{remaining}".to_string());
        order_disp.add(b"created_at_ms".to_string(), b"{created_at_ms}".to_string());
        order_disp.add(b"expiry_ms".to_string(),     b"{expiry_ms}".to_string());
        order_disp.update_version();
        transfer::public_transfer(order_disp, tx_context::sender(ctx));

        let sample_asset = SyntheticAsset {
            id: object::new(ctx),
            name: b"{name}".to_string(),
            symbol: b"{symbol}".to_string(),
            decimals: 9,
            pyth_feed_id: b"".to_string().into_bytes(),
            min_collateral_ratio: 0,
            total_supply: 0,
            is_active: true,
            liquidation_threshold_bps: 8500,
            liquidation_penalty_bps: 500,
            mint_fee_bps: 10,
            burn_fee_bps: 5,
            stability_fee_bps: 100,
            created_at: 0,
        };
        init_synth_display(&publisher, &sample_asset, ctx);
        let SyntheticAsset { id, name: _, symbol: _, decimals: _, pyth_feed_id: _, min_collateral_ratio: _, total_supply: _, is_active: _, created_at: _, stability_fee_bps: _, liquidation_threshold_bps: _, liquidation_penalty_bps: _, mint_fee_bps: _, burn_fee_bps: _ } = sample_asset;
        object::delete(id);

        let mut oracle_disp = display::new<OracleConfig>(&publisher, ctx);
        oracle_disp.add(b"name".to_string(),        b"Unxversal Oracle Config".to_string());
        oracle_disp.add(b"description".to_string(), b"Holds the allow-list of Pyth feeds trusted by Unxversal".to_string());
        oracle_disp.add(b"project_url".to_string(), b"https://unxversal.com".to_string());
        oracle_disp.update_version();
        transfer::public_transfer(oracle_disp, tx_context::sender(ctx));
        
        transfer::public_transfer(publisher, tx_context::sender(ctx));
    }

    /*******************************
    * Daddy-level admin management
    *******************************/
    public entry fun grant_admin(
        _daddy: &DaddyCap,
        registry: &mut SynthRegistry,
        new_admin: address,
        ctx: &mut TxContext
    ) {
        vec_set::insert(&mut registry.admin_addrs, new_admin);
        transfer::public_transfer(AdminCap { id: object::new(ctx) }, new_admin);
        event::emit(AdminGranted { admin_addr: new_admin, timestamp: 0u64 });
    }

    public entry fun revoke_admin(
        _daddy: &DaddyCap,
        registry: &mut SynthRegistry,
        bad_admin: address
    ) {
        vec_set::remove(&mut registry.admin_addrs, &bad_admin);
        event::emit(AdminRevoked { admin_addr: bad_admin, timestamp: 0u64 });
    }

    /*******************************
    * Parameter updates & emergency pause - gated by allow-list
    *******************************/
    public fun update_global_params(
        registry: &mut SynthRegistry,
        new_params: GlobalParams,
        ctx: &mut TxContext
    ) {
        assert_is_admin(registry, tx_context::sender(ctx));
        registry.global_params = new_params;
        event::emit(ParamsUpdated { updater: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun emergency_pause(registry: &mut SynthRegistry, ctx: &mut TxContext) {
        assert_is_admin(registry, tx_context::sender(ctx));
        registry.paused = true;
        event::emit(EmergencyPauseToggled { new_state: true, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    public entry fun resume(registry: &mut SynthRegistry, ctx: &mut TxContext) {
        assert_is_admin(registry, tx_context::sender(ctx));
        registry.paused = false;
        event::emit(EmergencyPauseToggled { new_state: false, by: tx_context::sender(ctx), timestamp: 0u64 });
    }

    /*******************************
    * Public getters for cross-module access
    *******************************/
    public fun get_order_remaining(order: &Order): u64 { order.remaining }
}