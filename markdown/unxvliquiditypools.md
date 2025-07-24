# UnXversal Liquidity Protocol Design

> **Note:** This document merges and supersedes the previous 'Automated Liquidity Provisioning Pools' and 'Manual Liquidity Management' protocols. For the latest permissioning, architecture, and on-chain/off-chain split, see [MOVING_FORWARD.md](../MOVING_FORWARD.md). **All liquidity strategies (manual and automated) are implemented on the unxvdex layer (orderbook-based), not directly on DeepBook. Pool/vault creation is permissionless. The distinction between manual and automated is a CLI/server/frontend difference, not a protocol difference.**

---

## Migration Note

- This protocol unifies all liquidity provisioning under a single system: **UnXversal Liquidity**.
- All previous manual and automated LP vaults/pools are now managed by this protocol.
- All strategies must operate on the unxvdex (orderbook) layer, not on AMM or simulated pools.
- Users can choose between manual (UI-driven) and automated (CLI/server-driven) strategies, but both share the same on-chain infrastructure and analytics.

---

## System Architecture & User Flow Overview

### How All Components Work Together

The UnXversal Liquidity protocol provides a unified, permissionless framework for both manual and automated liquidity provisioning, all built on top of the unxvdex orderbook. Users can deploy capital using either manual strategies (full user control via frontend/UI) or automated strategies (CLI/server-driven bots and automation), with all strategies sharing the same on-chain vault/pool logic, analytics, and risk management.

#### **Core Object Hierarchy & Relationships**

```
LiquidityRegistry (Shared, permissionless) ← Central configuration for all vaults/pools
    ↓ manages all vaults/pools
LiquidityVault<T, U> (Shared/Owned) → StrategyEngine ← manual or automated strategy execution
    ↓ tracks user positions      ↓ executes strategies on unxvdex orderbook
UserLPPosition (individual) ← user deposits & yields
    ↓ validates participation
RiskManager ← risk controls for all vaults/pools
    ↓ enforces user/system risk limits
PerformanceAnalytics ← unified analytics for all strategies
    ↓ tracks P&L, risk, and performance
Cross-Protocol Router → AutoSwap ← asset management for rebalancing, fee optimization
    ↓ enables cross-protocol LP   ↓ handles swaps/settlement
UNXV Integration → LP benefits, fee discounts, and advanced features
```

**Manual Mode**: User interacts via frontend/UI, configures all parameters, and manages vaults directly.
**Automated Mode**: User or operator runs CLI/server bots that automate strategy execution, rebalancing, and optimization.

---

## Permissioning Policy

- **Vault/pool creation is permissionless.**
- **All strategies must operate on the unxvdex (orderbook) layer.**
- **Manual vs automated is a UI/CLI/server distinction, not a protocol distinction.**
- See [MOVING_FORWARD.md](../MOVING_FORWARD.md) for the full permissioning matrix and rationale.

---

## User Flows

### 1. Manual Liquidity Provisioning (Frontend/UI)

**Step-by-Step Example:**
1. User connects wallet to frontend and navigates to the Liquidity section.
2. User selects "Create New Vault" and chooses a trading pair (e.g., sBTC/USDC).
3. User configures all strategy parameters:
   - Tick ranges, rebalancing frequency, risk limits, notification preferences, etc.
4. User deposits assets and confirms vault creation.
5. Vault is created on-chain; user can monitor performance, adjust parameters, and manually rebalance as desired.
6. All trades and liquidity actions are executed on the unxvdex orderbook.
7. Performance analytics, risk alerts, and historical data are available in the UI.

### 2. Automated Liquidity Provisioning (CLI/Server)

**Step-by-Step Example:**
1. User or operator runs the UnXversal CLI/server and connects to their wallet/account.
2. CLI/server indexes protocol events and monitors vaults/pools for opportunities.
3. User configures automation settings:
   - Strategy selection (e.g., grid, volatility, yield optimization), rebalancing triggers, risk budgets, etc.
4. CLI/server automatically executes strategy logic:
   - Places/cancels orders, rebalances positions, harvests rewards, manages risk, etc.
5. All actions are executed on the unxvdex orderbook via programmable transaction blocks (PTBs).
6. CLI/server provides logs, analytics, and can send notifications to the user.

