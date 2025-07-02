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

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

##### Flow & UX Summary — Phase 3
- **USDC Collateralisation**: Users deposit USDC using `synth::vault::deposit`, creating a `Position`.
- **Mint Synths**: `mint<Synth>` computes max issuable amount from real-time collateral ratio via `GlobalDebt`, mints synth coins, and increases `debt_shares`.
- **Burn & Withdraw**: `burn<Synth>` repays debt; once health ≥ threshold, `withdraw` returns surplus collateral.
- **Asset Listing**: Governors add new synths through `synth::factory::add_synth` (price ID + symbol). The front-end auto-lists pairs.
- **Planned helpers**: `synth::vault::liquidate`, `synth::vault::health_factor`, `synth::factory::pause_synth`.

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

##### Flow & UX Summary — Phase 4
- **Supply & uToken Mint**: Users supply assets via `lend::pool::supply<T>` which mints `UToken<T>` via `lend::utoken::mint`; APY shows through exchange rate.
- **Borrowing**: `lend::pool::borrow<U>` allows leveraged positions, tracked in `AccountLiquidity`.
- **Interest & Reserves**: `accrue_interest` runs per block (keeper/on-demand) and routes reserve factor to `fee_sink::reserve::on_accrue`.
- **Flash Loans**: `lend::flashloan::execute` grants atomic loans that must be repaid within tx.
- **Liquidations**: `lend::liquidation::liquidate` repays debt and seizes collateral when accounts fall below threshold.
- **Planned helpers**: `lend::pool::{enter_market,exit_market,pause_asset}`, `lend::liquidation::set_close_factor`.

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

### Tests / Audits
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

##### Flow & UX Summary — Phase 5
- **Mesh Node**: `relayer-node start` indexes on-chain events and broadcasts order-book diffs over WS + gossip.
- **Aggregator Snapshot**: A cloud worker periodically uploads compressed snapshots for quick client bootstrap.
- **Client Sync**: UI loads snapshot → verifies → subscribes to live stream for ms-latency data.
- **Uptime Rewards**: Future DAO proposals may allocate UNXV to relayers with high heartbeat scores.

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

##### Flow & UX Summary — Phase 6
- **Market Creation**: DAO executes `perps::market::add_market` (symbol, leverage limits). UI auto-lists new tab.
- **Open / Close**: Traders call `perps::clearing::{open,close}`; positions live in `perps::account::CrossMargin`.
- **Funding**: Keeper triggers `perps::funding::tick` hourly; 10 % skim goes to `fee_sink::perps::on_funding_skim`.
- **Margin Ops**: `add_margin` adds collateral; `withdraw` frees excess if safe.
- **Liquidation**: `perps::liquidation::liquidate` closes positions below maintenance margin; deficits tap `insurance::perps::Fund`.
- **Planned helpers**: `perps::market::update_params`, `perps::account::get_liq_price`, `insurance::perps::slash`.

---

## 📅 Phase 7 — Dated Futures
*(light delta since shares margin engine with perps)*

### On-Chain
| Module | Note |
|--------|------|
| `futures::series` | Immutable params per expiry |
| `futures::clearing` | Settle at expiry TWAP |
| `futures::factory` | Permissionless series listing w/ bond & veto |
| `fee_sink::futures` | 5 bps fee → UNXV split |

### Off-Chain
- Keeper to call `freeze_price()` 30 min pre-expiry & `settle_expiry()`.

### UI
- Futures calendar, basis chart, expiry settlement timeline.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

##### Flow & UX Summary — Phase 7
Two avenues to list a new dated-future series:

1. **DAO Path (governance proposal)**  
   • The Timelock/governor calls `futures::factory::create_series_dao`, which bypasses the bond/veto mechanics and activates instantly.  Ideal for quarterly "official" expiries.  

2. **Permissionless Path**  
   • Any account may call `futures::factory::create_series_user` (same as previous `create_series`) posting an UNXV bond.  A 12-hour guardian/DAO veto window can cancel unsafe listings; bond is slashed on veto/spam.

Shared flow after activation:  
• `SeriesActivated` event fires → relayers/UI auto-list.  
• Traders use RFQ fills into `futures::clearing::fill_orders`.  
• Keeper runs `freeze_price()` 30 min pre-expiry, then `settle_expiry()` handles PnL.  

