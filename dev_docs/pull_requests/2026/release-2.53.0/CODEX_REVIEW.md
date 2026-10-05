# PhoenixKit 2.53.0 pre-publication review

Date: 2026-10-05

Scope: changes since 2.52.2, through commit `48422020d`, plus the fixes below.
The candidate remains 2.53.0: Hex had 2.52.2 at review time and no 2.53.0 tag
or publication existed. No migration changes or further version bump are needed.

## Findings and fixes

- **BUG - HIGH:** The reconciler attempted copies per kind, then checked the
  combined count. Two existing local copies could hide a failed cloud copy
  when the new target was one local and one cloud, marking the file fully
  placed. The check before unlinking also combined verified objects, allowing
  excess local objects to stand in for a cloud location whose bytes were gone.
  Both checks now require enough local and cloud copies independently. Before
  unlinking, at least one remaining serving copy must also be real; verified
  backup copies cannot stand in for a primary whose location outlived its bytes.
  PostgreSQL-backed HTTP tests cover failed cloud writes, missing cloud objects
  and a missing serving primary alongside excess local or backup copies.
- **BUG - MEDIUM:** Reconciliation retained copies of a kind set to zero, and
  its serving fallback could write that kind anyway. Zero-count kinds are
  excluded from retained and writable placement. Old copies are unlinked only
  once the wanted kinds have enough verified copies; the last real copy is
  protected. When the remaining serving buckets belong to a zero-count kind,
  the file stays stale until the profile changes, including when those buckets
  are read-only or full. Tests cover moving local copies to cloud, refusing the
  unwanted serving fallback, and retaining read-only and full serving copies.
- **BUG - MEDIUM:** Removing the last writable cloud bucket disabled a nonzero
  Cloud copies input, preventing an admin from lowering it. Existing nonzero
  counts remain editable. The upload minimum's HTML maximum also used the
  saved total, blocking an increase in the same submission as the copy counts.
  Its maximum is now five, with the changeset enforcing the submitted total.
  LiveView tests cover both controls.
- **IMPROVEMENT - MEDIUM:** The upgrade note implied every mixed profile needed
  Cloud copies set manually. It now explains that V209 assigns cloud copies
  only when available local buckets cannot cover the old total. Storage docs
  and the personal-profile API docs now describe per-kind placement and the
  fact that a personal backup also receives sizes and tiles.
- **IMPROVEMENT - MEDIUM:** The reported trash-broadcast flake had an unscoped
  deletion-batch receive on a shared topic. It now selects this test's UUIDs,
  as the trash-batch assertion already did. The full suite also exposed a
  deadlock between async tests reordering the seeded system roles and a
  Libraries sync assertion racing a queued component update. Role-order
  suites now run synchronously, and the LiveView test waits for its event
  handler before inspecting the component.

## Validation

- `mix precommit` passed on the final code, including test-file compilation,
  strict Credo, Dialyzer and all 254 JavaScript tests.
- Full PostgreSQL-backed rerun with the seed that exposed the test races
  (`761508`): 87 doctests, 8,313 tests, zero failures, six skipped and one
  excluded.
- After the final read-only/full serving-copy guards, the affected suites
  passed again: 116 tests, zero failures. This covers reconciliation, S3 HTTP
  placement and failure handling, profile and library LiveViews, role order,
  trash broadcasts, V209 and the full migration chain in a named schema.
- `mix prerelease` passed on the final committed code: locked dependencies,
  production compilation, strict quality checks, dependency audits, docs,
  package build and release_check (7/7, zero warnings or failures). Its final
  cleanup removed the generated tarball.
- The completed review record is committed with the fixes; a fresh package
  build and release_check also verify the final clean tree after that record
  is finalized.

## Remaining verification limits

- Successful original and derived placement is exercised through the actual
  S3 provider and HTTP client against a local S3-compatible stub, including
  two local copies plus one cloud copy and an upload minimum of three. This
  does not verify a real provider's credentials, IAM policy, multipart upload,
  or service-specific behavior.
- LiveView tests verify the profile controls, their attributes and submissions.
  A visual browser check was not performed in this environment.
- The test PostgreSQL role lacks CREATEROLE; the suite reports that privileged
  test as excluded. Ordinary integration and migration tests run against PostgreSQL.
