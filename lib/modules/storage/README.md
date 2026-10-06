# PhoenixKit Storage System Specification

**Version:** 1.0
**Created:** 2025-10-28
**Status:** Planning Phase

## Overview

Comprehensive distributed file storage system for PhoenixKit with multi-location redundancy, automatic variant generation, smart volume selection, and secure URL serving.

---

## Architecture

### Database Schema (5 Tables with UUIDv7)

#### 1. phoenix_kit_buckets
Storage provider configurations (local disk, AWS S3, Backblaze B2, Cloudflare R2, Tigris)

```elixir
- id (uuid_v7, PK)
- name (string, required) - Display name
- provider (string, required) - "local", "s3", "b2", "r2", "tigris"
- region (string, nullable) - AWS region or equivalent
- endpoint (string, nullable) - Custom S3-compatible endpoint: a bare host (`s3.us-west-002.backblazeb2.com`), host:port, or a full URL (`http://minio.local:9000`); read in one place (`S3.endpoint/1`) for both requests and public URLs
- access_type (string, default "public") - How a remote bucket serves files: "public" (redirect to the object URL, or cdn_url), "private" (proxied through the app), "signed" (redirect to a presigned URL made for the request, 5 minutes)
- bucket_name (string, nullable) - S3 bucket name
- integration_uuid (uuid, nullable, no FK) - Where the keys come from: an `object_storage` PhoenixKit.Integrations connection (Settings → Integrations). The bucket form only offers this. Mutually exclusive with access_key_id/secret_access_key
- access_key_id (string, nullable) - LEGACY: a key saved on the bucket itself, not a secret — not encrypted
- secret_access_key (string, nullable) - LEGACY: encrypted at rest
- cdn_url (string, nullable) - CDN endpoint for file serving
- path_prefix (string, nullable) - Base path for files
- enabled (boolean, default: true)
- priority (integer, default: 0) - legacy: only the pre-profile selection and the read fallback order use it; a storage profile's per-bucket `write_priority` decides uploads (0 = random, >0 = specific priority)
- max_size_mb (integer, nullable) - Maximum storage capacity
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_buckets_enabled` on `enabled`
- `idx_buckets_provider` on `provider`

---

#### 2. phoenix_kit_files
Original file uploads with metadata

```elixir
- id (uuid_v7, PK)
- original_file_name (string, required) - User's original filename
- file_name (string, required) - System filename (uuid_v7-original.ext)
- mime_type (string, required) - image/jpeg, video/mp4, etc.
- file_type (string, required) - "image", "video", "document", "archive"
- ext (string, required) - jpg, mp4, pdf, etc.
- checksum (string, required) - MD5 or SHA256 hash
- size (integer, required) - File size in bytes
- width (integer, nullable) - Image/video width in pixels
- height (integer, nullable) - Image/video height in pixels
- duration (integer, nullable) - Video duration in seconds
- status (string, required) - "processing", "active", "failed"
- metadata (jsonb, nullable) - EXIF, codec info, etc.
- data (jsonb, default {}) - title / alt / description per language (V199)
- taken_at (timestamptz, nullable) - when the photo/video was taken, UTC (V200)
- taken_on (date, nullable) - the LOCAL date it was taken; what a library groups by (V200)
- taken_at_offset (integer, nullable) - seconds east of UTC, when known (V200)
- taken_at_source (string, nullable) - manual / exif / container / filename / inserted_at (V200)
- user_uuid (uuid_v7, FK -> phoenix_kit_users.uuid)
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_files_user_uuid` on `user_uuid`
- `idx_files_file_type` on `file_type`
- `idx_files_status` on `status`
- `idx_files_inserted_at` on `inserted_at`
- `phoenix_kit_files_capture_date_index` on `(user_uuid, taken_on DESC, taken_at DESC)`,
  partial over a user's visible, processed images and videos (V200)

**Foreign Keys:**
- `user_uuid` references `phoenix_kit_users(uuid)` ON DELETE CASCADE

---

#### 3. phoenix_kit_file_instances
File variants (thumbnails, resizes, video qualities)

```elixir
- id (uuid_v7, PK)
- variant_name (string, required) - "original", "thumbnail", "medium", "large", "720p", "1080p"
- file_name (string, required) - System filename (uuid_v7-variant.ext)
- mime_type (string, required)
- ext (string, required)
- checksum (string, required)
- size (integer, required) - Variant file size in bytes
- width (integer, nullable)
- height (integer, nullable)
- processing_status (string, required) - "pending", "processing", "completed", "failed"
- file_uuid (uuid_v7, FK -> phoenix_kit_files.uuid)
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_file_instances_file_uuid` on `file_uuid`
- `idx_file_instances_variant_name` on `variant_name`
- `idx_file_instances_processing_status` on `processing_status`

**Foreign Keys:**
- `file_uuid` references `phoenix_kit_files(uuid)` ON DELETE CASCADE

**Unique Constraint:**
- `unique_file_variant` on `(file_uuid, variant_name)`

---

#### 4. phoenix_kit_file_locations
Physical storage locations (redundancy tracking)

```elixir
- id (uuid_v7, PK)
- path (string, required) - Full path within bucket
- status (string, required) - "active", "syncing", "failed", "deleted"
- priority (integer, default: 0) - Location priority for retrieval
- last_verified_at (timestamp, nullable) - Last health check
- file_instance_uuid (uuid_v7, FK -> phoenix_kit_file_instances.uuid)
- bucket_uuid (uuid_v7, FK -> phoenix_kit_buckets.uuid)
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_file_locations_file_instance_uuid` on `file_instance_uuid`
- `idx_file_locations_bucket_uuid` on `bucket_uuid`
- `idx_file_locations_status` on `status`

**Foreign Keys:**
- `file_instance_uuid` references `phoenix_kit_file_instances(uuid)` ON DELETE CASCADE
- `bucket_uuid` references `phoenix_kit_buckets(uuid)` ON DELETE CASCADE

---

#### 5. phoenix_kit_storage_dimensions
Admin-configurable dimension presets for variant generation

```elixir
- id (uuid_v7, PK)
- name (string, required) - "thumbnail", "medium", "large", "720p", "1080p"
- width (integer, nullable) - Target width in pixels
- height (integer, nullable) - Target height in pixels
- quality (integer, default: 85) - Compression quality 1-100
- format (string, nullable) - "jpg", "webp", "png", null = keep original
- applies_to (string, required) - "image", "video", "both"
- enabled (boolean, default: true)
- order (integer, default: 0) - Display order in admin
- inserted_at (timestamp)
- updated_at (timestamp)
```

**Indexes:**
- `idx_dimensions_enabled` on `enabled`
- `idx_dimensions_order` on `order`

**Unique Constraint:**
- `unique_dimension_name` on `name`

**Default Seeded Dimensions (8 total):**

The V18 migration will seed the following default dimensions:

```elixir
# Image Dimensions (4)
%{
  name: "thumbnail",
  width: 150,
  height: 150,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 1
}

%{
  name: "small",
  width: 300,
  height: 300,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 2
}

%{
  name: "medium",
  width: 800,
  height: 600,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 3
}

%{
  name: "large",
  width: 1920,
  height: 1080,
  quality: 85,
  format: "jpg",
  applies_to: "image",
  enabled: true,
  order: 4
}

# Video Quality Dimensions (3)
%{
  name: "360p",
  width: 640,
  height: 360,
  quality: 28,  # CRF value for FFmpeg video encoding
  format: "mp4",
  applies_to: "video",
  enabled: true,
  order: 5
}

%{
  name: "720p",
  width: 1280,
  height: 720,
  quality: 28,
  format: "mp4",
  applies_to: "video",
  enabled: true,
  order: 6
}

%{
  name: "1080p",
  width: 1920,
  height: 1080,
  quality: 28,
  format: "mp4",
  applies_to: "video",
  enabled: true,
  order: 7
}

