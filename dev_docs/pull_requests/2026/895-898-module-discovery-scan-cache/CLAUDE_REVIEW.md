# PRs #895 + #898: module discovery — runtime scan cache and the fast module hash

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged (reviewed together: same module, same theme)
**Commits**: #895 `8a49033d2`, `cb27a2427` (merge `1d34e922f`); #898 `d8d087c80`, `822c6121c`, merge-of-main `de5899c6a` (merge `4bc66c0b9`)
**Date**: 2026-10-02 (merged 2026-10-04)

## Goal

- **#895** — the admin Modules page (and `ModuleRegistry.not_installed_packages/0`) ran
  `ModuleDiscovery.discover_external_modules/0` on every mount / toggle / PubSub event, reading every beam
  of every phoenix_kit-dependent dep. Cache the result once per VM in `:persistent_term`.
- **#898** — the host router's `__mix_recompile__?/0` called `module_hash/0` (a full scan), and Mix runs it
  on every compile — in dev, on every request through `Phoenix.CodeReloader`. Add `module_hash_fast/0`,
  which fingerprints the scan's inputs with `stat` alone and only re-scans when the fingerprint moves.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/module_discovery.ex` | #895: `cached_external_modules/0`, `refresh_cache/0`, `clear_cache/0` (`:persistent_term` + `:global.trans` single-flight). #898: `module_hash_fast/0` + inventory / fingerprint / memo helpers |
| `lib/phoenix_kit/module_registry.ex` | `load_modules/0` refreshes the cache (boot + `rescan/0`); `register/1`/`unregister/1` drop it; `installed_otp_apps` reads it; `not_installed_packages/0` computes it once |
| `lib/phoenix_kit_web/live/modules.ex` | `load_external_modules/1` reads the cache |
| `lib/phoenix_kit_web/integration.ex` | `__mix_recompile__?/0` calls `module_hash_fast/0`; the baked `current_hash` still comes from `module_hash/0` |
| tests + `test/support/module_scan_fixture.ex` | beam-read counting via `:beam_lib.chunks/2` call_count traces; fixture dep on the code path |

## Findings

### BUG - CRITICAL — #898's `@hash_memo_key` / `@settled_after_seconds` no longer exist; `module_hash_fast/0` is a silent no-op

`lib/phoenix_kit/module_discovery.ex:24` defines only `@cache_key`. The two attributes the fast path needs
are **read but never set**: `:125` (inside the `@doc`), `:141`, `:163`, `:164`, `:166`, `:176`.

Cause: the branch (`822c6121c`) defined them right after `require Logger`, with a comment; #895 added
`@cache_key` at the same spot. The "Merge branch 'main' into fix/module-hash-fingerprint" commit
(`de5899c6a`) resolved that overlap by keeping only `@cache_key` —
`git diff 822c6121c de5899c6a -- lib/phoenix_kit/module_discovery.ex` shows the `-@hash_memo_key …
-@settled_after_seconds 2` hunk. The merge never shows as a conflict in the PR's own diff, so it passed
review unnoticed.

Effect (an undefined attribute reads as `nil` and compiles with an `undefined module attribute` warning —
which `mix precommit`'s `compile --warnings-as-errors` should reject; I could not run mix here):

- `:persistent_term.get(nil, nil)` → no memo → `recompute_module_hash/0` → `newest < System.os_time(:second) - nil`
  raises `ArithmeticError` → the blanket `rescue` in `module_hash_fast/0` (`:148`) turns it into
  `module_hash/0`, **a full scan on every call**. The hash stays correct, so nothing breaks — #897 is simply
  not fixed, in the code path it was written for.
- The `@doc` renders "newer than  seconds".
- `module_hash_fast_test.exs`: the tests that count `:beam_lib.chunks/2` calls ("second call reads no beam",
  the `__mix_recompile__?/0` one) fail; the equality tests (`== module_hash/0`) and the "memo of another
  shape" test pass vacuously, because the fallback *is* the honest hash.

**Fix:** restore, under `@cache_key`:

```elixir
  # `:persistent_term` rather than a process or ETS table: there is no process of
  # ours to own one (Mix calls the check from its own compiler tasks, and
  # `PhoenixKit.KnownPackages` avoids persistent_term for a value that churns),
  # and this one is written only when the disk really changed.
  @hash_memo_key {__MODULE__, :module_hash_memo}

  # An mtime this recent cannot be told apart from "changed again a moment
  # later" on a filesystem with whole-second timestamps, so a fingerprint that
  # contains one is never remembered.
  @settled_after_seconds 2
```

Then run `mix test test/phoenix_kit/module_hash_fast_test.exs test/phoenix_kit/module_discovery_cache_test.exs`.

### IMPROVEMENT - HIGH — the blanket `rescue` in `module_hash_fast/0` hid the bug above, and the tests can't tell

`module_hash_fast/0` rescues *everything* to `module_hash/0` (`:148-151`). That is right for "a memo of
another shape", but it also converts any programming error in the fast path into a permanent, silent
performance regression — exactly what happened. Two cheap guards:

- log the rescued exception once (`Logger.warning`, deduplicated through a `:persistent_term` flag like
  `module_registry.ex:185`) so a broken fast path shows up in the dev console;
- add one test that asserts the memo is actually written after a settled call
  (`assert {_fp, _hash, _inv} = :persistent_term.get({ModuleDiscovery, :module_hash_memo}, nil)`), so the
  equality tests cannot pass while the optimisation is dead.

### IMPROVEMENT - MEDIUM — the dev host's own beams sit in the fingerprint, so every edit still costs a full scan (twice)

`scan_inventory/1` stats the beams of **every** app whose `.app` lists `:phoenix_kit` — and the host app is
one (the scan has no host exclusion). Any code edit rewrites host beams → the fingerprint moves → one full
scan on the next compile, and, because the changed files are younger than 2 s, the memo is not stored
(`:163`), so requests inside that window scan again; then one more scan after the settle. The fix removes
the per-*request* scan, not the per-*edit* one. Not wrong; the saving is partial in the case dev users feel
most.

**Fix (optional):** memoise the marker per beam, keyed `{path, mtime, size}` → module | nil, and on a miss
re-read only the beams whose key changed (the `inventory` already carries every name; storing the stat
beside it is a few lines). A miss then costs stats plus the handful of changed beams.

### IMPROVEMENT - MEDIUM — `:global.trans/2` locks across the whole cluster

`scan_once/0` (`:67`) uses the default `nodes = [node() | nodes()]`. The cache is node-local, so a cold
reader on node A waits for node B's multi-second scan for nothing, and a rolling restart serialises every
node's boot scan behind one cluster-wide lock. **Fix:** `:global.trans(id, fun, [node()])`. (`self()` as the
requester id is right: it keeps the lock re-entrant per process and exclusive between processes — the
concurrent-readers test proves one scan.)

