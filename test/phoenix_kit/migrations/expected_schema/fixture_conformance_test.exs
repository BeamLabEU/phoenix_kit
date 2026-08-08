defmodule PhoenixKit.Migrations.ExpectedSchema.FixtureConformanceTest do
  @moduledoc """
  Asserts `PhoenixKit.Test.FixtureExpectedSchema` actually satisfies
  `PhoenixKit.Migrations.ExpectedSchema.Behaviour` — structurally
  (`Object.valid?/1`/`DataInvariant.valid?/1` against every emitted entry,
  the closest thing to a runtime typespec assertion `ExUnit` can run) and
  semantically (the specific scope/revision/presence scenarios a repair
  engine's own unit tests will need the fixture for — see the fixture's own
  moduledoc "Coverage checklist").
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.DataInvariant
  alias PhoenixKit.Migrations.ExpectedSchema.Object
  alias PhoenixKit.Test.FixtureExpectedSchema, as: Fixture

  @all_classes Enum.sort(~w(extension function sequence table column index constraint seed)a)

  describe "@behaviour conformance" do
    test "exports the full contract at the arities Behaviour declares" do
      exported = Fixture.__info__(:functions)

      assert {:objects, 1} in exported
      assert {:data_invariants, 1} in exported
      assert {:chain_hash, 0} in exported
    end

    test "data_invariants/0 also exists (default-argument sugar, spec deviation 5)" do
      assert {:data_invariants, 0} in Fixture.__info__(:functions)
      assert Fixture.data_invariants() == Fixture.data_invariants("public")
    end
  end

  describe "objects/1 — structural conformance" do
    test "every emitted object passes Object.valid?/1" do
      for object <- Fixture.objects("public") do
        assert Object.valid?(object), "invalid object: #{inspect(object)}"
      end
    end

    test "covers every Object.class/0 value" do
      classes = Fixture.objects("public") |> Enum.map(& &1.class) |> Enum.uniq() |> Enum.sort()
      assert classes == @all_classes
    end

    test "ids are unique within the manifest" do
      ids = Fixture.objects("public") |> Enum.map(& &1.id)
      assert Enum.sort(ids) == ids |> Enum.uniq() |> Enum.sort()
    end

    test "is deterministic across calls" do
      assert Fixture.objects("public") == Fixture.objects("public")
    end
  end

  describe "objects/1 — prefix materialization" do
    test "nil prefix maps to public" do
      assert Fixture.objects(nil) == Fixture.objects("public")
    end

    test "every __SCHEMA__ token is substituted for the given prefix" do
      for object <- Fixture.objects("auth") do
        create_and_check = for v <- [object.create, object.check], is_binary(v), do: v
        shape_strings = Enum.flat_map(object.revisions, fn {_v, shape} -> Map.values(shape) end)

        for value <- create_and_check ++ shape_strings, is_binary(value) do
          refute String.contains?(value, "__SCHEMA__"), "leftover token in #{object.id}: #{value}"
        end
      end
    end

    test "rejects a prefix that cannot be safely interpolated into SQL" do
      assert_raise ArgumentError, fn -> Fixture.objects("Bad-Prefix") end
    end
  end

  describe "presence and legacy_optional" do
    test "at least one legacy_optional object is present, and its create is nil" do
      legacy = Fixture.objects("public") |> Enum.filter(&(&1.presence == :legacy_optional))

      assert legacy != []
      assert Enum.all?(legacy, &(&1.create == nil))
    end

    test "every legacy_optional object still carries a well-formed check (verify still probes it)" do
      legacy = Fixture.objects("public") |> Enum.filter(&(&1.presence == :legacy_optional))

      assert Enum.all?(legacy, fn object ->
               match?({:catalog, _}, object.check) or is_binary(object.check)
             end)
    end
  end

  describe "multi-revision objects" do
    test "module_key widens from VARCHAR(50)@53 to VARCHAR(120)@142" do
      object =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id == "column:phoenix_kit_fixture_role_permissions.module_key")
        )

      refute is_nil(object)
      assert length(object.revisions) == 2
      assert object.since == 53

      assert Object.shape_at(object, 100).type == "character varying(50)"
      assert Object.shape_at(object, 142).type == "character varying(120)"
      assert Object.shape_at(object, 52) == nil
      assert Object.newest_shape(object).type == "character varying(120)"
    end
  end

  describe "seed strategies" do
    test "covers :conflict_key, :where_not_exists, :admin_role_select, and {:helper, mfa}" do
      creates =
        Fixture.objects("public") |> Enum.filter(&(&1.class == :seed)) |> Enum.map(& &1.create)

      assert Enum.any?(
               creates,
               &(is_binary(&1) and String.contains?(&1, ~s|ON CONFLICT ("slug") DO NOTHING|))
             )

      assert Enum.any?(creates, &(is_binary(&1) and String.contains?(&1, "WHERE NOT EXISTS")))

      assert Enum.any?(
               creates,
               &(is_binary(&1) and
                   String.contains?(&1, "FROM public.phoenix_kit_fixture_owners o"))
             )

      assert Enum.any?(creates, &match?({:helper, _}, &1))
    end

    test "the helper-seeded row references its MFA without requiring the module to exist" do
      seed =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id == "seed:phoenix_kit_fixture_templates:__fixture_seeder__")
        )

      assert {:helper, {Mix.Tasks.PhoenixKit.SeedTemplates, :run, [["--quiet"]]}} = seed.create
      assert Object.valid?(seed)

      # Documents the expected case this create strategy exists for (v15/v31
      # lineage): the module genuinely does not exist in this repository. If
      # a future change adds it back, this line — not `Object.valid?/1` —
      # is what needs revisiting.
      refute Code.ensure_loaded?(Mix.Tasks.PhoenixKit.SeedTemplates)
    end
  end

  describe "foreign key decoding" do
    test "widgets.owner_uuid FK carries ON DELETE SET NULL, ON UPDATE NO ACTION" do
      fk =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id ==
              "constraint:phoenix_kit_fixture_widgets.phoenix_kit_fixture_widgets_owner_uuid_fkey")
        )

      shape = Object.newest_shape(fk)

      assert shape.type == "f"
      assert shape.foreign_table == "phoenix_kit_fixture_owners"
      assert shape.foreign_columns == ["uuid"]
      assert shape.on_delete == "n"
      assert shape.on_update == "a"
    end
  end

  describe "NOT NULL / DEFAULT asymmetry (Object moduledoc)" do
    test "a NOT NULL column with no default is created WITHOUT NOT NULL" do
      column =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id == "column:phoenix_kit_fixture_widgets.name")
        )

      assert Object.newest_shape(column).not_null == true
      assert is_binary(column.create)
      refute String.contains?(column.create, "NOT NULL")
      assert column.backfill == nil
    end

    test "a NOT NULL column WITH a default is created with NOT NULL and flagged for backfill" do
      column =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id == "column:phoenix_kit_fixture_widgets.uuid")
        )

      assert String.contains?(column.create, "NOT NULL")
      assert column.backfill == :default
    end
  end

  describe "sequence-before-column ordering" do
    test "the sequence backing widgets.number's default is its own manifest object" do
      sequence =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id == "sequence:phoenix_kit_fixture_widget_number_seq")
        )

      column =
        Enum.find(
          Fixture.objects("public"),
          &(&1.id == "column:phoenix_kit_fixture_widgets.number")
        )

      refute is_nil(sequence)
      assert column.create =~ "nextval('public.phoenix_kit_fixture_widget_number_seq'::regclass)"
    end
  end

  describe "data_invariants/1" do
    test "every emitted invariant passes DataInvariant.valid?/1" do
      for invariant <- Fixture.data_invariants("public") do
        assert DataInvariant.valid?(invariant), "invalid invariant: #{inspect(invariant)}"
      end
    end

    test "returns at least the spec-minimum 2-3 invariants, spanning different `since` versions" do
      invariants = Fixture.data_invariants("public")

      assert length(invariants) >= 2
      assert invariants |> Enum.map(& &1.since) |> Enum.uniq() |> length() >= 2
    end

    test "substitutes the prefix in every :assert" do
      for invariant <- Fixture.data_invariants("auth") do
        assert String.contains?(invariant.assert, "auth.")
        refute String.contains?(invariant.assert, "__SCHEMA__")
      end
    end
  end

  describe "chain_hash/0" do
    test "is a 64-char lowercase-hex string (the sha256-hex shape)" do
      assert Fixture.chain_hash() =~ ~r/^[0-9a-f]{64}$/
    end

    test "is stable across calls" do
      assert Fixture.chain_hash() == Fixture.chain_hash()
    end
  end
end
