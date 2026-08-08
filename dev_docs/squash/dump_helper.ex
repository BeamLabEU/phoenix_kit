defmodule PhoenixKit.Squash.DumpHelper do
  @moduledoc """
  pg_dump invocation + deterministic normalization so schema dumps taken from
  two different schemas (or two different scratch runs) compare byte-for-byte,
  plus the S2 seed-data oracle (spec 2026-07-14-squash-migrations-spec.md,
  sections 8.2 S1/S2 and 8.3).

  Functions tagged `[DB]` shell out to pg_dump/psql over a DIRECT connection
  (env from `PhoenixKit.Squash.RepoHelper.connection_env/0`). Everything else
  is pure and exercised offline by `run_self_checks/0`.

  ## Schema-dump normalization rules (S1 — these ARE the spec; keep reproducible)

  `normalise/2` applies, in order:

  1. psql meta lines dropped: any line whose first non-blank character is `\\`
     (`\\restrict`/`\\unrestrict` carry a per-dump random token since the
     2025-08 PostgreSQL security releases and never compare equal).
  2. Statement split via a dollar-quote-aware tokenizer (`split_statements/1`):
     statements end only at `;` encountered OUTSIDE single-quoted strings
     (`''` escape), double-quoted identifiers (`""` escape), dollar-quoted
     bodies (`$$..$$` and tagged `$tag$..$tag$`), line comments, and (nested)
     block comments. Top-level comment bytes are dropped during the scan;
     comment text INSIDE a dollar-quoted body is content and is preserved.
  3. Session statements removed: `SET ...` and `SELECT pg_catalog.set_config(...)`.
  4. `CREATE SCHEMA <schema>` removed after substitution (schema existence is a
     precondition, not shape; also makes public-vs-named comparisons possible).
  5. Schema-name substitution to `__SCHEMA__`, on word boundaries only
     (`(?<![A-Za-z0-9_])name(?![A-Za-z0-9_])`), so `myschema_extra` and
     `x_myschema` are never corrupted. Covers `"quoted"`, `'literal'`, and
     dotted forms in one rule. PLUS the prefix-embedded identifier rule: the
     V56-era `prefix_index_name/2` idiom names objects `<prefix>_phoenix_kit_*`
     on named-schema installs but bare `phoenix_kit_*` on public (v56.ex:574-576)
     — `<schema>_` immediately followed by `phoenix_kit` is STRIPPED, folding
     every install to the public-canonical name so named-vs-named and
     public-vs-named comparisons both work. (The manifest layer handles the
     same idiom separately via name templating — this fold is comparison-only.)
  6. `ARRAY[...]`-membership CHECK constraint canonicalization: Postgres has TWO
     equally-valid ways to deparse `x = ANY (ARRAY['a','b']::type[])` once the
     array is built from a cast type (e.g. `character varying`) — element-wise
     (`ARRAY[('a'::type)::text, ('b'::type)::text]`) or array-wise
     (`(ARRAY['a'::type, 'b'::type])::text[]`) — SAME constraint, same enforced
     values, chosen non-deterministically by which exact SQL text originally
     built the constraint's internal expression tree (confirmed empirically:
     both forms appear in this project's own tooling output for otherwise
     byte-identical constraints — spec section 6.2's "PG deparse differences
     must be handled structurally" risk, realized). `canonicalize_array_casts/1`
     folds ANY element-wise run into the array-wise form BEFORE the two dumps
     are compared, so this can never register as a false S1 divergence again.
  7. Whitespace: trailing whitespace trimmed per line; statements trimmed.
  8. Ordering: statements sorted lexicographically (byte order) AFTER
     substitution, joined with `;\\n\\n` plus a trailing `;` — pg_dump object
     ordering differences can never produce a diff.

  Not compared via dumps (by design): extensions (`pg_dump -n <schema>` omits
  non-members — the manifest/repair layer owns extension checks) and COMMENT
  statements (`--no-comments`; the version-marker comment is asserted
  separately, S15).

  ## `:legacy_optional` whitelist (S1 bimodality tolerance)

  `compare/5` accepts `legacy_optional: [object_name]` — names of objects with
  known bimodal presence (spec section 3.7: `preferred_locale` + its index, the
  V13-vs-V22 duplicate partial unique index). Semantics:

  - A statement LINE is removed (from BOTH sides, reported back as tolerated)
    only when the identifier it DECLARES — the column being defined, or the
    object being created (`CREATE INDEX` name, `ADD CONSTRAINT` name) —
    matches a whitelisted name on a word boundary. A line that merely
    REFERENCES a whitelisted name (an index definition over a whitelisted
    column) is kept, so the whitelist cannot mask one-sided drift of
    differently-named objects — the false S1 pass this oracle exists to
    prevent.
  - Column entries are table-QUALIFIED (`"table.column"`) and match only
    inside that table's `CREATE TABLE` statement — a same-named column in
    another table is NOT masked. Dotless entries (index/constraint/sequence
    names — schema-unique) match any declared identifier.
  - A statement whose every content line matches is dropped whole (covers
    single-line `CREATE INDEX ...`).
  - While the whitelist is active, trailing commas are stripped from ALL
    statement lines on BOTH sides, so removing a mid/last column line from a
    `CREATE TABLE` body stays syntactically neutral.
  - ANY remaining difference is a failure (`{:diff, unified_diff_text}`).
    Tolerated one-sided lines are reported via `{:equal_modulo_whitelist, ...}`
    so the caller can log them at info level.

  ## Seed-data normalization rules (S2 — reproducible)

  `dump_seed_data/2` emits one section per table (default list:
  `default_seed_tables/0`, dependency-ordered), each `-- table: <name>` plus
  CSV. Rules:

  1. Column projection: ALL columns, alphabetically ordered (physical attnum
     order is bimodal between fresh and upgraded installs).
  2. Row ordering: per-table stable business key (`name`/`key`/`code`/
     `module_key`/`slug`); override via `order_by:`; unknown tables order by
     all non-volatile columns. Note: `phoenix_kit_role_permissions` orders by
     `module_key` only — deterministic while only the Admin role is seeded.
  3. CSV via `COPY ... TO STDOUT (FORMAT csv, HEADER, FORCE_QUOTE *)` so NULL
     (unquoted empty) and '' (quoted empty) stay distinguishable.
  4. UUID remap (`normalize_seed_rows/1`): every uuid value is replaced by
     `<uuid-N>` where N is the order of first appearance across the WHOLE
     multi-table dump — FK identity (for example `role_permissions.role_uuid`
     vs `user_roles.uuid`) is preserved without comparing raw generated ids.
     Matching is case-insensitive.
  5. Timestamps: every timestamp-shaped value (date + time, optional fraction,
     optional `Z`/offset) becomes `<ts>` — including timestamps embedded in
     `value_json`. Date-only values are deliberately NOT normalized.
  6. A missing table yields a `-- table: <name> MISSING` section instead of an
     error (S2 tolerates seeder absence only in release mode — the caller
     decides whether MISSING is acceptable).
  """

  alias PhoenixKit.Squash.RepoHelper

  @schema_placeholder "__SCHEMA__"

  # Dependency-ordered: referenced tables before referencing ones so uuid
  # remapping assigns FK targets their token first.
  @default_seed_tables [
    "phoenix_kit_user_roles",
    "phoenix_kit_settings",
    "phoenix_kit_currencies",
    "phoenix_kit_payment_options",
    "phoenix_kit_storage_dimensions",
    "phoenix_kit_buckets",
    "phoenix_kit_role_permissions",
    "phoenix_kit_email_templates"
  ]

  @seed_order_keys %{
    "phoenix_kit_user_roles" => ["name"],
    "phoenix_kit_settings" => ["key"],
    "phoenix_kit_currencies" => ["code"],
    "phoenix_kit_payment_options" => ["code"],
    "phoenix_kit_storage_dimensions" => ["name"],
    "phoenix_kit_buckets" => ["name"],
    "phoenix_kit_role_permissions" => ["module_key"],
    "phoenix_kit_email_templates" => ["slug"]
  }

  # information_schema.columns data_type values excluded from ORDER BY keys
  # (their values are generated per-install and carry no stable order).
  @volatile_types [
    "uuid",
    "timestamp with time zone",
    "timestamp without time zone"
  ]

  @uuid_re ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
  @ts_re ~r/\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}(?::?\d{2})?)?/

  # Dollar-quote opener after the initial `$`: an optional tag
  # ([A-Za-z_][A-Za-z0-9_]*) immediately followed by the closing `$`.
  @dollar_tag_re ~r/\A(?:[A-Za-z_][A-Za-z0-9_]*)?\$/

  # Element-wise ARRAY[...]-membership cast run: one or more
  # `('literal'::type)::text` elements, comma-separated, inside `ARRAY[...]`.
  # Matched non-greedily is unnecessary — the element pattern itself cannot
  # span a `]`, so this cannot over-match past the array's real close.
  @array_cast_run_re ~r/ARRAY\[((?:\('[^']*'::[A-Za-z_ ]+\)::text,?\s*)+)\]/
  @array_cast_element_re ~r/\('([^']*)'::([A-Za-z_ ]+)\)::text/

  # ---------------------------------------------------------------------------
  # Dumping (DB)
  # ---------------------------------------------------------------------------

  @doc """
  Run `pg_dump --schema-only` for the given schema; returns `{:ok, sql}`.

  pg_dump is invoked over a DIRECT connection (PGHOST/PGPORT from env), which
  bypasses PgBouncer. Required: pg_dump relies on session state and catalog
  access that transaction-pooled PgBouncer connections break, and this
  project's PgBouncer silently drops transactional DDL — all verification
  traffic must use the direct 5432 endpoint.

  `schema_migrations` is excluded: Ecto's bookkeeping table is an
  implementation detail, not part of the PhoenixKit schema shape.

  On failure pg_dump's stderr goes to the console (not captured); the error
  tuple carries the exit code.

  [DB]
  """
  def dump(schema) do
    validate_pg_identifier!(schema, "schema")
    ce = RepoHelper.connection_env()

    args = [
      "--schema-only",
      "--no-owner",
      "--no-privileges",
      "--no-comments",
      "-n",
      schema,
      "--exclude-table=#{schema}.schema_migrations",
      ce.database
    ]

    case System.cmd("pg_dump", args, env: pg_env(ce)) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, "pg_dump exited #{exit_code}: #{output}"}
    end
  end

  @doc """
  Same as `dump/1` but raises on failure.
  [DB]
  """
  def dump!(schema) do
    case dump(schema) do
      {:ok, sql} -> sql
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Dump ordered, normalized seed-table rows for the S2 oracle.

  Options:

    * `:tables` — list of table names (default `default_seed_tables/0`)
    * `:order_by` — keyword/map of `table => [column]` ORDER BY overrides

  Returns `{:ok, normalized_text}` (sections per table, uuid/timestamp
  normalized per the moduledoc rules) or `{:error, reason}`.

  [DB]
  """
  def dump_seed_data(schema, opts \\ []) do
    validate_pg_identifier!(schema, "schema")
    tables = Keyword.get(opts, :tables, @default_seed_tables)

    # Keys stringified so both %{"table" => cols} and [table: cols] shapes work
    # against the string table names in :tables.
    overrides =
      Map.new(Keyword.get(opts, :order_by, []), fn {k, v} -> {to_string(k), v} end)

    order_keys = Map.merge(@seed_order_keys, overrides)

    tables
    |> Enum.reduce_while([], fn table, acc ->
      validate_pg_identifier!(table, "table")

      case seed_table_section(schema, table, Map.get(order_keys, table)) do
        {:ok, section} -> {:cont, [section | acc]}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      sections -> {:ok, sections |> Enum.reverse() |> Enum.join("\n") |> normalize_seed_rows()}
    end
  end

  @doc """
  Same as `dump_seed_data/2` but raises on failure.
  [DB]
  """
  def dump_seed_data!(schema, opts \\ []) do
    case dump_seed_data(schema, opts) do
      {:ok, text} -> text
      {:error, reason} -> raise reason
    end
  end

  @doc "Default seed-table list for the S2 oracle (dependency-ordered)."
  def default_seed_tables, do: @default_seed_tables

  # ---------------------------------------------------------------------------
  # Normalization (pure)
  # ---------------------------------------------------------------------------

  @doc """
  Normalise a pg_dump SQL string per the moduledoc rules. Pure.

  Deterministic for a given schema shape regardless of the schema name used,
  pg_dump object ordering, or the psql `\\restrict` token; idempotent given the
  same `schema_name`.
  """
  def normalise(sql, schema_name) when is_binary(sql) and is_binary(schema_name) do
    sql |> normalised_statements(schema_name) |> join_statements()
  end

  @doc """
  Split a SQL script into top-level statements. Pure.

  Splits ONLY on `;` outside single-quoted strings, double-quoted identifiers,
  `$$`/`$tag$` dollar-quoted bodies, line comments, and (nested) block
  comments. Top-level comments are dropped; comments inside dollar-quoted
  bodies are preserved as content. Statements are returned trimmed, without
  their terminating `;`.
  """
  def split_statements(sql) when is_binary(sql), do: scan(sql, :normal, <<>>, [])

  @doc """
  Replace `schema_name` with `__SCHEMA__` on word boundaries only. Pure.
  """
  def substitute_schema(sql, schema_name)
      when is_binary(sql) and is_binary(schema_name) do
    sql
    # Prefix-embedded identifiers first (V56-era prefix_index_name idiom,
    # v56.ex:574-576): `<schema>_phoenix_kit_*` folds to the public-canonical
    # bare name. Must run BEFORE the boundary rule (which would otherwise
    # never match inside the identifier) and only fires when followed by
    # `phoenix_kit`, so no other identifier can be corrupted.
    |> then(
      &Regex.replace(
        ~r/(?<![A-Za-z0-9_])#{Regex.escape(schema_name)}_(?=phoenix_kit)/,
        &1,
        ""
      )
    )
    |> then(&Regex.replace(boundary_regex(schema_name), &1, @schema_placeholder))
  end

  @doc """
  Fold an element-wise `ARRAY[(x::type)::text, ...]` cast run into the
  array-wise `(ARRAY[x::type, ...])::text[]` form. Pure; idempotent (a
  string with no element-wise run, including one already in array-wise
  form, passes through unchanged since its shape does not match
  `@array_cast_run_re`).

  See moduledoc rule 6 for why both forms are legitimate `pg_get_constraintdef`
  output for the SAME constraint.

      iex> DumpHelper.canonicalize_array_casts(
      ...>   "ANY (ARRAY[('a'::character varying)::text, ('b'::character varying)::text])"
      ...> )
      "ANY ((ARRAY['a'::character varying, 'b'::character varying])::text[])"
  """
  @spec canonicalize_array_casts(String.t()) :: String.t()
  def canonicalize_array_casts(text) when is_binary(text) do
    Regex.replace(@array_cast_run_re, text, fn _whole, run ->
      elements =
        Enum.map(Regex.scan(@array_cast_element_re, run), fn [_whole, literal, type] ->
          "'#{literal}'::#{String.trim(type)}"
        end)

      "(ARRAY[" <> Enum.join(elements, ", ") <> "])::text[]"
    end)
  end

  @doc """
  Detects the SAME `<schema>_phoenix_kit_*` idiom `substitute_schema/2` folds
  away above, but for an EXACT identifier (an index/constraint NAME, not a
  free-text SQL blob) — returns the bare suffix with the scratch-schema
  prefix stripped, or `nil` when `identifier` does not start with it.
  Anchored to the START of `identifier` (unlike `substitute_schema/2`'s
  free-text scan) — an index/constraint name is one token, not prose, so a
  match can only ever be meaningful there.

  Used by the manifest generator (`PhoenixKit.Squash.Generate.Catalog`) to
  canonicalize an object's dictionary KEY at capture time, so a stepwise and
  a single-shot run — which use different scratch schema names — key the
  SAME real-world object identically and never manufacture a phantom
  presence-bimodality pair out of it (spec 3.7's `:legacy_optional` model is
  for genuine presence differences, not a scratch-schema-name artifact).
  `substitute_schema/2`'s fold above always collapses to the BARE form
  regardless of which of the two known real-world naming conventions
  produced the name (v56.ex/v61.ex's `prefix_index_name/2` — bare on
  `public`, prefixed otherwise — vs v26.ex's inline naming — always
  prefixed, `public` included) — that is correct for THIS module's own
  scratch-vs-scratch dump comparisons, but callers that need the TRUE
  real-world name for a specific target prefix (the generator's Emitter,
  rendering an installable manifest/baseline) must re-derive it themselves
  from the bare suffix this function returns, keyed to the correct
  convention per object — see `Catalog.classify_exemption/1`.

      iex> DumpHelper.prefix_embedded_bare_suffix("pk_step_phoenix_kit_x_uuid_idx", "pk_step")
      "phoenix_kit_x_uuid_idx"
      iex> DumpHelper.prefix_embedded_bare_suffix("phoenix_kit_x_uuid_idx", "pk_step")
      nil
      iex> DumpHelper.prefix_embedded_bare_suffix("pk_step_something_else", "pk_step")
      nil
  """
  @spec prefix_embedded_bare_suffix(String.t(), String.t()) :: String.t() | nil
  def prefix_embedded_bare_suffix(identifier, schema_name)
      when is_binary(identifier) and is_binary(schema_name) do
    prefix = schema_name <> "_"

    if String.starts_with?(identifier, prefix) do
      rest = String.replace_prefix(identifier, prefix, "")
      if String.starts_with?(rest, "phoenix_kit"), do: rest
    end
  end

  @doc """
  Normalize a seed-data dump: remap uuids to `<uuid-N>` (N = order of first
  appearance, case-insensitive, consistent across the whole text) and replace
  timestamp-shaped values with `<ts>`. Pure.
  """
  def normalize_seed_rows(text) when is_binary(text) do
    {mapping, _n} =
      @uuid_re
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.reduce({%{}, 1}, fn uuid, {map, n} ->
        key = String.downcase(uuid)

        case map do
          %{^key => _} -> {map, n}
          _ -> {Map.put(map, key, "<uuid-#{n}>"), n + 1}
        end
      end)

    text
    |> then(&Regex.replace(@uuid_re, &1, fn u -> Map.fetch!(mapping, String.downcase(u)) end))
    |> then(&Regex.replace(@ts_re, &1, "<ts>"))
  end

  # ---------------------------------------------------------------------------
  # Comparison
  # ---------------------------------------------------------------------------

  @doc """
  Compare two raw dumps (from schemas `schema_a`/`schema_b`) after
  normalisation.

  Options:

    * `:legacy_optional` — list of object names whose presence-diff is
      tolerated (see moduledoc). Default `[]` = strict.

  Returns:

    * `:equal` — byte-identical after normalisation, nothing tolerated
    * `{:equal_modulo_whitelist, %{only_a: [line], only_b: [line]}}` — equal
      after whitelist filtering; the one-sided tolerated lines are listed
    * `{:diff, unified_diff_text}` — any unlisted difference (= FAILURE for S1)
  """
  def compare(dump_a, schema_a, dump_b, schema_b, opts \\ []) do
    whitelist = Keyword.get(opts, :legacy_optional, [])

    stmts_a = normalised_statements(dump_a, schema_a)
    stmts_b = normalised_statements(dump_b, schema_b)

    {kept_a, removed_a} = apply_whitelist(stmts_a, whitelist)
    {kept_b, removed_b} = apply_whitelist(stmts_b, whitelist)

    text_a = join_statements(kept_a)
    text_b = join_statements(kept_b)

    only_a = removed_a -- removed_b
    only_b = removed_b -- removed_a

    cond do
      text_a == text_b and only_a == [] and only_b == [] ->
        :equal

      text_a == text_b ->
        {:equal_modulo_whitelist, %{only_a: only_a, only_b: only_b}}

      true ->
        {:diff, diff_text(text_a, text_b, schema_a, schema_b)}
    end
  end

  @doc """
  Compare and print the outcome (unified diff on divergence, tolerated lines
  on whitelist matches). Returns the `compare/5` result so callers can branch.
  """
  def print_diff(dump_a, schema_a, dump_b, schema_b, opts \\ []) do
    case compare(dump_a, schema_a, dump_b, schema_b, opts) do
      :equal ->
        IO.puts("Dumps are identical after normalisation.")
        :equal

      {:equal_modulo_whitelist, tolerated} = result ->
        IO.puts("Dumps are identical modulo the :legacy_optional whitelist:")
        Enum.each(tolerated.only_a, &IO.puts("  only in #{schema_a}: #{&1}"))
        Enum.each(tolerated.only_b, &IO.puts("  only in #{schema_b}: #{&1}"))
        result

      {:diff, text} = result ->
        IO.puts("Dumps differ after normalisation (unlisted divergence = FAILURE):")
        IO.puts(text)
        result
    end
  end

  @doc """
  Unified diff of two texts via `diff -u` on temp files (never index-based
  line pairing — a single insertion must not avalanche). Returns `:equal` or
  `{:diff, diff_text}`. Offline-safe (no DB).
  """
  def unified_diff(text_a, text_b, label_a \\ "a", label_b \\ "b") do
    if text_a == text_b do
      :equal
    else
      # OS pid + VM-unique integer: safe against concurrent runs of this
      # tooling in separate VMs sharing one tmp dir.
      uniq = "#{System.pid()}_#{System.unique_integer([:positive])}"
      path_a = Path.join(System.tmp_dir!(), "pk_squash_diff_#{uniq}_a")
      path_b = Path.join(System.tmp_dir!(), "pk_squash_diff_#{uniq}_b")

      try do
        File.write!(path_a, ensure_trailing_newline(text_a))
        File.write!(path_b, ensure_trailing_newline(text_b))

        args = ["-u", "--label", label_a, "--label", label_b, path_a, path_b]

        case System.cmd("diff", args, stderr_to_stdout: true) do
          {_out, 0} -> :equal
          {out, 1} -> {:diff, out}
          {out, code} -> raise "diff exited #{code}: #{out}"
        end
      after
        File.rm(path_a)
        File.rm(path_b)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Self-checks (offline; used by verify.exs --check)
  # ---------------------------------------------------------------------------

  @splitter_fixture ~S"""
  -- top-level comment; with a semicolon
  CREATE FUNCTION f() RETURNS text
      AS $$
  BEGIN
    -- inner; comment kept
    PERFORM 1;
    RETURN 'a$b';
  END;
  $$ LANGUAGE plpgsql;

  CREATE FUNCTION g() RETURNS text AS $body$
  SELECT 'x; y';
  $body$ LANGUAGE sql;

  INSERT INTO t (a) VALUES ('don''t; stop');

  CREATE TABLE "weird;name" (id integer);

  PREPARE p AS SELECT $1;

  /* block; comment */ SELECT /* nested /* deep; */ ok */ 2;
  """

  @twin_dump_a ~S"""
  SET statement_timeout = 0;
  SELECT pg_catalog.set_config('search_path', '', false);
  \restrict AAAA1111
  --
  -- Name: users; Type: TABLE; Schema: pk_old; Owner: -
  --
  CREATE SCHEMA pk_old;
  CREATE TABLE pk_old.users (
      id integer NOT NULL,
      preferred_locale character varying(10),
      email text
  );
  CREATE INDEX idx_users_email ON pk_old.users USING btree (email);
  CREATE INDEX idx_users_preferred_locale ON pk_old.users USING btree (preferred_locale);
  CREATE FUNCTION pk_old.uuid_generate_v7() RETURNS uuid
      LANGUAGE plpgsql
      AS $$
  BEGIN
    -- keep; this comment is inside the body
    RETURN encode(public.gen_random_bytes(16), 'hex')::uuid;
  END;
  $$;
  \unrestrict AAAA1111
  """

  @twin_dump_b ~S"""
  SET statement_timeout = 0;
  SET client_encoding = 'UTF8';
  SELECT pg_catalog.set_config('search_path', '', false);
  \restrict BBBB2222
  CREATE SCHEMA pk_new;
  CREATE FUNCTION pk_new.uuid_generate_v7() RETURNS uuid
      LANGUAGE plpgsql
      AS $$
  BEGIN
    -- keep; this comment is inside the body
    RETURN encode(public.gen_random_bytes(16), 'hex')::uuid;
  END;
  $$;
  CREATE INDEX idx_users_preferred_locale ON pk_new.users USING btree (preferred_locale);
  CREATE INDEX idx_users_email ON pk_new.users USING btree (email);
  CREATE TABLE pk_new.users (
      id integer NOT NULL,
      preferred_locale character varying(10),
      email text
  );
  \unrestrict BBBB2222
  """

  @drift_dump_b ~S"""
  SET statement_timeout = 0;
  \restrict CCCC3333
  CREATE SCHEMA pk_new;
  CREATE FUNCTION pk_new.uuid_generate_v7() RETURNS uuid
      LANGUAGE plpgsql
      AS $$
  BEGIN
    -- keep; this comment is inside the body
    RETURN encode(public.gen_random_bytes(16), 'hex')::uuid;
  END;
  $$;
  CREATE INDEX idx_users_email ON pk_new.users USING btree (email);
  CREATE TABLE pk_new.users (
      id integer NOT NULL,
      email text
  );
  \unrestrict CCCC3333
  """

  @seed_fixture ~S"""
  -- table: phoenix_kit_user_roles
  "inserted_at","name","uuid"
  "2026-07-16 10:00:00.123456+00","Admin","0198c111-2222-7333-8444-555566667777"
  "2026-07-16T10:00:01Z","User","0198c111-2222-7333-8444-999966667777"
  -- table: phoenix_kit_role_permissions
  "module_key","role_uuid"
  "dashboard","0198C111-2222-7333-8444-555566667777"
  """

  @doc """
  Offline self-test of the pure normalisation machinery (dollar-quote
  splitter, schema substitution, normalise, whitelist compare, seed
  normalizer, diff shell-out). No DB access. Returns `:ok` or raises with the
  failing check's name. Called by verify.exs `--check`.
  """
  def run_self_checks do
    check_splitter()
    check_substitution()
    check_prefix_embedded_bare_suffix()
    check_normalise_and_compare()
    check_seed_normalizer()
    check_unified_diff()
    :ok
  end

  defp check_splitter do
    stmts = split_statements(@splitter_fixture)
    check!(length(stmts) == 6, "splitter: statement count (got #{length(stmts)})")

    [f, g, ins, tbl, prep, sel] = stmts

    check!(String.contains?(f, "PERFORM 1;"), "splitter: semicolon inside $$ body preserved")
    check!(String.contains?(f, "-- inner; comment kept"), "splitter: comment inside $$ kept")
    check!(String.contains?(f, "'a$b'"), "splitter: lone $ inside string")
    check!(String.contains?(g, "SELECT 'x; y';"), "splitter: semicolon inside $body$ tag")
    check!(ins == "INSERT INTO t (a) VALUES ('don''t; stop')", "splitter: '' escape")
    check!(tbl == ~s{CREATE TABLE "weird;name" (id integer)}, "splitter: quoted identifier")
    check!(prep == "PREPARE p AS SELECT $1", "splitter: positional param is not a dollar quote")
    normalized_sel = String.replace(sel, ~r/\s+/, " ")
    check!(normalized_sel == "SELECT 2", "splitter: block comments dropped (got #{inspect(sel)})")

    check!(
      not Enum.any?(stmts, &String.contains?(&1, "top-level comment")),
      "splitter: top-level comment dropped"
    )

    check!(not String.contains?(sel, "deep"), "splitter: nested block comment dropped")
  end

  defp check_substitution do
    input = ~s(SELECT * FROM pk_a.t, pk_a_extra.u, x_pk_a.v WHERE s = 'pk_a' AND q = "pk_a")

    expected =
      ~s(SELECT * FROM __SCHEMA__.t, pk_a_extra.u, x_pk_a.v WHERE s = '__SCHEMA__' AND q = "__SCHEMA__")

    check!(substitute_schema(input, "pk_a") == expected, "substitution: word boundaries")
  end

  defp check_prefix_embedded_bare_suffix do
    check!(
      prefix_embedded_bare_suffix("pk_step_phoenix_kit_x_uuid_idx", "pk_step") ==
        "phoenix_kit_x_uuid_idx",
      "prefix_embedded_bare_suffix: strips a matching scratch-schema prefix"
    )

    check!(
      prefix_embedded_bare_suffix("phoenix_kit_x_uuid_idx", "pk_step") == nil,
      "prefix_embedded_bare_suffix: nil when the identifier does not start with the schema"
    )

    check!(
      prefix_embedded_bare_suffix("pk_step_something_else", "pk_step") == nil,
      "prefix_embedded_bare_suffix: nil when not immediately followed by phoenix_kit"
    )

    check!(
      prefix_embedded_bare_suffix("other_pk_step_phoenix_kit_x", "pk_step") == nil,
      "prefix_embedded_bare_suffix: anchored to the START, not a mid-string match"
    )
  end

  # Whitelist branch coverage: comma-in-type column line + pg_dump's wrapped
  # `ALTER TABLE ONLY ... \n ADD CONSTRAINT` form, tolerated via a
  # table-qualified column entry + a bare constraint-name entry.
  @constraint_dump_a ~S"""
  CREATE TABLE pk_old.orders (
      id bigint,
      total numeric(10,2)
  );
  ALTER TABLE ONLY pk_old.orders
      ADD CONSTRAINT legacy_orders_unique UNIQUE (id);
  """

  @constraint_dump_b ~S"""
  CREATE TABLE pk_new.orders (
      id bigint
  );
  """

  defp check_normalise_and_compare do
    norm_a = normalise(@twin_dump_a, "pk_old")
    norm_b = normalise(@twin_dump_b, "pk_new")

    check!(norm_a == norm_b, "normalise: structural twins normalise identically")
    check!(String.contains?(norm_a, "__SCHEMA__.users"), "normalise: placeholder applied")
    check!(not String.contains?(norm_a, "SET "), "normalise: SET statements stripped")
    check!(not String.contains?(norm_a, "restrict"), "normalise: psql meta lines stripped")
    check!(not String.contains?(norm_a, "CREATE SCHEMA"), "normalise: CREATE SCHEMA stripped")
    check!(normalise(norm_a, "pk_old") == norm_a, "normalise: idempotent")

    embedded_a =
      normalise(
        "CREATE UNIQUE INDEX pk_old_phoenix_kit_ai_endpoints_uuid_idx ON pk_old.phoenix_kit_ai_endpoints USING btree (uuid);",
        "pk_old"
      )

    embedded_pub =
      normalise(
        "CREATE UNIQUE INDEX phoenix_kit_ai_endpoints_uuid_idx ON public.phoenix_kit_ai_endpoints USING btree (uuid);",
        "public"
      )

    check!(
      embedded_a == embedded_pub,
      "normalise: prefix-embedded index name folds to the public-canonical form"
    )

    check!(
      String.contains?(embedded_a, " phoenix_kit_ai_endpoints_uuid_idx "),
      "normalise: embedded schema prefix stripped from the identifier"
    )

    element_wise_check =
      "ALTER TABLE t ADD CONSTRAINT t_kind_check CHECK (((kind)::text = ANY " <>
        "(ARRAY[('a'::character varying)::text, ('b'::character varying)::text])));"

    array_wise_check =
      "ALTER TABLE t ADD CONSTRAINT t_kind_check CHECK (((kind)::text = ANY " <>
        "((ARRAY['a'::character varying, 'b'::character varying])::text[])));"

    check!(
      normalise(element_wise_check, "pk_old") == normalise(array_wise_check, "pk_old"),
      "normalise: element-wise and array-wise ANY(ARRAY[...]) casts fold to one form"
    )

    check!(
      canonicalize_array_casts(array_wise_check) == array_wise_check,
      "canonicalize_array_casts: already-canonical text passes through unchanged (idempotent)"
    )

    changed_check =
      "ALTER TABLE t ADD CONSTRAINT t_kind_check CHECK (((kind)::text = ANY " <>
        "(ARRAY[('a'::character varying)::text, ('c'::character varying)::text])));"

    check!(
      normalise(element_wise_check, "pk_old") != normalise(changed_check, "pk_old"),
      "normalise: a genuine value-set change still differs after canonicalization"
    )

    check!(
      compare(@twin_dump_a, "pk_old", @twin_dump_b, "pk_new") == :equal,
      "compare: twins are :equal"
    )

    case compare(@twin_dump_a, "pk_old", @drift_dump_b, "pk_new") do
      {:diff, text} ->
        check!(String.contains?(text, "preferred_locale"), "compare: diff names the drift")

      other ->
        check!(false, "compare: unwhitelisted drift must diff (got #{inspect(other)})")
    end

    whitelist = ["users.preferred_locale", "idx_users_preferred_locale"]

    case compare(@twin_dump_a, "pk_old", @drift_dump_b, "pk_new", legacy_optional: whitelist) do
      {:equal_modulo_whitelist, %{only_a: only_a, only_b: []}} ->
        check!(length(only_a) == 2, "compare: two tolerated entries (got #{inspect(only_a)})")

      other ->
        check!(false, "compare: whitelist must tolerate the drift (got #{inspect(other)})")
    end

    dup_side =
      "CREATE UNIQUE INDEX pk_x_phoenix_kit_t_uuid_idx ON pk_x.phoenix_kit_t USING btree (uuid);\n" <>
        "CREATE UNIQUE INDEX phoenix_kit_t_uuid_idx ON pk_x.phoenix_kit_t USING btree (uuid);"

    single_side =
      "CREATE UNIQUE INDEX phoenix_kit_t_uuid_idx ON pk_y.phoenix_kit_t USING btree (uuid);"

    check!(
      normalise(dup_side, "pk_x") == normalise(single_side, "pk_y"),
      "normalise: a prefix-embedded duplicate index folds to the single canonical form"
    )

    check!(
      match?({:diff, _}, compare(single_side, "pk_y", "", "pk_z")),
      "normalise: dedup never hides a genuinely absent object (one vs none still diffs)"
    )

    check!(
      match?(
        {:diff, _},
        compare(@twin_dump_a, "pk_old", @drift_dump_b, "pk_new",
          legacy_optional: ["other_table.preferred_locale", "idx_users_preferred_locale"]
        )
      ),
      "compare: a qualified entry for ANOTHER table must not mask the column"
    )

    check!(
      match?({:diff, _}, compare(@constraint_dump_a, "pk_old", @constraint_dump_b, "pk_new")),
      "compare: constraint/column drift diffs without whitelist"
    )

    case compare(@constraint_dump_a, "pk_old", @constraint_dump_b, "pk_new",
           legacy_optional: ["orders.total", "legacy_orders_unique"]
         ) do
      {:equal_modulo_whitelist, %{only_a: only_a, only_b: []}} ->
        check!(
          length(only_a) == 2,
          "compare: comma-typed column + ADD CONSTRAINT tolerated (got #{inspect(only_a)})"
        )

      other ->
        check!(false, "compare: constraint fixture must be tolerated (got #{inspect(other)})")
    end
  end

  defp check_seed_normalizer do
    n = normalize_seed_rows(@seed_fixture)

    check!(not String.contains?(n, "0198c111"), "seed: uuids remapped")
    check!(not String.contains?(n, "0198C111"), "seed: uppercase uuids remapped")
    check!(String.contains?(n, "<uuid-2>"), "seed: distinct uuids get distinct tokens")

    check!(
      length(String.split(n, "<uuid-1>")) == 3,
      "seed: same uuid maps to the same token across tables"
    )

    check!(String.contains?(n, "<ts>"), "seed: timestamps replaced")
    check!(not String.contains?(n, "2026-07-16"), "seed: no raw timestamps left")
  end

  defp check_unified_diff do
    check!(unified_diff("a\nb\n", "a\nb\n") == :equal, "diff: equal texts")

    case unified_diff("a\nb\n", "a\nc\n", "old", "new") do
      {:diff, text} ->
        check!(String.contains?(text, "-b") and String.contains?(text, "+c"), "diff: content")
        check!(String.contains?(text, "old") and String.contains?(text, "new"), "diff: labels")

      other ->
        check!(false, "diff: differing texts must diff (got #{inspect(other)})")
    end
  end

  defp check!(true, _name), do: :ok
  defp check!(false, name), do: raise("DumpHelper self-check failed: #{name}")

  # ---------------------------------------------------------------------------
  # Private: statement tokenizer
  # ---------------------------------------------------------------------------

  # Input exhausted — flush a trailing partial statement, if any.
  defp scan(<<>>, _state, cur, acc) do
    case String.trim(cur) do
      "" -> Enum.reverse(acc)
      stmt -> Enum.reverse([stmt | acc])
    end
  end

  defp scan(<<";", rest::binary>>, :normal, cur, acc) do
    case String.trim(cur) do
      "" -> scan(rest, :normal, <<>>, acc)
      stmt -> scan(rest, :normal, <<>>, [stmt | acc])
    end
  end

  # Top-level comments: content dropped (a newline / space survives so tokens
  # on either side never concatenate).
  defp scan(<<"--", rest::binary>>, :normal, cur, acc),
    do: scan(rest, :line_comment, cur, acc)

  defp scan(<<"/*", rest::binary>>, :normal, cur, acc),
    do: scan(rest, {:block_comment, 1}, cur, acc)

  defp scan(<<"'", rest::binary>>, :normal, cur, acc),
    do: scan(rest, :single_quote, <<cur::binary, "'">>, acc)

  defp scan(<<"\"", rest::binary>>, :normal, cur, acc),
    do: scan(rest, :double_quote, <<cur::binary, "\"">>, acc)

  defp scan(<<"$", _::binary>> = bin, :normal, cur, acc) do
    case take_dollar_tag(bin) do
      {:ok, tag, rest} ->
        scan(rest, {:dollar, tag}, <<cur::binary, tag::binary>>, acc)

      :no_tag ->
        <<c, rest::binary>> = bin
        scan(rest, :normal, <<cur::binary, c>>, acc)
    end
  end

  defp scan(<<c, rest::binary>>, :normal, cur, acc),
    do: scan(rest, :normal, <<cur::binary, c>>, acc)

  defp scan(<<"\n", rest::binary>>, :line_comment, cur, acc),
    do: scan(rest, :normal, <<cur::binary, "\n">>, acc)

  defp scan(<<_c, rest::binary>>, :line_comment, cur, acc),
    do: scan(rest, :line_comment, cur, acc)

  # Block comments nest in PostgreSQL.
  defp scan(<<"/*", rest::binary>>, {:block_comment, d}, cur, acc),
    do: scan(rest, {:block_comment, d + 1}, cur, acc)

  defp scan(<<"*/", rest::binary>>, {:block_comment, 1}, cur, acc),
    do: scan(rest, :normal, <<cur::binary, " ">>, acc)

  defp scan(<<"*/", rest::binary>>, {:block_comment, d}, cur, acc),
    do: scan(rest, {:block_comment, d - 1}, cur, acc)

  defp scan(<<_c, rest::binary>>, {:block_comment, _} = state, cur, acc),
    do: scan(rest, state, cur, acc)

  # Single-quoted string: '' is an escaped quote and stays inside.
  defp scan(<<"''", rest::binary>>, :single_quote, cur, acc),
    do: scan(rest, :single_quote, <<cur::binary, "''">>, acc)

  defp scan(<<"'", rest::binary>>, :single_quote, cur, acc),
    do: scan(rest, :normal, <<cur::binary, "'">>, acc)

  defp scan(<<c, rest::binary>>, :single_quote, cur, acc),
    do: scan(rest, :single_quote, <<cur::binary, c>>, acc)

  # Double-quoted identifier: "" is an escaped quote.
  defp scan(<<"\"\"", rest::binary>>, :double_quote, cur, acc),
    do: scan(rest, :double_quote, <<cur::binary, "\"\"">>, acc)

  defp scan(<<"\"", rest::binary>>, :double_quote, cur, acc),
    do: scan(rest, :normal, <<cur::binary, "\"">>, acc)

  defp scan(<<c, rest::binary>>, :double_quote, cur, acc),
    do: scan(rest, :double_quote, <<cur::binary, c>>, acc)

  # Dollar-quoted body: ends only at the exact same tag; everything inside
  # (semicolons, quotes, comments, other tags) is content.
  defp scan(bin, {:dollar, tag} = state, cur, acc) do
    if String.starts_with?(bin, tag) do
      rest = binary_part(bin, byte_size(tag), byte_size(bin) - byte_size(tag))
      scan(rest, :normal, <<cur::binary, tag::binary>>, acc)
    else
      <<c, rest::binary>> = bin
      scan(rest, state, <<cur::binary, c>>, acc)
    end
  end

  defp take_dollar_tag(<<"$", rest::binary>>) do
    case Regex.run(@dollar_tag_re, rest) do
      [match] ->
        tag = "$" <> match
        {:ok, tag, binary_part(rest, byte_size(match), byte_size(rest) - byte_size(match))}

      nil ->
        :no_tag
    end
  end

  # ---------------------------------------------------------------------------
  # Private: normalisation pipeline
  # ---------------------------------------------------------------------------

  defp normalised_statements(sql, schema_name) do
    sql
    |> strip_psql_meta_lines()
    |> split_statements()
    |> Enum.reject(&session_statement?/1)
    |> Enum.map(&normalise_statement(&1, schema_name))
    |> Enum.reject(&schema_create_statement?/1)
    |> Enum.sort()
    |> Enum.dedup()
  end

  # \restrict / \unrestrict / \connect lines are psql meta-commands, not SQL;
  # the restrict token is random per dump. Backslash-led lines cannot occur in
  # this project's function bodies, so a line-level strip is safe here.
  defp strip_psql_meta_lines(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(fn line -> String.starts_with?(String.trim_leading(line), "\\") end)
    |> Enum.join("\n")
  end

  defp session_statement?(stmt) do
    String.match?(stmt, ~r/\A(SET\s|SELECT pg_catalog\.set_config\()/i)
  end

  defp normalise_statement(stmt, schema_name) do
    stmt
    |> substitute_schema(schema_name)
    |> canonicalize_array_casts()
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  defp schema_create_statement?(stmt) do
    String.match?(stmt, ~r/\ACREATE SCHEMA (?:IF NOT EXISTS )?#{@schema_placeholder}\z/)
  end

  defp join_statements([]), do: ""
  defp join_statements(stmts), do: Enum.join(stmts, ";\n\n") <> ";"

  defp diff_text(text_a, text_b, label_a, label_b) do
    case unified_diff(text_a, text_b, label_a, label_b) do
      {:diff, text} -> text
      # Unreachable from compare/5 (texts differ), kept total for safety.
      :equal -> ""
    end
  end

  defp boundary_regex(name) do
    Regex.compile!("(?<![A-Za-z0-9_])" <> Regex.escape(name) <> "(?![A-Za-z0-9_])")
  end

  # ---------------------------------------------------------------------------
  # Private: whitelist filtering
  # ---------------------------------------------------------------------------

  # Returns {kept_statements, removed_lines}. See moduledoc for the rules;
  # trailing-comma stripping applies to every line on both sides whenever the
  # whitelist is active, so column-line removal stays syntactically neutral.
  defp apply_whitelist(stmts, []), do: {stmts, []}

  defp apply_whitelist(stmts, names) do
    # Entries with a dot are table-QUALIFIED column names ("table.column"):
    # they match only inside that table's CREATE TABLE statement, so a
    # same-named column in another table can never be masked. Dotless entries
    # match any declared identifier (index/constraint/sequence names are
    # schema-unique; bare column entries are accepted for back-compat but the
    # committed whitelists use the qualified form).
    {qualified, bare} = Enum.split_with(names, &String.contains?(&1, "."))
    bare_regexes = Enum.map(bare, &boundary_regex/1)

    qualified_pairs =
      Enum.map(qualified, fn entry ->
        [table, column] = String.split(entry, ".", parts: 2)
        {table, boundary_regex(column)}
      end)

    {kept, removed} =
      Enum.reduce(stmts, {[], []}, fn stmt, {kept, removed} ->
        lines = String.split(stmt, "\n")
        stmt_table = created_table(hd(lines))

        {dropped, remaining} =
          Enum.split_with(lines, fn line ->
            case declared_identifier(line) do
              nil ->
                false

              ident ->
                Enum.any?(bare_regexes, &Regex.match?(&1, ident)) or
                  Enum.any?(qualified_pairs, fn {table, re} ->
                    table == stmt_table and Regex.match?(re, ident)
                  end)
            end
          end)

        remaining = Enum.map(remaining, &strip_trailing_comma/1)

        cond do
          dropped == [] ->
            {[Enum.join(remaining, "\n") | kept], removed}

          Enum.all?(remaining, &structural_line?/1) ->
            {kept, [String.trim(stmt) | removed]}

          true ->
            {[Enum.join(remaining, "\n") | kept], Enum.map(dropped, &String.trim/1) ++ removed}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(removed)}
  end

  # The table a statement CREATEs, or nil — anchors qualified column entries.
  # Runs on normalized statements, so the schema is already `__SCHEMA__`.
  defp created_table(head_line) do
    case Regex.run(
           ~r/\ACREATE\s+TABLE\s+(?:ONLY\s+)?(?:"?[A-Za-z0-9_]+"?\.)?"?([A-Za-z0-9_]+)"?/i,
           String.trim_leading(head_line)
         ) do
      [_, table] -> table
      nil -> nil
    end
  end

  # The identifier a dump line DECLARES: the object name for single-object
  # statements (CREATE [UNIQUE] INDEX, ADD CONSTRAINT), else the first token
  # of a column-definition line. A whitelist name may only remove a line that
  # declares it; references inside other objects' definitions never match
  # (their declared identifier is the other object's name).
  defp declared_identifier(line) do
    trimmed = String.trim_leading(line)

    cond do
      m =
          Regex.run(
            ~r/\ACREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([A-Za-z0-9_]+)"?/i,
            trimmed
          ) ->
        Enum.at(m, 1)

      m = Regex.run(~r/\A(?:ADD\s+)?CONSTRAINT\s+"?([A-Za-z0-9_]+)"?/i, trimmed) ->
        Enum.at(m, 1)

      m = Regex.run(~r/\A"?([A-Za-z_][A-Za-z0-9_]*)"?[\s,]/, trimmed) ->
        Enum.at(m, 1)

      true ->
        nil
    end
  end

  defp strip_trailing_comma(line) do
    line |> String.trim_trailing() |> String.replace_suffix(",", "")
  end

  # diff(1) reports "\\ No newline at end of file" otherwise, polluting diffs.
  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  # An `ALTER TABLE [ONLY] <table>` head whose only action lines were
  # whitelist-dropped carries no semantics of its own — treat as structural
  # so the whole statement is tolerated (pg_dump wraps ADD CONSTRAINT onto a
  # continuation line under such a head).
  defp structural_line?(line) do
    trimmed = String.trim(line)
    trimmed in ["", "(", ")"] or Regex.match?(~r/\AALTER\s+TABLE\s+(?:ONLY\s+)?\S+\z/i, trimmed)
  end

  # ---------------------------------------------------------------------------
  # Private: seed dumping helpers (DB)
  # ---------------------------------------------------------------------------

  defp seed_table_section(schema, table, order_key) do
    case list_columns(schema, table) do
      {:ok, []} ->
        {:ok, "-- table: #{table} MISSING\n"}

      {:ok, cols} ->
        names = Enum.map(cols, &elem(&1, 0))
        stable = for {name, type} <- cols, type not in @volatile_types, do: name
        order = order_key || stable
        order = if order == [], do: names, else: order

        select_list = Enum.map_join(names, ", ", &quote_ident/1)
        order_list = Enum.map_join(order, ", ", &quote_ident/1)

        sql =
          "COPY (SELECT #{select_list} FROM #{quote_ident(schema)}.#{quote_ident(table)} " <>
            "ORDER BY #{order_list}) TO STDOUT WITH (FORMAT csv, HEADER, FORCE_QUOTE *)"

        case run_psql(sql) do
          {csv, 0} ->
            {:ok, "-- table: #{table}\n" <> csv}

          {out, code} ->
            {:error, "psql COPY failed for #{schema}.#{table} (exit #{code}): #{out}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Column names ordered alphabetically on purpose: physical attnum order is
  # bimodal between fresh and incrementally-upgraded installs.
  defp list_columns(schema, table) do
    sql = """
    SELECT column_name || '|' || data_type
    FROM information_schema.columns
    WHERE table_schema = '#{schema}' AND table_name = '#{table}'
    ORDER BY column_name
    """

    case run_psql(sql, ["-A", "-t"]) do
      {out, 0} ->
        cols =
          out
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [name, type] = String.split(line, "|", parts: 2)
            {name, type}
          end)

        {:ok, cols}

      {out, code} ->
        {:error, "psql column listing failed for #{schema}.#{table} (exit #{code}): #{out}"}
    end
  end

  defp run_psql(sql, extra_args \\ []) do
    ce = RepoHelper.connection_env()
    args = ["-X", "-q", "-v", "ON_ERROR_STOP=1"] ++ extra_args ++ ["-d", ce.database, "-c", sql]
    System.cmd("psql", args, env: pg_env(ce), stderr_to_stdout: true)
  end

  defp pg_env(ce) do
    [
      {"PGHOST", ce.host},
      {"PGPORT", to_string(ce.port)},
      {"PGUSER", ce.username},
      {"PGPASSWORD", ce.password},
      {"PGDATABASE", ce.database}
    ]
  end

  defp quote_ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")

  # Schema/table names are interpolated into shell args and SQL literals;
  # restrict to the same charset Helpers.validate_prefix! enforces.
  defp validate_pg_identifier!(name, kind) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      raise ArgumentError,
            "invalid #{kind} name #{inspect(name)}: must match [a-z_][a-z0-9_]*"
    end

    :ok
  end
end
