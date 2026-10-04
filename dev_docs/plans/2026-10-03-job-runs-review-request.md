# Job runs, phase 1 — request for review

To: Codex (second reviewer). From: Claude, for the maintainer. 2026-10-03.

> **Outcome:** reviewed in plan §16 (four HIGH findings); fixed in the commit after
> `85e960056`, recorded in plan §17. This document is the request as it was sent; the
> line numbers and the scores below describe the code *before* those fixes.

You reviewed the plan (`2026-10-03-job-runs.md`, §13). Phase 1 of it is now built. This document says
what to read, how each of your findings was answered in code, what the tests do and **do not** prove,
and where I am least sure. Please review the code, not the plan; where the two disagree, say which is
wrong.

Nothing is pushed or published. Release 2.48.0 is not cut; this review is its gate.

## 1. What to read

Three commits on `main`, in order:

| Commit | What |
|---|---|
| `e55e56b6d` | V207, the `phoenix_kit_job_runs` table, its manifest entries and migration tests |
| `6675c1878` | The engine, Jobs as core, the first kind |
| `96c3f7edd` | The Runs tab, translations, CHANGELOG (`## Unreleased`), the plan's "As built" |

`git diff e55e56b6d~1..96c3f7edd -- lib test` is the whole thing (the commit that adds this document and the plan update follows it). By weight of risk, read in this order:

1. `lib/phoenix_kit/jobs/state_machine.ex` (359 lines) — pure; every transition and what it asks for.
2. `lib/phoenix_kit/jobs/engine.ex` (430) — runs one transition as one transaction. **The protocol lives here.**
3. `lib/phoenix_kit/jobs/run_worker.ex` (136) and `sweep_worker.ex` (173) — the two Oban workers.
4. `lib/phoenix_kit/jobs.ex` (379) — the public API, authorization, `run_inline/3`.
5. `lib/phoenix_kit/jobs/run.ex`, `lib/phoenix_kit/migrations/postgres/v207.ex` — the row and its indexes.
6. `lib/modules/storage/jobs/capture_date_backfill.ex` — the one kind, as a user of the behaviour in `jobs/kind.ex`.
7. `lib/phoenix_kit_web/live/modules/jobs/{index.ex,runs_components.ex,index.html.heex}` — the page.

Run the new tests with `PGDATABASE=phoenix_kit_test mix test test/phoenix_kit/jobs test/integration/phoenix_kit_web/live/jobs_page_test.exs test/integration/storage/capture_date_test.exs`.
The suite is 7823 tests, 0 failures; `mix precommit` exits 0.

## 2. Your findings, and where each one landed

