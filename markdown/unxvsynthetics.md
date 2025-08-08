# UnXversal Synthetics Protocol Design (Token-less, No DeepBook)

> Note: This revision reflects the finalized direction: no DeepBook integration and no transferable synthetic tokens. Exposure is tracked as vault debt; all trading settles in USDC by mutating vaults atomically in a single transaction.

## System Architecture & User Flow Overview

### How All Components Work Together

The protocol is a vault-based CDP system where users post USDC as collateral and take exposure to synthetic assets by increasing or decreasing their vault’s synthetic debt balances. There are no on-chain CLOB pools and no minted Coin<T> synthetic tokens. Trades are settled by atomically mutating two vaults’ debt and moving USDC between them.

#### **Core Object Hierarchy & Relationships**

**ON-CHAIN OBJECTS:**
```
SynthRegistry (shared, admin-controlled)  ← Central configuration & synthetic asset definitions
    ↓ manages
SyntheticAsset configs (admin-listed only) ← Symbol, feed mapping, asset-specific risk params
    ↓ referenced by
CollateralVault (owned)                    ← User USDC collateral + per-symbol synthetic debt table
    ↓ relies on
OracleConfig (shared)                      ← Allow-listed Pyth feeds + freshness policy
```

**OFF-CHAIN SERVICES (CLI/Server):**
```
RiskMonitor / Indexer      ← monitors vault health & prices; feeds UIs and bots
Off-chain Matcher           ← maintains an order book; builds atomic txs to settle trades
LiquidationBot              ← triggers on-chain liquidations when vaults breach thresholds
Alerting / Analytics        ← user notifications and system telemetry
```

#### **Complete User Journey Flows**

**1. MINTING FLOW (Creating Synthetic Exposure)**
```
[ON-CHAIN] User deposits USDC → vault collateral increases
[ON-CHAIN] Oracle price validated → collateral ratio checked
[ON-CHAIN] mint_synthetic mutates vault.synthetic_debt (+amount)
[ON-CHAIN] Protocol fees assessed (USDC and/or UNXV discount)
```

**2. TRADING FLOW (Token-less, Off-chain Matching)**
```
[OFF-CHAIN] Orders matched off-chain when price crosses
[ON-CHAIN] Single tx settles:
  • Buyer: mint_synthetic (debt +X)
  • Seller: burn_synthetic (debt –X)
  • Move USDC buyer → seller (less fees)
  • Emit FeeCollected and trade events
```

**3. LIQUIDATION FLOW (Risk Management)**
```
[OFF-CHAIN] RiskMonitor detects under-collateralized vault
[OFF-CHAIN] LiquidationBot computes profitable tranche
[ON-CHAIN] Bot calls liquidate_vault:
  • Repay portion of debt
  • Seize USDC collateral + penalty
  • Distribute bot rewards per policy
```

#### **Key System Interactions**

**ON-CHAIN COMPONENTS:**
- **SynthRegistry**: Central configuration for listed assets, oracle mappings, and global risk/fee params
- **CollateralVault**: Owned object storing USDC collateral and per-asset synthetic debt balances
- **Oracle Integration**: Pyth price validation with allow-listed feed IDs and staleness policy
- **UNXV Fee Engine**: Optional fee discount when paying protocol fees in UNXV

**OFF-CHAIN SERVICES:**
- **RiskMonitor**: Monitors collateral ratios and surfaces liquidation candidates
- **Off-chain Matcher**: Maintains orderbook and submits settlement txs
- **LiquidationBot**: Executes on-chain liquidation calls
- **Analytics**: Price, fee, and health dashboards

#### **Critical Design Patterns**

1. **Atomic Operations**: Mint, burn, trade settlement, and liquidation are single-tx atomic sequences
2. **Token-less Exposure**: No Coin<T> synthetics; exposure lives only as vault debt
3. **Oracle Integration**: Pyth price validation gated by allow-listed feed IDs and freshness checks
4. **Risk Isolation**: Positions are siloed per vault; no contagion
5. **Fee Integration**: Base fees with optional UNXV discount and burn policy

#### **Data Flow & State Management**

- **Price Data**: Pyth → PriceOracle → RiskManager → liquidation decisions
- **User Positions**: SyntheticsVault → UserPosition updates → risk calculations
- **Trading Data**: DeepBook trades → fee collection → UNXV conversions → burns
- **Risk Monitoring**: Continuous monitoring of collateral ratios with real-time liquidation triggers
- **Global State**: SynthRegistry maintains system-wide parameters and configurations that all other components reference

