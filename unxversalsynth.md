# unxversal synth — USD-collateralised synthetic assets on **Sui**

Lets anyone lock **USDC** in a vault and mint tradeable ERC-20-style “sAssets” (sBTC, sETH, …) that track **any Pyth price feed**.
sAssets can be traded on DeepBook, supplied to **Lend**, or used as margin for perps, futures, and options.
All mint/burn fees are swapped to **UNXV**, fuelling the flywheel.

---

## 1 · Module map (Move)

| Module               | Resource / Object                    | Role                                                 |
| -------------------- | ------------------------------------ | ---------------------------------------------------- |
| `synth::vault`       | `Position` per account, `GlobalDebt` | Collateral ledger & debt shares                      |
| `synth::asset`       | `SynthInfo`                          | ERC-20 proxy (name, symbol, decimals)                |
| `synth::factory`     | —                                    | Deploys new synths from a Pyth price ID              |
| `synth::oracle`      | —                                    | Reads Pyth price attestation; fallback DeepBook TWAP |
| `synth::liquidation` | —                                    | CR check, seize USDC, burn debt                      |
| `fee_sink::mintburn` | —                                    | Swaps fees → UNXV → Treasury/Oracle gas vault        |

---

## 2 · Core parameters (governance-gated)

| Param                  | Default   | Bounds                           | Who can change      |
| ---------------------- | --------- | -------------------------------- | ------------------- |
| **minCR** (all synths) | **160 %** | ≥ 150 %                          | Governor → Timelock |
| **mintFee**            | 15 bps    | ±5 bps                           | Governor → Timelock |
| **burnFee**            | 8 bps     | ±5 bps                           | Governor → Timelock |
| **liqPenalty**         | 12 %      | lower-only fast path; raise 48 h | Guardian / Governor |
| **staleTolerance**     | 30 min    | 5-120 min                        | Guardian → Timelock |

---

## 3 · Mint / burn flow

```move
// 1. user deposits USDC
synth::vault::deposit_usdc(user, 10_000_000);  // 10 000 USDC (6-dec)

// 2. mint 0.1 sBTC (BTC @ 60 000)
synth::vault::mint<sBTC>(user, 0.1 * 10^18);
```

**Checks inside `mint`:**

```
valueUSD = price(sBTC) * 0.1
newCR    = (collateral + Δ) / (debt + valueUSD)
assert newCR ≥ minCR
mintFee  = valueUSD × 15 bps   // auto-swap → UNXV
```

*`burn()` mirrors the flow, applying `burnFee`.*

---

## 4 · Liquidations

| Trigger             | `collateralUSD / debtUSD < minCR`                   |
| ------------------- | --------------------------------------------------- |
| Amount liquidatable | Up to `closeFactor = 50 %` of debt                  |
| Reward split        | 50 % liquidator, 30 % surplus buffer, 20 % Treasury |
| Penalty             | 12 % of repaid debt (USDC seized)                   |

Liquidator can flash-borrow USDC from **Lend** inside the same tx.

---

## 5 · Fee routing → UNXV

```
mintFee / burnFee
        ▼
fee_sink::mintburn.swap_to_unxv()
        ▼
70 %  → oracle gas vault  (pays LayerZero / Pyth relayer)
30 %  → Treasury Safe
```

Swap path: USDC → UNXV RFQ on DeepBook, slippage guard ≤ 1 %.

---

## 6 · Oracle design

1. **Primary** — Pyth price object (confidence-weighted median)
   *Verifier* in Move checks attestation & slot freshness.
2. **Fallback** — 15-min DeepBook VWAP (haircut 2 %)
   Activated if Pyth update > `staleTolerance`.

---

## 7 · Supported synth universe (launch set)

All Pyth feeds are technically supported; DAO whitelists assets in batches.
Launch = top-tier liquidity + user demand:

`BTC, ETH, SOL, AVAX, BNB, DOGE, XRP, ADA, DOT, LINK, TON, SHIB, LTC, BCH, TRX, MATIC, APT, OP, SUI, 1INCH`

Governance can enable **any** ID from the master list (see Appendix A) in a one-transaction `factory.add_synth(price_id, name, symbol, decimals)`.

---

## 8 · Use-cases & integrations

| Product             | Benefit                                           | How it talks to Synth                         |
| ------------------- | ------------------------------------------------- | --------------------------------------------- |
| **DeepBook**        | Spot trade synths 1:1                             | Standard `coin::transfer`                     |
| **Lend**            | Borrow synths to short; post synths as collateral | `uSynth` markets (reserveFactor 20 %)         |
| **Perps / Futures** | List synth as underlier                           | Pyth already provides mark price              |
| **Options**         | Cash-settle options into synth                    | `options::exercise()` burns synth & pays USDC |

