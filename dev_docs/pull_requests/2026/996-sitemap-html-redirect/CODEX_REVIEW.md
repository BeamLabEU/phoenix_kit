# PR #996 — Codex review

**Reviewer:** Codex · **Date:** 2026-10-30 · **Baseline:** `716bce14e` on `main`

[PR #996](https://github.com/BeamLabEU/phoenix_kit/pull/996) — Fix /sitemap.html answering 500 on a site mounted at the root (`timujinne`). Reviewed the merged diff and current surrounding code, including subsequent merges.

Reviewed the redirect action and root, ordinary-prefix and nested-prefix regressions. `PhoenixKit.Modules.Sitemap.Router.get_path/1` builds a local path suitable for `redirect(to:)`; root now becomes `/sitemap.xml` instead of an external redirect to a relative address.

No additional findings. Existing tests exercise the controller response and Location header for all three mount shapes.

## Validation

See the [batch validation record](../2026-10-30-recent-merges/CODEX_REVIEW.md). This PR is reviewed individually; validation is shared across the interacting changes.