#### **Integration Points with UnXversal Ecosystem**

- **AutoSwap (optional)**: Route fees to UNXV and burn a portion
- **Lending/Derivatives**: Vault-based exposures can be referenced by adapters as needed
- **Liquid Staking**: Future collateral types are possible via upgrades (current version is USDC-only)

## Overview

UnXversal Synthetics enables **admin-permissioned listing** of synthetic assets (only admins can add synths), and **permissionless settlement** of trades for listed assets via off-chain matching and on-chain atomic vault mutations.

> Policy: Only assets listed by the admin in `SynthRegistry` can be minted or burned. Trading is off-chain matched and on-chain settled by calling vault functions; there is no on-chain orderbook.

### Benefits of USDC-Only Collateral

1. **Simplified Risk Management**: No need to manage multiple collateral types with different volatility profiles
2. **Stable Collateral**: USDC's price stability reduces liquidation risk and provides predictable collateral ratios
3. **Reduced Complexity**: Single collateral type simplifies vault management, liquidation logic, and user experience
4. **Better Capital Efficiency**: Users don't need to manage multiple collateral balances
5. **Unified Liquidity**: All synthetic assets trade against USDC, creating deeper liquidity pools
6. **Easier Oracle Integration**: Only need USDC price feeds for collateral valuation (typically $1.00)

## Decentralized Order Matching (On-chain Orders, Permissionless Matchers)

We avoid a centralized server by representing orders as on-chain shared objects and letting anyone act as a matcher. Discovery is off-chain and decentralized (any node can listen to events and index orders), but placement, cancellation, and settlement are on-chain and permissionless.

### Order Model

Orders are shared objects created by users. They reference the owner’s `CollateralVault` and encode immutable intent parameters.

```move
struct Order has key, store {
  id: UID,
  owner: address,            // order owner; only owner can cancel/amend
  vault_id: ID,              // owner’s CollateralVault to settle against
  symbol: String,            // e.g., "sBTC"
  side: u8,                  // 0 = buy (increase debt), 1 = sell (decrease debt)
  price: u64,                // limit price in quote units (USDC per 1 unit), scaled (e.g., 1e6)
  size: u64,                 // original size in synthetic units
  remaining: u64,            // unfilled size (decreases as it fills)
  created_at_ms: u64,        // for time-priority off-chain
  expiry_ms: u64,            // optional TTL; 0 = GTC
}
```

Key properties:
- Orders are visible on-chain and discoverable via events. Any node can index them.
- Anyone can call `match_orders` to fill crossing orders. Settlement is atomic and permissionless.
- Time/price priority is coordinated socially by indexers and UIs; the chain enforces correctness and solvency (ratios, balances), not priority fairness.

### Order Lifecycle

- place_limit_order: Owner posts a shared `Order`. Emits `OrderPlaced`.
- cancel_order: Owner cancels; can only be called by `order.owner`. Emits `OrderCancelled`.
- match_orders: Anyone matches crossing orders and settles atomically:
  - Validate crossing (buy.price ≥ sell.price) and non-expired.
  - Choose trade price (maker’s price or midpoint; policy is module-configurable).
  - Compute fill size = min(buy.remaining, sell.remaining).
  - Settle:
    - Buyer: `mint_synthetic` on buyer vault (+debt)
    - Seller: `burn_synthetic` on seller vault (−debt)
    - Move USDC from buyer vault → seller vault for notional value
    - Process protocol fees (USDC or UNXV discount) and emit `FeeCollected`
  - Decrease `remaining` on both; emit `OrderMatched` (with price, size, taker)

All checks run on-chain:
- Collateral ratio for buyer after mint must be ≥ min required
- Seller must have sufficient debt to burn
- Registry not paused; asset listed and active
- Oracle staleness and allowed-feed checks

### Events

```move
struct OrderPlaced has copy, drop {
  order_id: ID, owner: address, symbol: String, side: u8,
  price: u64, size: u64, remaining: u64, created_at_ms: u64, expiry_ms: u64,
}

struct OrderCancelled has copy, drop { order_id: ID, owner: address, timestamp: u64 }

struct OrderMatched has copy, drop {
  buy_order_id: ID, sell_order_id: ID,
  symbol: String, price: u64, size: u64,
  buyer: address, seller: address,
  timestamp: u64,
}
```

