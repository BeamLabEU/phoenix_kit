# Claude review — PR #909 (2026-10-06)

**Verdict:** sound; no bugs found. Two nitpicks recorded, nothing changed in `lib/`.

Scope: with `update_mode` on (`mix phoenix_kit.update` / `doctor`) `Settings.get_setting/1` answers nil, so
one-shot boot steps whose "already done" flag is read through it ran again — the visible damage was the
Admin auto-grant handing a revoked custom permission key back. The PR reads the two permission flags from
their rows, adds `catch :exit` to the auto-grant, and makes `ModuleRegistry.run_all_legacy_migrations/0`
a no-op under `update_mode`.

## Traced, no finding

- **Fail closed, both ways.** `get_setting_by_key/1` raises on a missing table and exits on a dead pool;
  the function's `rescue` handles the first and the new `catch :exit` the second, each returning `:ok`
  without granting. The old reader turned a failed read into nil ("never granted") — fail open; the new
  test renames the table inside the sandbox to prove the inverse.
- **Orchestrator guard placement.** The check is inside `run_all_legacy_migrations/0`, so `boot/1`, a
  host that still calls it directly after `Supervisor.start_link/2`, and the deprecated
  `Integrations.run_legacy_migrations/0` shim are all covered (all three exercised in the test).
- **No other flag reader at boot.** `rg` over `lib/` for `auto_granted` / `backfilled` flags read through
  `Settings.get_setting` finds none left; the two sites changed are the only ones.
- **`update_mode` is not a runtime-production state.** It is set only by the two mix tasks (and the
  supervisor/Dashboard/Settings read it), so skipping the legacy migrations cannot leave a running site
  without them — the host's next ordinary start runs them, as the docs now say.
- **Test helper note** in `test_helper.exs` was updated accurately: the one suite that touches the
  orchestrator sets `update_mode: false` itself.

## NITPICK — the flag read now bypasses the settings cache, one query per key per boot

`auto_grant_new_keys_to_admin/0` walks every core, feature and sub-permission key (several dozen) and
each now costs a `get_by` instead of a cache lookup. Boot-time only and negligible next to the grants a
fresh install performs; if it ever matters, one `Queries.list_settings_by_keys/1` over the
`auto_granted_perm:*` keys would make it a single query.

## NITPICK — `phoenix_kit.update` still starts the host before it migrates

The PR's own docs point this out (the update task boots the host against the old schema). Skipping the
legacy migrations removes the worst consequence, but `register_custom_permission_keys/0` and the two
permission steps still run in that window; they now tolerate a missing table (`table_missing_error?`),
which is what keeps this safe. Worth keeping in mind for any new boot step: it must survive an
old-schema database.