### 3. Hybrid/Delegated Automation
- Users can opt-in to automation bots (run by themselves or third parties) for advanced strategies, market creation, or liquidation.
- Vaults/pools can be managed collaboratively, with permissions and notifications for all actions.

---

## On-Chain vs Off-Chain Responsibilities

### On-Chain (Move)
- Core protocol logic for vault/pool creation, deposits, withdrawals, and strategy execution (on unxvdex orderbook).
- State management for all vaults, positions, and risk parameters.
- Event emission for all actions (deposits, trades, rebalances, risk alerts, etc.).
- Enforcement of permissionless creation and minimum interval (if needed).
- Risk checks, fee processing, and UNXV integration.

### Off-Chain (CLI/Server)
- Indexing protocol events for analytics, UI, and automation.
- Running bots for automated strategy execution, rebalancing, and risk management.
- Market creation, liquidation, and advanced order management (with user opt-in and rewards).
- Performance analytics, reporting, and notification services.
- User wallet management, transaction batching, and programmable transaction blocks (PTBs).

### Frontend (UI)
- Manual vault/pool creation and management.
- Parameter configuration, performance monitoring, and risk alerting.
- Visualization of analytics, historical data, and strategy effectiveness.
- User opt-in to automation and bot services.

---

## Core On-Chain Objects and Data Structures

### 1. LiquidityRegistry (Shared Object)
```move
struct LiquidityRegistry has key {
    id: UID,
    active_vaults: Table<String, LiquidityVaultInfo>,      // Vault ID -> vault info
    strategy_templates: Table<String, StrategyTemplate>,   // Strategy ID -> template/config
    risk_parameters: RiskParameters,                       // Global/system risk settings
    performance_analytics: PerformanceAnalytics,           // Analytics engine
    protocol_integrations: ProtocolIntegrations,           // Integration configs
    admin_cap: Option<AdminCap>,
}
```

### 2. LiquidityVault<T, U> (Shared/Owned Object)
```move
struct LiquidityVault<phantom T, phantom U> has key, store {
    id: UID,
    owner: address,
    vault_name: String,
    strategy_type: String,                                 // "MANUAL" or "AUTOMATED"
    strategy_config: Table<String, u64>,                   // Strategy parameters
    asset_a_type: String,
    asset_b_type: String,
    balance_a: Balance<T>,
    balance_b: Balance<U>,
    deployed_liquidity: DeployedLiquidity,
    user_positions: Table<address, UserLPPosition>,        // User -> position
    risk_limits: VaultRiskLimits,
    performance_data: VaultPerformanceData,
    status: String,                                        // "ACTIVE", "PAUSED", etc.
    last_rebalance: u64,
    creation_timestamp: u64,
}
```

### 3. UserLPPosition (Owned Object)
```move
struct UserLPPosition has key, store {
    id: UID,
    user: address,
    vault_id: String,
    shares_owned: u64,
    initial_deposit_a: u64,
    initial_deposit_b: u64,
    deposit_timestamp: u64,
    current_value: u64,
    fees_earned: u64,
    il_impact: i64,
    total_return: i64,
    auto_rebalance: bool,
    yield_strategy: String,
    risk_tolerance: String,
    notification_preferences: NotificationPreferences,
}
```

### 4. StrategyTemplate (Config Object)
```move
struct StrategyTemplate has store {
    template_id: String,
    template_name: String,
    description: String,
    strategy_type: String,                                 // "MANUAL", "AUTOMATED", "HYBRID"
    required_parameters: vector<ParameterDefinition>,
    default_values: Table<String, u64>,
    risk_level: String,
    performance_targets: PerformanceTargets,
}
```

### 5. Risk Management and Analytics
```move
struct RiskParameters has store {
    max_vaults_per_user: u64,
    max_total_liquidity: u64,
    global_drawdown_limit: u64,
    min_rebalance_interval: u64,
}

struct VaultRiskLimits has store {
    max_position_size: u64,
    max_drawdown: u64,
    stop_loss: u64,
    notification_thresholds: Table<String, u64>,
}

struct PerformanceAnalytics has store {
    vault_performance: Table<String, VaultPerformanceData>,
    user_performance: Table<address, UserPerformanceData>,
    strategy_performance: Table<String, StrategyPerformanceData>,
}
```

---

