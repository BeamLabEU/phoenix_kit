# Claude Review — PR #1046

**Reviewer:** Claude Opus 5.5, with codex (GPT-6.1) and zai (GLM-5.3)
**PR:** A people picker for every module, notification settings that save as you flip, which line sent a notification, a quoted message under it, avatar letters from the name (mdon)
**Reviewed:** 2026-11-19

The author's own review before opening, for core's part of the boss's fourth Projects list
(tim-dev, 2026-11-18). The `lib/` and admin-JS diff went to codex and zai with numbered
questions; codex re-reviewed the fixes. Every finding was checked against the code first; each
fix has a test where one could pin it.

## Findings

### BUG - MEDIUM — a second tab could switch a preference back on (fixed)
Saving on every change posted the WHOLE form, and the in-app write filled unposted keys from
the page's own copy: tab A turns "Posts" off, tab B (opened earlier) flips "Tasks", and B's
still-checked "Posts" was written back (codex, re-review). A change now saves only its
`_target`, and the in-app write merges only posted keys over what is stored now. Test: "a
second tab showing an older state writes back only the switch it flips".

### BUG - MEDIUM — LiveView form recovery could replay old switches (fixed)
On reconnect the form's old snapshot was replayed as a change (codex). The form is
`phx-auto-recover="ignore"`.

### BUG - LOW — switches under a master that is off were still reachable by keyboard (fixed)
`pointer-events-none` only; Tab + Space flipped them and posted (codex). They, and their hidden
"false", are `disabled` while the master is off: not posted, the stored value stands.

### BUG - LOW — a source could hand back a key it cannot describe (fixed)
`pick/2` / `confirm/2` returning another key added it unchecked (codex). `add_described/2`
describes it first.

### BUG - LOW — a pick refused by `max` still changed Recent and messaged the parent (fixed)
(codex, zai) `add/2` does nothing when the list did not change.

### BUG - LOW — stale ticks and chips after the parent changes the list (fixed)
A parent passing a different list (a refusal, its own change) left listed rows' ticks as they
were, and a chip described as "No longer listed" stayed so (codex, zai). `update/2` re-inserts
the changed keys' listed rows and re-describes chips without a row; a changed viewer resets
Recent and "Add me".

### BUG - LOW — option DOM ids could collide (fixed)
`"opt-#{kind}-#{uuid}"` is the same for `team-a`/`b` and `team`/`a-b` (codex). The id encodes
the key.

### BUG - LOW — two anchors could collide (fixed)
`notif-` + key with `.` → `-` made `comments.replies` and a type `comments-replies` one anchor
(codex). The anchor keeps the dot.

### BUG - LOW — "Add me" for a viewer the source cannot describe did nothing (fixed)
(zai) The button shows only when the viewer's key describes.

### NITPICK — an empty `name` stopped the avatar's fallback (fixed)
`%{name: "", username: "anna.kask"}` showed "?" (codex). Blank values are skipped.

## Checked and not changed

- **A quote's markdown link in the email** (codex, zai): email placeholders are substituted
  AFTER the markdown is rendered, and `{{…}}` values are escaped (`PhoenixKit.Email.Markdown`),
  so `[label](url)` in a quote arrives as text.