# Video Thumbnail (1)
%{
  name: "video_thumbnail",
  width: 640,
  height: 360,
  quality: 85,
  format: "jpg",
  applies_to: "video",
  enabled: true,
  order: 8
}
```

**Default Seeded Bucket:**

The V18 migration will seed one default local storage bucket:

```elixir
%{
  name: "Local Storage",
  provider: "local",
  region: nil,
  endpoint: nil,
  bucket_name: nil,
  access_key_id: nil,
  secret_access_key: nil,
  cdn_url: nil,
  path_prefix: nil,  # Uses storage_default_path setting from existing system
  enabled: true,
  priority: 0,       # Legacy; uploads follow the storage profile's upload order
  max_size_mb: nil   # Unlimited (will use all available disk space)
}
```

**Default Seeded Settings:**

The V18 migration will add 3 new settings:

```elixir
%{key: "storage_redundancy_copies", value: "1"}           # Store files on 2 buckets
%{key: "storage_auto_generate_variants", value: "true"}  # Auto-generate thumbnails/resizes
%{key: "storage_default_bucket_uuid", value: nil}        # Never read by bucket selection; no longer shown (2.40.1)
```

---

## File Type Support

| Type | Extensions | Scalable? | Variants Generated | Processing |
|------|-----------|-----------|-------------------|------------|
| **Image** | jpg, jpeg, png, webp, gif, heic | ✅ Yes | All enabled image dimensions | Mogrify/Vips |
| **Video** | mp4, webm, mov, avi, mkv | ✅ Yes | Quality variants + thumbnail | FFmpeg |
| **Document** | pdf, doc, docx, txt, md | ❌ No | Original only | Metadata extraction |
| **Archive** | zip, rar, 7z, tar, gz | ❌ No | Original only | None |

---

## Storage Logic

### Directory Structure
All instances stored **next to original** in same directory:

```
/bucket/path/
  018e3c4a-9f6b-7890-original.jpg
  018e3c4a-9f6b-7890-thumbnail.jpg
  018e3c4a-9f6b-7890-medium.jpg
  018e3c4a-9f6b-7890-large.jpg
