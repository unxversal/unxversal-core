# UnXversal Perpetuals Protocol

## Overview

The UnXversal Perpetuals Protocol enables decentralized trading of perpetual contracts (perpetual futures) on the Sui blockchain with advanced features like funding rates, liquidation mechanisms, and sophisticated risk management systems.

## ✅ On-Chain Implementation Status: **COMPLETE**

**Build Status**: ✅ Compiles cleanly, 100% test pass rate (12/12 tests)

## Architecture

### Core Components

#### 1. **PerpetualsRegistry** - Central Protocol Hub
- **Market Management**: Tracks all active perpetual markets and their configurations
- **Global Settings**: Protocol-wide parameters, fee structures, and risk limits
- **User Account Registry**: Central registry of all user accounts and their positions
- **Admin Controls**: Market creation, parameter updates, and emergency controls

#### 2. **PerpetualsMarket<T>** - Individual Market Implementation
- **Position Management**: Long and short position tracking with complete lifecycle management
- **Price Infrastructure**: Mark price, index price, and funding rate calculations
- **Open Interest Tracking**: Real-time monitoring of total long/short OI and imbalances
- **Liquidity Management**: Integration with DeepBook for order execution
- **Historical Data**: Price history, funding rate history, and trading volume tracking

#### 3. **UserAccount** - Trader Portfolio Management
- **Multi-Position Support**: Manage multiple positions across different markets
- **Margin Management**: Total margin, available margin, and used margin tracking
- **P&L Tracking**: Realized and unrealized P&L calculation and tracking
- **UNXV Integration**: Volume-based tier system for trading fee discounts

#### 4. **PerpetualPosition** - Individual Position State
- **Position Details**: Size, entry price, leverage, margin, and side (LONG/SHORT)
- **Risk Metrics**: Liquidation price, maintenance margin, and margin ratio
- **P&L Calculations**: Real-time unrealized P&L and cumulative realized P&L
- **Advanced Orders**: Stop-loss, take-profit, and trailing stop support
- **Funding Payments**: Automatic funding payment calculations and settlements

#### 5. **FundingRateCalculator** - Dynamic Funding Rate System
- **Premium Component**: Mark price vs index price divergence calculation
- **OI Imbalance Component**: Long/short open interest imbalance adjustments
- **Volatility Adjustments**: Market volatility-based funding rate modifications
- **Rate Capping**: Maximum funding rate limits with confidence scoring
- **Historical Tracking**: Complete funding rate history with detailed analytics

#### 6. **LiquidationEngine** - Risk Management & Liquidations
- **Health Monitoring**: Real-time position health factor calculations
- **Liquidation Queue**: Priority-based liquidation request processing
- **Partial Liquidations**: Intelligent partial liquidation with optimal sizing
- **Insurance Fund**: Automatic insurance fund management and socialized losses
- **Auto-Deleveraging**: Automatic deleveraging of profitable positions when needed

### Key Features Implemented

#### 🔢 **Signed Integer Mathematics**
- **Complete Implementation**: Full signed integer arithmetic for P&L calculations
- **Operations Supported**: Addition, subtraction, multiplication, division
- **Safety**: Overflow protection and proper negative value handling
- **Use Cases**: P&L calculations, funding rates, position values

#### 📊 **Advanced P&L Calculations**
- **Accurate Formulas**: Proper percentage-based P&L calculations
  - LONG P&L: `size * (exit_price - entry_price) / entry_price`
  - SHORT P&L: `size * (entry_price - exit_price) / entry_price`
- **Real-time Updates**: Continuous unrealized P&L calculation
- **Funding Integration**: Automatic funding payment adjustments

#### ⚖️ **Dynamic Funding Rates**
- **Multi-Component System**: Premium + OI imbalance + volatility adjustments
- **Adaptive Rates**: Market condition-responsive funding rate calculation
- **Rate Capping**: Maximum rate limits with confidence level tracking
- **Historical Data**: Complete funding rate history and analytics

#### 🚨 **Sophisticated Risk Management**
- **Health Factor Monitoring**: Real-time position health calculation
- **Intelligent Liquidations**: Optimal partial liquidation sizing
- **Circuit Breakers**: Market volatility protection mechanisms
- **Insurance Fund**: Automatic loss socialization and fund management

#### 🔐 **Security & Admin Controls**
- **Emergency Pause**: System-wide trading halt capabilities
- **Market Management**: Dynamic market addition and parameter updates
- **Fee Structure Updates**: Real-time fee adjustment capabilities
- **Access Control**: Role-based permission system

## On-Chain Smart Contract Functions

### Market Operations
- `add_market<T>()` - Add new perpetual market
- `open_position<T>()` - Open new perpetual position
- `close_position<T>()` - Close existing position
- `modify_position<T>()` - Adjust position size or margin

### Risk Management
- `liquidate_position<T>()` - Execute position liquidation
- `calculate_health_factor()` - Position health assessment
- `update_margin<T>()` - Add/remove position margin
- `apply_funding_payment<T>()` - Process funding payments

### Admin Functions
- `emergency_pause()` - System-wide emergency halt
- `resume_operations()` - Resume normal operations
- `update_fee_structure()` - Modify trading fees
- `manage_insurance_fund<T>()` - Insurance fund operations

### Data Access
- `get_position_info<T>()` - Position details and metrics
- `get_market_data<T>()` - Market statistics and parameters
- `get_funding_history<T>()` - Historical funding rates
- `calculate_liquidation_price()` - Liquidation price calculation

