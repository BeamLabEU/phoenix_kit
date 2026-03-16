# PR #412 — Publishing Module Overhaul

**Author:** Max Don (mdon)
**Base:** dev
**Stats:** +7,090 / -3,284 across 82 files, 99 commits

## What

Major refactor of the Publishing module: breaks monolithic `publishing.ex` (2,078 lines removed) into focused submodules, adds inline status controls, skeleton loading, trash management, clear translation, mobile responsiveness, and data integrity fixes from two security audits.

## Why

The Publishing module had grown into a single monolithic file making maintenance difficult. Additionally, missing features (trash, inline status, mobile UI) and security gaps (trashed posts publicly accessible) needed addressing.

## Key Changes

- **Architecture:** Facade pattern — `publishing.ex` delegates to `Groups`, `Posts`, `Versions`, `TranslationManager`, `StaleFixer`, `Shared`
- **Inline status control:** Change post status directly from listing page dropdown
- **Skeleton loading:** Deferred message pattern for tab/language switches
- **Trash management:** Soft-delete for groups/posts, hard-delete empty posts, restore flow
- **Clear translation:** Hard-delete content rows from editor sidebar
- **Public security:** Trashed posts excluded from all public queries, fallback to group listing
- **WebSocket fix:** Transport cache clearing to prevent permanent longpoll fallback
- **Mobile responsive:** Icon-only buttons on small screens
- **Migration V83:** Adds `status` column to `publishing_groups` table

## Related PRs

- Previous: [#397](/dev_docs/pull_requests/2026/397-publishing-editor-ux-translation) — Editor UX
- Previous: [#408](/dev_docs/pull_requests/2026/408-publishing-sync-legal-i18n) — Sync/Legal/i18n
- Follow-up: [#416](/dev_docs/pull_requests/2026) — Constants consolidation (already merged)
