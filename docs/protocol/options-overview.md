# Unxversal Options Protocol - Technical Overview

## Introduction

The Unxversal Options Protocol provides **NFT-based options trading** with **European-style settlement**. Each option is an **ERC-721 token** that can be traded, transferred, or exercised. The protocol features **automatic exercise**, **efficient collateral management**, and **oracle-based settlement**.

## Core Components

- **OptionNFT.sol**: ERC-721 option contracts with embedded parameters
- **CollateralVault.sol**: Collateral management and custody system
- **OptionFeeSwitch.sol**: Fee collection with auto-swap to USDC
- **OptionsAdmin.sol**: Asset management and configuration

## Key Features

### NFT-Based Options
- Each option is an ERC-721 token with embedded strike, expiry, and type
- Transferable and tradeable on secondary markets via DEX
- Composable with other DeFi protocols (lending, staking, etc.)
- Batch operations for gas efficiency

### European-Style Settlement  
- Exercise only at expiration for simplicity and gas efficiency
- Automatic exercise for in-the-money options via keeper network
- Oracle-based settlement using LayerZero price feeds
- Instant settlement with no manual intervention required

### Collateral Management
- **Call options**: Lock underlying asset (e.g., 1 ETH for 1 ETH call)
- **Put options**: Lock strike value in quote asset (e.g., $3000 USDC)
- Full collateralization requirement for safety
- Efficient capital usage through shared vault system

### Integrated Fee System
- **Premium fee**: 0.25% on option creation (paid by writer)
- **Exercise fee**: 0.5% on option exercise (paid by holder)
- **Auto-swap functionality** for non-USDC fee payments
- **Fee distribution**: 70% treasury, 20% insurance, 10% development

## Option Data Structure

```solidity
struct OptionData {
    OptionType optionType;          // CALL or PUT
    address underlying;             // Underlying asset (e.g., WETH)
    address quote;                  // Quote asset (e.g., USDC)
    uint256 strike;                 // Strike price (1e18 precision)
    uint256 expiry;                 // Expiration timestamp
    uint256 amount;                 // Option size (underlying units)
    address writer;                 // Option writer (collateral provider)
    OptionState state;              // ACTIVE, EXERCISED, EXPIRED
    uint256 collateralId;           // Link to collateral vault entry
}

enum OptionType { CALL, PUT }
enum OptionState { ACTIVE, EXERCISED, EXPIRED }
```

## Option Lifecycle

### 1. Option Writing
- Writer locks appropriate collateral in vault
- Option NFT minted to writer with embedded parameters
- Premium fee collected (0.25% of notional value)
- Option becomes tradeable immediately

### 2. Secondary Trading
- Option NFT can be listed on Unxversal DEX
- Buyers pay premium to current option holder
- Ownership transfers but writer remains liable for collateral
- Provides liquid secondary market for options

### 3. Expiry & Settlement
- Automatic exercise if in-the-money at expiration
- Oracle price determines settlement value
- Exercise fee (0.5%) collected from holder
- Collateral released based on exercise outcome

### 4. Collateral Return
- If exercised: Collateral used for settlement
- If expired OTM: Full collateral returned to writer
- Automatic process requiring no manual intervention

## Risk Management

### Position Limits
- Maximum expiry: 365 days (1 year)
- Minimum expiry: 1 hour
- Strike price bounds: 50% - 200% of current oracle price
- Maximum position size: $1,000,000 per option

### Collateral Requirements
- **Call Options**: 100% of underlying asset locked
- **Put Options**: 100% of strike value in quote asset locked
- No partial collateralization to ensure settlement capability
- Collateral cannot be withdrawn until option expires/exercises

### Oracle Integration
- LayerZero cross-chain price feeds from Ethereum
- 30-minute staleness tolerance for price data
- Circuit breakers for extreme price movements
- Fallback mechanisms for oracle failures

## Fee Structure

```ascii
Options Fee Breakdown:
┌─────────────────────────────────────────────────────────────┐
│ Premium Fee (Option Creation): 0.25%                       │
│ • Calculated on notional option value                      │
│ • Paid by option writer                                    │
│ • Collected in any asset, auto-swapped to USDC            │
│                                                             │
│ Exercise Fee (Option Exercise): 0.5%                       │
│ • Calculated on exercise proceeds                          │
│ • Paid by option holder                                    │
│ • Ensures only profitable exercises occur                  │
│                                                             │
│ Fee Distribution:                                           │
│ • 70% → Treasury (protocol development)                    │
│ • 20% → Insurance Fund (risk coverage)                     │
│ • 10% → Development Fund (core team)                       │
└─────────────────────────────────────────────────────────────┘
```

## Integration Examples

### Option Market Making
Writers can create option series across multiple strikes and expirations to provide liquidity for option buyers.

### Covered Call Strategies  
Token holders can write call options against their holdings to generate yield while maintaining upside exposure up to the strike price.

### Protective Put Strategies
Asset holders can buy put options to protect against downside risk while maintaining unlimited upside potential.

### Arbitrage Opportunities
Price discrepancies between options and underlying assets create arbitrage opportunities for sophisticated traders.

This options protocol enables sophisticated derivatives trading while maintaining simplicity through full collateralization and automatic settlement, integrating seamlessly with the broader Unxversal ecosystem. 