# Claude Review — PR #1045

**Reviewer:** Claude Opus 5.5
**PR:** Update fresco to 0.17, etcher to 0.29, tessera to 0.3.12 and leaf to 0.13 (alexdont)
**Reviewed:** 2026-11-19 (merged into `main` in the 2026-11-19 PR sweep)

## Verdict

Dependency-only. Merged as is. No findings.

## Checked

- The four lock entries move together (`etcher 0.29.0`, `fresco 0.17.0`, `tessera 0.3.12`,
  `leaf 0.13.2`). No transitive surprises in `mix.lock`.
- The floors move in step: tessera 0.3.12 is the first that admits fresco 0.17, and etcher 0.28+
  is the first that admits fresco 0.17. Each `mix.exs` comment says why its floor is where it is.
- `leaf` keeps its `or`-chained, closed-ceiling requirement (`~> 0.13.0`), per the comment
  above it: `phoenix_kit.js` loads leaf's browser half from the host's copy.
- #1047 relies on the etcher floor (it calls `Etcher.offline_worker/0`).
