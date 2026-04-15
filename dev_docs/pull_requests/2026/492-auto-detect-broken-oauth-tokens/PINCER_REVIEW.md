# PR #492 Review — Auto-detect broken OAuth tokens on refresh failures

**Scope reviewed:** only the single commit on top of `#491` —
`9c5bf558 Add automatic integration health tracking on OAuth refresh`.
Everything else in the diff is PR #491, which is already merged on `dev`.

## Summary

Solid, tightly-scoped change. It centralizes the "write status /
validation_status / last_validated_at + broadcast" logic into
`Integrations.record_validation/3`, then wires `refresh_access_token/1`
to call it on both failure (`status: "error"`) and on recovery-after-error
(`status: "connected"`). The manual "Test Connection" flow in
`IntegrationForm` now delegates to the same helper, which is a nice
de-duplication.

The behaviour matches the description: a broken Google OAuth refresh
will flip the admin badge to `error` immediately instead of waiting for
a human to click Test Connection.

## Findings

### BUG - MEDIUM — `record_validation/3` silently no-ops for UUID provider keys

`integrations.ex:686`

```elixir
case Settings.get_json_setting(settings_key(provider_key), nil) do
  nil ->
    Logger.debug("[Integrations] record_validation skipped — no integration at #{settings_key(provider_key)}")
    :ok
  data -> ...
end
```

`settings_key/1` wraps the argument as `integration:<uuid>:default`, so
when `provider_key` is a UUID (the settings-row identifier) the lookup
returns `nil` and `record_validation` silently does nothing.

This matters because the rest of the `Integrations` API *does* accept a
UUID — `get_integration/1` branches on `uuid?/1` and calls
`Settings.get_json_setting_by_uuid/1`, and `refresh_access_token/1`
itself has special handling for UUID lookups (see
`resolve_provider_lookup_key/2` and `resolve_storage_key/2`, added in
PR #479). A common call path that can hit this is:

  `authenticated_request(uuid, ...)` → 401 →
  `retry_with_refreshed_token(uuid, ...)` →
  `refresh_access_token(uuid)` → on failure →
  `record_refresh_failure(uuid, reason)` →
  `record_validation(uuid, {:error, ...})` → **no-op, admin UI never flips**.

This directly undermines the PR's stated goal for any external module
that holds onto the settings-row UUID (the document_creator module does
this). The manual "Test Connection" flow in `IntegrationForm` happens
to always pass a `"provider:name"` string, so that path is fine — but
the new automatic path is exactly where UUIDs show up.

Fix: branch on `uuid?/1` the same way `get_integration/1` does — read
via `get_json_setting_by_uuid/1` and write back via the same UUID, or
resolve the UUID to a provider/name and then use `settings_key/1`
consistently for read and write. Worth a small test that calls
`refresh_access_token/1` with a UUID and asserts the status flips.

### IMPROVEMENT - MEDIUM — `actor_uuid` argument is dead weight

`integrations.ex:668` and `integration_form.ex:261`

```elixir
def record_validation(provider_key, result, _actor_uuid \\ nil) do
```

The callsite in `IntegrationForm` dutifully threads `uuid` through, but
the function ignores it. Either:

- drop the arg (2-arity) since activity attribution is already handled
  inside `validate_connection/2` via its own `log_activity` call, or
- use it to attribute the two new activity entries
  (`integration.token_refresh_failed` / `integration.auto_recovered`).
  Today both hard-code `nil` as actor, which is accurate for the auto
  path but means if `record_validation` is ever invoked from a manual
  admin-initiated flow that also failed, the audit trail will not
  attribute the error stamp to anyone.

Leaning toward dropping it — the manual path already logs
`integration.validated` with the actor in `validate_connection/2`, so
the stamp write itself doesn't need an actor. An underscored parameter
in a public API is a smell.

### IMPROVEMENT - LOW — ignored return from `save_integration` inside `record_validation`

`integrations.ex:695-703`

```elixir
save_integration(provider_key, updated)
Events.broadcast_validated(provider_key, result)
```

If the DB write fails (encoding error, changeset failure — `save_integration`
does return `{:error, changeset}`), the event still fires announcing a
status change that didn't persist. Subscribers then render stale data
on the next read. Pattern-match the result and skip the broadcast on
error:

```elixir
case save_integration(provider_key, updated) do
  {:ok, _} -> Events.broadcast_validated(provider_key, result)
  {:error, _} = err -> err
end
```

Same pattern is already observed elsewhere in this module (e.g.
`save_setup/3` at line 163).

### NITPICK — triple read of the settings row on the failure path

`refresh_access_token/1` → `record_refresh_failure/2` → `record_validation/3`
and separately `maybe_record_recovery/1` each call
`Settings.get_json_setting(settings_key(provider_key), nil)` or
`get_integration/1`. That's 2–3 reads of the same row per refresh
attempt. Not hot-path critical (refresh is O(hours)), but trivial to
pass `data` through.

### NITPICK — error-string change is observable

Old format: `"error: #{reason}"` where `reason` could be an arbitrary
term (so you'd see things like `"error: %Req.Response{...}"`).
New format goes through `format_validation_reason/1` and produces
nicer strings like `"error: Token refresh failed (HTTP 400)"`. This is
an improvement, but if anything (tests, dashboards, alerting) is
parsing the `validation_status` string it will break. A quick grep
shows only the admin UI renders it as opaque text, so likely safe —
worth a mention.

### NITPICK — module file size

`integrations.ex` is now ~900 lines. Not this PR's fault, but the
validation-stamping helpers
(`record_validation`, `validation_fields`, `format_validation_reason`,
`record_refresh_failure`, `maybe_record_recovery`) are cohesive enough
to live in a small `Integrations.Health` sub-module. Future refactor.

## Tests

No new tests accompany the change. Given the bug-fix framing ("a real
incident… went unnoticed for hours"), at least one regression test
would be welcome:

- `refresh_access_token/1` with a stubbed OAuth client that returns
  `{:refresh_failed, 400}` → assert the stored record has
  `status: "error"` and `validation_status: "Token refresh failed (HTTP 400)"`.
- Follow-up success call → assert recovery to `status: "connected"`
  and presence of the `integration.auto_recovered` activity entry.
- UUID-keyed call (ties in with the MEDIUM bug above).

The `Bypass`/`Req.Test` adapter scaffolding would need to be introduced
— per the `#476` review notes, it doesn't exist yet — but a minimal
mock of `OAuth.refresh_access_token/2` via a module attribute or
`Mox` on the `OAuth` boundary would get most of the value.

## Verdict

Approve after addressing the UUID-handling bug (MEDIUM). The rest can
be follow-ups. The architectural direction — one authoritative
health-writing path, automatic error surfacing on the hot path — is
exactly right.
