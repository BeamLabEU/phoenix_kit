Three fixes to the hooks that portal a menu to `<body>`, found while the projects module's "Add task" popup (a `<dialog>` shown with `showModal()`) was in daily use. Each has a JS unit test over the hook's real `mounted()`/`render()`/`position()` (`test/js/`, `mix test.js`).

## What changed

**The mention menu shows over a modal dialog, under the trigger character** (`MentionInput`). A `showModal()` dialog sits in the browser's top layer and paints over everything outside it whatever its z-index, and makes everything outside it inert — so the `@`/`#` menu appended to `<body>` was there, open, and invisible behind the popup, and a popover on `<body>` was painted above but took no click (measured in Chrome). The menu now lives INSIDE the open dialog as a manual popover (top layer, not inert), put back by a `MutationObserver` when a LiveView patch of the dialog discards it; on a plain page it stays on `<body>` as before. It opens under the `@`/`#` itself (a mirror measures the character's box) rather than under the whole field, and flips above the field when there is no room below.

**The row menu portals into an open dialog, as a popover** (`RowMenu`): the ⋮ menu's content had the same trap inside a popup. `_portal()` picks the nearest open dialog, else `<body>`.

**A mention search carries the field's context**: the hook sends the field's `data-mention-context` (JSON, e.g. `{"project": uuid}`) with every `pk_mention_search`; `Mentions.Live` passes it to `Mentions.search/3` as `:context`, and the `Mentions` docs say handlers MAY narrow by it (a `#` typed inside a project offers that project's own records) and MUST still scope to the searcher. No attribute, or broken JSON, is a null context and the search as before. The projects and CRM modules use it (their PRs).

## Verification

`mix precommit` clean; `mix test.js` 279 tests, 0 failures. No version bump, no CHANGELOG entry.