```

### Storage profiles: where a library's bytes live (V205)

A library points at a **storage profile** (`Storage.Profiles`); a library
with none uses the **Default**, seeded by V205 from the buckets and
`storage_redundancy_copies` under a fixed uuid, so an install that never
touches profiles behaves as before. A profile has:

- `copies_local` / `copies_cloud` (0..5 each, 1..5 in all): how many copies of
  every file go to **local** buckets (the server's disks) and to **cloud** buckets
  (S3, B2, R2, Tigris) — two on disk and one in the cloud survives the server.
  An original and what is made from it (a size, a tile, a render) get the same.
  A kind the profile wants no copy of is not written, whatever buckets it has.
  `copies_originals` is the **total** (a CHECK keeps it `copies_local +
  copies_cloud`; `min_copies_on_write` is bounded by it) and `copies_variants`
  is not used; `StorageProfile.changeset/2` keeps both equal to the total (V209).
  The editor enables Cloud copies when a writable cloud bucket is present, or
  when an existing cloud count needs to be lowered after a bucket is removed;
  `Profiles.split_copies/2` splits a count that knows no kinds (the old
  redundancy setting) local first, as V209 did for existing profiles;
- `min_copies_on_write`: an original upload fails (and what was written is
  removed) unless this many copies succeed; the rest are made later;
- per bucket (`ProfileBucket`): a `role` (`primary` is written and served,
  `replica` is served when no primary has the copy, `backup` is written but
  never served), a fixed `write_priority` (nil is the shuffled pool), a `serve_order`, and a
  `status` (`active`; `read_only` serves but gets no new files; `draining`
  has its files moved to the profile's other buckets). A bucket holds
  everything the profile sends it, an original and what is made from it: there
  is no `stores` choice (V205's column stays in the table, and nothing reads or
  writes it).

**A bucket a profile lists is protected.** `Storage.delete_bucket/2` and
`Storage.update_bucket/3` (disabling) refuse it with
`{:error, {:in_use, usage}}` while any profile has a row for it, whatever the
row's role or status, and a user's own profile counts; nothing is taken out of
a profile on the way (the delete used to strip an empty bucket from every
profile, which could leave a library with nowhere to write). The bucket-row FK
is `RESTRICT`, so a row added in between is refused by the database too. The
admin frees the bucket first (Storage profiles tab: `draining` to move its
files, then remove it), and only then disables or deletes it. Enabling is
always allowed, and a user's own bucket is not guarded on disable (it goes with
its library). `Profiles.bucket_usage/1` says which profiles use which buckets
and how many libraries stand behind each (the Buckets tab's "Used by" column);
`Profiles.delete_profile/2` refuses a profile a library uses, and
`Profiles.library_names_using/1` names the site libraries in the way (a user's
library is counted, never named).

**Writes** (`Manager.store_file/2` with `:profile` and `:kind`, reached
through `Storage.store_by_profile/4`): the profile's buckets that are
enabled, `active` and under their `max_size_mb`, primaries before replicas
before backups, fixed write priority before the pool. Local and cloud buckets
are selected separately, up to each kind's copy count; a bucket whose write
fails is replaced by the next one of its kind. A file records the profile and
revision that placed it
(`placed_profile_uuid` / `placed_revision`; NULL is the Default at revision
1); fewer copies than wanted leave it stale (revision 0). An original with
fewer than `min_copies_on_write` copies fails, and what it wrote is removed
(`Storage.undo_store/3`, under the key's directory lock, and only when no
row names the key and no other upload into its directory is in flight:
keys are content-addressed).

**Serving** (`Locations.ranked/2`): a key's recorded buckets in the
**served file's own** profile order (`file_uuid:` on `get_file_access/2`
and `public_url/2`; a key shared with a cross-user copy in another library
is not ranked by that library's profile) — primaries, then replicas, then a
bucket the profile no longer lists, each by `serve_order`. A backup is
never served, and never probed as a fallback for that file either;
processing may read it last. A bucket's `enabled` flag stays the emergency stop:
a disabled bucket is neither written nor read, whatever its profile says.

Every bucket joins the Default when it is created, with no fixed write
priority (the shuffled pool). The **upload order** (`write_priority`) is set per
bucket in each profile, on Settings → Media → Storage profiles, and only
matters where a kind of bucket has more writable buckets than copies to make
(`Profiles.copies_advice/1`'s `order_matters`); the admin hides it elsewhere. A
bucket's own `priority` column is legacy: it is neither shown in the admin nor
copied into a profile. Nothing picks "the emptiest bucket": placement does not
know free space yet, so an empty upload order means a random turn. `Storage.redundancy_copies/0` and
`set_redundancy_copies/1` are the old setting, now the Default's copy count
(the setting row is kept in step). Profiles are edited on Settings → Media →
Storage profiles; a system library names its profile (and variant set) when it is
created (Libraries tab → New library) and keeps them: the admin shows them
read-only on the library's page, and moving where its files live is done by
changing the profile's buckets, which moves every library on it. The context
functions (`Profiles.set_library_profile/3`, `VariantSets.set_library_variant_set/3`)
still exist for code and for user libraries' own size choice.

### The library page

Settings → Media → Libraries lists the site's libraries in short rows (name,
files, size, storage as text, sync) and creates them; a library's name opens
`/admin/settings/media/libraries/:id` (`Live.Modules.Storage.LibraryPage`), the
way a bucket's name opens its page. The page shows the overview and address,
what it holds (files, folders, size, and `Storage.library_bucket_totals/1`:
where its objects are, per bucket), its storage profile and variant set
**read-only**, the sync state with Check now / Pause / Resume
(`LibrarySync`), the annotated-thumbnail choice, its history, and renames or
deletes it (an empty, non-default library only). Only a live **system** library
opens there; a user's library does not.

The **profile and variant set are chosen once**, in the New library form
(`Libraries.create_system_library/2` takes `storage_profile_uuid` and
`variant_set_uuid`; blank or the Default's uuid is stored as nil, and a user's
profile or an unknown one is refused), and the form offers them only when there
is more than the Default of each. The admin has no control to change them
afterwards: re-pointing a library at another profile is a bulk move of its
files. Change a profile's buckets instead (they move every library on it).
Switching a library's annotated-thumbnail choice does not regenerate existing
thumbnails.

### Variant sets: which sizes a library gets (V205)

**In the admin these are "renditions"** (a rendition is a smaller or
re-encoded copy of an upload, such as a thumbnail or a 720p video) and
"rendition sets"; the code keeps `variant` and `dimension`. They are the
**Renditions tab** of Settings → Media (`RenditionsComponent`, one tab per set,
`?tab=renditions&set=<uuid>`); adding or editing one is its own page
(`/admin/settings/media/renditions/new/image|video`, `/:id/edit`,
`DimensionForm`). Health is a tab too (`HealthComponent`, read when the tab
opens). `/admin/settings/media/dimensions` and `/health` only redirect to their
tabs.

A library points at a **variant set** (`Storage.VariantSets`; none is the
Default, seeded with every size the install had). A set's sizes are its
`phoenix_kit_storage_dimensions` rows, and size names are unique per set.
Every set has the **standard sizes** `thumbnail`, `small`, `medium`,
`large` and `video_thumbnail`: they cannot be deleted or renamed, and
`small`/`medium`/`large` keep the aspect ratio. `generate_variants` is the
set's (the Default's is what `storage_auto_generate_variants` was).

**Deep zoom (zoomable tiles) belongs to the library**, not the set: the
`deep_zoom` library setting (`Libraries.setting(library, :deep_zoom)`, a switch
on the library page). A library that has not chosen follows its set's old
`generate_tiles` flag (`VariantSets.deep_zoom_for_library?/1`,
`tiles_among/1`), which the admin no longer shows, so nothing changed when the
switch moved. Tiles are cut on the first request; turning deep zoom off only
stops serving them, and the ones made stay stored.

- A generated variant records the `spec_hash` of the size that made it; a
  file records the set and revision its variants were made by.
- A missing image size that is being made is served as the nearest smaller
  size the file has, then a placeholder — never a full original larger than
  the size (G17). Neither is cached, a private file's either. A size that
  will not be made (the set makes none, the size is disabled or for the
  other kind of file) serves the original, as before.
- A thumbnail with an annotation burned into it has no `spec_hash` (V205
  did not stamp one), so nothing ever makes over it.
- `Storage.variant_for(file, min_width: 300, aspect: :preserve)` picks a
  size by purpose, against the file's set.
- Sets are edited on Settings → Media → Renditions; a user library may
  pick a set an admin marked `selectable`.

- **A see-through image keeps its transparency.** A size configured as
  JPEG is written as `config :phoenix_kit, :variant_alpha_format` (default
  `"png"`; `"webp"`, `"avif"` and `"gif"` also accepted) when the original has an alpha
  channel. Only nil/`jpg`/`jpeg` sizes are redirected; a size set to webp or
  png keeps its own format.
- **Regenerating after an upgrade is manual, on purpose.** When a release
  changes how sizes are rendered, `Storage.VariantSets.remake_all/0` bumps
  every set's revision; the reconciler then remakes each file's sizes in the
  background, a batch at a time. Nothing triggers it automatically — on a
  large library it is real work, so the operator chooses when.

### The reconciler (V205)

`Storage.Reconciler`, run as a **job run per library** (`Storage.Jobs.Reconcile`,
`storage.reconcile`: 10 files a batch, 2 s apart, one file at a time under a
session advisory lock), makes every **stale** file match its library's profile
and set. `Workers.ReconcileJob` is the Oban job every change to storage
settings still queues; it starts those runs (`Reconcile.trigger/1`) for the
libraries that have files to bring up to date, so it works inside a
transaction. Each library's state — **Up to date**, **Syncing**, **Paused**,
**Waiting** (files out of date and no run) or **Needs attention** — is derived
by `Storage.LibraryState` and shown on Settings → Media → Libraries with
**Check now**, **Pause** and **Resume**; "out of date" is
`Reconciler.out_of_date_query/1`, the work-selection query `stale_query/1` its
subset. The location and checksum backfills and the library purge are runs too
(`storage.location_backfill`, `storage.checksum_backfill`,
`storage.purge_library` — the purge is visible but cannot be paused or cancelled).

### History

Every change to the site's storage configuration (buckets, profiles and their
bucket rows, libraries and their profile / variant set / annotated-thumbnail
choice, variant sets and sizes) is written to the Activity log by
`Storage.Audit` — who, when, and what changed from → to — permanently, never
naming a key or secret, and never for a user's own library, profile or bucket.
The context functions take `actor_uuid:` (the LiveViews pass
`PhoenixKitWeb.Actor.opts(socket)`). Settings → Media → **History** lists these
with the storage job runs' entries and the existing permanent `setting.changed`
entries for global `storage_*` settings. The list identifies the resource and
shows the actor and changed values; full Activity links require `dashboard`.

Audited context mutations lock and reload the current resource, and commit the
configuration and audit entry together through `Audit.transaction/1`. A failed
audit insert rolls the mutation back. Announcements and compatibility-setting
sync run after the transaction owned by Audit commits. For a transaction opened
by a caller, storage audit announcements are suppressed (Ecto has no after-commit
hook); History refreshes every 30 seconds while visible. Call
`Audit.transaction/1` at the outer boundary for immediate announcements. Cache
and compatibility-setting callbacks are best effort; inside caller-owned repo
transactions they retain their existing immediate behavior.

### Reconcile behavior

A file is stale when
its placement stamp differs from its profile, or — for an active file only
— its variant stamp differs from its set; trashed and unfinished files keep
their size stamp until they are active again.

- **Copies:** each checked, completed instance gets local and cloud copies
  separately, up to each kind's count, capped at buckets that hold one or can
  take one. Each copy is made, checked with `Manager.holds?/2` and recorded under
  the key's directory lock. A file whose only copies are on backups gets one
  on a primary or replica of a kind with copies wanted. If its remaining
  serving buckets belong to a zero-count kind, it stays stale until the profile
  changes, even when those buckets are read-only or full; the fallback never
  writes that kind or deletes the last serving copy.
- **Unlinks:** a copy on a bucket the profile no longer uses for it
  (draining, taken out, or a kind with zero copies wanted) goes only after both
  kinds' remaining copies are checked to be really there, never the last one.
  The object leaves that bucket only when no other active location there names the
  key, no instance under it is unchecked, and no upload into its directory
  is in flight (`Storage.unlink_location/2`, G11).
- **Sizes:** missing ones are made, ones with another `spec_hash` remade (a
  key shared with a cross-user copy is remade under a key of its own),
  ones the set dropped deleted; a disabled size, and an instance with no
  spec hash in a size slot (a burned thumbnail), are kept.
- A file is stamped only with what it now matches, and only while nothing
  marked it stale meanwhile. One that cannot be finished waits ten minutes
  (`reconcile_attempted_at`); a file stuck in `processing` for an hour, or
  `failed`, is placed like any other.
- Queued by every revision bump (a profile's copies or a bucket row's
  status or role — not serve order, write priority or storage
  class; a set's flags or sizes), a library moving, an incomplete upload, a
  restore, the daily prune and boot; a queued pass restarts from the
  beginning. The Health tab lists what is waiting and can queue a pass.

---

### Where a file is (V204)

A file's bytes are where its `phoenix_kit_file_locations` rows say: one row
per instance per bucket that holds the object (unique on the pair), keyed by
the object key (`path`). `Storage.Locations` is the lookup.

- **Reads, serving, `file_exists?`, `public_url`** try the buckets the rows
  name first (local, then by priority), then the other enabled buckets. A
  bucket found to hold the key that way is recorded. A bucket that raises
  counts as "not here", and the next is tried.
- **Every writer records its locations** once its instance row exists
  (uploads, variants, tiles, comment attachments, image edits, clones), and
  marks the instance checked. Variants and tiles are placed by the
  library's storage profile as derived files (V205); an edit render goes
  exactly where the key it replaces is (`force_bucket_ids`).
- **Checks** (`phoenix_kit_file_location_checks`): that an instance was
  checked against every bucket, and how many held it. The
  `LocationBackfillJob` walks the unchecked ones (queued after boot and by
  the daily prune, 50 every 5 s), records every copy, and remembers a miss so
  a missing object is not probed on every request. Health shows how many
  are left. A read's fallback record is not a check.
- **A bucket that still holds files cannot be deleted** (the location FK is
  `RESTRICT`); disable it instead. Bucket edits apply at once (the manager's
  bucket cache is cleared on every change).
- **Deletes**: deleting a file removes a key no instance references from
  every enabled bucket; the reconciler's unlinks are per bucket (V205, see
  above).
- `Storage.list_files(bucket_uuid: uuid)` lists the files with a copy there.

### Trash and restore

- A trashed file keeps its bytes and its placement; its sizes are checked
  again when it is restored.
- Restoring a file whose folder is trashed too brings it back into the
  nearest folder that is still there, or the root (2.41.0, #876).
- In the media browser, Restore is on the file menu, the row menu, the
  folder menu and the bulk bar, and dragging a trashed file into a folder
  restores it there. A folder holds a file once, as its home or through a
  link, so a move no longer leaves a file in two folders.

## URL Structure & Security

### URL Format
```
https://site.com/file/{uuid_v7}/{instance_name}/{token}
```

### Example
```
https://site.com/file/018e3c4a-9f6b-7890-abcd-ef1234567890/medium/a3f2
```

### Token Generation
```elixir
# Token = first 4 chars of MD5(file_id:instance_name + secret_key_base)
data = "#{file_id}:#{instance_name}"
secret = Application.get_env(:phoenix_kit, :secret_key_base)
token = :crypto.hash(:md5, data <> secret)
        |> Base.encode16(case: :lower)
        |> String.slice(0..3)
