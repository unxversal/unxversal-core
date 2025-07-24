# Audit: unxvliquiditypools

## Current On-Chain Approach
- **Pool Listing:** Only admin can create new liquidity pools (admin_cap required).
- **Trading:** Pools are managed by protocol, with automated strategies and risk controls.
- **Orderbook:** No direct orderbook, but pools could be paired with DeepBook for orderbook trading.

## Proper Permissionless Orderbook Approach
- **Pool Listing:** Allow anyone to create new liquidity pools permissionlessly.
- **Orderbook:** Enable permissionless DeepBook pool creation for any asset pair, and allow protocol pools to be listed on DeepBook.

## Recommended Architectural Changes
- Remove admin_cap requirement for pool creation; allow permissionless pool listing.
- Integrate with DeepBook for orderbook-based trading of pool shares or LP tokens.

## Observations
- Protocol is robust for managed liquidity, but permissionless pool creation would increase flexibility and composability. 