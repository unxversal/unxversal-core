/// Module: unxversal_synthetics
module unxversal::synthetics {
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::object;
    use sui::package;
    use sui::display;
    use std::string::String;
    use std::vec_set::VecSet;
    use std::option::{Self, Option};
    use std::event;
    use usdc::usdc::USDC;
    use sui::clock::Clock;
    use sui::types;
    use std::table::{Self as Table, Table};

    /*******************************/
    /*  -------- STRUCTS -------- */
    /*******************************/

    /// Privileged capability that can **itself** mint/revoke ordinary
    /// `AdminCap`s. Only one exists and is given to the deployer in `init`.
    public struct DaddyCap has key {
        id: UID,    // Unique identifier for the DaddyCap object
    }

    /// AdminCap grants privileged access for admin operations.
    public struct AdminCap has key, store {
        id: UID,    // Unique identifier for the admin capability object
    }

    /// Global parameters for the synthetic asset protocol.
    struct GlobalParams has store {
        min_collateral_ratio: u64,     // Minimum collateral-to-debt ratio (150% = 1500 basis points) - safety buffer
        liquidation_threshold: u64,    // Ratio below which liquidation is triggered (120% = 1200 basis points)
        liquidation_penalty: u64,      // Penalty fee taken from liquidated collateral (5% = 500 basis points)
        max_synthetics: u64,           // Maximum number of synthetic asset types to prevent unbounded growth
        stability_fee: u64,            // Annual interest rate charged on outstanding debt for protocol sustainability
        bot_split: u64,              // Percentage of liquidation proceeds split with bots (10 = 10% = 1000 basis points)
        mint_fee: u64,              // Fee charged for minting new synthetic assets (1 = 1% = 100 basis points)
        burn_fee: u64,              // Fee charged for burning synthetic assets (1 = 1% = 100 basis points)
    }

    /// Represents a synthetic asset with its metadata.
    struct SynthRegistry has key {
        id: UID,                                      // Unique identifier for the registry object
        synthetics: Table<String, SyntheticAsset>,    // Maps asset symbols to their metadata (e.g., "sBTC" -> SyntheticAsset)
        oracle_feeds: Table<String, vector<u8>>,      // Maps asset symbols to Pyth price feed IDs for price lookups
        global_params: GlobalParams,                  // System-wide risk parameters that apply to all synthetic assets
        admin_cap: Option<AdminCap>,                  // Optional admin capability for initial setup, can be destroyed after deployment
    }

    /// Represents a synthetic asset with its metadata.
    struct SyntheticAsset has store {
        name: String,                     // Full name of the synthetic asset (e.g., "Synthetic Bitcoin")
        symbol: String,                   // Trading symbol (e.g., "sBTC") used for identification and trading
        decimals: u8,                     // Number of decimal places for token precision (typically 8 for BTC, 18 for ETH)
        pyth_feed_id: vector<u8>,         // Pyth Network price feed identifier for real-time price data
        min_collateral_ratio: u64,        // Asset-specific minimum collateral ratio (may differ from global for riskier assets)
        total_supply: u64,                // Total amount of this synthetic asset minted across all users
        deepbook_pool_id: Option<ID>,     // DeepBook pool ID for trading this synthetic against USDC
        is_active: bool,                  // Whether minting/burning is currently enabled (emergency pause capability)
        created_at: u64,                  // Timestamp of asset creation for analytics and ordering
    }

    struct CollateralVault has key {
        id: UID,                                  // Unique identifier for this user's vault
        owner: address,                           // Address of the vault owner (only they can modify it)
        collateral_balance: Balance<USDC>,        // Amount of USDC collateral deposited in this vault
        synthetic_debt: Table<String, u64>,       // Maps synthetic symbols to amounts owed (e.g., "sBTC" -> 50000000)
        last_update: u64,                         // Timestamp of last vault modification for fee calculations
        liquidation_price: Table<String, u64>,    // Cached liquidation prices per synthetic to optimize gas usage
    }

    struct SyntheticCoin<phantom T> has key, store {
        id: UID,                 // Unique identifier for this coin object
        balance: Balance<T>,     // The actual token balance of the synthetic asset
        synthetic_type: String,  // String identifier linking back to SyntheticAsset in registry
    }

    /*******************************/
    /*  -------- EVENTS --------- */
    /*******************************/

    public struct AdminGranted has copy, drop {
        admin_addr: address,
        timestamp: u64,
    }

