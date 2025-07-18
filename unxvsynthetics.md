# UnXversal Synthetics Protocol Design

## System Architecture & User Flow Overview

### How All Components Work Together

The UnXversal Synthetics protocol creates a sophisticated ecosystem where multiple on-chain objects, functions, and external integrations work in harmony to enable synthetic asset creation, trading, and management:

#### **Core Object Hierarchy & Relationships**

```
SynthRegistry (Shared) ← Central authority & configuration
    ↓ manages
SyntheticAsset configs → DeepBook Pools ← trading venues
    ↓ references            ↓ provides liquidity
SyntheticsVault<T> (Shared) ← user positions
    ↓ tracks
UserPosition (individual) → BalanceManager ← holds funds
    ↓ validates              ↓ executes
RiskManager (Service) → PriceOracle ← Pyth feeds
    ↓ monitors              ↓ provides pricing
LiquidationEngine ← processes liquidations
```

#### **Complete User Journey Flows**

**1. MINTING FLOW (Creating Synthetic Assets)**
```
User → deposit USDC → SyntheticsVault checks collateral ratio → 
calls RiskManager validation → PriceOracle gets current prices → 
mint synthetic tokens → update UserPosition → 
create/update DeepBook pool liquidity
```

**2. TRADING FLOW (Synthetic Asset Exchange)**
```
User → submit order to DeepBook → BalanceManager validates funds → 
order matching engine processes → trade executes → 
fees collected → UNXV fee discounts applied → 
position updates → real-time price discovery
```

**3. LIQUIDATION FLOW (Risk Management)**
```
RiskManager monitors positions → detects under-collateralized vault → 
LiquidationEngine calculates liquidation amount → 
flash loan from DeepBook → liquidate position → 
repay debt + penalty → distribute remaining collateral → 
update all affected positions
```

#### **Key System Interactions**

- **SynthRegistry**: Acts as the central configuration hub, managing all synthetic asset definitions, oracle mappings, and global risk parameters
- **SyntheticsVault<T>**: Individual user vaults that hold USDC collateral and track minted synthetic positions, with built-in risk monitoring
- **DeepBook Integration**: Provides order book trading infrastructure, flash loans for liquidations, and real-time price discovery
- **PriceOracle**: Aggregates Pyth Network feeds to provide accurate, manipulation-resistant pricing for all synthetic assets
- **RiskManager**: Continuously monitors collateral ratios, triggers liquidations, and enforces risk parameters across all positions
- **LiquidationEngine**: Handles the complex liquidation process using flash loans and atomic transactions
- **BalanceManager**: Sui's native fund management system that holds user assets across all DeepBook operations

#### **Critical Design Patterns**

1. **Atomic Operations**: All minting, trading, and liquidation operations are atomic - they either complete fully or revert entirely
2. **Flash Loan Integration**: Liquidations use DeepBook flash loans to ensure zero-capital liquidations with immediate debt repayment
3. **Oracle Integration**: Real-time price feeds from Pyth Network ensure accurate collateral valuation and liquidation triggers
4. **Risk Isolation**: Each user's position is isolated in their own vault, preventing contagion between users
5. **Fee Integration**: Seamless integration with UNXV tokenomics for fee discounts and protocol value accrual

#### **Data Flow & State Management**

- **Price Data**: Pyth → PriceOracle → RiskManager → liquidation decisions
- **User Positions**: SyntheticsVault → UserPosition updates → risk calculations
- **Trading Data**: DeepBook trades → fee collection → UNXV conversions → burns
- **Risk Monitoring**: Continuous monitoring of collateral ratios with real-time liquidation triggers
- **Global State**: SynthRegistry maintains system-wide parameters and configurations that all other components reference

#### **Integration Points with UnXversal Ecosystem**

- **AutoSwap**: Automatic fee processing and UNXV burning from all trading fees
- **DEX**: Synthetic assets become tradeable on the main DEX with cross-asset routing
- **Lending**: Synthetic assets can be used as collateral in the lending protocol
- **Options/Perpetuals**: Synthetic assets serve as underlying assets for derivatives
- **Liquid Staking**: stSUI can be accepted as collateral in future versions

## Overview

UnXversal Synthetics enables permissionless creation and trading of synthetic assets backed by USDC collateral, built on top of DeepBook's order book infrastructure. Users can mint synthetic assets by depositing USDC and trade them on DeepBook pools with automatic price feeds from Pyth Network.

### Benefits of USDC-Only Collateral

1. **Simplified Risk Management**: No need to manage multiple collateral types with different volatility profiles
2. **Stable Collateral**: USDC's price stability reduces liquidation risk and provides predictable collateral ratios
3. **Reduced Complexity**: Single collateral type simplifies vault management, liquidation logic, and user experience
4. **Better Capital Efficiency**: Users don't need to manage multiple collateral balances
5. **Unified Liquidity**: All synthetic assets trade against USDC, creating deeper liquidity pools
6. **Easier Oracle Integration**: Only need USDC price feeds for collateral valuation (typically $1.00)

## DeepBook Integration Summary

