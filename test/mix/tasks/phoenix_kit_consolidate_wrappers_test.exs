defmodule Mix.Tasks.PhoenixKit.ConsolidateWrappersTest do
  @moduledoc """
  DB-free unit + tmp_dir integration tests for the wrapper-history collapser.

  No PostgreSQL anywhere: this task only ever reads/writes files under a
  migrations directory, so every test here operates on `tmp_dir!/0` fixtures
  built from the exact three real wrapper shapes emitted today by
  `mix phoenix_kit.install` (`PhoenixKit.Install.MigrationStrategy`),
  `mix phoenix_kit.update`, and `mix phoenix_kit.gen.migration` — verified by
  reading each generator's current source before writing these fixtures.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.PhoenixKit.ConsolidateWrappers, as: CW

  # -------------------------------------------------------------------
  # Fixture content builders — mirror the 3 real generators exactly
  # -------------------------------------------------------------------

  # PhoenixKit.Install.MigrationStrategy.create_initial_migration_silent/3:
  # `migration_opts("public", _)` always renders "[]" (no version, no
  # create_schema key at all — irrelevant for the public schema); a named
  # prefix renders `inspect(prefix: prefix, create_schema: create_schema)`.
  defp installer_content(nil, _create_schema) do
    """
    defmodule MyApp.Repo.Migrations.AddPhoenixKitTables do
      use Ecto.Migration

      def up, do: PhoenixKit.Migrations.up([])

      def down, do: PhoenixKit.Migrations.down([])
    end
    """
  end

  defp installer_content(prefix, create_schema) do
    opts = "[prefix: #{inspect(prefix)}, create_schema: #{create_schema}]"

    """
    defmodule MyApp.Repo.Migrations.AddPhoenixKitTables do
      use Ecto.Migration

      def up, do: PhoenixKit.Migrations.up(#{opts})

      def down, do: PhoenixKit.Migrations.down(#{opts})
    end
    """
  end

  # Mix.Tasks.PhoenixKit.Update.create_update_migration_with_igniter/5: padded
  # filename version, bracketed list literal, Ecto.Migrations.* namespace.
  defp update_padded_content(from, to, prefix \\ "public", create_schema \\ false) do
    """
    defmodule Ecto.Migrations.PhoenixKitUpdateV#{pad(from)}ToV#{pad(to)} do
      @moduledoc false
      use Ecto.Migration

      @disable_ddl_transaction true

      def up do
        PhoenixKit.Migrations.up([
          prefix: "#{prefix}",
          version: #{to},
          create_schema: #{create_schema}
        ])
      end

      def down do
        PhoenixKit.Migrations.down([
          prefix: "#{prefix}",
          version: #{from}
        ])
      end
    end
    """
  end

  # Mix.Tasks.PhoenixKit.Gen.Migration.migration_content/5: unpadded filename
  # version, bare keyword-list args (no brackets), app-repo namespace.
  defp gen_unpadded_content(from, to, prefix \\ "public", create_schema \\ false) do
    """
    defmodule MyApp.Repo.Migrations.PhoenixKitUpdateV#{from}ToV#{to} do
      @moduledoc false
      use Ecto.Migration

      @disable_ddl_transaction true

      def up do
        PhoenixKit.Migrations.up(
          prefix: "#{prefix}",
          version: #{to},
          create_schema: #{create_schema}
        )
      end

      def down do
        PhoenixKit.Migrations.down(
          prefix: "#{prefix}",
          version: #{from}
        )
      end
    end
    """
  end

  defp foreign_content(name \\ "AddIndexToOrders") do
    """
    defmodule MyApp.Repo.Migrations.#{name} do
      use Ecto.Migration

      def change do
        create index(:orders, [:customer_id])
      end
    end
    """
  end

  defp pad(v) when v < 10, do: "0#{v}"
  defp pad(v), do: to_string(v)

  # -------------------------------------------------------------------
  # classify/1
  # -------------------------------------------------------------------

  describe "classify/1" do
    test "installer wrapper, public schema (empty-list opts)" do
      assert CW.classify(installer_content(nil, false)) ==
               {:wrapper,
                %{prefix: "public", create_schema: false, up_version: :unpinned, down_version: 0}}
    end

    test "installer wrapper, named prefix, create_schema true" do
      assert CW.classify(installer_content("auth", true)) ==
               {:wrapper,
                %{prefix: "auth", create_schema: true, up_version: :unpinned, down_version: 0}}
    end

    test "update.ex-style padded, bracketed, pinned wrapper" do
      assert CW.classify(update_padded_content(5, 27)) ==
               {:wrapper,
                %{prefix: "public", create_schema: false, up_version: 27, down_version: 5}}
    end

    test "gen.migration.ex-style unpadded, bare-keyword, pinned wrapper" do
      assert CW.classify(gen_unpadded_content(27, 89, "auth", true)) ==
               {:wrapper,
                %{prefix: "auth", create_schema: true, up_version: 89, down_version: 27}}
    end

    test "a plain consumer migration is foreign" do
      assert CW.classify(foreign_content()) == :foreign
    end

    test "a migration merely naming phoenix_kit in its own name/body is still foreign" do
      content = """
      defmodule MyApp.Repo.Migrations.PhoenixKitCatalogueV013BasePrice do
        use Ecto.Migration

        def change do
          execute "ALTER TABLE phoenix_kit_cat_items ADD COLUMN IF NOT EXISTS base_price numeric",
                  "ALTER TABLE phoenix_kit_cat_items DROP COLUMN base_price"
        end
      end
      """

      assert CW.classify(content) == :foreign
    end

    test "unparseable: calls up/1 without a matching down/1" do
      content = """
      defmodule M do
        def up, do: PhoenixKit.Migrations.up([])
      end
      """

      assert {:unparseable, reason} = CW.classify(content)
      assert reason =~ "without a matching .down/1"
    end

    test "unparseable: calls down/1 without a matching up/1" do
      content = """
      defmodule M do
        def down, do: PhoenixKit.Migrations.down([])
      end
      """

      assert {:unparseable, reason} = CW.classify(content)
      assert reason =~ "without a matching .up/1"
    end

    test "unparseable: up/down disagree on prefix" do
      content = """
      defmodule M do
        def up, do: PhoenixKit.Migrations.up(prefix: "a", version: 5)
        def down, do: PhoenixKit.Migrations.down(prefix: "b", version: 1)
      end
      """

      assert {:unparseable, reason} = CW.classify(content)
      assert reason =~ "disagree on prefix"
    end

    test "unparseable: an invalid prefix value" do
      content = """
      defmodule M do
        def up, do: PhoenixKit.Migrations.up(prefix: "NOT VALID!", version: 5)
        def down, do: PhoenixKit.Migrations.down(prefix: "NOT VALID!", version: 1)
      end
      """

      assert {:unparseable, reason} = CW.classify(content)
      assert reason =~ "invalid PhoenixKit schema prefix"
    end

    test "unparseable: up/1 call never closes before EOF" do
      content =
        "def up, do: PhoenixKit.Migrations.up(prefix: \"public\"\ndef down, do: PhoenixKit.Migrations.down([])"

      assert {:unparseable, reason} = CW.classify(content)
      assert reason =~ "unbalanced"
    end

    test "a closing paren inside a quoted prefix value cannot terminate the scan early" do
      # Pathological but must not crash or misparse: the balanced-paren
      # scanner must treat ')' inside a string literal as inert. If it
      # regressed and stopped at the embedded ')' instead, the up/down
      # prefixes would either fail to parse at all or silently disagree —
      # neither of which is the specific rejection asserted here. Reaching
      # exactly the validate_prefix! rejection, quoting the FULL value,
      # proves both calls parsed the whole "weird)prefix" string intact.
      content = """
      def up, do: PhoenixKit.Migrations.up(prefix: "weird)prefix", version: 5)
      def down, do: PhoenixKit.Migrations.down(prefix: "weird)prefix", version: 1)
      """

      assert {:unparseable, reason} = CW.classify(content)
      assert reason =~ "invalid PhoenixKit schema prefix"
      assert reason =~ "weird)prefix"
    end
  end

  # -------------------------------------------------------------------
  # discover/1
  # -------------------------------------------------------------------

  describe "discover/1" do
    test "returns {:error, :enoent} for a missing directory" do
      missing =
        Path.join(System.tmp_dir!(), "pk_cw_missing_#{System.unique_integer([:positive])}")

      assert CW.discover(missing) == {:error, :enoent}
    end

    test "lists only leading-digit .exs files, sorted by timestamp, with content read" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "20260101000002_second.exs"), "b")
      File.write!(Path.join(dir, "20260101000001_first.exs"), "a")
      File.write!(Path.join(dir, "not_a_migration.exs"), "ignored")
      File.write!(Path.join(dir, "README.md"), "ignored")

      assert {:ok, entries} = CW.discover(dir)

      assert Enum.map(entries, & &1.filename) == [
               "20260101000001_first.exs",
               "20260101000002_second.exs"
             ]

      assert Enum.map(entries, & &1.content) == ["a", "b"]
      assert Enum.map(entries, & &1.timestamp) == [20_260_101_000_001, 20_260_101_000_002]
    end
  end

  # -------------------------------------------------------------------
  # build_plan/2
  # -------------------------------------------------------------------

  describe "build_plan/2" do
    test "{:noop, :none_found} when there are no wrapper files" do
      entries = [entry(1, foreign_content())]
      assert CW.build_plan(entries) == {:noop, :none_found}
    end

    test "{:noop, :single_wrapper} when exactly one wrapper file exists" do
      entries = [entry(1, installer_content(nil, false))]
      assert CW.build_plan(entries) == {:noop, :single_wrapper}
    end

    test "happy path: installer + several pinned wrappers, no interleaving" do
      entries = [
        entry(1, installer_content(nil, false)),
        entry(2, update_padded_content(1, 27)),
        entry(3, gen_unpadded_content(27, 89)),
        entry(4, update_padded_content(89, 121))
      ]

      assert {:ok, plan} = CW.build_plan(entries)
      assert plan.prefix == "public"
      assert plan.create_schema == false
      assert plan.down_target == 0
      assert plan.up_target == 121
      assert plan.timestamp_str == "1"
      assert plan.filename == "1_phoenix_kit_consolidated.exs"
      assert length(plan.files_to_delete) == 4
      assert plan.forced_interleaved == []
    end

    test "refuses with {:error, {:interleaved, _}} when a foreign file sits between wrappers" do
      entries = [
        entry(1, installer_content(nil, false)),
        entry(2, foreign_content("Sneaky")),
        entry(3, update_padded_content(1, 27))
      ]

      assert {:error, {:interleaved, [interloper]}} = CW.build_plan(entries)
      assert interloper.timestamp == 2
    end

    test "--force proceeds despite interleaving and records it as forced_interleaved" do
      entries = [
        entry(1, installer_content(nil, false)),
        entry(2, foreign_content("Sneaky")),
        entry(3, update_padded_content(1, 27))
      ]

      assert {:ok, plan} = CW.build_plan(entries, %{force: true})
      assert [interloper] = plan.forced_interleaved
      assert interloper.timestamp == 2
      # The foreign file is reported, never scheduled for deletion.
      refute interloper.path in plan.files_to_delete
    end

    test "a foreign file entirely before the first wrapper is never interleaved" do
      entries = [
        entry(1, foreign_content("Before")),
        entry(2, installer_content(nil, false)),
        entry(3, update_padded_content(1, 27))
      ]

      assert {:ok, plan} = CW.build_plan(entries)
      assert plan.forced_interleaved == []
    end

    test "a foreign file entirely after the last wrapper is never interleaved" do
      entries = [
        entry(1, installer_content(nil, false)),
        entry(2, update_padded_content(1, 27)),
        entry(3, foreign_content("After"))
      ]

      assert {:ok, plan} = CW.build_plan(entries)
      assert plan.forced_interleaved == []
    end

    test "{:error, {:unparseable, _}} is fatal even when --force is passed" do
      entries = [
        entry(1, installer_content(nil, false)),
        entry(2, update_padded_content(1, 27)),
        entry(3, "def up, do: PhoenixKit.Migrations.up([])")
      ]

      assert {:error, {:unparseable, [bad]}} = CW.build_plan(entries, %{force: true})
      assert {:unparseable, _reason} = bad.tag
    end

    test "{:error, {:mixed_prefixes, _}} when wrappers for 2 prefixes are found and no --prefix given" do
      entries = [
        entry(1, installer_content(nil, false)),
        entry(2, installer_content("auth", true))
      ]

      assert {:error, {:mixed_prefixes, groups}} = CW.build_plan(entries)
      assert Map.keys(groups) |> Enum.sort() == ["auth", "public"]
    end

    test "--prefix scopes the chain and treats other-prefix wrappers as neutral (not interleaved)" do
      entries = [
        entry(1, installer_content(nil, false)),
        # Sits chronologically BETWEEN the public chain's endpoints, but is a
        # recognized PhoenixKit wrapper for a different prefix — must not be
        # reported as an interleaved foreign migration for the public plan.
        entry(2, installer_content("auth", true)),
        entry(3, update_padded_content(1, 27))
      ]

      assert {:ok, plan} = CW.build_plan(entries, %{prefix: "public"})
      assert plan.prefix == "public"
      assert plan.forced_interleaved == []
      assert length(plan.files_to_delete) == 2
    end

    test "up_target is :unpinned when the last in-scope wrapper itself never pins a version" do
      # Not producible by any of the 3 real generators today (an unpinned
      # wrapper can only ever be the sole/earliest one) — this exercises the
      # defensive branch directly via hand-built entries.
      entries = [
        entry(1, update_padded_content(1, 27)),
        entry(2, installer_content(nil, false))
      ]

      assert {:ok, plan} = CW.build_plan(entries)
      assert plan.up_target == :unpinned
      assert plan.down_target == 1
    end

    test "re-consolidating: the earliest wrapper already occupies the computed target path, so files_to_delete must never include it" do
      # Simulates the state after a FIRST successful consolidation (a file
      # literally named "<ts>_phoenix_kit_consolidated.exs") plus one NEW
      # `phoenix_kit.update` wrapper accumulated afterward — the exact
      # maintenance scenario this task's own docs anticipate ("consolidate
      # once, accumulate more wrappers, consolidate again"). The earliest
      # in-scope wrapper's path is then, by construction, IDENTICAL to the
      # path this run computes for its own new file.
      already_consolidated = %{
        path: "/fixture/20260101000001_phoenix_kit_consolidated.exs",
        filename: "20260101000001_phoenix_kit_consolidated.exs",
        timestamp: 20_260_101_000_001,
        timestamp_str: "20260101000001",
        content: update_padded_content(0, 27)
      }

      new_wrapper = entry(20_260_101_000_002, gen_unpadded_content(27, 89))

      assert {:ok, plan} = CW.build_plan([already_consolidated, new_wrapper])
      assert plan.path == already_consolidated.path
      refute plan.path in plan.files_to_delete
      assert plan.files_to_delete == [new_wrapper.path]
    end
  end

  # -------------------------------------------------------------------
  # render_content/1
  # -------------------------------------------------------------------

  describe "render_content/1" do
    test "pinned target: valid Elixir, correct module, disable_ddl_transaction, exact up/down calls" do
      plan = plan_fixture(up_target: 89, down_target: 5, prefix: "public", create_schema: false)

      content = CW.render_content(plan)

      assert {:ok, _quoted} = Code.string_to_quoted(content)
      assert content =~ "Migrations.PhoenixKitConsolidated do"
      assert content =~ "@disable_ddl_transaction true"

      assert content =~
               ~s[PhoenixKit.Migrations.up(prefix: "public", create_schema: false, version: 89)]

      assert content =~ ~s[PhoenixKit.Migrations.down(prefix: "public", version: 5)]
    end

    test "unpinned target: up call carries no version:, down is still pinned" do
      plan =
        plan_fixture(up_target: :unpinned, down_target: 0, prefix: "public", create_schema: false)

      content = CW.render_content(plan)

      assert {:ok, _quoted} = Code.string_to_quoted(content)
      assert content =~ ~s[PhoenixKit.Migrations.up(prefix: "public", create_schema: false)]
      refute String.contains?(up_line(content), "version:")
      assert content =~ ~s[PhoenixKit.Migrations.down(prefix: "public", version: 0)]
    end

    test "named prefix and create_schema true round-trip into the rendered call" do
      plan = plan_fixture(up_target: 27, down_target: 0, prefix: "auth", create_schema: true)

      content = CW.render_content(plan)

      assert content =~ ~s[prefix: "auth", create_schema: true, version: 27]
    end

    test "is idempotent under Code.format_string! (already mix-format-clean)" do
      plan = plan_fixture(up_target: 89, down_target: 5)
      content = CW.render_content(plan)

      reformatted = content |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
      assert reformatted == content
    end
  end

  # -------------------------------------------------------------------
  # apply!/1 and end-to-end run/1 (tmp_dir integration, no DB)
  # -------------------------------------------------------------------

  describe "apply!/1 and run/1 end-to-end" do
    test "dry run (default / --dry-run) leaves the directory untouched" do
      dir = tmp_dir!()
      write_chain(dir)
      before = dir |> File.ls!() |> Enum.sort()

      capture_io(fn -> CW.run(["--migrations-dir", dir]) end)
      capture_io(fn -> CW.run(["--migrations-dir", dir, "--dry-run"]) end)

      assert dir |> File.ls!() |> Enum.sort() == before
    end

    test "--apply writes the consolidated file at the first wrapper's timestamp and deletes the rest" do
      dir = tmp_dir!()

      write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

      write_file!(
        dir,
        "20260101000002",
        "phoenix_kit_update_v01_to_v27",
        update_padded_content(1, 27)
      )

      write_file!(
        dir,
        "20260101000003",
        "phoenix_kit_update_v27_to_v89",
        gen_unpadded_content(27, 89)
      )

      capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply"]) end)

      assert File.ls!(dir) == ["20260101000001_phoenix_kit_consolidated.exs"]

      content = File.read!(Path.join(dir, "20260101000001_phoenix_kit_consolidated.exs"))
      assert content =~ "version: 89"
      assert content =~ "PhoenixKit.Migrations.down(prefix: \"public\", version: 0)"
    end

    test "re-consolidating an already-consolidated file plus a new wrapper overwrites in place instead of deleting everything" do
      dir = tmp_dir!()

      # Byte-for-byte what a FIRST successful `--apply` run would have
      # written (mirrors `plan_fixture/1`'s defaults) — this test simulates
      # running the task a SECOND time after wrappers accumulated again.
      first_run_plan =
        plan_fixture(up_target: 27, down_target: 0, prefix: "public", create_schema: false)

      File.write!(
        Path.join(dir, "20260101000001_phoenix_kit_consolidated.exs"),
        CW.render_content(first_run_plan)
      )

      write_file!(
        dir,
        "20260101000002",
        "phoenix_kit_update_v27_to_v89",
        gen_unpadded_content(27, 89)
      )

      capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply"]) end)

      # Must still contain exactly one, non-empty PhoenixKit migration file —
      # not zero (the bug this guards: writing the new content and then
      # deleting the very file it was just written to, because the earliest
      # in-scope wrapper WAS the previously-consolidated file at the same
      # path).
      assert File.ls!(dir) == ["20260101000001_phoenix_kit_consolidated.exs"]

      content = File.read!(Path.join(dir, "20260101000001_phoenix_kit_consolidated.exs"))
      refute content == ""
      assert content =~ "version: 89"
      assert content =~ "PhoenixKit.Migrations.down(prefix: \"public\", version: 0)"
    end

    test "realistic 41-file-style chain: many foreign files + 1 installer + 5 update wrappers, no interleaving" do
      dir = tmp_dir!()

      # 20 foreign files strictly before the PhoenixKit chain begins.
      for i <- 1..20 do
        write_file!(
          dir,
          ts(i),
          "consumer_migration_#{i}",
          foreign_content("ConsumerMigration#{i}")
        )
      end

      write_file!(dir, ts(21), "add_phoenix_kit_tables", installer_content(nil, false))
      write_file!(dir, ts(22), "phoenix_kit_update_v01_to_v27", update_padded_content(1, 27))
      write_file!(dir, ts(23), "phoenix_kit_update_v27_to_v53", gen_unpadded_content(27, 53))
      write_file!(dir, ts(24), "phoenix_kit_update_v53_to_v89", update_padded_content(53, 89))
      write_file!(dir, ts(25), "phoenix_kit_update_v89_to_v121", gen_unpadded_content(89, 121))

      write_file!(
        dir,
        ts(26),
        "phoenix_kit_force_update_v121_to_v135",
        update_padded_content(121, 135)
      )

      # 15 more foreign files strictly after the chain ends.
      for i <- 27..41 do
        write_file!(
          dir,
          ts(i),
          "consumer_migration_#{i}",
          foreign_content("ConsumerMigration#{i}")
        )
      end

      assert length(File.ls!(dir)) == 41

      capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply"]) end)

      remaining = File.ls!(dir)
      # 35 foreign files survive untouched; the 6 wrappers become 1.
      assert length(remaining) == 36
      assert "#{ts(21)}_phoenix_kit_consolidated.exs" in remaining

      content = File.read!(Path.join(dir, "#{ts(21)}_phoenix_kit_consolidated.exs"))
      assert content =~ "version: 135"
      assert content =~ "version: 0)"

      for i <- 1..20, do: assert("#{ts(i)}_consumer_migration_#{i}.exs" in remaining)
      for i <- 27..41, do: assert("#{ts(i)}_consumer_migration_#{i}.exs" in remaining)
    end

    test "an interleaved consumer migration raises Mix.Error naming the file, and touches nothing" do
      dir = tmp_dir!()

      write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

      write_file!(
        dir,
        "20260101000002",
        "phoenix_kit_catalogue_v013_base_price",
        foreign_content("PhoenixKitCatalogueV013BasePrice")
      )

      write_file!(
        dir,
        "20260101000003",
        "phoenix_kit_update_v01_to_v27",
        update_padded_content(1, 27)
      )

      before = dir |> File.ls!() |> Enum.sort()

      assert_raise Mix.Error, ~r/phoenix_kit_catalogue_v013_base_price/, fn ->
        capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply"]) end)
      end

      assert dir |> File.ls!() |> Enum.sort() == before
    end

    test "--force bypasses the interleaving refusal, applies, and leaves the foreign file untouched" do
      dir = tmp_dir!()

      write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

      foreign_path =
        write_file!(
          dir,
          "20260101000002",
          "phoenix_kit_catalogue_v013_base_price",
          foreign_content("Sneaky")
        )

      write_file!(
        dir,
        "20260101000003",
        "phoenix_kit_update_v01_to_v27",
        update_padded_content(1, 27)
      )

      original_foreign_content = File.read!(foreign_path)

      capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply", "--force"]) end)

      remaining = File.ls!(dir) |> Enum.sort()

      assert remaining == [
               "20260101000001_phoenix_kit_consolidated.exs",
               "20260101000002_phoenix_kit_catalogue_v013_base_price.exs"
             ]

      assert File.read!(foreign_path) == original_foreign_content
    end

    test "mixed prefixes without --prefix raises Mix.Error listing both prefixes" do
      dir = tmp_dir!()
      write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

      write_file!(
        dir,
        "20260101000002",
        "add_phoenix_kit_tables_auth",
        installer_content("auth", true)
      )

      assert_raise Mix.Error, ~r/more than one schema prefix/, fn ->
        capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply"]) end)
      end
    end

    test "--prefix resolves the mixed-prefix case to one chain" do
      dir = tmp_dir!()
      write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

      write_file!(
        dir,
        "20260101000002",
        "phoenix_kit_update_v01_to_v27",
        update_padded_content(1, 27)
      )

      write_file!(
        dir,
        "20260101000003",
        "add_phoenix_kit_tables_auth",
        installer_content("auth", true)
      )

      capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply", "--prefix", "public"]) end)

      remaining = File.ls!(dir) |> Enum.sort()

      assert remaining == [
               "20260101000001_phoenix_kit_consolidated.exs",
               "20260101000003_add_phoenix_kit_tables_auth.exs"
             ]
    end

    test "no migrations directory at all is a harmless no-op" do
      missing =
        Path.join(System.tmp_dir!(), "pk_cw_missing_run_#{System.unique_integer([:positive])}")

      output = capture_io(fn -> CW.run(["--migrations-dir", missing, "--apply"]) end)
      assert output =~ "nothing to do"
      refute File.exists?(missing)
    end

    test "single wrapper is a harmless no-op, never writes or deletes" do
      dir = tmp_dir!()
      write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

      output = capture_io(fn -> CW.run(["--migrations-dir", dir, "--apply"]) end)
      assert output =~ "nothing to consolidate"
      assert File.ls!(dir) == ["20260101000001_add_phoenix_kit_tables.exs"]
    end

    test "--help prints usage and does not touch any directory" do
      output = capture_io(fn -> CW.run(["--help"]) end)
      assert output =~ "mix phoenix_kit.consolidate_wrappers"
      assert output =~ "--apply"
    end
  end

  # -------------------------------------------------------------------
  # parse_args/1
  # -------------------------------------------------------------------

  describe "parse_args/1" do
    test "defaults: dry run, no force, no prefix, standard migrations dir" do
      opts = CW.parse_args([])
      assert opts.apply? == false
      assert opts.force? == false
      assert opts.prefix == nil
      assert opts.migrations_dir == Path.join(["priv", "repo", "migrations"])
      assert opts.help == false
    end

    test "parses every flag" do
      opts =
        CW.parse_args(["--apply", "--force", "--prefix", "auth", "--migrations-dir", "tmp/mig"])

      assert opts.apply? == true
      assert opts.force? == true
      assert opts.prefix == "auth"
      assert opts.migrations_dir == "tmp/mig"
    end

    test "--dry-run is accepted (default behavior either way)" do
      opts = CW.parse_args(["--dry-run"])
      assert opts.apply? == false
    end

    test "-h is an alias for --help" do
      assert CW.parse_args(["-h"]).help == true
      assert CW.parse_args(["--help"]).help == true
    end
  end

  # -------------------------------------------------------------------
  # helpers
  # -------------------------------------------------------------------

  defp tmp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "pk_consolidate_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_file!(dir, timestamp, slug, content) do
    path = Path.join(dir, "#{timestamp}_#{slug}.exs")
    File.write!(path, content)
    path
  end

  defp write_chain(dir) do
    write_file!(dir, "20260101000001", "add_phoenix_kit_tables", installer_content(nil, false))

    write_file!(
      dir,
      "20260101000002",
      "phoenix_kit_update_v01_to_v27",
      update_padded_content(1, 27)
    )
  end

  defp ts(i), do: 20_260_101_000_000 + i

  # Builds an entry as `discover/1` would, without touching disk — used to
  # unit-test `build_plan/2` directly.
  defp entry(timestamp, content) do
    %{
      path: "/fixture/#{timestamp}_x.exs",
      filename: "#{timestamp}_x.exs",
      timestamp: timestamp,
      timestamp_str: to_string(timestamp),
      content: content
    }
  end

  defp plan_fixture(overrides) do
    base = %{
      prefix: "public",
      create_schema: false,
      up_target: 1,
      down_target: 0,
      timestamp_str: "20260101000001",
      dir: "/fixture",
      filename: "20260101000001_phoenix_kit_consolidated.exs",
      path: "/fixture/20260101000001_phoenix_kit_consolidated.exs",
      files_to_delete: ["/fixture/a.exs", "/fixture/b.exs"],
      forced_interleaved: []
    }

    Map.merge(base, Map.new(overrides))
  end

  defp up_line(content) do
    content
    |> String.split("\n")
    |> Enum.find("", &String.contains?(&1, "PhoenixKit.Migrations.up("))
  end
end