    public struct AdminRevoked has copy, drop {
        admin_addr: address,
        timestamp: u64,
    }

    public struct ParamsUpdated has copy, drop {
        updater: address,
        timestamp: u64,
    }

    public struct EmergencyPauseToggled has copy, drop {
        new_state: bool,
        by: address,
        timestamp: u64,
    }

    /*******************************/
    /*  -------- INIT ----------- */
    /*******************************/

    /// ────────────────────────────────────────────────────────────────────────────────
    /// Init – runs exactly once at publish time
    /// ────────────────────────────────────────────────────────────────────────────────
    fun init(otw: SYNTHETICS, ctx: &mut TxContext) {
        // Safety: enforce OTW
        assert!(types::is_one_time_witness(&otw), 0);

        // 1. Claim a Publisher for display objects
        let publisher = package::claim(otw, ctx);

        // 2. Instantiate default global parameters (placeholder numbers)
        let params = GlobalParams {
            min_collateral_ratio: 1_500,      // 150%
            liquidation_threshold: 1_200,     // 120%
            liquidation_penalty: 500,         // 5%
            max_synthetics: 700,
            stability_fee: 200,               // 2% APR (in basis pts)
            bot_split: 4_000,                 // 40% of penalty
            mint_fee: 50,                     // 0.5%
            burn_fee: 30,                     // 0.3%
        };

        // 3. Create empty tables for synthetics & oracle feeds
        let syn_table: Table<String, SyntheticAsset> = Table::empty();
        let feed_table: Table<String, vector<u8>> = Table::empty();

        // 4. Create the shared SynthRegistry object (paused = false initially)
        let registry = SynthRegistry {
            id: object::new(ctx),
            synthetics: syn_table,
            oracle_feeds: feed_table,
            global_params: params,
            paused: false,
        };
        transfer::share_object(registry);

        // 5. Mint the DaddyCap and a first AdminCap to the deployer (ctx.sender())
        let daddy = DaddyCap { id: object::new(ctx) };
        let admin = AdminCap { id: object::new(ctx) };
        transfer::transfer(daddy, ctx.sender());
        transfer::transfer(admin, ctx.sender());

        // 6. Create a Display<SynthRegistry> for UI/Wallets
        let mut disp = display::new<SynthRegistry>(&publisher, ctx);
        disp.add(b"name".to_string(),           b"Unxversal Synthetics Registry".to_string());
        disp.add(b"description".to_string(),    b"This object stores all valid synthetic assets supported by Unxversal".to_string());
        disp.add(b"image_url".to_string(),      b"{image_url}".to_string()); // placeholder
        disp.add(b"thumbnail_url".to_string(),  b"{thumbnail_url}".to_string());
        disp.add(b"project_url".to_string(),    b"https://unxversal.com".to_string());
        disp.add(b"creator".to_string(),        b"Unxversal Synthetics".to_string());
        disp.update_version();

        // 7. Hand publisher & display back to deployer for future updates
        transfer::transfer(publisher, ctx.sender());
        transfer::transfer(disp, ctx.sender());
    }

    /// ────────────────────────────────────────────────────────────────────────────────
    /// Admin‑cap management (only DaddyCap holder can call these)
    /// ────────────────────────────────────────────────────────────────────────────────
    public entry fun grant_admin(daddy: &DaddyCap, new_admin: address, ctx: &mut TxContext) {
        // Presence of &DaddyCap proves authority → mint new AdminCap to address
        transfer::transfer(AdminCap { id: object::new(ctx) }, new_admin);
    }

    public entry fun revoke_admin(daddy: &DaddyCap, admin_cap: AdminCap) {
        // Destroy the supplied admin_cap – revokes privileges
        let AdminCap { id } = admin_cap;
        object::delete(id);
    }

    /// ────────────────────────────────────────────────────────────────────────────────
    /// GlobalParams mutation – any AdminCap holder can call
    /// ────────────────────────────────────────────────────────────────────────────────
    public entry fun update_global_params(
        _admin: &AdminCap,
        registry: &mut SynthRegistry,
        new_params: GlobalParams
    ) {
        registry.global_params = new_params;
    }

    /// Emergency pause / resume – any AdminCap holder
    public entry fun emergency_pause(_admin: &AdminCap, registry: &mut SynthRegistry) {
        registry.paused = true;
    }

    public entry fun resume(_admin: &AdminCap, registry: &mut SynthRegistry) {
        registry.paused = false;
    }

}