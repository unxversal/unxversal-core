# Audit: unxvlending

## Current On-Chain Approach
- **Asset Listing:** Only admin can add supported assets and create lending pools (admin_cap required).
- **Pricing:** Uses Pyth oracles for collateral/borrow valuation.
- **Trading:** No orderbook; lending/borrowing is via pool model (Aave/Compound style).
- **Market Creation:** Permissioned (admin only).

## Proper Permissionless Orderbook Approach
- **Asset Listing:** Allow anyone to propose or create new lending pools (with risk parameters set by governance or market).
- **Orderbook:** Lending protocols are not typically orderbook-based, but could allow peer-to-peer lending orderbooks for advanced use-cases.

## Recommended Architectural Changes
- Consider permissionless pool creation with risk parameter templates and/or governance approval.
- Add hooks/events for new pool proposals and community voting.

## Observations
- Protocol is robust for pool-based lending.
- Permissionless pool creation would increase flexibility but also risk.
- Orderbook model is not standard for lending, but could be explored for P2P lending. 