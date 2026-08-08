# generate_baseline.exs — ExpectedSchema manifest + baseline-slice generator.
#
# Spec: dev_docs/plans/2026-07-14-squash-migrations-spec.md, sections 5.1 (manifest shape),
# 8.3 bullet 1 (this tool), 3.7 (bimodal end-states), 4 (floor parameterization).
# Inventory: dev_docs/plans/2026-07-14-squash-inventory.md (Drops section feeds the
# refuse-to-emit guard).
#
# Pipeline (full run, [DB]):
#
#   1. Run the OLD chain version-by-version (separate Ecto.Migrator invocations via
#      MigrationRunner.run_chain_stepwise/5) into a scratch schema, taking a structural
#      catalog snapshot after EVERY version (tables, columns with type/typmod/nullability/
#      default, indexes via pg_index, constraints via pg_constraint, sequences, functions,
#      seed rows). Consecutive-snapshot diffs yield `since` (introducing version),
#      `revisions` (one entry per observed alteration) and drops (excluded from the
#      manifest, listed in the report).
#   2. Run a single-shot full-chain install into a second scratch schema and diff its
#      end-state against the stepwise end-state: presence differences ARE the spec-3.7
#      bimodality whitelist, emitted as `presence: :legacy_optional` (repair never creates
#      them). The same names feed DumpHelper.compare/5 `legacy_optional:` so the S1
#      dump-level oracle cross-checks the structural diff — any unlisted dump diff aborts.
#   3. Emit lib-ready source for PhoenixKit.Migrations.ExpectedSchema (deterministic
#      order: since, class, id; chain_hash over lib/.../postgres/v*.ex; data invariants
#      for the upgrade-only transforms) plus the V{floor} baseline module rendered from
#      the since <= floor slice. Both artifacts are parse-gated before writing. Output
#      goes to --output-dir for HAND REVIEW — nothing is written into lib/ (that is P2/P3).
#
# Offline gate (MUST pass after every edit; no DB access):
#
#   MIX_ENV=test mix run --no-start dev_docs/squash/generate_baseline.exs --check
#
# Full generation (scratch DB, direct connection — never PgBouncer):
#
#   PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=<scratch-db> \
#   PK_SQUASH_FLOOR=<floor> \
#   MIX_ENV=test mix run dev_docs/squash/generate_baseline.exs \
#     [--floor N] [--output-dir DIR] [--schema-stepwise S] [--schema-single S] \
#     [--keep-schemas]
#
# Floor/current are NEVER hardcoded: current comes from
# PhoenixKit.Migrations.Postgres.current_version/0, the floor from --floor >
# PK_SQUASH_FLOOR > @initial_version (when already squashed). Without any floor input the
# baseline slice is skipped and only the manifest + reports are produced.
#
# June 2026 draft note: the old Transformer (pg_dump text -> module rewrite) is gone —
# it did not compile (unescaped interpolation), its dollar-quote splitter was broken and
# its preamble regressed the 2026-07 prefix fixes. This rewrite generates from catalog
# introspection instead and gates every emission through Code.string_to_quoted!.

Code.require_file(Path.join(__DIR__, "repo_helper.ex"))
Code.require_file(Path.join(__DIR__, "dump_helper.ex"))
Code.require_file(Path.join(__DIR__, "migration_runner.ex"))

