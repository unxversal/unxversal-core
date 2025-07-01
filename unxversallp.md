# **unxversal LP — Unified Liquidity-Provisioning Vaults**

Deploy one set of Move vault contracts that can **market-make, quote, hedge, lend, and farm** across **every** unxversal venue—DeepBook spot, perps, dated futures, options, synth mint / burn, and even external Sui AMMs.
Token-holders (UNXV, USDC, synths, or any whitelisted coin) deposit once; strategy logic, hedging, and risk controls run autonomously under DAO-audited code.

---

## 1 · Why an LP layer?

| Pain today                                       | How unxversal LP fixes it                                                     |
| ------------------------------------------------ | ----------------------------------------------------------------------------- |
| Fragmented liquidity across spot, perps, options | One vault can route inventory to any venue with the best risk-adjusted reward |
| Retail users can’t write MM bots                 | Deposit → pick a strategy preset → track P\&L in real time                    |
| Active LPs need separate hedging capital         | Vaults use cross-margin + flash-loans to delta-neutralise on the fly          |
| No yield on idle insurance & Treasury funds      | DAO can delegate a % of pools to low-risk vaults for extra UNXV buy-pressure  |

---

## 2 · High-level architecture

```
┌──────────────────────────────────── Sui ────────────────────────────────────┐
│                                                                            │
│  DeepBook  Spot / Perps  ─┐                                                │
│                           │ fill / cancel                                  │
│  External AMMs (e.g. Cetus) ─┐                                             │
│                              ▼                                             │
│                      ┌───────────────────┐        price feeds              │
│                      │ Strategy Modules  │◄─────────────── Pyth            │
│                      └──────┬────────────┘                                 │
│        hedge / flash        │ rebalance                                    │
│                              ▼                                             │
│                      ┌───────────────────┐                                 │
│                      │     Vault Core    │                                 │
│  deposit / withdraw  │   (uLP tokens)    │                                 │
│        ▲             └────────┬──────────┘                                 │
│  Wallet / SDK                 │                                             │
│                               swap fees → UNXV                              │
│                      ┌────────▼──────────┐                                 │
│                      │ FeeSink / Treasury│                                 │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3 · Core Move modules

| Module                | Key resources                                    | Description                                                                  |
| --------------------- | ------------------------------------------------ | ---------------------------------------------------------------------------- |
| `lp::vault`           | `VaultConfig`, `DepositorPosition`, `uLP<Asset>` | Shares, deposits, withdrawals, accounting                                    |
| `lp::strategy_base`   | trait-like interface                             | `rebalance()`, `report()`, `max_drawdown()`                                  |
| `lp::strategies::<X>` | Strategy state                                   | Range MM, pegged quotes, delta-neutral funding capture, covered-call writer… |
| `lp::risk`            | `CircuitBreaker`, `HealthCheck`                  | Slippage, drawdown, time-lock, market status                                 |
| `lp::exec`            | —                                                | Batches orders to DeepBook / AMMs, calls flash-loan, hedge helpers           |
| `fee_sink::lp`        | —                                                | Converts protocol-side vault fees → UNXV (10 % performance fee)              |

All vaults inherit `vault_core`, while strategies remain hot-swappable through `exec` delegation and DAO-approved upgrades.

---

## 4 · Strategy presets (launch list)

| Tier                    | Name                                                         | What it does                                                             | Risk / return |
| ----------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------ | ------------- |
| **Passive**             | *Delta-neutral Range*                                        | Places symmetric bids/asks inside ±σ band, rebalances when filled.       | Low           |
| **Enhanced stable**     | *Liquidity Sandwich*                                         | Provides range liquidity ±0.2 % then routes excess to Lend for interest. | Low-med       |
| **Funding farm**        | *Long spot vs. short perp* when perp funding > threshold.    | Medium                                                                   |               |
| **Basis trader**        | *Buy synth, short dated future* to harvest basis at expiry.  | Medium                                                                   |               |
| **Covered call writer** | Sells OTM calls, auto-hedges delta with perps.               | High                                                                     |               |
| **MM Pro**              | External algorithm upload via Sui “delegate script” object\* | User-defined                                                             |               |

\* **Delegate script** = verified Move module that implements the `strategy_base` trait; vault governance whitelists uploaders.

---

## 5 · Vault lifecycle

1. **Create** – DAO or any user deploys new vault with chosen strategy & guardrails.
2. **Deposit** – Users send asset; receive `uLP` shares (`exchangeRate = 1` at genesis).
3. **Execution loop** (keeper bot or anyone):

   * `exec.rebalance()` → strategy decides orders / hedges.
   * Gas cost reimbursed from vault.
4. **Report** – `strategy.report()` updates P\&L, exchangeRate, drawdown.
5. **Withdraw** – Burn `uLP`, receive proportional assets (or auto-swap to deposit asset).
6. **Retire / migrate** – DAO can set `closed = true`, vault only allows withdrawals.

---

## 6 · Risk controls

| Control                        | Default                        | Adjustable          |
| ------------------------------ | ------------------------------ | ------------------- |
| **Max drawdown**               | 10 % of vault NAV              | Governor lower-only |
| **Slippage guard**             | 0.5 % per trade                | Strategy config     |
| **TVL cap**                    | 2 M USD eq. per vault (launch) | DAO vote            |
| **Time-lock for param change** | 6 h                            | Fixed               |
| **Emergency pause**            | Guardian multi-sig             | Yes                 |

Vault status & kill-switch fields live on-chain and surface in the SDK/GUI.

---

## 7 · Fee model

| Fee                        | Rate                    | Routing                                     |
| -------------------------- | ----------------------- | ------------------------------------------- |
| **Performance**            | 10 % of net new profits | Swapped → UNXV<br>50 % burn · 50 % Treasury |
| **Management**             | 1 %/yr streaming        | Treasury (covers keeper gas)                |
| **Early exit (if locked)** | 0.5 %                   | 100 % to remaining vault LPs                |

Performance fees crystallise on each positive `report()`; negative P\&L must be cleared before next fee accrues (“high-water mark”).

---

## 8 · User interface essentials

* Strategy gallery with APR, max DD, Sharpe.
* Deposit slider + gas estimator.
* Live greeks (for options strategies) & funding APRs (for perps).
* Per-vault and per-user P\&L charts, exportable CSV.
* “Zap” toggle – auto-swap any supported coin → vault deposit asset via DeepBook.

---

## 9 · DAO hooks & synergies

| Asset bucket           | Allocation target                           | Mechanism                               |
| ---------------------- | ------------------------------------------- | --------------------------------------- |
| **Treasury idle UNXV** | 20 % into **Covered Call** vault each epoch | Governor proposal                       |
| **Insurance excess**   | Low-risk **Liquidity Sandwich**             | Hard-coded policy trigger               |
| **ve-UNXV gauge**      | 5 % emission weight                         | LP gauges compete with Perps/Synth/Lend |

LP vaults thus become an internal flywheel: they tighten DeepBook spreads, seed funding markets, and create incremental UNXV buy-pressure.

---

## 10 · Roadmap

| Phase    | Milestones                                                                       |
| -------- | -------------------------------------------------------------------------------- |
| **α**    | Deploy vault\_core + Range strategy; manual keeper; single-asset deposits (USDC) |
| **β**    | Add Funding farm & Liquidity Sandwich; uLP token listed in Lend; GUI v1          |
| **v1.0** | Delegate-script framework; cross-margin hedging; DAO TVL allocation vote         |
| **v2.0** | Cross-chain mirror vaults (via Wormhole) & mobile quick-deposit                  |

---

### TL;DR

**unxversal LP** turns passive token holders into multi-venue market makers:
deposit once → vault does MM, hedging, lending, and options writing across the entire protocol stack.
Profits stream back as auto-bought UNXV, half burnt, half feeding Treasury—amplifying the system’s value loop while deepening every orderbook.
