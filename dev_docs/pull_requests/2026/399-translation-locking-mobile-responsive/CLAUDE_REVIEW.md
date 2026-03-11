# PR #399 Review — Translation Locking, Active Editor Warnings, Mobile Responsive

**Author:** Max Don (`mdon`)
**Merged:** 2026-03-10
**Files changed:** 5 (260 additions, 73 deletions)

## Summary

Three features in one PR:
1. **Translation locking** — locks the editor (source + target languages) while AI translation is in progress, preventing edits that would conflict with the translation worker.
2. **Active editor warnings** — before starting translation, warns if other users are actively editing target or source languages.
3. **Mobile responsive improvements** — compact stats row on mobile, hidden low-value metadata on small screens, full-width action buttons.

## What's Good

- **Translation lock concept is solid.** Locking both source and target language editors during translation prevents data loss from concurrent edits. The lock/unlock lifecycle is clean: set on `:translation_started` broadcast, cleared on `:translation_completed`.
- **Active editor detection** is a nice UX touch — checking Presence for lock owners before confirming translation, with clear warning messages showing who's editing which language.
- **`edit_disabled?` template variable** reduces repetition in the template nicely — single source of truth for the combined readonly/locked state.
- **Mobile responsive** changes are well-scoped. The dual stat grid approach (desktop 5-col with "Publishing Groups", mobile 4-col without) is pragmatic.
- **`admin_page_header.ex`** — `[&>*]:w-full [&>*]:sm:w-auto` is a clean pattern for responsive action buttons.

## Issues Found

### 1. Bug: `readonly?` save handler bypasses translation lock (Medium)

**File:** `editor.ex:656-669`

The save handlers are ordered:
```elixir
def handle_event("save", _, socket) when socket.assigns.readonly? == true do
  socket = maybe_reclaim_lock(socket)
  if socket.assigns[:readonly?] do
    {:noreply, put_flash(socket, :error, ...)}
  else
    Persistence.perform_save(socket)  # ← bypasses translation_locked? check!
  end
end

def handle_event("save", _, socket)
    when socket.assigns.translation_locked? == true do
  {:noreply, put_flash(socket, :error, ...)}
end
```

If a user is `readonly?` (spectating) AND translation is locked, then `maybe_reclaim_lock` succeeds (they get the lock back), the code falls into the `else` branch and calls `Persistence.perform_save` — completely bypassing the `translation_locked?` guard. The fix is simple — add the translation lock check in the reclaim path:

```elixir
def handle_event("save", _params, socket) when socket.assigns.readonly? == true do
  socket = maybe_reclaim_lock(socket)

  cond do
    socket.assigns[:readonly?] ->
      {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
    socket.assigns[:translation_locked?] ->
      {:noreply, put_flash(socket, :error, gettext("Cannot save while translation is in progress"))}
    true ->
      Persistence.perform_save(socket)
  end
end
```

### 2. Inconsistent assign access style (Low)

Mixed usage of `socket.assigns[:translation_locked?]` (bracket, nil-safe) and `socket.assigns.translation_locked?` (dot, raises on missing):

| Location | Style |
|---|---|
| `update_meta` guard | `socket.assigns[:translation_locked?]` (bracket) |
| `update_content` guard | `socket.assigns[:translation_locked?]` (bracket) |
| `save` guard clause | `socket.assigns.translation_locked?` (dot) |
| `autosave` handler | `socket.assigns[:translation_locked?]` (bracket) |

Since `translation_locked?` is assigned in `mount`, dot access is safe everywhere. But the inconsistency suggests some defensiveness — pick one style. Guard clauses require dot access, so bracket access in the `if` bodies is just inconsistent, not a bug.

### 3. Duplicated source language logic (Low)

`source_language_for_translation/1` in `editor.ex` and inline logic in `translation.ex:check_source_language_editor/2` both compute:
```elixir
post[:primary_language] || Publishing.get_primary_language()
```

Consider extracting to a single shared helper (e.g., in `Translation` module) to avoid drift.

### 4. Unnecessary wrapper div (Nitpick)

```heex
<div class="flex items-center gap-2">
  <.link ...>Manage Endpoints</.link>
</div>
```

The wrapping `div` with `gap-2` has only one child. If it's prep for a future second link, that's fine — but currently it's dead structure.

### 5. Duplicated mobile/desktop stat cards (Nitpick)

The index template now has two separate stat grids — one `hidden sm:grid` (desktop) and one `sm:hidden` (mobile). This duplicates the data bindings. A component or shared partial could reduce this, but it's a reasonable trade-off for readability at this scale.

## Improvement Suggestions

1. **Fix the readonly/translation-lock save bypass** (issue #1 above) — this is a real bug that allows saving during translation if the user was previously spectating.
2. **Consider a `locked_reason` assign** instead of separate `readonly?` + `translation_locked?` booleans. As more lock reasons appear, a single `{:locked, :translation}` / `{:locked, :spectating}` / `nil` pattern would be cleaner and prevent ordering bugs in guard clauses.
3. **Push a JS event when locking** — currently the TipTap editor's `readonly` attribute is set via template re-render, but if the editor component caches its initial state, it might not react to a server-side assign change mid-session. Verify the rich text editor properly disables on re-render.
4. **Test the edge case:** user opens editor → starts translating → translation completes → user should be able to edit again without page refresh. The `assign(:translation_locked?, false)` on completion should handle this, but worth a manual check.

## Verdict

Good feature PR. The translation locking fills a real gap in the concurrent editing story. The mobile responsive work is solid. The main actionable item is **fixing the save bypass when reclaiming a lock during active translation** (issue #1).
