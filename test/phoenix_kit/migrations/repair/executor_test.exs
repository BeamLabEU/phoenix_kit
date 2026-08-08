defmodule PhoenixKit.Migrations.Repair.ExecutorTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.Executor
  alias PhoenixKit.Migrations.Repair.Scope
  alias PhoenixKit.Test.FixtureExpectedSchema

  @objects FixtureExpectedSchema.objects("public")
  defp find(id), do: Enum.find(@objects, &(&1.id == id))
  defp resolve(id, bound), do: Scope.resolve(find(id), bound)

  describe "create_action/2 — legacy_optional" do
    test "nil regardless of prefix — repair never creates known bimodal drift" do
      resolved = resolve("column:phoenix_kit_fixture_widgets.legacy_flag", 142)
      assert Executor.create_action(resolved, "public") == nil
    end
  end

  describe "create_action/2 — :column always rebuilds from the resolved shape" do
    test "single-revision column, exact statement text" do
      resolved = resolve("column:phoenix_kit_fixture_widgets.name", 142)

      assert Executor.create_action(resolved, "public") ==
               ~s|ALTER TABLE public.phoenix_kit_fixture_widgets ADD COLUMN IF NOT EXISTS "name" character varying(50)|
    end

    test "multi-revision column at an OLD comment version → the OLD shape's SQL, not the newest" do
      resolved = resolve("column:phoenix_kit_fixture_role_permissions.module_key", 100)

      # not_null: true but default: nil in the fixture's shape (like V53's
      # real module_key column) — NOT NULL is correctly omitted per the
      # asymmetry ShapeSql documents, not a bug in either the fixture or
      # this assertion.
      assert Executor.create_action(resolved, "public") ==
               ~s|ALTER TABLE public.phoenix_kit_fixture_role_permissions ADD COLUMN IF NOT EXISTS "module_key" character varying(50)|
    end

    test "multi-revision column at/after the newer revision → the NEW shape's SQL" do
      resolved = resolve("column:phoenix_kit_fixture_role_permissions.module_key", 142)

      assert Executor.create_action(resolved, "public") ==
               ~s|ALTER TABLE public.phoenix_kit_fixture_role_permissions ADD COLUMN IF NOT EXISTS "module_key" character varying(120)|
    end

    test "a different prefix is honored, not hardcoded to public" do
      resolved = resolve("column:phoenix_kit_fixture_widgets.name", 142)

      assert Executor.create_action(resolved, "auth") =~
               "ALTER TABLE auth.phoenix_kit_fixture_widgets"
    end
  end

  describe "create_action/2 — :index always rebuilds from the resolved shape" do
    test "exact statement text, IF NOT EXISTS inserted, name stays bare" do
      resolved = resolve("index:phoenix_kit_fixture_widgets_owner_uuid_index", 142)

      assert Executor.create_action(resolved, "public") ==
               "CREATE INDEX IF NOT EXISTS phoenix_kit_fixture_widgets_owner_uuid_index " <>
                 "ON public.phoenix_kit_fixture_widgets USING btree (owner_uuid)"
    end
  end

  describe "create_action/2 — :constraint always adds NOT VALID for foreign keys, never for anything else" do
    test "a primary key gets no NOT VALID" do
      resolved =
        resolve("constraint:phoenix_kit_fixture_widgets.phoenix_kit_fixture_widgets_pkey", 142)

      refute Executor.create_action(resolved, "public") =~ "NOT VALID"
    end

    test "a foreign key DOES get NOT VALID, even though the manifest's own object.create never would" do
      id = "constraint:phoenix_kit_fixture_widgets.phoenix_kit_fixture_widgets_owner_uuid_fkey"
      resolved = resolve(id, 142)
      object = find(id)

      action = Executor.create_action(resolved, "public")
      assert action =~ "NOT VALID"
      refute object.create =~ "NOT VALID"
    end

    test "the guard inside the rebuilt constraint SQL is still name-anchored, never a regclass cast" do
      id = "constraint:phoenix_kit_fixture_widgets.phoenix_kit_fixture_widgets_owner_uuid_fkey"
      resolved = resolve(id, 142)
      action = Executor.create_action(resolved, "public")

      refute action =~ "::regclass"
      assert action =~ "n.nspname = 'public'"
    end
  end

  describe "create_action/2 — revision-blind classes (:extension/:function/:sequence/:table/:seed) use the object's own precomputed create, unconditionally" do
    test "extension" do
      resolved = resolve("extension:citext", 142)
      object = find("extension:citext")
      assert Executor.create_action(resolved, "public") == object.create
      assert match?({:helper, _mfa}, Executor.create_action(resolved, "public"))
    end

    test "function" do
      resolved = resolve("function:uuid_generate_v7()", 142)
      object = find("function:uuid_generate_v7()")
      assert Executor.create_action(resolved, "public") == object.create
    end

    test "sequence" do
      resolved = resolve("sequence:phoenix_kit_fixture_widget_number_seq", 142)
      object = find("sequence:phoenix_kit_fixture_widget_number_seq")
      assert Executor.create_action(resolved, "public") == object.create
    end

    test "table" do
      resolved = resolve("table:phoenix_kit_fixture_widgets", 142)
      object = find("table:phoenix_kit_fixture_widgets")
      assert Executor.create_action(resolved, "public") == object.create
    end

    test "seed (:conflict_key strategy)" do
      id = "seed:phoenix_kit_fixture_owners:acme"
      resolved = resolve(id, 142)
      object = find(id)
      assert Executor.create_action(resolved, "public") == object.create
      assert Executor.create_action(resolved, "public") =~ "ON CONFLICT"
    end

    test "seed ({:helper, mfa} strategy) — the mfa is passed through untouched" do
      id = "seed:phoenix_kit_fixture_templates:__fixture_seeder__"
      resolved = resolve(id, 142)
      object = find(id)
      assert Executor.create_action(resolved, "public") == object.create
      assert {:helper, {Mix.Tasks.PhoenixKit.SeedTemplates, :run, [["--quiet"]]}} = object.create
    end
  end

  test "create_action/2 needs nothing beyond class/check/shape — matches the moduledoc's minimal doctest example" do
    resolved = %{
      object: %{
        class: :column,
        check: {:catalog, %{kind: :column, table: "widgets", column: "name"}}
      },
      shape: %{type: "text", not_null: false, default: nil}
    }

    assert Executor.create_action(resolved, "public") ==
             ~s(ALTER TABLE public.widgets ADD COLUMN IF NOT EXISTS "name" text)
  end

  doctest Executor
end