## Strategy Types & Configuration

### 1. Manual Strategies (User-Configured)
- **Overview**: User configures all parameters, manages rebalancing, and monitors risk/performance via the frontend.
- **Example Parameters**:
  - Tick range (lower/upper bounds)
  - Rebalancing frequency (manual, time-based, threshold-based)
  - Position size, risk limits, stop-loss/take-profit
  - Notification preferences
- **Example Flow**:
  1. User selects "Manual Strategy" and configures all parameters.
  2. User deposits assets and confirms vault creation.
  3. User manually rebalances, adjusts parameters, and monitors analytics.

### 2. Automated Strategies (Bot/CLI-Driven)
- **Overview**: User or operator configures automation settings; CLI/server executes strategy logic, rebalancing, and optimization.
- **Example Parameters**:
  - Strategy type (grid, volatility, yield optimization, etc.)
  - Rebalancing triggers (price movement, time, volatility, etc.)
  - Risk budget, max drawdown, auto-compound
  - Delegation/automation permissions
- **Example Flow**:
  1. User configures automation via CLI/server.
  2. Bot monitors market, executes trades, rebalances, and manages risk.
  3. User receives analytics, notifications, and can override automation if desired.

### 3. Hybrid/Delegated Strategies
- **Overview**: Users can opt-in to third-party bots or collaborative vault management.
- **Features**:
  - Shared vaults with multiple managers
  - Delegated automation with user approval/notifications
  - Community or DAO-driven strategy selection

### 4. StrategyTemplate Example (Move)
```move
struct StrategyTemplate has store {
    template_id: String,
    template_name: String,
    description: String,
    strategy_type: String, // "MANUAL", "AUTOMATED", "HYBRID"
    required_parameters: vector<ParameterDefinition>,
    default_values: Table<String, u64>,
    risk_level: String,
    performance_targets: PerformanceTargets,
}
```

---

## Risk Management & Controls

### 1. Vault-Level Risk Controls
- **On-Chain Enforcement**:
  - Max position size per vault
  - Max drawdown and stop-loss triggers
  - Minimum rebalance interval
  - Emergency pause/circuit breaker
- **Off-Chain/Automation**:
  - Automated risk monitoring and alerts
  - Auto-rebalance or auto-close on risk breach
  - User-configurable notification thresholds

### 2. User-Level Risk Controls
- **Limits on total exposure across vaults**
- **Custom risk profiles (conservative, moderate, aggressive)**
- **Real-time risk analytics and alerts (UI/CLI)**

### 3. Global/Systemic Risk Controls
- **Protocol-wide drawdown and liquidity limits**
- **System-wide circuit breakers and emergency withdrawal**
- **Admin controls for protocol upgrades and parameter changes (see MOVING_FORWARD.md)**

### 4. Example Risk Structs (Move)
```move
struct VaultRiskLimits has store {
    max_position_size: u64,
    max_drawdown: u64,
    stop_loss: u64,
    notification_thresholds: Table<String, u64>,
}

struct RiskParameters has store {
    max_vaults_per_user: u64,
    max_total_liquidity: u64,
    global_drawdown_limit: u64,
    min_rebalance_interval: u64,
}
```

---

## Performance Analytics & Reporting

### 1. On-Chain Analytics
- **Vault-level performance tracking** (returns, fees, IL, drawdown)
- **User-level analytics** (P&L, share of fees, risk metrics)
- **Strategy-level analytics** (performance by strategy type)
- **Event emission for all key actions** (deposits, trades, rebalances, risk events)

### 2. Off-Chain Analytics (CLI/Server, Indexer)
- **Aggregated analytics and reporting** (historical performance, risk trends, leaderboard)
- **Advanced analytics** (Sharpe/Sortino ratios, VaR, stress tests, attribution)
- **Custom dashboards and notifications** (UI/CLI)
- **Exportable reports for compliance, tax, and governance**

### 3. Example Analytics Structs (Move)
```move
struct PerformanceAnalytics has store {
    vault_performance: Table<String, VaultPerformanceData>,
    user_performance: Table<address, UserPerformanceData>,
    strategy_performance: Table<String, StrategyPerformanceData>,
}

struct VaultPerformanceData has store {
    inception_date: u64,
    all_time_volume: u64,
    all_time_fees: u64,
    daily_returns: vector<i64>,
    monthly_returns: vector<i64>,
    cumulative_return: i64,
    volatility: u64,
    max_drawdown: u64,
    sharpe_ratio: u64,
    sortino_ratio: u64,
    capital_efficiency: u64,
    fee_capture_rate: u64,
    liquidity_utilization: u64,
}
```

