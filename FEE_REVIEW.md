# UnXversal Protocols: Tokenomics, Fees, and UNXV Rewards Review

---

## Global UNXV Tokenomics
- **Total Supply:** 1,000,000,000 UNXV (1B)
- **Founding Team:** 30% (300,000,000 UNXV)
- **Initial Airdrop:** 30% (300,000,000 UNXV)
- **Community/Protocol Incentives:** 40% (400,000,000 UNXV)
- **DAO/Treasury:** None (no DAO, no treasury)
- **UNXV Utility:** Fee discounts, protocol rewards, liquidity mining, performance boosts, exclusive access, and burning/deflation.

---

## Summary Table: Fees, Rewards, and UNXV Usage by Protocol

| Protocol         | Fee Structure / %         | UNXV Discount/Reward | Burning/Deflation | Notes |
|------------------|--------------------------|----------------------|-------------------|-------|
| Synthetics       | Mint/burn at oracle price; protocol fees on mint/burn (variable, e.g. 0.1-0.5%) | Fee discounts for UNXV holders; protocol fees can be paid in UNXV | Yes, protocol fees can be converted to UNXV and burned | Only admin can list synths |
| Lending          | Interest, liquidation, and protocol fees (variable, e.g. 0.1-0.5%) | Fee discounts for UNXV holders; protocol fees can be paid in UNXV | Yes, protocol fees can be converted to UNXV and burned | Only admin can list assets |
| DEX (Spot)       | Trading fee: 0.3% (30 bps); routing fee: 0.1% (10 bps); maker rebate: 0.05% (5 bps); max fee: 1% | 20% discount for UNXV payments | Yes, UNXV used for fee payment is burned | Only admin can add pools |
| AutoSwap         | Swap fee: 0.1% (10 bps); UNXV discount: 50% | 50% discount for UNXV holders on swap fees | Yes, all protocol fees ultimately converted to UNXV and burned | Only admin can add assets/pools |
| Perpetuals       | Maker fee: -0.025% (rebate); taker fee: 0.075%; funding fee; liquidation penalty: 5% | UNXV discounts for both maker/taker; higher tiers for stakers | Yes, protocol fees can be converted to UNXV and burned | Only admin can add markets |
| Options          | Protocol fee on premium (variable, e.g. 0.1-0.5%); exercise/settlement fees | Fee discounts for UNXV holders; premium/settlement fees can be paid in UNXV | Yes, protocol fees can be converted to UNXV and burned | Permissionless market creation |
| Dated Futures    | Trading fee: variable (e.g. 0.1-0.5%); settlement fee | Fee discounts for UNXV holders; protocol fees can be paid in UNXV | Yes, protocol fees can be converted to UNXV and burned | Permissionless, min interval |
| Gas Futures      | Trading fee: variable (e.g. 0.1-0.5%); settlement fee | Fee discounts for UNXV holders; protocol fees can be paid in UNXV | Yes, protocol fees can be converted to UNXV and burned | Permissionless, min interval |
| Liquidity        | Performance/withdrawal fees: variable; IL protection premium; yield optimization fees | UNXV boosts: trading fee share, yield, IL protection discount, priority withdrawal, advanced analytics | Yes, protocol fees can be converted to UNXV and burned | Permissionless, unified protocol |
| Trader Vaults    | Performance fee: default 10% (configurable 5-25%); no management fee; withdrawal fee: variable | UNXV boosts: fee discounts, advanced analytics, priority access, higher profit share for stakers | Yes, protocol fees can be converted to UNXV and burned | Permissionless |

---

## Fee Types and Configuration Table

> **Note:** All fees and bot rewards are protocol parameters configured at deployment (not hard-coded in the Move source). Fees and rewards can be updated via governance or admin controls as specified in MOVING_FORWARD.md. The values below are typical defaults or expected ranges, but actual values may differ per deployment or upgrade. Maintenance fees, maker/taker fees, rebates, and bot rewards are all protocol parameters and can be set per market. **All bot rewards are paid as a percentage of collected fees, not as a fixed UNXV amount.**

