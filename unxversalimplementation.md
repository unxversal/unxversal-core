# **unxversal Implementation Roadmap**
*A phased build-out plan from MVP to full DeFi operating system*

---

## 📜 Document Purpose
This document translates the high-level unxversal vision into an actionable build sequence.  
For **each phase** we specify:
1. **Primary Objectives & Rationale** (what problem we solve first)
2. **On-Chain Deliverables** (Move packages deployed to Sui)
3. **Off-Chain / Backend Services** (indexers, keepers, bots, CLI tools)
4. **UI / Front-End Milestones** (user-facing apps & dashboards)
5. **Dependencies & Tests** (audit, fuzz, integration pipelines)

The order reflects critical-path dependencies, quick wins for adoption, and progressive hardening of risk.

---

## 🗺️ Phase-by-Phase Timeline

| Phase | Target Quarter | Milestone Tag | Primary User Personas Unlocked |
|-------|----------------|--------------|--------------------------------|
| **0** | Month 0        | *Dev Bootstrap* | Core devs & auditors |
| **1** | Q1             | *DAO Genesis* | Governors, Treasury ops |
| **2** | Q1             | *Spot v1* | Active traders |
| **3** | Q2             | *Synth MVP* | Traders, power users |
| **4** | Q2             | *Lend α* | Yield farmers |
| **5** | Q3             | *Relayer Mesh* | Infra providers |
| **6** | Q3             | *Perps β* | Active traders, liquidators |
| **7** | Q4             | *Dated Futures* | Hedgers, risk managers |
| **8** | Q4             | *Options β* | Risk managers, structured desks |
| **9** | Q1 +1          | *Exotics α* | Institutional desks |
| **10**| Q1 +1          | *LP Vaults* | Passive capital |
| **11**| Q2 +1          | *Liquid Staking* | Newcomers, yield farmers |
| **12**| Q2 +1          | *Gas Futures* | Protocol treasuries |
| **13**| Rolling        | *Infra Tooling* | Bots, keepers, explorers |
| **14**| Rolling        | *Cross-Chain* | New ecosystems |

---

## 🔧 Phase 0 — Development Bootstrap
**Goal**: Establish tooling & CI so every later phase lands fast & safely.

### On-Chain
- *N/A* (Use Sui testnet faucet only)

### Off-Chain
- Monorepo scaffolding (`pnpm`, `cargo`, `move` workspace)  
- GitHub Actions: lint, unit tests, `sui move test`, static analysis  
- Local Sui-Fullnode docker image for deterministic e2e tests  
- `forge-fuzz` harness for Move invariants (via Move Prover)

### UI
- Storybook + Tailwind design system  
- Wallet adapter abstraction (Suiet, Nightly, Ethos)

### Tests / Audits
- Coverage >85 % on unit tests  
- Pre-commit hooks (prettier, clippy, move-lint)

---

## 🏛️ Phase 1 — DAO Genesis & UNXV Token
### Objectives
1. Deploy immutable `UNXV` coin & vesting escrows.  
2. Launch `ve-Locker`, `Governor`, `Timelock`, and seeded Treasury.

### On-Chain Components
| Module | Resource | Notes |
|--------|----------|-------|
| `unxv::coin` | `Coin` | 1 B supply, mint cap burned |
| `unxv_ve::locker` | `Locker<NFT>` | Linear decay voting power |
| `gov::bravo` | `Proposal`, `Receipt` | Ported from OZ Governor-Bravo |
| `gov::timelock` | `Timelock` | 48 h delay |
| `treasury::safe` | `Safe` | Owns UNXV & USDC |

### Off-Chain
- CLI: `unxv-gov` to create & simulate proposals.  
- DAO dashboard indexer (Postgres) syncing proposal & vote events.

### UI
- Governance portal (proposals, vote signing, vesting viewer).  
- Token dashboard (balance, lock, delegate).

### Dependencies
- Audit of token & DAO contracts (Quantstamp).  
- Move Prover proofs on supply-cap & vote-count invariants.

---

