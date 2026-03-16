# Follow-up Items for PR #412

Post-merge issues and improvements discovered during review.

## Fixed (Batch 1 — commit 7f8af650)

- ~~**#1** StaleFixer hard-deletes freshly created posts~~ — Added 5-minute grace period
- ~~**#2** `@endpoint_url` nil crash during dead render~~ — Default to `""` instead of `nil`
- ~~**#3** Audit metadata not written on post updates~~ — `audit_meta` now flows through to `DBStorage.update_post/2`
- ~~**#4** XSS risk in media URL insertion~~ — `file_url` now JSON-encoded
- ~~**#9** `find_available_timestamp` race condition~~ — Moved inside the transaction

## Fixed (Batch 2 — commit 09b58b6e)

- ~~**#5** `published_at` set on draft creation~~ — Set to `nil` for new drafts
- ~~**#6** `fix_all_stale_values` runs sub-fixers twice per post~~ — Removed duplicate calls
- ~~**#7** `publish_version` skips title validation~~ — Added `validate_primary_title!` in transaction
- ~~**#10** `should_regenerate_cache?` always returns true~~ — Simplified to `def should_regenerate_cache?(_), do: true`
- ~~**#11** i18n bug in persistence error messages~~ — Wrapped all raw strings in `gettext`
- ~~**#13** `Task.start` should use Task.Supervisor~~ — Added `PhoenixKit.TaskSupervisor` to supervision tree

## Remaining — Logic Issues

### 8. `set_translation_status` contradicts `fix_translation_status_consistency`
- **Where:** `translation_manager.ex:251-274` vs `stale_fixer.ex:518-542`
- **What:** Manual translation status overrides are silently reverted by the stale fixer.
- **Fix:** Add a `manually_overridden` flag to content rows, or document that translation status always follows primary.
- **Decision needed:** Is manual override a real use case, or should translation status always follow primary?

## Fixed (Batch 3 — dedup, performance, dead code)

- ~~**#12** Duplicated functions (`fetch_option`, `audit_metadata`, `db_post?`)~~ — All delegate to canonical locations (`Shared`, `Posts`)
- ~~**#14** Missing `restore_post` in facade~~ — Added `Posts.restore_post/2` + facade delegation, listing.ex uses it
- ~~**#15** Unused `build_redirect_url_from_slugs`~~ — Removed
- ~~**#16** `handle_localized_request/3` and `handle_non_localized_request/3` identical~~ — Merged into `handle_request/3`
- ~~**#17** `get_group/1`, `get_group_mode/1`, `group_name/1` load ALL groups~~ — Direct `DBStorage.get_group_by_slug/1` queries
- ~~**#19** `list_times_on_date` filters in Elixir~~ — Added `:date` opt to `DBStorage.list_posts_timestamp_mode/3`
- ~~**#20** Fallback controller loads all posts for single lookups~~ — Uses `DBStorage.read_post/2` and `read_post_by_datetime/3`

## Remaining — Code Quality

### 16b. `find_cached_post/2` duplicated between `PostRendering` and `Translations`
- Not addressed in Batch 3 (separate concern from the controller dedup).

## Remaining — Performance

### 18. `StaleFixer.fix_all_stale_values/0` N+1 queries
- Nested loops without preloading — thousands of queries for moderate-size sites.

## Remaining — Testing

### 21. Zero coverage for controller submodules
- `Routing`, `Language`, `SlugResolution`, `PostRendering`, `Listing`, `Translations`, `Fallback`
- These contain pure logic testable without DB.