### MEV and Fairness
- Anyone can be a matcher; this decentralizes operation but allows competition for matches.
- Mitigations (optional, can be added later): frequent batch auctions, commit-reveal for match sets, max slippage constraints on orders, or match proofs.
- Priority (price-time) is coordinated by indexers/UIs and not enforced in the Move module beyond correctness.

## Core Architecture

### On-Chain Objects

#### 1. SynthRegistry (Shared Object, Admin-Controlled)
```move
struct SynthRegistry has key {
    id: UID,                                      // Unique identifier for the registry object
    synthetics: Table<String, SyntheticAsset>,    // Maps asset symbols to their metadata (e.g., "sBTC" -> SyntheticAsset)
    oracle_feeds: Table<String, vector<u8>>,      // Maps asset symbols to Pyth price feed IDs for price lookups
    global_params: GlobalParams,                  // System-wide risk parameters that apply to all synthetic assets
    paused: bool,                                 // Circuit breaker; blocks state-changing ops when true
    admin_addrs: VecSet<address>,                 // Allow-list of admin addresses (managed by DaddyCap)
}

struct GlobalParams has store {
    min_collateral_ratio: u64,     // Minimum collateral-to-debt ratio (150% = 1500 basis points) - safety buffer
    liquidation_threshold: u64,    // Ratio below which liquidation is triggered (120% = 1200 basis points)
    liquidation_penalty: u64,      // Penalty fee taken from liquidated collateral (5% = 500 basis points)
    max_synthetics: u64,           // Maximum number of synthetic asset types to prevent unbounded growth
    stability_fee: u64,            // Annual interest rate charged on outstanding debt for protocol sustainability
}

/// AdminCap grants privileged access for initial setup and emergency functions
/// Will be destroyed after deployment to make protocol immutable
struct AdminCap has key, store {
    id: UID,    // Unique identifier for the admin capability object
}
```

#### 2. SyntheticAsset (Admin-Listed Only)
```move
struct SyntheticAsset has store {
    name: String,                     // Full name of the synthetic asset (e.g., "Synthetic Bitcoin")
    symbol: String,                   // Trading symbol (e.g., "sBTC") used for identification and trading
    decimals: u8,                     // Number of decimal places for token precision (typically 8 for BTC, 18 for ETH)
    pyth_feed_id: vector<u8>,         // Pyth Network price feed identifier for real-time price data
    min_collateral_ratio: u64,        // Asset-specific minimum collateral ratio (may differ from global for riskier assets)
    total_supply: u64,                // Total amount of this synthetic asset minted across all users
    is_active: bool,                  // Whether minting/burning is currently enabled (emergency pause capability)
    created_at: u64,                  // Timestamp of asset creation for analytics and ordering
}
```

#### 3. CollateralVault (Owned Object)
```move
struct CollateralVault has key {
    id: UID,                                  // Unique identifier for this user's vault
    owner: address,                           // Address of the vault owner (only they can modify it)
    collateral: Coin<USDC>,                   // USDC collateral held in this vault
    synthetic_debt: Table<String, u64>,       // Maps synthetic symbols to amounts owed (e.g., "sBTC" -> 50000000)
    last_update_ms: u64,                      // Timestamp of last modification
}
```

There is no transferable `SyntheticCoin<T>` in the token-less model. If needed later, a wrapper object can be introduced without changing core accounting.

### Off-Chain Services (CLI/Server Components)

#### 1. RiskMonitor Service
- **Continuous Health Monitoring**: Tracks collateral ratios across all vaults in real-time
- **Liquidation Detection**: Identifies vaults that fall below liquidation threshold
- **User Alerting**: Sends notifications to users approaching liquidation
- **Analytics**: Provides health metrics and risk analytics

#### 2. LiquidationBot Service
- **Automated Liquidations**: Triggers on-chain liquidation functions when profitable
- **Gas Optimization**: Batches liquidations and optimizes for gas efficiency
- **Profit Calculation**: Determines optimal liquidation amounts and timing

#### 3. Market Creation Service
- **DeepBook Pool Creation**: Automatically creates pools for new synthetic assets
- **Liquidity Management**: Manages initial liquidity for new synthetic markets
- **Pool Monitoring**: Tracks pool health and trading activity

### Events