**How DeepBook Works:**
- **Pool**: Central limit order book for each trading pair (e.g., synth/USDC)
- **BalanceManager**: Holds user funds across all pools, requires TradeProof for operations
- **Order Matching**: Automatic matching of buy/sell orders with maker/taker fees
- **Flash Loans**: Uncollateralized borrowing within single transaction
- **Indexer**: Real-time data feeds for order books, trades, and volumes

**Our Integration:**
- Create DeepBook pools for each synthetic asset vs collateral pairs
- Use flash loans for atomic liquidations and arbitrage
- Leverage indexer for real-time pricing and risk management
- Integrate with existing fee structure while adding UNXV discounts

## Core Architecture

### On-Chain Objects

#### 1. SynthRegistry (Shared Object)
```move
struct SynthRegistry has key {
    id: UID,                                      // Unique identifier for the registry object
    synthetics: Table<String, SyntheticAsset>,    // Maps asset symbols to their metadata (e.g., "sBTC" -> SyntheticAsset)
    oracle_feeds: Table<String, vector<u8>>,      // Maps asset symbols to Pyth price feed IDs for price lookups
    global_params: GlobalParams,                  // System-wide risk parameters that apply to all synthetic assets
    admin_cap: Option<AdminCap>,                  // Optional admin capability for initial setup, destroyed after deployment
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

#### 2. SyntheticAsset (Stored in Registry)
```move
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
```

#### 3. CollateralVault (Owned Object)
```move
struct CollateralVault has key {
    id: UID,                                  // Unique identifier for this user's vault
    owner: address,                           // Address of the vault owner (only they can modify it)
    collateral_balance: Balance<USDC>,        // Amount of USDC collateral deposited in this vault
    synthetic_debt: Table<String, u64>,       // Maps synthetic symbols to amounts owed (e.g., "sBTC" -> 50000000)
    last_update: u64,                         // Timestamp of last vault modification for fee calculations
    liquidation_price: Table<String, u64>,    // Cached liquidation prices per synthetic to optimize gas usage
}
```

#### 4. SyntheticCoin (Transferable Asset)
```move
struct SyntheticCoin<phantom T> has key, store {
    id: UID,                 // Unique identifier for this coin object
    balance: Balance<T>,     // The actual token balance of the synthetic asset
    synthetic_type: String,  // String identifier linking back to SyntheticAsset in registry
}
```

#### 5. LiquidationBot (Service Object)
```move
struct LiquidationBot has key {
    id: UID,                                // Unique identifier for this liquidation bot
    operator: address,                      // Address authorized to operate this bot
    min_profit_threshold: u64,              // Minimum profit required before executing liquidation (gas optimization)
    max_liquidation_amount: u64,            // Maximum debt amount this bot will liquidate per transaction
    whitelisted_assets: VecSet<String>,     // Synthetic asset types this bot is configured to liquidate
}
```

### Events

#### 1. Synthetic Asset Events
```move
// When new synthetic asset is created
struct SyntheticAssetCreated has copy, drop {
    asset_name: String,         // Full name of the created asset for display purposes
    asset_symbol: String,       // Trading symbol for identification in UIs and trading
    pyth_feed_id: vector<u8>,   // Price feed ID for price tracking and validation
    creator: address,           // Address that created this asset (initially admin, later community)
    deepbook_pool_id: ID,       // DeepBook pool ID for immediate trading capability
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
    deepbook_registry: &mut Registry,   // DeepBook registry for creating trading pools
    ctx: &mut TxContext,                // Transaction context for object creation and events
): ID // Returns DeepBook pool ID for immediate trading setup
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
public fun mint_synthetic<T>(
    vault: &mut CollateralVault,        // User's vault providing collateral for minting
    synthetic_type: String,             // Type of synthetic to mint (e.g., "sBTC")
    amount: u64,                        // Amount of synthetic tokens to mint
    registry: &SynthRegistry,           // Registry for asset parameters and validation
    price_info: &PriceInfoObject,       // Current price data for collateral ratio calculation
    clock: &Clock,                      // Sui clock for fee calculations and validation
    ctx: &mut TxContext,                // Transaction context for object creation and events
): SyntheticCoin<T>  // Returns newly minted synthetic tokens