---

## 9 · Risk mitigations

| Risk                 | Guardrail                                                                     |
| -------------------- | ----------------------------------------------------------------------------- |
| Pyth outage          | DeepBook VWAP fallback with 2 % haircut; Guardian can raise `minCR` instantly |
| USDC de-peg          | Oracle can include Circle on-chain price; DAO may pause mint & raise CR       |
| Runaway synth supply | Debt cap per asset (`maxDebtUSD`) adjustable by DAO                           |
| Liquidation cliff    | Penalty can only be lowered instantly, raised through Timelock                |

Audit + fuzz coverage on CR math, price freshness, and oracle switching logic.

---

## 10 · Gas & UX notes

* **Batch helper** – `router::mint_and_trade()` swaps USDC → synth → posts DeepBook order in one tx.
* **Permit-style** – Supports Sui `sponsored_tx` to cover USDC approval gas.
* **Mobile** – Relayer WS streams synth price so wallet shows live collateral ratio.

---

## 11 · KPI targets (year-1)

| Metric            | Goal                                    |
| ----------------- | --------------------------------------- |
| Synth supply      | > \$50 M                                |
| Avg CR            | ≤ 250 %                                 |
| Oracle gas funded | 100 % from mint fees (no DAO subsidies) |
| Insolvent vaults  | 0                                       |

---

## 12 · TL;DR

*Lock USDC → mint any of 400+ Pyth-priced assets.*
15 bps in, 8 bps out, 160 % min CR.
Fees auto-convert to UNXV and pay oracle gas—closing the loop while giving traders limitless synthetic exposure on Sui.

---

### Appendix A – Full Pyth feed list (whitelist-eligible)