#### 1. Synthetic Asset Events
```move
// When new synthetic asset is created
struct SyntheticAssetCreated has copy, drop {
    asset_name: String,         // Full name of the created asset for display purposes
    asset_symbol: String,       // Trading symbol for identification in UIs and trading
    pyth_feed_id: vector<u8>,   // Price feed ID for price tracking and validation
    creator: address,           // Address that created this asset (initially admin, later community)
    timestamp: u64,             // Creation time for chronological ordering and analytics
}

// When synthetic is minted
struct SyntheticMinted has copy, drop {
    vault_id: ID,                       // Vault that minted the synthetic for position tracking
    synthetic_type: String,             // Type of synthetic minted (e.g., "sBTC")
    amount_minted: u64,                 // Amount of synthetic tokens created
    usdc_collateral_deposited: u64,     // Amount of USDC collateral backing this mint
    minter: address,                    // User who performed the minting operation
    new_collateral_ratio: u64,          // Updated collateral ratio after minting for risk monitoring
    timestamp: u64,                     // Mint time for analytics and fee calculations
}

// When synthetic is burned
struct SyntheticBurned has copy, drop {
    vault_id: ID,                       // Vault that burned the synthetic for position tracking
    synthetic_type: String,             // Type of synthetic burned (e.g., "sBTC")
    amount_burned: u64,                 // Amount of synthetic tokens destroyed
    usdc_collateral_withdrawn: u64,     // Amount of USDC collateral released back to user
    burner: address,                    // User who performed the burning operation
    new_collateral_ratio: u64,          // Updated collateral ratio after burning
    timestamp: u64,                     // Burn time for analytics and tracking
}
```

#### 2. Liquidation Events
```move
struct LiquidationExecuted has copy, drop {
    vault_id: ID,                   // Vault that was liquidated for risk tracking
    liquidator: address,            // Address that performed the liquidation and earned rewards
    liquidated_amount: u64,         // Amount of synthetic debt repaid during liquidation
    usdc_collateral_seized: u64,    // Amount of USDC collateral taken by liquidator
    liquidation_penalty: u64,       // Penalty amount deducted from vault owner's collateral
    synthetic_type: String,         // Type of synthetic that was liquidated
    timestamp: u64,                 // Liquidation time for risk analysis and monitoring
}

struct LiquidationBotRegistered has copy, drop {
    bot_id: ID,                     // Unique identifier for the registered bot
    operator: address,              // Address authorized to operate this bot
    min_profit_threshold: u64,      // Minimum profit threshold for bot operation efficiency
    timestamp: u64,                 // Registration time for tracking bot ecosystem growth
}
```

#### 3. Fee Events
```move
struct FeeCollected has copy, drop {
    fee_type: String,               // Type of fee collected ("mint", "burn", "stability") for revenue breakdown
    amount: u64,                    // Amount of fee collected in the respective asset
    asset_type: String,             // Asset used to pay the fee (USDC, UNXV, or synthetic)
    user: address,                  // User who paid the fee for user analytics
    unxv_discount_applied: bool,    // Whether UNXV discount was used for tokenomics tracking
    timestamp: u64,                 // Fee collection time for revenue analytics
}

struct UnxvBurned has copy, drop {
    amount_burned: u64,     // Amount of UNXV tokens permanently removed from supply
    fee_source: String,     // Source of fees that generated this burn ("minting", "trading", etc.)
    timestamp: u64,         // Burn time for tokenomics analytics and supply tracking
}
```

## Core Functions

### 1. Synthetic Asset Creation
```move
public fun create_synthetic_asset(
    registry: &mut SynthRegistry,       // Central registry to store the new asset metadata
    asset_name: String,                 // Human-readable name (e.g., "Synthetic Bitcoin")
    asset_symbol: String,               // Trading symbol (e.g., "sBTC") for identification
    pyth_feed_id: vector<u8>,           // Pyth price feed ID for real-time price data
    min_collateral_ratio: u64,          // Minimum collateral ratio specific to this asset's risk profile
    ctx: &mut TxContext,                // Transaction context for object creation and events
)
```