public fun burn_synthetic<T>(
    vault: &mut CollateralVault,        // User's vault to reduce debt and potentially release collateral
    synthetic_coin: SyntheticCoin<T>,   // Synthetic tokens being burned to reduce debt
    registry: &SynthRegistry,           // Registry for asset parameters and fee calculations
    price_info: &PriceInfoObject,       // Current price data for collateral calculations
    clock: &Clock,                      // Sui clock for fee calculations
    ctx: &mut TxContext,                // Transaction context for events
): Option<Coin<USDC>>  // Returns USDC collateral if any is released
```

### 4. Liquidation
```move
public fun liquidate_vault<T>(
    vault: &mut CollateralVault,        // Undercollateralized vault being liquidated
    synthetic_type: String,             // Type of synthetic debt being repaid
    liquidation_amount: u64,            // Amount of debt to repay (limited by vault debt and max liquidation)
    registry: &SynthRegistry,           // Registry for liquidation parameters and penalties
    price_info: &PriceInfoObject,       // Current price data for liquidation calculations
    clock: &Clock,                      // Sui clock for timestamp validation
    ctx: &mut TxContext,                // Transaction context for events
): (SyntheticCoin<T>, Coin<USDC>)  // Returns (debt repaid as synthetic tokens, USDC collateral seized)
```

### 5. Flash Loan Integration
```move
public fun flash_mint_arbitrage<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,  // DeepBook pool for executing arbitrage trades
    vault: &mut CollateralVault,             // Vault to temporarily mint synthetics for arbitrage
    synthetic_type: String,                  // Type of synthetic to flash mint
    arbitrage_amount: u64,                   // Amount to flash mint for arbitrage opportunity
    registry: &SynthRegistry,                // Registry for synthetic asset parameters
    price_info: &PriceInfoObject,            // Price data for arbitrage calculations
    clock: &Clock,                           // Sui clock for validation
    ctx: &mut TxContext,                     // Transaction context
): FlashLoan  // Returns hot potato that must be repaid in same transaction
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

### Auto-swap Integration
```move
public fun process_fee_payment(
    fee_amount: u64,                        // Amount of fee to be paid
    payment_asset: String,                  // Asset type being used for payment
    user_balance_manager: &mut BalanceManager,  // User's DeepBook balance manager for asset access
    autoswap_contract: &mut AutoSwapContract,   // Contract for converting assets to UNXV
    ctx: &mut TxContext,                    // Transaction context
)
```

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
    registry: &SynthRegistry,               // Registry containing all synthetic assets and parameters
    price_feeds: vector<PriceInfoObject>,   // Current price data for all tracked assets
    clock: &Clock,                          // Sui clock for calculations
): SystemHealth  // Returns comprehensive system health metrics

struct SystemHealth has drop {
    total_collateral_value: u64,    // Total USD value of all collateral in the system
    total_synthetic_value: u64,     // Total USD value of all outstanding synthetic debt
    global_collateral_ratio: u64,   // System-wide collateral ratio (total_collateral / total_debt)
    at_risk_vaults: u64,            // Number of vaults close to liquidation threshold
    system_solvent: bool,           // Whether the system has sufficient collateral backing
}
```

## DeepBook Pool Management

### 1. Automatic Pool Creation
```move
public fun create_deepbook_pool_for_synthetic(
    synthetic_type: String,             // Synthetic asset symbol to create pool for
    registry: &mut SynthRegistry,       // Registry to store the pool ID reference
    deepbook_registry: &mut Registry,   // DeepBook registry for pool creation
    creation_fee: Coin<DEEP>,           // DEEP tokens required for pool creation fee
    ctx: &mut TxContext,                // Transaction context
): ID  // Returns newly created pool ID for synthetic/USDC trading pair
```

### 2. Liquidity Incentives
```move
public fun provide_initial_liquidity<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,  // DeepBook pool to provide liquidity to
    synthetic_amount: u64,                   // Amount of synthetic asset to provide as liquidity
    collateral_amount: u64,                  // Amount of USDC collateral to provide as liquidity
    price_range: PriceRange,                 // Price range for concentrated liquidity provision
    balance_manager: &mut BalanceManager,    // User's balance manager for asset access
    trade_proof: &TradeProof,                // Proof of authorization for DeepBook operations
    ctx: &mut TxContext,                     // Transaction context
)
```

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

// DeepBook integration
/api/v1/deepbook/pools/synthetic   // Synthetic asset pools
/api/v1/deepbook/volume/synthetic  // Trading volumes
/api/v1/deepbook/liquidity/synthetic // Liquidity metrics
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
- DeepBook order book integration
- Price charts with oracle feeds
- Liquidity provision tools
- Arbitrage opportunities

### 3. Risk Management
- System health monitoring
- Price feed status
- Liquidation queue
- Fee analytics

## AdminCap Explanation

The `AdminCap` is a capability object that grants administrative privileges during the initial protocol setup. It allows the deployer to:

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

1. **Oracle Failures**: Multiple price feed validation
2. **Flash Loan Attacks**: Atomic operation constraints
3. **Collateral Volatility**: Dynamic liquidation thresholds (USDC stability mitigates this)
4. **Smart Contract Risks**: Formal verification and audits
5. **Economic Attacks**: Incentive alignment and circuit breakers
6. **AdminCap Security**: Must be destroyed after deployment to ensure immutability

## Deployment Strategy

### Phase 1: Core Infrastructure
- Deploy SynthRegistry and core contracts
- Create initial synthetic assets (sUSD, sBTC, sETH)
- Set up price feeds and DeepBook pools

### Phase 2: Advanced Features  
- Liquidation bots and flash loan integration
- Advanced synthetic assets (commodities, indices)
- Cross-collateral support

### Phase 3: Ecosystem Integration
- Integration with other UnXversal protocols
- Synthetic derivatives and structured products
- Institutional features

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