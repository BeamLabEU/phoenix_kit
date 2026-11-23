# PR #1054 — Add the in_menu tab key to nav_tabs: a tab kept behind "⋯" on every width

**Author:** timujinne · **State:** merged 2026-11-23 (`e3acfecc5`) · **Reviewed:** 2026-11-23

Reviewed before the merge, from the PR diff. These passed at the PR head:

- `nav_tabs_test.exs`: 54 tests
- `nav_tabs_overflow.test.cjs`: 34 tests
- `admin_split.test.cjs`
- the format check

**Verdict:** merged as is. The nitpicks are optional doc and accessibility polish, left open.

## Checked, fine

- **No new hook.** `NavTabsOverflow` stays admin, and `ADMIN_HOOKS`, the admin file's keys
  and `admin_split.test.cjs` still agree. No new gettext strings, no forms, no hardcoded kit
  paths.
- **Layout.** `navTabsLayout/6` uses the same threshold and the same room beside "⋯" as the
  old `navTabsHidden`. It maps the active index correctly past forced tabs. All-forced, zero
  width and negative room are safe.
- **Server and hook agree.** The server's `in_menu?/2` and the hook's `forced` set both leave
  out the active tab, and the class order matches what `classList.toggle` produces. No core
  caller uses `overflow={:menu}` yet, so the menu items now rendered `hidden` by the server
  reach no existing page.
- **Focus.** The focus move runs in `updated()`. That runs before the browser blurs a button
  hidden by `display:none`, so `focusOnMore` reads the right element.

## Findings

1. **NITPICK — the focus promise covers only `patch` and event tabs.** The doc says focus
   moves to the active tab whenever "⋯" hides while focused. A `navigate:` tab picked from the
   menu loads a new LiveView, so focus lands on `<body>`. Say so in the doc.
2. **NITPICK — "⋯" is focusable before the admin bundle arrives.** In an `in_menu` strip the
   server renders the button visible, and it does nothing until the hook mounts (forever,
   without JavaScript). The moduledoc documents this and warns that a page's only route must
   not be an `in_menu` tab. Optional: render `aria-disabled="true"` and let the hook clear it.
3. **NITPICK — no browser check yet.** Before the release, try two things in Chromium: pick
   the last `in_menu` event tab from the menu, then resize until every tab fits while "⋯" has
   focus.

## Fixed on main in the follow-up pass

- **Nitpick 1.** The moduledoc now says the focus move covers `patch` and event tabs; a
  `navigate:` tab picked from the menu loads a new LiveView, so focus lands on `<body>`.
- **Nitpick 2.** The server renders the "⋯" button `aria-disabled="true"`; the
  `NavTabsOverflow` hook clears the attribute on every `sync()` (a patch re-adds it, the next
  sync clears it again). Tests: `nav_tabs_test.exs` (attribute present) and
  `nav_tabs_overflow.test.cjs` (cleared on sync).
