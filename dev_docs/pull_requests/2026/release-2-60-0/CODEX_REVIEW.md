# Codex review — release 2.60.0 (2026-10-09)

Scope: `v2.59.0..048af0864`, including the storage/detail-page split, repair and permanent audit trail,
V216 key layouts, Ukrainian catalogue and Publishing sitemap slugs (#919, #921). Independent recheck of
`CLAUDE_REVIEW.md`; that document is preserved. Version remains 2.60.0. No push, publication or tag is authorized.

## Findings fixed in this recheck

- **BUG - HIGH — contributor writes through the viewer.** Browser restrictions stopped its own events but
  were absent from the child viewer. A contributor could change another uploader's title, tags, EXIF or
  persisted rotation. The browser now passes uploader, library and visibility boundaries into the viewer;
  writes re-read the row and enforce all boundaries. The editor is hidden for unwritable files. Real LiveView
  coverage sends forged events to the nested component; separate coverage refuses a file in another library.
- **BUG - HIGH — storage repair without library edit access.** A library contributor/viewer with
  `media.manage` could read the storage page and run repair or regeneration on another person's file.
  Actions now require library edit access, with the current file reloaded and authorization checked on each
  event. The contributor regression also checks the storage page and a forged Fix event.
- **BUG - HIGH — regeneration overwrote shared rendition keys.** Repair, Make and Regenerate all used the
  ordinary rendition key even when another file referenced it, changing that file's served bytes without
  updating its checksum or metadata. Repair now uses a fresh key for rebuilt sizes. The common generation
  path compares the rendered checksum with every instance referencing the target key: changed bytes get a
  fresh key; identical bytes retain duplicate-upload sharing. Including this file's own reference protects
  an upload that clones it during generation. A real cross-user duplicate-upload regression checks both
  instance keys and the untouched old object; the earlier V205 sharing/reconciliation regression also passes.
- **BUG - HIGH — an unrecorded original was adopted without a checksum check.** Existence alone made it
  healthy on the first repair pass, so corrupted bytes could be used for regeneration. Unrecorded copies now
  go through the same checksum check as recovery from other buckets. A tampered original with its location
  row removed is refused and never reconciled.
- **BUG - MEDIUM — concurrent repair and stale edit state.** Repair now holds the reconciler's existing
  session advisory lock for the entire operation and reloads the file before checking for a pending image edit.
  Tests hold the lock from an independent PostgreSQL connection and use a stale pre-edit struct. Busy errors
  leave the storage page usable. A supervised, unlinked repair task survives the LiveView waiter exiting on
  navigation (Elixir Task.Supervised demonitoring after startup was checked); the existing page test exercises
  successful task delivery. A runtime check killed the waiter, then allowed the supervised task to finish,
  confirming its independent lifetime. This is not a durable queue: application/node shutdown still ends it.
- **BUG - MEDIUM — unsafe reconciliation and disabled targets.** Repair refuses writes to a disabled bucket
  but still permits reading an existing copy there. Failed, skipped, unreadable or unrecoverable actions prevent
  reconciliation, extending Claude's failed-restore fix. If a bucket could not be read, an original is not
  declared unrecoverable merely because the other copy is bad. Both cases have real provider regressions.
- **BUG - MEDIUM — unsuccessful attempts claimed repairs.** A permanent repair entry now requires an actual
  restore, regeneration or newly recorded copy; failures may accompany real changes. Repeated attempts on an
  unfixable original create no repair entries. Damage discovery remains auditable on each explicit verification.
- **BUG - MEDIUM — per-size downloads disappeared for ordinary Media users.** The viewer again offers the
  custom/annotated rendition URLs already authorized by the browser, retaining signatures/version query
  parameters and adding `dl=1`. It excludes the DZI manifest, cropped annotated thumbnail and retired stale
  annotation slot, as the old download list did. With no answer to the optional product question,
  existing Media capabilities were preserved. A real ordinary-user page test covers this.
- **BUG - MEDIUM — stale verification after generation.** Make and Regenerate all now discard verification
  results from the old rendition bytes when work starts.

## Claude's fixes and release scope checked

- Failed-restore handling, trash-view-independent permanent deletion, storage-link/uploader gating, private
  library audit suppression and redirect privacy: read their implementation and exercised their regression
  coverage in the relevant suites. No additional release blocker found there.
- V216: constant default, qualified SQL, idempotent up/down, current migration/schema/chain metadata and
  preserved existing file paths. Full migration-chain coverage includes named schemas.
- Key layouts: new integration coverage uploads under all four layouts, removes each original instance,
  changes the default profile layout, then heals via a duplicate upload. Both keys and object bytes remain
  correct. Existing unit coverage checks path generation, validation and profile revision behavior.
- Sitemap language slugs: canonical grouping, Publishing language-key resolution/fallback and slugless posts
  reviewed; no change to #921 required.
- Ukrainian catalogue: structural coverage and placeholders checked separately from translation quality.
  Claude's request for a Ukrainian speaker to review the flagged short labels remains appropriate.

## Remaining limitations

- **BUG - MEDIUM:** recovery of an object with no location row searches enabled site buckets only
  (`FileRepair.good_elsewhere/3` → `Storage.list_enabled_buckets/0`). An intact object in a user's own
  bucket can therefore be missed and reported unrecoverable after its location rows are lost. This fails
  safely: the object is neither changed nor deleted and reconciliation is skipped. Left for a follow-up
  extending recovery through the library's own profile, with tests that forbid probing another user's
  bucket; global bucket enumeration must continue to exclude user buckets.
- **IMPROVEMENT - MEDIUM:** repair still reads copies on up to two passes and again for final verification.
  This is additional cloud egress; changing the pass model needs a separate performance change.
- **IMPROVEMENT - MEDIUM:** storage/detail mounts still query the database. This existed before the split;
  moving report hydration to connected mount can be handled separately.
- The repair lock serializes repair and reconciliation, not every upload, annotation render or image-edit job.
  Variant publication retains the existing original-key/source guard; no global storage lock was introduced.
- Existing catalogue nits recorded by Claude (English fuzzy entries and Russian singular count wording) are
  outside this release's changed translations. Linguistic sign-off was not performed.

## Validation

- `mix precommit`: exit 0; format, warnings-as-errors compile, test compilation, Credo and Dialyzer pass;
  345 JavaScript tests pass. Existing Dialyzer ignore entries/unnecessary-skip notices remain unchanged.
- Full final PostgreSQL suite at `6f67a50b5`: `PGPOOL=20 mix test --max-cases 8`, exit 0;
  **89 doctests, 9052 tests, 0 failures, 10 skipped (1 excluded)**, 606.6 seconds. Integration tests ran;
  the privileged `requires_createrole` test is excluded because the database role lacks CREATEROLE.
- Focused repair/reconciler/V205 compatibility coverage passes. The ordinary-user download regression
  also checks that the two supported choices are present while retired/cropped annotation slots are absent.
  The first broad run exposed the duplicate-sharing assumption; it was corrected in the implementation
  and the full suite above rerun successfully. No test was relaxed to hide the sharing regression.
- Final `mix prerelease` at `6f67a50b5`: exit 0, including prod compilation, quality, dependency audits,
  documentation and package build; release check **7/7, 0 warnings, 0 failures**. `package.clean` removed
  the generated 4.6 MB tarball.
- Ukrainian `default.po` against `default.pot`: 0 missing/stale/empty/fuzzy entries and 0 placeholder
  mismatches when singular and plural sources are considered together. This is structural verification,
  not linguistic sign-off.
- Final review-only commit records these results; implementation and version are unchanged by that commit.

**Verdict:** no known CRITICAL/HIGH release blocker remains after the fixes. V216 and #921 are approved.
The medium recovery/performance limitations above remain explicit. Prepared and committed locally;
not pushed, published or tagged.
