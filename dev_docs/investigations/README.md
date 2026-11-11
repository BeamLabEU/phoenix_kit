# Investigations

Deep-dives into specific bugs or failure modes. These documents diagnose a problem in detail — root cause, reproduction path, affected code, and the chosen fix. They serve as a record of non-obvious issues so the same problem isn't re-investigated later.

## When to Add a File Here

- A bug with a non-obvious root cause that required significant investigation
- Silent failure or data loss scenario that needed careful tracing
- A class of problem that could recur in similar code

## Files

| File | What It Covers |
|------|---------------|
| `2026-02-21-liveview-form-error-handling.md` | Investigation into LiveView form save handlers silently swallowing errors and causing data loss — root cause, affected patterns, and the correct fix |
| `2026-07-27-missing-form-id-audit.md` | 26 `phx-change` forms shipped without an `id`, silently disabling LiveView form recovery — why the reporter's `grep` found only 12, why `<.form for={%{}}>` is affected too, and the detection rule that replaces the grep |
| `2026-11-11-lib-file-count-growth.md` | Why `lib/` grew from 596 to 963 files between 1 September and 11 November 2026 — per-directory and per-week breakdown, the longer history (the March peak, module extraction, the August squash), file sizes, and the growth of `test/` and `dev_docs/` |