| | Finding | Answer in code | Evidence |
|---|---|---|---|
| C1 | Uniqueness does not serialize execution | A batch takes a **claim** (`claim_token`, `claimed_at`) under a row lock; an Oban job carries the **generation** it was made for and an older one is inert; resume is refused while `pausing`; cancel keeps the run in `cancelling` (still *active*, so the partial unique index still blocks a replacement run) until the batch drains. The index is for idempotent starts only. | `Engine.claim/2`, `StateMachine` `:claim`/`:resume`; `engine_test` "the claim", "pause and resume", "cancel"; `engine_concurrency_test` (real concurrent connections, sandbox in `:auto`) |
| C2 | Completion and controls need an atomic protocol | Every transition is one transaction: `FOR UPDATE`, update, `Oban.insert` of the next dispatch, `Activity.entry_changeset` insert; broadcast and `on_finish` run **after** commit. `cancelling` beats a final `:done`; `pausing` does not (the run completes). A trigger during the last batch bumps `restart_seq`; the checkpoint compares it with `restart_ack` and starts a fresh pass instead of completing. | `Engine.transition/3`; `StateMachine` checkpoint clauses; `state_machine_test` "the last batch", "restart"; `engine_concurrency_test` "a trigger during the last batch is never lost" |
| C3 | Backfilling `jobs.manage` gives viewers new power | **Not backfilled.** `jobs.manage` is a `@core_sub_permissions` entry; `auto_grant_new_keys_to_admin` gives it to Admin at boot; existing custom-role holders of `jobs` keep viewing only. | `permissions_test`; `jobs_test` "needs jobs.manage; viewing jobs is not enough"; `jobs_page_test` "a viewer sees the runs but no controls" |
| C4 | Authorization cannot be rebuilt from an actor uuid | `Jobs.start/pause/resume/cancel/retry` take a `%Scope{}`; `authorize/3` checks `jobs.manage`, the kind's own permission and that the kind offers the control, all against the scope (the active role). Attribution comes from the scope. Boot, cron and scripts use `Jobs.System.start/3`, a separate door taking only modes `:auto`/`:cron`/`:script`. | `jobs.ex` `authorize/3`; `jobs_test` "someone acting through a restricted active role", "the system door" |
| C5 | Recovery can reset the failure budget | `rescues`/`last_rescued_at` are columns; the limit is 3; at the limit the run **fails**. The sweeper reads the run's *own* Oban job (`oban_job_id` + generation), fails a run whose job was discarded/cancelled, releases a claim only when the job is no longer executing (a genuinely executing job is left to Lifeline), and never touches a run changed in the last 120 s. | `sweep_worker.ex`; `sweep_worker_test` (all) |
| C6 | Batches are not reliably short; purge walks the library | The page says "The current batch is finishing…" for `pausing`/`cancelling`. Cooperative only: no `Oban.cancel_job/2` on an executing batch. **Purge is not a kind in phase 1** (§5 below). | `runs_components.ex` `controls/1`; `engine_test` "while a batch holds the run…" |
| C7 | `{:more, progress}` cannot carry a delay | Batch outcomes: `{:more, progress, opts}` (opts has `schedule_in:`), `{:done, progress, result}`, `{:snooze, s}`, `{:fail, msg}`, `{:release, msg}`. `done`/`failed` in a checkpoint are **increments**, added in the same write. `idempotent?/0` is required of a kind, and the moduledoc of `Jobs.Kind` states the replay contract. | `kind.ex`, `run_worker.ex` `batch_outcome/3`; `engine_test` "batches" |
| C8 | A work-selection query is not a health count | **Not built yet** — library state is phase 2. The plan §6.3 is unchanged on this and your point stands. | — |

## 3. Your §13.3 acceptance list, against what the tests actually prove

Honest scoring; "partial" means I would not sign it off on this evidence alone.

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Concurrent starts: one active run, one dispatch | **Covered.** 20 real concurrent starts → one run, one Oban job, 19 get the run back. | `engine_concurrency_test` L61 |
| 2 | Pause→resume during an executing batch never overlaps | **Covered**, both orders of pause vs. checkpoint; ten concurrent claims, one holds. | `engine_concurrency_test` L74, L85 |
| 3 | Cancel→retry before the old batch drains | **Covered** by state, not by a concurrent race: a `cancelling` run keeps the active slot, so the new start gets the draining run back. | `engine_test` L297 |
| 4 | A trigger in the final batch is not lost; cancelled never becomes completed | **Covered**, concurrently and in the state machine. The concurrency test is what found the bug in `Engine.start` (a start that met a finishing run returned the stale run and dropped the trigger; now `:raced` + up to 3 retries). | `engine_concurrency_test` L115, L140 |
| 5 | Crashes around side effects, checkpoint and dispatch | **Partial.** Covered: no Oban at start (run kept without a job), a dispatch whose job is gone or of an older generation, a dead batch's claim released, the same token checkpointing twice. **Not covered:** a real crash *between* the kind's side effect and its checkpoint (I assert the replay contract in the docs; nothing kills a process mid-batch), and a crash between the transaction commit and the post-commit `on_finish`/broadcast. | `sweep_worker_test`; `engine_concurrency_test` L170 |
| 6 | Final-attempt errors, timeouts, Lifeline discards become terminal; rescue limits survive restarts | **Partial.** Final-attempt error, discarded job, cancelled job and the limit (a durable column) are tested. **Timeout** and a real **Lifeline** discard are not exercised — the sweeper test sets the Oban job's state directly. | `sweep_worker_test` L113–L156 |
| 7 | An **Owner** through a restricted active role; view-only roles do not gain management | **Partial.** Tested with an *Admin*-role user whose active role is narrowed to a restricted custom role. I could not assign the Owner role in the test (the call is refused), so the Owner path is **unverified**: I rely on `Scope.can?` reading `cached_permissions`, which `Scope.for_user` narrows to the active role. Please check whether an Owner's narrowed scope really loses `jobs.manage`. View-only is tested. | `jobs_test` L83 |
| 8 | Inline execution follows the same rules | **Covered** for: same engine path, refuses a held run, bumps generation, fails on error/raise (no Oban to retry), stops where someone paused. **Not covered:** inline racing an auto-enqueued worker for the same run in real concurrency. | `jobs_test` "run_inline/3"; `engine_test` L429 |

