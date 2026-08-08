defmodule PhoenixKit.Migrations.Repair.ProbeTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.FixtureExpectedSchema

  @empty_snapshot %{
    tables: %{},
    columns: %{},
    indexes: %{},
    constraints: %{},
    sequences: %{},
    functions: %{},
    extensions: %{}
  }

  @objects FixtureExpectedSchema.objects("public")

  describe "lookup/2 — dispatches per catalog kind, pure (hand-built snapshot, no DB)" do
    test "table: present" do
      snapshot = %{@empty_snapshot | tables: %{"widgets" => %{}}}
      assert Probe.lookup(snapshot, {:catalog, %{kind: :table, name: "widgets"}}) == %{}
    end

    test "table: absent → nil" do
      assert Probe.lookup(@empty_snapshot, {:catalog, %{kind: :table, name: "widgets"}}) == nil
    end

    test "extension" do
      snapshot = %{@empty_snapshot | extensions: %{"citext" => %{}}}
      assert Probe.lookup(snapshot, {:catalog, %{kind: :extension, name: "citext"}}) == %{}
      assert Probe.lookup(snapshot, {:catalog, %{kind: :extension, name: "pgcrypto"}}) == nil
    end

    test "column: keyed by {table, column}" do
      shape = %{type: "uuid", not_null: true, default: nil, pos: 1}
      snapshot = %{@empty_snapshot | columns: %{{"widgets", "uuid"} => shape}}

      assert Probe.lookup(
               snapshot,
               {:catalog, %{kind: :column, table: "widgets", column: "uuid"}}
             ) == shape

      assert Probe.lookup(
               snapshot,
               {:catalog, %{kind: :column, table: "widgets", column: "name"}}
             ) == nil

      assert Probe.lookup(snapshot, {:catalog, %{kind: :column, table: "other", column: "uuid"}}) ==
               nil
    end

    test "index: keyed by name alone (names are unique within a schema)" do
      shape = %{table: "widgets", unique: false}
      snapshot = %{@empty_snapshot | indexes: %{"widgets_owner_idx" => shape}}

      assert Probe.lookup(snapshot, {:catalog, %{kind: :index, name: "widgets_owner_idx"}}) ==
               shape
    end

    test "constraint: keyed by {table, name}" do
      shape = %{type: "p"}
      snapshot = %{@empty_snapshot | constraints: %{{"widgets", "widgets_pkey"} => shape}}

      assert Probe.lookup(
               snapshot,
               {:catalog, %{kind: :constraint, table: "widgets", name: "widgets_pkey"}}
             ) == shape
    end

    test "sequence: keyed by name" do
      shape = %{data_type: "bigint"}
      snapshot = %{@empty_snapshot | sequences: %{"widget_seq" => shape}}
      assert Probe.lookup(snapshot, {:catalog, %{kind: :sequence, name: "widget_seq"}}) == shape
    end

    test "function: keyed by {name, args}" do
      shape = %{returns: "uuid"}
      snapshot = %{@empty_snapshot | functions: %{{"uuid_generate_v7", ""} => shape}}

      assert Probe.lookup(
               snapshot,
               {:catalog, %{kind: :function, name: "uuid_generate_v7", args: ""}}
             ) == shape
    end

    test "a raw SQL string (:seed's check shape) is never a catalog lookup — always nil" do
      assert Probe.lookup(@empty_snapshot, "SELECT EXISTS (SELECT 1 FROM t WHERE k = 'v')") == nil
    end
  end

  describe "presence_by_since/2 — the marker-probe input CommentPolicy consumes" do
    test "a fully-populated snapshot: every non-seed, non-legacy_optional since-bucket reads present" do
      snapshot = full_snapshot(@objects)
      presence = Probe.presence_by_since(@objects, snapshot)

      # since 53 (uuid + module_key column, both present) must read true.
      assert {53, true} = Enum.find(presence, &(elem(&1, 0) == 53))
    end

    test "seed presence never counts against a since-bucket, even if the row is genuinely absent" do
      # since: 2 is ONLY the {:helper, mfa} seed object (best-effort, optional
      # module absent in this repo) — with no OTHER object at since 2, an
      # empty snapshot must still read this bucket as present (vacuously),
      # not absent, or a healthy DB missing only an optional seed would look
      # "behind" to the marker cross-check.
      presence = Probe.presence_by_since(@objects, @empty_snapshot)
      assert {2, true} = Enum.find(presence, &(elem(&1, 0) == 2))
    end

    test "legacy_optional absence never counts against its since-bucket either" do
      # since: 3 is ONLY phoenix_kit_fixture_widgets.legacy_flag (:legacy_optional).
      presence = Probe.presence_by_since(@objects, @empty_snapshot)
      assert {3, true} = Enum.find(presence, &(elem(&1, 0) == 3))
    end

    test "a genuinely missing REQUIRED, non-seed object marks its since-bucket absent" do
      # since: 1 has phoenix_kit_fixture_widgets (table) + .uuid/.name columns
      # (all :required) plus one :where_not_exists seed (excluded) — an
      # empty snapshot is missing the table/columns, so since 1 reads false.
      presence = Probe.presence_by_since(@objects, @empty_snapshot)
      assert {1, false} = Enum.find(presence, &(elem(&1, 0) == 1))
    end
  end

  # ── Test-only snapshot builder: marks every non-seed object's newest shape
  # as present, for the "everything is healthy" half of presence_by_since/2's
  # coverage above. ──────────────────────────────────────────────────────

  defp full_snapshot(objects) do
    base = %{
      tables: %{},
      columns: %{},
      indexes: %{},
      constraints: %{},
      sequences: %{},
      functions: %{},
      extensions: %{}
    }

    Enum.reduce(objects, base, &put_present/2)
  end

  defp put_present(%{class: :seed}, snapshot), do: snapshot

  defp put_present(%{class: :table, check: {:catalog, %{name: name}}}, snapshot) do
    put_in(snapshot, [:tables, name], %{})
  end

  defp put_present(%{class: :extension, check: {:catalog, %{name: name}}}, snapshot) do
    put_in(snapshot, [:extensions, name], %{})
  end

  defp put_present(
         %{class: :column, check: {:catalog, %{table: t, column: c}}} = object,
         snapshot
       ) do
    put_in(snapshot, [:columns, {t, c}], newest_shape(object))
  end

  defp put_present(%{class: :index, check: {:catalog, %{name: name}}} = object, snapshot) do
    put_in(snapshot, [:indexes, name], newest_shape(object))
  end

  defp put_present(
         %{class: :constraint, check: {:catalog, %{table: t, name: name}}} = object,
         snapshot
       ) do
    put_in(snapshot, [:constraints, {t, name}], newest_shape(object))
  end

  defp put_present(%{class: :sequence, check: {:catalog, %{name: name}}} = object, snapshot) do
    put_in(snapshot, [:sequences, name], newest_shape(object))
  end

  defp put_present(
         %{class: :function, check: {:catalog, %{name: name, args: args}}} = object,
         snapshot
       ) do
    put_in(snapshot, [:functions, {name, args}], newest_shape(object))
  end

  defp newest_shape(%{revisions: revisions}), do: revisions |> List.last() |> elem(1)

  doctest Probe
end
