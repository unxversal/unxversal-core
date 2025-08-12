## Debugging and Refactoring Guidance for Sui Move (UNXV packages)

This guide distills the patterns and fixes we applied while cleaning up `synthetics.move` so you can systematically resolve similar issues across the rest of the codebase (e.g., `vaults.move`, `treasury.move`, etc.). Follow the workflow and checklists below to eliminate hundreds of recurring build and lint errors quickly and safely.

### Workflow: build-first, categorize, fix by class
The user will provide you the current errors for the file.

### Common fixes (by error class)

1) Incomplete name after '::' / turbofish misuse
- Problem: `table::new::<T, U>(ctx)` and similar often trigger parsing issues.
- Fix: Use standard generic syntax without turbofish spacing quirks.
  - Replace: `table::new::<String, u64>(ctx)`
  - With: `table::new<String, u64>(ctx)`

2) Missing/incorrect std helpers for cloning String and vectors
- Problem: Calling unknown helpers like `std::vector::copy` or `.clone()` on `String`.
- Fixes:
  - Implement a local `clone_string(&String) -> String` that copies bytes and re-utf8s:
    ```move
    fun clone_string(s: &String): String {
        let src = std::string::as_bytes(s);
        let mut out = std::vector::empty<u8>();
        let mut i = 0; let n = std::vector::length(src);
        while (i < n) { std::vector::push_back(&mut out, *std::vector::borrow(src, i)); i = i + 1; };
        std::string::utf8(out)
    }
    ```
  - Implement `copy_vector_u8(&vector<u8>) -> vector<u8>` similarly when you need to copy borrowed bytes from tables.
  - Replace all `foo.clone()` on `String` with `clone_string(&foo)`.

3) If-expression syntax without parentheses
- Problem: Inline if-expressions like `let x = if cond { a } else { b };` without parentheses break parsing.
- Fix: Always wrap the condition in parentheses:
  - `let x = if (cond) { a } else { b };`

4) u64::MAX is not available
- Problem: `u64::MAX` doesn’t resolve on Sui Move target.
- Fix: Define a module constant once and reference it everywhere:
  - `const U64_MAX_LITERAL: u64 = 18_446_744_073_709_551_615;`
  - Replace all `u64::MAX` with `U64_MAX_LITERAL`.

5) Coin vs Balance – storage vs I/O
- Problem: Storing `Coin<T>` in structs is space-inefficient and causes many API mismatches.
- Guidance:
  - Store as `sui::balance::Balance<C>` in on-chain state (e.g., vault collateral).
  - Keep user I/O and transfers as `sui::coin::Coin<T>` and convert at the boundary.
  - Use conversions:
    - Wrap: `coin::from_balance(balance, ctx)`
    - Unwrap: `coin::into_balance(coin)`
    - Split balance: `balance::split(&mut bal, amount)`
    - Join balance: `balance::join(&mut bal, part)`
  - Coin aggregation and splits:
    - Use `coin::join(&mut coin, other_coin)` (not `merge`).
    - Use `coin::split(&mut coin, amount, ctx)` (note the required `ctx`).

6) Vector and table borrow types
- Problems:
  - Using `vector<&T>` where code expects `vector<T>` and vice versa.
  - Passing a `&vector<u8>` where a `vector<u8>` is expected.
- Fixes:
  - For vectors in parameters: pick one – either pass values (`vector<T>`) and borrow items with `vector::borrow(&v, i)`, or pass `vector<&T>` but then don’t deref the borrow result.
  - For table borrows of `vector<u8>`, if you need an owned `vector<u8>`, copy it via `copy_vector_u8(table::borrow(...))` (no extra `&`).

7) Table API – consistent generics and usage
- Problem: Wrong generic form or types for `table::new`, `table::add`, `table::borrow(_mut)`, `table::contains`, `table::remove`.
- Fixes:
  - Create: `let t = table::new<String, T>(ctx);`
  - Access patterns use owned `String` keys – feed `clone_string(&key)` when needed.

8) Displays (sui::display) patterns
- Problem: Trying to add Display for non-key types or causing dependency cycles.
- Fixes:
  - Only types with `key` can have a Display. For non-key data, create a keyed wrapper (e.g., `struct SyntheticAssetInfo has key { id: UID, asset: SyntheticAsset }`) and register Display for that.
  - Always call `update_version()` and then transfer the Display object so wallets can access it.
  - Avoid cross-module Display registration that introduces dependency cycles. Register a type’s Display in its own module.

