# Claude Review — PR #1042

**PR:** Add Connected apps, the sign-in settings tab, guides and translations for the OAuth
server (timujinne)
**Reviewer:** Claude Opus 5.5, with an independent reviewer per layer of the stack
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep; fixes are on `main`)

The OAuth stack #1039–#1043 was reviewed one layer at a time, each against the current `main`
(so a problem a later layer already fixed is noted, not reopened). V233 and V234 are unreleased,
so the schema changes below amend V234 rather than adding V235. The manifest was regenerated and
the chain hash restamped.

## Verdict

No critical or high bug on current `main`.

The worst problem in this PR's own diff was that any holder of `api` could change the OAuth
policy and add clients. #1043 had already closed that in the page with `with_owner/2`.

Checked and sound:
- **Events:** every event that changes something goes through `with_access/2` (a fresh scope,
  no borrowed session). An event the page does not know is refused.
- **Disconnecting:** it re-authorizes inside `Connections.revoke/3`, so no IDOR.
- **Forms:** they have unique ids.
- **Settings keys:** the `api_oauth_*` keys are not writable through `update_settings/2`.
- **Activity entries** carry no secrets.
- **Gettext:** every msgid the new code uses exists.

## Findings

### IMPROVEMENT - MEDIUM — the Owner rule lived only in the page (fixed, 9a8d8fa82)
`OAuthConfig.save`, `Clients.register_preregistered` and `Clients.delete` took no actor. The
delete also ended every connection by default (`only_idle: false`). Now:
- `save/3` and `register_preregistered/2` take the actor's scope and answer
  `{:error, :forbidden}` unless it is an Owner who holds `api`;
- `delete/3` decides from the scope: an Owner ends live connections, anyone else holding
  `api` removes only an idle client;
- `:system` ends connections only with an explicit `end_connections: true`.

There are forged-call tests.

### NITPICK — the guide's OAuth section built the MCP address from `site_url` (fixed, f5598c6b5)
With a path in `site_url`, the `claude mcp add` line named a URL whose protected-resource
metadata announced a different `resource`. The guide now uses `Status.report()`'s resource URL.

### NITPICK — Connected apps showed `user.email` in the Owner's list (fixed, 3d0428d8c)
It now uses `User.delivery_email/1`.

## Open
- **Owner's view of every connection.** It builds one scope per distinct person
  (`Connections.owner_states/1`) and reloads on each update. It is fine at today's sizes, and
  worth batching if the list grows.
- **No notice when someone else ends a connection.** `oauth.grant_revoked` carries no
  `target_uuid`, so the person is not notified. Adding one sends a notification through every
  channel, which is a product decision.
- **Owner checks and the active role.** They read the full role set (`narrow: false`), as Keys
  and Approvals do.
