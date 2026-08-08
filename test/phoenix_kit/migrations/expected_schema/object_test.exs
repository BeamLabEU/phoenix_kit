defmodule PhoenixKit.Migrations.ExpectedSchema.ObjectTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.Object

  # role_permissions.module_key: the exact multi-revision example named
  # throughout the spec (VARCHAR(50)@53 -> VARCHAR(120)@142).
  @multi_revision %{
    id: "column:phoenix_kit_fixture_role_permissions.module_key",
    class: :column,
    since: 53,
    revisions: [
      {53, %{type: "character varying(50)", not_null: true, default: nil, pos: 2}},
      {142, %{type: "character varying(120)", not_null: true, default: nil, pos: 2}}
    ],
    presence: :required,
    check:
      {:catalog,
       %{kind: :column, table: "phoenix_kit_fixture_role_permissions", column: "module_key"}},
    create:
      "ALTER TABLE __SCHEMA__.phoenix_kit_fixture_role_permissions " <>
        "ADD COLUMN IF NOT EXISTS \"module_key\" character varying(120)",
    backfill: nil
  }

  describe "normalize_prefix/1" do
    test "nil normalizes to \"public\"" do
      assert Object.normalize_prefix(nil) == "public"
    end

    test "a valid prefix passes through unchanged" do
      assert Object.normalize_prefix("auth") == "auth"
    end

    test "rejects a prefix that cannot be safely interpolated into SQL" do
      assert_raise ArgumentError, fn -> Object.normalize_prefix("Bad-Prefix") end
    end
  end

  describe "schema_token/0" do
    test "is the literal __SCHEMA__ placeholder" do
      assert Object.schema_token() == "__SCHEMA__"
    end
  end

  describe "materialize/2" do
    test "substitutes the token in :create and :check string fields" do
      object = %{
        id: "table:phoenix_kit_fixture_widgets",
        class: :table,
        since: 1,
        revisions: [{1, %{}}],
        presence: :required,
        check: "SELECT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_fixture_widgets)",
        create: "CREATE TABLE IF NOT EXISTS __SCHEMA__.phoenix_kit_fixture_widgets ()",
        backfill: nil
      }

      materialized = Object.materialize(object, "auth")

      assert materialized.create ==
               "CREATE TABLE IF NOT EXISTS auth.phoenix_kit_fixture_widgets ()"

      assert materialized.check ==
               "SELECT EXISTS (SELECT 1 FROM auth.phoenix_kit_fixture_widgets)"
    end

    test "a {:catalog, spec} check with no tokens in its values is unchanged" do
      object = %{
        id: "table:phoenix_kit_fixture_widgets",
        class: :table,
        since: 1,
        revisions: [{1, %{}}],
        presence: :required,
        check: {:catalog, %{kind: :table, name: "phoenix_kit_fixture_widgets"}},
        create: "CREATE TABLE IF NOT EXISTS __SCHEMA__.phoenix_kit_fixture_widgets ()",
        backfill: nil
      }

      materialized = Object.materialize(object, "auth")

      assert materialized.check ==
               {:catalog, %{kind: :table, name: "phoenix_kit_fixture_widgets"}}
    end

    test "resolves a prefix-embedded-name marker inside a {:catalog, spec} check's :name" do
      exempt_object = %{
        id: "index:phoenix_kit_fixture_settings_uuid_idx",
        class: :index,
        since: 5,
        revisions: [{5, %{}}],
        presence: :required,
        check:
          {:catalog,
           %{
             kind: :index,
             name: Object.name_marker(:exempt) <> "phoenix_kit_fixture_settings_uuid_idx",
             table: "phoenix_kit_fixture_settings"
           }},
        create: nil,
        backfill: nil
      }

      # `:exempt` (v56.ex/v61.ex's prefix_index_name/2 convention) — bare on
      # public, prefixed otherwise.
      {:catalog, public_spec} = Object.materialize(exempt_object, "public").check
      assert public_spec.name == "phoenix_kit_fixture_settings_uuid_idx"

      {:catalog, named_spec} = Object.materialize(exempt_object, "auth").check
      assert named_spec.name == "auth_phoenix_kit_fixture_settings_uuid_idx"

      always_object =
        put_in(exempt_object, [:check], {
          :catalog,
          %{
            kind: :index,
            name: Object.name_marker(:always) <> "phoenix_kit_fixture_files_checksum_index",
            table: "phoenix_kit_fixture_files"
          }
        })

      # `:always` (v26.ex's convention) — prefixed unconditionally, public included.
      {:catalog, public_always_spec} = Object.materialize(always_object, "public").check
      assert public_always_spec.name == "public_phoenix_kit_fixture_files_checksum_index"

      {:catalog, named_always_spec} = Object.materialize(always_object, "auth").check
      assert named_always_spec.name == "auth_phoenix_kit_fixture_files_checksum_index"
    end

    test "substitutes the :prefix sentinel inside a helper create's args, leaving other atoms alone" do
      object = %{
        id: "function:uuid_generate_v7()",
        class: :function,
        since: 1,
        revisions: [
          {1, %{returns: "uuid", language: "plpgsql", body_md5: "x", definition: "..."}}
        ],
        presence: :required,
        check: {:catalog, %{kind: :function, name: "uuid_generate_v7", args: ""}},
        create:
          {:helper,
           {PhoenixKit.Migrations.Postgres.Helpers, :ensure_uuid_v7_function,
            [:prefix, :untouched]}},
        backfill: nil
      }

      materialized = Object.materialize(object, "auth")

      assert materialized.create ==
               {:helper,
                {PhoenixKit.Migrations.Postgres.Helpers, :ensure_uuid_v7_function,
                 ["auth", :untouched]}}
    end

    test "leaves a nil create alone (legacy_optional objects)" do
      object = %{
        id: "column:phoenix_kit_fixture_widgets.legacy_flag",
        class: :column,
        since: 3,
        revisions: [{3, %{type: "boolean", not_null: false, default: nil, pos: 5}}],
        presence: :legacy_optional,
        check:
          {:catalog,
           %{kind: :column, table: "phoenix_kit_fixture_widgets", column: "legacy_flag"}},
        create: nil,
        backfill: nil
      }

      assert Object.materialize(object, "auth").create == nil
    end

    test "substitutes the token inside revision shape string and list values, leaving other types alone" do
      object = %{
        id: "index:phoenix_kit_fixture_widgets_owner_uuid_index",
        class: :index,
        since: 5,
        revisions: [
          {5,
           %{
             table: "phoenix_kit_fixture_widgets",
             unique: false,
             method: "btree",
             definition:
               "CREATE INDEX phoenix_kit_fixture_widgets_owner_uuid_index ON " <>
                 "__SCHEMA__.phoenix_kit_fixture_widgets USING btree (owner_uuid)",
             predicate: nil,
             keys: ["owner_uuid"],
             opclasses: ["uuid_ops"]
           }}
        ],
        presence: :required,
        check:
          {:catalog,
           %{
             kind: :index,
             name: "phoenix_kit_fixture_widgets_owner_uuid_index",
             table: "phoenix_kit_fixture_widgets"
           }},
        create:
          "CREATE INDEX IF NOT EXISTS phoenix_kit_fixture_widgets_owner_uuid_index ON " <>
            "__SCHEMA__.phoenix_kit_fixture_widgets USING btree (owner_uuid)",
        backfill: nil
      }

      materialized = Object.materialize(object, "auth")
      {5, shape} = List.first(materialized.revisions)

      assert shape.definition =~ "auth.phoenix_kit_fixture_widgets"
      refute shape.definition =~ "__SCHEMA__"
      assert shape.predicate == nil
      assert shape.unique == false
      assert shape.keys == ["owner_uuid"]
    end
  end

  describe "shape_at/2" do
    test "selects the newest revision with as_of_version <= the given version" do
      assert Object.shape_at(@multi_revision, 53).type == "character varying(50)"
      assert Object.shape_at(@multi_revision, 100).type == "character varying(50)"
      assert Object.shape_at(@multi_revision, 141).type == "character varying(50)"
      assert Object.shape_at(@multi_revision, 142).type == "character varying(120)"
      assert Object.shape_at(@multi_revision, 151).type == "character varying(120)"
    end

    test "returns nil when the object does not exist yet at that version" do
      assert Object.shape_at(@multi_revision, 52) == nil
      assert Object.shape_at(@multi_revision, 1) == nil
    end
  end

  describe "newest_shape/1" do
    test "returns the final revision regardless of the caller's DB version" do
      assert Object.newest_shape(@multi_revision).type == "character varying(120)"
    end

    test "matches shape_at/2 for a single-revision object" do
      single = %{@multi_revision | revisions: [{53, %{type: "character varying(50)"}}]}
      assert Object.newest_shape(single) == Object.shape_at(single, 53)
    end
  end

  describe "valid?/1" do
    test "accepts a well-formed single-revision required object" do
      assert Object.valid?(%{
               id: "extension:citext",
               class: :extension,
               since: 1,
               revisions: [{1, %{}}],
               presence: :required,
               check: {:catalog, %{kind: :extension, name: "citext"}},
               create:
                 {:helper,
                  {PhoenixKit.Migrations.Postgres.Helpers, :ensure_extension!, ["citext"]}},
               backfill: nil
             })
    end

    test "accepts the multi-revision fixture object" do
      assert Object.valid?(@multi_revision)
    end

    test "rejects a non-map" do
      refute Object.valid?("not an object")
      refute Object.valid?(nil)
      refute Object.valid?([:a, :b])
    end

    test "rejects a missing field" do
      refute Object.valid?(Map.delete(@multi_revision, :backfill))
    end

    test "rejects an unexpected extra field" do
      refute Object.valid?(Map.put(@multi_revision, :extra, "nope"))
    end

    test "rejects an unknown class (no :oban, no :comment)" do
      refute Object.valid?(%{@multi_revision | class: :oban})
      refute Object.valid?(%{@multi_revision | class: :comment})
    end

    test "rejects since <= 0" do
      refute Object.valid?(%{@multi_revision | since: 0})
      refute Object.valid?(%{@multi_revision | since: -1})
    end

    test "rejects revisions not starting at since" do
      refute Object.valid?(%{@multi_revision | since: 1})
    end

    test "rejects revisions out of ascending order" do
      out_of_order = %{@multi_revision | since: 142, revisions: [{142, %{}}, {53, %{}}]}
      refute Object.valid?(out_of_order)
    end

    test "rejects duplicate revision versions" do
      dup = %{@multi_revision | since: 53, revisions: [{53, %{}}, {53, %{}}]}
      refute Object.valid?(dup)
    end

    test "rejects legacy_optional with a non-nil create (the load-bearing pairing)" do
      refute Object.valid?(%{@multi_revision | presence: :legacy_optional})
    end

    test "accepts legacy_optional with create: nil" do
      assert Object.valid?(%{@multi_revision | presence: :legacy_optional, create: nil})
    end

    test "rejects an unrecognized check shape" do
      refute Object.valid?(%{@multi_revision | check: :bogus})
      refute Object.valid?(%{@multi_revision | check: {:catalog, "not a map"}})
    end

    test "rejects an unrecognized backfill value" do
      refute Object.valid?(%{@multi_revision | backfill: :manual})
    end
  end
end