```

### Security Benefits
- ✅ Prevents file enumeration (can't guess URLs)
- ✅ Each instance has unique token
- ✅ Token changes if secret changes
- ✅ Secure comparison prevents timing attacks
- ✅ No user-guessable patterns

### Versions and caching

A file URL may carry `?v=` — the first 16 hex characters of the served
instance's checksum (`URLSigner.signed_url(uuid, variant, version: instance)`,
`URLSigner.version/1`). Build URLs with it wherever the instance is at hand.

| Request | Response |
|---|---|
| `v` names the bytes the variant holds now (any hex prefix of 8+ characters) | `public, max-age=31536000, immutable` |
| `v` names other bytes | `302` to the current `v`, `no-store` |
| no `v`, file never edited | `public, max-age=86400` + ETag |
| no `v`, file edited before | `public, no-cache` + ETag (revalidated on every use) |
| variant not generated yet (a smaller size, a placeholder, or — for a size that will not be made — the original stands in) | `no-store`, `x-variant-status: pending` |
| an image edit is rendering, or failed | a grey SVG placeholder, `no-store` (also `cdn-cache-control`), `x-variant-status: editing` / `edit-failed` |
| a system-managed file (tile chunk, an edited image's unedited original) | `404` |

Deep-zoom tiles carry the version in the path, because the viewer derives
tile URLs from the manifest's path and drops its query:
`/tiles/<token>/<uuid>-<v>.dzi` and `/tiles/<token>/<uuid>-<v>_files/<level>/<col>_<row>.<ext>`,
stored under `_tiles/<uuid>/<v>/`. A version that is not the current one is
a 404. The legacy `/tiles/<token>/<uuid>.dzi` resolves to the current version
and is never cached.

### Checking a file URL you were handed

`URLSigner.verify_url(url, opts)` returns `{:ok, %{uuid:, variant:, version:}}`
when the string is a well-formed file URL signed by this app (and the file
exists, is not system-managed or trashed, and a private file's time-window
token is still valid). **That is not authorization**: check the viewer's
rights to the uuid separately. Only the path is checked, never the scheme or
host — act on the returned uuid, never fetch or render the string itself.

## Storing a file from a URL

`Storage.store_from_url(url, user_uuid: …)` downloads a URL and stores it
like an upload (`:library_uuid`, `:allowed_types` — default `["image/"]` —,
`:filename`). It blocks for the whole download: call it from a Task or a
job, never a LiveView event handler.

- **The fetch never reaches the server's own network.**
  `Storage.RemoteFetch.download/2` allows https only (`allow_http:`), ports
  80/443 (`allowed_ports:`), resolves the host once, requires every address
  to be public (`PhoenixKit.Utils.PublicAddress`) and connects to the
  address it checked; redirects are followed by hand and re-checked; the body
  is capped (`max_bytes`, 25 MB) within one `timeout` (15 s). A network with
  its own internal ranges (a NAT64 prefix that is not `64:ff9b::/96`) lists
  them in `config :phoenix_kit, :blocked_ip_ranges, ["…/96"]`. Never fetch a
  user-supplied URL with a plain HTTP client.
- **The stored type comes from the bytes** (`Storage.Sniff`), not the
  response's `Content-Type` or the name; an unknown or disallowed type is
  `{:error, :unsupported_type}`. The stored name is the URL's last path
  segment, cleaned of separators.

---

## Title, alt text and description (translatable)

A file's title, alt text and description are read and written through
`PhoenixKit.Modules.Storage.FileDetails` — never by reaching into `data` or
`metadata` directly:

```elixir
Storage.translated_alt(file, locale)          # "" when none — never the file name
Storage.translated_title(file, locale)        # nil when none
Storage.translated_description(file, locale)

Storage.translated_alts(uuids, locale)        # %{uuid => alt}, one query — for list pages
Storage.translated_alt_by_uuid(uuid, locale)

