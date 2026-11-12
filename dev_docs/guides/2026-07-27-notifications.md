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

`Types.list/0` merges core + modules; toggle appears automatically. `Notifications.Prefs.user_wants?/2` is **fail-open** — unknown actions, missing prefs, or lookup errors return `true`.

**Custom display:** `Render.render/1` honors three metadata keys before falling back:

```elixir
metadata: %{
  "notification_text" => "Alice left you a 5-star review.",
  "notification_icon" => "hero-star",
  "notification_link" => "/reviews/#{review.uuid}"
}
```

Any key can be absent — Render falls back to the action lookup for the missing parts.

**Mentions** (`PhoenixKit.Mentions.notify/2`, action `mention.created`) are a core type of their own, `"mentions"`, so a person can mute them or route them to email like anything else (routing is fail-closed: an action no type owns never leaves the inbox). The activity stores `actor_name` (full name, else username — never the email's local part) and Render words it in the reader's language: "Ada mentioned you." (`hero-at-symbol`). A caller passes `link:` — a local path built with `Routes.path/1`, pointing at the mention itself (comments: the record's page + `#pk-comment-<uuid>`); anything failing `Routes.local_path?/1` is dropped. Rows from before the name was stored keep their own `notification_text`.

## Delivery channels (external destinations)

Pluggable per-user routing of notifications to **external** destinations
(Telegram, Email; more via modules) on top of the in-app inbox. **Model B —
parallel routing layer**: the inbox path above is untouched; external channels
are computed + enqueued independently, so "Telegram on, inbox off" works with
**no migration** (config rides `users.custom_fields`).

- **`PhoenixKit.Notifications.Channel`** behaviour: `key/0`, `label/0`, `icon/0`,
  `configured?/2`, `deliver/2`, optional `validate_config/1`. `deliver/2` takes a
  channel-neutral, pre-rendered `t:envelope/0` (absolute URL) and returns a
  permanent/transient error taxonomy so the worker decides retry-vs-give-up.
- **`Channels`** registry: core `[Email, Telegram]` + modules' optional
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

**Cleanup:** `PhoenixKit.Notifications.PruneWorker` daily (`"0 4 * * *"`). Retention: `notifications_retention_days` → falls back to `activity_retention_days` (default 90). Cascading FK deletes also remove notifications when the underlying activity is pruned.
