# futures.md — Dated cash-settled futures on **Sui**

Binary-safe leverage for traders who want a hard expiry instead of perpetual funding.
Series are matched on **DeepBook**, margined in the **Cross-Margin** account shared with perps, and cash-settle to a **Pyth** mark price at expiry.
Every trade fee routes to **UNXV** just like the rest of the stack.

---

## 1 · Module map (Move)

| Module              | Resource / Object                  | Purpose                                                                     |
| ------------------- | ---------------------------------- | --------------------------------------------------------------------------- |
| `futures::series`   | `FutureSeries`                     | Immutable params: assetId, expiryTs, tickSize, maxLeverage, initMM, maintMM |
| `futures::factory`  | —                                  | Deploys new `FutureSeries` and registers with Clearing House                |
| `futures::clearing` | —                                  | `open`, `close`, `add_margin`, `withdraw`, `settle_expiry`                  |
| `futures::account`  | Uses `perps::account::CrossMargin` | Same collateral & PnL bucket as perps                                       |
| `futures::oracle`   | —                                  | Pulls settlement price from Pyth; fallback DeepBook TWAP                    |
| `fee_sink::futures` | —                                  | 5 bps taker fee → swap→UNXV (burn + Treasury)                               |

All Series share the **same** insurance fund already used by perps.

---

## 2 · Series creation & listing

```move
// Governance-timelocked call
futures::factory::create_series(
    asset_id = "BTC",
    expiry_ts = 1725494400,   // 2024-09-05 00:00:00 UTC
    max_lev   = 10,
    init_mm   = 10_000,       // 10 %
    maint_mm  = 6_000,        // 6 %
    tick_size = 0.5 USD
);
```

* Emits `SeriesCreated` for indexers → UI auto-lists contract.
* DeepBook market key = `hash("BTC"+"2024-09-05")`.

---

## 3 · Trading & margin flow

### 3.1 Open / Close

```
futures::clearing::fill_orders(
    trader,
    series_id,
    deepbook_order_ids,
    notionals_usd[]
);
```

* **Taker fee** = 5 bps of notional, swapped to UNXV → 60 % burn / 40 % Treasury.
* Margin checks identical to perps but **no funding** accrual.

### 3.2 Ongoing margin

```
marginReq = |pos_size| / leverageAllowed
health     = (collateral + unrealisedPnL) / marginReq
```

Liquidation threshold = `health < 1.0`; penalty = 1 % of closed notional.

---

## 4 · Settlement process

| Phase            | Timestamp                                                                                                                                                                          | Action                       |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| **T-30 min → T** | `futures::oracle::freeze_price()` stores 30-min Pyth TWAP; cancels unfilled DeepBook orders                                                                                        | Automatic keeper or any user |
| **At Expiry T**  | `settle_expiry(series_id)` callable by anyone: <br>• Computes `PnL = pos_size × (settlePrice − entryPx)` <br>• Credits / debits USDC collateral <br>• Sets `series.settled = true` | Gas refunded by protocol     |
| **Post-expiry**  | Traders withdraw collateral; Series object becomes read-only.                                                                                                                      | —                            |

If a trader is underwater (negative collateral) the **Insurance Fund** tops up; DAO can claw back later via debt-auction.

---

## 5 · Default parameter set

| Asset class   | Max Lev | Init MM | Maint MM | Tick   | Fee   |
| ------------- | ------- | ------- | -------- | ------ | ----- |
| BTC & ETH     | 10×     | 10 %    | 6 %      | \$0.50 | 5 bps |
| High-cap alts | 8×      | 12 %    | 8 %      | \$0.10 | 6 bps |
| sAssets       | 6×      | 15 %    | 10 %     | \$0.10 | 8 bps |

Governance can adjust ±2 bps fee or ±20 % leverage per proposal.

---

## 6 · Fee routing

```
taker_fee (asset) ─► fee_sink::futures.swap_to_unxv()
                      ├─ 60 % burn
                      └─ 40 % Treasury
```

Swap path via DeepBook RFQ; slippage guard ≤ 1 %.

---

## 7 · Oracle & risk

| Risk                           | Guardrail                                                         |
| ------------------------------ | ----------------------------------------------------------------- |
| Pyth outage at expiry          | Use DeepBook 30-min VWAP as fallback –4 % haircut                 |
| Last-minute price manipulation | 30-min freeze window before expiry; oracle median of that period  |
| Calendar spread abuse          | Factory enforces min 7-day gap between expiries on same underlier |
| Short squeeze gap              | Higher maint MM for final 48 h (auto-ramps +2 %)                  |

---

## 8 · Integration matrix

| Module      | Use of Futures                                                   |
| ----------- | ---------------------------------------------------------------- |
| **Options** | European option settlement references the same series price      |
| **Lend**    | Futures margin deposits earn supply APY until used               |
| **Synth**   | Traders can hedge large synth exposure by shorting dated futures |

---

## 9 · Launch schedule

1. **Beta** – BTC-0925, ETH-0925 two-month contracts.
2. **Expand** – Rolling monthly expiries for BTC, ETH, SOL, sBTC, sETH.
3. **Permissionless** – DAO whitelists assetId once; anyone may spin new expiries ≥30 d out.
4. **Cash-settle automation** – Keeper network subsidised by Treasury until fees cover gas.

---

## 10 · TL;DR

*DeepBook orderbook + date-certain cash settlement.*
5 bps taker fee funnels into UNXV; no funding headaches.
Shared margin with perps keeps UX simple, while Pyth oracle ensures provable, manipulation-resistant expiry pricing.