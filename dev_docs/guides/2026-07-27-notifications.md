# Notifications

Moved from `AGENTS.md` 2026-07-27 — a short operational summary stayed
there; this is the full reference.

Per-user inbox, driven by activity log. When `Activity.log/1` records an entry with `target_uuid != actor_uuid`, a row goes into `phoenix_kit_notifications` for the target user. Admins use `/admin/activity` for audit — they do NOT receive notifications.

Kill switch: `notifications_enabled` setting (default `"true"`).

**Generation:** automatic — never insert directly into `phoenix_kit_notifications`; create the activity and let the hook in `lib/phoenix_kit/activity/activity.ex` fan out via `PhoenixKit.Notifications.maybe_create_from_activity/1`. Each row is `(activity_uuid, recipient_uuid)` with independent `seen_at`/`dismissed_at`.

**Rendering:** `PhoenixKit.Notifications.Render.render(notification)` → `%{icon, text, link, actor_uuid}`. Unknown actions fall back to the raw action string.

**Public API** (`PhoenixKit.Notifications`):
- `list_for_user(user_uuid, opts)` — `:page`, `:per_page`, `:status (:unread|:all)`, `:include_dismissed`
- `recent_for_user(user_uuid, limit \\ 10)`, `count_unread(user_uuid)`
- `mark_seen` / `mark_all_seen` / `dismiss` / `dismiss_all` (all `(user_uuid, ...)`)
- `get_notification(user_uuid, uuid)` — recipient-scoped
- `enabled?/0`, `retention_days/0`, `prune/1`

**PubSub topic:** `PhoenixKit.Notifications.Events.topic_for_user(user_uuid)` (`"phoenix_kit:notifications:<uuid>"`). Events: `{:notification_created, n}`, `{:notification_seen, n}`, `{:notification_dismissed, n}`, `{:notifications_bulk_updated, :seen | :dismissed}`.

**UI** — no PhoenixKit-owned notifications page. Embeddable bell `PhoenixKitWeb.Live.NotificationsBell` (sticky nested LV, owns its PubSub sub):

```heex
<%= Phoenix.Component.live_render(@socket, PhoenixKitWeb.Live.NotificationsBell,
      id: "pk-notifications-bell", sticky: true,
      session: %{"user_uuid" => @current_user.uuid}) %>
```

"Seen" only on explicit user action — opening the dropdown does NOT auto-mark seen.

**Per-user preferences:** users mute notification *types* (not actions) via `UserSettings`. Persisted in `users.custom_fields["notification_preferences"]` (V18 JSONB column). Types live in `PhoenixKit.Notifications.Types`. Core types: `"account"`, `"posts"`, `"comments"`. External modules contribute via optional `notification_types/0` on `PhoenixKit.Module`:

```elixir
@impl PhoenixKit.Module
def notification_types do
  [%{key: "reviews", label: "Reviews", description: "...",
     actions: ["review.submitted", "review.edited"], default: true}]
end
```

`Types.list/0` merges core + modules; toggle appears automatically.

