# Claude Review — PR #782

**Title:** Fix two duplicate/hreflang defects in multi-domain sitemaps
**Author:** timujinne
**Head commit:** 3ef2174a
**Verdict:** Approve — two IMPROVEMENT-HIGH findings raised in review, both applied in the branch

## Summary

Two defects in `DomainMode`, both found on a live three-domain install
(en primary + de + fr) by comparing the generated per-host sitemaps against
what the rendered pages actually emit:

1. A canonical-path group containing a single language still received a
   self + `x-default` hreflang pair whenever that language was the primary
   domain's. The page-level builders already drop an under-2-entry set as
   noise and emit nothing, so the sitemap advertised an alternate set the
   page's own `<head>` never backed up.
2. One host's file could list the same `<loc>` twice. A locale-prefixed clone
   route (`live "/de"` on the home LiveView, so `/de` does not 404 on a prefix
   install) is discovered by `RouterDiscovery` with no `canonical_path`, so it
   forms its own group; re-hosting strips the prefix and lands it on
   `https://<de-host>/`, where the static source has already placed that
   domain's home. The two groups cannot merge, so the home appeared twice —
   once with the full cross-domain alternates, once bare.

## Review scope

Read in full: the diff against `a9a66190` across `domain_mode.ex`,
`generator.ex`, `url_entry.ex` and `domain_mode_test.exs`; plus the
surrounding `rebuild_for_domains/2` → `domain_entries/5` →
`group_alternates/4` path, `extra_for_primary/5`, `domainless_entries/4`,
`home_url/5`, and the pre-existing dedup in `generator.ex`.

Specifically checked and found correct:

- **The guard does not drop URLs.** `loc` and `alternates` are computed
  independently in `domain_entries/5`; an emptied alternate list still emits
  the entry.
- **Single-language non-primary groups.** These previously produced a lone
  self-reference. A one-entry hreflang set is not a set, so returning `[]`
  for them is a correction, not a regression.
- **Domainless languages survive.** `extra_for_primary/5` filters against
  `taken` before dedup runs, so an own-language entry and a domainless entry
  cannot collide into a loss.
- **Sort order.** Non-primary hosts were sorted inside `domain_entries/5`,
  the primary after concatenation; both now sort by `loc` on the same key
  after dedup, which makes the order strictly total rather than changing it.
- **Priority parsing.** `priority` arrives as float, string, or nil depending
  on the source; the shared ranking reuses `UrlEntry.parse_priority/1` and
  falls back to `0.0` rather than raising on an unparseable value.

## Findings

### IMPROVEMENT - HIGH — the guard silently voided an existing assertion (applied)

`test/integration/sitemap/domain_mode_test.exs` — the test "untranslated group
appears only on its language's domain" pinned rule m2 (never mislabel another
language as `x-default`, stated in the `DomainMode` moduledoc) with
`refute Enum.any?(fr_entry.alternates, &(&1.hreflang == "x-default"))`.

That group is single-language, so after the new guard `alternates == []` and
the `refute` passes against an empty list — vacuously, for a reason unrelated
to what it claims to test. Proven by mutation: making `group_alternates/4`
append an `x-default` on the `nil -> links` branch (i.e. violating m2 outright)
left the suite fully green.

Applied: that test now asserts the empty list it actually exercises, and a new
test pins m2 with a genuine two-language group carrying no primary-language
entry, so the `refute` is meaningful again.

### IMPROVEMENT - HIGH — a second dedup policy beside the one already shipped (applied)

The branch introduced a local `dedup_by_loc/1` in `DomainMode` ranking
candidates by alternate count, then priority, then arrival order. `Generator`
already carried `dedupe_by_loc/1` + `entry_richness/1` solving the same
problem, with a comment describing this very scenario, and with one rule the
new implementation did not reproduce: a `RouterDiscovery` entry scores `0` and
therefore **always** loses a same-`loc` collision, regardless of its own
priority. A ranking that compares only alternates and priority would let a
route-discovery entry win as soon as it happened to carry either.

Applied: the policy moved to `UrlEntry.dedupe_by_loc/1` +
`UrlEntry.richness/1`, and both `Generator` and `DomainMode` now call it. The
duplicate implementation and its private priority parser were removed rather
than kept in parallel.

## Verification

- `mix test test/integration/sitemap/` — 77 tests, 0 failures.
- Full suite: 43 doctests, 4388 tests, 0 failures.
- `mix format --check-formatted` clean on all touched files.
- **Mutation-proven, one failure each, green after restore:** violating m2 in
  `group_alternates/4` fails the new m2 test; removing the dedup call from
  `rebuild_for_domains/2` fails the duplicate-home test.
- Confirmed against the live three-domain install by regenerating: the
  duplicate home is gone from both non-primary domains (639 → 638 URLs each,
  primary unchanged at 643); untranslated URLs carry no hreflang block,
  matching their rendered pages; fully translated URLs keep their complete
  de/en/fr/x-default sets pointing at the correct per-domain translated slugs;
  and the surviving home entry is the rich one (priority 0.9 with the full
  alternate set), not the bare clone.

## Not done here

`@version` and `CHANGELOG.md` are deliberately left untouched for the
maintainer.
