# Audit: unxvmanuallp

## Current On-Chain Approach
- **Vault Listing:** Anyone can create a new manual LP vault (permissionless for users).
- **Trading:** Users control liquidity provisioning strategies, with DeepBook integration for execution.
- **Orderbook:** DeepBook is permissionless, and manual LP vaults can interact with any pool.

## Proper Permissionless Orderbook Approach
- **Vault Listing:** Already permissionless for vault creation.
- **Orderbook:** Users can create and interact with any DeepBook pool permissionlessly.

## Recommended Architectural Changes
- No major changes needed; protocol is already permissionless for vault creation and DeepBook interaction.
- Consider adding more hooks for vaults to interact with DEX/orderbooks.

## Observations
- Protocol is robust and permissionless for its intended use-case.
- No major architectural flaws. 