# PR #1001: Add editable library access, safe backup storage and live progress — Mistral review

**Reviewer:** Mistral · **Baseline:** `23ed7a4a8` on `main` (merge of #1001).
(Codex's review of the same PR found and fixed one HIGH authorization gap;
this review focused on the serving/audience path and the backup-storage
write path.)

## What the PR does

- Library "audience": a published user library may require sign-in
  (`settings["public_audience"] = "authenticated"`); such libraries answer
  as private for URL minting, rotate an `access_revision` baked into the
  time-window token MAC on change, and every serving path re-checks the
  viewer at request time.
- Editable library access via `Libraries.Preferences` (owner or system role,
  fresh re-read scope intersected with the active role, explicit
  `confirm: "true"` and the publication permission to expand the audience).
- `Libraries.add_user_storage/4`: append verified backup buckets to an
  existing library profile.

## Verified sound

- `FileController` applies `library_audience_allowed?/2` on `show`,
  download and `unedited` (all via `get_servable_file/2`) and in the shared
  tile/manifest token check; login-required files are never answered with a
  public-object redirect (`keep_authenticated/2` proxies) and get
  `cache-control: private` (`request_cache_mode/4`,
  `tile_response_cache_control/3`), so a shared cache cannot keep the bytes
  past the window. Old permanent links issued while anonymous stay
  verifiable, but the request-time audience check still refuses anonymous
  reads — the token alone is not the last word.
- `URLSigner.access_revision_suffix/1` only extends the *private*
  (time-window) MAC and degrades to the old signature when the repo is not
  running, so boots and migrations keep verifying.
- `Preferences.update/3` locks the row `FOR UPDATE`, re-reads the user and
  permissions inside the transaction, requires confirmation for
  address/audience changes, and gates audience expansion with
  `can_publish?/2` (system role, host policy, or `storage.public_library`).
  Rank order private < authenticated < anonymous is enforced.
- `add_user_storage/4` re-checks ownership, permission and fresh scope inside
  the transaction on a locked row, probes every target before any write,
  and re-checks connection snapshots under `ConnectionLock` row locks before
  inserting buckets; duplicates are detected by physical destination
  (endpoint host/port, AWS commercial partition collapsed, `.com.cn` kept
  distinct), not just by credential row. Bucket cap counts the user's own
  buckets.
- `can_read_library?/2` fails closed for nil library/scope; anonymous
  visitors get `audience_allows?` only for genuinely public libraries.

## Findings

No new defects found in the reviewed paths. One note:

### NITPICK — `access_revision_suffix/1` adds a DB read per private-URL verification

Every signed-URL mint/verify of a file now joins to its library for the
revision. It is a single indexed lookup and guarded when the repo is down;
acceptable, recorded here in case private-URL traffic ever shows up in
profiles.

## Validation

Compile clean (`mix compile --warnings-as-errors`). The audience and
backup-storage integration tests (`library_audience_test.exs`,
`user_storage_creation_test.exs`, `own_storage_ui_test.exs`) need PostgreSQL,
which was in recovery mode during this review — run them once the database
is back before relying on this review alone.
