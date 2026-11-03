# Library verification and activity

Add Libraries / Activity tabs to the personal Media settings surface. Activity lists
library-scoped runs for libraries the viewer currently belongs to. Owners may start
verification and pause, resume, cancel or retry verification and reconciliation;
members may read history. Recheck the active session role and library ownership at
every action. Never grant global job-management permissions to library owners.

Verification is read-only: check originals by default, optionally include previews,
and optionally download each copy to compare SHA-256 checksums. Walk files in bounded
batches with a durable cursor and a start-time upper bound; new uploads belong to
the next check. Report absent instances, inaccessible objects, unrecorded checksums,
checksum mismatches and incomplete placement without repairing or changing locations.

Reuse job runs, lifecycle history and polling already present in Media. Persist a
batch summary and individual problems in the same transaction as its checkpoint,
so replayed or superseded batches do not duplicate logs. Log identifiers and fixed
problem codes, never credentials, raw provider errors or private names. Resolve
names only after checking access. Reconciliation adds summaries and unfinished file
identifiers to the same history. Paginate runs and logs; existing job/activity
retention policies apply (90 days by default). No new tables are necessary.

Validate with local object fixtures, presence and checksum failures, preview scope,
cursor/replay tests, cross-account and forged controls, revoked membership/permissions,
UI tests and existing storage/job engine suites. Repair remains a separate future action.

## Verification limits

Use one unfinished verification across every account and library (queued, paused
and draining included), plus one newly admitted check per rolling 30 days per
library. Failed/cancelled checks and manual retries share the cooldown. Resuming
or automatically retrying a batch continues the original run. Enforce admission
inside the engine's insertion transaction, under a global PostgreSQL transaction
lock, so all start paths and simultaneous requests share the policy. Stamp the
library's internal settings alongside the run so pruning history cannot erase the
cooldown; fall back to existing run timestamps for checks predating the policy.
Expose a next-allowed date and a private, generic global-busy message in the UI.
