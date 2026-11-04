# PR #1009 — Fix repair creating a duplicate of an index or key constraint that exists under another name

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve with fixes; one bug fixed

`Repair.Equivalence` looks for an object of the declared structure under another name. A twin is
reported as `:equivalent_under_another_name`, nothing is created, and the version cross-check counts it
as present.

## Checked and sound

- **No path reaches `ctx.twins` without it being set.** `presence_missing_finding/4` is reached only
  through `apply_scope/7`, and all three callers (`run_adopt`, the standard run, `run_module_manifest`)
  go through `assign_twins/5` first. The nil clause (a manifest that cannot be read) sets `%{}`.
- **`Probe.lookup/2` copes with every `check`.** A non-catalog check returns nil, and `find/4` falls
  through to its last clause, so a seed is never given a twin.
- **An index backing a constraint is out by construction.** `partition_index_row/2` puts it in
  `constraint_backed_indexes`, and `find/4` reads `snapshot.indexes` only.
- **The one-to-one rule holds across passes.** `taken` is threaded core -> module -> module. The
  cross-check uses plain `declared_names`, which gives the same answer because core is assigned first.
- **`columns_part/2` fails safe.** A qualifier or table it cannot read returns `:error`, which is "not a
  twin", so a real absence stays `:missing`.
- **The new finding kinds need no other wiring.** `Report.summary/1` and the task's breakdown count
  `finding.kind` generically, and `:info` does not touch the exit code or `floor_verify_clean?`.

## Findings

### BUG - MEDIUM — an invalid index counted as a twin, so the real one was never built (fixed)

`Probe` did not read `pg_index.indisvalid`, and the moduledoc listed "validity of an index" among the
things not compared. An index left invalid by a failed or cancelled `CREATE INDEX CONCURRENTLY` keeps a
perfectly good catalog shape, so it matched `Differ.compare/3` and the definition check. Repair then
reported "equivalent under another name; not created".

This is a regression from this PR. Before it, the declared index read as `:missing` and repair built it.
After it, the host has no usable index (the planner never uses an invalid one), repair stays quiet, and
the note tells the operator to rename the broken index to the declared name. That also makes the broken
index "found by name", where no repair can ever replace it.

Being documented does not settle it: the same moduledoc's "Rules that keep a real loss from being hidden"
is the contract, and this hid one. Found by name, validity is a separate question, because repair could
not build the index anyway. As a twin, structure is the only identity, and the object has to be able to
do the declared object's job.

Reproduced on a real catalog: two rows of one owner, then `CREATE UNIQUE INDEX CONCURRENTLY` fails and
leaves the index behind. `Repair.verify/1` reported `:equivalent_under_another_name`.

Fix: `Probe` reads `i.indisvalid` into the index shape as `valid`, and `Equivalence.find/4` skips an
invalid candidate. `Differ` compares named fields, so the extra key changes nothing found by name, and
the manifest generator reads `Squash.Generate.Catalog`, not `Probe`, so no manifest moves. The moduledoc
now states the rule.

Tests: `test/integration/repair_test.exs` (a real invalid index, `UniqueIndexManifest`; this one failed
before the fix) and `equivalence_test.exs` (a valid twin matches, an invalid one does not).

Key constraints keep the PR's rule on purpose. A `NOT VALID` foreign key still checks every new row, so
it is not a lost constraint, and repair's own path creates foreign keys `NOT VALID` first.
