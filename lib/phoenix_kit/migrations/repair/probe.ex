defmodule PhoenixKit.Migrations.Repair.Probe do
  @moduledoc """
  All read-only introspection against the **target** server: the raw version
  comment (task rule (a): never `PhoenixKit.Migrations.Postgres.migrated_version/1`'s
  legacy no-comment→1 mapping — see below), a structural catalog snapshot
  mirroring `PhoenixKit.Squash.Generate.Catalog`'s queries (`dev_docs/squash/
  generate_baseline.exs`), and the small pure helpers that read an
  `PhoenixKit.Migrations.ExpectedSchema.Object.t()`'s `check` field against
  that snapshot.

  Every function that takes a `repo` executes real queries and has no unit
  test (this repo's suite is DB-free); `lookup/2` and `presence_by_since/2`
  take an already-fetched snapshot and are pure — those are the ones
  `test/phoenix_kit/migrations/repair/probe_test.exs` exercises directly with
  hand-built snapshots.

  ## Raw comment read — why this duplicates `Postgres.migrated_version/1`'s SQL instead of calling it

  `Postgres.migrated_version/1` (`postgres.ex:1373-1410`) runs the exact same
  two queries this module's `raw_comment/2` does (table-exists, then
  `obj_description`), but its **last clause folds "table exists, no comment"
  into `1`** ("Table exists but no version comment - assume version 1
  (legacy V01 installation)") — the right behavior for a migration entry
  point deciding what to run next, and exactly the wrong behavior for
  `PhoenixKit.Migrations.Repair`: spec §6.4 R4 needs to tell "genuinely at
  V1" apart from "half-installed/adopted, comment stripped" (§6.1: "that
  mapping would swallow the half-installed/adopted case into the below-floor
  error"). There is no way to get the un-folded value out of
  `migrated_version/1` — its `case` has no branch that returns it — so
  `raw_comment/2` re-implements the same two queries and stops one line
  earlier.
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object

  @typedoc "`:absent` (table missing), `nil` (table exists, no comment), or the numeric comment."
  @type raw_comment :: :absent | nil | non_neg_integer()

  @typedoc "One schema's structural snapshot — mirrors `PhoenixKit.Squash.Generate.Catalog.snapshot/2`'s shape, minus seeds (see moduledoc \"Seeds\" note on `PhoenixKit.Migrations.Repair.Differ`)."
  @type snapshot :: %{
          tables: %{String.t() => map()},
          columns: %{{String.t(), String.t()} => map()},
          indexes: %{String.t() => map()},
          constraints: %{{String.t(), String.t()} => map()},
          sequences: %{String.t() => map()},
          functions: %{{String.t(), String.t()} => map()},
          extensions: %{String.t() => map()}
        }

  @doc """
  The raw version comment — see moduledoc. Never raises; any query failure
  (including an invalid prefix reaching the DB, which should not happen —
  callers validate first) is treated the same as "table absent".
  """
  @spec raw_comment(Ecto.Repo.t(), String.t()) :: raw_comment()
  def raw_comment(repo, prefix) do
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit'
      AND table_schema = $1
    )
    """

    case repo.query(table_exists_query, [prefix], log: false) do
      {:ok, %{rows: [[true]]}} -> read_comment(repo, prefix)
      _ -> :absent
    end
  end

  defp read_comment(repo, prefix) do
    version_query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = 'phoenix_kit'
    AND pg_namespace.nspname = $1
    """

    case repo.query(version_query, [prefix], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      {:ok, %{rows: [[nil]]}} -> nil
      _ -> nil
    end
  end

  @doc "The connected server's Postgres major version (`SHOW server_version_num`'s leading digits), for §6.3's preflight."
  @spec server_version_major(Ecto.Repo.t()) :: pos_integer() | :unknown
  def server_version_major(repo) do
    case repo.query("SHOW server_version_num", [], log: false) do
      {:ok, %{rows: [[num_str]]}} when is_binary(num_str) ->
        num_str |> String.to_integer() |> div(10_000)

      _ ->
        :unknown
    end
  end

  @tables_sql """
  SELECT c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND c.relkind = 'r'
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
  """

  # `con.conindid` is NOT exclusively "the index this PK/UNIQUE constraint owns" —
  # Postgres also points a FOREIGN KEY constraint's `conindid` at the unique index
  # on the REFERENCED table/column it relies on for uniqueness (`contype = 'f'`,
  # on the far side of the FK, not the referencing side). Filtering on bare
  # `con.oid IS NULL` therefore silently dropped every unique index that is
  # merely an FK's target elsewhere in the schema — confirmed live: a fresh
  # install's `phoenix_kit_ai_endpoints_uuid_idx` disappeared from the snapshot
  # (and so, from `lookup/2`) purely because `fk_ai_requests_endpoint_uuid` (a
  # constraint on a DIFFERENT table, `phoenix_kit_ai_requests`) references it —
  # `repair` then reported the index "missing" and (harmlessly, `CREATE ...IF
  # NOT EXISTS`) "repaired" one that was never gone, on every healthy install
  # with an FK-referenced uuid index (a common shape — see `dev_docs/squash/
  # generate_baseline.exs`'s `Catalog` module, which mirrors this same query and
  # carried the identical bug). The join must restrict to `contype IN ('p','
  # 'u')` — the only two constraint kinds where "this index backs a constraint
  # ON ITS OWN TABLE, so don't ALSO list it as a bare index" is the intended
  # rule.
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
  """

  @sequences_sql """
  SELECT c.relname,
         pg_catalog.format_type(s.seqtypid, NULL),
         s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle
  FROM pg_sequence s
  JOIN pg_class c ON c.oid = s.seqrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1
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
  """

  # No namespace filter — matches `PhoenixKit.Squash.Generate.Catalog`'s own
  # `@extensions_sql` exactly. `Helpers.ensure_extension!/1-2` never specifies
  # a target schema (`CREATE EXTENSION IF NOT EXISTS <name>`, no `WITH
  # SCHEMA`), so citext/pgcrypto/pg_trgm are effectively database-wide, not
  # scoped to the PhoenixKit install's own prefix — a prefixed install shares
  # them with the rest of the database.
  @extensions_sql "SELECT extname FROM pg_extension"

  @doc """
  A full structural snapshot of `prefix` on the target server — one round
  trip per class (7 queries total), mirroring
  `PhoenixKit.Squash.Generate.Catalog.snapshot/2`'s shape exactly (minus
  seeds — see `PhoenixKit.Migrations.Repair.Differ`'s moduledoc for why seed
  rows are checked for presence only, never snapshotted for value
  comparison). `oban_*` tables/sequences/functions and `schema_migrations`
  are excluded — Oban is delegated, never manifested (spec §6.1).

  ## Why this forces `search_path = ''` for the duration of the snapshot

  `pg_get_expr`/`pg_get_indexdef`/`pg_get_constraintdef` (used by the
  columns/indexes/constraints queries below to render defaults, predicates,
  and definitions) decide **at read time**, from the QUERYING session's
  `search_path`, whether to schema-qualify a referenced function/type —
  never from how the object was originally created. The manifest's
  expected shapes are captured by the generator
  (`PhoenixKit.Squash.Generate.Catalog.snapshot/2`, `dev_docs/squash/
  generate_baseline.exs`) from a scratch schema its own `validate_schemas!/1`
  refuses to let be named `"public"` — specifically so that schema is never
  on the generation connection's default search_path — so the generator's
  captured text is (by that constraint) always schema-qualified, then
  token-substituted for `"__SCHEMA__"` (`DumpHelper.substitute_schema/2`).
  A `"public"`-prefix install's OWN default search_path normally DOES
  include `public`, so without this, the exact same stored default (e.g.
  every `uuid_generate_v7()`-defaulted column — nearly every primary/
  foreign key in the chain) would read back UNQUALIFIED here while the
  materialized manifest expects it QUALIFIED, manufacturing a false
  `:wrong_shape` divergence (`PhoenixKit.Migrations.Repair.Differ`) on the
  single most common install topology, on very common objects, for reasons
  having nothing to do with real drift. Forcing `search_path = ''` here —
  the same idiom `pg_dump` itself relies on for portable, fully-qualified
  output — makes this side schema-qualify exactly as consistently as the
  generator's capture does, independent of which prefix is being probed.
  `pg_catalog` (every query below is a `pg_catalog`/`pg_*` read) stays
  resolvable regardless: Postgres always searches it first, whether or not
  it is named in `search_path`.

  Runs inside `repo.checkout/2` so the `SET`, every catalog query, and the
  final `RESET` land on the SAME physical connection — Ecto/DBConnection
  checkout nests transparently, so this is equally safe called from inside
  `PhoenixKit.Migrations.Repair.Environment.with_lock/2`'s own outer
  checkout (the common, direct-connection path) or as the outermost
  checkout (the `--unsafe-pooled` path, which skips the lock). The `after`
  clause restores `search_path` unconditionally, even if a catalog query
  raises — this is session-level state on a connection this process
  **borrows** from a pool it shares with the rest of the host application;
  leaving it at `''` would silently break any later unqualified query
  issued by anything else on that physical connection once it is checked
  back in. `RESET search_path` (never a literal previous-value `SET`)
  correctly restores the default for every deployment this tool documents
  supporting — PhoenixKit's own runtime queries never rely on `search_path`
  for a prefixed install (`CLAUDE.md`: "no `search_path` requirement on the
  DB role"), so nothing in this codebase's own connections customizes it at
  connect time for a `RESET` to lose.
  """
  @spec snapshot(Ecto.Repo.t(), String.t()) :: snapshot()
  def snapshot(repo, prefix) do
    repo.checkout(fn ->
      repo.query!("SET search_path TO ''", [], log: false)

      try do
        %{
          tables: tables(repo, prefix),
          columns: columns(repo, prefix),
          indexes: indexes(repo, prefix),
          constraints: constraints(repo, prefix),
          sequences: sequences(repo, prefix),
          functions: functions(repo, prefix),
          extensions: extensions(repo, prefix)
        }
      after
        repo.query!("RESET search_path", [], log: false)
      end
    end)
  end

  defp tables(repo, prefix) do
    for [name] <- rows!(repo, @tables_sql, [prefix]),
        keep_table?(name),
        into: %{},
        do: {name, %{}}
  end

  defp columns(repo, prefix) do
    for [table, col, type, not_null, default, pos] <- rows!(repo, @columns_sql, [prefix]),
        keep_table?(table),
        into: %{} do
      {{table, col}, %{type: type, not_null: not_null, default: default, pos: pos}}
    end
  end

  defp indexes(repo, prefix) do
    for [table, name, unique, method, definition, predicate, keys, opclasses] <-
          rows!(repo, @indexes_sql, [prefix]),
        keep_table?(table),
        into: %{} do
      {name,
       %{
         table: table,
         unique: unique,
         method: method,
         definition: definition,
         predicate: predicate,
         keys: keys || [],
         opclasses: opclasses || []
       }}
    end
  end

  defp constraints(repo, prefix) do
    for [table, name, contype, definition, columns, ftable, fcolumns, del, upd] <-
          rows!(repo, @constraints_sql, [prefix]),
        keep_table?(table),
        into: %{} do
      {{table, name},
       %{
         type: contype,
         definition: definition,
         columns: columns,
         foreign_table: ftable,
         foreign_columns: fcolumns,
         on_delete: fk_action(contype, del),
         on_update: fk_action(contype, upd)
       }}
    end
  end

  defp sequences(repo, prefix) do
    for [name, type, start, inc, min, max, cache, cycle] <- rows!(repo, @sequences_sql, [prefix]),
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

  defp functions(repo, prefix) do
    for [name, args, definition, lang, returns, md5] <- rows!(repo, @functions_sql, [prefix]),
        keep_function?(name),
        into: %{} do
      {{name, args}, %{returns: returns, language: lang, body_md5: md5, definition: definition}}
    end
  end

  defp extensions(repo, _prefix) do
    for [name] <- rows!(repo, @extensions_sql, []), into: %{}, do: {name, %{}}
  end

  defp rows!(repo, sql, params) do
    %{rows: rows} = repo.query!(sql, params, log: false)
    rows
  end

  # Mirrors `PhoenixKit.Squash.Generate.Catalog`'s three near-identical
  # filters exactly (kept distinct, not merged, for the same reason Catalog
  # keeps them distinct — `keep_function?/1`'s "oban" match is deliberately
  # broader, no trailing underscore).
  defp keep_table?(name),
    do: name != "schema_migrations" and not String.starts_with?(name, "oban_")

  defp keep_sequence?(name), do: not String.starts_with?(name, "oban_")
  defp keep_function?(name), do: not String.starts_with?(name, "oban")

  defp fk_action("f", action), do: action
  defp fk_action(_contype, _action), do: nil

  @doc """
  Looks up the observed shape for one `{:catalog, spec}` check within a
  `snapshot/2` result. `nil` means absent (the caller treats that as
  `:missing`). Pure — the one function in this module with a direct unit
  test (`probe_test.exs` builds a snapshot by hand).

      iex> snapshot = %{tables: %{"widgets" => %{}}, columns: %{}, indexes: %{},
      ...>   constraints: %{}, sequences: %{}, functions: %{}, extensions: %{}}
      iex> Probe.lookup(snapshot, {:catalog, %{kind: :table, name: "widgets"}})
      %{}
      iex> Probe.lookup(snapshot, {:catalog, %{kind: :table, name: "missing"}})
      nil
  """
  @spec lookup(snapshot(), Object.check()) :: map() | nil
  def lookup(snapshot, {:catalog, %{kind: :table, name: name}}),
    do: Map.get(snapshot.tables, name)

  def lookup(snapshot, {:catalog, %{kind: :extension, name: name}}),
    do: Map.get(snapshot.extensions, name)

  def lookup(snapshot, {:catalog, %{kind: :column, table: t, column: c}}),
    do: Map.get(snapshot.columns, {t, c})

  def lookup(snapshot, {:catalog, %{kind: :index, name: n}}), do: Map.get(snapshot.indexes, n)

  def lookup(snapshot, {:catalog, %{kind: :constraint, table: t, name: n}}),
    do: Map.get(snapshot.constraints, {t, n})

  def lookup(snapshot, {:catalog, %{kind: :sequence, name: n}}),
    do: Map.get(snapshot.sequences, n)

  def lookup(snapshot, {:catalog, %{kind: :function, name: n, args: a}}),
    do: Map.get(snapshot.functions, {n, a})

  # :seed checks are a raw SQL string, not a catalog spec — presence is
  # decided by executing it (`seed_present?/2`), never by snapshot lookup.
  def lookup(_snapshot, check) when is_binary(check), do: nil

  @doc "Executes an already-materialized `:seed` `check` SQL string (`SELECT EXISTS (...)`)."
  @spec seed_present?(Ecto.Repo.t(), String.t()) :: boolean()
  def seed_present?(repo, check_sql) when is_binary(check_sql) do
    case repo.query(check_sql, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  For each distinct `since` among `objects`, whether every object introduced
  at that version is structurally present in `snapshot` — the input
  `PhoenixKit.Migrations.Repair.CommentPolicy.highest_fully_present_version/1`
  consumes. `:seed`-class and `:legacy_optional` objects are excluded from
  the computation (never made to count against a version being "fully
  present"): seed presence is a data-completeness question, not a schema
  marker (best-effort seeders are "NOT guaranteed present" by design), and
  `:legacy_optional` presence is bimodal by design (spec §3.7) — either state
  is normal, so neither should ever cause a version to read as "behind".

  Grouping happens on the RAW `since` first, filtering only within each
  group — never `Enum.filter/2` before `Enum.group_by/2`. A `since` bucket
  whose objects are *entirely* seeds/`:legacy_optional` (e.g. a version that
  only ever added a seed row) still gets an entry here, `{since, true}`
  (`Enum.all?/2` on the empty, fully-filtered list is vacuously `true`) —
  dropping such a bucket from the result instead of reporting it present
  would happen to be harmless for `CommentPolicy.highest_fully_present_version/1`
  today (`take_while` over a sorted list tolerates a missing entry exactly
  like a `true` one), but this function's own contract — "for each distinct
  `since` among `objects`" — promises an entry for every one, and a future
  caller should not have to know that gap-tolerance to rely on it correctly.
  """
  @spec presence_by_since(list(Object.t()), snapshot()) :: [{pos_integer(), boolean()}]
  def presence_by_since(objects, snapshot) do
    objects
    |> Enum.group_by(& &1.since)
    |> Enum.map(fn {since, objs} ->
      countable = Enum.filter(objs, &counts_for_marker?/1)
      {since, Enum.all?(countable, &present?(&1, snapshot))}
    end)
  end

  defp counts_for_marker?(%{class: :seed}), do: false
  defp counts_for_marker?(%{presence: :legacy_optional}), do: false
  defp counts_for_marker?(_object), do: true

  defp present?(%{check: check}, snapshot), do: not is_nil(lookup(snapshot, check))

  @doc """
  Counts rows in `table` whose `fk_column` does not match any row in
  `foreign_table.foreign_column` — the orphan diagnostic spec §6.3 attaches
  to a failed FK `VALIDATE CONSTRAINT` (leave the constraint `NOT VALID`,
  report the count rather than guessing a fix). All four identifiers are
  validated (`[a-zA-Z_][a-zA-Z0-9_]*`) before interpolation — they come from
  the catalog snapshot, not user input, but this executes as a plain string
  query, not a parameterized one, because table/column names cannot be bind
  parameters in SQL.
  """
  @spec orphan_count(Ecto.Repo.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          non_neg_integer() | :unknown
  def orphan_count(repo, prefix, table, fk_column, foreign_table, foreign_column) do
    for ident <- [prefix, table, fk_column, foreign_table, foreign_column] do
      unless is_binary(ident) and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, ident) do
        raise ArgumentError, "unsafe SQL identifier in orphan_count: #{inspect(ident)}"
      end
    end

    query = """
    SELECT count(*)::integer FROM #{prefix}.#{table} t
    WHERE t.#{fk_column} IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM #{prefix}.#{foreign_table} r WHERE r.#{foreign_column} = t.#{fk_column})
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[count]]}} -> count
      _ -> :unknown
    end
  end
end