---

## Protocol and Cross-Protocol Integration

### 1. DEX (unxvdex) Integration
- **All liquidity strategies operate on the unxvdex orderbook layer.**
- Vaults/pools place, manage, and rebalance orders via the DEX, not directly on DeepBook.
- Performance, risk, and analytics are unified with DEX trading data.
- Cross-asset routing and advanced order types are available for LP strategies.

### 2. AutoSwap Integration
- **Fee optimization and asset management**: Vaults/pools use AutoSwap for fee conversion, rebalancing, and settlement.
- Automated strategies can trigger swaps for optimal rebalancing or yield harvesting.
- IL protection and yield optimization can leverage AutoSwap for hedging and payout.

### 3. Synthetics Integration
- **Liquidity provision for synthetic assets**: Vaults/pools can provide liquidity for synthetic pairs (e.g., sBTC/USDC).
- Synthetic LP tokens may be used as collateral in other protocols.
- Yield and risk analytics are integrated with synthetics protocol data.

### 4. Lending Integration
- **LP tokens as collateral**: Users can use LP/vault tokens as collateral in the lending protocol.
- Automated strategies can borrow/lend for leveraged LP positions.
- Risk management is coordinated with lending health factors and liquidation bots.

### 5. Options, Perps, and Futures Integration
- **Liquidity for derivatives**: Vaults/pools can provide liquidity for options, perps, and futures markets on the DEX.
- Automated strategies can hedge LP exposure using options or futures.
- Cross-protocol analytics for risk, yield, and hedging effectiveness.

### 6. Trader Vaults Integration
- **Strategy delegation**: Users can allocate capital to trader-managed vaults that use liquidity strategies.
- Performance fees, profit sharing, and analytics are unified across protocols.

### 7. Governance and Upgradability
- **Protocol parameters (risk, fees, strategy templates) are upgradable via governance.**
- Admin controls for emergency pause, upgrades, and parameter changes (see MOVING_FORWARD.md).
- Community/DAO governance for strategy whitelisting, fee structure, and protocol upgrades.

---

## Deployment, Upgradeability, and Governance

### 1. Phased Deployment
- **Phase 1: Core Infrastructure**
  - Deploy unified LiquidityRegistry, vault logic, and DEX integration.
  - Enable permissionless vault/pool creation and manual strategies.
  - Launch basic analytics and risk management.
- **Phase 2: Automation and Advanced Features**
  - Deploy CLI/server automation, strategy templates, and performance analytics.
  - Integrate AutoSwap, synthetics, lending, and derivatives protocols.
  - Launch IL protection, yield optimization, and cross-protocol routing.
- **Phase 3: Ecosystem Integration and Governance**
  - Enable LP tokens as collateral, trader vaults, and community/DAO governance.
  - Expand analytics, dashboards, and reporting.
  - Implement upgradability and protocol parameter governance.

### 2. Upgradeability
- **Modular contract design**: Registry, vault, strategy, and analytics modules are upgradable.
- **AdminCap and governance**: Upgrades and parameter changes require admin or governance approval.
- **Emergency controls**: Protocol pause, emergency withdrawal, and circuit breakers are available.

### 3. Governance
- **Community/DAO governance**: Users can propose and vote on protocol upgrades, strategy templates, and fee structures.
- **Parameter management**: Risk, fee, and strategy parameters are managed via governance.
- **Transparency**: All governance actions, votes, and parameter changes are on-chain and auditable.

---

## Conclusion

The UnXversal Liquidity protocol provides a unified, permissionless, and orderbook-based framework for all liquidity provisioning strategies—manual, automated, and hybrid. All strategies operate on the unxvdex layer, with robust risk management, analytics, and cross-protocol integration. The protocol is designed for upgradability, community governance, and seamless integration with the broader UnXversal ecosystem.

**For implementation details, permissioning, and architecture, always reference [MOVING_FORWARD.md](../MOVING_FORWARD.md).** 