# **unxversal: The Comprehensive Overview**

---

## **1. High-Level Vision: The DeFi Operating System on Sui**

**unxversal** is a modular, all-in-one DeFi protocol built on the Sui blockchain. Its mission is to provide a unified and capital-efficient environment to **trade, borrow, lend, hedge, and speculate on any Pyth-priced asset**.

It achieves this by deeply integrating with Sui's native infrastructure:

*   **DeepBook:** All spot and derivative order matching is handled by Sui's native on-chain central limit orderbook, ensuring deterministic, CEX-grade fairness and shared liquidity.
*   **Pyth Oracles:** Provides low-latency price feeds for over 400 assets, forming the backbone for the protocol's synthetic assets, margin calculations, and settlement pricing.
*   **Sui's Object Model:** Enables gas-efficient, granular control over positions, collateral, and permissions, leading to a safer and more responsive user experience.

The entire ecosystem is powered by a single utility and governance token, **UNXV**, creating a closed-loop economy where all protocol activity reinforces the token's value.

---

## **2. The UNXV Token & Value Accrual**

The UNXV token is the core of the unxversal economy, with a hard-capped supply of **1,000,000,000 tokens**.

### **2.1. The Fee Flywheel: All Roads Lead to UNXV**

unxversal's most critical economic feature is its unified fee model. Every action that generates a fee—be it a trade, a loan, or a liquidation—follows a simple, powerful path:

1.  **Fee Charged in Transacting Asset:** A user pays a fee in USDC, sBTC, ETH, etc.
2.  **Instant On-Chain Swap:** The protocol automatically swaps that fee into **UNXV** via a DeepBook RFQ order within the same transaction.
3.  **Distribution:** The resulting UNXV is then routed to various destinations based on DAO-governed rules:
    *   **Burn:** A portion of fees is permanently removed from circulation.
    *   **Treasury:** Funds protocol operations, grants, and audits.
    *   **Insurance Funds:** Backstops the various derivative and lending protocols.
    *   **ve-Locking:** A portion of fees is bought and locked for 4 years, aligning protocol revenue with long-term governance.
    *   **Incentives:** A slice is paid to participants like DEX relayers or liquidators.

This mechanism ensures that **any and all economic activity directly translates into buying pressure and utility for UNXV.**

### **2.2. veUNXV Governance & Staking**

Users can lock their UNXV for 1 to 4 years to receive **veUNXV** (vote-escrowed UNXV), an NFT representing their governance power.

*   **Governance:** veUNXV holders can create proposals and vote on all protocol parameters, upgrades, and Treasury spending.
*   **Gauge Weighting:** veUNXV holders vote weekly to direct the flow of UNXV emissions to different products (e.g., boosting liquidity rewards for the BTC-PERP market).
*   **Fee Earning:** veUNXV holders receive a share of protocol fees and can boost their own farming yields.

### **2.3. Genesis Allocation**

| Bucket                 | %     | Purpose                                            |
| ---------------------- | ----- | -------------------------------------------------- |
| Community Incentives   | 30%   | Liquidity mining, usage rewards (6-year emission). |
| Founders & Core        | 30%   | 1-year cliff, 4-year linear vest.                  |
| DAO Treasury           | 15%   | Unlocked for grants, audits, operations.           |
| Ecosystem & Partners   | 10%   | MM loans, cross-chain bridges.                     |
| Protocol-Owned Liq.    | 10%   | Seed UNXV/USDC DeepBook liquidity.                 |
| Airdrop                | 3%    | Reward early testers and community members.        |

---

## **3. The unxversal Product Suite**

All products are designed to be composable, sharing a single cross-margin account and leveraging the same core infrastructure.

### **3.1. Synthetic Assets (sAssets)**

The foundation of the ecosystem. Users can lock USDC in a vault (160% minimum collateralization ratio) to mint synthetic "sAssets" (like sBTC, sETH, sSOL) that track any Pyth price feed. These sAssets are first-class citizens, usable across every other unxversal product.

### **3.2. Spot DEX**

A thin, permissionless wrapper around **DeepBook**. It adds UNXV-denominated fees and a real-time relayer mesh for a CEX-like trading experience without reinventing the matching engine.

### **3.3. Lending (uCoin Money Market)**

A permissionless money market where users can supply or borrow any Pyth-priced asset (USDC, UNXV, sAssets). Idle margin from the derivatives platforms is automatically deposited here to earn yield. A portion of interest accrued is converted to UNXV and split between the Treasury and a 4-year ve-lock.

### **3.4. Perpetual Futures (Perps)**

