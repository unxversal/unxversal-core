# fees.md — Unified fee grid (all values in **UNXV** after swap)

Every protocol action pays in the transacting asset → auto–RFQ-swapped on DeepBook → routed per the table below.

| #     | Protocol / Action               | Default rate                 | Swap path (asset → UNXV) | Split after swap                                      | Governance bounds\* |
| ----- | ------------------------------- | ---------------------------- | ------------------------ | ----------------------------------------------------- | ------------------- |
| **1** | **Spot DEX** taker fill         | **6 bps** of filled notional | `fee_sink::dex`          | 60 % Relayer† · 40 % Treasury                         | ±2 bps              |
| 2     | Synth **mint**                  | **15 bps** of USD value      | `fee_sink::mintburn`     | 70 % Oracle-gas vault · 30 % Treasury                 | ±5 bps              |
| 3     | Synth **burn**                  | **8 bps**                    | same as above            | 100 % Treasury                                        | ±5 bps              |
| 4     | Synth **liquidation penalty**   | **12 %** of debt repaid      | —                        | 50 % Liquidator · 30 % Surplus buffer · 20 % Treasury | lower-only (fast)   |
| 5     | **Lend** interest reserve       | **12 %** of interest accrued | `fee_sink::reserve`      | 50 % ve-lock(4 y) · 50 % Treasury                     | ≤ 20 %              |
| 6     | Lend **flash-loan** fee         | **8 bps**                    | same                     | 80 % Treasury · 20 % Flash-rebate pool                | ±4 bps              |
| 7     | Lend **liquidation penalty**    | **10 %** of debt             | —                        | 60 % Liquidator · 25 % Lend-insurance · 15 % Treasury | lower-only          |
| 8     | **Perps** taker fill            | **10 bps**                   | `fee_sink::perps`        | 50 % Perps-insurance · 30 % Burn · 20 % Treasury      | ±2 bps              |
| 9     | Perps **funding skim**          | **10 %** of gross funding    | same                     | 100 % Perps-insurance                                 | 5–15 %              |
| 10    | Perps **liquidation penalty**   | 1.5–2.5 % by market          | —                        | 70 % Liquidator · 30 % Perps-insurance                | lower-only          |
| 11    | **Futures** taker fill          | **5 bps** (majors)           | `fee_sink::futures`      | 60 % Burn · 40 % Treasury                             | ±2 bps              |
| 12    | Futures **liquidation penalty** | 1 %                          | —                        | 70 % Liquidator · 30 % Insurance                      | fixed               |
| 13    | **Options** premium fee         | **15 bps** (majors)          | `fee_sink::options`      | 60 % Burn · 40 % Treasury                             | ±3 bps              |
| 14    | Options **writer liquidation**  | 2–4 %                        | —                        | 80 % Insurance · 20 % Treasury                        | lower-only          |
| 15    | **DEX maker spam-guard**        | **0.2 USDC** flat            | swapped on arrival       | 100 % Treasury                                        | ±0.1                |

<sup>† Relayer slice routes 100 % to Treasury if taker omits `relayer_addr`.<br>
\*All rate changes go through Governor ➜ Timelock (48 h). “Lower-only” items may be cut instantly by Pause Guardian but can **never** be raised without full vote.</sup>

---

## Routing logic (pseudo)

```move
fn on_fee(asset: Coin, bp: u64, route: FeeRoute) {
    let unxv_amount =
        if asset.type != UNXV {
            deepbook::rfq_swap(asset, UNXV, slippage ≤ 1%)
        } else { asset }
    }
    distribute(unxv_amount, route);       // percentages per table
}
```

All swaps revert if TWAP-guard detects > 1 % slippage versus Pyth price.

---

## Treasury & insurance thresholds

| Pool                               | Target                    | Excess handling                                    |
| ---------------------------------- | ------------------------- | -------------------------------------------------- |
| **Oracle-gas vault**               | 6 months Pyth + L0 runway | auto-sends overflow to Treasury                    |
| **Perps / Lend / Synth insurance** | 5 % of respective TVL     | stream excess to Treasury each epoch               |
| **Treasury liquid UNXV**           | 24-month ops runway       | surplus triggers buy-and-burn or buy-and-lock vote |

---

## Parameter governance quick-chart

| What can move?                       | Envelope               | Who / How fast                     |
| ------------------------------------ | ---------------------- | ---------------------------------- |
| Fee **rates**                        | As “Governance bounds” | Governor proposal → 48 h timelock  |
| **Splits** between sub-pools         | ±10 % per slice        | Same as above                      |
| **Slippage guard**                   | 0.5–2 %                | Guardian lower-only; raise via DAO |
| **Thresholds** (insurance %, runway) | 3–10 % / 6–36 m        | DAO                                |

---

### TL;DR

* One table, one swap path, one token: **all roads lead to UNXV**.
* Relayers, liquidators, oracle gas, insurance, Treasury and burn all get their slices automatically.
* Every knob is timelocked and—where safety-critical—can only be **lowered** instantly, never raised without community consent.