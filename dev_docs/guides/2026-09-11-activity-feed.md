# Activity Feed

Tracks business-level actions. Admin UI: `/admin/activity` (and `/admin/activity/:uuid`). Core: `lib/phoenix_kit/activity/`. Notifications (the per-user inbox driven by this log) are covered in `dev_docs/guides/2026-07-27-notifications.md`.

```elixir
PhoenixKit.Activity.log(%{
  action: "post.created",       # required — "resource.verb"
  module: "posts",              # filterable
  mode: "manual",               # "manual" | "auto" | "cron" | "script"
  actor_uuid: user.uuid,
  resource_type: "post",
  resource_uuid: post.uuid,
  target_uuid: nil,             # who was affected (drives notifications)
  metadata: %{"actor_role" => "user", "title" => post.title}
})
```

- **Profile/field changes** — `log_user_change("user.profile_updated", user, changeset, actor_uuid: …, target_uuid: …, mode: "manual", actor_role: "admin")` auto-extracts `field_from`/`field_to` from a changeset; skips logging if nothing changed.
- **Conventions:** `action` = `resource.verb`; `module` = key string; `actor_role` baked at log time; `resource_type` usually equals `module`. Examples: `rg 'Activity.log' lib/phoenix_kit/users/`.
- **External modules** — call `PhoenixKit.Activity.log(module_key, action, opts)` (options: `:actor_uuid`, `:mode`, `:resource_type`, `:resource_uuid`, `:target_uuid`, `:metadata`, `:permanent`; `log_failed/3` marks the metadata `"db_pending" => true` for an attempt that did not land). It never raises — a failed insert, a raise, an exit or a throw is logged and returned as `{:error, _}` — so no guard or rescue of your own. Read the actor with `PhoenixKitWeb.Actor` (`uuid/1` and `opts/1` read the scope first, then the bare current user; `role/1` reads the scope's active role, so it is `nil` without a scope), never from assigns by hand. Neither `log/3`/`log_failed/3` nor `PhoenixKitWeb.Actor` exists in core ≤ 2.37.5: a module on the open `~> 2.0` pin checks `Code.ensure_loaded?(PhoenixKit.Activity) and function_exported?(PhoenixKit.Activity, :log, 3)` (and `Code.ensure_loaded?(PhoenixKitWeb.Actor)`) and keeps its old path as the fallback until it raises its core floor.
- **Storage configuration** is logged by `PhoenixKit.Modules.Storage.Audit` (module `"storage"`, actions `storage.<resource>.<verb>`, `permanent: true`, changes in the `"changes"` shape) and read back on Settings → Media → History with `PhoenixKitWeb.Components.Core.ActivityList`.

  Storage mutators lock the current resource and insert its audit entry in the
  same transaction. `Storage.Audit.transaction/1` collects nested entries and
  publishes after its owned transaction commits. Inside an external repo
  transaction it suppresses storage announcements; Media History's periodic
  refresh finds committed entries. The tab also includes existing permanent
  `setting.changed` entries for global `storage_*` settings. Resource identity is
  shown separately from changed values; detail links require `dashboard` access.
- **Cleanup:** `activity_retention_days` setting (default 90). `PhoenixKit.Activity.PruneWorker` runs daily via Oban.
