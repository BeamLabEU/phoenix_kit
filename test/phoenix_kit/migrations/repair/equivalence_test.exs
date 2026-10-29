defmodule PhoenixKit.Migrations.Repair.EquivalenceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.Equivalence
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Migrations.Repair.Scope
  alias PhoenixKit.Test.FixtureExpectedSchema

  @widgets "phoenix_kit_fixture_widgets"
  @owners "phoenix_kit_fixture_owners"

  @objects FixtureExpectedSchema.objects("public")
  @claimed Equivalence.claimed_names(@objects)

  @empty_snapshot %{
    tables: %{},
    columns: %{},
    indexes: %{},
    constraint_backed_indexes: %{},
    constraints: %{},
    sequences: %{},
    functions: %{},
    extensions: %{}
  }

  defp object(id), do: Enum.find(@objects, &(&1.id == id)) || flunk("no fixture object #{id}")
  defp shape(object, bound \\ 142), do: Scope.resolve(object, bound).shape

  defp find(snapshot, id, claimed \\ @claimed) do
    object = object(id)
    Equivalence.find(snapshot, object, shape(object), claimed)
  end

  defp snapshot(parts), do: Map.merge(@empty_snapshot, Map.new(parts))

  # The fixture's `widgets_owner_uuid_index`: a plain btree on owner_uuid.
  defp index(attrs \\ []) do
    Map.merge(
      %{
        table: @widgets,
        unique: false,
        method: "btree",
        definition: "",
        predicate: nil,
        keys: ["owner_uuid"],
        opclasses: ["uuid_ops"]
      },
      Map.new(attrs)
    )
  end

  defp key(type, columns) do
    %{
      type: type,
      definition: "",
      columns: columns,
      foreign_table: nil,
      foreign_columns: nil,
      on_delete: nil,
      on_update: nil
    }
  end

  # The fixture's `widgets_owner_uuid_fkey`: owner_uuid -> owners(uuid), ON DELETE SET NULL.
  defp fk(attrs \\ []) do
    Map.merge(
      %{
        type: "f",
        definition: "",
        columns: ["owner_uuid"],
        foreign_table: @owners,
        foreign_columns: ["uuid"],
        on_delete: "n",
        on_update: "a"
      },
      Map.new(attrs)
    )
  end

  @index_id "index:phoenix_kit_fixture_widgets_owner_uuid_index"
  @fk_id "constraint:#{@widgets}.phoenix_kit_fixture_widgets_owner_uuid_fkey"
  @slug_id "constraint:#{@owners}.phoenix_kit_fixture_owners_slug_key"
  @owners_pkey_id "constraint:#{@owners}.phoenix_kit_fixture_owners_pkey"

  describe "an index under another name" do
    test "with the declared structure is the twin" do
      snapshot = snapshot(indexes: %{"legacy_owner_idx" => index()})
      assert find(snapshot, @index_id) == {:index, "legacy_owner_idx"}
    end

    test "when several qualify, the first by name wins (more than 32 candidates, so map order is not name order)" do
      indexes =
        for n <- 39..0//-1, into: %{}, do: {"idx_#{String.pad_leading("#{n}", 2, "0")}", index()}

      assert find(snapshot(indexes: indexes), @index_id) == {:index, "idx_00"}
    end

    test "that is unique when a plain one is declared is not a twin" do
      assert find(snapshot(indexes: %{"legacy" => index(unique: true)}), @index_id) == nil
    end

    test "with a predicate the declaration does not have is not a twin" do
      partial = index(predicate: "(owner_uuid IS NOT NULL)")
      assert find(snapshot(indexes: %{"legacy" => partial}), @index_id) == nil
    end

    test "on other columns, another method or other operator classes is not a twin" do
      for other <- [
            index(keys: ["name"]),
            index(keys: ["owner_uuid", "name"]),
            index(method: "hash"),
            index(opclasses: ["uuid_minmax_ops"])
          ] do
        assert find(snapshot(indexes: %{"legacy" => other}), @index_id) == nil
      end
    end

    test "on another table is not a twin" do
      assert find(snapshot(indexes: %{"legacy" => index(table: @owners)}), @index_id) == nil
    end

    test "that the manifest names itself is never a twin" do
      # `phoenix_kit_fixture_owners_name_idx` is declared by the fixture; here it
      # sits on the widgets table with the declared structure. Its own name is
      # how its own presence is judged, so it cannot stand in for the missing one.
      snapshot = snapshot(indexes: %{"phoenix_kit_fixture_owners_name_idx" => index()})
      assert find(snapshot, @index_id) == nil
    end

    test "that is the declared index itself is not its own twin" do
      declared = "phoenix_kit_fixture_widgets_owner_uuid_index"
      assert find(snapshot(indexes: %{declared => index()}), @index_id) == nil
    end

    test "an index backed by a constraint is not looked at" do
      snapshot = snapshot(constraint_backed_indexes: %{"legacy" => index()})
      assert find(snapshot, @index_id) == nil
    end
  end

  describe "a primary key or unique constraint under another name" do
    test "a unique constraint on the declared columns is the twin" do
      snapshot = snapshot(constraints: %{{@owners, "legacy_slug_key"} => key("u", ["slug"])})
      assert find(snapshot, @slug_id) == {:constraint, "legacy_slug_key"}
    end

    test "a primary key on the declared columns is the twin" do
      snapshot = snapshot(constraints: %{{@owners, "legacy_pkey"} => key("p", ["uuid"])})
      assert find(snapshot, @owners_pkey_id) == {:constraint, "legacy_pkey"}
    end

    test "another type, other columns or another table is not a twin" do
      for {table, observed} <- [
            {@owners, key("u", ["uuid"])},
            {@owners, key("p", ["slug"])},
            {@owners, key("p", ["uuid", "slug"])},
            {@widgets, key("p", ["uuid"])}
          ] do
        assert find(snapshot(constraints: %{{table, "legacy"} => observed}), @owners_pkey_id) ==
                 nil
      end
    end

    test "a constraint the manifest names itself is never a twin" do
      # Two declared unique constraints with one structure cannot stand in for each other.
      clone =
        update_in(object(@slug_id), [:check], &rename_check(&1, "phoenix_kit_declared_clone"))

      claimed = Equivalence.claimed_names([clone | @objects])

      snapshot =
        snapshot(constraints: %{{@owners, "phoenix_kit_declared_clone"} => key("u", ["slug"])})

      assert Equivalence.find(snapshot, object(@slug_id), shape(object(@slug_id)), claimed) == nil
    end
  end

  describe "a foreign key under another name" do
    test "with the declared columns, referenced table and columns and actions is the twin" do
      snapshot = snapshot(constraints: %{{@widgets, "legacy_owner_fk"} => fk()})
      assert find(snapshot, @fk_id) == {:constraint, "legacy_owner_fk"}
    end

    test "that differs in any of them is not a twin" do
      for other <- [
            fk(columns: ["name"]),
            fk(foreign_table: @widgets),
            fk(foreign_columns: ["slug"]),
            fk(on_delete: "c"),
            fk(on_update: "c")
          ] do
        assert find(snapshot(constraints: %{{@widgets, "legacy"} => other}), @fk_id) == nil
      end
    end
  end

  describe "what is never looked for" do
    test "a CHECK constraint" do
      object = %{
        class: :constraint,
        check: {:catalog, %{kind: :constraint, table: @widgets, name: "declared_check"}}
      }

      expected = %{type: "c", definition: "CHECK ((x > 0))"}

      snapshot =
        snapshot(
          constraints: %{
            {@widgets, "legacy_check"} => %{type: "c", definition: "CHECK ((x > 0))"}
          }
        )

      assert Equivalence.find(snapshot, object, expected, @claimed) == nil
    end

    test "a column, a table, a sequence or a seed" do
      for class <- [:column, :table, :sequence, :seed] do
        object = Enum.find(@objects, &(&1.class == class)) || flunk("no #{class} in the fixture")

        assert Equivalence.find(@empty_snapshot, object, %{}, @claimed) == nil
      end
    end
  end

  describe "assign/4 — one object answers for at most one declared object" do
    defp resolved(id, bound \\ 142), do: Scope.resolve(object(id), bound)

    defp clone_of_index(name) do
      declared = object(@index_id)
      {:catalog, spec} = declared.check
      %{declared | id: "index:#{name}", check: {:catalog, %{spec | name: name}}}
    end

    test "a single twin goes to the first declared object only" do
      second = clone_of_index("phoenix_kit_fixture_widgets_owner_uuid_second_index")
      claimed = Equivalence.claimed_names([second | @objects])
      resolved = [resolved(@index_id), Scope.resolve(second, 142)]

      twins = Equivalence.assign(snapshot(indexes: %{"legacy" => index()}), resolved, claimed)

      assert twins == %{@index_id => {:index, "legacy"}}
    end

    test "two twins serve two declared objects, one each" do
      second = clone_of_index("phoenix_kit_fixture_widgets_owner_uuid_second_index")
      claimed = Equivalence.claimed_names([second | @objects])
      resolved = [resolved(@index_id), Scope.resolve(second, 142)]
      snapshot = snapshot(indexes: %{"a_legacy" => index(), "b_legacy" => index()})

      twins = Equivalence.assign(snapshot, resolved, claimed)

      assert twins[@index_id] == {:index, "a_legacy"}

      assert twins["index:phoenix_kit_fixture_widgets_owner_uuid_second_index"] ==
               {:index, "b_legacy"}
    end

    test "an object present under its own name gets no twin and takes none" do
      declared = "phoenix_kit_fixture_widgets_owner_uuid_index"
      snapshot = snapshot(indexes: %{declared => index(), "legacy" => index()})

      assert Equivalence.assign(snapshot, [resolved(@index_id)], @claimed) == %{}
    end
  end

  describe "a predicate printed differently" do
    test "is not a twin: a re-printed predicate cannot be told from a different one" do
      object = object(@index_id)
      expected = Map.put(shape(object), :predicate, "(owner_uuid IS NOT NULL)")

      for printed <- ["owner_uuid IS NOT NULL", "(name IS NOT NULL)"] do
        snapshot = snapshot(indexes: %{"legacy" => index(predicate: printed)})
        assert Equivalence.find(snapshot, object, expected, @claimed) == nil
      end
    end
  end

  describe "with_twins_as_present/5" do
    test "lists a twin under the declared name and leaves the rest alone" do
      snapshot = snapshot(indexes: %{"legacy" => index()})
      index_object = object(@index_id)

      assert Probe.lookup(snapshot, index_object.check) == nil

      result = Equivalence.with_twins_as_present(snapshot, @objects, @claimed, 142)

      assert Probe.lookup(result, index_object.check) == index()

      assert Map.keys(result.indexes) |> Enum.sort() == [
               "legacy",
               "phoenix_kit_fixture_widgets_owner_uuid_index"
             ]
    end

    test "does the same for a key constraint" do
      snapshot = snapshot(constraints: %{{@widgets, "legacy_owner_fk"} => fk()})
      result = Equivalence.with_twins_as_present(snapshot, @objects, @claimed, 142)

      assert Probe.lookup(result, object(@fk_id).check) == fk()
    end

    test "does nothing for an object that is not in scope at the bound" do
      snapshot = snapshot(indexes: %{"legacy" => index()})
      # the fixture's index is `since: 5`
      result = Equivalence.with_twins_as_present(snapshot, @objects, @claimed, 4)

      assert result == snapshot
    end

    test "does nothing when there is no twin" do
      snapshot = snapshot(indexes: %{"legacy" => index(unique: true)})
      assert Equivalence.with_twins_as_present(snapshot, @objects, @claimed, 142) == snapshot
    end

    test "does nothing for an object that is present under its own name" do
      declared = "phoenix_kit_fixture_widgets_owner_uuid_index"
      snapshot = snapshot(indexes: %{declared => index(), "legacy" => index()})

      assert Equivalence.with_twins_as_present(snapshot, @objects, @claimed, 142) == snapshot
    end
  end

  defp rename_check({:catalog, spec}, name), do: {:catalog, %{spec | name: name}}
end
