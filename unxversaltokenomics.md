# **unxversal tokenomics – UNXV on Sui**

---

## 1 · Hard-capped supply

| Item               | Amount                 | Notes                                                                                        |
| ------------------ | ---------------------- | -------------------------------------------------------------------------------------------- |
| **Maximum supply** | **1 000 000 000 UNXV** | Immutable `U64` in the Move `Supply` resource                                                |
| **Decimals**       | 9                      | Matches Sui convention                                                                       |
| **Mint authority** | Burned at genesis      | All genesis buckets minted in a single `initialise()` call, then the capability is destroyed |

---

## 2 · Genesis allocation & vesting

| Bucket                                          | %         | Tokens  | Unlock schedule                                          | Rationale                                            |
| ----------------------------------------------- | --------- | ------- | -------------------------------------------------------- | ---------------------------------------------------- |
| Founders & core contributors                    | **30 %**  | 300 M   | 12-month cliff → linear 48 m vest (Move `VestingEscrow`) | No VC round, so founders carry larger execution risk |
| Community incentives (liquidity & usage gauges) | **30 %**  | 300 M   | Streaming emissions (see §4)                             | Rewards DeepBook makers, volume, borrow/minters      |
| DAO Treasury                                    | 15 %      | 150 M   | Unlocked; governed by Timelock                           | Grants, audits, insurance top-ups                    |
| Ecosystem & integrations                        | 10 %      | 100 M   | 6-month cliff → 36 m linear                              | Market-maker loans, cross-chain deployments          |
| Protocol-owned liquidity (POL)                  | 10 %      | 100 M   | 50 % paired with USDC in a DAO LP, LP tokens 24 m lock   | Deep UNXV/USDC book from day 1                       |
| Early user airdrop                              | 3 %       | 30 M    | 12-month claim, unclaimed burns                          | Align beta testers & white-hat bug hunters           |
| **Total**                                       | **100 %** | **1 B** | —                                                        | —                                                    |

---

## 3 · Fee capture & value flow

**Every protocol fee is denominated in the asset being transacted → instantly market-swapped to UNXV → routed as below:**

| Stream                       | Default split                                    | Mechanism (Move module)                                  |
| ---------------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| **Spot taker fee (6 bps)**   | 60 % relayer / 40 % FeeSink                      | DeepBook passes `takerFeeObject` to `fee_sink.deposit()` |
| **Perps taker fee (10 bps)** | 50 % Perps-insurance / 30 % burn / 20 % Treasury | Auto-swap via DeepBook RFQ, then routed                  |
| **Synth mint (15 bps)**      | 70 % Oracle gas vault / 30 % Treasury            | `vault.mint()` triggers swap-and-route                   |
| **Borrow reserve (12 %)**    | 50 % buy-and-**lock** in veUNXV / 50 % Treasury  | `lend_pool.accrueInterest()` mints & locks               |
| **Liquidation penalties**    | 60 % liquidator / 40 % burn                      | Paid out post-swap in `liquidate()`                      |

*All percentages **governable** inside a ±10 % envelope, 48 h timelock.*

---

## 4 · Emission schedule (community incentives)

A six-year, hyperbolic decay that avoids an abrupt cliff:

| Year      | UNXV emitted | Notes                                                       |
| --------- | ------------ | ----------------------------------------------------------- |
| **0 → 1** | **80 M**     | Kick-start DeepBook liquidity & testnet → mainnet migration |
| 1 → 2     | 60 M         | 25 % cut                                                    |
| 2 → 3     | 45 M         | 25 % cut                                                    |
| 3 → 4     | 35 M         | 22 % cut                                                    |
| 4 → 5     | 25 M         | 29 % cut                                                    |
| 5 → 6     | 15 M         | Tail emissions keep gauges alive                            |
| **Total** | **260 M**    | Remainder of the 300 M bucket is a DAO budget buffer        |

*Block-by-block drip → weekly **GaugeController** vote (ve-weighted) decides share across: Spot, Synth, Lend, Perps, Futures, Options.*

---

## 5 · ve-UNXV mechanics

| Parameter      | Value                                                             |
| -------------- | ----------------------------------------------------------------- |
| Lock range     | **1 – 4 years**                                                   |
| Voting power   | `ve = UNXV_locked × lock_time / 4 y` (linear)                     |
| Emission boost | Up to **2×** on farming gauges                                    |
| Early exit     | Not allowed; can **rage-quit** by paying 50 % penalty to Treasury |
| Delegation     | Any address; default delegate = locker                            |

The ve-resource is a **Move object** owned by the locker; voting checkpoints stored per epoch for cheap snapshot reads.

---

## 6 · UNXV utilities

1. **Governance** – propose & vote on DAO motions (only ve-holders).
2. **Fee rebates** – DeepBook takers holding ≥ 1 % ve-share get 25 % fee kick-back.
3. **Collateral** – Accepted in Lend pool at $max\,\text{LTV}=40 \%$.
4. **Staking yield** – Treasury may route a share of surplus fees to ve-boosted staking contract (opt-in by vote).

---

## 7 · Treasury playbook (post-swap UNXV)

| Priority | Action                                   | Trigger                            |
| -------- | ---------------------------------------- | ---------------------------------- |
| 1        | **Insurance top-up**                     | Any pool < 5 % TVL buffer          |
| 2        | **Buy-&-lock** extra UNXV into 4-year ve | Treasury balance > 24-month runway |
| 3        | **Grants & audits**                      | Quarterly Funding Round vote       |
| 4        | **Programmatic burn**                    | Anything above 50 M liquid UNXV    |

All transfers executed by `treasury.execute()` → guarded by Timelock.

---

## 8 · Inflation vs. burn projection (illustrative)

*Assuming 50 M USD annual protocol fees + 40 % routed to burn:*

```
Year-1 net supply change
= +80 M emissions  –  (50 M × 40 % ÷ UNXV_price)

If UNXV ≈ $1.00 → burns 20 M → **+60 M net**
If UNXV ≈ $3.00 → burns 6.7 M → **+73 M net**
```

Protocol can glide towards neutral or deflationary once fee flow ≥ emissions.

---

## 9 · Security levers

* **FeeSink cap** – if swap slippage > 1 %, the tx reverts (oracle sanity check).
* **Emission throttle** – DAO can drop the yearly drip by up to 20 % with a fast-track vote.
* **Guardian kill-switch** – Freeze emissions if a critical exploit drains UNXV.

---

## 10 · TL;DR

* **1 B hard-cap** – no hidden mints.
* **All fees bought into UNXV**, then burned, locked, or sent to Treasury.
* Six-year incentive schedule front-loads liquidity but decays fast.
* ve-locking governs everything and earns fee rebates plus boosted emissions.
* A flexible Treasury loop lets the DAO toggle between burn, lock, and growth spending as protocol revenue scales.