Storage.change_file_details(file, %{}, lang: "et")              # an editor tab's changeset
Storage.update_file_details(file, params, lang: "et")           # replaces that language only
```

The text lives in the `data` column, one entry per language:
`%{"en-US" => %{"title" => …, "alt" => …}, "et" => %{…}}`. Every language
holds its own text and **none is marked as primary**, so changing the site's
primary language converts nothing. Each field resolves when it is read: the
language asked for (or a dialect of it) → the site's current primary language
→ any other language. Resolving many files? Pass `primary:` once instead of
letting every call read the setting.

The editors (the media detail page, the viewer sidebar) have no language
tabs: they edit the language the page is shown in
(`FileDetails.content_language(locale)`), so the admin language switcher is
the content switcher.

This is deliberately not the `PhoenixKit.Utils.Multilang` structure (diffs
against an embedded primary): for three fields it buys nothing and ties the
stored text to a setting that can change.

A file saved before V199 has its title and description in `metadata`; while
its `data` is empty that text is read as the primary language's, and the
first save moves it into `data`. After that `metadata` only receives a copy
of the primary-language text, for the readers that still look there.

## Libraries

Every file, media folder and folder link belongs to one **library**
(`library_uuid`, V202), a partition of the file store. Everything that existed
before V202 is in **Media**, the default system library, which has a fixed uuid
(`Storage.Libraries.media_uuid/0`). Media is also the column default, so any
writer that names no library, core's or a module's, lands there. System
libraries are created, renamed and deleted (when empty) in Settings → Media →
Libraries; `/admin/media` shows a switcher once a second one exists. Media is the bare `/admin/media`; any other library is
`/admin/media/library/<slug>`, where the slug comes from its name and is kept
when it is renamed (`Libraries.get_system_library_by_slug/1`).

- **Store into a library:** `Storage.store_file_in_buckets(..., library_uuid: uuid)`.
  A library with a `key_prefix` keys new objects under it
  (`{key_prefix}/{hash[0..1]}/{hash}/…`); Media has none and keeps the
  per-uploader layout (`{user_uuid[0..1]}/{hash[0..1]}/{hash}/…`).
- **Folders:** a root folder takes the library its attrs name (default Media),
  and a subfolder always takes its parent's. Folder names are unique per library
  and parent.
- **Nothing crosses libraries:** attaching, linking or moving a file into
  another library's folder, or moving a folder under another library's parent,
  returns `{:error, :other_library}`. A folder link carries its file's library,
  and the database refuses one that does not.
- **Listing one library:** the root-level listing, search, orphan and trash
  functions take `library_uuid:`. Without it they list every library, exactly
  as before.
- **Access:** `Storage.Libraries.can?(scope, file, :read | :edit)` is the
  single per-file check: the uploader, an Owner/Admin, the `"media"` key
  (edit, system libraries only), and a user library's owner and members.
- **Dedup is per library:** one copy per uploader per library. Media keeps
  the key it always had; any other library folds itself into
  `user_file_checksum` (`Storage.calculate_user_file_checksum/3`).

### User libraries (V203)

Off until the install turns them on (`storage_user_libraries_enabled`,
Settings → Media → Libraries). A user with the `"storage"` permission uses
the libraries they own or are a member of; `"storage.create_library"`
creates them, up to `storage_user_library_limit`. Each is `private`, and its
members are `manager`, `contributor` or `viewer` (`Libraries.allows?/2`).

- **API:** `Libraries.create_user_library/2`, `list_user_libraries/1`,
  `get_user_library/2` (by uuid, or the owner's own slug), `add_member/4`,
  `update_member_role/4`, `remove_member/3`, `trash_library/2`,
  `set_default_library/2`, `default_user_library/1`. Each checks the
  caller's role itself.
- **Pages:** users manage their libraries on the profile's Media tab
  (`/profile/settings/media`); `/admin/libraries` browses them (moderation
  and testing). `phoenix_kit_photos` is the end-user surface.
- **Trash and deletion:** a trashed library frees its name at once and is
  purged, bytes included, after `trash_retention_days` (`PurgeLibraryJob`,
  queued by the daily prune). Deleting a user trashes the libraries they own
  first (the database refuses otherwise, V203), and keeps their uploads
  elsewhere with no uploader.
- **Admins:** an Owner or Admin can open a user's library at
  `/admin/libraries/<uuid>`; every opening is audit-logged
  (`storage.library_opened`).


### User-owned storage (V206)

A user may keep a library's files in their **own S3-compatible bucket** (AWS S3,
Backblaze B2, Cloudflare R2, Tigris) instead of the site's storage. Off until the
site turns it on (`storage_user_buckets_enabled`, Settings → Media → Libraries);
needs the `"storage.own_storage"` sub-permission and `"integrations"` (the keys are
a personal `object_storage` connection, offered on the user's "add integration"
picker only while the setting is on).

- **Created with the library**, on the profile's Media tab, in one transaction:
  `Libraries.create_user_library/3` with a `"storage"` map (`mode` `only` or
  `backup`, the user's connection, provider, bucket, region/endpoint). The bucket
  is probed first (list, write, delete); a failure creates nothing. **The choice
  is final**: `Profiles.set_library_profile/2` refuses to move a library off or
  onto user storage.
- **`only`**: the user's bucket is the profile's one `primary`. **`backup`**: the
  site's buckets keep their roles (a **snapshot of the Default profile at
  creation**; a site bucket added later is not used) and the user's bucket holds a
  `backup` of every file, including sizes and tiles. Every file gets a copy on
  each writable snapshotted site bucket, counted per kind, plus a cloud copy on
  the backup (at most 5 copies, so four site buckets, active first). Uploads
  succeed on the Default's terms counting the site's
  copies only (`min_copies_on_write` ignores a backup: it is never served); the
  reconciler makes a backup the write missed.
- **Schema**: `owner_uuid` on `phoenix_kit_buckets` and `phoenix_kit_storage_profiles`
  (NULL = the site's; **no foreign key**, so a deleted user's bucket can never
  become a site bucket), and `phoenix_kit_buckets_owned_check`: an owned bucket is
  never `local`, always on a connection, never `public`.
- **The site never sees it**: `Storage.list_buckets/0`, `list_enabled_buckets/0`
  and `Profiles.list_profiles/0` return the site's rows only. A user's bucket is
  reached only through the file location rows and its owner's profile: reads
  resolve located buckets by uuid (`Manager.read_order/4`; the fallback that probes
  other buckets is the site's pool alone), and the objects of a user library are
  deleted from its profile's own buckets (`Storage.owned_buckets_for_dir/1`,
  found through the library's `key_prefix`).
- **Safety**: credentials are read as the owner (`owner: {:user, uuid}`); the
  endpoint is held to the `:personal` policy (https, no local/private/metadata
  address, host resolved) when the bucket is saved and whenever a request is built
  (`Storage.Endpoint`); files are served through signed links or the proxy, never a
  plain object URL.
- **Purge**: trashing a library and purging it deletes the objects it wrote in the
  user's bucket **before** its rows; if an object cannot be deleted the file, library,
  profile and bucket row stay and the purge job retries (`{:error, :objects_remain}`),
  then the user's profile and bucket go. Deleting a *user account* also
  deletes their personal connections, so the keys are gone by the time the purge
  runs and the objects in their own bucket are left there.
- **Admin**: the Libraries tab shows each user library's storage (site, own bucket,
  or backup) by bucket provider, never a credential. Removing a connection a bucket
  uses says so first, on the admin and the personal pages.

### Private files

A file in a private library (every user library) is served only with a
**time-window token**: an HMAC over the file, the variant and an expiry
rounded up to a window (`storage_private_url_window_hours`, default 12). The
file and tile routes refuse its permanent token, answer an expired one with
403, never redirect to a public object URL, and send `private` cache headers
(`private, max-age=3600`, tiles included). `get_public_url*` does not return
a bucket's object URL for one.

- ⚠️ **Mint a private file's URL after an access check:**
  `Storage.authorized_url(scope, file, variant)` checks
  `can?(scope, file, :read)` and mints the right token. The other URL helpers
  (`get_public_url*`, `list_image_set_variants*`) mint the permanent token,
  which a private file refuses: they fail closed.
- Building URLs by hand: `URLSigner.signed_url(uuid, variant, private: true)`,
  with `Libraries.private_file?/1`, or `Libraries.private_among/1` for a batch.
- ⚠️ **A `MediaBrowser` given a `library_uuid` refuses any event that names a
  file or folder of another library.** A host embedding it for a user
  library relies on that: the scope-folder check alone admits everything.

## When a photo or video was taken

`PhoenixKit.Modules.Storage.CaptureDate` reads it; four columns hold it
(V200). `taken_on` is the **local date** and is what to group by: a photo
taken at 23:00 on 31 July in California is a July photo, although it is
already 1 August in UTC, so grouping on `taken_at` files it under the wrong
month. `taken_at` is the UTC instant — exact when the offset is known, the
local time stored as UTC when it is not (most EXIF has no offset), which
still orders a library correctly.

Where a date comes from, strongest first (`taken_at_source`):

1. `manual` — set by a person; never replaced automatically
2. `exif` (images: `DateTimeOriginal`, else `DateTimeDigitized`, with their
   offset tags) and `container` (video: QuickTime's creation date, which
   keeps the local time and offset, else `creation_time`, UTC)
3. `filename` — `IMG_20180701_120000.jpg`, `PXL_20240315_081100123.jpg`,
   `2018-07-01 12.34.56.jpg`, …
4. `inserted_at` — the upload time; every file has one, so every image and
   video resolves to *some* date

A file's modification time is not a source: stored originals live on disk or
in object storage, where it is the upload time.

**Who writes it.** `ProcessFileJob` dates each new upload from the bytes it
already downloads for the dimensions, in the same guarded transaction.
`Storage.Workers.CaptureDateBackfillJob` dates files stored before V200:

```elixir
CaptureDateBackfillJob.enqueue()        # a pass in the background (file_processing queue)
CaptureDateBackfillJob.pending_count()  # images and videos still without a date
```

```bash
mix phoenix_kit.storage.backfill_capture_dates   # a pass in the foreground, with progress
```

**Never downgraded.** An image edit keeps only the ICC profile, so an edited
original has no EXIF, and re-reading it finds the file name or the upload
time at best. Every automatic writer goes through `CaptureDate.replace?/2`: a
date is replaced only by one from an equally strong or stronger source, and a
manual date never. An edited image is dated from its unedited backup
(`original_file_uuid`) instead of its own bytes.

**Needs** ImageMagick's `identify` for images (already required) and `ffprobe`
for video. Without `ffprobe` a video falls back to its file name or upload
time — the same degradation its dimensions and duration already have.

## Editing images

`PhoenixKit.Modules.Storage.ImageEditing` edits a stored image after upload:
crop, quarter turns, mirroring, straightening, redaction (blur, pixelate,
black box), brightness and contrast. The edit is data
(`PhoenixKit.Modules.Storage.ImageEdit`, stored in `files.edits`), always
applied to the unedited original by `ApplyImageEditJob` with ImageMagick. The
UI is `PhoenixKitWeb.Components.ImageEditor`.

**The file keeps its uuid.** Its `"original"` instance becomes the edited
bytes, so every module that stored the uuid shows the edit, and every reader
of the original (variants, tiles, downloads, public URLs) gets it without
knowing. Object keys are content-addressed, so the edited bytes get new keys.

**The unedited original is not destroyed** (setting
`storage_image_edit_mode`, default `keep_original`). Its instance rows move
to a hidden child file — `system_managed`, `file_name: "unedited-original"`,
`parent_file_uuid` = the file, `files.original_file_uuid` points at it — that
is never listed, never a dedup target and never served by the public routes.
Whoever may edit the image can download it
(`GET /api/files/:uuid/unedited`), restore it, or delete it, which bakes the
edit in. With `replace_original`, every save bakes immediately.

**The unedited original leaves the keys it was served under.** On a public
bucket a file's objects are reachable as plain bucket URLs (the file routes
redirect to them), so bytes left at those keys would survive a redaction
behind any saved link. The first edit therefore copies every unedited object
to a private key (`unedited_<128 random bits>_<name>`, same directory), points
the backup's rows and locations at the copies, and deletes the served keys
once nothing references them. A key another file still references (a
cross-user copy of the same bytes) is that file's and stays. A backup made
before this (2.28.0) moves on its next edit; a revert brings the copies back
as the file's keys, and the next edit copies them again.

**What an edit cannot take back:** copies already made of a response. A
versioned file URL is served `immutable`, so a browser or CDN that fetched
the unredacted image keeps it until its own cache expires. If you front
files with a CDN and redact, purge it: `[:phoenix_kit, :storage,
:file_edited]` telemetry fires after each swap with the `file_uuid` and the
`removed_keys`.

**While an edit renders** (`edit_state: "pending"`) **or after it failed**
(`"failed"`), every variant of the file is served as a placeholder: a
half-applied redaction must never show what it hides. Retry from the editor
or with `ImageEditing.retry/2`.

**Concurrency.** Saving bumps `edit_revision`. Every step of the job checks
it: a render for an older revision is thrown away, a revision already
published is not published twice, and a failure marks only its own revision.
Variant and dimension results are recorded only while the original they were
made from is still the file's (`Storage.original_key?/2`).

**Deleting stored objects.** An object is deleted exactly when no instance
row references its key any more (an edited file and its backup share a
directory; cross-user copies share keys). `Storage.delete_stored_objects/2`
re-checks the references under the directory's advisory lock and deletes
inside it; publishing a new object takes the same lock and checks the object
still exists. Never delete a stored object any other way.

**Annotations** are drawn in pixel space, so an image with annotations
refuses edits that change its geometry (crop, turn, mirror, straighten);
redaction and tone changes are fine, and "save as copy" always is. An edit
that changes the geometry also clears avatar crops made on the image.

**Not editable:** GIFs and other animated images, system-managed files,
trashed files, and formats ImageMagick cannot write back.

---

## Settings

New settings added in V18 migration:

```elixir
storage_redundancy_copies: "1"           # The Default storage profile's copy count (V205 alias)
storage_auto_generate_variants: "true"   # The Default variant set's generate_variants (V205 alias)
storage_tile_generation_enabled: "false" # The Default variant set's old generate_tiles flag (V205 alias); deep zoom is now per library
storage_max_upload_size_mb: "500"        # Per-file upload cap
storage_user_libraries_enabled: "false"  # User libraries on/off (V203)
storage_user_library_limit: "10"         # Libraries one user may own (V203)
storage_private_url_window_hours: "12"   # How long a private file's link lasts (V203)
storage_default_bucket_uuid: nil         # Unused: selection never read it; storage profiles (V205) replace the idea
```

**Access in code:** the three aliases are read and written through the
Default profile and set, which keep the rows in step:
```elixir
Storage.redundancy_copies()            # Storage.set_redundancy_copies(2)
Storage.get_auto_generate_variants()   # Storage.set_auto_generate_variants(true)
Storage.tile_generation_enabled?()     # Storage.set_tile_generation(false)
```

---

## Data Flow Example

**User uploads profile.jpg (2000x2000 JPEG):**

### 1. Upload
```
POST /api/upload
Content-Type: multipart/form-data
```

### 2. Create File Record
```elixir
%PhoenixKit.Storage.File{
  id: "018e3c4a-9f6b-7890-abcd-ef1234567890",  # UUIDv7
  original_file_name: "profile.jpg",
  file_name: "018e3c4a-9f6b-7890-original.jpg",
  mime_type: "image/jpeg",
  file_type: "image",
  ext: "jpg",
  checksum: "abc123def456...",
  size: 524_288,  # 512 KB
  width: 2000,
  height: 2000,
  status: "processing",
  user_id: "018e1234-5678-..."
}
```

### 3. Queue Background Job
```elixir
Oban.insert(ProcessFileJob.new(%{file_id: "018e3c4a-..."}))
```

### 4. Generate Variants (4 enabled dimensions)
```elixir
# Original (no resize)
%FileInstance{
  variant_name: "original",
  file_name: "018e3c4a-9f6b-7890-original.jpg",
  size: 524_288,
  width: 2000,
  height: 2000,
  processing_status: "completed"
}

