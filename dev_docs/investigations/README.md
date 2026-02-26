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
