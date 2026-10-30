defmodule PhoenixKit.Integration.RealManifestShapesTest do
  @moduledoc """
  The real `ExpectedSchema` manifest against the suite's own freshly migrated
  database — the part of `dev_docs/squash/verify.exs`'s S8 ("a freshly
  installed chain must yield an empty repair plan") that `mix test` can run.

  Hand-declared manifest entries are where the manifest and the chain drift
  apart, and nothing else in the suite compares them. Two such drifts went
  unnoticed until S8 was run by hand: the V170 notification indexes carried
  their expression keys in the full definition's doubled parentheses (so every
  healthy install reported them as the wrong shape), and the settings seeds
  that V184 and V189 delete were still required (so `mix phoenix_kit.repair`
  put them back).
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  defp required(class) do
    for %{class: ^class, presence: :required} = object <- ExpectedSchema.objects("public"),
        do: object
  end

  # The shape a database at the chain head must have: the newest revision.
  defp newest_shape(%{revisions: revisions}) do
    {_version, shape} = Enum.max_by(revisions, fn {version, _} -> version end)
    shape
  end

  test "every required index exists with the shape the repair probe reads" do
    snapshot = Probe.snapshot(Repo, "public")

    problems =
      for object <- required(:index),
          problem = index_problem(object, Probe.lookup(snapshot, object.check)),
          do: {object.id, problem}

    assert problems == []
  end

  # Best-effort seeders (a Mix task the migration calls when it can) are not
  # guaranteed present by design; every other required seed is.
  test "every required seed exists after the chain has run" do
    missing =
      for object <- required(:seed),
          not Map.get(newest_shape(object), :best_effort, false),
          not Probe.seed_present?(Repo, object.check),
          do: object.id

    assert missing == []
  end

  test "a seed the chain deletes is optional and never re-created" do
    for key <- ~w(billing_default_currency shop_currency) do
      object =
        Enum.find(
          ExpectedSchema.objects("public"),
          &(&1.id == "seed:phoenix_kit_settings:#{key}")
        )

      assert %{presence: :legacy_optional, create: nil} = object
      refute Probe.seed_present?(Repo, object.check), "#{key} is deleted by the chain"
    end
  end

  # A CHECK keeps the parse tree of the SQL that created it. core's two
  # storage-profile CHECKs read `a BETWEEN .. AND ..` chains; a database whose
  # constraint was parsed with the first BETWEEN folded into the outer AND
  # prints the same condition with one pair of parentheses fewer. Repair called
  # that `wrong_shape`. The folded form is written here by hand, which gives
  # the same stored tree.
  describe "a CHECK stored with the AND chain nested another way" do
    @folded_checks %{
      "phoenix_kit_storage_profiles_copies_check" =>
        "copies_originals >= 1 AND copies_originals <= 5 AND " <>
          "(copies_variants >= 1 AND copies_variants <= 5) AND " <>
          "(min_copies_on_write >= 1 AND min_copies_on_write <= copies_originals)",
      "phoenix_kit_storage_profiles_local_cloud_check" =>
        "copies_local >= 0 AND copies_local <= 5 AND " <>
          "(copies_cloud >= 0 AND copies_cloud <= 5) AND " <>
          "copies_local + copies_cloud = copies_originals"
    }

    defp storage_check(name) do
      Enum.find(
        required(:constraint),
        &(&1.id == "constraint:phoenix_kit_storage_profiles.#{name}")
      )
    end

    defp observed_check(name) do
      snapshot = Probe.snapshot(Repo, "public")
      Probe.lookup(snapshot, storage_check(name).check)
    end

    defp restore_check_text(name, condition) do
      Repo.query!(
        "ALTER TABLE phoenix_kit_storage_profiles DROP CONSTRAINT #{name}, " <>
          "ADD CONSTRAINT #{name} CHECK (#{condition})"
      )
    end

    for {name, condition} <- @folded_checks do
      test "#{name} still matches the manifest" do
        name = unquote(name)
        object = storage_check(name)
        expected = newest_shape(object)

        # The fresh chain agrees with the manifest to begin with.
        assert Differ.compare(:constraint, expected, observed_check(name)) == :match

        restore_check_text(name, unquote(condition))
        observed = observed_check(name)

        # The scenario is real: the stored text is no longer the manifest's.
        refute observed.definition == expected.definition
        assert Differ.compare(:constraint, expected, observed) == :match
      end

      test "#{name} with another bound is a wrong shape" do
        name = unquote(name)
        object = storage_check(name)

        restore_check_text(
          name,
          String.replace(unquote(condition), "<= 5", "<= 4", global: false)
        )

        assert {:mismatch, reasons} =
                 Differ.compare(:constraint, newest_shape(object), observed_check(name))

        assert Enum.any?(reasons, &(&1 =~ "definition"))
      end
    end
  end

  defp index_problem(_object, nil), do: :missing

  defp index_problem(object, observed) do
    case Differ.compare(:index, newest_shape(object), observed) do
      :match ->
        nil

      {:mismatch, _} = mismatch ->
        # Definition text rendered by another Postgres major is not a shape
        # difference; the repair engine reports it the same way.
        if Differ.deparse_text_only?(mismatch), do: nil, else: mismatch
    end
  end
end