# Thumbnail (150x150)
%FileInstance{
  variant_name: "thumbnail",
  file_name: "018e3c4a-9f6b-7890-thumbnail.jpg",
  size: 8_192,
  width: 150,
  height: 150,
  processing_status: "completed"
}

# Medium (800x800)
%FileInstance{
  variant_name: "medium",
  file_name: "018e3c4a-9f6b-7890-medium.jpg",
  size: 102_400,
  width: 800,
  height: 800,
  processing_status: "completed"
}

# Large (1920x1920)
%FileInstance{
  variant_name: "large",
  file_name: "018e3c4a-9f6b-7890-large.jpg",
  size: 262_144,
  width: 1920,
  height: 1920,
  processing_status: "completed"
}
```

### 5. Select Buckets (redundancy = 2)
```elixir
# Priority buckets available: B2 (priority 1), R2 (priority 2)
selected_buckets = [
  %Bucket{name: "Backblaze B2", priority: 1},
  %Bucket{name: "Cloudflare R2", priority: 2}
]
```

### 6. Upload to Storage
Each bucket receives all 4 instances:

```
Backblaze B2:
  /path/018e3c4a-9f6b-7890-original.jpg
  /path/018e3c4a-9f6b-7890-thumbnail.jpg
  /path/018e3c4a-9f6b-7890-medium.jpg
  /path/018e3c4a-9f6b-7890-large.jpg

Cloudflare R2:
  /path/018e3c4a-9f6b-7890-original.jpg
  /path/018e3c4a-9f6b-7890-thumbnail.jpg
  /path/018e3c4a-9f6b-7890-medium.jpg
  /path/018e3c4a-9f6b-7890-large.jpg
```

### 7. Create Location Records (8 total)
4 instances × 2 buckets = 8 location records

```elixir
%FileLocation{path: "/path/018e3c4a-...-original.jpg", bucket_id: b2_id, instance_id: orig_id}
%FileLocation{path: "/path/018e3c4a-...-thumbnail.jpg", bucket_id: b2_id, instance_id: thumb_id}
%FileLocation{path: "/path/018e3c4a-...-medium.jpg", bucket_id: b2_id, instance_id: med_id}
%FileLocation{path: "/path/018e3c4a-...-large.jpg", bucket_id: b2_id, instance_id: large_id}
# ... 4 more for R2
```

### 8. Update Status
```elixir
File.update(file, %{status: "active"})
```

### 9. Generate Signed URLs
```elixir
PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-...", "thumbnail")
# => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/thumbnail/a3f2"

PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-...", "medium")
# => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/medium/b7e5"

