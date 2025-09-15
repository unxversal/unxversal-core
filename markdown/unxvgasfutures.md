### ℹ️ About Sui Gas Futures

**Sui Gas Futures** let you trade the **on-chain reference gas price** of Sui. The product is cash-settled in USDC and uses the Sui runtime’s own `reference_gas_price` as the price index (no off-chain oracles).

---

#### 📈 What the price is
- **Index**: Sui’s `reference_gas_price` (in **MIST**).
- We treat this as a **1e6-scaled price unit** internally. In other words, the on-chain `reference_gas_price` number is used directly as `price_1e6`.

> Plain English: if the chain reports `reference_gas_price = 1,200` (MIST), the futures **price** we use in the engine is **1,200** in 1e6-scaled units.

---

#### 🔢 What 1 contract means
- **Contract size**: `contractSize` MIST **per** 1e6 price unit **per contract**.
- **Per-contract notional (in USDC)**:
  
  **notional = (price_1e6 × contractSize) / 1,000,000**

- P&L is linear in price changes:
  
  **ΔPnL (per contract) = (Δprice_1e6 × contractSize) / 1,000,000** (paid in USDC)

**Example** (using your defaults):
- `contractSize = 2`
- Index moves from **1,000 → 1,500** (Δprice_1e6 = **+500**)
- **Per-contract P&L = 500 × 2 / 1,000,000 = +0.001 USDC**  
  (Scale position size to get the exposure you want.)

> Tip: If you want bigger $ moves per tick in your UI, increase `contractSize`.

---

#### 🧮 Margin, fees, liquidation (defaults shown)
- **Initial Margin (IM)**: `initialMarginBps = 1000` (10% of notional)
- **Maintenance Margin (MM)**: `maintenanceMarginBps = 600` (6% of notional)
- **Liquidation Fee**: `liquidationFeeBps = 100` (1% of notional)  
  – portion routed to keeper via `keeperIncentiveBps = 2000` (of the penalty share)
- **Tiered IM**: Large notionals can require higher IM (see tier thresholds in code).
- **Share-of-OI & Notional Caps**: Optional risk controls may cap per-account exposure.

---

#### 🕒 Listing & expiry
- Markets are generated **weekly** (per your config: Friday 00:00 UTC), for up to `maxMarkets`.
- **Settlement**: At expiry, we snap the settlement price from the **Last Valid Print (LVP)** at/just before expiry.  
  If unavailable, we fall back to a **5-minute TWAP** over recent samples.  
  After settlement, the market becomes **close-only**, and PnL is cash-settled in USDC.

---

#### 🧷 Price integrity
- **On-chain index only**: prices come from `reference_gas_price` (MIST).
- **Deviation gate** (optional): trades may be rejected if the current index deviates beyond `max_deviation_bps` from the last stored price.
- **TWAP buffer**: we keep up to 64 recent samples over a 5-minute window to compute TWAP when needed.

---

#### 🧾 Order flow
- **Order book** matching with maker/taker events.
- **Maker rebates / taker fees** are accounted in USDC (or via your UNXV discount path).
- Realized PnL credits are streamed to your account; unrealized becomes realized on trade close.

---

#### 📌 TL;DR
- **Underlying**: Sui `reference_gas_price` (MIST) → used as `price_1e6`.
- **Value per contract**: `(price_1e6 × contractSize) / 1,000,000` USDC.
- **PnL per contract**: `(Δprice_1e6 × contractSize) / 1,000,000` USDC.
- **Cash-settled** in USDC. Weekly expiries with on-chain index, LVP/TWAP settlement.
