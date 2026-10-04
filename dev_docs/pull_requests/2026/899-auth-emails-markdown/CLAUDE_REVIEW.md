# PR #899: Markdown core emails with buttons, a welcome email, the notification email in the layout

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commits**: `6778089d4` … `9cee898d4` (merge `2726ab358`)
**Date**: 2026-10-04

## Goal

Core's own emails (confirm, reset, change-email, magic link, invitations, login alerts)
become Markdown with a real button; a welcome email is sent once after a user confirms
their own address (off by default); the notification email goes through
`Content.resolve/5`, so it gets the layout, branding, overrides and a preview entry.

## What was changed

| Area | Change |
|---|---|
| `email/markdown.ex` | Blank-placeholder paragraphs dropped, `{{{raw}}}`-only paragraph unwrapped, `[{{url}}]({{url}})` reads `url` in text, blank-line collapse |
| `email/core_templates.ex` | Every default is `markdown`; new `welcome` and `notification` entries; `welcome_variables/1` |
| `email/content.ex` | HTML order: every host part now outranks every default (host `text` beats default `html`/`markdown`) |
| `users/welcome_email.ex`, `welcome_email_worker.ex` | Transition tracking in the confirming transaction, savepoint + `lock_timeout` insert, claim-then-send worker with an at-most-once mark |
| `users/auth.ex`, `magic_link_registration.ex` | `track_transition` / `multi` wired into the four confirmation paths |
| `notifications/channels/email.ex` | Built from `Content.resolve("notification", …)`, HTML body added |
| `live/settings/email_sending*` | Welcome-email toggle; `email_preview*` order notes |

## Verification

- **Markdown → HTML injection.** Read `Markdown` end to end. Every placeholder becomes an
  opaque nonce token before parsing, values are substituted *after* rendering and
  sanitizing (`escape: true`), link/image addresses are filled and checked on their own
  (`http(s)`/`mailto:` only, images `http(s)`), then escaped as attribute values and put
  in by a nonce-keyed pass. MDEx runs with `unsafe: false` and raw HTML is dropped. A
  user-controlled value (`browser_os`, `location`, a site name, a notification text)
  cannot reach the markup, a `javascript:`/`data:` link is dropped to its label, and a
  value cannot forge a token (48-bit random nonce, absent from the source). No finding.