PhoenixKit.Storage.URLSigner.signed_url("018e3c4a-...", "large")
# => "/file/018e3c4a-9f6b-7890-abcd-ef1234567890/large/c2d9"
```

---

## Implementation Phases

### Phase 1: Database Foundation (Current Session)

**Deliverables:**
- ✅ Add `{:uuidv7, "~> 1.0"}` dependency to `mix.exs`
- ✅ Create migration V19 with all 5 tables
- ✅ Seed default dimensions (thumbnail, small, medium, large, 720p, 1080p)
- ✅ Seed default local bucket (priority 0)
- ✅ Add storage settings (redundancy_copies, auto_generate_variants)
- ✅ Create 5 Ecto schemas with UUIDv7 support
- ✅ Create `PhoenixKit.Storage` context module:
  - CRUD operations for all entities
  - Smart bucket selection with priority system
  - Free space calculation for random buckets
  - URL generation helpers
  - Token signing functions
- ✅ Create `PhoenixKit.Storage.URLSigner` module
- ✅ Test compilation

**Files to Create:**
1. `lib/phoenix_kit/migrations/postgres/v19.ex`
2. `lib/phoenix_kit/storage.ex`
3. `lib/phoenix_kit/storage/bucket.ex`
4. `lib/phoenix_kit/storage/file.ex`
5. `lib/phoenix_kit/storage/file_instance.ex`
6. `lib/phoenix_kit/storage/file_location.ex`
7. `lib/phoenix_kit/storage/dimension.ex`
8. `lib/phoenix_kit/storage/url_signer.ex`

**Files to Modify:**
1. `mix.exs` - Add ecto_uuidv7 dependency

---

### Phase 2: Admin UI (Next Session)

**Deliverables:**

#### Buckets/Volumes Management
- Location: `/admin/settings/storage/buckets`
- Features:
  - List all storage buckets/volumes
  - Add new bucket with provider dropdown (local, s3, b2, r2)
  - Edit bucket configuration (name, credentials, endpoint, priority, max size)
  - Delete bucket with safety checks
  - Enable/disable buckets
  - Show usage statistics (used space, free space)
  - Test connection button
  - Provider badges: [Local] [S3] [B2] [R2]

**Files to Create:**
1. `lib/phoenix_kit_web/live/settings/storage/buckets.ex`
2. `lib/phoenix_kit_web/live/settings/storage/buckets.html.heex`
3. `lib/phoenix_kit_web/live/settings/storage/bucket_form.ex`
4. `lib/phoenix_kit_web/live/settings/storage/bucket_form.html.heex`

#### Dimensions Management
- Location: `/admin/settings/storage/dimensions`
- Features:
  - List all dimension presets
  - Add new dimension (name, width, height, quality, format)
  - Edit dimension presets
  - Delete custom dimensions (protect seeded defaults)
  - Enable/disable dimensions
  - Set applies_to (image, video, both)
  - Drag-to-reorder dimensions

**Files to Create:**
1. `lib/phoenix_kit_web/live/settings/storage/dimensions.ex`
2. `lib/phoenix_kit_web/live/settings/storage/dimensions.html.heex`
3. `lib/phoenix_kit_web/live/settings/storage/dimension_form.ex`
4. `lib/phoenix_kit_web/live/settings/storage/dimension_form.html.heex`

#### Updated Storage Settings
- Location: `/admin/settings/storage` (existing page)
- Add redundancy copies selector (1-5)
- Add auto-generate variants toggle
- Add default bucket selector dropdown
- Keep existing path configuration

**Files to Modify:**
1. `lib/phoenix_kit_web/live/settings/storage.ex`
2. `lib/phoenix_kit_web/live/settings/storage.html.heex`

---

### Phase 3: File Upload & Processing (Future)

**Deliverables:**

#### Upload Controller
- Route: `POST /api/upload`
- Features:
  - Handle multipart file uploads
  - Validate file type and size
  - Generate unique filename with UUIDv7
  - Calculate checksum (MD5 or SHA256)
  - Detect MIME type and extract metadata
  - Create `phoenix_kit_files` record
  - Queue background processing job

**Files to Create:**
1. `lib/phoenix_kit_web/controllers/upload_controller.ex`
2. `lib/phoenix_kit/storage/upload.ex` - Upload handling logic

#### Background Processing (Oban)
- **Image Processing** (Mogrify/Vips):
  - Generate variants for enabled dimensions
  - Optimize images (compression, format conversion)
  - Extract EXIF data (width, height, orientation)
- **Video Processing** (FFmpeg):
  - Generate quality variants (720p, 1080p)
  - Extract video thumbnail (frame at 1 second)
  - Extract metadata (duration, resolution, codec)
- **Document Processing**:
  - Extract metadata (page count, author, etc.)
  - No variant generation
- **Storage Distribution**:
  - Select buckets using priority system
  - Upload original + variants to all selected buckets
  - Create `phoenix_kit_file_instances` records
  - Create `phoenix_kit_file_locations` records

**Files to Create:**
1. `lib/phoenix_kit/storage/workers/process_file_job.ex`
2. `lib/phoenix_kit/storage/processors/image_processor.ex`
3. `lib/phoenix_kit/storage/processors/video_processor.ex`
4. `lib/phoenix_kit/storage/processors/document_processor.ex`
5. `lib/phoenix_kit/storage/uploaders/local_uploader.ex`
6. `lib/phoenix_kit/storage/uploaders/s3_uploader.ex`

**Dependencies to Add:**
- `{:mogrify, "~> 0.9"}` or `{:vix, "~> 0.5"}` - Image processing
- `{:ffmpex, "~> 0.10"}` - Video processing
- `{:ex_aws, "~> 2.5"}` - AWS S3 integration
- `{:ex_aws_s3, "~> 2.5"}` - S3 operations
- `{:oban, "~> 2.17"}` - Background jobs (if not already present)

---

### Phase 4: File Serving (Future)

**Deliverables:**

#### File Serving Controller
- Route: `GET /file/:file_id/:instance_name/:token`
- Features:
  - Token verification (prevent unauthorized access)
  - Query `phoenix_kit_file_locations` for file paths
  - Try each location in priority order (automatic failover)
  - Stream file with correct headers:
    - `Content-Type` (from mime_type)
    - `Content-Length` (from size)
    - `Cache-Control` (e.g., max-age=31536000 for immutable files)
    - `ETag` (from checksum)
  - Log access for analytics
  - Support range requests (HTTP 206 for video streaming)

#### CDN Integration
- If bucket has `cdn_url`, redirect to CDN
- Otherwise serve directly from storage (local/S3)

**Files to Create:**
1. `lib/phoenix_kit_web/controllers/file_controller.ex`
2. `lib/phoenix_kit/storage/file_server.ex` - Serving logic

**Router Update:**
```elixir
get "/file/:file_id/:instance_name/:token", FileController, :show
```

---

### Phase 5: Admin Dashboard (Future)

**Deliverables:**

#### Storage Analytics Dashboard
- Location: `/admin/storage` or dedicated storage section
- **User Statistics**:
  - Files uploaded per user
  - Storage used per user (bytes, formatted)
  - Top 10 storage users
- **File Statistics**:
  - Total files count
  - Total storage used (formatted)
  - Files by type (images, videos, documents, archives)
  - Files by status (active, processing, failed)
- **Storage Distribution**:
  - Storage used per bucket/volume
  - Free space per bucket
  - Redundancy health (files with missing copies)
- **Charts & Visualizations**:
  - Storage growth over time (line chart)
  - File type distribution (pie chart)
  - Bucket usage (bar chart)

**Files to Create:**
1. `lib/phoenix_kit_web/live/dashboard/storage.ex`
2. `lib/phoenix_kit_web/live/dashboard/storage.html.heex`

**Context Methods to Add:**
```elixir
# In PhoenixKit.Storage
def get_storage_stats()
def get_user_storage_stats(limit \\ 10)
def get_bucket_usage_stats()
def get_file_type_distribution()
def get_storage_growth_over_time(days \\ 30)
def get_redundancy_health()
```

#### File Browser (Optional)
- Location: `/admin/storage/files`
- Features:
  - Browse all files in system
  - Filter by user, file type, date range
  - Search by filename
  - View file details and all instances
  - See which buckets store each file
  - Delete files (cascade delete instances and locations)
  - Bulk operations (delete, move, verify)

**Files to Create:**
1. `lib/phoenix_kit_web/live/storage/file_browser.ex`
2. `lib/phoenix_kit_web/live/storage/file_browser.html.heex`
3. `lib/phoenix_kit_web/live/storage/file_details.ex`
4. `lib/phoenix_kit_web/live/storage/file_details.html.heex`

---

## Future Features (Planned but Not Scheduled)

### Cloud Backup Mode
**Setting:** `storage_cloud_backup_only` (boolean, default: false)

**Concept:**
- Local storage prioritized for both upload and retrieval
- Cloud storage used only as backup/disaster recovery
- Reduces cloud bandwidth costs
- Faster file serving from local drives

**Upload Behavior (when enabled):**
1. Always upload to local buckets first
2. Then replicate to cloud buckets for redundancy
3. If redundancy = 2:
   - Use 2 local drives if available
   - If only 1 local, use 1 local + 1 cloud
   - If no local, fall back to 2 cloud buckets

**Retrieval Behavior (when enabled):**
1. Always try local locations first
2. If local fails, automatic failover to cloud
3. Site stays up even if all local drives fail

**Implementation:**
```elixir
# Settings
%{key: "storage_cloud_backup_only", value: "false"}

# Bucket selection logic
def select_buckets_cloud_backup_mode(buckets, redundancy_count) do
  local = Enum.filter(buckets, & &1.provider == "local")
  cloud = Enum.filter(buckets, & &1.provider in ["s3", "b2", "r2", "tigris"])

  local_selected = select_by_priority_and_space(local, redundancy_count)

  if length(local_selected) < redundancy_count do
    cloud_needed = redundancy_count - length(local_selected)
    cloud_selected = select_by_priority_and_space(cloud, cloud_needed)
    local_selected ++ cloud_selected
  else
    local_selected
  end
end

# File serving order
def get_file_locations_cloud_backup_mode(file_id, instance_name) do
  locations = query_file_locations(file_id, instance_name)

  # Sort: local first, then cloud
  Enum.sort_by(locations, fn loc ->
    if loc.bucket.provider == "local", do: 0, else: 1
  end)