### 2. Collateral Management
```move
public fun deposit_collateral(
    vault: &mut CollateralVault,    // User's vault to receive the collateral
    usdc_collateral: Coin<USDC>,    // USDC coins being deposited as collateral
    ctx: &mut TxContext,            // Transaction context for event emission
)

public fun withdraw_collateral(
    vault: &mut CollateralVault,        // User's vault to withdraw collateral from
    amount: u64,                        // Amount of USDC to withdraw (in smallest units)
    registry: &SynthRegistry,           // Registry for accessing global parameters and asset data
    price_info: &PriceInfoObject,       // Pyth price data for collateral ratio calculations
    clock: &Clock,                      // Sui clock for timestamp validation and fee calculations
    ctx: &mut TxContext,                // Transaction context for event emission
): Coin<USDC>  // Returns the withdrawn USDC collateral
```

### 3. Synthetic Minting/Burning
```move
public fun mint_synthetic(
    vault: &mut CollateralVault,        // User's vault providing collateral for minting
    synthetic_symbol: String,           // Type of synthetic to mint (e.g., "sBTC")
    amount: u64,                        // Amount of synthetic tokens to mint
    registry: &mut SynthRegistry,       // Registry for asset parameters and validation
    oracle_cfg: &OracleConfig,          // Oracle configuration (allowed feeds & max age)
    clock: &Clock,                      // Sui clock for staleness checks
    price: &PriceInfoObject,            // Price data for collateral ratio calculation
    ctx: &mut TxContext                 // Transaction context for events
)

public fun burn_synthetic(
    vault: &mut CollateralVault,        // User's vault to reduce debt and potentially release collateral
    registry: &mut SynthRegistry,       // Registry for asset parameters and fee calculations
    oracle_cfg: &OracleConfig,          // Oracle configuration (allowed feeds & max age)
    clock: &Clock,                      // Sui clock for staleness checks (optional in burn)
    price: &PriceInfoObject,            // Price data (optional in burn)
    synthetic_symbol: String,           // Type of synthetic burned (e.g., "sBTC")
    amount: u64,                        // Amount burned
    ctx: &mut TxContext                 // Transaction context for events
)
```

### 4. Liquidation
```move
public fun liquidate_vault(
    vault: &mut CollateralVault,        // Undercollateralized vault being liquidated
    registry: &mut SynthRegistry,       // Registry for liquidation parameters and penalties
    oracle_cfg: &OracleConfig,          // Oracle configuration
    clock: &Clock,                      // Sui clock
    price: &PriceInfoObject,            // Price data
    synthetic_symbol: String,           // Type of synthetic debt being repaid
    liquidation_amount: u64,            // Amount of debt to repay (limited by vault debt and max liquidation)
    ctx: &mut TxContext                 // Transaction context for events
)
```

## Fee Structure with UNXV Integration

### Fee Types
1. **Minting Fee**: 0.5% of minted value
2. **Burning Fee**: 0.3% of burned value  
3. **Stability Fee**: 2% annually on outstanding debt
4. **Liquidation Fee**: 5% penalty on liquidated collateral

### UNXV Discount Mechanism
```move
struct FeeCalculation has drop {
    base_fee: u64,          // Original fee amount before any discounts
    unxv_discount: u64,     // Discount amount when paying with UNXV (20% of base_fee)
    final_fee: u64,         // Actual fee amount after applying discounts
    payment_asset: String,  // Asset type used for payment ("UNXV", "USDC", or "input_asset")
}

public fun calculate_fee_with_discount(
    base_fee: u64,              // Original fee amount calculated from operation
    payment_asset: String,      // Asset the user wants to pay fees with
    unxv_balance: u64,          // User's available UNXV balance for discount eligibility
): FeeCalculation  // Returns fee breakdown with discount calculations
```

### Fee Processing Hooks

Fee processing is integrated at call sites (mint, burn, liquidation). The flow computes base fees from value, applies UNXV discount if chosen and covered, then transfers/burns accordingly. If an AutoSwap is used to convert fees into UNXV, it should be a small adapter called by the synthetics module.

## Risk Management

### 1. Collateral Ratio Monitoring
```move
public fun check_vault_health(
    vault: &CollateralVault,        // Vault to assess for liquidation risk
    synthetic_type: String,         // Specific synthetic asset to check (for multi-asset vaults)
    registry: &SynthRegistry,       // Registry for risk parameters and asset data
    price_info: &PriceInfoObject,   // Current price data for accurate ratio calculation
    clock: &Clock,                  // Sui clock for timestamp validation
): (u64, bool)  // Returns (current collateral ratio in basis points, is liquidatable boolean)
```

