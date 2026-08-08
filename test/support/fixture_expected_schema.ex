defmodule PhoenixKit.Test.FixtureExpectedSchema do
  @moduledoc """
  A small, hand-written, semantically-rich implementation of
  `PhoenixKit.Migrations.ExpectedSchema.Behaviour` — test-only infrastructure
  (compiled under `test/support`, never part of the built library) standing
  in for the real tool-generated `PhoenixKit.Migrations.ExpectedSchema`
  manifest, which does not exist yet (it lands with the squash PR, P3, once a
  scratch database is available). Every P2 test that needs to exercise
  scope/revision/presence logic without a database points
  `PhoenixKit.Migrations.ExpectedSchema.Resolver` at this module:

      Application.put_env(:phoenix_kit, :expected_schema_module, PhoenixKit.Test.FixtureExpectedSchema)

  The table/column/index/constraint names below all live under a
  `phoenix_kit_fixture_*` prefix and never collide with a real PhoenixKit
  table — this is a self-contained toy schema, not a slice of the real chain.
  Shapes and SQL text are hand-computed to be what
  `PhoenixKit.Squash.Generate.Emitter` (the real, frozen P1 generator) would
  emit for equivalent inputs, using the same idioms (bare index names on
  CREATE, name-anchored `pg_constraint` JOIN guards — never a `regclass`
  cast, `ADD COLUMN IF NOT EXISTS` per-column healing, the `"__SCHEMA__"`
  token). It does not re-derive that dispatch generically — see the module
  docs for `PhoenixKit.Migrations.ExpectedSchema.Object` for why a
  duck-typed-map contract like this one does not warrant reimplementing
  ~200 lines of the generator's own per-class SQL-building machinery inside
  a 25-object test fixture.

  ## Coverage checklist

    * every `class()` — extension, function, sequence, table, column, index,
      constraint, seed (all 8);
    * a multi-revision object — `phoenix_kit_fixture_role_permissions.module_key`
      widens `VARCHAR(50)@53` → `VARCHAR(120)@142`, the exact style called out
      in spec §5.1;
    * a `:legacy_optional` object — `phoenix_kit_fixture_widgets.legacy_flag`
      (`create: nil`, mirroring `users.preferred_locale`'s spec §3.7 bimodal
      drift);
    * all four real `@seed_strategies` shapes, one each:
      `phoenix_kit_fixture_owners` (`:conflict_key`, the common case —
      settings/roles/currencies-style `ON CONFLICT ... DO NOTHING`),
      `phoenix_kit_fixture_widgets` (`:where_not_exists`, mirrors V20's
      bucket seed — no unique constraint to hang a conflict target off),
      `phoenix_kit_fixture_role_permissions` (`:admin_role_select`, mirrors
      V53/V55 — conditional on a lookup row existing), and
      `phoenix_kit_fixture_templates` (`{:helper, mfa}`, mirrors the v15/v31
      best-effort email-template seeder lineage — the referenced module is
      genuinely absent in this repository today, exactly like production);
    * a foreign key with `on_delete`/`on_update` decoding
      (`phoenix_kit_fixture_widgets_owner_uuid_fkey`, `ON DELETE SET NULL`);
    * a sequence-backed column default
      (`phoenix_kit_fixture_widgets.number` / `phoenix_kit_fixture_widget_number_seq`),
      exercising the "sequences before tables" class-ordering concern (spec
      §5.1);
    * the `NOT NULL`-without-`DEFAULT` asymmetry
      (`phoenix_kit_fixture_widgets.name`: `not_null: true`, `default: nil` →
      `create` deliberately omits `NOT NULL` — see `Object`'s moduledoc);
    * 3 data invariants, one per real-world flavor (uniqueness, composite-key
      absence, rename-cleanup).

  `since` values span `1..142` so tests can pick a DB "comment" that lands
  before/at/between/after every revision boundary above.
  """

  @behaviour PhoenixKit.Migrations.ExpectedSchema.Behaviour

  alias PhoenixKit.Migrations.ExpectedSchema.DataInvariant
  alias PhoenixKit.Migrations.ExpectedSchema.Object
  alias PhoenixKit.Migrations.Postgres.Helpers

  @widgets "phoenix_kit_fixture_widgets"
  @owners "phoenix_kit_fixture_owners"
  @role_permissions "phoenix_kit_fixture_role_permissions"
  @templates "phoenix_kit_fixture_templates"

  # 64 lowercase hex chars — the sha256-hex *shape* `chain_hash/0` promises,
  # deliberately not a real hash of anything (there is no fixed `v*.ex` set
  # this fixture corresponds to). Mirrors the real generator's own
  # `PhoenixKit.Squash.Generate.Fixture.@meta.chain_hash`.
  @chain_hash String.duplicate("ab", 32)

  @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
  def objects(prefix) do
    prefix = Object.normalize_prefix(prefix)
    Enum.map(raw_objects(), &Object.materialize(&1, prefix))
  end

  @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
  def data_invariants(prefix \\ "public") do
    prefix = Object.normalize_prefix(prefix)
    Enum.map(raw_data_invariants(), &DataInvariant.materialize(&1, prefix))
  end

  @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
  def chain_hash, do: @chain_hash

  # ---------------------------------------------------------------------------
  # Raw (pre-materialize) objects
  # ---------------------------------------------------------------------------

  defp raw_objects do
    [
      extension_object("citext", 1),
      uuid_function_object(1),
      widget_number_sequence_object(),
      table_object(@widgets, 1),
      table_object(@owners, 5),
      table_object(@role_permissions, 53),
      column_object(@widgets, "uuid", 1,
        type: "uuid",
        not_null: true,
        default: "__SCHEMA__.uuid_generate_v7()",
        pos: 1
      ),
      # not_null: true but default: nil — `create` must NOT emit NOT NULL
      # (adding a NOT NULL column with no default to a populated table would
      # fail); this is the asymmetry documented on `Object`.
      column_object(@widgets, "name", 1, type: "character varying(50)", not_null: true, pos: 2),
      column_object(@widgets, "legacy_flag", 3,
        type: "boolean",
        pos: 5,
        presence: :legacy_optional
      ),
      column_object(@widgets, "owner_uuid", 5, type: "uuid", pos: 6),
      column_object(@widgets, "number", 5,
        type: "bigint",
        not_null: true,
        default: "nextval('__SCHEMA__.#{sequence_name()}'::regclass)",
        pos: 7
      ),
      column_object(@owners, "uuid", 5,
        type: "uuid",
        not_null: true,
        default: "__SCHEMA__.uuid_generate_v7()",
        pos: 1
      ),
      column_object(@owners, "slug", 5, type: "character varying(80)", not_null: true, pos: 2),
      column_object(@owners, "name", 5, type: "character varying(120)", pos: 3),
      column_object(@role_permissions, "uuid", 53,
        type: "uuid",
        not_null: true,
        default: "__SCHEMA__.uuid_generate_v7()",
        pos: 1
      ),
      multi_revision_column_object(@role_permissions, "module_key", [
        {53, column_shape("character varying(50)", not_null: true, pos: 2)},
        {142, column_shape("character varying(120)", not_null: true, pos: 2)}
      ]),
      widgets_owner_uuid_index_object(),
      owners_prefix_embedded_index_object(),
      constraint_object(
        @widgets,
        "phoenix_kit_fixture_widgets_pkey",
        1,
        "p",
        "PRIMARY KEY (uuid)",
        columns: ["uuid"]
      ),
      constraint_object(@owners, "phoenix_kit_fixture_owners_pkey", 5, "p", "PRIMARY KEY (uuid)",
        columns: ["uuid"]
      ),
      constraint_object(@owners, "phoenix_kit_fixture_owners_slug_key", 5, "u", "UNIQUE (slug)",
        columns: ["slug"]
      ),
      constraint_object(
        @widgets,
        "phoenix_kit_fixture_widgets_owner_uuid_fkey",
        5,
        "f",
        "FOREIGN KEY (owner_uuid) REFERENCES __SCHEMA__.#{@owners}(uuid) ON DELETE SET NULL",
        columns: ["owner_uuid"],
        foreign_table: @owners,
        foreign_columns: ["uuid"],
        on_delete: "n",
        on_update: "a"
      ),
      constraint_object(
        @role_permissions,
        "phoenix_kit_fixture_role_permissions_pkey",
        53,
        "p",
        "PRIMARY KEY (uuid)",
        columns: ["uuid"]
      ),
      owners_seed_object(),
      widgets_default_seed_object(),
      role_permissions_seed_object(),
      templates_helper_seed_object()
    ]
  end

  defp raw_data_invariants do
    [
      %{
        since: 5,
        desc:
          "fixture: owners.slug unique among non-NULL values (mirrors V137's aws_message_id check)",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.#{@owners} " <>
            "WHERE slug IS NOT NULL GROUP BY slug HAVING COUNT(*) > 1)"
      },
      %{
        since: 53,
        desc:
          "fixture: role_permissions.module_key never carries the pre-widen composite form " <>
            "(mirrors V114's integration-key rewrite check)",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.#{@role_permissions} WHERE module_key LIKE '%:%')"
      },
      %{
        since: 60,
        desc:
          "fixture: legacy 'legacy_'-prefixed owner slugs were renamed away " <>
            "(mirrors V77/V109's settings-key rename checks)",
        assert:
          "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.#{@owners} WHERE slug LIKE 'legacy_%')"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Object builders — one per class, small and non-generic on purpose (see
  # moduledoc). Each mirrors the corresponding `Emitter.object_create/2`
  # clause's logic, not just its output.
  # ---------------------------------------------------------------------------

  defp extension_object(name, since) do
    %{
      id: "extension:#{name}",
      class: :extension,
      since: since,
      revisions: [{since, %{}}],
      presence: :required,
      check: {:catalog, %{kind: :extension, name: name}},
      create: {:helper, {Helpers, :ensure_extension!, [name]}},
      backfill: nil
    }
  end

  # `create` below is the REAL helper (`Helpers.ensure_uuid_v7_function/2`,
  # not fixture-authored SQL) — unlike every other object in this file, its
  # observed shape after `build_objects/1` is whatever that helper actually
  # creates, not something this fixture controls. `body_md5`/`definition`
  # below are therefore the *real* values (captured against a scratch DB via
  # `md5(prosrc)`/`pg_get_functiondef`, 2026-08), not hand-invented
  # placeholders — a toy body here would make every test that builds this
  # object and then expects a clean verify permanently see a `:wrong_shape`
  # finding it can never satisfy. Only `body_md5` (with `returns`/
  # `language`) is actually compared (`Differ.compare/3` deliberately
  # excludes `definition` — see its moduledoc), and `body_md5` is a hash of
  # `prosrc` alone, which does not embed the calling prefix — it is stable
  # across prefixes, but embeds `pgcrypto_schema/1`'s resolved schema
  # (`Helpers`), which falls back to `"public"` whenever pgcrypto is not
  # already installed under a different schema. If this ever starts failing
  # because pgcrypto lives elsewhere in a given scratch DB, recompute via
  # `SELECT md5(prosrc) FROM pg_proc WHERE proname = 'uuid_generate_v7'`
  # after calling the real helper.
  defp uuid_function_object(since) do
    definition = """
    CREATE OR REPLACE FUNCTION __SCHEMA__.uuid_generate_v7()
     RETURNS uuid
     LANGUAGE plpgsql
    AS $function$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      -- Get current timestamp in milliseconds
      unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);

      -- Build UUIDv7: 6 bytes timestamp + 2 bytes random (with version) + 8 bytes random (with variant)
      uuid_bytes := unix_ts_ms || public.gen_random_bytes(10);

      -- Set version 7 (0111xxxx in byte 7)
      uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);

      -- Set variant (10xxxxxx in byte 9)
      uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);

      RETURN encode(uuid_bytes, 'hex')::uuid;
    END
    $function$
    """

    %{
      id: "function:uuid_generate_v7()",
      class: :function,
      since: since,
      revisions: [
        {since,
         %{
           returns: "uuid",
           language: "plpgsql",
           body_md5: "01ffea8ed8743df8517604290f53cd34",
           definition: definition
         }}
      ],
      presence: :required,
      check: {:catalog, %{kind: :function, name: "uuid_generate_v7", args: ""}},
      create: {:helper, {Helpers, :ensure_uuid_v7_function, [:prefix]}},
      backfill: nil
    }
  end

  defp sequence_name, do: "phoenix_kit_fixture_widget_number_seq"

  defp widget_number_sequence_object do
    name = sequence_name()

    shape = %{
      data_type: "bigint",
      start: 1,
      increment: 1,
      min: 1,
      max: 9_223_372_036_854_775_807,
      cache: 1,
      cycle: false
    }

    create =
      "CREATE SEQUENCE IF NOT EXISTS __SCHEMA__.#{name} AS bigint " <>
        "INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 START WITH 1 CACHE 1"

    %{
      id: "sequence:#{name}",
      class: :sequence,
      since: 5,
      revisions: [{5, shape}],
      presence: :required,
      check: {:catalog, %{kind: :sequence, name: name}},
      create: create,
      backfill: nil
    }
  end

  defp table_object(table, since) do
    %{
      id: "table:#{table}",
      class: :table,
      since: since,
      revisions: [{since, %{}}],
      presence: :required,
      check: {:catalog, %{kind: :table, name: table}},
      create: "CREATE TABLE IF NOT EXISTS __SCHEMA__.#{table} ()",
      backfill: nil
    }
  end

  # Columns are their own manifest objects (spec §5.1: "every surviving column
  # is its own :column object... keeps repair fully additive and
  # revision-scoped") — CREATE TABLE only ever produces an empty shell.
  defp column_object(table, column, since, opts) do
    presence = Keyword.get(opts, :presence, :required)
    shape = column_shape(Keyword.fetch!(opts, :type), opts)

    %{
      id: "column:#{table}.#{column}",
      class: :column,
      since: since,
      revisions: [{since, shape}],
      presence: presence,
      check: {:catalog, %{kind: :column, table: table, column: column}},
      create:
        if(presence == :legacy_optional, do: nil, else: column_create(table, column, shape)),
      backfill: column_backfill(shape)
    }
  end

  defp multi_revision_column_object(table, column, revisions) do
    {since, _shape} = List.first(revisions)
    newest = revisions |> List.last() |> elem(1)

    %{
      id: "column:#{table}.#{column}",
      class: :column,
      since: since,
      revisions: revisions,
      presence: :required,
      check: {:catalog, %{kind: :column, table: table, column: column}},
      create: column_create(table, column, newest),
      backfill: column_backfill(newest)
    }
  end

  defp column_shape(type, opts) do
    %{
      type: type,
      not_null: Keyword.get(opts, :not_null, false),
      default: Keyword.get(opts, :default),
      pos: Keyword.fetch!(opts, :pos)
    }
  end

  # Mirrors `Emitter.object_create/2`'s :column clause exactly: NOT NULL is
  # only ever emitted when a DEFAULT accompanies it, regardless of the
  # target shape's own `not_null` — repair can only safely add a NOT NULL
  # column when it can immediately satisfy the constraint on existing rows.
  defp column_create(table, column, %{type: type, not_null: not_null, default: default}) do
    not_null_safe? = not_null and not is_nil(default)

    "ALTER TABLE __SCHEMA__.#{table} ADD COLUMN IF NOT EXISTS \"#{column}\" #{type}" <>
      if(default, do: " DEFAULT #{default}", else: "") <>
      if(not_null_safe?, do: " NOT NULL", else: "")
  end

  defp column_backfill(%{not_null: not_null, default: default}) do
    if not_null and not is_nil(default), do: :default, else: nil
  end

  defp widgets_owner_uuid_index_object do
    name = "phoenix_kit_fixture_widgets_owner_uuid_index"
    definition = "CREATE INDEX #{name} ON __SCHEMA__.#{@widgets} USING btree (owner_uuid)"

    %{
      id: "index:#{name}",
      class: :index,
      since: 5,
      revisions: [
        {5,
         %{
           table: @widgets,
           unique: false,
           method: "btree",
           definition: definition,
           predicate: nil,
           keys: ["owner_uuid"],
           opclasses: ["uuid_ops"]
         }}
      ],
      presence: :required,
      check: {:catalog, %{kind: :index, name: name, table: @widgets}},
      create: index_create_sql(definition),
      backfill: nil
    }
  end

  # Prefix-embedded-name regression coverage (spec: stepwise-vs-single-shot
  # shape bimodality, V56.ex:574-576's/V61.ex's `prefix_index_name/2`
  # idiom — bare on `public`/`nil`, `"#{prefix}_"` otherwise). Mirrors what
  # `PhoenixKit.Squash.Generate.Catalog`'s capture-time canonicalization
  # produces: keyed by the bare suffix, the marker baked into
  # `definition`/`check.name` in place of the (already-stripped)
  # scratch-schema prefix — `Object.materialize/2` resolves it exactly like
  # `Emitter`'s baked-in-generated-source copy does.
  #
  # Deliberately NON-unique, on `name` (not `uuid`): a first-DB-contact
  # defect surfaced when this was a UNIQUE index on `@owners`'s `uuid`
  # column, which already carries a `PRIMARY KEY (uuid)` — a second unique
  # index over the identical column gave Postgres's own FK-resolution logic
  # (`phoenix_kit_fixture_widgets_owner_uuid_fkey REFERENCES owners(uuid)`)
  # two equally-valid candidate supporting indexes, and it silently bound
  # the constraint to THIS one instead of the pkey — a real DB artifact of
  # the fixture's own choice of column, nothing to do with the templating
  # mechanism under test. `name` has no competing constraint, so it cannot
  # recur here.
  defp owners_prefix_embedded_index_object do
    bare = "phoenix_kit_fixture_owners_name_idx"
    marker = Object.name_marker(:exempt)

    definition =
      "CREATE INDEX #{marker}#{bare} ON __SCHEMA__.#{@owners} USING btree (name)"

    %{
      id: "index:#{bare}",
      class: :index,
      since: 5,
      revisions: [
        {5,
         %{
           table: @owners,
           unique: false,
           method: "btree",
           definition: definition,
           predicate: nil,
           keys: ["name"],
           opclasses: ["text_ops"]
         }}
      ],
      presence: :required,
      check: {:catalog, %{kind: :index, name: "#{marker}#{bare}", table: @owners}},
      create: index_create_sql(definition),
      backfill: nil
    }
  end

  # Mirrors `Emitter.index_create_sql/1`: the index NAME stays bare on
  # CREATE (schema qualification is only valid on DROP INDEX).
  defp index_create_sql(definition) do
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

  defp constraint_object(table, name, since, type, definition, extra) do
    shape = %{
      type: type,
      definition: definition,
      columns: Keyword.get(extra, :columns),
      foreign_table: Keyword.get(extra, :foreign_table),
      foreign_columns: Keyword.get(extra, :foreign_columns),
      on_delete: Keyword.get(extra, :on_delete),
      on_update: Keyword.get(extra, :on_update)
    }

    %{
      id: "constraint:#{table}.#{name}",
      class: :constraint,
      since: since,
      revisions: [{since, shape}],
      presence: :required,
      check: {:catalog, %{kind: :constraint, table: table, name: name}},
      create: guarded_constraint_sql(table, name, definition),
      backfill: nil
    }
  end

  # Mirrors `Emitter.guarded_constraint_sql/3`: name-based `pg_constraint`
  # JOIN anchored on `nspname` — never a `regclass` cast (CLAUDE.md/V146).
  defp guarded_constraint_sql(table, name, definition) do
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
    $$
    """
  end

  # :conflict_key strategy — the common case (settings/roles/currencies/...).
  # Column order mirrors `Emitter.seed_cols_and_vals/4`: key column first,
  # then the remaining captured columns sorted alphabetically.
  defp owners_seed_object do
    key_value = "acme"

    create =
      ~s|INSERT INTO __SCHEMA__.#{@owners} ("slug", "name")\n| <>
        "VALUES ('acme', 'Acme Supply Co.')\n" <>
        "ON CONFLICT (\"slug\") DO NOTHING"

    %{
      id: "seed:#{@owners}:#{key_value}",
      class: :seed,
      since: 5,
      revisions: [
        {5,
         %{
           key_column: "slug",
           key_value: key_value,
           values: %{"slug" => key_value, "name" => "Acme Supply Co."}
         }}
      ],
      presence: :required,
      check: "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.#{@owners} WHERE \"slug\" = 'acme')",
      create: create,
      backfill: nil
    }
  end

  # :where_not_exists strategy — mirrors V20's bucket seed: no unique
  # constraint on `name` to hang an ON CONFLICT target off.
  defp widgets_default_seed_object do
    key_value = "__default_widget__"

    create =
      ~s|INSERT INTO __SCHEMA__.#{@widgets} ("name", "number")\n| <>
        "SELECT '#{key_value}', 0\n" <>
        "WHERE NOT EXISTS (\n" <>
        "  SELECT 1 FROM __SCHEMA__.#{@widgets} WHERE \"name\" = '#{key_value}'\n" <>
        ")"

    %{
      id: "seed:#{@widgets}:#{key_value}",
      class: :seed,
      since: 1,
      revisions: [
        {1,
         %{
           key_column: "name",
           key_value: key_value,
           values: %{"name" => key_value, "number" => 0}
         }}
      ],
      presence: :required,
      check:
        "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.#{@widgets} WHERE \"name\" = '#{key_value}')",
      create: create,
      backfill: nil
    }
  end

  # :admin_role_select strategy — mirrors V53/V55: conditional on a lookup
  # row existing, identity resolved by a business key at execution time.
  defp role_permissions_seed_object do
    key_value = "widgets.manage"

    create =
      "INSERT INTO __SCHEMA__.#{@role_permissions} (\"module_key\")\n" <>
        "SELECT '#{key_value}'\n" <>
        "FROM __SCHEMA__.#{@owners} o\n" <>
        "WHERE o.slug = 'acme'\n" <>
        "ON CONFLICT DO NOTHING"

    %{
      id: "seed:#{@role_permissions}:#{key_value}",
      class: :seed,
      since: 53,
      revisions: [
        {53,
         %{key_column: "module_key", key_value: key_value, values: %{"module_key" => key_value}}}
      ],
      presence: :required,
      check:
        "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.#{@role_permissions} WHERE \"module_key\" = '#{key_value}')",
      create: create,
      backfill: nil
    }
  end

  # {:helper, mfa} strategy — mirrors the v15/v31 best-effort email-template
  # seeder lineage. `Mix.Tasks.PhoenixKit.SeedTemplates` genuinely does not
  # exist in this repository today (it was referenced by v15.ex/generate_baseline.exs
  # long before either committed the module itself) — that is the expected
  # "optional module absent" case this create strategy exists for, not a
  # mistake in this fixture. See `Object`'s moduledoc, "Helper creates".
  defp templates_helper_seed_object do
    %{
      id: "seed:#{@templates}:__fixture_seeder__",
      class: :seed,
      since: 2,
      revisions: [{2, %{best_effort: true, source: "fixture"}}],
      presence: :required,
      check: "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.#{@templates})",
      create: {:helper, {Mix.Tasks.PhoenixKit.SeedTemplates, :run, [["--quiet"]]}},
      backfill: nil
    }
  end
end
