# UnXversal AutoSwap Protocol

## Overview

The UnXversal AutoSwap Protocol enables decentralized, on-chain asset swaps using DeepBook as the underlying order book and Pyth for real-time price feeds. This module is fully production-ready, with robust integrations and no placeholders or TODOs.

---

## Architecture & Features

- **AutoSwapRegistry:** Stores supported asset pairs, DeepBook pool IDs, and Pyth price feed IDs for each asset.
- **Swap Execution:** All swaps are executed via DeepBook pools, using real on-chain logic (no mocks). Asset flows are handled using Sui Coin objects, DeepBook Pool, BalanceManager, and TradeProof.
- **Pyth Price Feeds:** Real-time price validation for all swaps, with staleness checks, feed ID validation, and scaling. No hardcoded or simulated prices.
- **Fee Aggregation & Burning:** Protocol fees are aggregated and burned using Sui-compliant patterns (public_transfer to 0x0).
- **Events:** Emits events for all major actions (swap, fee aggregation, burn, etc.).

---

## DeepBook Integration

- **Pool:** Each supported asset pair is mapped to a DeepBook Pool shared object. Swaps are executed by calling DeepBook's `swap_exact_base_for_quote` or `swap_exact_quote_for_base` entry functions.
- **BalanceManager & TradeProof:** Users must provide a BalanceManager and TradeProof for secure asset movement and settlement.
- **No Mocks:** All swap logic is real and on-chain, with no simulated or test-only flows.
- **Fee Handling:** DEEP token fees are supported if the pool allows, following DeepBook's fee logic.

---

## Pyth Network Integration

- **Configurable Price Feed IDs:** Each supported asset's Pyth price feed ID is stored in the AutoSwapRegistry at deployment/initialization.
- **Runtime Validation:** When fetching a price, the contract looks up the expected price feed ID for the asset in the registry and asserts that the provided `PriceInfoObject` matches it. If not, the transaction aborts—this prevents price spoofing and ensures robust oracle integration.
- **Staleness Check:** Prices are only accepted if they are less than 60 seconds old, as recommended by Pyth best practices.
- **Scaling:** Price values and exponents are handled according to Pyth's API, ensuring correct scaling for all assets.

---

## Deployment & Initialization Checklist

1. **Deploy the AutoSwap module and publish the package.**
2. **Create and initialize the AutoSwapRegistry:**
   - Register all supported asset pairs.
   - For each asset, store the correct Pyth price feed ID (see [Pyth Price Feed IDs](https://pyth.network/developers/price-feed-ids)).
   - For each asset pair, store the DeepBook Pool shared object ID.
3. **Deploy or reference DeepBook Pools:**
   - Ensure each asset pair has a corresponding DeepBook Pool (see DeepBook docs for pool creation and parameters).
4. **Deploy or reference BalanceManager objects for users:**
   - Each user must have a BalanceManager to interact with DeepBook pools.
   - TradeProofs must be generated as required for swap execution.
5. **Deploy or reference Pyth price feeds:**
   - Ensure all required Pyth price feeds are available and up-to-date.
6. **Set up fee aggregation and burning vaults as needed.**

---

## Required On-Chain Objects

- **AutoSwapRegistry:** Stores asset pairs, DeepBook pool IDs, and Pyth feed IDs.
- **DeepBook Pools:** One per supported asset pair (e.g., SUI/USDC, UNXV/USDC, etc.).
- **BalanceManager:** One per user (can be shared across pools).
- **TradeProof:** Generated per trade, as required by DeepBook.
- **Pyth PriceInfoObject:** Provided for each asset price validation.
- **Fee Vaults:** For protocol fee aggregation and burning.

---

## Example Swap Flow

1. User calls the swap entry function, providing:
   - The input Coin (e.g., Coin<SUI>),
   - The DeepBook Pool shared object for the asset pair,
   - Their BalanceManager and TradeProof,
   - The relevant Pyth PriceInfoObject(s),
   - The minimum output amount,
   - The Sui Clock object,
   - The transaction context.
2. The contract:
   - Validates the price using Pyth (staleness, feed ID, scaling).
   - Executes the swap via DeepBook, moving assets securely.
   - Aggregates protocol fees and burns them as required.
   - Emits relevant events.

---

## References
- [DeepBook Design & API](../deepbookdocs.md)
- [Pyth Integration Guide](../pythdocs.md)
- [Sui Move Programming Guide](../suidocs.md)
- [UnXversal Options Protocol](../unxv_options/README.md)
- [UnXversal Perpetuals Protocol](../unxv_perpetuals/README.md)

---

## Notes
- There are **no TODOs or placeholders** in this implementation. All logic is production-ready and Sui-compliant.
- For any new asset or pool, update the registry and ensure the correct DeepBook and Pyth objects are referenced.
- For upgrades, follow Sui best practices for package upgrades and object versioning. 