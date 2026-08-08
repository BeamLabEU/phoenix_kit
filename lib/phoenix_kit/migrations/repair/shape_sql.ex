defmodule PhoenixKit.Migrations.Repair.ShapeSql do
  @moduledoc """
  Rebuilds a `CREATE`/structural-probe SQL statement from an
  `PhoenixKit.Migrations.ExpectedSchema.Object.shape_at/2` result, for the
  classes where the manifest's own precomputed `object.create`/`object.check`
  (always the **newest** revision — see `Object`'s moduledoc) is the wrong
  thing to execute against an intermediate comment version.

  ## Why only `:column`/`:index`/`:constraint`

  The frozen P1 generator (`PhoenixKit.Squash.Generate.Emitter.object_create/2`,
  `dev_docs/squash/generate_baseline.exs`) itself only ever revision-scopes
  these three classes — `:extension`/`:function`/`:sequence`/`:table`/`:seed`
  creates are built from `newest_shape/1` **unconditionally**, even inside the
  generator's own `render_baseline/4` (which slices `since <= floor` and
  rebuilds from `shape_at/2` for those three classes but not the other five).
  That is a deliberate property of the ground truth, not an oversight to
  "fix" here:

    * `:table` creates are always the same empty-shell `CREATE TABLE ... ()`
      regardless of revision (every column is its own separate `:column`
      object — spec §5.1's "every surviving column is its own object").
    * `:extension`/`:function` creates are idempotent, additive,
      revision-blind operations (`ensure_extension!/2`,
      `ensure_uuid_v7_function/2`, or a `CREATE OR REPLACE FUNCTION`) —
      there is no "old shape" a later delta depends on the *absence* of.
    * `:sequence` creates are a one-time declaration; nothing in the chain
      alters a sequence's own increment/min/max/cache/cycle after creation.
    * `:seed` rebuild would need the emission **strategy**
      (`:conflict_key`/`:where_not_exists`/`:admin_role_select`/helper) —
      information the generator deliberately does not carry into the final
      `Object.t()` (it is folded into the precomputed `create` string at
      generation time, per table, not per revision). No real seed object in
      the current manifest actually needs revision-scoped values (the
      generator's baseline seed policy is always `DO NOTHING`/
      `WHERE NOT EXISTS`, never an upgrade-era `DO UPDATE` — spec §8.2/S2),
      so this is a documented, deliberate gap rather than a silent one: if a
      future manifest ever ships a genuinely multi-revision `:seed` object,
      `PhoenixKit.Migrations.Repair.Scope` falls back to the newest-shape
      `create`/`check` for it, exactly like it does for the other four
      revision-blind classes.

  Every function takes an already-materialized `prefix` (a real schema name,
  never the `"__SCHEMA__"` token) — by the time
  `PhoenixKit.Migrations.Repair` has an `Object.t()` in hand, it came from
  `manifest.objects(prefix)`, which already substituted every revision's
  shape (`Object.materialize/2` walks `:revisions` too, not just the
  top-level `:create`/`:check`).

  Idioms mirrored exactly from `PhoenixKit.Squash.Generate.Emitter`
  (CLAUDE.md's prefix-safety rules): bare index names on `CREATE`, a
  name-anchored `pg_constraint` JOIN guard for constraints (never a
  `regclass` cast — the V146 25P02 trap), `ADD COLUMN IF NOT EXISTS`.
  """

  @doc """
  `ALTER TABLE <prefix>.<table> ADD COLUMN IF NOT EXISTS "<column>" <type>
  [DEFAULT <default>] [NOT NULL]` — mirrors `Emitter.column_def/3`'s call
  site inside `object_create/2`'s `:column` clause exactly, including the
  NOT-NULL-only-with-a-DEFAULT asymmetry (adding a `NOT NULL` column with no
  default to a populated table fails outright, so a repair-created column is
  never given one without a value to fall back on).

      iex> ShapeSql.column_create("public", "phoenix_kit_widgets", "name",
      ...>   %{type: "character varying(50)", not_null: true, default: nil})
      ~s|ALTER TABLE public.phoenix_kit_widgets ADD COLUMN IF NOT EXISTS "name" character varying(50)|

      iex> ShapeSql.column_create("public", "phoenix_kit_widgets", "uuid",
      ...>   %{type: "uuid", not_null: true, default: "public.uuid_generate_v7()"})
      ~s|ALTER TABLE public.phoenix_kit_widgets ADD COLUMN IF NOT EXISTS "uuid" uuid DEFAULT public.uuid_generate_v7() NOT NULL|
  """
  @spec column_create(String.t(), String.t(), String.t(), map()) :: String.t()
  def column_create(prefix, table, column, %{type: type, not_null: not_null, default: default}) do
    not_null_safe? = not_null and not is_nil(default)

    ~s(ALTER TABLE #{prefix}.#{table} ADD COLUMN IF NOT EXISTS "#{column}" #{type}) <>
      if(default, do: " DEFAULT #{default}", else: "") <>
      if(not_null_safe?, do: " NOT NULL", else: "")
  end

  @doc """
  Inserts `IF NOT EXISTS` into a captured `pg_get_indexdef` definition —
  mirrors `Emitter.index_create_sql/1` exactly (index **names** stay bare on
  `CREATE`; only `DROP INDEX` ever takes a schema-qualified name).

      iex> ShapeSql.index_create(%{definition: "CREATE INDEX my_idx ON public.widgets USING btree (owner_uuid)"})
      "CREATE INDEX IF NOT EXISTS my_idx ON public.widgets USING btree (owner_uuid)"
  """
  @spec index_create(%{definition: String.t()}) :: String.t()
  def index_create(%{definition: definition}) do
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
        raise ArgumentError,
              "unexpected index definition (no CREATE [UNIQUE] INDEX prefix): #{definition}"
    end
  end

  @doc """
  Name-anchored, guarded `ADD CONSTRAINT` — mirrors
  `Emitter.guarded_constraint_sql/3` exactly: a `pg_constraint` JOIN keyed on
  `conname` + `t.relname` + `n.nspname`, never a `'<table>'::regclass` cast
  (CLAUDE.md's documented 25P02 trap for immediate checks — this guard is
  evaluated inside a queued `DO $$` block via `execute/1` in migration
  context, but `PhoenixKit.Migrations.Repair.Executor` runs it as an
  immediate statement too; the guard itself never casts a name to
  `regclass`, so it stays safe either way).

  `opts[:not_valid]` appends ` NOT VALID` — spec §6.3's rule for foreign keys
  specifically (`Executor` passes this for `shape.type == "f"`, followed by a
  separate `VALIDATE CONSTRAINT` statement; V113 is the in-chain precedent
  for the two-step). Never set for any other constraint type — a `NOT VALID`
  primary key or unique constraint is not valid Postgres syntax.

      iex> ShapeSql.constraint_create("public", "phoenix_kit_widgets", "phoenix_kit_widgets_pkey",
      ...>   %{definition: "PRIMARY KEY (uuid)"})
      ...> |> String.contains?("ADD CONSTRAINT phoenix_kit_widgets_pkey PRIMARY KEY (uuid);")
      true
  """
  @spec constraint_create(
          String.t(),
          String.t(),
          String.t(),
          %{definition: String.t()},
          keyword()
        ) ::
          String.t()
  def constraint_create(prefix, table, name, shape, opts \\ [])

  def constraint_create(prefix, table, name, %{definition: definition}, opts) do
    suffix = if Keyword.get(opts, :not_valid, false), do: " NOT VALID", else: ""

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
          AND n.nspname = '#{prefix}'
      ) THEN
        ALTER TABLE #{prefix}.#{table} ADD CONSTRAINT #{name} #{definition}#{suffix};
      END IF;
    END
    $$
    """
  end

  @doc """
  `ALTER TABLE <prefix>.<table> VALIDATE CONSTRAINT <name>` — the second half
  of the `NOT VALID` two-step (V113 precedent: cheap on a live table, only
  scans rows written after the `ADD`, not the whole table).

      iex> ShapeSql.validate_constraint("public", "phoenix_kit_widgets", "phoenix_kit_widgets_owner_uuid_fkey")
      "ALTER TABLE public.phoenix_kit_widgets VALIDATE CONSTRAINT phoenix_kit_widgets_owner_uuid_fkey"
  """
  @spec validate_constraint(String.t(), String.t(), String.t()) :: String.t()
  def validate_constraint(prefix, table, name) do
    "ALTER TABLE #{prefix}.#{table} VALIDATE CONSTRAINT #{name}"
  end
end
