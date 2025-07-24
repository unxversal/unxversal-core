# UnXversal Protocols: Bots, Automation, and Incentives

---

## Overview

UnXversal protocols rely on a set of off-chain bots and automation services to keep the system healthy, permissionless, and fully functional. These bots are run by users, node operators, or third parties, and are incentivized through protocol rewards (including UNXV) and/or direct protocol fees. This document outlines the required bots, their roles, and the incentive mechanisms for running them.

---

## Types of Bots and Their Roles

### 1. Liquidation Bots
- **Role:** Monitor lending, synthetics, perps, and other protocols for undercollateralized or unhealthy positions. Trigger liquidations to prevent bad debt and maintain protocol solvency.
- **Incentive:** Liquidation reward/fee (e.g., 5-10% of liquidated value, split between liquidator and protocol/insurance fund). Paid directly in protocol assets or via AutoSwap.
- **Notes:**
  - Liquidation rewards are protocol parameters (see FEE_REVIEW.md).
  - Anyone can run a liquidation bot; competition ensures timely liquidations.

### 2. Market Creation Bots (Derivatives)
- **Role:** Automatically create new markets for permissionless derivatives (options, dated futures, gas futures) at required intervals (e.g., daily, weekly, monthly). Ensure that markets for all supported assets and expiries always exist.
- **Incentive:** UNXV mining/reward for creating new markets ("market mining"). First to create a valid market for a given asset/expiry receives a fixed or variable UNXV reward.
- **Notes:**
  - User running the bot pays the gas for market creation.
  - Rewards are distributed on a first-come, first-served basis, but protocol can enforce minimum intervals and anti-spam measures.
  - This mechanism ensures the network is always up-to-date and permissionless.

### 3. Oracle/Price Update Bots
- **Role:** Submit or relay price/oracle updates (if required for certain protocols, e.g., custom or fallback oracles, or for gas price reference in gas futures).
- **Incentive:** Optional UNXV reward for timely, accurate updates (if not handled by external oracles like Pyth).
- **Notes:**
  - Most price feeds are handled by Pyth or similar, but fallback or custom oracles may require bot relays.

### 4. Settlement Bots
- **Role:** Trigger settlement for expiring contracts (dated futures, gas futures, options, etc.), process daily mark-to-market, and ensure timely settlement and payout.
- **Incentive:** UNXV reward or protocol fee for settling contracts (can be a small fixed fee or a share of protocol fees).
- **Notes:**
  - Settlement is permissionless; anyone can run a settlement bot.
  - Protocol can enforce minimum intervals and anti-spam measures.

### 5. Automation Bots (Generalized)
- **Role:** Automate protocol functions such as rebalancing liquidity pools, executing automated trading strategies, harvesting yield, and optimizing cross-protocol positions.
- **Incentive:**
  - Direct protocol rewards (e.g., share of yield optimization fees, performance fees, or UNXV boosts).
  - Indirect benefit to users running their own automation (e.g., improved returns, reduced risk).
- **Notes:**
  - Users can run their own bots or opt-in to third-party automation.

### 6. Indexer/Analytics Bots
- **Role:** Index protocol events, provide analytics, dashboards, and real-time monitoring for users and the frontend.
- **Incentive:** No direct protocol reward, but essential for ecosystem health and user experience.

---

## Incentive Mechanisms and Nuances

- **Liquidation Rewards:** Paid directly from protocol fees; highly competitive, so rewards are typically sufficient.
- **Market Mining (Derivatives):** UNXV rewards for creating new markets; protocol can set reward size, frequency, and anti-spam rules. Gas is paid by the bot operator.
- **Settlement Rewards:** Small UNXV or protocol fee for settling contracts; ensures timely settlement and prevents stuck markets.
- **Oracle/Price Update Rewards:** Optional, only if protocol requires custom/fallback oracles.
- **Automation/Optimization Rewards:** Share of performance/yield optimization fees, or UNXV boosts for running automation.
- **Anti-Spam/Abuse:**
  - Minimum intervals for market creation/settlement.
  - Protocol can slash or withhold rewards for spam or malicious activity.
  - All actions are transparent and auditable on-chain.

---

## Recommendations for Additional Bots or Incentives

- **Insurance/Rescue Bots:** Monitor for protocol emergencies (e.g., stuck liquidations, failed settlements) and trigger emergency procedures. Could be rewarded with UNXV or protocol fees.
- **Governance Bots:** Automate proposal submission, voting reminders, and parameter updates (if/when community governance is enabled).
- **Community/Analytics Bots:** Provide open dashboards, alerts, and analytics to improve transparency and user experience.

---

## Implementation Notes
- All bot incentives and rewards are protocol parameters and can be updated via governance/admin controls.
- Bot operators must pay gas for their actions; rewards are designed to cover costs and provide additional incentive.
- All bot actions are permissionless and open to anyone; competition ensures protocol health and decentralization.
- For fee/reward values, see FEE_REVIEW.md and MOVING_FORWARD.md.

---

## Conclusion

Bots and automation are essential for the health, permissionlessness, and robustness of the UnXversal ecosystem. By incentivizing users to run liquidation, market creation, settlement, oracle, and automation bots, the protocol ensures that all critical functions are decentralized, timely, and sustainable. This document serves as a reference for contributors, node operators, and protocol designers. 