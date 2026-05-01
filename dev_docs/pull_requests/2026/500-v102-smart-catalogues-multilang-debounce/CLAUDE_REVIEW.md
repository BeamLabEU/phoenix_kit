# Claude Review — PR #500

**Title:** Add V102 smart catalogues migration and multilang debounce flow
**Author:** @mdon
**Branch:** `dev` → `dev` (internal)
**Diff:** +658 / −30 across 11 files
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/500

## Summary of changes

1. **V102 migration** — adds `discount_percentage` to catalogues (NOT NULL default 0) and items (nullable override), a `kind` column on catalogues (`'standard' | 'smart'`), per-item `default_value` / `default_unit`, and a new `phoenix_kit_cat_item_catalogue_rules` join table. All wrapped in idempotent `DO $$ … $$` blocks; `down/1` is explicit and lossy-but-reversible.
2. **MultilangForm debounce flow** — `mount_multilang/1` now attaches a hidden `:handle_info` hook via `Phoenix.LiveView.attach_hook/4`. `handle_switch_language/2` schedules a 150 ms trailing debounce via `Process.send_after`, storing the timer ref in `socket.private`. `switch_lang_js/2` toggles skeleton/fields `hidden` classes **client-side at t=0**, so the server never fights the client on visibility state.
3. **Core form components** — `<.input>`, `<.select>`, `<.textarea>`, `<.checkbox>` realign `class` to merge onto the styled element (Phoenix 1.7 generator convention). `<.input>` gains `wrapper_class` for the outer `phx-feedback-for` div. Per the PR: no in-tree caller used the old semantics — I verified this with grep (zero matches for `<.input … class=` etc. in `lib/phoenix_kit_web/`).
4. **CSS sources compiler** — handles absolute dep paths without the broken `../../` prefix.
5. **`mix.exs`** — adds `test_load_filters` / `test_ignore_filters` for Elixir 1.19 `mix test` hygiene, bumps version to **1.7.99**.
6. **AGENTS.md** — adds Core Form Components / Multilang Form Components sections, plus a new "CHANGELOG ownership" rule.

---

## Findings

### BUG — MEDIUM: AGENTS.md says "process dictionary" but implementation uses `socket.private`

**File:** `AGENTS.md` line 39 (new Multilang section)

> *"…schedules a new `Process.send_after(self(), {:__multilang_apply_lang__, lang}, 150)`, **stores the timer ref in the process dictionary** (not socket assigns — avoids triggering phantom render+diff cycles)…"*

The implementation actually stores the ref via `Phoenix.LiveView.put_private/3`:

```elixir
# lib/phoenix_kit_web/components/multilang_form.ex:642
Phoenix.LiveView.put_private(socket, @multilang_timer_private_key, timer_ref)
```

And the new test file explicitly contrasts the two:

```elixir
# test/phoenix_kit_web/components/multilang_form_test.exs:834
# The timer ref now lives in `socket.private` (not the process
# dictionary) so we assert against that.
```

Agents reading AGENTS.md would be misled about where to look / how to test. Small doc fix: replace "process dictionary" with "`socket.private` (via `Phoenix.LiveView.put_private/3`)". Rationale (diff cost vs. assigns) still stands and is valid for `private` too.

### IMPROVEMENT — MEDIUM: Stale debounce message can still slip through after `cancel_timer`

**File:** `lib/phoenix_kit_web/components/multilang_form.ex:658` (`cancel_multilang_timer/1`)

```elixir
defp cancel_multilang_timer(socket) do
  case Map.get(socket.private, @multilang_timer_private_key) do
    ref when is_reference(ref) ->
      Process.cancel_timer(ref)
      Phoenix.LiveView.put_private(socket, @multilang_timer_private_key, nil)
    _ ->
      socket
  end
end
```

`Process.cancel_timer/1` returns `false` (and does nothing useful) if the timer already fired — in which case the `{:__multilang_apply_lang__, stale_lang}` message is already sitting in the mailbox. Sequence:

