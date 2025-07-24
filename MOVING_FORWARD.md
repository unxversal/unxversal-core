# MOVING_FORWARD.md

## UnXversal Protocols: Architectural Review & Next Steps

---

### 1. **Project Overview**
UnXversal is a modular DeFi protocol suite on Sui, with:
- **On-chain protocols** (Move)
- **CLI/server backend** (automation, bots, indexers, off-chain logic)
- **Frontend** (user interface, manual/automated controls)

---

### 2. **Permissioning & Market Creation Policy**

| Protocol            | Listing/Market Creation | Rationale/Notes |
|---------------------|------------------------|-----------------|
| **unxvsynthetics**  | Permissioned (admin)   | Risk control, only admin lists synths |
| **unxvlending**     | Permissioned (admin)   | Admin maintains asset consistency |
| **unxvdex**         | Permissioned (admin)   | Only admin can add pools to DEX |
| **unxvautoswap**    | Permissioned (admin)   | Asset pairs set by admin |
| **unxvperps**       | Permissioned (admin)   | One market per synth-usdc, admin deploys |
| **unxvoptions**     | Permissionless         | Anyone can create option markets |
| **unxvdatedfutures**| Permissionless         | Anyone can create futures contracts (min interval: daily) |
| **unxvgasfutures**  | Permissionless         | Anyone can create gas futures (min interval: daily) |
| **unxvtradervaults**| Permissionless         | Anyone can create vaults |
| **unxvliquidity**   | Permissionless         | Anyone can create pools/strategies |
| **unxvmanuallp**    | Permissionless         | (To be merged with unxvliquidity) |
| **unxvexotics**     | (Ignore for now)       | |

- **Permissionless protocols**: Add minimum interval (e.g., daily) for market creation to prevent spam.
- **Permissioned protocols**: Admin maintains consistency, risk, and asset mapping.

---

### 3. **On-Chain vs Off-Chain (CLI/Server) Responsibilities**

- **On-Chain (Move):**
  - Core protocol logic, state, and validation
  - Market/pool/contract creation (with permissioning as above)
  - Trading, settlement, margin, collateral, and risk checks
  - Event emission for off-chain indexers
  - For gas futures: Use SuiSystemState referenceGasPrice for on-chain gas price (no oracle needed)

- **Off-Chain (CLI/Server):**
  - Indexing protocol events for trading, analytics, and UI
  - Running bots: liquidation, oracle updates, market creation (with opt-in and rewards)
  - Automated liquidity management (for unxvliquidity, manual vs automated is a CLI/frontend distinction)
  - User wallet management, transaction batching, and programmable transaction blocks (PTBs)
  - Market creation bots: enforce min interval, allow user opt-in, reward bot operators

- **Frontend:**
  - Manual user controls for all protocols
  - UI for both manual and automated strategies (manual LP vs automated LP is a UI/CLI distinction)

---

### 4. **Source of Truth & Documentation**

- **Markdown docs in `/markdown/`** are the current source of truth for protocol design, but need to be revised to:
  - Reflect updated permissioning and market creation policies
  - Clarify on-chain vs off-chain responsibilities
  - Document the merging of manual LP and automated LP into a single `unxv_liquidity` protocol
  - Remove/replace any references to placeholder logic or non-DeepBook-based strategies

- **On-chain code** must be updated to:
  - Remove all placeholder/simulated logic (especially in liquidity protocols)
  - Ensure all permissionless protocols allow market creation as specified
  - Use DeepBook as the base for all orderbook/market logic (liquidity, options, futures, etc.)
  - For gas futures, use SuiSystemState referenceGasPrice for on-chain gas price

---

### 5. **Outstanding Issues & Action Items**

#### **A. Protocol Architecture**
- [ ] Update all on-chain protocols to match the permissioning table above
- [ ] Merge `unxv_liquidity` and `unxv_manuallp` into a single protocol, with both manual and automated strategies
- [ ] Ensure all liquidity strategies operate on the DEX layer (not directly on DeepBook)
- [ ] Remove all placeholder/simulated logic from liquidity, vaults, and any other protocols
- [ ] Implement minimum interval for permissionless market creation (enforced on-chain)
- [ ] Update gas futures to use on-chain SuiSystemState gas price

#### **B. Documentation**
- [ ] Revise all `/markdown/` docs to reflect new architecture, permissioning, and on-/off-chain split
- [ ] Document the CLI/server's role in automation, bots, and user opt-in for market creation/liquidation/oracle bots
- [ ] Clarify the distinction between manual and automated LP as a UI/CLI/server difference, not a protocol difference

#### **C. Implementation & Testing**
- [ ] Fully implement and test all on-chain protocols (no placeholders)
- [ ] Ensure all permissionless protocols have proper spam prevention (min interval, etc.)
- [ ] Add/expand test coverage for all new/updated logic

#### **D. Governance & Upgradability**
- [ ] Document and implement upgradability/governance for permissioned protocols (admin rotation, parameter changes, etc.)

---

### 6. **Next Steps**
1. **Review and update all on-chain protocol code** to match the permissioning and architecture above
2. **Revise all markdown documentation** to reflect the new architecture and clarify on-chain/off-chain split
3. **Merge and refactor liquidity protocols** into a single, DeepBook-based, permissionless protocol
4. **Implement minimum interval logic** for permissionless market creation
5. **Update gas futures to use on-chain gas price**
6. **Expand and update test coverage**
7. **Document and implement governance for permissioned protocols**
8. **Plan CLI/server and frontend implementation** to support both manual and automated strategies, bots, and user opt-in

---

### 7. **If You Are a Contributor**
- **Read this document fully before making changes**
- **Coordinate with the team** before starting major refactors
- **Document all changes in both code and markdown**
- **Ask for review if you are unsure about permissioning, on-chain/off-chain split, or protocol design**

---

**If you have questions or want to propose changes, open an issue or PR referencing this document.** 