| Protocol         | Fee Type / Bot Reward     | Default / Typical Value      | Fee Breakdown (Burn/Bot/Other)                | Range / Notes                                 |
|------------------|--------------------------|-----------------------------|-----------------------------------------------|-----------------------------------------------|
| Synthetics       | Mint/Burn Fee            | 0.1% - 0.5%                 | 80% burned / 20% to automation bot            | Protocol parameter; paid on mint/burn         |
|                  | Maintenance Fee          | 1% - 5% annualized           | 80% burned / 20% to automation bot            | Protocol parameter; paid by synth holders, accrued to protocol/stakers |
|                  | Liquidation Fee/Reward   | 0.5% - 2%                   | 80% burned / 20% to liquidation bot           | Paid to liquidator bot; protocol parameter    |
| Lending          | Interest Rate            | Variable (market-driven)     | 80% burned / 20% to automation bot            | Protocol sets base rates, can be dynamic      |
|                  | Protocol Fee             | 0.1% - 0.5%                 | 80% burned / 20% to automation bot            | On interest/borrow, paid to protocol          |
|                  | Liquidation Fee/Reward   | 5% - 10%                     | 80% burned / 20% to liquidation bot           | Split between liquidator bot and protocol     |
| DEX (Spot)       | Trading Fee              | 0.3% (30 bps)                | 80% burned / 20% to automation bot            | Protocol parameter; default industry standard |
|                  | Routing Fee              | 0.1% (10 bps)                | 80% burned / 20% to automation bot            | For cross-asset trades                        |
|                  | Maker Rebate             | 0.05% (5 bps)                | 100% to maker (rebate)                        | Paid to makers; can be negative fee           |
|                  | Max Fee                  | 1%                           | 80% burned / 20% to automation bot            | Hard cap on total fee                         |
| AutoSwap         | Swap Fee                 | 0.1% (10 bps)                | 80% burned / 20% to automation bot            | Protocol parameter; can be dynamic            |
|                  | UNXV Discount            | 50%                          | 80% burned / 20% to automation bot            | For UNXV payments                             |
| Perpetuals       | Maker Fee                | -0.025% (rebate)             | 100% to maker (rebate)                        | Paid to makers; can be negative fee           |
|                  | Taker Fee                | 0.075%                       | 80% burned / 20% to automation bot            | Protocol parameter                            |
|                  | Funding Fee              | Variable (market-driven)     | 80% burned / 20% to automation bot            | Calculated per funding interval               |
|                  | Liquidation Penalty/Reward| 5%                           | 40% to liquidation bot / 10% insurance / 50% burned | 40% to liquidator bot, 10% insurance, 50% protocol |
| Options          | Protocol Fee (Premium)   | 0.1% - 0.5%                  | 80% burned / 20% to market creation bot       | On option premium; protocol parameter         |
|                  | Exercise/Settlement      | 0.1% - 0.5%                  | 80% burned / 20% to settlement bot            | On exercise/settlement; protocol parameter    |
|                  | Maker Fee/Rebate         | -0.025% to 0%                | 100% to maker (rebate)                        | Protocol parameter; paid to makers            |
|                  | Taker Fee                | 0.05% - 0.1%                 | 80% burned / 20% to automation bot            | Protocol parameter; paid by takers            |
| Dated Futures    | Trading Fee              | 0.1% - 0.5%                  | 80% burned / 20% to market creation bot       | Protocol parameter                            |
|                  | Settlement Fee           | 0.1% - 0.5%                  | 80% burned / 20% to settlement bot            | Protocol parameter                            |
|                  | Maker Fee/Rebate         | -0.025% to 0%                | 100% to maker (rebate)                        | Protocol parameter; paid to makers            |
|                  | Taker Fee                | 0.05% - 0.1%                 | 80% burned / 20% to automation bot            | Protocol parameter; paid by takers            |
| Gas Futures      | Trading Fee              | 0.1% - 0.5%                  | 80% burned / 20% to market creation bot       | Protocol parameter                            |
|                  | Settlement Fee           | 0.1% - 0.5%                  | 80% burned / 20% to settlement bot            | Protocol parameter                            |
|                  | Maker Fee/Rebate         | -0.025% to 0%                | 100% to maker (rebate)                        | Protocol parameter; paid to makers            |
|                  | Taker Fee                | 0.05% - 0.1%                 | 80% burned / 20% to automation bot            | Protocol parameter; paid by takers            |
| Liquidity        | Performance Fee          | 0% - 20%                      | 80% burned / 20% to automation bot            | Set by vault/strategy; protocol parameter     |
|                  | Withdrawal Fee           | 0% - 1%                       | 80% burned / 20% to automation bot            | Set by vault/strategy; protocol parameter     |
|                  | IL Protection Premium    | Variable                      | 80% burned / 20% to automation bot            | Based on coverage, set by protocol            |
|                  | Yield Optimization Fee   | Variable                      | 80% burned / 20% to automation bot            | Based on strategy, set by protocol            |
| Trader Vaults    | Performance Fee          | 10% (default, 5-50% allowed)  | 80% burned / 20% to automation bot            | High water mark; set by manager within range  |
|                  | Withdrawal Fee           | 0% - 1%                       | 80% burned / 20% to automation bot            | Set by vault/manager; protocol parameter      |