### 2. Oracle Price Validation
```move
public fun validate_price_feed(
    price_info: &PriceInfoObject,   // Pyth price data object to validate
    expected_feed_id: vector<u8>,   // Expected Pyth feed ID to prevent feed substitution attacks
    max_age: u64,                   // Maximum allowed age for price data (staleness check)
    clock: &Clock,                  // Sui clock for timestamp comparison
): I64  // Returns validated price with confidence interval
```

### 3. System Stability Checks
```move
public fun check_system_stability(
    vaults: vector<&CollateralVault>,       // Sample of vaults (or all if feasible)
    registry: &SynthRegistry,               // Registry containing params
    oracle_cfg: &OracleConfig,              // Oracle config
    clocks: vector<&Clock>,                 // Clocks per vault (or one shared)
    prices: vector<&PriceInfoObject>,       // Price objects aligned to vaults
): SystemHealth  // Returns comprehensive system health metrics

struct SystemHealth has drop {
    total_collateral_value: u64,    // Total USD value of all collateral in the system
    total_synthetic_value: u64,     // Total USD value of all outstanding synthetic debt
    global_collateral_ratio: u64,   // System-wide collateral ratio (total_collateral / total_debt)
    at_risk_vaults: u64,            // Number of vaults close to liquidation threshold
    system_solvent: bool,           // Whether the system has sufficient collateral backing
}
```

## Matching & Settlement

- Off-chain: Maintain order books and generate settlement candidates.
- On-chain: A single programmable transaction performs vault mutations, USDC transfer between vaults, and fee processing. No synthetic tokens are minted or transferred.

## Display Metadata (Wallet / Explorer UX)

These objects will have `Display<T>` metadata so wallets/explorers can render human-friendly views. Displays are created during object initialization (or order placement) and transferred to the owner or stored with the shared object as appropriate.

- SynthRegistry
  - When: during `synthetics::init`
  - Suggested keys: `name`, `description`, `image_url`, `thumbnail_url`, `project_url`, `creator`
  - Example values: "Unxversal Synthetics Registry", "Central registry storing all synthetic assets listed by Unxversal", project URL, creator name

- SyntheticAsset
  - When: upon `create_synthetic_asset`
  - Suggested keys: `name`, `description`, `image_url`, `thumbnail_url`, `project_url`, `creator`
  - Placeholders: `{name}`, `{symbol}`
  - Example description: "Synthetic {name} provided by Unxversal"

- CollateralVault
  - When: upon `create_vault`
  - Suggested keys: `name`, `description`, `image_url`, `thumbnail_url`, `creator`
  - Example name: "UNXV Synth Collateral Vault"

- OracleConfig
  - When: upon `oracle::init`
  - Suggested keys: `name`, `description`, `project_url`
  - Example name: "Unxversal Oracle Config"; description: "Holds the allow‑list of Pyth feeds trusted by Unxversal"

- Order
  - When: upon `place_limit_order`
  - Suggested keys: `name`, `description`, `symbol`, `side`, `price`, `size`, `remaining`, `created_at_ms`, `expiry_ms`
  - Placeholders referencing order fields: `{symbol}`, `{side}`, `{price}`, `{size}`, `{remaining}`
  - Example name: "Order: {symbol} {side} {size} @ {price}"

Notes:
- Displays are optional but recommended for the above types to improve wallet and explorer UX.
- Placeholders must correspond to fields present on the underlying struct.
- For shared objects (e.g., `SynthRegistry`, `OracleConfig`), create the `Display<T>` once at init and hand the `Display` object to the deployer or appropriate admin account.

## Indexer Integration

### Events to Index
1. **SyntheticAssetCreated** - Track new synthetic assets
2. **SyntheticMinted/Burned** - Monitor supply changes
3. **LiquidationExecuted** - Risk monitoring
4. **FeeCollected** - Revenue tracking
5. **UnxvBurned** - Tokenomics tracking

### API Endpoints Needed
```typescript
// Custom indexer endpoints
/api/v1/synthetics/assets          // List all synthetic assets
/api/v1/synthetics/vaults/{owner}  // User's vaults
/api/v1/synthetics/health          // System health metrics
/api/v1/synthetics/liquidations    // Liquidation opportunities
/api/v1/synthetics/fees            // Fee analytics
/api/v1/synthetics/prices          // Price feeds with oracle data
```

## CLI/Server Components

