# PR #899 — GPT release recheck

Reviewed the published 2.52.0 tag (`72c9b8127`) against 2.51.0, including Claude's post-merge fixes.

The Markdown pipeline preserves placeholders through parsing, sanitizes the rendered structure, checks substituted link destinations and escapes attribute values. The new defaults, host-text HTML precedence, preview notes and notification channel agree. Welcome jobs are enqueued transactionally on the normal single-repo confirmation paths, and a conditional JSONB update claims delivery. Known build/refusal failures release the claim; ambiguous delivery failures keep it and cancel retries. The new outer `catch :exit` covers magic-link registration's post-commit enqueue.

## Findings still present in 2.52.0

- **BUG - MEDIUM:** the welcome button links to `Routes.base_url()`; a host without a root route sends the reader to a 404. This was already recorded by Claude. Left unchanged in this recheck: changing the default destination and translated copy is a separate product change.
- **BUG - MEDIUM:** transactional welcome enqueue assumes the default Oban instance uses PhoenixKit's repo. `guarded_insert/1` creates its savepoint on `Repo.repo()`, whereas `Oban.insert/1` uses Oban's configured repo. With separate pools/databases the job is independently committed: an outer confirmation rollback cannot remove it, and a worker that runs before confirmation commits discards the job as unconfirmed. Confirmed with independent repo pools and a scratch Oban schema: one job survived the confirming repo rollback (the expected transactional result is zero). Claude recorded this as a nitpick; it is a functional limitation of the transactional guarantee. Left unchanged: resolving it needs an explicit cross-repo enqueue strategy or a documented/enforced same-repo requirement.
- **NITPICK (fixed locally):** the new welcome test updated a `%User{}` without matching its type first, which emitted an Elixir 1.19 compiler warning. Added the struct pattern. The email-preview test helper also contained an unreachable `{:ok, _}` revoke clause; simplified it to return the actual permission API result. The latter predated this release.

See the [complete release recheck](../../../reviews/2026-10-04-2.52.0-release/GPT_REVIEW.md) for validation and package provenance.