9) Documentation comments and banners
- Problem: `/* ****** */` banners flagged as doc issues.
- Fix: Replace with proper `///` doc comments above items or as section headings.

10) Unused imports and duplicate aliases
- Problem: Aliases like `use std::vector::{Self as vector};` or default Sui aliases cause warnings.
- Fix: Remove redundant Self aliases. If the module is used, minimal import is fine, otherwise delete the import.

11) Unused parameters and functions
- Problem: Lints for unused params or unused helper funcs.
- Fix: Prefix unused parameters with `_` (e.g., `_registry`, `_clock`), or remove functions if truly dead. For public APIs required by external callers, prefer `_`-prefixing.

12) Statement terminators after blocks
- Problem: Parser errors like “Unexpected 'let' / Expected ';'” after a block.
- Fix: Ensure statements are correctly terminated. In some contexts (after a block used as a statement), a trailing `;` is required before the next statement.

### Suggested remediation sequence per file
1) Replace banner comments with `///` and clean imports (remove redundant aliases).
2) Add `U64_MAX_LITERAL` and replace all `u64::MAX` references.
3) Fix if-expression conditions to use parentheses.
4) Implement `clone_string`, `copy_vector_u8` (once per module) and replace `.clone()` / `vector::copy` usages.
5) Convert stored `Coin<T>` fields to `Balance<T>` when appropriate; update deposit/withdraw/fees/settlement logic and conversions at boundaries.
6) Normalize table/vector APIs:
   - `table::new<String, T>(ctx)`
   - Pass proper owned keys (use `clone_string`).
   - Copy `vector<u8>` values as needed.
7) Fix coin API usage:
   - `coin::join` for aggregation
   - `coin::split(&mut coin, amount, ctx)`
8) Displays:
   - Register within the defining module; for non-key types, create keyed wrappers.
9) Resolve unused parameter/function warnings by `_`-prefixing or removal.
10) Re-run build and lints; address any residual type errors (usually mismatched reference/value types or missing `ctx`).

### Pattern snippets (copy-pasteable)

- Balance storage with Coin I/O (deposit):
```move
public fun deposit_collateral<C>(
    _cfg: &CollateralConfig<C>, vault: &mut CollateralVault<C>, coins_in: coin::Coin<C>, ctx: &mut TxContext
) {
    let bal_in = coin::into_balance(coins_in);
    balance::join(&mut vault.collateral, bal_in);
    vault.last_update_ms = sui::tx_context::epoch_timestamp_ms(ctx);
}
```

- Balance split to coin (withdraw):
```move
let out_bal = balance::split(&mut vault.collateral, amount);
let out_coin = coin::from_balance(out_bal, ctx);
```

- UNXV aggregation and split with ctx:
```move
let mut merged = coin::zero<UNXV>(ctx);
let mut i = 0; while (i < vector::length(&unxv_payment)) {
    let c = vector::pop_back(&mut unxv_payment);
    coin::join(&mut merged, c);
    i = i + 1;
};
let exact = coin::split(&mut merged, amount_needed, ctx);
```

- Table value copy for bytes:
```move
let k = clone_string(symbol);
if (table::contains(&registry.oracle_feeds, k)) {
    copy_vector_u8(table::borrow(&registry.oracle_feeds, clone_string(symbol)))
} else { b"".to_string().into_bytes() }
```

### Breaking dependency cycles
- Don’t register Display for `A::Type` in module `B` if `A` also depends on `B` – it forms a cycle.
- Register each type’s Display in its own module (or isolate display registration into a third module without depending back on the original).

### Validation checklist (before commit)
- Build is green: `sui move build`.
- No parser errors (if/blocks, semicolons).
- No `u64::MAX`; only `U64_MAX_LITERAL`.
- No `.clone()` on `String`; only `clone_string`.
- No `vector::copy`; only `copy_vector_u8` where needed.
- All `coin::split` include `ctx` and mutable self.
- Displays: `update_version()` and transferred; no cross-module cycles.
- Warnings addressed or intentionally `_`-prefixed.

### Notes
- Prefer small, safe, file-scoped edits; rebuild often.
- Default aliases for `vector`, `object`, `transfer`, `TxContext`, `option` are available; don’t redundantly alias modules with `Self as ...` unless necessary.