### 1. Price Feed Manager
```typescript
class PriceFeedManager {
    private pythClient: SuiPythClient;      // Client for connecting to Pyth Network price feeds
    private feedIds: Map<string, string>;   // Maps synthetic symbols to their Pyth feed IDs
    
    // Updates price feeds for specified synthetic assets
    async updatePriceFeeds(synthetics: string[]): Promise<void>;
    // Validates that price data is fresh and within confidence bounds
    async validatePrices(synthetic: string): Promise<boolean>;
    // Retrieves price with confidence interval for risk calculations
    async getPriceWithConfidence(synthetic: string): Promise<PriceData>;
}
```

### 2. Liquidation Bot
```typescript
class LiquidationBot {
    private suiClient: SuiClient;           // Sui blockchain client for transaction execution
    private vaultMonitor: VaultMonitor;     // Service for monitoring vault health status
    
    // Scans all vaults to identify liquidation opportunities
    async scanForLiquidations(): Promise<LiquidationOpportunity[]>;
    // Executes liquidation transaction for profitable opportunities
    async executeLiquidation(opportunity: LiquidationOpportunity): Promise<void>;
    // Calculates expected profit from liquidating a specific vault
    async calculateProfitability(vault: VaultData): Promise<number>;
}
```

### 3. Vault Manager
```typescript
class VaultManager {
    // Creates a new USDC-collateralized vault for the user
    async createVault(): Promise<string>;
    // Deposits USDC collateral into specified vault
    async depositCollateral(vaultId: string, usdcAmount: number): Promise<void>;
    // Withdraws USDC collateral while maintaining safe collateral ratio
    async withdrawCollateral(vaultId: string, usdcAmount: number): Promise<void>;
    // Mints synthetic assets against vault collateral
    async mintSynthetic(vaultId: string, syntheticType: string, amount: number): Promise<void>;
    // Burns synthetic assets to reduce debt and potentially release collateral
    async burnSynthetic(vaultId: string, syntheticType: string, amount: number): Promise<void>;
    // Monitors vault health and liquidation risk
    async monitorHealth(vaultId: string): Promise<VaultHealth>;
}
```

## Frontend Integration

### 1. Vault Dashboard
- Real-time collateral ratios
- Liquidation warnings
- Minting/burning interface
- Fee calculator with UNXV discounts

### 2. Trading Interface
- Off-chain order book + settlement composer
- Price charts with oracle feeds
- Fee preview & UNXV discount UX

### 3. Risk Management
- System health monitoring
- Price feed status
- Liquidation queue
- Fee analytics

## Permissioning & Market Creation

- **Asset Listing:** Only the admin (holding AdminCap) can add new synthetic assets to the registry. This is a permissioned operation for risk management and protocol consistency.
- **Trading:** Anyone can trade listed assets by participating in off-chain matching. Settlement is permissionless (no admin required) and occurs by calling the on-chain vault functions atomically.
- **On-Chain/Off-Chain Split:**
  - On-chain: All minting, burning, collateral, and trading logic; admin listing of assets; event emission.
  - Off-chain: Indexing, liquidation bots, price monitoring, and user-facing automation.

## AdminCap Explanation

The `AdminCap` is a capability object that grants administrative privileges during the initial protocol setup and for listing new synthetic assets. **Only the admin can list new assets.**

### Initial Setup Functions (Requires AdminCap)
```move
public fun initialize_synthetic_asset(
    registry: &mut SynthRegistry,   // Central registry to initialize with new asset
    _admin_cap: &AdminCap,          // Admin capability proving authorization for privileged operation
    asset_name: String,             // Full descriptive name of the synthetic asset
    asset_symbol: String,           // Trading symbol for the asset (e.g., "sBTC")
    pyth_feed_id: vector<u8>,       // Pyth Network price feed identifier for price data
    min_collateral_ratio: u64,      // Minimum collateral ratio for this specific asset
    ctx: &mut TxContext,            // Transaction context for object creation
)

public fun update_global_params(
    registry: &mut SynthRegistry,   // Registry containing global parameters to update
    _admin_cap: &AdminCap,          // Admin capability proving authorization
    new_params: GlobalParams,       // New parameter values to apply system-wide
    ctx: &mut TxContext,            // Transaction context for events
)

public fun emergency_pause(
    registry: &mut SynthRegistry,   // Registry to modify for system-wide pause
    _admin_cap: &AdminCap,          // Admin capability proving emergency authorization
    ctx: &mut TxContext,            // Transaction context for emergency events
)
```