Planned helpers: `futures::series::pause`, `futures::clearing::close_position`, `futures::factory::update_bond_size`.

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

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

##### Flow & UX Summary — Phase 8
- **Write Options**: Sellers lock collateral via `options::clearing::write`, minting option tokens.
- **RFQ Buy**: Buyers present signed RFQ to `options::clearing::buy`; premium transfers atomically.
- **Exercise**: If ITM after expiry, holders call `exercise` for payout.
- **Liquidations**: `liquidate_writer` seizes collateral when writers under-collateralise.
- **Planned helpers**: `options::series::create`, `options::series::update_iv_cap`, `options::clearing::close`.

---

## 🎪 Phase 9 — Exotics α
*(Barrier options, range accruals, power perps)*

### On-Chain
Shared margin + new `exotics::*` engine; see `exotics.md`.

### Off-Chain
- Barrier monitor daemon storing min/max price ring-buffer.

### UI
- Pay-off graph playground, live barrier status badge.

### Tests / Audits
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

##### Flow & UX Summary — Phase 9
- **Barrier Watch**: Off-chain daemon feeds prices into `exotics::engine::knock_check` to update status.
- **Settle**: Anyone can call `engine::settle` after barrier event or expiry to distribute payouts.
- **UI**: Dashboard shows live barrier badge and payoff graph.
- **Planned helpers**: `exotics::series::create`, barrier-type enum, `exotics::engine::pause`.

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

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

##### Flow & UX Summary — Phase 10
- **Deposit**: `lp::vault::deposit` mints shares proportional to NAV.
- **Rebalance**: Keeper calls `lp::strategy_base::rebalance`; PnL reported via `lp::vault::report` and fees skimmed.
- **Withdraw**: `lp::vault::withdraw` burns shares and returns assets.
- **Planned helpers**: `lp::vault::set_strategy`, `lp::vault::pause`, performance-fee setter.

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

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

##### Flow & UX Summary — Phase 11
- **Stake**: `lstake::vault::deposit` swaps SUI → sSUI (rebasing).
- **Unstake**: `request_unstake` moves sSUI into a batch claimable after `claim_epoch`.
- **Claim**: After epoch, `claim` redeems SUI minus skim via `fee_sink::lstake`.
- **Planned helpers**: `lstake::vault::rebalance_validators`, `lstake::vault::compound_rewards`.

---

## ⛽ Phase 12 — Gas Futures
*(see `gasfut.md` for detail)*

### On-Chain
`gasfut::*` series, AMM, reserve pool, risk module.
+`gasfut::factory` permissionless series listing (bond + guardian veto).

### Off-Chain
- Δ-hedge daemon shorting SUI/USDC perps when reserve Δ rises.

### UI
- Quote widget: break-even vs historic gas volatility.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

##### Flow & UX Summary — Phase 12
- **Permissionless Listing**: Anyone can call `gasfut::factory::create_series_user` with `{expiry, contract_size}` and post an UNXV bond. Guardians have 12 h to `veto` unsafe listings; bond is slashed on veto or spam.
- **DAO Listing**: Timelock/governor may instead call `gasfut::factory::create_series_dao` for immediate activation with no bond.
- **Series Activation**: After activation (or after veto window), a `GasSeriesActivated` event is emitted; relayers auto-list the contract in the gas-futures quote widget.
- **Trading Exposure**: Users trade exposure through `gasfut::amm::swap`, quoting against a virtual reserve; price tracks implied gas volatility.
- **Reserve Hedging**: Off-chain daemon monitors AMM Δ and hedges via SUI/USDC perps, keeping the pool delta-neutral.
- **Settlement**: Keeper (or anyone) calls `gasfut::series::settle_expiry` at maturity to transfer PnL; user-path bond is refunded if volume > MIN_VOL.
- **Planned helpers**: `gasfut::amm::add_liquidity`, `gasfut::factory::update_bond_size`.

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

---

## 📘 Appendix A — Comprehensive Module Pseudocode
*High-level Move skeletons for every module across all phases. Function names, visibility, and key resource fields serve as guidance during development. Error handling, events, and full generics intentionally omitted for brevity.*

> **Legend**  
> `has key` → object stored on chain  
> `has store` → generic type param  
> `ctx: &mut TxContext` → Sui transaction context  
> `sig: &signer` → required signer for mutating auth