## Technical Specifications

### Position Limits
- **Minimum Position Size**: 1 USDC equivalent
- **Maximum Leverage**: 50x (configurable per market)
- **Maximum OI Limit**: 1,000,000 USDC per market (configurable)

### Fee Structure
- **Base Trading Fee**: 10 basis points (0.10%)
- **UNXV Discount**: Up to 20% fee reduction for UNXV holders
- **Liquidation Penalty**: 250 basis points (2.50%)
- **Insurance Fund Ratio**: 60% of liquidation penalties

### Risk Parameters
- **Maintenance Margin**: 5% minimum
- **Liquidation Threshold**: 7.5% margin ratio
- **Maximum Funding Rate**: 375 basis points (3.75%)
- **Circuit Breaker**: 15% price movement triggers

## Off-Chain CLI Requirements

### Trading Operations
```bash
# Position Management
unxv perps open --market BTC-PERP --side LONG --size 1000 --leverage 10
unxv perps close --position-id 0x123... --size 500
unxv perps modify --position-id 0x123... --add-margin 100

# Market Data
unxv perps markets --list
unxv perps price --market BTC-PERP --live
unxv perps funding --market BTC-PERP --history 7d

# Account Management
unxv perps account --summary
unxv perps positions --active
unxv perps pnl --realized --unrealized
```

### Risk Monitoring
```bash
# Position Health
unxv perps health --position-id 0x123...
unxv perps liquidation-price --position-id 0x123...

# Market Monitoring
unxv perps oi --market BTC-PERP
unxv perps volume --market BTC-PERP --24h
```

### Admin Operations
```bash
# Market Management
unxv perps admin add-market --symbol ETH-PERP --max-leverage 25
unxv perps admin update-fees --market BTC-PERP --fee 0.08%
unxv perps admin pause --emergency

# Liquidation Management
unxv perps admin liquidate --position-id 0x123... --partial
unxv perps admin insurance-fund --balance
```

## Frontend Integration Points

### Real-Time Data Feeds
- **Live Prices**: WebSocket feeds for mark and index prices
- **Position Updates**: Real-time P&L and margin ratio updates
- **Funding Rates**: Live funding rate calculations and payments
- **Liquidation Alerts**: Position health warnings and notifications

### Trading Interface
- **Order Entry**: Position size, leverage, and order type selection
- **Position Management**: Margin adjustment and position modification
- **Risk Display**: Health factor, liquidation price, and margin requirements
- **P&L Tracking**: Real-time profit/loss display and history

### Market Data Dashboard
- **OI Charts**: Open interest visualization and trends
- **Funding History**: Historical funding rate charts and analysis
- **Volume Analytics**: Trading volume breakdown and statistics
- **Liquidation Activity**: Recent liquidations and market impact

### Portfolio Management
- **Multi-Position View**: Portfolio overview across all markets
- **Risk Analytics**: Portfolio-level risk metrics and exposure
- **Transaction History**: Complete trading and funding payment history
- **Performance Metrics**: Returns, Sharpe ratio, and risk-adjusted performance

## Integration with Other Protocols

### AutoSwap Integration
- **Automatic Conversions**: Convert any asset to USDC for margin
- **Fee Processing**: Route trading fees through AutoSwap for UNXV burning
- **Liquidation Proceeds**: Automatic conversion of liquidated assets

### DEX Integration
- **Order Routing**: Route large orders through DEX for better execution
- **Arbitrage Detection**: Identify perp-spot arbitrage opportunities
- **Cross-Market Analysis**: Compare perpetual vs spot pricing

## Deployment Checklist

### Pre-Deployment
- [x] Complete smart contract implementation
- [x] Comprehensive test suite (12/12 tests passing)
- [x] Security review and audit preparation
- [x] Gas optimization analysis

### Testnet Deployment
- [ ] Deploy contracts to Sui testnet
- [ ] Configure initial markets (BTC-PERP, ETH-PERP)
- [ ] Set up price feeds and oracle integration
- [ ] Test liquidation mechanisms

### CLI Development
- [ ] Implement trading commands
- [ ] Build market data queries
- [ ] Create admin management tools
- [ ] Add risk monitoring features

### Frontend Development
- [ ] Real-time trading interface
- [ ] Portfolio management dashboard
- [ ] Risk monitoring alerts
- [ ] Historical data visualization

## Testing Coverage

### Core Functionality Tests ✅
- Protocol initialization and market setup
- User account creation and management
- Position opening and closing operations
- Funding rate calculation and application

### Advanced Features Tests ✅
- Signed integer mathematics operations
- P&L calculations for LONG and SHORT positions
- Emergency pause and resume functionality
- Insurance fund management

### Risk Management Tests ✅
- Margin health factor calculations
- Liquidation eligibility and execution
- Market information retrieval
- Registry configuration management

## Security Considerations

### Access Control
- Admin-only functions protected by capability system
- Emergency pause accessible only to authorized addresses
- Market parameter updates require admin privileges

### Risk Mitigation
- Position size limits and leverage caps
- Circuit breaker mechanisms for extreme price movements
- Insurance fund for socialized loss protection
- Partial liquidation to minimize market impact

### Data Integrity
- Immutable position history and transaction records
- Tamper-proof funding rate calculations
- Verifiable P&L computation and tracking

The UnXversal Perpetuals Protocol provides a complete foundation for decentralized perpetual futures trading with institutional-grade risk management and user experience. 