- **All fees and bot rewards above are protocol parameters, not hard-coded.**
- **Fee and reward changes require governance/admin action and are transparent on-chain.**
- **UNXV discounts, boosts, and burning apply as described in the summary table and protocol details.**

---

## Protocol-by-Protocol Details

### 1. Synthetics
- **Mint/Burn Fees:** Protocol fee on minting/burning synthetic assets (e.g. 0.1-0.5%)
- **Maintenance Fee:** 1-5% annualized, paid by synth holders
- **Liquidation Fee/Reward:** 0.5-2% paid to liquidator bot (protocol parameter)
- **UNXV Usage:**
  - Fee discounts for UNXV holders
  - Protocol fees can be paid in UNXV
  - All protocol fees ultimately converted to UNXV and burned (deflationary)
- **Rewards:** Liquidation bots are rewarded from liquidation fees

### 2. Lending
- **Interest/Liquidation Fees:** Protocol fee on interest and liquidation (e.g. 0.1-0.5%)
- **Liquidation Fee/Reward:** 5-10% split between liquidator bot and protocol
- **UNXV Usage:**
  - Fee discounts for UNXV holders
  - Protocol fees can be paid in UNXV
  - All protocol fees ultimately converted to UNXV and burned
- **Rewards:** Liquidation bots are rewarded from liquidation fees

### 3. DEX (Spot)
- **Trading Fee:** 0.3% (30 bps) base
- **Routing Fee:** 0.1% (10 bps) for cross-asset trades
- **Maker Rebate:** 0.05% (5 bps)
- **Max Fee:** 1%
- **UNXV Usage:**
  - 20% discount for UNXV payments (i.e. pay trading fees in UNXV)
  - UNXV used for fee payment is burned (deflationary)
- **Rewards:** Maker rebates, trading volume analytics, UNXV boosts for LPs

### 4. AutoSwap
- **Swap Fee:** 0.1% (10 bps) base
- **UNXV Discount:** 50% for UNXV holders
- **UNXV Usage:**
  - All protocol fees ultimately converted to UNXV and burned
  - UNXV holders get priority processing, advanced features, and fee discounts
- **Rewards:** None specified beyond fee discounts

### 5. Perpetuals
- **Maker Fee:** -0.025% (rebate)
- **Taker Fee:** 0.075%
- **Funding Fee:** Dynamic, based on market conditions
- **Liquidation Penalty/Reward:** 5% (40% to liquidator bot, 10% to insurance fund, 50% to protocol)
- **UNXV Usage:**
  - Discounts for both maker/taker (higher tiers for stakers)
  - Protocol fees can be paid in UNXV and are burned
- **Rewards:** Liquidation bots are rewarded from liquidation penalty