Cross-margin perpetual futures with up to 20x leverage, matched on DeepBook. An on-chain clearing house handles funding rates and risk. Taker fees and a 10% skim of funding payments are converted to UNXV to seed the perps insurance fund and the Treasury.

### **3.5. Dated Futures**

Cash-settled, date-certain futures that also trade on DeepBook and use the same cross-margin account as perps. They offer leverage without the complexity of perpetual funding rates, settling to a Pyth mark price at expiry.

### **3.6. Options**

Fully collateralized, European-style calls and puts. They can be traded on DeepBook or via a gas-saving off-chain RFQ system. They settle to a Pyth mark price and are margined within the shared cross-margin account.

### **3.7. Exotics**

A specialized clearing house for path-dependent derivatives like **barrier options** (knock-in/knock-out), **range-accrual notes**, and **power perps** (PnL ∝ S^n). These products allow for sophisticated hedging and speculation, with all fees feeding the UNXV flywheel.

### **3.8. Liquid Staking (sSUI)**

A liquid staking solution that wraps SUI into **sSUI**, a yield-bearing, rebasing token. sSUI earns staking rewards while remaining liquid for use as collateral across the entire unxversal ecosystem. A 5% skim of staking rewards is converted to UNXV.

### **3.9. Gas Futures**

A novel market allowing users and protocols to hedge against Sui network transaction fee volatility. Users can buy tokenized claims on a fixed amount of future gas units, locking in their operational costs.

### **3.10. LP Vaults**

Automated, strategy-driven vaults that allow passive users to provide liquidity across all unxversal venues (spot, perps, options, etc.). Vaults can execute complex strategies like market making, basis trading, and covered-call writing, with a portion of profits converted to UNXV.

---

## **4. Governance & Security**

### **4.1. DAO Structure**

*   **Governor:** An OpenZeppelin Bravo-style module for on-chain proposals and voting.
*   **Timelock:** A mandatory 48-hour delay on all critical and privileged actions, giving the community time to react to approved proposals.
*   **Pause Guardian:** A 3-of-5 multisig controlled by trusted community members that can instantly pause critical functions (but cannot move funds) for up to 7 days in an emergency. This power is revocable by the DAO after year one.

### **4.2. Liquidations & Solvency**

The protocol relies on a permissionless, competitive market of **liquidation bots** to maintain solvency. When any position (lend, synth, or derivative) becomes undercollateralized, bots are incentivized to step in, repay the debt, and collect a penalty. This externalizes the work of maintaining protocol health, making it more resilient and censorship-resistant.

### **4.3. Insurance Funds**

Each risk-bearing protocol (Perps, Options, Lend) is backstopped by a dedicated insurance fund, capitalized by a portion of its fee revenue (in UNXV). These funds are the last line of defense against bad debt from extreme market events.

---

## **5. System Architecture Map**

This diagram illustrates the flow of value and interaction between the core components of the unxversal ecosystem.

```
┌─────────────────────────────────────────── Sui network ────────────────────────────────────────────┐
│                                                                                                   │
│          ┌─────────────┐      DeepBook       ┌─────────────┐                                      │
│          │  Spot DEX   │ ─────────▲─────────▶ │  Perps/Futs │  (fill events)                       │
│          └─────────────┘          │           └─────────────┘                                      │
│                ▲                 RFQ                ▲                                              │
│                │    RFQ swap ─────┴─────▶ fee_sink  │                                              │
│                │                        (asset→UNXV)│                                              │
│  Wallet / SDK  │                                     │                                              │
│    (users)     ▼                                     │                                              │
│        ┌──────────────────┐          UNXV            │                                              │
│        │ Cross-Margin ACCT│──────────────────────────┴─────┐                                        │
│        └──────────────────┘                                │                                        │
│           ▲        ▲     ▲                                ▼                                        │
│           │        │     │                        ┌────────────┐                                   │
│           │        │     │                        │Insurance(s)│  (Perps • Lend • Synth)           │
│           │        │     │                        └────────────┘                                   │
│           │        │     │                                ▲                                        │
│   Lend ◄──┘        │     └──► Synth Vault  ◄──────────────┘                                        │
│                    │                                                                       UNXV fees│
│                    └──── Liquidation Engines ────┐                                                  │
│                                                  ▼                                                  │
│                                        ┌─────────────────┐                                          │
│                                        │ Treasury (UNXV) │                                          │
│                                        └────────┬────────┘                                          │
│                                                 ▽                                                   │
│       Oracle-Gas Vault◄───70 % fees  buy&burn / buy&lock  DAO spending                               │
└───────────────────────────────────────────────────────────────────────────────────────────────────────┘
```
