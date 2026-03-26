# PR #430 — Fix migrations ensure required applications started before repo

**Author:** construct-d
**Base:** dev
**Date:** 2026-03-18

## Summary

Fixes migration failures when required OTP applications aren't started before `repo.start_link/1`. Adds explicit `Application.ensure_all_started/1` calls for `:telemetry`, `:db_connection`, `:ecto`, and `:postgrex` in `do_start_repo/1`.

## Changes

| File | What changed |
|------|-------------|
| `lib/phoenix_kit/migrations/postgres.ex` | Added 4 `Application.ensure_all_started/1` calls before `repo.start_link(config)` in `do_start_repo/1` |

## Context

Without these calls, migrations can fail with errors like `** (exit) no process: the process is not alive` when DBConnection, Ecto Registry, or Postgrex SCRAM cache aren't started. This happens when migrations run outside the normal application boot (e.g., during `mix phoenix_kit.install` or standalone migration scripts).
