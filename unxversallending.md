# unxversal lend — Permissionless money-market on **Sui**

Turns any Pyth-priced asset—**USDC, UNXV, or sAssets**—into productive collateral you can borrow against, earn interest on, flash-loan, or use as margin for perps, futures, and options.
All protocol reserves are swapped to **UNXV** at accrual time, feeding the fee flywheel.

---

## 1 · Module map (Move)

| Module              | Resource / Object                              | Role                                                        |
| ------------------- | ---------------------------------------------- | ----------------------------------------------------------- |
| `lend::pool`        | `PoolConfig`, `MarketInfo`, `AccountLiquidity` | Core ledger & interest math                                 |
| `lend::utoken`      | `UToken<Underlying>`                           | Interest-bearing receipt coin (“uUSDC”, “uUNXV”)            |
| `lend::rates`       | `RateModel<Underlying>`                        | Piece-wise linear borrow-rate curve                         |
| `lend::controller`  | —                                              | Collateral factors, pause switches                          |
| `lend::oracle`      | —                                              | Reads Pyth price objects; fallback to DeepBook TWAP         |
| `lend::flashloan`   | —                                              | Single-block borrow of any listed asset                     |
| `lend::liquidation` | —                                              | Close factor, seize bonus, penalty routing                  |
| `fee_sink::reserve` | —                                              | Swaps reserveFactor share → UNXV; locks half into ve-locker |

All markets live in **one** Pool object; adding a new asset is an O(1) on-chain action.

---

## 2 · Supported assets v1

| Underlying | Decimals | CollateralFactor | ReserveFactor | Oracle source            |
| ---------- | -------- | ---------------- | ------------- | ------------------------ |
| **USDC**   | 6        | 80 %             | 10 %          | Pyth                     |
| **UNXV**   | 9        | 40 %             | 15 %          | Pyth (DEX TWAP fallback) |
| **sBTC**   | 18       | 65 %             | 20 %          | Pyth BTC/USD             |
| **sETH**   | 18       | 70 %             | 20 %          | Pyth ETH/USD             |

*(Governance can list any Pyth-priced coin or synth; params gated by timelock.)*

---

## 3 · Interest-rate model (per asset)

```
          borrowRate(u)
             ▲
  slope2     |                /
             |               /
             |              /
  slope1     |            /
             |          /
 baseRate    |________/________  u = borrowed / supplied
                     kink
```

Default constants:

| Asset | base  | slope1 | slope2 | kink |
| ----- | ----- | ------ | ------ | ---- |
| USDC  | 0 %   | 5 %    | 300 %  | 80 % |
| UNXV  | 0.5 % | 8 %    | 400 %  | 70 % |
| sBTC  | 1 %   | 10 %   | 500 %  | 70 % |

`accrue_interest()` runs once per block, updating `borrowIndex` & `uToken exchangeRate`.

---

## 4 · User flows

### 4.1 Supply

```move
coin::transfer<USDC>(wallet, pool_addr, 10_000 * 10^6);
lend::pool::supply<USDC>(pool, 10_000_000);
```

Returns `uUSDC` at `exchangeRate`.

### 4.2 Borrow

```move
let amount = 5 * 10^18; // 5 sETH
lend::pool::borrow<sETH>(pool, amount);
```

Controller checks:

```
borrowValueUSD ≤ Σ(collateral_i * factor_i * price_i)
```

### 4.3 Repay & withdraw

```move
lend::pool::repay<sETH>(pool, amount);
lend::pool::withdraw<USDC>(pool, uUSDC_amount);
```

### 4.4 Flash-loan

```move
lend::flashloan::execute<UNXV>(
     pool, 
     amount, 
     b"callback_payload"
);
```

Must return `amount + fee` in the same transaction or abort.

---

## 5 · Liquidations

| Trigger     | `healthFactor < 1.0`                                     |
| ----------- | -------------------------------------------------------- |
| CloseFactor | 50 % of debt                                             |
| Seize bonus | 10 % of repaid debt (liquidator keeps 60 %, 40 % → burn) |

Liquidator may atomically swap seized collateral on DeepBook to cover gas risk.

---

## 6 · Reserve Factor & UNXV conversion

1. On each `accrue_interest()`, `interest * reserveFactor` is transferred to `fee_sink::reserve`.
2. `reserve.swap_to_unxv()` RFQs price on DeepBook; slippage guard 1 %.
3. Resulting UNXV:

   * **50 %** locked 4 y into ve-locker (auto-delegate to Treasury)
   * **50 %** held liquid in Treasury Safe.

All on-chain; no off-chain keeper.

---

## 7 · Integration hooks

| Protocol                      | Benefit received                                                    | How to use Lend                                                       |
| ----------------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------- |
| **Perps / Futures / Options** | Earn supply APY on idle margin                                      | Clearing-house deposits user margin as supply; withdrawals burn uCoin |
| **Synth vault**               | Flash-borrow USDC to rescue under-CR vaults                         | `flashloan` call inside liquidation tx                                |
| **Liquidation bots**          | One tx: flashBorrow → repay → seize collateral → swap → repay flash | Reduces external capital requirement                                  |

---

## 8 · Risk management & governance knobs

| Parameter          | Bounds             | Change flow                |
| ------------------ | ------------------ | -------------------------- |
| `collateralFactor` | ≤ 90 %             | Governor → Timelock        |
| `reserveFactor`    | ≤ 20 %             | Governor → Timelock        |
| RateModel slopes   | ±50 %/proposal     | Governor → Timelock        |
| Pause market       | instant lower-only | Guardian (unpause via DAO) |

Price guard: any oracle older than `staleTolerance = 30 min` pauses new borrows.

---

## 9 · Security checklist

| Vector               | Mitigation                                                                    |
| -------------------- | ----------------------------------------------------------------------------- |
| Oracle spoof         | Pyth price attestation → Move verifier; DeepBook TWAP fallback w/ 5 % haircut |
| Interest overflow    | `checked_math` & 128-bit indices                                              |
| Insolvent flash-loan | Borrow must revert unless `amount+fee` returned                               |
| Re-entrancy          | No external calls before internal state updates                               |
| Bad CF change        | Only decreases fast; increases 48 h delayed                                   |

Full audit + Code4rena contest precede mainnet.

---

## 10 · Gas & UX notes

* **Single shared `Pool` object** → one lookup per op.
* `uToken` implements `coin::transfer` so wallets treat it like any coin.
* SDK auto-applies EIP-712 style permits using Sui’s `sponsored_tx` for gasless approvals.

---

## 11 · Launch KPI targets

| Metric                     | Goal       |
| -------------------------- | ---------- |
| Supply TVL after 3 m       | \$30 M     |
| Avg utilisation (USDC)     | 60 %       |
| Annual reserve flow → UNXV | ≥ 5 M UNXV |
| Insolvent accounts         | 0          |

---

## 12 · TL;DR

* One shared money market, unlimited asset listing via Pyth feeds.
* Interest & liquidation reserves auto-convert to **UNXV**, half lock, half treasury.
* Built-in flash-loans, oracle redundancy, and cross-margin plug-ins power the rest of the unxversal stack.