defmodule PhoenixKit.Squash.Generate.Config do
  @moduledoc false

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Squash.MigrationRunner

  @usage """
  generate_baseline.exs — ExpectedSchema manifest + baseline-slice generator

  Offline gate (no DB):
      MIX_ENV=test mix run --no-start dev_docs/squash/generate_baseline.exs --check

  Full generation (scratch DB, direct connection — never PgBouncer):
      PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=<scratch> \\
      PK_SQUASH_FLOOR=<floor> \\
      MIX_ENV=test mix run dev_docs/squash/generate_baseline.exs [flags]

  Flags:
      --check              offline smoke: compile + fixture code-gen + helper self-checks
      --floor N            baseline floor (precedence: --floor > PK_SQUASH_FLOOR >
                           @initial_version when > 1); validated against the compiled
                           chain; with no floor input the baseline slice is skipped
      --output-dir DIR     artifact directory (default: dev_docs/squash/output)
      --schema-stepwise S  scratch schema for the stepwise run (default
                           pk_squash_gen_step; never "public")
      --schema-single S    scratch schema for the single-shot run (default
                           pk_squash_gen_single; never "public")
      --keep-schemas       skip scratch-schema cleanup (debugging)
      --help               print this help
  """

  def usage, do: @usage

  def parse!(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          check: :boolean,
          floor: :integer,
          output_dir: :string,
          schema_stepwise: :string,
          schema_single: :string,
          keep_schemas: :boolean,
          help: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      bad = rest ++ Enum.map(invalid, &elem(&1, 0))
      raise ArgumentError, "unrecognized arguments: #{inspect(bad)}\n\n" <> @usage
    end

    config = %{
      check: Keyword.get(opts, :check, false),
      help: Keyword.get(opts, :help, false),
      floor: resolve_floor(Keyword.get(opts, :floor)),
      output_dir: Keyword.get(opts, :output_dir, Path.expand("output", __DIR__)),
      schema_stepwise: Keyword.get(opts, :schema_stepwise, "pk_squash_gen_step"),
      schema_single: Keyword.get(opts, :schema_single, "pk_squash_gen_single"),
      keep_schemas: Keyword.get(opts, :keep_schemas, false),
      inventory_doc: Path.expand("../plans/2026-07-14-squash-inventory.md", __DIR__)
    }

    validate_schemas!(config)
    config
  end

  # Floor resolution: --floor > PK_SQUASH_FLOOR (parsed by MigrationRunner.floor/0) >
  # @initial_version when the registry is already squashed. nil = no baseline slice.
  defp resolve_floor(argv_floor) do
    initial = Postgres.initial_version()
    current = Postgres.current_version()

    floor =
      cond do
        is_integer(argv_floor) -> argv_floor
        System.get_env("PK_SQUASH_FLOOR") not in [nil, ""] -> MigrationRunner.floor()
        initial > 1 -> initial
        true -> nil
      end

    cond do
      is_nil(floor) ->
        nil

      floor < initial or floor > current ->
        raise ArgumentError, "floor #{floor} outside the compiled chain #{initial}..#{current}"

      initial > 1 and floor != initial ->
        raise ArgumentError,
              "floor #{floor} contradicts the squashed registry's @initial_version #{initial}"

      true ->
        floor
    end
  end

  defp validate_schemas!(config) do
    for schema <- [config.schema_stepwise, config.schema_single] do
      Helpers.validate_prefix!(schema)

      if schema == "public" do
        raise ArgumentError,
              "scratch schemas must be NAMED schemas: schema-name substitution and " <>
                "catalog-expression normalization are ambiguous against public"
      end
    end

    if config.schema_stepwise == config.schema_single do
      raise ArgumentError, "stepwise and single-shot schemas must differ"
    end

    :ok
  end
end

defmodule PhoenixKit.Squash.Generate.Catalog do
  @moduledoc false

  # Structural catalog snapshots of one schema. Rules (spec section 6.2 lineage):
  #
  # * every query is anchored on nspname/table_schema via a $1 parameter — NEVER a
  #   regclass cast on an interpolated name (the 25P02 trap from CLAUDE.md);
  # * expression text (defaults, index/constraint definitions, function bodies) is
  #   rendered by the TARGET server (pg_get_expr/pg_get_indexdef/pg_get_constraintdef)
  #   and then normalized to the __SCHEMA__ token via DumpHelper.substitute_schema/2,
  #   so snapshots are scratch-schema-name-agnostic;
  # * Oban objects and Ecto's schema_migrations bookkeeping are filtered out (Oban is
  #   delegated, never manifested — spec section 6.1);
  # * indexes that back a constraint (pkey/unique) are represented ONLY as constraints;
  # * NOT NULL is tracked per column, so pg_constraint rows are restricted to
  #   contype IN ('p','u','f','c','x') (PG17+ may catalog NOT NULL as contype 'n').

  alias PhoenixKit.Squash.DumpHelper

  @tracked_extensions ["citext", "pgcrypto", "pg_trgm"]

  # Seed-table capture: business key + optional explicit capture-column list.
  # Default capture = every column that is not volatile (uuid/timestamp types,
  # "id", *_id, *_uuid — identities are per-install; FK identity for
  # role_permissions is implied by the Admin-only seed policy).
  @seed_capture %{
    "phoenix_kit_user_roles" => %{key: "name"},
    "phoenix_kit_settings" => %{key: "key"},
    "phoenix_kit_currencies" => %{key: "code"},
    "phoenix_kit_payment_options" => %{key: "code"},
    "phoenix_kit_storage_dimensions" => %{key: "name"},
    "phoenix_kit_buckets" => %{key: "name"},
    "phoenix_kit_role_permissions" => %{key: "module_key", capture: ["module_key"]},
    "phoenix_kit_email_templates" => %{key: "slug", capture: ["slug"]}
  }

  @tables_sql """
  SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND c.relkind = 'r'
  ORDER BY c.relname
  """

  @columns_sql """
  SELECT c.relname,
         a.attname,
         pg_catalog.format_type(a.atttypid, a.atttypmod),
         a.attnotnull,
         pg_catalog.pg_get_expr(d.adbin, d.adrelid),
         a.attnum
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE n.nspname = $1
    AND c.relkind = 'r'
    AND a.attnum > 0
    AND NOT a.attisdropped
  ORDER BY c.relname, a.attnum
  """

  # `con.conindid` is NOT exclusively "the index this PK/UNIQUE constraint
  # owns" — Postgres also points a FOREIGN KEY constraint's `conindid` at the
  # unique index on the REFERENCED table/column it relies on for uniqueness
  # (`contype = 'f'`, the far side of the FK, not the referencing side).
  # Filtering on bare `con.oid IS NULL` silently drops every unique index
  # that is merely an FK's target elsewhere in the schema. Confirmed live
  # (`mix run` against a fresh install of the real chain):
  # `phoenix_kit_ai_endpoints_uuid_idx` disappeared from BOTH this capture
  # AND `PhoenixKit.Migrations.Repair.Probe`'s identical query (same bug,
  # independently duplicated per this module's own header note on why the
  # two copies exist) purely because `fk_ai_requests_endpoint_uuid` — a
  # constraint on a DIFFERENT table, `phoenix_kit_ai_requests` — references
  # it; the manifest then omitted the object entirely (dropped as
  # `since <= 135`/no `dropped_at`, i.e. never seen at all, since the
  # exclusion applies at every snapshot including v163's final one) and a
  # LIVE `mix phoenix_kit.repair` run against ANY healthy install with an
  # FK-referenced uuid index — a common shape, several dozen tables in this
  # chain — reported the index "missing" and (harmlessly, `CREATE ...IF NOT
  # EXISTS`) "repaired" one that was never gone. The join must restrict to
  # `contype IN ('p', 'u')` — the only two constraint kinds where "this index
  # backs a constraint ON ITS OWN TABLE, so don't ALSO list it as a bare
  # index" is the intended rule.
  @indexes_sql """
  SELECT t.relname,
         ic.relname,
         i.indisunique,
         am.amname,
         pg_catalog.pg_get_indexdef(i.indexrelid),
         pg_catalog.pg_get_expr(i.indpred, i.indrelid),
         (SELECT array_agg(pg_catalog.pg_get_indexdef(i.indexrelid, s.n, true) ORDER BY s.n)
          FROM generate_series(1, i.indnatts) AS s(n)),
         (SELECT array_agg(op.opcname ORDER BY u.ord)
          FROM unnest(string_to_array(i.indclass::text, ' ')::oid[])
               WITH ORDINALITY AS u(opcoid, ord)
          JOIN pg_opclass op ON op.oid = u.opcoid)
  FROM pg_index i
  JOIN pg_class ic ON ic.oid = i.indexrelid
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  JOIN pg_am am ON am.oid = ic.relam
  LEFT JOIN pg_constraint con
    ON con.conindid = i.indexrelid AND con.contype IN ('p', 'u')
  WHERE n.nspname = $1 AND con.oid IS NULL
  ORDER BY ic.relname
  """

  @constraints_sql """
  SELECT t.relname,
         c.conname,
         c.contype::text,
         pg_catalog.pg_get_constraintdef(c.oid),
         (SELECT array_agg(a.attname ORDER BY u.ord)
          FROM unnest(c.conkey) WITH ORDINALITY AS u(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = u.attnum),
         ft.relname,
         (SELECT array_agg(a.attname ORDER BY u.ord)
          FROM unnest(c.confkey) WITH ORDINALITY AS u(attnum, ord)
          JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = u.attnum),
         c.confdeltype::text,
         c.confupdtype::text
  FROM pg_constraint c
  JOIN pg_class t ON t.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  LEFT JOIN pg_class ft ON ft.oid = c.confrelid
  WHERE n.nspname = $1 AND c.contype IN ('p', 'u', 'f', 'c', 'x')
  ORDER BY t.relname, c.conname
  """

  @sequences_sql """
  SELECT c.relname,
         pg_catalog.format_type(s.seqtypid, NULL),
         s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle
  FROM pg_sequence s
  JOIN pg_class c ON c.oid = s.seqrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1
  ORDER BY c.relname
  """

  @functions_sql """
  SELECT p.proname,
         pg_catalog.pg_get_function_identity_arguments(p.oid),
         pg_catalog.pg_get_functiondef(p.oid),
         l.lanname,
         pg_catalog.format_type(p.prorettype, NULL),
         md5(p.prosrc)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_language l ON l.oid = p.prolang
  WHERE n.nspname = $1 AND p.prokind = 'f'
  ORDER BY p.proname
  """

  @extensions_sql """
  SELECT extname FROM pg_extension WHERE extname = ANY($1) ORDER BY extname
  """

  def tracked_extensions, do: @tracked_extensions

  def seed_tables, do: @seed_capture |> Map.keys() |> Enum.sort()

  @doc """
  Full structural snapshot of one schema. [DB]

  ## Why `search_path = ''` for the duration of the capture

  Mirrors `PhoenixKit.Migrations.Repair.Probe.snapshot/2` verbatim (see that
  function's own moduledoc for the full explanation) — do not modify Probe;
  this is the generator's own copy of the same idiom, kept here so the two
  capture connections schema-qualify identically. In short:
  `pg_get_expr`/`pg_get_indexdef`/`format_type` decide **at read time**,
  from the querying session's `search_path`, whether to schema-qualify a
  referenced function/type/extension — never from how the object was
  originally created. This scratch schema is never `"public"` (never on
  the default search_path), so THIS capture already schema-qualifies most
  cross-schema references consistently by construction — except for
  objects that live in `public` itself (shared extension types — citext,
  from V01's case-insensitive email columns, is this chain's only one):
  `public` IS on the ordinary default search_path (`"$user", public`), so
  without forcing `search_path = ''` here too, `format_type()` would
  render a citext-typed column as the unqualified `"citext"` at
  generation time while `Probe.snapshot/2`'s forced-empty search_path
  always reads it back as `"public.citext"` at verify/repair time — a
  real, confirmed P1/P2 asymmetry (not cosmetic: it blocked `--adopt`
  from ever stamping any real install, since `phoenix_kit_users.email`
  sits in every install's floor slice). Forcing it here too — the same
  idiom `pg_dump` itself relies on for portable, fully-qualified output —
  makes both captures schema-qualify exactly as consistently as each
  other, independent of which prefix either one is probing.

  Runs inside `repo.checkout/2` so the `SET`, every catalog query, and the
  final `RESET` land on the SAME physical connection (checkout nests
  transparently, same as Probe). The `after` clause restores `search_path`
  unconditionally, even if a catalog query raises — session-level state on
  a connection this process borrows from a shared pool.
  """
  def snapshot(repo, schema) do
    repo.checkout(fn ->
      repo.query!("SET search_path TO ''", [], log: false)

      try do
        columns = columns(repo, schema)

        %{
          tables: tables(repo, schema),
          columns: columns,
          indexes: indexes(repo, schema),
          constraints: constraints(repo, schema),
          sequences: sequences(repo, schema),
          functions: functions(repo, schema),
          extensions: extensions(repo),
          seeds: seeds(repo, schema, columns)
        }
      after
        repo.query!("RESET search_path", [], log: false)
      end
    end)
  end

  defp tables(repo, schema) do
    for [name] <- rows!(repo, @tables_sql, [schema]), keep_table?(name), into: %{} do
      {name, %{}}
    end
  end

  defp columns(repo, schema) do
    for [table, col, type, not_null, default, pos] <- rows!(repo, @columns_sql, [schema]),
        keep_table?(table),
        into: %{} do
      {{table, col},
       %{type: type, not_null: not_null, default: normalize_expr(default, schema), pos: pos}}
    end
  end

  defp indexes(repo, schema) do
    for [table, name, unique, method, definition, predicate, keys, opclasses] <-
          rows!(repo, @indexes_sql, [schema]),
        keep_table?(table),
        into: %{} do
      {canonical_name, exemption} = canonicalize_object_name(name, schema)

      {canonical_name,
       %{
         table: table,
         unique: unique,
         method: method,
         definition: templatize_field(definition, schema, name, canonical_name, exemption),
         predicate: templatize_field(predicate, schema, name, canonical_name, exemption),
         keys: Enum.map(keys || [], &DumpHelper.substitute_schema(&1, schema)),
         opclasses: opclasses || [],
         name_template: exemption
       }}
    end
  end

  defp constraints(repo, schema) do
    for [table, name, contype, definition, columns, ftable, fcolumns, del, upd] <-
          rows!(repo, @constraints_sql, [schema]),
        keep_table?(table),
        into: %{} do
      {canonical_name, exemption} = canonicalize_object_name(name, schema)

      {{table, canonical_name},
       %{
         type: contype,
         definition: templatize_field(definition, schema, name, canonical_name, exemption),
         columns: columns,
         foreign_table: ftable,
         foreign_columns: fcolumns,
         on_delete: fk_action(contype, del),
         on_update: fk_action(contype, upd),
         name_template: exemption
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Prefix-embedded object names — see DumpHelper.prefix_embedded_bare_suffix/2's
  # moduledoc for the full "why" (two known real conventions, empirically
  # distinguished). Detecting and canonicalizing at CAPTURE time — rather than
  # leaving the scratch-schema-literal name as the snapshot's dictionary KEY —
  # means Differ/Bimodality need no changes at all: a stepwise and a
  # single-shot run key the SAME real object identically (both fold to the
  # bare suffix), so the 47 phantom :legacy_optional entries this class of
  # name produced simply never arise. `name_template` on the returned shape
  # carries WHICH of the two conventions applies, for Emitter to render a
  # prefix-aware name back out at manifest/baseline-emission time.

  @name_marker_exempt "__PK_NAME_EXEMPT__"
  @name_marker_always "__PK_NAME_ALWAYS__"

  @doc "The marker token Emitter substitutes for a resolved prefix at render time."
  def name_marker(:exempt), do: @name_marker_exempt
  def name_marker(:always), do: @name_marker_always

  # `nil` exemption for the overwhelming majority of names (not prefix-embedded
  # at all) — `canonical_name` is then just `name`, unchanged.
  defp canonicalize_object_name(name, schema) do
    case DumpHelper.prefix_embedded_bare_suffix(name, schema) do
      nil -> {name, nil}
      bare -> {bare, classify_exemption(bare)}
    end
  end

  # The ONLY two real call sites in the whole migration chain that embed a
  # schema name directly into an object's own NAME (verified by grepping
  # every `lib/phoenix_kit/migrations/**/*.ex` file for `#{prefix}` used
  # inside a `name:`/identifier position — not schema-QUALIFICATION, which
  # `normalize_expr/2` already handles separately):
  #
  #   * v56.ex's/v61.ex's byte-identical `prefix_index_name/2` — always
  #     produces a `"#{table}_uuid_idx"` suffix, bare on `public`/`nil`,
  #     `"#{prefix}_#{bare}"` otherwise. The `_uuid_idx` suffix below is
  #     this function's literal, unconditional output shape — not a guess.
  #   * v26.ex's one inline `name: "#{prefix}_phoenix_kit_files_user_file_checksum_index"`
  #     — no conditional at all, so ALWAYS prefixed, `public` included.
  #     Confirmed empirically (2026-08-04) against a live, fully-migrated
  #     `public` schema: the real index is named
  #     `public_phoenix_kit_files_user_file_checksum_index`, not the bare
  #     form `substitute_schema/2`'s fold would suggest.
  #
  # A prefix-embedded name matching neither shape is unrecognized — refuse to
  # guess (this codebase's standing convention for exactly this situation,
  # e.g. InventoryGuard) rather than silently picking the wrong convention
  # and shipping a manifest that misnames the object on every real "public"
  # install (the common case).
  defp classify_exemption("phoenix_kit_files_user_file_checksum_index"), do: :always

  defp classify_exemption(bare) do
    if String.ends_with?(bare, "_uuid_idx") do
      :exempt
    else
      raise "unrecognized prefix-embedded object name #{inspect(bare)} — read its source " <>
              "migration to determine whether \"public\" is exempted from the prefix (like " <>
              "v56.ex/v61.ex's prefix_index_name/2) or always included (like v26.ex's inline " <>
              "naming — verify EMPIRICALLY against a live public schema, never guess), then " <>
              "extend Catalog.classify_exemption/1"
    end
  end

  defp templatize_field(nil, _schema, _raw_name, _canonical_name, _exemption), do: nil

  defp templatize_field(text, schema, _raw_name, _canonical_name, nil),
    do: normalize_expr(text, schema)

  # `raw_name` (the exact captured identifier, e.g. "pk_squash_gen_step_phoenix_kit_x_uuid_idx")
  # is used as the search key — an exact literal match, so this can never
  # collide with an unrelated `schema.table`-qualifier occurrence elsewhere
  # in the same text (that uses a `.` join, not `_`, and normalize_expr/2's
  # own fold handles it separately, afterward).
  defp templatize_field(text, schema, raw_name, canonical_name, exemption) do
    text
    |> String.replace(raw_name, name_marker(exemption) <> canonical_name)
    |> normalize_expr(schema)
  end

  defp sequences(repo, schema) do
    for [name, type, start, inc, min, max, cache, cycle] <- rows!(repo, @sequences_sql, [schema]),
        keep_sequence?(name),
        into: %{} do
      {name,
       %{
         data_type: type,
         start: start,
         increment: inc,
         min: min,
         max: max,
         cache: cache,
         cycle: cycle
       }}
    end
  end

  defp functions(repo, schema) do
    for [name, args, definition, lang, returns, md5] <- rows!(repo, @functions_sql, [schema]),
        keep_function?(name),
        into: %{} do
      {{name, args},
       %{
         returns: returns,
         language: lang,
         body_md5: md5,
         definition: normalize_expr(definition, schema)
       }}
    end
  end

  defp extensions(repo) do
    for [name] <- rows!(repo, @extensions_sql, [@tracked_extensions]), into: %{} do
      {name, %{}}
    end
  end

  # Seed rows keyed {table, business_key_value}. Tables absent at this chain point
  # (or whose key column does not exist yet) are skipped — the differ then tags the
  # rows' `since` as the version where they first appear.
  defp seeds(repo, schema, columns) do
    Enum.reduce(@seed_capture, %{}, fn {table, spec}, acc ->
      table_columns =
        columns
        |> Enum.filter(fn {{t, _c}, _shape} -> t == table end)
        |> Map.new(fn {{_t, c}, shape} -> {c, shape} end)

      cond do
        table_columns == %{} -> acc
        not Map.has_key?(table_columns, spec.key) -> acc
        true -> Map.merge(acc, capture_table_seeds(repo, schema, table, spec, table_columns))
      end
    end)
  end

  defp capture_table_seeds(repo, schema, table, spec, table_columns) do
    capture_cols =
      case spec[:capture] do
        nil ->
          table_columns
          |> Enum.reject(fn {c, shape} -> volatile_column?(c, shape.type) end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        cols ->
          Enum.filter(cols, &Map.has_key?(table_columns, &1))
      end

    select_list =
      Enum.map_join(capture_cols, ", ", fn c ->
        validate_identifier!(c)
        if table_columns[c].type == "jsonb", do: ~s("#{c}"::text), else: ~s("#{c}")
      end)

    validate_identifier!(spec.key)
    sql = ~s[SELECT #{select_list} FROM #{schema}.#{table} ORDER BY "#{spec.key}"]

    Enum.reduce(rows!(repo, sql, []), %{}, fn row, acc ->
      values =
        capture_cols
        |> Enum.zip(row)
        |> Map.new(fn {c, v} -> {c, normalize_seed_value(table, c, v)} end)

      key_value = Map.fetch!(values, spec.key)

      unless is_binary(key_value) do
        raise "seed capture #{table}: business key #{spec.key} is not text: #{inspect(key_value)}"
      end

      if Map.has_key?(acc, {table, key_value}) do
        raise "seed capture #{table}: duplicate business key #{inspect(key_value)}"
      end

      Map.put(acc, {table, key_value}, %{
        key_column: spec.key,
        key_value: key_value,
        values: values
      })
    end)
  end

  defp rows!(repo, sql, params) do
    %{rows: rows} = repo.query!(sql, params, log: false)
    rows
  end

  defp keep_table?(name),
    do: name != "schema_migrations" and not String.starts_with?(name, "oban_")

  defp keep_sequence?(name), do: not String.starts_with?(name, "oban_")

  defp keep_function?(name), do: not String.starts_with?(name, "oban")

  defp fk_action("f", action), do: action
  defp fk_action(_contype, _action), do: nil

  defp normalize_expr(nil, _schema), do: nil
  defp normalize_expr(text, schema), do: DumpHelper.substitute_schema(text, schema)

  defp volatile_column?(name, type) do
    name == "id" or String.ends_with?(name, "_id") or String.ends_with?(name, "_uuid") or
      type == "uuid" or String.starts_with?(type, "timestamp")
  end

  # Values must survive `inspect` -> parse round-trips in the emitted manifest
  # (the raw captured value is embedded, via each object's `revisions`, as an
  # Elixir literal in the generated ExpectedSchema source): structs (Decimal,
  # ...) are flattened to their string form. Lists/maps — a Postgres array
  # column decoded by Postgrex as a native list (e.g. V98's
  # `alternative_formats text[]`), or a jsonb/json value that arrived
  # undecoded — round-trip fine as plain Elixir terms too (a list/map built
  # from the value types handled here is valid literal Elixir source), so
  # they are kept as terms, recursively normalized element-wise, rather than
  # pre-serialized here. `PhoenixKit.Squash.Generate.Emitter.literal/2`
  # decides the actual SQL rendering (a native `{...}` array literal vs a
  # canonical-JSON `::jsonb` literal) from the real column type at emission
  # time — this capture step has no such type context to make that call
  # correctly (a `text[]` value serialized to JSON `[...]` syntax here would
  # be invalid `text[]` input later; that mistake is exactly what a "just
  # JSON-encode it" fix at this layer would produce).
  defp normalize_seed_value(table, col, value) do
    cond do
      is_struct(value) ->
        to_string(value)

      is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value) ->
        value

      is_list(value) ->
        Enum.map(value, &normalize_seed_value(table, col, &1))

      is_map(value) ->
        Map.new(value, fn {k, v} -> {k, normalize_seed_value(table, col, v)} end)

      true ->
        raise "seed capture #{table}.#{col}: unsupported value #{inspect(value)}"
    end
  end

  defp validate_identifier!(name) do
    unless is_binary(name) and name =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "unsafe SQL identifier: #{inspect(name)}"
    end

    :ok
  end
end

defmodule PhoenixKit.Squash.Generate.Differ do
  @moduledoc false

  # Pure per-version snapshot diffing -> object history -> final catalog.
  #
  # History events per {class, key}: {:added, v, shape} | {:changed, v, shape} |
  # {:dropped, v}, chronological. `since` restarts at the LAST :added (a drop +
  # re-add resets the revision chain); `revisions` = introducing shape plus one
  # entry per later alteration (spec 5.1: single-shape entries are forbidden for
  # objects the diff pass saw altered — guaranteed by construction here).

  @classes [
    :extensions,
    :functions,
    :sequences,
    :tables,
    :columns,
    :indexes,
    :constraints,
    :seeds
  ]

  @singular %{
    extensions: :extension,
    functions: :function,
    sequences: :sequence,
    tables: :table,
    columns: :column,
    indexes: :index,
    constraints: :constraint,
    seeds: :seed
  }

  @class_rank %{
    extension: 0,
    function: 1,
    sequence: 2,
    table: 3,
    column: 4,
    index: 5,
    constraint: 6,
    seed: 7
  }

  def classes, do: @classes

  def singular(class), do: Map.fetch!(@singular, class)

  def class_rank(class), do: Map.fetch!(@class_rank, class)

  @doc """
  Secondary sort tier within the `:constraint` class: foreign keys (contype
  `"f"`) sort AFTER every non-FK constraint (PK/UNIQUE/CHECK, contype
  `"p"`/`"u"`/`"c"`/`"x"`), regardless of `id`.

  Emission relies on `{since, class_rank, ...}` ordering alone being enough
  to guarantee a referenced table's own PK/UNIQUE exists before any FK
  targeting it is created. That held only by accident pre-squash, when
  `since` values were spread across ~160 versions — a referencing table's
  FK and the referenced table's PK rarely shared the exact same `since`, so
  the `id` tiebreak (pure alphabetical) rarely had to arbitrate between
  them. Post-squash, nearly everything below the floor collapses to the
  SAME `since` (the floor itself), so the `id` tiebreak alone decides —
  and alphabetical order has no notion of "PK before the FK that needs
  it" (`phoenix_kit_file_instances_..._fkey` < `phoenix_kit_files_pkey`
  lexically, which is backwards). Splitting non-FK-before-FK as a THIRD
  sort key restores correctness for any `since` tier, not just the
  floor's, without needing a full per-table topological sort: every
  non-FK constraint only depends on its own table (already ordered before
  ANY constraint via `class_rank`), so putting all of them ahead of every
  FK in the same tier is sufficient — a FK's referenced table's own
  PK/UNIQUE is always in the same class, so it always lands first.
  """
  def constraint_fk_rank(:constraint, shape) when is_map(shape) do
    if Map.get(shape, :type) == "f", do: 1, else: 0
  end

  def constraint_fk_rank(_class, _shape), do: 0

  @doc "Fold ascending [{version, snapshot}] into %{{class, key} => [event]}."
  def history(snapshots) do
    empty = Map.new(@classes, &{&1, %{}})

    {_prev, hist} =
      Enum.reduce(snapshots, {empty, %{}}, fn {version, snap}, {prev, hist} ->
        hist =
          Enum.reduce(@classes, hist, fn class, acc ->
            diff_class(class, version, Map.fetch!(prev, class), Map.fetch!(snap, class), acc)
          end)

        {snap, hist}
      end)

    Map.new(hist, fn {key, events} -> {key, Enum.reverse(events)} end)
  end

  defp diff_class(class, version, prev, curr, hist) do
    hist =
      Enum.reduce(curr, hist, fn {key, shape}, acc ->
        case Map.fetch(prev, key) do
          :error ->
            push(acc, {class, key}, {:added, version, shape})

          {:ok, old} ->
            if comparable(class, old) == comparable(class, shape) do
              acc
            else
              push(acc, {class, key}, {:changed, version, shape})
            end
        end
      end)

    Enum.reduce(prev, hist, fn {key, _shape}, acc ->
      if Map.has_key?(curr, key), do: acc, else: push(acc, {class, key}, {:dropped, version})
    end)
  end

  defp push(hist, key, event), do: Map.update(hist, key, [event], &[event | &1])

  # Column physical position is stored (CREATE TABLE assembly order) but never a
  # revision trigger — attnum churn is incidental.
  def comparable(:columns, shape), do: Map.drop(shape, [:pos])
  def comparable(_class, shape), do: shape

  @doc """
  Final object catalog from the history + the final stepwise snapshot.

  Returns %{objects: [intermediate], drops: [dropped-object info]} where objects
  carry class (singular), key, id, since, revisions, presence: :required.
  Dropped objects are EXCLUDED from the manifest (`objects/1`/`data_invariants/1`
  describe the fully-migrated steady state only) and surfaced for the report —
  but `drops` entries ALSO carry `since`/`revisions` (not just `dropped_at`),
  because the baseline-slice renderer (`Emitter.render_baseline/4`) needs them
  for objects dropped ABOVE the floor: such an object existed in the baseline's
  own shape (it was introduced at/before the floor and survives into the
  post-floor delta chain) even though it is absent from the fully-migrated
  final state the plain manifest describes. Discovered live post-squash: with
  `@initial_version` at a real floor, `since` values for everything below it
  collapse to the floor itself, and this class of gap went from
  theoretical-but-masked (pre-squash, "dropped along the chain" mostly meant
  "dropped below any candidate floor, so it doesn't matter") to a hard crash —
  `V152.up/1`'s bare `ALTER COLUMN list_uuid DROP NOT NULL` against a floor-135
  baseline missing the column entirely, because V156 (above the floor) drops it
  later and the old `catalog/2` excluded it from `objects` on that basis alone,
  with no floor-awareness at all. See `render_baseline/4`'s `floor_carryover/3`.
  """
  def catalog(history, final_snapshot) do
    objects =
      for class <- @classes,
          {key, _shape} <- Map.fetch!(final_snapshot, class) do
        events = Map.fetch!(history, {class, key})
        {since, revisions} = since_and_revisions(events)

        %{
          class: singular(class),
          key: key,
          id: object_id(class, key),
          since: since,
          revisions: revisions,
          presence: :required
        }
      end

    drops =
      history
      |> Enum.filter(fn {{class, key}, _events} ->
        not Map.has_key?(Map.fetch!(final_snapshot, class), key)
      end)
      |> Enum.map(fn {{class, key}, events} ->
        {:dropped, dropped_at} = List.last(events)
        {since, revisions} = since_and_revisions(events)

        %{
          class: singular(class),
          key: key,
          id: object_id(class, key),
          since: since,
          revisions: revisions,
          dropped_at: dropped_at
        }
      end)
      |> Enum.sort_by(& &1.id)

    %{
      objects:
        Enum.sort_by(objects, fn object ->
          {_v, shape} = List.last(object.revisions)

          {object.since, class_rank(object.class), constraint_fk_rank(object.class, shape),
           object.id}
        end),
      drops: drops
    }
  end

  defp since_and_revisions(events) do
    {since, revs} =
      Enum.reduce(events, {nil, []}, fn
        {:added, v, shape}, {_since, _revs} -> {v, [{v, shape}]}
        {:changed, v, shape}, {since, revs} -> {since, [{v, shape} | revs]}
        {:dropped, _v}, acc -> acc
      end)

    {since, Enum.reverse(revs)}
  end

  @doc "Version of the LAST :added event for {class, key}, or nil if never seen."
  def last_added_version(history, class, key) do
    case Map.get(history, {class, key}) do
      nil ->
        nil

      events ->
        Enum.reduce(events, nil, fn
          {:added, v, _shape}, _acc -> v
          _event, acc -> acc
        end)
    end
  end

  def object_id(class, key) when is_map_key(@singular, class),
    do: id_for(@singular[class], key)

  def object_id(class, key) when is_map_key(@class_rank, class), do: id_for(class, key)

  defp id_for(:table, table), do: "table:#{table}"
  defp id_for(:column, {t, c}), do: "column:#{t}.#{c}"
  defp id_for(:index, name), do: "index:#{name}"
  defp id_for(:constraint, {t, n}), do: "constraint:#{t}.#{n}"
  defp id_for(:sequence, name), do: "sequence:#{name}"
  defp id_for(:function, {name, args}), do: "function:#{name}(#{args})"
  defp id_for(:extension, name), do: "extension:#{name}"
  defp id_for(:seed, {t, key}), do: "seed:#{t}:#{key}"
end

defmodule PhoenixKit.Squash.Generate.Bimodality do
  @moduledoc false

  # Spec section 3.7: the OLD chain's end-state is bimodal (single-run installs vs
  # per-version upgraded installs). The stepwise end-state is CANONICAL (it carries
  # since/revisions); presence differences against the single-shot end-state become
  # `presence: :legacy_optional` entries (repair never creates them). Same-key SHAPE
  # differences cannot be expressed by the presence model and abort generation.

  alias PhoenixKit.Squash.Generate.Differ

  def diff(stepwise_final, single_final) do
    Enum.reduce(
      Differ.classes(),
      %{only_single: [], only_stepwise: [], mismatched: []},
      fn class, acc ->
        step = Map.fetch!(stepwise_final, class)
        single = Map.fetch!(single_final, class)

        only_single =
          for {key, shape} <- single, not Map.has_key?(step, key), do: {class, key, shape}

        only_stepwise =
          for {key, shape} <- step, not Map.has_key?(single, key), do: {class, key, shape}

        mismatched =
          for {key, shape} <- step,
              other = Map.get(single, key),
              other != nil,
              Differ.comparable(class, shape) != Differ.comparable(class, other),
              do: {class, key, shape, other}

        %{
          only_single: acc.only_single ++ sort3(only_single),
          only_stepwise: acc.only_stepwise ++ sort3(only_stepwise),
          mismatched: acc.mismatched ++ Enum.sort_by(mismatched, &inspect(elem(&1, 1)))
        }
      end
    )
  end

  defp sort3(list), do: Enum.sort_by(list, fn {_class, key, _shape} -> inspect(key) end)

  @doc """
  Fold the bimodality diff into the object list:

  * stepwise-only objects flip to presence: :legacy_optional;
  * single-shot-only objects are ADDED as :legacy_optional, `since` recovered from
    the stepwise history (they typically appeared and were then dropped there, e.g.
    users.preferred_locale V28->V30); unresolvable `since` defaults to 1 and is
    reported.

  Returns {objects, notes} — notes list ids whose since could not be recovered.
  """
  def apply_to_objects(objects, history, bidiff) do
    flip_ids =
      MapSet.new(bidiff.only_stepwise, fn {class, key, _shape} -> Differ.object_id(class, key) end)

    flipped =
      Enum.map(objects, fn object ->
        if MapSet.member?(flip_ids, object.id) do
          %{object | presence: :legacy_optional}
        else
          object
        end
      end)

    {extra, notes} =
      Enum.map_reduce(bidiff.only_single, [], fn {class, key, shape}, notes ->
        id = Differ.object_id(class, key)
        recovered = Differ.last_added_version(history, class, key)
        since = recovered || 1
        notes = if recovered, do: notes, else: [id | notes]

        object = %{
          class: Differ.singular(class),
          key: key,
          id: id,
          since: since,
          revisions: [{since, shape}],
          presence: :legacy_optional
        }

        {object, notes}
      end)

    {flipped ++ extra, %{unknown_since: Enum.sort(notes)}}
  end

  @doc """
  Object names for DumpHelper.compare/5 legacy_optional (S1 whitelist).
  Columns are table-qualified (`table.column`) so a same-named column in
  another table can never be masked; other classes use bare object names
  (index/constraint/sequence names are schema-unique).
  """
  def whitelist(bidiff) do
    (bidiff.only_single ++ bidiff.only_stepwise)
    |> Enum.flat_map(fn {class, key, _shape} -> name_tokens(class, key) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp name_tokens(:columns, {t, c}), do: ["#{t}.#{c}"]
  defp name_tokens(:constraints, {_t, n}), do: [n]
  defp name_tokens(:tables, t), do: [t]
  defp name_tokens(:indexes, n), do: [n]
  defp name_tokens(:sequences, n), do: [n]
  defp name_tokens(:functions, {n, _args}), do: [n]
  defp name_tokens(_class, _key), do: []
end

defmodule PhoenixKit.Squash.Generate.InventoryGuard do
  @moduledoc false

  # Refuse-to-emit guard (spec 8.3): objects the inventory doc's "Drops/renames"
  # section marks as gone from the final state must NEVER appear as
  # presence: :required manifest entries. The list below is curated FROM the doc
  # (each entry carries a doc token); assert_inventory_doc!/1 is the staleness
  # detector — if the doc no longer mentions a token, the curation must be revisited.
  #
  # A guard HIT is not silently skipped: it means the scratch run produced an object
  # the inventory says cannot exist — a real anomaly (chain edit, wrong checkout) —
  # so generation aborts.

  @excluded_exact [
    # tables renamed/dropped along the chain
    {"table:phoenix_kit_subscription_plans", "phoenix_kit_subscription_plans"},
    {"table:phoenix_kit_machine_types", "phoenix_kit_machine_types"},
    {"table:phoenix_kit_operations", "phoenix_kit_operations"},
    {"table:phoenix_kit_defect_reasons", "phoenix_kit_defect_reasons"},
    # columns dropped/renamed away
    {"column:phoenix_kit_user_role_assignments.is_active", "is_active"},
    {"column:phoenix_kit_files.checksum", "checksum"},
    {"column:phoenix_kit_shop_categories.image_url", "image_url"},
    {"column:phoenix_kit_shop_import_logs.product_ids", "product_ids"},
    {"column:phoenix_kit_staff_people.skills", "skills"},
    {"column:phoenix_kit_doc_templates.category", "category"},
    {"column:phoenix_kit_doc_template_presets.category", "category"},
    {"column:phoenix_kit_cat_items.price", "price"},
    {"column:phoenix_kit_locations.location_type_uuid", "location_type_uuid"},
    {"column:phoenix_kit_publishing_posts.scheduled_at", "scheduled_at"},
    {"column:phoenix_kit_publishing_posts.status", "scheduled_at/status"},
    {"column:phoenix_kit_publishing_posts.published_at", "published_at"},
    {"column:phoenix_kit_publishing_posts.primary_language", "primary_language"},
    # V28's users.preferred_locale may exist ONLY as :legacy_optional (section 3.7)
    {"column:phoenix_kit_users.preferred_locale", "preferred_locale"},
    # indexes dropped/replaced along the chain
    {"index:idx_user_role_assignments_user_active", "idx_user_role_assignments_user_active"},
    {"index:idx_user_role_assignments_role_active", "idx_user_role_assignments_role_active"},
    {"index:phoenix_kit_projects_name_index", "phoenix_kit_projects_name_index"},
    {"index:phoenix_kit_projects_name_template_index",
     "phoenix_kit_projects_name_template_index"},
    {"index:phoenix_kit_projects_name_project_index", "phoenix_kit_projects_name_project_index"},
    {"index:phoenix_kit_project_tasks_title_index", "phoenix_kit_project_tasks_title_index"},
    {"index:phoenix_kit_cat_items_sku_index", "phoenix_kit_cat_items_sku_index"},
    {"index:phoenix_kit_doc_templates_category_index",
     "phoenix_kit_doc_templates_category_index"},
    {"index:phoenix_kit_location_types_name_index", "phoenix_kit_location_types_name_index"},
    {"index:idx_publishing_posts_scheduled", "idx_publishing_posts_scheduled"},
    {"index:idx_publishing_posts_group_status", "idx_publishing_posts_group_status"},
    {"index:idx_publishing_posts_group_published_at", "idx_publishing_posts_group_published_at"},
    {"index:phoenix_kit_shop_products_slug_unique_idx",
     "phoenix_kit_shop_products_slug_unique_idx"},
    {"index:phoenix_kit_shop_categories_slug_unique_idx",
     "phoenix_kit_shop_categories_slug_unique_idx"},
    # constraints replaced later
    {"constraint:phoenix_kit_users_tokens.user_id_required_for_non_registration_tokens",
     "user_id_required_for_non_registration_tokens"},
    # sequences
    {"sequence:phoenix_kit_id_seq", "phoenix_kit_id_seq"},
    # settings rows deleted by V34
    {"seed:phoenix_kit_settings:ai_text_processing_slots", "ai_text_processing_slots"},
    {"seed:phoenix_kit_settings:ai_vision_processing_slots", "ai_vision_processing_slots"},
    {"seed:phoenix_kit_settings:ai_image_gen_slots", "ai_image_gen_slots"},
    {"seed:phoenix_kit_settings:ai_embeddings_slots", "ai_embeddings_slots"},
    # role_permissions module_key renamed V77 -> V109
    {"seed:phoenix_kit_role_permissions:tickets", "tickets"},
    {"seed:phoenix_kit_role_permissions:customer_service", "customer_service"},
    # V152: newsletters send profiles moved to core email (table + 2 indexes dropped)
    {"table:phoenix_kit_newsletters_send_profiles", "phoenix_kit_newsletters_send_profiles"},
    {"index:idx_nl_send_profiles_integration", "idx_nl_send_profiles_integration"},
    {"index:idx_nl_send_profiles_default", "idx_nl_send_profiles_default"},
    # V156: newsletters lists migrated into CRM (tables + broadcast link dropped)
    {"table:phoenix_kit_newsletters_lists", "phoenix_kit_newsletters_lists"},
    {"table:phoenix_kit_newsletters_list_members", "phoenix_kit_newsletters_list_members"},
    {"column:phoenix_kit_newsletters_broadcasts.list_uuid", "list_uuid"},
    {"constraint:phoenix_kit_newsletters_broadcasts.fk_newsletters_broadcasts_list",
     "fk_newsletters_broadcasts_list"},
    {"index:idx_newsletters_broadcasts_list", "idx_newsletters_broadcasts_list"}
  ]

  @excluded_prefix [
    {"table:phoenix_kit_mailing_", "phoenix_kit_mailing_lists"},
    {"table:phoenix_kit_db_sync_", "phoenix_kit_db_sync_connections"},
    {"seed:phoenix_kit_settings:db_sync_", "db_sync_enabled"},
    {"seed:phoenix_kit_settings:tickets_", "tickets_enabled"},
    {"seed:phoenix_kit_settings:customer_service_", "customer_service_"}
  ]

  def excluded_exact, do: @excluded_exact

  def excluded_prefix, do: @excluded_prefix

  @doc "Raise when any :required object matches the exclusion list."
  def assert_catalog!(objects) do
    violations =
      objects
      |> Enum.filter(&(&1.presence == :required))
      |> Enum.flat_map(fn object ->
        case match_exclusion(object.id) do
          nil -> []
          doc_token -> [{object.id, doc_token}]
        end
      end)

    if violations != [] do
      details =
        Enum.map_join(violations, "\n", fn {id, token} ->
          "  #{id} (inventory Drops section, cf. #{inspect(token)})"
        end)

      raise "inventory guard: the scratch run produced objects the inventory doc " <>
              "marks as excluded from the final state — refusing to emit them as " <>
              ":required:\n" <> details
    end

    :ok
  end

  defp match_exclusion(id) do
    exact = Enum.find(@excluded_exact, fn {excluded_id, _token} -> excluded_id == id end)

    prefix =
      Enum.find(@excluded_prefix, fn {excluded_prefix, _token} ->
        String.starts_with?(id, excluded_prefix)
      end)

    case exact || prefix do
      nil -> nil
      {_id_or_prefix, token} -> token
    end
  end

  @doc """
  Staleness detector: the inventory doc must exist, contain the Drops section, and
  still mention every curated token. Raises otherwise (regenerating against a moved
  or rewritten inventory needs the curation re-checked by a human).
  """
  def assert_inventory_doc!(path) do
    unless File.exists?(path) do
      raise "inventory doc not found at #{path} — the exclusion guard curation " <>
              "cannot be cross-checked"
    end

    text = File.read!(path)

    unless String.contains?(text, "## Drops/renames") do
      raise "inventory doc #{path} lost its \"## Drops/renames\" section — re-curate " <>
              "the InventoryGuard exclusion list before regenerating"
    end

    missing =
      (@excluded_exact ++ @excluded_prefix)
      |> Enum.map(fn {_id, token} -> token end)
      |> Enum.uniq()
      |> Enum.reject(&String.contains?(text, &1))

    if missing != [] do
      raise "inventory doc #{path} no longer mentions curated guard tokens " <>
              "#{inspect(missing)} — re-curate the InventoryGuard exclusion list"
    end

    :ok
  end
end

defmodule PhoenixKit.Squash.Generate.Emitter do
  @moduledoc false

  # Code generation for the two artifacts:
  #
  # * ExpectedSchema manifest — object data is emitted as ONE inspected literal
  #   (never string-built Elixir), so quoting/escaping bugs are structurally
  #   impossible in the data part; SQL inside it carries the __SCHEMA__ token that
  #   objects/1 substitutes at runtime.
  # * V{floor} baseline module — assembled from the since <= floor slice at the
  #   newest revision <= floor. SQL is emitted into execute() heredocs; the ONLY
  #   interpolations in the generated module are built here from @pound so this
  #   generator's own source never contains an escapable interpolation (the June
  #   draft's fatal class). Every render is parse-gated by callers.
  #
  # Prefix-safety rules honored in all emitted SQL (CLAUDE.md): bare index names on
  # CREATE, name-based pg_constraint JOIN guards anchored on nspname (never regclass
  # casts in immediate checks), extensions/uuid function via Helpers, CREATE SCHEMA
  # only through the V01-semantics check in the baseline preamble.

  alias PhoenixKit.Squash.Generate.Catalog
  alias PhoenixKit.Squash.Generate.Differ

  @pound "#"
  @schema_token "__SCHEMA__"

  # Seed emission strategies. :skip rows are represented by template_seed_objects/0
  # helper entries instead (V15/V31 best-effort seeder lineage). An unknown seed
  # table raises at emit time — extending the capture set requires a strategy.
  @seed_strategies %{
    "phoenix_kit_user_roles" => :conflict_key,
    "phoenix_kit_settings" => :conflict_key,
    "phoenix_kit_currencies" => :conflict_key,
    "phoenix_kit_payment_options" => :conflict_key,
    "phoenix_kit_storage_dimensions" => :conflict_key,
    "phoenix_kit_buckets" => :where_not_exists,
    "phoenix_kit_role_permissions" => :admin_role_select,
    "phoenix_kit_email_templates" => :skip
  }

  # `owner:` — spec 5.1's per-module-extraction-slice hint (task-#4/operator's
  # modularization vision): a best-effort tag for which future standalone
  # `phoenix_kit_*` module a core-chain object's table family would belong to
  # if/when it is carved out, NOT an authoritative taxonomy the repair/verify
  # engine depends on for correctness. Data, not code, per the same instinct
  # as `@seed_strategies` above — extending family coverage is a one-line
  # addition here, never a new `object_owner/1` clause.
  #
  # Checked as a PREFIX against the table name with the `"phoenix_kit_"` lead
  # stripped (e.g. `"cat_items"` for `phoenix_kit_cat_items`) — prefix, not
  # substring, matters: `phoenix_kit_file_locations` (V20, Storage — bucket
  # placement for a file variant) must NOT fall into :locations just because
  # it contains "location" as a substring; it doesn't START WITH "location".
  @table_owner_prefixes [
    {"cat_", :catalogue},
    {"warehouse_", :warehouse},
    {"crm_", :crm},
    {"staff_", :staff},
    {"project", :projects},
    {"newsletters_", :newsletters},
    {"publishing_", :publishing},
    {"og_", :og_images},
    {"location", :locations},
    {"ai_", :ai},
    {"doc_", :document_creator}
  ]

  # The one family that genuinely needs substring (not prefix) matching: its
  # member tables don't share a common lead — `phoenix_kit_comments`
  # (standalone comments module) alongside `phoenix_kit_post_comments`/
  # `phoenix_kit_post_likes`/`phoenix_kit_post_dislikes`/
  # `phoenix_kit_ticket_comments`/`phoenix_kit_comment_likes` (posts/tickets
  # features). Deliberately lumped into one :comments bucket rather than
  # split by feature — see the moduledoc note on this being a best-effort
  # hint, not a rigorous taxonomy.
  @table_owner_substrings [
    {"comment", :comments},
    {"like", :comments},
    {"dislike", :comments}
  ]

  @doc """
  Best-effort module-ownership tag for a table name — see `@table_owner_prefixes`
  moduledoc note. Checked in order (prefix families first, then the
  comments/likes/dislikes substring bucket); `:core` is the fallthrough for
  everything else (settings, users, auth, email, entities, shop, billing,
  sync, tickets, storage — features that live in the base package with no
  planned extraction).
  """
  @spec owner_for_table(String.t()) :: atom()
  def owner_for_table(table) when is_binary(table) do
    bare = String.replace_prefix(table, "phoenix_kit_", "")

    Enum.find_value(@table_owner_prefixes, fn {prefix, owner} ->
      if String.starts_with?(bare, prefix), do: owner
    end) ||
      Enum.find_value(@table_owner_substrings, fn {substr, owner} ->
        if String.contains?(bare, substr), do: owner
      end) || :core
  end

  # ---------------------------------------------------------------------------
  # Static generator-authored entries
  # ---------------------------------------------------------------------------

  @doc """
  Data invariants (spec 5.1 minimum set) for upgrade-only transforms that a squash
  cannot replay: verify reports them, --adopt gates on them. Convention: the assert
  SQL returns one row with one boolean column; true = invariant holds.
  """
  def data_invariants do
    [
      %{
        since: 77,
        desc: "V77: tickets_* settings keys were renamed; none may remain",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_settings WHERE key IN " <>
            "('tickets_enabled','tickets_per_page','tickets_comments_enabled'," <>
            "'tickets_internal_notes_enabled','tickets_attachments_enabled'," <>
            "'tickets_allow_reopen','auto_granted_perm:tickets'))"
      },
      %{
        since: 109,
        desc: "V109: customer_service_* settings keys renamed to customer_support_*",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_settings " <>
            "WHERE key LIKE 'customer_service_%')"
      },
      %{
        since: 109,
        desc: "V109: role_permissions module_key uses customer_support",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_role_permissions " <>
            "WHERE module_key IN ('tickets', 'customer_service'))"
      },
      %{
        since: 114,
        desc: "V114: settings integration rows are uuid-keyed; no composite integration:* keys",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_settings " <>
            "WHERE key LIKE 'integration:%')"
      },
      %{
        since: 137,
        desc: "V137: email_logs.aws_message_id unique among non-NULL values",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_email_logs " <>
            "WHERE aws_message_id IS NOT NULL " <>
            "GROUP BY aws_message_id HAVING COUNT(*) > 1)"
      },
      %{
        since: 137,
        desc: "V137: email_events deduplicated for single-occurrence event types",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_email_events " <>
            "WHERE event_type NOT IN ('open','click') " <>
            "GROUP BY email_log_uuid, event_type HAVING COUNT(*) > 1)"
      }
    ]
  end

  @doc """
  System email templates are seeded best-effort by optional modules (their only
  historical call sites, v15.ex:130-151 and v31.ex:523-525, die with the deleted
  files). Emitted as :seed helper entries; consumers MUST wrap the mfa in
  Code.ensure_loaded?/apply/rescue best-effort semantics.
  """
  def template_seed_objects do
    [
      %{
        class: :seed,
        key: {"phoenix_kit_email_templates", "__system_seeder__"},
        id: "seed:phoenix_kit_email_templates:system_seeder",
        since: 15,
        revisions: [{15, %{best_effort: true, source: "v15.ex:130-151"}}],
        presence: :required,
        create_override: {:helper, {Mix.Tasks.PhoenixKit.SeedTemplates, :run, [["--quiet"]]}},
        check_override: "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_email_templates)"
      },
      %{
        class: :seed,
        key: {"phoenix_kit_email_templates", "__billing_seeder__"},
        id: "seed:phoenix_kit_email_templates:billing_seeder",
        since: 31,
        revisions: [{31, %{best_effort: true, source: "v31.ex:523-525"}}],
        presence: :required,
        create_override:
          {:helper, {PhoenixKit.Modules.Emails.Templates, :seed_system_templates, []}},
        check_override: "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_email_templates)"
      }
    ]
  end

  @doc "sha256 over the sorted v*.ex file set (spec 5.1 chain_hash). Offline."
  def chain_hash(migrations_dir) do
    files = migrations_dir |> Path.join("v*.ex") |> Path.wildcard() |> Enum.sort()

    if files == [] do
      raise "no v*.ex migration files found under #{migrations_dir}"
    end

    hash =
      files
      |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
        acc
        |> :crypto.hash_update(Path.basename(file))
        |> :crypto.hash_update("\n")
        |> :crypto.hash_update(File.read!(file))
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {hash, length(files)}
  end

  # ---------------------------------------------------------------------------
  # Manifest emission
  # ---------------------------------------------------------------------------

  @doc """
  Convert intermediate objects (Differ/Bimodality output + template_seed_objects)
  into the emitted spec-5.1 maps: id/class/since/revisions/presence/check/create/
  backfill/owner. :legacy_optional objects get create: nil (repair never creates
  them). Seed rows whose table strategy is :skip are dropped (helper entries
  cover them).
  """
  def build_objects(objects) do
    cols = columns_by_table(objects, &newest_shape/1)

    objects
    |> Enum.reject(&skip_seed_row?/1)
    |> Enum.sort_by(
      &{&1.since, Differ.class_rank(&1.class),
       Differ.constraint_fk_rank(&1.class, newest_shape(&1)), &1.id}
    )
    |> Enum.map(fn object ->
      %{
        id: object.id,
        class: object.class,
        since: object.since,
        revisions: object.revisions,
        presence: object.presence,
        check: object_check(object),
        create: object_create(object, cols),
        backfill: object_backfill(object),
        owner: object_owner(object)
      }
    end)
  end

  defp skip_seed_row?(%{class: :seed, key: {table, _key}} = object) do
    Map.get(@seed_strategies, table) == :skip and not Map.has_key?(object, :create_override)
  end

  defp skip_seed_row?(_object), do: false

  defp object_check(%{check_override: check}), do: check

  defp object_check(%{class: :table, key: table}), do: {:catalog, %{kind: :table, name: table}}

  defp object_check(%{class: :column, key: {table, column}}),
    do: {:catalog, %{kind: :column, table: table, column: column}}

  defp object_check(%{class: :index, key: name} = object) do
    shape = newest_shape(object)
    {:catalog, %{kind: :index, name: templated_name(name, shape), table: shape.table}}
  end

  defp object_check(%{class: :constraint, key: {table, name}} = object) do
    shape = newest_shape(object)
    {:catalog, %{kind: :constraint, table: table, name: templated_name(name, shape)}}
  end

  defp object_check(%{class: :sequence, key: name}),
    do: {:catalog, %{kind: :sequence, name: name}}

  defp object_check(%{class: :function, key: {name, args}}),
    do: {:catalog, %{kind: :function, name: name, args: args}}

  defp object_check(%{class: :extension, key: name}),
    do: {:catalog, %{kind: :extension, name: name}}

  defp object_check(%{class: :seed, key: {table, _value}} = object) do
    shape = newest_shape(object)
    seed_check_sql(table, shape)
  end

  # `key`/`name` is already the CANONICAL bare form for a prefix-embedded
  # index/constraint (Catalog.canonicalize_object_name/2 keys the snapshot by
  # it) — re-attach the marker Catalog stamped on the shape's `name_template`
  # so the RENDERED check/create carries the resolvable prefix-aware form,
  # not the bare canonical one (which is only a valid real name on `public`
  # for the `:exempt` convention, and never valid on its own for `:always`).
  defp templated_name(bare, %{name_template: nil}), do: bare

  defp templated_name(bare, %{name_template: exemption}),
    do: Catalog.name_marker(exemption) <> bare

  defp templated_name(bare, _shape_without_template), do: bare

  # `owner:` dispatch — same class shapes `object_check/1` pattern-matches on,
  # resolved down to "the table this object belongs to" and handed to
  # `owner_for_table/1`. Sequences are named after their owning table by this
  # chain's convention (e.g. `phoenix_kit_warehouse_..._number_seq`), so the
  # same prefix logic applies to a sequence's own key unchanged. Functions
  # and extensions are schema-wide, not table-scoped — always :core.
  # Public (unlike its `object_check`/`object_create` siblings) so
  # `Main.check_owner_mapping!/0`'s offline --check gate can exercise every
  # class's dispatch directly, without needing full check/create shape data.
  @doc false
  def object_owner(%{class: :table, key: table}), do: owner_for_table(table)

  def object_owner(%{class: :column, key: {table, _column}}), do: owner_for_table(table)

  def object_owner(%{class: :index} = object), do: owner_for_table(newest_shape(object).table)

  def object_owner(%{class: :constraint, key: {table, _name}}), do: owner_for_table(table)

  def object_owner(%{class: :sequence, key: name}), do: owner_for_table(name)

  def object_owner(%{class: :function}), do: :core

  def object_owner(%{class: :extension}), do: :core

  def object_owner(%{class: :seed, key: {table, _value}}), do: owner_for_table(table)

  defp object_create(%{presence: :legacy_optional}, _cols), do: nil

  defp object_create(%{create_override: create}, _cols), do: create

  defp object_create(%{class: :extension, key: name}, _cols),
    do: {:helper, {PhoenixKit.Migrations.Postgres.Helpers, :ensure_extension!, [name]}}

  defp object_create(%{class: :function, key: {"uuid_generate_v7", _args}}, _cols),
    do: {:helper, {PhoenixKit.Migrations.Postgres.Helpers, :ensure_uuid_v7_function, [:prefix]}}

  defp object_create(%{class: :function} = object, _cols), do: newest_shape(object).definition

  defp object_create(%{class: :sequence, key: name} = object, _cols),
    do: sequence_create_sql(name, newest_shape(object))

  # Tables are created EMPTY: every surviving column is its own :column object
  # (revision-scoped ADD COLUMN IF NOT EXISTS), the PK its own :constraint. This
  # keeps repair fully additive and revision-scoped whether the table was missing
  # entirely or partially present. The baseline renderer assembles readable
  # CREATE TABLE (columns...) statements instead.
  defp object_create(%{class: :table, key: table}, _cols),
    do: "CREATE TABLE IF NOT EXISTS __SCHEMA__.#{table} ()"

  defp object_create(%{class: :column, key: {table, column}} = object, _cols) do
    shape = newest_shape(object)

    "ALTER TABLE __SCHEMA__.#{table} ADD COLUMN IF NOT EXISTS " <>
      column_def(column, shape, not_null: shape.not_null and shape.default != nil)
  end

  defp object_create(%{class: :index} = object, _cols),
    do: index_create_sql(newest_shape(object).definition)

  defp object_create(%{class: :constraint, key: {table, name}} = object, _cols) do
    shape = newest_shape(object)
    guarded_constraint_sql(table, templated_name(name, shape), shape.definition)
  end

  defp object_create(%{class: :seed, key: {table, _value}} = object, cols),
    do: seed_insert_sql(table, newest_shape(object), Map.get(cols, table, %{}))

  # Repair may backfill ONLY a column it itself just added, from its declared
  # default (spec D7 / 6.2).
  defp object_backfill(%{class: :column} = object) do
    shape = newest_shape(object)
    if shape.not_null and shape.default != nil, do: :default, else: nil
  end

  defp object_backfill(_object), do: nil

  def newest_shape(%{revisions: revisions}) do
    {_version, shape} = List.last(revisions)
    shape
  end

  @doc "Newest revision shape with as_of_version <= floor, or nil."
  def shape_at(%{revisions: revisions}, floor) do
    revisions
    |> Enum.filter(fn {version, _shape} -> version <= floor end)
    |> List.last()
    |> case do
      nil -> nil
      {_version, shape} -> shape
    end
  end

  defp columns_by_table(objects, selector) do
    objects
    |> Enum.filter(&(&1.class == :column))
    |> Enum.group_by(fn %{key: {table, _col}} -> table end)
    |> Map.new(fn {table, cols} ->
      {table,
       cols
       |> Enum.map(fn %{key: {_t, col}} = object -> {col, selector.(object)} end)
       |> Enum.reject(fn {_col, shape} -> is_nil(shape) end)
       |> Map.new()}
    end)
  end

  @doc """
  Render the ExpectedSchema module source. `meta` carries :initial/:current/
  :chain_hash/:file_count; opts :module overrides the module name (fixture use).
  Output is mix-format-clean (Code.format_string!).
  """
  def render_manifest(objects, meta, opts \\ []) do
    module = Keyword.get(opts, :module, "PhoenixKit.Migrations.ExpectedSchema")
    emitted = build_objects(objects)
    objects_literal = inspect_literal(emitted)
    invariants_literal = inspect_literal(data_invariants())

    source = """
    defmodule #{module} do
      @moduledoc false

      # Generated by dev_docs/squash/generate_baseline.exs — DO NOT EDIT, regenerate
      # (spec: dev_docs/plans/2026-07-14-squash-migrations-spec.md, sections 5.1/8.3).
      # NEVER hand-merged: after any rebase touching lib/phoenix_kit/migrations/postgres/
      # v*.ex, regenerate; chain_hash/0 is the staleness detector (release_check + unit
      # test assert it).
      #
      # Chain at generation: initial=#{meta.initial} current=#{meta.current} files=#{meta.file_count}
      #
      # Conventions:
      #
      # * "__SCHEMA__" tokens are replaced with the validated prefix by objects/1 and
      #   data_invariants/1 (schema-anchored SQL; nspname literals in DO-block guards).
      # * create: {:helper, {mod, fun, args}} — invoked via apply/3; the :prefix atom in
      #   args stands for the runtime prefix. Email-template seed helpers reference
      #   OPTIONAL modules and must run under Code.ensure_loaded?/apply/rescue
      #   best-effort semantics (v15/v31 lineage); their shape carries best_effort: true.
      # * revisions are ordered {as_of_version, shape}; consumers select the newest
      #   revision with as_of_version <= the DB's raw comment version (spec 6.1). The
      #   :create string reflects the NEWEST revision — healing an older-comment DB must
      #   rebuild from the SELECTED revision's shape (:definition/:type/:default carry
      #   enough rendered SQL for that).
      # * presence: :legacy_optional marks spec-3.7 bimodal drift (fresh single-run vs
      #   incrementally upgraded installs); verify reports info-level either way, repair
      #   NEVER creates them (create: nil).
      # * Oban objects are deliberately absent — delegated to Oban.Migration (spec 6.1).
      # * The version-marker COMMENT is not an object; migration entry points own it.
      # * data_invariants assert SQL returns one row/one boolean column; true = holds.
      #   Report-only; also the --adopt gate (spec 6.4 R4).
      # * Structural note for the repair engine (P2): expression/definition texts were
      #   rendered by the generation server (PG #{meta[:server] || "17.x"}); compare
      #   structurally per spec 6.2 (re-normalize through the TARGET server's pg_get_expr,
      #   tolerate schema-qualification differences), never by raw text equality across
      #   PG majors.

      alias PhoenixKit.Migrations.Postgres.Helpers

      @schema_token "__SCHEMA__"
      @name_marker_exempt "__PK_NAME_EXEMPT__"
      @name_marker_always "__PK_NAME_ALWAYS__"
      @chain_hash "#{meta.chain_hash}"

      def objects(prefix) do
        prefix = normalize_prefix!(prefix)
        Enum.map(raw_objects(), &materialize_object(&1, prefix))
      end

      def data_invariants(prefix \\\\ "public") do
        prefix = normalize_prefix!(prefix)

        Enum.map(raw_data_invariants(), fn invariant ->
          %{invariant | assert: String.replace(invariant.assert, @schema_token, prefix)}
        end)
      end

      def chain_hash, do: @chain_hash

      defp normalize_prefix!(nil), do: "public"

      defp normalize_prefix!(prefix) do
        Helpers.validate_prefix!(prefix)
        prefix
      end

      defp materialize_object(object, prefix) do
        %{
          object
          | create: materialize_create(object.create, prefix),
            check: materialize_check(object.check, prefix),
            revisions:
              Enum.map(object.revisions, fn {version, shape} ->
                {version, materialize_shape(shape, prefix)}
              end)
        }
      end

      defp materialize_create(nil, _prefix), do: nil

      defp materialize_create({:helper, {mod, fun, args}}, prefix) do
        args =
          Enum.map(args, fn
            :prefix -> prefix
            other -> other
          end)

        {:helper, {mod, fun, args}}
      end

      defp materialize_create(sql, prefix) when is_binary(sql),
        do: materialize_value(sql, prefix)

      defp materialize_check({:catalog, spec}, prefix),
        do: {:catalog, Map.new(spec, fn {k, v} -> {k, materialize_value(v, prefix)} end)}

      defp materialize_check(sql, prefix) when is_binary(sql),
        do: materialize_value(sql, prefix)

      defp materialize_shape(shape, prefix) do
        Map.new(shape, fn {key, value} -> {key, materialize_value(value, prefix)} end)
      end

      defp materialize_value(value, prefix) when is_binary(value) do
        value
        |> String.replace(@schema_token, prefix)
        |> String.replace(@name_marker_exempt, if(prefix == "public", do: "", else: prefix <> "_"))
        |> String.replace(@name_marker_always, prefix <> "_")
      end

      defp materialize_value(value, prefix) when is_list(value),
        do: Enum.map(value, &materialize_value(&1, prefix))

      defp materialize_value(value, _prefix), do: value

      defp raw_objects do
        #{objects_literal}
      end

      defp raw_data_invariants do
        #{invariants_literal}
      end
    end
    """

    format(source)
  end

  # ---------------------------------------------------------------------------
  # Baseline emission
  # ---------------------------------------------------------------------------

  @doc """
  Render the V{floor} baseline module from the since <= floor slice of the
  intermediate objects (presence :required only; :legacy_optional drift is never
  reproduced), each object at its newest revision <= floor.

  opts :module overrides the module name (fixture use). opts :drops (default
  `[]`) is `Differ.catalog/2`'s `drops` list — objects absent from the FINAL
  (fully-migrated) state are correctly excluded from the plain `objects` list
  (the manifest describes only the steady state), but an object introduced
  at/before the floor and dropped by a delta ABOVE the floor still belongs in
  the BASELINE — it existed at V{floor}, and the surviving delta drops it when
  the chain actually runs. `floor_carryover/2` re-admits exactly those.
  """
  def render_baseline(objects, floor, meta, opts \\ []) do
    module = Keyword.get(opts, :module, "PhoenixKit.Migrations.Postgres.V#{floor}")
    drops = Keyword.get(opts, :drops, [])
    objects = objects ++ floor_carryover(drops, floor)

    slice =
      objects
      |> Enum.filter(&(&1.presence == :required and &1.since <= floor))
      # Real captured rows for :skip-strategy seed tables (email_templates: the
      # Mix-task seeder can insert actual rows during a live stepwise run) are
      # helper-seeded, never their own INSERT — the same exclusion build_objects/1
      # applies for the manifest. Without it, seed_insert_sql/3 hits its
      # "unreachable" branch the first time a real template row exists.
      |> Enum.reject(&skip_seed_row?/1)
      |> Enum.map(fn object -> Map.put(object, :shape, shape_at(object, floor)) end)
      |> Enum.reject(&is_nil(&1.shape))
      |> Enum.sort_by(
        &{&1.since, Differ.class_rank(&1.class), Differ.constraint_fk_rank(&1.class, &1.shape),
         &1.id}
      )

    by_class = Enum.group_by(slice, & &1.class)
    cols = columns_by_table(slice, & &1.shape)
    helper_seeds = for %{create_override: {:helper, mfa}} <- Map.get(by_class, :seed, []), do: mfa

    up_lines =
      baseline_up(by_class, cols, helper_seeds, floor)

    down_lines = baseline_down(by_class)

    source =
      Enum.join(
        baseline_header(module, floor, meta) ++
          up_lines ++ [""] ++ down_lines ++ [""] ++ baseline_private(helper_seeds) ++ ["end", ""],
        "\n"
      )

    format(source)
  end

  # Objects dropped ABOVE the floor (introduced at/before it, removed by a
  # still-existing delta module) belong in the baseline slice even though
  # `Differ.catalog/2` excludes them from the plain manifest `objects` list
  # (see `render_baseline/4`'s moduledoc for the full rationale — this is
  # the fix for a live regeneration crash: `V152.up/1`'s bare `ALTER COLUMN
  # list_uuid DROP NOT NULL` against a V135 baseline that never created the
  # column, because V156 — above the floor — drops it later).
  #
  # `since <= floor`: it must have existed at the floor to belong in the
  # baseline at all. `dropped_at > floor`: dropped AT OR BELOW the floor is
  # correctly excluded (it never reached the floor's final state — the
  # ordinary case `catalog/2` already always got right).
  defp floor_carryover(drops, floor) do
    for %{since: since, dropped_at: dropped_at} = drop <- drops,
        since <= floor,
        dropped_at > floor do
      %{
        class: drop.class,
        key: drop.key,
        id: drop.id,
        since: drop.since,
        revisions: drop.revisions,
        presence: :required
      }
    end
  end

  defp baseline_header(module, floor, meta) do
    [
      "defmodule #{module} do",
      "  @moduledoc false",
      "",
      "  # V#{floor}: squash baseline — consolidation of V01..V#{floor} (spec section 5.1).",
      "  # Generated by dev_docs/squash/generate_baseline.exs from a real migrated scratch",
      "  # schema — DO NOT EDIT, regenerate and re-review.",
      "  # Chain at generation: initial=#{meta.initial} current=#{meta.current} " <>
        "chain_hash=#{meta.chain_hash}",
      "  #",
      "  # Class order: extensions < functions < sequences < tables < indexes <",
      "  # constraints < Oban delegation < seeds < version stamp (columns fold into",
      "  # CREATE TABLE). Every shape is AT-FLOOR (newest revision as_of_version <=",
      "  # V#{floor}) — NOT necessarily final-state: an object a still-present delta",
      "  # above this floor later alters or drops is emitted here in the form that",
      "  # delta expects to find, so its ALTER/DROP has something to act on when the",
      "  # chain actually runs (confirmed live: V152's bare `list_uuid` NOT NULL",
      "  # relax against a floor-135 baseline that omitted the column entirely).",
      "  # Constraints keep their HISTORICAL names (pre-rename *_pkey names survive",
      "  # table renames), so fresh installs match upgraded installs (S1).",
      "",
      "  use Ecto.Migration",
      "",
      "  alias PhoenixKit.Migrations.Postgres.Helpers",
      ""
    ]
  end

  defp baseline_up(by_class, cols, helper_seeds, floor) do
    extensions =
      for object <- Map.get(by_class, :extension, []) do
        "    Helpers.ensure_extension!(#{inspect(object.key)})"
      end

    functions =
      Enum.map(Map.get(by_class, :function, []), fn
        %{key: {"uuid_generate_v7", _args}} -> "    Helpers.ensure_uuid_v7_function(prefix)"
        object -> render_execute(object.shape.definition)
      end)

    sequences =
      for object <- Map.get(by_class, :sequence, []) do
        render_execute(sequence_create_sql(object.key, object.shape))
      end

    tables =
      for object <- Map.get(by_class, :table, []) do
        render_execute(table_create_sql(object.key, Map.get(cols, object.key, %{})))
      end

    indexes =
      for object <- Map.get(by_class, :index, []) do
        render_execute(index_create_sql(object.shape.definition))
      end

    constraints =
      for %{key: {table, name}} = object <- Map.get(by_class, :constraint, []) do
        templated = templated_name(name, object.shape)
        render_execute(guarded_constraint_sql(table, templated, object.shape.definition))
      end

    seeds =
      by_class
      |> Map.get(:seed, [])
      |> Enum.reject(&Map.has_key?(&1, :create_override))
      |> Enum.map(fn %{key: {table, _value}} = object ->
        render_execute(seed_insert_sql(table, object.shape, Map.get(cols, table, %{})))
      end)

    seed_helper_lines =
      if helper_seeds == [] do
        []
      else
        [
          "",
          "    # Best-effort email-template seeding (v15/v31 lineage) needs flushed tables.",
          "    flush()",
          "    seed_best_effort_helpers()"
        ]
      end

    # `pn` (prefix-name form: "" on public, "#{prefix}_" otherwise — mirrors
    # Catalog's `:exempt` convention, v56.ex/v61.ex's prefix_index_name/2)
    # is only bound when this floor slice actually contains an object
    # needing it — an unconditional bind would be a compiler warning (and a
    # `--warnings-as-errors` failure once this file lands in lib/) on any
    # slice with none.
    pn_line =
      if Enum.any?(indexes ++ constraints, &String.contains?(&1, interp_pn())) do
        [~s[    pn = if prefix == "public", do: "", else: "] <> interp_prefix() <> ~s[_"]]
      else
        []
      end

    [
      "  def up(opts) do",
      ~s[    prefix = Map.get(opts, :prefix, "public")],
      ~s[    create_schema = Map.get(opts, :create_schema, prefix != "public")],
      "    Helpers.validate_prefix!(prefix)",
      ~s[    p = "] <> interp_prefix() <> ~s[."]
    ] ++
      pn_line ++
      [
        "",
        "    ensure_schema!(prefix, create_schema)",
        "",
        "    # -- extensions (immediate, privilege-aware; never bare CREATE EXTENSION)"
      ] ++
      extensions ++
      ["", "    # -- functions (schema-qualified; never search_path-dependent)"] ++
      functions ++
      ["", "    # -- sequences (before tables: nextval() column defaults)"] ++
      sequences ++
      ["", "    # -- tables (at-floor shapes; a delta above the floor may still alter/drop)"] ++
      tables ++
      ["", "    # -- indexes (bare names on CREATE)"] ++
      indexes ++
      ["", "    # -- constraints (name-anchored guards; no regclass casts)"] ++
      constraints ++
      [
        "",
        "    # -- Oban (delegated, never inlined; create_schema: false is load-bearing, V27)",
        "    Oban.Migration.up(prefix: prefix, create_schema: false)",
        "",
        "    # -- seeds (at-floor values; DO NOTHING / WHERE NOT EXISTS only)"
      ] ++
      seeds ++
      seed_helper_lines ++
      [
        "",
        "    # -- version stamp (single-step runs get no auto-stamp; a multi-step",
        "    #    range-end stamp overwrites afterwards — correct either way, S15)",
        ~s[    execute("COMMENT ON TABLE ] <>
          interp_p() <> ~s[phoenix_kit IS '#{floor}'")],
        "  end"
      ]
  end

  defp baseline_down(by_class) do
    tables =
      by_class
      |> Map.get(:table, [])
      |> Enum.reverse()
      |> Enum.map(fn object ->
        ~s[    execute("DROP TABLE IF EXISTS ] <> interp_p() <> ~s[#{object.key} CASCADE")]
      end)

    sequences =
      by_class
      |> Map.get(:sequence, [])
      |> Enum.reverse()
      |> Enum.map(fn object ->
        ~s[    execute("DROP SEQUENCE IF EXISTS ] <> interp_p() <> ~s[#{object.key}")]
      end)

    functions =
      by_class
      |> Map.get(:function, [])
      |> Enum.reverse()
      |> Enum.map(fn %{key: {name, args}} ->
        ~s[      execute("DROP FUNCTION IF EXISTS ] <> interp_p() <> ~s[#{name}(#{args})")]
      end)

    function_block =
      if functions == [] do
        []
      else
        [
          "",
          "    # Schema-scoped functions are dropped only for named-schema installs: a",
          "    # public install's functions may be shared with other applications in the",
          "    # database (never drop shared extensions / public functions).",
          ~s[    if prefix != "public" do]
        ] ++ functions ++ ["    end"]
      end

    [
      "  def down(opts) do",
      ~s[    prefix = Map.get(opts, :prefix, "public")],
      "    Helpers.validate_prefix!(prefix)",
      ~s[    p = "] <> interp_prefix() <> ~s[."],
      "",
      "    # Oban teardown via delegation (V27 semantics)",
      "    Oban.Migration.down(prefix: prefix, version: 1)",
      "",
      "    # Tables in reverse creation order; dropping the phoenix_kit meta table",
      "    # removes the version comment, so migrated_version/1 reports 0.",
      ""
    ] ++
      tables ++ [""] ++ sequences ++ function_block ++ ["  end"]
  end

  defp baseline_private(helper_seeds) do
    seed_helper =
      if helper_seeds == [] do
        []
      else
        mfas = Enum.map_join(helper_seeds, ",\n", fn mfa -> "          #{inspect(mfa)}" end)

        [
          "",
          "  # Best-effort (v15/v31 lineage): the seeder modules are OPTIONAL — absent in",
          "  # production releases and in installs without the emails module; failures",
          "  # must never abort the baseline.",
          "  defp seed_best_effort_helpers do",
          "    for {mod, fun, args} <- [",
          mfas,
          "        ] do",
          "      case Code.ensure_loaded(mod) do",
          "        {:module, _} ->",
          "          try do",
          "            # credo:disable-for-next-line Credo.Check.Refactor.Apply",
          "            apply(mod, fun, args)",
          "          rescue",
          "            error ->",
          ~s[              IO.puts("Warning: email-template seeding skipped: " <> inspect(error))],
          "          end",
          "",
          "        {:error, _} ->",
          "          :ok",
          "      end",
          "    end",
          "",
          "    :ok",
          "  end"
        ]
      end

    [
      "  # V01 semantics: CREATE SCHEMA only when missing and requested — a bare",
      "  # CREATE SCHEMA IF NOT EXISTS fails its privilege check for low-privilege",
      "  # roles even when the schema exists. Immediate query: this module is the",
      "  # first of any fresh run, so nothing is queued yet.",
      ~s[  defp ensure_schema!("public", _create_schema), do: :ok],
      "",
      "  defp ensure_schema!(prefix, create_schema) do",
      "    %{rows: [[exists]]} =",
      "      repo().query!(",
      ~s[        "SELECT EXISTS (SELECT FROM information_schema.schemata WHERE schema_name = $1)",],
      "        [prefix],",
      "        log: false",
      "      )",
      "",
      "    cond do",
      "      exists ->",
      "        :ok",
      "",
      "      create_schema ->",
      "        # prefix is validated ([a-z_][a-z0-9_]*), safe unquoted",
      "        repo().query!(\"CREATE SCHEMA \" <> prefix, [], log: false)",
      "",
      "      true ->",
      "        raise \"PhoenixKit baseline: schema \" <>",
      "                inspect(prefix) <>",
      "                \" does not exist and create_schema: false was given; \" <>",
      "                \"create the schema or pass create_schema: true\"",
      "    end",
      "",
      "    :ok",
      "  end"
    ] ++ seed_helper
  end

  # ---------------------------------------------------------------------------
  # SQL builders (shared manifest/baseline; all emit __SCHEMA__ tokens)
  # ---------------------------------------------------------------------------

  def column_def(name, shape, opts \\ []) do
    not_null = Keyword.get(opts, :not_null, shape.not_null)

    ~s("#{name}" #{shape.type}) <>
      if(shape.default, do: " DEFAULT #{shape.default}", else: "") <>
      if(not_null, do: " NOT NULL", else: "")
  end

  def table_create_sql(table, columns) do
    body =
      columns
      |> Enum.sort_by(fn {_col, shape} -> shape.pos end)
      |> Enum.map_join(",\n", fn {col, shape} -> "  " <> column_def(col, shape) end)

    if body == "" do
      "CREATE TABLE IF NOT EXISTS __SCHEMA__.#{table} ()"
    else
      "CREATE TABLE IF NOT EXISTS __SCHEMA__.#{table} (\n" <> body <> "\n)"
    end
  end

  def sequence_create_sql(name, shape) do
    "CREATE SEQUENCE IF NOT EXISTS __SCHEMA__.#{name} AS #{shape.data_type} " <>
      "INCREMENT BY #{shape.increment} MINVALUE #{shape.min} MAXVALUE #{shape.max} " <>
      "START WITH #{shape.start} CACHE #{shape.cache}" <>
      if(shape.cycle, do: " CYCLE", else: "")
  end

  # pg_get_indexdef output: index NAME is bare (prefix rule), table is qualified.
  def index_create_sql(definition) do
    cond do
      String.starts_with?(definition, "CREATE UNIQUE INDEX ") ->
        String.replace_prefix(
          definition,
          "CREATE UNIQUE INDEX ",
          "CREATE UNIQUE INDEX IF NOT EXISTS "
        )

      String.starts_with?(definition, "CREATE INDEX ") ->
        String.replace_prefix(definition, "CREATE INDEX ", "CREATE INDEX IF NOT EXISTS ")

      true ->
        raise "unexpected index definition (no CREATE [UNIQUE] INDEX prefix): #{definition}"
    end
  end

  # Guard idiom mandated by CLAUDE.md/V146: name-based pg_constraint JOIN anchored
  # on nspname — never a regclass cast. Queued DO block; evaluated at flush time.
  def guarded_constraint_sql(table, name, definition) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{name}'
          AND t.relname = '#{table}'
          AND n.nspname = '__SCHEMA__'
      ) THEN
        ALTER TABLE __SCHEMA__.#{table} ADD CONSTRAINT #{name} #{definition};
      END IF;
    END
    $$\
    """
  end

  def seed_check_sql(table, shape) do
    "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.#{table} " <>
      "WHERE #{quote_ident(shape.key_column)} = #{escape_str(shape.key_value)})"
  end

  def seed_insert_sql(table, shape, table_cols) do
    case Map.get(@seed_strategies, table) do
      nil ->
        raise "no seed emission strategy for #{table} — extend " <>
                "PhoenixKit.Squash.Generate.Emitter.@seed_strategies deliberately"

      :skip ->
        raise "seed rows for #{table} are :skip (helper-seeded); this should be unreachable"

      strategy ->
        build_seed_sql(strategy, table, shape, table_cols)
    end
  end

  defp build_seed_sql(:conflict_key, table, shape, table_cols) do
    {cols, vals} = seed_cols_and_vals(table, shape, table_cols, [])

    "INSERT INTO __SCHEMA__.#{table} (#{cols})\n" <>
      "VALUES (#{vals})\n" <>
      "ON CONFLICT (#{quote_ident(shape.key_column)}) DO NOTHING"
  end

  # V20 bucket class: no unique constraint to hang ON CONFLICT on (spec 5.1).
  defp build_seed_sql(:where_not_exists, table, shape, table_cols) do
    {cols, vals} = seed_cols_and_vals(table, shape, table_cols, [])

    "INSERT INTO __SCHEMA__.#{table} (#{cols})\n" <>
      "SELECT #{vals}\n" <>
      "WHERE NOT EXISTS (\n" <>
      "  SELECT 1 FROM __SCHEMA__.#{table} " <>
      "WHERE #{quote_ident(shape.key_column)} = #{escape_str(shape.key_value)}\n" <>
      ")"
  end

  # V53/V55 lineage: conditional on the Admin role existing; role identity resolved
  # by name at execution time.
  defp build_seed_sql(:admin_role_select, table, shape, table_cols) do
    {cols, vals} = seed_cols_and_vals(table, shape, table_cols, ["role_uuid"])

    "INSERT INTO __SCHEMA__.#{table} (#{quote_ident("role_uuid")}, #{cols})\n" <>
      "SELECT r.uuid, #{vals}\n" <>
      "FROM __SCHEMA__.phoenix_kit_user_roles r\n" <>
      "WHERE r.name = 'Admin'\n" <>
      "ON CONFLICT DO NOTHING"
  end

  # Column list = business key first + remaining captured values (sorted) + NOW()
  # fill-ins for NOT NULL default-less timestamp columns. Any other NOT NULL
  # default-less column the strategy cannot fill raises — loud, not guessed.
  defp seed_cols_and_vals(table, shape, table_cols, strategy_provided) do
    value_cols =
      [shape.key_column | Enum.sort(Map.keys(shape.values) -- [shape.key_column])]

    ts_cols =
      table_cols
      |> Enum.filter(fn {col, col_shape} ->
        col_shape.not_null and is_nil(col_shape.default) and
          String.starts_with?(col_shape.type, "timestamp") and col not in value_cols
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    unfillable =
      table_cols
      |> Enum.filter(fn {col, col_shape} ->
        col_shape.not_null and is_nil(col_shape.default) and
          col not in value_cols and col not in ts_cols and col not in strategy_provided
      end)
      |> Enum.map(&elem(&1, 0))

    if unfillable != [] do
      raise "seed emission for #{table}: NOT NULL default-less columns " <>
              "#{inspect(unfillable)} cannot be filled by the strategy"
    end

    cols = Enum.map_join(value_cols ++ ts_cols, ", ", &quote_ident/1)

    vals =
      Enum.map_join(value_cols, ", ", fn col ->
        literal(Map.fetch!(shape.values, col), col_type(table_cols, col))
      end) <>
        Enum.map_join(ts_cols, "", fn _col -> ", NOW()" end)

    {cols, vals}
  end

  defp col_type(table_cols, col) do
    case Map.get(table_cols, col) do
      nil -> nil
      shape -> shape.type
    end
  end

  defp literal(nil, _type), do: "NULL"
  defp literal(true, _type), do: "TRUE"
  defp literal(false, _type), do: "FALSE"
  defp literal(value, _type) when is_integer(value) or is_float(value), do: to_string(value)
  defp literal(value, "jsonb") when is_binary(value), do: escape_str(value) <> "::jsonb"
  defp literal(value, _type) when is_binary(value), do: escape_str(value)

  # A real Postgres array column (`text[]`, ... — `@columns_sql`'s
  # `pg_catalog.format_type/2` always suffixes the element type with `[]`)
  # needs its own literal syntax: `'{"a","b"}'::text[]`. JSON array syntax
  # (`["a","b"]`) is NOT valid `text[]` input and would fail the INSERT.
  # Anything else compound — the column type is unknown or not an array, or
  # the value is a map — has no native bare-literal SQL syntax here (Postgres
  # has no untyped "map" literal), so it goes through canonical JSON with an
  # explicit `::jsonb` cast instead.
  defp literal(value, type) when is_list(value) do
    if is_binary(type) and String.ends_with?(type, "[]") do
      array_literal(value, type)
    else
      escape_str(canonical_json(value)) <> "::jsonb"
    end
  end

  defp literal(value, _type) when is_map(value) do
    escape_str(canonical_json(value)) <> "::jsonb"
  end

  defp literal(value, type),
    do: raise("unsupported seed literal #{inspect(value)} for column type #{inspect(type)}")

  # `type` is the full `format_type` text (e.g. "text[]") — reused verbatim
  # as the cast suffix. Elements are individually double-quoted and escaped
  # per the Postgres array-literal grammar (distinct from JSON string
  # escaping, though `\` and `"` happen to escape the same way); the whole
  # `{...}` body then goes through `escape_str/1` like any other string
  # literal, so a single quote inside an element is still handled correctly.
  defp array_literal(elements, type) do
    body = "{" <> Enum.map_join(elements, ",", &array_element/1) <> "}"
    escape_str(body) <> "::" <> type
  end

  defp array_element(nil), do: "NULL"

  defp array_element(el) when is_binary(el) do
    escaped =
      el
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp array_element(el), do: to_string(el)

  # Deterministic JSON encoding for seed values captured as lists/maps — map
  # keys are sorted so the SAME logical value always produces byte-identical
  # text (manifest determinism: the `--check` gate asserts two consecutive
  # emissions from the same objects are byte-equal). Deliberately not the
  # stdlib `JSON.encode/1` (Elixir 1.18+): it does not promise map key
  # order, which would make re-running the generator against the same DB
  # state risk a different manifest byte for byte.
  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Float.to_string(value)
  defp canonical_json(value) when is_binary(value), do: canonical_json_string(value)

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value) when is_map(value) do
    body =
      value
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join(",", fn {k, v} -> canonical_json_string(k) <> ":" <> canonical_json(v) end)

    "{" <> body <> "}"
  end

  defp canonical_json_string(str) do
    escaped =
      str
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  defp escape_str(value), do: "'" <> String.replace(value, "'", "''") <> "'"

  defp quote_ident(name), do: ~s("#{name}")

  # ---------------------------------------------------------------------------
  # Source assembly primitives
  # ---------------------------------------------------------------------------

  # Literal `\#{p}` / `\#{prefix}` / `\#{pn}` character sequences for the
  # GENERATED module, built from @pound so this generator never contains an
  # escapable interpolation.
  defp interp_p, do: @pound <> "{p}"
  defp interp_prefix, do: @pound <> "{prefix}"
  defp interp_pn, do: @pound <> "{pn}"

  # SQL (carrying __SCHEMA__ tokens) -> an execute() source line/heredoc whose
  # interpolations resolve inside the generated module (p / prefix locals).
  def render_execute(sql) do
    snippet = sql_snippet(sql)

    if String.contains?(snippet, "\n") or String.length(snippet) > 72 or
         String.contains?(snippet, "\"") do
      body =
        snippet
        |> String.split("\n")
        |> Enum.map_join("\n", fn
          "" -> ""
          line -> "    " <> line
        end)

      ~s[    execute("""\n] <> body <> ~s[\n    """)]
    else
      ~s[    execute("] <> snippet <> ~s[")]
    end
  end

  # Escape FIRST (backslashes and any pre-existing pound-brace so heredocs cannot
  # activate them), then swap the __SCHEMA__ tokens for live interpolations.
  def sql_snippet(sql) do
    if String.contains?(sql, ~s(""")) do
      raise "SQL contains a triple-quote sequence; cannot emit as heredoc: #{sql}"
    end

    sql
    |> String.replace("\\", "\\\\")
    |> String.replace(@pound <> "{", "\\" <> @pound <> "{")
    |> String.replace("'" <> @schema_token <> "'", "'" <> interp_prefix() <> "'")
    |> String.replace(@schema_token <> ".", interp_p())
    |> String.replace(@schema_token, interp_prefix())
    # Prefix-embedded object names (Catalog.canonicalize_object_name/2) — the
    # `:exempt` marker resolves via the `pn` local (bare on public, "prefix_"
    # otherwise — see needs_pn?/1's call site, which conditionally binds it);
    # `:always` is unconditional, so it inlines `prefix` directly with no new
    # local needed.
    |> String.replace(Catalog.name_marker(:exempt), interp_pn())
    |> String.replace(Catalog.name_marker(:always), interp_prefix() <> "_")
  end

  def inspect_literal(data) do
    inspect(data,
      limit: :infinity,
      printable_limit: :infinity,
      charlists: :as_lists,
      pretty: true,
      width: 98
    )
  end

  def format(source) do
    IO.iodata_to_binary([Code.format_string!(source), "\n"])
  end
end

defmodule PhoenixKit.Squash.Generate.Fixture do
  @moduledoc false

  # Embedded fixture catalog (no DB) proving the whole pure pipeline in --check:
  # differ semantics, bimodality handling, inventory guard, and — critically — that
  # the code generators produce PARSEABLE, COMPILABLE Elixir (the June draft died
  # exactly here). Shapes mirror Catalog.snapshot/2 structures byte-for-byte.

  alias PhoenixKit.Squash.Generate.Bimodality
  alias PhoenixKit.Squash.Generate.Catalog
  alias PhoenixKit.Squash.Generate.Differ
  alias PhoenixKit.Squash.Generate.Emitter
  alias PhoenixKit.Squash.Generate.InventoryGuard

  @pound "#"

  @widgets "phoenix_kit_fix_widgets"
  @owners "phoenix_kit_fix_owners"

  @meta %{
    initial: 1,
    current: 5,
    chain_hash: String.duplicate("ab", 32),
    file_count: 5
  }

  def run_all do
    snapshots = [{1, snapshot_v1()}, {5, snapshot_v5()}]
    history = Differ.history(snapshots)
    {_v, final} = List.last(snapshots)
    %{objects: objects, drops: drops} = Differ.catalog(history, final)

    check_differ!(objects, drops)

    single = single_final()
    bidiff = Bimodality.diff(final, single)
    check_bimodality!(bidiff)

    {objects, notes} = Bimodality.apply_to_objects(objects, history, bidiff)
    check_legacy!(objects, notes, bidiff)

    objects = objects ++ [fixture_helper_seed(), fixture_real_template_row()]

    InventoryGuard.assert_catalog!(objects)
    check_guard_rejects!(objects)

    manifest_src = check_manifest!(objects)
    check_manifest_compiles!(manifest_src)
    check_baseline!(objects, drops)
    check_mismatch_detection!(final)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixture snapshots
  # ---------------------------------------------------------------------------

  defp snapshot_v1 do
    %{
      tables: %{@widgets => %{}},
      columns: %{
        {@widgets, "uuid"} => %{
          type: "uuid",
          not_null: true,
          default: "__SCHEMA__.uuid_generate_v7()",
          pos: 1
        },
        {@widgets, "name"} => %{
          type: "character varying(50)",
          not_null: true,
          default: nil,
          pos: 2
        },
        {@widgets, "legacy_col"} => %{type: "integer", not_null: false, default: nil, pos: 3},
        {@widgets, "inserted_at"} => %{
          type: "timestamp with time zone",
          not_null: true,
          default: nil,
          pos: 4
        }
      },
      indexes: %{
        "phoenix_kit_fix_widgets_name_index" => %{
          table: @widgets,
          unique: false,
          method: "btree",
          definition:
            "CREATE INDEX phoenix_kit_fix_widgets_name_index ON __SCHEMA__." <>
              "phoenix_kit_fix_widgets USING btree (name)",
          predicate: nil,
          keys: ["name"],
          opclasses: ["text_ops"]
        }
      },
      constraints: %{
        {@widgets, "phoenix_kit_fix_widgets_pkey"} => %{
          type: "p",
          definition: "PRIMARY KEY (uuid)",
          columns: ["uuid"],
          foreign_table: nil,
          foreign_columns: nil,
          on_delete: nil,
          on_update: nil
        }
      },
      sequences: %{
        "phoenix_kit_fix_counter_seq" => %{
          data_type: "bigint",
          start: 1,
          increment: 1,
          min: 1,
          max: 9_223_372_036_854_775_807,
          cache: 1,
          cycle: false
        }
      },
      functions: %{
        {"uuid_generate_v7", ""} => %{
          returns: "uuid",
          language: "plpgsql",
          body_md5: "11111111111111111111111111111111",
          definition:
            "CREATE OR REPLACE FUNCTION __SCHEMA__.uuid_generate_v7()\n RETURNS uuid\n" <>
              " LANGUAGE plpgsql\nAS $function$\nBEGIN\n  RETURN gen_random_uuid();\n" <>
              "END\n$function$\n"
        },
        {"extract_fix_slug", "input text"} => %{
          returns: "text",
          language: "plpgsql",
          body_md5: "22222222222222222222222222222222",
          definition:
            "CREATE OR REPLACE FUNCTION __SCHEMA__.extract_fix_slug(input text)\n" <>
              " RETURNS text\n LANGUAGE plpgsql\nAS $function$\nBEGIN\n  RETURN input;\n" <>
              "END\n$function$\n"
        }
      },
      extensions: %{"citext" => %{}},
      seeds: %{
        {"phoenix_kit_user_roles", "Admin"} => %{
          key_column: "name",
          key_value: "Admin",
          values: %{
            "name" => "Admin",
            "description" => "Admin's role",
            "is_system_role" => true
          }
        },
        {"phoenix_kit_settings", "fix_enabled"} => %{
          key_column: "key",
          key_value: "fix_enabled",
          values: %{
            "key" => "fix_enabled",
            "value" => "false",
            "value_json" => nil,
            "module" => nil
          }
        }
      }
    }
  end

  defp snapshot_v5 do
    v1 = snapshot_v1()

    columns =
      v1.columns
      |> Map.delete({@widgets, "legacy_col"})
      |> Map.put({@widgets, "name"}, %{
        type: "character varying(120)",
        not_null: true,
        default: nil,
        pos: 2
      })
      |> Map.put({@widgets, "note"}, %{type: "text", not_null: false, default: nil, pos: 5})
      |> Map.put({@widgets, "owner_uuid"}, %{type: "uuid", not_null: false, default: nil, pos: 6})
      |> Map.put({@owners, "uuid"}, %{
        type: "uuid",
        not_null: true,
        default: "__SCHEMA__.uuid_generate_v7()",
        pos: 1
      })
      |> Map.put({@owners, "value_json"}, %{type: "jsonb", not_null: false, default: nil, pos: 2})
      # Regression coverage for the seed-capture list/map defect (mirrors the
      # real V98 `alternative_formats text[]` column, decoded by Postgrex as
      # a native Elixir list): proves the manifest/baseline emitters render
      # a `text[]`-typed seed value as a native array literal, never JSON
      # array syntax — see the `square` seed row below and
      # `Emitter.literal/2`.
      |> Map.put({"phoenix_kit_storage_dimensions", "alternative_formats"}, %{
        type: "text[]",
        not_null: true,
        default: "'{}'::text[]",
        pos: 1
      })

    constraints =
      v1.constraints
      |> Map.put({@owners, "phoenix_kit_fix_owners_pkey"}, %{
        type: "p",
        definition: "PRIMARY KEY (uuid)",
        columns: ["uuid"],
        foreign_table: nil,
        foreign_columns: nil,
        on_delete: nil,
        on_update: nil
      })
      |> Map.put({@widgets, "phoenix_kit_fix_widgets_owner_uuid_fkey"}, %{
        type: "f",
        definition:
          "FOREIGN KEY (owner_uuid) REFERENCES __SCHEMA__.phoenix_kit_fix_owners(uuid) " <>
            "ON DELETE SET NULL",
        columns: ["owner_uuid"],
        foreign_table: @owners,
        foreign_columns: ["uuid"],
        on_delete: "n",
        on_update: "a"
      })
      |> Map.put({@widgets, "phoenix_kit_fix_widgets_name_check"}, %{
        type: "c",
        definition: "CHECK (char_length(name::text) > 0)",
        columns: ["name"],
        foreign_table: nil,
        foreign_columns: nil,
        on_delete: nil,
        on_update: nil
      })

    seeds =
      v1.seeds
      |> Map.put({"phoenix_kit_settings", "fix_enabled"}, %{
        key_column: "key",
        key_value: "fix_enabled",
        values: %{
          "key" => "fix_enabled",
          "value" => "false",
          # Nested map regression coverage (spec: seed-capture list/map
          # defect) — a genuinely nested value (a map containing both a
          # sub-map and a list), proving the emitters recurse correctly and
          # render sorted-key canonical JSON cast to jsonb. `value_json` is
          # a real column (V12) capable of holding exactly this shape.
          "value_json" => %{
            "limits" => %{"max_users" => 1000, "storage_gb" => 100},
            "features" => ["dark_mode", "notifications"]
          },
          "module" => "system"
        }
      })
      |> Map.put({"phoenix_kit_buckets", "Local Storage"}, %{
        key_column: "name",
        key_value: "Local Storage",
        values: %{
          "name" => "Local Storage",
          "provider" => "local",
          "endpoint" => "priv/media",
          "priority" => 0
        }
      })
      |> Map.put({"phoenix_kit_role_permissions", "dashboard"}, %{
        key_column: "module_key",
        key_value: "dashboard",
        values: %{"module_key" => "dashboard"}
      })
      |> Map.put({"phoenix_kit_payment_options", "cod"}, %{
        key_column: "code",
        key_value: "cod",
        values: %{
          "code" => "cod",
          "name" => ~s({"en": "Cash on delivery, 'as is'"}),
          "is_active" => true,
          "position" => 1
        }
      })
      # List regression coverage (spec: seed-capture list/map defect) —
      # mirrors the real `alternative_formats text[]` column added above.
      |> Map.put({"phoenix_kit_storage_dimensions", "square"}, %{
        key_column: "name",
        key_value: "square",
        values: %{
          "name" => "square",
          "alternative_formats" => ["webp", "avif"]
        }
      })

    # Prefix-embedded-name regression coverage (spec: stepwise-vs-single-shot
    # shape bimodality caused by V56/V61's `prefix_index_name/2` idiom —
    # bare on `public`/`nil`, `"#{prefix}_"` otherwise) — mirrors what
    # `Catalog.indexes/2` would ACTUALLY produce after capture-time
    # canonicalization: keyed by the bare suffix, `name_template: :exempt`
    # on the shape, `Catalog.name_marker(:exempt)` baked into `definition`
    # in place of the (already-stripped) scratch-schema prefix.
    indexes =
      Map.put(v1.indexes, "phoenix_kit_fix_widgets_uuid_idx", %{
        table: @widgets,
        unique: true,
        method: "btree",
        definition:
          "CREATE UNIQUE INDEX " <>
            Catalog.name_marker(:exempt) <>
            "phoenix_kit_fix_widgets_uuid_idx ON __SCHEMA__." <>
            "phoenix_kit_fix_widgets USING btree (uuid)",
        predicate: nil,
        keys: ["uuid"],
        opclasses: ["uuid_ops"],
        name_template: :exempt
      })

    %{
      v1
      | tables: Map.put(v1.tables, @owners, %{}),
        columns: columns,
        indexes: indexes,
        constraints: constraints,
        seeds: seeds
    }
  end

  # Single-shot end-state: retains a column+index the stepwise run does not
  # (preferred_locale analogue) and LACKS one stepwise index — both directions
  # of the spec-3.7 bimodality.
  defp single_final do
    v5 = snapshot_v5()

    %{
      v5
      | columns:
          Map.put(v5.columns, {@widgets, "fix_locale"}, %{
            type: "character varying(10)",
            not_null: false,
            default: nil,
            pos: 7
          }),
        indexes:
          v5.indexes
          |> Map.delete("phoenix_kit_fix_widgets_name_index")
          |> Map.put("phoenix_kit_fix_widgets_fix_locale_index", %{
            table: @widgets,
            unique: false,
            method: "btree",
            definition:
              "CREATE INDEX phoenix_kit_fix_widgets_fix_locale_index ON __SCHEMA__." <>
                "phoenix_kit_fix_widgets USING btree (fix_locale)",
            predicate: nil,
            keys: ["fix_locale"],
            opclasses: ["text_ops"]
          })
    }
  end

  defp fixture_helper_seed do
    %{
      class: :seed,
      key: {"phoenix_kit_email_templates", "__fixture_seeder__"},
      id: "seed:phoenix_kit_email_templates:fixture_seeder",
      since: 2,
      revisions: [{2, %{best_effort: true, source: "fixture"}}],
      presence: :required,
      create_override: {:helper, {Mix.Tasks.PhoenixKit.SeedTemplates, :run, [["--quiet"]]}},
      check_override: "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_email_templates)"
    }
  end

  # A REAL captured seed row (no create_override) for a :skip-strategy table —
  # regression fixture for the case where the email-template Mix-task seeder
  # inserts actual rows during a live stepwise run (v15/v31 lineage). Both
  # emitters must exclude these exactly like build_objects/1's skip_seed_row?
  # does: helper-seeded, never their own INSERT statement.
  defp fixture_real_template_row do
    %{
      class: :seed,
      key: {"phoenix_kit_email_templates", "fixture_real_row"},
      id: "seed:phoenix_kit_email_templates:fixture_real_row",
      since: 2,
      revisions: [
        {2,
         %{
           key_column: "slug",
           key_value: "fixture_real_row",
           values: %{"slug" => "fixture_real_row"}
         }}
      ],
      presence: :required
    }
  end

  # ---------------------------------------------------------------------------
  # Assertions
  # ---------------------------------------------------------------------------

  defp check_differ!(objects, drops) do
    by_id = Map.new(objects, &{&1.id, &1})

    name = Map.fetch!(by_id, "column:#{@widgets}.name")
    assert!(name.since == 1, "differ: name column since 1")
    assert!(length(name.revisions) == 2, "differ: name column carries the V5 revision")
    assert!(match?([{1, _}, {5, _}], name.revisions), "differ: name revision versions")

    note = Map.fetch!(by_id, "column:#{@widgets}.note")
    assert!(note.since == 5 and length(note.revisions) == 1, "differ: note column since 5")

    assert!(
      Enum.any?(drops, &(&1.id == "column:#{@widgets}.legacy_col" and &1.dropped_at == 5)),
      "differ: legacy_col recorded as dropped at 5"
    )

    assert!(
      not Map.has_key?(by_id, "column:#{@widgets}.legacy_col"),
      "differ: dropped column excluded from objects"
    )

    fk = Map.fetch!(by_id, "constraint:#{@widgets}.phoenix_kit_fix_widgets_owner_uuid_fkey")
    assert!(fk.since == 5, "differ: fk constraint since 5")

    seed = Map.fetch!(by_id, "seed:phoenix_kit_settings:fix_enabled")
    assert!(match?([{1, _}, {5, _}], seed.revisions), "differ: seed module retag is a revision")
  end

  defp check_bimodality!(bidiff) do
    only_single_ids =
      Enum.map(bidiff.only_single, fn {class, key, _} -> Differ.object_id(class, key) end)

    only_step_ids =
      Enum.map(bidiff.only_stepwise, fn {class, key, _} -> Differ.object_id(class, key) end)

    assert!(
      "column:#{@widgets}.fix_locale" in only_single_ids and
        "index:phoenix_kit_fix_widgets_fix_locale_index" in only_single_ids,
      "bimodality: single-only objects detected"
    )

    assert!(
      only_step_ids == ["index:phoenix_kit_fix_widgets_name_index"],
      "bimodality: stepwise-only index detected"
    )

    assert!(bidiff.mismatched == [], "bimodality: fixture modes have no shape mismatch")

    whitelist = Bimodality.whitelist(bidiff)

    assert!(
      "#{@widgets}.fix_locale" in whitelist and "phoenix_kit_fix_widgets_name_index" in whitelist and
        "phoenix_kit_fix_widgets_fix_locale_index" in whitelist,
      "bimodality: whitelist carries qualified column + bare object names"
    )
  end

  defp check_legacy!(objects, notes, _bidiff) do
    by_id = Map.new(objects, &{&1.id, &1})

    locale = Map.fetch!(by_id, "column:#{@widgets}.fix_locale")

    assert!(
      locale.presence == :legacy_optional and locale.since == 1,
      "legacy: single-only column added as :legacy_optional (since falls back to 1)"
    )

    name_index = Map.fetch!(by_id, "index:phoenix_kit_fix_widgets_name_index")
    assert!(name_index.presence == :legacy_optional, "legacy: stepwise-only index flipped")

    assert!(
      notes.unknown_since == [
        "column:#{@widgets}.fix_locale",
        "index:phoenix_kit_fix_widgets_fix_locale_index"
      ],
      "legacy: unresolvable since is reported"
    )
  end

  defp check_guard_rejects!(objects) do
    poisoned = [
      %{
        class: :sequence,
        key: "phoenix_kit_id_seq",
        id: "sequence:phoenix_kit_id_seq",
        since: 1,
        revisions: [{1, %{}}],
        presence: :required
      }
      | objects
    ]

    assert!(
      raises?(fn -> InventoryGuard.assert_catalog!(poisoned) end),
      "guard: excluded :required object aborts emission"
    )
  end

  defp check_manifest!(objects) do
    src =
      Emitter.render_manifest(objects, @meta,
        module: "PhoenixKit.Squash.Generate.FixtureManifest"
      )

    maybe_dump("fixture_expected_schema.ex", src)

    src2 =
      Emitter.render_manifest(objects, @meta,
        module: "PhoenixKit.Squash.Generate.FixtureManifest"
      )

    assert!(src == src2, "manifest: deterministic emission")
    Code.string_to_quoted!(src)

    for needle <- [
          "def objects(prefix)",
          "def data_invariants(",
          "def chain_hash",
          "__SCHEMA__",
          "legacy_optional"
        ] do
      assert!(String.contains?(src, needle), "manifest: source contains #{inspect(needle)}")
    end

    assert!(
      not String.contains?(src, "fixture_real_row"),
      "manifest: real captured :skip-strategy seed row excluded (no create_override)"
    )

    src
  end

  defp check_manifest_compiles!(src) do
    mods = Code.compile_string(src)
    # Resolved at runtime so compile-time remote-call warnings cannot fire for a
    # module that only exists after Code.compile_string/1.
    mod = Module.concat(PhoenixKit.Squash.Generate, :FixtureManifest)
    assert!(Enum.any?(mods, fn {m, _bin} -> m == mod end), "manifest: fixture module compiled")

    try do
      objects = mod.objects("fix_pfx")

      leftover_tokens = ["__SCHEMA__", Catalog.name_marker(:exempt), Catalog.name_marker(:always)]

      leftover_token =
        Enum.any?(objects, fn object ->
          strings =
            [object.create, object.check] ++
              Enum.flat_map(object.revisions, fn {_v, shape} -> Map.values(shape) end)

          strings
          |> Enum.filter(&is_binary/1)
          |> Enum.any?(fn s -> Enum.any?(leftover_tokens, &String.contains?(s, &1)) end)
        end)

      assert!(
        not leftover_token,
        "manifest: objects/1 substitutes every __SCHEMA__/prefix-embedded-name token"
      )

      uuid_fn =
        Enum.find(objects, &(&1.id == "function:uuid_generate_v7()"))

      assert!(
        uuid_fn.create ==
          {:helper,
           {PhoenixKit.Migrations.Postgres.Helpers, :ensure_uuid_v7_function, ["fix_pfx"]}},
        "manifest: helper :prefix argument materialized"
      )

      table = Enum.find(objects, &(&1.id == "table:#{@widgets}"))

      assert!(
        table.create == "CREATE TABLE IF NOT EXISTS fix_pfx.#{@widgets} ()",
        "manifest: table create substituted"
      )

      locale = Enum.find(objects, &(&1.id == "column:#{@widgets}.fix_locale"))
      assert!(locale.create == nil, "manifest: legacy_optional create is nil")

      seed = Enum.find(objects, &(&1.id == "seed:phoenix_kit_settings:fix_enabled"))

      assert!(
        is_binary(seed.check) and seed.check =~ "fix_pfx.",
        "manifest: seed check substituted"
      )

      assert!(
        seed.create =~ "ON CONFLICT (\"key\") DO NOTHING",
        "manifest: settings conflict target"
      )

      assert!(seed.create =~ "'system'", "manifest: seed create uses NEWEST revision values")

      # Seed-capture list/map defect: a genuinely nested value (map
      # containing a sub-map and a list) must render as sorted-key
      # canonical JSON cast to jsonb — never raise, never depend on
      # insertion/decode order.
      assert!(
        seed.create =~
          ~s('{"features":["dark_mode","notifications"],) <>
            ~s("limits":{"max_users":1000,"storage_gb":100}}'::jsonb),
        "manifest: nested map seed value renders as canonical (sorted-key) JSON cast to jsonb"
      )

      dimension = Enum.find(objects, &(&1.id == "seed:phoenix_kit_storage_dimensions:square"))

      # Same defect, the array half: a `text[]` value must render as a
      # native Postgres array literal, never JSON array syntax (`[...]` is
      # not valid `text[]` input).
      assert!(
        dimension.create =~ ~s('{"webp","avif"}'::text[]),
        "manifest: text[] seed value renders as a native array literal, not JSON syntax"
      )

      bucket = Enum.find(objects, &(&1.id == "seed:phoenix_kit_buckets:Local Storage"))
      assert!(bucket.create =~ "WHERE NOT EXISTS", "manifest: bucket WHERE NOT EXISTS strategy")

      perm = Enum.find(objects, &(&1.id == "seed:phoenix_kit_role_permissions:dashboard"))

      assert!(
        perm.create =~ "WHERE r.name = 'Admin'" and perm.create =~ "ON CONFLICT DO NOTHING",
        "manifest: role_permissions Admin-select strategy"
      )

      payment = Enum.find(objects, &(&1.id == "seed:phoenix_kit_payment_options:cod"))
      assert!(payment.create =~ "''as is''", "manifest: single quotes escaped in seed values")

      # Prefix-embedded-name templating (spec: stepwise-vs-single-shot shape
      # bimodality, V56/V61's prefix_index_name/2 idiom) — on a NAMED
      # prefix the index's real name is prefixed.
      prefixed_idx = Enum.find(objects, &(&1.id == "index:phoenix_kit_fix_widgets_uuid_idx"))

      assert!(
        prefixed_idx.create =~
          "CREATE UNIQUE INDEX IF NOT EXISTS fix_pfx_phoenix_kit_fix_widgets_uuid_idx ON " <>
            "fix_pfx.phoenix_kit_fix_widgets",
        "manifest: prefix-embedded index create resolves PREFIXED on a named schema"
      )

      assert!(
        match?(
          {:catalog, %{name: "fix_pfx_phoenix_kit_fix_widgets_uuid_idx"}},
          prefixed_idx.check
        ),
        "manifest: prefix-embedded index check.name resolves PREFIXED on a named schema"
      )

      assert!(mod.objects(nil) != [], "manifest: nil prefix maps to public")

      # ... and on `public` (nil -> "public") the SAME object's real name is
      # BARE — the `:exempt` convention's whole point (v56.ex/v61.ex never
      # embed the prefix for a public install).
      public_idx =
        nil
        |> mod.objects()
        |> Enum.find(&(&1.id == "index:phoenix_kit_fix_widgets_uuid_idx"))

      assert!(
        public_idx.create =~
          "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_fix_widgets_uuid_idx ON " <>
            "public.phoenix_kit_fix_widgets" and
          not String.contains?(public_idx.create, "public_phoenix_kit_fix_widgets_uuid_idx"),
        "manifest: prefix-embedded index create resolves BARE on public"
      )

      assert!(
        match?({:catalog, %{name: "phoenix_kit_fix_widgets_uuid_idx"}}, public_idx.check),
        "manifest: prefix-embedded index check.name resolves BARE on public"
      )

      assert!(raises?(fn -> mod.objects("Bad-Prefix") end), "manifest: invalid prefix raises")

      invariant = mod.data_invariants("fix_pfx") |> List.first()
      assert!(invariant.assert =~ "fix_pfx.", "manifest: data invariant substituted")
      assert!(mod.chain_hash() == @meta.chain_hash, "manifest: chain_hash embedded")
    after
      :code.delete(mod)
      :code.purge(mod)
    end
  end

  defp check_baseline!(objects, drops) do
    src5 =
      Emitter.render_baseline(objects, 5, @meta,
        module: "PhoenixKit.Squash.Generate.FixtureBaselineV5",
        drops: drops
      )

    src5_again =
      Emitter.render_baseline(objects, 5, @meta,
        module: "PhoenixKit.Squash.Generate.FixtureBaselineV5",
        drops: drops
      )

    assert!(src5 == src5_again, "baseline: deterministic emission")
    maybe_dump("fixture_baseline_v5.ex", src5)
    Code.string_to_quoted!(src5)

    interp_p = @pound <> "{p}"
    interp_prefix = @pound <> "{prefix}"
    interp_pn = @pound <> "{pn}"

    for needle <- [
          "Helpers.ensure_extension!(\"citext\")",
          "Helpers.ensure_uuid_v7_function(prefix)",
          "Oban.Migration.up(prefix: prefix, create_schema: false)",
          "character varying(120)",
          "\"note\" text",
          "CREATE SEQUENCE IF NOT EXISTS " <> interp_p <> "phoenix_kit_fix_counter_seq",
          "REFERENCES " <> interp_p <> "phoenix_kit_fix_owners(uuid)",
          "AND n.nspname = '" <> interp_prefix <> "'",
          "phoenix_kit IS '5'",
          "WHERE NOT EXISTS",
          "seed_best_effort_helpers()",
          "Mix.Tasks.PhoenixKit.SeedTemplates",
          "DROP TABLE IF EXISTS " <> interp_p <> "phoenix_kit_fix_widgets CASCADE",
          # Prefix-embedded-name templating: `pn` is bound (only because this
          # slice has an object needing it) and the index create interpolates
          # it in place of the (stripped) scratch-schema prefix.
          ~s[pn = if prefix == "public", do: "", else: "] <> interp_prefix <> ~s[_"],
          "CREATE UNIQUE INDEX IF NOT EXISTS " <> interp_pn <> "phoenix_kit_fix_widgets_uuid_idx"
        ] do
      assert!(String.contains?(src5, needle), "baseline v5: source contains #{inspect(needle)}")
    end

    for absent <- [
          "character varying(50)",
          "legacy_col",
          "fix_locale",
          "name_index",
          "fixture_real_row"
        ] do
      assert!(
        not String.contains?(src5, absent),
        "baseline v5: source must NOT contain #{inspect(absent)}"
      )
    end

    mods = Code.compile_string(src5)
    mod = PhoenixKit.Squash.Generate.FixtureBaselineV5
    assert!(Enum.any?(mods, fn {m, _bin} -> m == mod end), "baseline: fixture module compiled")
    :code.delete(mod)
    :code.purge(mod)

    src1 =
      Emitter.render_baseline(objects, 1, @meta,
        module: "PhoenixKit.Squash.Generate.FixtureBaselineV1",
        drops: drops
      )

    Code.string_to_quoted!(src1)

    assert!(
      String.contains?(src1, "character varying(50)"),
      "baseline v1: floor-scoped revision selected"
    )

    # `legacy_col`: since 1, dropped at 5 — ABOVE this floor (1), so it must
    # be CARRIED OVER into the floor=1 baseline (floor_carryover/2's whole
    # reason for existing: it existed at V1, and the still-live V5 delta is
    # what actually drops it when the chain runs — the baseline must create
    # it or V5's drop has nothing to act on). Contrast with src5 above,
    # where `legacy_col` is correctly ABSENT (dropped AT floor 5, not above
    # it — the ordinary case `Differ.catalog/2` always got right).
    assert!(
      String.contains?(src1, "legacy_col"),
      "baseline v1: dropped-above-the-floor column is carried over"
    )

    for absent <- [
          "note",
          "phoenix_kit_fix_owners",
          "seed_best_effort_helpers",
          "fix_locale",
          # since: 5 — out of scope for the floor=1 slice.
          "phoenix_kit_fix_widgets_uuid_idx"
        ] do
      assert!(
        not String.contains?(src1, absent),
        "baseline v1: source must NOT contain #{inspect(absent)}"
      )
    end

    assert!(String.contains?(src1, "phoenix_kit IS '1'"), "baseline v1: stamps its floor")

    # Regression guard for the live V152 crash class, at a floor STRICTLY
    # ABOVE `legacy_col`'s `since` (1 < 3 < dropped_at 5) — src1 above only
    # proves carryover at the since == floor boundary (1 == 1), which cannot
    # distinguish "carried because it predates the floor" from "carried
    # because it happens to equal the floor". A real chain floor is never
    # the exact version that introduced every carried object (V79 created
    # `list_uuid`, floor 135 is 56 versions later) — this reuses the SAME
    # objects/drops (no new fixture snapshot needed: `legacy_col` already
    # satisfies since=1 <= 3 <= dropped_at-1=4) to pin the general case.
    src3 =
      Emitter.render_baseline(objects, 3, @meta,
        module: "PhoenixKit.Squash.Generate.FixtureBaselineV3",
        drops: drops
      )

    Code.string_to_quoted!(src3)

    assert!(
      String.contains?(src3, "legacy_col"),
      "baseline v3: a column created BEFORE the floor (since 1 < 3) and dropped by a " <>
        "still-live delta ABOVE the floor (dropped_at 5 > 3) is emitted by the baseline"
    )

    assert!(
      not Map.has_key?(Map.new(objects, &{&1.id, &1}), "column:#{@widgets}.legacy_col"),
      "baseline v3: the same dropped-above-floor column is absent from `objects` — the " <>
        "manifest source list never carries drops at all, regardless of floor"
    )
  end

  defp check_mismatch_detection!(final) do
    tweaked =
      put_in(final, [:columns, {@widgets, "name"}], %{
        type: "text",
        not_null: true,
        default: nil,
        pos: 2
      })

    bidiff = Bimodality.diff(final, tweaked)

    assert!(
      match?([{:columns, {@widgets, "name"}, _, _}], bidiff.mismatched),
      "bimodality: same-key shape mismatch is detected (abort path)"
    )
  end

  # Set PK_SQUASH_CHECK_DUMP=<dir> to retain the fixture-generated sources for
  # eyeballing (they are otherwise only parse/compile-gated in memory).
  defp maybe_dump(name, src) do
    case System.get_env("PK_SQUASH_CHECK_DUMP") do
      nil ->
        :ok

      dir ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, name), src)
    end

    :ok
  end

  defp assert!(true, _label), do: :ok
  defp assert!(false, label), do: raise("generate_baseline --check failed: #{label}")

  defp raises?(fun) do
    fun.()
    false
  rescue
    _error -> true
  end
end

defmodule PhoenixKit.Squash.Generate.Main do
  @moduledoc false

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Squash.DumpHelper
  alias PhoenixKit.Squash.Generate.Bimodality
  alias PhoenixKit.Squash.Generate.Catalog
  alias PhoenixKit.Squash.Generate.Config
  alias PhoenixKit.Squash.Generate.Differ
  alias PhoenixKit.Squash.Generate.Emitter
  alias PhoenixKit.Squash.Generate.Fixture
  alias PhoenixKit.Squash.Generate.InventoryGuard
  alias PhoenixKit.Squash.MigrationRunner
  alias PhoenixKit.Squash.RepoHelper

  def main(argv) do
    config = Config.parse!(argv)

    cond do
      config.help -> IO.puts(Config.usage())
      config.check -> check(config)
      true -> generate(config)
    end
  end

  # ---------------------------------------------------------------------------
  # --check (offline)
  # ---------------------------------------------------------------------------

  def check(config) do
    RepoHelper.run_self_checks()
    DumpHelper.run_self_checks()
    MigrationRunner.check()
    InventoryGuard.assert_inventory_doc!(config.inventory_doc)
    Fixture.run_all()
    check_chain_hash!()
    check_config_parsing!()
    check_seed_tables_sync!()
    check_owner_mapping!()

    IO.puts(
      "OK generate_baseline.exs --check: helper self-checks, inventory-doc cross-check, " <>
        "fixture differ/bimodality/guard, manifest+baseline emit/parse/compile, " <>
        "config parsing, owner mapping — all offline gates passed"
    )

    :ok
  end

  defp check_chain_hash! do
    {hash, count} = Emitter.chain_hash(migrations_dir())

    unless hash =~ ~r/^[0-9a-f]{64}$/ and count >= 1 do
      raise "chain_hash smoke failed: #{inspect({hash, count})}"
    end

    :ok
  end

  defp check_config_parsing! do
    checks = [
      {"unknown flag rejected", fn -> Config.parse!(["--bogus"]) end},
      {"positional argument rejected", fn -> Config.parse!(["surprise"]) end},
      {"out-of-range floor rejected", fn -> Config.parse!(["--floor", "999999"]) end},
      {"public scratch schema rejected",
       fn -> Config.parse!(["--schema-stepwise", "public"]) end},
      {"invalid schema name rejected", fn -> Config.parse!(["--schema-single", "Bad-Name"]) end},
      {"identical schemas rejected",
       fn -> Config.parse!(["--schema-stepwise", "same_x", "--schema-single", "same_x"]) end}
    ]

    for {label, fun} <- checks do
      ok =
        try do
          fun.()
          false
        rescue
          _error -> true
        end

      unless ok, do: raise("config parsing check failed: #{label}")
    end

    valid = Config.parse!(["--floor", Integer.to_string(Postgres.initial_version())])

    unless valid.floor == Postgres.initial_version() do
      raise "config parsing check failed: explicit valid floor accepted"
    end

    :ok
  end

  # Guards against the two independently-maintained seed-table sets drifting
  # apart: Catalog.@seed_capture (what the manifest emits :seed objects for)
  # and DumpHelper.@default_seed_tables (what the S2 oracle dumps by default).
  # A silent mismatch here is exactly how a real bucket-seeding divergence
  # (or any future new seed table) would go undetected by S2.
  defp check_seed_tables_sync! do
    generator_tables = Enum.sort(Catalog.seed_tables())
    oracle_tables = Enum.sort(DumpHelper.default_seed_tables())

    unless generator_tables == oracle_tables do
      raise "seed-table drift: Catalog.seed_tables/0 #{inspect(generator_tables)} != " <>
              "DumpHelper.default_seed_tables/0 #{inspect(oracle_tables)} — keep the " <>
              "manifest's seed-capture set and the S2 oracle's dump set in sync"
    end

    :ok
  end

  # `owner:` (spec 5.1's per-module-extraction-slice hint): every object
  # CLASS `Emitter.object_owner/1` dispatches on (mirrors `object_check/1`'s
  # class list) must resolve to an atom, never crash or fall through
  # unhandled — proven here with minimal per-class synthetic objects, since
  # `object_owner/1` only needs `class`/`key` (plus `revisions` for the
  # `:index` case, to reach the owning table via `newest_shape/1`), not the
  # full check/create shape data `build_objects/1`'s OTHER emitted fields
  # need. Then at least one REAL table name must resolve to a non-:core
  # owner — proves the family-mapping DATA actually matches real
  # `phoenix_kit_*` names, not just that every branch returns some atom.
  defp check_owner_mapping! do
    minimal_objects_by_class = [
      %{class: :table, key: "phoenix_kit_cat_items"},
      %{class: :column, key: {"phoenix_kit_cat_items", "name"}},
      %{
        class: :index,
        key: "phoenix_kit_cat_items_name_idx",
        revisions: [{1, %{table: "phoenix_kit_cat_items"}}]
      },
      %{class: :constraint, key: {"phoenix_kit_cat_items", "phoenix_kit_cat_items_pkey"}},
      %{class: :sequence, key: "phoenix_kit_warehouse_stock_number_seq"},
      %{class: :function, key: {"uuid_generate_v7", ""}},
      %{class: :extension, key: "citext"},
      %{class: :seed, key: {"phoenix_kit_settings", "some_key"}}
    ]

    unless Enum.all?(minimal_objects_by_class, &is_atom(Emitter.object_owner(&1))) do
      raise "owner mapping check failed: object_owner/1 did not resolve every object class " <>
              "to an atom"
    end

    spot_checks = [
      {"phoenix_kit_cat_items", :catalogue},
      {"phoenix_kit_warehouse_stock", :warehouse},
      {"phoenix_kit_crm_contacts", :crm},
      {"phoenix_kit_staff_people", :staff},
      {"phoenix_kit_projects", :projects},
      {"phoenix_kit_newsletters_broadcasts", :newsletters},
      {"phoenix_kit_publishing_posts", :publishing},
      {"phoenix_kit_og_templates", :og_images},
      {"phoenix_kit_locations", :locations},
      {"phoenix_kit_comments", :comments},
      {"phoenix_kit_ai_requests", :ai},
      {"phoenix_kit_doc_templates", :document_creator},
      # False-positive guards: substring "location"/"project" present but the
      # table does NOT belong to those families (doesn't START WITH them).
      {"phoenix_kit_file_locations", :core},
      {"phoenix_kit_settings", :core}
    ]

    for {table, expected} <- spot_checks do
      actual = Emitter.owner_for_table(table)

      unless actual == expected do
        raise "owner mapping check failed: #{table} resolved to #{inspect(actual)}, " <>
                "expected #{inspect(expected)}"
      end
    end

    non_core = Enum.count(spot_checks, fn {_table, owner} -> owner != :core end)

    unless non_core > 0 do
      raise "owner mapping check failed: spot-check table has zero non-:core entries"
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Full generation [DB]
  # ---------------------------------------------------------------------------

  def generate(config) do
    initial = Postgres.initial_version()
    current = Postgres.current_version()
    {chain_hash, file_count} = Emitter.chain_hash(migrations_dir())

    meta = %{initial: initial, current: current, chain_hash: chain_hash, file_count: file_count}

    InventoryGuard.assert_inventory_doc!(config.inventory_doc)

    IO.puts("""
    =======================================================
    PhoenixKit squash — ExpectedSchema manifest generator
    Chain: initial=#{initial} current=#{current} files=#{file_count}
    Floor: #{config.floor || "(none — baseline slice skipped)"}
    Schemas: #{config.schema_stepwise} (stepwise) / #{config.schema_single} (single-shot)
    Output: #{config.output_dir}
    =======================================================
    """)

    repo = RepoHelper.start!()
    drop_schema(repo, config.schema_stepwise)
    drop_schema(repo, config.schema_single)

    try do
      IO.puts("Step 1: stepwise chain V#{initial}..V#{current} with per-version snapshots ...")
      snapshots = run_stepwise(repo, config.schema_stepwise, initial, current)

      IO.puts("Step 2: single-shot full-chain install ...")
      MigrationRunner.run_old_chain(repo, config.schema_single, to_version: current)
      single_snap = Catalog.snapshot(repo, config.schema_single)

      IO.puts("Step 3: dumps (schema + seed data) ...")
      dump_step = DumpHelper.dump!(config.schema_stepwise)
      dump_single = DumpHelper.dump!(config.schema_single)

      # Catalog.seed_tables/0 is the single source of truth for "which tables
      # this generator captures as seeds" (mirrors @seed_capture exactly);
      # deriving from it here — instead of hand-patching DumpHelper's own S2
      # oracle default — means a future @seed_capture addition flows into the
      # reference dump without a second edit. check_seed_tables_sync!/0 (in
      # --check) guards against the two sets drifting apart silently.
      seed_dump =
        DumpHelper.dump_seed_data!(config.schema_stepwise, tables: Catalog.seed_tables())

      IO.puts("Step 4: per-version diffing + bimodality enumeration ...")
      history = Differ.history(snapshots)
      {_last_version, final_snap} = List.last(snapshots)
      %{objects: objects, drops: drops} = Differ.catalog(history, final_snap)

      bidiff = Bimodality.diff(final_snap, single_snap)
      abort_on_mode_shape_mismatch!(config, bidiff)

      {objects, legacy_notes} = Bimodality.apply_to_objects(objects, history, bidiff)
      whitelist = Bimodality.whitelist(bidiff)
      objects = objects ++ Emitter.template_seed_objects()

      compare_result =
        DumpHelper.compare(dump_step, config.schema_stepwise, dump_single, config.schema_single,
          legacy_optional: whitelist
        )

      case compare_result do
        :equal ->
          :ok

        {:equal_modulo_whitelist, _tolerated} ->
          :ok

        {:diff, text} ->
          File.mkdir_p!(config.output_dir)
          diff_path = Path.join(config.output_dir, "mode_dump_diff.txt")
          File.write!(diff_path, text)

          raise "S1 cross-check failed: the normalized dump diff between modes has " <>
                  "differences the structural whitelist does not cover (see #{diff_path}); " <>
                  "the catalog snapshot layer is missing an object class"
      end

      InventoryGuard.assert_catalog!(objects)

      IO.puts("Step 5: emitting artifacts ...")
      manifest_src = Emitter.render_manifest(objects, meta)
      Code.string_to_quoted!(manifest_src)

      unless manifest_src == Emitter.render_manifest(objects, meta) do
        raise "manifest emission is not deterministic"
      end

      File.mkdir_p!(config.output_dir)
      manifest_path = Path.join(config.output_dir, "expected_schema.ex")
      File.write!(manifest_path, manifest_src)

      baseline_path =
        case config.floor do
          nil ->
            nil

          floor ->
            baseline_src = Emitter.render_baseline(objects, floor, meta, drops: drops)
            Code.string_to_quoted!(baseline_src)
            path = Path.join(config.output_dir, "v#{floor}.ex")
            File.write!(path, baseline_src)
            path
        end

      step_ref = Path.join(config.output_dir, "reference_dump_stepwise.sql")
      single_ref = Path.join(config.output_dir, "reference_dump_single.sql")
      seed_ref = Path.join(config.output_dir, "reference_seed_data.txt")
      report_path = Path.join(config.output_dir, "generation_report.md")

      File.write!(step_ref, DumpHelper.normalise(dump_step, config.schema_stepwise))
      File.write!(single_ref, DumpHelper.normalise(dump_single, config.schema_single))
      File.write!(seed_ref, seed_dump)

      File.write!(
        report_path,
        report(meta, config, objects, drops, bidiff, legacy_notes, whitelist, compare_result)
      )

      IO.puts("""

      Done. Artifacts (HAND REVIEW REQUIRED before anything moves into lib/ — P2/P3):
        manifest:       #{manifest_path}
        baseline slice: #{baseline_path || "(skipped — no floor input)"}
        reference dumps: #{step_ref}, #{single_ref}
        seed reference:  #{seed_ref}
        report:          #{report_path}
      """)

      :ok
    after
      if config.keep_schemas do
        IO.puts("Keeping scratch schemas (--keep-schemas).")
      else
        drop_schema(repo, config.schema_stepwise)
        drop_schema(repo, config.schema_single)
      end
    end
  end

  defp run_stepwise(repo, schema, initial, current) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    try do
      MigrationRunner.run_chain_stepwise(repo, schema, initial..current, fn version ->
        snap = Catalog.snapshot(repo, schema)
        Agent.update(agent, &[{version, snap} | &1])

        if rem(version, 25) == 0 or version == current do
          IO.puts("  V#{version} migrated + snapshotted")
        end
      end)

      agent |> Agent.get(& &1) |> Enum.reverse()
    after
      Agent.stop(agent)
    end
  end

  defp abort_on_mode_shape_mismatch!(config, bidiff) do
    if bidiff.mismatched != [] do
      File.mkdir_p!(config.output_dir)
      path = Path.join(config.output_dir, "mode_shape_mismatch.txt")

      body =
        Enum.map_join(bidiff.mismatched, "\n\n", fn {class, key, step_shape, single_shape} ->
          """
          #{Differ.object_id(class, key)}
            stepwise:    #{inspect(step_shape)}
            single-shot: #{inspect(single_shape)}
          """
        end)

      File.write!(path, body)

      raise "single-shot and stepwise runs disagree on the SHAPE of " <>
              "#{length(bidiff.mismatched)} object(s) — the presence-based " <>
              ":legacy_optional model cannot express that (see #{path}); investigate " <>
              "before regenerating"
    end

    :ok
  end

  defp report(meta, config, objects, drops, bidiff, legacy_notes, whitelist, compare_result) do
    # Counted post Emitter.build_objects/1 (the same filter render_manifest/1
    # applies) so this matches what actually lands in expected_schema.ex —
    # NOT the raw intermediate list, which still carries :skip-strategy seed
    # rows (e.g. real V15/V31 email-template rows captured during a live
    # stepwise run) that build_objects/1 silently drops before emission.
    class_counts =
      objects
      |> Emitter.build_objects()
      |> Enum.frequencies_by(& &1.class)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {class, count} -> "- #{class}: #{count}" end)

    legacy_ids =
      objects
      |> Enum.filter(&(&1.presence == :legacy_optional))
      |> Enum.map_join("\n", &"- #{&1.id} (since #{&1.since})")

    # Explicit, machine-greppable divergence marker between "gone by design"
    # (dropped at/below the floor — the baseline never creates it, nothing to
    # carry) and "carried into the baseline at its at-floor shape" (created
    # at/before the floor, dropped by a delta that still runs ABOVE it — the
    # exact V152 `list_uuid` class of gap: without this the object is silent
    # in BOTH the manifest, since drops never appear there, at all floors, AND
    # the report, so nothing short of a live migration crash surfaced it).
    baseline_carried? = fn drop ->
      is_integer(config.floor) and drop.since <= config.floor and drop.dropped_at > config.floor
    end

    drops_list =
      Enum.map_join(drops, "\n", fn drop ->
        tag =
          if baseline_carried?.(drop) do
            " [BASELINE-CARRIED: since V#{drop.since} <= floor #{config.floor} < " <>
              "dropped_at V#{drop.dropped_at} — emitted in the baseline at its at-floor " <>
              "shape so this still-live delta has something to act on]"
          else
            ""
          end

        "- #{drop.id} (dropped at V#{drop.dropped_at})#{tag}"
      end)

    carried_count = Enum.count(drops, baseline_carried?)

    compare_line =
      case compare_result do
        :equal ->
          "equal (strict)"

        {:equal_modulo_whitelist, tolerated} ->
          "equal modulo whitelist (only_a: #{length(tolerated.only_a)} lines, " <>
            "only_b: #{length(tolerated.only_b)} lines)"
      end

    unknown_since =
      case legacy_notes.unknown_since do
        [] -> "(none)"
        ids -> Enum.map_join(ids, "\n", &"- #{&1} (since defaulted to 1 — review)")
      end

    """
    # Squash generation report

    - Chain: initial=#{meta.initial} current=#{meta.current} files=#{meta.file_count}
    - chain_hash: #{meta.chain_hash}
    - Floor: #{config.floor || "(none — baseline slice skipped)"}
    - Schemas: #{config.schema_stepwise} (stepwise/canonical) / #{config.schema_single} (single-shot)
    - S1 mode cross-check (normalized dumps, whitelist-filtered): #{compare_line}

    ## Object counts (as emitted into expected_schema.ex; post seed-skip filtering)

    #{class_counts}

    ## Bimodality (spec 3.7) — presence: :legacy_optional

    Single-shot-only: #{length(bidiff.only_single)}; stepwise-only: #{length(bidiff.only_stepwise)}.

    #{legacy_ids}

    ### Unresolved `since` for single-only objects

    #{unknown_since}

    ### S1 whitelist (DumpHelper legacy_optional tokens)

    #{Enum.map_join(whitelist, "\n", &"- #{&1}")}

    ## Dropped along the chain (EXCLUDED from the manifest — final-state only)

    #{carried_count} of #{length(drops)} are BASELINE-CARRIED (created at/before the floor,
    dropped by a delta that still runs above it — emitted into V#{config.floor || "{floor}"} at
    their at-floor shape; see spec 5.1's at-floor rule). The rest were dropped at/below the
    floor and are correctly gone from BOTH the manifest and the baseline.

    #{drops_list}

    ## Hand-review checklist

    - [ ] Every :legacy_optional entry is an EXPECTED spec-3.7 case (preferred_locale
          family, V13-vs-V22 duplicate index) — anything else needs investigation.
    - [ ] Seed values (settings/currencies/payment options/dimensions/bucket) match the
          inventory's final-state expectations (customer_support_* naming, no ai_*_slots,
          module tags).
    - [ ] Baseline slice compiles and passes `mix format --check-formatted` once moved
          into lib/ (P3), and reads sanely next to a recent hand-written version module.
    - [ ] Non-uuid function bodies (emitted verbatim from pg_get_functiondef) are
          schema-qualified at every internal call site — an unqualified reference
          inside a body is search_path-dependent (spec section 6.2 / CLAUDE.md
          prefix rules); the generator does not assert this mechanically.
    - [ ] Constraint names in the baseline match the manifest (historical *_pkey names
          survive table renames on purpose).
    """
  end

  defp drop_schema(_repo, "public") do
    raise "refusing DROP SCHEMA on public — the generator only drops its own scratch schemas"
  end

  defp drop_schema(repo, schema) do
    refuse_live_schema!(repo, schema)
    do_drop_schema(repo, schema)
  end

  defp do_drop_schema(repo, schema) do
    RepoHelper.query!(repo, ~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
    :ok
  rescue
    error ->
      IO.puts("WARNING: could not drop scratch schema #{schema}: #{inspect(error)}")
      :ok
  end

  # Named-schema twin of verify.exs's refuse_live_install! (spec: NOTHING
  # destructive near live data). --schema-stepwise/--schema-single are
  # operator-supplied and dropped PRE-RUN, so a typo naming a live prefixed
  # install would wipe it; a scratch schema this tool created never contains
  # user rows (migrations alone never insert users) — populated
  # phoenix_kit_users == live install, refuse with no override. Runs OUTSIDE
  # do_drop_schema's rescue so the refusal cannot be swallowed as a WARNING.
  defp refuse_live_schema!(repo, schema) do
    %{rows: [[reg]]} =
      RepoHelper.query!(repo, "SELECT to_regclass('#{schema}.phoenix_kit_users')::text")

    users =
      if reg do
        %{rows: [[n]]} =
          RepoHelper.query!(repo, "SELECT count(*) FROM \"#{schema}\".phoenix_kit_users")

        n
      else
        0
      end

    if users > 0 do
      raise """
      refusing DROP SCHEMA #{schema}: it contains #{users} row(s) in
      #{schema}.phoenix_kit_users — that is a LIVE prefixed PhoenixKit install,
      not a leftover scratch schema. Pick a different --schema-stepwise /
      --schema-single name; there is deliberately no override.
      """
    end

    :ok
  end

  defp migrations_dir do
    Path.expand("../../lib/phoenix_kit/migrations/postgres", __DIR__)
  end
end

PhoenixKit.Squash.Generate.Main.main(System.argv())
