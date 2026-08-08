defmodule PhoenixKit.Migrations.ExpectedSchema.DataInvariantTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.DataInvariant

  @invariant %{
    since: 114,
    desc: "V114: settings integration rows are uuid-keyed; no composite integration:* keys",
    assert:
      "SELECT NOT EXISTS (SELECT 1 FROM __SCHEMA__.phoenix_kit_settings WHERE key LIKE 'integration:%')"
  }

  describe "materialize/2" do
    test "substitutes the schema token in :assert only" do
      materialized = DataInvariant.materialize(@invariant, "auth")

      assert materialized.assert ==
               "SELECT NOT EXISTS (SELECT 1 FROM auth.phoenix_kit_settings WHERE key LIKE 'integration:%')"

      assert materialized.since == @invariant.since
      assert materialized.desc == @invariant.desc
    end

    test "is a no-op on an :assert with no token (defensive)" do
      untokened = %{@invariant | assert: "SELECT true"}
      assert DataInvariant.materialize(untokened, "auth").assert == "SELECT true"
    end
  end

  describe "valid?/1" do
    test "accepts a well-formed invariant" do
      assert DataInvariant.valid?(@invariant)
    end

    test "rejects a missing field" do
      refute DataInvariant.valid?(Map.delete(@invariant, :desc))
      refute DataInvariant.valid?(Map.delete(@invariant, :since))
      refute DataInvariant.valid?(Map.delete(@invariant, :assert))
    end

    test "rejects an unexpected extra field" do
      refute DataInvariant.valid?(Map.put(@invariant, :extra, true))
    end

    test "rejects a non-positive since" do
      refute DataInvariant.valid?(%{@invariant | since: 0})
      refute DataInvariant.valid?(%{@invariant | since: -5})
    end

    test "rejects a blank desc or assert" do
      refute DataInvariant.valid?(%{@invariant | desc: ""})
      refute DataInvariant.valid?(%{@invariant | assert: ""})
    end

    test "rejects non-string desc/assert" do
      refute DataInvariant.valid?(%{@invariant | desc: :not_a_string})
      refute DataInvariant.valid?(%{@invariant | assert: 123})
    end

    test "rejects a non-map" do
      refute DataInvariant.valid?(nil)
      refute DataInvariant.valid?("nope")
      refute DataInvariant.valid?([:a, :b])
    end
  end
end
