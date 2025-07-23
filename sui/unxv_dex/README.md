# UnXversal DEX Protocol

## Overview

The UnXversal DEX Protocol enables advanced spot trading and aggregation on Sui, built on top of DeepBook. It supports direct spot trades between supported asset pairs, robust fee management, and seamless integration with the broader UnXversal ecosystem.

- **DeepBook Integration:** All trades are executed via DeepBook pools. The protocol requires the correct Pool, BalanceManager, and TradeProof objects for secure, on-chain asset movement. No mock or simulated logic is present.
- **Direct Trades Only:** Only direct trades (single pool, single hop) are supported on-chain. Routed/cross-asset trades (multi-hop) must be composed off-chain or via programmable transaction blocks (PTBs). This is a Sui/DeepBook best practice and a Move language constraint.
- **No Hardcoded Addresses:** All shared objects (Pool, BalanceManager, etc.) are passed as arguments. DeepBook and Pyth addresses are assigned at deployment via CLI or script.

## Key Components

- **DEXRegistry:** Central registry for supported pools, fee structure, and admin controls.
- **PoolInfo:** Metadata for each supported DeepBook pool (base/quote asset, pool ID, status, etc.).
- **FeeStructure:** Configurable trading, routing, and discount fees.
- **TradingSession:** Per-user session for tracking orders, volume, and fees.
- **Direct Trade Entry:** The only on-chain trade entry point is for direct trades, requiring all shared objects as arguments.

## DeepBook Integration

- **Order Placement:** Uses DeepBook's `place_limit_order` entry point, passing the correct Pool, BalanceManager, and a TradeProof generated on-chain.
- **Asset Flows:** All asset movement is handled by DeepBook and BalanceManager. No coins are minted, burned, or simulated in protocol logic.
- **No Global Object Fetching:** All objects are passed as arguments; no hardcoded or global fetches.

## Cross-Asset/Routed Trades

- **Not Supported On-Chain:** Generic routed (multi-hop) trades are not possible in Sui Move due to type and object constraints.
- **How to Route:** To perform a routed trade, compose multiple direct trades in a programmable transaction block (PTB) or handle routing off-chain.
- **Documentation:** The protocol code and this README clearly document this limitation and best practice.

## Deployment & Initialization Checklist

1. **Publish the DEX package** to the desired Sui network.
2. **Deploy DeepBook pools** for each supported asset pair (e.g., SUI/USDC, BTC/USDC).
3. **Create and share BalanceManager objects** for each user or trading entity.
4. **Initialize the DEXRegistry** with supported pools and fee structure.
5. **Assign DeepBook and Pyth addresses** at deployment via CLI or deployment script (do not hardcode in Move.toml or source).
6. **Set up off-chain routing logic** or PTBs for any cross-asset/multi-hop trades.

## Required On-Chain Objects

- **DEXRegistry:** Central registry for pools and fees.
- **DeepBook Pools:** One per supported asset pair.
- **BalanceManager:** One per user or trading entity.
- **AdminCap:** For protocol upgrades and admin actions.

## Example Direct Trade Flow

1. User deposits funds into their BalanceManager.
2. User generates a TradeProof (as owner) for their BalanceManager.
3. User calls the DEX direct trade entry function, passing:
   - The correct DeepBook Pool (for the asset pair)
   - Their BalanceManager
   - The generated TradeProof
   - Order parameters (side, price, quantity, etc.)
   - A valid TxContext
4. DeepBook handles order matching, settlement, and emits all relevant events.

## Security & Best Practices

- **No test/mocked logic in production.**
- **No hardcoded addresses.**
- **All flows are Sui-compliant and production-ready.**
- **Routed trades must be handled off-chain or via PTBs.**

---

For more details, see the protocol source code and the DeepBook and Pyth documentation. 