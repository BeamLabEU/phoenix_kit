# Instructions

Task-specific instructions written for AI agents or developers to execute a defined change across the codebase. These are operational documents — they tell you exactly what to find and what to change, rather than explaining why a system works the way it does.

## When to Add a File Here

- A mechanical but large-scale refactor that needs precise step-by-step instructions
- Instructions produced after an analysis to guide the follow-up implementation work
- Agent prompts or checklists for codebase-wide pattern changes

## Files

| File | What It Covers |
|------|---------------|
| `2026-02-16-uuid-parameter-rename-instructions.md` | Instructions for renaming UUID parameters to the `_uuid` suffix convention and adding hard errors on integer inputs — produced after PR #340 completed the schema migration |
