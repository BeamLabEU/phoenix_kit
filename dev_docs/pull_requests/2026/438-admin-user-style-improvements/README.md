# PR #438 — Improve admin and user styles

**Author:** construct-d
**Base:** dev
**Date:** 2026-03-20

## Summary

UI/layout refinements across admin and user dashboard pages. Two commits: admin styles and user dashboard styles.

## Changes

| File | What changed |
|------|-------------|
| `user_settings.ex` | Removed outer `card`/`card-body` wrapper and `h1` title — component now renders flat `<div>` so the parent page controls layout and heading |
| `dashboard/settings.ex` | Replaced `max-w-6xl mx-auto` with `p-6`, added `admin_page_header` component with back link, removed dev mailbox notice positioning |
| `dashboard.html.heex` | Removed `max-w-6xl mx-auto` wrapper from main content area — content now fills available width |
| `media.html.heex` | Changed admin media page container from `p-6` to `container flex-col mx-auto px-4 py-6` |