1. User clicks EN → T1 scheduled.
2. 150 ms elapses, T1 fires, `{:__multilang_apply_lang__, "en"}` lands in mailbox, LV process hasn't dequeued yet.
3. User clicks JA → `cancel_multilang_timer` called but T1 has already fired (returns false). New T2 scheduled for `"ja"`.
4. LV dequeues T1 → hook sets `current_lang = "en"` → render.
5. LV dequeues T2 → hook sets `current_lang = "ja"` → render.

The new test already hedges for this: `assert length(messages) <= 1`. In practice morphdom will coalesce but two server renders still happen, which is exactly what the debounce was introduced to prevent.

Cheap fix inside `cancel_multilang_timer`: flush the mailbox of any stale apply message after cancel:

```elixir
Process.cancel_timer(ref)
receive do
  {:__multilang_apply_lang__, _} -> :ok
after
  0 -> :ok
end
```

Or use `Process.cancel_timer(ref, async: false, info: false)` + an explicit flush — either way, bound the number of renders to 1 in all cases.

### IMPROVEMENT — LOW: `rescue ArgumentError` is broader than intended

**File:** `lib/phoenix_kit_web/components/multilang_form.ex:586`

```elixir
rescue
  ArgumentError -> socket
```

The intent (per the comment) is "ignore `attach_hook/4` refusing to run on a LiveComponent socket". But any other `ArgumentError` raised from inside `attach_hook/4` (bad callback arity, future LiveView tightening) would also be silently swallowed, and the consumer would lose the debounce hook with no hint. Two tighter alternatives:

- Gate on the socket shape: `if Map.has_key?(socket, :router) and socket.router != nil, do: attach, else: socket` — or check `Phoenix.LiveView.connected?/1` + whatever field disambiguates LV from LiveComponent in your target LV version.
- Rescue and match the message: `%ArgumentError{message: msg}` where `msg =~ "attach_hook"` — clumsy but explicit.

Not a blocker — the current code is pragmatic and the intended failure mode is "consumer adds handle_info manually", which the test file doesn't exercise. Worth a TODO comment at minimum.

### IMPROVEMENT — LOW: `phoenix_kit_cat_item_catalogue_rules_item_index` is redundant with the unique pair index

**File:** `lib/phoenix_kit/migrations/postgres/v102.ex:277–284`

```sql
CREATE UNIQUE INDEX … _pair_index ON … (item_uuid, referenced_catalogue_uuid)
CREATE INDEX … _item_index ON … (item_uuid)
```

Postgres can use the leftmost prefix of a composite index. `_pair_index` already satisfies any query filtering solely by `item_uuid`, so `_item_index` is a duplicate write cost with no read benefit. Safe to drop it. `_referenced_index` is justified because `referenced_catalogue_uuid` is the right-hand column of `_pair_index` and wouldn't be used by the planner for that filter alone.

### IMPROVEMENT — LOW: Partial index indexes `(uuid)` but the predicate is on `kind`

**File:** `lib/phoenix_kit/migrations/postgres/v102.ex:346–350`

```sql
CREATE INDEX … _kind_smart_index ON phoenix_kit_cat_catalogues (uuid) WHERE kind = 'smart'
```

Comment says *"smart-item edit form filters by them on every mount"*, i.e. `SELECT … WHERE kind = 'smart'`. Indexing on `(uuid)` is fine for covering, but so is an even cheaper index — Postgres will use a partial index as a small bitmap scan regardless of the indexed column, so you could index the predicate column itself (`ON (kind) WHERE kind = 'smart'`) or just `ON (name)` if the edit form also sorts by name. Not wrong as-is; just a note that there may be a more useful indexed expression for common queries like "list smart catalogues sorted by name".

### NITPICK: CHANGELOG.md gap