end
```

### File Verification & Health Checks
- Periodic background job to verify file integrity
- Check file existence and checksum matches
- Mark missing/corrupted locations as `failed`
- Alert admin if redundancy falls below threshold
- Auto-repair by copying from healthy locations

### Storage Migration Tools
- Move files between buckets
- Batch migration with progress tracking
- Verify after migration
- Update location records

### Advanced Analytics
- File access logs (who accessed what, when)
- Most popular files
- Bandwidth usage per bucket
- Cost estimation for cloud storage

### API Endpoints
- RESTful API for file upload/download
- Authentication with API tokens
- Rate limiting
- Webhook callbacks for processing completion

---

## Code Structure

```
lib/
├── phoenix_kit/
│   ├── storage.ex                      # Main context module
│   ├── storage/
│   │   ├── bucket.ex                   # Bucket schema
│   │   ├── file.ex                     # File schema
│   │   ├── file_instance.ex            # FileInstance schema
│   │   ├── file_location.ex            # FileLocation schema
│   │   ├── dimension.ex                # Dimension schema
│   │   ├── url_signer.ex               # Token generation/verification
│   │   ├── upload.ex                   # Upload handling (Phase 3)
│   │   ├── file_server.ex              # File serving logic (Phase 4)
│   │   ├── workers/
│   │   │   └── process_file_job.ex     # Background processing (Phase 3)
│   │   ├── processors/
│   │   │   ├── image_processor.ex      # Image variant generation (Phase 3)
│   │   │   ├── video_processor.ex      # Video variant generation (Phase 3)
│   │   │   └── document_processor.ex   # Document metadata (Phase 3)
│   │   └── uploaders/
│   │       ├── local_uploader.ex       # Local filesystem upload (Phase 3)
│   │       └── s3_uploader.ex          # S3-compatible upload (Phase 3)
│   └── migrations/
│       └── postgres/
│           └── v18.ex                  # Storage system migration (Phase 1)
├── phoenix_kit_web/
│   ├── controllers/
│   │   ├── upload_controller.ex        # File upload endpoint (Phase 3)
│   │   └── file_controller.ex          # File serving endpoint (Phase 4)
│   └── live/
│       ├── settings/
│       │   ├── storage.ex              # Storage settings (modified Phase 2)
│       │   ├── storage.html.heex       # Storage settings view (modified Phase 2)
│       │   └── storage/
│       │       ├── buckets.ex          # Buckets management (Phase 2)
│       │       ├── buckets.html.heex   # Buckets view (Phase 2)
│       │       ├── bucket_form.ex      # Bucket form component (Phase 2)
│       │       ├── bucket_form.html.heex
│       │       ├── dimensions.ex       # Dimensions management (Phase 2)
│       │       ├── dimensions.html.heex
│       │       ├── dimension_form.ex   # Dimension form component (Phase 2)
│       │       └── dimension_form.html.heex
│       ├── dashboard/
│       │   └── storage.ex              # Storage analytics (Phase 5)
│       │   └── storage.html.heex       # Storage analytics view (Phase 5)
│       └── storage/
│           ├── file_browser.ex         # File browser (Phase 5)
│           ├── file_browser.html.heex
│           ├── file_details.ex         # File details modal (Phase 5)
│           └── file_details.html.heex
└── modules/
    └── storage/
        └── spec.md                     # This file
```

---

## Testing Strategy

### Unit Tests
- Schema validations
- Context CRUD operations
- Token generation/verification
- Bucket selection algorithm
- Free space calculation

### Integration Tests
- File upload flow
- Background processing
- Multi-location redundancy
- Failover behavior
- File serving with token verification

### Performance Tests
- Large file uploads (>100MB)
- Concurrent uploads
- Token generation speed
- Database query performance

---

## Security Considerations

### Token-based URLs
- ✅ Prevents enumeration attacks
- ✅ Each instance has unique token
- ✅ Secure comparison prevents timing attacks
- ✅ Tokens rotate if secret_key_base changes

### File Upload Validation
- ✅ MIME type verification (not just extension)
- ✅ File size limits (per bucket max_size_mb)
- ✅ Malware scanning (future integration)
- ✅ User upload quotas (future feature)

### Access Control
- ✅ User-specific file ownership (user_id foreign key)
- ✅ Admin-only bucket/dimension management
- ✅ Role-based permissions (leverage existing role system)

### Credentials Storage
- ✅ Encrypt `secret_access_key` at rest (`PhoenixKit.Integrations.Encryption`, AES-256-GCM)
- ✅ `access_key_id` is a credentials identifier, not a secret — stored as-is, not encrypted
- ✅ Cloud buckets reference a `PhoenixKit.Integrations` `object_storage` connection
  (`integration_uuid`); the bucket form has no key fields. A bucket that still carries its
  own keys (legacy) keeps working, and `Storage.BucketCredentials.move_to_integration/2`
  (bucket form button, or "Move all" on Settings → Media) moves them — never automatically,
  and never clearing a key it cannot read back through the new connection. Direct keys stay
  supported through `Storage.create_bucket/1` for scripts and seeds. A bucket's `region` and
  `endpoint` stay on the bucket (the form prefills them from the connection).
- ✅ Endpoints are parsed in one place (`Storage.Endpoint.parse/1`, shared with the
  `object_storage` validator) and guarded by `Storage.Endpoint.check/3`: a system bucket may
  use a local or private endpoint (a MinIO on the same network), but never a metadata,
  link-local or reserved address; a personal connection needs https and no local/private
  address, with the host resolved and every address checked. The check is not a connect-time
  pin — a name whose DNS changes between the check and the request is not caught.
- ✅ A bucket reads credentials from a connection owned by its own owner only
  (`S3.resolve_credentials/1` passes `owner:`); every bucket is system-owned until user-owned
  buckets exist
- ✅ "Test Connection" writes, reads back and deletes a small object under a fresh
  `.phoenix_kit/connection-test-…` key (it never touches an object it did not write):
  read-only keys are the common misconfiguration
- ⚠️ No bulk backfill for a `secret_access_key` already in the column when encryption was
  added — it stays plaintext until the next save of the bucket for ANY reason (the
  changeset re-derives and re-encrypts it opportunistically, not on a schedule)
- ✅ Use environment variables for secrets
- ✅ Never log credentials

---

## Migration Path

### From V18 to V19
1. Run `mix phoenix_kit.update`
2. System detects current version (V18)
3. Applies V19 migration:
   - Creates 5 new tables
   - Adds 3 new settings
   - Seeds default dimensions
   - Seeds default local bucket
4. No downtime required (additive changes only)
5. Existing PhoenixKit features unaffected

### Rollback Strategy
- V19 migration includes `down/1` function
- Drops all 5 tables
- Removes settings
- No data loss for existing features

---

## Performance Optimization

### Database Indexes
All critical queries indexed:
- File lookups by user_id
- Instance lookups by file_id
- Location lookups by instance_id and bucket_id
- Dashboard analytics (file_type, status, inserted_at)

### Caching Strategy (Future)
- Cache bucket configuration (rarely changes)
- Cache dimension presets (rarely changes)
- Cache file metadata for hot files (Redis)
- CDN caching for static files

### Query Optimization
- Use `preload` for associations (avoid N+1)
- Paginate file browser queries
- Use database aggregations for analytics
- Index all foreign keys

---

## Dependencies

### Phase 1 (Immediate)
```elixir
{:uuidv7, "~> 1.0"}  # UUIDv7 generation with Ecto.Type support
```

### Phase 3 (Future)
```elixir
{:mogrify, "~> 0.9"}       # Image processing (ImageMagick wrapper)
# OR
{:vix, "~> 0.5"}           # Image processing (libvips wrapper, faster)

{:ffmpex, "~> 0.10"}       # Video processing (FFmpeg wrapper)
{:ex_aws, "~> 2.5"}        # AWS SDK
{:ex_aws_s3, "~> 2.5"}     # S3 operations
{:oban, "~> 2.17"}         # Background jobs (if not present)
```

---

## Configuration

### Application Config
```elixir
# config/config.exs
config :phoenix_kit,
  repo: MyApp.Repo,
  secret_key_base: "..." # Required for token generation

# Optional overrides
config :phoenix_kit, PhoenixKit.Storage,
  max_upload_size_mb: 100,
  allowed_mime_types: ["image/*", "video/*", "application/pdf"]
```

### Environment Variables (Phase 3)
```bash
# AWS S3
AWS_S3_BUCKET=...

# Backblaze B2
B2_KEY_ID=...
B2_APPLICATION_KEY=...
B2_BUCKET=...

# Cloudflare R2
R2_ACCOUNT_ID=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=...
```

---

## Changelog

### V19 Migration - Storage System Foundation
**Added:**
- 5 new database tables (buckets, files, file_instances, file_locations, dimensions)
- UUIDv7 support via uuidv7 package
- Smart bucket selection with priority system
- Token-based URL security
- Multi-location redundancy support
- 3 new settings (redundancy_copies, auto_generate_variants, default_bucket_id)
- Seeded default dimensions (thumbnail, small, medium, large, 720p, 1080p)
- Seeded default local bucket

**Files Created:**
- `lib/phoenix_kit/migrations/postgres/v19.ex`
- `lib/phoenix_kit/storage.ex`
- `lib/phoenix_kit/storage/bucket.ex`
- `lib/phoenix_kit/storage/file.ex`
- `lib/phoenix_kit/storage/file_instance.ex`
- `lib/phoenix_kit/storage/file_location.ex`
- `lib/phoenix_kit/storage/dimension.ex`
- `lib/phoenix_kit/storage/url_signer.ex`

---

## Notes

- All UUIDs are v7 version (time-sortable)
- PostgreSQL-only (uses JSONB for metadata)
- Migration follows Oban-style versioning pattern
- Compatible with existing PhoenixKit authentication and role systems
- No breaking changes to existing functionality
- Ready for production use after Phase 4 completion

---

**End of Specification**
