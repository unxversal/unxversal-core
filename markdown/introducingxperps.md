### ℹ️ About xPERPs

**xPERPs** are perpetual contracts on synthetic underlyings that don’t have a liquid spot market. They let you trade directional exposure on things like **private-company valuations** or the **USD cost of blockchain gas**, using the same tools you know from perps and options.

---

#### 🏢 Private-Company xPERPs

Examples: **xOPENAI, xSTRIPE, xKALSHI**

* Each synthetic represents **exposure to a private company’s valuation**, not equity.
* **1 unit = a scaled valuation chip.** We use one consistent formula:

  **Implied Valuation (in $B) = xPERP Price (in $) × 0.75**

* This means that every $1 in price corresponds to **$0.75B of implied company valuation**.  
  - Example: if **xOPENAI trades at $800**, the implied valuation is **$600B**.  
  - If **xKALSHI trades at $10**, the implied valuation is **$7.5B**.
* The displayed *reference price* (e.g. $667 for xOPENAI) is just a **baseline anchor** derived from the company’s most recent valuation using this standard formula.

⚠️ This baseline is *not a cap*. Market prices are set entirely by supply and demand and can move freely — into the hundreds or thousands if traders believe the company is worth more.

---

#### ⛽ Gas Futures xPERPs

Examples: **xgETH, xgSOL, xgARB**

* Each gas xPERP tracks the **USD cost of a simple native transfer** on a given chain.
* **1 unit = the cost of one simple transfer, in USD.**
  - Example: if **xgETH = $0.45**, that means one ETH L1 transfer costs about $0.45.
* The *reference price* is based on recent averages, while the **live index is an EMA** of observed transaction fees.
* ⚠️ Prices can rise sharply with network demand (NFT mints, airdrops, congestion). There is no ceiling.

---

#### 📌 Key Takeaways

* **Private-company xPERPs:** 1 unit = scaled valuation chip. Formula: $1 = $0.75B of implied valuation.
* **Gas xPERPs:** 1 unit = the live USD cost of one simple transfer.
* **Reference prices are just baselines** — actual trading levels are discovered by the market.
* **PnL always in USDC** — all xPERPs settle to stablecoin profit/loss.