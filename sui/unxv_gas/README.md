# UnXversal Gas Futures Protocol

## Overview

The UnXversal Gas Futures Protocol is the world's first blockchain gas price derivatives market, enabling sophisticated hedging of operational costs and speculative trading on Sui network gas prices. It is designed for sponsored transaction providers, institutional gas cost management, and advanced DeFi users seeking to hedge or speculate on Sui gas price volatility. The protocol is fully on-chain, production-ready, and integrates with DeepBook and Pyth for robust price discovery and settlement.

---

## On-Chain Architecture

### Core Components
- **GasFuturesRegistry**: Central protocol registry for all gas futures contracts, contract types, risk parameters, and UNXV benefits.
- **GasFuturesMarket**: Shared object for each contract, tracks positions, open interest, and settlement data.
- **GasPosition**: User position object, tracks gas units, margin, P&L, and hedging effectiveness.
- **GasOracle**: Real-time on-chain gas price oracle, provides TWAP/VWAP and volatility data for settlement and risk management.
- **SettlementEngine**: Handles automated settlement, margin calls, and performance tracking.
- **AdminCap**: Administrative capability for protocol management.

### Key Flows
- **Position Opening**: User supplies margin, protocol fetches real-time gas price from GasOracle, places a market order (DeepBook integration), and records the position.
- **Margining & Liquidation**: Mark-to-market and margin checks use live gas prices. Liquidations are triggered on-chain if margin falls below maintenance.
- **Settlement**: At expiry, protocol fetches final price (TWAP/VWAP) from GasOracle, calculates P&L, and pays out from on-chain settlement funds.
- **DeepBook Integration**: All order routing (open/close/roll) is performed via DeepBook pools, using BalanceManager and TradeProof for secure fund flows.

### Events
- `GasFuturesContractListed`, `GasFuturesSettled`, `GasPositionOpened`, `GasPositionSettled`, `GasPriceUpdated`, `NetworkCongestionSpike`

---

## Required On-Chain Objects

To deploy and interact with the UnXversal Gas Futures Protocol, you must create and configure the following on-chain objects:

- **GasFuturesRegistry**: Central protocol configuration and contract registry (created at initialization)
- **GasFuturesMarket**: One per listed contract (e.g., SUI-GAS-DEC24), linked to DeepBook pool and GasOracle
- **GasOracle**: Shared object for real-time gas price, TWAP/VWAP, and volatility data
- **SettlementEngine**: Shared object for settlement and margining logic
- **DeepBook Pool**: One per contract, for order execution and settlement (created via DeepBook)
- **BalanceManager**: One per user, for margin and settlement (created via DeepBook)
- **TradeProof**: Generated per trade, as required by DeepBook
- **AdminCap**: For protocol administration and upgrades

---

## Deployment & Initialization Checklist

1. **Publish the unxv_gas Move package** to the desired Sui network.
2. **Initialize the protocol:**
   - Call the `init` entry function to create and share the `GasFuturesRegistry`, `GasOracle`, and `SettlementEngine` shared objects.
   - The `AdminCap` will be transferred to the deployer for protocol management.
3. **Create DeepBook Pools:**
   - For each contract (e.g., SUI-GAS-DEC24), create a DeepBook pool for the relevant trading pair using DeepBook's `create_permissionless_pool` or equivalent.
   - Record the DeepBook pool ID for each contract.
4. **Register Gas Contract Types and Contracts:**
   - Use `create_gas_futures_contract` to list new contracts, passing the contract type, expiry, and other parameters.
5. **Configure GasOracle:**
   - Ensure the GasOracle is updated regularly with real-time gas price data (off-chain keepers or bots may be required).
6. **Create User BalanceManagers:**
   - Each user must create a `BalanceManager` object via DeepBook to hold margin and interact with pools.
   - Users must generate a `TradeProof` for each trade.
7. **(Optional) Configure UNXV Benefits:**
   - The registry supports tiered UNXV staking benefits for trading and settlement fee discounts.
8. **Pass All Required Objects to Entry Functions:**
   - All protocol entry functions require you to pass in the relevant shared objects (e.g., `&mut GasFuturesMarket`, `&mut GasFuturesRegistry`, `&mut SettlementEngine`, `&BalanceManager`, etc.).
   - The contract does **not** assume any pre-existing global objects; you must always pass them in.

---

## Integration Points

- **DeepBook**: Used for all order routing and liquidity. No placeholders.
- **GasOracle**: Used for all price, margin, and settlement logic. No placeholders.
- **BalanceManager/TradeProof**: Used for all user fund flows.
- **Events**: All key actions emit events for off-chain indexers and UIs.

---

## Off-Chain Responsibilities

- **GasOracle Updates**: Off-chain bots/keepers should update the GasOracle with real-time gas price data at the configured frequency.
- **Settlement Triggers**: Off-chain bots/keepers may trigger settlement, expiry, and liquidation flows at the correct times.
- **Analytics & Indexing**: Use protocol events for analytics, user dashboards, and compliance.
- **Order Book UI**: Frontend should display DeepBook order book, user positions, and margin status in real time.
- **CLI/Server**: Should handle wallet management, position monitoring, and automated roll/close strategies.

---

## Deployment Example

```bash
cd sui/unxv_gas
sui move build
sui move publish --gas-budget 50000000
```

After publishing, initialize the protocol and create required objects as described above.

---

## Contact & Further Development

- For integration, see the CLI/server and frontend documentation (coming soon).
- For protocol upgrades, see `PROTOCOL_REVISION.md` and the main repo changelog. 