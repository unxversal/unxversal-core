# options.md — European calls & puts on **Sui**

Fully-collateralised, cash-settled options you can quote on **DeepBook** or via off-chain RFQ, margin in the shared cross-margin account, and settle to a **Pyth** mark on expiry.
Premium fees are auto-swapped to **UNXV**, fuelling buy-&-burn and the options insurance pool.

---

## 1 · Module map (Move)

| Module               | Resource / Object  | Purpose                                                                          |
| -------------------- | ------------------ | -------------------------------------------------------------------------------- |
| `options::series`    | `OptionSeries`     | Immutable: *underlier*, *type* (call/put), *strike*, *expiryTs*, *tick*, *IVCap* |
| `options::factory`   | —                  | Deploys new Series; writes to registry                                           |
| `options::orderbook` | —                  | (Optional) RFQ settlement by signature; DeepBook handles main CLOB               |
| `options::clearing`  | —                  | `write`, `buy`, `exercise`, `add_margin`, `withdraw`                             |
| `options::greeks`    | —                  | Black-Scholes / IV analytics (pure Move)                                         |
| `options::oracle`    | —                  | Pyth mark price; DeepBook TWAP fallback                                          |
| `fee_sink::options`  | —                  | Premium fee 15 bps → swap→UNXV (burn + Treasury)                                 |
| `insurance::options` | `OptionsInsurance` | Pays tail risk on writer shortfalls                                              |

All series share the cross-margin collateral bucket used by **Perps & Futures**.

---

## 2 · Series creation

```move
// Governor-timelocked
options::factory::create_series(
    underlier = "BTC",
    option_type = CALL,          // or PUT
    strike = 70_000_000,         // USD-cents 70 000
    expiry  = 1725494400,        // 2024-09-05 00:00 UTC
    tick    = 0.5 USD,
    iv_cap  = 3000   // 300 % annualised
);
```

Emits `SeriesCreated` → indexer → DeepBook market key `BTC-C-70K-20240905`.

---

## 3 · Trading & writing flow

### 3.1 Writing (short)

```move
// Writer escrows USDC and issues option tokens (oBTC-C-70K-0925)
options::clearing::write(series_id, contracts, collateral_usdc);
```

* **Collateral requirement** (European):
  *Call*: `max(0, S_max − K) × contracts` capped by IVCap
  *Put*: `K × contracts`
  *Margin*\* merges with other cross-margin positions.

### 3.2 Buying (long)

*Buy on DeepBook or RFQ*

* **Premium fee** = 15 bps of premium → swapped to UNXV
  • 60 % burn, 40 % Treasury

### 3.3 Closing prior to expiry

* Long: sell on DeepBook or `exercise_early()` if deep ITM (optional, penalty 0.5 % to insurance).
* Short: buy back option tokens & burn (`close_short()`).

### 3.4 Settlement at expiry

1. **Freeze price** 30 min pre-T.
2. Anyone calls `settle_expiry(series_id)` (gas refunded):

   ```
   payoff = max(0, (S_settle − K)) × contracts   // call
          = max(0, (K − S_settle)) × contracts   // put
   ```
3. Writers pay USDC collateral; longs receive USDC, options burn.
4. Deficit (writer defaults) → OptionsInsurance pays gap.

---

## 4 · Margin schedule

| Time to Expiry | Writer collateral multiplier   |
| -------------- | ------------------------------ |
| > 14 d         | 1.0 × Black-Scholes 99 Δ bound |
| 14 d → 7 d     | +15 % ramp                     |
| ≤ 7 d          | +30 % ramp                     |
| Final 24 h     | Full intrinsic + 10 % buffer   |

Collateral models use `options::greeks::bs_price()` with IV capped at `iv_cap`.

---

## 5 · Fee routing & insurance

```
premium_fee (asset) ─► fee_sink::options.swap_to_unxv()
                        ├─ 60 % burn
                        └─ 40 % Treasury
```

**Insurance pool** bootstrapped with 500 k UNXV from Treasury.
Pool tops up from seized collateral & 20 % of liquidation penalties.

---

## 6 · RFQ meta-orders (gas-saver)

1. Writer signs `Quote { price, size, expiry, nonce }` EIP-712-style.
2. Taker submits `buy_by_sig(quote, sig)` to `options::orderbook`.
3. Module verifies signature, pulls premium, issues option tokens, routes fee.

Saves DeepBook posting gas for illiquid strikes.

---

## 7 · Risk controls

| Risk                   | Guardrail                                                 |
| ---------------------- | --------------------------------------------------------- |
| IV blast manipulation  | `iv_cap` per series; cannot exceed 3 000 bps/√yr          |
| Oracle outage          | DeepBook TWAP fallback (haircut 3 %)                      |
| Writer default         | Insurance fund backstop; DAO can socialise loss if > fund |
| Deep ITM call squeeze  | Dynamic collateral ramps as Δ→1                           |
| Signature replay (RFQ) | Nonce tracking per writer                                 |

---

## 8 · Integration grid

| Module      | How it plugs in                                                                   |
| ----------- | --------------------------------------------------------------------------------- |
| **Perps**   | Traders hedge gamma via perp delta sizing                                         |
| **Futures** | Physically deliver long option via buying dated future pre-expiry                 |
| **Lend**    | Long option tokens accepted as 0 collateral; writers’ collateral earns supply APY |
| **Synth**   | Underlier prices + DeepBook liquidity for hedge trades                            |

---

## 9 · Default parameter set

| Option tier   | Tick   | Max IV Cap | Premium fee | Writer liq penalty |
| ------------- | ------ | ---------- | ----------- | ------------------ |
| BTC / ETH     | \$0.50 | 300 %      | 15 bps      | 2 %                |
| High-cap alts | \$0.10 | 400 %      | 18 bps      | 3 %                |
| sAssets       | \$0.05 | 500 %      | 20 bps      | 4 %                |

Governance can move fee ±3 bps, IVCap ±100 % within timelock.

---

## 10 · Launch cadence

1. **Pilot** — BTC-70K-C/P & ETH-4K-C/P 3-month expiries.
2. **Round-2** — 5 strikes ladder per underlier, monthly roll.
3. **Permissionless** — DAO whitelists underlier once; anyone may create strikes ≥5 % OTM, expiry 4-8 weeks out.
4. **RFQ relayers** — Incentive pool in UNXV for first-month market makers.

---

## 11 · TL;DR

European options, on-chain matched or RFQ, margin-shared with perps & futures.
15 bps premium fee drives UNXV burn + Treasury.
Pyth mark guarantees provable cash settlement, while an insurance pool backstops extreme moves—completing unxversal’s derivatives triangle on Sui.