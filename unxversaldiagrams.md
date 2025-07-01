# **unxversal diagrams**

Below is a compact set of high-resolution ASCII schematics for the entire stack and each major subsystem.

---

## 0 · Top-level map  (“Everything, everywhere, in UNXV”)

```
┌─────────────────────────────────────────── Sui network ────────────────────────────────────────────┐
│                                                                                                   │
│          ┌─────────────┐      DeepBook       ┌─────────────┐                                      │
│          │  Spot DEX   │ ─────────▲─────────▶ │  Perps/Futs │  (fill events)                       │
│          └─────────────┘          │           └─────────────┘                                      │
│                ▲                 RFQ                ▲                                              │
│                │    RFQ swap ─────┴─────▶ fee_sink  │                                              │
│                │                        (asset→UNXV)│                                              │
│  Wallet / SDK  │                                     │                                              │
│    (users)     ▼                                     │                                              │
│        ┌──────────────────┐          UNXV            │                                              │
│        │ Cross-Margin ACCT│──────────────────────────┴─────┐                                        │
│        └──────────────────┘                                │                                        │
│           ▲        ▲     ▲                                ▼                                        │
│           │        │     │                        ┌────────────┐                                   │
│           │        │     │                        │Insurance(s)│  (Perps • Lend • Synth)           │
│           │        │     │                        └────────────┘                                   │
│           │        │     │                                ▲                                        │
│   Lend ◄──┘        │     └──► Synth Vault  ◄──────────────┘                                        │
│                    │                                                                       UNXV fees│
│                    └──── Liquidation Engines ────┐                                                  │
│                                                  ▼                                                  │
│                                        ┌─────────────────┐                                          │
│                                        │ Treasury (UNXV) │                                          │
│                                        └────────┬────────┘                                          │
│                                                 ▽                                                   │
│       Oracle-Gas Vault◄───70 % fees  buy&burn / buy&lock  DAO spending                               │
└───────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 1 · Governance & Treasury

```
                 ┌───────────────────────────┐
                 │  ve-Locker (NFT w/ bias)  │      (1–4 yr decay)
                 └───────┬─────────▲─────────┘
                         │         │delegate
          1 % VP to file │         │
         proposal bond   │         │
                         ▼         │
  ┌───────────────┐   vote/prop   ┌────────────────┐   execute    ┌───────────────────┐
  │   Governor    │──────────────▶│  Timelock 48h  │─────────────▶│ Protocol Upgrades │
  └─────▲─────────┘                └─────▲─────────┘               └─────────▲────────┘
        │                               pause                               │
        │  Guardian 3/5 multisig  ────────┘                                funds
        ▼
  ┌───────────────┐
  │ Treasury Safe │── buy&burn / grants / insurance top-ups
  └───────────────┘
```

---

## 2 · Spot DEX on DeepBook

```
 Maker               Taker                       On-chain
┌───────┐    place    │                 ┌──────────────────────────┐
│Wallet │─────────────┤                 │  DeepBook Matching Eng.  │
└───────┘             ▼     fill event  └──────────┬───────────────┘
                 ┌───────────────┐                ▼
                 │Relayer Mesh   │──────push────▶ SDK  ←─┐
                 └───────────────┘                       │ verify sim
                                             fee_sink(asset) → swap → UNXV
```

---

## 3 · Lend (uCoin Money-Market)

```
                 supply / withdraw
Wallet ────────▶ Core Pool ────┐
                               │ borrow / repay
                               ▼
                       AccountLiquidity
                               ▲
      accrue_interest()        │
         reserves─────────┐    │
                          ▼    │
                 fee_sink::reserve swap→UNXV
                          │
            50 % ve-lock  │ 50 % liquid Treasury
```

---

## 4 · Synth Vault

```
      ┌───────────────────────────┐
      │  USDC Collateral Vault    │
      └───────────────────────────┘
              ▲  ▲      ▲
  deposit     │  │mint  │burn
              │  │      │
              ▼  │      ▼
           Position<N>  Synth ERC-20 (sBTC…)
              │
    CR check ─┴── if CR<160 %
              │
  ┌───────────┴───────────┐
  │ Liquidation Engine    │
  └───────────┬───────────┘
              │
     seize USDC + penalty
              ▼
   50 % Bot reward (→UNXV) etc.
```

---

## 5 · Perps & Futures Clearing House

```
          DeepBook fills
                │
                ▼
┌─────────────────────────────────────────┐
│      ClearingHouse (cross-margin)      │
│ ─ positions{market}                    │
│ ─ collateral (USDC/UNXV)               │
│ ─ funding_index[market]                │
└───┬───────────────────────────┬────────┘
    │funding accrual           │liquidation
    ▼                          ▼
 perps::funding          perps::liquidation
    │ skim 10 %          │ 70 % → bot
    ▼                    │
fee_sink::perps          │
    │                    │
 UNXV  → Insurance pool ◄┘
```

---

## 6 · Options Engine (RFQ + DeepBook)

```
Writer                 Buyer                 Clearing
┌──────┐ RFQ  ┌────┐  │                     ┌─────────────────┐
│sign  │──────│Bot │──┤  DeepBook          │  OptionSeries   │
└──────┘      └────┘  │  or RFQ            │  PnL + Collat.  │
     collateral esc.  │                    └──────┬──────────┘
                      │                           │
                      ▼                           │expiry
                fee_sink::options ── burn+treasury│
                                                  ▼
                                    settle & pay writers/longs
```

---

## 7 · Liquidation Bot Workflow

```
  WebSocket price tick
          │
          ▼
   health_check(dev_inspect)
          │unsafe
          ▼
 Flash-borrow USDC (Lend)  ──┐
          │ repay victim     │
          ▼                  │
  Liquidate Synth / Lend / Perp
          │                  │
  seize collateral            │
          ▼                  │
  DeepBook RFQ swap → UNXV ◀──┘
          │
        Profit
```

---

## Cheat-sheet of arrows

```
▲  user→protocol      ─ actions / calls
▼  protocol→user      ═ object ownership
→  fee UNXV flow      ≡ broadcast / relay
```
