# Why `lib/` grew from about 600 to 963 files

**Date:** 2026-11-11 · **Measured at:** `1e3efbc39` (version 3.5.0) · **Baseline:** `9b4d41bfd`, the last commit before 2026-09-01 (version 2.13.18)

## Question

The compiler now reports more than 900 files. The remembered size was 600 to 700. Where did 200 to 300 files come from, and is any of it accidental?

## Answer

Nothing was added by accident. `lib/` went from 596 files on 1 September to 963 on 11 November: 372 files added, 5 deleted, over 1,848 commits. Every large block of additions maps to a feature built in that period. No generated code, vendored code or build output is tracked under `lib/`.

The files are not smaller than before, so this is not one codebase cut into more pieces. Without the generated schema manifest, `lib/` grew from about 208k to 344k lines (+66%) while the file count grew 62%.

Seven areas hold 312 of the 367 net new files:

| Area | Files, 1 Sep | Files, 11 Nov | Net | Lines, 1 Sep → 11 Nov |
|---|---|---|---|---|
| `lib/modules/storage` | 39 | 123 | +84 | 12,160 → 50,744 |
| `lib/phoenix_kit/migrations` | 69 | 126 | +57 | 97,839 → 101,661 |
| `lib/phoenix_kit/api` | 0 | 54 | +54 | 0 → 14,036 |
| `lib/phoenix_kit_web/components` | 108 | 151 | +43 | 34,844 → 55,194 |
| `lib/phoenix_kit_web/live` | 66 | 98 | +32 | not measured |
| `lib/phoenix_kit/users` | 32 | 62 | +30 | 14,433 → 25,964 |
| `lib/phoenix_kit/jobs` | 0 | 12 | +12 | not measured |
| 18 other directories | | | +55 | |

## How it was measured

- File counts are `git ls-tree -r --name-only <commit> -- lib | wc -l` at the last commit before each date, so they count tracked files only.
- Additions and deletions are `git diff --name-status --no-renames <baseline> HEAD -- lib`.
- Line counts are raw `wc -l` over `.ex` and `.heex` files, blank lines and comments included.
- The weekly figures count files by the ISO week of the commit that first added them. They sum to 378, a little above the 372 in the diff, because a few files were added and removed again inside the period.

## Growth over time

### The long view

| Date | `lib/` | of which `lib/modules` | What happened |
|---|---|---|---|
| 2025-09-01 | 70 | 0 | |
| 2025-11-01 | 299 | 6 | |
| 2026-01-01 | 629 | 46 | |
| 2026-02-01 | 761 | 421 | Feature modules moved under `lib/modules` |
| 2026-03-15 | 891 | 502 | Previous peak |
| 2026-04-15 | 514 | 107 | Modules extracted into their own packages |
| 2026-06-01 | 558 | 85 | |
| 2026-08-01 | 640 | 77 | |
| 2026-08-15 | 570 | 82 | Migration squash removed 135 version files |
| 2026-09-01 | 596 | 83 | Baseline of this report |
| 2026-10-01 | 711 | | |
| 2026-11-01 | 925 | | |
| 2026-11-11 | 963 | 167 | Highest count so far |

The remembered "600 to 700" is accurate for January, and again for April through September. The project was at 891 once before, in March, when billing (78 files), publishing (77), shop (63), emails (39) and sixteen other modules still lived in core. Extracting them brought it down to 514. The current 963 has passed that peak with only storage, sitemap, crawlers, maintenance and languages left under `lib/modules`.

### Week by week since the baseline

| ISO week | Files added | Main contributors |
|---|---|---|
| W36 (from 31 Aug) | 11 | migrations 5 |
| W37 | 23 | website access 6 |
| W38 | 32 | migrations 9, components 8, storage 7 |
| W39 | 43 | storage 21, migrations 7 |
| W40 | 54 | storage 19, jobs 12, email 5 |
| W41 | 35 | storage 18, migrations 8, components 5 |
| W42 (from 12 Oct) | 69 | Machine API 45, components 12, live 5 |
| W43 | 36 | Machine API 10, live 6, migrations 5 |
| W44 | 40 | storage 12, users 9, live 7, migrations 6 |
| W45 | 25 | storage 6, users 6 |
| W46 (partial) | 10 | |

The single largest week is W42, when the Machine API landed. Storage is the most persistent contributor: it adds files in seven of the eleven weeks.

## Where the files went

### Storage: +84 files (39 → 123)

Libraries (V202 to V205), user-owned buckets (V206), profiles and variant sets, the reconciler, image editing with its hidden original, private file URLs, the removal guard and remote fetch. The directory now breaks down as:

| Subdirectory | Files |
|---|---|
| `services/` | 30 |
| top level | 28 |
| `web/` | 20 |
| `schemas/` | 16 |
| `workers/` | 13 |
| `jobs/` | 6 |
| `providers/` | 5 |
| `reorganizer/` | 3 |
| `libraries/` | 2 |

Storage quadrupled in lines. It is the largest single thing in core and the only large feature module that was never extracted. `storage.ex` alone is 9,163 lines. Thirteen more files for it sit outside the module, in `lib/phoenix_kit_web/components/media_browser/`.

### Migrations: +57 files (69 → 126)

Fifty of these are version files: 47 at the baseline, 97 now, running V135 to V231. The other seven are support modules (`expected_schema/`, `repair/`, two at the top level).

