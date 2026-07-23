## 1.7.210 - 2026-07-23

### Fixed
- **Issue #652** — `** (ArgumentError) flash not fetched, call fetch_flash/2`
  on every router-rendered LiveView that redirects during mount with a flash
  message set (e.g. `:phoenix_kit_ensure_admin`'s "You must log in to access
  this page." redirect for unauthenticated admin-route hits). The dev/test
  router's `:browser` pipeline had no `fetch_flash`/`fetch_live_flash` plug,
  so `Phoenix.LiveView.Controller.live_render/3` crashed instead of
  redirecting whenever it tried to fold the on-mount flash back onto the
  conn. Added `plug :fetch_live_flash` to `lib/phoenix_kit_web/router.ex`'s
  `:browser` pipeline, plus a regression test. Test-harness-only fix — real
  parent apps generated via `mix phx.new` already carry this plug by
  convention.

## 1.7.209 - 2026-07-23

### Added
- **Etcher image annotation tool** — the media viewer's annotation toolbar
  now exposes Etcher's `:image` tool (fresco `~> 0.10`, etcher `~> 0.9`),
  which inserts an image annotation via the OS file picker as a `data:`
  URL (PR #660).
- **Migration V157** — widens `phoenix_kit_annotations_kind_check` to allow
  the new `"image"` annotation kind, paired with `Annotation.@kinds`.
  `@current_version` bumped 156 → 157.

### Fixed
- The `:image` toolbar tool added by PR #660 shipped without widening the
  annotation kind whitelist/CHECK constraint to match — image annotations
  drew fine client-side but silently failed to persist across a reload
  (same regression class as V130's `"marker"` fix). Closed by V157 above.

## 1.7.208 - 2026-07-21

### Changed
- `<.admin_page_header back={...}>`'s back affordance now renders inline
  beside the title (a circular icon chip aligned to the title's first line)
  instead of as a bare ghost button on its own row above it. When
  `back_label` is set, the chip widens to show the label from the `sm`
  breakpoint up; phones always stay icon-only. A blank `back_label=""` now
  normalizes to absent instead of producing an empty `aria-label`/tooltip.
  No attribute API change — all existing `back`/`back_label` call sites
  render the new anatomy unchanged (PR #659).

## 1.7.207 - 2026-07-21

### Added
- **Migration V156** — migrates legacy `phoenix_kit_newsletters_lists` /
  `..._list_members` into the CRM's `phoenix_kit_crm_lists` /
  `..._crm_list_members` (spec §4.5), re-points
  `phoenix_kit_newsletters_broadcasts` off `list_uuid` onto
  `source_type = 'crm_list'` / `crm_list_uuid`, then drops the legacy tables
  and column entirely. Requires a coordinated release with the newsletters
  module — see the migration's moduledoc warning. `@current_version` bumped
  155 → 156.
- `PhoenixKit.Users.Auth.merge_user_custom_fields/3` — atomically merges keys
  into a user's `custom_fields` JSONB column at the database level
  (`custom_fields || additions` inside the `UPDATE` itself), closing a
  lost-update race where two callers merging *different* keys concurrently
  (e.g. a locale-preference switch and a newsletters opt-out) could silently
  drop one writer's key. `delete_user_custom_field/3` gets the same atomic
  treatment (`custom_fields - key`); `set_user_custom_field/3` and
  `update_user_locale_preference/2` now route through these atomic
  primitives instead of a read-modify-write whole-map replace.
- `PhoenixKit.RepoHelper.update_all/3` — delegate to the configured repo's
  `update_all/3`, needed by the atomic custom-fields primitives above.

### Fixed
- `merge_user_custom_fields/3` and `delete_user_custom_field/3` now bump
  `updated_at` on write (missed in the initial PR since `Repo.update_all/2`,
  unlike a changeset-backed `Repo.update/2`, doesn't auto-stamp timestamps).

## 1.7.206 - 2026-07-20

### Added
- **Migration V154** — `phoenix_kit_og_templates` (reusable OpenGraph canvas
  designs; JSONB `canvas`) and `phoenix_kit_og_assignments` (binds a template
  to a `module_key × scope_type × scope_uuid` scope via a partial-index pair),
  powering the upcoming `phoenix_kit_og` plugin. `@current_version` bumped
  153 → 154.
- **Migration V155** — `crm_contact_uuid` on `phoenix_kit_newsletters_deliveries`
  (soft reference, no FK, matching the `crm_list_uuid` convention), a widened
  `..._recipient_check` CHECK (still requires an addressable recipient, and
  now also forbids a row claimed by both `user_uuid` and `crm_contact_uuid`),
  the first DB-level per-broadcast delivery dedup (three partial unique
  indexes), and `source_params` JSONB on `..._broadcasts` for the new
  `user_group` (core-role) recipient source. `@current_version` bumped
  154 → 155.
- `<.bulk_actions_toolbar>` gained a `:trailing` slot for far-right toolbar
  content (e.g. a view-mode switcher) that should sit apart from the
  left-aligned sort/filter controls.
- `<.search_toolbar>` shows a loading spinner while its debounced search is
  in flight; opt out with `loading_indicator={false}` for client-instant
  filters (pairs with the new `TableLocalSearch` hook).
- `TableLocalSearch` JS hook: client-instant row narrowing for
  `<.search_toolbar>` tables once the full row set is already loaded, without
  waiting on the server round-trip.
- `AdminSidebarScroll` JS hook: the admin sidebar keeps its scroll position
  across live redirects and full reloads instead of resetting to the top.
- `<.tab_item>` sets `aria-current="page"` on the active tab.
- `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` gained `page_action`:
  a compact circular action button rendered next to the breadcrumb title.
- `PhoenixKit.Settings.timezone_options/0` and `get_timezone_label/1`: a cheap
  timezone-label accessor that resolves without building the full
  `get_setting_options/0` map, so callers that only need the timezone string
  no longer pay for a `Roles.list_roles/0` query on every call.

### Changed
- Bumped `etcher` to `0.8.2` (fixes invisible circle annotations on a rotated
  canvas).

## 1.7.205 - 2026-07-19

### Changed
- Bumped `beamlab_ex_aws_sqs` to `~> 5.0`, declared as `{:ex_aws_sqs, "~> 5.0", hex:
  :beamlab_ex_aws_sqs}`. v5.0.0 renamed the compiled OTP app back to `:ex_aws_sqs`
  (only the Hex package name is `beamlab_ex_aws_sqs`), so it can be a drop-in for
  anything depending on `:ex_aws_sqs` directly. No code changes — `ExAws.SQS`'s
  public API is unchanged.

## 1.7.204 - 2026-07-19

### Added
- Media browser: per-file kebab menu gained Rotate left/right (counter-
  clockwise + clockwise), saving `metadata["rotation"]` the same way the
  viewer's rotate button does and refreshing the grid thumbnail live.
- Esc now exits the media browser's select mode, mirroring the toolbar's
  Cancel button.

### Changed
- **New folders default to a small hero header** instead of medium
  (`PhoenixKit.Modules.Storage.Folder.header_size` default flips to
  `"small"`). **Migration V153** flips the DB column default to match and
  backfills existing `'medium'` rows to `'small'` (indistinguishable from
  "never customized"); rows already on `'large'` or `'small'` are left
  alone. `@current_version` bumped 152 → 153.
- **A folder's Trash is now scoped to that folder's own subtree** instead
  of always listing every trashed folder/file across the whole install —
  opening Trash inside a folder no longer shows what was trashed under
  unrelated sibling roots. Applies to the trash view, the trash-count
  badge, and Empty Trash.

### Fixed
- **A folder's own cover/logo files were hidden from that folder's file
  listing.** They're real, re-selectable files (not synthetic assets) and
  now show up like any other file in the folder they decorate.
- Estonian (`et`) translations: several `default.po` entries were mapped to
  the wrong string entirely (e.g. "Header size" read as "Pealkiri"/Title,
  "Documents" read as "Kommentaarid"/Comments) rather than being merely
  untranslated.
- **"Test email" on the Email Sending settings page showed a raw
  `{:incomplete_credentials, [...]}` tuple** when the active send
  integration was missing a required field. Now shows a plain-language
  message naming the missing field(s).
- **Migration V152**: a newsletters delivery row could be saved addressable
  by neither a core `User` nor a snapshotted `recipient_email`, making it
  unreachable by any send path. Added a `CHECK (user_uuid IS NOT NULL OR
  recipient_email IS NOT NULL)` constraint as a DB-level backstop (the Ecto
  insert path already guarded this; the constraint just closes the gap for
  anything that bypasses it).

## 1.7.203 - 2026-07-18

### Added
- **Send Profiles moved from `phoenix_kit_newsletters` into core.**
  `PhoenixKit.Email.SendProfile`/`SendProfiles` are now shared infrastructure
  any module can send through, routed via the profile's `Integrations`
  connection (per-provider `ProviderOptions`, including SES/Brevo
  configuration-set and tag options). App-config transport is now
  detect-and-display only.
- **New Settings → Email Sending page**: transport detection, default-profile
  picker, and a seam (`email_settings_sections/0`) where external modules
  (e.g. the `emails` package) mount their own settings sections as
  live_components instead of owning a separate Settings tab. Send Profiles
  CRUD gets its own nested sidebar entry under Email Sending.
- **Quota/credits surfacing per send profile**: SES `GetSendQuota` and Brevo
  `/account` (plan + credits) are now shown per profile; a validator that
  cannot verify actual sending capability (e.g. SES credentials scoped to
  `ses:SendEmail` alone) says so instead of showing a bare green tick.
- **Migration V152**: `email_send_profiles` created in core (uuid-preserving
  copy from the old newsletters table, which is then dropped); CRM contact
  list groundwork (`phoenix_kit_crm_lists`, `phoenix_kit_crm_list_members`,
  citext member email); broadcasts can now source recipients from a CRM list
  (`source_type`/`crm_list_uuid`, soft reference).

### Fixed
- **A stored email connection with a blank required field (SMTP `host`, SES
  `aws_region`) could crash mail delivery with the plaintext secret embedded
  in the crash message.** A connection's `status` can say "connected" while
  an individual field was blanked out after the last successful validation;
  that reached `Swoosh.Mailer.deliver/2` uncaught, which raises with the
  *entire* adapter config — password/access key included — inlined in the
  exception text. `PhoenixKit.Mailer.swoosh_config_for/1` now validates
  required fields itself and fails closed with
  `{:error, {:incomplete_credentials, [field_names]}}` before any
  secret-bearing config is built.
- **`pagination_range/2` could OOM the whole BEAM.** An unclamped
  `current_page` (e.g. `?page=9999999999`) built a descending
  `9999999997..56` Range — ~10 billion iterations in the component's `for`.
  Now clamps into `[1, max(total_pages, 1)]` with an explicit `//1` step as
  a second guard; `pagination_controls/1` additionally gained a
  `total_pages > 1` outer guard.
- `table_default`'s search toolbar rendered no `<form>` when only
  `on_change` was given — `phx-change` on a formless input dies silently
  client-side. The form is now always rendered.
- Admin view permission map: five settings LiveViews (Integrations,
  IntegrationForm, EmailSending, SendProfiles, SendProfileForm) resolved to
  nil → custom "settings"-scoped roles were denied. Mapped explicitly.
- A plugin module assigning `page_section` was a silent no-op —
  `admin.html.heex` now forwards it (and `page_section_path`) to the layout.
- **The universal `smtp` integration provider could not send at all.** gen_smtp
  supplies no TLS options of its own and OTP's `:ssl` now defaults to
  `verify: :verify_peer` with no CA store, so port 465 died with
  `{:options, :incompatible}` and STARTTLS died with `:tls_failed`. The transport
  now builds the options properly (`PhoenixKit.Mailer.SmtpTransport`), including
  the `depth` gen_smtp otherwise defaults to `0` — which rejects every real
  certificate chain.
- **"Test Connection" verified nothing** for `aws_ses`, `smtp` and `brevo_api`:
  the connection was stamped `"connected"` without a byte leaving the box, so a
  wrong key showed green and then failed at send time. All three now perform a
  real check, bounded by a deadline.
- **A failed connection check could take the operator's page down, or leak a
  socket for twenty minutes.** `:gen_smtp_client.open/1` runs in the calling
  process and waits on a hard-coded 20-minute timeout past `connect`; the checks
  now run in an isolated, linked-and-monitored process
  (`PhoenixKit.Integrations.Probe`) that neither kills its caller nor outlives it.

### Security
- **SMTP no longer sends in plaintext when TLS cannot be established.**
  `tls: :if_available` had been masking the broken TLS configuration above by
  silently falling back to an unencrypted session — with the relay password on the
  wire. A relay that expects credentials now fails closed.

### Changed — may require action on upgrade
- **SMTP sending now stops on images with no CA bundle** (`{:error, :no_ca_store}`)
  instead of proceeding with certificate verification disabled. Slim base images
  (distroless, scratch, some Alpine builds) are affected: install `ca-certificates`.
  A relay configured with no username or password still degrades rather than
  failing — it has no credentials to protect.
- **Configured SMTP relays are no longer MX-resolved** (`no_mx_lookups: true`).
  gen_smtp would otherwise look up the relay's MX records and connect to whatever
  they point at, while SNI and the hostname check stay pinned to the configured
  name — a guaranteed certificate mismatch. If you configured `host` as a bare
  domain and relied on MX resolution, point it at the relay itself.
- **AWS SES credentials scoped to `ses:SendEmail` alone now pass Test Connection
  with a note** rather than a bare green tick. They cannot read the send quota, so
  the check can prove the credentials are valid but not that they can send, and it
  now says so on screen instead of only in the log.

## 1.7.202 - 2026-07-18

### Fixed
- Media rotation now persists for any user, not just admins. The embedded
  `MediaBrowser` popup opts every viewer into `persist_rotation` (previously
  gated on `@admin`) — rotation is the file's shared orientation
  (`metadata["rotation"]`), not a per-user preference, so a non-admin who
  could open and rotate a file in an embedded browser saw the turn but it
  never stuck. The admin detail page already did this unconditionally; the
  popup now matches. The `Details` link stays admin-only.

## 1.7.201 - 2026-07-18

### Fixed
- `/admin/media/:file_uuid` was declared before `/admin/media/selector`,
  so the router matched `selector` as a `:file_uuid` param and the
  dedicated selector route was unreachable — reordered.
- Folder header cover/logo images now render the file's saved rotation
  (previously always unrotated, unlike every other thumbnail surface).
- `MediaSelectorModal`/`MediaSelector` selection is now an ordered list
  instead of a `MapSet`, so pick order survives to `MediaGallery`'s
  "featured image" (first entry) instead of being silently reshuffled.
  Multi-select pickers also gained an optional `max_select` cap with a
  "Maximum N files" indicator instead of the consumer silently truncating
  on confirm.
- Media browser bug sweep: "Select all" now covers files inside expanded
  stacks; download (single + bulk) resolves selections that span pages or
  live inside a stack instead of silently no-oping; permanent delete now
  double-checks `status == "trashed"`; leaving trash view reloads the real
  folder list instead of reusing the stale trashed one; switching between
  trash/normal view clears any carried-over selection; paging in
  controlled mode no longer drops the trash/orphaned views through a URL
  round-trip they can't address; deleting the last item on a page clamps
  back to the last populated page instead of showing an empty grid;
  "Delete folder" copy now correctly says contents are deleted recursively
  (not moved to the parent).
- `MediaDetail` no longer crashes on a malformed `file_uuid` route segment
  (falls back to the "not found" state).
- `MediaSelector`'s `return_to` param is now restricted to same-origin
  paths (rejects `//host` / `/\host` bypasses); `page` no longer crashes
  the mount on a non-numeric value; pagination links use `patch` instead
  of `navigate` so a page change doesn't drop the in-memory multi-select;
  the browse query now excludes trashed/system-managed files; a failed
  upload no longer crashes the LiveView.
- `storage_max_upload_size_mb` setting no longer crashes every media
  surface at mount if the stored value isn't numeric.
- Dependency bumps: `beamlab_countries` 1.0.8 → 1.1.0,
  `beamlab_ex_aws_sqs` 4.0.0 → 4.1.0.

## 1.7.200 - 2026-07-17

### Added
- Media thumbnails (browser grid/list/stacks, gallery, both media-selector
  pickers) now render a file's saved rotation as a CSS transform, matching
  what the popup viewer's canvas shows — no re-encode needed, and baked
  annotated thumbnails stay untouched on disk.
- The media browser's "⋯" overflow menu now also lists Add Media, Cancel
  upload, and Search, so every page action is reachable from one place even
  when the toolbar wraps tight.
- 4 strings (`Failed to save rotation`, `Hide details`, `Rotation saved`,
  `Show details`) translated to et/ru.

### Fixed
- A file's rotation or rebaked annotated thumbnail is now reflected in a
  collapsed stack's pile preview — previously only the grid and open
  viewer picked up the live refresh, leaving the pile stuck on the stale
  thumbnail.
- Clicking a file inside an expanded stack now opens the popup viewer
  (previously a silent no-op, since the lookup only searched the current
  page's file list, not the stack's own); the viewer's prev/next now steps
  through the correct sibling list in both stacked and flat views.
- Select-mode toolbar's exit button now reads "Cancel" instead of "Done" —
  it exits without applying anything, so "Done" read like a confirm it
  never was.

## 1.7.199 - 2026-07-17

### Added
- `MultilangForm.mount_multilang/2` now auto-attaches a `:handle_event`
  hook that intercepts the `"switch_language"` event pushed by
  `<.multilang_tabs>` — consumers no longer need their own
  `handle_event("switch_language", …)` clause (forgetting it used to crash
  the LiveView on the first tab click). Opt out with
  `auto_switch_language: false` to handle the event manually.
- `SearchPicker` gains a `search_on_focus` attr (default `false`) that
  opens the dropdown on focus/click of an empty input — promotes the
  previously JS-only `data-search-on-focus` behavior to a documented,
  first-class attribute (the raw rest attr is still honored).
- Event-based `NavTabs` buttons now pulse (`animate-pulse`) while
  `phx-click-loading` is applied, giving instant feedback for a tab
  switch whose content needs a server round-trip.

### Fixed
- Closed a test-coverage gap on the new `mount_multilang/2`
  switch-language hook (and its `auto_switch_language: false` opt-out).

## 1.7.198 - 2026-07-16

### Added
- Live refresh for the `MediaBrowser` popup viewer: `ProcessFileJob` and
  `AnnotationThumbnailJob` now broadcast completion over PubSub
  (`Storage.subscribe_to_file_events/0`), so a just-uploaded file's
  dimensions/variants and a rebaked annotated thumbnail appear in an open
  browser/viewer without a manual reload. Thumbnail updates refresh the
  grid row only — an open annotator session is never remounted mid-edit.
- Collapsible info sidebar in the popup viewer (filename/Download/
  metadata/comments), toggled from a corner button and persisted per-user
  so it survives prev/next, reopen, and reload.
- Rotation-save confirmation: a transient status pill over the canvas
  confirms each persisted rotation (or surfaces a failure) — previously
  the write was invisible, indistinguishable from a view-only rotation.
- Admin-context `MediaBrowser` clicks now open the same in-place modal
  viewer as everyone else (previously they navigated straight to
  `/admin/media/:uuid`); the viewer sidebar gains an "Open details page"
  link to the full admin page instead.
- Folder view now scrolls as a single region — breadcrumbs, hero header,
  toolbar, and file grid scroll together instead of the grid owning its
  own nested scrollport — fixing the list view's sticky column header not
  pinning correctly against the real scroll area.
- Bumped `etcher` to 0.8.0, `fresco` to 0.9.0, `tessera` to 0.3.3.

### Fixed
- `MarkdownEditor`'s unsaved-changes navigation guard is now opt-in
  (`protect_navigation={true}`), off by default. The old `true` default
  never actually armed the guard — a boolean renders as a bare HEEx
  attribute, which failed the JS hook's `=== "true"` string check — so
  this makes the previously-inert behavior deliberate, and hosts that
  pass `protect_navigation={true}` now get a real (working) guard.

## 1.7.197 - 2026-07-16

### Added
- V151: `supplier_source` (`crm_company | crm_contact | local`, CHECK-backed)
  and `is_primary` (partial-unique, one primary per item) columns on
  `phoenix_kit_cat_item_supplier_info` — completes the V149 junction for the
  merged `phoenix_kit_catalogue` sourcing layer, which reads/writes both on
  every insert/update.
- V151: normalizes `phoenix_kit_crm_contacts.email` /
  `phoenix_kit_crm_companies.email` to `citext`, a prerequisite for
  case-insensitive email matching in the CRM v2 backfill and the
  user↔contact bridge.
- `mix phoenix_kit.doctor` gains three checks: **Schema Drift** (a version
  marker claiming a column that's actually missing at the resolved prefix —
  surfaces an installer/migration-runner drift with no other self-service
  signal), **Child Start Order** (reads the host `application.ex` and fails
  when `PhoenixKit.Supervisor`/`Oban` are listed before the Repo, the boot
  crash class where Oban opens a pool against a database connection that
  doesn't exist yet), and prefix resolution now goes through the same
  `PrefixConfig.resolve_prefix/1` as `phoenix_kit.update --status`, fixing
  doctor reporting "not installed" against a prefixed install it was
  actually diagnosing at the wrong schema.

### Fixed
- Closed an `HtmlSanitizer` stored-XSS bypass: the `href`/`src` scheme
  filter only blacklisted literal `javascript:`/`vbscript:`/`data:`, so
  entity-encoded (`jav&#x61;script:`), whitespace-obfuscated
  (`java&Tab;script:`), and raw-control-char variants slipped through into
  any markdown-rendered rich-text sink. Replaced it with an allowlist
  (`http`/`https`/`mailto`/`tel` + relative/fragment URLs) evaluated over a
  decoded, control-char-stripped, normalized value — the transform only
  ever removes an attribute, never rewrites the visible URL.
- Fixed the admin sidebar's width flipping by ~15px around a modal's
  scroll-lock on long admin pages (the drawer grid's auto-sized sidebar
  column resolves differently depending on whether the page root currently
  has a scrollbar).
- `phoenix_kit.doctor`'s Oban Configuration check reported `0 queues, 0
  plugins` because doctor's own pool-capping zeroed the app-env Oban config
  before the check read it; now snapshotted before capping.
- Silenced a dialyzer false positive (`call_without_opaque`) in
  `QrLogin.location_for/1`'s `Task.Supervisor.async_nolink` +
  `Task.yield`/`Task.shutdown` idiom, matching the existing `auth.ex`
  ignore-list precedent for the same opaque-widening class.

## 1.7.196 - 2026-07-15

### Added
- OpenRouter and xAI now declare the `:image_generation` capability (OpenAI
  already did). Both genuinely have real image-gen models (OpenRouter's
  catalog includes Gemini image/GPT-image-1 style entries; xAI has
  `grok-imagine-image[-quality]`) reachable at the standard
  `/images/generations` path — gates `phoenix_kit_ai`'s new "Image
  Generation" Endpoint model type to providers that can actually serve it.

## 1.7.195 - 2026-07-14

### Added
- V150: nullable `browser`/`os` columns on `phoenix_kit_users_tokens`,
  parsed from the User-Agent at login. Session device names ("Safari on
  iOS") are now available for every session, independent of the
  `new_login_alert_enabled` setting — previously the name only came from
  `known_devices`, which that setting gates. The self-service Active
  Sessions list and the admin all-sessions page (new Device column) both
  use it, falling back to a known-device row for pre-V150 sessions.
- `Sessions.get_session_stats/0` gains `by_os`/`by_browser` breakdowns of
  active sessions (most-common first), rendered as two cards on the admin
  sessions page.
- The user-facing "Active today"/"Active yesterday" session labels now
  include the precise sign-in time ("Active today at 14:32").

### Fixed
- Admin Dashboard LiveView subscribed to the sessions PubSub topic but had
  no `handle_info` clause for `{:session_created, ...}`,
  `{:session_revoked, ...}`, or `{:user_sessions_revoked, ...}` — an
  unmatched message crashed and reconnected the LiveView. Now refreshes
  the session-stats tiles on each.
- `mix gettext.extract --merge` fuzzy-matched several of the above's new
  strings against unrelated old strings in the `ru`/`et` locales (e.g.
  "Device" landed as "Service", "By browser" as "browser tab", and the new
  `%{time}` interpolation was dropped from "Active today/yesterday").
  Corrected all affected `ru`/`et` translations to keep both locales fully
  translated, per project convention.

## 1.7.194 - 2026-07-14

### Added
- xAI provider now declares the `:realtime_voice` capability (in addition
  to `:ai_completions`), gating `phoenix_kit_ai`'s new streaming-voice
  Playground panel (built on the `xai` Hex package's `Xai.Realtime`
  WebSocket client) to xAI endpoints only.

## 1.7.193 - 2026-07-14

### Added
- V148: `phoenix_kit_crm_party_roles` table for the `phoenix_kit_crm`
  module — a polymorphic role edge marking an existing CRM company or
  contact as `supplier`, `client`, or another commercial counterparty role
  (a party can hold several roles at once). No FK on the polymorphic
  `(roleable_type, roleable_uuid)` pair; `valid_from`/`valid_to` lifecycle,
  `is_active` filter, role-scoped `metadata`.

### Fixed
- V148's `uuid` column `DEFAULT` now schema-qualifies `uuid_generate_v7()`
  with the install prefix (matching V138/V144) — the unqualified call
  would have resolved via `search_path` and failed on named-schema
  installs.

## 1.7.192 - 2026-07-14

### Added
- **Self-service Active Sessions** — a `:sessions` section in
  `UserSettings` lists a user's live sessions (device, location, last
  active), flags the current one, and lets them revoke a single session or
  all other sessions. Sessions are enriched from `KnownDevice` history;
  degrades gracefully (no browser/OS/location) for sessions predating
  device fingerprinting.
- **QR sign-in remember-me and return-to** — the desktop QR sign-in page
  gained a "Keep me logged in" checkbox and now carries a sanitized
  `return_to` through the mint → approve → finish handoff, both wired into
  the existing `UserAuth.log_in_user/3` `remember_me`/`user_return_to`
  machinery.
- **In-app notification for new-device sign-ins** — `LoginAlerts` now
  raises a standalone `"security"`-type notification (new core
  notification type) alongside the existing email when a login is seen
  from an unrecognized device.
- V147: persists the resolved `"City, Country"` geo-location on
  `phoenix_kit_user_known_devices` (nullable `location`) so Active
  Sessions doesn't need a live geo lookup per render.

### Fixed
- QR confirm screen no longer shows a bare "unknown" IP when
  `IpAddress.extract_from_socket/1` can't read peer data — treated as
  absent, same as a blank IP.
- The desktop QR page's connected mount no longer blocks showing the QR
  code behind a synchronous, up-to-~10s (two sequential providers × 5s
  each) geolocation lookup. `QrLogin.location_for/1` now bounds the lookup
  to 1.5s via an unlinked, supervised `Task` — a slow/unreachable geo API
  degrades to "no location" instead of stalling the page whose only job is
  showing the code quickly.
- Corrected Russian/Estonian translations for the new session-management
  strings introduced above, including an inverted `"Sign out"` →
  `"Войти"`/`"Logi sisse"` ("Log in") that `mix gettext.merge` fuzzy-matched
  against unrelated existing entries and left uncorrected.

## 1.7.191 - 2026-07-13

### Added
- **xAI as a built-in integration provider** — `:api_key` auth, Grok models
  via the OpenAI-compatible `https://api.x.ai/v1` API. Declares
  `:ai_completions`, so it surfaces automatically in `phoenix_kit_ai`'s
  endpoint picker with no changes needed there (provider discovery has been
  fully registry-driven since 0.9.0). *Test Connection* validates against
  `GET /v1/models` — confirmed live (401 without a key) even though the
  endpoint isn't listed on xAI's published API reference.

## 1.7.190 - 2026-07-13

### Security
- **Integration credentials (AWS SES, SMTP, Brevo API keys, etc.) were
  silently stored in plaintext on real host apps.** `encryption_key/0`
  only read the flat `config :phoenix_kit, secret_key_base:` — a key the
  installer never sets — so encryption was effectively always disabled
  outside of manual, undocumented setup. Now falls back to the host app's
  own Phoenix Endpoint `secret_key_base` (which every Phoenix app has),
  keeping the flat key's precedence so any install that *did* set it
  derives an identical key. Pre-existing plaintext values still read back
  correctly and are transparently re-encrypted on next save. `password`
  fields (SMTP) now encrypt too. The KDF is also correctly documented now
  (a single SHA-256, not PBKDF2 as previously claimed).

### Added
- **Integrations-backed email sending foundation** ("Phase 1" of a
  multi-repo newsletters effort — `phoenix_kit_emails` and
  `phoenix_kit_newsletters` both depend on this release). Adds
  `PhoenixKit.Mailer.deliver_via_integration/3`, which sends through any
  configured `PhoenixKit.Integrations` connection instead of only the
  host's static mailer adapter: `aws_ses` (key/secret), a new universal
  `smtp` provider (one named connection per vendor — Brevo, Mailgun,
  SendGrid, a self-hosted relay, etc.), and `brevo_api` (with a real
  *Test Connection* check against Brevo's account endpoint). SMTP
  transport correctly selects implicit TLS (`ssl: true`) on port 465 vs.
  mandatory STARTTLS elsewhere when credentials are present, failing
  closed rather than risking a plaintext credential leak. Recipients
  blocklisted by the optional `phoenix_kit_emails` package (hard bounces,
  complaints, manual blocks) are now refused before delivery on **every**
  outbound path, not just newsletters — auth mail included. New migration
  V145 adds `phoenix_kit_newsletters_send_profiles` (named send
  configurations, at most one default, partial-unique-indexed) and
  `phoenix_kit_newsletters_broadcasts.send_profile_uuid`.
- **New-login security alerts** ("We noticed a new login to your
  account", the same pattern GitHub/xAI/etc. use). Every login path
  (password, magic link, OAuth, QR) now checks the login's device
  (IP + hashed user-agent) against history for that user; an unrecognized
  device is emailed and logged as `user.new_login_detected`, a recognized
  one is silent. Off by default — enable at Admin → Settings →
  Authorization → "Login Notifications". New migration V143 adds
  `phoenix_kit_user_known_devices`.
- **Manufacturing/warehouse module tables consolidated into core.** Moves
  `phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`,
  `phoenix_kit_machine_operations`, `phoenix_kit_warehouse_transfers`, and
  `phoenix_kit_warehouse_min_stock` out of the `phoenix_kit_manufacturing`/
  `phoenix_kit_warehouse` packages' own migrations and into core's single
  numbered chain (V144), matching the precedent already set for locations
  and other warehouse tables. Upgrade-safe for hosts on published
  `phoenix_kit_manufacturing` 0.2.0.

### Changed
- **Dropped `Jason` in favor of Elixir's built-in `JSON` module (1.18+)**
  everywhere in phoenix_kit's own code — no behavior change; `jason`
  itself stays in the dependency tree (`ecto`, `phoenix`, `ex_aws`, and
  others still require it transitively).
- **`ex_aws_sqs` replaced with the maintained
  [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs)
  fork.** Unblocks Hex publishing itself: upstream `ex_aws_sqs` (archived,
  last released January 2023) pins `hackney ~> 1.9`, which cannot coexist
  with the `hackney ~> 4.0` upgrade below without an `override: true` —
  and Hex refuses to publish any package depending on one. The fork
  declares no hackney dependency at all. SQS now speaks AWS's JSON
  protocol instead of the legacy XML protocol (response shapes changed
  accordingly in `PhoenixKit.AWS.InfrastructureSetup`); fixed a related
  latent bug surfaced by the switch — the "queue already exists" fallback
  checked for AWS error code `QueueAlreadyExists`, but the real SQS API
  error is `QueueNameExists`.
- Ported the multi-session "Accounts" switcher (add/switch/remove
  account, "log out from all accounts") into
  `UserDashboardNav.user_dropdown/1` — previously only the admin top-bar
  dropdown had it, so host apps rendering their own layout via
  `user_dropdown/1` had no multi-session UI at all.

## 1.7.189 - 2026-07-12

### Added
- **QR device-handoff login ("scan to sign in").** A signed-out browser at
  `/users/qr-login` shows a QR code; an already-signed-in phone scans it
  (native camera, no app needed), reviews the requesting device
  (browser/OS/IP), and taps Approve — the desktop signs in with no
  password. Approval always happens on the trusted phone; the desktop
  receives nothing until the phone approves. Built on the new
  [`keyfob`](https://hex.pm/packages/keyfob) library. Off by default —
  enable at Admin → Settings → Authorization → "Enable QR code sign-in".
  Post-merge hardening: the `qr_login_enabled` setting is now enforced as
  an immediate kill switch on the phone-approval and completion paths (not
  just the desktop entry point), and request creation is rate-limited per
  IP (`PhoenixKit.Users.RateLimiter.check_qr_login_rate_limit/1`) to guard
  the public, pre-auth mint endpoint against ETS-table exhaustion.

### Fixed
- **Prefix hardening for low-privilege multi-schema installs**, driven by
  a field report from a hardened install (DBA-pre-created schema, no
  database-level CREATE, PG15+ non-writable `public`, PgBouncer):
  `CREATE EXTENSION`/`CREATE SCHEMA` now check `pg_extension`/
  `information_schema.schemata` before attempting creation (Postgres
  checks the CREATE privilege *before* the IF-NOT-EXISTS short-circuit,
  failing low-privilege roles even when the object already exists); V27
  now threads `create_schema: false` through to Oban's migration so it
  can't re-default to `true` and execute a failing `CREATE SCHEMA`
  mid-chain; `uuid_generate_v7()` is now created inside the install's
  schema (not wherever `search_path` happens to point) with all ~89 call
  sites schema-qualified, including the pgcrypto `gen_random_bytes` call
  inside the function body; the prefix is validated at every entry point.
  New runtime `PhoenixKit.SchemaPrefix` (all 21 table-backed schemas
  adopt it) means prefixed installs no longer depend on the DB role's
  `search_path` for ordinary queries. Install/update/status/gen.migration
  tooling now persists and resolves `--prefix` correctly, distinguishes an
  unreachable database from a genuinely absent install, and warns when an
  existing host Oban config lacks the install's prefix.
  Post-merge: fixed a matching unqualified-call bug the same PR's own
  sweep missed — V26's pgcrypto `digest()` backfill call was still bare
  (same failure mode as the pre-fix `uuid_generate_v7()`, now qualified
  via the new `Helpers.pgcrypto_call/1`) — and fixed the new Oban
  prefix-detection regex to skip commented-out config blocks (it could
  both false-positive on a commented example block and false-negative
  when a commented block happened to mention `prefix:`, masking a
  genuinely unprefixed active block).
- **daisyUI modal scrollbar-gutter compensations removed.** Fixes a
  reported "clicked cancel and a scroll bar showed up" bug on scrolling
  pages: daisyUI ≥ 5.1's own conditional gutter reservation handles both
  scrolling and non-scrolling pages correctly on its own, so core's
  1.7.179 counter-rules and PkDialog's inline override were fighting it
  and causing the reflow. `PhoenixKit.Install.DaisyUI` now declares a
  designed-for minimum (5.6.0) and warns hosts on an older vendored
  daisyUI via `phoenix_kit.install`/`.update`/`.doctor` — advisory only,
  nothing touches host files.
- **The 1.7.188 hackney 4.x upgrade made this package un-publishable**,
  discovered while cutting this release: `mix hex.publish` refuses to
  build any package carrying an `override: true` dependency, which
  `mix.exs` needed because `ex_aws_sqs` (last released Jan 2023, since
  archived upstream) pins `hackney ~> 1.9` — incompatible with `~> 4.0`
  with no override. Switched the SQS dependency to
  [`beamlab_ex_aws_sqs`](https://hex.pm/packages/beamlab_ex_aws_sqs), a
  maintained fork with the same public API (`ExAws.SQS`) that declares no
  hackney dependency at all, clearing the conflict — `override: true` on
  both hackney and httpoison is gone, and the now-fully-unused
  `httpoison` dependency itself is dropped. The fork also switches SQS
  from the legacy Query/XML protocol to AWS's JSON protocol, which
  changes response shapes (raw `%{"QueueUrl" => ...}` instead of
  `%{body: %{queue_url: ...}}`); `PhoenixKit.AWS.InfrastructureSetup`
  (SQS/DLQ provisioning) is updated accordingly, including a latent bug
  this surfaced — the "queue already exists" fallback path was checking
  for AWS error code `QueueAlreadyExists`, but the real SQS API error is
  `QueueNameExists` (confirmed against `botocore`'s service definition),
  so idempotent re-runs of setup against a differently-configured
  existing queue likely never hit the intended fallback under the old
  protocol either.

## 1.7.188 - 2026-07-12

### Security
- **hackney upgraded 1.25.0 → 4.5.2 and httpoison upgraded 2.3.0 → 3.0.0,
  clearing all 4 hackney CVEs accepted in 1.7.178 (1 HIGH: `ssl:connect/2`
  post-handshake TLS upgrade with no timeout; 2 moderate CR/LF-injection /
  SSRF-bypass; 1 low CRLF injection).** Both are now pinned via `override:
  true` in `mix.exs`, since two stale transitive constraints still declared
  the old majors: `ex_aws_sqs` (last released 2023) pins `hackney ~> 1.9`,
  and `ueberauth_apple` (last released 2023, now removed — see below) pinned
  `httpoison ~> 1.0 or ~> 2.0`. Verified safe to override: `ex_aws_sqs`
  never calls hackney directly (the pin is vestigial, only listed for its
  own `:test` env); `ex_aws` itself already relaxed to `hackney ~> 4.0,
  optional: true` as of 2.7.0 (our lock was just stale at 2.6.1); hackney
  4.0's release notes confirm the public `hackney:request/5` API is
  unchanged from 1.x (the major bump split HTTP/2 and HTTP/3 into separate
  libraries, `h2` and `quic`, and replaced the built-in metrics subsystem
  with a middleware chain); every real hackney consumer in the tree
  (`ex_aws`, `tesla`, `swoosh`) only touches that stable surface. Full
  investigation: `dev_docs/audits/2026-07-12-hackney-upgrade-resolution.md`
  (supersedes `2026-07-07-hackney-cve-2026-advisories-audit.md`).

### Removed
- **BREAKING: Apple Sign-In removed** (`ueberauth_apple` dependency
  dropped, along with its Settings UI, credential storage, and login/admin
  buttons). `ueberauth_apple` has been unmaintained since its 0.6.1 release
  in 2023 and was the sole reason httpoison — and therefore hackney — could
  not move past the versions above. Hosts with Apple Sign-In configured
  will see the "Apple Sign-In" toggle and credential fields disappear from
  Settings → Authorization; any users who previously linked an Apple
  account keep that link (existing `phoenix_kit_user_oauth_providers` rows
  are untouched and still shown/manageable in account settings), but new
  Apple sign-ins are no longer offered. Plan is to reintroduce this via a
  maintained fork of `ueberauth_apple` in a future release.

## 1.7.187 - 2026-07-12

### Fixed
- **`data-confirm` was silently swallowed on `BulkSelectScope` action buttons.**
  The hook's `_onActionClick` calls `e.preventDefault()` synchronously on
  every `data-bulk-action` click; `phoenix_html`'s own window-level click
  listener (which implements `data-confirm`) bails out early via `if
  (e.defaultPrevented) return;`, so its confirm dialog never fired. Any
  button carrying both `data-confirm` and `data-bulk-action` — most notably
  bulk/permanent delete — executed with no prompt. The hook now checks
  `data-confirm` itself and calls `window.confirm()` before proceeding,
  mirroring `phoenix_html`'s native behavior; cancelling stops the click
  and the LiveView event is never pushed. Found while migrating
  `phoenix_kit_comments`, `phoenix_kit_posts`, and `phoenix_kit_entities` to
  BulkSelect — all three already pair `data-confirm` with a destructive
  bulk action and are fixed retroactively once they pick up this release.

## 1.7.186 - 2026-07-12

### Fixed
- **The 1.7.185 `phoenix_kit.js` self-heal never ran on hosts whose
  `mix.exs` was missing the `:phoenix_kit_js_sources` compiler — exactly the
  older installs that need it most.** Root cause (found by a downstream
  agent bisecting a host stuck on stale JS after upgrading): registering
  `:phoenix_kit_css_sources` and `:phoenix_kit_js_sources` was two SEPARATE
  `Igniter.Project.MixProject.update/4` calls against the same `mix.exs`
  `:compilers` key. The first call, hitting an absent key, has to insert
  `[atom] ++ Mix.compilers()` — a `++` call, not a literal list, since
  `Mix.compilers()` is a live call that can't be flattened at install time.
  The second call then lands on that `++` node instead of a list, and
  `Igniter.Code.List.prepend_new_to_list/2` (which only understands literal
  lists) silently fails into a `{:warning, ...}` easy to miss in the wall of
  `mix phoenix_kit.update`/`install` output — so the second compiler never
  actually got registered even though the run reported success. This is
  exactly what happened in production: a host had `:phoenix_kit_css_sources`
  from the first call but never `:phoenix_kit_js_sources` from the second,
  across many `phoenix_kit.update` runs, so the JS-hooks compiler (and
  therefore 1.7.185's vendoring fix) never ran.
  `PhoenixKit.Install.Common.ensure_compilers_registered/2` now registers
  every PhoenixKit compiler in ONE call — used by both `mix
  phoenix_kit.install` and `mix phoenix_kit.update` — and, for hosts already
  stuck in the broken `[atom] ++ Mix.compilers()` shape, descends into the
  literal list on the left of `++` and repairs it there instead of bailing.
  Covered by a regression test that reproduces the exact broken shape and
  asserts both compilers end up present, not just the notice claiming they
  do.

## 1.7.185 - 2026-07-11

### Fixed
- **`phoenix_kit.js` (core JS hooks — `RowMenu`, drawer/modal toggles, etc.)
  could silently 404 in production, breaking every PhoenixKit JS hook with no
  error anywhere.** It was only ever copied into a host's
  `priv/static/assets/vendor/` by the one-shot `File.cp/2` in `mix
  phoenix_kit.install`/`mix phoenix_kit.update` — a deploy that does `rm -rf
  priv/static` + asset rebuild without re-running `phoenix_kit.update` (true
  of most CI/CD pipelines) shipped the stale or missing file, so a bug fix
  landing in this same JS file could ship correctly in every other respect
  (compiled `.ex`/`.heex` changes apply the moment the dependency bumps) while
  the JS fix itself never reached the browser. The `:phoenix_kit_js_sources`
  compiler — which already regenerated `phoenix_kit_modules.js` (the
  external-module hook bundle) on every `mix compile` — now also vendors
  `phoenix_kit.js` itself the same way: self-healing after any `priv/static`
  wipe, with zero dependency on `phoenix_kit.update` ever running again after
  the initial install.
- **`JsIntegration.update_js_file/0` swallowed copy failures** (`rescue` →
  `Logger.warning` → `{:error, reason}` that its one caller, `mix
  phoenix_kit.update`, never checked) — `mix phoenix_kit.update` could report
  success while the vendored file silently stayed stale or absent. Now raises
  (`Mix.raise/1`) on a resolution/copy failure and verifies the destination
  file exists and is non-empty as a post-condition. `mix
  phoenix_kit.assets.rebuild` — billed as *the* asset-rebuild task — now also
  refreshes `phoenix_kit.js` via the same path, not just the CSS pipeline.

## 1.7.184 - 2026-07-11

### Added
- **`Checkbox` core component extended** (`PhoenixKitWeb.Components.Core.Checkbox`):
  `disabled` (previously silently dropped — not in the allowed globals),
  `wrapper_class` (styles the wrapping `<label>` — spacing, or
  `pointer-events-none` to lock a checkbox *without* excluding it from form
  submission the way `disabled` would), `title` (tooltip on the whole label,
  not just the box), and a `:description` slot for secondary helper text. The
  default slot now doubles as rich label content (badges, icons, conditional
  markup) overriding the plain `label` string when given.
- **`LayoutWrapper.app_layout` gains `page_section`/`page_section_path`** —
  an optional breadcrumb segment between "Admin Panel" and `page_title` (e.g.
  "Admin Panel / Users / Jane Doe" on a user detail page instead of jumping
  straight from "Admin Panel" to the user's name).

### Changed
- **Checkboxes across core migrated to `<.checkbox>`** (settings pages,
  registration/OAuth toggles, storage bucket/dimension forms, org tax
  toggle, `user_form`'s boolean custom field) so future daisyUI syntax or
  style changes are a one-file edit instead of a repo-wide sweep. Left
  hand-rolled where the shape doesn't fit a boolean toggle (role-assignment
  checkboxes and the image-format multi-select use `value={item}` collected
  via `Map.values/1`, not the hidden-false/checkbox-true pattern).
- **Users list/detail naming unified.** The admin page title now reads
  `@page_title` ("Users") instead of a hardcoded "User Management" that had
  drifted out of sync with it; the sidebar subtab is "Users" instead of
  "Manage Users".
- **User detail page now offers the same actions as the Users list's `⋮`
  menu** — Roles, Confirm/Unconfirm email, Activate/Deactivate, and (for your
  own profile) Settings, via the same `table_row_menu` component and
  `Auth`/`Roles` context calls. Delete is now hidden (not just rejected on
  click) when `Auth.can_delete_user?/2` says no, matching the list.
- **Users list's Location column explains itself when empty.** If
  `track_registration_geolocation` is off, every row now says "Tracking
  disabled" with a link to Settings → Users, instead of an unexplained
  per-row "No data" that looked like missing data rather than a disabled
  feature.

### Fixed
- **Row-action `⋮` menus could silently eat clicks on menu items (WebKit —
  i.e. every browser on iOS/iPadOS, plus desktop Safari).** The `RowMenu` JS
  hook portals its floating menu to `<body>` while open so it can escape a
  clipped table container; its "click outside closes the menu" listener only
  checked containment against the trigger's wrapper, not the (now
  elsewhere-in-the-DOM) menu itself. Clicking a menu item was treated as an
  outside click: the capture-phase listener closed and relocated the menu
  mid-dispatch, and WebKit drops an in-flight click when its target moves
  during capture — so the tapped action never ran. Fixed by also checking
  containment against the portaled menu.
- **Checkboxes with hidden-false-fallback markup weren't wrapped in a
  `<label>`** across settings pages (registration, notifications,
  multi-session, magic link, OAuth master/provider switches, storage bucket
  enable, org tax enable), so clicking the adjacent text did nothing —
  only the checkbox square itself was clickable. For the OAuth provider
  switches specifically (locked via `pointer-events-none` while the master
  switch is off), the lock moved from the checkbox to the wrapping label so
  wrapping it in `<label>` couldn't let a text click bypass the lock.

## 1.7.183 - 2026-07-11

### Fixed
- **Prefixed (`--prefix`) installs could fail to migrate.** `CREATE INDEX` was
  being called with a schema-qualified index name (`CREATE INDEX prefix.name ON
  ...`), which Postgres rejects outright — an index always lands in its table's
  schema, so only the table reference may be qualified. Affected
  `add_uuid_unique_indexes`/`drop_uuid_unique_indexes` (`uuid_fk_columns.ex`),
  `V56`, `V57`, and `V95`'s media-folder unique index. (#628)
- **Cross-schema false-positive existence checks on prefixed installs.** Several
  idempotency guards (`pg_constraint` lookups in `V35`, `V102`, `V113`, `V115`,
  `V118`, `V119`; an `information_schema.columns` lookup in `V95`) matched on
  constraint/column name alone, so an identically-named constraint or column
  already present in a *different* schema's table made the guard think it existed
  in the current schema too — silently skipping the `ADD CONSTRAINT`/`ADD COLUMN`.
  Fixed by anchoring each check to the target relation (`conrelid = '<prefix>.
  <table>'::regclass` / `table_schema = '<prefix>'`). Added an integration test
  that runs the full versioned migration chain into a named schema and asserts
  every index and column lands correctly. (#628)

## 1.7.182 - 2026-07-10

### Added
- **Fine-grained sub-permissions.** Modules can declare additive permissions under
  their base key via the optional `sub_permissions` field of `permission_metadata/0`
  (e.g. `"calendar.view_others"`), stored in `phoenix_kit_role_permissions.module_key`
  as composed dotted keys. A sub-permission implies its base: granting a sub
  auto-grants the base, revoking the base cascades its subs off, and every write
  path (`grant_permission/3`, `revoke_permission/3`, `set_permissions/3`) normalizes
  the set so no orphan sub-key row can persist. Modules check sub-grants with
  `Scope.can?/2` (key held **and** module enabled). The permission matrix renders
  subs as indented rows under their module. (#627)
- **`V141` — personal calendar events + participants** for the standalone
  `phoenix_kit_calendar` module: `phoenix_kit_calendar_events` (one implicit
  personal calendar per user, timed/all-day exclusive-end pairs with a CHECK,
  cascade on user delete, loose `location_uuid` link) and
  `phoenix_kit_calendar_event_participants` (loose `kind`/`target_uuid` refs with a
  snapshotted `display_name`, visibility resolved live against staff/CRM tables). (#627)
- **Reusable core UI components.** `SearchPicker` (client-instant typeahead with
  browse-on-focus, per-instance event scoping, `direction=up`, cross-source dedup,
  load-more paging), `PopoverPanel` (anchored rich-content popover, client-side
  open/close with click-away), and the `PkDialogDraft` JS hook (preserves an open
  form's draft across a LiveView reconnect). Both function components are imported
  into `PhoenixKitWeb`. (#627)

### Changed
- **Admin is now genuinely permission-gated.** Only `Owner` is hard-coded as
  all-access; `Admin` (and every other role) is governed by the permission matrix.
  Admin defaults to all keys via seeding/auto-grant, and a boot-time Task
  (`auto_grant_new_keys_to_admin/0`) fills newly-installed module keys — but an
  Owner's revocation now sticks everywhere, including fresh mounts (previously the
  system-role bypass ignored revocations on fresh mounts). The full-access fallback
  keys on **table presence** (`permissions_table_ready?/0`), not row count, so
  stripping a role bare can no longer restore access, and a DB blip fails closed. (#627)
- **`V142`** widens `phoenix_kit_role_permissions.module_key` `VARCHAR(50) → VARCHAR(120)`
  so composed sub-permission keys fit. (#627)
- **Role changes are authorized in the context.** `sync_user_roles/3` takes an
  `:actor` and drops changes the actor isn't allowed to make (a non-Owner can't
  grant or strip Owner/Admin); the last Owner can never be removed. The quick
  role-toggle and the permission-matrix revoke route through the same guards. The
  function now returns `{:ok, %{assignments, roles_before, roles_after}}` so audit
  logs record the delta **actually applied**, not the submitted set. (#627)
- **`Checkbox` `checked` default is now `nil`** ("derive from the field's value") —
  a non-nil attr default defeated the field clause's `assign_new`, so a field-bound
  checkbox always rendered unchecked. (#627)
- **`AdminPageHeader` accepts a `class`** to override its default bottom margin
  (e.g. `"mb-0"` when the page owns spacing). (#627)

### Fixed
- **Role/permission mutations are race-free under concurrent admins.**
  Transaction-scoped Postgres advisory locks + in-transaction re-reads: the last
  Owner can never reach zero (shared lock at `count_remaining_owners`), the matrix
  revoke re-reads the role's held keys under a `(role, base)` lock and rejects
  (`:unauthorized`) if a cascaded sub falls outside the actor's grantable set, and
  `set_permissions/3` locks the `Role` row so two concurrent calls can't leave the
  union of disjoint desired sets. (#627)
- **Post-merge review:** refactored `grant_permission/3` to satisfy
  `credo --strict` (removed a redundant `with` clause and one nesting level) — the
  base-then-sub cascade and rollback behavior are unchanged. (#627)

## 1.7.181 - 2026-07-10

### Changed
- **Admin settings pages modernized.** Replaced ad-hoc `<div class="divider">`
  headings across the General, Authorization, Users, Media, and Instance
  Dimensions pages with a reusable `<.section_header>` (icon + uppercase title +
  rule + optional actions slot). Per-field status echoes ("Selected: X | Saved:
  Y", always visible) are replaced by `<.unsaved_hint>`, which renders only when a
  field diverges from its saved value, so clean fields carry no noise. The four
  hand-copied ~95-line OAuth provider guides (Google/Apple/GitHub/Facebook)
  collapse into one `<.oauth_setup_instructions>` component with a `:steps` slot.
  Both new components live in `Components.Core.FormSection`. (#626)
- **Browser Tab identity group + live preview.** The site-icon and default-tab-
  title fields are merged into one "Browser Tab" group on the General page, with a
  live browser-chrome preview (icon + tab title + address bar) that updates as you
  type. The site icon and project logo now default to each other via
  `Settings.get_site_icon_uuid/0` and `get_logo_uuid/0` — setting either brands
  both the browser tab and the app chrome; the favicon and layout wrappers read
  through these resolvers. (#626)
- **Destructive resets now confirm.** The General "Reset ALL settings" and Instance
  Dimensions "Reset to Defaults" actions gained a `data-confirm` guard. (#626)
- **Dependency bump.** `saxy` 1.6.0 → 1.6.1.

### Fixed
- **Registration dirty-indicator missed two toggles.** The Users-page unsaved-
  changes hint for the registration group compared only `allow_registration` and
  `track_registration_geolocation`, so flipping `registration_show_username` or
  `enable_organization_accounts` left the group looking clean. It now checks all
  four keys. (#626)

### i18n
- **Storage-module flashes and page titles localized.** Every `put_flash` in the
  Media settings and Instance Dimensions LiveViews (bucket toggles, redundancy,
  variants, repair, dimension CRUD/reset) is wrapped in `gettext`/`ngettext` with
  proper `%{}` interpolation and correct pluralization for the redundancy-copies
  message. Full `.pot` re-extract with ru/et translations for all new strings.
  Also dropped a dead drag-drop `<script>`/`<style>` block from the Media settings
  template (targeted element ids that no longer exist). (#626)

## 1.7.180 - 2026-07-09

### Added
- **V140 migration: `phoenix_kit_warehouse` tables.** Creates the six tables backing
  the standalone `phoenix_kit_warehouse` package — `phoenix_kit_warehouse_stock`,
  `_inventory_documents`, `_internal_orders`, `_supplier_orders`, `_goods_receipts`,
  `_goods_issues`. Intra-module FKs are kept (`supplier_orders.internal_order_uuid` →
  `internal_orders`, `goods_receipts.supplier_order_uuid` → `supplier_orders`,
  `goods_issues.internal_order_uuid` → `internal_orders`), as is
  `performed_by_uuid` → `phoenix_kit_users`. The host-specific `sub_order_uuid` FK is
  replaced by a generic `source_refs` JSONB column resolved through a host-registered
  callback, so the package depends on no particular "order" concept. Tables ship
  empty — nothing reads or writes them yet. (#624)

### Fixed
- **V140 `quantity >= 0` check was silently skipped on non-`public` schemas.** The
  constraint-existence guard matched `pg_constraint.conname` alone, but constraint
  names are unique per `(schema, table)` — not globally. A second PhoenixKit install
  into another schema in the same database found the first schema's constraint, took
  the `IF NOT EXISTS` false branch, and created `phoenix_kit_warehouse_stock` with no
  non-negative-quantity check while reporting success. Now scoped with
  `AND conrelid = '<prefixed table>'::regclass`, matching V41/V72/V78.
  (post-merge review)
- **V140 `source_refs` reverse lookups were unindexed.** Dropping the indexed
  `sub_order_uuid` FK column in favour of JSONB removed the index behind "which
  documents reference this order?", turning it into a sequential scan. Added
  `USING GIN (source_refs)` on `internal_orders`, `supplier_orders`,
  `goods_receipts`, and `goods_issues`. (post-merge review)
- **V140 `phoenix_kit_warehouse_stock` could not be queried by location.** Its only
  index was `UNIQUE (item_uuid, location_uuid)`, which a composite btree cannot serve
  for a bare `WHERE location_uuid = $1` — the most natural query against a stock
  table, and one every other warehouse table already had an index for. Added
  `phoenix_kit_warehouse_stock_location_uuid_index`. (post-merge review)

### Changed
- **V140 moduledoc corrected.** It justified `item_uuid` / `location_uuid` /
  `storage_folder_uuid` / `supplier_uuid` as FK-less "cross-package references", but
  all four targets (`phoenix_kit_cat_items`, `phoenix_kit_locations`,
  `phoenix_kit_media_folders`, `phoenix_kit_cat_suppliers`) are created by this same
  core migration set — V122 already declares an FK on `location_uuid`. The doc now
  states the truth: an FK is possible, it is omitted pending a delete-semantics
  decision, and referential integrity for those columns is not enforced by the
  database. Also genericised the private downstream app's table names, which were
  rendering on hexdocs. (post-merge review)
- **Dependency bumps.** `ecto` 3.14.0 → 3.14.1, `postgrex` 0.22.2 → 0.22.3,
  `plug` 1.20.2 → 1.20.3, `mdex_native` 0.2.4 → 0.2.5.

## 1.7.179 - 2026-07-08

### Added
- **V139 migration: per-dashboard `config` column.** Adds a JSONB `config` column
  (`NOT NULL DEFAULT '{}'`) to `phoenix_kit_dashboards` for dashboard-level
  presentation state (layout mode, pixel-mode zoom, home tier, per-tier markers),
  read and written whole like `layout`. Idempotent (`ADD COLUMN IF NOT EXISTS`);
  unblocks the dashboards module's next Hex floor. (#623)
- **Installer wires a `viewport_width` LiveSocket connect param.**
  `mix phoenix_kit.install` / `mix phoenix_kit.update` now add
  `viewport_width: window.innerWidth` to the host's LiveSocket `params:` (rewritten
  into a closure so reconnects re-read the width). Responsive PhoenixKit LiveViews
  (e.g. the dashboards builder) use it to resolve the right layout tier server-side
  on the first render instead of a client-hook round-trip; everything degrades
  gracefully without it. The rewrite is deliberately conservative — it anchors on
  the real `new LiveSocket(` call, only patches a `params:` object at the options'
  top brace depth, blanks string literals and comments before depth counting, and
  refuses every ambiguous shape with a manual-instructions notice rather than risk
  corrupting host `app.js`. Pinned by 13 tests in `js_integration_test.exs`. (#623)

### Fixed
- **daisyUI 5.0.x modal scrollbar-gutter strip.** daisyUI 5.0.x reserves a scrollbar
  gutter while a modal/drawer is open and paints it with a base-100 trick that
  mismatches on non-base-100 pages, so classic-scrollbar users saw an uncovered strip
  at the window's right edge on every admin page. An unlayered
  `:root:has(.modal-open, …) { scrollbar-gutter: auto }` counter-rule in the admin
  `LayoutWrapper` and the core root layout beats the layered original regardless of
  stylesheet order. Documented trade-off: scrollable pages get a small reflow on
  modal open instead of the mispainted strip. Upstream fixed this properly in daisyUI
  5.1.0–5.6.x; an `AGENTS.md` TODO tracks removing the rule once hosts upgrade. (#623)

### Changed
- **Migration-history doc block tracks V139.** `Migrations.Postgres`'s version list
  now carries the `### V139` entry and the `⚡ LATEST` marker, which the merge left
  pointing at V138. (post-merge review)

## 1.7.178 - 2026-07-07

### Added
- **Extensible resource deep-links across the activity feed and notifications.**
  External modules can declare how their resource types link to their pages via the
  new optional `resource_links/0` `PhoenixKit.Module` callback — a
  `resource_type => resolver` map where a resolver is a module implementing
  `resolve_comment_resources/1`, a path-template string (`"/admin/widgets/:uuid"`),
  or a `%{"path" => ..., "title" => ...}` map. Merged into `PhoenixKit.ResourceLinks`
  with a documented precedence (resolver module → module template → host
  `comment_resource_paths` setting). (#621)
- **Integration activities deep-link to their Settings edit page.**
  `Integrations.log_activity` now stamps the connection's storage-row `resource_uuid`,
  and the new `PhoenixKit.Integrations.ResourceLinks` resolves `"integration"`
  resources to `/admin/settings/integrations/:uuid`, titled `provider / name`. (#621)
- **Actor and target identities are now clickable in the activity feed and the
  notifications admin list.** A lightweight `resource_email_link/1` component links
  the who-did-it / who-it's-for emails to those users' admin pages, falling back to
  plain text when unresolved. (#621)
- **"All notifications" overview on the Notifications admin page.** A paginated table
  (via `Notifications.admin_list/1`) shows every notification's recipient, rendered
  text, per-user seen/dismissed state, and date. (#621)

### Fixed
- **Jobs admin scheduled-jobs tab no longer crashes.** The template referenced
  `job.id` / `job.resource_id`, which do not exist on the
  `PhoenixKit.ScheduledJobs.ScheduledJob` schema (`@primary_key {:uuid, ...}`,
  `field :resource_uuid`) — every render raised `KeyError`. Now uses `job.uuid` /
  `job.resource_uuid`, consistent with the `repo.get(ScheduledJob, uuid)` lookup. (#622)
- **Notifications admin pagination no longer renders a runaway button list** for an
  out-of-range `?page=` query param. An explicit `//1` range step makes an
  out-of-range page yield an empty range instead of a descending one. (post-merge review)

### Security
- **hackney 1.25.0 advisory batch (EEF-CVE-2026-47069 / 47071 / 47075 / 47076)
  reviewed and accepted — no code change.** There is no fixed hackney 1.x; the fix
  lives only in hackney 4.x, which the dependency tree cannot reach while
  `ueberauth_apple` pins `httpoison < 3.0` (→ `hackney < 2.0`). Real-world exposure is
  low: hackney is only the default HTTP backend for `ex_aws` and the Apple-OAuth path
  (fixed endpoints, no SOCKS5, no user-controlled URLs/cookies/query strings). Full
  analysis and the eventual upgrade trigger:
  `dev_docs/audits/2026-07-07-hackney-cve-2026-advisories-audit.md`.

## 1.7.177 - 2026-07-07

### Changed
- **Auth form fields now render their leading icon *inside* the input.** The
  email/username/password/organization-name fields on the registration, login,
  and magic-link forms previously showed their icon in a separate label above
  the field; they now follow daisyUI 5's `<label class="input">` wrapper pattern
  so the icon sits inside the field border (text labels are retained above). The
  shared `PhoenixKitWeb.Components.Core.Input` `:icon` slot renders inside the
  field accordingly. The organization account-type `<select>`'s label icon was
  dropped for consistency (daisyUI has no icon-inside variant for selects).
- **Updated phoenix to 1.8.9, phoenix_live_view to 1.2.6, websock_adapter to
  0.6.0, and ex_ast to 0.12.9.**

### Fixed
- **The `auth_seo_no_index` regression test no longer raises at mount and breaks
  `mix test`.** Its stand-in `PublicHostAppLive` mounted through
  `:phoenix_kit_mount_current_scope`, whose `handle_params` hook needs a non-nil
  `socket.router` — which `live_isolated/3` never provides. The test now drives a
  routed, test-only LiveView (`PhoenixKitWeb.Test.PublicHostAppLive`, routed only
  under `Mix.env() == :test`) via a real HTTP request, and asserts against the
  actual rendered `noindex`/`nofollow` meta tags a crawler would see rather than
  the raw `:seo_no_index` assign. (#620)

## 1.7.176 - 2026-07-06

### Added
- **Activity feed entries now deep-link to the resource they acted on.** A new
  shared `PhoenixKit.ResourceLinks` resolver turns an entry's
  `(resource_type, resource_uuid)` into a navigable link to the underlying
  record, reusing the comments-moderation two-tier mechanism (auto-registered
  handler modules for `post`/`file`/`user`, then `comment_resource_paths` string
  templates). A core `<.resource_link>` chip renders the resolved title with a
  thumbnail or type icon on both the Activity index Subject cell and the detail
  page, falling back to the resolved user email and then a truncated uuid.
  Resolution is batched per resource type and fails open to the uuid fallback,
  so a missing or throwing handler never crashes the admin feed. (#619)
- **Image rotation in the media viewer is now persisted.** Rotating an image in
  the admin media viewer saves the angle to the file row's `metadata["rotation"]`
  and restores it on the next open, via fresco 0.8's opt-in `persist_rotation`
  server bridge. Every viewer (including public galleries) seeds the saved
  orientation on first paint, but only admin-context hosts — the `MediaBrowser`
  modal (gated on `@admin`) and the admin-only media-detail page — write back to
  the shared file row. (#618)

### Changed
- **Updated fresco to 0.8.0, etcher to 0.7.2, tessera to 0.3.2.** fresco 0.8's
  new `persist_rotation` bridge backs the media-viewer rotation persistence
  above.

## 1.7.175 - 2026-07-06

### Added
- **Sitemap settings page now exposes Router Discovery exclude patterns,
  protected pipelines, custom URLs, and static routes.** These four settings
  (`sitemap_router_discovery_exclude_patterns`, `sitemap_protected_pipelines`,
  `sitemap_custom_urls`, `sitemap_static_routes`) previously had no admin UI —
  changing them required editing the database directly. They're now editable
  from a new "Advanced" section on `/admin/settings/sitemap`, with the
  exclude-patterns field validated against `Regex.compile/1` before saving
  (an invalid pattern is rejected with an inline error instead of being
  silently dropped later) and pipeline names restricted to identifier-safe
  characters.
- **Sitemap sources can now declare their own settings via
  `PhoenixKit.Modules.Sitemap.Sources.Source.sitemap_settings_schema/0`.**
  This new optional callback lets a source module (built-in or contributed by
  another package, e.g. an Entities module) describe boolean/string/integer
  settings with a label, help text, and default; the sitemap settings page
  discovers and renders them automatically, reading/writing through
  `PhoenixKit.Settings` the same way built-in settings work. No core source
  implements it yet — this is purely an extension point for
  settings that don't already have a home in the core UI.

### Fixed
- **Toggling a source-contributed boolean setting no longer crashes the sitemap
  settings page when the field declares a non-boolean default.** The extension
  toggle handler now reads the current value through the same rescue-protected
  path the render uses, so a source that declares `%{type: :boolean, default: nil}`
  (allowed by the `term()` default type) can't raise `FunctionClauseError` from
  `Settings.get_boolean_setting/2`'s `is_boolean/1` guard on click.

## 1.7.174 - 2026-07-05

### Fixed
- **Host layouts are no longer double-wrapped, and both `{@inner_content}` and
  `render_slot(@inner_block)` work.** PhoenixKit LiveViews used to set their
  native Phoenix `:layout` to the host's configured `config :phoenix_kit, layout:`
  — but every page *also* applies that same host layout itself via
  `LayoutWrapper.app_layout` in its render. So a host layout with visible chrome
  rendered twice (doubled header / nav / footer, body singular), and a host layout
  written in the Phoenix 1.8 idiom (`slot :inner_block` + `render_slot(@inner_block)`)
  crashed with `KeyError: key :inner_block not found` because Phoenix invokes a
  `:layout` with `@inner_content` only.

  The native `:layout` is now a pure passthrough (`PhoenixKitWeb.Layouts.app`,
  which renders only `{@inner_content}`), making `app_layout` the **single owner**
  of the host layout — applied exactly once. `app_layout` hands the host layout
  both a real `inner_block` slot and a lazily-derived `@inner_content`, so a host
  layout renders correctly whether it uses `{@inner_content}` (the documented
  contract) or `render_slot(@inner_block)`. A misconfigured layout function falls
  back to PhoenixKit's own layout instead of 500-ing every page.

  Hosts that previously worked around the double-wrap (e.g. detecting slot vs.
  `@inner_content` in their own layout) can drop that workaround.

## 1.7.173 - 2026-07-05

### Changed
- **DaisyUI theme names are now translatable.** `ThemeConfig`'s `@labels` map
  (System, Light, Dark, and 34 other theme names) was hardcoded without gettext
  wrapping, so it rendered in English regardless of locale. Adds
  `translated_label/1` and `translated_label_map/0`; the theme-switcher dropdown
  and the layout wrapper's client-side JS label map now use them.
- **User dashboard nav gains an `:authenticated_links` attribute.**
  `PhoenixKitWeb.Components.UserDashboardNav.user_dropdown/1` now accepts
  `authenticated_links` (default `[:admin, :dashboard, :settings, :logout]`),
  mirroring the existing `:guest_links` narrowing. Lets a host app hide menu
  entries its own navigation already covers (e.g. `:dashboard`). Narrowing-only:
  `:admin` still requires `Scope.admin?/1`, so it can never grant access.
- **Dependency bumps:** `ex_ast` 0.12.5 → 0.12.7, `mdex` 0.13.2 → 0.13.3,
  `mdex_native` 0.2.3 → 0.2.4, `swoosh` 1.26.2 → 1.26.3 (lockfile).

### Fixed
- **V80 migration could corrupt email-template data on a retried multi-version
  run.** V80 was the only version module that never recorded its own
  `COMMENT ON TABLE phoenix_kit IS '80'` checkpoint. Because update migrations
  run with `@disable_ddl_transaction` (each step auto-commits individually), a
  failure in a later version would cause a subsequent `mix ecto.migrate` to
  resume from V80 and re-run its `ALTER COLUMN ... TYPE jsonb USING
  jsonb_build_object('en', ...)` against already-converted columns,
  double-wrapping the values (`{"en": {"en": "..."}}`). V80 now writes its
  checkpoint like every other version and guards the conversion on the column's
  current type so it's idempotent. (#612)

### i18n
- **French UI strings translated.** French was ~5% translated (1688 of 1776
  msgids blank in `default.po`, all 8 blank in `phoenix_kit.po`) despite most
  strings being reachable from public-facing pages (theme switcher, "Log in",
  etc.). All ~1782 blank entries across `default.po` / `phoenix_kit.po` /
  `errors.po` are now translated to idiomatic French (formal register, plural
  forms per entry).
- Localized three previously-hardcoded labels in the user dashboard nav
  ("Dashboard", "Settings", "Log Out") via `gettext/1`, matching the rest of the
  component; new msgids extracted across all locale catalogs.

### Internal
- Ignore a `Gettext.Backend`-generated `call_without_opaque` Dialyzer false
  positive (Expo's opaque `PluralForms` struct passed into
  `Gettext.Plural.plural/2`) so `mix precommit` passes on Erlang 28 / Elixir
  1.19. Already on the latest `gettext` 1.0.2 / `expo` 1.1.1; no user code is
  involved.

## 1.7.172 - 2026-07-03

### Changed
- Added the `rustler` dependency as optional (lockfile). `mdex_native` builds
  from source (instead of downloading a precompiled NIF) when
  `MDEX_NATIVE_BUILD=1` is set in the environment; that path requires rustler
  itself, not just `rustler_precompiled`.

### Fixed
- **Gettext locale falling back to default on publishing content routes.**
  `process_locale/1` only matched `path_params["locale"]`, but the internal
  routes `phoenix_kit_publishing` generates for localized content
  (`get "/:language/:group"`) bind the segment as `"language"` instead. The
  mismatch meant `Gettext.put_locale/1` was never called on those requests, so
  translations silently rendered in the site default locale regardless of the
  URL prefix (e.g. `/en/articles` rendering Russian nav text).

## 1.7.171 - 2026-07-03

### Changed
- **`RouterDiscovery` sitemap source compiles exclude/include-only patterns
  once per collection instead of once per route per pattern.** Same behavior,
  fewer `Regex.compile/1` calls; invalid patterns (e.g. a bare `"*"`, which is
  not a valid regex) are now logged instead of silently swallowed. Two more
  default excludes: `^/__` (internal/technical routes, e.g. Publishing's
  dispatch catch-all scope) and `^/maintenance$` (PhoenixKit's reserved
  maintenance page) — both mainly load-bearing for installs with a non-default
  `url_prefix`. (#614, #615)
- **New optional `reserved_route_prefixes/0` module callback** +
  `PhoenixKit.ModuleRegistry.all_reserved_route_prefixes/0`. Lets a module
  declare top-level route path segments it owns (e.g. `["legal"]`), so a
  database-driven dispatcher (e.g. Publishing's `/:language/:group/*path`
  catch-all) can avoid swallowing another module's route just because a
  same-named record happens to exist in its own data. Iterates all installed
  modules (not just enabled ones), since the guarded route is normally
  compiled into the host router independent of the module's runtime
  enabled/disabled toggle. Declaring a prefix is passive on its own — it
  changes nothing until a dispatcher consults it. (#614)
- Bumped `phoenix_live_view` 1.2.4 → 1.2.5, `plug` 1.20.1 → 1.20.2, `makeup`
  1.2.1 → 1.2.2 (lockfile).

### Fixed
- **V70 migration crash on installs missing the legacy `email_log_id` /
  `matched_email_log_id` integer FK columns.** The re-backfill guards checked
  that the UUID companion columns existed but not the legacy integer columns
  the raw SQL actually joins on, so an install where those legacy columns were
  already dropped hit an `undefined column` error. (#613)
- **Sitemap no longer advertises URLs while the SEO module's `noindex`
  directive is active.** `/sitemap.xml` (XML and HTML) now publishes an empty
  but schema-valid `<urlset>` instead of the full URL list whenever
  `seo_no_index` is enabled, and toggling the directive invalidates + triggers
  regeneration of the cached sitemap so it doesn't keep serving a stale file.
  (#614)
- **Sitemap `RouterDiscovery` no longer masks richer entries from other
  sources.** `RouterDiscovery` enumerates every GET route generically; when a
  content source (Publishing, Entities, …) emitted a richer entry (priority,
  `canonical_path`, hreflang alternates) for the same URL, the old
  `loc`-based dedup kept whichever entry was listed first — always the
  generic `RouterDiscovery` one — silently dropping priority and hreflang
  alternates from the sitemap. Dedup now always prefers the richer,
  non-`RouterDiscovery` entry regardless of source order. (#615)
- **`seo_no_index` now reaches a host application's own public LiveViews.**
  Previously only `LayoutWrapper.app_layout_inner/1` (PhoenixKit's own
  admin/plugin views) set the `:seo_no_index` assign that `root.html.heex`
  reads for the `noindex,nofollow` meta tags, so a host app's own public
  LiveView — mounted through PhoenixKit's `on_mount` chain for
  `current_user`/locale support but rendered with its own layout — never got
  the directive even with it enabled. The assign is now set from the
  `handle_params` hook shared by every PhoenixKit `on_mount` variant. (#616)

## 1.7.170 - 2026-06-29

### Added
- **Audio playback in the media viewer.** Opening an audio file (in the in-place
  modal or `/admin/media/:uuid`) now renders an interactive WaveSurfer waveform
  with a play/pause button and click-to-seek instead of a document placeholder.
  WaveSurfer is lazy-loaded via a dynamic CDN import only when audio is opened (no
  npm/hex dependency, no cost on other pages); the hidden native `<audio>` is the
  playback source and the fallback (native controls) if the library can't load.
  Audio is detected by mime, `file_type`, **or** extension, so mp3s stored with a
  generic `application/octet-stream` mime are still recognised. Grid, list, and
  stack views show a music-note icon and an "AUDIO" label. (#611)

### Changed
- **Folder sidebar handles deep names.** Deeply nested folders keep their full
  names and the tree scrolls horizontally instead of truncating to a few
  characters; the root→current active path is drawn bolder (4px, was 2px) and
  centred on the axis so the branch you're on stands out. (#611)

### Fixed
- **Media browser display dropdown label.** The display dropdown now reads
  "Stacks" in Stacks mode (was stuck on "Grid"), driven by a lookup over the view
  options instead of a two-way grid/list assumption. (#611)
- **Notifications dropdown overflow.** A tall notifications list now scrolls
  vertically instead of wrapping into extra columns — daisyUI `menu`'s
  `flex-wrap: wrap` is replaced with a plain `flex flex-col flex-nowrap` list. (#611)
- **Users table actions menu.** The `…` actions menu is pinned to the far-right
  edge so it no longer drifts into a wide auto-width cell when columns are
  hidden. (#611)
- **Account switcher overflow.** Long emails are truncated (with a hover tooltip)
  and the role badge is pinned, fixing horizontal overflow in the user
  dropdown. (#611)

## 1.7.169 - 2026-06-28

### Added
- **V138 migration — CRM v1 interaction-tracker tables.** Five `phoenix_kit_crm_*`
  tables laying down the CRM module's first data model: `contacts` (profile with an
  **optional** `user_uuid` login link, partial-unique so it's 1:1 only among linked
  rows), `companies`, `company_memberships` (M:N contact↔company with free-form
  `role_in_company` + `department` + `is_primary` on the edge), `interactions`
  (logged interaction: type/when/subject/body + subject contact + owner user), and
  `interaction_parties` (flat resolvable "who was involved" — `raw_name` always
  kept, `contact_uuid`/`staff_person_uuid` resolve under an exclusive-arc CHECK,
  `party_snapshot` JSONB freezes the party's profile as-of-then). `staff_person_uuid`
  is a soft ref (no FK) so the optional staff module stays optional. Migration-only;
  idempotent up/down. (#610)
- **Optional description slot on `Core.Checkbox`.** Passing an inner block renders a
  muted helper line under the now-bold label and switches the row to top alignment;
  with no slot the checkbox renders exactly as before. (#610)

### Fixed
- **`delete_folder_completely` no longer destroys a file shared into a folder
  outside the deleted subtree.** A file also linked (via `FolderLink`) into an
  external folder is now re-homed there — consuming that link — instead of being
  hard-deleted, which previously cascaded the file's external links away and
  silently stripped it from the unrelated folder. Files confined to the subtree are
  still permanently deleted. Covered by two new integration tests. (#610)

## 1.7.168 - 2026-06-27

### Changed
- **Sharper non-full-res thumbnails for grid/stack media cards.** Added a `:card`
  size mode to `MediaThumbnail` and switched the grid card, stack card, and
  stacks-view grid card to it. Cards now prefer the 400px baked Etcher thumbnail /
  300px `small` variant instead of the blurry 150px `thumbnail`, so media piles
  render crisply at 2× DPI. (#609)

### Fixed
- **`:card` thumbnails no longer load a full-res `original` when intermediate
  variants are missing.** A file with a `thumbnail` but no `small`/`medium` (partial
  variant generation, legacy upload, or admin-disabled dimensions) now falls back
  to the light 150px `thumbnail` before the multi-megabyte `original` — keeping the
  card payload light as intended. Reconciled the `MediaThumbnail` moduledoc and
  `attr` docs with the actual `:card` priority chain. (#609 follow-up)
- Added pure-function unit tests for `MediaThumbnail.resolve_url/2` covering every
  size mode and the `:card` fallback chain.

## 1.7.167 - 2026-06-26

### Added
- **Basecamp-style "stacks" view for the MediaBrowser.** A third view mode
  (alongside grid/list) renders top-level folders as photo "piles" with loose
  files under "Everything else". Clicking a pile opens its grid inline (multiple
  open at once, newest on top) with a FLIP fly-out/fly-back animation that fires
  only on explicit open/close — restores on refresh/navigate-back are instant and
  flash-free (`prefers-reduced-motion` respected). Open stacks persist across
  refresh/navigation in `localStorage` (`StackMemory` hook), scoped per
  virtual-root. Each stack paginates independently (`load_more_stack`, one page at
  a time) so a folder with thousands of files stays fast, and supports drag-drop
  of media between stacks / "Everything else" with the drop outline tinted to the
  folder's own colour. Per-file kebab menu (Download / Move / Trash) on stack
  cards mirrors grid view. (#608)
- **`ViewportPopover` JS hook.** Clamps the folder Edit-header popover to the
  viewport (flips it to open upward when there's more room above, pins Save/Done
  as a non-scrolling footer), so Save stays reachable when the browser is embedded
  low in a page. (#608)

### Changed
- Bumped the `:ex_ast` dependency 0.12.0 → 0.12.1 (lockfile).

### Fixed
- **`Created by %{name}` ru/et translation.** The folder-header creator label was
  added to the Estonian/Russian catalogs as a `fuzzy` auto-fill that both
  mistranslated it ("Create" imperative) and dropped the `%{name}` placeholder —
  inert today (gettext falls back to English for fuzzy entries) but a latent
  landmine if the flag were ever cleared. Corrected to `Создал %{name}` /
  `Loonud %{name}` and de-fuzzed so the proper translation is active.

### i18n
- Estonian + Russian translation of the newly-surfaced MediaBrowser strings (and
  other recent additions); previously-empty catalog entries dropped from 14 to 1
  in both locales. `%{...}` placeholders, markdown links and arrows preserved.
  (#608)

## 1.7.166 - 2026-06-25

### Added
- **Annotated media thumbnails baked from Etcher shapes.** A file's Etcher
  annotation shapes (rectangles, circles, marker/freehand strokes) are baked into
  a single deterministic `thumbnail_annotated` PNG variant (ImageMagick, with the
  geometry→draw mapping delegated to `Etcher.Raster`), so the markup is visible in
  the MediaBrowser grid without rendering shapes live for every viewer. The
  `AnnotationThumbnailJob` Oban worker debounces regeneration in the background;
  its unique constraint is computed from the installed `Oban.Job.states/0` minus
  the terminal states (robust across Oban 2.20/2.23) and excludes `:completed`, so
  a finished regen never throttles the next edit. The grid prefers the baked
  variant with a checksum-based cache-bust and falls back to the plain thumbnail.
  Gated behind a project-wide media setting (`storage_annotated_thumbnails_enabled`,
  off by default) — an "Annotated Thumbnails" toggle in Media Settings → Media
  Configuration. Bumps the `:etcher` dependency to `~> 0.7`. (#607)
- **`VariantGenerator.store_prepared_variant/5`.** Stores an already-rendered
  variant file (produced outside the resize pipeline, e.g. the baked annotated
  thumbnail) through the existing stats / bucket-storage / `FileInstance` /
  file-location tail. (#607)

### Changed
- **Referrals extracted into the standalone `phoenix_kit_referrals` module.** The
  referral-codes feature (schemas, business logic, admin UI) leaves core for the
  auto-discovered package, mirroring how posts and user_connections are
  structured; core keeps the database tables (migrations untouched). A new
  runtime-dispatch facade, `PhoenixKit.Users.Referrals`, resolves the installed
  module by its `PhoenixKit.Module` key and dispatches via `apply/3`, so core has
  **no compile-time dependency** on the package. With the module absent every call
  degrades safely: the system reads as disabled, lookups return `nil`, and
  `use_code/2` is a no-op (the referral field disappears from signup). The
  module's admin tab and routes now flow through generic module discovery
  (`admin_tabs/0`, `settings_tabs/0`, `route_module/0`) instead of the removed
  hardcoded subtab and route injection. (#607)

## 1.7.165 - 2026-06-24

### Added
- **`sitemap_sources/0` module callback for zero-config sitemap source
  registration.** External modules can contribute their own
  `Sitemap.Sources.Source` modules (e.g. Entities) to the generated sitemap with
  no host-app configuration, mirroring route / CSS / JS auto-discovery. Collected
  via `ModuleRegistry.all_sitemap_sources/0` from **enabled** modules and appended
  to the base source list (deduplicated, order-preserving). A host
  `config :phoenix_kit, sitemap: [sources: [...]]` now acts as a base list that
  module sources extend rather than fully replace. (#603)
- **Migration V137 — email event deduplication + `aws_message_id` backfill.**
  Backs the `Emails.Event` schema's declared unique constraints with real partial
  unique indexes (one per `(email_log_uuid, event_type)` for single-occurrence
  types; one per `(email_log_uuid, event_type, occurred_at)` for open/click),
  removing pre-existing duplicates first. Backfills the indexed `aws_message_id`
  column from the legacy `headers` JSONB (conflict-safe via `DISTINCT ON` +
  `NOT EXISTS`). Adds pg_trgm substring-search indexes for the admin email list,
  per-template open/click analytics composites, and an archiver body-compression
  partial index. Host apps pick this up via `mix phoenix_kit.update`. (#604)
- **`user` comment-resource handler.** A comment attached to a user resolves to
  the user's display name, `/admin/users/view/:uuid`, and avatar thumbnail in the
  comments moderation admin instead of a bare uuid. (#605)
- **`notification_default_link` setting.** A catch-all destination for
  notifications that have no link of their own. Defaults to `/dashboard`
  (authenticated-only; guarded to a no-op when the user dashboard is disabled);
  clear the field to make such notifications non-clickable. Built through
  `Routes.path/1`, so it carries the URL prefix and the recipient's locale. An
  opt-in `config :phoenix_kit, warn_unlinked_notifications: true` logs how to wire
  a link when a clicked notification has neither. (#605)

### Changed
- **Link-less notifications read as informational.** The notifications bell shows
  a default cursor (not a pointer) for a notification with no effective target,
  and clicking it still clears its unread state rather than appearing broken.
  (#605)

### Fixed
- **A disabled module's source no longer leaks into the flat sitemap.**
  `all_sitemap_sources/0` now aggregates from **enabled** modules only, so a
  disabled module contributes nothing even in flat-sitemap mode — where the
  generator force-collects sources and bypasses each source's own `enabled?/0`.
  The previous `all_modules/0` aggregation relied solely on that per-source gate,
  which flat mode skips. (#603)
- **Comment `file` resource links no longer double-prefix under a non-root
  `url_prefix`.** Comment-resource handlers must return a raw path (the comments
  module applies `Routes.path/1` once); the `file` handler pre-applied it. Both
  the `file` and new `user` handlers now return raw paths, matching `post`. (#605)
- **Notifications bell reads its default-link setting from cache.**
  `default_link/1` used the uncached `Settings.get_setting/2` on a hot path (the
  sticky bell's `refresh/1` runs on mount and on every notification PubSub event);
  it now uses the ETS-backed `get_setting_cached/2`. (#605)

## 1.7.164 - 2026-06-22

### Fixed
- **`user.email_unconfirmed` notifications regained their settings link.** PR #602
  replaced the broad `"user." <> _` link rule with an explicit `@account_actions`
  whitelist but omitted `user.email_unconfirmed` — the toggle-sibling of
  `user.email_confirmed`, emitted from the same admin code path and declared an
  `"account"` notification type. Its notification lost its `/dashboard/settings`
  click-through. It is now in the whitelist, so the whole account toggle is
  consistent.

### Changed
- **`user.email_unconfirmed` now renders dedicated icon/text.** Previously it fell
  through to the generic `hero-bell` + humanized-action display while
  `user.email_confirmed` showed a tailored message. It now renders
  `hero-exclamation-circle` + "Your email is no longer confirmed.", matching its
  sibling.

## 1.7.163 - 2026-06-22

### Fixed
- **Notification click-through links.** `Render.link_for/1` mapped only
  `"user." <> anything` → `/dashboard/settings` (wrongly catching `user.followed`)
  and everything else → `nil`, so social notifications (`post.*`, `comment.*`)
  navigated nowhere and follow notifications opened the settings page. The
  account-action → settings mapping is now an explicit whitelist;
  `user.followed` / `post.*` / `comment.*` / `user.deleted` / unknown actions
  return `nil` so the emitter's `notification_link` metadata drives the deep-link.
- **Notification links now carry the recipient's locale prefix.**
  `Render.render/2` accepts a locale that is threaded into `Routes.path`; the
  notifications bell receives `"locale"` in its session (from `LayoutWrapper`)
  and passes it at click time. Previously the link was built in the sticky bell's
  process with no locale, so it used the default locale instead of the user's.

## 1.7.162 - 2026-06-18

### Added
- **`MarkdownEditor` `:prompt_insert` action** — a host can trigger a client-side
  `window.prompt` (e.g. a video URL) and insert the result by substituting
  `%{value}` in a template, via
  `send_update(..., action: :prompt_insert, prompt:, template:)`, with no inline
  script of its own. (#601)

### Changed
- **`Components.Core.MarkdownEditor` is now driven by a LiveView hook**
  (`window.PhoenixKitHooks.MarkdownEditor` in `phoenix_kit.js`) instead of an
  inline `<script>` plus inline `onclick`/`onmousedown` handlers. The old
  approach broke under a strict Content-Security-Policy (a nonce never authorizes
  inline event handlers; an absent nonce blocks the `<script>`) and failed on
  LiveView navigation (a patched-in `<script>` never re-executes), so the toolbar
  and image insertion only worked after a full page refresh. Toolbar buttons now
  carry `data-md-action` attributes; server commands (`insert-at-cursor`,
  `set-content`) arrive via `handleEvent` filtered by `global_id` so multiple
  editors on one page don't cross-fire; toolbars ship hidden and the hook reveals
  them, with a `<noscript>` hint when JS is off. The public component API
  (`:insert_at_cursor`, the `{:editor_content_changed}` host message, the attrs)
  is unchanged. (#601)
- **`confirm_modal` confirm button gains `phx-disable-with`** so a fast
  double-click can't fire `on_confirm` twice (e.g. double-enqueue an AI
  translation). Applies to every confirm modal; no behavior change beyond the
  in-flight disable. (#601)

### Fixed
- **`Utils.Geolocation` now uses `Req`** instead of calling Finch directly
  against a `PhoenixKit.Finch` pool that nothing starts (not PhoenixKit's empty
  supervisor, not the installer, which only starts `Swoosh.Finch`). Every lookup
  previously raised "unknown registry", was swallowed by the rescue, and
  registration fell back to IP-only — so `registration_country` / `region` /
  `city` were never populated. IP geolocation now works with no host supervisor
  setup (`Req` rides its own auto-started pool). `retry: false` keeps the lookup
  single-shot on the registration path.
- **`MarkdownEditor`'s unsaved-changes `beforeunload` prompt no longer fires
  after a successful save** — the hook's local dirty flag now resets when the
  server reports `save_status` `"saved"`, instead of staying armed for the page's
  life after the first keystroke (most hosts never push the `changes-status`
  event that previously cleared it).

### Removed
- **`MarkdownEditor` `script_nonce` attr** — unused now that the editor is
  hook-driven. (#601)
- **Orphaned `priv/static/assets/phoenix_kit_markdown_editor.js`** — the old
  standalone inline-script implementation, superseded by the `MarkdownEditor`
  hook in `phoenix_kit.js` and referenced by nothing (the installer copies only
  `phoenix_kit.js`).

### i18n
- Gettext-wrapped the `MarkdownEditor` heading-button title (`Heading %{level}`,
  previously a hardcoded string) and refreshed the JS-disabled `<noscript>` hint
  copy. Both are translatable; the translation catalogs pick them up on the next
  resync. (#601)

## 1.7.161 - 2026-06-18

### Changed
- **`Components.Core.Markdown` now renders via `MDEx`** instead of `earmark`.
  The `<.markdown>` component consolidates onto the same Rust-NIF renderer
  already shared across the dependency tree (`leaf`, `phoenix_kit_comments`) —
  completing the migration begun in 1.7.158. Output is preserved: GFM
  (strikethrough/table/autolink/tasklist), smart typography,
  `<code class="language-…">` fenced code blocks, and raw-HTML passthrough on
  `sanitize={false}` (the default path still runs `HtmlSanitizer`).
- Updated the publishing format guide to name MDEx as the markdown renderer.

### Removed
- **`earmark` direct dependency.** It was retained only for
  `Components.Core.Markdown`; with that component on `MDEx`, the dep and its
  `mix.lock` entry are removed. `earmark_parser` remains transitively via
  `ex_doc` and is unaffected.

## 1.7.160 - 2026-06-17

### Fixed
- **V122 migration on pre-locations databases** (issue #598) — `V122` creates
  `phoenix_kit_location_spaces` with a required FK to `phoenix_kit_locations`,
  a table created only in `V91`. Because the locations tables were added to an
  already-released `v91.ex`, any database that passed V91 *before* that addition
  never received the parent table, so V122 aborted the whole migration
  transaction with `42P01 undefined_table`. `V122.up/1` now
  `create_if_not_exists`-backfills `phoenix_kit_locations` (mirroring V91's
  final shape) before building the FK — an idempotent no-op where V91 already
  created it, and a repair where it was missing.

## 1.7.159 - 2026-06-17

Staff-support core changes (V136 employment history, Activity per-resource
filter, media picker hardening, embedded-LiveView identity) plus follow-up
review fixes. These changes landed on `main` after 1.7.158 without a version
bump; recorded here.

### Added
- **V136 migration** — `phoenix_kit_staff_employments`, a per-person history of
  employment spans (employment type, translatable `job_title`, department/team
  snapshot, date range, `work_location`, `notes`). A partial unique index
  enforces one open (current) span per person; the matching
  `phoenix_kit_staff_people` columns are kept as a denormalized mirror of the
  current span (not dropped). Backfills one open span per existing person
  (guarded, retry-safe). `@current_version` → 136.
- **`PhoenixKitWeb.Users.Auth.assign_embedded_current_user/2`** — reconstructs
  `:phoenix_kit_current_user` / `:phoenix_kit_current_scope` on an off-router
  embedded LiveView mount from a host-supplied `session["current_user_uuid"]`.
  No-ops on a router mount, degrades to anonymous for an absent/unknown/inactive
  uuid, and reconstructs identity (not authorization). Reference consumer:
  `phoenix_kit_projects`.
- **Upload-only media picker** — `MediaSelectorModal` gains a `browse: false`
  mode that hides the library grid/search/filter, leaving a pure uploader
  (uploaded files auto-select).
- `update_user_custom_fields/3` gains `:broadcast` and `:ensure_definitions`
  options (both default `true`, so existing callers are unchanged).

### Changed
- `PhoenixKit.Activity.list/1` (and `count/1`) now honour a `:resource_uuid`
  filter, and the admin Activity page (`/admin/activity`) reads a `resource_uuid`
  URL param — so a module can deep-link a per-resource feed. Previously
  `:resource_uuid` was silently ignored, leaking every same-type resource's
  events into a per-resource view.
- `MediaSelectorModal` constrains uploads to the active type filter, shows
  filter-aware copy, excludes trashed / system-managed files from the browse
  list, and gives each instance a unique `<dialog>` id so two pickers on one
  page don't collide.
- Admin **Activity page** UI follow-ups (PR #600): the filter toolbar fits one
  row on mobile (Module / Mode / Action / Type as compact dropdowns), a
  persisted grid/list Display toggle, and a mobile-friendly list view. The
  user form's Cancel / primary buttons are reordered (Cancel left, primary
  right) to match the rest of the admin UI.

### Fixed
- The manage-users **and** activity grid/list view toggles no longer register
  their internal `users_view_mode` / `activity_view_mode` preference as a
  user-facing custom-field definition (it was leaking into the Customize Columns
  modal) and no longer broadcast a `user_updated` event — so toggling the view
  stops re-querying the users list for every connected admin.
- The Activity page's new filter dropdowns preserve the `resource_uuid`
  deep-link scope (a per-resource feed no longer reverts to all activity when a
  filter is picked).
- The media picker now rejects off-type uploads server-side. The client `accept`
  list is fixed when the upload is first allowed and can't track the in-modal
  type dropdown, so an image/video picker could still store an off-type file;
  `MediaSelectorModal` re-checks the type on upload and rejects mismatches.
- The accepted-types hint is shown in the upload-only media picker (it was
  hidden in `browse: false` mode, the one place it's most useful).

### i18n
- Internationalized the full-page media selector and the Jobs / Languages admin
  page headers; added the new picker copy strings (et, ru).

## 1.7.158 - 2026-06-17

Centralize the MDEx (markdown) dependency in core.

### Changed
- **`mdex` is now a direct dependency of `phoenix_kit`** (`~> 0.13`), so every
  module shares one resolved version through the core dependency tree instead of
  each declaring its own and risking version mismatches — the same arrangement
  already used for `leaf`. Modules that render markdown (e.g.
  `phoenix_kit_comments`) call `MDEx` directly and should rely on it being
  provided transitively via `phoenix_kit` rather than declaring their own
  `mdex` dep.

## 1.7.157 - 2026-06-17

Core support for the `phoenix_kit_comments` admin work — file-comment resolution
and an annotation deep-link — plus admin navbar/MediaBrowser layout fixes and a
dependency refresh.

### Added
- **File-comment resource resolution.** `PhoenixKit.Annotations.resolve_comment_resources/1`
  maps `"file"` comment resources (including annotation discussions anchored via
  `metadata.annotation_uuid`) to the file's display name and admin media path, plus a
  signed `"thumbnail"` URL for images — so the comments moderation admin can link a
  thumbnail chip instead of showing a bare uuid. Registered as the `"file"` handler by
  `phoenix_kit_comments`, gated on this module being loaded.
- **Annotation deep-link.** `MediaDetail` reads `?annotation=<uuid>` and pushes
  `etcher:select-shape`; a new `phoenix_kit.js` bridge retries `layer.selectShape(uuid)`
  until the Etcher canvas layer is ready, so a comment's chip lands on the file with its
  shape selected. (No-ops on readonly shapes and on the static mount.)
- **Plugin admin pages can forward `page_title`/`page_subtitle` to the navbar.** The plugin
  admin layout now passes them through to `app_layout`, so plugin pages can drop their
  in-content header and show the title/subtitle in the navbar breadcrumb (matching the core
  media page).

### Changed
- **Dependency refresh:** `finch` 0.22 → 0.23, `phoenix_live_view` 1.2.1 → 1.2.3,
  `sourceror` 1.12.0 → 1.12.2, `tailwind` installer 0.5.0 → 0.5.1, and `req` pinned to
  0.5.17.
- **MediaBrowser admin-page layout.** Always show the sidebar "Folders" header, align the
  breadcrumb row flush with it, and drop the page padding so the browser fills the admin
  media page.

### Fixed
- **Mobile admin navbar breadcrumb.** When a page has a title, the `Admin Panel /` prefix
  is hidden below `sm` (and the title truncates) so it no longer overlaps the
  theme/notifications controls.
- **Media browser hero header z-index.** The hero's `z-30` (and the toolbar dropdowns'
  `z-20`) are confined to the card's own stacking context via `isolate`, so they no longer
  paint over the mobile drawer/navbar.
- **Media list view tablet columns.** The Type/Size columns now cross over to the folded
  mobile meta line at the same `md` breakpoint as Date, so they're no longer double-rendered
  (column + meta line) in the `[sm, md)` tablet band.

## 1.7.156 - 2026-06-16

MediaBrowser folder UX polish (folder-aware search, a name-it modal, an
active-branch sidebar highlight, and a clean mobile layout) plus dependency
upgrades.

### Added
- **Folder results in media search.** A name search in the MediaBrowser now
  surfaces matching *folders* alongside the matching files, scoped exactly like
  the file search (a folder's direct children when inside one, the whole subtree
  at a scope root, everything at the real root). Backed by a new
  `PhoenixKit.Modules.Storage.search_folders/3`.
- **New-folder name modal.** Creating a folder opens a modal to name it — with
  an `"untitled"` / `"untitled N"` placeholder default when left blank — instead
  of immediately dropping an inline-rename `"untitled"` folder into the sidebar.
  Cancel adds nothing. The `FolderExplorer`'s create button now emits
  `open_new_folder_modal` (was `create_untitled_folder`).
- **Active-branch highlight in the folder sidebar tree.** The guide-line
  connectors from a root folder down to the current folder are darkened (same
  hue, bolder alpha) so you can trace the branch you're inside. Suppressed in
  trash view.

### Changed
- **Cleaner MediaBrowser mobile layout.**
- **Dependency upgrades:** `leaf` 0.2 → 0.3 (its markdown backend swapped from
  `earmark` to the `mdex` Rust NIF — transparent to PhoenixKit, which keeps its
  own direct `earmark` dep for `Components.Core.Markdown`), `tailwind` installer
  0.4 → 0.5, `floki` 0.38.4.

### Fixed
- **Folder rename now updates the hero header title.** Renaming a folder from
  the sidebar keeps the hero header (and an open Edit-header panel) in sync when
  the renamed folder is the one being shown — it no longer kept the pre-rename
  name.
- **Media sidebar active-turn corner.** Sharp for a mid-branch turn, rounded for
  the last child.

## 1.7.155 - 2026-06-15

Makes the integration provider registry capability-discoverable, so consumers
(e.g. `phoenix_kit_ai`) can build provider lists dynamically instead of
hardcoding them.

### Added
- **`PhoenixKit.Integrations.Providers.with_capability/1`** — returns all
  providers (built-in + external-module) that declare a given capability, in
  `all/0` order. An AI module can render its provider picker from
  `with_capability(:ai_completions)` so a newly-registered chat provider
  surfaces automatically, with no hardcoded list.
- **`PhoenixKit.Integrations.Providers.base_url/1`** — returns a provider's
  primary REST API base URL (or `nil`). The `:ai_completions` providers
  (OpenAI, OpenRouter, Mistral, DeepSeek) now declare a `:base_url`, letting
  consumers derive a default endpoint base from the registry.

### Changed
- `@type provider` now documents the optional `:base_url`, `:validation`, and
  `:instructions` keys that real provider maps already carry (typespec accuracy
  only — no runtime change).

### Added
- **OpenAI integration provider** (`PhoenixKit.Integrations.Providers`). A new
  built-in `api_key` provider for OpenAI, alongside OpenRouter / Mistral /
  DeepSeek / ElevenLabs. It appears automatically in the admin Integrations UI —
  no migration or host changes needed. Connect with a single API key from
  platform.openai.com → API Keys; **Test Connection** validates it against
  `GET https://api.openai.com/v1/models` using standard `Authorization: Bearer`,
  so the generic `authenticated_request/4` helper works for consumers too.
  Declared capabilities cover OpenAI's range: `:ai_completions`,
  `:ai_embeddings`, `:image_generation`, `:text_to_speech`, `:speech_to_text`.

## 1.7.153 - 2026-06-15

Adds **ElevenLabs** as a built-in integration provider for text-to-speech and voice generation.

### Added
- **ElevenLabs integration provider** (`PhoenixKit.Integrations.Providers`). A new
  built-in `api_key` provider for ElevenLabs' audio AI, alongside OpenRouter /
  Mistral / DeepSeek. It shows up automatically in the admin Integrations UI — no
  migration or host changes needed. Connect with a single API key from
  ElevenLabs → Settings → API Keys; **Test Connection** validates it against
  `GET https://api.elevenlabs.io/v1/user` using ElevenLabs' custom `xi-api-key`
  header (not `Authorization: Bearer`). Declared capabilities span the full audio
  range: `:text_to_speech`, `:speech_to_text`, `:sound_effects`,
  `:music_generation`. Consumers reference the connection by uuid and set the
  `xi-api-key` header themselves (via `get_credentials/1`) — the generic
  `authenticated_request/4` helper is Bearer-only and does not fit ElevenLabs'
  scheme.

## 1.7.152 - 2026-06-15

Fixes two user-menu language-switcher bugs on locale-prefixed / default-locale pages.

### Fixed
- **`user_dropdown` / guest dropdown no longer crash on a bare `/:locale`
  path.** `remove_locale_from_path/1` fed the post-strip remainder to
  `Path.join/1`, which raised `FunctionClauseError` on an empty list — so
  rendering the in-menu language switcher on a path that is *only* a locale
  segment (e.g. `/ru`, `/fr`, `/en-GB`) 500'd the page. A path that reduces to
  just a locale now returns `/`, so the switch links resolve correctly (`/ru`,
  `/fr`, …). Surfaced by hosts adopting locale-prefixed landings (1.7.150+).
  Locale detection stays narrow (2-char base or 5-char dialect) so a real 3-char
  page segment like `/faq` isn't mistaken for a locale.
- **Current language now highlights on the default locale.** The in-menu list
  compared the enabled dialect against `@current_locale` with full-dialect
  equality, so on the default page (where the active locale resolves to a fixed
  dialect like `en-US` while English is enabled as `en-GB`) nothing matched and
  the active language wasn't marked. Highlighting now compares **base codes**
  (`en`/`en-GB`/`en-US` all match), matching `Core.LanguageSwitcher`, and works
  whether the caller passes a base or a dialect.
- **Guest dropdown trigger matches the authenticated avatar shape.** The
  logged-out trigger was a round `hero-user-circle`; it's now a rounded-rectangle
  placeholder (`w-10 h-10 rounded-lg`) with a person silhouette, consistent with
  the signed-in avatar.

## 1.7.151 - 2026-06-15

Anonymous (guest) state for the user-menu widget, so one dropdown serves both signed-in and logged-out visitors and always offers a language switcher.

### Added
- **Guest dropdown in `UserDashboardNav.user_dropdown/1`.** The anonymous
  state, previously a bare "Login" button, now renders the same dropdown shape
  as the authenticated state: a generic "not signed in" trigger
  (`hero-user-circle`) opening a menu with guest links — **Log in**, **Sign up**,
  **Forgot password**, **Magic link** — plus the shared language switcher. A host
  can now rely on this single widget for everyone and drop a separate standalone
  switcher. Guest links are gated by the `allow_registration` /
  `magic_link_login_enabled` settings (log in and forgot-password always show).
- **`:show_language_switcher` attr** (default `true`) on `user_dropdown/1` —
  hides the in-menu language list in both states, for hosts that keep a
  standalone switcher and want to avoid a duplicate.
- **`:guest_links` attr** (default `[:login, :register, :reset, :magic_link]`) —
  narrows which guest links may appear; the per-feature settings gates still
  apply, so it can only narrow, never force-enable a disabled feature.

### Changed
- The authenticated and guest dropdowns now share one internal
  `language_menu_section` component, so both states render an identical
  language list. The guest switcher reuses the same URL logic, so locale links
  resolve correctly on locale-less pages (`/` → `/ru`, building on 1.7.150).

## 1.7.150 - 2026-06-15

Fixes locale-prefixed root URLs so anonymous visitors can switch language on a parent app's `/:locale` landing page.

### Fixed
- **`Routes.path("/", locale: x)` no longer emits a trailing slash.** The
  locale-prefixed root was built as `/{locale}/` (e.g. `/ru/`); Phoenix routers
  don't match a trailing slash, so a parent app's `/:locale` landing route 404'd
  and the language switcher's link on `/` led nowhere for anonymous visitors.
  Core now emits `/{locale}` (e.g. `/ru`) for the bare root while every other
  path is unchanged. The standalone
  `LanguageSwitcher.language_switcher_dropdown` routes through this primitive, so
  its anonymous-landing links resolve correctly. phoenix_kit keeps its
  URL-as-truth locale model (no session/cookie locale) — the parent app declares
  a `/:locale` landing and the switcher's link now reaches it.

## 1.7.149 - 2026-06-15

Structured staff skills: the V135 migration (PR #594) replaces the free-text staff `skills` column with a first-class, translatable skill entity.

### Added
- **V135 migration — structured staff skills.** Replaces the free-text
  `phoenix_kit_staff_people.skills` column with a first-class, translatable
  `phoenix_kit_staff_skills` entity (globally unique by `lower(name)`) and a
  `phoenix_kit_staff_person_skills` many-to-many join. Each skill carries its
  own per-skill, translatable proficiency levels (`levels` JSONB array of
  `{id, name, translations}`) plus an `allow_multiple_levels` boolean; the
  join's `proficiency_levels` JSONB array holds the selected level ids. The
  comma-separated free-text is split, trimmed, case-insensitively de-duplicated
  into skill rows, linked to each person, and the column is dropped — guarded on
  the column's existence so a partial re-run is a safe no-op. Lossy by design:
  per-locale `translations["skills"]` overrides don't map to structured skills
  and are stripped (structured skills carry their own translations going
  forward). `down/1` is a lossy rollback (re-adds an empty `skills` column).
- **Partial birthday index** on `phoenix_kit_staff_people(date_of_birth)`
  (active + non-null DOB only) so `Staff.upcoming_birthdays/1` scans a small
  index instead of the full people table.

### Fixed
- **V135 data migration caps skill tokens at 255 chars.** The source
  `skills` column is unbounded `TEXT` but `phoenix_kit_staff_skills.name` is
  `VARCHAR(255)` (the `Skill` changeset's max), so a >255-char token would raise
  `value too long` and wedge the migration on every host. Both the skill INSERT
  and the link-INSERT join now truncate with `LEFT(trim(tok), 255)` so a long
  token stores and links on the same truncated form.

## 1.7.148 - 2026-06-14

Follow-up to 1.7.147: scopes the embedded-`MediaBrowser` header fix and adds `URLSigner.put_dzi_url/3` test coverage.

### Fixed
- **Scoped `MediaBrowser` header fallback** — an embedded browser scoped to a
  customized folder was rendering that folder's header customizations
  (description / logo / cover / creation-info) under the all-files / orphaned /
  trash / search views as well as at its root, so the `<h2>` title ("All Files" /
  "Trash" / …) disagreed with the metadata below it. The scope folder's header
  now shows only at the effective root. `header_folder_target/6` is the single
  source of truth shared by the nav data path and the template, and the hero
  cover-image arm is gated so the scope-folder cover can't bleed into those views
  either. The header stays read-only at the scoped root.

## 1.7.147 - 2026-06-14

Media viewer deep-zoom: progressive resolution + DZI tile streaming via Tessera 0.3.

### Added
- **Progressive resolution + DZI tile streaming** in the media canvas viewer
  (`/admin/media/:uuid`, the in-place modal, and the lightbox), backed by the
  rewritten **Tessera 0.3.1** (now a Fresco peer layer, no OpenSeadragon). The
  viewer opens on the cheap **medium** variant and swaps **medium → large** on
  zoom; past the sharpest raster it streams **DZI tiles of the original** (only
  the visible region) for images over 4K, or shows the full **original** raster
  for ≤4K. Tiles ride Fresco's stage transform so they stay glued to the image
  during pan/zoom; tile generation respects EXIF orientation.

### Changed
- `URLSigner.put_dzi_url/3` is now the single source of truth for the signed
  `"dzi"` manifest URL, shared by the media browser, detail page, and lightbox
  (previously only the browser produced it, so deep zoom was missing on the
  other two). Built in the non-localized route scope so it resolves on any
  locale.
- `{:tessera, "~> 0.3"}` (was `~> 0.2`); the jsDelivr hook pin tracks `v0.3.1`.

## 1.7.146 - 2026-06-14

### Added
- **`js_sources/0`** — a zero-config mechanism for external PhoenixKit modules to
  ship LiveView JS hook bundles into the host app, mirroring `css_sources/0`. A
  module declares `%{app:, file:, global:}` entries; the new
  `:phoenix_kit_js_sources` compiler resolves each bundle via `:code.priv_dir/1`
  (Hex + path deps), IIFE-wraps and concatenates them into
  `priv/static/assets/vendor/phoenix_kit_modules.js`, and folds each
  `window.<Global>` into `window.PhoenixKitHooks` (already spread into the host's
  `LiveSocket`). One stable `<script>` tag is added by `mix phoenix_kit.install`;
  `mix phoenix_kit.update` backfills it on existing installs. The compiler fails
  loudly on a missing bundle, a duplicate global, or a non-identifier global.
  Hook **names** must also be namespaced to stay unique across modules and the
  core hooks (documented on the callback) — the merge is last-write-wins.

### Changed
- PhoenixKit self-doc links now point at `phoenix-kit.hexdocs.pm` instead of the
  `hexdocs.pm/phoenix_kit` path form (install/update task footers, the
  not-installed warning, and the per-module-i18n guide).

### Fixed
- Media sidebar tree-state persistence no longer clobbers other `custom_fields`
  keys. `persist_tree_state/1` re-reads the user fresh from the DB before
  writing (matching `persist_user_view_mode/2`), because
  `update_user_custom_fields` replaces the entire `custom_fields` map with no
  server-side merge. The 1.7.145 version wrote from the stale in-socket copy, so
  expanding/collapsing a folder could silently revert a `custom_fields` value
  saved elsewhere since the browser loaded (e.g. notification preferences).
- The CSS/JS source compilers are now **prepended** to `Mix.compilers()` instead
  of replacing the list when a host has no `compilers:` key yet (the `css_sources`
  analogue had the same latent bug), in both install and update.
- `seed_modules_js_file/1` surfaces a seed-write failure as an installer warning
  instead of swallowing it (the file is still recreated on the next compile).

## 1.7.145 - 2026-06-13

Media browser overhaul: folder hero header + full customization, unified
toolbar, a shared folder-tree component, persisted tree state, and selection UX.

### Added
- **Folder hero header**: the folder header is now a hero block with a cover
  image background (or a soft folder-color gradient, neutral on non-folder
  views), faded to the page at the bottom, with the title, description,
  created-by avatar + name, date, and file count overlaid. New
  `cover_file_uuid` column on `phoenix_kit_media_folders` (migration **V134**).
- **Folder header customization** (V134, same migration): a **logo/icon**
  (`logo_file_uuid`, transparent-PNG aware), a **header size** (`header_size`:
  small / medium / large), and independent per-element visibility toggles —
  title, icon, **creator**, **date created**, **file count**, description, and
  background (`header_show_*` columns). Creator / date / file-count are separate
  toggles so users show only the pieces they want.
- **Edit header** panel to edit a folder's name + description together (muted,
  clickable "No description — add one" placeholder when empty), plus **logo** and
  **cover image** selectors that open the shared media picker scoped to the
  folder — pick an existing image or upload a new one; **Remove** clears it (the
  image stays in the folder). Opens as a popover dropping from the Edit header
  button (not a centered modal), ordered name/description → logo/background →
  size → toggles.
- **Display / Sort / Filter toolbar**: Display switches grid/list, Sort orders
  by newest/oldest/name/size, Filter narrows by file type. Each trigger shows
  the current selection with a chevron; sort + filter run through
  `list_files_in_scope`.
- **Long-press to multi-select**: holding a file/folder card ~450ms (without
  moving) enters select mode and selects it (subtle vibrate where supported);
  the trailing click is swallowed. Via `setupLongPress` on the `MediaDragDrop`
  hook + a `long_press_select` server handler.
- Media settings **Quick Actions** gained info icons + hover tooltips, plus a
  **Find Orphaned Files** and **Repair Media Module** action.

### Changed
- **Unified header/toolbar**: the toolbar, search, Add Media, Select and folder
  meta all live inside the hero. Layout is view-controls-left / actions-right,
  with secondary actions (Select, New folder) in a ⋯ overflow; the redundant
  result count and the standalone grid/list toggle were dropped. Add Media
  toggles in place to a fixed-width **Cancel** (toolbar doesn't shift), search is
  an inline expand-on-click field, and the list view has a sticky column header.
- **Media page header moved into the admin topbar** as a breadcrumb
  (`{ProjectName} Admin Panel / Media · subtitle`) via a new `page_subtitle`
  attr on the app layout, freeing the full content area for the browser. Generic
  — any admin page that sets `page_title` gets the breadcrumb.
- **Shared folder-tree node**: the sidebar and the Move modal now render the same
  parameterized `FolderExplorer.folder_tree_node` (config: navigate/toggle event,
  rename, drag, hover), so guide-line and structure changes stay in sync. The
  duplicate `move_folder_option` was removed.
- **Sidebar tree state persists server-side**: expanded folders + collapsed flag
  are stored in user meta and rendered on first paint (like the grid/list view
  mode), removing the collapsed-then-jump-open flash after connect.
- **Select-mode toolbar** reworked: it stays inside the header (no jump on
  toggle), with a clear **Done** exit button + count + Select all / Clear on the
  left and bulk Move / Download / Delete (Delete red) on the right, shown only
  when something is selected.
- **Folder tree guide lines** (sidebar + Move modal): per-row connectors with a
  `├` tee and a rounded `└` curl on the last row, elbows that reach the item,
  and 50% line opacity via an inheriting `--pk-tree-line` variable.
  `tree_connector_class/2` + `tree_line_color/1` are shared helpers.
- Media folder sidebar rows are fully clickable to open a folder (chevron still
  toggles, rename pencil still renames).
- Decluttered the media settings page: top banners folded into the
  subtitle/Quick Actions and the stale "Advanced Features Coming Soon" card
  removed.

### Fixed
- Edit header popover click-away routed its event to the parent LiveView and
  crashed with a `FunctionClauseError`; it now targets the component.
- Transparent-PNG logos render transparently (`object-contain` + drop shadow)
  instead of as a black/white box.
- Colored folders now show the blue selection highlight (the inline folder color
  was outranking the tint; it's now `!important`).
- Uncolored tree guide lines no longer render solid black (daisyUI-5 renamed
  `--bc`; replaced with a valid `currentColor`-based color).
- The orphaned-files view no longer mixes in folder cards (files only).
- The folder-header description no longer shows a large top blank line
  (`whitespace-pre-line` preserved the HEEx-indented expression's newline).
- A folder's chosen cover/logo no longer appears as a loose file in that
  folder's grid/list — `list_files_in_scope/2` excludes the folder's own
  `cover_file_uuid`/`logo_file_uuid` (the design intent the schema documented but
  didn't enforce). They remain real files, re-selectable from the header picker.
- Header media (creator avatar, cover, logo) is loaded only when its
  `header_show_*` toggle is on, dropping up to three queries + two signed-URL
  builds per folder navigation; the Edit-header previews still load them on open.
- `cover_file_uuid` / `logo_file_uuid` are now FK columns to
  `phoenix_kit_files(uuid)` with `ON DELETE SET NULL`, so deleting a referenced
  file self-heals the header reference; `header_size` is now `NOT NULL` (V134).
- Media file sort is case-insensitive for name and carries a stable `uuid`
  tiebreaker so equal sizes/names/timestamps can't shuffle across pages.
- Sidebar tree state persists from the in-socket user instead of re-reading the
  user from the DB on every expand/collapse; toolbar sort/filter/size handlers
  ignore out-of-whitelist values instead of crashing the component.

## 1.7.144 - 2026-06-10

### Added
- `table_row_menu_link/1` now accepts `target` and `rel` attributes directly
  (via its `:global` include list), so host apps can render external links that
  open in a new tab — e.g. `target="_blank" rel="noopener noreferrer"` — without
  tripping the "undefined attribute" compile warning under
  `--warnings-as-errors`.

## 1.7.143 - 2026-06-11

### Changed
- Media browser header now reads top-to-bottom in a logical order: breadcrumb →
  title → folder description → toolbar. The contextual title (folder name, or
  "All Media" / "Trash" / "Orphaned Files" / "All Files" at the roots) moved out
  of the action toolbar and above the folder-description block, so the title sits
  directly under the breadcrumb and the description reads as belonging to it.

## 1.7.142 - 2026-06-10

### Fixed
- Media browser breadcrumb now always renders in the same place (no
  disappearing row / layout jump when navigating to the root). At the root it
  shows "All Media" (or the scope folder name) as the current, non-link crumb
  instead of vanishing; inside a folder it stays the clickable path.

## 1.7.141 - 2026-06-10

### Added
- Media detail page (`/admin/media/:file_uuid`) now has a back arrow to the
  left of the title. It does a browser **history back**, returning the user to
  exactly where they were before opening the file — the folder grid they came
  from (the MediaBrowser keeps the open folder in the `?folder=` query) rather
  than always the media root. Falls back to `/admin/media` for a direct/shared
  load with no history.

## 1.7.140 - 2026-06-10

### Changed
- Bump `leaf` 0.2.22 → **0.2.23** (dep min in `mix.exs` + the jsDelivr CDN pin
  in `phoenix_kit.js`, `@v0.2.22 → @v0.2.23`). 0.2.23 is a large, default-
  preserving Leaf release: GFM task lists & callouts, custom/unknown tag
  round-trip preservation, an expanded host-integration/authoring API, RTL +
  symbol/date inserts, and an Obsidian-style hybrid live preview for list
  markers and checkboxes. Stored markdown and existing usage are unchanged.

## 1.7.139 - 2026-06-10

### Fixed
- External module CSS auto-discovery is now deterministic at compile time.
  `PhoenixKit.ModuleDiscovery` scanned `:application.loaded_applications/0`, so on
  a cold build (`rm -rf _build && mix compile`) a dep whose app hadn't been loaded
  yet was invisible — `_phoenix_kit_sources.css` was generated **empty**, and under
  Tailwind v4 `@import "tailwindcss" source(none);` the dep's classes (e.g.
  responsive `sm:/md:/xl:table-cell` columns) were never compiled, silently
  breaking admin UI in the host. Discovery now walks dependency `ebin` directories
  on the code path (reading each `<app>.app` + the persisted `@phoenix_kit_module`
  beam attribute via `:beam_lib.chunks/2`) independent of load state, matching the
  module's documented "no module loading required" contract.

### Added
- The `:phoenix_kit_css_sources` compiler now emits a loud build warning when it
  generates zero `@source` lines while phoenix_kit-dependent deps are present on
  disk, turning a hard-to-diagnose missing-CSS mystery into a one-line warning.

## 1.7.138 - 2026-06-09

### Fixed
- Media browser: removed the dead client-side view-mode persistence left over
  from the 1.7.136 server-side switch. The `MediaDragDrop` hook no longer writes
  the now-unread `phoenix_kit_media_view_mode` localStorage key (or the
  `data-view-mode` button attrs / `dataset.mediaView`) — view mode is persisted
  per-user in `custom_fields` and rendered on first paint.
- Media browser: the current-folder header description editor now cancels on
  Escape, matching the grid-card and list-row editors.

### Changed
- Media browser: folder-description textareas are debounced
  (`phx-debounce="300"`) so editing no longer round-trips on every keystroke,
  and the description editor resolves the folder from already-loaded assigns
  instead of issuing a redundant query on open/save.

## 1.7.137 - 2026-06-09

### Fixed
- Bump `leaf` 0.2.21 → **0.2.22** (dep min in `mix.exs` + the jsDelivr CDN pin
  in `phoenix_kit.js`, `@v0.2.21 → @v0.2.22`) for the markdown-link round-trip
  fix: editing rich-text content with a link no longer doubles it into
  `[[label](url)](url)` on each save (affected comments/posts editors).

## 1.7.136 - 2026-06-08

### Fixed
- Media browser no longer flashes grid view before switching to the user's
  saved list view on load. The grid/list preference is now persisted per-user
  in `custom_fields["media_view_mode"]` and rendered on first paint (dead +
  connected render), instead of being restored from localStorage via a
  post-connect `set_view_mode` push. The `MediaDragDrop` hook's localStorage
  restore was removed; the toolbar toggle still drives `set_view_mode`, which
  now persists server-side.

## 1.7.135 - 2026-06-08

### Added
- **Folder descriptions** — media folders can now carry an optional free-text
  description that admins can add/edit/clear. Surfaced in three places in the
  Media browser, all sharing one save path:
  - Inside a folder: a prominent "Add a folder description" button / info box
    under the breadcrumb, with an inline editor.
  - Grid view: a clamped description line under each folder card + an
    "Add/Edit description" entry in the card's ⋯ menu (inline editor on the card).
  - List view: a new **Description** column after Path + the same ⋯ menu entry
    (inline editor in the row).
- **V132** migration adds the `description TEXT` column to
  `phoenix_kit_media_folders` (`ADD COLUMN IF NOT EXISTS`, idempotent), and
  `Folder`'s changeset casts it with a 2000-char cap.

## 1.7.134 - 2026-06-08

### Changed
- The `/admin/media` page now fills the full content width and viewport height
  instead of floating in a width-capped, fixed-height card. The page wrapper
  drops `container mx-auto` for `w-full` + `h-[calc(100dvh-4rem)]`, and the
  browser's file grid scrolls internally rather than the whole page growing.

### Added
- `PhoenixKitWeb.Components.MediaBrowser` gains a `fill_height` attr (default
  `false`). When `true`, the browser grows to fill its parent (`flex-1`)
  instead of the bounded `h-[72vh] max-h-[48rem]` card — used by the full-page
  admin media view; modal/gallery embeds keep the bounded default.

## 1.7.133 - 2026-06-08

### Removed
- **AI translation pipeline moved out of core into the `phoenix_kit_ai` plugin** (PR #586).
  Core keeps only the `phoenix_kit_ai_endpoints` / `_prompts` table migrations (the single
  versioned chain) and the generic, AI-agnostic `ai_translate` attr on
  `Components.Core.LanguageSwitcher`. Removed from core:
  - `PhoenixKit.Modules.AI` + `.Translatable` / `.Translations` / `.TranslateWorker` /
    `.Translation` (the whole pipeline) — re-homed to `PhoenixKitAI.*`.
  - The optional `PhoenixKit.Module.ai_translatables/0` callback and its
    `PhoenixKit.ModuleRegistry.all_ai_translatables/0` / `find_ai_translatable/1` discovery —
    discovery now lives in `PhoenixKitAI.Translatables` as a duck-typed scan over
    `ModuleRegistry.all_modules/0`.
  - `PhoenixKitWeb.Components.AITranslate{,.Embed,.FormBinding,.FormGlue}` (the AI-translate
    modal UI), and the `Utils.Routes.ai_path/0` helper (now `PhoenixKitAI.Routes.ai_path/0`).

  **Breaking for direct consumers of these APIs.** Feature modules
  (publishing / catalogue / projects) now depend on `phoenix_kit_ai` and implement
  `PhoenixKitAI.Translatable`; they float to this core release via `~>` minimums. Hosts that
  used the in-core `Modules.AI.*` / `AITranslate.*` modules must switch to the plugin.

## 1.7.132 - 2026-06-07

### Added
- **`PhoenixKitWeb.Components.AITranslate.Embed`** — a `use`-able macro that
  wires the host side of the AI-translate modal so consumers stop hand-copying
  it. Via `attach_hook` lifecycle hooks it injects the six `ai_*` `handle_event`
  clauses (`ai_toggle_modal`, `ai_select_endpoint`, `ai_select_prompt`,
  `ai_select_scope`, `ai_generate_prompt`, `ai_translate_lang`) and the
  `{:ai_translation, …}` `handle_info` clause, composing with the host's own
  handlers (non-AI events/messages pass straight through). Form re-sync defaults
  to assigning both `:changeset` and `:form`; hosts whose sync differs override
  `ai_translate_assign_form/2`. Because lifecycle hooks run before the host's
  own callbacks and `:halt` on the events they own, a host clause for those AI
  events is shadowed — the moduledoc documents this so the AI clauses aren't
  re-implemented in the host.
- **V131** migration adds a generic `metadata JSONB NOT NULL DEFAULT '{}'`
  column to `phoenix_kit_staff_people` (mirrors the `entity_data` shape). The
  first consumer is staff soft-delete, which stashes the prior lifecycle status
  under `metadata["trashed_from_status"]`; the column is general-purpose so
  future per-person metadata needs no new migration. Idempotent
  `ADD COLUMN IF NOT EXISTS`; `@current_version` → 131.

### Fixed
- Media detail comments: forward Leaf editor events to the embedded
  `CommentsComponent`. The Leaf rich-text composer reports its content to the
  host LiveView via a `{:leaf_changed, …}` process message; `media_detail`
  wasn't forwarding it, so "Post Comment" silently posted empty content. Adds
  the runtime forward (resolved against the optional `phoenix_kit_comments` dep)
  plus a `handle_info` catch-all so unmatched messages don't crash the LV.

### Changed
- Extract `PhoenixKitWeb.CommentsForwarding.forward_leaf_changed/2` — the
  `{:leaf_changed, _}` forwarding contract (optional-dep guard + runtime
  `apply/3` + `:pass`/contract-drift handling, logging unexpected returns) now
  lives in one module. `MediaBrowser.Embed` and `MediaDetail` both delegate to
  it instead of carrying near-verbatim copies, so a future
  `forward_leaf_event/2` contract change touches one call site. As a side
  effect the `MediaBrowser.Embed` macro no longer injects `require Logger` into
  every host (the only `Logger` use moved into the shared module).
- Document required host wiring on the callback-message components
  `MediaSelectorModal`, `MarkdownEditor`, and `MediaGallery` — loud
  "required host wiring / silent failure otherwise" moduledoc contracts. These
  stay docs-only by design (per-consumer handling, not uniform boilerplate, so
  no Embed macro). `MediaSelectorModal` also documents the `:notify` alternative
  for LiveComponent consumers.
- Dependency bumps (`mix.lock`): `bandit` 1.11.1 → 1.12.0, `etcher`
  0.6.5 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `spitfire` 0.3.12 → 0.3.13, `tesla`
  1.18.3 → 1.20.0.

## 1.7.131 - 2026-06-05

### Added
- Per-user Etcher line params ("ink") saved to user meta, mirroring the color
  palette. `MediaCanvasViewer` wires Etcher 0.6.5's new
  `etcher:line-params-changed` hook: the global stroke defaults (width /
  opacity / dash for new shapes) are one set per user shared across every
  viewer, seeded fresh from `custom_fields["etcher_line_params"]` on mount and
  persisted back via `update_user_custom_fields/2` on every slider edit. The
  payload is sanitized on both write and read — width clamped 1..40, opacity
  0..1, dash restricted to `solid`/`dashed`/`dotted`, merged over the default —
  so a partial or garbage client payload can never reach
  `<Etcher.layer line_params={…}>`.
- Expose the full Etcher 0.6.5 toolset in the Media viewer: add `:grabber`
  (pan) and `:marker` (highlighter) to `MediaCanvasViewer`'s `tools` list,
  which previously omitted them. Marker is pure marking for now — it persists
  like any shape (via `annotations-changed`) but skips the annotation composer,
  so highlighting doesn't prompt for a title/comment; it's just a line.
  Its tooltip shows a byline instead: the drawing user's display name (stamped
  into `metadata` server-side at creation, not the spoofable client wire) over
  the creation date — filled instantly via the patch-shape push and identical
  after a reload.
- **V130** migration widens `phoenix_kit_annotations_kind_check` to allow
  `'marker'`, and `Annotation`'s `@kinds` adds it too. Without both layers the
  marker insert was rejected and silently dropped, so a marker vanished on
  reload.

### Changed
- Upgrade `etcher` 0.5.5 → 0.6.5 (adds the line-params hook + API) and bump the
  matching jsDelivr CDN pin in `phoenix_kit.js` (`@v0.5.5 → @v0.6.5`) so the
  lazy-loaded browser JS is the same version — a stale pin silently serves an
  old `etcher.js` and the new hook never fires. Also bump `credo`
  1.7.18 → 1.7.19 and `owl` 0.13.0 → 0.13.1.

### Fixed
- **V129** migration adds the missing `subscription_type_uuid` UUID column to
  `phoenix_kit_subscriptions`. The column the billing `Subscription` schema uses
  was only ever *renamed* in V65 (`plan_uuid` → `subscription_type_uuid`), never
  added, and `plan_uuid` never existed — so on a fresh `ensure_current/2` build
  the column was absent and every subscription insert / the billing
  Subscriptions LiveView raised `undefined_column`. Idempotent throughout:
  nullable UUID FK to `phoenix_kit_subscription_types(uuid)` `ON DELETE SET NULL`
  plus a partial index, every step guarded.
- AI translation now retries a bare HTTP 429 surfaced as `{:api_error, 429}`
  instead of discarding it on the first attempt. The built-in OpenRouter client
  already maps 429 → `:rate_limited` (snoozed), so this is defense-in-depth for
  a custom/future provider that returns the raw status — 429 is the canonical
  retry-after. Also corrected the worker's `:timeout` retry-clause comment
  (`PhoenixKitAI.Completion` remaps transport timeouts to `:request_timeout`
  before they reach the worker).
- Core `<.select field={...}>` now renders changeset validation errors. The
  component already had the rendering side (`select-error` class + the `<.error>`
  loop) but its `FormField` clause never populated `@errors` from
  `field.errors`, so `<.select>` silently swallowed validation errors while the
  sibling `<.input>` showed them. Mirrors `Input` exactly.

## 1.7.130 - 2026-06-04

### Added
- Generic AI-driven translation pipeline in core, so feature modules plug in
  via a small adapter instead of re-implementing the whole stack:
  - `PhoenixKit.Modules.AI.Translatable` behaviour (`fetch/2`, `source_fields/2`,
    `put_translation/4`, optional `pubsub_topics/1`), exposed by a module via the
    optional `ai_translatables/0` callback on `PhoenixKit.Module` and discovered
    through `PhoenixKit.ModuleRegistry.all_ai_translatables/0` /
    `find_ai_translatable/1`. `resource_type` strings must be globally unique;
    on a collision the first registered module wins.
  - `PhoenixKit.Modules.AI.Translations` orchestration — availability,
    endpoint/prompt defaults, idempotent shared prompt provisioning,
    `enqueue/1` + `enqueue_all_missing/2` (app-level de-dup, fail-open),
    per-resource + global PubSub topics, and `missing_languages/3`.
  - `PhoenixKit.Modules.AI.TranslateWorker` — generic one-job-per-language Oban
    worker: retry classification (transient errors incl. `:timeout` retry, 5xx
    retry, deterministic discards), `{:snooze, 30}` on rate-limit so a burst
    backs off without consuming attempts, and an `ai.translation_added` audit
    entry on success.
- Shared AI-translate UI for multilang form LiveViews:
  - `PhoenixKitWeb.Components.AITranslate` — render-only trigger button, modal
    (endpoint/prompt selectors, scope picker, generate-default-prompt), inline
    progress bar, and a "taking a while, runs in the background" stall hint.
  - `PhoenixKitWeb.Components.AITranslate.{FormGlue,FormBinding}` — the shared
    LiveView state machine (modal events, scope dispatch, live progress, the
    stall timer with a per-arm token guard) behind a 3-callback binding, so a
    consumer wires a tiny adapter + binding and delegates.

### Changed
- AI-translation broadcasts keep translated **content** off broad topics: the
  full payload (with `:fields`) goes only to the per-resource topic the form
  consumes; the global + adapter topics receive a content-free summary, so
  resource text is never fanned out to topics a monitor/dashboard might watch.

### Fixed
- Sanitize the per-user Etcher color palette on both write and read.
  `MediaCanvasViewer` now filters the client-supplied `etcher:colors-changed`
  payload to short, color-shaped strings (deduped, capped at 24) before
  persisting into `custom_fields`, ignoring the event when nothing valid
  survives; `load_user_colors/1` runs the same sanitization on read, so a
  palette stored before the guard shipped — or written by any other path — can
  never reach `<Etcher.layer colors={…}>` untrusted.

## 1.7.129 - 2026-06-03

### Added
- Per-user Etcher color palette in the media viewer. `MediaCanvasViewer`
  passes the user's saved palette to `<Etcher.layer colors={…}>` and
  persists edits from the `etcher:colors-changed` event into the user's
  `custom_fields` ("etcher_colors"), so a user's annotation colors follow
  them across files. Falls back to a default 5-color palette.

### Changed
- Pin the Etcher lazy-load CDN to `v0.5.5` (`phoenix_kit.js`) and the hex
  `etcher` dep to `~> 0.5.5`. 0.5.5 ships the per-user colors API plus the
  reworked annotation toolbar: the color `[⋯]` is an always-visible
  palette-icon hue-picker entry, toolbar overflow splits ~50/50 between
  the tools and the color swatches, undo/redo collapse as a single unit,
  and color slots that don't fit inline appear in the picker popup above
  the presets. The per-user palette **injection** (the `:colors` attr →
  `data-colors`) needs the 0.5.4+ layer component; the picker UI itself
  works from the CDN bump alone.

## 1.7.128 - 2026-06-01

### Added
- Sub-projects and project assignees (core schema support for the
  `phoenix_kit_projects` module). A sub-project is an assignment row that
  points at a child project instead of a task template, so it lives in the
  parent's task timeline with dependencies + drag-reorder for free; a whole
  project (or sub-project) can also be assigned to a Department / Team /
  Person, exactly like a task. The schemas, context, and UI ship in the
  external `phoenix_kit_projects` package — this release adds the migrations.

### Migrations
- **V127** — sub-projects as tasks: adds `child_project_uuid`
  (FK `phoenix_kit_projects(uuid) ON DELETE RESTRICT`) to
  `phoenix_kit_project_assignments`, drops `NOT NULL` on `task_uuid`, and adds
  a `task_uuid`-XOR-`child_project_uuid` CHECK. A partial UNIQUE index on
  `(child_project_uuid) WHERE NOT NULL` enforces one parent per child and also
  serves child-link lookups (an equality predicate implies `IS NOT NULL`).
- **V128** — assignee on projects (and sub-projects): adds
  `assigned_team_uuid` / `assigned_department_uuid` / `assigned_person_uuid`
  (FKs to the staff tables, `ON DELETE SET NULL`) to `phoenix_kit_projects`
  with a `num_nonnulls(...) <= 1` single-assignee CHECK + a partial index per
  FK. `@current_version` → 128.

### Fixed
- Notifications kill-switch (`Notifications.enabled?/0`) reads the setting
  uncached again. The `:settings` cache is node-local with no cross-node
  invalidation or TTL, so a cached read let a disable on one node go unseen on
  others until restart; the uncached read keeps the switch immediate and
  cluster-wide.
- `Notifications.admin_stats/0` now runs a single
  `count(...) FILTER (WHERE ...)` query (one table scan) instead of three
  separate `COUNT(*)` aggregates, and `get_config/0` skips it entirely when the
  module is disabled — it's called for every module on each Modules-page render.

## 1.7.127 - 2026-06-01

### Added
- Standalone notifications — a notification no longer has to come from an
  activity. `PhoenixKit.Notifications.create/1` inserts an
  activity-less notification carrying its own display content:

      Notifications.create(%{
        recipient_uuid: user.uuid,
        text: "Your export is ready.",
        icon: "hero-arrow-down-tray",
        link: "/exports/123"
      })

  `:text` / `:icon` / `:link` fold into a new `metadata` JSONB column as
  the `notification_text` / `notification_icon` / `notification_link`
  keys `Render` already honors; `Render` reads them off the notification
  itself when there's no activity. Honors the `notifications_enabled`
  kill-switch.
- `Notifications.create/1` takes an optional `:type` (notification type
  key) or `:action` (action string) to opt the standalone send into the
  recipient's per-type **preference filter** (fail-open) — omit both for
  an unconditional app-driven send.
- `Notifications.create_many/2` — the multi-recipient fan-out primitive:
  one standalone notification per recipient uuid (caller supplies the
  list, e.g. an author's followers), de-duped, each filtered
  independently by `:type`/`:action` prefs. Returns `{:ok, created_count}`.
- `Notifications.Prefs.user_wants_type?/2` — type-keyed preference check
  (vs the action-keyed `user_wants?/2`), backing the `:type` filter above.
- Notifications is now a toggleable core **module** (`use PhoenixKit.Module`):
  it appears as a card on the admin Modules page (enable/disable flips the
  existing `notifications_enabled` kill-switch) and contributes a
  `/admin/notifications` overview page + admin nav tab. The overview is a
  simple read-only page — enabled state, retention window, and aggregate
  counts (total / unread / dismissed via `Notifications.admin_stats/0`).
- The `NotificationsBell` (sticky nested LiveView) is now embedded in the
  admin header, to the right of the theme switcher — shown only when the
  Notifications module is enabled and a user is logged in. `app_layout`
  gained an optional `socket` attr (threaded from the admin call sites +
  `admin.html.heex`); the bell renders via `live_render(@socket, …)` and
  isn't rendered when no socket is threaded (e.g. public/auth pages).

### Migrations
- **V126** — `phoenix_kit_notifications.activity_uuid` is now nullable
  (standalone notifications) and a `metadata JSONB NOT NULL DEFAULT '{}'`
  column is added. The `(activity_uuid, recipient_uuid)` unique index
  still holds (Postgres treats NULLs as distinct). `@current_version` → 126.

## 1.7.126 - 2026-05-30

### Added
- `MediaBrowser.Embed` gains an opt-in `url_sync` option so any embedding
  LiveView gets shareable, deep-linkable folder URLs with one line:

      use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: true
      # or, for a non-default component id / multiple browsers:
      use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "my-browser"]

  It provides the full controlled-mode round-trip the host previously had
  to hand-write (~50 lines), via LiveView lifecycle hooks attached in
  `on_mount` (not injected `handle_params`/`handle_info` clauses) so it
  **composes with a host that already defines its own** — e.g. an
  `…/orders/:id/edit/files` page that loads the order in its own
  `handle_params`. `on_mount` parses `:initial_params` from the URL, a
  `:handle_params` hook feeds them to the component, and a `:handle_info`
  hook intercepts the component's `{:navigate, …}` and `push_patch`es
  folder / search / page / view onto the current path (every existing
  segment — locale, parent ids, sub-tab — preserved). Folder is tracked
  by uuid (stable across renames; unknown/out-of-scope falls back to
  root); base path is taken from the live URL so router prefixes are
  respected. Reusable `parse_nav_params/1` + `build_nav_query/1` helpers
  are public. The host template passes `on_navigate={:navigate}` +
  `initial_params={@initial_params}`. A `push_patch` issued from a
  `handle_info` hook makes LiveView call `view.handle_params/3`
  unconditionally, so the macro injects a trivial `handle_params/3` stub
  when (and only when) the host defines none — a host with its own keeps
  it. (Note: changing the macro requires recompiling the host;
  `mix deps.compile phoenix_kit --force` in a parent app after updating.)
  The `:handle_params` hook only re-syncs the component when the parsed
  folder / search / page / view actually changed, so unrelated host
  navigation on a multi-purpose page doesn't trigger a needless reload.
- Installer: the `catalogue_pdf` Oban queue (concurrency 2) is now added
  to the host Oban config on `mix phoenix_kit.install` /
  `mix phoenix_kit.update` (and to the fresh-install default queues).
  `phoenix_kit_catalogue` enqueues a `:catalogue_pdf` job per uploaded PDF
  (`pdfinfo` + `pdftotext` text extraction); Oban only runs listed queues,
  so without this entry the jobs sat `available` forever — uploads looked
  fine but text search silently never worked. Added unconditionally (an
  idle queue costs nothing) so a host that later adds the catalogue module
  is already wired.

### Changed
- `/admin/media` (`Live.Users.Media`) now uses `url_sync` instead of its
  bespoke `handle_params`/`handle_info`/`initial_params` plumbing —
  behavior unchanged, ~45 lines lighter.
- MediaBrowser Move modal: the destination picker is now a collapsible
  directory tree (chevron expand/collapse + colored folder icons),
  matching the left-sidebar experience, instead of a flat fully-expanded
  dump of every folder in the project. It **opens seeded from the
  sidebar's current expansion** (`expanded_folders`), so the picker shows
  the same open directories you already see on the left, then tracks its
  own `move_expanded` independently (drilling in the picker doesn't move
  the sidebar). The picker is a plain full-width `<ul>` (not a daisyUI
  `menu`, which laid the custom tree rows out horizontally and spilled
  past the box); names truncate and horizontal overflow is clipped so it
  fits the modal.

### Fixed
- MediaBrowser: the grid/list view toggle and the item count no longer
  vanish in an empty folder (or a folder that has subfolders but no
  files). They were gated on `@total_count > 0` (file count only); now
  shown whenever there are files, folders, or you're inside a folder.
- `<.pagination_info>` renders "No results" at `total_count == 0` instead
  of the nonsensical "Showing 1 to 0 results".
- MediaBrowser: the bulk **Move** button is disabled in Select Mode until
  at least one item is selected (matching the Download/Delete actions,
  which already hide with an empty selection). The `show_move_modal`
  handler is guarded too, so it can't open an empty modal.

### Migrations
- **V125** — project workflow statuses (entities-backed, cement-at-start).
  New `phoenix_kit_project_statuses` table (the cemented per-project status
  snapshot: `project_uuid` FK `ON DELETE CASCADE`, `label` / `slug` /
  `position`, `data` + `translations` JSONB, `source_entity_data_uuid`
  provenance with no FK; index on `(project_uuid)`, unique on
  `(project_uuid, slug)`). New columns on `phoenix_kit_projects`:
  `status_entity_uuid` (FK → `phoenix_kit_entities` `ON DELETE SET NULL`),
  `current_status_slug`, a generic `settings` JSONB, and a free-form
  `external_id VARCHAR(255)` for tying a project to an external system
  (not unique, not an FK; partial-indexed `WHERE NOT NULL`, set
  programmatically). Idempotent; `down/0` reverses to 124.
  `@current_version` is now 125.

## 1.7.125 - 2026-05-29

### Fixed
- `<.load_more infinite>` no longer over-fetches or wedges. The
  `InfiniteScroll` JS hook now re-fires only when its `data-cursor`
  changes (not on every unrelated LiveView diff), guards against stacked
  in-flight pushes, and carries a 2s watchdog so a load that resolves
  without advancing the cursor (empty/no-op page, stale `total`, or a
  replace-in-place list with a constant `loaded`) can never permanently
  disable auto-scroll — worst case is a brief stall that the next scroll
  or the manual button recovers.
- `MediaBrowser.Embed`'s injected `:leaf_changed` forwarder no longer
  crashes the host LiveView if `PhoenixKitComments.Web.CommentsComponent.forward_leaf_event/2`
  returns an unexpected value — an `other ->` branch logs a warning and
  degrades to `{:noreply, socket}`.
- Inline annotation-title edits from the comments sidebar now log a
  `Logger.warning` when the underlying `Annotations.update/2` write fails
  (previously the error was discarded, making a failed write
  indistinguishable from a no-op). UX is unchanged — still no flash.

### Changed
- `<.load_more>`: in `infinite` mode, `data-cursor` defaults to `@loaded`
  (so most callers can omit `cursor`), and the component raises a clear
  `ArgumentError` when `infinite` is set without an `id`. `resolve_cursor/1`
  is now nil/type-safe and computed only for the infinite variant.
- Bump the lazy-load `etcher` CDN pin in `phoenix_kit.js` `v0.5.2 → v0.5.3`
  to match the resolved `etcher` hex dependency.


### Merged
- Merged upstream `dev`, which added **V122** (`phoenix_kit_location_spaces`
  + staff `translations` JSONB + staff `Person.name`) and **V123**
  (catalogue folders: `phoenix_kit_cat_folders` + `cat_catalogues.folder_uuid`),
  plus the `<.load_more>` infinite-scroll option.

### Migrations
- **V124** — the media-folder partial unique index (previously authored
  as V122 on this fork) is **renumbered to V124** because upstream
  claimed V122/V123. Content is unchanged: restricts
  `phoenix_kit_media_folders_name_parent_idx` to `WHERE trashed_at IS NULL`.
  `@current_version` is now 124.

## 1.7.123 - 2026-05-29

### Added
- `/admin/media/:file_uuid` (MediaDetail) now renders the image through
  the Fresco canvas + Etcher annotation layer instead of a plain
  `<img>`, reaching parity with the in-place modal: draw / edit / delete
  annotations, the composer popover, and persistence all work on the
  standalone page. Implemented via a new `viewer_only` mode on
  `MediaCanvasViewer` that suppresses its close button + sidebar so a
  page host can supply its own chrome.
- A comments thread (annotation-aware) on MediaDetail, above the Storage
  Locations card — mirrors the modal sidebar's embed. Promotes
  `MediaCanvasViewer.load_annotations_for/1`,
  `build_comment_decorations/1`, and `comments_enabled?/0` to public so
  page hosts reuse them.

### Changed
- Bump leaf 0.2.20 → 0.2.21 (hex dep + `phoenix_kit.js` CDN pin).

### Fixed
- MediaDetail's embedded canvas now receives the file's intrinsic
  `width` / `height`, so the Fresco canvas matches the source image
  aspect instead of falling back to a 1000×1000 square (which letterboxed
  the image and stranded annotations on the dotted background).

## 1.7.122 - 2026-05-28

### Fixed
- `pagination_info` drops the redundant `of N` suffix when the result set
  fits on one page (`total_count <= per_page`) — e.g. "Showing 1 to 4
  results" instead of "Showing 1 to 4 of 4 results". The media browser
  toolbar reads cleaner; multi-page views are unchanged.
- New folder creation at the root of a scoped media browser no longer fails
  silently when a trashed "untitled" folder still occupies the unique
  index slot. V124 restricts `phoenix_kit_media_folders_name_parent_idx`
  to `WHERE trashed_at IS NULL`, so trashed folders no longer reserve
  names from the user's perspective.
- `MediaBrowser.Embed` now forwards `{:leaf_changed, _}` events from
  sidebar comment Leaf editors to `PhoenixKitComments.Web.CommentsComponent`
  via runtime `Code.ensure_loaded?` + `apply/3` (sibling deps with no
  compile-order guarantee). Without this, typed content in those editors
  never reached the server. User-defined `:leaf_changed` clauses still win
  because the injected clause is appended last.

### Changed
- The inline rename input for the auto-created "untitled" folder now
  selects all of its value on mount instead of just focusing — type
  immediately replaces the placeholder name without reaching for the
  mouse. Implemented via a new tiny `SelectOnMount` JS hook in
  `phoenix_kit.js` (reusable for any "type-to-replace" inline edit).

### Migrations
- **V124** — `phoenix_kit_media_folders_name_parent_idx` is now a partial
  unique index `WHERE trashed_at IS NULL`. Active siblings are the only
  rows the constraint sees, matching what `Storage.list_folders/2`
  returns. (Renumbered from V122 after the upstream merge — see 1.7.124.)

## 1.7.121 - 2026-05-25

### Added
- Core list-UI toolkit for admin tables, all in
  `lib/phoenix_kit_web/components/core/` (PR #568):
  - `BulkSelect` — `<.bulk_select_scope>` + `<.bulk_select_header_cell>` +
    `<.bulk_select_cell>` + `<.bulk_actions_toolbar>`. Selection lives
    client-side via the `BulkSelectScope` JS hook (per-checkbox toggles feel
    instant — no LV round-trip); the server only receives the selected uuids
    at action time as `%{"uuids" => [...]}`. The selection survives LV
    re-renders (reorder / load_more / sort).
  - `Sortable` — `<.sortable_tbody>` + `<.sortable_row>` wrap the
    `SortableGrid` hook wiring; `enabled={false}` cleanly omits the hook so
    drag turns off when sorting by a non-position field. Pair with
    `<.drag_handle_cell>` / `<.drag_handle_header_cell>` on `<.table_default>`.
  - `<.reorder_modal>` — strategy-picker dialog for bulk reorder; the consumer
    LV owns the strategy whitelist.
  - `<.load_more>` pagination footer (in `core/pagination.ex`) for embeddable /
    DnD-aware lists where rows append rather than navigate away.
- `<.modal keep_in_dom>` mode — renders the `<dialog>` regardless of `@show`
  and flips visibility via `data-show` + the `PkDialog` hook, enabling instant
  client-side open without a server round-trip (PR #568).
- `PhoenixKit.boot/1` hook so late-loaded modules can register after app start
  (PR #569).

### Changed
- `<.modal>` now renders a native `<dialog>` in the browser top layer
  (`PkDialog` hook + `showModal()`) instead of `<div class="modal">`. It is
  immune to ancestor stacking contexts / z-index and covers the full visual
  viewport (PR #568).
- `<.sort_selector>` is now race-free: the field select sends only `sort_by`
  and the direction arrow sends only `sort_dir`; the LV handler derives the
  missing half from assigns. Manual-order mode hides the direction toggle
  entirely (PR #568).
- `<.table_default>` rows carry a named `group/row` Tailwind marker (not a bare
  `group`) so the drag-handle hide-until-hover reveal stays keyed to row hover
  without clobbering unnamed `group-hover:` utilities nested in cells (PR #568).
- Activity feed renders dates with locale-aware formatting (PR #569).
- `redirect_invalid_locale/2` reads `prefixless_primary?()` once instead of
  twice, removing a torn-read window on a concurrent setting flip
  (PR #554 follow-up).
- Annotation storage adapter no longer accepts `:creator_uuid` from event
  payloads — authorship is resolved server-side from the actor, so a forged
  payload can't claim it (PR #550 follow-up).

### Fixed
- PkDialog top-layer leak: a `<dialog>` opened via `showModal()` stayed in the
  top layer (still capturing all clicks) after Phoenix LV's DOM patcher
  stripped the browser-added `open` attribute on re-render, while CSS rendered
  it `display: none` — visually closed but blocking the rest of the page.
  `PkDialog` now uses the `:modal` pseudo-class as the truth source and
  restores the stripped attribute before `close()` (PR #568).
- The "Reorder N selected" bulk-toolbar label was rendered untranslated: it
  used `gettext_noop/1` (extraction-only) and the JS hook does no translation,
  so it stayed English in every non-default locale. Now translated at render
  time while preserving the `%{count}` placeholder for client-side interpolation
  (PR #568 post-merge review).
- `<.drag_handle_cell>`'s default title now renders (the `default: nil` attr was
  shadowing `assign_new`) (PR #568).
- Registration and magic-link registration fieldsets unified to
  `class="fieldset min-w-0"` (dropped redundant `w-full`) (PR #559 follow-up).
- Combined the split revoke-all-sessions confirmation sentence into one
  translatable string (PR #569).
- Guard `stat.label` against non-binary values in the modules overview
  (PR #569).

### i18n
- Broad i18n coverage sweep across the user-facing admin pages — Users
  management, Session management, Live Sessions, User Settings, the General
  settings sidebar tab, and the Modules overview — with ru/et catalogs brought
  back to 100% and fuzzy msgids / mistranslations corrected (PR #569).
- Translate the stranded "Last updated:" label in Live Sessions (PR #569).

## 1.7.120 - 2026-05-24

### Changed
- Ecommerce admin i18n is now owned by the `phoenix_kit_ecommerce` module
  instead of PhoenixKit core. The `PhoenixKitWeb.EcommerceGettextManifest` shim
  that re-emitted ecommerce strings into core's POT for extraction is gone, and
  ~1,750 ecommerce-only msgids are dropped from `default.pot` and every locale
  catalog — ecommerce translations now live in the module's own gettext (PR #567).
- Dependency bump: `etcher` 0.4.9 → 0.4.10.

### Removed
- `PhoenixKitWeb.EcommerceGettextManifest` — ecommerce translation extraction
  moved into the `phoenix_kit_ecommerce` module (PR #567).

### Fixed
- Mobile horizontal overflow on card surfaces. `PhoenixKitWeb.Components.Core.ModuleCard`
  and the `TableDefault` card views are now shrink-safe — `min-w-0` + `break-words`
  on the flex/grid children keep a long unbreakable token (email, username) from
  forcing a card wider than its grid track — and the module admin-links row wraps
  via `flex-wrap` instead of overflowing (PR #567).

### i18n
- Completed `ru` / `et` translations for newly-extracted core strings
  (sort-selector direction tooltips, "URL Behavior" language settings, annotation
  toolbar hint), restoring both locales to 100%.
- Fixed fuzzy msgids and `ru` / `et` mistranslations swept in by the ecommerce
  i18n extract (PR #567).

## 1.7.119 - 2026-05-22

### Changed
- `PhoenixKitWeb.Components.Core.TableDefault` — `:class` attr widened from
  `:string` to `:any` on all 7 `table_default*` components, so the
  Phoenix-idiomatic `class={[if(...), ...]}` list form compiles without an attr
  warning. The components already wrap `@class` in a flattened list, so there is
  no rendered-output change for existing string callers (PR #565).
- `PhoenixKitWeb.Components.MultilangForm` — the standalone info alert is now a
  hover/focus tooltip on an info icon beside the "Content Language" header, and
  the default loading skeleton uses `bg-base-content/15 animate-pulse` instead of
  daisyUI's near-invisible `.skeleton`, so the loading state is visible on
  `bg-base-100` cards (PR #565).
- `Translation.handle_ai_response/2` extracts the OpenAI-shaped completion
  content inline rather than via `PhoenixKitAI.Completion.extract_content/1`,
  dropping the cross-module dependency on the optional AI plugin — works whether
  the plugin is present, absent, or stubbed (PR #565).
- Dependency bumps: `etcher` 0.4.8 → 0.4.9, `fresco` 0.5.5 → 0.5.8,
  `floki` 0.38.2 → 0.38.3.

### Fixed
- AI translation parser no longer leaks an unrequested marker's content into the
  preceding field. A field capture now terminates at any line-anchored
  `\n---<NAME>---` marker, not just the requested-field markers — so a model
  emitting an extra `---TITLE---` (e.g. from an unbound `{{title}}` template
  variable) no longer rolls that block into the prior `---NAME---` field. The
  newline anchor keeps literal mid-paragraph `---WORD---` tokens (technical docs,
  API examples) inside the capture (PR #565).
- AI translation empty sections resolve consistently to `""`. A present-but-empty
  trailing marker now records `""` instead of failing the whole response with
  `{:parse_error, {:missing_fields, ...}}`, matching how an empty middle section
  already resolved. A genuinely absent marker still reports `missing_fields`, so
  the "model forgot a marker" signal is preserved (follow-up to PR #565).

## 1.7.118 - 2026-05-21

### Added
- `card_grid_class` attr on `PhoenixKitWeb.Components.Core.TableDefault` —
  overrides the card-view grid layout (column density, gaps) without touching
  the component. Default unchanged. Must be layout-only (no `display` utility —
  the component sets `grid`/`hidden` per view-mode branch) and a literal in a
  Tailwind-scanned source so the classes compile (PR #561).
- Responsive `cols` on `PhoenixKitWeb.Components.Core.DraggableList` (and the
  `MediaGallery` passthrough) — `:cols` now accepts a string of Tailwind
  grid-column classes (e.g. `"grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8"`) for a
  responsive thumbnail grid, in addition to an integer 1..6. Any other value
  (out-of-range integer, atom, …) falls back to `grid-cols-4` (PR #561).

### Changed
- `MediaGallery` now hides the Add tile entirely once the selection reaches
  `max_count` (or 1 in `:single` mode), instead of rendering it disabled and
  greyed. Supersedes the disable-at-limit behavior shipped in 1.7.117 (PR #561).
- Magic-link registration request sends the email via `start_async`, so the
  submit is non-blocking and the in-flight spinner renders, matching the
  password-less magic-link login flow. Replaces the prior `phx-disable-with`
  (follow-up to PR #559).
- Dependency bumps: `etcher` 0.4.6 → 0.4.8, `fresco` 0.5.4 → 0.5.5,
  `ex_doc` 0.40.2 → 0.40.3.

### Fixed
- AI translation no longer fails on every real request.
  `Translation.translate_fields/6` was treating `PhoenixKitAI.ask_with_prompt/4`'s
  OpenAI-shaped response map (`%{"choices" => [...]}`) as `:unexpected_response`
  and erroring out. The success branch now routes map responses through
  `PhoenixKitAI.Completion.extract_content/1` (the helper publishing's
  `TranslatePostWorker` already uses), with a raw-binary fallback so test stubs
  and older plugin versions keep working (PR #560).
- `Translation.translate_fields/6` rejects an empty `fields` map up front with
  `{:error, {:parse_error, :no_markers}}` instead of rendering a field-less
  prompt and spending an AI request that only fails downstream in the parser
  (PR #558).
- Auth-form submit buttons no longer overflow their card.
  `<fieldset>`'s browser-default `min-width: min-content` let the fieldset — and
  its `w-full` submit button — grow past the form width; `min-w-0` is now applied
  to the six remaining auth-form fieldsets. Also dropped `phx-disable-with` on
  the magic-link login form, where it collided with the `@loading` branch and
  made LiveView's diff merger inject a stray SVG into the button (PR #559).

## 1.7.117 - 2026-05-21

### Added
- `PhoenixKit.Modules.AI` — core-side conveniences for the optional
  `PhoenixKitAI` plugin. `available?/0` is a module-loadability check (loaded
  AND exports `ask_with_prompt/4`); gate AI-driven UI on it so apps without the
  plugin fall back to non-AI behavior automatically (PR #557).
- `PhoenixKit.Modules.AI.Translation` — shared AI-translation orchestration
  reused by every feature module that wants AI translation. `translate_fields/6`
  takes a `%{field_name => text}` map and returns the same shape, or a
  normalized `{:error, atom_or_tuple}` covering every failure mode (missing
  endpoint/prompt, plugin absent, duplicate/partial markers, AI exception/exit).
  `parse_response/2` is the public, case-insensitive `---FIELD_NAME---` parser.
  Each dispatch writes one `core.ai_translation.requested` activity entry for a
  unified token-spend audit trail (PR #557).
- `ai_translate` attr on `LanguageSwitcher.language_switcher_dropdown` — opt-in
  affordance that renders a per-missing-language sparkle button plus a bulk
  "translate all missing" CTA. The component is pure event-emit (no
  `PhoenixKitAI` reference): it fires the host's `phx-click` event and the host
  enqueues its own translation worker. `nil`/`enabled: false` = today's behavior
  (PR #557).
- `max_count` attr on `PhoenixKitWeb.Components.MediaGallery` — caps the number
  of selected images in `:multiple` mode and disables the Add button at the
  limit (defence-in-depth: `apply_selection` also clamps). `nil` = unlimited;
  `:single` mode implies a limit of 1 (PR #556).
- `card_media` slot on `PhoenixKitWeb.Components.Core.TableDefault` — optional
  media region (thumbnail / cover image / document preview) rendered above the
  card body in card view; the slot owns its own padding/background (PR #556).
- Controlled `view_mode` (+ `view_event`) on `TableDefault` — pass
  `view_mode="card"|"table"` to take the card⇄table toggle from assigns instead
  of the default JS hook + localStorage. The component then renders only that
  view and the toolbar buttons emit `view_event` with `phx-value-mode`, so the
  view choice can be URL-backed (`push_patch`) or survive LV navigation (PR #556).
- `class` attr on `TableDefault.table_default_header` — override the header
  styling per call site (PR #556).

### Changed
- `TableDefault.table_default_header` default changed from
  `bg-primary text-primary-content` to `bg-base-300` — a calmer, theme-neutral
  header that reads as a subtle separator from `<tbody>`. This affects every
  `<.table_default_header>` that does not pass an explicit `class`. Pass
  `class="bg-primary text-primary-content"` to restore the previous look, or
  `class=""` for a bare header (PR #556).
- `MediaGallery` in `:single` mode now disables the Add button once an image is
  selected; replace the image via the per-thumbnail Remove (✕) then Add. The
  selection cap of 1 is unchanged (PR #556).

## 1.7.116 - 2026-05-20

### Added
- `Languages.prefixless_primary_safe?/0` — boot- and mix-task-safe wrapper
  around `default_language_no_prefix?/0`. Returns `false` during mix-task
  context (via the same `:phoenix_kit_config_status` sentinel `Routes.path/1`
  uses) and rescues any other lookup exception to `false`. Use from
  boot/middleware contexts where the Settings table may not be reachable;
  `default_language_no_prefix?/0` remains the runtime entry point.
  `Routes.path/1` and `PhoenixKitWeb.Users.Auth` now both delegate to this
  canonical implementation (PR #554).
- `PhoenixKit.Modules.Sitemap.LocalePath` — shared `emit_prefix?/2`
  decision rule for the three sitemap sources (`publishing`, `static`,
  `posts`). Each source still owns its segment formatting (display code
  with hreflang awareness for publishing, base code for static + posts);
  the module owns only the decision so the policy stays consistent across
  sources (PR #554).
- `DialectMapper.group_dialects_by_base/1` — counts sibling dialects per
  base language code. Used by the language switcher and admin/user nav
  dropdowns to decide whether to show a country qualifier (PR #555).
- `LanguageSwitcher.dedupe_names/1` + `extract_base_language_name/1` —
  public helpers called from `AdminNav` and `UserDashboardNav` so all
  language menus share one country-qualifier dedup rule (PR #555).

### Changed
- Frontend language switcher (`PhoenixKitWeb.Components.Core.LanguageSwitcher`'s
  dropdown + continent-grouped views) now drops the country qualifier from
  rendered labels when only one dialect of a given base language is enabled.
  `English (United States)`, `Estonian (Estonia)`, `French (France)` render
  as `English`, `Estonian`, `French` whenever no sibling dialect is
  configured; enabling a second dialect of the same base (e.g. `en-US` +
  `en-GB`) causes those entries to reacquire the country qualifier so they
  remain distinguishable. Same rule applies in the admin top-bar dropdown
  and user dashboard nav. Continent-grouped views compute sibling counts
  globally across all enabled languages, so a base split across continents
  keeps its qualifier in both groups. Restores the bare-label rendering
  that was lost when commit `d1c2d577` rewrote the switcher to
  one-row-per-dialect (PR #555).
- Sitemap sources `publishing`, `static`, and `posts` share one
  `LocalePath.emit_prefix?/2` decision rule instead of three byte-identical
  copies; three near-identical private `single_language_mode?/0` helpers
  collapse into one defensive lookup on `LocalePath` (PR #554).
- `redirect_invalid_locale/2` honors the site-wide
  `default_language_no_prefix` setting. With the setting OFF (default), an
  invalid locale segment is swapped for the primary base code so the
  redirect lands on the canonical prefixed shape; with the setting ON, the
  segment is stripped entirely. Previously the plug always emitted the
  prefixless shape, which was inconsistent with how the rest of the app
  emits primary-language URLs when the setting is OFF (PR #554).
- Dependency bumps: `etcher` 0.3.0 → 0.4.0, `fresco` 0.5.2 → 0.5.3.

### Fixed
- Login (and any other primary-language POST) no longer fails with the
  default `default_language_no_prefix` setting. `process_valid_locale/2`
  was unconditionally 301-redirecting `/<default>/...` → `/...` for
  non-admin requests, discarding the POST body. The redirect is now gated
  on `Languages.prefixless_primary_safe?/0` so the canonical primary shape
  matches whichever setting state the site is in (PR #554).
- Sitemap sources `static.ex` and `posts.ex` honor the site-wide
  `default_language_no_prefix` setting for the primary language. Both had
  the same `_is_default` ignored bug that PR #552 fixed in the publishing
  source — they previously emitted `/en/about` and `/en/blog/post` in
  multilang mode regardless of the setting (PR #554).

## 1.7.115 - 2026-05-19

### Added
- Site-wide `default_language_no_prefix` setting on the Languages admin page
  (`/admin/settings/languages`) controls whether the primary language emits
  its locale segment in URLs. When on, `/admin/users` and `/blog/post`
  replace `/en/admin/users` and `/en/blog/post` across admin pages, public
  pages, sitemap, and redirects; other languages always keep their prefix.
  Default is off, matching the historical publishing default, so existing
  installs' indexed URLs stay stable on upgrade. Installs that previously
  toggled `publishing_default_language_no_prefix` get auto-migrated to the
  new key on the next boot via `Languages.migrate_legacy/0` (PR #552).
- `@type t/0` on `PhoenixKit.Settings.Setting` schema. Lets consumers spec
  setting-returning functions (`{:ok, Settings.Setting.t()} | {:error, …}`)
  without tripping dialyzer's `unknown_type` warning.

### Changed
- Admin URL emission for the primary language now follows the new site-wide
  `default_language_no_prefix` setting (default off), restoring the
  `/en/admin/users` shape that 1.7.114 had emitted prefixless
  unconditionally. Both URL shapes still resolve at the router level via the
  dual-scope admin emission, so existing bookmarks and external links keep
  working (PR #552).
- Dependency bumps: `ecto` 3.13.6 → 3.14.0, `ecto_sql` 3.13.5 → 3.14.0,
  `fresco` 0.5.0 → 0.5.2, `hammer` 7.3.0 → 7.4.0.

### Fixed
- Publishing sitemap honors `default_language_no_prefix` for the primary
  language. Previously the sitemap always emitted `/en/blog/post` in
  multilang mode regardless of the setting, drifting away from the URLs
  publishing actually served at request time (PR #552).
- `Languages.default_language_no_prefix?/0` docstring no longer references
  the nonexistent `PhoenixKit.Migration.migrate_default_language_no_prefix/0`
  — points at the real entry point `migrate_legacy/0`.
- `Routes.admin_path/2` `## Examples` no longer mixes setting-dependent
  cases with deterministic ones inside `iex>` doctest prompts, so adding
  `doctest PhoenixKit.Utils.Routes` later won't fail. Setting-dependent
  shapes are still shown, just outside the executable doctest block.

## 1.7.114 - 2026-05-19

### Added
- `module_assigns` attribute on `LayoutWrapper.app_layout` — a single map
  whose keys are merged into the assigns passed to a host's parent layout,
  letting feature modules thread arbitrary host-consumable data (e.g.
  `phoenix_kit_publishing_translations`) across the layout boundary without
  core having to declare each key (PR #551).

### Changed
- Locale resolution is now URL-authoritative. The `phoenix_kit_locale_base`
  session value and `user.custom_fields["preferred_locale"]` are no longer
  read for routing — the URL's locale segment (or its absence) is the only
  source of truth across both the LiveView mount and the HTTP plug. Fixes a
  sticky-locale bug where visiting one locale-prefixed URL pinned that locale
  onto every later prefixless URL (PR #551).
- Admin URLs drop the locale segment for the primary language, matching
  non-admin behaviour. Both `/<prefix>/admin/*` and
  `/<prefix>/:locale/admin/*` remain routable, so legacy prefixed links keep
  working (PR #551).
- Admin, public, and authenticated-dashboard LiveView routes are each served
  from a single unified `live_session` (`:phoenix_kit_admin`,
  `:phoenix_kit_public`, `:phoenix_kit_authenticated`) spanning both the
  primary-language (`/<prefix>/...`) and locale-prefixed
  (`/<prefix>/:locale/...`) URL shapes. Switching locale now stays on the
  WebSocket via `push_navigate` instead of forcing a full-page reload —
  previously each surface was split across two sessions and every locale
  change crossed a `live_session` boundary.
- `DialectMapper.resolve_dialect/2` collapsed to `resolve_dialect/1`: dialect
  resolution is URL-driven and no longer consults a user's
  `custom_fields["preferred_locale"]`. Removed the now-unused
  `User.preferred_locale_changeset/2` and `User.get_preferred_locale/1`.

### Fixed
- Table RowMenu dropdown is portaled to `<body>` while open so its
  `position: fixed` coordinates escape any `<dialog>` or `transform`/`contain`
  containing block — previously the menu could render far off-screen inside
  modals (PR #551). It also no longer leaves a duplicate menu element behind
  when a server-side LiveView update re-renders the row while the menu is
  open.
- Publishing route dispatch threads the workspace `url_prefix`, so it keeps
  working when PhoenixKit is mounted under a non-root path (PR #551).

## 1.7.113 - 2026-05-18

### Added
- `line` annotation kind — a two-endpoint line tool alongside `dimension`
  (same geometry, no arrowheads, no inline numeric label). V121 migration
  widens the `phoenix_kit_annotations_kind_check` constraint to accept it.
- `PhoenixKitWeb.Components.MediaCanvasViewer` — shared LiveComponent owning
  the per-file canvas + Etcher annotation layer + composer popover + comments
  thread. Embedded by both `MediaBrowser` and `MediaViewer`, so files opened
  via `MediaGallery` → `MediaViewer` get the full pan/zoom + annotation
  experience (PR #550).
- `Storage.folder_subtree_uuids/1` is now public — walks a folder tree and
  returns every descendant uuid including the root (PR #549).

### Changed
- `MediaBrowser` migrated to Etcher 0.3 + Fresco 0.5: per-op annotation events
  collapse into a single bulk `etcher:annotations-changed` diff; `fresco` and
  `etcher` deps flipped from local path deps to hex pins (`~> 0.5` / `~> 0.3`)
  (PR #550).
- Annotation composer now positions itself above its shape and drops the
  shape entirely when dismissed via Cancel (PR #550).
- Deleting an annotation now hard-deletes its linked comments instead of
  leaving `[removed]` placeholders in the file's thread (PR #550).
- Activity and Users/Sessions filter panels relocated into the
  `<.table_default>` toolbar row; tables render unconditionally with the
  empty state as a table-body row so filters/search stay visible on a
  zero-result filter (PR #549).

### Fixed
- Users/Sessions search regression — form-less `<input>`s no longer delivered
  `phx-change`; search inputs are wrapped in `<form phx-change="search">`
  again (PR #549).
- Folder-scoped media picker now includes images in nested subfolders, not
  just files directly in the scope folder (PR #549).
- V120 migration tolerates a missing `phoenix_kit_doc_template_presets` table
  on hosts that never installed the Document Creator module — the index
  rebuild is guarded on table existence (PR #550).
- V121 migration adds the kind-check constraint unconditionally after
  `DROP CONSTRAINT IF EXISTS`; the previous `pg_constraint` existence guard
  was not schema-scoped and would skip the add on multi-prefix installs.
- Annotation updates no longer cast `:uuid`, closing a path where a stray
  payload uuid could rewrite an annotation's primary key.
- `MediaCanvasViewer` annotation sync skips no-op `UPDATE`s — Etcher
  re-broadcasts the full annotation list on every mutation, so untouched
  rows are now diffed out and a zero-net-change re-broadcast does no DB work.
- Users role-filter dropdown reflects the active filter again (`<option
  selected>` instead of an ignored `<select value>`); the empty-state
  "Clear Filters" button resets all filters via a dedicated handler.
- Activity empty state distinguishes "No activities match the current
  filters" from "No activities recorded yet".

## 1.7.112 - 2026-05-18

### Added
- `PhoenixKitWeb.Components.MediaGallery` — reusable LiveComponent for selecting,
  ordering, previewing and removing a set of images.
- `PhoenixKitWeb.Components.MediaViewer` — standalone image lightbox LiveComponent
  (prev/next, keyboard, download). Extracted from `MediaGallery`; usable independently.
- `Storage.get_files/1` — batch file fetch preserving input order.
- `FolderExplorer` component — folder tree extracted from `MediaBrowser` as a
  reusable component (PR #544).
- `<.table_default>` sort + drag-to-reorder primitives (PR #548)
  - New `:sort_bar` slot rendered above the toolbar, visible in both card and table views.
  - `<.table_default_body>` accepts `:global` attrs so consumers can wire the
    `SortableGrid` hook (`phx-hook`, `data-sortable-*`) directly onto `<tbody>`.
  - `<.table_default_header_cell>` `:inner_block` is now optional — empty `<th>`
    cells for drag-handle / selection columns no longer need a placeholder.
  - `:card_body` slot for fully-custom card content; `:card_class` accepts a string
    or `(item) -> string` function; `:above_cards` slot; `2xl:grid-cols-4` card grid.
- `<.sort_selector>` core component — field-picker select + direction toggle, with a
  `manual_field` mode that swaps the toggle for a drag-handle hint (PR #548).
- `<.bulk_actions_bar>` core component — selection counter + action-button slot +
  Clear button; `wrapper_class` covers the inline-card and sticky/blurred shapes (PR #548).
- `<.empty_state>` core component — `compact` / `card` / `featured` "no rows" panels
  with optional icon, description, and CTA slot (PR #548).
- `<.form_section>` and `<.form_actions>` core components — card-wrapped titled form
  sections and a Cancel + Submit footer bar (PR #548).
- New `PhoenixKit.Utils` helpers (PR #548)
  - `Reorder.reorder/4` — two-phase index-rewrite primitive for drag-to-reorder list
    views; schema-agnostic, UUID-filtered, payload-capped, returns `{:ok, count}`.
  - `Values.blank_to_nil/1` and `Values.presence/1` — canonical `"" → nil` helpers
    (the latter trims first); previously duplicated across 7+ modules.
  - `Format.bytes/2` — single human-readable byte formatter with `:decimals` /
    `:unknown` / `:base` (1024 vs 1000) options; replaced 8 private copies.
- V120 migration — document-creator category / type taxonomy (PR #545).

### Changed
- `MediaSelectorModal` accepts an optional `notify: {module, id}` to deliver the
  selection via `send_update` instead of a process message.
- `MediaGallery` delegates its inline lightbox to `MediaViewer` — no behavior
  change for existing consumers.
- `<.draggable_list>` gains an optional `target` attr (CSS selector). When set,
  the `SortableGrid` hook routes the reorder event via `pushEventTo` so it
  reaches a LiveComponent rather than the host LiveView.
- `<.sort_header_cell>` polish — inactive-column up/down hint, in-flight loading
  spinner, and atom-or-string `sort.dir` tolerance (PR #548).
- `admin_page_header` — `back` / `back_click` are now deprecated no-ops; the back
  arrow no longer renders. Retained so existing call sites compile (PR #548).
- `MediaBrowser` folder management overhaul (PR #544)
  - Recursive folder trash + drag-to-trash; instant "untitled" folder creation.
  - Folders draggable across grid / list / sidebar; drop-into-current-folder via
    the main content area; whole-selection drag in select mode.
  - Per-file and per-folder kebab menus migrated to `TableRowMenu` (fixes clipping).
  - Folder rename made more apparent; click-away cancels.
- etcher / fresco dependency requirements tightened to `~> 0.2.6`.
- Upgraded library dependencies.

### Fixed
- `MediaGallery` drag-to-reorder no longer pushes `reorder_images` to the host
  LiveView (where it had no handler and crashed the page). The grid now passes
  `target` to `<.draggable_list>` so the event reaches the component's own
  `handle_event/3`.
- `MediaBrowser` breadcrumbs no longer duplicate the current folder or ignore
  scope; move-to-root now works under scope; `update_folder/3` guarded against
  `parent_uuid: nil`; N+1 in session breadcrumb work eliminated (PR #544).
- `admin_page_header` no longer carries an unused `Icon` import left by the
  back-button removal — restores a clean `mix compile --warnings-as-errors`.
- `Utils.Values.blank_to_nil/1` and `presence/1` no longer raise on non-string
  input (e.g. a list from a `key[]=` query param) — they fall back to pass-through
  and `nil` respectively.
- V120 migration review fixes — primary-key defaults, multi-prefix guards, exact
  legacy category mapping, `uuid_generate_v7()` per house convention (PR #545).
- Avatar dropdown overflow, scroll, hover, and click-feedback fixes.

### i18n
- Ecommerce gettext manifest + `ru` / `et` translations; fixed 91 fuzzy ecommerce
  translations (PR #547).
- Projects + comments gettext manifests with `et` / `ru` translations (PR #542).
- Global Gettext locale synced alongside the backend-specific one.

## 1.7.111 - 2026-05-14

### Added
- V118 migration: callout + text annotation kinds + optional `title` column on `phoenix_kit_annotations` (PR #541)
  - Widens `phoenix_kit_annotations_kind_check` to include `"callout"` (leader-line annotation: anchor point + line to a labeled bbox) and `"text"` (freestanding click-drag text label). Both new tools shipped in Etcher 0.2; the CHECK update is folded into a single `DROP + ADD` so we don't take two trips over the same constraint
  - Adds nullable `title varchar(200)` column. Every kind can carry a short label — renders inline on the shape (above the bbox for rect/circle/polygon, at the leader endpoint for callout, inside the bbox for text). Length matches the schema-side `validate_length(:title, max: 200)`. Lives in its own column so it stays queryable outside the JSONB blob
  - `Annotation` schema gains `:title` field + the two new kinds in `@kinds`; `@cast_fields` allows it through the changeset
- `PhoenixKit.Annotations.restore_linked_comments/3` (PR #541)
  - Undo-of-delete support: when an annotation deletion is reversed via Etcher's undo stack, the original uuid is gone but the soft-deleted comments still reference it through `metadata.annotation_uuid`. The function flips matching `status: "deleted"` comments back to `"published"` and rewrites their `metadata.annotation_uuid` to point at the recreated row. Returns count restored. No-ops cleanly when PhoenixKitComments isn't installed
- `AnnotationComposer` title input (PR #541)
  - Optional title field above the comment textarea. Title-only annotations are now allowed (skips the comment-thread create entirely; the row gets only its `title` column set). `update_draft` accepts both `comment` and `title` keys, debounced 500ms each. Title persistence threaded through `:annotation_composer_posted` → `MediaBrowser.finalize_annotation_compose/3`
- `MediaBrowser` etcher 0.2 wiring (PR #541)
  - `etcher:updated` now accepts any combination of `geometry / style / metadata / title` in one payload (previously geometry-only). In-memory annotation list mirrors writes so the tooltip reflects the new title without waiting for a `load_annotations_for/1` round-trip
  - Composer popover suppressed for `kind == "text"` (content arrives inline via etcher's foreignObject editor) and `restore: true` (recreated row already has its title/metadata; user wasn't trying to create a new annotation)
  - On `restore: true` + `restore_from_uuid`, walks soft-deleted comments via `restore_linked_comments/3` and refreshes the comments sidebar
  - Tool list extended: `[:rectangle, :circle, :polygon, :freehand, :callout, :text, :eraser]`
  - Etcher overlay now attaches to the Fresco viewer even when Tessera has no sources (pre-PR: an empty `tessera_sources(f)` fell back to a plain `<img>` with no annotation overlay at all). Annotations now work on fresh uploads that haven't been through the variant generator
- `ViewerKeydown` JS hook (PR #541)
  - Replaces `phx-window-keydown="viewer_keydown"` on the viewer modal. Two filters the stock binding couldn't express: (1) only `Escape` / `ArrowLeft` / `ArrowRight` reach the server (letter keys no longer spam LV logs), (2) navigation keys suppressed while focus is in `<input>` / `<textarea>` / contenteditable so arrow keys move the text caret instead of flipping the modal to the next image while typing
- Post-merge review doc in `dev_docs/pull_requests/2026/541-v118-callout-text-etcher-0.2/CLAUDE_REVIEW.md` with finding disposition table

### Changed
- `{:etcher, "~> 0.1"}` → `{:etcher, "~> 0.2"}` — adds callout / text / eraser tools, undo/redo, satellite titles, and a complete `window.Etcher.layerFor(id)` programmatic control surface (PR #541)
- `AnnotationComposer` textarea `phx-debounce` 150 → 500ms — quieter LV logs at typical typing speed, no perceived input lag (PR #541)
- `priv/static/assets/phoenix_kit.js` strips 584 lines of inlined fresco / tessera / etcher hooks. Parent apps now import each lib's own `priv/static/` bundle ahead of `phoenix_kit.js`, and phoenix_kit adopts `window.{Fresco,Tessera,Etcher}Hooks` into `window.PhoenixKitHooks`. Eliminates drift between the inlined snapshot and the hex packages (PR #541)

### Hygiene
- Lockfile updates: `fresco 0.1.1 → 0.1.2`

## 1.7.110 - 2026-05-13

### Added
- V117 migration: document composition tables for `phoenix_kit_document_creator` (PR #539)
  - Adds nullable `category :: varchar` column + index to `phoenix_kit_doc_templates` so templates self-classify (financial / technical / etc.) and the template grid can filter by scope
  - Creates `phoenix_kit_doc_document_sections` — join table snapshotting `(document_uuid, template_uuid, position, variable_values, image_params)` for every section of every composed document. `document_uuid → :delete_all` cascades sections with their parent; `template_uuid → :nilify_all` lets sections outlive the template (regenerate-required state). Unique `(document_uuid, position)` + lookup index on `(document_uuid)`
  - Creates `phoenix_kit_doc_template_presets` — named reusable section recipes scoped via `(scope_type, scope_id)` and optionally categorized. `sections` is a JSONB array of `[%{template_uuid, position, variable_values, image_params}]`. Index on `(scope_type, scope_id, category)`
  - Legacy `Document.template_uuid` column retained: composed docs leave it `NULL`, legacy single-template docs continue to use it

### Fixed
- Fixed ungrouped `handle_event/3` clauses in `MediaBrowser` by relocating `creator_attrs/2` helper to private-helpers block
- Restored sitemap dynamic `<lastmod>` for homepage and group listing pages (`Sources.Static`, `Sources.Publishing`)
  - PR #539's merge silently re-removed `static_lastmod/1` and `latest_post_date/2` (a zombie revert that came back via merge conflict and got cut again from a behind-the-base fork). Result: every static URL was reporting `lastmod: <today>` on every crawl (a known false-freshness signal Google de-prioritizes), and every group listing was shipping without `<lastmod>` at all
  - Homepage `<lastmod>` now uses a new lightweight `Publishing.latest_post_date_global/0` helper — single pass over each group's posts to take max `published_at`. Replaces the prior shape that called `Publishing.collect/1` and threw away everything except the `:lastmod` field (which triggered ~3× redundant `list_posts/2` calls per group inside `collect/1`)

### Hygiene
- Routine lockfile updates (`mix.lock`)
- Precommit: `compile --force` replaced with `compile --warnings-as-errors --all-warnings`, added `deps.unlock --check-unused`, switched from `quality` to `quality.ci` (format-check)
- Dialyzer: removed 5 unused ignore filters (css_integration, process_scheduled_jobs_worker, duplicate conn_case/data_case, integrations guard_fail)
- Removed stale `:phoenix_kit` self-entry from `mix.lock`

## 1.7.109 - 2026-05-12

### Added
- V114 migration: Integrations storage switched to uuid-only `key` column on `phoenix_kit_settings` (PR #536)
  - Collapses the per-row `key` from the composite `integration:<provider>:<name>` shape to just the row's UUIDv7. Lifts both name restrictions baked into the old shape: the regex `[a-zA-Z0-9][a-zA-Z0-9\-_]*` and per-provider uniqueness are gone. Any non-empty string (after trim) is now a valid connection name; duplicates within a provider coexist (uuids disambiguate). Names with spaces, punctuation, "My Company Drive (US)" — all allowed
  - `add_connection/3`: generates UUIDv7 up-front, embeds it in both the `uuid` and `key` columns; provider + name live purely in `value_json`. `rename_connection/3` rewrites only the JSONB `name` field — storage key is the row uuid, untouched across renames, so consumer modules pinning to uuid keep working
  - Read sites (`get_integration_by_uuid/1`, `list_connections/1`, `load_all_connections/1`) source provider + name from JSONB; the list helpers expose `:date_added` so UI callers render "Created N ago" without a second lookup
  - `provider:name` string lookups now first-match by case-insensitive name sort (names aren't unique anymore). Read-shim contract preserved for legacy `migrate_legacy/0` callsites
  - `log_activity` takes explicit `(provider, name)` so audit rows carry human-readable names — parsing the key would have stamped a uuid string into `metadata.connection`
  - Migration walks every `integration:%`-keyed row in a single UPDATE, backfills missing `value_json -> 'name'` / `'provider'`, ensures `module = 'integrations'`, and rewrites `key = uuid::text`. Legacy V0-shape keys without `:name` fold to `name = "default"`. `down/1` rewrites back to composite shape with `-<8-char>` suffix from UUIDv7's random tail on duplicate `(provider, name)` pairs
- V115 migration: `phoenix_kit_annotations` table for drawn-on-image shapes via the Etcher overlay (PR #537)
  - Stores rectangle / circle / polygon / freehand shapes tied to a `phoenix_kit_files` row in image-pixel coordinates. Geometry is JSONB; shape kinds enforced via DB-level CHECK constraint matching Etcher 0.1's four-tool set
  - `file_uuid` FK `ON DELETE :delete_all` — annotations vanish with their host image. `creator_uuid` nullable + `ON DELETE :nilify_all` so user deletion preserves their annotations as anonymous
  - Discussion threads attach via the existing comments convention: comments anchored to the **file** (`resource_type = "file"`, `resource_uuid = file_uuid`) with `metadata.annotation_uuid` carrying the back-reference. Annotation-rooted comments appear in the file's main thread alongside non-annotated discussion
  - Indexes: `(file_uuid)` for per-file listing, partial `(creator_uuid) WHERE creator_uuid IS NOT NULL` for author lookups
- V116 migration: nullable self-FK `parent_uuid` on `phoenix_kit_entity_data` (PR #538)
  - Each entity-data row can point at another row of the same entity as its parent. System field — always present, optional, never user-removable (does not appear in `entities.fields_definition`). Existing rows stay `parent_uuid = NULL` and become roots; no backfill
  - No `ON DELETE` cascade — parent/child linkage and same-entity scope are managed by the `PhoenixKitEntities.EntityData` context inside a transaction. A DB-level cascade would bypass the soft-delete machinery and the activity log
  - Same-entity enforcement is a context-layer responsibility. B-tree index on `(parent_uuid)` covers the "list children" query for the WordPress-style indented tree
- `PhoenixKit.Annotations` context + `PhoenixKit.Modules.Storage.EtcherAdapter` (PR #537)
  - Context handles CRUD against `phoenix_kit_annotations` plus `list_for_file_with_previews/1` that pulls every file comment in a single bulk query and groups by `metadata.annotation_uuid` for the tooltip preview
  - `Annotations.delete/1` runs comment cascade + annotation row delete in a `Repo.transaction/1` so a failure between the two doesn't leave the annotation alive with its discussion thread destroyed
  - `Annotation.adapter_writable_fields/0` exposes the schema's `@cast_fields` (minus `file_uuid`, which the adapter sets server-side from `target_uuid`) as the source of truth for the adapter whitelist — the adapter's `@schema_keys` derives from it so a future schema field can't drift silently
  - `EtcherAdapter` implements the `Etcher.Storage` behaviour, dispatching to the context. Adapter explicitly whitelists payload keys before reaching `String.to_existing_atom` — guards against forward-compat with Etcher's payload shape growing new client-side keys
- `PhoenixKitWeb.Components.AnnotationComposer` LiveComponent (PR #537)
  - Focused composer for attaching the first comment to a newly-drawn annotation. Explicit Post / Cancel control flow owns the annotation lifecycle: Post commits comment + solidifies annotation, Cancel rolls the annotation back. Communicates with the parent MediaBrowser via LC-to-LC `send_update/2`, no host-LV plumbing required
  - Scope: text + file uploads (image / video / audio / pdf / archive) + Giphy picker. Audio recording (which the full `CommentsComponent` supports) intentionally skipped for v1
- MediaBrowser integration with the Etcher overlay (PR #537)
  - `Etcher.layer` mounted alongside `Fresco.viewer` in the modal. New `etcher:created` / `:updated` / `:deleted` / `:selected` handlers wire the JS overlay into the storage backend
  - Lifecycle: `open_viewer/2` preloads annotations + rolls back any pending compose; `finalize_annotation_compose/2` reloads annotations and pokes the file's `CommentsComponent` to refresh; `refresh_file_comments/1` flips the component's `loaded?` to false to trigger a sidebar reload
  - `creator_uuid` is set server-side from the scope — client-supplied `creator_uuid` in the payload is overridden, preventing author spoofing
- `IntegrationPicker` rewrite (PR #536)
  - Card subtitle: priority `external_account_id` → masked credential tail (first 8 + `…` + last 4 for any of `api_key` / `bot_token` / `access_key`; `•••` for keys under 14 chars)
  - Age line under subtitle using shared `<.time_ago>`
  - Status badge: distinct label + colour for each of the four canonical statuses (`connected` → green "Connected", `error` → red "Auth failed" with `validation_status` tooltip, `configured` → yellow "Not tested", `disconnected` → grey "Not connected")
  - Provider icon + display name auto-resolve via `Integrations.Providers.get/1` — callers no longer pre-attach a `:provider` struct
  - Provider-name badge hidden when picker is filtered to a single provider (both real callsites do this)
  - Click feedback: `phx-click-loading` dims the clicked card + blocks rapid re-clicks during the LV round-trip; daisyUI `loading-spinner` swaps in for the status badge during the same window
  - `provider_def` memoized in a `Map.new(connections, ...)` shared between `filter_by_search/3` and the render path — drops `Providers.get/1` calls from 2N to N per render
  - 33 new component spec tests covering subtitle priority + masked credential + age + provider auto-resolve + status branches + filter-by-provider + search threshold + empty state + deleted-card warning + click-action dispatch
- `<.draggable_list>` `:sortable_handle` attribute (PR #538)
  - Optional CSS selector (e.g. `".pk-drag-handle"`) that restricts drag initiation to elements matching the selector inside each item. When set, the item wrapper drops `cursor-grab` styling — the caller renders their own handle. Backward-compatible: default `nil` preserves whole-item drag. Mirrors `<.table_default>`'s `:on_reorder` + `.pk-drag-handle` convention. JS hook (`SortableGrid`) already supported `data-sortable-handle`; this PR wires the Elixir-side knob through
- Etcher tooltip JS slot overrides (PR #537)
  - `window.Etcher.tooltipSlots` `.header` / `.footer` / `.body` translate `metadata.comment_*` keys into the rich tooltip (author header, date · count subheader, thumbnail + quoted text body). `window.Etcher = window.Etcher || {}` guards against load order
- `AnnotationComposerPosition` JS hook keeping the MediaBrowser's floating annotation-composer popover inside the viewer bounds via re-clamping on mount + updates + window resize
- Dep adds: `:fresco ~> 0.1` (OpenSeadragon viewer wrapper, now a direct dep since Tessera 0.2 split it out), `:etcher ~> 0.1` (annotation overlay)
- Three post-merge review docs in `dev_docs/pull_requests/2026/`: `536-integrations-v114-uuid-keys-picker-ux/`, `537-annotations-v115-etcher-overlay/`, `538-v116-parent-uuid-draggable-handle/` — each with finding disposition tables tracking which items were addressed in follow-up commits and which were deferred to the original PR author

### Changed
- `Integrations.validate_connection/2` rescue narrowed to `[DBConnection.OwnershipError, Postgrex.Error, Req.TransportError]` so genuine logic bugs (`KeyError`, `ArgumentError`, `MatchError`) bubble up to the supervisor instead of being swallowed under a generic "validation failed". `validate_credentials/2` mirrored the narrowing post-merge for parity (PR #536)
- `Integrations.authenticated_request/4` docstring spells out the URL-trust contract: the integration's Bearer token is attached to every request, so callers must pin URLs to a domain allowlist before invoking. Internal callers (`OpenRouterClient`, OAuth refresh, userinfo) build URLs from the Providers registry which is hardcoded and safe; new callsites taking URLs from elsewhere need their own guard (PR #536)
- `phx-disable-with` on Save / Test Connection / Disconnect / Delete buttons on `integration_form.html.heex` plus the OAuth Connect Account button. Pre-fix, a double-click + slow network could submit two save requests or spawn parallel HTTP probes (PR #536)
- IntegrationForm `create_connection` + `save_form_with_rename` error branches preserve `:new_name` + `:form_values` on error so a failed `:empty_name` submit doesn't wipe the api_key the operator just typed. Dropped the dead `:already_exists` / `:invalid_name` error branches (those tuples no longer fire post-V114). Template: removed the now-incorrect "Letters, digits, hyphens, and underscores. Must be unique per provider." name-rules hint (PR #536)
- `PhoenixKit.Users.Permissions.module_label("db")` / `module_icon` / `module_description` pin `db` in `@core_*` maps so the display is correct even when the external `phoenix_kit_db` module isn't loaded (PR #536)
- `MediaBrowser.format_date/1` strftime format string wrapped in `gettext(...)` so locales can reorder date components (`%d %b %Y` for en-GB / fr / de) without code changes
- `AnnotationComposer.first_error/1` routes through `PhoenixKitWeb.Components.Core.Input.translate_error/1` — gettext-aware helper that interpolates `%{count}` and other opts properly
- `AGENTS.md` CHANGELOG-ownership instruction corrected — entries are written by agents against the bumped `@version` heading, matching the project's actual workflow

### Fixed
- Post-merge fixes folded from review of PR #536:
  - V114 docstring drift after rebase rename: moduledoc references "V113" but the module is V114; "Stamp the table comment with '113'" while code stamps '114'; "post-V113 regression / invariant" in tests and picker comment. All swept to V114
  - `Permissions.module_label("db")` was falling through to `String.capitalize("db")` = `"Db"` when the external `phoenix_kit_db` module isn't loaded; test asserts `"DB"`. Folded in to keep the post-rebase baseline green
  - Test fixture rows in `storage/scope_test.exs`, `media_browser_scope_test.exs`, `media_browser_test.exs` violated V113's `phoenix_kit_files_user_or_parent_check` CHECK constraint; each `create_file!/1` now stamps `user_uuid` via a memoised `ensure_user!/0` helper
  - `IntegrationPicker.filter_by_search/3` had a shadowing `name` variable in the inner case pattern match; renamed to `provider_name`
  - `String.slice` negative-bound range pinned with explicit step (`-4..-1//1`) to silence Elixir 1.16+ range-step warning
  - Credo cleanup: `get_integration/1` 2-branch `cond` with `true` arm → `if/else`; inline `PhoenixKit.Settings.Queries.get_setting_by_uuid/1` calls aliased as `SettingsQueries` in `integrations_test.exs`; three test files (`storage/scope_test.exs`, `media_browser_scope_test.exs`, `media_browser_test.exs`) alias `PhoenixKit.Users.Auth` for their `ensure_user!` helpers
- Post-merge fixes folded from review of PR #537:
  - `Annotations.delete/1` deleted linked comments outside a transaction — if the comment cascade succeeded and the annotation row delete then failed (FK violation, DB transient), comments were gone but the annotation remained with its discussion permanently destroyed. Wrapped in `Repo.transaction/1` via an extracted `delete_in_transaction/1` helper
  - `resource_type = "annotation"` claim in three moduledocs (`annotation.ex`, `v115.ex`, `etcher_adapter.ex`) contradicted the actual implementation, which anchors comments to the **file** (`resource_type = "file"`) with `metadata.annotation_uuid`. All docs swept to match reality
  - `Annotations.delete_linked_comments/1` bare `rescue _ -> :ok` swallowed every exception class including logic bugs. Narrowed to `[DBConnection.OwnershipError, Postgrex.Error, ArgumentError]` so logic bugs surface
  - `AnnotationComposer.normalize/1` reinvented what `Ecto.Changeset.cast/3` already does (accepts both atom- and string-keyed maps) AND silently passed the original map through when `String.to_existing_atom` failed, hiding typo'd field names from the user as "geometry: can't be blank" rather than "unknown field" — function deleted
  - In-repo `Code.ensure_loaded?(PhoenixKit.Annotations)` guard in `MediaBrowser.load_annotations_for/1` was needless defensive code — `Annotations` is in the same compilation unit
  - `@compile {:no_warn_undefined, [PhoenixKit.Modules.Storage, ...]}` would have shadowed legitimate compile errors on a core module rename — `Storage` removed from the suppression list
  - `AnnotationComposerPosition.destroyed` cleanup conditional was a never-falls-through guard — simplified
  - Etcher slot-preservation JS comment misstated the mechanism — corrected to "PhoenixKit owns the tooltip layout; downstream consumers must load AFTER phoenix_kit.js"
  - Credo cleanup: `Annotations.first_attachment_thumbnail/1` single-clause `with` → `case`; aliased `Annotations`, `Storage`, `EtcherAdapter`, `Storage.File` so six "nested modules could be aliased" findings clear
  - PhoenixKitComments dialyzer ignores added for `annotations.ex` + `annotation_composer.ex` (optional sibling package, guarded at runtime)
- V114 down SQL collision-suffix source: `substring(uuid::text from 1 for 8)` extracted UUIDv7's timestamp prefix — same-millisecond rows produced identical suffixes ⇒ duplicate "uniquified" keys when two+ rows collided on `(provider, name)`. Switched to `substring(uuid::text from 25 for 8)` (random tail, 32 bits of entropy). Mirrored in `run_down!` in the V114 test (PR #538 follow-up)
- 3-row collision test added to V114 test suite covering N ≥ 3 case (exactly one plain key, N-1 distinct suffixed keys, all keys unique)
- IntegrationPicker click feedback was missing: clicking a card showed no visual response during the 100-500ms LV round-trip — operators would click again and submit a second request. Added `phx-click-loading:opacity-60 phx-click-loading:pointer-events-none` + status-badge → spinner swap during the in-flight window (PR #536)

### i18n
- AnnotationComposer user-facing strings wrapped in gettext (flash messages + heex literals + ARIA labels — ~17 strings)
- MediaBrowser `format_date` strftime pattern wrapped in gettext so locales reorder date components
- IntegrationPicker status labels (`Connected` / `Auth failed` / `Not tested` / `Not connected`) and search placeholder + empty-state strings wrapped in gettext
- IntegrationForm flash messages, button labels, name placeholder, danger-zone copy, OAuth step labels, redirect-uri instructions wrapped in gettext


## 1.7.108 - 2026-05-11

### Added
- V112 migration: `phoenix_kit_projects*` schema evolution (PR #533)
  - `archived_at TIMESTAMP(0)` on `phoenix_kit_projects` so the admin dashboard can soft-hide projects without flipping a status enum. Mirrors the workspace convention used by `phoenix_kit_publishing`'s `posts.trashed_at` and `phoenix_kit_files.trashed_at` — null = visible, non-null = soft-hidden, with the timestamp doubling as audit metadata. Existing `status = 'archived'` rows backfilled into `archived_at` so the dashboard filters keep working transparently
  - `phoenix_kit_projects_visible_idx` partial index on `(inserted_at DESC) WHERE archived_at IS NULL` — one partial covers both project-list and template-list dashboard reads (neither view shows archived rows)
  - `translations JSONB NOT NULL DEFAULT '{}'` on `phoenix_kit_projects`, `phoenix_kit_project_tasks`, `phoenix_kit_project_assignments` for per-language overrides on user-input content (name / description / title). Primary stays in dedicated columns; JSONB only carries non-primary overrides
  - `position INTEGER NOT NULL DEFAULT 0` on `phoenix_kit_projects` and `phoenix_kit_project_tasks` so the drag-and-drop reorder API can persist manual ordering. Existing rows fold into the `0` bucket and the schema's secondary order-by-`inserted_at` kicks in until a user actually drags
  - `scheduled_start_date` retyped from `DATE` to `TIMESTAMP(0)` so scheduled-overdue detection honors time-of-day (a project scheduled for today 09:00 flips to `:overdue` at 09:01, not at midnight). Column name kept — lying name + honest type beats the churn of renaming every call site
  - Drops the three remaining unique-name indexes — `phoenix_kit_projects_name_template_index`, `phoenix_kit_projects_name_project_index`, `phoenix_kit_project_tasks_title_index`. Name uniqueness is now policy, not schema — editing or duplicating names no longer trips a stale index, and future renames don't need migration coordination
  - Bumps migrator `@current_version` 111 → 112 — without this V112 was dead code
  - All steps idempotent (column-existence, index-existence, USING coercion clauses); `down/1` reverses each change so a rollback restores the V111 shape. `down/1` restores the V105/V101 unique indexes **first**, before dropping any V112 columns, so a duplicate-name conflict at rollback aborts cleanly rather than leaving a half-rolled schema
- `test/phoenix_kit/migrations/v112_test.exs` — pins every V112 addition (archived_at column + type + nullability, visible-index existence AND predicate shape, translations JSONB on the three tables, scheduled_start_date retype, position columns) plus the four dropped indexes and the duplicate-name behavior. The predicate test refutes any `is_template` mention, closing the docs-drift loop
- `dev_docs/pull_requests/2026/533-v112-projects-schema-evolution/CLAUDE_REVIEW.md` — post-merge review with finding dispositions
- V113 migration: system-managed media flag for Tessera deep-zoom tiles + comments↔files junction (PR #534)
  - `system_managed BOOLEAN NOT NULL DEFAULT false` on `phoenix_kit_files` — marks internally-generated media (DZI tile pyramids + per-tile chunks) so the MediaBrowser excludes them from user listings and the variant generator skips them (tile chunks don't need small / medium / large — just an `"original"` FileInstance)
  - `parent_file_uuid UUID` nullable FK to `phoenix_kit_files(uuid)` ON DELETE CASCADE — system-managed tile rows cascade away when their source image is hard-deleted
  - `user_uuid` drops NOT NULL — system-managed rows belong to a parent File, not a user. The DB-level CHECK `phoenix_kit_files_user_or_parent_check` enforces "`user_uuid IS NOT NULL OR parent_file_uuid IS NOT NULL`" so raw inserts can't violate the invariant
  - `phoenix_kit_files_system_dedup_index` partial unique index on `(parent_file_uuid, file_name) WHERE system_managed = true` — concurrent lazy-generation requests for the same uncached tile dedupe at the DB level via the changeset's `unique_constraint`; `Storage.store_system_file/3` recovers the winner's row on conflict
  - Two more partial indexes — `phoenix_kit_files_parent_uuid_index` (per-source lookup + cascade-cleanup) and `phoenix_kit_files_system_managed_index` (keeps the MediaBrowser's "user files only" sort cheap as the tile catalog grows)
  - `phoenix_kit_comment_media` junction table letting the comments module attach core File rows to comments with position + caption. Cascade on `comment_uuid`, RESTRICT on `file_uuid` (a file can't hard-delete while attached). Consumer code lands in a later PR
  - Bumps migrator `@current_version` 112 → 113; all DDL idempotent via `IF NOT EXISTS` / DO-blocks
- Deep Zoom Image viewer in MediaBrowser via Tessera (OpenSeadragon wrapper, PR #534)
  - New `Tessera.Viewer.viewer` replaces the static `<img>` in the file modal; `tessera_sources/1` builds the progressive layer list (medium → optional large → DZI manifest)
  - `<Tessera.Storage>` adapter (`PhoenixKit.Modules.Storage.TesseraAdapter`) lands tile writes in the storage pipeline (multi-bucket via `Manager.store_file/2` + a system-managed File row via `Storage.store_system_file/3`)
  - Two new public endpoints — `/tiles/:token/:dzi_filename` and `/tiles/:token/:files_segment/:level/:tile_filename` — generate the DZI manifest and individual tiles **lazily** on first request, then serve from storage. Signed `URLSigner` token in the URL path (not query) so OpenSeadragon's tile-URL derivation preserves it across manifest → tile fetch. The "dzi" variant name is distinct from storage variants so a leaked file-serving token can't grant tile access. Unauthorized requests return 404 to prevent UUID enumeration
  - Per-`file_uuid` `:global.set_lock` mutex + double-checked locking around the generators serializes concurrent cold-path requests for the same image; different images stay parallel. Lock timeout surfaces as 503 + `Retry-After` header
  - Tempfile lifecycles wrapped in `try/after` so `Tessera.generate_tile/4` or `Manager.retrieve_file/2` exceptions don't leak files into `System.tmp_dir!()`
  - New storage setting `storage_tile_generation_enabled` (default `"false"`) is the kill switch — when off, MediaBrowser emits no manifest URLs and the tile endpoints return 404
- `Storage.store_system_file/3` — context helper for system-managed media (tiles, manifests). Idempotent: check-then-insert with unique-violation recovery via the new dedup index, so two concurrent writers for the same key both end up with the same row
- `Storage` query helper `exclude_system_managed/1` — applied to every `list_*` / `count_*` / orphan / trash query so system-managed rows are invisible in the MediaBrowser regardless of how the query is composed
- `test/phoenix_kit/migrations/v113_test.exs` — pins every V113 addition (system_managed column shape, parent_file_uuid FK with cascade verification, user_uuid nullability change, three indexes including the partial-unique dedup, CHECK constraint with a raw-SQL test that double-null inserts are rejected, comment_media table + its two indexes)
- `dev_docs/pull_requests/2026/534-media-browser-tessera-tiles/CLAUDE_REVIEW.md` — review with finding dispositions; CRITICAL + HIGH items fixed in the same release

### Changed
- `<.translatable_field>` in `PhoenixKitWeb.Components.MultilangForm` — wrapper now `flex flex-col gap-1` and base input/textarea classes carry `w-full` (commits `52856738`, `0412beaf`). daisyUI 5's `.label` is `inline-flex` and `.input`/`.textarea` are `inline-block`, so without forcing column direction here label and field sat on the same row. Aligns the multilang form's layout with the regular `<.input>` core component
- `test/phoenix_kit/migrations/v106_test.exs` — dropped the "schema state (verified at boot)" `describe` block (its assertions pinned V112's drops, not V106's adds — moved to `V112Test`). File now scoped to V106's `down/1` cross-mode duplicate pre-check, matching its filename

### Fixed
- V112 `down/1` rollback ordering (post-merge review fix, commit `0cde04a8`). Original `down/1` dropped columns before restoring unique indexes; if post-V112 work introduced any duplicate names (V112's whole purpose), the `CREATE UNIQUE INDEX` would raise mid-rollback after columns were already gone. Reordered so index restoration runs first
- V112 visible-index predicate docs/code alignment — migrator moduledoc claimed `WHERE archived_at IS NULL AND is_template = false` but actual index only filtered on `archived_at IS NULL`. Docs updated to match the emitted SQL with rationale (one partial covers both visible projects and visible templates)
- MediaBrowser i18n — list-view dropdown duplicates of the folder menu (Color heading, delete data-confirm, Delete button) were missed in the original sweep; wrapped so list view matches grid view. Three flash/confirm messages embedded two independent counts in a single `gettext` call which made correct pluralization impossible in Russian (3 forms) and Estonian (2 forms); each composed from two `ngettext` calls injected into the surrounding `gettext` template (PR #532)

### i18n
- MediaBrowser UI strings wrapped in gettext + Russian and Estonian translations (PRs #532, plus earlier commits `c717c9d0` / `d44bf95c`)
- `/admin/modules` page strings wrapped in gettext + ru/et translations (PR #530)
- Core sidebar tabs wired to `PhoenixKitWeb.Gettext` for ru/et (PR #529, commits `43e528ac` / `c5fd5bae`)
- Sitemap settings UI strings wrapped in gettext (commit `afcc281a`)
- General Settings widened + `/admin/modules/languages` strings wrapped (commit `24ceec90`)
- Core `badge.ex` + `time_display.ex` status strings wrapped (commit `1fe0ad78`)
- 9 new tab-label msgids + complete Estonian translation in `default.po` (commit `373478f5`)
- Bare `Active` badge in `users.html.heex:278` wrapped (commit `8a341e90`)

### Layout
- Admin settings pages widened for wide screens (commit `3ea70ec1`)
- Module settings pages — sitemap, storage, referrals — widened for wide screens (commit `d867cb57`)

### Hygiene
- `mix format` reflow of long-line `gettext` / `ngettext` / `put_flash` calls in `media_browser.ex` and `media_browser.html.heex` (commit `9841ac31`). Surfaced when `mix precommit` ran during V112 review-followup work; no semantic changes
- New Hex dep: `{:tessera, "~> 0.1"}` — OpenSeadragon wrapper used by the Deep Zoom viewer

## 1.7.107 - 2026-05-10

### Added
- Two opt-in stateless helpers on `PhoenixKitWeb.Components.Core.TableDefault` (PR #528)
  - `sort_header_cell/1` — clickable `<th>` with `hero-chevron-up-mini`/`-down-mini` icon when active, inert label-only `<th>` when `sort` attr is `nil`. Configurable `event` (default `"toggle_sort"`), `target`, `align` (`:left`/`:right`/`:center`). The `align` is applied to the `<th class>` (`text-right` / `text-center`) so non-sortable columns honour it consistently with the sortable ones
  - `sort_header_cell/1` emits `aria-sort="ascending"|"descending"|"none"` on the `<th>` when sortable, omitted when inert. Pinned by 4 regression tests covering all three states + omitted
  - `search_toolbar/1` — daisyUI `input-sm` with `hero-magnifying-glass` icon and `phx-debounce` (default 300ms). Optional `<form>` wrap when `on_submit` is set. Placeholder defaults to `dgettext("default", "Search...")`. `phx-target` propagates to both the `<form>` and `<input>` so submit-on-Enter retargets correctly when embedded in a `LiveComponent`
  - `test/phoenix_kit_web/components/core/table_default_test.exs` — new directory + 18 component tests; closes part of the standing `core/` test-coverage TODO from `CLAUDE.md`
- `change_page` event handler in `PhoenixKitWeb.Live.Users.LiveSessions` — pagination on `/admin/users/live-sessions` was bound to `phx-click="goto_page"` with no matching `handle_event/3` clause, so clicking any page number raised `FunctionClauseError` and crashed the LV (PR #528 follow-up). Renamed the binding to `change_page` and added the handler mirroring the sibling `users.ex:121` convention

### Changed
- `PhoenixKitWeb.Live.Users.LiveSessions` — collapsed `:sort_by` + `:sort_order` assigns into a single `:sort = %{by, dir}` map; renamed event `"sort_by"` → `"toggle_sort"` with `"by"` param. First click on a new column sorts ascending (was descending); subsequent clicks toggle. `flip_dir/1` tightened from `flip_dir(_)` catch-all to explicit `:desc` clause so unintended values surface as a crash rather than silent coercion (PR #528)
- `lib/phoenix_kit_web/live/users/live_sessions.html.heex` and `lib/phoenix_kit_web/live/users/users.html.heex` — both call sites of `<.search_toolbar>` dropped the redundant `on_submit="search"`. The input's debounced `phx-change="search"` already covers the same event; keeping both made Enter fire `"search"` twice (immediate submit + 300ms-later debounced change) (PR #528 follow-up)

### Fixed
- `lib/phoenix_kit_web/live/users/users.html.heex` — replaced bare search form (every keystroke hit the server) with `<.search_toolbar>` carrying the 300ms `phx-debounce` (PR #528)
- `<.search_toolbar>` form variant double-bound `phx-change` on both `<form>` and `<input>`, doubling work per keystroke. `phx-change` is now bound only on the `<input>`; the `<form>` carries `phx-submit` only. `phx-target` now propagates to both so LiveComponent embedding works end-to-end. Two regression tests pin both behaviours (PR #528, commit `dfc91238`)

### i18n
- `mix gettext.extract --merge` resync — adds `"Search..."` msgid + `et` / `ru` translations and surfaces accumulated drift from prior commits where extract wasn't run (PR #528, separate commit `a7c1d35b`)

### Hygiene
- `.gitignore` — adds `/priv/static/assets/vendor/` so `mix phoenix_kit.install` runs against `/app` itself don't leave an outdated copy of the source JS in tree (PR #528)
- `mix.lock` — `db_connection` 2.10.0 → 2.10.1, `igniter` 0.7.9 → 0.8.0 (pulls in `ex_ast` 0.11.0 as new transitive). Routine patch bumps

## 1.7.106 - 2026-05-08

### Added
- V111 migration: PDF library tables for the upcoming catalogue PDF subtab (PR #516)
  - `phoenix_kit_cat_pdfs` — thin per-upload row. `file_uuid` FK to `phoenix_kit_files(uuid)` ON DELETE RESTRICT (catalogue manages the file lifecycle; core prune can't remove files referenced by a live catalogue row). Soft-delete via `status` sentinel (`active` / `trashed`) + `trashed_at`. Two uploads of identical content (different filenames) → two rows sharing one `phoenix_kit_files` row + one extraction
  - `phoenix_kit_cat_pdf_extractions` — keyed by `file_uuid` PK. Worker state machine (`pending → extracting → extracted | scanned_no_text | failed`) + `page_count` + `extracted_at` + `error_message`. Cascades on file hard delete
  - `phoenix_kit_cat_pdf_page_contents` — content-addressed dedup cache. PK on `content_hash` (SHA-256 hex of normalized page text). Same page text across multiple PDFs is stored once. GIN trigram index lives here so the search index doesn't grow with cross-PDF duplication
  - `phoenix_kit_cat_pdf_pages` — composite PK `(file_uuid, page_number)`; `content_hash` FK to the dedup cache (RESTRICT — orphaned content rows GC'd by a catalogue-side helper, not by FK cascade)
  - Enables `pg_trgm` extension; `@current_version` 110 → 111
- `PhoenixKit.KnownPackages` — live catalog of known external PhoenixKit packages, replacing the previously hardcoded list in `ModuleRegistry.known_external_packages/0` (PR #523)
  - Fetched on demand from `https://hex.pm/api/packages?search=phoenix_kit_&sort=name` and cached for 10 minutes in an ETS named table (`:phoenix_kit_known_packages_cache`)
  - Stale-while-revalidate with cap: on Hex failure, serves cached data up to `:max_stale_age_ms` (default 24h); beyond that, drops the cache and falls back to `:extra_known_packages` config entries only
  - `:warning` log on stale-served and empty-cache-extras-only; `:error` log when cache exceeds max stale age — operationally distinct alert levels
  - `Link`-header pagination with a 20-page cap (`@max_pages`) so a malformed `Link` header pointing back to the same page can't loop forever
  - `extra_known_packages` config knob — parent apps with private/forked packages declare them inline and they take precedence over Hex entries on the `package` dedup key (`source: "config"` baked in)
  - `hex_docs_icon_name: hero-<name>` convention — package authors append the marker to their Hex package description and the catalog UI picks it up; default is `hero-puzzle-piece`
- Per-module gettext support on Dashboard sidebar labels and tooltips (PR #522)
  - `PhoenixKit.Dashboard.Tab` gains `gettext_backend: module() | nil` (default `nil`) and `gettext_domain: String.t()` (default `"default"`) fields, plus `localized_label/1` and `localized_tooltip/1` resolvers that call `Gettext.dgettext/3` when a backend is set and fall back to the raw label otherwise
  - `PhoenixKit.Dashboard.Group` gains the same two fields plus `localized_label/1`
  - `Tab.divider/1` and `Tab.group_header/1` accept the new opts; `Tab.new/1` round-trips both via `get_attr/2`
  - 14 render sites in `Sidebar`, `AdminSidebar`, `TabItem` swap `tab.label` → `Tab.localized_label(tab)` and equivalents — mechanically uniform, no shape changes
  - Hot-reload safety via `Map.get/2` (not pattern matching) on the new fields — old-shape `%Tab{}` cached in ETS or `:persistent_term` from before the upgrade falls through as if `gettext_backend` were `nil` rather than raising `FunctionClauseError`. Pinned by an explicit `Map.delete(:gettext_backend)` regression test
  - `guides/per-module-i18n.md` — public guide for module developers (setup checklist, `mix.exs` / backend / `.po` flow, `dynamic_children/2` locale handling, dividers and group headers, tooltips, greenfield template, retrofitting checklist, smoke test pattern, common pitfalls including the hot-reload safety contract)
  - `dev_docs/instructions/2026-05-08-per-module-i18n-procedure.md` — internal operational procedure capturing every gotcha hit during the Newsletters pilot (skip-worktree on mix.exs, path-dep workflow during local dev, conditional CI skip pattern for graceful degradation)
- `:per_translation_urls` attr on the three `LanguageSwitcher` variants — `language_switcher_dropdown/1`, `language_switcher_buttons/1`, `language_switcher_inline/1` (PR #525)
  - Each entry is `%{code: <display_code>, url: <full_url>}`. Both atom-keyed and string-keyed entries accepted (useful when the list comes from JSON/JSONB rather than Elixir code)
  - Resolves each language's `base_code` against the list via `DialectMapper.extract_base/1` so `"en-US"` and `"en"` both resolve cleanly. Falls back to the locale-rewrite default when no entry matches OR the matched entry has a `nil` URL (e.g. an unpublished draft)
  - Useful when a feature module has computed canonical URLs that the simple locale-rewrite default can't reproduce — for example publishing's per-language URL slugs where `/en/blog/my-post` and `/fr/blog/mon-article` aren't related by segment swap. Pass `assigns[:phoenix_kit_publishing_translations]` from the layout
  - 7 new tests in `test/phoenix_kit_web/components/core/language_switcher_test.exs` pin the contract (atom-keyed, string-keyed, full-dialect normalization, per-language fallback, nil/empty/missing-attr pass-through)
- Drag-handle scoping + sortable feedback infrastructure (PR #525)
  - `<.table_default>` emits `data-sortable-handle=".pk-drag-handle"` when `@on_reorder` is set; only the `.pk-drag-handle` element gets `cursor-grab` styling. Click-to-expand / button-press / text-selection on a card no longer fights with SortableJS drag detection
  - `SortableGrid` JS hook: new `sortable:flash` LV→client event handler. The host LV pushes `{uuid: "...", status: "ok" | "error"}` after each `reorder_items` attempt; the hook applies `pk-sortable-flash-{ok,err}` class for ~1.2s, idempotent via reflow trigger. Queries every `[data-id]` element so table-view + card-view both animate. Defensive status-validation guard — unknown values bail rather than falling into the err-class branch
  - `<tr>` cell-width preservation via `onChoose` / `onUnchoose` — SortableJS's `forceFallback: true` + `fallbackOnBody: true` clones the dragged `<tr>` to `document.body`, where it loses its `<table>` ancestor and `<td>`s collapse to content width. The hook now snapshots computed widths and pins them inline before the drag preview renders; `onUnchoose` restores them
  - `data-sortable-handle` attr threads to SortableJS's `handle` option for any caller; `moved_id` always included in the `reorder_items` payload (was only on cross-container moves) so the LV can push back a `sortable:flash` keyed to the just-moved row
- MediaBrowser modal viewer becomes the default click target for non-admin / non-select_mode browsers, with read-only image / video / PDF / icon preview, metadata sidebar, Download button, prev/next chevrons (and ←/→ keyboard shortcuts), and Esc / backdrop close (PR #519)
  - Mobile-fullscreen layout via `position: fixed; inset: 0` — bypasses daisyUI's grid + iOS Safari's 100vh/100dvh quirks. Desktop reverts to `95vw × 90vh` centered modal with rounded corners. The `!`-prefix utility chain on `.modal-box` is required because daisyUI v5's defaults win the cascade over plain Tailwind utilities
  - `MediaImageZoom` JS hook lazy-loads Panzoom 4.6.0 from jsDelivr when the modal opens; image supports wheel/pinch/double-tap zoom and drag-pan. Listener attaches to the parent so the cursor doesn't have to land on the image; `destroyed` cleanup removes the wheel listener and destroys the Panzoom instance
  - Bulk-select still reachable — clicking the toolbar's Select button flips `select_mode` on, and from then on clicks toggle selection instead of opening the modal
- LiveView login redirect now carries the original request path as `?return_to=` (PR #519)
  - New `login_path_with_return_to/1` private helper in `PhoenixKitWeb.Users.Auth` reads `Phoenix.LiveView.get_connect_info(socket, :uri)`, encodes `path?query` via `URI.encode_www_form/1`, and threads it into the redirect target. Wired into the four `redirect_require_login` paths in `on_mount` hooks
  - Trailing-slash self-loop guard: `String.trim_trailing(path, "/")` on both sides of the equality check, so `/users/log-in` and `/users/log-in/` are treated as the same path and no return-to round-trips back to itself
  - Pairs with the existing `?return_to=` flow in `login.ex` (`sanitize_return_to/1` → `:user_return_to` session → `log_in_user/3`)
- `PhoenixKit.ModuleRegistry.get_module_key_for_namespace/1` — symmetric with the existing `get_by_key/1`. Resolves a top-level Elixir namespace string (e.g. `"PhoenixKitEntities"`) to the registered plugin's `module_key/0` (PR #521)
  - Iterates `all_modules/0`, matches on `Module.split(mod) == [top_namespace]` (exact, single segment), returns the key string or `nil` for unmatched
  - Reads from `:persistent_term` so there's no GenServer roundtrip on the hot path
- Microsoft 365 OAuth tenant override + generic `interpolate_url/3` helper in `PhoenixKit.Integrations.OAuth` — providers can now substitute `{key}` placeholders in `auth_url` / `token_url` from per-row `integration_data`, falling back to a provider-level `:url_defaults` map (PR #516)
  - Closes the previously hardcoded `/common/` Microsoft tenant — single-tenant operators got AADSTS50194 errors. New `tenant_id` setup field with `common` default; multi-tenant remains the default behavior. Three pinning tests in `test/phoenix_kit/integrations/oauth_test.exs`
  - Wired into `authorization_url/5`, `exchange_code/4`, `refresh_access_token/2`. URLs without `{` pass through unchanged (zero impact on Google / OpenRouter / Mistral / DeepSeek)
- "Resolve a LiveView module to its permission key" block-comment on `PhoenixKitWeb.Users.Auth.permission_key_for_admin_view/1` documenting the four-step resolution order (static map → custom-tabs → `PhoenixKit.Modules.<X>.Web.*` namespace → registered-plugin namespace) and the fail-closed nil default

### Changed
- DB module extracted from core into the standalone `phoenix_kit_db` Hex package (PR #518)
  - Removed `lib/modules/db/` (`db.ex`, `listener.ex`, `web/{activity,index,show}.{ex,html.heex}`) — ~2010 lines across 8 files
  - `module_registry.ex` — dropped `PhoenixKit.Modules.DB` from `internal_modules/0`
  - `integration.ex` — dropped the three hand-registered `live "/admin/db…"` declarations (auto-discovery via `admin_tabs/0` picks them up once the package is installed)
  - `modules.html.heex` — dropped the hardcoded DB module card; auto-render via `<.module_card>` based on `admin_tabs/0` discovery
  - `dev_docs/guides/2026-02-24-module-system-guide.md` — moved `lib/modules/db/db.ex` from the Internal examples section to External as `phoenix_kit_db/`, between hello_world and document_creator
- `PhoenixKit.ModuleRegistry.not_installed_packages/0` switches from `Code.ensure_loaded?(pkg.module)` to OTP-app-name MapSet membership (PR #523) — the more correct semantics, since module-loading state and OTP-app-installed state aren't the same: an extracted-but-not-yet-installed module fragment could pass `Code.ensure_loaded?` but isn't actually a dep
- `PhoenixKit.Integrations.OAuth.verify_oauth_state/2` missing-state branch tightened from lenient `:ok` to `{:error, :state_mismatch}` (PR #516, closes a CSRF-relevant gap from PR #511's review NIT #10) — every `connect_oauth` event saves state via `save_oauth_state/2` before redirect post-2026-05, so a missing state at callback time means either bypass or row-mutated-mid-flow; both are CSRF-relevant
- `IntegrationPicker` drops the `conn.name == "default"` substitution that contradicted PR #511's own moduledoc ("Names are pure user-chosen labels with no system semantics") — always renders the user-chosen name + provider badge (PR #516, closes PR #511 NIT #6)
- `<.file_upload>` `full_upload/1` variant entry-progress label reads `Uploading… {entry.progress}%` instead of the bare percentage — `entry.progress` is always client→server upload progress per Phoenix LV convention, so the wording is universally accurate (PR #516)
- `LanguageSwitcher` resolves the per-language URL once per iteration via inline `<% url = ... %>` and reuses it for `href` and `phx-value-url` — halves the per-render `resolve_url/3` cost and pins both call sites to the same URL (post-merge triage)
- `KnownPackages` moduledoc grew an "Operational signals" section enumerating the three log levels (`:warning` stale-served / no-cache / `:error` exceeded max stale age) and what each signals operationally (post-merge triage)

### Fixed
- Publishing routing-strategy collision: any host route shaped `/:locale/<literal>/...` declared after `phoenix_kit_routes()` was silently shadowed by publishing's `/:language/:group/*path` catch-all (PR #524)
  - `phoenix_kit_routes/0` now emits a publishing-specific dispatch shim when `PhoenixKitPublishing.RouterDispatch` is loaded — internal-prefix scope at `/<url_prefix>/__phoenix_kit_publishing_dispatch` with `/localized` and `/root` discriminator sub-scopes, plus a `def call/2` override that calls `RouterDispatch.maybe_rewrite/1` on every request and only rewrites publishing-bound URLs onto the internal prefix. Host routes get a fair shot at every URL
  - `restore_path/2` runs after route binding (via the new `:phoenix_kit_publishing_internal` pipeline) so canonical-URL generation reads the URL the client sent — without it, publishing's `default_language_no_prefix` redirect would spin on the internal prefix forever
  - Compile-time gated on `Code.ensure_loaded?(PhoenixKitPublishing.RouterDispatch)`; installs without publishing in the dep tree get `quote do end` (no-op AST). The `__mix_recompile__?/0` mechanism injected by `phoenix_kit_routes/0` forces a host-router recompile when publishing is added or removed from deps — handles the dep-cache staleness case
  - Browser-smoke verified across 8 URL classes: localized + canonical publishing posts, host's `/:locale/services/view/...` routes (was 404 pre-fix), admin redirects, plain home, genuine 404s. HTML body sweep confirmed zero leakage of the internal prefix in canonical / og / links / JS / headers
- Custom-role users with explicit plugin permissions (`entities`, `billing`, `ai`, …) were silently locked out of plugin admin pages because `infer_permission_key_from_module/1` only resolved the core `PhoenixKit.Modules.*` namespace. External plugins (`PhoenixKitEntities.*`, `PhoenixKitBilling.*`, …) returned `nil` from all three resolution paths, collapsing onto the "no permission" branch in `enforce_admin_view_permission/2` (PR #521)
  - New `[top | _rest] -> ModuleRegistry.get_module_key_for_namespace(top)` clause on `infer_permission_key_from_module/1`. Old `_ -> nil` fallback removed (unreachable post-`Module.split/1`). Owner / Admin behaviour and the fail-closed default for genuinely unknown views are preserved
  - Initial implementation used `[^top_namespace | _]` which matched any registered module whose `Module.split` *starts with* the segment; live repro on a parent app showed `get_module_key_for_namespace("PhoenixKit") => "db"` because `PhoenixKit.Modules.DB` happened to be the first registered module beginning with `"PhoenixKit"`. Tightened to `[^top_namespace]` (exact, single segment) and pinned with a regression test
  - `permission_key_for_admin_view/1` exposed as `@doc false def` (was `defp`) so 4 new unit tests in `test/phoenix_kit_web/users/auth_test.exs` can exercise the resolution layers without LiveView mounting machinery; 3 new tests in `test/phoenix_kit/module_registry_test.exs` pin `get_module_key_for_namespace/1` (uses `Module.create/3` with explicit top-level fixture names to avoid test-module auto-nesting)
- `PhoenixKitWeb.PagesHTML` removed (PR #518) — the module had no controller, no routes, no callers. The `embed_templates "pages_html/*"` directive plus `pages_html/show.html.heex` plus the `integration.ex` docstring described a markdown-page-rendering feature that was never wired up. Publishing module covers actual CMS-page rendering. `ast-grep --lang elixir --pattern 'PhoenixKitWeb.PagesHTML'` confirms zero structural references remain
- `MediaBrowser` chevron-button positioning: daisyUI's active-state CSS replaces `transform` with `scale(0.97)` on click, which would clobber a `-translate-y-1/2` on the button itself and make it jump down 50% of its height. Chevron positioning now sits on a wrapper `<div>`, not the button (PR #519)
- `media_browser.html.heex` modal-viewer leading comment referenced the now-removed `viewer={true}` attr; rewritten to describe the new default click behaviour (post-merge triage)
- Dead `defaults[String.to_atom(key)]` fallback in `OAuth.interpolate_url/3` — no provider in `Providers.providers/0` ships an atom-keyed `url_defaults`, so the path was unreachable. Removed; comment documents that provider authors must use string keys (post-merge triage)
- `KnownPackages.fetch_hex_page/3` recursion grew an explicit `@max_pages 20` cap so a malformed `Link` header pointing back to the same page can no longer loop forever; `ensure_table/0` rescue now carries an explanatory comment about the `:ets.whereis/1` → `:ets.new/2` race window (post-merge triage)
- `KnownPackages` test_helper.exs: the `System.cmd("psql", ...)` DB-existence check now `try/rescue ErlangError` so environments where `psql` isn't on PATH fall through to the connect-direct branch instead of crashing the test boot (PR #523)
- Pre-existing credo `Refactor.Apply` opportunities on the three `apply/3` calls in `compile_publishing_routing/1` silenced with inline `# credo:disable-for-next-line` annotations and an empirically-verified comment explaining why the variable-indirection alternative (`mod = ModuleName; mod.fun()`) doesn't shield the compiler's static-resolution warning either. `mix credo --strict` now reports zero issues across the tree (post-merge triage)

### Removed
- `PhoenixKit.Modules.DB` and the entire `lib/modules/db/` directory — extracted to the standalone `phoenix_kit_db` Hex package; companion repo TBA (PR #518)
- `PhoenixKitWeb.PagesHTML` and its `pages_html/show.html.heex` template — dead code, never wired up to a controller or route (PR #518)
- `MediaBrowser`'s `:viewer` attr — the four-mode click handler collapsed to three modes (`select_mode` → `admin` → modal viewer); pickers reach `select_mode` via the toolbar's Select button. The default click action is now the modal viewer, so callers that previously passed `viewer={true}` see no behaviour change. Callers that depended on the old picker-by-default (no `admin`, no `viewer` → click toggles selection) need to instruct users to click the toolbar's Select button instead (PR #519)

## 1.7.105 - 2026-05-05

### Added
- `PhoenixKit.Migration.ensure_current/2` — re-runnable analog of `mix ecto.migrate` for test helpers and any boot path running against a long-lived database (PR #515)
  - Passes a fresh wall-clock version (`:os.system_time(:microsecond)`) to `Ecto.Migrator.up/4` on every call so Ecto sees a "new" migration each time and invokes the inner runner; PhoenixKit's own marker (the comment on the `phoenix_kit` table) short-circuits internally if there's nothing new to apply
  - Forwards `:prefix` from the Ecto.Migration runner context inside the new private `PhoenixKit.Migration.Runner` wrapper so callers passing `prefix: "auth"` aren't silently routed to `"public"`
  - Microsecond precision keeps the collision and clock-skew windows small enough that an NTP correction would have to rewind the clock by µs at exactly the wrong moment to hide a newly-shipped migration; bigint-safe (Postgres covers ~292 years)
  - The `schema_migrations` table accumulates one row per call — cosmetic noise acceptable for the test-DB use case; production migrations via `mix ecto.migrate` / `mix phoenix_kit.update` remain unchanged
- V110 migration: nullable `language VARCHAR(10)` column on `phoenix_kit_doc_templates` so each Document Creator template can be tagged with a single locale (PR #515)
  - Full locale codes (`en-US`, `et-EE`, `ja`) — matches `PhoenixKit.Module.Languages.get_enabled_languages/0` output; lossless, consumers that want bare base codes can derive them via `DialectMapper.dialect_to_base/1`
  - Existing rows survive without a backfill; the form (landing in `phoenix_kit_document_creator` separately) pre-selects the project's primary language when creating new templates
  - Documents intentionally do not get a language column — they inherit from `template_uuid → templates.language`
  - `@current_version` 109 → 110; ⚡ LATEST tag moved off V109 onto V110
- `PhoenixKit.Migration.Runner.runner_opts/1` — pure transform of the runner-context prefix into opts threaded to `PhoenixKit.Migration.up/1` / `down/1` (PR #515 review follow-up)
  - Split out of the previous closure-style `runner_opts/0` so the prefix-forwarding behaviour can be regression-tested without spinning up a real `Ecto.Migration.Runner` process (which conflicts with the Ecto sandbox)
  - Three new unit assertions in `test/phoenix_kit/migration_test.exs` pin the contract: `nil → []` (drop, so `with_defaults/2`'s `"public"` default isn't clobbered), `"auth" → [prefix: "auth"]`, arbitrary tenant prefix forwarded verbatim. If someone "simplifies" `runner_opts` to always return `[]`, CI now fails
- "Return contract" section in the `ensure_current/2` moduledoc clarifying that failures (advisory-lock contention, migration crashes, connection errors) raise from `Ecto.Migrator.up/4` rather than being wrapped in `{:error, _}` (PR #515 review follow-up)

### Changed
- `test/test_helper.exs` switched from path-form `Ecto.Migrator.run(repo, migrations_path, :up, all: true)` to `PhoenixKit.Migration.ensure_current/2` (PR #515)
  - Deletes the now-redundant wrapper migration `test/support/postgres/migrations/20260316000000_add_phoenix_kit.exs`
- `AGENTS.md` test-infra section updated: `test_helper.exs` is now the canonical migration application point, with a **Do not** warning against the stale tuple form `Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)` (PR #515)

### Fixed
- Documented test-helper migration patterns silently went stale after the first run (PR #515)
  - Both the tuple form (`Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)`, documented in `dev_docs/migration_cleanup.md`) and the path form (used by core's own test_helper via the `20260316000000_add_phoenix_kit.exs` wrapper) hit the same trap: Ecto.Migrator records the version in `schema_migrations` after the first call and filters that entry out of pending on every subsequent boot. `PhoenixKit.Migration.up/1` was never re-invoked, so newly-shipped Vxxx migrations didn't apply on subsequent boots even though PhoenixKit's own marker was idempotent. Symptom: `column ... does not exist` after `mix deps.update phoenix_kit` brought in new migrations but the test DB stayed at the old marker
  - Verified empirically — core's own `phoenix_kit_test` was at marker 107 even though Hex 1.7.103 shipped V108 + V109; first boot after switching to `ensure_current/2` advanced the marker through V108 / V109 / V110 correctly

## 1.7.104 - 2026-05-04

### Changed
- Customer Service module extracted from core into the standalone `phoenix_kit_customer_support` Hex package — companion repo: [BeamLabEU/phoenix_kit_customer_support](https://github.com/BeamLabEU/phoenix_kit_customer_support) (PR #514)
  - Removed `lib/modules/customer_service/` (~6 KLOC, 22 files) and `lib/phoenix_kit_web/routes/customer_service.ex`; the module is now an external optional dependency
  - `module_registry.ex` — dropped `PhoenixKit.Modules.CustomerService` from `internal_modules/0`, added the corresponding `phoenix_kit_customer_support` entry to `known_external_packages/0`
  - `integration.ex` — replaced inline `/dashboard/customer-service/tickets` route blocks with `Code.ensure_loaded?(PhoenixKitCustomerSupport.Web.UserList)` guards so absent-package = no routes
  - DB tables (`phoenix_kit_tickets`, `phoenix_kit_ticket_*`) stay in core under their existing names — they're domain-shaped, not module-shaped, and the prior migrations (V35/V51/V53/V58/V72/V74/V75/V77) remain in core's migration history
- Renamed "Customer Service" → "Customer Support" across the public surface (PR #514)
  - Module: `PhoenixKitCustomerService` → `PhoenixKitCustomerSupport`
  - OTP app: `:phoenix_kit_customer_service` → `:phoenix_kit_customer_support`
  - Hex package: `phoenix_kit_customer_service` → `phoenix_kit_customer_support`
  - Settings keys: `customer_service_*` → `customer_support_*` (7 keys)
  - URL paths: `/customer-service/*` → `/customer-support/*` (admin + user-facing, both base and locale-prefixed routes)
  - Permission key: `customer_service` → `customer_support`
  - Dashboard module card and admin nav target updated to match

### Added
- V109 migration: rename Customer Service module identifiers in-place so existing installs migrate cleanly (PR #514)
  - Renames 7 settings keys from `customer_service_*` → `customer_support_*` in `phoenix_kit_settings`
  - Renames `auto_granted_perm:customer_service` → `auto_granted_perm:customer_support`
  - Renames `phoenix_kit_role_permissions.module_key` from `customer_service` → `customer_support`
  - Idempotent (`IF EXISTS` guards on every rename); reversible `down/1` for emergency rollback
  - `@current_version` 108 → 109; ⚡ LATEST tag moved off V107 onto V109

### Fixed
- `PhoenixKit.Users.Auth.anonymize_user_tickets/1` was a no-op since the original Tickets → CustomerService rename — `Module.concat([PhoenixKit, Modules, Tickets, Ticket])` resolved to a never-loaded module so the `Code.ensure_loaded?` guard always failed and ticket anonymization silently skipped on user deletion. Now points at `PhoenixKitCustomerSupport.Ticket` (PR #514)
- V108 (drag-and-drop position columns, shipped in 1.7.103) was missing from the `lib/phoenix_kit/migrations/postgres.ex` per-version docstring catalog. Backfilled in this release alongside the V109 entry (PR #514 review)
- `lib/phoenix_kit/migrations/postgres/v109.ex` `rename_role_permission/4` carried an unused `_prefix` arg — the table name is already prefix-qualified at the call site. Trimmed to `/3` (PR #514 review)

## 1.7.103 - 2026-05-02

### Added
- V107 migration: pin AI endpoints to a specific integration row via `integration_uuid` + add the missing unique index on `lower(name)` (PR #511)
  - Nullable `integration_uuid uuid` column on `phoenix_kit_ai_endpoints` with btree index
  - Backfill maps existing `provider` strings to integration rows: exact `"provider:name"` matches get the corresponding storage row; bare `"provider"` gets the most-recently-validated `integration:provider:*` row, tiebreaking on `uuid ASC` (UUIDv7 time-ordered). Unresolvable endpoints stay NULL
  - Unique index `phoenix_kit_ai_endpoints_name_index ON (lower(name))` — the `unique_constraint(:name)` declaration in the changeset has been dead code since V34 created this table without the index
- V108 migration: `position integer DEFAULT 0` on three admin list surfaces — `phoenix_kit_entities`, `phoenix_kit_cat_catalogues`, `phoenix_kit_cat_items` — so drag-and-drop reordering can persist user-driven order (PR #512)
- Strict-UUID Integrations public API (PR #511)
  - Write-side APIs now take only the integration row's uuid — no more deriving storage keys from JSONB fields
  - `Integrations.resolve_to_uuid/1` — dual-input lookup primitive that accepts a uuid or a `provider:name` string (for `migrate_legacy/0` callbacks)
  - `migrate_legacy/0` optional callback on `PhoenixKit.Module` — each module owns its legacy data shape; core provides primitives. Orchestrated by `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`
  - Mistral, DeepSeek, and Microsoft 365 added to the built-in providers registry
  - `integration_picker` updated: no auto-select on single-provider, toggle-to-deselect support
- Drag-and-drop core infrastructure (PR #512)
  - `<.draggable_list>` new `:draggable` boolean attr (default `true`) — when false, renders without SortableJS hook and grab-cursor styling
  - `<.table_default>` new `:on_reorder`, `:reorder_scope`, `:reorder_group`, `:item_id` attrs — wire the card-view container as a SortableGrid hook target for cross-container drag
  - `SortableGrid` hook (JS): `data-sortable-group` for cross-container drag, `readScope/1` helper for `data-sortable-scope-*` attrs, cross-container `onEnd` detection with `from*` scope prefix, `try/catch` wrapping
  - `TableCardView` hook (JS): `updated()` callback re-applies saved view mode after LV re-renders so card/table toggle survives SortableJS drops
- Media viewer modal on `MediaBrowser` (PR #513)
  - New `viewer={true}` attr — clicking a file opens an in-place modal with image/video/PDF/icon preview, metadata sidebar (filename, type, MIME, size, uploaded date), and Download button. Closes via X / Esc / backdrop
  - Prev/next chevrons and ArrowLeft/ArrowRight keyboard shortcuts step through the current page's files; arrows hide at boundaries
  - `PhoenixKitComments.Web.CommentsComponent` embedded in the sidebar when the Comments module is installed and enabled (optional-dep wiring: `@compile {:no_warn_undefined}` + `Code.ensure_loaded?` + `@dialyzer :nowarn_function`)
- Arity-2 `dynamic_children_fn` `@typedoc` + test-only delegate for the admin sidebar dispatcher (PR #506 follow-up in #512)

### Changed
- `handle_event("click_file", …)` in MediaBrowser refactored from two-mode `if/else` to four-clause `cond`: `select_mode` → `admin` → `viewer` → picker default (PR #513)
- `connected_at` semantics clarified in AGENTS.md — rewritten on every successful re-test (not one-shot); `last_validated_at` rewritten unconditionally on every validation attempt, success or failure
- Bumped `leaf` editor dependency `~> 0.2.10 → ~> 0.2.11` and the matching CDN URL (PR #513)

### Fixed
- AGENTS.md doc drift: `PhoenixKit.Modules.run_all_legacy_migrations/0` corrected to `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`; V107 moduledoc tiebreak clarified as `uuid ASC` not `inserted_at ASC` (PR #511 review)
- V107 unique-name index verified with three new integration tests: index exists, duplicate names rejected, case-only differences collide (PR #511 review)
- Media viewer modal: `String.starts_with?/2` guarded with `is_binary(f.mime_type)` so nil mime_type falls through to the icon fallback instead of crashing (PR #513 review)
- Media viewer modal: PDF iframe hardened with `sandbox="allow-same-origin"` to block embedded JavaScript in same-origin deployments (PR #513 review)
- `<.draggable_list>` `data-id` now always emitted regardless of `:draggable` attr so click-to-select handlers and test selectors work in both modes (PR #512 review)
- `:reorder_scope` attr doc on `<.table_default>` now documents the camelCase round-trip (`:category_uuid` → `"categoryUuid"` in the LV handler payload) (PR #512 review)

## 1.7.102 - 2026-04-29

### Added
- V105 migration: CRM tables for the upcoming `phoenix_kit_crm` plugin (PR #507)
  - `phoenix_kit_crm_role_settings` — one row per role with `enabled BOOLEAN NOT NULL DEFAULT false` so existing roles stay opted out until explicitly enabled. PK on `role_uuid`; FK → `phoenix_kit_user_roles(uuid)` ON DELETE CASCADE
  - `phoenix_kit_crm_user_role_view` — per-user, per-scope view preferences (column selection, ordering, filters). UUIDv7 PK; unique `(user_uuid, scope)`; index on `(user_uuid)`; FK → `phoenix_kit_users(uuid)` ON DELETE CASCADE. `scope` is a string like `"role:<uuid>"` or `"companies"`
- V106 migration: split `phoenix_kit_projects.name` uniqueness across templates and real projects (PR #510)
  - Replaces V101's single global unique index on `lower(name)` with two partial unique indexes: `phoenix_kit_projects_name_template_index WHERE is_template = true` and `phoenix_kit_projects_name_project_index WHERE is_template = false`
  - Lets a template `"Onboarding"` and a real project `"Onboarding"` coexist, unblocking `Projects.create_project_from_template/2` for the common reuse-the-template-name path
  - `down/1` recreates V101's single global index; lossy if a template and a real project share a name post-V106 — resolve duplicates before rolling back
- Legal module i18n — translations across `de/fr/it/pl` plus refreshed `ru/es`. New `de/fr/it/pl` POs created via `mix gettext.merge --locale` with proper `Plural-Forms` headers (German `n != 1`, French `n > 1`, Italian `n != 1`, Polish 3-form rule). Pre-existing non-empty `msgstr` values preserved (PR #509)
- `lib/phoenix_kit_web/legal_gettext_manifest.ex` — re-emits the 50 translatable strings used by `phoenix_kit_legal` so the gettext extractor (which doesn't walk into deps) records them into core's POT. Never called at runtime; pure extraction target with refresh procedure documented in the moduledoc (PR #509)
- `css_sources/0` accepts string entries — `@callback css_sources()` widened from `[atom()]` to `[atom() | String.t()]`. Strings flow through `format_source/2` → `source_for_path/1` (absolute paths emit `@source "<abs>";` verbatim, relative get the standard `../../` prefix); atoms continue to resolve via parent app's mix.exs deps. Lets modules mix OTP-app atoms with literal path strings — first known consumer is `phoenix_kit_legal`, which ships a path-dep absolute fallback alongside its OTP-app entry so both Hex and path-dep installs work without parent-app toggles. Backwards compatible: existing `def css_sources, do: [:phoenix_kit_my_module]` keeps working unchanged (PR #509)

### Changed
- Bumped `leaf` editor dependency `~> 0.2.6 → ~> 0.2.10` and the matching CDN URL in `priv/static/assets/phoenix_kit.js` so the runtime loader pulls the same version. Includes `min-width: 0` + toolbar-wrap fixes so the editor stops claiming an unbounded intrinsic width on mount (PR #508)
- `priv/gettext/default.pot` cleanup — dropped ~900 phantom msgids left over from modules extracted to standalone packages (billing, publishing, entities, etc.) (PR #509)

### Fixed
- `application/pdf` uploads in MediaBrowser. `determine_file_type/1` returned `"pdf"`, but the `File` changeset validates `file_type` against `["image", "video", "audio", "document", "archive", "other"]` — every PDF upload silently failed validation and never reached any bucket. Now maps `application/pdf` → `"document"`, matching how form-upload integrations already classify PDFs (PR #507)
- V106 `COMMENT ON TABLE` version values were off by one (`up` wrote `'105'` instead of `'106'`, `down` wrote `'104'` instead of `'105'`). The migration framework reads this comment as the source of truth for the migrated version, so on the incremental V105 → V106 upgrade path the comment never advanced past `'105'` — V106.up would replay on every deploy and the admin dashboard / `mix phoenix_kit.status` would report a stale version. Fresh installs masked the bug because `handle_version_recording/4` stamps the final version on multi-step runs and overrode V106's bad write. Caught in review of PR #510 and amended in place since V106 had not yet shipped to Hex

## 1.7.101 - 2026-04-24

### Added
- **Notifications module** — per-user inbox driven by the activity log. When `PhoenixKit.Activity.log/1` records an entry with `target_uuid != actor_uuid`, a row is inserted into `phoenix_kit_notifications` for the target user. Independent `seen_at` / `dismissed_at` per row, per-user PubSub topic (`"phoenix_kit:notifications:<user_uuid>"`), global kill-switch via `notifications_enabled` setting (default `"true"`). Admins still audit via `/admin/activity` and don't receive notifications (PR #505)
  - V104 migration: `phoenix_kit_notifications` with UUIDv7 PK, FKs to `phoenix_kit_activities` and `phoenix_kit_users` (both `ON DELETE CASCADE`), unique `(activity_uuid, recipient_uuid)` index, partial `(recipient_uuid, inserted_at DESC) WHERE dismissed_at IS NULL` index for the inbox read path
  - `PhoenixKit.Notifications` public API: `maybe_create_from_activity/1`, `list_for_user/2`, `recent_for_user/2`, `count_unread/1`, `mark_seen/2`, `mark_all_seen/1`, `dismiss/2`, `dismiss_all/1`, `get_notification/2`, `enabled?/0`, `retention_days/0`, `prune/1`
  - `PhoenixKit.Notifications.Render.render/1` — maps action → `%{icon, text, link, actor_uuid}`; honors metadata overrides (`notification_text`, `notification_icon`, `notification_link`) before falling back to the action lookup
  - `PhoenixKit.Notifications.Types` registry — three core types (`account`, `posts`, `comments`) plus extension point for external modules via the new optional `notification_types/0` callback on `PhoenixKit.Module`
  - `PhoenixKit.Notifications.Prefs` — per-user preferences persisted in `custom_fields.notification_preferences` (reuses V18 JSONB column; no migration). Fail-open on any ambiguity
  - `PhoenixKit.Notifications.PruneWorker` — daily Oban cron at `"0 4 * * *"`; retention via `notifications_retention_days` (falls back to `activity_retention_days`, default 90)
  - `PhoenixKitWeb.Live.NotificationsBell` — sticky nested LiveView for the bell + dropdown. Not mounted by default; parent apps render it where they have a user-facing header via `Phoenix.Component.live_render(..., sticky: true, session: %{"user_uuid" => ...})`. Badge + recent list refresh live via PubSub
  - Notification preferences section in `PhoenixKitWeb.Live.Components.UserSettings` — one toggle per registered type; unknown submitted keys dropped at the call site
  - `notifications_enabled` toggle on `/admin/settings`
- Arity-2 `dynamic_children_fn` for admin sidebar tabs — callbacks can now be `(scope, locale -> [tab])` in addition to the existing `(scope -> [tab])`. Backwards-compatible extension: the sidebar dispatches on arity, every existing 1-arity callback keeps working unchanged. Lets plugins render locale-aware child labels without reading `Gettext.get_locale/1` at render time (PR #506)

## 1.7.100 - 2026-04-22

### Added
- V103 migration: nullable self-FK `parent_uuid` on `phoenix_kit_cat_categories` with b-tree index on `(parent_uuid)` for arbitrary-depth category trees. Existing rows stay `NULL` and become roots — no backfill. No DB-level `ON DELETE` cascade (subtree cascades are owned by the context layer so they go through soft-delete + activity log) (PR #503)
- `scope_folder_id` attr on `PhoenixKitWeb.Live.Components.MediaSelectorModal` — filters the browse query to the given folder plus any files reached via `FolderLink`, and assigns newly-uploaded files into that folder (adopt as home if orphan, else add a `FolderLink`). Plugins scoping the picker to a single domain object (e.g. a catalogue item) pass this after lazy-creating their folder (PR #503)
- `PhoenixKit.Settings.Setting.optional_settings/0` accessor exposing `@optional_settings` for invariant tests
- Invariant test (`test/phoenix_kit/settings/setting_test.exs`) asserting every empty-string default in `PhoenixKit.Settings.get_defaults/0` is also in `@optional_settings`, to prevent the class of bug fixed in PR #502 from recurring

### Changed
- `PhoenixKit.Modules.Storage.File` changeset `file_type` allowlist widened from `["image", "video", "document", "archive"]` to include `"audio"` and `"other"` so non-image/video uploads bucket cleanly (PR #503)
- `MediaSelectorModal.load_files/2` refactored into four composable `scope_files_by_{user,folder,type,search}` helpers — credo cyclomatic-complexity fix from adding the new scope branch (PR #503)

### Fixed
- Settings batch save no longer rolls back when `site_icon_file_uuid` or `default_tab_title` is left empty on the General Settings form. Both keys added to `@optional_settings` in `PhoenixKit.Settings.Setting` and seeded with empty-string defaults in `PhoenixKit.Settings.get_defaults/0` (PR #502)
- `MediaSelectorModal.maybe_set_folder/2` errors (from the `folder_uuid` update or `FolderLink` insert) now log a warning via `warn_on_folder_error/3` instead of being silently discarded by `_ =`. Previously, a failed scope assignment after a successful upload left no trace

## 1.7.99 - 2026-04-20

### Added
- V100 migration: staff tables — `phoenix_kit_staff_departments`, `phoenix_kit_staff_teams`, `phoenix_kit_staff_people`, `phoenix_kit_staff_team_memberships` (PR #498)
- V101 migration: projects tables — `phoenix_kit_project_tasks`, `phoenix_kit_project_task_dependencies`, `phoenix_kit_projects`, `phoenix_kit_project_assignments`, `phoenix_kit_project_dependencies`; polymorphic assignee with `CHECK (num_nonnulls(...) <= 1)` (PR #498)
- V102 migration: smart catalogues + per-catalogue/item discount (PR #500)
  - `phoenix_kit_cat_catalogues.discount_percentage` (NOT NULL DEFAULT 0) and `kind` (`'standard' | 'smart'`) columns with CHECK constraints
  - `phoenix_kit_cat_items.discount_percentage`, `default_value`, `default_unit` override columns
  - new `phoenix_kit_cat_item_catalogue_rules` table with unique `(item_uuid, referenced_catalogue_uuid)` and ON DELETE CASCADE on both FKs
  - partial index on `kind = 'smart'`
- `PhoenixKitWeb.Components.MediaBrowser.Embed` — one-line `use` macro that injects `on_mount` upload setup, the `"validate"` upload-channel stub, and the MediaBrowser `handle_info` delegator (PR #499)
- MediaBrowser selection menu with bulk download (staggered `<a download>` dispatch via `MediaDragDrop` hook) (PR #499)
- MediaBrowser `admin` attr to gate detail-page `push_navigate` — picker mode (default) vs admin mode (PR #499)
- MediaBrowser drag-drop file-to-folder move (PR #499)
- MediaBrowser toggleable search bar in the header (PR #499)
- MediaBrowser drag-drop upload at any folder level (PR #499)
- Site icon + default tab title settings, logo moved to main settings page (PR #499)
- MultilangForm debounce flow: `mount_multilang/1` attaches a hidden `:handle_info` hook via `Phoenix.LiveView.attach_hook/4`; `handle_switch_language/2` schedules a 150 ms trailing debounce via `Process.send_after` (timer ref stored in `socket.private` to avoid render+diff cycles); `switch_lang_js/2` toggles skeleton/fields `hidden` classes client-side at t=0 (PR #500)
- `<.input>` gains a `wrapper_class` attr for the outer `phx-feedback-for` div (PR #500)
- `test_load_filters` / `test_ignore_filters` in `mix.exs` for Elixir 1.19 `mix test` hygiene (PR #500)
- AGENTS.md: Core Form Components section, Multilang Form Components section, and CHANGELOG-ownership rule (entries written by the maintainer, not agents)

### Changed
- MediaBrowser sidebar and content unified into a single card (PR #499)
- Scope-root new-folder form aligned with sibling folder rows (PR #499)
- Core form components (`<.input>`, `<.select>`, `<.textarea>`, `<.checkbox>`) now merge the `class` attr onto the styled element itself — matches the Phoenix 1.7 generator convention. No in-tree caller used the old wrapper-class behavior; external consumers should switch to `wrapper_class` on `<.input>` (PR #500)
- `compile.phoenix_kit_css_sources` emits absolute dep paths verbatim instead of prefixing `../../` (PR #500)

### Fixed
- MediaBrowser list view broken by stale view-toggle CSS (PR #499)
- Credo `AliasUsage` warning inside `MediaBrowser.Embed`'s quoted block silenced (PR #499)

## 1.7.98 - 2026-04-16

### Added
- V99 migration: `trashed_at` column on `phoenix_kit_files` with partial index for soft-delete (PR #497)
- Media trash bucket: soft-delete files with restore/empty/permanent-delete actions and sidebar count badge
- `PhoenixKit.Modules.Storage.Workers.PruneTrashJob` — daily Oban cron (3 AM) that permanently deletes files older than `trash_retention_days` (default 30)
- Drag-drop upload: drop device files directly onto the folder content area (`FolderDropUpload` JS hook)
- URL-param hydration on first mount so reloads don't flash the root view

### Fixed
- Scope guard on `restore_selected` in MediaBrowser — a scoped embed could previously restore files outside its scope via a crafted `toggle_select` payload
- Trash view, permanent-delete, and `empty_trash` now respect `scope_folder_id` via recursive CTE
- `list_files/1` excludes trashed files
- Breadcrumb and search bar moved inside card body so padding matches grid/list content

## 1.7.97 - 2026-04-15

### Added
- V97 migration: per-item `markup_percentage` override on catalogue items (PR #493)
- V98 migration: `alternative_formats` column on storage dimensions
- `PhoenixKit.Modules.Shared.Components.ImageSet` — responsive `<picture>` component with AVIF/WebP/JPEG `<source>` entries
- `PhoenixKit.Modules.Storage.VariantNaming` — format-suffix parsing utility
- Multi-format variant generation (WebP/AVIF alongside primary format per dimension)
- Variant dimensions and file sizes shown on media detail page
- UUID search support on media page search bar

### Changed
- V95 migration made truly idempotent for `folder_uuid` column (raw SQL `IF NOT EXISTS` block)
- Dimensions table format cell renders as `JPEG + WEBP, AVIF` (fixed stray `" +"` separator)

### Fixed
- Long text overflow in media detail sidebar
- Missing original file size in variant download buttons

## 1.7.96 - 2026-04-13

### Added
- Sortable languages in admin (drag-and-drop reorder)
- hide_source option on DraggableList component
- Wiggle animation for reorder mode with prefers-reduced-motion support

### Changed
- Dedup language codes in reorder, use MapSet for lookup
- Extract wiggle CSS to JS-injected styles with pk- prefix

## 1.7.95 - 2026-04-11

### Added
- V95 migration: media folders and folder links tables
- V96 migration: catalogue_uuid FK on catalogue items for direct catalogue membership

## 1.7.94 - 2026-04-10

### Added
- Media folder system with sidebar, select mode, list/grid view, drag-drop file moving
- Folder colors, inline rename, select folders, and context menus
- Search bar and folder path column to media page
- Media Health page for redundancy monitoring
- Sync with progress tracking, pause/resume/stop controls, real-time sync log
- Media sync moved to Oban worker for persistence and reliability
- Multipart S3 uploads
- Tigris storage provider support
- Test Connection button to bucket form
- Configurable max upload size setting
- Reusable SearchableSelect LiveComponent
- Provider-specific labels for B2, R2, and S3 bucket configuration
- AWS regions dropdown via `aws_regions` hex package

### Changed
- Rename Storage to Media, use thumbnail variant for media grid
- Redesign media sidebar with proper file explorer conventions
- Migrate bucket and dimensions tables to `table_default` component
- Restyle bucket/dimension forms with card sections and DaisyUI 5 fieldset/legend
- Persist folder tree expand state and sidebar collapsed in localStorage
- Remove LLMText module (preserved in feature/llmtext branch)
- Remove CDN URL field from bucket configuration form

### Fixed
- Fix #478: register CSS sources compiler and create stub file on install
- Fix integration activity logs always having nil actor_uuid
- Fix S3 upload failures and false file location records
- Fix folder card hover lag (use `transition-colors` instead of `transition-all`)
- Fix folder name truncation, rename animation, and input autofocus
- Fix select mode content jump and improve render performance
- Fix mix tasks: `Routes.path` unavailable, `ecto.migrate` skips host repo
- Fix OAuth users getting signed out after ~1-2 hours

## 1.7.93 - 2026-04-08

### Fixed
- Fix installer to auto-inject PhoenixKitHooks into app.js
- Fix decrypt after legacy integration migration
- Improve OAuth login with remember_me by default

### Added
- Activity logging for Integrations (setup, connect, disconnect, token refresh, validation)
- Cookie max_age set to 60 days

### Changed
- Simplify integration status: `configured` removed, now `connected` or `disconnected`
- Validate connection checks provider exists before credentials

## 1.7.92 - 2026-04-07

### Fixed
- Fix Google token refresh for named integration connections (e.g. google:work)
- Add resolve_provider_lookup_key/2 and resolve_storage_key/2 helpers

### Added
- Add V94 migration for Document Creator sync (google_doc_id, status, path, folder_id columns)

## 1.7.91 - 2026-04-06

### Added
- Add centralized Integrations system for external service connections (OAuth, API keys, bot tokens)
- Add AES-256-GCM encryption at rest for stored credentials
- Add OAuth 2.0 CSRF state parameter protection
- Add `required_integrations/0` and `integration_providers/0` callbacks to PhoenixKit.Module
- Add IntegrationPicker reusable component
- Add Integrations admin settings tab
- Add provider registry with Google and OpenRouter built-in

### Fixed
- Fix password field overwrite bug when editing integrations
- Fix duplicate line in `maybe_set_userinfo/2`
- Consolidate validation logic into Integrations context
- Make validation URL provider-configurable (no more hardcoded Telegram URL)

## 1.7.90 - 2026-04-04

### Added
- Add organization accounts support with person/organization user types
- Add organization invitations system with token-based invite flow
- Add V91 locations migration: location types, locations, and type assignments tables
- Add V92 organization accounts migration (invitations, user type fields)
- Add JS hooks integration for parent app install and update workflows
- Add LLMText module for AI/LLM-friendly content generation
- Add auth logo from settings to admin header
- Add billing tabs component

### Changed
- Move tax rate and CountryData from Billing to core PhoenixKit
- Remove hardcoded Billing and E-Commerce module cards in favor of auto-discovery
- Update AGENTS.md with severity level definitions and JS hooks documentation

### Fixed
- Fix double sidebar for core modules and improve struct compatibility
- Hide hamburger menu button when sidebar is permanently visible
- Fix token security, gettext, and validation issues in organization invitations
- Fix tax data loss, invitation status guard, and IbanData safety

## 1.7.88 - 2026-04-02

### Changed
- Migrate select elements to daisyUI 5 label wrapper pattern (#472)

### Fixed
- Fix negated condition in maintenance toggle flash message
- Fix dialyzer warnings for CSS sources compiler, clean up 6 stale ignore entries

## 1.7.87 - 2026-03-31

### Added
- Add V89 migration: catalogue pricing with base_price and markup_percentage
- Add status_badge component and wrapper_class attr to table_default
- Add inline and auto display modes to table_row_menu
- Add show_toggle attr to table_default and sync TableCardView instances
- Add continent grouping to language switcher for many languages
- Add language system tests, docs, error handling, and group_by_continent option

### Changed
- Unify admin and frontend language systems into single source of truth
- Unify status badge components into single status_badge
- Remove deprecated select-bordered class for daisyUI 5 compatibility
- Disable automatic CI triggers, switch to manual-only

### Fixed
- Fix language switcher URL generation for prefixed admin paths
- Fix dialyzer warnings in language switcher URL generation

## 1.7.86 - 2026-03-30

### Changed
- Update Shop module references from `PhoenixKit.Modules.Shop` to `PhoenixKitEcommerce` namespace
- Update Billing module references from `PhoenixKit.Modules.Billing` to `PhoenixKitBilling` namespace
- Restore LayoutWrapper in core module templates (not auto-applied to bundled modules)
- Document `extra_applications` requirement for external module auto-discovery

### Fixed
- Fix missing `url_path` assign in referrals LiveViews causing runtime crash after LayoutWrapper restoration
- Fix media selector modal mobile responsiveness (header overflow, button sizing, padding)

## 1.7.85 - 2026-03-30

### Added
- Add user-scoped media selector for avatar and fix custom fields position bug

### Changed
- Remove Pages module from core and clean up all references
- Extract Connections module into external `phoenix_kit_user_connections` package
- Remove unused Storage alias from user settings

## 1.7.84 - 2026-03-28

### Added
- Add missing cookie consent widget to dashboard layout
- Add user dashboard routes for billing profiles

### Changed
- Remove Legal module from core (extracted to `phoenix_kit_legal` package)
- Remove LayoutWrapper from remaining storage and maintenance templates
- Remove duplicate LayoutWrapper from admin module templates

### Fixed
- Fix core modules misclassified as external plugin views causing double admin chrome

## 1.7.83 - 2026-03-27

### Added
- Add V88 migration: Publishing schema V2 restructure
- Add user dashboard generator with LiveView templates and standardize layout
- Add `--index` flag to user dashboard generator for overriding default dashboard
- Add Estonian to backend languages, fix Chinese code zh-CN → zh
- Add CountryData to core utils for billing extraction
- Add sitemap scheduler startup recovery

### Changed
- Extract Comments module into external `phoenix_kit_comments` package
- Remove Shop module from core (extracted to `phoenix_kit_ecommerce` package)
- Remove Billing module from core (extracted to `phoenix_kit_billing` package)
- Replace hardcoded external module stats with generic `module_stats` callback
- Remove hardcoded module cards for extracted packages
- Rename and simplify admin page generator
- Update Leaf dependency to v0.2.6

### Fixed
- Fix V88 migration: index prefix and partial re-run safety
- Fix orphan files query to use `publishing_versions` table
- Fix post-review issues from PR #453: Shop.Cart guard, consent attrs, language naming
- Fix shop modules: remove billing struct patterns and fix nil clause ordering
- Fix double navbar on comments admin pages
- Fix auth page background breaking footer and page layout

## 1.7.82 - 2026-03-24

### Added
- Add V86 migration: Document Creator tables (headers_footers, templates, documents)
- Add V87 migration: Catalogue tables (manufacturers, suppliers, catalogues, categories, items)
- Add `system_prompt` field to AI prompts and AI Playground page
- Add database connection check to install and update tasks
- Add AdminEditHelper for universal admin edit links in public views
- Add email provider behaviour, refactor Mailer and UserNotifier
- Add lastmod to sitemap group listings and homepage
- Enrich external module cards with config stats, settings link, and `module_card` component

### Changed
- Extract Emails module from core to standalone `phoenix_kit_emails` package
- Extract Publishing module to standalone `phoenix_kit_publishing` package
- Extract Entities module to standalone `phoenix_kit_entities` package
- Extract AI module to standalone `phoenix_kit_ai` package
- Remove hardcoded Emails block from Modules page — now rendered as external package
- Guard all Publishing references behind `Code.ensure_loaded?` for external module support
- Guard EntityForm render call with `Code.ensure_loaded?` check in Pages renderer
- Suppress warnings for optional external modules with `@compile :no_warn_undefined`
- Exclude external module namespaces from Credo alias usage check
- Make module registry and permissions tests count-independent after module extractions
- Document `ensure_compiled` vs `ensure_loaded?` choice in integration route collection
- Update Leaf dependency to v0.2.5

### Fixed
- Fix V86/V87 migrations to use `uuid_generate_v7()` instead of `gen_random_uuid()`
- Fix post-merge issues from Emails extraction
- Fix `extract_admin_links`: skip parent tabs, deduplicate paths
- Fix `external_plugin_view?` to recognize `PhoenixKit.Modules.*.Web` as external packages
- Fix DbConnectionCheck: correct spec, naming, and remove hard exit from status task
- Fix media selector modal z-index to appear above all overlays
- Fix `module_card` to render `hero-*` icons properly
- Fix cookie consent: dynamic legal links, theme-aware backdrop, daisyUI toggle

## 1.7.81 - 2026-03-21

### Changed
- Extract Posts module to standalone `phoenix_kit_posts` package
- Update Comments module to conditionally load Posts handler via `Code.ensure_loaded?/1`
- Update scheduled jobs worker with extracted catch-up helpers for optional Posts dispatch

## 1.7.80 - 2026-03-20

### Added
- Add `uuid` type to custom fields system
- Add auto-registration of custom field definitions on save with type inference

### Changed
- Extract Sync module to standalone `phoenix_kit_sync` package
- Move custom fields domain logic to `CustomFields` module, deduplicate UUID regex, add error logging
- Fix permissions table style — replace manual zebra striping with daisyUI `table-zebra`, use primary-colored header

### Fixed
- Fix avatar upload handling and `custom_fields` preservation in UserSettings
- Fix admin page and user dashboard styles
- Fix plugin reference name in module system guide

## 1.7.79 - 2026-03-20

### Fixed
- Fix UserSettings regressions from PR #436 redesign:
  - Restore timezone selector (timezone select, mismatch warning, browser detection)
  - Restore Apple OAuth provider icon (`hero-device-phone-mobile`)
  - Restore OAuth-only password warning for users without passwords
  - Restore provider email display in connected accounts list
  - Fix custom field `select` using index-based values instead of actual option values (data compatibility break)
  - Restore all custom field input types (`textarea`, `number`, `email`, `url`, `date`) — were collapsed to plain text
  - Restore `required` attribute on custom field inputs
  - Restore unique `id` attributes on password/email form hidden inputs
  - Restore profile/avatar success and error messages in template
  - Fix `shadow-xl` → `shadow-sm` for card styling consistency
  - Fix divider placement — move out of username field, add "Additional Information" heading for custom fields
  - Extract `extract_custom_fields/1` and `merge_custom_fields/3` helpers to DRY duplicated logic

## 1.7.78 - 2026-03-18

### Added
- Add Tailwind/daisyUI class injection for markdown rendering — replaces inline `<style>` block with classes injected during Earmark post-processing (works without `@tailwindcss/typography` plugin)
- Add blank line preservation in markdown content — intentional double blank lines render as visible spacing
- Add translation worker retry resilience — on retry, already-translated languages are skipped by checking content timestamps against job `inserted_at`
- Add dynamic timeout scaling for translation worker (~1.5 min per language, minimum 15 minutes)
- Add structured logging with consistent prefixes (`[Sync.Notifier]`, `[Sync.API]`, `[Sync.Connections]`) throughout Sync connection flow
- Add connection event logging on both sender and receiver sides for debugging

### Changed
- Rename Sync "Sender/Receiver" terminology to "Outgoing/Incoming" across UI
- Allow editing incoming Sync connections (previously restricted to outgoing only)
- Remove "with permanent connections" from Sync index page subtitle
- Bump markdown render cache version to v2 to invalidate stale cached HTML

### Fixed
- Fix Sync sender URL resolving to `localhost:4000` — now checks DB `site_url` setting before falling back to endpoint config
- Fix `auth_token_hash` logged in full — truncate to first 8 characters in Sync connection logs
- Fix double `get_our_site_url()` call per notification — pass resolved URL instead of recomputing
- Fix Sync crash on non-UTF8 binary data — base64-encode raw binaries during serialization, decode on import
- Fix Sync pull error responses silently ignored — add `Logger.error` to all failure paths (401, 404, HTTP errors, offline, invalid response)
- Fix Sync completion UI not showing skipped/errored records — track and display per-table import counts with warning state

## 1.7.77 - 2026-03-17

### Added
- Add Open Graph and Twitter Card meta tags for public publishing pages (og:title, og:description, og:image, og:url, og:locale, canonical link, and Twitter Card tags)
- Add `og:site_name` meta tag using project title
- Add `resolve_language_key/2` helper to `LanguageHelpers` for base code to dialect code matching in language maps
- Add Tailwind Typography prose overrides using daisyUI theme variables (oklch(--bc), oklch(--p), oklch(--b2), oklch(--b3)) for theme-aware markdown styling
- Add automated scheduled jobs cleanup to prevent table bloat (deletes completed jobs older than 7 days)
- Add `lastmod` (last modified) to sitemap entries for SEO — router-discovered routes use beam file mtime, static entries use current date

### Changed
- Replace inline markdown CSS with centralized prose overrides in `app.css` using `@layer base` (removes 323 lines of duplication)
- Update publishing preview template to show full public interface with working language switcher
- Move `MarkdownContent` component to use Tailwind prose classes instead of custom inline styles
- Extract duplicated `resolve_language_key/2` from `listing.ex` and `html.ex` to shared `LanguageHelpers` module
- Extract `update_post_from_form/3` from publishing editor to reduce cyclomatic complexity (from >10 to <10)
- Update Leaf content editor dependency from v0.1.0 to v0.2.0

### Fixed
- Fix `mix phoenix_kit.status` showing V01 instead of actual migration version — properly start Repo with parent app config when using `--no-start`
- Fix language map lookup when canonical URL uses base code (e.g., "en" → "en-US" matching)
- Fix `absolute_url/2` to use stricter URL protocol checking ("http://" or "https://" instead of just "http")
- Fix preview language links to conditionally include version parameter only when version is non-nil
- Fix translation reload showing primary language content instead of translated content
- Fix PubSub subscription mismatch for translation and version events on timestamp-mode posts (slug vs uuid topic mismatch)
- Fix email template seeding failing on fresh install (wrap string fields in i18n maps)
- Fix whitespace in slug format examples on publishing group pages

## 1.7.76 - 2026-03-16

### Fixed
- Fix `mix phoenix_kit.status` port conflict when app is already running (use `--no-start` to avoid booting the HTTP endpoint)
- Add self-healing version comment detection — automatically corrects V83 comment bug where migrations ran but version stayed at V82

## 1.7.75 - 2026-03-16

### Added
- Add `custom_fields` support to `registration_changeset/3` for atomic user creation with custom metadata
- Add entity data view extension documentation and route override pattern

### Fixed
- Fix mobile overflow issues in email module UI (queue, blocklist, metrics, template editor)
- Fix early validation in template editor — errors only shown after first user interaction
- Fix Send Test Email modal overflowing on mobile (max-w-4xl → max-w-2xl)
- Fix V83 migration missing `down/1` version comment rollback
- Fix V83 migration prefix_str inconsistency in version comment
- Fix dialyzer `guard_fail` warnings from upstream publishing merge
- Fix remaining doc warnings for delegated hidden functions

## 1.7.74 - 2026-03-16

### Fixed
- Remove dead `should_regenerate_cache?/1` from Shared module (uncalled function returning `true` in every branch)
- Remove obsolete `bulk_operation_topic` test referencing deleted PubSub function
- Fix missing trailing newline in `shared.ex`

## 1.7.73 - 2026-03-13

### Changed
- Move module access guards from individual mount functions to centralized `enforce_admin_view_permission` hook
- Disabled modules now block all roles (including Owner/Admin) at the `on_mount` level, covering all ~50 admin LiveViews automatically
- Remove per-LiveView `enabled?()` mount guards from AI, Entities, Publishing, Sitemap, Billing, Customer Service, Emails, Email Tracking, Legal, Referrals, Shop settings

## 1.7.72 - 2026-03-13

### Added
- Add module access guards — disabled modules now hide action buttons and block mount on settings/endpoints
- Add error flash auto-dismiss after 8 seconds
- Add `enabled?()` mount guards to AI, Media, Entities, Publishing, Sitemap endpoints
- Add error logging in Legal `list_generated_pages` instead of silent rescue

### Fixed
- Fix Legal module broken connection with DB-backed Publishing (`post.path` → `post.uuid`, `updated_at` → `published_at`)
- Fix Legal module Configure button guard when module is disabled
- Fix Sitemap RouterDiscovery including routes from disabled modules
- Fix DB.Listener missing `{:eventually, _ref}` case for auto_reconnect

### Changed
- Remove duplicate enable/disable toggles from 7 module settings pages (Emails, Email Tracking, Legal, Referrals, Billing, Customer Service, Shop)
- Simplify primary_language lookup in Publishing.DBStorage

## 1.7.71 - 2026-03-12

### Fixed
- Fix mixed atom/string key error in `EntityData.maybe_add_position/1` when auto-assigning position to string-keyed params
- Fix same mixed key error in `EntityData.maybe_add_created_by/1`
- Fix `FOR UPDATE` with aggregate function error in `EntityData.next_position/1` (PostgreSQL `0A000 feature_not_supported`)

## 1.7.70 - 2026-03-12

### Added
- Add PhoenixKitGlobals component for JavaScript globals injection
- Add metadata JSONB field to comments schema (V82 migration)
- Add reply indicators to admin comments page
- Add test comments seed script for visual verification
- Add admin page generator category index pages with automatic route registration
- Add duplicate validation (ID, URL, label) to admin page generator
- Add compile-time warning for unresolved legacy admin LiveView modules
- Add `phoenix_kit_app_base/0` helper to Routes utility

### Fixed
- Fix dimension form inputs clearing each other on change
- Fix MarkdownEditor toolbar not working on LiveView navigation
- Fix CommentsComponent crash on post details page (`resource_id` → `resource_uuid`)
- Fix credo alias ordering in integration module
- Fix WebP transparency loss in center-crop image processing
- Fix 304 Not Modified support in FileController

### Changed
- Update admin page generator to use flat `admin_dashboard_tabs` config with `live_view` field
- Deprecate legacy `admin_dashboard_categories` config format (warning on use)
- Auto-infer LiveView modules from URL paths for legacy admin categories
- Add `attr :rest, :global` to `phoenix_kit_globals` component

## 1.7.69 - 2026-03-10
- Add responsive multi-column card grid to `table_default` component: 1 col on mobile, 2 cols on md, 3 cols on lg breakpoints
- Style card view cards with `bg-base-200` and `shadow-sm` to visually distinguish them from the page background

## 1.7.68 - 2026-03-10
- Merge upstream changes: publishing editor rework, AI translation, bulk group actions, V77/V78 migration fixes, scheduled jobs queue, Settings.Queries module, plugin migration callbacks

## 1.7.67 - 2026-03-10

### Breaking Changes (requires manual steps in parent app)
- V79 migration rewritten in-place: drops `phoenix_kit_mailing_*` tables, creates `phoenix_kit_newsletters_*`
- Oban queue renamed: `mailing_delivery` → `newsletters_delivery` (update `config/config.exs`)
- Settings keys changed: `mailing_enabled` → `newsletters_enabled`, `mailing_default_template` → `newsletters_default_template`, `mailing_rate_limit` → `newsletters_rate_limit`
- Email template category value changed: `"mailing"` → `"newsletters"` (existing templates need DB update)
- URL paths changed: `/admin/mailing/*` → `/admin/newsletters/*`, `/mailing/unsubscribe` → `/newsletters/unsubscribe`

### Changed
- Rename `PhoenixKit.Modules.Mailing` → `PhoenixKit.Modules.Newsletters` and all submodules
- Rename DB tables: `phoenix_kit_mailing_lists/list_members/broadcasts/deliveries` → `phoenix_kit_newsletters_*`
- Rename Elixir modules: `Mailing.List`, `Mailing.Broadcast`, `Mailing.Delivery`, `Mailing.ListMember`, `Mailing.Broadcaster`, `Mailing.Workers.DeliveryWorker` → `Newsletters.*`
- Rename web modules: `Mailing.Web.*` → `Newsletters.Web.*`
- Rename route module: `PhoenixKitWeb.Routes.MailingRoutes` → `NewslettersRoutes`
- Rename dashboard tabs: `:admin_mailing` → `:admin_newsletters`

## 1.7.66 - 2026-03-09
- Clean up publishing module: fix UUID routing bugs (slug vs UUID in version creation, PubSub broadcasts, translation status), remove dead code and filesystem path references
- Optimize publishing DB queries: batch loading, ListingCache for dashboard, bulk UPDATE for translation statuses, debounced PubSub updates
- Rework editor to two-column layout with content-first design (title + editor left, metadata right)
- Rework AI translation: integrate AI prompt system, modal UI replacing slidedown, translation progress recovery across page refreshes
- Replace primary language banner with compact tooltip on language switcher
- Add skeleton loading UI for language switching in publishing editor
- Fix collaborative editing: spectator initial sync, lock promotion JS updates, lock expiration timer
- Fix admin sidebar highlighting for publishing group pages
- Fix custom fields card hidden when no field definitions are registered
- Add bulk "Add to Group" action on posts index with dynamic group filter dropdown

## 1.7.65 - 2026-03-08
- Fix V77 migration crash: role_id column renamed to role_uuid in UUID migration

## 1.7.64 - 2026-03-08
- Remove legacy filesystem paths from publishing module — strip all `.phk` virtual path references from mapper, editor, listing, and preview
- Switch all event handlers and navigation from path-based to UUID-based routing
- Fix timestamp-mode posts returning 404: normalize post_time to zero seconds, with hour:minute-only fallback query for legacy data
- Add collision prevention for same-minute timestamp posts (auto-bump to next minute, max 60 attempts)
- Add unique_constraint on (group_uuid, post_date, post_time) to schema
- Render empty listing page instead of 404 when group exists but has no published posts
- Show Primary Language banner during new post creation
- Add missing PubSub handlers to publishing Index view (version_created, version_live_changed, version_deleted) with catch-all
- Fix primary language migration using removed path field — now uses UUID/slug directly
- Remove cache management UI from listing page (accessible via settings only)
- Add safety guards to URL builders: raise ArgumentError on nil UUID instead of producing broken URLs

## 1.7.63 - 2026-03-06
- Remove filesystem storage from publishing module — delete Storage, DualWrite, and all storage/* submodules (~7k lines removed)
- Add LanguageHelpers and SlugHelpers as standalone modules, simplify to DB-only throughout
- Fix slug conflict clearing bug: `clear_url_slugs_for_conflicts` passed wrong slug to DB cleanup
- Fix ngettext interpolation in primary language migration modal (literal `%{count}` in UI)
- Clean up stale filesystem references in comments, docs, and user-facing strings
- Fix V77/V78 migration crashes when UUID columns are missing (tables created after V56 ran)
- Simplify V77/V78 migrations — remove over-engineered column detection, rely on idempotent patterns
- Fix email tracking bug: `handle_delivery_result` used `get_log!` (raises) in a nil-matching branch; add `get_log/1` non-bang wrapper and remove unused public functions
- Add `migration_module/0` callback to plugin module system — `mix phoenix_kit.update` auto-discovers and runs plugin migrations
- Add `Settings.Queries` module for database operations
- Add dedicated queue and 1-day pruner for scheduled jobs cron worker
- Fix user dashboard navigation links
- Fix ueberauth providers configuration format in installer

## 1.7.62 - 2026-03-05
- Fix UnicodeConversionError crash in integration plug when response body contains non-UTF8 binary data
- Fix DB browser rendering of raw binary values (e.g. UUID bytes) in table and activity views
- Add V78 migration: backfill missing AI module columns skipped by V41 conditional checks
  - Add `reasoning_enabled`, `reasoning_effort`, `reasoning_max_tokens`, `reasoning_exclude` to `phoenix_kit_ai_endpoints`
  - Add `prompt_uuid`, `prompt_name` to `phoenix_kit_ai_requests` with index and FK constraint

## 1.7.61 - 2026-03-04
- Replace `plug_cowboy` with `bandit ~> 1.0` as HTTP adapter (Phoenix 1.8 default)
- Remove stale deps from lock: `cowboy`, `cowlib`, `cowboy_telemetry`, `plug_cowboy`, `combine`, `dns_cluster`, `phoenix_live_dashboard`, `poolboy`, `timex`, `tzdata`
- Remove deprecated `fetch_live_flash` plug
- Add audit_log query limits
- Fix atom table exhaustion risk and remove duplicate function
- Update excluded_apps list in route resolver to match current deps
- Update HTML comments to EEx format in templates and components
- Clean up stale dep spec and dead commented-out code

## 1.7.60 - 2026-03-03
- Remove legacy FS→DB migration modules: `DBImporter`, `MigrateToDatabaseWorker`, `ValidateMigrationWorker`
- Remove `JsIntegration` install/update module (JS setup is now manual)
- Remove all "Import to DB" / "Migrate to Database" UI buttons from publishing pages
- Remove DB import/migration PubSub broadcast functions and LiveView handlers
- Simplify publishing listing: drop `fs_post_count`, `needs_import`, `db_import_in_progress` assigns
- Move post title field into the editor content column with larger styling
- Simplify editor save button logic (always clickable unless readonly/autosaving)
- Add `enrich_with_db_uuids/2` to ListingCache for UUID-based admin links in filesystem mode
- Refine Sync module: migrate `connection_id` references to `connection_uuid`
- Update publishing README to reflect DB-only storage model

## 1.7.59 - 2026-03-03
- Fix V75: use CASCADE when dropping `phoenix_kit_id_seq` (meta table `phoenix_kit.id` DEFAULT depends on it)

## 1.7.58 - 2026-03-03
- Add V75 migration: fix uuid column defaults and cleanup
  - Set `DEFAULT uuid_generate_v7()` on 27 tables missing it (Category A tables — V72 rename dropped old sequence DEFAULT)
  - Fix 4 tables using `gen_random_uuid()` (UUIDv4) → `uuid_generate_v7()` (UUIDv7)
  - Drop orphaned `phoenix_kit_id_seq` sequence

## 1.7.57 - 2026-03-03
- Fix V74 migration: skip tables without bigint `id` (e.g. publishing tables created with UUID PKs)
- Fix V74: use `DROP COLUMN id CASCADE` to handle dependent FK constraints in one statement

## 1.7.56 - 2026-03-03
- Add V74 migration: drop integer `id`/`_id` columns, promote `uuid` to PK on all tables
  - Drop all FK constraints referencing integer `id` columns (dynamic discovery)
  - Drop ~95 integer FK columns across all tables (sourced from uuid_fk_columns.ex + extras)
  - Drop bigint `id` PK + promote `uuid` to PK on 47 Category B tables
  - After V74, every PhoenixKit table uses `uuid` as its primary key — no integer PKs remain
- Remove `source: :id` from `webhook_event.ex` schema (DB column now matches field name)

## 1.7.55 - 2026-03-03
- Fix scheduled_job.ex `source: :id` regression — PR #383 reintroduced mapping to dropped DB column
- Add V73 migration: pre-drop prerequisites for Category B UUID migration
  - SET NOT NULL on 7 uuid columns (`ai_endpoints`, `ai_prompts`, `consent_logs`, `payment_methods`, `role_permissions`, `subscription_types`, `sync_connections`)
  - CREATE UNIQUE INDEX on 3 tables (`consent_logs`, `payment_methods`, `subscription_types`)
  - ALTER INDEX RENAME on 4 indexes to match renamed columns (`post_tag_assignments`, `post_group_assignments`, `post_media`, `file_instances`)
- Add `RepoHelper.get_pk_column/1` — queries `pg_index` for PK column name, falls back to `"id"`
- Fix DB explorer to use dynamic PK column in `fetch_row`, `table_preview`, and notify trigger
- Fix Sync API controller to use dynamic PK column in `fetch_filtered_records` and `build_where_clause`
- Fix Sync connection notifier to use dynamic PK column in `insert_record` and `build_update_clause`
- Update 4 schema constraint names to match V72 column renames (`post_id` → `post_uuid`, `file_id` → `file_uuid`)
- Remove dead `:user_id` from OAuth `replace_all_except` list

## 1.7.54 - 2026-03-03
- Add V72 migration: rename PK column `id` → `uuid` on 30 Category A tables (metadata-only, instant)
- Add 4 missing FK constraints: `comments.user_uuid`, `comments_dislikes.user_uuid`, `comments_likes.user_uuid`, `scheduled_jobs.created_by_uuid`
- Remove `source: :id` mapping from 29 Category A Ecto schemas — DB column now matches field name directly

## 1.7.53 - 2026-03-02
- Add `mix phoenix_kit.doctor` diagnostic command — detects migration version vs `schema_migrations` discrepancies, stale COMMENT tags, and common DB issues
- Add `update_mode` to `mix phoenix_kit.update` — skips heavy DB components (Oban, cache warmers, settings queries) and caps Ecto pool at 2 during migrations to prevent DB saturation
- Run `ecto.migrate` in-process instead of `System.cmd` for better error reporting and reliability
- Fix three migration hang root causes: NULL UUIDs causing infinite backfill loop, orphaned FK references blocking constraint creation, varchar uuid columns crashing Ecto schema loader
- Fix migration hang: disable DDL transaction in generated migration wrapper — prevents entire multi-version migration from running in a single transaction holding AccessExclusiveLock
- Fix V50 migration hang: add `lock_timeout` for `phoenix_kit_buckets` ALTER TABLE and check column existence before ALTER
- Fix settings cache race: warm synchronously in `init/1` when `sync_init: true`; fix `warm_critical_data` inserting `{key, value, nil}` 3-tuples when TTL is nil
- Fix cache `sync_init` blocking supervisor for 60s when DB is overloaded
- Fix startup DB timeout: defer `Dashboard.Registry` init and reorder supervisor children
- Silence cache warmer spam and auto-grant warning when `role_permissions` table doesn't exist yet
- Fix `gen.migration` task: generate UUID primary keys and `user_uuid` FK instead of integer-based
- Fix broken GDPR anonymization: remove leftover `user_id: nil` from `update_all` calls
- Rename `_id` → `_uuid` across all remaining application code: billing, shop, storage, entities, sync, emails, tickets, permissions, roles, connections, publishing, and user_notifier
- Rename function names: `find_role_by_id` → `find_role_by_uuid`, `parse_id` → `parse_uuid`, `import_id` → `import_uuid`
- Fix Dialyzer warning: remove unreachable pattern match in cache warming
- Fix V56/V63 migration crash: `email_log_uuid` backfill fails with `datatype_mismatch` when `phoenix_kit_email_logs.uuid` is `character varying` instead of native `uuid` type
- Fix UUIDFKColumns: replace broken Elixir `rescue` with PostgreSQL `EXCEPTION` handler inside DO blocks — prevents outer transaction abort on backfill failure
- Add `::uuid` explicit cast in all UUIDFKColumns backfill SQL to handle varchar source columns gracefully
- Fix V56: add pre-step to convert varchar `uuid` columns on all FK source tables to native `uuid` type before `UUIDFKColumns.up` runs
- Fix V63: wrap `matched_email_log_uuid` backfill in DO block with EXCEPTION handler and `::uuid` cast
- Add V70 migration: re-backfills `email_log_uuid` and `matched_email_log_uuid` for installs where V56/V63 silently skipped the backfill; resets stale random UUIDs written by the V56 NULL-fill fallback
- Add investigation doc: `dev_docs/investigations/2026-03-01-varchar-uuid-migration-bug.md`

## 1.7.52 - 2026-02-28
- Add translatable `title` field to posts and fix timestamp-mode post handling
- Add V69 migration: make role table integer FK columns nullable
- Add `mix precommit` alias (`compile → format → credo --strict`) to `mix.exs`
- Update AGENTS.md with pre-commit instructions, replacing old minimal checklist
- Rename `Scope.user_id` → `Scope.user_uuid` for consistency
- Rename `user_id` → `user_uuid` across event handlers, templates, and messages
- Rename `user_id` → `user_uuid` in emails rate_limiter; `log_id` → `log_uuid` in emails interceptor, SQS processor, and sync task
- Rename `user_id` → `aws_user_id` in AWS credentials verifier
- Rename `resource_id` → `resource_uuid` in scheduled jobs
- Rename `_id` → `_uuid` in billing, shop, AI, entities, legal, posts, tickets, storage, scheduled jobs, and permissions
- Rename `_id` → `_uuid` across metadata, forms, helpers, and tests
- Replace `DateTime.utc_now()` with `UtilsDate.utc_now()` across codebase
- Remove redundant `connection_id` parameter from sync `connection_notifier`
- Fix crash bugs: `.user_id` struct access → `.user_uuid` in billing events and order_form
- Fix UUID field references for webhook_events and post images
- Fix duplicate map keys left from UUID migration in hooks and rate_limiter
- Fix alias ordering Credo violations across 18 files
- Fix timestamp-mode post lookups, migration ordering, and admin UI (PR #376 review follow-up)
- Fix `tab_callback_context` missing clause; demote double-wrap log to debug
- Add dialyzer ignore for unused `tab_callback_context` clause
- Update integration guide, making-pages-live guide, dashboard README, and usage-rules to use UUID terminology

## 1.7.51 - 2026-02-26
- Add V64 migration: fix login crash by replacing `user_id` check constraint with `user_uuid` on user tokens table
- Add V65 migration: rename `SubscriptionPlan` to `SubscriptionType` (table, columns, indexes, constraints)
- Rename `SubscriptionPlan` schema, context functions, events, routes, LiveViews, and workers to `SubscriptionType`
- Add orphaned media file cleanup system
  - `mix phoenix_kit.cleanup_orphaned_files` task with dry-run and `--delete` modes
  - `DeleteOrphanedFileJob` Oban worker with 60s delay and orphan re-check before deletion
  - Orphan filter toggle and "Delete all orphaned" button in Media admin UI
- Add Delete File button with confirmation modal to Media Detail page
- Add secondary language slug uniqueness validation via JSONB query in entity data
- Rename `seed_title_in_data` to `seed_translatable_fields` in entity data form
- Unify slug labels to "Slug (URL-friendly identifier)" across entity forms
- Standardize dev_docs file naming convention (`{date}-{kebab-case}-{type}.md`)
- Fix orphan detection crash: remove references to non-existent `phoenix_kit_shop_variants` table
- Fix `String.trim(nil)` crash in SQS workers when AWS credentials not configured
- Fix default preload `:plan` to `:subscription_type` in `list_subscriptions/1` and `list_user_subscriptions/2`
- Fix `auth.ex` storing integer `file.id` instead of `file.uuid` for avatar custom field
- Fix `create_subscription/2` dead code and key mismatch — now accepts `:subscription_type_uuid` as preferred key
- Fix `change_subscription_type/3` reading stale `subscription_type_id` instead of `subscription_type_uuid`
- Fix AWS Config returning empty string instead of nil when credentials unconfigured
- Fix email log `Access` behaviour error when called with `EmailLogData` struct
- Fix `Interceptor` using deprecated `log.id` instead of `log.uuid` in header and event
- Fix shop billing cascade: check `disable_system()` result and log on failure
- Replace `defp` proxy wrappers with `import` in 4 shop LiveViews (cart, catalog, checkout)
- Rename `post_id` to `post_uuid` in 5 private post functions
- Remove legacy integer ID function clauses from posts and billing modules
- Remove accidentally committed `.beam` files, add `*.beam` to `.gitignore`
- Remove empty legacy `subscription_plan_form.ex` and `subscription_plans.ex`
- Add doc notes about performance for `all_admin_tabs/0` and `get_config/0`
- Remove dead `_plugin_session_name` variable from integration routes

## 1.7.50 - 2026-02-25
- Fix `defp show_dev_notice?` CLAUDE.md violation: replace private helper with `<.dev_mailbox_notice>` Phoenix Component
  - New component at `lib/phoenix_kit_web/components/core/dev_notice.ex` with `message` and `class` attrs
  - Removed from `login.ex`, `registration.ex`, `magic_link.ex`, `forgot_password.ex`, `dashboard/settings.ex`
  - Updated all corresponding HEEX templates to use `<.dev_mailbox_notice>`
- Fix duplicate route alias compilation warnings in `phoenix_kit_authenticated_routes/1`
  - Split module-scope routes into `authenticated_live_routes/0` and `authenticated_live_locale_routes/0`
  - Locale variants now use `_locale` suffix (e.g. `:shop_user_orders_locale`)
- Fix undeclared `sidebar_after_shop` attr in `shop_layout/1` component
- Fix `maybe_redirect_authenticated/1` hardcoded `"/"` redirect — use `signed_in_path(socket)` consistently
- Fix double `Map.from_struct` in `Emails.Interceptor.create_email_log/2` — redundant call removed

## 1.7.49 - 2026-02-24
- Add V63 migration: UUID companion column safety net round 2
  - Add `uuid` identity column to `phoenix_kit_ai_accounts` (missed by V61 due to wrong table name)
  - Add `account_uuid` companion to `phoenix_kit_ai_requests` (backfilled from ai_accounts)
  - Add `matched_email_log_uuid` to `phoenix_kit_email_orphaned_events` (backfilled from email_logs)
  - Add `subscription_uuid` to `phoenix_kit_invoices` (backfilled from subscriptions)
  - Add `variant_uuid` to `phoenix_kit_shop_cart_items` (nullable, no variants table)
  - Update Invoice, AI Request, and CartItem schemas with new uuid companion fields

## 1.7.48 - 2026-02-24
- Add V62 migration: rename 35 UUID-typed FK columns from `_id` suffix to `_uuid` suffix
  - Enforces naming convention: `_id` = integer (legacy/deprecated), `_uuid` = UUID
  - Groups: Posts module (15 renames), Comments (4), Tickets (6), Storage (3), Publishing (3), Shop (3), Scheduled Jobs (1)
  - No data migration — columns already held correct UUID values, pure rename
  - All DB operations idempotent (IF EXISTS guards) — safe on installs with optional modules disabled
  - Update all Ecto schemas, context files, web files, and tests to use new field names

## 1.7.47 - 2026-02-24
- Fix V13 migration down/0 to use `remove_if_exists` instead of `remove` for idempotency
  - Fixes "column aws_message_id does not exist" error when rolling back V13

## 1.7.46 - 2026-02-24
- Add plugin module system with `PhoenixKit.Module` behaviour, `ModuleRegistry`, and zero-config auto-discovery
  - 5 required + 8 optional callbacks with sensible defaults via `use PhoenixKit.Module`
  - Auto-discovers external modules by scanning `.beam` files for `@phoenix_kit_module` attribute
  - All 21 internal modules now implement the behaviour, removing 786 lines of hardcoded tab enumeration
  - External module admin routes auto-generated at compile time from `admin_tabs` with `live_view` field
- Add live sidebar updates via PubSub when modules are enabled/disabled
- Add server-side authorization on module toggle events (prevents crafted WebSocket bypass)
- Add startup validation: duplicate module keys, permission key mismatches, duplicate tab IDs, missing permission fields
- Add compile-time warnings for route module and LiveView compilation failures
- Standardize AI, Billing, and Shop to use `update_boolean_setting_with_module/3` (consistent with all other modules)
- Fix billing→shop cascade: shop now disabled after billing toggle succeeds (prevents orphaned state)
- Fix `Tab.permission_granted?/2` to handle atom permission keys instead of silently bypassing checks
- Fix `static_children/0` to catch module `children/0` failures instead of crashing the supervisor

## 1.7.45 - 2026-02-23
- Fix auth forms mobile overflow on small screens (px-4 added to all form containers)
- Fix daisyUI v5 compliance: remove deprecated `input-bordered` from `<.input>` component and all auth templates
- Fix `<.header>` hardcoded `text-zinc-*` colors replaced with semantic `text-base-content` for dark theme support
- Convert forgot_password, reset_password, confirmation, confirmation_instructions to unified card layout
- Add missing `LayoutWrapper.app_layout` wrapper to confirmation form
- Fix V40 migration silently skipping V32-V39 tables due to Ecto command buffering
  - Root cause: `repo().query()` (immediate) couldn't see buffered table creation commands
  - V31's `flush()` was the last flush before V40, creating a clean V31/V32 split
  - Add `flush()` to V40 and V56 to prevent recurrence on new installations
- Add V61 migration: uuid column safety net for 6 tables missed by V40
  - Tables fixed: admin_notes, ai_requests, subscriptions, payment_provider_configs, webhook_events, sync_transfers
  - Also adds `created_by_uuid` FK column to phoenix_kit_scheduled_jobs

## 1.7.44 - 2026-02-23
- Add Publishing module: DB storage, public post rendering, and i18n support
- Add unified `admin_page_header` component, replace all per-page admin headers
- Add try/rescue to all form save handlers to prevent silent data loss on validation errors
- Add skeleton loading placeholders for entity language tab switching
- Add "Update Entity" submit button at top of entity form for quicker saves
- Add responsive card view to entities listing, remove stats/filters
- Memoize `IbanData.all_specs/0` with compile-time module attribute for performance
- Auto-register built-in comment resource handlers
- Make entity slug translatable and move it into Entity Information section
- Move multilang info alert above language tabs with improved explanation
- Tighten language tab spacing, replace daisyUI tab classes with compact utilities
- Remove hardcoded category column, filter, and bulk action from data navigator
- Fix CommentsComponent crash on post detail page
- Fix Entity update crash from DateTime microseconds in `:utc_datetime` fields
- Fix `email_templates` schema/migration mismatch breaking fresh installs
- Fix locale disappearing from admin URLs on sidebar navigation
- Fix badge component height on mobile devices
- Fix cached plan error spam during migrations with column type changes
- Fix CSS specificity debt and inline styles replaced with Tailwind classes
- Fix mobile responsiveness across admin panel
- Replace remaining `DateTime.utc_now()` with `UtilsDate.utc_now()` in all DB write contexts

## 1.7.43 - 2026-02-18
- Standardize all schemas to `:utc_datetime` and `DateTime.utc_now()` across 73 files
  - Replace `:utc_datetime_usec` with `:utc_datetime` and `NaiveDateTime` with `DateTime`
  - Add V58 migration to convert all timestamp columns across 68 tables from `timestamp` to `timestamptz`
  - Fix UUID FK backfill to handle NULL UUIDs before applying NOT NULL constraints
- Fix DateTime.utc_now() microsecond crashes in 19 files after `:utc_datetime` schema migration
  - Add `DateTime.truncate(:second)` to all `DateTime.utc_now()` calls in contexts
  - Affected: settings, billing, shop, emails, referrals, tickets, comments, auth, permissions, roles
- Fix Language struct Access error on admin modules page and all bracket-access-on-struct bugs
- Add 20 typed structs replacing plain maps across billing, entities, sync, emails, AI, and dashboard
  - Billing: CheckoutSession, SetupSession, WebhookEventData, PaymentMethodInfo, ChargeResult, RefundResult, ProviderInfo
  - Other: AIModel, FieldType, EmailLogData, LegalFramework, PageType, Group, TableSchema, ColumnInfo, SitemapFile, TimelineEvent, IbanData, SessionFingerprint
- Fix `register_groups` to convert plain maps to `Group` structs, preventing sidebar crashes
- Fix CastError in live sessions page by using UUID lookup instead of integer id
- Fix guest checkout flow: relax NOT NULL on legacy integer FK columns, fix transaction error double-wrapping
- Add return_to login redirect support for seamless post-login navigation (e.g., guest checkout)
- Add cart merge on login for guest checkout sessions
- Fix shop module .id to .uuid migration in Storage image lookups and import modules
- Fix hardcoded "PhoenixKit" fallback in admin header project title
- Fix admin sidebar submenu not opening on localized routes
- Fix 2 dialyzer warnings in checkout session and UUID migration
- Add multi-language support for Entities module
  - New `Multilang` module with pure-function helpers for multilang JSONB data
  - Language tabs in entity form, data form, and data view (adaptive compact mode for >5 languages)
  - Override-only storage for secondary languages with ghost-text placeholders
  - Lazy re-keying when global primary language changes (recomputes all secondary overrides)
  - Translation convenience API: `Entities.set_entity_translation/3`, `EntityData.set_translation/3`, `EntityData.set_title_translation/3`, and related get/remove functions
  - Multilang-aware category extraction in data navigator and entity data
  - Non-translatable fields (slug, status) separated into their own card
  - Required field indicators hidden on secondary language tabs
  - Title translations stored as `_title` in JSONB data column (unified with other field translations)
  - Slug generation disabled on secondary language tabs
  - Validation error messages wrapped in gettext for i18n
  - 124 pure function tests for Multilang, HtmlSanitizer, FieldTypes, FieldType
- Fix entities multilang review issues
  - Unify title storage in JSONB data column, fix rekey logic for primary language changes
  - Add `seed_title_in_data` for lazy backwards-compat migration on mount
  - Replace `String.to_existing_atom` with compile-time `@preserve_fields` map
  - Fix 7 remaining issues from PR #341 permissions review
  - Add catch-all fallback clauses to Scope functions to prevent FunctionClauseError
  - Sort `custom_keys/0` explicitly instead of relying on Erlang map ordering

## 1.7.42 - 2026-02-17
- Use PostgreSQL IF NOT EXISTS / IF EXISTS for UUID column operations
  - Replace manual column_exists? checks with native DDL guards in V56 and UUIDFKColumns
  - Makes migrations more robust and idempotent

## 1.7.41 - 2026-02-16
- Fix FK constraint creation crash when UUID target tables lack unique indexes
  - Ensure unique indexes on all FK-target uuid columns before adding FK constraints
  - Fixes `invalid_foreign_key` error on `phoenix_kit_ai_endpoints` and other tables

## 1.7.40 - 2026-02-16
- Remove redundant mb-4 wrapper div around back buttons in 4 admin pages
- Add V57 migration to repair missing UUID FK columns
- Update language filter to use languages_official instead of languages_spoken

## 1.7.39 - 2026-02-16
- Complete UUID migration (Pattern 2) across all remaining modules
  - Migrate posts, tickets, storage, comments, referrals, and connections schemas to UUID-based user references
  - Migrate posts like/dislike/mention functions to accept UUID user identifiers
  - Fix stale `.id` access across posts, storage, tickets, email, connections, and image downloader
  - Fix ProcessFileJob and media_detail to use user_uuid instead of deprecated user_id
  - Replace legacy `.id` access with `.uuid` across mix tasks and admin presence
  - Remove legacy integer fields from RoleAssignment schema
  - Fix 10 Dialyzer warnings across comments, connections, referrals, and shop modules
- Harden permissions system with security and correctness fixes
  - Fix security and correctness issues in permissions system
  - Add permission edit protection for own role and higher-authority roles
  - Add Owner protection to `can_edit_role_permissions/2` and standardize UUID usage
  - Fix edge cases, silent failures, and crash risks in permissions and roles
  - Fix dual-write in `set_permissions/3` and cross-view PubSub refresh
  - Fix permissions summary to count only visible keys
  - Fix multiple bugs in custom permission keys and admin routing
  - Add auto-grant of custom permission keys to Admin role
  - Add defensive input validation to custom permission key registration
  - Fix `unless/else` to `if/else` for Credo compliance
- Add gettext i18n to roles and permissions admin UI
- Add Level 1 test suite for permissions, roles, and scope (156 tests)
- Fix responsive header layout across all admin pages
  - Add responsive text classes (`text-2xl sm:text-4xl` / `text-base sm:text-lg`) to all page headers
  - Fix missed responsive text classes in storage, media selector, and publishing pages
- Replace dropdown action menus with inline buttons in table rows
- Fix require_module_access plug to check feature_enabled like LiveView on_mount
- Fix admin sidebar wipe when enabling/disabling modules
- Add `get_role_by_uuid/1` API and update integration guide
- Restore admin edit button in user dropdown and add product links in cart
- Fix selected_ids to use MapSet for O(1) lookups
- Fix Dialyzer CI failure for ExUnit.CaseTemplate test support files
- Fix Credo nesting and Dialyzer MapSet opaque type warnings
- Update Permissions Matrix page title and section labels

## 1.7.38 - 2026-02-15
- Fix Ecto.ChangeError in entities by using DateTime instead of NaiveDateTime
- Fix infinite recursion risk in category circular reference validation
- Add DateTime inconsistency audit report with phased migration plan
- Add custom permission key auto-registration for admin tabs
  - Custom admin tabs with non-built-in permission keys now auto-register with the permission system
  - Custom keys appear in the permission matrix and roles popup under "Custom" section
  - Owner role automatically gets access to custom permission keys
  - Custom LiveView permission enforcement via cached `:persistent_term` mapping
  - New API: `Permissions.register_custom_key/2`, `unregister_custom_key/1`, `custom_keys/0`, `clear_custom_keys/0`
  - Key validation: format check (`~r/^[a-z][a-z0-9_]*$/`), `ArgumentError` on built-in key collision

## 1.7.37 - 2026-02-15
- Fix UUID PR review issues: aliases, dashboard_assigns, and naming issues
- Fix V56 migration: add subscription_plans to uuid column setup lists
- Add admin edit buttons and improve shop catalog UX
- Add registry-driven admin navigation system
- Fix localized field validation in Shop forms
- And bunch of bugs and optimizations

## 1.7.36 - 2026-02-13
- Add storefront sidebar filters, category grid, and dashboard shop integration
  - New `CatalogSidebar` component: reusable sidebar with collapsible filter sections and category tree navigation
  - New `FilterHelpers` module: filter data loading, URL query string building, price/vendor/metadata filtering
  - Storefront filter configuration in admin settings: enable/disable filters, edit labels, add metadata option filters
  - Auto-discovery of filterable product metadata options (e.g., Size, Color) with one-click filter creation
  - Price range filter with min/max inputs and range display
  - Vendor and metadata option filters with checkbox selection and active count badges
  - Filter state persisted in URL query params for shareable filtered views
  - "Show Categories in Shop" setting: displays category card grid above products on main shop page
  - Sidebar category navigation always visible in sidebar (decoupled from grid setting)
  - Dashboard layout integration: shop filters and categories rendered in dashboard sidebar for authenticated users
  - `sidebar_after_shop` slot in dashboard layout for injecting custom sidebar content
  - Product detail page updated to use shared sidebar and filter context for consistent navigation
  - Mobile filter drawer with toggle button and active filter count badge
  - Category page filters scoped to category products
  - Fix `phx-value-value` collision on filter checkboxes: renamed to `phx-value-val` to avoid HTML checkbox `value="on"` overwrite
  - **Known issue**: metadata option filters (e.g., Size) may not filter correctly in all cases; needs further investigation
- Add file upload field type to Entities module
  - New `file` field type with configurable max entries, file size, and accepted formats
  - `FormBuilder` renders file upload UI with drag-and-drop zone (admin entity forms, placeholder)
  - New `:advanced` field category
- Fix 3 remaining UUID migration bugs in billing forms
- Fix 8 UUID migration bugs found in PR #330 post-merge review
- Add UUIDv7 migration V56 with dual-write support

## 1.7.35 - 2026-02-12
- Rewrite Sitemap module to sitemapindex architecture with per-module files
  - `/sitemap.xml` now returns a `<sitemapindex>` referencing per-module files at `/sitemaps/sitemap-{source}.xml`
  - Dual mode support: "Index mode" (per-module files, default) and "Flat mode" (single urlset when Router Discovery enabled)
  - New `Source` behaviour callbacks: `sitemap_filename/0` and `sub_sitemaps/1` for per-group file splitting
  - New `Generator.generate_all/1` and `generate_module/2` with auto-splitting at 50,000 URLs
  - FileStorage rewrite with `save_module/2`, `load_module/1`, `delete_module/1`, `list_module_files/0`
  - Cache rewrite supporting `{:module_xml, filename}` and `{:module_entries, source}` keys
  - Per-module stats stored as JSON in Settings with `get_module_stats/0`
  - Per-module regeneration via `SchedulerWorker.regenerate_module_now/1` (Oban)
  - Settings UI overhaul: per-module sitemap cards with stats, regeneration buttons, mode indicators
  - Publishing source: per-blog sub-sitemaps via `sitemap_publishing_split_by_group` setting
  - Entities source: per-entity-type sub-sitemaps
  - Static source: login page excluded, registration conditionally included
  - Router Discovery default changed to `false` (index mode is new default)
  - Removed "cards" XSL style; added `sitemap-index-minimal.xsl` and `sitemap-index-table.xsl`
  - Sitemap routes no longer go through `:browser` pipeline (public XML endpoints)
- Add PDF support for Storage module
  - New `PdfProcessor` module using `poppler-utils` (`pdftoppm`, `pdfinfo`)
  - First page rendered to JPEG thumbnail at configurable DPI
  - PDF metadata extraction (page count, title, author, creator, creation date)
  - `VariantGenerator` extended for document/PDF MIME types
  - Media UI: inline PDF viewer on detail page, PDF badges on thumbnails, metadata display
  - New system dependency checks for poppler in `Dependencies` module
- Fix option price display for options with all-zero modifiers
  - New `has_nonzero_modifiers?/1` filters out option groups where all price modifiers are zero
  - Price modifiers displayed as badges on option buttons (e.g., "+$5.00")
  - Cart saves all selected specs including non-price-affecting options (e.g., Color)
  - `build_cart_display_name/3` includes all selected specs in display name
- Fix category icons fallback to legacy product images
  - `Category.get_image_url/2` falls back to `featured_product.featured_image` (legacy URL)
  - Product detail respects `shop_category_icon_mode` setting for category subtab icons
  - Guard clauses tightened for Storage vs legacy URL handling
- Add ImportConfig filtering at CSV preview stage
  - Config filters applied during CSV analysis/preview, not just during import
  - Import wizard shows skipped product count with warning badge
  - Category creation uses language normalization for consistent JSONB slug keys
  - Imported option labels use `_option_slots` metadata for proper display names
- Fix admin sidebar full-page reload after upstream merge
  - Comments and Sync routes merged into main admin `live_session`
- Add runtime sitemaps directory to gitignore

## 1.7.34 - 2026-02-11
- Extract Comments into standalone reusable module (V55 migration)
  - New `PhoenixKit.Modules.Comments` context with polymorphic `resource_type` + `resource_id` associations
  - New tables: `phoenix_kit_comments`, `phoenix_kit_comments_likes`, `phoenix_kit_comments_dislikes`
  - Reusable `CommentsComponent` LiveComponent that can be embedded in any resource detail page
  - Threaded comments with configurable max depth and content length
  - Like/dislike system with atomic counter cache
  - Moderation admin UI at `{prefix}/admin/comments` with filters, search, and bulk actions
  - Module settings page at `{prefix}/admin/settings/comments`
  - Resource handler callback system for notifying parent modules (e.g., Posts) of comment changes
  - "comments" permission key added (25 total permission keys, 20 feature modules)
  - Posts module refactored to consume Comments module API instead of inline implementation
  - Legacy `phoenix_kit_post_comments` tables preserved for backward compatibility
- Add shop enhancements, sitemap sources, and admin navigation fix
  - Shop module improvements: product options toggle, import configs, drag-and-drop reordering, catalog language redirects
  - Sitemap module: shop source (categories, products, catalog), data source toggles in settings UI
  - Admin sidebar seamless navigation (consolidate live_sessions)
  - Migration fixes and V54 addition
- Fix preview-to-editor round-trip state and data loss bugs
  - Fix 8 bugs in the preview_token handle_params path that had diverged from the other editor entry points as features were added over time
  - Merge disk metadata into preview post to prevent silent data loss when saving after a preview round-trip
  - Add error logging to enrich_from_disk for observability
- Add module-level permission system for role-based admin access control
  - Custom roles can now be granted granular access to specific admin sections and feature modules. Permissions are managed through a new interactive matrix UI, enforced at both route and sidebar level, and update in real-time across all admin tabs via PubSub.

## 1.7.33 - 2026-02-04
- Add module-level permission system (V53 migration)
  - `phoenix_kit_role_permissions` table with allowlist model (row present = granted)
  - 24 permission keys: 5 core sections + 19 feature modules
  - Owner bypasses all checks; Admin seeded with all 24 keys by default
  - Custom roles start with no permissions, assigned via matrix UI or API
  - `PhoenixKit.Users.Permissions` context for granting, revoking, and querying role permissions
  - Interactive permission matrix at `{prefix}/admin/users/permissions`
  - Inline permission editor in Roles page with grant/revoke all
  - Route-level enforcement via `phoenix_kit_ensure_admin` and `phoenix_kit_ensure_module_access`
  - Sidebar nav gated per-user based on granted permissions
  - Real-time PubSub updates: permission changes reflect across all admin tabs
  - Backward compatible: pre-existing Admins retain full access before V53 migration
- Add PubSub events for real-time updates in Tickets and Shop modules
  - Tickets.Events module with broadcast for ticket lifecycle (created, updated, status changed, assigned, priority changed)
  - Comment and internal note events for ticket discussions
  - Shop.Events extension with product, category, inventory events
  - LiveViews subscribe to events for real-time UI updates
- Add User Deletion API with GDPR-compliant data handling
  - delete_user/2 with cascade delete for related data (tokens, OAuth, billing profiles, carts)
  - Anonymization strategy for orders, posts, comments, tickets, email logs, files
  - Protection: cannot delete self, cannot delete last Owner
  - Admin UI with delete button, confirmation modal, and real-time list updates
  - Broadcast :user_deleted event for multi-admin synchronization
- Fix compilation errors in auth.ex (pin operator with dynamic Ecto queries)
- Update core PhoenixKit schemas and Referrals to new UUID standard
- Update Shop module with localized slug support and unified image gallery
- Add PubSub events for Tickets and Shop modules, User Deletion API
- Added support for uuid to referral module
- Add markdown rendering and bucket access types
- Update Sync module to new UUID standard pattern
- Update billing module to use DB-generated UUIDs
- Update entities module to UUID standard matching AI module

## 1.7.32 - 2026-02-03
- Storage Module: Smart file serving with bucket access types (V50 migration)
  - Add `access_type` field to buckets: "public", "private", "signed"
  - Local files are now served directly without temp file copying (performance improvement)
  - Public cloud buckets redirect to CDN URL (faster, reduces server load)
  - Private cloud buckets proxy files through server (for ACL-protected storage)
  - Add retry logic for bucket cache race conditions during file access

  **⚠️ BREAKING CHANGE: Cloud Bucket Access Type**

  Cloud buckets (S3, B2, R2) now default to `access_type = "public"`, which redirects
  users directly to the bucket's public URL instead of proxying through the server.

  **If you have private/ACL-protected buckets:**
  - Go to Storage → Buckets → Edit your bucket
  - Set "Access Type" to "Private"
  - Files will be proxied through the server using credentials (previous behavior)

  **If you have public buckets (redirect mode):**

  For redirect to work, your bucket must be publicly accessible:

  1. **Enable Public Access** in your cloud provider settings:
     - AWS S3: Disable "Block all public access" and set bucket policy
     - Backblaze B2: Set bucket to "Public"
     - Cloudflare R2: Configure public access or use Custom Domain

  2. **Configure CORS** if serving files cross-origin (required when your site
     domain differs from bucket domain):

     AWS S3 / R2 CORS configuration example:
     ```json
     [
       {
         "AllowedHeaders": ["*"],
         "AllowedMethods": ["GET", "HEAD"],
         "AllowedOrigins": ["https://yourdomain.com"],
         "ExposeHeaders": ["ETag", "Content-Length"],
         "MaxAgeSeconds": 3600
       }
     ]
     ```

     Replace `https://yourdomain.com` with your actual domain, or use `"*"` for
     any origin (less secure but simpler for testing).

  See AWS documentation: https://docs.aws.amazon.com/AmazonS3/latest/userguide/enabling-cors-examples.html

## 1.7.31 - 2026-01-29
- Refactor publishing module into submodules and improve URL slug handling
  - Storage module refactoring:
    - Split storage.ex into specialized submodules: Paths, Languages, Slugs, Versions, Deletion, and Helpers for better organization and maintainability
    - Move controller logic into submodules: Fallback, Language, Listing, PostFetching, PostRendering, Routing, SlugResolution, Translations
    - Move editor logic into submodules: Collaborative, Forms, Helpers, Persistence, Preview, Translation, Versions
  - Listing page improvements:
    - Show live version's translations and statuses instead of latest version
    - Fetch languages from filesystem when version_languages cache is empty
    - Fix paths to point to live version files when clicking language buttons
    - Add "showing vN" badge that combines with version count display
    - Fix public URL to always use post's primary language
  - URL slug priority system:
    - Directory slugs now have priority over custom url_slugs
    - Prevent setting url_slug that conflicts with another post's directory name
    - Auto-clear conflicting url_slugs instead of blocking saves
    - Show info notice when url_slugs are auto-cleared due to conflicts
    - Clear conflicting url_slugs from ALL translations, not just current one
    - Clear conflicting custom url_slugs when new post is created

## 1.7.30 - 2026-01-28
- Posts Module
  - Add likes and dislikes system for post comments (V48 migration)
  - Post body field is no longer required
- User Management
  - Add dropdown field type support for user custom fields
- Shop Module (E-commerce)
  - Fix JSONB search queries and add defensive guards for robustness
  - Fix JSONB localized fields consistency across product/category operations
  - Add shop import enhancements with V49 migration
  - Fix image migration robustness and catalog display issues
  - Add language selection dropdown to CSV import for localized content
  - Add variant image mapping support for Shop products
  - Add legacy image support for backward-compatible variant mappings
- Bug Fixes
  - Fix UUID column error for auth tables during upgrade - Users upgrading from PhoenixKit < 1.7.0 no longer get "column uuid does not exist" error when logging in. Added auth tables (users, tokens, roles, role_assignments) to UUIDRepair module.

## 1.7.29 - 2026-01-26
- Add primary language improvements and AI translation progress tracking
  - Real-time translation progress - Added progress bars to editor and listing pages showing AI translation status
  - Primary language improvements - Posts now store their primary language for isolation from global setting changes
  - Language handling fixes - Fixed base code to dialect mapping (e.g., en → en-US) across public URLs and editor
  - UI polish - Updated language switcher colors, modal text, and added prominent primary language display in editor
  - Documentation - Added comprehensive README for the Languages module

## 1.7.28 - 2026-01-24
- Major improvements to the Publishing module's multi-language workflow: renamed "master" to "primary" terminology, fixed URL routing with locales, added language migration tools, improved cache performance, and fixed several UI/UX issues in settings and admin pages.
  - Multi-Language System Improvements
    - Rename master to primary terminology - Updated all references from "master language" to "primary language" for consistency and clarity
    - Fix language in URL breaking navigation - Resolved issues where locale prefixes in URLs caused routing problems
    - Isolate posts from global primary_language changes - Posts now store their own primary language, preventing drift when global settings change
    - Add "Translate to This Language" button - Quick translation action for non-primary languages in the editor
    - Sort languages in dropdowns - Consistent alphabetical sorting across all language selectors
  - Migration Tools
    - Add version structure migration UI - Visual indicators and migration buttons throughout the publishing module
    - Fix legacy post migration - Resolved "post not found" errors when migrating from legacy to versioned structure
    - Handle dual directory structures - Fixed migration when both publishing/ and blogging/ directories exist
    - Add primary language migration system - Tools to migrate posts to use isolated primary language settings
  - Performance
    - Improve listing performance - Read from cache when possible, reducing database/filesystem hits
    - Language caching with WebSocket transport - Faster language resolution with proper cache invalidation
    - Add Create Group shortcut - Quick access button on publishing overview page
  - Settings & Admin UI Fixes
    - Fix General settings content language glitch - Resolved weird UI behavior when changing content language
    - Fix settings tab highlighting - General and Languages tabs now properly highlight on child pages
    - Fix admin header dropdowns - Theme and language dropdowns in admin header now work correctly
    - Update Entities module description - Clearer description on the Modules page
- Updated the languages module added front and backend tabs for languages
- Add localized routes for Shop module
  - Add locale-prefixed routes (/:locale/shop/...) for multi-language Shop module support
  - Add language validation to only allow enabled languages in URLs
  - Add language preview switcher for admin product detail page


## 1.7.27 - 2026-01-19
- Changed / Added
  - Added prefix-aware navigation helpers and dynamic URL prefix support across dashboard, tabs, auth pages, and project home URLs, fixing issues when locale or prefix is nil.
  - Introduced comprehensive dashboard branding and theming:
    - Configurable branding, title suffix, and logo handling.
    - Shared theme controller with daisyUI integration, color scheme guide, and improved theme switcher placement.
  - Enhanced dashboard navigation:
    - Configurable subtab styling, redirects, highlights, and mobile subtab support.
    - Multiple context selectors with dependency support.
    - Reserved additional locale path segments for dashboard and users.
  - Added context-aware features:
    - Context-aware badges with update helpers, guards for nil contexts, and improved preservation during tab refresh.
    - Consistent context-aware merge behavior.
  - Improved authentication and user setup:
    - Added fetch_phoenix_kit_current_user to the auto-setup pipeline.
    - Fixed auth pages and titles to use centralized Settings/Config branding.
  - Performance and quality improvements:
    - Optimized Presence and Config modules to reduce repeated checks and lookups.
    - Added dashboard_assigns/1 helper to prevent unnecessary layout re-rendering.
    - Fixed hardcoded branding and paths to rely on configuration fallbacks.
  - Documentation updates:
    - Added guides for dashboard theming, tab path formats, subtab behavior, and context selectors.
    - Added prominent built-in features section and reduced overall documentation size.
- Maintenance:
  - Fixed Credo/Dialyzer issues, formatting problems, and test failures.
  - Cleaned up unused Dialyzer ignores and added ignores for test support files.

## 1.7.26 - 2026-01-18
- Language switcher fix

## 1.7.25 - 2026-01-16
- Bug fix - Added check for nil on language_swithcer on log-in page

## 1.7.24 - 2026-01-15
- Add Shop module with products, categories, cart, and checkout flow
- Add user billing profiles for reusable billing information
- Add payment options selection in checkout (bank transfer, card payment)
- Add user order pages with UUID-based URLs
- Add PubSub broadcasts to Billing module for real-time updates
- Add automatic default currency for orders
- Add Billing and Shop tabs to user dashboard tab system
- Add automatic dashboard tabs refresh when modules are enabled/disabled
- Fix user dashboard layout sidebar height calculation
- Fix OAuth avatar display in admin navigation

## 1.7.23 - 2026-01-14
- Added user functions, language switcher on login page (also support for Estonian and Russian on login)
- Removed logs spamming about oban jobs

## 1.7.22 - 2026-01-13
- Add AWS config module with centralized credential management
- Add context selector for multi-tenant dashboard navigation
- Add comprehensive user dashboard tab system with CLI generator
- Consolidate Publishing module into self-contained structure
- Publishing Module: Versioning, AI Translation, Per-Language URLs & Real-time Updates
- Fixed referralcodes to referrals for more universal code


## 1.7.21 - 2026-01-10
- Publishing Module: Versioning, AI Translation, Per-Language URLs & Real-time Updates
- Fixed referralcodes to referrals for more universal code
- Consolidate OAuth config through Config.UeberAuth abstraction

## 1.7.20 - 2026-01-09
- Fix user avatar fallback when Gravatar is unavailable
- Fixed issues with phx_kit install
- Add scheduled job cancellation when disabling modules
- Fix race condition in file controller for parallel requests

## 1.7.19 - 2026-01-07
We are doing code cleanup and refactoring to move forward with more new modules and more features:
- Moved referral_codes module to correct location lib/modules and fixed issue with install not working
- Standardize admin UI styling and add reusable components
- Move Emails module to lib/modules/emails with PhoenixKit.Modules.Emails namespace
- Migrate Entities, AI, and Blogging modules to lib/modules/ with PhoenixKit.Modules namespace
- Updated the javascript usage to not create userspace javascript files
- Move Sitemap and Billing modules to lib/modules/ with consolidated namespace
- Move DB and Sync modules to lib/modules/ with PhoenixKit.Modules namespace
- Moved posts module files to lib/modules folder
- Add DB Explorer module 

## 1.7.18 - 2026-01-03

- Blog Versioning, Caching System, and Complete Programmatic API
- Add Cookie Consent Widget (Legal Module Phase 2)
- Add Legal module improvements and cookie consent enhancements

