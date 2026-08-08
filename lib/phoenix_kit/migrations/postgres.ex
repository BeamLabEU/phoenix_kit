defmodule PhoenixKit.Migrations.Postgres do
  @moduledoc """
  PhoenixKit PostgreSQL Migration System

  This module handles versioned migrations for PhoenixKit, supporting incremental
  updates and rollbacks between different schema versions.

  ## Migration Versions

  ### V164 - Repair the V56/V57 flush-order bug's fallout, and converge two
  ### prefix-unsafe historical shapes ⚡ LATEST
  - Also folds in what an earlier draft carried as a separate V164: V68
    (partial `idx_publishing_posts_group_slug`) and V65 (the
    `phoenix_kit_subscription_plans_slug_uidx` -> `..._types_slug_uidx`
    rename) each issued a BARE, unqualified DROP/ALTER guarded by `IF
    EXISTS`: effective on `public`, a silent no-op in a named schema, so
    the two install paths diverged and the `V135` baseline — generated
    into a named schema — kept the unintended shape. This version
    idempotently converges both onto the historical `public`/intended
    shape, and is a no-op on every real public install. This release
    ships ONE migration, so it lives here rather than in a second version
  - V56/V57 queued `UUIDFKColumns.up/1`'s `ADD COLUMN`s immediately before
    `add_constraints/1`'s immediate `column_exists?`/NOT NULL guards with
    no `flush()` between them (V57 had none at all) — harmless on an
    incremental chain run, but on a single-shot run (fresh install) the
    guards ran before Postgres had ever seen the queued columns, so ~46
    `*_uuid` FK columns across ~33 tables were left nullable instead of
    NOT NULL, and `phoenix_kit_comments.fk_comments_user_uuid` was never
    created at all — V72 later found it missing and guessed `ON DELETE
    CASCADE` instead of V56/V57's own declared `SET NULL`
  - V56/V57 now carry the missing `flush()`, and V72's guess is now `SET
    NULL`, so this only repairs installs whose single-shot run already
    happened before those fixes; it is a no-op everywhere else
  - Per affected column: sets NOT NULL only if it currently has zero NULL
    rows; otherwise warns (table/column/row count) and leaves it
    nullable — never backfills live data with an invented value
  - Corrects `fk_comments_user_uuid` from CASCADE to SET NULL if the
    buggy shape is present
  - Repair-only: `down/1` restamps the comment, never undoes the fix

  ### V163 - UUID primary-key integrity (catalog-driven repair, upstream #688)
  - Repairs any `phoenix_kit_*` table whose `uuid` column is the wrong
    type, nullable, or not the primary key — the state V40/V56/V74 each
    assumed impossible and a production install reached anyway
    (`phoenix_kit_email_events`: `varchar(255)`, nullable, no PK at all)
  - Catalog-driven on purpose: every earlier attempt enumerated tables by
    hand and this one was missing from every list
  - Above two million rows the `ALTER COLUMN ... TYPE uuid` rewrite and the
    `ADD PRIMARY KEY` are DEFERRED and logged with the command to run in a
    maintenance window, rather than taking `ACCESS EXCLUSIVE` on a large
    table mid-deploy; `mix phoenix_kit.doctor` is the loud channel
  - Runs BEFORE V164 by construction, which is the order V164 needs: a
    foreign key cannot reference a column with no unique/primary key, so
    promoting `uuid` to PK here is what lets V164's FK repair validate
  - NOTE: upstream's own moduledoc for this version is missing — its
    heading landed above V162's body and V162's heading was lost. The
    section below is written from `v163.ex`'s own moduledoc; carry this
    correction back in the PR

  ### V162 - Payment-option linkage on billing orders

  Adds a nullable `payment_option_uuid` FK (+ index) to
  `phoenix_kit_orders`, pointing at `phoenix_kit_payment_options`. The
  order's `payment_method` is a small closed vocabulary; the payment
  OPTION is the operator-configured row the customer actually chose, and
  the choice used to be discarded at checkout. `ON DELETE SET NULL` so
  deleting an option neither fails nor destroys order history.

  ### V161 - Case-insensitive `phoenix_kit_users.username` (citext)
  - `username` was `VARCHAR(255)` (V08's `:string`) — comparison semantics
    come from the column type, not the Ecto schema field, so every lookup
    (`get_user_by_username/1`, `unsafe_validate_unique`, the unique index
    itself) was exact-match; `alice` and `Alice` could both register
  - Converts the column to `citext`, same fix already applied to `email`
    in V01 and the CRM party email columns in V151
  - Pre-check (mirrors V106's down-step) raises on any existing
    case-insensitive collision before the DDL runs, naming the offending
    value; `WHERE username IS NOT NULL` guards against nullable rows
    false-colliding under `GROUP BY`
  - `varchar` → `citext` is binary-coercible (`pg_cast.castmethod = 'b'`),
    confirmed live — no table rewrite; the column's B-tree index does get
    rebuilt (also confirmed live), which is what makes it enforce
    case-insensitive uniqueness right after the `ALTER`

  ### V160 - Settings `value` widened to TEXT
  - `phoenix_kit_settings.value` was `VARCHAR(255)` (V03's `:string`) while
    `Settings.Setting` validated it at `max: 1000` — anything in between
    passed the changeset and then raised a raw `Postgrex.Error`
  - Surfaced by list-valued settings: the sitemap's default exclude
    patterns serialize to ~450 characters, so saving them always crashed
  - Catalog-only change in PostgreSQL: no rewrite, no long lock

  ### V159 - Publishing categories + post view counters
  - `phoenix_kit_publishing_categories` — hierarchical per-group taxonomy
    (nullable `parent_uuid` self-FK, V103 catalogue shape); `slug` unique
    per group; `name_i18n` JSONB per-language display names; `position`
    for manual ordering; group delete cascades, parent delete lifts
    children to the root (`ON DELETE SET NULL`)
  - `phoenix_kit_publishing_post_categories` — post↔category M:N
    (post-level, WordPress semantics — not per-version); both sides
    cascade
  - `phoenix_kit_publishing_post_views` — per-day view rollups keyed
    `(post_uuid, view_date)`, incremented in place; totals are
    `SUM(count)`; dedup/bot filtering are app-side, no reader PII stored

  ### V158 - Broadcast attachments (accumulator)
  - Adds `attachments JSONB NOT NULL DEFAULT '[]'` to
    `phoenix_kit_newsletters_broadcasts` — an ordered list of Storage
    file uuids attached to every email of the broadcast; soft references
    (no FK) per this table's `crm_list_uuid` precedent, with a
    `jsonb_typeof = 'array'` CHECK as the DB-level shape backstop
  - Shipped in 1.7.211 — the accumulator is closed; the next restructuring
    section opens V159

  ### V157 - Image annotation kind
  - Widens `phoenix_kit_annotations_kind_check` to allow `'image'`
  - Pairs with the schema's `@kinds` (also widened) so Etcher's `:image`
    tool — exposed in the media viewer's toolbar by PR #660 — can
    actually persist; same regression shape as V130's `"marker"`

  ### V156 - Legacy newsletters lists migrated into CRM, tables dropped
  - **Requires a coordinated release with the newsletters module** — drops
    tables/columns an older newsletters release still reads; see V156's
    moduledoc warning
  - Data: every `phoenix_kit_newsletters_lists` row copied to
    `phoenix_kit_crm_lists` (same slug — reused if a CRM list already has
    it), `subscribable = true`
  - Data: a `phoenix_kit_crm_contacts` row per distinct user with a legacy
    membership (reused if one already exists by email), linked to that
    user's `user_uuid` via a straight UPDATE against `phoenix_kit_users` —
    never creates a user, `connect_user/2`'s placeholder-minting is
    structurally unreachable from this migration
  - Data: legacy memberships copied to `phoenix_kit_crm_list_members`,
    status mapped (`active`→`subscribed`, `unsubscribed`→`removed`),
    `subscribed_at`/`unsubscribed_at` preserved verbatim (not `now()`);
    `subscriber_count` recounted after
  - Re-points every `newsletters_list` broadcast still referencing a
    migrated list to `source_type = 'crm_list'` + `crm_list_uuid`; any
    broadcast an orphaned `list_uuid` couldn't be re-pointed from (should
    be none — `ON DELETE RESTRICT` guarantees referential integrity, see
    moduledoc) has that uuid preserved into
    `source_params->>'legacy_list_uuid'` first
  - Drops `fk_newsletters_broadcasts_list` + `list_uuid` column, then
    `phoenix_kit_newsletters_list_members` and `phoenix_kit_newsletters_lists`
    themselves
  - `down/1` restores the two tables (V79 shape) and the FK/column
    (nullable, matching V152) — structure only, migrated/re-pointed data
    is not moved back

  ### V155 - Delivery CRM contact id + per-broadcast dedup
  - Adds `crm_contact_uuid` (bare, nullable UUID, no FK — same soft-ref
    pattern as `crm_list_uuid`) to `phoenix_kit_newsletters_deliveries`,
    plus a plain index on it
  - Replaces `phoenix_kit_newsletters_deliveries_recipient_check` (same
    name) with a widened CHECK: still requires an addressable recipient
    (`user_uuid` or `recipient_email`), and now additionally forbids a
    row claimed by both `user_uuid` and `crm_contact_uuid` at once —
    deliberately NOT a strict XOR; see V155's moduledoc for why
  - Adds three partial unique indexes — `(broadcast_uuid, user_uuid)`,
    `(broadcast_uuid, crm_contact_uuid)`, `(broadcast_uuid,
    recipient_email)`, each `WHERE ... IS NOT NULL` — the first DB-level
    per-broadcast delivery dedup; `insert_all` previously had no
    `ON CONFLICT` guard at all
  - Adds `source_params JSONB NOT NULL DEFAULT '{}'` to
    `phoenix_kit_newsletters_broadcasts`, for the new `user_group`
    (core-role) recipient source — a role set, so JSONB rather than
    another scalar soft-ref uuid column. Shape:
    `%{"role_uuids" => [...], "role_names_snapshot" => [...]}` — uuids
    resolve (a role's name is mutable), the name snapshot is display-only

  ### V154 - OpenGraph templates + assignments (`phoenix_kit_og`)
  - Adds `phoenix_kit_og_templates` (reusable OG canvas designs; JSONB
    `canvas` element list) and `phoenix_kit_og_assignments` (binds a
    template to a `module_key × scope_type × scope_uuid` scope with a JSONB
    `slot_mapping`). Uniqueness via a partial-index pair (NULL `scope_uuid`
    is the module-wide default tier); `template_uuid` cascades on delete.
    Powers the `phoenix_kit_og` plugin.

  ### V153 - Folder header size defaults to small
  - Flips `phoenix_kit_media_folders.header_size` column default from
    'medium' (V134) to 'small', and backfills existing 'medium' rows to
    'small' ('medium' was the old default, so it reads as untouched;
    'large' is a deliberate choice and is left alone)

  ### V152 - Newsletters/CRM/Core restructuring (accumulator)
  - Unreleased — per the "one open migration" rule, every DDL step of the
    restructuring plan lands in V152 as its own section until it ships;
    later stages append here rather than opening V153.
  - Section: send profiles move to core Email. Creates
    `phoenix_kit_email_send_profiles` — same shape V145 gave
    `phoenix_kit_newsletters_send_profiles`, now owned by core's
    `PhoenixKit.Email` namespace. Copies every row across by `uuid`, then
    drops the V145 table. `idx_nl_send_profiles_*` indexes become
    `idx_email_send_profiles_*`. Does not touch
    `phoenix_kit_newsletters_broadcasts.send_profile_uuid` — still a bare
    UUID with no FK, so it points at the same row regardless of which
    table now owns it.

  ### V150 - Readable device name on session tokens
  - Adds nullable `browser` + `os` to `phoenix_kit_users_tokens`, parsed
    from the User-Agent at login, so the Active Sessions list and admin
    all-sessions view show a device name for every session without the
    known-devices/geo machinery (which stays gated behind new-login alerts).

  ### V149 - Catalogue item-supplier sourcing info + CRM xref
  - Adds `phoenix_kit_cat_item_supplier_info` (per-item, per-supplier SKU /
    unit cost / currency / lead time / MOQ; `supplier_uuid` soft ref to a
    CRM party or local `cat_supplier`) and a soft `crm_company_uuid` xref on
    `phoenix_kit_cat_suppliers`. No primary among these rows — the item's
    default supplier is the V146 `primary_supplier_uuid` scalar.

  ### V148 - CRM party roles (suppliers, clients)
  - Adds `phoenix_kit_crm_party_roles` for the `phoenix_kit_crm` module:
    polymorphic role edge marking a CRM company or contact as `supplier`,
    `client`, or other commercial role. One party can hold several roles;
    `valid_from`/`valid_to` lifecycle, `is_active` filter, role-scoped
    `metadata`. No FK on `roleable_uuid`; unique on
    `(roleable_type, roleable_uuid, role)`.

  ### V147 - Known-device geo-location
  - Adds nullable `location` (`City, Country`) to
    `phoenix_kit_user_known_devices`. Resolved once at new-device time by
    `PhoenixKit.Users.LoginAlerts` and stored so the user's Active Sessions
    list can show sign-in location without a per-render geo lookup.

  ### V146 - Catalogue item primary supplier
  - Adds nullable `primary_supplier_uuid` FK (`ON DELETE SET NULL`) +
    partial index to `phoenix_kit_cat_items` — an item's default
    supplier, independent of manufacturer (generic/unbranded materials;
    tie-break when a manufacturer has several suppliers). Backs the
    `phoenix_kit_catalogue` feature from its commit 2e47cdf.

  ### V145 - Newsletters Send Settings (send profiles)
  - Adds `phoenix_kit_newsletters_send_profiles`: named send configurations
    referencing a core Integrations connection (`integration_uuid`, no FK)
    plus per-account send parameters (from-name/email, reply-to, signature,
    rate limits, `advanced` per-provider extras jsonb).
  - Multiple profiles may share one integration; at most one may be
    `is_default`, enforced by a partial unique index on `is_default`.
  - Adds `send_profile_uuid` (bare UUID, no FK) to
    `phoenix_kit_newsletters_broadcasts` so a broadcast can pin which send
    profile delivers it.

  ### V144 - Manufacturing/Warehouse module tables consolidation
  - Consolidates 5 objects previously created by `phoenix_kit_manufacturing`'s
    and `phoenix_kit_warehouse`'s own `migration_module/0` into core's
    migration chain: `phoenix_kit_machines`, `phoenix_kit_machine_type_assignments`,
    `phoenix_kit_machine_operations`, `phoenix_kit_warehouse_transfers`
    (+ its `number` sequence), and `phoenix_kit_warehouse_min_stock`.
  - `machine_type_uuid`/`operation_uuid` on the two join tables are soft
    references (no FK) to the entities package. Upgrade path for hosts on
    the published `phoenix_kit_manufacturing` 0.2.0 (module V1): the join
    table already exists there with a *live* FK on `machine_type_uuid` —
    this migration drops it unconditionally. Warehouse tables are
    fresh-install-only DDL (`phoenix_kit_warehouse` 0.1.0 never published
    migrations for them, so no upgrade case exists).
  - The pre-V5 manufacturing directory tables (`phoenix_kit_machine_types`,
    `phoenix_kit_operations`, `phoenix_kit_defect_reasons`) are not
    re-created; each is dropped only if present and empty, left in place
    with a database `NOTICE` when non-empty — see the PR body for the
    manual data-migration note on such hosts.
  - Rollback mirrors the five creates; see `V144.down/1`'s moduledoc for
    the upgrade-host caveat (can't distinguish a pre-existing
    `machine_type_assignments` table from one V144 created).

  ### V143 - Known-device history for new-login alerts
  - Adds `phoenix_kit_user_known_devices` (IP + hashed user-agent per user,
    unique per `(user_uuid, ip_address, user_agent_hash)`) so a login from
    an unrecognized device can be told apart from a familiar one.
  - Backs the `new_login_alert_enabled` setting and
    `user.new_login_detected` activity action.

  ### V142 - Wider role-permission keys
  - Widens `phoenix_kit_role_permissions.module_key` from `VARCHAR(50)` to
    `VARCHAR(120)` so fine-grained sub-permissions can be stored as composed
    dotted keys (`"calendar.view_others"` — base and sub parts are each
    capped at 50 chars, so a composed key can reach 101).
  - Rollback deletes rows over 50 chars (sub-permission grants are additive
    and re-grantable) before narrowing the column back.

  ### V141 - Calendar events + participants
  - Adds `phoenix_kit_calendar_events` for the `phoenix_kit_calendar` module:
    one implicit personal calendar per user (`owner_uuid` FK, CASCADE on user
    delete). Timed events use an exclusive-end UTC pair; all-day events use an
    exclusive-end DATE pair; a CHECK enforces exactly one pair per row matching
    the `all_day` flag, with end > start. Status is active/cancelled.
    `location_uuid` loosely links a stored location (name snapshotted into the
    `location` string — no cross-module FK).
  - Adds `phoenix_kit_calendar_event_participants`: loose `kind` + `target_uuid`
    references (user / staff_person / crm_contact / crm_company / free_text)
    with a `display_name` snapshot and `added_by_uuid` audit. Visibility is
    resolved LIVE at query time against the physical staff/CRM tables, so a
    company participant means "current members" and no module code is needed.
    Partial uniques dedup targets per event and free-text case-insensitively.
  - Extended in place while unreleased (idempotent-additive statements).
  - Rollback drops both tables.

  ### V140 - Warehouse module tables
  - Creates `phoenix_kit_warehouse_stock`, `phoenix_kit_warehouse_inventory_documents`,
    `phoenix_kit_warehouse_internal_orders`, `phoenix_kit_warehouse_supplier_orders`,
    `phoenix_kit_warehouse_goods_receipts`, and `phoenix_kit_warehouse_goods_issues` —
    the storage layer for the standalone `phoenix_kit_warehouse` package.
  - `internal_orders` and `goods_issues` have no FK to any order table — the
    relationship lives in a generic `source_refs` JSONB column instead, resolved
    by a host-registered callback so the package has zero dependency on any
    particular "order" concept. GIN-indexed for reverse lookups.
  - Intra-module FKs preserved: `supplier_orders.internal_order_uuid` →
    `internal_orders`; `goods_receipts.supplier_order_uuid` → `supplier_orders`;
    `goods_issues.internal_order_uuid` → `internal_orders`.
  - `item_uuid`, `location_uuid`, `storage_folder_uuid`, `supplier_uuid` are
    plain UUID columns — no FK, so the database does not enforce referential
    integrity for them (delete semantics still undecided).
  - No data is copied from any existing table — these tables are empty until a
    consuming app populates them.

  ### V139 - Dashboard `config` column
  - Adds a JSONB `config` column (`NOT NULL DEFAULT '{}'`) to
    `phoenix_kit_dashboards` for per-dashboard presentation settings, read and
    written whole like `layout`. Backs the dashboards plugin module.
  - Idempotent (`ADD COLUMN IF NOT EXISTS`); rollback drops the column.

  ### V138 - CRM v1 interaction tracker
  - Adds five `phoenix_kit_crm_*` tables for the CRM module's first data model:
    `contacts` (profile + **optional** `user_uuid` login link, partial-unique so
    it's 1:1 only among linked rows), `companies`, `company_memberships` (M:N
    contact↔company with free-form `role_in_company` + `department` + `is_primary`
    on the edge), `interactions` (logged interaction: type/when/body/subject
    contact/owner user), and `interaction_parties` (flat resolvable "who was
    involved": `raw_name` always kept, `contact_uuid`/`staff_person_uuid` resolve
    when matched under an exclusive-arc CHECK, `party_snapshot` JSONB freezes the
    party's profile as-of-then). `staff_person_uuid` is a soft ref (no FK) so the
    optional staff module stays optional.

  ### V136 - Staff employment history
  - Adds `phoenix_kit_staff_employments` — a per-person history of employment
    spans (employment type, translatable `job_title`, org placement via
    `primary_department_uuid` + a `primary_team_uuid` snapshot, date range with
    `employment_end_date IS NULL` = the open/current span, `work_location`,
    `notes`). A partial unique index enforces one open span per person. The
    matching `phoenix_kit_staff_people` columns are kept as a denormalized mirror
    of the current span (written by the app's `sync_current/1`), not dropped.
    Backfills one open span per existing person from those columns (guarded,
    retry-safe; people with no employment data are skipped).

  ### V135 - Structured staff skills
  - Replaces the free-text `phoenix_kit_staff_people.skills` column with a
    first-class translatable `phoenix_kit_staff_skills` entity + a
    `phoenix_kit_staff_person_skills` join. Each skill carries its own
    per-skill, translatable proficiency levels (`levels` JSONB array of
    `{id, name, translations}`) and an `allow_multiple_levels` boolean; the
    join's `proficiency_levels` JSONB array holds the selected level ids.
    Migrates the comma-separated free-text into structured rows (case-insensitive
    dedup, guarded for retry-safety) and drops the column. Lossy by design:
    per-locale `translations["skills"]` overrides don't map to structured skills
    and are stripped. Also adds a partial index on
    `phoenix_kit_staff_people(date_of_birth)` (active + non-null DOB only) for
    `Staff.upcoming_birthdays/1`.

  ### V01 - V134 - Baseline (consolidated into V135 by the squash)

  Every version from V01 (initial auth/roles/settings foundation) through
  V134 (media-folder header customization) has been collapsed into the
  `V135` baseline module — this release's `@initial_version` (the squash
  floor; spec `dev_docs/plans/2026-07-14-squash-migrations-spec.md`).
  `V135.up/1` applies the FINAL post-V134 shape of every table, index,
  constraint, function, extension, and seed directly — no intermediate
  drops/renames/backfills are replayed. See
  `dev_docs/plans/2026-07-14-squash-inventory.md` for the full
  per-version history this consolidates (seeds, drops/renames, hazards)
  and `PhoenixKit.Migrations.ExpectedSchema`
  (`lib/phoenix_kit/migrations/expected_schema.ex`, tool-generated,
  `@moduledoc false`) for the machine-readable manifest the baseline was
  generated from.

  Installs below V135 cannot upgrade directly to this release --
  `up/1`/`down/1` raise `PhoenixKit.Migrations.BelowFloorError` — they
  must first apply the frozen pre-squash 1.7.x bridge release up to at
  least V135, then move to this release (spec §7.2's two-stage rollout /
  §5.2's registry guards).

  ## Migration Paths

  ### Fresh Installation (0 -> Current)
  Applies the `V135` baseline (the consolidated V01..V134 shape), then
  every delta V136..V164 in sequence (`plan_up/3`'s fresh-install clamp,
  spec §5.2 D13).

  ### Incremental Updates
  - Below V135: rejected with `PhoenixKit.Migrations.BelowFloorError` --
    apply the 1.7.x bridge release first (spec §7.2).
  - At V135 (the floor) or above: runs each delta module from
    `current + 1` through the target version in sequence.

  ### Rollback Support
  - Down to any version above V135: runs each delta module's `down/1` in
    reverse, from `current` down to `target + 1`.
  - Down to V135 or below: the delta range stops at V136 (never
    dispatches a deleted below-floor module); `V135.down/1` is then
    applied directly for a full `version: 0` teardown (Oban included). A
    target strictly between 0 and V135 clamps to V135 instead of
    guessing an unreproducible intermediate shape (spec §5.2's
    `{:clamped, ...}`).

  ## Usage Examples

      # Update to the latest version
      PhoenixKit.Migrations.Postgres.up(prefix: "myapp")

      # Update to a specific version
      PhoenixKit.Migrations.Postgres.up(prefix: "myapp", version: 150)

      # Rollback to a specific version
      PhoenixKit.Migrations.Postgres.down(prefix: "myapp", version: 149)

      # Complete rollback (tears down the V135 baseline too)
      PhoenixKit.Migrations.Postgres.down(prefix: "myapp", version: 0)

  ## PostgreSQL Features
  - Schema prefix support for multi-tenant applications
  - Optimized indexes for performance
  - Foreign key constraints with proper cascading
  - Extension support (citext)
  - Version tracking with table comments
  """

  @behaviour PhoenixKit.Migration

  use Ecto.Migration

  alias PhoenixKit.Migrations.BelowFloorError
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Repair.Environment

  @initial_version 135
  @current_version 164
  @default_prefix "public"

  # First version whose SQL referenced uuid_generate_v7() in the
  # pre-squash chain — V40/V56/V61/V63 were its historical
  # creation/repair sites, now folded into the V135 baseline's single
  # `Helpers.ensure_uuid_v7_function/1` call. Kept as the `:run_delta`
  # guard's threshold: every reachable `initial` is now either 0
  # (fresh install, handled by the baseline directly) or >= the floor
  # (135, itself >= 40), so this re-ensure fires on every delta
  # upgrade as pure defense-in-depth.
  @uuid_fn_version 40

  @doc false
  def initial_version, do: @initial_version

  @doc false
  def current_version, do: @current_version

  @impl PhoenixKit.Migration
  def up(opts) do
    opts = with_defaults(opts, @current_version)
    acquire_chain_lock!()
    initial = migrated_version(opts)

    case plan_up(initial, opts.version, @initial_version) do
      {:raise, db_version, floor} ->
        raise BelowFloorError, db_version: db_version, floor: floor, context: :up

      {:run, range} ->
        change(range, :up, opts)

      {:run_delta, range} ->
        if initial >= @uuid_fn_version, do: Helpers.ensure_uuid_v7_function(opts.prefix)
        change(range, :up, opts)

      :noop ->
        :ok
    end
  end

  @impl PhoenixKit.Migration
  def down(opts) do
    # For down operations, don't set a default version - let target_version logic handle it
    opts = Enum.into(opts, %{prefix: @default_prefix})

    Helpers.validate_prefix!(opts.prefix)

    opts =
      opts
      |> Map.put(:quoted_prefix, inspect(opts.prefix))
      |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
      |> Map.put_new(:create_schema, opts.prefix != @default_prefix)

    acquire_chain_lock!()

    current_version = migrated_version(opts)

    # Determine target version:
    # - If version not specified, rollback to complete removal (0)
    # - If version specified, rollback to that version
    target_version = Map.get(opts, :version, 0)

    case plan_down(current_version, target_version, @initial_version) do
      {:raise, db_version, floor} ->
        raise BelowFloorError, db_version: db_version, floor: floor, context: :down

      {:teardown, range, floor} ->
        # `range` (current..(floor+1)//-1) never includes `floor` itself — a
        # Range spanning down to/past the floor would, once versions below a
        # RAISED floor are deleted from the codebase, dispatch to modules
        # that no longer exist (GLM M3). The floor's own down/1 is applied
        # as an explicit list element instead of a computed range endpoint.
        # Folded into ONE `change/3` call (not two) so the progress
        # header/bar spans the whole teardown exactly as before this
        # split existed — `change/3` only ever consumes its first argument
        # via `Enum.to_list/1`, so a plain list works identically to a
        # Range. At `@initial_version == 1` this list is byte-for-byte the
        # same `[current, current - 1, ..., 1]` the old single range
        # produced (see `PostgresBelowFloorTest` "down/1 teardown
        # degenerates to today's single-range semantics at floor 1").
        change(Enum.to_list(range) ++ [floor], :down, opts)

      {:clamped, range, floor} ->
        IO.warn(
          "PhoenixKit down/1: target version #{target_version} is below this release's " <>
            "floor (V#{floor}) — clamping to V#{floor}. Below-floor PhoenixKit state cannot " <>
            "be rolled back through this release (the migration bridge is required for " <>
            "that). This is a recorded no-op: the calling migration's own schema_migrations " <>
            "row is marked rolled back, but PhoenixKit's own version comment stays at V#{floor}."
        )

        change(range, :down, opts)

      {:run, range} ->
        change(range, :down, opts)

      :noop ->
        :ok
    end
  end

  @typedoc "Routing decision `up/1` acts on — pure, see `plan_up/3`."
  @type up_plan ::
          {:raise, db_version :: pos_integer(), floor :: pos_integer()}
          | {:run, Range.t()}
          | {:run_delta, Range.t()}
          | :noop

  # Pure routing decision for `up/1`, spec §5.2. Takes the DB's currently
  # migrated version, the requested target, and the floor to check against —
  # no DB access, no module attribute reads — so it is unit-testable at ANY
  # floor, not just whatever `@initial_version` currently compiles to.
  #
  #   * `initial > 0 and initial < initial_version` — below-floor install;
  #     this release's chain cannot replay it. `{:raise, initial,
  #     initial_version}`.
  #   * `initial == 0` — fresh install; clamps the target up to at least the
  #     floor (D13 — covers both a pinned below-floor wrapper doing
  #     `up(version: 27)` under a higher floor, and a pathological
  #     `version: 0`/negative pin). `{:run, initial_version..max(target,
  #     initial_version)}`.
  #   * `initial < target` — ordinary delta upgrade. `{:run_delta,
  #     (initial + 1)..target}` (the `_delta` tag tells `up/1` to also run
  #     the uuid-function re-ensure, same as today).
  #   * else `:noop` — already at or past target.
  @doc false
  @spec plan_up(
          initial :: non_neg_integer(),
          target :: integer(),
          initial_version :: pos_integer()
        ) :: up_plan()
  def plan_up(initial, target, initial_version) do
    cond do
      initial > 0 and initial < initial_version ->
        {:raise, initial, initial_version}

      initial == 0 ->
        {:run, initial_version..max(target, initial_version)}

      initial < target ->
        {:run_delta, (initial + 1)..target}

      true ->
        :noop
    end
  end

  @typedoc "Routing decision `down/1` acts on — pure, see `plan_down/3`."
  @type down_plan ::
          {:raise, db_version :: pos_integer(), floor :: pos_integer()}
          | {:teardown, Range.t(), floor :: pos_integer()}
          | {:clamped, Range.t(), floor :: pos_integer()}
          | {:run, Range.t()}
          | :noop

  # Pure routing decision for `down/1`, spec §5.2. Same DB-free/floor-free
  # shape as `plan_up/3` — see its comment.
  #
  #   * `current > 0 and current < initial_version` — below-floor install;
  #     cannot be rolled back through this release either (a below-floor
  #     install has no `up/1` path INTO this release to roll back from in
  #     the first place — reachable only if the comment regressed under it
  #     by some other means). `{:raise, current, initial_version}`.
  #   * `current <= target` — already at or below target; no-op (matches
  #     the pre-existing `if current_version > target_version` guard).
  #   * `target == 0` — full teardown. `{:teardown,
  #     current..(initial_version + 1)//-1, initial_version}` — the range
  #     stops one above the floor; `down/1` applies the floor module
  #     directly for the last step (see its own comment for why).
  #   * `0 < target < initial_version` — target requests a below-floor
  #     shape this release can't produce; clamps to the floor instead of
  #     guessing. `{:clamped, current..(initial_version + 1)//-1,
  #     initial_version}` (was dormant while `initial_version` was 1 — no
  #     integer satisfies `0 < target < 1`; LIVE since the squash raised the
  #     floor to 135).
  #   * else — ordinary partial rollback, unchanged. `{:run,
  #     current..(target + 1)//-1}`.
  #
  # A negative `target` falls through to the last branch, matching today's
  # (pre-existing, unguarded) behavior — out of scope for this pass, which
  # only wires the three branches spec §5.2 names.
  @doc false
  @spec plan_down(
          current :: non_neg_integer(),
          target :: integer(),
          initial_version :: pos_integer()
        ) :: down_plan()
  def plan_down(current, target, initial_version) do
    cond do
      current > 0 and current < initial_version ->
        {:raise, current, initial_version}

      current <= target ->
        :noop

      # `<= 0`, not `== 0`: a negative target used to fall through to the
      # `{:run, current..(target + 1)//-1}` clause below, which drops every
      # table via the baseline's `down/1` and then dispatches V134..V1 —
      # modules the squash deleted — raising `UndefinedFunctionError` on an
      # install it had just destroyed. Pre-squash those modules existed and the
      # run merely completed a full rollback, so the blast radius is new (Kimi
      # review, 2026-08-08). Any target at or below zero means "remove
      # everything", which is exactly the teardown path.
      target <= 0 ->
        {:teardown, current..(initial_version + 1)//-1, initial_version}

      target > 0 and target < initial_version ->
        {:clamped, current..(initial_version + 1)//-1, initial_version}

      true ->
        {:run, current..(target + 1)//-1}
    end
  end

  # Read-path twin of `parse_version_comment!/2`: reports rather than raises.
  defp parse_version_comment_leniently(version, prefix) do
    String.to_integer(String.trim(version))
  rescue
    ArgumentError ->
      IO.warn(
        "PhoenixKit: #{prefix}.phoenix_kit's version comment is #{inspect(version)}, which " <>
          "is not a version number — reporting 0. `mix phoenix_kit.update` will REFUSE this " <>
          "database until it is restamped; `mix phoenix_kit.doctor` reports the real state."
      )

      0
  end

  # `String.to_integer/1` raises a bare ArgumentError naming nothing useful when
  # the comment was edited by hand ('v164', 'final', ' 164'). Same advice as the
  # missing-comment path: this value decides which migrations run, so guessing is
  # never the answer (Kimi review, 2026-08-08).
  defp parse_version_comment!(version, opts) do
    String.to_integer(String.trim(version))
  rescue
    ArgumentError ->
      reraise(
        """
        PhoenixKit: #{opts.prefix}.phoenix_kit's version comment is #{inspect(version)}, \
        which is not a version number. It decides which migrations run, so it cannot be \
        guessed. Establish the real state with `mix phoenix_kit.doctor` and restamp it:

            COMMENT ON TABLE #{opts.prefix}.phoenix_kit IS '<version>';
        """,
        __STACKTRACE__
      )
  end

  @impl PhoenixKit.Migration
  def migrated_version(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    # First check if phoenix_kit table exists
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo().query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, check for version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo().query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) ->
            parse_version_comment!(version, opts)

          _ ->
            raise """
            PhoenixKit: #{opts.prefix}.phoenix_kit exists but carries no version comment.

            The comment is the only record of which migrations this database has. \
            Pre-squash a missing comment was read as "V01 legacy" and the chain simply \
            replayed from the start; this release cannot do that — below-floor versions \
            no longer exist here, so the guess would route a possibly CURRENT database to \
            the 1.7.x bridge, whose backfill overwrites still-NULL tracked columns with \
            freshly generated uuids pointing at nothing.

            Establish the real state and restamp the comment by hand:

                mix phoenix_kit.doctor       # reports schema-vs-comment discrepancies
                COMMENT ON TABLE #{opts.prefix}.phoenix_kit IS '<version>';
            """
        end

      {:ok, %{rows: [[false]]}} ->
        # Table doesn't exist - no PhoenixKit installed
        0

      _ ->
        0
    end
  end

  @doc """
  Get current migrated version from database in runtime context (outside migrations).

  This function can be called from Mix tasks and other non-migration contexts.
  """
  def migrated_version_runtime(opts) do
    opts = with_defaults(opts, @initial_version)
    escaped_prefix = Map.fetch!(opts, :escaped_prefix)

    # Add retry logic for better reliability
    retry_version_detection(opts, escaped_prefix, 3)
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed") — that misleads the operator AND
    # lets the unvalidated string reach interpolated SQL in callers'
    # fallback paths.
    e in ArgumentError ->
      reraise e, __STACKTRACE__

    _ ->
      0
  end

  # Retry version detection with exponential backoff
  defp retry_version_detection(opts, escaped_prefix, retries_left) when retries_left > 0 do
    # Use hybrid repo detection with fallback strategies
    case get_repo_with_fallback() do
      nil when retries_left > 1 ->
        # Wait a bit and retry
        Process.sleep(100)
        retry_version_detection(opts, escaped_prefix, retries_left - 1)

      nil ->
        0

      repo ->
        # Ensure repo is started before querying database
        case ensure_repo_started(repo) do
          :ok ->
            case check_version_with_runtime_repo(repo, escaped_prefix) do
              0 when retries_left > 1 ->
                # If we get 0 but repo is available, retry once more
                Process.sleep(50)
                check_version_with_runtime_repo(repo, escaped_prefix)

              version ->
                version
            end

          {:error, _reason} when retries_left > 1 ->
            # If repo can't be started, wait and retry
            Process.sleep(100)
            retry_version_detection(opts, escaped_prefix, retries_left - 1)

          {:error, _reason} ->
            # Final retry failed - return 0 (not installed)
            0
        end
    end
  rescue
    _ ->
      if retries_left > 1 do
        Process.sleep(100)
        retry_version_detection(opts, escaped_prefix, retries_left - 1)
      else
        0
      end
  end

  defp retry_version_detection(_opts, _escaped_prefix, 0), do: 0

  # Check version using runtime repo (same logic as migrated_version)
  defp check_version_with_runtime_repo(repo, escaped_prefix) do
    # First check if phoenix_kit table exists
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        # Table exists, check for version comment
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        # Deliberately NOT the raising behaviour `migrated_version/1` now has for
        # the same two cases. This twin is the READ path — `phoenix_kit.status`,
        # the doctor, the admin UI — and an anomalous comment must not take the
        # interface down; only the MIGRATOR must refuse, because only it acts on
        # the value destructively. So the legacy guess stays, but stops being
        # silent (Kimi review, 2026-08-08).
        case repo.query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) ->
            parse_version_comment_leniently(version, escaped_prefix)

          _ ->
            IO.warn(
              "PhoenixKit: #{escaped_prefix}.phoenix_kit exists but carries no version comment — " <>
                "reporting V01 (legacy) for display purposes. `mix phoenix_kit.update` will " <>
                "REFUSE this database until the comment is restamped; run " <>
                "`mix phoenix_kit.doctor` to establish the real state."
            )

            1
        end

      {:ok, %{rows: [[false]]}} ->
        # Table doesn't exist - no PhoenixKit installed
        0

      _ ->
        0
    end
  end

  @doc """
  Heal version comment if schema artifacts exist for a higher version.

  V83 had a bug where the COMMENT ON TABLE statement used an incorrect prefix,
  leaving the comment at the previous version even though the migration ran
  successfully. This function detects and corrects the mismatch.

  Returns `{:healed, new_version}` if the comment was fixed, or `:ok` if
  no healing was needed.
  """
  def heal_version_comment(reported_version, opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, opts[:prefix] || "public")
    # Local guard (defense in depth) — current callers pre-validate, but
    # this function interpolates the prefix into DDL and must not rely
    # on every future caller doing so.
    Helpers.validate_prefix!(escaped_prefix)
    prefix_str = if escaped_prefix != "public", do: "#{escaped_prefix}.", else: ""

    case get_repo_with_fallback() do
      nil ->
        :ok

      repo ->
        healed =
          version_checks()
          |> Enum.filter(fn {v, _query} -> v > reported_version and v <= @current_version end)
          |> Enum.sort_by(fn {v, _} -> v end)
          |> Enum.reduce(reported_version, fn {v, check_query_fn}, acc ->
            query = check_query_fn.(escaped_prefix, prefix_str)

            case repo.query(query, [], log: false) do
              {:ok, %{rows: [[true]]}} -> v
              _ -> acc
            end
          end)

        if healed > reported_version do
          comment_query =
            "COMMENT ON TABLE #{prefix_str}phoenix_kit IS '#{healed}'"

          repo.query(comment_query, [], log: false)
          {:healed, healed}
        else
          :ok
        end
    end
  rescue
    _ -> :ok
  end

  # Schema artifact checks for versions that may have had comment bugs.
  # Each entry is {version, fn(escaped_prefix, prefix_str) -> verification_query}.
  #
  # Empty since the squash (floor 135): the only entry this ever held (V83's
  # comment-prefix bug) belonged to a version now folded into the V135
  # baseline — below this release's floor, so it can never again be the
  # `reported_version` a below-floor-but-schema-ahead DB needs healed past.
  # The mechanism itself stays: a future version with the same class of bug
  # adds its own `{version, check_fn}` entry here.
  defp version_checks do
    []
  end

  defp change(range, direction, opts) do
    range_list = Enum.to_list(range)
    total_steps = length(range_list)

    show_migration_header(range_list, direction, total_steps)
    execute_migration_steps(range_list, direction, opts, total_steps)
    show_completion_message(total_steps)
    handle_version_recording(direction, range, opts, total_steps)
  end

  # Show migration progress header for multi-step migrations
  defp show_migration_header(range_list, direction, total_steps) do
    if total_steps > 1 do
      {start_version, end_version} =
        case direction do
          :up -> {Enum.min(range_list), Enum.max(range_list)}
          :down -> {Enum.max(range_list), Enum.min(range_list)}
        end

      action = if direction == :up, do: "Applying", else: "Rolling back"

      IO.puts(
        "🔄 #{action} PhoenixKit V#{String.pad_leading(to_string(start_version), 2, "0")}→V#{String.pad_leading(to_string(end_version), 2, "0")}"
      )
    end
  end

  # Execute migration steps with progress tracking
  defp execute_migration_steps(range_list, direction, opts, total_steps) do
    range_list
    |> Enum.with_index()
    |> Enum.each(fn {index, step_index} ->
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      # Show progress bar for multi-step migrations
      if total_steps > 1 do
        show_migration_progress(step_index + 1, total_steps, "V#{pad_idx}")
      end

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end)
  end

  # Show completion message for multi-step migrations
  defp show_completion_message(total_steps) do
    if total_steps > 1 do
      IO.puts("✅ PhoenixKit migration complete\n")
    end
  end

  # Handle version recording based on direction
  defp handle_version_recording(direction, range, opts, total_steps) do
    case direction do
      :up ->
        # For up migrations, only set final version comment for multi-step migrations
        # Individual migrations handle their own version comments for single steps
        if total_steps > 1 do
          record_version(opts, Enum.max(range))
        end

      :down ->
        # For down migrations, let individual migration handle version comments
        # This prevents conflicts with version comments in migration down() functions
        :ok
    end
  end

  # Show migration progress bar
  defp show_migration_progress(current_step, total_steps, version_info) do
    percentage = div(current_step * 100, total_steps)
    progress_width = 20
    filled_width = div(current_step * progress_width, total_steps)
    empty_width = progress_width - filled_width

    filled_bar = String.duplicate("█", filled_width)
    empty_bar = String.duplicate("▒", empty_width)

    progress_bar = "#{filled_bar}#{empty_bar}"

    # Use carriage return to update the same line
    IO.write(
      "\r#{progress_bar} #{percentage}% (#{current_step}/#{total_steps} migrations) #{version_info}"
    )

    # Add newline after the last step
    if current_step == total_steps do
      IO.puts("")
    end
  end

  # Same key `PhoenixKit.Migrations.Repair` locks on (spec §6.1). Read what it
  # does and does not buy before relying on it:
  #
  #   * A chain run that starts while a repair already holds the lock WAITS
  #     here until that repair finishes (bounded, see below). That direction is
  #     real exclusion, on the install path and the update path alike — the
  #     acquire itself contends even when the lock cannot then be HELD.
  #     Deliberately taken before the version read, so it also covers a run
  #     that turns out to be a no-op: one statement, and if a repair really is
  #     running, waiting for it is the correct answer rather than reading a
  #     comment it is in the middle of changing.
  #   * A repair that starts while a chain run is mid-DDL is NOT blocked. The
  #     wrappers this chain runs under are generated with
  #     `@disable_ddl_transaction true` (`mix phoenix_kit.update`,
  #     `phoenix_kit.gen.migration`), so there is no enclosing transaction and
  #     this statement auto-commits — the lock is released before the DDL that
  #     follows it. Repair's before/after version-comment re-read
  #     (`Repair.CommentPolicy.concurrent_migration?/2`, S18) is what catches
  #     that direction, by detection rather than prevention.
  #
  # Transaction-scoped anyway, and deliberately not repair's session-scoped
  # form: a session lock taken here would survive a raising migration and ride
  # the connection back into the pool, where nothing ever unlocks it and every
  # later repair on that key blocks forever. Releasing it by hand is not
  # sufficient either — `execute/1` only QUEUES DDL, so an unlock at the end of
  # `up/1` would fire before the queued statements are flushed. Making the
  # remaining direction real needs a design change, not a bigger lock.
  # `pg_try_...` in a bounded loop, never the blocking `pg_advisory_xact_lock`:
  # `Ecto.Migrator` runs migrations with `timeout: :infinity`, so the blocking
  # form turns a held lock into a silent, unbounded hang with nothing printed
  # (Opus review 2026-08-07). Waiting is still the right behaviour — a repair
  # mid-flight is exactly what this lock is for — but it has to be visible and
  # it has to end.
  @chain_lock_attempts 300
  @chain_lock_sleep_ms 1_000

  defp acquire_chain_lock!(attempts_left \\ @chain_lock_attempts) do
    %{rows: [[acquired?]]} =
      repo().query!(
        "SELECT pg_try_advisory_xact_lock($1)",
        [Environment.lock_key()],
        log: false
      )

    cond do
      acquired? ->
        :ok

      attempts_left > 1 ->
        maybe_announce_lock_wait(attempts_left)
        Process.sleep(@chain_lock_sleep_ms)
        acquire_chain_lock!(attempts_left - 1)

      true ->
        raise """
        PhoenixKit: could not start the migration chain — another process has held the \
        PhoenixKit migration/repair advisory lock (key #{Environment.lock_key()}) for over \
        #{div(@chain_lock_attempts * @chain_lock_sleep_ms, 1000)} seconds.

        This is normally a `mix phoenix_kit.repair` still running against the same database. \
        Wait for it to finish and re-run; the chain is idempotent. If nothing is running, an \
        earlier crashed process may hold it — find the holder with:

            SELECT pid, query FROM pg_locks l JOIN pg_stat_activity a USING (pid)
            WHERE l.locktype = 'advisory';
        """
    end
  end

  defp maybe_announce_lock_wait(attempts_left) do
    if attempts_left == @chain_lock_attempts or rem(attempts_left, 30) == 0 do
      IO.puts(
        :stderr,
        "PhoenixKit: waiting for a concurrent PhoenixKit repair/migration to release the " <>
          "migration lock before continuing..."
      )
    end
  end

  defp record_version(_opts, 0) do
    # Handle rollback to version 0 - tables are dropped, so we can't update comment
    # This is expected behavior for complete rollback
    :ok
  end

  defp record_version(%{prefix: prefix}, version) do
    # Use execute for migration context - only once per migration cycle
    execute "COMMENT ON TABLE #{prefix}.phoenix_kit IS '#{version}'"
  end

  # Get the application that owns the repo module

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    Helpers.validate_prefix!(opts.prefix)

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
    |> Map.put_new(:create_schema, opts.prefix != @default_prefix)
  end

  # Hybrid repo detection with fallback strategies (shared with status command)
  defp get_repo_with_fallback do
    # Strategy 1: Try to get from PhoenixKit application config
    case PhoenixKit.Config.get_repo() do
      nil ->
        # Strategy 2: Try to ensure PhoenixKit application is started
        case ensure_phoenix_kit_started() do
          repo when not is_nil(repo) ->
            repo

          nil ->
            # Strategy 3: Auto-detect from project configuration
            detect_repo_from_project()
        end

      repo ->
        repo
    end
  end

  # Try to start PhoenixKit application and get repo config
  defp ensure_phoenix_kit_started do
    Application.ensure_all_started(:phoenix_kit)
    PhoenixKit.Config.get_repo()
  rescue
    _ -> nil
  end

  # Auto-detect repository from project configuration
  defp detect_repo_from_project do
    parent_app_name = Mix.Project.config()[:app]

    # Try :ecto_repos config first
    case try_ecto_repos_config(parent_app_name) do
      nil -> try_naming_patterns(parent_app_name)
      repo -> repo
    end
  end

  # Try to get repo from :ecto_repos application config
  defp try_ecto_repos_config(nil), do: nil

  defp try_ecto_repos_config(app_name) do
    case Application.get_env(app_name, :ecto_repos, []) do
      [repo | _] when is_atom(repo) ->
        if ensure_repo_loaded?(repo), do: repo, else: nil

      [] ->
        nil
    end
  rescue
    _ -> nil
  end

  # Try common naming patterns
  defp try_naming_patterns(nil), do: nil

  defp try_naming_patterns(app_name) do
    # Try most common pattern: AppName.Repo
    repo_module = Module.concat([Macro.camelize(to_string(app_name)), "Repo"])

    if ensure_repo_loaded?(repo_module) do
      repo_module
    else
      nil
    end
  end

  # Check if repo module exists and is loaded
  defp ensure_repo_loaded?(repo) when is_atom(repo) and not is_nil(repo) do
    Code.ensure_loaded?(repo) && function_exported?(repo, :__adapter__, 0)
  rescue
    _ -> false
  end

  defp ensure_repo_loaded?(_), do: false

  # Ensure repo is properly started for database operations.
  # In --no-start context, Repo process may not be running yet.
  defp ensure_repo_started(repo) do
    if Process.whereis(repo) != nil do
      :ok
    else
      start_repo_with_config(repo)
    end
  rescue
    error -> {:error, "Failed to start repo: #{inspect(error)}"}
  end

  defp start_repo_with_config(repo) do
    # Try Mix.Ecto.ensure_repo first (handles config resolution)
    if Code.ensure_loaded?(Mix.Ecto) do
      Mix.Ecto.ensure_repo(repo, [])

      # ensure_repo loads but doesn't start — start the process
      if Process.whereis(repo) == nil do
        do_start_repo(repo)
      else
        :ok
      end
    else
      do_start_repo(repo)
    end
  end

  defp do_start_repo(repo) do
    # Get config from parent app's application env
    app =
      if Code.ensure_loaded?(Mix) and function_exported?(Mix.Project, :config, 0),
        do: Mix.Project.config()[:app]

    config = if app, do: Application.get_env(app, repo, []), else: []

    # Ensure required applications are started before starting repo
    # These must be started for repo.start_link/1 to work:
    # - :telemetry (for DBConnection metrics)
    # - :db_connection (provides DBConnection.Watcher)
    # - :ecto (provides Ecto.Repo.Registry)
    # - :postgrex (provides Postgrex.SCRAM.LockedCache)
    Application.ensure_all_started(:telemetry)
    Application.ensure_all_started(:db_connection)
    Application.ensure_all_started(:ecto)
    Application.ensure_all_started(:postgrex)

    case repo.start_link(config) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, "Failed to start #{inspect(repo)}: #{inspect(reason)}"}
    end
  end
end
