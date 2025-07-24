# Audit: unxvoptions

## Current On-Chain Approach
- **Market Listing:** Only admin can create new option markets (admin_cap required).
- **Pricing:** Option price is calculated on-chain using Black-Scholes and Pyth oracles, not by orderbook supply/demand.
- **Trading:** Options are bought/sold at model price, not via orderbook matching.
- **Orderbook:** DeepBook integration exists, but not for permissionless market creation or orderbook-based pricing.

## Proper Permissionless Orderbook Approach
- **Market Listing:** Allow anyone to create new option markets (strikes/expiries) permissionlessly.
- **Pricing:** Use DeepBook orderbook for price discovery—let users place bids/asks, and market determines option price.
- **Orderbook:** Each option market should have a DeepBook pool; protocol should not enforce model pricing.

## Recommended Architectural Changes
- Remove admin_cap requirement for market creation; allow permissionless listing of new strikes/expiries.
- Use DeepBook orderbook for all option trading and price discovery.
- Make on-chain pricing model optional or for reference only.

## Observations
- Current design is more like a centralized options protocol (admin-listed, model-priced).
- Permissionless, orderbook-based options would better match DeFi/CLOB standards and user expectations. 