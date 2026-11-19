# Claude Review — PR #1043

**PR:** Add approval of OAuth connections, an optional key revocation on password change and a
mail about a new connection, V234 (timujinne)
**Reviewer:** Claude Opus 5.5, with an independent reviewer per layer of the stack
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep; fixes are on `main`)

The OAuth stack #1039–#1043 was reviewed one layer at a time, each against the current `main`
(so a problem a later layer already fixed is noted, not reopened). V233 and V234 are unreleased,
so the schema changes below amend V234 rather than adding V235. The manifest was regenerated and
the chain hash restamped.

## Verdict

No critical or high bug.
- **Waiting connections.** `require_approved/1` in `Executor.execute/5` runs before the tool
  lookup, the idempotency replay, the confirm-token redeem and the gate. A waiting connection
  therefore cannot read, write or replay through any path.
- **`Grants.approve/3`** is one conditional UPDATE, checks Owner + `api`, and refuses a borrowed
  session.
- **Defaults.** A missing setting reads as `approval`, and an unreadable one fails closed.
- **Password changes.** Every path that changes a password (own change, admin, reset, the rotation
  after an external sign-in proof) revokes in the same transaction.
- **`ConnectedMail`** is sent after the commit, to a proven address, and carries no secret.

## The PR's "known limits", judged
1. **A waiting connection sees tool names.** Kept. A stateless MCP client gets no
   `list_changed`, so an empty list would stay empty after approval.
2. **The Owner saw where answers go from the client's current row.** Fixed in b1308b2c4. A
   metadata document can change after the consent. A grant now keeps the `redirect_uri` its code
   was issued for (V234, set at the exchange), and Waiting for approval and
   `oauth.grant_approved` show that.
3. **`save` / `register_preregistered` left the Owner check to the caller.** Fixed in 9a8d8fa82
   (see #1042's review).
4. **A `pk_` key can stay cached for up to 60 s after a nested password transaction.** Left as
   is. It needs an unconfirmed account that holds personal keys, with the switch on, inside the
   OAuth callback's transaction.

## Findings fixed
- **NITPICK — the core mailer called a LiveView module.** `UserNotifier` called
  `Live.Settings.Api.module_label/1`; that function is now `PhoenixKit.API.ModuleLabel`
  (4ce0e36fc).
- **NITPICK — Waiting for approval showed `user.email`.** It now uses `User.delivery_email/1`
  (4ce0e36fc).

## Open
- **The person is not told the Owner's decision.** `oauth.grant_approved` and the rejection
  carry no `target_uuid`. Same product decision as in #1042.
- **An app name that looks like a URL** is quoted and cut, but mail clients may still autolink
  it in the text part.
- **V234 could be folded into V233.** It now also carries the review's indexes and two columns.
  Left as two migrations.
