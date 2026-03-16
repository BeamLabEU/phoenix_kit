# Claude's Review of PR #415 — Integrate Leaf editor into PhoenixKit

**Verdict: Approve with follow-up items**

The integration is functional and the Elixir-side changes are clean. The inline JS bundling was the right rapid-integration approach and was immediately corrected in PR #416. A few issues remain.

---

## Issues

### 1. XSS in media insertion (visual mode) — Moderate

**File:** `lib/modules/posts/web/edit.html.heex:480`

```javascript
const html = '<img src="' + fileUrl + '" alt="' + altText + '" />';
document.execCommand('insertHTML', false, html);
```

`fileUrl` is interpolated directly into an HTML string without escaping. If the file URL contains `"` or other HTML-special characters, it breaks the tag and could enable XSS via `insertHTML`. Should use DOM APIs (`createElement` + `setAttribute`) or escape the URL.

**Note:** This is the same class of issue flagged in PR #412 review (#5) for the Publishing editor's `publishingEditorInsertMedia`. Both should be fixed together.

### 2. `document.execCommand` is deprecated — Minor

`execCommand('insertHTML')` is deprecated in modern browsers. It still works but is no longer in the HTML spec. The Leaf editor itself may have a proper insertion API that should be used instead.

### 3. Missing `@impl true` on Leaf message handlers — Minor

**File:** `lib/modules/posts/web/edit.ex:326-335`

The three `handle_info` clauses for Leaf messages (`leaf_changed`, `leaf_insert_request`, `leaf_mode_changed`) are missing `@impl true` annotations, unlike the other `handle_info` clauses above them.

### 4. Recursive `handle_info` call — Minor

**File:** `lib/modules/posts/web/edit.ex:330`

```elixir
def handle_info({:leaf_insert_request, %{type: type}}, socket) do
  handle_info({:editor_insert_component, %{type: type}}, socket)
end
```

Calling `handle_info` recursively works but bypasses LiveView's message dispatch. Cleaner to extract the shared logic into a private function both clauses call, or use `send(self(), ...)` if the full dispatch is needed.

---

## What's Good

- **`live_content` assign pattern** — Separating live editor state from the initial `content` assign is correct. The `socket.assigns[:live_content] || socket.assigns.content` fallback on save handles the "no edits yet" case cleanly.
- **Broadened editor_id match** — `"post-content-editor" <> _` handles both MarkdownEditor and Leaf editor IDs without breaking existing code.
- **Catch-all handlers** — `leaf_mode_changed` is properly handled as a no-op to prevent "no matching clause" crashes.

---

## Follow-up

- [ ] Fix XSS in `postsEditorInsertMedia` visual mode — use DOM APIs instead of string concatenation
- [ ] Add `@impl true` to the three Leaf `handle_info` clauses
- [ ] Consider replacing recursive `handle_info` with extracted private function
