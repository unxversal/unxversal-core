/// Module: unxversal_synthetics
module unxversal::synthetics {

    use usdc::usdc::USDC;

    /// AdminCap grants privileged access for admin operations.
    struct AdminCap has key, store {
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

}