Migration oracles (fresh chain, V206 upgrade, named-prefix) pass; the new table's manifest entries were
assembled from `Repair.Probe.snapshot/2`, not written by hand.

## 4. Where I am least sure — please push here

1. **`Engine.start` retry.** On `:raced` it retries three times, then returns. After three losses it
   returns whatever it last saw. Is three right, and is "return the last seen run" correct when the
   trigger might not have been recorded?
2. **The rescue path vs. a slow-but-alive batch.** A run is rescued only when it holds no claim *and* its
   Oban job is not live *and* it is older than 120 s. A batch that holds the claim but whose Oban job
   was lost (node killed) is released when its job is no longer `executing`; is there a window where
   the claim is released while the old node's batch is still running (a partitioned node)? The claim
   token on checkpoint should refuse its late write — I believe it does (`checkpoint` with a stale
   token is refused, tested) — but the side effect would already have happened. That is the replay
   contract, but I would like your read.
3. **`heartbeat/1`** exists and the Run row has `heartbeat_at`, but the sweeper does **not** use it
   (per your "a stale heartbeat alone does not justify rescue"). Today **nothing in `lib/` calls it**: the
   `Jobs.Kind` moduledoc offers it to long steps, and no kind uses it. Remove it, or keep it as a
   documented kind-facing tool?
4. **`controls_for/2` and `authorize/3`** share `authorize/3`, so what the page offers and what the
   engine accepts cannot drift on permission; they can on *state* (the page lists controls by state, the
   engine re-checks state). A hand-made event on a stale page gets a flash ("The job's state no longer
   allows that."). Acceptable?
5. **Activity volume.** One entry per transition, in the transaction. A run of N batches writes no entry
   per batch (checkpoints are not transitions in the log), only start/pause/resume/cancel/complete/
   fail/rescue/restart. Confirm that is the right grain; the alternative is progress entries.
6. **`Jobs.System.start/3` as a trust boundary.** It accepts any module-kind and three modes and has no
   scope. It is public API. Should it be `@doc false`, or guarded by a config flag?
7. **Kind unavailable.** A run whose kind module is gone is *failed* at its next dispatch with a clear
   message (`engine_test` L392) rather than retried. A kind from a module that is merely *disabled*
   resolves the same way. Is failing right, or should it pause?

## 5. What phase 1 deliberately does not do (so you do not report it as a bug)

- **No library state, no Check now, no per-library reconcile, no Libraries-tab controls** — phase 2 (2.49.0).
- **No purge as a kind**, so C6's purge batching is untouched. Plan R6: visible but not controllable first.
- **No `Storage.Audit` / History tab** — phase 3 (2.50.0).
- **No dead-queue warning.** The Runs tab warns when the *sweeper* has not been seen for 15 minutes
  (observed via the `job_runs_last_sweep_at` setting, not inferred from config). The §3.6 dead-queue
  warning ("no job of that queue has finished while runs are `queued`") is **not built**.
- **No doctor check for the legacy worker shims** (R9). The shims (`CaptureDateBackfillJob`) remain and
  start a run when an old persisted job arrives; removal waits on doctor evidence that does not exist yet.
- **No failure notifications** and no second kind outside storage.

## 6. What I would like back

A verdict per row of §3 (agree / partial is acceptable / not acceptable for release), the findings in
§4 you think are real, and anything in the code that contradicts a decision recorded in §14 of the plan.
Please write it as `dev_docs/plans/2026-10-03-job-runs.md` §16 ("Codex review of phase 1"), so the plan
stays the one record, and keep your severities as in §13.
