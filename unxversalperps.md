# perps.md — Cross-margin perpetual futures on **Sui**

Trade BTC, ETH, any **sAsset**, or top Pyth-priced coins with up to **20× leverage**.
Matching happens on **DeepBook**; all risk & funding are handled by an on-chain **Clearing House**.
Every taker fee and funding skim is swapped into **UNXV**, seeding the perps insurance fund and the broader value loop.

---

## 1 · Module map (Move)

| Module               | Resource / Object                                           | Responsibility                                                        |
| -------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------- |
| `perps::market`      | `MarketInfo`                                                | Immutable params (tick size, maxLeverage, maintMargin, fundingCap)    |
| `perps::account`     | `CrossMargin { collateral, pnl, positions<Vec<Position>> }` | One object per trader                                                 |
| `perps::clearing`    | —                                                           | Entry point: `open`, `close`, `add_margin`, `withdraw`, `fill_orders` |
| `perps::funding`     | —                                                           | Funding index accumulator & rate calculator                           |
| `perps::liquidation` | —                                                           | Health test & force-close logic                                       |
| `perps::oracle`      | —                                                           | Pyth mark price + DeepBook index price                                |
| `fee_sink::perps`    | —                                                           | 10 bps taker fee → swap → UNXV → Insurance / Treasury                 |
| `insurance::perps`   | `PerpsInsurance`                                            | Pays bad-debt; lends excess to Lend pool                              |

All markets share **one** collateral token (USDC) plus optional UNXV collateral once DAO whitelists.

---

## 2 · Position struct (packed)

```move
struct Position has copy, drop, store {
    size: i128,           // + long, − short (1e18 base = $1)
    entry_price: u128,    // Q64.64
    last_funding: u128,   // funding index snapshot
}
```

Cross-margin = one `CrossMargin` object per trader; PnL nets across markets.

---

## 3 · Opening / closing flow

```move
// Trader hits a DeepBook perp order (off-chain)
perps::clearing::fill_orders(
    trader,
    orders,          // DeepBook order IDs
    sizes            // notional per order
);
```

For each fill:

1. **Margin check**

   ```
   requiredMargin = notional / maxLev
   assert freeCollateral ≥ requiredMargin
   ```

2. **Position blend**

   ```
   new_size  = old_size ± notional
   entry_px  = (old_size*old_px + Δ*fill_px) / new_size
   ```

3. **Taker fee = 10 bps** of notional → `fee_sink::perps`.

---

## 4 · Funding-rate mechanics

| Symbol                     | Mark price (`P_mark`) | Index price (`P_index`)    |
| -------------------------- | --------------------- | -------------------------- |
| BTC-PERP, ETH-PERP, majors | Pyth 1-min TWAP       | DeepBook spot VWAP (1 min) |
| sAsset underliers          | Pyth synth feed       | DeepBook sAsset/USDC book  |

**Premium** `Δ = (P_mark − P_index) / P_index`

Hourly funding rate:

```
f = clamp(Δ, ±fundingCap)
```

`perps::funding::tick()` bumps `funding_index += f * dt`
When a position changes size or on `settle_funding()` call, trader’s collateral adjusts:

```
fundingPayment = pos.size * (fund_idx_now − pos.last_funding)
collateral    -= fundingPayment
```

**Protocol skim:** 10 % of gross funding flow → `fee_sink::perps`.

---

## 5 · Risk parameters (governance-gated)

| Parameter           | BTC        | ETH        | High-cap alts | sAssets     |
| ------------------- | ---------- | ---------- | ------------- | ----------- |
| `maxLeverage`       | 20×        | 20×        | 10×           | 10×         |
| `maintenanceMargin` | 5 %        | 6 %        | 8 %           | 10 %        |
| `fundingCap`        | 75 bps / h | 75 bps / h | 100 bps / h   | 120 bps / h |
| `liqPenalty`        | 1.5 %      | 1.5 %      | 2.0 %         | 2.5 %       |

All changes: lower-only instant, raise via 48 h Timelock.

---

## 6 · Liquidations

*Health*

```
health = (collateral + unrealisedPnL) / (marginReq)
marginReq = Σ |position_i| / leverageAllowed_i
```

Trigger: `health < 1.0`

Liquidator call:

```move
perps::liquidation::liquidate(
    trader, 
    market_id, 
    max_notional_to_close
);
```

* Closes up to `closeFactor = 50 %` size at `P_mark`.
* Penalty = `liqPenalty × notionalClosed`
* **Reward split**: 70 % liquidator, 30 % Insurance fund (UNXV after swap).

Liquidator may bundle:

```
flashBorrow USDC (Lend) → close perpetual → repay flash
```

---

## 7 · Fee routing & insurance

| Stream                | Split                                                    | Path                             |
| --------------------- | -------------------------------------------------------- | -------------------------------- |
| **Taker fee 10 bps**  | 50 % → Perps Insurance<br>30 % → burn<br>20 % → Treasury | `fee_sink::perps.swap_to_unxv()` |
| **Funding skim 10 %** | 100 % → Perps Insurance                                  | ditto                            |

**Perps Insurance threshold** = 5 % of perps OI (USD).
Excess UNXV lends into **Lend** as supply, earning yield until drawn.

---

## 8 · Integration hooks

| With…        | Benefit to perps                                             | Benefit from perps                              |
| ------------ | ------------------------------------------------------------ | ----------------------------------------------- |
| **DeepBook** | Deterministic matching; spot VWAP = index price              | Extra taker flow deepens spot liquidity         |
| **Lend**     | Flash-borrows for liquidators; deposit idle margin as supply | Interest reserves paid in UNXV → flywheel       |
| **Synths**   | Immediate listing of any new synth underlier                 | Perps open interest drives synth hedging volume |

---

## 9 · Security checklist

| Threat                      | Mitigation                                                  |
| --------------------------- | ----------------------------------------------------------- |
| Oracle spoof                | Pyth proof verify + fallback TWAP with haircut              |
| Funding grief (spam trades) | Funding cap per hour + 10 % protocol skim                   |
| Cross-market wipe           | Cross-margin nets PnL first; isolated-margin opt-in         |
| Re-entrancy                 | Clearing writes state then external calls; no callbacks     |
| Insurance drain             | DAO can top-up from Treasury or mint capped debt-token vote |

Audit + Code4rena contest precede mainnet.

---

## 10 · Gas & UX highlights

* **Multicall** – `add_margin + fill_orders` in one tx.
* **Permit2** – USDC margin deposit without separate approve.
* **SDK** – Local funding & liquidation sim so wallet shows live liq-price before signing.
* **Sub-second fills** – Relayer pushes DeepBook best bid/ask; bots match in <1 block.

---

## 11 · Launch plan

1. **Beta** — BTC-PERP & ETH-PERP, 10× leverage cap.
2. **Phase-2** — List SOL, DOGE, sBTC, sETH.
3. **Phase-3** — Permissionless listing: any Pyth feed with ≥ \$1 M daily spot volume.
4. **Insurance seeding** — Treasury commits 1 M UNXV initial backstop before mainnet.

---

## 12 · TL;DR

*DeepBook matching + on-chain margin = CEX-grade perps without a custom sequencer.*
10 bps taker fee and funding skim auto-convert to **UNXV**, filling the insurance pool and burning supply.
Cross-margin across spot, synth, futures, and options—everything powered by the same oracle and fee flywheel.

