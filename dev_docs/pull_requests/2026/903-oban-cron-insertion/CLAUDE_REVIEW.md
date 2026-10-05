# PR #903: Fix phoenix_kit.update skipping Oban cron entries when the crontab ends in a comment

**Author**: @timujinne
**Reviewer**: Claude
**Status**: ✅ Merged
**Commit**: `0c68bb4a0` … `2f2dc5c00` (8 commits)
**Date**: 2026-10-05

## Goal

`mix phoenix_kit.update` backfills cron entries, plugins and queues into a host's `config :app, Oban` block by
text. Every splice read the tail of the *source text* as the tail of the *list*, so a comment after the last
tuple put the separating comma inside the comment, the candidate stopped parsing, `ConfigVerify` rolled it
back, and the host got a one-line "please add manually" in the middle of a long run. On a real host that left
out `Jobs.SweepWorker`, `Jobs.PruneWorker`, `BucketLogPruneWorker` and `LoginAttemptsPruneWorker` — without the
sweeper a job run whose batch died is never recovered, which the Jobs page promises `mix phoenix_kit.update`
installs.

## What was changed

| File | Change |
|---|---|
| `lib/phoenix_kit/install/config_splice.ex` (new, 1329 lines) | Masks comments and string/sigil/heredoc/char-literal bodies byte for byte, finds the block and list on the masked copy, appends after the last real token on the original; tree helpers (alias resolution, Oban 2.24 renames, duplicate detection) |
| `lib/phoenix_kit/install/oban_config.ex` | Every list splice (worker, digest, scheduled-jobs entries, Cron plugin, Lifeline, queues) goes through `ConfigSplice`; presence/declined read from the app's own block; manual steps collected into one summary |
| `lib/mix/tasks/phoenix_kit.update.ex` | `finish_update/1` prints the "Manual steps needed" block after the migration/asset output, also when the run raises; the success line says so when steps are pending |
| `lib/phoenix_kit/install/config_verify.ex` | `emit_warnings: false` on the parse |
| `test/phoenix_kit/install/oban_cron_insertion_test.exs` (new), `oban_config_test.exs` | 205 new tests; 15 lines adjusted |

## Verification

- **The bug reproduces on main and is fixed by the PR.** A crontab whose last tuple has no comma, followed by
  a comment block: main refuses ("Could not safely add worker cron entries… Please manually add" ×5), the PR
  adds all five after the last tuple, keeps the commented-out lines below them, and the file parses.
- **No behaviour change on ordinary configs.** Ran `ensure_worker_cron_entries/2` + `ensure_digest_cron_entries/2`
  in memory against all 16 real host `config/config.exs` files in the workspace on both trees: output is
  byte-identical on every one (14 changed by the backfill, 2 already current).
- **Extra adversarial shapes** (own probes, beyond the PR's battery): no trailing comma, trailing comma +
  comment, end-of-line comment containing `]`, a string holding `# ]`, a `~w(a b])` sigil and `?]` char literal
  before a tail comment, a heredoc argument containing `]]]`, a CRLF file, an empty `crontab: []`. Every case
  parses, adds the entries, leaves the neighbouring `config :my_app, :other` untouched and is idempotent on a
  second run.
- `mix test test/phoenix_kit/install test/mix`: 8 doctests, 684 tests, 0 failures (the count the PR states).
- `mix precommit` on the PR head: exit 0 (compile with warnings as errors, `credo --strict` no issues,
  dialyzer passed, JS tests 254 pass).
- The branch merges into main without conflicts, and main had not touched any of the six files since the
  branch point.

## Findings

No bugs.

**IMPROVEMENT - MEDIUM** — The fix is a 1.3k-line hand-written lexer plus a 2.7k-line test file for what is
at its core a misplaced comma. It is acceptable because every write passes four independent checks (balanced
brackets on the masked copy, the candidate parses, the new entries are direct members of the intended list,
and the candidate minus the new entries parses to exactly the host's original tree) plus the duplicate net,
and any miss refuses and leaves the file alone — a refusal costs the host a manual step, never a corrupted
config. A structural, comment-preserving edit (Sourceror/Igniter AST zipper) would remove the lexer; I did not
evaluate whether it keeps comments and spacing well enough here. Left as is; worth revisiting only if the
masker needs another round of fixes.

**NITPICK** — The manual-steps and declined-entries state lives in the process dictionary
(`ObanConfig.record_manual_step/2`, `take_manual_steps/0`). It works because the Oban pass and the closing
summary run in the Mix task's own process, and the unit tests cover the summary-after-raise path. I did not run
`mix phoenix_kit.update` end to end on a host copy; the PR describes doing so each round. If Igniter ever
moves the config pass to another process, the summary would silently come out empty.

**NITPICK (behaviour change, documented)** — A declined entry (a crontab line commented out) now counts only
when the comment is **inside the Cron plugin's `crontab:` list**; previously a comment naming the worker
anywhere in the file suppressed the entry. A host that declined an entry with a comment outside its crontab
will get the entry offered again. Recorded in the CHANGELOG entry.

## Outcome

Merged as is (merge commit, history preserved). Nothing to fix in the PR.