A type (and each sub-type) may also carry `example:` — one concrete case it
covers, shown under its description on My Settings ("For example: “Fit the
doors” is marked “Can be started”."), so a reader can tell which line sent a
notification. Register it with `gettext_noop/1` like the label.

**Which line sent it** (2026-11-19): every notification names its line and
links to it — `Render.reason(notification, recipient, locale)` →
`%{key, label, text, link}` ("You get this because “Projects › Comments” is
on."), nil when no type owns the action. The link goes to the line's row on
My Settings (`/admin/notifications/settings#notif-<key>`) for
someone who reaches the admin area, else to the profile settings'
Notifications section. The inbox shows it under each entry; email carries it
as `{{reason}} {{settings_url}}`, Telegram as a last line. `Notifications.Prefs.user_wants?/2` is **fail-open** — unknown actions, missing prefs, or lookup errors return `true`.

**Notification wording.** Settings → Notification messages edits email subjects,
Markdown bodies and Telegram text for each type and language. A role needs
`settings.messages`. The historical settings backfill grants only
`settings.security`. Delivery tries the recipient’s dialect and its base
language for each type in turn, then the host template and core default.
Readers without a locale preference use the site content language. The editor
previews with sample values, and delivery preserves the record and settings
links when custom wording omits them.

**Custom display:** `Render.render/1` honors three metadata keys before falling back:

```elixir
metadata: %{
  "notification_text" => "Alice left you a 5-star review.",
  "notification_icon" => "hero-star",
  "notification_link" => "/reviews/#{review.uuid}"
}
```

Any key can be absent — Render falls back to the action lookup for the missing parts.

**A quote under the line** (2026-11-19): a notification can carry the
message that came with it — the comment typed when a task was marked done,
a reopen reason, the comment someone was mentioned in — shown as its own
block (the writer's face and name, then the text) rather than squeezed into
the one line:

```elixir
metadata: %{
  "quote" => %{
    "text" => "Measured again, wall A is 3240.",  # required, markdown (Leaf's)
    "author_uuid" => writer.uuid,                 # optional: face + current name
    "author_name" => "Anna Kask"                  # optional: shown when no account
  }
}
```

`Render.quote/1` reads it (from the activity's metadata, or a standalone
notification's): mention tokens become their labels, the text is cut at
2,000 characters for display. The inbox renders it as sanitized markdown
(`<.markdown compact>`); email carries it as `{{quote}}` and Telegram as a
paragraph, both plain text with the writer's name ("Anna Kask: “…”").
Store the WHOLE message in the activity: the notification is its only copy
for a reader who cannot open the record it came from.

**Mentions** (`PhoenixKit.Mentions.notify/2`, action `mention.created`) are a core type of their own, `"mentions"`, so a person can mute them or route them to email like anything else (routing is fail-closed: an action no type owns never leaves the inbox). The activity stores `actor_name` (full name, else username — never the email's local part) and Render words it in the reader's language: "Ada mentioned you." (`hero-at-symbol`). A caller passes `link:` — a local path built with `Routes.path/1`, pointing at the mention itself (comments: the record's page + `#pk-comment-<uuid>`); anything failing `Routes.local_path?/1` is dropped. Rows from before the name was stored keep their own `notification_text`.

Since 2026-11-25:

- **Off means off.** With the mentions switch off (`Mentions.enabled?/0`), `notify/2` sends nothing; `sync/4` still indexes, so backlinks keep working.
- **Asked again at delivery.** The type carries `visible: {PhoenixKit.Mentions, :still_visible?}`: email omits the quote and push skips delivery when the recipient loses access. A stored quote also requires a working visibility handler at delivery time.
- **The reader's language.** A stored `notification_link` that names a language the site serves is re-spelled in the reader's at render (`Render`), since a mention's link is built in the author's request.
- **Forgetting a deleted record's words.** `PhoenixKit.Mentions.forget_source(source_type, source_uuid)` removes `"quote"` and `"preview"` from every `mention.created` activity for a mention IN that record (the activity carries `mention_source_type` / `mention_source_uuid`) or ABOUT it (the activity's resource). The ping and its link stay. A module calls it when it deletes the record (the comments module, on a comment's deletion; feature-detect it with `function_exported?/3`). Activities written before 2026-11-25 carry no mention source and are found only by their resource.
- **Kept rows.** A re-save keeps the row of a mention still in the text, so a claim racing it still lands; a failed activity write gives the claim back so a later save can try again.

## Delivery channels (external destinations)

Pluggable per-user routing of notifications to **external** destinations
(Telegram, Email, Browser push; more via modules) on top of the in-app inbox. **Model B —
parallel routing layer**: the inbox path above is untouched; external channels
are computed + enqueued independently, so "Telegram on, inbox off" works with
**no migration** (config rides `users.custom_fields`).

- **`PhoenixKit.Notifications.Channel`** behaviour: `key/0`, `label/0`, `icon/0`,
  `configured?/2`, `deliver/2`, optional `validate_config/1`. `deliver/2` takes a
  channel-neutral, pre-rendered `t:envelope/0` (absolute URL) and returns a
  permanent/transient error taxonomy so the worker decides retry-vs-give-up.
- **`Channels`** registry: core `[Email, Telegram, Push]` + modules' optional
  `notification_channels/0` (same merge as `Types`). `Channels.Email` is
  always-configured (sends via `Mailer`); `Channels.Telegram` auto-discovers the
  recipient's Telegram connections + captured `chat_ids`.
- **`ChannelConfig`** — per-channel config under
  `custom_fields["notification_channel:<key>"]` (ONE top-level key per channel so
  the atomic shallow `||` merge can't clobber siblings). Reserved: `enabled`
  (default on), `types` (**fail-closed** per-type opt-in), `cadences`.
- **`Routing`** — `targets_for_action/2` / `targets_for_type/2` / `any_target?/2`,
  **fail-closed**: untyped / standalone sends never route out.
- **Delivery**: `DeliveryWorker` on a dedicated `:notifications` Oban queue
  (enqueued at creation for immediate cadences; the inbox insert is **decoupled**
  from the enqueue, so a failed channel enqueue never costs the user their inbox
  row). `DigestWorker` is an Oban cron (one entry per cadence: immediate / hourly
  / 12h / daily / weekly) that counts activity in a fixed window and sends one
  summary — no per-user last-sent state. `DigestWorker` is enqueued ONLY by those
  cron entries, so **`mix phoenix_kit.update` must backfill them into existing
  hosts** — `ObanConfig.ensure_notifications_queue/2` + `ensure_digest_cron_entries/2`
  edit an already-installed `config/config.exs`, since a digest cadence suppresses
  the per-event inbox row and a missing cron entry would silently drop the
  summary too (the same template-only gap `PruneWorker` still has). Adding config
  to the install template alone never reaches upgraded hosts.
- **Registry loading:** `Channels.external_channels/0` (like `Types.external_types/0`)
  guards with `Code.ensure_loaded?(mod) and function_exported?(mod, :notification_channels, 0)`
  — a bare `function_exported?/3` is `false` for a not-yet-loaded module under a
  release, silently dropping the channel.
- **Never trust param keys:** the settings LV builds channel/type/cadence maps by
  `Map.take`-ing params against `Channels.keys()` / `Types.all_pref_keys()`, never
  by iterating raw param keys (which name their own storage keys).
- **Telegram setup** lives on the personal integration form (mode select + chat
  capture folded into Test), NOT the notifications page. `mode`: `"single"` (lock
  one chat) / `"multi"` (broadcast to all who started the bot); an **Unlink**
  button clears captured `chat_ids`. The `notification_channel:telegram` config
  holds only routing/cadence — connection + chat live on the integration.
- **Site bot (one bot — one site)** — the admin picks ONE website Telegram
  connection (Settings → Integrations → the bot → "User notifications", setting
  `telegram_notifications_connection`, `Telegram.SiteBot`); it is off by default.
  Each user then links their own chat from the **Telegram card on their profile
  settings page** (`Live.Components.TelegramNotificationsCard`, no admin access
  needed): Connect mints a one-time `https://t.me/<bot>?start=<token>` link
  (`Telegram.Linking`, 64-char token, hash in `phoenix_kit_users_tokens` context
  `telegram_link`, minted for ONE bot, 15 min, spent by the delete that reads it),
  the user presses Start, and `Linking.poll/1` links THAT chat to the token's
  owner — the sender is never guessed, a group `/start` is ignored, and the bot's
  reply names the site, never the account.
  - **Polling** — there is no webhook or background poller: the card polls every
    3 s while a link is pending (one timer per card; Connect / "I've sent it" are
    throttled; a card with nothing pending never calls Telegram), once on opening
    with a pending link, and on the button. A poll reads the updates with
    `getUpdates`, then runs ONE short database transaction under a Postgres
    advisory lock (spend the tokens, record the links) — no Telegram call inside
    it — and only after the commit confirms the offset and sends the replies. A
    failed confirmation re-reads the batch, which is harmless: a `/start` whose
    chat is already linked to the bot is passed over silently, never answered
    "expired". The bot must have no webhook (`getUpdates` refuses) — the admin
    form warns.
  - **Storage** — `custom_fields["notification_channel:telegram"]`
    (`site_chat_id`, `site_connection_uuid`, `linked_at`); the FIRST link switches
    on the types the user already receives in the app (a one-time copy), after
    that the card's checkboxes rule and fail-closed stays the default. Linking
    and Disconnect are logged to the activity feed as `telegram.linked` /
    `telegram.unlinked` (actor = the user; the chat id is not recorded).
  - **Delivery** — a user's own bot wins over the site bot; a link to a bot that
    is no longer the selected one delivers nothing. Errors about the CHAT
    (blocked, kicked, deactivated, chat not found) are permanent and soft-disable
    that user's channel; errors about the BOT (revoked token, 401/404, deleted
    connection) are transient for the site bot — every linked user would fail
    alike, so none is switched off. A soft-disabled user sees "Switched off" on
    the card and a **Reconnect** button, which runs the same one-tap flow and
    switches delivery back on.

- **Browser push (`Channels.Push`, key `"push"`, label "Browser")** — Web Push
  (RFC 8030/8291/8292) to the person's browsers and phones, built in core with
  no extra dependency (`PhoenixKit.Notifications.Push`, V235). Site settings on
  Settings → Notification messages: `push_enabled` (default on), `push_show_line`
  (default off: a locked screen shows only the site's name and "New
  notification" / "N notifications pending"), `push_group_seconds` (default 30,
  5–600). The site's VAPID key pair is made on first use (setting
  `push_vapid_key`, encrypted with the site’s restricted settings and included in
  encryption-key rotation). Turning push on requires a working encryption key.
  - **Devices** — one `phoenix_kit_push_installations` row per browser
    subscription, one `phoenix_kit_push_bindings` row per account that turned
    push on there (several accounts in one browser share the installation). The
    person turns it on from the **Browser card** of their notification settings
    (`Live.Components.PushNotificationsCard`, hook `PkPush`); a borrowed session,
    a managed organization and a service user are refused. The first time, the
    types the account gets by email are ticked for Browser too. The card lets the
    person change those choices, including accounts without admin access. At most 10
    devices per account. An endpoint must be a known push service
    (`WebPush.endpoint_ok?/2`: FCM, Mozilla, Apple, Windows, plus
    `config :phoenix_kit, :push_service_hosts`) on a public address — never a
    URL of the person's choosing.
  - **Grouping** — the channel writes a `phoenix_kit_push_pending` row and
    schedules one `GroupWorker` per account (Oban unique on the user); when the
    window ends it sends ONE push per device (`SendWorker`, TTL 7 days, `Topic`
    per account so the service replaces an undelivered one, `tag` per account
    so the screen shows one). A 404/410 from the service deletes the device; a
    429/5xx retries. A notice the reader can no longer see (`visible: false`)
    is never queued. The quoted comment never goes into a push.
  - **Clicks** — the payload carries only `<prefix>/notifications/open/<handle>`,
    an encrypted handle (account, same-site link, summary?, 7-day expiry).
    `PushOpenController` opens it for the account in use; for another account
    this browser holds and may switch to (`MultiSession.gate_allowed?/1`, not a
    borrowed one) it asks "Switch and open" (a CSRF POST); anything else gets a
    page that names no one.
  - **Clean-up** — logging out (and removing an account from the switcher, or
    logging out an added one) drops that account's binding in this browser
    (cookie `pk_push_browser`), and the last binding takes the installation.
    Whatever ends a linked Telegram chat ends every device of the account
    (`Push.forget_account/1`; `forget_account!/1` inside a caller's
    transaction): deactivation, a password change or reset, an external-proof
    confirmation, signing out everywhere or the other sessions (this browser's
    too: a binding names no session), conversion to a managed organization,
    deletion. A new path of that kind calls it too. `take_pending/1` builds
    nothing for an account `subscribe/3` would refuse. A rotated subscription is reported
    by the worker to `POST <prefix>/push/resubscribe`, proven by the old
    subscription's `auth` secret.
  - **Host notes** — the service worker is served by core at
    `<prefix>/push/sw.js` with scope `<prefix>/push/` (it never sits in front of
    the host's pages; it has no fetch handler). A host with a Content Security
    Policy needs `worker-src 'self'` and `manifest-src 'self'`. iPhone and iPad
    get web push only from a site added to the Home Screen: the card links
    `<prefix>/push/install`, which carries the manifest itself, so the host's
    layout needs no change. Jobs run on the existing `:notifications` queue.

**Cleanup:** `PhoenixKit.Notifications.PruneWorker` daily (`"0 4 * * *"`). Retention: `notifications_retention_days` → falls back to `activity_retention_days` (default 90). Cascading FK deletes also remove notifications when the underlying activity is pruned.
