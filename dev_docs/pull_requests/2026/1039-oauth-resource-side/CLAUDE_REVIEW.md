# Claude Review — PR #1039

**PR:** Add the data model and resource side of an OAuth 2.1 authorization server for the admin
MCP endpoint, V233 (timujinne)
**Reviewer:** Claude Opus 5.5, with an independent reviewer per layer of the stack
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep; fixes are on `main`)

The OAuth stack #1039–#1043 was reviewed one layer at a time, each against the current `main`
(so a problem a later layer already fixed is noted, not reopened). V233 and V234 are unreleased,
so the schema changes below amend V234 rather than adding V235. The manifest was regenerated and
the chain hash restamped.

## Verdict

No critical or high finding. The security core holds:
- tokens are 32 random bytes, stored as SHA-256 of kind + secret;
- rights are the grant scopes ∩ the owner's rights, read on every call and never cached;
- the lock order is key → grant → tokens everywhere;
- hidden keys are excluded from every listing, count, rotate and scope edit, and `Keys.verify/2`
  refuses them;
- `pkoa_` is accepted only on `/mcp/admin`, and only while OAuth is on;
- V233 follows the prefix rules.

## Findings

### IMPROVEMENT - MEDIUM — a removed client's hidden keys stayed behind for good (fixed, d2d219672)
The grants cascade with the client, but their hidden `phoenix_kit_api_keys` rows did not, and
the prune walks grants, so it never saw them. The removal now deletes the hidden keys of the
client's ended grants in its own transaction. A key with confirmations stays until those are
cleared, then the new prune step `orphan_keys` removes it.

### IMPROVEMENT - MEDIUM — no index on the tokens' and codes' `expires_at` (fixed, b1308b2c4)
Every prune batch was a sequential scan, and rotated refresh tokens are kept until the grant ends.
Both columns are now indexed (V234).

### NITPICK — `delete_unactivated` deleted `grant.key_uuid` without checking it is the grant's hidden key (fixed, 4ce0e36fc)
### NITPICK — `insert_preregistered` took `client_uri` unchecked (fixed, 4ce0e36fc)
It now goes through `clean_uri/1`, which no longer raises on bytes that are not UTF-8.

## Checked, not changed
- **`Resource.normalize/1` and the scheme's case.** `URI.new` already lower-cases the scheme,
  so a mixed-case scheme works. The reported refusal does not happen.
- **The `insufficient_scope` challenge** cannot fire on MCP, because a missing scope is a tool
  error there, not a 403. It is harmless, and left for a step-up flow.
- Already fixed by later layers: BodyGuard keeping the last of two repeated form parameters, and
  the idle-client prune deleting rows without repeating its conditions.