## 🏪 Phase 2 — Spot DEX v1 (DeepBook Wrapper)
### Objectives
Ship first **end-user utility**: real trading & UNXV fee capture.

### On-Chain
| Module | Functionality |
|--------|---------------|
| `dex::router` | Safe wrappers around DeepBook `place/cancel/fill` |
| `fee_sink::dex` | Swap taker fee asset→UNXV; route splits |
| `relayer::registry` | Store WS relayer reputations (opt-in) |

### Off-Chain
- **Indexer + Relayer** binary:  
  • Streams DeepBook events → WS  
  • Caches order-book deltas in Redis.
- `@unxv/sdk` TypeScript:  
  `connect()`, `matchBest()`, `simulateFill()`.

### UI
- **Trading GUI** (Next.js):  
  Orderbook, depth, recent trades, wallet panel, fee rebate banner.

### Tests
- Load test: 1000 orders/s, <500 ms WS latency.
- Integration: taker fee auto-swaps within same tx.

---

## 🧪 Phase 3 — Synthetic Assets MVP
### Objectives
Enable broad asset coverage → network effect for later derivatives.

### On-Chain
| Module | Key Resources | Description |
|--------|---------------|-------------|
| `synth::vault` | `Position`, `GlobalDebt` | CR calc, mint/burn |
| `synth::factory` | — | List new synth via Pyth ID |
| `fee_sink::mintburn` | — | 15 bps mint fee routing |

### Off-Chain
- Oracle attestation relay (LayerZero) auto-posts Pyth price objects.  
- Keeper: fallback DeepBook VWAP writer if Pyth stale.

### UI
- Mint/Burn wizard, CR slider, liquidation price preview.  
- Synth watch-list auto-generates DeepBook pairs.

### Dependencies
- Testnet Pyth integration with alerting on price drift.  
- Quantitative fuzzing on CR & liquidation math.

---

## 💵 Phase 4 — Lending α (uCoin Money Market)
### Objectives
Unlock idle capital yield & flash-loan infra for later bots.

### On-Chain
| Module | Resource | Notes |
|--------|----------|-------|
| `lend::pool` | `PoolConfig`, `MarketInfo` | All markets share one pool |
| `lend::utoken` | `UToken<T>` | Interest-bearing receipt coin |
| `lend::flashloan` | — | Single block atomic loan |
| `fee_sink::reserve` | — | Reserve factor UNXV routing |

### Off-Chain
- Rate model CLI to simulate utilisation curves.  
- Liquidation-pricing oracle (uses DeepBook mid).

### UI
- Supply / Borrow panel, health factor meter, interest graphs.  
- Flash-loan sandbox with code snippets.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

## 🌐 Phase 5 — Relayer Mesh & Public Indexer
### Objectives
Hardening real-time data infra for perps & options latency needs.

### On-Chain
- *No new modules* (mesh off-chain).

### Off-Chain
| Service | Description |
|---------|-------------|
| Mesh Node | Combines indexer + WS broadcaster + libp2p gossip |
| Aggregator | Optional Cloudflare R2 cached snapshot for thin clients |

CLI: `relayer-node start --peer=<addr>`.

### UI
- Latency dashboard, relayer uptime leaderboard.

---

## ⚡ Phase 6 — Perpetual Futures β
### Objectives
Deliver high-leverage trading; backstop risk with insurance fund.

### On-Chain
| Module | Functionality |
|--------|---------------|
| `perps::market` | Market params registry |
| `perps::account` | Cross-margin struct |
| `perps::clearing` | Open/close, margin flows |
| `perps::funding` | Index accumulator, 10 % skim |
| `perps::liquidation` | Close-factor & penalties |
| `insurance::perps` | UNXV-denominated fund |

### Off-Chain
- Funding-rate keeper (trigger `tick()` hourly).  
- Liquidation bot starter kit (Rust) using flash-loan.

### UI
- Advanced trading terminal: ladder, position panel, funding APR chart.  
- Liquidation watch list & risk bar.

### Tests / Audits
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

---

## 📅 Phase 7 — Dated Futures
*(light delta since shares margin engine with perps)*

