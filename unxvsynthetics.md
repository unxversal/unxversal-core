# UnXversal Synthetics Protocol Design

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
    id: UID,
    synthetics: Table<String, SyntheticAsset>,
    oracle_feeds: Table<String, vector<u8>>, // Pyth price feed IDs
    global_params: GlobalParams,
    admin_cap: Option<AdminCap>,
}

struct GlobalParams has store {
    min_collateral_ratio: u64,     // 150% = 1500 basis points
    liquidation_threshold: u64,    // 120% = 1200 basis points
    liquidation_penalty: u64,      // 5% = 500 basis points
    max_synthetics: u64,           // Max synthetic types
    stability_fee: u64,            // Annual percentage
}

/// AdminCap grants privileged access for initial setup and emergency functions
/// Will be destroyed after deployment to make protocol immutable
struct AdminCap has key, store {
    id: UID,
}
```

#### 2. SyntheticAsset (Stored in Registry)
```move
struct SyntheticAsset has store {
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
```

#### 3. CollateralVault (Owned Object)
```move
struct CollateralVault has key {
    id: UID,
    owner: address,
    collateral_balance: Balance<USDC>,    // USDC-only collateral
    synthetic_debt: Table<String, u64>,  // synth_symbol -> amount owed
    last_update: u64,
    liquidation_price: Table<String, u64>, // cached liquidation prices per synthetic
}
```

#### 4. SyntheticCoin (Transferable Asset)
```move
struct SyntheticCoin<phantom T> has key, store {
    id: UID,
    balance: Balance<T>,
    synthetic_type: String,
}
```

#### 5. LiquidationBot (Service Object)
```move
struct LiquidationBot has key {
    id: UID,
    operator: address,
    min_profit_threshold: u64,
    max_liquidation_amount: u64,
    whitelisted_assets: VecSet<String>,
}
```

### Events

#### 1. Synthetic Asset Events
```move
// When new synthetic asset is created
struct SyntheticAssetCreated has copy, drop {
    asset_name: String,
    asset_symbol: String,
    pyth_feed_id: vector<u8>,
    creator: address,
    deepbook_pool_id: ID,
    timestamp: u64,
}

// When synthetic is minted
struct SyntheticMinted has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_minted: u64,
    usdc_collateral_deposited: u64,
    minter: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}

// When synthetic is burned
struct SyntheticBurned has copy, drop {
    vault_id: ID,
    synthetic_type: String,
    amount_burned: u64,
    usdc_collateral_withdrawn: u64,
    burner: address,
    new_collateral_ratio: u64,
    timestamp: u64,
}
```

#### 2. Liquidation Events
```move
struct LiquidationExecuted has copy, drop {
    vault_id: ID,
    liquidator: address,
    liquidated_amount: u64,
    usdc_collateral_seized: u64,
    liquidation_penalty: u64,
    synthetic_type: String,
    timestamp: u64,
}

struct LiquidationBotRegistered has copy, drop {
    bot_id: ID,
    operator: address,
    min_profit_threshold: u64,
    timestamp: u64,
}
```

#### 3. Fee Events
```move
struct FeeCollected has copy, drop {
    fee_type: String, // "mint", "burn", "stability"
    amount: u64,
    asset_type: String,
    user: address,
    unxv_discount_applied: bool,
    timestamp: u64,
}

struct UnxvBurned has copy, drop {
    amount_burned: u64,
    fee_source: String,
    timestamp: u64,
}
```

## Core Functions

### 1. Synthetic Asset Creation
```move
public fun create_synthetic_asset(
    registry: &mut SynthRegistry,
    asset_name: String,
    asset_symbol: String,
    pyth_feed_id: vector<u8>,
    min_collateral_ratio: u64,
    deepbook_registry: &mut Registry,
    ctx: &mut TxContext,
): ID // Returns DeepBook pool ID
```

### 2. Collateral Management
```move
public fun deposit_collateral(
    vault: &mut CollateralVault,
    usdc_collateral: Coin<USDC>,
    ctx: &mut TxContext,
)

public fun withdraw_collateral(
    vault: &mut CollateralVault,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDC>
```

### 3. Synthetic Minting/Burning
```move
public fun mint_synthetic<T>(
    vault: &mut CollateralVault,
    synthetic_type: String,
    amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): SyntheticCoin<T>

public fun burn_synthetic<T>(
    vault: &mut CollateralVault,
    synthetic_coin: SyntheticCoin<T>,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<Coin<USDC>> // Returns USDC collateral if any
```

### 4. Liquidation
```move
public fun liquidate_vault<T>(
    vault: &mut CollateralVault,
    synthetic_type: String,
    liquidation_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): (SyntheticCoin<T>, Coin<USDC>) // Returns debt repaid, USDC collateral seized
```

### 5. Flash Loan Integration
```move
public fun flash_mint_arbitrage<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    vault: &mut CollateralVault,
    synthetic_type: String,
    arbitrage_amount: u64,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
    ctx: &mut TxContext,
): FlashLoan // Hot potato for atomic arbitrage
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
    base_fee: u64,
    unxv_discount: u64,    // 20% discount
    final_fee: u64,
    payment_asset: String,  // "UNXV", "USDC", or "input_asset"
}

