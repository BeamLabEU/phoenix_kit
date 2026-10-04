defmodule PhoenixKit.ObanSchemaTest do
  @moduledoc """
  The pure half of keeping a host's Oban schema in step with its Oban
  library: what a catalog answer means, which prefixes are checked, the
  migration the updater writes, and the doctor's verdict. The database half —
  a real schema at v13 failing a unique insert, and the generated migration
  fixing it — is `PhoenixKit.Integration.ObanSchemaUpgradeTest`.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor
  alias PhoenixKit.ObanSchema

  doctest PhoenixKit.ObanSchema

  describe "classify/2 — the version is the COMMENT on oban_jobs" do
    test "a comment equal to the library's version is current" do
      assert ObanSchema.classify({:comment, "14"}, 14) == {:current, 14}
    end

    test "an older version is behind, naming both versions" do
      assert ObanSchema.classify({:comment, "13"}, 14) == {:behind, 13, 14}
      assert ObanSchema.classify({:comment, "9"}, 14) == {:behind, 9, 14}
    end

    test "a newer version is ahead, never behind" do
      assert ObanSchema.classify({:comment, "15"}, 14) == {:ahead, 15, 14}
    end

    test "no table is its own answer, not version 0" do
      # Oban's migrated_version/1 folds a missing table and a missing comment
      # into 0; "migrate from 0" over tables that exist is the guess this
      # module refuses to make, so the two must stay apart.
      assert ObanSchema.classify(:no_table, 14) == :no_table
      assert ObanSchema.classify({:comment, nil}, 14) == {:unversioned, nil}
    end

    test "a comment that is not a positive integer is unversioned" do
      for comment <- ["", "0", "∞", "v13", "13 rows", "-1"] do
        assert ObanSchema.classify({:comment, comment}, 14) == {:unversioned, comment},
               "expected #{inspect(comment)} to be unversioned"
      end
    end

    test "surrounding whitespace in the comment is tolerated" do
      assert ObanSchema.classify({:comment, " 13\n"}, 14) == {:behind, 13, 14}
    end
  end

  describe "check/2 — the adapter is asked, not assumed" do
    defmodule SQLiteRepo do
      def __adapter__, do: Ecto.Adapters.SQLite3
    end

    defmodule BrokenRepo do
      def __adapter__, do: Ecto.Adapters.Postgres
      def query!(_sql, _params, _opts), do: raise(DBConnection.ConnectionError, "closed")
    end

    test "a repo that is not Postgres is reported and never queried" do
      assert ObanSchema.check(SQLiteRepo, "public") ==
               {:unsupported_adapter, Ecto.Adapters.SQLite3}
    end

    test "an unreachable database is an error value, never a raise" do
      assert {:error, message} = ObanSchema.check(BrokenRepo, "public")
      assert message =~ "closed"
    end
  end

  describe "prefixes/2" do
    test "core's prefix always comes first" do
      assert ObanSchema.prefixes("auth", prefix: "jobs") == ["auth", "jobs"]
    end

    test "an Oban config without prefix runs at public, Oban's default" do
      assert ObanSchema.prefixes("auth", queues: [default: 10]) == ["auth", "public"]
      assert ObanSchema.prefixes("public", queues: [default: 10]) == ["public"]
    end

    test "a config that is not a keyword list, or a non-string prefix, adds nothing" do
      assert ObanSchema.prefixes("auth", nil) == ["auth"]
      assert ObanSchema.prefixes("auth", %{prefix: "x"}) == ["auth"]
      assert ObanSchema.prefixes("auth", prefix: false) == ["auth"]
    end
  end

  describe "migration_source/4" do
    setup do
      source = ObanSchema.migration_source("MyApp", "auth", 13, 14)
      %{source: source, ast: Code.string_to_quoted!(source)}
    end

    test "is valid Elixir defining a host migration module", %{ast: ast, source: source} do
      assert {:defmodule, _, [{:__aliases__, _, parts}, _]} = ast
      assert parts == [:MyApp, :Repo, :Migrations, :PhoenixKitUpdateObanAuthV13ToV14]
      assert source =~ "use Ecto.Migration"
    end

    test "up steps to the library's version at the prefix, never creating the schema",
         %{source: source} do
      assert source =~
               ~s|Oban.Migration.up(version: 14, prefix: "auth", create_schema: false)|
    end

    test "down reverts exactly the versions up added", %{source: source} do
      # Oban.Migration.down/1 reverts every version down to AND INCLUDING the
      # one it is given — so `from + 1` lands back on `from`.
      assert source =~ ~s|Oban.Migration.down(version: 14, prefix: "auth")|

      multi = ObanSchema.migration_source("MyApp", "public", 11, 14)
      assert multi =~ ~s|Oban.Migration.up(version: 14, prefix: "public", create_schema: false)|
      assert multi =~ ~s|Oban.Migration.down(version: 12, prefix: "public")|
    end

    test "the module name follows the prefix, so two prefixes never collide" do
      public = ObanSchema.migration_source("MyApp", "public", 13, 14)
      assert public =~ "defmodule MyApp.Repo.Migrations.PhoenixKitUpdateObanV13ToV14 do"

      assert ObanSchema.migration_suffix("public", 13, 14) !=
               ObanSchema.migration_suffix("auth", 13, 14)
    end
  end

  describe "write_migration/5" do
    @describetag :tmp_dir

    test "writes the file once and finds it on the next run", %{tmp_dir: dir} do
      assert {:created, path} =
               ObanSchema.write_migration(dir, "MyApp", "public", {13, 14}, "20261004120000")

      assert Path.basename(path) == "20261004120000_phoenix_kit_update_oban_v13_to_v14.exs"
      assert File.read!(path) == ObanSchema.migration_source("MyApp", "public", 13, 14)

      # An interrupted update (file written, migrate failed) re-runs: a second
      # copy would carry a duplicate module name, which Ecto refuses outright.
      assert ObanSchema.write_migration(dir, "MyApp", "public", {13, 14}, "20261004130000") ==
               {:exists, path}

      assert File.ls!(dir) == [Path.basename(path)]
    end

    test "a different step or prefix is a different file", %{tmp_dir: dir} do
      {:created, _} = ObanSchema.write_migration(dir, "MyApp", "public", {13, 14}, "1")
      {:created, _} = ObanSchema.write_migration(dir, "MyApp", "auth", {13, 14}, "2")
      {:created, _} = ObanSchema.write_migration(dir, "MyApp", "public", {14, 15}, "3")

      assert length(File.ls!(dir)) == 3
    end

    test "creates the directory when the host has none yet", %{tmp_dir: dir} do
      nested = Path.join(dir, "priv/repo/migrations")
      assert {:created, _} = ObanSchema.write_migration(nested, "MyApp", "public", {13, 14}, "1")
    end
  end

  describe "generatable_prefix?/1" do
    test "plain schema names only — they go into a filename and a module name" do
      assert ObanSchema.generatable_prefix?("public")
      assert ObanSchema.generatable_prefix?("my_app_jobs")
      refute ObanSchema.generatable_prefix?("My-Schema")
      refute ObanSchema.generatable_prefix?("1jobs")
      refute ObanSchema.generatable_prefix?("jobs\"; drop")
    end
  end

  describe "boot_warning/2" do
    test "names the versions, the prefix, the consequence and the fix" do
      message = ObanSchema.boot_warning("public", {:behind, 13, 14})
      assert message =~ "schema v13, Oban expects v14"
      assert message =~ ~s(prefix "public")
      assert message =~ "unique job inserts"
      assert message =~ "mix phoenix_kit.update"
    end
  end

  describe "warn_if_behind/1" do
    test "is silent and returns :ok when no Oban instance runs under that name" do
      assert ObanSchema.warn_if_behind(oban: __MODULE__.NoSuchOban) == :ok
    end
  end

  describe "the doctor's Oban Schema verdict" do
    test "matching the library passes" do
      assert {:pass, detail} = Doctor.oban_schema_verdict([{"public", {:current, 14}}])
      assert detail =~ ~s("public": v14, matches Oban)
    end

    test "behind warns, naming both versions and the command" do
      assert {:warn, detail} = Doctor.oban_schema_verdict([{"public", {:behind, 13, 14}}])
      assert detail =~ "schema v13, Oban expects v14"
      assert detail =~ "mix phoenix_kit.update"
    end

    test "newer than the library is reported, not warned" do
      assert {:pass, detail} = Doctor.oban_schema_verdict([{"public", {:ahead, 15, 14}}])
      assert detail =~ "newer than this Oban"
    end

    test "one prefix behind warns even when another is current" do
      assert {:warn, detail} =
               Doctor.oban_schema_verdict([
                 {"auth", {:current, 14}},
                 {"public", {:behind, 13, 14}}
               ])

      assert detail =~ ~s("auth": v14)
      assert detail =~ ~s("public": schema v13)
    end

    test "an unreadable version or database warns" do
      assert {:warn, _} = Doctor.oban_schema_verdict([{"public", {:unversioned, nil}}])
      assert {:warn, _} = Doctor.oban_schema_verdict([{"public", {:error, "closed"}}])
    end

    test "no oban_jobs anywhere passes, and a missing table is not listed beside a real one" do
      assert {:pass, detail} = Doctor.oban_schema_verdict([{"public", :no_table}])
      assert detail =~ "No oban_jobs table"

      assert {:pass, detail} =
               Doctor.oban_schema_verdict([{"auth", {:current, 14}}, {"public", :no_table}])

      refute detail =~ "public"
    end
  end
end
