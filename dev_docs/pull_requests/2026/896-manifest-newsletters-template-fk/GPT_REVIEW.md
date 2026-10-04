# PR #896 — GPT release recheck

Reviewed the published 2.52.0 tag (`72c9b8127`) against 2.51.0.

No additional defect found. Core's manifest omits exactly the module-owned newsletters template FK. The generator excludes the same object from the manifest while retaining it in baseline generation. Neighbouring constraints remain managed. The generator's offline self-check passed, including its module-owned exclusion assertion; the release includes integration tests for the original, repointed and missing FK and repair of a neighbouring FK.

See the [complete release recheck](../../../reviews/2026-10-04-2.52.0-release/GPT_REVIEW.md) for validation and package provenance.