public fun calculate_fee_with_discount(
    base_fee: u64,
    payment_asset: String,
    unxv_balance: u64,
): FeeCalculation
```

### Auto-swap Integration
```move
public fun process_fee_payment(
    fee_amount: u64,
    payment_asset: String,
    user_balance_manager: &mut BalanceManager,
    autoswap_contract: &mut AutoSwapContract,
    ctx: &mut TxContext,
)
```

## Risk Management

### 1. Collateral Ratio Monitoring
```move
public fun check_vault_health(
    vault: &CollateralVault,
    synthetic_type: String,
    registry: &SynthRegistry,
    price_info: &PriceInfoObject,
    clock: &Clock,
): (u64, bool) // Returns (collateral_ratio, is_liquidatable)
```

### 2. Oracle Price Validation
```move
public fun validate_price_feed(
    price_info: &PriceInfoObject,
    expected_feed_id: vector<u8>,
    max_age: u64,
    clock: &Clock,
): I64
```

### 3. System Stability Checks
```move
public fun check_system_stability(
    registry: &SynthRegistry,
    price_feeds: vector<PriceInfoObject>,
    clock: &Clock,
): SystemHealth

struct SystemHealth has drop {
    total_collateral_value: u64,
    total_synthetic_value: u64,
    global_collateral_ratio: u64,
    at_risk_vaults: u64,
    system_solvent: bool,
}
```

## DeepBook Pool Management

### 1. Automatic Pool Creation
```move
public fun create_deepbook_pool_for_synthetic(
    synthetic_type: String,
    registry: &mut SynthRegistry,
    deepbook_registry: &mut Registry,
    creation_fee: Coin<DEEP>,
    ctx: &mut TxContext,
): ID // Returns pool ID for synthetic/USDC pair
```

### 2. Liquidity Incentives
```move
public fun provide_initial_liquidity<BaseAsset, QuoteAsset>(
    pool: &mut Pool<BaseAsset, QuoteAsset>,
    synthetic_amount: u64,
    collateral_amount: u64,
    price_range: PriceRange,
    balance_manager: &mut BalanceManager,
    trade_proof: &TradeProof,
    ctx: &mut TxContext,
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
    private pythClient: SuiPythClient;
    private feedIds: Map<string, string>;
    
    async updatePriceFeeds(synthetics: string[]): Promise<void>;
    async validatePrices(synthetic: string): Promise<boolean>;
    async getPriceWithConfidence(synthetic: string): Promise<PriceData>;
}
```

### 2. Liquidation Bot
```typescript
class LiquidationBot {
    private suiClient: SuiClient;
    private vaultMonitor: VaultMonitor;
    
    async scanForLiquidations(): Promise<LiquidationOpportunity[]>;
    async executeLiquidation(opportunity: LiquidationOpportunity): Promise<void>;
    async calculateProfitability(vault: VaultData): Promise<number>;
}
```

### 3. Vault Manager
```typescript
class VaultManager {
    async createVault(): Promise<string>; // USDC-only collateral
    async depositCollateral(vaultId: string, usdcAmount: number): Promise<void>;
    async withdrawCollateral(vaultId: string, usdcAmount: number): Promise<void>;
    async mintSynthetic(vaultId: string, syntheticType: string, amount: number): Promise<void>;
    async burnSynthetic(vaultId: string, syntheticType: string, amount: number): Promise<void>;
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
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,
    asset_name: String,
    asset_symbol: String,
    pyth_feed_id: vector<u8>,
    min_collateral_ratio: u64,
    ctx: &mut TxContext,
)

public fun update_global_params(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,
    new_params: GlobalParams,
    ctx: &mut TxContext,
)

public fun emergency_pause(
    registry: &mut SynthRegistry,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext,
)
```

### Making Protocol Immutable
```move
public fun destroy_admin_cap(admin_cap: AdminCap) {
    let AdminCap { id } = admin_cap;
    object::delete(id);
}

// Or transfer to burn address
public fun transfer_admin_to_burn(admin_cap: AdminCap, ctx: &mut TxContext) {
    transfer::public_transfer(admin_cap, @0x0);
}
```

Once the AdminCap is destroyed or transferred to a burn address, the protocol becomes truly immutable and decentralized.

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