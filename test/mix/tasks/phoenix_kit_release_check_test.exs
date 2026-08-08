defmodule Mix.Tasks.PhoenixKit.ReleaseCheckTest do
  # `async: false` — several tests below override
  # `:phoenix_kit, :expected_schema_module` (the same global Application env
  # key `PhoenixKit.Migrations.ExpectedSchema.ResolverTest` mutates) to drive
  # `check_manifest_chain_hash/0`'s :ok/:error branches. Same rationale as
  # that file: no upside to letting these tests interleave with each other
  # or with anything else that might resolve the manifest module.
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhoenixKit.ReleaseCheck
  alias PhoenixKit.Migrations.ExpectedSchema
  alias PhoenixKit.Migrations.ExpectedSchema.Resolver
  alias PhoenixKit.Migrations.Postgres

  setup do
    Application.delete_env(:phoenix_kit, :expected_schema_module)
    on_exit(fn -> Application.delete_env(:phoenix_kit, :expected_schema_module) end)
  end

  # A manifest stub whose `chain_hash/0` is computed FROM the same function
  # under test, so it is guaranteed to match — this exercises
  # `check_manifest_chain_hash/0`'s `{:ok, module}` + hash-equal control flow
  # (Resolver wiring, message shape) deterministically, without needing the
  # real P3-generated manifest to exist. It is not an independent oracle for
  # the hashing *algorithm* itself — that fidelity comes from
  # `compute_chain_hash/0`'s doc comment citing the exact generator source it
  # was copied from, not from this stub.
  defmodule MatchingManifestStub do
    @moduledoc false
    @behaviour PhoenixKit.Migrations.ExpectedSchema.Behaviour

    @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
    def objects(_prefix), do: []

    @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
    def data_invariants(_prefix \\ "public"), do: []

    @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
    def chain_hash, do: elem(ReleaseCheck.compute_chain_hash(), 0)
  end

  describe "floor_report/2 (pure — spec §5.3's min(vNN on disk) == initial_version)" do
    test "matches: the lowest disk version equals initial_version" do
      assert ReleaseCheck.floor_report(1, [5, 1, 3]) == {:ok, 1}
    end

    test "no files on disk at all" do
      assert ReleaseCheck.floor_report(1, []) == {:error, :no_files}
    end

    test "disk floor is LOWER than initial_version — a stray below-floor file" do
      assert ReleaseCheck.floor_report(10, [1, 10, 11]) == {:error, {:floor_mismatch, 1, 10}}
    end

    test "disk floor is HIGHER than initial_version — files were deleted without bumping it" do
      assert ReleaseCheck.floor_report(1, [5, 6, 7]) == {:error, {:floor_mismatch, 5, 1}}
    end
  end

  describe "contiguity_report/4 (pure — spec §5.3's range-completeness property)" do
    test "contiguous files, every module loadable" do
      assert ReleaseCheck.contiguity_report(1, 5, [1, 2, 3, 4, 5], fn _ -> true end) == {:ok, 5}
    end

    test "detects a missing on-disk file" do
      assert ReleaseCheck.contiguity_report(1, 5, [1, 2, 4, 5], fn _ -> true end) ==
               {:error, %{missing_files: [3], missing_modules: []}}
    end

    test "detects an unloadable module even when every file is present" do
      loadable? = fn n -> n != 3 end

      assert ReleaseCheck.contiguity_report(1, 5, [1, 2, 3, 4, 5], loadable?) ==
               {:error, %{missing_files: [], missing_modules: [3]}}
    end

    test "reports independent file-gap and module-gap versions, not just their union" do
      loadable? = fn n -> n != 2 end

      assert ReleaseCheck.contiguity_report(1, 5, [1, 3, 4, 5], loadable?) ==
               {:error, %{missing_files: [2], missing_modules: [2]}}
    end
  end

  describe "compute_chain_hash/0" do
    test "is deterministic" do
      assert ReleaseCheck.compute_chain_hash() == ReleaseCheck.compute_chain_hash()
    end

    test "returns a lowercase sha256-hex digest and the real on-disk file count" do
      {hash, count} = ReleaseCheck.compute_chain_hash()

      assert hash =~ ~r/^[0-9a-f]{64}$/
      assert count == length(Path.wildcard("lib/phoenix_kit/migrations/postgres/v*.ex"))
      assert count > 0
    end
  end

  describe "check_manifest_chain_hash/0" do
    test "SKIPs (not fails) when no manifest resolves" do
      # The real manifest IS generated on this branch (the squash promoted it
      # into lib/), so the not-generated path is reached by pointing the
      # resolver at a module that does not exist rather than by the default.
      Application.put_env(:phoenix_kit, :expected_schema_module, NoSuchManifestModule)

      assert {:skip, message} = ReleaseCheck.check_manifest_chain_hash()

      assert message ==
               Resolver.not_generated_message() <> " — chain_hash freshness check skipped."
    end

    test "the real manifest's chain_hash is fresh against the on-disk chain" do
      # Not a stub: this is the shipped manifest compared to a freshly computed
      # hash, so editing a v*.ex without regenerating fails HERE, in the
      # habitual `mix test` loop, not only in the manual release check.
      assert Code.ensure_loaded?(ExpectedSchema)

      assert ExpectedSchema.chain_hash() ==
               elem(ReleaseCheck.compute_chain_hash(), 0)
    end

    test "fails when a resolved manifest's chain_hash no longer matches a fresh computation" do
      Application.put_env(
        :phoenix_kit,
        :expected_schema_module,
        PhoenixKit.Test.FixtureExpectedSchema
      )

      assert {:fail, message} = ReleaseCheck.check_manifest_chain_hash()
      assert message =~ "chain_hash/0 is stale"
    end

    test "passes when a resolved manifest's chain_hash matches a fresh computation" do
      Application.put_env(:phoenix_kit, :expected_schema_module, MatchingManifestStub)

      assert {:pass, message} = ReleaseCheck.check_manifest_chain_hash()
      assert message =~ "chain_hash matches"
    end
  end

  describe "check_migration_sync/0 against the real, squashed chain" do
    test "passes with the floor, contiguity and a fresh chain_hash all asserted" do
      assert {:pass, detail} = ReleaseCheck.check_migration_sync()

      refute detail =~ "FAIL"
      refute detail =~ "SKIP"
      assert detail =~ "chain_hash matches"
      assert detail =~ "V#{Postgres.initial_version()}..V#{Postgres.current_version()}"
    end
  end
end
