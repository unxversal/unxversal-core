## Unxversal Protocol – Module‑Agnostic Audit Execution Protocol

### Purpose
This document describes a repeatable, module‑agnostic process for auditing and hardening Move modules under `packages/unxversal/sources`. It defines how to author and maintain `packageaudit.md`, the per‑module task numbering scheme, sequencing, acceptance criteria, and coding conventions required to reach mainnet readiness. Synthetics is used at the end as a worked example, but the protocol applies uniformly to DEX, Lending, Treasury, Oracle, and other modules.

### Scope and guiding principles
- **No backwards compatibility**: Remove legacy/obsolete code, helpers, and comments. Do not keep code “just in case.”
- **Production-ready, no placeholders**: Implement fully and cleanly; do not leave stubs/todos; do not silence lint warnings [[memory:6164256]] [[memory:5808521]].
- **Use Switchboard On-Demand (when dealing with oracles)**: Bind price feeds by hash; scrub Pyth-specific naming. Verify feed hash on use [[memory:6116637]].
 - **ZERO-TRUST prices (no user-supplied numbers)**: Always read prices from Switchboard aggregators with staleness/positivity checks; do not accept per-tx input price bags (e.g., PriceSet) for state-changing ops. If helper containers exist, they must be populated from aggregators within the same PTB and validated by feed-hash bindings.
- **Time source**: Use `sui::clock::Clock` and `timestamp_ms(clock)` for time; pass an immutable `Clock` ref where needed [[memory:6164259]].
- **Move docs**: Use `///` for documentation comments [[memory:6116641]].
- **Repo hygiene**: Do not modify any files under `packages/sui` [[memory:6969244]].

### Deliverable artifacts
- `packageaudit.md`: A numbered, trackable checklist of audit items for the active module using a module prefix (e.g., `SYN-01…`, `DEX-01…`, `LEND-01…`). Each item carries a status tag `[Pending]`, `[In‑Progress]`, or `[Done]` and a concise problem/remediation summary.
- Code edits to the active module file(s) and only the minimal, related hooks in dependent modules (e.g., DEX hooks when auditing Synthetics).

### Task numbering and statuses
- Choose a short module code and prefix all tasks:
  - Synthetics → `SYN-XX`
  - DEX → `DEX-XX`
  - Lending → `LEND-XX`
  - Treasury → `TRE-XX`
  - Oracle → `ORC-XX`
- Each checklist line begins with its ordinal and status, e.g. `1) [Pending] Title (SYN-01)`.
- Update the status inline as work progresses: `[Pending]` → `[In‑Progress]` → `[Done]`.

### Baseline checklist to instantiate in packageaudit.md (module‑agnostic)
Create items from the categories below (rename titles and adapt detail per module). For Synthetics, the right column shows the example mapping used.

- Core settlement/consistency invariants → e.g., PnL nets between parties; no value leakage (SYN‑01)
- Authorization and permissionless flows → e.g., DEX‑authorized fills without owner gate (SYN‑02)
- Matching/operation invariants → e.g., symbol/side/tick/lot/price bands; binding to accounts (SYN‑03)
- Legacy removal → delete obsolete types/APIs/comments; no back‑compat scaffolding (SYN‑04)
- Treasury semantics → only fees/penalties go to Treasury; business logic value flows peer↔peer (SYN‑05)
- Incentives/discounts → enforce preconditions; document fallbacks (SYN‑06)
- Risk caps → use live inputs for risk checks (e.g., concentration, leverage) (SYN‑07)
- Lifecycle events → placement/creation + updates + GC/expiry events (SYN‑08)
- Comment/docs cleanup → phase markers/old design references removed (SYN‑09)
- Fail‑closed posture → assert required bindings/config are set before actions (SYN‑10)
- Config pruning → keep only used params; remove dead settings (SYN‑11)
- Views/API shape → last‑mark vs price‑aware/read‑only consistency (SYN‑12)
- Test scaffolding cleanup → remove obsolete test‑only mirrors; modernize helpers (SYN‑13)
- Price/input coverage → assert complete, non‑zero inputs before state change (SYN‑14)

### Standard workflow (applies to any module)
1. Discovery pass
   - Read the target module(s) end-to-end.
   - Read adjacent modules that interface with the target (only as necessary for invariants).
   - Confirm repository rules: do not edit `packages/sui` [[memory:6969244]].
2. Initialize `packageaudit.md`
   - Add the “Unxversal <Module> – Production Readiness Audit (Trackable Checklist)” heading.
   - Insert items per the categories above with `[Pending]` status, each with a Problem/Evidence/Remediation trio.
   - Add a short Notes section reminding about oracle/Treasury conventions where relevant.
