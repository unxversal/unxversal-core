# **unxversal Exotics — path-dependent pay-offs on Sui**

Adds a plug-in clearing-house that mints, tracks, and settles **non-vanilla derivatives**—barrier options, range-accrual notes, and power perps—while reusing the oracle, margin, liquidation, and **UNXV** fee rails already live in the unxversal stack.

---

## 1 · Why exotics?

| Value prop            | Detail                                                                                                  |
| --------------------- | ------------------------------------------------------------------------------------------------------- |
| **New risk surfaces** | Traders hedge “stay in range”, “breakout”, or convex beta views unavailable with vanilla options/perps. |
| **Higher fee yield**  | Exotic flows tolerate wider spreads (20–40 bps), boosting UNXV buy-pressure.                            |
| **Minimal new code**  | Built on existing Cross-Margin & Oracle rails—no fresh insurance pool needed.                           |

---

## 2 · Supported pay-offs (launch set)

| Code         | Description              | Pay-off formula                                 | Typical use-case                          |
| ------------ | ------------------------ | ----------------------------------------------- | ----------------------------------------- |
| `KO_CALL`    | **Knock-out call**       | `max(0, S_T – K)` *if* `S_t < B` ∀ t            | Cheap trend bet—but dies if price crashes |
| `KI_PUT`     | **Knock-in put**         | Activates only if barrier hit, then vanilla put | Hedge only if support breaks              |
| `RANGE_ACC`  | **Range accrual**        | Pays coupon `c` per epoch while `L ≤ S ≤ U`     | Earn yield in chop                        |
| `PWR_PERP_n` | **Power perp** (`n=2,3`) | PnL ∝ `S^n` funding-adjusted                    | Leveraged beta or variance trading        |

DAO can whitelist new recipes via a JSON schema (`underlier, type, params, expiry`).

---

## 3 · Module map (Move)

| Module              | Resource / Object        | Responsibility                                            |
| ------------------- | ------------------------ | --------------------------------------------------------- |
| `exotics::recipe`   | `RecipeTemplate`         | Immutable blueprint of param constraints                  |
| `exotics::series`   | `ExoticSeries`           | Instantiated pay-off contract (underlier, params, expiry) |
| `exotics::vault`    | `WriterPool`, `uXOToken` | Margin escrow & ERC-20 share token                        |
| `exotics::engine`   | —                        | Mint, trade, settle, knock checks                         |
| `exotics::oracle`   | —                        | Reads Pyth + barrier/history bookkeeping                  |
| `exotics::risk`     | —                        | Draw-down guard, close-factor, circuit breaker            |
| `fee_sink::exotics` | —                        | Swap fees → UNXV (burn & Treasury)                        |

All new objects plug into the existing **Cross-Margin** account and **Liquidation Engines**.

---

## 4 · Lifecycle walk-through (Barrier call example)

1. **Series creation** (DAO vote)

```move
exotics::recipe::create(
  underlier = "BTC",
  payoff    = KO_CALL,
  params    = {strike: 70_000, barrier: 50_000},
  expiry    = 2025-12-31
);
```

2. **Writing**
   Writer escrows USDC margin ≥ intrinsic + VAR buffer, receives `uXBTC-KO-70K-50K` tokens.

3. **Trading**
   *Path A*: DeepBook orderbook (6 bps taker fee)
   *Path B*: Strategy vault buys bulk and market-makes.

4. **Barrier tracking**
   `exotics::oracle::on_price(price)` stores min/max in 1 min ring-buffer; flags `knocked = true` if rule violated.

5. **Settlement**
   At expiry or early exercise:

   ```
   payoff = knocked ? 0 : max(0, S_T – K)
   ```

   Writers pay USDC, longs burn token & receive cash.

6. **Fees & routing**
   *Mint fee* 20 bps, *Trade fee* 12 bps → `fee_sink::exotics` → swap → **UNXV**
   *Split*: 60 % burn · 40 % Treasury.

---

## 5 · Margin & liquidation

| Stage           | Collateral requirement                                              |
| --------------- | ------------------------------------------------------------------- |
| New position    | Black-Scholes 99 Δ + VAR buffer (capped by `iv_cap` = 400 %)        |
| Knocked series  | Collateral instantly drops to `0` (call) or intrinsic (put)         |
| Draw-down guard | If writer pool equity ↓ 10 % intra-block → halt new mints           |
| Liquidation     | Same engine as options; penalty 2 % to liquidator (UNXV after swap) |

---

## 6 · Risk controls

| Parameter             | Default        | Fast change         | Range       |
| --------------------- | -------------- | ------------------- | ----------- |
| `iv_cap` (per series) | 400 % ann.     | Guardian lower-only | 200–600 %   |
| `drawdown_limit`      | 10 % of NAV    | Guardian lower-only | 5–20 %      |
| `writer_cap`          | \$1 M notional | DAO timelock        | up to \$5 M |

Outlier risk merges into existing **Options Insurance** pool; no new fund required.

---

## 7 · Fee grid (after swap → UNXV)

| Event              | Rate         | Split                          |
| ------------------ | ------------ | ------------------------------ |
| Mint / Burn        | 20 bps       | 60 % burn · 40 % Treasury      |
| Trade (DeepBook)   | 12 bps taker | 40 % Relayer · 60 % Treasury   |
| AMM swap           | 15 bps       | 60 % burn · 40 % Treasury      |
| Writer liquidation | 2 %          | 80 % Insurance · 20 % Treasury |

---

## 8 · Composability quick-wins

| Consumer        | Benefit                                                               |
| --------------- | --------------------------------------------------------------------- |
| **LP Vaults**   | Deploy a *Barrier Range Writer* vault to farm premiums.               |
| **Perps desks** | Hedge delta/vega exposure by trading power perps inside cross-margin. |
| **Treasury**    | Sell far-OTM KO calls on idle UNXV to fund buy-back programmes.       |

---

## 9 · Launch checklist

1. **Audit recipe factory + engine** (share code with Options module).
2. **Deploy pilot series**: BTC KO Call 70 K/55 K & ETH Range 2 K–3 K (3-month).
3. **Enable barrier ring-buffer on oracle daemon.**
4. **List series tokens in GUI** under “Exotics” tab with payoff graph & barrier status.
5. Incentivise first \$1 M TVL with ve-UNXV gauge weight (3 weeks).

---

### TL;DR

*unxversal Exotics* mints barrier options, range notes, and power perps—no OTC desk required.
Fees buy & burn **UNXV**, margin plugs straight into existing insurance, and traders gain a whole new palette of structured bets without leaving Sui.