- **`{{{raw}}}`** is reachable only from template text (core's copy has none; a host file
  or a translator's `.po` is trusted input), and `unwrap_raw_paragraphs` only strips the
  `<p>` around it.
- **Welcome — at most once.** One job per real transition (`track_transition` locks the
  row `FOR NO KEY UPDATE`, so the loser of two racing confirmations re-reads a confirmed
  row under READ COMMITTED); the worker's single conditional `UPDATE … WHERE (custom_fields
  -> key) IS NULL AND confirmed_at IS NOT NULL` is the claim; the mark is released only
  when building failed or the mailer returned `{:error, _}`; a raise/exit *during*
  delivery cancels instead of retrying. Job args are string-keyed. Checked `claim/1`
  and `release/1` against a `NULL` `custom_fields` (`NULL -> key` is NULL, `COALESCE`
  covers the write, `NULL - key` is NULL) — both fine.
- **Never in the way.** `insert/1` rescues *and* catches; inside a transaction the insert
  has its own savepoint, `SET LOCAL lock_timeout`, and the caller's value is put back
  with `set_config(…, true)` before `RELEASE`; on failure `ROLLBACK TO SAVEPOINT` undoes
  the `SET LOCAL` too. The queue (`notifications`) is declared in `ObanQueues`' core set.
- **Admin confirmations stay silent** (`admin_confirm_user/1`, `toggle_user_confirmation/2`);
  magic-link registration calls `after_confirmation/1` itself after the commit.
- **Notification channel.** Digest and immediate deliveries both reach `deliver/2` with an
  absolute `url` (`absolutize/1`, `digest_envelope/4`), so a `[…]({{url}})` override
  survives the http(s) rule. `subject`/`text` are never HTML-escaped (`Substitution`
  escapes only the `html` part), and the default is a `text` part, so
  `Layout.text_to_html/1` escapes the notification text. The kill switch and the digest
  cadence decide *whether* to deliver and are untouched.
- **`layout: false` / order.** The new `@html_order` and `@text_order` match the preview
  notes word for word; the `{:file, :text}` row builds no HTML when the layout is off, so
  `first_body/4` falls through to the default, as documented.
- **.po files.** 0 fuzzy entries in every catalog. Scripted placeholder parity
  (`{{…}}` and `%{…}`) over every `default.po`: the welcome message differs only in `et`
  (intro sentence no longer names the site) and `ru` (button reads «Перейти на сайт»);
  both are idiomatic rewrites, every variable the button and link need is intact.

## Findings

- **BUG - MEDIUM** — `lib/phoenix_kit/email/core_templates.ex:183`. The welcome email's
  button links to `Routes.base_url()` (the host's `/`). `AGENTS.md` ("Post-auth
  destination") says `"/"` belongs to the host and 404s on every install that never
  declared a root route — that is why `Routes.post_auth_path/2` ends in `/admin`. The
  welcome email is a *post-confirmation* call to action, and on such a site its one
  button is a 404 page. The footer link is the same URL but is not the call to action.
  **Fix:** add a variable for the landing (`start_url`/`account_url` =
  `Routes.base_url() <> Routes.post_auth_path()`, which honours `after_login_path`), point
  the default button at it, keep `site_url` for the footer-style link; update the guide's
  variable table and `welcome_variables/1`'s doc.

- **IMPROVEMENT - MEDIUM** — `guides/email-templates.md` / `CHANGELOG.md`. The change of
  `@html_order` is a behaviour change for any host that overrides only `text.txt` of an
  email whose caller ships an `html` default (a module email): its HTML used to be the
  module's `html`, now it is the host's text as plain paragraphs. It is documented in
  `Content`'s moduledoc, but it has to be in the CHANGELOG under **Changed** — the PR did not
  touch it.

- **NITPICK** — `lib/phoenix_kit/users/welcome_email.ex:111` and
  `magic_link_registration.ex:215`. `after_confirmation/1` is unguarded: `enabled?/0`
  rescues but does not `catch :exit`, and the magic-link call runs *after* the account is
  created and confirmed, outside any transaction, so a dead pool (an exit, not a raise)
  at that instant fails the registration response. `AGENTS.md` ("Soft-failure paths need
  `rescue` AND `catch :exit`"). **Fix:** wrap the body of `after_confirmation/1` in the same
  `rescue`/`catch` as `insert/1` and return `:error`.

- **NITPICK** — `welcome_email.ex:160-176`. The job goes in through `Oban.insert/1` (the
  default instance), while the savepoint, `SET LOCAL` and the "in the confirming
  transaction" promise are about `Repo.repo()`. If a host's Oban runs on another repo,
  the job is committed at once on its own connection, and a run that beats the
  confirmation's commit finds the row unconfirmed → `:not_claimed` → `:ok`: the welcome
  email is silently lost. One shared repo (the supported setup) is unaffected; say so in
  the moduledoc, or compare `Oban.config(Oban).repo` with `Repo.repo()` and enqueue only
  when equal.

- **NITPICK** — the plain-text body of every button email now carries the address twice
  (`Confirm account: <url>`, then `open this link: <url>`). The HTML needs both, the text
  part does not. `Markdown.to_text/2` could skip a paragraph whose only link repeats the
  previous paragraph's address, or the defaults could keep the fallback line out of the text.

- **NITPICK** — `lib/phoenix_kit_web/live/settings/email_preview.ex:66`. The comment still
  says "Core's eight entries"; the catalog has ten since this PR.

## Verdict

Approve as merged. The Markdown pipeline is sound against injection, and the welcome email's
once-only, after-commit and never-in-the-way claims all hold against the code. Fix the
welcome button's destination (the one user-visible defect), add the CHANGELOG line for the
HTML-order change, and take the small guards at leisure.

## Resolution (2.52.0)

- **BUG - MEDIUM (welcome button to `/`)** — not changed. The button deliberately leads where the footer does
  (`site_url`), a host's homepage being the natural landing after confirming; switching the default to a new
  `start_url` rewrites the welcome email's msgid and so its translations in all eight locales, and a host that
  overrides the template keeps working either way. Left for the maintainer: if a host without a `/` route turns up,
  add `start_url` (`Routes.base_url() <> Routes.post_auth_path()`) and move the default button to it.
- **IMPROVEMENT - MEDIUM (HTML body order)** — fixed: CHANGELOG 2.52.0 Changed documents the new order.
- **NITPICK (`after_confirmation/1` exit)** — fixed: now rescues and catches `:exit`, returning `:error`.
  `magic_link_registration.ex` calls it, so its response is covered too.
- Single-repo Oban assumption of the welcome enqueue, duplicated URL in the text body — left as noted.
- `email_preview.ex` "eight entries" comment — fixed.
