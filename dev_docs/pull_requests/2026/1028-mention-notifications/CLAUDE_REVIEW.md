# PR #1028 — Add mention notifications that say who, in the reader's language, and link to the mention

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; one improvement fixed, one limitation on record

`Mentions.notify/2` stops storing the English sentence "You were mentioned" and instead stores the author's
`actor_name` (full name, else username, never the email local part); `Notifications.Render` words
`mention.created` in the reader's locale ("%{name} mentioned you." / "You were mentioned.", `hero-at-symbol`). A
caller may pass `link:`, kept only when `Routes.local_path?/1` accepts it, stored as `notification_link`. A new
notification type `mentions` (default on) owns the action, so it can be muted and routed to email — routing is
fail-closed, so before this an action no type owned never left the inbox. The channel toggle is restyled
`toggle-primary`.

Checked and fine: the names are read once per batch, after the claim, so a losing concurrent save reads nothing.
`notification_text` in metadata still wins in Render, so rows from before the change keep their stored text. The
`preview` is still only stored for `:yes` visibility; the link is stored for `:unknown` too, which matches the
existing comment ("the link answers for itself"). All three msgids are in `default.pot` and the nine `.po` files
(`en` left empty as everywhere else; "Mentions" already existed). Ran `test/integration/mention_notifications_test.exs`
against a scratch DB: green.

## Findings

### IMPROVEMENT - MEDIUM — `actor_names/1` rescued but did not catch `:exit` (fixed)

AGENTS.md: soft-failure paths need `rescue` **and** `catch :exit` — an unreachable DB raises on an unowned checkout
but exits on a dead pool. The name lookup is the soft part of `notify/2` (no names → "You were mentioned."), but a
pool exit there would escape `notify/2`'s own `rescue` and crash the caller (a comment save) after the mentions
were already claimed, so the pings were lost for good. Added `catch :exit, _ -> %{}`.

### IMPROVEMENT - MEDIUM — the link carries the writer's locale, not the reader's (not fixed, on record)

The text is now in the reader's language, but `link:` is built by the caller with `Routes.path/1` in the writer's
request, so with Languages on a mention written on `/et/...` sends an English reader to the Estonian page. This is
the general `notification_link` contract (Render returns it verbatim, "expected to already be prefix/locale-correct"),
shared by every module emitter, so it is not this PR's to change. A fix belongs in Render for every
`notification_link` — e.g. `Routes.locale_switch_path(link, locale)` when a recipient locale is known — but that
re-adds the URL prefix to any link not built under it (a host path), so it needs its own change with a guard for
that case.
