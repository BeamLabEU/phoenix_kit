# Claude Review — PR #443: AI System Prompt & Playground

**Verdict:** Approve with minor observations

## What's Good

1. **Clean system_prompt integration.** The field slots naturally into the existing Prompt schema. Variable extraction from both fields is handled by combining strings before regex, which keeps the logic simple and avoids duplicate extraction paths.

2. **`render_system_prompt/2` follows existing patterns.** Pattern-matched on `nil` and `""` returning `{:ok, nil}`, consistent with how `render/2` works. The `with` chain in `ask_with_prompt` integrates cleanly.

3. **Playground LiveView is well-structured.** Separation of concerns is clear: `apply_form_changes` delegates to focused `maybe_update_*` helpers, request execution is split into `execute_prompt_request` and `execute_freeform_request`, and the async `handle_info(:do_send, ...)` pattern avoids blocking the LiveView process.

4. **Migration is idempotent.** V85 checks both table and column existence with `information_schema` queries before altering — safe for re-runs and partial migrations.

5. **Good test coverage.** 44 unit tests covering the Prompt module's public API comprehensively, including edge cases (nil, empty strings, atom vs string keys, deduplication).

## Issues Found

### Minor: Missing `tab-active` class on Playground tab in endpoints page

In `endpoints.html.heex`, the Playground tab link (lines 145-150 of the diff) lacks the conditional `tab-active` class that other tabs use:

```heex
# Current (missing active state):
<.link navigate={...} class="tab">

# Expected pattern (matching other tabs):
<.link navigate={...} class={"tab #{if @active_tab == "playground", do: "tab-active"}"}>
```

The same issue exists in `prompts.html.heex` — the Playground tab there also has no active state conditional. Only `playground.html.heex` itself correctly shows the active state (hardcoded as `tab tab-active`).

**Impact:** The Playground tab won't highlight in the navigation when navigating from Endpoints or Prompts pages. Cosmetic only.

### Minor: Playground doesn't extract variables from system_prompt when switching prompts

In `maybe_update_prompt/2` (playground.ex), when a prompt is selected, variables are extracted only from `edited_content`:

```elixir
variables = if prompt, do: Prompt.extract_variables(edited_content || ""), else: []
```

If the prompt's `system_prompt` also contains variables, they won't appear as input fields until the user edits the content template. Should combine both fields:

```elixir
variables = if prompt do
  system_vars = Prompt.extract_variables(prompt.system_prompt || "")
  content_vars = Prompt.extract_variables(edited_content || "")
  Enum.uniq(system_vars ++ content_vars)
else
  []
end
```

**Impact:** Variables defined only in the system prompt won't have input fields in the Playground. They'll be sent as-is with `{{VarName}}` unreplaced.

### Observation: `phx-update="ignore"` on content textarea

The edited content textarea uses `phx-update="ignore"` to preserve user edits across re-renders. This is correct for the use case, but means the textarea won't update if the user selects a different prompt — the `maybe_update_prompt` code sets `edited_content` in assigns but the DOM won't reflect it because of the ignore directive.

This is mitigated by the wrapping div having a dynamic ID (`edited-content-wrap-#{@selected_prompt.uuid}`), which forces a new DOM element when the prompt changes. Clever solution.

### Observation: Blocking AI call in handle_info

The `handle_info(:do_send, ...)` handler calls `execute_request/1` synchronously. While this is better than doing it in `handle_event` (the UI updates with the loading state first), a very slow AI response will still block other messages to this LiveView process.

For an admin-only tool this is acceptable. If it becomes an issue, wrapping in `Task.Supervisor.async_nolink` would be the standard improvement.

## Testing Notes

- Tests are all unit-level (no DB required) — they test `Prompt` struct functions directly
- No integration tests for the Playground LiveView itself, which is reasonable for an initial PR