3. Execute tasks in priority order
   - Priority template: CORE INVARIANTS → AUTH → MATCH/RISK → LEGACY REMOVAL → TREASURY/INCENTIVES → RISK CAPS → LIFECYCLE → COMMENTS/FAIL‑CLOSED → CONFIG/VIEW/TEST CLEANUP.
   - For Synthetics, this maps to: SYN‑01 → SYN‑02 → SYN‑03 → SYN‑04 → SYN‑05 → SYN‑06 → SYN‑07 → SYN‑08/09/10 → SYN‑11/12/13/14.
   - After each change, run lints/build for the edited files and update `packageaudit.md` status to `[Done]` when satisfied.
4. Lint/build discipline
   - For each edited Move file, run lints or `sui move build` and resolve errors systematically: first run the build, list the errors/warnings per file, then fix them file-by-file [[memory:5902724]].
   - Never disable lints to “get green” [[memory:6164256]].
5. Documentation and comments
   - Replace legacy/phase terminology with the current design language.
   - Keep comments concise and use `///` docs [[memory:6116641]].

### Implementation guidance per checklist category (apply per module)
- **Core settlement/consistency**: Ensure value conservation across operations (e.g., PnL nets party↔party; borrow/repay adjust totals consistently; escrow accounting matches book state).
- **Authorization/permissionless**: Expose package‑visible paths for system actors (e.g., DEX/keepers) while keeping owner‑only where appropriate; enforce capability‑based checks instead of sender equality when matching.
- **Matching/operation invariants**: Validate price/size/tick/lot bounds, opposite sides, non‑crossing guards for posted remainders, account/object bindings.
- **Legacy removal**: Delete obsolete structs/APIs/comments; scrub old vendor naming; avoid “compat” code for unpublished versions.
- **Treasury semantics**: Route only protocol revenues and penalties to Treasury; never route directional PnL there.
- **Incentives/discounts**: Require all needed inputs (e.g., token price) when applying discounts; else skip explicitly.
- **Risk caps**: Enforce IM/MM/leverage/concentration using live inputs when needed; avoid relying on stale marks during state changes.
- **Lifecycle events**: Emit creation, placement, matched, cancelled/expired, and GC events to support indexers.
- **Comments/docs**: Replace phase markers/legacy language with current design; keep docs concise and actionable.
- **Fail‑closed posture**: Guard on required bindings (e.g., registry→treasury, registry→collateral config, pool configs) before allowing actions.
- **Config pruning**: Keep only used config fields; remove dead config to reduce attack surface.
- **Views/API shape**: Separate last‑mark diagnostics from live, input‑validated views; remove unused parameters.
- **Test scaffolding**: Replace legacy mirrors with current domain events or targeted test helpers.

### Oracle and time handling
- Verify Switchboard feed binding by comparing the aggregator’s feed hash against the registry mapping; read price via a staleness‑checked function when applicable [[memory:6116637]].
- For time, pass `&Clock` and call `sui::clock::timestamp_ms(clock)` as needed [[memory:6164259]].

### Indexing and events
- Emit precise, machine‑readable events for: parameter updates, position/order lifecycle, fees, liquidations, and other module‑specific milestones.

### Citing code in packageaudit.md (examples)
- When citing evidence, prefer exact code snippets with file path and line range:
```1215:1264:packages/unxversal/sources/synthetics.move
// snippet
```
- Keep citations short and relevant; elide unrelated content.

### Definition of Done
- All baseline items for the active module are `[Done]` in `packageaudit.md`.
- No legacy references or obsolete vendor naming remain.
- All permissionless flows and invariants are enforced as applicable to the module.
- Treasury/incentive semantics are correct for the module’s remit.
- Lints/build pass; comments updated to reflect the current design.
- No changes under `packages/sui` [[memory:6969244]].

### Template – packageaudit.md (starter skeleton)
```
## Unxversal <Module> – Production Readiness Audit (Trackable Checklist)

Status legend: [Pending], [In‑Progress], [Done]

1) [Pending] <Module‑specific core consistency item> (MOD‑01)
   - Problem:
   - Evidence:
   - Remediation:

2) [Pending] <Module‑specific authorization/permissionless item> (MOD‑02)
   - Problem:
   - Evidence:
   - Remediation:

... continue items per the category list, up to 14

Notes
- Oracle stack: Switchboard On‑Demand only (if applicable).
 - ZERO‑TRUST price policy: never trust user-inputted prices; use aggregator reads with feed-hash verification.
- Treasury semantics: only fees/penalties go to Treasury (if applicable).
```

### Sequencing rationale
- Address critical correctness and UX first (CORE/AUTH/MATCH), then remove legacy to reduce surface area, then harden fees/discounts/risk caps, finish lifecycle and fail‑closed posture, and finally streamline config/views/tests.

### Post‑completion
- When all tasks are `[Done]`, add a short summary to `packageaudit.md` noting impact, and prepare a separate testing plan (unit/integration) in a new task set (tests are implemented as a separate step, not embedded during code completion [[memory:5808521]]).

### Worked example (Synthetics)
- Use `SYN-XX` prefix; instantiate the 14 baseline items with the synthetics‑specific wording used during this migration.
- Touch DEX only where necessary for synth settlement/matching invariants.


