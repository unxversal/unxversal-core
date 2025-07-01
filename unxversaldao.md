# **unxversal DAO on Sui**

---

## 1 · Building blocks

| Layer                | Sui Move module      | Purpose                                               | Notes                                                |
| -------------------- | -------------------- | ----------------------------------------------------- | ---------------------------------------------------- |
| **UNXV Coin**        | `unxv::coin`         | Fungible coin, 9-decimals                             | Implements `TransferHooks` for vote-checkpointing    |
| **ve-Locker**        | `unxv_ve::locker`    | Time-locked NFTs that hold UNXV and host voting power | Linear decay → zero at unlock                        |
| **Gauge Controller** | `gauges::controller` | Stores weekly emission weights per product ID         | Updated by ve-votes                                  |
| **Governor**         | `gov::bravo`         | Propose → vote → queue                                | OpenZeppelin Governor-Bravo logic ported to Move     |
| **Timelock**         | `gov::timelock`      | 48 h execution delay                                  | Sole owner of every up-gradable or privileged module |
| **Treasury Safe**    | `treasury::safe`     | Owns UNXV & USDC reserves                             | `execute()` callable only by Timelock                |
| **Pause Guardian**   | `guardian::switch`   | 3-of-5 multisig can pause critical funcs for ≤ 7 days | Guardian capability burnable by DAO ≥ month 12       |

All objects are **Move resources**; authority is passed by object ownership transfer—no implicit `only_owner` addresses.

---

## 2 · ve-Locker internals

```move
struct Locker has key {
    id: UID,
    owner: address,
    unxv_amount: u64,
    unlock_ts: u64,
    slope: u128,   // voting power drop per second
    bias: u128,    // current voting power = max(0, bias − slope·(t−t0))
    delegate: address,
}
```

*Lock creation*

```
slope = amount / (lock_secs)
bias  = slope * lock_secs
```

* **Lock length**: 1 – 4 years (seconds granularity, max constant enforced).
* **Checkpoint**: `locker.touch()` called on any lock/extend/merge to record bias in `History<T>::vector`.
* **Delegation**: `delegate` field amendable anytime; checkpoints emitted.

---

## 3 · Governor parameters

| Param                         | Value                           | Rationale                       |
| ----------------------------- | ------------------------------- | ------------------------------- |
| **proposalThreshold**         | 1 % of circulating **ve** power | Filters spam                    |
| **maxOperations**             | 20 calls / proposal             | Enough for multi-asset upgrades |
| **quorumNumerator**           | 4 % of circulating ve power     | Avoid governance capture        |
| **votingDelay**               | 1 day                           | Time to read forum post         |
| **votingPeriod**              | 5 days                          | Long enough for retail voters   |
| **executionDelay (Timelock)** | 48 h                            | Reaction window for users       |
| **gracePeriod**               | 7 days                          | Must execute within a week      |

All constants live in `gov::config` and can only be **lowered in safety** (e.g., shorten voting) by a full on-chain proposal.

---

## 4 · Proposal lifecycle (block-time view)

```mermaid
graph TD
  Forum[Discourse RFC<br/>(5 days)]
  Snapshot[Off-chain temp check<br/>(3 days)]
  Proposal[On-chain proposal<br/>(submit + 1% stake)]
  Vote[Voting window<br/>(5 days)]
  Queue[Timelock<br/>(48 h)]
  Exec[Execute<br/>state change]

  Forum --> Snapshot
  Snapshot -- majority & quorum --> Proposal
  Proposal --> Vote
  Vote -- majority & quorum --> Queue
  Queue --> Exec
```

*If quorum fails*, proposer’s 1 000 UNXV bond is **slashed** to Treasury.

---

## 5 · Pause Guardian

| Item           | Detail                                                                                        |
| -------------- | --------------------------------------------------------------------------------------------- |
| **Structure**  | Multisig object `guardian::Safe`, 5 signers, 3 to act                                         |
| **Scope**      | Can call `set_paused(true)` on: Synth Vault, Lend Pool, Perps ClearingHouse, Futures, Options |
| **Duration**   | Max 7 days per incident (`expiry_ts` stored), auto-unpauses                                   |
| **Revocation** | DAO can `guardian::burn_capability()` after month 12 if ≥ 10 % ve power vote “yes”            |

Guardian has **no ability to move funds** or **raise fees**—only freeze or lower risk parameters.

---

## 6 · Gauge voting

* Weekly epoch ID = `floor(timestamp / 604800)`.
* Each locker casts `weight(assetId, pct)`; sum of weights per epoch must = 100 %.
* `controller.emit_rate(assetId)` reads votes at epoch rollover and mints community-emission UNXV directly to product distributors.

*Abstain* → weight defaults to previous epoch (reduces gas).

---

## 7 · Admin / upgrade flow

1. Devs publish a new **Move package** with version bump (`UnxvPerps v2`).
2. DAO proposal includes:

   ```move
   gov::queue(
       timelock,
       [
         call UnxvPerps::migrate_state(old_addr, new_addr),
         call Registry::update_addr("perps", new_addr)
       ]
   )
   ```
3. After Timelock delay, anyone calls `execute()`; registry switches, old contract becomes read-only.

No opaque delegate-calls; upgrades are explicit installs + state copy.

---

## 8 · Gas & storage considerations

| Concern                     | Mitigation                                                                |
| --------------------------- | ------------------------------------------------------------------------- |
| Growing vote history vector | Prune checkpoints older than 1 year into cumulative “archive” entry       |
| Storage fees for lockers    | Locker can merge into another locker (same owner) to reduce object count  |
| Proposal blob size          | `gov::bravo` stores only hash; full calldata lives in IPFS, fetched by UI |

---

## 9 · Off-chain tooling

* **Discourse** for RFC threads → auto-sync into Sui indexer for link integrity.
* **Snapshot-style** temp-check via off-chain signature; UI displays but governance ignores result unless majority “yes”.
* **CLI** (`unxv-gov`) to batch-sign vote txs, delegate power, and simulate proposals locally.

---

## 10 · TL;DR

* **ve-UNXV NFTs** hold voting power that decays linearly to unlock.
* **Governor → Timelock** controls every privileged call; 48 h delay.
* **3-of-5 Pause Guardian** can only pause or lower risk for 7 days, revocable after year 1.
* Gauge voting routes emissions, and proposer deposits are slashed to deter spam—keeping the DAO solvent, competitive and credibly neutral.