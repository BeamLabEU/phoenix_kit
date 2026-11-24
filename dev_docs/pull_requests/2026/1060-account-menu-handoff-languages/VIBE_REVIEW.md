# PR #1060 — Send the account menus' language switch through the cross-domain handoff

**Author:** timujinne · **State:** merged 2026-11-24 (`a1b8b603b`) · **Reviewed:** 2026-11-24

The account menus' language list learned about one-domain-per-language sites: an alternative
language with a host of its own now goes through `/handoff/start` instead of a plain locale
switch, so the sign-in and cart travel to that domain.

**Verdict:** merged, one finding fixed on main (the `leave_for/2` redirect guard below).

## Checked, fine

- **The new `Handoff.hand_over_languages/2` only composes existing, reviewed helpers.**
  `resolve/0`, `own_host/2` (host-name comparison, downcased request host), `host_name/1`,
  `host_for_language/2`, `language_for_host/2` all predate the PR on main; the new function
  reads the site once (`resolve/0`) and asks the resolver once per distinct enabled language
  (pinned by the `:resolver_asked` tests in `handoff_test.exs` and `menu_handoff_test.exs`).
  It returns `%{}` without touching the resolver when `current_host` is not a binary or there
  are fewer than two codes. A page host that is not one of the site's (`own_host` → `nil`, e.g.
  `shop.test.evil.test`) gets no handoff entries — `start` would refuse it anyway. Ports are
  compared by host name, matching `start`'s `same_host?/2`, so two ports of one host name get
  no handoff (pinned by a test).
- **`:dialect` vs `:host_language`.** `destination_kind/3` compares the target host's served
  language (`language_for_host/2`, first enabled code on that host) with the chosen code, so
  `en-GB` on a host that serves `en-US` first keeps its `/en-gb` segment; pinned in both the
  unit tests and the menu tests (`to=%2Fphoenix_kit%2Fen-gb%2Fusers%2Flog-in`).
- **`Routes.locale_switch_path/3` with `locale: :none`.** `path/2` already documented and
  handled `locale: :none`; the PR only widens the spec and fixes `strip_locale_segment/1`,
  which used `String.split(path, "/", parts: 3)` and so never recognized a bare locale root
  carrying a query or fragment (`/de?x=1` split to the single segment `de?x=1`). The new
  `~r{\A/([^/?#]*)(.*)\z}s` ends the segment at `/`, `?` or `#`; `root_of/1` keeps a `/` rest
  and re-adds one otherwise (`/de?x=1` → `/?x=1`, `/de` → `/`, `/jaguar?x=1` untouched). The
  new `describe "locale :none"` block pins all of these, including stripping a disabled
  active locale and a lowercase dialect segment.
- **The menus.** `AccountMenu.languages/2` (default `current_host \ nil`, so the old `languages/1`
  call sites keep compiling) attaches `:handoff` per language; `language_url/3` builds either
  the plain switch or `Handoff.start_path/2` with the target-domain path. Link mode gets
  `rel="nofollow"` only on handoff entries; event mode keeps `phoenix_kit_set_locale` (the
  preference is still saved) with the handoff URL as `phx-value-url`. `AdminNav`,
  `UserDashboardNav`, both layouts, `LayoutWrapper.app_layout` (with the
  `socket_host/1` fallback from `socket.host_uri`) and the direct `app_layout` call sites all
  thread the host; `LayoutHelpers.dashboard_assigns/1` whitelists `:url_host` through to the
  dashboard layout. `Auth.set_routing_info/3` assigns `:url_host` from the handle_params URL on
  every kit-mounted LiveView.
- **Markup that must not change is pinned as byte-identical:** no host, unknown host,
  look-alike host, disabled handoff (one host), and no resolver at all all render exactly the
  old section, in both switch modes.

## Findings

### BUG - MEDIUM — `leave_for/2` redirected on an event param without `Routes.local_path?/1`

`Auth.handle_locale_event("phoenix_kit_set_locale", %{"url" => url}, …)` passes the event's
`phx-value-url` straight through. The PR added
`Phoenix.LiveView.redirect(socket, to: url)` for URLs under `Routes.path("/handoff/start")`,
guarded only by `String.starts_with?/2`. The repo rule (AGENTS.md, login & registration) is
that every LiveView `redirect(to: …)` of user-influenced input goes through
`Routes.local_path?/1`, which rejects `//`, `/\` and every C0/DEL byte; LiveView's own
`validate_local_url!/2` does not catch all control characters (it checks `\`, `/%09`, `/\t`,
`\n`, `\r`, and browsers strip tab/CR/LF from URLs). The fixed `"/…"` prefix makes a
protocol-relative target unreachable, so this was defense-in-depth rather than a live open
redirect — but the rule exists for exactly this shape.

**Fixed on main:** `leave_for/2` now requires `Routes.local_path?(url) and
String.starts_with?(url, Routes.path("/handoff/start"))`. Regression test in
`test/integration/phoenix_kit_web/live/admin_menu_handoff_test.exs`: a forged handoff-prefixed
URL carrying a vertical tab (`<<11>>`, which passes LiveView's check) must not come back as
`{:error, {:redirect, _}}`.

### NITPICK — none blocking

The PR body's own caveat stands: the `:event` path is LiveViewTest-only, not browser-checked.
The guide's new "The account menus" section documents the V236-first deployment order and the
limits (impersonated / organization sessions arrive signed out; the path is carried, not a
translated one).

## Validation

- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`,
  dialyzer via `mix precommit` — clean.
- `mix test` — full suite incl. integration (postgres-test reachable): the new
  `menu_handoff_test.exs`, `admin_menu_handoff_test.exs`, `dashboard_layout_host_test.exs`, the
  `handoff_test.exs` and `locale_switch_path_test.exs` additions, plus the forged-URL test —
  pass; the only failures are the two pre-existing known `FileRepairTest` ones.
