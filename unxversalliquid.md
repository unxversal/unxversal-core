# **unxversal Liquid — sSUI liquid-staking layer**

A yield-bearing wrapper that turns locked SUI stake into a transferable, DeFi-ready coin (**sSUI**).
Stakers earn base-layer rewards **and** can supply, margin, LP, or hedge with the same asset across every unxversal venue.
A 5 % skim on staking yield is auto-swapped into **UNXV**—50 % burned, 50 % to Treasury—keeping the flywheel humming.

---

## 1 · Why build it inside unxversal?

| Value                       | Detail                                                                                                         |
| --------------------------- | -------------------------------------------------------------------------------------------------------------- |
| **Native yield collateral** | Lend, Perps, Options accept sSUI at 90 % LTV—users earn while they trade.                                      |
| **New fee stream → UNXV**   | 5 % of staking rewards converts to UNXV each epoch, half burned.                                               |
| **TVL magnet**              | Liquid SUI stake typically grows to ≥ 30 % chain supply; plugs straight into LP Vaults and DeepBook liquidity. |
| **Validator leverage**      | DAO can allocate treasury-held UNXV/SUI to a validator set it controls, capturing commission.                  |

---

## 2 · High-level architecture

```
User SUI
   │deposit
   ▼
┌─────────────────────────┐
│  stakepool::vault       │   delegates ▲
│  (holds SUI + meta)     │─────────────┘
└────────┬───────────────┘
         │ mint/rebase
         ▼
   sSUI ERC-20 coin           (9-decimal, rebase daily)
         │
         │ trade / lend / margin
         ▼
fee_sink::lstake  (5 % of rewards each epoch)
         │
    swap→UNXV on DeepBook
  50 % burn   ·   50 % Treasury
```

---

## 3 · Module map (Move)

| Module             | Resource / Object         | Purpose                                                          |
| ------------------ | ------------------------- | ---------------------------------------------------------------- |
| `lstake::vault`    | `StakePool`, `StakeBatch` | Collect deposits, queue withdrawals, track validator weights     |
| `lstake::coin`     | `sSUI` (ERC-20)           | Rebase token; 1 sSUI ≈ 1 SUI at deposit, supply grows with yield |
| `lstake::oracle`   | —                         | Tracks validator performance; slashing alerts                    |
| `lstake::govern`   | —                         | Add/remove validators, tweak fee rate, pause                     |
| `fee_sink::lstake` | —                         | Epoch swap of reward skim → UNXV                                 |

---

## 4 · User flows

| Action            | Steps                                                         | Fees                 |
| ----------------- | ------------------------------------------------------------- | -------------------- |
| **Stake**         | `deposit(amount)` → receive sSUI at current `exchangeRate`.   | None                 |
| **Unstake**       | `request_unstake(amount)` → 2-epoch unbond queue → `claim()`. | None                 |
| **Instant exit**  | Sell sSUI/SUI on DeepBook—spread ≤ 0.3 %.                     | DeepBook taker 6 bps |
| **Auto-compound** | Rebase each epoch; wallet balances grow—no tx needed.         | 5 % skim → UNXV      |

---

## 5 · Fee & rebase math

```
epochReward = total_staked × validator_APY × epoch_len
skim        = epochReward × 5 %
pool_gain   = epochReward − skim
exchangeRate_new = (total_staked + pool_gain) / sSUI_supply
```

`skim` is transferred to fee\_sink→swap→UNXV, split burn/treasury.

---

## 6 · Risk controls

| Risk                | Mitigation                                                                      |
| ------------------- | ------------------------------------------------------------------------------- |
| Validator slashing  | Diverse whitelist; max 15 % stake per validator; health oracle auto-rebalances. |
| Smart-contract bug  | Audit, 48 h timelock on upgrades, pause guardian.                               |
| De-peg (sSUI < SUI) | Arbitrage via DeepBook; DAO market-makes if spread > 1 %.                       |
| Liquidity crunch    | Unstake queue max 2 epochs; AMM overlay on DeepBook seeds 24-hr liquidity pool. |

Insurance: 10 % of Treasury’s burned-share UNXV is diverted to a “Slash Fund” until it covers 1 % of total stake.

---

## 7 · Integration quick-wins

| Venue               | How sSUI is used                                               |
| ------------------- | -------------------------------------------------------------- |
| **Lend**            | Market listed day-1; collateralFactor = 90 %.                  |
| **Perps / Futures** | Accepted as margin, exchange-rate updated hourly via oracle.   |
| **LP Vaults**       | Launch a “sSUI range-maker” vault—stake + earn trading fees.   |
| **Synths**          | Mint `sSUIx` synth for synthetic leveraged staking strategies. |

---

## 8 · Governance knobs

| Param                | Default            | Bounds | Change path         |
| -------------------- | ------------------ | ------ | ------------------- |
| Reward skim          | 5 %                | 0–10 % | Governor + Timelock |
| Validator set size   | 10                 | 5–20   | Same                |
| Unstake queue epochs | 2                  | 1–4    | Same                |
| Pause staking        | Guardian (instant) | —      | Unpause via DAO     |

---

## 9 · Launch checklist

1. **Audit stakepool & rebase math** (share libs with vault\_core).
2. Deploy with 5 validators (2 community, 3 DAO-run).
3. Seed DeepBook `sSUI/SUI` range-AMM with 250 k SUI from Treasury.
4. List sSUI in **Lend**; set collateralFactor = 90 %.
5. Add sSUI to GUI dashboard with live APY & exchange-rate charts.

---

## 10 · TL;DR

*unxversal Liquid* tokenises SUI stake into **sSUI**—a rebasing, transferable coin you can trade, leverage, or LP while still earning network yield.
A 5 % reward skim feeds the UNXV burn-and-Treasury loop, validator risk is diversified and insured, and the entire module plugs straight into Lend, Perps, and Options on day 1.