### Phase 1 — DAO Genesis

#### `unxv::coin`
```move
module unxv::coin {
    struct Supply has key { total: u64 }
    public fun initialise(sig: &signer, total: u64, ctx: &mut TxContext);
    public fun mint(sig: &signer, amount: u64, ctx: &mut TxContext): Coin<UNXV>;
    public fun burn(sig: &signer, coin: Coin<UNXV>, ctx: &mut TxContext);
    public fun transfer(from: &signer, to: address, amount: u64, ctx: &mut TxContext);
}
```

#### `unxv_ve::locker`
```move
module unxv_ve::locker {
    struct Locker has key {
        id: UID,
        owner: address,
        amount: u64,
        unlock_ts: u64,
        slope: u128,
        bias: u128,
        delegate: address,
    }
    public fun lock(sig: &signer, amount: u64, duration_sec: u64, ctx: &mut TxContext): Locker;
    public fun extend(sig: &signer, locker: &mut Locker, add_dur: u64);
    public fun merge(sig: &signer, a:&mut Locker, b: Locker);
    public fun delegate(sig: &signer, locker:&mut Locker, to: address);
}
```

#### `gov::bravo`
```move
module gov::bravo {
    struct Proposal has key { id: u64, proposer: address, eta: u64, executed: bool, canceled: bool }
    public fun propose(sig:&signer, targets: vector<address>, values: vector<u64>, calldatas: vector<vector<u8>>, description: vector<u8>, ctx:&mut TxContext): Proposal;
    public fun cast_vote(sig:&signer, proposal_id:u64, support:bool);
    public fun queue(sig:&signer, proposal_id:u64, ctx:&mut TxContext);
    public fun execute(sig:&signer, proposal_id:u64, ctx:&mut TxContext);
    public fun cancel(sig:&signer, proposal_id:u64);
}
```

#### `gov::timelock`
```move
module gov::timelock {
    struct Timelock has key { delay: u64 }
    public fun queue(sig:&signer, tx: TimelockTx, eta:u64);
    public fun execute(sig:&signer, tx_id:u64, ctx:&mut TxContext);
}
```