### 6. Options
- **Protocol Fee:** On premium (e.g. 0.1-0.5%)
- **Exercise/Settlement Fees:** Variable
- **Maker Fee/Rebate:** -0.025% to 0% (protocol parameter)
- **Taker Fee:** 0.05% to 0.1% (protocol parameter)
- **Market Creation Reward:** Variable (e.g., 1-10 UNXV) paid to bot for creating new market
- **Settlement Reward:** Variable (e.g., 0.5-2 UNXV) paid to bot for settling expiring contracts
- **UNXV Usage:**
  - Fee discounts for UNXV holders
  - Premium/settlement fees can be paid in UNXV
  - All protocol fees ultimately converted to UNXV and burned
- **Rewards:** Market creation and settlement bots are rewarded in UNXV

### 7. Dated Futures
- **Trading Fee:** Variable (e.g. 0.1-0.5%)
- **Settlement Fee:** Variable
- **Maker Fee/Rebate:** -0.025% to 0% (protocol parameter)
- **Taker Fee:** 0.05% to 0.1% (protocol parameter)
- **Market Creation Reward:** Variable (e.g., 1-10 UNXV) paid to bot for creating new market
- **Settlement Reward:** Variable (e.g., 0.5-2 UNXV) paid to bot for settling expiring contracts
- **UNXV Usage:**
  - Fee discounts for UNXV holders
  - Protocol fees can be paid in UNXV
  - All protocol fees ultimately converted to UNXV and burned
- **Rewards:** Market creation and settlement bots are rewarded in UNXV

### 8. Gas Futures
- **Trading Fee:** Variable (e.g. 0.1-0.5%)
- **Settlement Fee:** Variable
- **Maker Fee/Rebate:** -0.025% to 0% (protocol parameter)
- **Taker Fee:** 0.05% to 0.1% (protocol parameter)
- **Market Creation Reward:** Variable (e.g., 1-10 UNXV) paid to bot for creating new market
- **Settlement Reward:** Variable (e.g., 0.5-2 UNXV) paid to bot for settling expiring contracts
- **UNXV Usage:**
  - Fee discounts for UNXV holders
  - Protocol fees can be paid in UNXV
  - All protocol fees ultimately converted to UNXV and burned
- **Rewards:** Market creation and settlement bots are rewarded in UNXV

### 9. Liquidity (Unified Protocol)
- **Performance/Withdrawal Fees:** Variable, set by vault/strategy
- **IL Protection Premium:** Variable, based on coverage
- **Yield Optimization Fees:** Variable, based on strategy
- **UNXV Usage:**
  - Trading fee share boost (0-40% by tier)
  - Yield optimization access, IL protection discount (up to 70% by tier)
  - Priority withdrawal, advanced analytics, custom strategy access for higher tiers
  - All protocol fees ultimately converted to UNXV and burned
- **Rewards:** Automation bots (rebalancing, optimization) can be rewarded from performance/yield fees or UNXV boosts

### 10. Trader Vaults
- **Performance Fee:** Default 10% (configurable 5-50%, high water mark)
- **Withdrawal Fee:** Variable, set by vault
- **UNXV Usage:**
  - Fee discounts for stakers
  - Advanced analytics, priority access, higher profit share for stakers
  - All protocol fees ultimately converted to UNXV and burned
- **Rewards:** Automation bots (strategy execution, reporting) can be rewarded from performance fees or UNXV boosts

---

## UNXV Deflation and Rewards Mechanisms
- **Fee Burning:** All protocol fees (from trading, swaps, mint/burn, performance, etc.) are ultimately converted to UNXV and burned, creating deflationary pressure.
- **Discounts:** UNXV holders receive fee discounts across all protocols (20-50% typical, up to 70% for IL protection).
- **Boosts:** UNXV stakers receive trading fee share boosts, yield optimization access, priority withdrawal, advanced analytics, and exclusive features.
- **No DAO/Treasury:** All protocol rewards and incentives are distributed directly to users, managers, and LPs; no treasury or DAO allocation.

---

## References
- All numbers, percentages, and values are based on the latest markdown documentation for each protocol and [MOVING_FORWARD.md](./MOVING_FORWARD.md).
- For implementation details, always reference the protocol markdowns and MOVING_FORWARD.md. 