1INCH, A, AAVE, ABSTER, ACT, ADA, AERGO, AERO, AEVO, AFSUI, AI16Z, AIXBT, AKT, ALGO, ALICE, ALT, AMI, AMP, AMPL, ANIME, ANKR, ANON, APE, API3, APT, AR, ARB, ARC, ARKM, ASF, ASTR, ATH, ATLAS, ATOM, AUDIO, AURORA, AUSD, AVAIL, AVAX, AXL, AXS, B3, BABY, BABYDOGE, BAL, BAN, BAND, BAT, BBSOL, BCH, BEAM, BENJI, BERA, BERAETH, BERASTONE, BGB, BIFI, BIO, BITCOIN, BLAST, BLUB, BLUE, BLUR, BLZE, BMT, BMTON, BNB, BNSOL, BOBA, BOBAETH, BODEN, BOLD, BOME, BONK, BOOP, BORG, BRETT, BROCCOLI, BSOL, BSV, BTC, BTT, BUCK, BUDDY, BYUSD, C98, CAKE, CARV, CAT, CBBTC, CBETH, CDCETH, CDXUSD, CELO, CELR, CETUS, CFX, CHILLGUY, CHR, CHZ, CLANKER, CLOUD, CMETH, COMP, COOK, COOKIE, COQ, CORE, COW, CRO, CRV, CSPR, CTSI, CUSD, CVX, DAI, DASH, DBR, DEEP, DEGEN, DEUSD, DEXE, DODO, DOGE, DOGINME, DOGS, DOT, DRIFT, DSOL, DYDX, DYM, EAPT, EBTC, EDU, EGLD, EIGEN, ELON, ENA, ENJ, ENS, ETC, ETH, ETHFI, ETHX, EUL, EURA, EURC, EVMOS, EZETH, F, FAI, FARTCOIN, FDUSD, FET, FEUSD, FHYPE, FIDA, FIL, FLOKI, FLOW, FLR, FORM, FOXY, FRAX, FRUSDT, FRXETH, FRXUSD, FTT, FUD, FUEL, FUSDC, FWOG, G, GALA, GGAVAX, GHO, GLMR, GMT, GMX, GNO, GNS, GOAT, GOGLZ, GORK, GPS, GRAIL, GRASS, GRIFFAIN, GRT, GT, GUSD, HAEDAL, HASUI, HBAR, HENLO, HFT, HFUN, HIPPO, HNT, HONEY, HSOL, HT, HTON, HUMA, HYPE, HYPER, HYPERSTABLE, IBERA, IBGT, ICP, IDEX, ILV, IMX, INF, INIT, INJ, IO, IOT, IOTA, IOTX, IP, ISEI, JASMY, JITOSOL, JLP, JOE, JTO, JUP, JUPSOL, K, KAIA, KAITO, KAS, KAVA, KBTC, KCS, KERNEL, KEYCAT, KHYPE, KMNO, KNC, KOBAN, KSM, KTON, LAUNCHCOIN, LAYER, LBGT, LBTC, LDO, LEO, LHYPE, LINEAR, LINK, LION, LIQUIDBERABTC, LIQUIDBERAETH, LL, LOFI, LOOKS, LOOP, LOUD, LQTY, LRC, LSETH, LST, LTC, LUCE, LUNA, LUNC, LUSD, LVLUSD, LVN, MANA, MANEKI, MANTA, MASK, MATICX, MAV, MBTC, ME, MELANIA, MEME, MERL, METASTABLE, METH, METIS, MEW, MEZO, MHYPE, MICHI, MIM, MINA, MKR, MNDE, MNT, MOBILE, MOBY, MOD, MODE, MOG, MOODENG, MORPHO, MOTHER, MOVE, MSETH, MSOL, MSUSD, MTR, MTRG, MUBARAK, MYRO, NAVX, NEAR, NECT, NEIRO, NEON, NEXO, NIL, NOOT, NOT, NS, NTRN, NXPC, ODOS, OGN, OHM, OKB, OM, OMG, OMI, ONDO, ONE, OOGA, OP, ORCA, ORDER, ORDI, ORIBGT, OS, OSMO, OUSDT, PARTI, PAXG, PENDLE, PENGU, PEOPLE, PEPE, PERP, PI, PLUME, PNUT, POL, PONKE, POPCAT, PRCL, PRIME, PROMPT, PST, PUFETH, PURR, PXETH, PYTH, PYUSD, QNT, QTUM, QUICK, RAY, RDNT, RED, RENDER, RESOLV, RETARDIO, RETH, REZ, RLB, RLP, RLUSD, RON, ROSE, RPL, RSETH, RSR, RSWETH, RUNE, RUSD, S, SAFE, SAMO, SAND, SATS, SAVAX, SAVUSD, SCA, SCETH, SCFX, SCR, SCRT, SCRVUSD, SCUSD, SD, SDAI, SDEUSD, SEAM, SEI, SEND, SENDCOIN, SFRXETH, SFRXUSD, SHADOW, SHDW, SHIB, SIGN, SKATE, SKI, SKL, SKY, SLERF, SLP, SLVLUSD, SNX, SOL, SOLV, SOLVBTC, SONIC, SONICSOL, SOON, SOPH, SPELL, SPOT, SPX6900, SRUSD, SSOL, STAPT, STBGT, STCORE, STETH, STG, STHAPT, STHYPE, STIP, STKAPT, STNEAR, STONE, STORJ, STREAM, STRK, STS, STSUI, STTON, STUSD, STX, SUI, SUPR, SUSD, SUSDA, SUSDE, SUSDS, SUSHI, SWARMS, SWETH, SXP, SYN, SYRUPUSDC, SYRUPUSDT, SYUSD, TAIKO, TAO, TBTC, TENET, TEST1, TEST2, TETH, THAPT, THE, THETA, THL, TIA, TNSR, TOKEN, TON, TOSHI, TRB, TRUAPT, TRUMP, TRX, TST, TSTON, TURBO, TURBOS, TUSD, TUT, UBTC, UETH, UFART, UMA, UNI, USD*, USD0++, USD0, USD1, USDA, USDAF, USDB, USDC, USDD, USDE, USDG, USDL, USDN, USDP, USDS, USDT, USDT0, USDTB, USDX, USDXL, USDY, USOL, USR, USTC, USUAL, USYC, VADER, VANA, VELODROME, VET, VIC, VINE, VIP, VIRTUAL, VSOL, VSUI, VVV, W, WAGMI, WAL, WAMPL, WANS, WAVES, WBETH, WBTC, WCT, WEETH, WELL, WEN, WETH, WFRAGSOL, WIF, WLD, WM, WOJAK, WOM, WOO, WSTETH, WSTHYPE, WSTKSCETH, WSTKSCUSD, WSTUSR, WUSDL, XAI, XAUT, XCFX, XDC, XEC, XION, XLM, XMR, XPRT, XRD, XRP, XTZ, XUSD, XUSDC, YFI, YNETH, YNETHX, YUSD, YUTY, ZBTC, ZEC, ZEN, ZENBTC, ZEREBRO, ZERO, ZETA, ZEUS, ZEX, ZIL, ZK, ZORA, ZRO

*(The DAO can copy-paste any symbol(s) into `factory.add_synth()` to activate.)*