### NITPICK — `register/1` / `unregister/1` drop the scan cache although the disk did not change

`module_registry.ex:663,672`. The scan cache holds disk + config; a runtime `register/1` of a module that is
not on disk changes neither, so the next Modules mount pays a cold scan (seconds) for no new information.
Defensible if the intent is "a module arriving at runtime might have new beams" — if so, say so in the
comment; otherwise drop the two calls. The test helpers call both constantly, which is why the tests
re-warm with `refresh_cache/0` after `register`.

### NITPICK — boot scans twice

`static_children/0` (Supervisor init) and `init/1` each go through `load_modules/0` → `refresh_cache/0`: two
full scans per boot, as before. `init/1` could read `cached_external_modules/0` when `static_children/0`
already filled it. Pre-existing, now one-line cheap to fix.

### NITPICK — `module_hash/0`'s doc is half stale

`module_discovery.ex:98-101` still says it is "used by `__mix_recompile__?/0`" — only the compile-time
baked hash uses it now. Reword (the `@doc` of `module_hash_fast/0` is correct).

### NITPICK — `persistent_term` churn

`put` of a different value and `erase` of an existing key trigger a global GC pass. `refresh_cache` /
`clear_cache` run at boot / rescan / register only, and the hash memo changes only after a disk change in
dev, so it is acceptable; noted because the memo's `inventory` (every beam name of every dependent app) is
the largest term stored.

### NITPICK — no CHANGELOG entry for either PR

Neither is in `CHANGELOG.md` (2.51.0 was cut before the merges). Goes in the next version's Fixed section.

## Verified OK

- **Equivalence of `module_hash_fast/0` and `module_hash/0`**: the inventory mirrors the scan —
  first sorted `.app` per dir (`Path.wildcard` order), `applications` check, dotfile exclusion,
  `Enum.uniq` / sort / `term_to_binary` / md5; a test compares them bit for bit.
- **Compile-time callers stay honest**: every router macro, the Mix compilers, `Migrations.Modules`,
  `ObanQueues` still call `discover_external_modules/0`; `integration.ex:1752` bakes `module_hash/0`.
  `cached_external_modules/0` has exactly two callers (registry `installed_otp_apps`, Modules page).
- **Fingerprint ordering** (fingerprint before scan; code path read once) leaves any race as one extra scan,
  never a stale pairing. The 2 s settle rule covers whole-second mtimes; future-dated mtimes (NFS, skewed
  clocks) never settle and just keep scanning — safe. `:infinity` on an unknown dir is never stored.
- **Single-flight**: lock released by `trans`'s `after` even if the scan raises; double-checked inside the
  lock. Writes by `refresh_cache/0` outside the lock (registry) are harmless — same disk, same value.
- **Modules page**: the cache removes the scan from `mount` and from the three toggle/PubSub re-renders.
  (The page's other `mount` work — settings and module configs — is pre-existing and untouched.)
- **Test hygiene**: both suites are `async: false` for the global trace / persistent_term; caches and code
  paths are restored in `on_exit`; fixture app names are unique per test; the `:modules` config test restores
  the env. `Process.sleep(3_200)` in `setup_all` is the price of the settle rule — acceptable.
- **Do the tests fail without the fix?** #895's beam-read counters would, since the fixture dep makes a scan
  visible (the "guards the assertions" test). #898's count tests would — and, as found above, *do* fail on
  today's tree.

## Verdict

#895: approve as merged. #898: **the merge dropped the memo attributes, so the optimisation does not
run** — restore the two attributes (above) before anything else, then consider the logging guard.

## Resolution (2.52.0)

- **BUG - CRITICAL** — fixed: `@hash_memo_key` and `@settled_after_seconds` restored in `module_discovery.ex`.
- **IMPROVEMENT - HIGH** — fixed: the rescue in `module_hash_fast/0` now logs why it fell back (the beam-read-count tests
  already fail without the memo; the equality tests pass either way by design).
- **IMPROVEMENT - MEDIUM (`:global.trans`)** — fixed: lock restricted to `[node()]`, matching the node-local cache.
- **IMPROVEMENT - MEDIUM (host beams in the fingerprint)** — not changed: a per-beam marker memo adds state for a
  dev-only cost the PR already cut from every request to every edit.
- `module_hash/0` doc — fixed. CHANGELOG — entries added under 2.52.0 Fixed.
- Register/unregister cache drops, double boot scan, `persistent_term` churn — left as noted (harmless).
