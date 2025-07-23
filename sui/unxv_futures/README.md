# UnXversal Dated Futures Protocol

## Overview

The UnXversal Dated Futures Protocol enables decentralized trading of standardized futures contracts on synthetic and native assets. It is designed for robust, transparent, and fully on-chain margining, trading, and settlement, leveraging Pyth Network for oracle prices and DeepBook for order routing and liquidity.

---

## On-Chain Architecture

### Core Components
- **FuturesRegistry**: Central protocol registry for all contracts, margin configs, and risk parameters.
- **FuturesMarket**: Shared object for each contract, tracks positions, open interest, and settlement funds.
- **FuturesPosition**: User position object, tracks size, margin, P&L, and settlement eligibility.
- **SettlementEngine**: Handles daily and final settlement, margin calls, and liquidation.
- **CalendarSpreadEngine**: Supports spread trading and margin offsets.
- **AdminCap**: Administrative capability for protocol management.

### Key Flows
- **Position Opening**: User supplies margin, protocol fetches real-time price from Pyth, places a market order on DeepBook, and records the position.
- **Margining & Liquidation**: Mark-to-market and margin checks use live Pyth prices. Liquidations are triggered on-chain if margin falls below maintenance.
- **Settlement**: At expiry, protocol fetches final price from Pyth, calculates P&L, and pays out from on-chain settlement funds.
- **DeepBook Integration**: All order routing (open/close/roll) is performed via DeepBook pools, using BalanceManager and TradeProof for secure fund flows.

### Events
- `FuturesContractListed`, `FuturesContractExpired`, `FuturesPositionOpened`, `PositionSettled`, `CalendarSpreadExecuted`

---

## Required On-Chain Objects

To deploy and interact with the UnXversal Dated Futures Protocol, you must create and configure the following on-chain objects:

- **FuturesRegistry**: Central protocol configuration and contract registry (created at initialization)
- **FuturesMarket**: One per listed contract (e.g., BTC-DEC24), linked to DeepBook pool and Pyth price feed
- **SettlementEngine**: Shared object for settlement and margining logic
- **CalendarSpreadEngine**: Shared object for spread trading and margin offsets
- **DeepBook Pool**: One per contract, for order execution and settlement (created via DeepBook)
- **Pyth PriceInfoObject**: One per underlying asset, for real-time price feeds (created via Pyth)
- **BalanceManager**: One per user, for margin and settlement (created via DeepBook)
- **TradeProof**: Generated per trade, as required by DeepBook
- **AdminCap**: For protocol administration and upgrades

---

## Deployment & Initialization Checklist

1. **Publish the unxv_futures Move package** to the desired Sui network.
2. **Initialize the protocol:**
   - Call the `init` entry function to create and share the `FuturesRegistry`, `SettlementEngine`, and `CalendarSpreadEngine` shared objects.
   - The `AdminCap` will be transferred to the deployer for protocol management.
3. **Create DeepBook Pools:**
   - For each contract (e.g., BTC-DEC24), create a DeepBook pool for the relevant trading pair using DeepBook's `create_permissionless_pool` or equivalent.
   - Record the DeepBook pool ID for each contract.
4. **Register Underlying Assets and Contracts:**
   - Use `add_underlying_asset` or `add_underlying_asset_simple` to register supported assets and their contract series in the `FuturesRegistry`.
   - Use `create_futures_contract` to list new contracts, passing the DeepBook pool ID and other parameters.
5. **Configure Pyth Price Feeds:**
   - For each contract/underlying, ensure the correct Pyth `PriceInfoObject` is available and up-to-date.
   - Store the expected price feed ID for each contract in the registry.
6. **Create User BalanceManagers:**
   - Each user must create a `BalanceManager` object via DeepBook to hold margin and interact with pools.
   - Users must generate a `TradeProof` for each trade.
7. **(Optional) Set up Calendar Spreads:**
   - Use `create_calendar_spread` to enable spread trading between contract months.
8. **(Optional) Configure UNXV Benefits:**
   - The registry supports tiered UNXV staking benefits for trading and settlement fee discounts.
9. **Pass All Required Objects to Entry Functions:**
   - All protocol entry functions require you to pass in the relevant shared objects (e.g., `&mut FuturesMarket`, `&mut FuturesRegistry`, `&mut SettlementEngine`, `&BalanceManager`, etc.).
   - The contract does **not** assume any pre-existing global objects; you must always pass them in.
   - **Price feed validation:** The contract will compare the price ID in the provided `PriceInfoObject` to the configured value in the registry for the relevant contract. If they do not match, the transaction aborts. This prevents price spoofing and ensures robust oracle integration.

---

## Off-Chain Responsibilities

- **Cron Jobs**: Off-chain bots/keepers should trigger daily settlement, expiry, and liquidation flows at the correct times.
- **Analytics & Indexing**: Use the DeepBook Indexer and protocol events for analytics, user dashboards, and compliance.
- **Order Book UI**: Frontend should display DeepBook order book, user positions, and margin status in real time.
- **CLI/Server**: Should handle wallet management, position monitoring, and automated roll/close strategies.

---

## Integration Points

- **Pyth Network**: Used for all price, margin, and settlement logic. No placeholders.
- **DeepBook**: Used for all order routing and liquidity. No placeholders.
- **BalanceManager/TradeProof**: Used for all user fund flows.
- **Events**: All key actions emit events for off-chain indexers and UIs.

---

## Deployment Example

```bash
cd sui/unxv_futures
sui move build
sui move publish --gas-budget 50000000
```

After publishing, initialize the protocol and create required objects as described above.

---

## Contact & Further Development

- For integration, see the CLI/server and frontend documentation (coming soon).
- For protocol upgrades, see `PROTOCOL_REVISION.md` and the main repo changelog. 