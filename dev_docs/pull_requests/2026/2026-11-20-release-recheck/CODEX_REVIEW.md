# Review since PhoenixKit 3.6.1

Compared release tag `v3.6.1` with `6fc0bb7b6` on main. The range includes PRs #1037–#1050, the per-viewer menu badges, dependency updates, and post-merge corrections. The individual PR records cover the original reviews. This pass checked the combined changes against the release baseline.

## Findings fixed

- **BUG - MEDIUM, provider sign-in (#1050).** A failed decryption produced a present settings key with a nil value. The direct credential reader passed nil through, and the provider checks accepted it because they compare with the empty string. Direct reads now use the same missing credential value as cached reads. The database regression confirms that corrupting a previously working secret removes the provider from eligibility.
- **BUG - MEDIUM, sitemap scheduling (#1044).** A queued manual regeneration could suppress boot recovery and could be deleted when scheduling was disabled. The schedule queries now select recurring jobs. Oban also deduplicates pending recurrences, so repeated requests for the next run produce one job. The integration test queues a manual run first and checks recovery, repeated inserts, status and cancellation.
- **BUG - MEDIUM, local media storage.** During the baseline suite a stalled thumbnail copy occupied the Erlang file server. A separate thumbnail size timed out waiting to check whether its object existed and was omitted from the linked copy. Local existence checks now use the filesystem directly. The existing named-pipe regression exercises this path.
- **BUG - MEDIUM, image sets (#1038).** Both components of an aspect ratio could parse as numbers while their quotient overflowed. The ratio check now runs in a guard, so an unrepresentable quotient falls back to natural image widths. The component test covers a ratio passed as a string.
- **BUG - MEDIUM, overlay sizing (#1049).** The bottom of a scrolling element's border box includes its border and horizontal scrollbar. The height hook now measures to the bottom of the scrollport. The DOM regression distinguishes the two geometries.
- **Test reliability.** The media-gallery test used ExUnit's 100 ms default for a reply that follows an asynchronous LiveComponent update and database reads. It now allows one second for that reply and still asserts the exact selection.

## Release considerations

The opt-in offline annotation feature still retains local copies after sign-out, as recorded in the review of #1047. Hosts using shared devices should take this into account before enabling it.

The release metadata still points to the published 3.6.1 tag. Version selection, the dated changelog entry and the final packaging gate belong to the release cut.

## Verification

- The baseline PostgreSQL run found two failures, in the external picker and local storage copy tests. A fresh database migrated through V234. Repeating the full suite with seed 759714 yielded 16,190 tests and 99 doctests with zero failures, 34 skipped and one excluded because the database role lacks CREATEROLE. The local-storage change landed during that rerun and was independently verified against all 40 link-copy tests and seven consecutive executions of the timeout regression.
- The final `mix precommit` passed, including strict Credo, Dialyzer and 937 JavaScript tests. Both dependency audits passed. The built Hex package passed the generated-content check, and the release checker verified the migration chain and manifest hash.