### On-Chain
| Module | Note |
|--------|------|
| `futures::series` | Immutable params per expiry |
| `futures::clearing` | Settle at expiry TWAP |
| `fee_sink::futures` | 5 bps fee → UNXV split |

### Off-Chain
- Keeper to call `freeze_price()` 30 min pre-expiry & `settle_expiry()`.

### UI
- Futures calendar, basis chart, expiry settlement timeline.

---

## 🎭 Phase 8 — Options β
### On-Chain
| Module | Highlights |
|--------|------------|
| `options::series` | Strike, expiry, IVCap |
| `options::orderbook` | EIP-712 RFQ settle |
| `insurance::options` | Capitalised by premium fees |

### Off-Chain
- Black-Scholes IV calculator library (WASM).  
- RFQ signer bot template.

### UI
- Volatility surface heat-map, strategy builder (spreads).  
- Writer dashboard with collateral ramp preview.

---

## 🎪 Phase 9 — Exotics α
*(Barrier options, range accruals, power perps)*

### On-Chain
Shared margin + new `exotics::*` engine; see `exotics.md`.

### Off-Chain
- Barrier monitor daemon storing min/max price ring-buffer.

### UI
- Pay-off graph playground, live barrier status badge.

---

## 🤖 Phase 10 — LP Vaults
### On-Chain
| Module | Notes |
|--------|------|
| `lp::vault` | Deposits, uLP shares |
| `lp::strategy_base` | Trait + delegate scripts |
| `fee_sink::lp` | 10 % perf fee routing |

### Off-Chain
- Keeper framework: `rebalance()` jobs per strategy.  
- Strategy SDK to compile Move delegate modules.

### UI
- Vault gallery, risk score, performance charts, high-water mark.

---

## 🌊 Phase 11 — Liquid Staking (sSUI)
### On-Chain
| Module | Resource |
|--------|----------|
| `lstake::vault` | StakePool, StakeBatch |
| `lstake::coin` | sSUI rebasing coin |
| `fee_sink::lstake` | 5 % skim swap |

### Off-Chain
- Validator performance oracle & auto-rebalancer.

### UI
- sSUI APY chart, stake/unstake flow, validator set display.

---

## ⛽ Phase 12 — Gas Futures
*(see `gasfut.md` for detail)*

### On-Chain
`gasfut::*` series, AMM, reserve pool, risk module.

### Off-Chain
- Δ-hedge daemon shorting SUI/USDC perps when reserve Δ rises.

### UI
- Quote widget: break-even vs historic gas volatility.

---

## 🏗️ Phase 13 — Infrastructure Tooling (Rolling)
- **Liquidation Bots**: Open-source templates, Docker images.  
- **Oracle Keepers**: SLA monitor & fail-over scripts.  
- **Block Explorer Plugins**: UI modules for Sui explorers to decode unxversal events.

---

## 🌉 Phase 14 — Cross-Chain Expansion
- Wormhole UNXV bridge contracts.  
- Mirror spot markets on external chains via price stream.

---

## ✅ Test, Audit, and Launch Gates
| Gate | Metric |
|------|--------|
| Unit test coverage | ≥85 % for each Move package |
| Fuzz & Prover invariants | No critical counter-examples |
| External security audit | Passed w/ all Highs fixed |
| Load/latency test | ≤1 s P90 end-to-end tx time |
| Bug bounty | Code4rena ≥$100k pool before mainnet |

---

## 📡 Deployment & Operations
- **CI/CD**: Tag → build Move release → run testnet smoke → propose DAO upgrade.  
- **Monitoring**: Grafana + Prometheus dashboards for relayers, keepers, Pyth freshness, fee_sink slippage.  
- **Incident Response**: PagerDuty alerts wired to Guardian multisig holders.

---

## 🌟 Conclusion
This phased roadmap balances **utility first** (spot DEX) with **risk-managed complexity** (perps → options → exotics).  
Each step compounds liquidity, fee flow, and community engagement while ensuring audits and monitoring are in place before escalating systemic risk.

*Iterate fast, ship safely, and let every new module amplify the UNXV flywheel.* 