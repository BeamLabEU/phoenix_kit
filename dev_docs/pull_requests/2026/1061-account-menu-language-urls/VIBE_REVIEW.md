# PR #1061 — Let the account menus take the page's own URL per language

**Author:** timujinne · **State:** merged 2026-11-24 (`8987ebfd2`, main/3.8.0 merged in first) ·
**Reviewed:** 2026-11-24

Follow-up to #1060: the account menus (`user_dropdown/1` signed-in and guest, the admin
dropdown, the standalone `LanguageSwitcher`) take an optional `language_urls` — the page's own
URL per language (publishing's `phoenix_kit_publishing_translations` list or a plain
`%{code => url}` map) — so a page whose address differs per language (translated slug) leads to
the right page instead of the current path rewritten.

**Verdict:** merged. No new findings; the branch also carries the #1060 follow-up fixes
(segment-exact `leave_for/2`, prefix-segment split) reviewed below.

## Checked, fine

- **Off-site links are impossible through the attr.** `AccountMenu.page_path/4` reduces every
  given URL through `reduce_url/2`: local paths pass as `:relative`; absolute `http(s)` URLs only
  when their host name (port-stripped, downcased via `Handoff.host_name/1`) equals the entry's
  target host (the page's `current_host`, or the language's own host for a handoff entry);
  protocol-relative (`//host` parses with `host` set and `scheme: nil` → no clause matches),
  `javascript:`, and other-host URLs all answer `nil`. The fragment is dropped, and the result
  is re-checked with `Handoff.valid_to/1` (which runs `Routes.local_path?/1`) no matter what was
  done to it. `same_host?/2` has a catch-all `false`.
- **Destination shaping.** On the page's own domain a `:page_path` is used as-is; through the
  handoff an absolute URL of the target domain is already its address, a relative one keeps
  whole for `:dialect` and loses only the language's own leading locale segment for
  `:host_language` (`Routes.domain_page_path/2`). `language_url/3` falls back to the computed
  switch path whenever there is no `:page_path`.
- **`LanguageSwitcher.translation_url/3`** is the one lookup (exact code, then bare base, then
  any dialect of the base; `:base` mode preserves the standalone switcher's historical
  list-order semantics). Blank codes match nothing; an unknown `match` value has no clause and
  fails loudly. Both list (`%{code:, url:}` atom/string keys) and map shapes are accepted;
  structs are excluded from the map clause.
- **`leave_for/2` is now segment-exact**: `url == start` or `start <> "?"` / `start <> "/"`,
  on top of the 3.8.0 `Routes.local_path?/1` guard — `/handoff/startx` no longer takes the full
  redirect branch. Regression tests cover it (`admin_menu_handoff_test.exs`).
- **`Routes.split_page_prefix/1`** splits the mount prefix on segment boundaries
  (`/phoenix_kit?x=1` is the prefix with a query, `/phoenix_kitn` is not), fixing the
  `locale_switch_path/3` crash on a path that merely starts with the prefix; `locale_switch_path/3`
  now uses it, and `locale_prefixed_path/3` emits `/{locale}?query` correctly for a root with a
  query/fragment. `Routes.domain_page_path/2` strips only the leading own-locale segment
  (`/de/de/x` → `/de/x`, `/blog/de/...` untouched, host paths outside the prefix untouched).
- **`hand_over_languages/2`** now also returns each language's `host` (`%{code => %{kind:, host:}}`),
  which the menu needs to accept absolute URLs of that domain; it reads `host_languages/0` once
  and still asks nothing without a binary host or with fewer than two codes. The 3.8.0 call
  sites and tests were updated for the new value shape.
- **`layouts/admin.html.heex`** dropped its explicit `current_host` — the socket-derived
  `socket_host/1` in `app_layout` covers plugin pages now; the guard test
  (`app_layout_host_guard_test.exs`) pins every `app_layout` call site's host source.

## Validation

- `mix compile --warnings-as-errors` clean; the nine test files the PR touches/added:
  322 tests, 0 failures.
- `mix precommit` (compile warnings-as-errors, deps.unlock --check-unused, format-check,
  credo --strict, dialyzer, test.compile, JS tests) — exit 0.
- Full `mix test` in this environment shows the same pre-existing environmental failures as
  pristine main (CaptureLog leaks under concurrency, ~1.8k; identical count with and without
  this PR — verified by stashing), plus the author's known 2 `FileRepairTest` ones are
  included in that baseline. Not caused by this PR.