This is a cost of the one-file-per-version design and not of code volume. The whole directory gained under 4k lines, and 76,244 of its 101,661 lines are the generated `expected_schema.ex` manifest. The August squash is the only thing that has ever reduced this count.

### Machine API: +54 files, all new

`lib/phoenix_kit/api/` did not exist at the baseline. It now holds 32 top-level modules (executor, registry, keys, auth, REST, MCP, OpenAPI, problem, rate limit, validator, tool lint and others) and six subdirectories: `keys/` 5, `mcp/` 5, `confirm/` 4, `public_discovery/` 4, `approvals/` 2, `idempotency/` 2. About 14k lines.

### Web components: +43 files (108 → 151)

- 23 in `core/`: `activity_list`, `admin_edit_link`, `admin_label`, `audio_recorder`, `chart_lanes`, `chart_scale`, `crumb_switcher`, `date_input`, `date_nav`, `decimal_input`, `file_details_fields`, `file_exif_panel`, `form_field_hint`, `hdr_badge`, `library_load_notice`, `operation_preview`, `organization_switcher`, `preview_card`, `repair_log`, `role_switcher`, `save_button`, `upload_manager`, `website_access_badges`.
- 13 in `media_browser/`.
- 7 at the top level.

### LiveViews: +32 files (66 → 98)

12 settings pages (API, API guide, approvals and the storage and library settings among them), 10 live components, 8 user pages.

### Users: +30 files (32 → 62)

- Acting for an organization: `managed_organizations` and its four submodules, `organization_manager`, `organization_manager_role`, `organization_managers`, `organization_people`, `person_organizations`, `relationship_type`, `relationship_types`, `acting_link`.
- Sessions and sign-in: `active_role`, `passkeys`, `auth/passkey`, `auth/session_ref`, `sessions/revocation` and its observer, `login_attempt`, `login_attempts` and its prune worker.
- Smaller pieces: `avatar_crop`, `avatar_shape`, `format_country`, `view_pref`, `view_prefs`, `welcome_email` and its worker, `permissions/admin_grants`.

### Smaller additions

| Directory | Net | Contents |
|---|---|---|
| `lib/phoenix_kit/jobs` | +12 | New job engine: engine, state machine, run, history, kinds, Oban store, three workers |
| `lib/phoenix_kit` (top level) | +7 | |
| `lib/phoenix_kit/email` | +6 | Branding, catalog, layout, markdown, send profiles |
| `lib/phoenix_kit/integrations` | +6 | |
| `lib/phoenix_kit/website_access` | +5 | Gate, attempts, allowed addresses, environment, redirect |
| `lib/phoenix_kit/utils` | +5 | |
| Twelve further directories | +14 | Four or fewer each |

## File sizes

Of the 957 `.ex` and `.heex` files in `lib/` today, the average is 439 lines.

| Lines | Files |
|---|---|
| under 100 | 273 |
| 100 to 299 | 348 |
| 300 to 999 | 270 |
| 1,000 to 2,999 | 59 |
| 3,000 and over | 7 |

Average file size in bytes moved from 17,594 to 16,812, a 4% drop, which confirms the growth is new code and not splitting.

The seven largest files:

| Lines | File |
|---|---|
| 76,244 | `lib/phoenix_kit/migrations/expected_schema.ex` (generated) |
| 9,163 | `lib/modules/storage/storage.ex` |
| 7,732 | `lib/phoenix_kit_web/components/media_browser.ex` |
| 4,316 | `lib/phoenix_kit_web/users/auth.ex` |
| 4,230 | `lib/phoenix_kit/users/auth.ex` |
| 3,265 | `lib/modules/storage/libraries.ex` |
| 3,225 | `lib/mix/tasks/phoenix_kit.doctor.ex` |

## The rest of the repository

The repository as a whole grew faster than `lib/`: 1,668 tracked files on 1 September, 3,239 now.

| Directory | 1 Sep | 11 Nov | Notes |
|---|---|---|---|
| `test/` | 353 | 1,143 | `phoenix_kit` 134 → 410, `integration` 88 → 356, `phoenix_kit_web` 74 → 189, `js` 5 → 53, `support` 7 → 44, `modules` 7 → 42 |
| `dev_docs/` | 626 | 1,018 | `pull_requests` 511 → 821 accounts for most of it; `plans` 28 → 52, `squash` 25 → 41, `guides` 13 → 23 |
| `lib/` | 596 | 963 | |
| `priv/` and everything else | 93 | 115 | |

Neither `test/` nor `dev_docs/` ships: the Hex package is `lib priv mix.exs README.md LICENSE CHANGELOG.md`. Only `lib/` affects compile time and package size.

## Observations

1. **Storage is the extraction candidate.** At 123 files and 51k lines, plus 13 media browser component files, it is larger than billing, publishing or shop were when they were extracted. Whether it can leave core is a separate question: media, avatars and the file routes depend on it, which is why it stayed.
2. **Migrations grow by a fixed amount per schema change.** Fifty version files in ten weeks. Only another squash brings that down, as the August one did (minus 135).
3. **The Machine API is self-contained.** Fifty-four files under one directory that names no feature module. Its file count is unlikely to keep growing at the October rate now that the transports exist.
4. **`dev_docs/pull_requests` is 821 files, a quarter of the repository.** It costs nothing at compile time, but it is the largest single directory in a checkout.

No action was taken as part of this investigation.