#### `treasury::safe`
```move
module treasury::safe {
    struct Safe has key { id: UID, owner: address }
    public fun execute(sig:&signer, safe:&mut Safe, calls: vector<vector<u8>>, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 1
- **Mint & Distribution**: Core multisig calls `unxv::coin::initialise` to mint the full UNXV supply directly into `treasury::safe`. Subsequent token grants use `unxv::coin::transfer`.
- **Lock → Vote Flow**: A holder calls `unxv_ve::locker::lock` which mints an on-chain veNFT (`Locker`). Voting weight decays linearly toward `unlock_ts` via the `bias` field. The dApp UI presents an amount × duration slider and signs the single `lock` call.
- **Delegation**: Owners delegate voting power via `locker::delegate`; this is surfaced in the governance dashboard as "Voting to ...".
- **Proposal Lifecycle**: Any address meeting the threshold calls `gov::bravo::propose`. After voting, `queue` transfers calldata to `gov::timelock`; `execute` becomes callable once the 48 h `delay` has passed.
- **Treasury Actions**: Passed proposals typically invoke `treasury::safe::execute` to fund contributors or trigger upgrades.
- **Planned helper functions**: `unxv_ve::locker::unlock`, `gov::bravo::state`, `treasury::safe::deposit`.

---

### Phase 2 — Spot DEX Wrapper

#### `dex::router`
```move
module dex::router {
    public fun place_limit(sig:&signer, market: address, side:u8, price:u64, size:u64, relayer: option<address>, ctx:&mut TxContext);
    public fun cancel(sig:&signer, market: address, order_id: u128, ctx:&mut TxContext);
    public fun batch(sig:&signer, calls: vector<vector<u8>>, ctx:&mut TxContext);
}
```

#### `fee_sink::dex`
```move
module fee_sink::dex {
    public fun on_fill(asset: Coin<T>, fee_bps: u64, relayer: option<address>, ctx:&mut TxContext);
}
```

#### `relayer::registry`
```move
module relayer::registry {
    struct Relayer has key { id: UID, addr: address, score: u64 }
    public fun register(sig:&signer, ctx:&mut TxContext): Relayer;
    public fun slash(sig:&signer, relayer:&mut Relayer, delta:u64);
    public fun boost(sig:&signer, relayer:&mut Relayer, delta:u64);
}
```

##### Flow & UX Summary — Phase 2
- **Place / Cancel Orders**: Traders sign `dex::router::place_limit` or `batch`; the router forwards to DeepBook and emits `PlaceEvent` for relayer meshes.
- **Realtime Orderbook**: Relayers stream DeepBook events over WebSocket; the Next.js GUI merges deltas for sub-100 ms depth rendering.
- **Fee Capture**: `fee_sink::dex::on_fill` swaps taker fees to UNXV and credits the treasury in the same tx.
- **Relayer Reputation**: Market-makers call `relayer::registry::register`. Scores are DAO-governed via `boost` / `slash`.
- **Planned helper functions**: `dex::router::place_market`, `dex::router::cancel_all`, `relayer::registry::deregister`.

---

### Phase 3 — Synthetic Assets

#### `synth::vault`
```move
module synth::vault {
    struct Position has key { id: UID, owner: address, collateral_usdc: u64, debt_shares: u128 }
    struct GlobalDebt has key { id: UID, total_debt_usd: u128, total_shares:u128 }
    public fun deposit(sig:&signer, usdc: Coin<USDC>, ctx:&mut TxContext);
    public fun mint<Synth: store>(sig:&signer, amount: u64, ctx:&mut TxContext);
    public fun burn<Synth: store>(sig:&signer, amount: u64, ctx:&mut TxContext);
    public fun withdraw(sig:&signer, usdc_amount: u64, ctx:&mut TxContext);
}
```

#### `synth::factory`
```move
module synth::factory {
    struct SynthInfo has key { id: UID, price_id: vector<u8>, symbol: vector<u8>, decimals:u8 }
    public fun add_synth(sig:&signer, price_id: vector<u8>, symbol: vector<u8>, dec:u8, ctx:&mut TxContext): SynthInfo;
}
```

#### `fee_sink::mintburn`
```move
module fee_sink::mintburn {
    public fun route(asset: Coin<T>, fee_bps:u64, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 3
- **USDC Collateralisation**: Users deposit USDC using `synth::vault::deposit`, creating a `Position`.
- **Mint Synths**: `mint<Synth>` computes max issuable amount from real-time collateral ratio via `GlobalDebt`, mints synth coins, and increases `debt_shares`.
- **Burn & Withdraw**: `burn<Synth>` repays debt; once health ≥ threshold, `withdraw` returns surplus collateral.
- **Asset Listing**: Governors add new synths through `synth::factory::add_synth` (price ID + symbol). The front-end auto-lists pairs.
- **Planned helpers**: `synth::vault::liquidate`, `synth::vault::health_factor`, `synth::factory::pause_synth`.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 4 — Lending Market

#### `lend::pool`
```move
module lend::pool {
    struct MarketInfo has key { asset: TypeTag, reserve_factor: u64, collateral_factor: u64 }
    struct AccountLiquidity has key { id: UID, owner: address, borrows: vector<(TypeTag,u128)>, collaterals: vector<(TypeTag,u128)> }
    public fun supply<T: store>(sig:&signer, amount:u64, ctx:&mut TxContext);
    public fun withdraw<T: store>(sig:&signer, u_tokens:u64, ctx:&mut TxContext);
    public fun borrow<T: store>(sig:&signer, amount:u64, ctx:&mut TxContext);
    public fun repay<T: store>(sig:&signer, amount:u64, ctx:&mut TxContext);
    public fun accrue_interest<T: store>(market:&mut MarketInfo, ctx:&mut TxContext);
}
```

#### `lend::utoken`
```move
module lend::utoken {
    struct UToken<T> has key, store { supply:u128 }
    public fun mint<T: store>(sig:&signer, underlying: Coin<T>, ctx:&mut TxContext): Coin<UToken<T>>;
    public fun redeem<T: store>(sig:&signer, u_token: Coin<UToken<T>>, ctx:&mut TxContext): Coin<T>;
}
```

#### `lend::flashloan`
```move
module lend::flashloan {
    public fun execute<T: store>(sig:&signer, pool: address, amount:u64, payload: vector<u8>, ctx:&mut TxContext);
}
```

#### `lend::liquidation`
```move
module lend::liquidation {
    public fun liquidate<T: store>(sig:&signer, borrower: address, repay_asset: TypeTag, max_repay:u64, ctx:&mut TxContext);
}
```

#### `fee_sink::reserve`
```move
module fee_sink::reserve {
    public fun on_accrue<T: store>(asset: Coin<T>, reserve_factor:u64, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 4
- **Supply & uToken Mint**: Users supply assets via `lend::pool::supply<T>` which mints `UToken<T>` via `lend::utoken::mint`; APY shows through exchange rate.
- **Borrowing**: `lend::pool::borrow<U>` allows leveraged positions, tracked in `AccountLiquidity`.
- **Interest & Reserves**: `accrue_interest` runs per block (keeper/on-demand) and routes reserve factor to `fee_sink::reserve::on_accrue`.
- **Flash Loans**: `lend::flashloan::execute` grants atomic loans that must be repaid within tx.
- **Liquidations**: `lend::liquidation::liquidate` repays debt and seizes collateral when accounts fall below threshold.
- **Planned helpers**: `lend::pool::{enter_market,exit_market,pause_asset}`, `lend::liquidation::set_close_factor`.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 5 — Relayer Mesh (off-chain only)
*No new on-chain modules; omitted.*

### Tests / Audits
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

##### Flow & UX Summary — Phase 5
- **Mesh Node**: `relayer-node start` indexes on-chain events and broadcasts order-book diffs over WS + gossip.
- **Aggregator Snapshot**: A cloud worker periodically uploads compressed snapshots for quick client bootstrap.
- **Client Sync**: UI loads snapshot → verifies → subscribes to live stream for ms-latency data.
- **Uptime Rewards**: Future DAO proposals may allocate UNXV to relayers with high heartbeat scores.

### Tests / Audits
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

---

### Phase 6 — Perpetual Futures

#### `perps::market`
```move
module perps::market {
    struct MarketInfo has key { id: UID, symbol: vector<u8>, max_leverage:u64, maint_margin:u64, funding_cap:u64 }
    public fun add_market(sig:&signer, info: MarketInfo, ctx:&mut TxContext);
}
```

#### `perps::account`
```move
module perps::account {
    struct CrossMargin has key { id: UID, owner: address, collateral_usd:u64, positions: vector<(address, Position)> }
    struct Position { size:i128, entry_price:u128, last_funding:u128 }
}
```

#### `perps::clearing`
```move
module perps::clearing {
    public fun open(sig:&signer, market: address, notional:u64, side: bool, ctx:&mut TxContext);
    public fun close(sig:&signer, market: address, notional:u64, ctx:&mut TxContext);
    public fun add_margin(sig:&signer, usdc: Coin<USDC>, ctx:&mut TxContext);
    public fun withdraw(sig:&signer, amount:u64, ctx:&mut TxContext);
}
```

#### `perps::funding`
```move
module perps::funding {
    public fun tick(market:&mut perps::market::MarketInfo, ctx:&mut TxContext);
}
```

#### `perps::liquidation`
```move
module perps::liquidation {
    public fun liquidate(sig:&signer, trader: address, market: address, max_close:u64, ctx:&mut TxContext);
}
```

#### `insurance::perps`
```move
module insurance::perps {
    struct Fund has key { id: UID, balance_unxv:u64 }
    public fun deposit(sig:&signer, amt: Coin<UNXV>, ctx:&mut TxContext);
    public fun pay(trader: address, usd_amount:u64, ctx:&mut TxContext);
}
```

#### `fee_sink::perps`
```move
module fee_sink::perps {
    public fun on_taker_fee(asset: Coin<T>, ctx:&mut TxContext);
    public fun on_funding_skim(asset: Coin<T>, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 6
- **Market Creation**: DAO executes `perps::market::add_market` (symbol, leverage limits). UI auto-lists new tab.
- **Open / Close**: Traders call `perps::clearing::{open,close}`; positions live in `perps::account::CrossMargin`.
- **Funding**: Keeper triggers `perps::funding::tick` hourly; 10 % skim goes to `fee_sink::perps::on_funding_skim`.
- **Margin Ops**: `add_margin` adds collateral; `withdraw` frees excess if safe.
- **Liquidation**: `perps::liquidation::liquidate` closes positions below maintenance margin; deficits tap `insurance::perps::Fund`.
- **Planned helpers**: `perps::market::update_params`, `perps::account::get_liq_price`, `insurance::perps::slash`.

### Tests / Audits
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

---

### Phase 7 — Dated Futures
```move
module futures::series {
    struct FutureSeries has key { id: UID, asset: vector<u8>, expiry:u64, max_leverage:u64 }
}

module futures::clearing {
    public fun fill_orders(sig:&signer, series: address, orders: vector<u128>, sizes: vector<u64>, ctx:&mut TxContext);
    public fun settle_expiry(sig:&signer, series: address, ctx:&mut TxContext);
}
```

#### `futures::factory`
```move
module futures::factory {
    struct ListingBond has key { id: UID, amount: u64 }

    /// Governor/Timelock-only instant listing (no bond, no veto window).
    public fun create_series_dao(
        sig:&signer,
        underlier: vector<u8>,
        expiry: u64,
        max_leverage:u64,
        ctx:&mut TxContext
    ): address;

    /// Permissionless listing.  Caller posts `bond`; subject to guardian veto.
    public fun create_series_user(
        sig:&signer,
        underlier: vector<u8>,
        expiry: u64,
        max_leverage:u64,
        bond: Coin<UNXV>,
        ctx:&mut TxContext
    ): address;

    /// Guardian / DAO veto within window.
    public fun veto(sig:&signer, series: address, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 7
Two avenues to list a new dated-future series:

1. **DAO Path (governance proposal)**  
   • The Timelock/governor calls `futures::factory::create_series_dao`, which bypasses the bond/veto mechanics and activates instantly.  Ideal for quarterly "official" expiries.  

2. **Permissionless Path**  
   • Any account may call `futures::factory::create_series_user` (same as previous `create_series`) posting an UNXV bond.  A 12-hour guardian/DAO veto window can cancel unsafe listings; bond is slashed on veto/spam.

Shared flow after activation:  
• `SeriesActivated` event fires → relayers/UI auto-list.  
• Traders use RFQ fills into `futures::clearing::fill_orders`.  
• Keeper runs `freeze_price()` 30 min pre-expiry, then `settle_expiry()` handles PnL.  

Planned helpers: `futures::series::pause`, `futures::clearing::close_position`, `futures::factory::update_bond_size`.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 8 — Options
```move
module options::series {
    struct OptionSeries has key { id: UID, underlier: vector<u8>, strike:u128, expiry:u64, iv_cap:u64, call: bool }
}

module options::clearing {
    public fun write(sig:&signer, series: address, contracts:u64, collateral: Coin<USDC>, ctx:&mut TxContext);
    public fun buy(sig:&signer, series: address, contracts:u64, premium: Coin<USDC>, ctx:&mut TxContext);
    public fun exercise(sig:&signer, series: address, ctx:&mut TxContext);
    public fun liquidate_writer(sig:&signer, writer: address, series: address, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 8
- **Write Options**: Sellers lock collateral via `options::clearing::write`, minting option tokens.
- **RFQ Buy**: Buyers present signed RFQ to `options::clearing::buy`; premium transfers atomically.
- **Exercise**: If ITM after expiry, holders call `exercise` for payout.
- **Liquidations**: `liquidate_writer` seizes collateral when writers under-collateralise.
- **Planned helpers**: `options::series::create`, `options::series::update_iv_cap`, `options::clearing::close`.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 9 — Exotics (selected)
```move
module exotics::series { /* similar to options */ }
module exotics::engine {
    public fun knock_check(price:u128, series: address);
    public fun settle(sig:&signer, series: address, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 9
- **Barrier Watch**: Off-chain daemon feeds prices into `exotics::engine::knock_check` to update status.
- **Settle**: Anyone can call `engine::settle` after barrier event or expiry to distribute payouts.
- **UI**: Dashboard shows live barrier badge and payoff graph.
- **Planned helpers**: `exotics::series::create`, barrier-type enum, `exotics::engine::pause`.

### Tests
- Suiet fuzz on funding math.  
- External audit (Trail of Bits) pre-mainnet.

---

### Phase 10 — LP Vaults
```move
module lp::vault {
    struct VaultConfig has key { id: UID, asset: TypeTag, strategy: address, tvl_cap:u128 }
    struct DepositorPosition has key { id: UID, shares:u128 }
    public fun deposit<T: store>(sig:&signer, asset: Coin<T>, ctx:&mut TxContext);
    public fun withdraw<T: store>(sig:&signer, shares:u128, ctx:&mut TxContext);
    public fun report(sig:&signer, vault:&mut VaultConfig, pnl:u128, ctx:&mut TxContext);
}

module lp::strategy_base {
    public fun rebalance(vault: &mut lp::vault::VaultConfig, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 10
- **Deposit**: `lp::vault::deposit` mints shares proportional to NAV.
- **Rebalance**: Keeper calls `lp::strategy_base::rebalance`; PnL reported via `lp::vault::report` and fees skimmed.
- **Withdraw**: `lp::vault::withdraw` burns shares and returns assets.
- **Planned helpers**: `lp::vault::set_strategy`, `lp::vault::pause`, performance-fee setter.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 11 — Liquid Staking
```move
module lstake::vault {
    struct StakePool has key { id: UID, total_sui:u128, total_shares:u128 }
    struct StakeBatch has key { id: UID, amount:u64, claim_epoch:u64 }
    public fun deposit(sig:&signer, sui: Coin<SUI>, ctx:&mut TxContext): Coin<sSUI>;
    public fun request_unstake(sig:&signer, s_sui: Coin<sSUI>, ctx:&mut TxContext);
    public fun claim(sig:&signer, batch_id: u64, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 11
- **Stake**: `lstake::vault::deposit` swaps SUI → sSUI (rebasing).
- **Unstake**: `request_unstake` moves sSUI into a batch claimable after `claim_epoch`.
- **Claim**: After epoch, `claim` redeems SUI minus skim via `fee_sink::lstake`.
- **Planned helpers**: `lstake::vault::rebalance_validators`, `lstake::vault::compound_rewards`.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 12 — Gas Futures
```move
module gasfut::series { /* similar concept to futures::series */ }
module gasfut::amm { public fun swap(sig:&signer, in_coin: Coin<T>, out_min:u64, ctx:&mut TxContext); }
```

#### `gasfut::factory`
```move
module gasfut::factory {
    struct GasSeriesBond has key { id: UID, amount:u64 }

    /// Governor/Timelock direct listing.
    public fun create_series_dao(
        sig:&signer,
        expiry:u64,
        contract_size:u64,
        ctx:&mut TxContext
    ): address;

    /// Permissionless listing with bond + veto window.
    public fun create_series_user(
        sig:&signer,
        expiry:u64,
        contract_size:u64,
        bond: Coin<UNXV>,
        ctx:&mut TxContext
    ): address;

    public fun veto(sig:&signer, series: address, ctx:&mut TxContext);
}
```

##### Flow & UX Summary — Phase 12
- **Permissionless Listing**: Anyone can call `gasfut::factory::create_series_user` with `{expiry, contract_size}` and post an UNXV bond. Guardians have 12 h to `veto` unsafe listings; bond is slashed on veto or spam.
- **DAO Listing**: Timelock/governor may instead call `gasfut::factory::create_series_dao` for immediate activation with no bond.
- **Series Activation**: After activation (or after veto window), a `GasSeriesActivated` event is emitted; relayers auto-list the contract in the gas-futures quote widget.
- **Trading Exposure**: Users trade exposure through `gasfut::amm::swap`, quoting against a virtual reserve; price tracks implied gas volatility.
- **Reserve Hedging**: Off-chain daemon monitors AMM Δ and hedges via SUI/USDC perps, keeping the pool delta-neutral.
- **Settlement**: Keeper (or anyone) calls `gasfut::series::settle_expiry` at maturity to transfer PnL; user-path bond is refunded if volume > MIN_VOL.
- **Planned helpers**: `gasfut::amm::add_liquidity`, `gasfut::factory::update_bond_size`.

### Tests
- Invariant: totalCash + totalBorrows + reserves = assets().

---

### Phase 13 — Infrastructure Tooling
*Purely off-chain helpers—pseudocode omitted.*

### Phase 14 — Cross-Chain Bridge
*Relies on Wormhole contracts; separate spec.*

---

### 🛠️ Next Steps
1. Convert these skeletons into full Move packages with access modifiers, events, and exhaustive tests.  
2. Flesh-out error codes, authority models, and integration points.  
3. Iterate module-by-module following the phase order in this document. 