- **The parent ignoring a `:changed` message** leaves the optimistic chip (and a surrounding
  form's hidden input): documented — a parent that refuses hands the list back.
- **A form named `<id>-no-form`** on the page would own the search input (codex): needs the
  host to pick that exact id.
- **Paste from the right-click menu** does not search until the next key press (codex):
  `phx-keyup` only; an input outside every form cannot carry `phx-change`.
- **Viewer cleared to nil** keeps the previous one (codex): no caller clears the viewer.
- **The email text part collapses 3+ newlines** (zai): only spacing; paragraphs stay
  paragraphs.
- **Row menus and item 16** (the coordinator): `table_row_menu` was already in the top layer
  (portal + `popover="manual"`), so a card cannot cover it; switching to `popover="auto"` would
  bypass the hook's close bookkeeping. `_open` now closes any other open row menu.

## Verification

- `mix precommit`: exit 0 on the final tree.
- Full suite: see the PR body.

---

## Post-merge review (2026-11-19 PR sweep)

**Reviewer:** Claude Opus 5.5 (an independent read of the merged diff, after the author's review
above). Fixed on `main`, after the merge.

### BUG - HIGH — search results piled up instead of being replaced (fixed)
The options stream was configured with `dom_id: "opt-…"`, while each `<li>` was rendered with
`id={"#{@id}-#{dom_id}"}`. LiveView's client matches stream inserts and resets by `el.id`, so it
never tracked these rows. A `reset: true` (a new search, browse → search) then removed nothing,
and the new rows were added under the old ones. LiveViewTest's DOM does not show this. The stream
is now configured in the first `update/2`, once the component's id is known: its dom_id is
`"<id>-opt-…"`, and the `<li>` renders exactly `id={dom_id}`. The rendered ids are unchanged.

### BUG - MEDIUM — the "Change" and "Connect" links opened the Account tab (fixed)
`Render.settings_link/3` (for people outside the admin area) and `Telegram.connect_path/0`
pointed at `/profile/settings#…`. That URL opens the default tab, Account, where neither anchor
exists. Both now point at `/profile/settings/notifications#…`. `reason_line_test.exs` asserted
the old URL and has been corrected.

### BUG - MEDIUM — a mention chip on a public page showed the person's uuid and face (fixed)
On a `withhold_titles` surface (a project portal, public comments), `Mentions.state_for/4` makes
a person a bare name. The new chip clause ignored that and rendered `data-mention-user={uuid}`
and `<.user_avatar>`, whose Gravatar URL is a hash of the email. `mention_text/1` no longer loads
the mentioned users on such a surface, so the plain-name clause renders. Test: "on a public
surface a person is a name, with no uuid and no face".

### BUG - MEDIUM — the default source showed every account's email to any picker user (fixed)
Anyone who can render a picker reaches `UserSource`. It showed `delivery_email` as each row's
sublabel, searched email by substring (a "does anyone use this domain" oracle), listed
unconfirmed sign-ups, and matched a managed organization on its `.invalid` placeholder. It now
follows `PhoenixKit.Mentions.Users`:
- confirmed accounts only;
- no email on a row (the sublabel is the username, when it adds to the name);
- the address matched only from its start, on `contact_email` for a managed organization;
- organizations sorted by their name.

Tests: `test/phoenix_kit_web/components/people_picker/user_source_test.exs`.

### BUG - LOW (dev/test) — Recent and "Add me" missing for a source not yet loaded (fixed)
The optional callbacks were probed with `function_exported?/3`, which does not load the module.
`update/2` now calls `Code.ensure_loaded/1` on the source.

### NITPICK — channel cells under an off master were reachable by keyboard (fixed)
This is the same gap the author fixed for the in-app switches. `channel_cell` takes `disabled`
for sub-type rows under an off master, so the cell and its hidden "false" are not posted.

### NITPICK — the moduledoc said `viewer_uuid` defaults to the current user's (fixed)
A LiveComponent never sees its parent's assigns. The doc now says to pass it, and the example
does.

### Not changed
- **Chip, remove-button and home-row ids** still join `kind-uuid` with a dash, so a dashed kind
  could collide. Callers' selectors (this repo's tests, `phoenix_kit_projects`) name these ids,
  and core's kinds are dash-free. Left as is.
- **`Recent.put/3`** rebuilds the list from a read taken before the write, so two tabs picking
  at once can lose one pick. The cost is one Recent entry.
- **`forward_leaf_event`'s `:leaf_suggest`** needs a `phoenix_kit_comments` release that handles
  it. Until then the composer's typeahead answers `:pass`.