### Making Protocol Immutable
```move
public fun destroy_admin_cap(admin_cap: AdminCap) {
    let AdminCap { id } = admin_cap;    // Destructure the capability object
    object::delete(id);                 // Permanently delete the capability, making protocol immutable
}

// Or transfer to burn address
public fun transfer_admin_to_burn(admin_cap: AdminCap, ctx: &mut TxContext) {
    transfer::public_transfer(admin_cap, @0x0);  // Transfer to burn address (effectively destroying it)
}
```

## Security Considerations

- **Asset Listing is Permissioned:** Only admin can list new assets. This prevents spam, risk, and protocol inconsistency.
- **Market Creation/Trading is Permissionless:** Anyone can create pools and trade for listed assets, maximizing composability and liquidity.

## Deployment Strategy

- **Phase 1:** Deploy registry, admin lists initial assets (sUSD, sBTC, sETH, etc.)
- **Phase 2:** Trading via off-chain matching + on-chain settlement; integrate fee engine
- **Phase 3:** Liquidations and bot rewards; optional AutoSwap-to-UNXV flows

## UNXV Tokenomics Integration

### Fee Revenue Distribution
- 50% burned (deflationary pressure)
- 30% protocol treasury
- 20% liquidity incentives

### Discount Mechanism
- 20% fee discount for UNXV payments
- Auto-swap non-UNXV fees to UNXV
- Gradual burn of collected fees

This creates a sustainable flywheel where protocol usage drives UNXV demand and supply reduction, while providing clear utility and value accrual to token holders. 

---

## Required Bots and Automation

### 1. Liquidation Bots
- **Role:** Monitor for undercollateralized or unhealthy positions and trigger liquidations.
- **Interaction:** Call on-chain liquidation functions; interact with liquidation queue and insurance fund.
- **Reward:** Receive a percentage of liquidation fee (see FEE_REVIEW.md).

### 2. Automation Bots
- **Role:** Automate protocol functions such as rebalancing, fee processing, and risk management.
- **Interaction:** Call on-chain automation functions; interact with automation queue.
- **Reward:** Receive a percentage of protocol fees (see FEE_REVIEW.md).

---

## On-Chain Objects/Interfaces for Bots (optional extensions)

```move
struct LiquidationRequest has store {
    position_id: ID,
    user: address,
    liquidation_price: u64,
    margin_deficit: u64,
    priority_score: u64,
    request_timestamp: u64,
}

struct LiquidationQueue has key, store {
    id: UID,
    pending_liquidations: vector<LiquidationRequest>,
}

struct AutomationRequest has store {
    vault_id: String,
    action: String, // e.g., "REBALANCE", "FEE_PROCESSING"
    parameters: Table<String, u64>,
    request_timestamp: u64,
}

struct AutomationQueue has key, store {
    id: UID,
    pending_automations: vector<AutomationRequest>,
}

struct InsuranceFund has key, store {
    id: UID,
    balance: Balance<USDC>,
    total_contributions: u64,
    total_payouts: u64,
}

struct BotRewardTracker has key, store {
    id: UID,
    bot_address: address,
    total_rewards_earned: u64,
    last_reward_timestamp: u64,
}
```

---

## Off-Chain Bot Interfaces (TypeScript)

```typescript
interface LiquidationBot {
  pollLiquidationQueue(): Promise<LiquidationRequest[]>;
  submitLiquidation(positionId: string): Promise<TxResult>;
  claimReward(botAddress: string): Promise<RewardReceipt>;
}

interface AutomationBot {
  pollAutomationQueue(): Promise<AutomationRequest[]>;
  submitAutomation(request: AutomationRequest): Promise<TxResult>;
  claimReward(botAddress: string): Promise<RewardReceipt>;
}

interface RewardTrackerBot {
  getTotalRewards(botAddress: string): Promise<number>;
  getLastRewardTimestamp(botAddress: string): Promise<number>;
}

interface TxResult {
  success: boolean;
  txHash: string;
  error?: string;
}

interface RewardReceipt {
  amount: number;
  timestamp: number;
  txHash: string;
}
```

---

## References
- See [FEE_REVIEW.md](../FEE_REVIEW.md) and [UNXV_BOTS.md](../UNXV_BOTS.md) for details on bot rewards and incentives. 