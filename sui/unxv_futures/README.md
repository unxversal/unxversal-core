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

### Key Flows
- **Position Opening**: User supplies margin, protocol fetches real-time price from Pyth, places a market order on DeepBook, and records the position.
- **Margining & Liquidation**: Mark-to-market and margin checks use live Pyth prices. Liquidations are triggered on-chain if margin falls below maintenance.
- **Settlement**: At expiry, protocol fetches final price from Pyth, calculates P&L, and pays out from on-chain settlement funds.
- **DeepBook Integration**: All order routing (open/close/roll) is performed via DeepBook pools, using BalanceManager and TradeProof for secure fund flows.

### Events
- `FuturesContractListed`, `FuturesContractExpired`, `FuturesPositionOpened`, `PositionSettled`, `CalendarSpreadExecuted`

---

## Off-Chain Responsibilities

- **Cron Jobs**: Off-chain bots/keepers should trigger daily settlement, expiry, and liquidation flows at the correct times.
- **Analytics & Indexing**: Use the DeepBook Indexer and protocol events for analytics, user dashboards, and compliance.
- **Order Book UI**: Frontend should display DeepBook order book, user positions, and margin status in real time.
- **CLI/Server**: Should handle wallet management, position monitoring, and automated roll/close strategies.

---

## Deployment & Testing

- All on-chain code is production-ready and fully tested (see `sui/unxv_futures/tests/unxv_futures_tests.move`).
- To deploy: publish the Move package to Sui testnet/mainnet, initialize the registry, and create markets with valid DeepBook pool IDs.
- To test: run `sui move test` in this directory for full coverage.

---

## Integration Points

- **Pyth Network**: Used for all price, margin, and settlement logic. No placeholders.
- **DeepBook**: Used for all order routing and liquidity. No placeholders.
- **BalanceManager/TradeProof**: Used for all user fund flows.
- **Events**: All key actions emit events for off-chain indexers and UIs.

---

## Contact & Further Development

- For integration, see the CLI/server and frontend documentation (coming soon).
- For protocol upgrades, see `PROTOCOL_REVISION.md` and the main repo changelog. 