`mix.exs` bumps `@version` to `1.7.99` but `CHANGELOG.md` has no new entry. Per the new AGENTS.md rule added in this same PR ("CHANGELOG ownership: entries are written by the project maintainer… flag the gap and stop"), this is **intentional**. Flagging as the rule instructs — maintainer (@fotkin) please fill in the CHANGELOG entry before the next hex publish. Not a blocker for merging.

### NITPICK: `kind` vocabulary is defined in three places

`'standard' | 'smart'` appears in (1) the `DEFAULT 'standard'` column default, (2) the `CHECK (kind IN (...))` constraint, (3) the moduledoc, and will presumably appear a fourth time in the Ecto schema / changeset. Not a bug — just a note that adding a third `kind` value in the future is a migration plus a schema update plus a search/replace. Acceptable for a two-value enum.

### NITPICK: `source_for_path/1` only detects POSIX absolute paths

**File:** `lib/mix/tasks/compile.phoenix_kit_css_sources.ex:78`

```elixir
defp source_for_path("/" <> _ = abs_path), do: "@source \"#{abs_path}\";"
```

Windows absolute paths (`C:\…`, `\\server\share\…`) would hit the relative branch and get a broken `../../C:\…`. Given PhoenixKit's Linux/macOS focus and that path-deps on Windows use forward slashes when written by mix anyway, this is almost certainly fine — but the function is easy to extend with a `win_abs?/1` guard if Windows support is ever on the table.

---

## Things I liked

- **The debounce architecture is clean.** Client-side toggles own "skeleton visible" immediately; the server owns only the final `current_lang` commit; there is *no* server diff that can fight the client JS. That's the right separation, and the moduledoc spells it out end-to-end.
- **`attach_hook` intercepting the internal `:__multilang_apply_lang__` message** means consumers don't need a `handle_info/2` clause — one of the cleanest ways to encapsulate a library-owned message without leaking it into the consumer's callback surface. `{:halt, socket}` also suppresses the "unhandled message" warning cleanly.
- **Timer ref in `socket.private`, not assigns.** Correct call — assigns would trigger a render+diff cycle and would fight the client toggles. This is exactly the kind of thing the phoenix-thinking skill warns about, and the PR got it right.
- **V102 migration is thorough:** idempotent `IF NOT EXISTS` / `IF NOT EXISTS (SELECT FROM pg_constraint …)` checks on every statement, explicit `down/1` (including dropping CHECK constraints before columns to stay reversible in partial-rollback scenarios), consistent use of `DECIMAL(7, 2) CHECK (… >= 0 AND … <= 100)` for percentage semantics. Matches the pattern in V101.
- **`NOT NULL DEFAULT 0`** on `discount_percentage` is the right default — PG 11+ adds the column in O(1) without a table rewrite, and the DEFAULT guarantees existing rows preserve "no discount" semantics without an explicit backfill.
- **Core form `class`/`wrapper_class` realignment** brings the components into line with the Phoenix 1.7 generator convention, which is what downstream consumers will expect. The new `wrapper_class` escape hatch preserves the old capability without breakage for anyone who was using it (zero in-tree callers, per my grep).
- **Test coverage for the debounce flow** is good — schedule / cancel / reschedule / apply all exercised, and the conditional `if is_reference(ref)` guards for the "languages not configured in test env" case are thoughtful.

---

## Verdict

**Approve with minor doc fix.** No blockers — the MEDIUM finding about `cancel_timer` + stale mailbox message is a real corner case worth addressing but is already hedged by the test. The AGENTS.md "process dictionary" line should be fixed in this PR or the next, since it contradicts the actual code.

## Recommended follow-ups (ordered by priority)

1. Fix the "process dictionary" → "`socket.private`" wording in AGENTS.md.
2. Flush stale `:__multilang_apply_lang__` messages inside `cancel_multilang_timer/1`.
3. Drop the redundant `_item_index` on `phoenix_kit_cat_item_catalogue_rules`.
4. Narrow the `rescue ArgumentError` or add a TODO noting the intended failure mode.
5. Maintainer to add a CHANGELOG.md entry for 1.7.99 before the next hex publish.
