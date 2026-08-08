defmodule PhoenixKit.Migrations.Repair.ScopeTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.Object
  alias PhoenixKit.Migrations.Repair.Scope
  alias PhoenixKit.Test.FixtureExpectedSchema

  # Real Object.t() values from the fixture — since the fixture's whole
  # point (per its own moduledoc) is to be structurally faithful to what the
  # real generator emits, testing Scope against it (rather than hand-rolled
  # ad hoc maps) exercises the actual contract boundary.
  @objects FixtureExpectedSchema.objects("public")

  defp find(id), do: Enum.find(@objects, &(&1.id == id))

  describe "partition/2" do
    test "splits by since <= bound" do
      {in_scope, pending} = Scope.partition(@objects, 53)

      assert Enum.all?(in_scope, &(&1.since <= 53))
      assert Enum.all?(pending, &(&1.since > 53))
      assert length(in_scope) + length(pending) == length(@objects)
    end

    test "bound below every since → everything pending" do
      {in_scope, _pending} = Scope.partition(@objects, 0)
      assert in_scope == []
    end

    test "bound at or above every since → nothing pending" do
      {_in_scope, pending} = Scope.partition(@objects, 142)
      assert pending == []
    end
  end

  describe "resolve/2 — single-revision objects" do
    test "before `since` → nil (not in scope yet)" do
      # phoenix_kit_fixture_role_permissions.uuid: since 53
      object = find("column:phoenix_kit_fixture_role_permissions.uuid")
      assert Scope.resolve(object, 10) == nil
    end

    test "at `since` → resolves to that object's one shape" do
      object = find("column:phoenix_kit_fixture_role_permissions.uuid")
      assert %{object: ^object, shape: shape} = Scope.resolve(object, 53)
      assert shape.type == "uuid"
    end

    test "long after `since` → still resolves (single-revision objects never change)" do
      object = find("column:phoenix_kit_fixture_role_permissions.uuid")
      assert %{shape: shape} = Scope.resolve(object, 142)
      assert shape.type == "uuid"
    end
  end

  describe "resolve/2 — multi-revision objects (spec §5.1's running example)" do
    @module_key "column:phoenix_kit_fixture_role_permissions.module_key"

    test "between since and the next revision boundary → the OLD shape, never the newest (the scope rule's whole point)" do
      object = find(@module_key)
      assert %{shape: shape} = Scope.resolve(object, 100)
      assert shape.type == "character varying(50)"
      refute shape.type == Object.newest_shape(object).type
    end

    test "exactly at the revision boundary → the NEW shape (V142 IS the revision)" do
      object = find(@module_key)
      assert %{shape: shape} = Scope.resolve(object, 142)
      assert shape.type == "character varying(120)"
    end

    test "well past the newest revision → the newest shape" do
      object = find(@module_key)
      assert %{shape: shape} = Scope.resolve(object, 200)
      assert shape.type == "character varying(120)"
      assert shape == Object.newest_shape(object)
    end

    test "before `since` entirely → nil" do
      object = find(@module_key)
      assert Scope.resolve(object, 30) == nil
    end
  end

  describe "resolve/2 — legacy_optional object" do
    test "resolves to its (only) shape once in scope — presence handling is the caller's job, not Scope's" do
      object = find("column:phoenix_kit_fixture_widgets.legacy_flag")
      assert %{shape: shape} = Scope.resolve(object, 142)
      assert shape.type == "boolean"
    end
  end

  describe "in_scope_invariants/2" do
    test "filters by since <= bound, same rule as partition/2" do
      invariants = FixtureExpectedSchema.data_invariants("public")
      in_scope = Scope.in_scope_invariants(invariants, 53)

      assert Enum.all?(in_scope, &(&1.since <= 53))
      assert Enum.any?(in_scope, &(&1.since == 5))
      refute Enum.any?(in_scope, &(&1.since == 60))
    end
  end

  describe "class_rank/1" do
    test "matches the additive-safety order exactly" do
      assert Scope.class_rank(:extension) < Scope.class_rank(:function)
      assert Scope.class_rank(:function) < Scope.class_rank(:sequence)
      assert Scope.class_rank(:sequence) < Scope.class_rank(:table)
      assert Scope.class_rank(:table) < Scope.class_rank(:column)
      assert Scope.class_rank(:column) < Scope.class_rank(:index)
      assert Scope.class_rank(:index) < Scope.class_rank(:constraint)
      assert Scope.class_rank(:constraint) < Scope.class_rank(:seed)
    end
  end

  describe "execution_order/1" do
    test "a table's column is never ordered before the table itself would be created, even if the column has an earlier since" do
      table = find("table:phoenix_kit_fixture_owners")
      # phoenix_kit_fixture_widgets.uuid: since 1, class :column
      early_column = find("column:phoenix_kit_fixture_widgets.uuid")

      resolved = [
        %{object: early_column, shape: Object.newest_shape(early_column)},
        %{object: table, shape: Object.newest_shape(table)}
      ]

      ordered = Scope.execution_order(resolved)
      assert Enum.map(ordered, & &1.object.class) == [:table, :column]
    end

    test "within the same class, orders by since then id" do
      widgets_uuid = find("column:phoenix_kit_fixture_widgets.uuid")
      widgets_name = find("column:phoenix_kit_fixture_widgets.name")

      resolved = [
        %{object: widgets_name, shape: Object.newest_shape(widgets_name)},
        %{object: widgets_uuid, shape: Object.newest_shape(widgets_uuid)}
      ]

      ordered = Scope.execution_order(resolved)
      # Both since: 1 — falls back to id ordering, which sorts ".name" before ".uuid".
      assert Enum.map(ordered, & &1.object.id) ==
               Enum.sort([
                 "column:phoenix_kit_fixture_widgets.name",
                 "column:phoenix_kit_fixture_widgets.uuid"
               ])
    end

    test "within :constraint, a same-since FK never sorts before the PK it references — even when the FK's id is alphabetically earlier" do
      # Reproduces a live regeneration failure (squash floor 135): most
      # pre-floor objects collapse to the SAME `since`, so `id` becomes the
      # deciding tiebreak — and alphabetical order has no notion of
      # dependency. `phoenix_kit_file_instances_..._fkey` sorts before
      # `phoenix_kit_files_pkey` purely because "_" < "s" in "file[_i]" vs
      # "file[s]", which is exactly backwards: creating the FK first raises
      # "no unique constraint matching given keys for referenced table".
      pk = %{class: :constraint, since: 135, id: "constraint:phoenix_kit_files_pkey"}
      pk_shape = %{type: "p"}

      fk = %{
        class: :constraint,
        since: 135,
        id: "constraint:phoenix_kit_file_instances_file_id_fkey"
      }

      fk_shape = %{type: "f"}

      # Confirm the trap: without the fix, plain id-ordering would put the
      # FK first (this assertion is the reason the fix has a third tier).
      assert fk.id < pk.id

      resolved = [
        %{object: fk, shape: fk_shape},
        %{object: pk, shape: pk_shape}
      ]

      ordered = Scope.execution_order(resolved)
      assert Enum.map(ordered, & &1.object.id) == [pk.id, fk.id]
    end

    test "a same-since FK sorts after a same-since UNIQUE constraint it depends on too" do
      unique = %{class: :constraint, since: 90, id: "constraint:aaa_first_alphabetically_key"}
      unique_shape = %{type: "u"}
      fk = %{class: :constraint, since: 90, id: "constraint:zzz_last_alphabetically_fkey"}
      fk_shape = %{type: "f"}

      resolved = [
        %{object: fk, shape: fk_shape},
        %{object: unique, shape: unique_shape}
      ]

      ordered = Scope.execution_order(resolved)
      assert Enum.map(ordered, & &1.object.id) == [unique.id, fk.id]
    end
  end

  describe "constraint_fk_rank/2" do
    test "ranks a foreign-key constraint shape above every other constraint contype" do
      assert Scope.constraint_fk_rank(:constraint, %{type: "f"}) == 1
      assert Scope.constraint_fk_rank(:constraint, %{type: "p"}) == 0
      assert Scope.constraint_fk_rank(:constraint, %{type: "u"}) == 0
      assert Scope.constraint_fk_rank(:constraint, %{type: "c"}) == 0
      assert Scope.constraint_fk_rank(:constraint, %{type: "x"}) == 0
    end

    test "is always 0 outside the :constraint class, regardless of shape" do
      assert Scope.constraint_fk_rank(:column, %{type: "f"}) == 0
      assert Scope.constraint_fk_rank(:index, %{}) == 0
    end
  end
end
