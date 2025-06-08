# Sample Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a Hardhat Ignition module that deploys that contract.

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat ignition deploy ./ignition/modules/Lock.ts
```


Oracle Flow

```
Ethereum L1 (Not used for OracleRelayerSrc in this scenario)

        |
        |
        V

Polygon (or other L2/Sidechain)
+---------------------------------+
|      Chainlink Aggregators      | --(reads price)--> OracleRelayerSrc.sol
|        (e.g., BTC/USD)          |                    (on Polygon)
+---------------------------------+                        |
                                                           |--(sends LZ message via Polygon L0 Endpoint)-+
                                                           |                                            |
                                                           V                                            |
                                                    LayerZero Network                                   |
                                                           |                                            |
                                                           |                                            |
                                                           V                                            |
Peaq EVM                                                                                                |
+---------------------------------+                                                                     |
| OracleRelayerDst.sol            | <--(receives LZ message via Peaq L0 Endpoint)-------------------------+
|   (on Peaq)                     |
+---------------------------------+
      |
      | --(getPrice)--> Unxversal Synth, Lend, Perps (on Peaq)
      V
```


I'm building a suite of defi protocols, descriptions below.

unxversal dex — full-stack architecture
0. Why it exists

Pool-based AMMs waste capital and can’t express limit prices.

CEXs have great UX but need trust.
unxversal dex merges both worlds: a pure-on-chain settlement engine with off-chain, permissionless discovery powered by NFT-encoded orders.

1. Smart-contract core (Solidity)
flowchart TD
    subgraph "1. Smart Contract Core (Solidity)"
        A["OrderNFT (ERC-721)"] --> B["PermitHelper"]
        B --> C["FeeSwitch"]
    end

    subgraph "2. On-Chain Guarantees"
        D["Atomicity"] --> E["Price-Time Priority"]
        E --> F["No Re-Entrancy"]
        F --> G["Upgradeable Frontend"]
    end

    subgraph "3. Indexer/Relayer Network"
        H["Event Replayer"] --> I["Live Streamer"]
        I --> J["REST/GraphQL API"]
        J --> K["P2P Gossip Network"]
    end

    subgraph "4. Client-Side Stack"
        L["Wallet"] --> M["unxv-SDK"]
        M --> N["Helper"]
        M --> O["Cache"]
        M --> P["RPC"]
        M --> Q["Indexer Connector"]
    end

    subgraph "5. User Flows"
        R["Maker"] --> S["Create Order"]
        T["Taker"] --> U["Fill Order"]
    end

    subgraph "6. Security"
        V["Front-Running"] --> W["Indexer Censorship"]
        W --> X["Fake Tokens"]
        X --> Y["Price Overflow"]
    end

    A --> D
    C --> H
    J --> M
    M --> R
    M --> T
    D --> V

Contract	Purpose	Key funcs
OrderNFT (ERC-721)	Stores every maker order as an NFT with mutable amountRemaining.	createOrder() → mint • fillOrders() → batch-settle • cancelOrder() → burn
PermitHelper	Optional module that accepts ERC-2612 / Permit2 signatures so makers & takers skip the stand-alone approve().	permitAndCreate(), permitAndFill()
FeeSwitch (upgrade-free)	Immutable fee vars collected inside fillOrders(); can be set to 0 at deployment or hard-coded.	setFeeRecipient() (one-time)

All contracts are deployed once and never re-initialised; there is no factory, no pair registry.

Order record (packed into one storage slot for gas)
struct Order {
  address  maker;        // 160 bits
  uint32   expiry;       //  32 bits
  uint24   feeBps;       //  24 bits
  uint8    sellDecimals; //   8 bits
  // ---- slot boundary (224) ----
  uint256  amountRemaining;   // 256 bits
  address  sellToken;         // 160 bits (separate slot)
  address  buyToken;          // 160 bits
  uint256  price;             // 256 bits (18-dec fixed-point)
}
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Gas: ~ 95 k for createOrder, ~ 35 k per order inside fillOrders().

2. On-chain guarantees

Atomicity – a batch either settles all requested fills or reverts; partial execution never leaks.

Price-time priority – enforced implicitly: contract only checks bounds, while the taker chooses order array order; indexers police fairness by filtering.

No re-entrancy – pulls tokens before external transfers, uses single-entry guard.

Upgradeable front-ends, but immutable rules – the core logic is fixed at genesis.

3. Indexer / relayer mesh
Component	What it stores in memory	Protocols
Event Replayer	On startup, scans Order* logs from block 0 → tip	JSON-RPC, WebSocket
Live Streamer	Subscribes to new logs, applies diffs to the book	WSS
REST / GraphQL API	GET /markets, GET /book/:pair, WS /stream	HTTP 1.1 / WS
P2P Gossip (opt.)	libp2p + GossipSub topic unxv-orders-v1 to push deltas peer→peer	TCP / WebRTC

Anyone can run a node; no auth keys, no whitelists.

Canonical pair key

function pairKey(a: Address, b: Address): string {
  return ethers.keccak256(
    ethers.solidityPacked(
      ["address","address"],
      a.toLowerCase() < b.toLowerCase() ? [a,b] : [b,a]
    )
  );
}
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Ts
IGNORE_WHEN_COPYING_END
4. Client-side stack
flowchart LR
    A["Browser/CLI User Process"] --> B["unxv SDK"]
    subgraph B["unxv SDK"]
        direction TB
        C["Helper: matchBest"]
        D["Memory Cache"]
        E["RPC Connector"]
        F["Indexer Pool"]
    end
    B --> G["Ethereum"]
    F --> D
    E --> D
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Mermaid
IGNORE_WHEN_COPYING_END

Auto-heal – SDK races two indexers; if both drop, falls back to slow on-chain log polling.

Trust-but-verify – before signing fillOrders, SDK simulates the call with eth_call using the chosen orders to guarantee the indexer didn’t lie.

Language ports – TS (browser/Node), Rust (CLI/high-perf bots), Python (research notebooks).

5. User flows
Maker

If needed: approve(DEX, amount) or EIP-2612 signature.

createOrder(sellToken, buyToken, amount, price, expiry)

UI instantly renders the pending order while waiting for indexer echo.

Taker

sdk.subscribePair() → local book fills.

matchBest(book, wantToken, qty) produces orderIds[] + fillAmounts[].

fillOrders(orderIds, fillAmounts) (single tx).

SDK monitors OrderFilled to update the cache.

New market listing

The very first createOrder() that references a never-seen pair creates the market automatically.
UI pulls token metadata (symbol, decimals, logo) from token-lists or on-chain fallback.

6. Security & MEV hardening
Risk	Mitigation
Front-running	Users can add deadline + minAmountOut params; taker can route via Flashbots or MEV-Share.
Indexer censorship	Multiple indexers, on-chain log fallback.
Fake tokens	UI-layer allow-list or warning banner; contract itself remains neutral.
Price overflow	price stored as 18-dec fixed-point; range-checked on input.
Token fee-on-transfer	SDK/contract optionally mark tokens as “unsafe”, skip them.
7. Extensibility roadmap

RFQ meta-orders – off-chain signed short-lived quotes that settle through fillOrdersBySig().

Cross-chain – canonical OrderNFT on L2, settlement via shared sequencer or ZK proof back to mainnet.

Batch auctions – periodic batcher contract that nets maker ↔ taker flows and pays only two ERC-20 transfers per price level.

8. Deployment blueprint

Contracts ⇒ Solidity 0.8.x, hard-coded constructor params, verified on Etherscan.

Indexer image ⇒ Docker (unxv/indexer:latest) + .env with RPC_URL, START_BLOCK.

SDK ⇒ npm i @unxv/sdk (published under MIT).

Reference dApp ⇒ Next.js + Wagmi, served from IPFS.

Docs & token-lists ⇒ GitBook + GitHub repo for logo PRs.

9. Key take-aways

Everything liquid is an NFT – an order is a transferable position.

Zero admin friction – any ERC-20 pair, any time, no DAO vote.

Off-chain speed, on-chain trust – matching logic local, settlement atomic.

Composable – other protocols can hold OrderNFTs, build vaults, lend against open orders, etc.

Welcome to unxversal dex – the order-book DEX that stays universal, permissionless, and NFT-native from day 1.

All fee destinations (treasury, oracle-gas vault, insurance funds) are USDC-denominated. Fees received in other assets are auto-swapped to USDC via a whitelisted route at the time of deposit

“unxversal synth” — a sister protocol for USD-collateralised synthetic assets on peaq EVM

Goal Let users lock USDC on peaq and mint tradeable ERC-20 “sAssets” that mirror the price of BTC, ETH, SOL, FX pairs, commodities, etc.
Constraint peaq is not supported by Chainlink, but it is an endpoint in LayerZero.
Assumption A governance / admin address can tweak risk parameters and run oracle keepers.

1 | High-level component map
flowchart TD
  subgraph Off-chain
    Watcher["Price-Watcher<br>(ETH mainnet)"]
    Keeper["Risk-Keeper bots"]
  end
  subgraph "Ethereum (L0 src)"
    Chainlink["Chainlink Aggregator<br>(e.g. BTC/USD)"]
    ZROut["OracleRelayerSrc<br>(sends prices)"]
  end
  subgraph "peaq (L0 dst)"
    ZRIn["OracleRelayerDst<br>(updates prices)"]
    Vault["USDC Vault"]
    SynthFactory["SynthFactory"]
    sBTC["sBTC (ERC-20)"]
    sETH["sETH (ERC-20)"]
    Liquidator["LiquidationEngine"]
    Admin["Admin Role"]
  end
  Watcher -->|fetch & post| ZROut
  ZROut --LayerZero--> ZRIn
  ZRIn -->|setPrice| Vault
  Vault --> SynthFactory
  SynthFactory -->|mint/burn| sBTC
  SynthFactory -->|mint/burn| sETH
  Liquidator --> Vault
  Admin  --> Vault
  Admin --> SynthFactory
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Mermaid
IGNORE_WHEN_COPYING_END
2 | Core smart-contract modules (peaq)
Contract	Function	Mutable knobs
USDCVault	• Holds user collateral<br>• Tracks per-account debt vs. collateral<br>• Emits PositionUpdated	minCR (e.g. 150 %), liquidationPenalty, feeBps
SynthFactory	• Deploys minimal-proxy ERC-20 synths (sBTC, sETH, …)<br>• Records each synth’s oracle ID and risk params	addSynth(assetId, name, symbol, oracle, minCR)
OracleRelayerDst	• Receives LayerZero messages<br>• Stores price and lastUpdated per assetId	Governance can set staleTolerance
LiquidationEngine	• Anyone can call liquidate(account, synthId) if CR < minCR<br>• Seizes USDC plus penalty; burns debt	penaltyBps, keeperRewardBps
AdminModule	• Pause switches, emergency shutdown, fee withdrawal	Governance multisig

All contracts are Ownable but not upgradeable; upgrades go through new-contract, migrate-state flow.

3 | Oracle design without Chainlink on peaq

On Ethereum
An OracleRelayerSrc contract reads any Chainlink Aggregator (latestRoundData) every N blocks.
When abs(oldPrice – newPrice) > δ or time > Δ, it sends a LayerZero message:

struct PriceMsg { uint256 assetId; uint256 price; uint32 ts; }
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

LayerZero endpoint automatically delivers the message to peaq.

OracleRelayerDst decodes and stores the price.
Stale-price guard: Vault refuses mints if now – lastUpdated > staleTolerance.

Fallback: If L0 is down, the admin multisig can post a signed price that must be lower-bound conservative.

Gas model: relayerSrc funds L0 fees from a keeper EOAs; cost << deploying Chainlink node.

4 | User flow
4.1 Deposit & Mint
// 1) user approves USDC to Vault
vault.deposit(10_000 * 1e6);          // 10 000 USDC

// 2) mint 0.1 sBTC (assume BTC = 60 000 USD, CR = 150 %)
vault.mint(sBTC, 0.1 * 1e18);
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Checks inside mint

valueUsd = price(sBTC) * amount / 1e18
newCR    = (collateral + Δ) / (debt + valueUsd)
require(newCR ≥ minCR)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END
4.2 Trade the synth

sBTC, sETH, … are standard ERC-20s:

trade on unxversal dex directly,

provide LP on other peaq AMMs,

transfer cross-chain via LayerZero OFT-wrapper.

4.3 Burn & Withdraw
// user swaps sBTC → USDC on unxversal dex, then:
vault.burn(sBTC, 0.1e18);
vault.withdraw(availableUSDC);
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END
5 | Liquidation mechanics
Step	Formula
Trigger	CR < minCR (≈ 150 %)
Caller	Anyone (keeper, front-runner, even the user)
Amount	Enough debt to restore > targetCR (e.g. 200 %)
Reward	seizedUSDC = repaidDebt × (1 + penaltyBps)<br>split between keeperRewardBps and system fee

Liquidations are single-tx and deterministic; no auction required.

6 | Admin / governance duties
Action	Typical cadence
Add new synth	Vote & deploy via SynthFactory
Tune risk params (minCR, penaltyBps)	Monthly / when volatility spikes
Top-up oracle relayer gas	Automatic bot
Emergency pause	Multisig only, via AdminModule.pauseAll()
Fee withdrawal	Collect USDC fees to treasury address

All critical functions emit AdminAction events so indexers & dashboards remain in sync.

7 | Security checklist
Vector	Mitigation
Oracle spoof	L0 message must originate from whitelisted OracleRelayerSrc; payload includes chainIdSrc & hash-guard.
Price delay	staleTolerance (e.g. 30 min); mint/burn reverts if stale.
USDC depeg	Governance can raise minCR or pause mints.
Contract bugs	Standard OpenZeppelin libs, extensive Foundry fuzzing + immunefi bug-bounty.
Bridged message re-org	RelayerSrc waits ~ L1 finality + N before sending.
8 | Integration with unxversal dex

Synths conform to plain ERC-20 → makers deposit sBTC / sETH the same way.

Takers can execute delta-neutral strategies (e.g. short sBTC vs. long BTC on CEX).

A RouterHelper in the SDK can:

swap USDC → sBTC (via dex orderbook),

call vault.depositAndMint() in one transaction (permit support).

9 | Minimum viable launch plan

Deploy core contracts on peaq with admin multisig.

Deploy OracleRelayerSrc on Ethereum; whitelist 3 keeper EOAs.

List sBTC, sETH, sSOL (all 18 dec) with minCR = 160 %.

Publish TypeScript SDK v0.1 (@unxv/synth-sdk).

Add synth toggle in the reference Next.js dApp.

Announce bug bounty → 2 weeks testnet → mainnet.

10 | Key take-aways

USDC-only collateral keeps accounting simple and mirrors real-world dollars.

LayerZero relay sidesteps peaq’s lack of native oracle networks while retaining on-chain verifiability.

The design stays fully permissionless for users yet leaves an admin circuit-breaker for risk.

Seamless composability with unxversal dex turns synths into first-class, limit-tradable assets from day 1.

All fee destinations (treasury, oracle-gas vault, insurance funds) are USDC-denominated. Fees received in other assets are auto-swapped to USDC via a whitelisted route at the time of deposit

unxversal lend — permissionless lending & borrowing layer for the peaq EVM
Objective	Turn any ERC-20—including USDC, sAssets, and “real” tokens—into productive collateral that can be borrowed against or lent out to earn yield.
Why peaq?	Low fees, LayerZero endpoint → cross-chain liquidity routes, but no native Chainlink → we recycle the LayerZero oracle relayer already built for unxversal synth.
Governance	A multisig “Admin” role sets risk parameters and can pause markets, but all day-to-day operations are autonomous & on-chain.
1. Component map
flowchart TD
  subgraph "Off-chain"
    Keeper["Liquidation Bots"]
    OracleRelayerSrc["OracleRelayerSrc\n(Ethereum + Chainlink)"]
  end
  subgraph "peaq"
    OracleRelayerDst["OracleRelayerDst"]
    Controller["RiskController"]
    Pool["CorePool"]
    MarketUSDC["uUSDC (receipt)"]
    MarketETH["uWETH"]
    MarketsSynth["sBTC, sETH, etc."]
    LiquidationEngine["LiquidationEngine"]
    Admin["Admin"]
  end
  OracleRelayerSrc -- "LayerZero" --> OracleRelayerDst
  OracleRelayerDst --> Controller
  Controller --> Pool
  Pool -- "mints" --> MarketUSDC
  Pool -- "mints" --> MarketETH
  Pool -- "mints" --> MarketsSynth
  LiquidationEngine --> Pool
  Keeper --> LiquidationEngine
  Admin --> Controller
  Admin --> Pool
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Mermaid
IGNORE_WHEN_COPYING_END
2. Smart-contract modules
Contract	What it does	Key mutables
uToken (ERC-20)	Interest-bearing receipt token (e.g. uUSDC). 1 uUSDC ↔ 1 USDC at initial time; exchange-rate grows as interest accrues.	immutable after deploy
CorePool	Tracks supplied & borrowed balances per asset; accrues interest per block; mints/burns uTokens.	reserveFactor, flashFeeBps
InterestRateModel	Piece-wise linear borrowRate(u) where u = borrowed/liquidity.	base, slope1, slope2, kink
RiskController	Stores collateral factors, liquidation bonus, price oracle ref; gate-keeps all Pool ops.	collateralFactor[asset], liqBonus[asset]
OracleRelayerDst	Same LayerZero sink used by unxversal synth; getPrice(asset) view for Controller.	staleTolerance
LiquidationEngine	Anyone can repay under-collateralised debt and seize collateral with bonus.	closeFactorBps, liqBonusBps
AdminModule	Pause switches, list/unlist assets, sweep fees.	multisig only

All contracts are non-upgradeable; new versions are deployed side-by-side and state is migrated by users.

3. Lifecycle flows
3.1 Supply (lend)
IERC20(USDC).approve(Pool, 10_000e6);
Pool.supply(USDC, 10_000e6, msg.sender);   // mints uUSDC to lender
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Exchange-rate math

uMinted = amount / exchangeRate;         // starts at 1.0, rises over time
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Interest accrues to the exchangeRate; lender balance grows without extra txs.

3.2 Borrow
Pool.borrow(sETH, 500e18);               // borrow 500 sETH
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Checks performed by RiskController:

valueBorrowedUSD = price(sETH)*500
valueCollateralUSD = Σ(supplied_i * collateralFactor_i * price_i)
require(valueBorrowedUSD ≤ valueCollateralUSD)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Interest on the borrow balance accrues each block:

borrowIndex_next = borrowIndex_curr * (1 + borrowRate * Δblocks)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END
3.3 Repay & withdraw
Pool.repay(sETH, 500e18);
Pool.withdraw(USDC, 1_000e6);
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Repayment reduces borrower’s debt; withdrawal burns uTokens at current exchange-rate.

3.4 Liquidation
Trigger	healthFactor = collateralUSD / debtUSD falls below 1.0
Action	Any keeper calls liquidate(borrower, repayAsset, maxRepay)
Result	Repays up to closeFactor of debt, seizes collateral at 1 + liqBonus discount

Keepers can instantly trade seized collateral on unxversal dex or use a flash-borrow from the Pool itself.

4. Interest-rate curve (per asset)
borrowRate(u)
         ▲
 highSlope2|                /
           |               /
           |              /
 slope1    |            /
           |          /
  baseRate |________/________  u (utilization)
                    kink
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Typical params:

Asset	base	slope1	slope2	kink	reserveFactor
USDC	0 %	5 %	300 %	80 %	10 %
WETH	0.5 %	8 %	400 %	75 %	15 %
sBTC	1 %	10 %	500 %	70 %	20 %

reserveFactor diverts a share of interest to the protocol treasury.

5. Oracle design (no Chainlink on peaq)

Exactly the same pipeline as unxversal synth:

On Ethereum OracleRelayerSrc reads Chainlink, packs {assetId, price, ts} and sends through LayerZero.

On peaq OracleRelayerDst stores price & timestamp.

RiskController refuses any action if now - ts > staleTolerance (e.g. 30 min).

For assets that only exist on peaq (governance token, LP shares):

Use a TWAP from* unxversal dex**:*

price = TWAP(lastNTrades, 30 min);   // computed on-chain via rolling oracle window
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

The admin can assign either LayerZero oracle ID or DEX-TWAP per asset.

6. Cross-protocol synergies
With…	Integration
unxversal dex	Liquidators can batch: flashBorrow → swap on dex → repay + seize collateral in a single tx.
unxversal synth	sAssets are borrowable → users can open delta-neutral shorts (borrow sBTC, sell on dex).
LayerZero OFT	uTokens can be bridged as OFT-v2 to other chains, keeping interest accrual consistent.
7. Admin / governance playbook
Task	Frequency
List new asset	Audit token, set collateralFactor, deploy uToken, add to Controller
Tune factors	When volatility or liquidity profile changes
Sweep reserves	Monthly; sends accrued USDC to treasury multisig
Pause market	Emergency only (pause(asset) halts new borrows & liquidations but allows repays)

All admin txs emit AdminEvent logs for dashboards.

8. Security & economic safeguards
Risk	Counter-measure
Oracle outage	staleTolerance check; admin can switch to DEX-TWAP fallback.
Bad collateral factor	Factors begin conservative (e.g. 65 %) and can only be decreased quickly; increases have 48-h timelock.
Insolvent flash-loan	Flash-borrow must return amount + fee within same tx or reverts.
Interest-rate manipulation	Curve params only owner-set with 24-h timelock; changes broadcast in advance.
Re-entrancy	CEI pattern + OpenZeppelin guards on every external call.
9. MVP launch checklist

Audit contracts (Code4rena contest + formal verification of interest math).

Deploy USDC, WETH, sETH, sBTC markets with conservative factors.

Publish TypeScript SDK (@unxv/lend-sdk) sharing utils with dex & synth packages.

Integrate supply/borrow UI panels into the existing Next.js dApp.

Provide in-browser liquidation bot example + docs for pro keepers.

Run 2-week incentivised testnet with bug bounty.

Mainnet launch with 3 M USDC protocol insurance fund (treasury-seeded).

The payoff

Composability – one shared oracle, one shared liquidation economy, three products (dex, synth, lend) that reinforce each other.

Capital efficiency – users can lever up synth exposure, market-make on unxversal dex, or farm interest—all with the same collateral.

Trust-minimised – immutable core, transparent oracles, open liquidations.

LayerZero-ready – prices in, assets out, future cross-chain money markets baked in.

unxversal lend completes the stack: trade, create, and now earn on any asset in the peaq ecosystem.

All fee destinations (treasury, oracle-gas vault, insurance funds) are USDC-denominated. Fees received in other assets are auto-swapped to USDC via a whitelisted route at the time of deposit

unxversal perps — cross-margin perpetual futures on peaq EVM

Mission Let traders go long / short with up to 20× leverage on BTC, ETH, SOL, sAssets, or any ERC-20 that has a reliable oracle price, while re-using the oracle, liquidation, and LayerZero rails already deployed for unxversal synth and unxversal lend.
Approach Central-clearinghouse smart contracts (no LP vAMM), off-chain price-time order-matching identical to the unxversal dex flow, on-chain risk & funding accounting, oracle mark-price via LayerZero.

1 System map
flowchart LR
  subgraph "Off-chain"
    Indexer["Perps Indexer\n(order-book)"]
    Matcher["Taker / Bot"]
    OracleSrc["OracleRelayerSrc\n(ETH → Chainlink)"]
  end

  subgraph "peaq"
    OracleDst["OracleRelayerDst"]
    Clearning["PerpClearingHouse"]
    Margin["MarginAccount"]
    Funding["FundingRateLib"]
    Liquidation["PerpLiquidation"]
    Admin["Admin Role"]
  end

  Indexer <-->|"orders"| Matcher
  Matcher -->|"tx fillOrderPerp"| Clearning
  OracleSrc -- "LayerZero" --> OracleDst
  OracleDst --> Clearning
  Clearning --> Margin
  Clearning --> Funding
  Clearning --> Liquidation
  Liquidation --> Margin
  Admin --> Clearning
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Mermaid
IGNORE_WHEN_COPYING_END

Order discovery & matching: identical mesh indexer you already run for spot NFT orders; now the NFT encodes side (long/short), size (USD notional) and limit price.

Clearing house: a single position ledger—every matched trade updates two wallets’ PnL and the global open interest; tokens never leave the contract until trader withdraws profit.

Funding rate: paid peer-to-peer each hour block-timestamp aligns with OracleDst mark price.

2 Core contracts & state
Contract	Role	Key storage
MarginAccount	Maps trader → { collateral, realisedPnl, crossPosition[] }	packed struct per market
PerpMarket (one per asset)	Immutable params + accumulators	openInterest, fundingIndex, maintenanceMarginBps, maxLeverage
PerpClearingHouse	Entry for openPosition(), close(), fillOrdersPerp(), addMargin(), withdraw()	reads/writes Margin + Market
FundingRateLib	Pure view lib → currentFunding() derived from   TWAP(Pmark − Pindex) & fundingIndex	none (stateless)
PerpLiquidation	Anyone can call liquidate(trader, marketId)	
OracleRelayerDst	Same instance used by lend/synth	price[assetId], ts

All contracts are non-upgradeable; version bumps deploy side-by-side.

2.1 Position struct (packed)
struct Position {
    int128  size;        // + long, − short (1e18 base = $1)
    uint128 entryPrice;  // Q112.112 fixed-point
    uint128 lastFunding; // fundingIndex snapshot
}
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END
3 Open / close flow (maker & taker)

Maker posts a limit Order NFT off-chain:

side = Long
notional = 50 000 USDC
price = 2 400 USDC (ETH)
leverage = 10×
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Taker finds order, submits

fillOrdersPerp(orderIds[], notional[], marketId)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

ClearingHouse in a loop:

// margin check on both sides
requiredMargin = notional / leverage
assert(marginAvailable ≥ requiredMargin)

// update positions
newSize = pos.size ± notional
pos.entryPrice = _blend(...)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Collateral: pulled from user’s wallet on first trade (addMargin can be batched via permit).

PnL & funding: realised when position changes size or when trader withdraws.

4 Funding-rate mechanics

Mark price  Pmark = oracle TWAP from OracleDst (1-min).

Index price  Pindex = median of last N trades on unxversal dex (configurable, fallback to oracle).

Premium  Δ = (Pmark − Pindex) / Pindex.

Hourly funding rate  f = clamp(Δ, ±maxPremium) (e.g. ±0.75 %/h).

Market stores a monotonically growing fundingIndex = fundingIndex + f * Δt.

When any position changes or a funding settlement is forced, PnL adjusts:

fundingPayment = pos.size * (fundingIndex_now − pos.lastFunding)
margin -= fundingPayment
pos.lastFunding = fundingIndex_now
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Funding clears peer-to-peer (longs pay shorts or vice-versa); the protocol only charges a small fee on each trade.

5 Risk parameters & liquidation
Symbol	Max Lev	Maint-MM (Bps)	Liq-Penalty	Funding Cap
BTC-PERP	20×	500 bps (5 %)	150 bps	75 bps/h
ETH-PERP	20×	600 bps	150 bps	75 bps/h
sBTC	15×	700 bps	200 bps	100 bps/h
Alt-coins	10×	1 000 bps	250 bps	150 bps/h

Health = (margin + unrealisedPnL) / (|position| / leverageAllowed)
Liquidation triggers at health < 1.0

Liquidator tx:

liquidate(trader, marketId, maxNotionalToClose)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Closes up to closeFactor (e.g. 50 %) of size at Pmark.

Liquidator receives a spread = liqPenalty × notionalClosed.

Optionally uses flashClose()—dex market-order into spot to hedge.

6 Synergies with the stack
Existing layer	Benefit to perps	Benefit from perps
unxversal dex	Provides instant spot liquidity to hedge perp inventory; shares indexer infra.	Extra taker flow => deeper books; perps traders swap collateral & hedge.
unxversal lend	Traders can borrow USDC or sAssets to post margin without leaving protocol.	Lend earns interest on margin balances; liquidations pipe seized collateral back to lend pools.
unxversal synth	Synth oracles already bridged; sAssets can be listed as perps underlier.	Perps funding markets give price discovery and hedge flow for synth holders.

Margin balances are ERC-4626 vault shares internally; earn supply APY from lend pool until withdrawn.

7 Gas & UX optimisations

Cross-function batching – multicall wrapper lets users addMargin → fillOrdersPerp in one tx.

Permit2 for USDC – avoid explicit approve.

Off-chain position simulation – SDK replicates funding & PnL maths locally so the wallet shows projected liquidation price before signing.

Sub-second execution – WebSocket indexer pushes bestBid/Ask so bots quote and fill in < 1 block.

8 Admin & governance
Switch	Purpose
setMarketParams(kink, maxLev, mmBps)	Adjust risk as volatility shifts
pauseMarket(marketId)	Halt new positions if oracle unstable
setFundingConfig(maxPremium, capPerHour)	Tame runaway funding loops
withdrawProtocolFees()	Send trading + liquidation fees to treasury

All changes queued in 24 h timelock with on-chain event log.

9 Security checklist
Threat	Mitigation
Oracle spoof / LZ message forgery	Verified sender + message hash; stale check; multi-sig emergency price patch.
Over-funding grief	Funding cap per hour; funding bound to ±maxPrem.
Cross-market portfolio wipe	Cross-margin nets PnL before health calc; isolated-margin opt-in.
Re-entrancy / CMV	CEI, isolated storage per market, no external calls in internal loops.
Index front-run	Users may add triggerPrice and send via MEV-share or Flashbots bundle.

Full audit + competitive Code4rena contest before mainnet.

10 MVP rollout

Deploy BTC-PERP & ETH-PERP with 10× max leverage.

Indexer upgrade – support PerpOrder NFT schema (side, leverage, notional).

SDK v0.3 – @unxv/perps-sdk with funding & liquidation calculators.

Alpha sandbox – 2-week, capped OI, leaderboard rewards.

Mainnet launch – uncapped OI, oracle redundancy (dual LZ senders).

Key take-aways

Same mental model as CEX perps—cross-margin account, hourly funding, up to 20× leverage.

Order-book matching piggybacks on unxversal dex infrastructure—no new sequencer or vAMM risk.

LayerZero oracles guarantee on-chain mark price without native Chainlink.

Deep integration with lend & synth closes the triangle: trade → borrow → hedge, all inside one trust-minimised ecosystem.

Welcome to unxversal perps—institution-grade perpetual futures, built the crypto-native, modular way on peaq EVM.

All fee destinations (treasury, oracle-gas vault, insurance funds) are USDC-denominated. Fees received in other assets are auto-swapped to USDC via a whitelisted route at the time of deposit

unxversal DAO — the operating system for the entire protocol stack

(dex · synth · lend · perps)

1 ▸ Mission statement

Keep the protocol solvent, competitive, and credibly neutral while funnelling the majority of value back to UNXV holders and the broader ecosystem.

2 ▸ Governance layer (on-chain contracts)
Contract	Core role	Notes
UNXV (ERC-20 + EIP-2612)	Voting checkpoints, fee-permits	Capped at 1 B supply, minter revoked at genesis
veUNXV (Voting-Escrow)	Lock 1-4 yrs → non-transferable ve balance that decays linearly	Boosts voting power and gauge weight
GaugeController	Allocates weekly UNXV emissions to usage gauges (dex, lend, synth, perps)	Weights voted with veUNXV
Governor (Oz Governor Bravo fork)	Propose → vote → queue → execute	proposalThreshold = 1 % of circulating ve-voting power<br>quorum = 4 %
TimelockController	48 h execution delay; sole owner is Governor	Guards all privileged calls (treasury spend, parameter tweaks)
Treasury	Multi-asset vault (USDC, UNXV, LP tokens)	execute() callable only by Timelock
GuardianPause	3-of-5 multisig can pause critical contracts for 7 days	Revocable by DAO after Year 1

All contracts are upgradeable only through explicit DAO proposals and timelock; product–layer contracts (dex/synth/lend/perps) remain immutable.

3 ▸ Voting & delegation

One veUNXV = one vote (linear; no quadratic games).

Delegation possible to any address—including the escrow itself—so passive lockers can empower delegates.

Off-chain voting via Snapshot mirrors on-chain checkpoints for gas-free signalling; final decisions always go through on-chain Governor.

4 ▸ Proposal lifecycle
graph TD
    Draft[Forum discussion<br>(5 d)]
    TempCheck[Snapshot temp-check<br>(3 d)]
    Onchain[Governor proposal<br>(submit + deposit)]
    Vote[On-chain vote<br>(5 d)]
    Queue[Timelock (48 h)]
    Exec[Execute]

    Draft --> TempCheck
    TempCheck -->|≥50 % yes & quorum| Onchain
    Onchain --> Vote
    Vote -->|≥quorum + majority| Queue --> Exec
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Mermaid
IGNORE_WHEN_COPYING_END

Proposer deposit (1 000 UNXV) is slashed if the proposal fails quorum—deterring spam.

5 ▸ Treasury management
Stream	Destination	Control
Protocol fees (USDC)	Treasury	Auto-swept daily from product contracts
UNXV emissions	GaugeController.distribute() weekly	Formula: epochInflation × gaugeWeight / totalWeight
Insurance fund excess	Treasury when surplus > 5 % of TVL	Autonomous cron via Keeper

Spending categories (budget lines voted at quarterly “funding rounds”):

Oracle gas & infra reimbursements

Security & audits

Public-goods grants / hackathons

Buy-back-and-make (buy UNXV → lock in ve)

Liquidity provisioning (POL)

Treasury operations > $100 k USDC require two-step vote (signal + execution).

6 ▸ Technical parameter authority
Product module	Parameter buckets	Change flow
Dex FeeSwitch & order-NFT	takerFee, makerRebate, spamFee	Governor → Timelock
Synth Vault	mintFee, burnFee, minCR, penalty, oracle id	Governor → Timelock
Lend CorePool/Controller	collateralFactor, reserveFactor, interestCurve	Governor → Timelock
Perps ClearingHouse	takerFee, fundingCap, maxLeverage	Governor → Timelock
Insurance thresholds	targetPercent	Governor → Timelock
Emissions	epochInflation, gaugeWhitelist	Governor → Timelock

Emergency Guardian can lower fees/penalties or pause new positions instantly but cannot raise values or move funds.

7 ▸ Workstreams & sub-DAOs
WG (sub-DAO)	Mandate	Budget cadence	Tooling
Risk & Parameters	Suggest collateral factors, leverage, fee tweaks	Monthly	Dune dashboards, Gauntlet-style VaR sims
Engineering	Core repos, audits, keeper infra	Quarterly	GitHub multisig, Hardhat deployer
Growth & BD	CEX bridges, marketing, listings	Quarterly	Multi-sig with 3 community delegates
Grants	≤ $25 k grants to builders	Rolling	Safe multisig + Clawback timelock

Each WG receives a streaming budget via Sablier; renewal needs DAO vote.

8 ▸ Transparency stack

Real-time dataLake.unxv.xyz:

Protocol TVL, fees, insurance coverage

DAO wallet balances & pending proposals

Founder vesting schedule & cliff countdown

Bi-weekly community call + Notion minutes pushed to IPFS.

Mandatory executive summary for every proposal (≤ 500 words + on-chain diff).

9 ▸ Launch & bootstrap timeline
T-Day	Milestone
T-0	Deploy UNXV, veUNXV, Timelock, Governor — transfer ownership of core products to Timelock
T+7 d	Publish constitution (forum) & open first “Funding Epoch 0” proposal (oracle gas + POL LP).
T+14 d	Enable Gauge emissions — initial weights: dex 25 %, lend 25 %, synth 20 %, perps 30 %
Month 3	Guardian pause rights revocable by DAO vote if ≥ 10 % circulating ve votes “yes”
Month 12	Community working-group elections; founder addresses lose Guardian seats by default
10 ▸ Security & audit plan

Full audit of DAO suite (Governor, ve, gauges) by OpenZeppelin.

Continuous fuzzing pipeline (Foundry + Echidna) for vote-timelock edge-cases.

Bug-bounty on Immunefi (Tier 3, max $500 k).

DAO custody — core keys in Trezor + distributed Shamir backup; multisig signers rotate yearly.

TL;DR

One-token, ve-locked, Governor-Timelock DAO

35 % founder vest (4 y, 1 y cliff); no investors

Permissions: day-to-day gauges & budgets via weekly votes, all contract-level changes timelocked 48 h

Guardian pause only until Year 1, then fully community-owned

Clear funding rails: fees → treasury → buy-burn, grants, infra

Transparent, auditable, and ready for permissionless growth on peaq from day 1.

All fee destinations (treasury, oracle-gas vault, insurance funds) are USDC-denominated. Fees received in other assets are auto-swapped to USDC via a whitelisted route at the time of deposit

Below is a single, coherent fee grid that covers every live path through unxversal dex, synth, lend, and perps.
All numbers are default launch values; each parameter lives on-chain behind the Admin role (24 h timelock).

Protocol path	Action	Fee metric	New default	Split (where it goes)
DEX	Maker createOrder	Spam-guard mint fee	0.2 USDC flat	100 % ➜ treasury (covers oracle gas)
	Taker fillOrders	Taker fee on filled notional	6 bps (0.06 %)	60 % ➜ relayer address*<br>30 % ➜ treasury<br>10 % ➜ GOV buy-&-burn
	Cancel / partial fills	—	0	—
Synth	mint()	Mint fee	15 bps of USD value	70 % ➜ oracle-gas vault<br>30 % ➜ surplus buffer
	burn()	Burn fee	8 bps	100 % ➜ surplus buffer
	Stability accrual	Continuous rate	2 % APR	100 % ➜ surplus buffer
	Liquidation	Penalty on debt repaid	12 %	50 % ➜ liquidator<br>30 % ➜ surplus buffer (insurance)<br>20 % ➜ treasury
Lend	Borrow interest	Reserve factor	12 % of interest	100 % ➜ treasury
	Flash-loan	Flat fee	8 bps	80 % ➜ treasury<br>20 % ➜ flash-fee rebate pool
	Liquidation	Penalty	10 %	60 % ➜ liquidator<br>25 % ➜ insurance<br>15 % ➜ treasury
Perps	Trade (open/close)	Taker fee on notional	10 bps	70 % ➜ insurance fund¹<br>20 % ➜ treasury<br>10 % ➜ maker rebate (from taker fee)
	Funding payments	Protocol skim	10 – 15 % of gross funding²	100 % ➜ insurance fund
	Profit withdrawal	Exit fee	10 bps on realised P&L	100 % ➜ treasury
	Liquidation	Penalty	2.9 % of notional closed	70 % ➜ liquidator<br>30 % ➜ insurance fund

<sub>* relayer is passed in fillOrders; if omitted, 100 % of that slice routes to the treasury.<br>
¹ Perps-insurance is contract-isolated but may lend idle USDC into unxversal lend for yield.<br>
² Funding is trader-to-trader; the skim is carved out inside the same transfer.</sub>

How the pieces fit together
Pool	Inflows	Use-of-funds / Drains
Treasury	– DEX mint + 30 % taker slice<br>– Synth mint/burn/stability share<br>– 15 % of lend liquidations<br>– 20 % of perps taker fees<br>– Exit & flash fees	• Pay LayerZero oracle gas if oracle vault empty<br>• Protocol R&D / buy-backs after 18 m reserve floor
Oracle gas vault	70 % of synth-mint fees	Auto-top-ups relayerSrc wallets via keeper
Surplus buffer (synth insurance)	30 % of mint/burn fees + 30 % of liquidation penalties	Covers bad debt if USDC de-pegs or oracle lag
Lend insurance	25 % of lend-liquidation penalties	Backstops shortfall in extreme market gaps
Perps insurance	70 % of perps taker fee slice + funding skim	Pays negative-equity claw-backs, then lends excess into lend pool

When any insurance fund exceeds its target (e.g. 5 % of protocol TVL) the excess streams to the treasury each epoch.

Parameter governance & transparency
Parameter	Contract	Setter	Bounds / Timelock
takerFeeBps, makerRebateBps	DEX FeeSwitch	Admin multisig	±2 bps per 48 h
mintFeeBps, stabilityAPR	Synth USDCVault	Admin	±0.25 % per 7 d
reserveFactor	Lend CorePool	Admin	max 20 %; 24 h
tradeFeeBps, exitFeeBps	Perp ClearingHouse	Admin	±2 bps per 48 h
All penalties	Respective LiquidationEngine	Admin	may lower instantly, raise after 48 h

Each change emits a FeeParameterUpdated event that dashboards index within seconds.

Competitive rationale
Market	Our all-in cost	Benchmarks
Spot DEX taker	0.06 %	CEX: 0.10–0.20 %
Synth mint + burn round-trip	0.23 %	MakerDAO stability + swap ≈ 0.50 % +
Borrow APY drag (reserve)	12 % of interest	Aave & Compound: 10–20 %
Perps taker (per side)	0.10 %	Binance Futures: 0.04–0.07 % (+ hidden funding clipping)

We remain cheaper than incumbents yet collect sufficient revenue to:

pay oracle gas (LayerZero isn’t free),

seed robust insurance buffers,

fund continued development.

Launch checklist

Hard-code defaults in V1 bytecode → publish audited hash.

Seed insurance funds with 1 M USDC from the treasury multisig.

Stand-up dashboard fees.unxv.xyz that live-queries every FeeSwitch and pool balance.

Draft governance docs explaining why each ceiling exists and the ratchet schedule for future fee reductions.

TL;DR

Uniform, memorable numbers—6 bps spot, 23 bps synth round-trip, 10 bps perps.

Multi-tier splits send revenue first to oracle gas & insurance, then to the treasury.

Timelocked governance lets the protocol tune fees without shocking users.

Still beats CEX pricing while staying self-funded and chain-native.

Why liquidation bots exist

Every collateral-backed DeFi system lives or dies by one rule: the protocol must always be able to pay what it owes.
Whenever a borrower, minter, or leveraged trader slips below the minimum collateral ratio (CR) or maintenance margin, the protocol itself is at risk of insolvency. Liquidation bots are the autonomous first-responders that:

Detect under-collateralised positions within seconds of price updates.

Repay or close enough of the bad position—using their own capital or a flash-loan—so the account returns to safety (or is fully closed).

Collect a bounty (liquidation penalty) that compensates them for gas, oracle latency risk, and capital at risk.

No central operator can do this fast or reliably enough; decentralised bots turn risk management into an open, self-incentivising market.

How bots interact with each unxversal module
Protocol	Liquidation trigger	Bot’s on-chain action	Paid reward
unxversal synth	collateralUSDC / debtUSD < minCR (e.g. 150 %)	vault.liquidate(account, synthId, repayAmount) – burns the debtor’s synth debt and seizes USDC	12 % of debt repaid (updated grid) – 50 % to bot, 30 % to surplus buffer, 20 % to treasury
unxversal lend	healthFactor < 1.0 (collateral value < borrowed value / collateralFactor)	pool.liquidate(borrower, repayAsset, maxRepay) – repays up to closeFactor of debt, receives discounted collateral	10 % of debt repaid – 60 % bot, 25 % lend-insurance, 15 % treasury
unxversal perps	margin + unrealisedPnL < maintMargin or health < 1	clearingHouse.liquidate(trader, marketId, maxNotional) – force-closes part/all of the perp position at oracle mark price	2.9 % of notional closed – 70 % bot, 30 % perps-insurance
unxversal dex (spot)	N/A – fully pre-funded; no liquidations	—	—
Bot workflow step-by-step
sequenceDiagram
  participant Bot
  participant RPC as peaq RPC
  participant OracleDst
  participant Protocol

  OracleDst->>RPC: New price pushed via LayerZero
  Bot->>RPC: eth_call getSafetyRatios()
  alt Unsafe position(s) exist
      Bot->>Protocol: liquidate(...){gas}
      Protocol-->>Bot: collateral + reward
  else No risk
      Bot-->>Bot: sleep(≈10s)
  end
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Mermaid
IGNORE_WHEN_COPYING_END

Listen on WebSocket for PriceUpdated, Vault.PositionUpdated, Pool.Borrow, Perp.Trade, etc.

Simulate the safety ratio with an eth_call (“dry-run”) to avoid reverting.

Bundle a liquidation tx—optionally with:

Flash-loan from unxversal lend to source repay funds,

Spot swap on unxversal dex to hedge seized collateral.

Send via public mempool or MEV-Share / Flashbots to avoid being front-run.

Collect penalty reward. A good bot pays:

gas + 1–3 bps latency risk <<< bounty (900 bps synth, 800 bps lend, 290 bps perps).

Why multiple bots = healthier protocol

Competition keeps slippage low – The first bot wins, so they optimise gas and close just enough debt.

Quick reaction to flash-crashes – Parallel bots reduce lag to the first block after an oracle tick.

No single point of failure – If your own bot goes offline, others backstop solvency.

Building a liquidation bot in practice

Index critical events (Subgraph, native logs, or the official indexer WS):

ws.subscribe(["PriceUpdated","PositionUpdated","Borrow","Trade"], handler)
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Ts
IGNORE_WHEN_COPYING_END

Keep local order-book for unxversal dex so you can instant-swap seized collateral to the repay asset.

Pre-fund the bot’s wallet with:

some PEAQ gas,

USDC (synth / lend liquidations),

sBTC/sETH (optional for perps hedging).

Flash-loan helper (pseudo):

flashLoanAndLiquidate(asset, repay, victim) {
    pool.flashLoan(asset, repay, abi.encode(victim));
}
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
Solidity
IGNORE_WHEN_COPYING_END

Race: bundle via Flashbots for priority, back-off to mempool if bundle fails.

Economic intuition
Parameter (synth)	Example value	Notes
Debt repaid	$100 000	Bot burns this much synth
Penalty (12 %)	$12 000	Gross bounty
Gas cost	$45	150 k gas × 30 gwei × $0.01
Oracle drift risk	~$200	The only real risk window (~15 s)
Net PnL	≈ $11 755	Very attractive – draws plenty of bots

Even with fee increases, the penalties remain generous relative to cost, ensuring an active liquidation market.

TL;DR for founders

Liquidation bots are the automated “risk valve” that keep collateral ratios healthy across synth, lend and perps.
Design bots to be permissionless, profitable, and easily replicable; the protocol stays solvent, and you can still run your own bot fleet to capture a slice of bounties while others keep you honest.

1 · Token fundamentals
Parameter	Value
Symbol / name	UNXV – unxversal governance token
Chain	peaq EVM (ERC-20 with EIP-2612 permits)
Decimals	18
Fixed max supply	1 000 000 000 UNXV (hard-capped)
Minters	Only the genesis deployer (then renounced)
2 · Genesis allocation
Bucket	% of supply	Tokens (1 B = baseline)	Vesting / lock-up	Rationale
Founders + core team	35 %	350 000 000	4 yr linear ⟂ 1 yr cliff (escrow contract)	Long-term skin-in-game; no investor tranche, so founders take larger cut
Community incentives (“make-to-earn”)	35 %	350 000 000	Streaming emissions over 6 yrs, decaying 1.4 × every 12 mo	Trade-mining, liquidity gauges, referral quests
Protocol treasury (DAO)	15 %	150 000 000	Unlocked → controlled by on-chain Governor	Grants, audits, buy-backs, oracle gas, insurance top-ups
Ecosystem & integrations fund	8 %	80 000 000	4 yr linear ⟂ 6-month cliff; draws by DAO vote	Hackathons, cross-chain deployments, market-maker loans
Initial liquidity bootstrap (POL)	5 %	50 000 000	50 % paired with USDC in a DAO-owned LP; LP tokens time-locked 2 yrs	Deepens GOV/USDC market from day-1
Airdrop to early testers	2 %	20 000 000	12-month claim window; unclaimed → burns	Aligns early power-users & bug-hunters

Totals: 100 % → 1 000 000 000 UNXV.

3 · Vesting mechanics (founders & team)

Escrow contract: immutable; beneficiaries & amounts fixed at genesis.

Schedule:

Year 0-1     : 0 % unlocked  
Month 13-48 : 1/48 unlocked each month
IGNORE_WHEN_COPYING_START
content_copy
download
Use code with caution.
IGNORE_WHEN_COPYING_END

Delegate-while-locked: escrow can delegate its voting power to a DAO-designated address so founders may govern proportionally, yet tokens remain non-transferable until vest dates.

4 · DAO architecture (“unxversal DAO”)
Layer	Contract / stack	Parameters
Token	ERC-20 + EIP-2612	capped supply, voting checkpoints
Ve-wrapper (optional after 6-mo)	Voting-Escrow (“veUNXV”)	lock 1-4 yrs → linear boost; enables gauges
Governor	OpenZeppelin Governor Bravo fork	proposalThreshold = 1 % of circulating voting power; quorum = 4 %
Timelock	48 h delay (owner = Governor)	minDelay = 48 h, maxDelay = 7 d
Guardian / emergency pause	3-of-5 multisig (core + advisors)	can pause critical contracts 7 days; revocable by DAO
Treasury	Timelocked ERC-20/ETH vault	spends only via Governor proposals
5 · Emission & incentive dial-ins

Community incentives (350 M) stream block-by-block:

Year 1   : 80 M

Year 2   : 60 M

Year 3   : 45 M

Year 4   : 35 M

Year 5-6 : 130 M (decays quarterly; exact curve editable by DAO)

Gauges (spot trading, synth minting, perps volume, lending supply) decide where the weekly drip flows; weight vote uses veUNXV.

6 · Revenue → value flow

Fees accrue in USDC to Treasury & insurance pools.

DAO policy (simple-majority vote) chooses among:

Buy-and-burn UNXV on the spot DEX.

Buy-and-stake UNXV back into ve-locker, recycling rewards.

Direct dividend in USDC to ve-holders (requires legal comfort).

Reinvest into yield strategies (lend pools, balancer POL).

Founders profit through their vested UNXV plus any DAO-approved service retainer or keeper revenues (if they operate bots).

7 · Bootstrap sequence

Deploy UNXV token → mint all buckets to temporary deployer.

Create escrow contracts, treasury, ve-locker, timelock, governor.

Transfer each bucket to its contract (founder escrow, treasury, etc.).

Renounce minter role → supply immutable.

Provide POL liquidity (UNXV + USDC) on unxversal DEX; lock LP tokens in DAO vault.

DAO genesis proposal → activate gauges & initial incentive weights.

8 · Transparency & trust anchors

All vesting & treasury addresses posted in launch blog + verified on-chain.

Founders’ vest schedule enforced by code; any cliff-bypass attempt would revert.

Real-time dashboard shows:

circulating vs. locked UNXV,

next unlock dates,

treasury balances & fee inflows.

TL;DR

1 B fixed UNXV, no investors.

35 % founder/core team on a 4-yr vest with 1-yr cliff.

Equal-sized 35 % community pool fuels long-term liquidity and usage.

On-chain Governor + 48 h Timelock controls the 15 % treasury stack.

Fees → treasury → buy-burn, fee-share or reinvest—maximising upside for locked UNXV holders (founders included) while keeping every governance move transparent and time-delayed.

All fee destinations (treasury, oracle-gas vault, insurance funds) are USDC-denominated. Fees received in other assets are auto-swapped to USDC via a whitelisted route at the time of deposit

Option	What it looks like	Pros	Cons / hidden complexity	When it’s the right call
USDC-only vaults<br>(treasury + insurance)	All fees are auto-swapped to USDC as they arrive.  Treasury/insurance contracts hold a single ERC-20.	• Simple accounting, single oracle<br>• Insurance payouts deterministic (1 USDC = 1 USDC)<br>• Zero portfolio-management governance overhead	• Opportunity cost if stables yield < real assets<br>• Requires swap liquidity for every exotic fee asset<br>• Long-run inflation/peg risk rests on one stable issuer	Launch phase – you want solvency proofs, transparent runway, minimal parameter surface.
Multi-asset “triage” vault	Fees accrue as is (WETH, sBTC, etc.) but the contract auto-sells to USDC only when needed (oracle gas payout, claim, buy-back).	• Less swap slippage on inbound flow<br>• Treasury benefits from upside in volatile assets<br>• Still pays liabilities in a stable unit	• Requires on-chain TWAP oracles & swap routes for every new asset<br>• Insurance mark-to-market becomes noisy → social consensus on how much is “enough”	Growth phase – TVL high, you want to hodl a β-portfolio but keep liabilities USD-denominated.
Fully multi-asset treasury & risk fund	DAO holds a discretionary portfolio (stables, ETH, sAssets, LSTs) and pays claims in whatever the proposal specifies.	• Can capture staking/LST yield & price upside<br>• Enables DAO-level diversification strategies	• Portfolio management is now its own job: rebalancing, risk reporting, and governance bikeshedding<br>• Insurance payouts may vary with market cycles – bad UX for claimants	Mature phase – robust dashboarding, dedicated Risk WG, deeper liquidity to re-balance at will.
Recommended sequence for unxversal

Year 0–1 (Launch → Product/Market Fit)
USDC-only.
Why? You can publish a solvency dashboard where insurance ≥ 5 % TVL, oracle gas runway shows in months, and it’s trivial for auditors to reason about worst-case scenarios.

Year 1–2 (TVL > $100 M, stable fee flow)
Graduate to the Triage vault:

• Treasury contract accepts whitelisted ERC-20s.*

• At each epoch it sells-to-USDC anything beyond a % threshold.*
This retains upside (e.g., perps fees arrive in WETH, rise with bull market) but auto-builds reserves in your accounting currency.

Year 2+ (DAO staffed, Risk WG live)
If the community desires, migrate a slice (say 20 %) of reserves into a Discretionary Portfolio module that can stake ETH-LSTs, LP UNXV/USDC, or even lend into unxversal lend.  All moves gated by veUNXV vote + timelock.

Practical implementation details
Topic	USDC-only specifics
Fee-sweep transactions	Product contracts call Treasury.depositFee(asset, amount); if asset != USDC, they immediately route through a 0-slippage order-book RFQ (dex) or a whitelisted 1inch path.
Insurance payouts	A single claim(amountUSDC, reason) function; easier to audit caps and claw-backs.
Liquidity needs	Pair UNXV/USDC POL once, then most swaps (WETH→USDC, sBTC→USDC) use that pool’s routing path—lowering sell pressure on UNXV.
Dashboards	One line-chart shows Treasury USDC, another shows Insurance USDC; TVL divisor makes ratios trivial.
TL;DR

Start USDC-only. It’s clean, auditor-friendly, and guarantees that every oracle-gas invoice, buy-back, or insurance payout is covered in a predictable dollar unit.
Once fee inflows and community governance mature, you can progressively loosen into a multi-asset vault—but make that an explicit DAO milestone, not a launch-day complication.

thr first part of my todolist is generating the directory structure for all the files. generate a directorystructure for all the files. I'll be using hardhat, and the network we're building on is an EVM called peaq, docs below

peaq home pagelight logo

Search...
⌘K

Ask AI
Support
Portal

Welcome
Build
SDK Reference
Changelog
News
Community
Repos
Getting Started
What is peaq
Installing peaq SDK
Connecting to peaq
Get test tokens
Tokenomics
How to Send and Receive $PEAQ
Build Your First DePIN
Onboard a Machine
Store Machine Data
Run and Test
Deploy your DePIN
The Basic Operations
On-chain vs Off-chain
Listening and Parsing Chain Events
Submitting Transactions
Gas Operations
Smart Contracts
Deploying ERC-20 Token
Deploying ERC-721 NFT
Working with Wallet Addresses
Smart Contract Storage
Block Explorers
Wallets
The Advanced Operations
Precompiles
Node Operations
Off Chain Storage
Sending Bulk Transactions
Account Abstraction
Indexers
Getting Started
Connecting to peaq
On this reference page, you will find the network types, RPC/WSS URLs, chain identifiers, etc. to connect to peaq or agung.

​
Networks:
Network	Network type
peaq	Mainnet
agung	Testnet
​
Chain ID

peaq

agung

Copy
3338
​
Public RPC URLs

peaq

agung

Copy
https://quicknode.peaq.xyz/

https://peaq.api.onfinality.io/public

https://peaq-rpc.publicnode.com

https://peaq-rpc.dwellir.com
​
Public WSS URLs

peaq

agung

Copy
wss://quicknode.peaq.xyz/

wss://peaq.api.onfinality.io/public

wss://peaq-rpc.publicnode.com

wss://peaq-rpc.dwellir.com
​
Private URLs
You can create your custom peaq RPC/WSS endpoint with QuickNode or OnFinality. To do so, follow one of the guides below:

QuickNode guide
OnFinality guide
​
Block explorers
​
peaq
Block Explorer	Type	URL
Subscan	EVM & Substrate	Subscan
Polkadot.js	EVM & Substrate	polkadot.js.org
​
agung
Block Explorer	Type	URL
Subscan	EVM & Substrate	Subscan
Polkadot.js	EVM & Substrate	polkadot.js.org
​
Node setup
​
Node hardware requirements

Copy
OS - Ubuntu 20.04
CPU - 3.3 GHz AMD EPYC 7002
Storage - 1TB SSD
Memory - 8GB
​
Docker image peaq

Copy
docker run -v peaq-storage:/chain-data -p 9944:9944 peaq/parachain:peaq-v0.0.104 
--parachain-id 3338 
--chain ./node/src/chain-specs/peaq-raw.json 
--base-path chain-data 
--port 30333 
--rpc-port 9944 
--rpc-cors=all 
--execution wasm 
--state-pruning archive 
-- 
--execution wasm 
--port 30343 --rpc-port 9977 
--sync warp
Installing peaq SDK
Get test tokens
Powered by Mintlify
On this page
Networks:
Chain ID
Public RPC URLs
Public WSS URLs
Private URLs
Block explorers
peaq
agung
Node setup
Node hardware requirements
Docker image peaq
Connecting to peaq - peaq