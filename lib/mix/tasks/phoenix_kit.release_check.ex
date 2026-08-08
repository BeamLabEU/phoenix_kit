defmodule Mix.Tasks.PhoenixKit.ReleaseCheck do
  @moduledoc """
  Asserts release-metadata consistency before publishing to Hex.

  Catches the class of mistakes that `precommit`/`quality.ci` cannot see —
  version/CHANGELOG/migration drift and unsafe git state — and exits non-zero
  on any failure so it can gate `mix hex.publish`. It is the semantic core of
  the `mix prerelease` alias and runs without a database.

  ## Usage

      $ mix phoenix_kit.release_check
      $ mix phoenix_kit.release_check --allow-dirty --allow-branch

  ## Options

    * `--allow-dirty`  — downgrade the "working tree clean" check to a warning
    * `--allow-branch` — downgrade the "on main branch" check to a warning

  ## Checks Performed

    1. **CHANGELOG Heading** — top `## X.Y.Z` entry matches `mix.exs` `@version`
       (and is a real version, not "Unreleased").
    2. **CHANGELOG Body** — that entry has at least one content line.
    3. **Migration Version Sync** — code/disk/module consistency for the
       versioned migration chain:
         * `Migrations.Postgres.current_version/0` equals the highest
           `vNNN.ex` file on disk.
         * `Migrations.Postgres.initial_version/0` equals the LOWEST
           `vNNN.ex` file on disk (catches an orphaned below-floor file, or
           a floor bump that left the old file behind).
         * every version in `initial_version/0..current_version/0` has both
           a `vNNN.ex` file on disk AND a loadable
           `PhoenixKit.Migrations.Postgres.VNNN` module — catches an
           accidentally deleted delta file.
         * when `PhoenixKit.Migrations.ExpectedSchema` (the tool-generated
           verify-and-repair manifest, squash spec §5.1/§8.3) is loaded, its
           `chain_hash/0` must match a fresh SHA-256 over the same `vNNN.ex`
           file set — catches a migration added without regenerating the
           manifest. While the manifest does not exist yet (pre-squash, P2,
           pending the operator scratch DB), this prints an explicit SKIP
           notice instead of failing — see
           `dev_docs/plans/2026-07-14-squash-migrations-spec.md`.
    4. **Git Tree Clean** — no uncommitted changes (`--allow-dirty` to warn).
    5. **Git Branch** — on `main` (`--allow-branch` to warn).
    6. **Tag Collision** — tag `v<version>` does not already exist (publish-
       before-tag means a pre-existing tag signals a double release).
  """

  use Mix.Task

  alias PhoenixKit.Migrations.ExpectedSchema.Resolver

  @shortdoc "Asserts version/CHANGELOG/migration/git consistency before a Hex release"

  @switches [allow_dirty: :boolean, allow_branch: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)

    version = Mix.Project.config()[:version]

    header("PhoenixKit Release Check (v#{version})")

    results = [
      run_check("CHANGELOG Heading", fn -> check_changelog_heading(version) end),
      run_check("CHANGELOG Body", fn -> check_changelog_body(version) end),
      run_check("Migration Version Sync", fn -> check_migration_sync() end),
      run_check("Git Tree Clean", fn -> check_git_clean(opts) end),
      run_check("Git Branch", fn -> check_git_branch(opts) end),
      run_check("Tag Collision", fn -> check_tag_collision(version) end)
    ]

    IO.puts("")
    summary(results)
  end

  # ── Check implementations (return {:pass | :warn | :fail, detail}) ──

  defp check_changelog_heading(version) do
    case top_changelog_version() do
      {:ok, ^version} ->
        {:pass, "Top CHANGELOG entry is #{version}"}

      {:ok, other} ->
        {:fail,
         "mix.exs is #{version} but top CHANGELOG entry is #{other}. " <>
           "Add a `## #{version} - <date>` section before publishing."}

      :unreleased ->
        {:fail, "Top CHANGELOG entry is still \"Unreleased\" — stamp it with #{version}."}

      :error ->
        {:fail, "Could not find a `## X.Y.Z` heading in CHANGELOG.md"}
    end
  end

  defp check_changelog_body(version) do
    case changelog_body(version) do
      {:ok, body} ->
        if String.trim(body) == "" do
          {:fail, "The #{version} CHANGELOG section has no content."}
        else
          lines = body |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))
          {:pass, "#{lines} non-blank line(s)"}
        end

      :error ->
        {:fail, "No CHANGELOG section found for #{version}."}
    end
  end

  # Public for testability (mix task internals otherwise); @doc false. Lets a
  # unit test assert directly that this passes against the real, un-squashed
  # chain (spec §5.3's "habitual mix test gate" requirement) without going
  # through `run/1`'s git/CHANGELOG side effects.
  @doc false
  def check_migration_sync do
    module = PhoenixKit.Migrations.Postgres

    if migrations_module_ready?(module) do
      disk_versions = migration_file_versions()

      [
        check_highest_matches_current(module, disk_versions),
        check_floor(module, disk_versions),
        check_range_contiguity(module, disk_versions),
        check_manifest_chain_hash()
      ]
      |> combine_sync_results()
    else
      {:warn, "PhoenixKit.Migrations.Postgres.current_version/0 not available — skipped."}
    end
  end

  defp migrations_module_ready?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :current_version, 0) and
      function_exported?(module, :initial_version, 0)
  end

  # Folds the four sub-checks into the single {:pass|:warn|:fail, detail}
  # shape `run_check/2` expects: worst-status-wins (fail > warn > pass), and
  # `:skip` (the chain_hash sub-check while the manifest doesn't exist yet)
  # never worsens the overall status — it is rendered in `detail` with an
  # explicit "SKIP" tag instead.
  defp combine_sync_results(sub_results) do
    status =
      cond do
        Enum.any?(sub_results, &match?({:fail, _}, &1)) -> :fail
        Enum.any?(sub_results, &match?({:warn, _}, &1)) -> :warn
        true -> :pass
      end

    {status, Enum.map_join(sub_results, "\n       ", &format_sub_result/1)}
  end

  defp format_sub_result({:pass, msg}), do: "PASS #{msg}"
  defp format_sub_result({:warn, msg}), do: "WARN #{msg}"
  defp format_sub_result({:fail, msg}), do: "FAIL #{msg}"
  defp format_sub_result({:skip, msg}), do: "SKIP #{msg}"

  defp check_highest_matches_current(module, disk_versions) do
    code_version = module.current_version()

    case Enum.max(disk_versions, fn -> nil end) do
      nil ->
        {:fail, "No vNNN.ex migration files found."}

      ^code_version ->
        {:pass, "current_version/0 == v#{code_version}.ex"}

      file_version ->
        {:fail,
         "Migrations.Postgres.current_version/0 is #{code_version} but the highest " <>
           "migration file is v#{file_version}.ex — register the new version (or " <>
           "remove the stray file)."}
    end
  end

  defp check_floor(module, disk_versions) do
    floor = module.initial_version()

    case floor_report(floor, disk_versions) do
      {:ok, floor} ->
        {:pass, "min(vNN.ex on disk) == initial_version/0 (V#{floor})"}

      {:error, :no_files} ->
        {:fail, "No vNNN.ex migration files found."}

      {:error, {:floor_mismatch, disk_min, floor}} ->
        {:fail,
         "initial_version/0 is V#{floor} but the lowest migration file on disk is " <>
           "V#{disk_min} — either a below-floor file was orphaned, or initial_version/0 " <>
           "was bumped without deleting the files it now excludes."}
    end
  end

  # `min(disk_versions) == initial_version` as a pure fact, decoupled from
  # disk/module I/O so it is directly unit-testable with synthetic data.
  # `:ok` carries the confirmed floor back for the caller's success message.
  # Public for testability (mix task internals otherwise); @doc false.
  @doc false
  def floor_report(initial_version, disk_versions) do
    case Enum.min(disk_versions, fn -> nil end) do
      nil -> {:error, :no_files}
      ^initial_version -> {:ok, initial_version}
      disk_min -> {:error, {:floor_mismatch, disk_min, initial_version}}
    end
  end

  defp check_range_contiguity(module, disk_versions) do
    floor = module.initial_version()
    current = module.current_version()

    case contiguity_report(floor, current, disk_versions, &loadable_version_module?/1) do
      {:ok, count} ->
        {:pass, "V#{floor}..V#{current} contiguous (#{count} versions), every module loadable"}

      {:error, %{missing_files: missing_files, missing_modules: missing_modules}} ->
        {:fail, contiguity_failure_message(floor, current, missing_files, missing_modules)}
    end
  end

  # Every version in `floor..current` resolves to both an on-disk file
  # (checked via `disk_versions`, a plain list of the version numbers
  # actually found) and a loadable module (checked via `loadable?`, a 1-arg
  # predicate) — the range-completeness property (squash spec §5.3): the
  # habitual `mix test` gate must catch an accidentally deleted delta file
  # even though `release_check` itself only runs via the `prerelease` alias.
  #
  # Pure and injectable on purpose — `loadable?` lets a unit test simulate a
  # missing module without needing a real missing file on disk (this repo's
  # `v*.ex` chain is out of scope to mutate for a test fixture), and passing
  # `disk_versions` directly (rather than re-scanning) lets the same
  # synthetic data drive both the file-gap and module-gap branches
  # independently. Public for testability; @doc false.
  @doc false
  def contiguity_report(floor, current, disk_versions, loadable?)
      when is_function(loadable?, 1) do
    present = MapSet.new(disk_versions)
    expected = floor..current

    missing_files = Enum.filter(expected, &(not MapSet.member?(present, &1)))
    missing_modules = Enum.filter(expected, &(not loadable?.(&1)))

    if missing_files == [] and missing_modules == [] do
      {:ok, Enum.count(expected)}
    else
      {:error, %{missing_files: missing_files, missing_modules: missing_modules}}
    end
  end

  defp contiguity_failure_message(floor, current, missing_files, missing_modules) do
    problems =
      [file_gap_message(missing_files), module_gap_message(missing_modules)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    "V#{floor}..V#{current} is not contiguous — #{problems}"
  end

  defp file_gap_message([]), do: nil

  defp file_gap_message(missing),
    do: "missing vNN.ex file(s) for version(s) #{Enum.join(missing, ", ")}"

  defp module_gap_message([]), do: nil

  defp module_gap_message(missing) do
    names = Enum.map_join(missing, ", ", &inspect(version_module(&1)))
    "unloadable module(s) #{names}"
  end

  # Same module-name construction `Postgres.execute_migration_steps/2`'s
  # dispatch uses (`postgres.ex` ~:1616-1631, verified at HEAD): 2-digit
  # zero-padded for V01..V99, unpadded beyond (V100, V101, …) because
  # `String.pad_leading/3` only pads UP TO the given length, never truncates
  # a longer string.
  defp version_module(n) do
    Module.concat(PhoenixKit.Migrations.Postgres, "V#{String.pad_leading(to_string(n), 2, "0")}")
  end

  defp loadable_version_module?(n), do: Code.ensure_loaded?(version_module(n))

  # `PhoenixKit.Migrations.ExpectedSchema` (spec §5.1) does not exist in this
  # repository yet — it is generated from a real migrated scratch DB and
  # lands with the squash PR (P3). Every consumer resolves it through
  # `Resolver.resolve/0` so "not generated yet" degrades identically
  # everywhere instead of each call site guarding it separately. Public for
  # testability (needs `Application.put_env(:phoenix_kit, :expected_schema_module, ...)`
  # to exercise the :ok/:error branches — see `Resolver`'s moduledoc); @doc false.
  @doc false
  def check_manifest_chain_hash do
    case Resolver.resolve() do
      {:ok, manifest_module} ->
        {computed, count} = compute_chain_hash()

        if manifest_module.chain_hash() == computed do
          {:pass, "chain_hash matches #{count} on-disk migration file(s)"}
        else
          {:fail,
           "#{inspect(manifest_module)}.chain_hash/0 is stale — it no longer matches a " <>
             "fresh hash over lib/phoenix_kit/migrations/postgres/v*.ex. Regenerate the " <>
             "manifest (dev_docs/squash/generate_baseline.exs) before releasing."}
        end

      {:error, :not_generated} ->
        {:skip, "#{Resolver.not_generated_message()} — chain_hash freshness check skipped."}
    end
  end

  # SHA-256 (lower-hex) over the sorted `v*.ex` migration file set —
  # duplicated from `dev_docs/squash/generate_baseline.exs`'s
  # `PhoenixKit.Squash.Generate.Emitter.chain_hash/1` (verified at HEAD; that
  # script is a dev-only tool, not part of the compiled library, so this mix
  # task cannot call it directly — the algorithm is reproduced byte-for-byte
  # here instead). Any future change to the generator's algorithm must
  # update this copy too.
  #
  # Unlike the generator's version, this deliberately does not raise on an
  # empty file set — `check_floor/2`/`check_highest_matches_current/2`
  # already surface that catastrophic case as a `:fail`; this function stays
  # a never-raise helper so `mix phoenix_kit.release_check` itself never
  # crashes. Public for testability; @doc false.
  @doc false
  def compute_chain_hash do
    files = postgres_migrations_glob() |> Path.wildcard() |> Enum.sort()

    hash =
      files
      |> Enum.reduce(:crypto.hash_init(:sha256), fn file, acc ->
        acc
        |> :crypto.hash_update(Path.basename(file))
        |> :crypto.hash_update("\n")
        |> :crypto.hash_update(File.read!(file))
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {hash, length(files)}
  end

  defp check_git_clean(opts) do
    case git(["status", "--porcelain"]) do
      {:ok, ""} ->
        {:pass, "No uncommitted changes"}

      {:ok, out} ->
        count = out |> String.split("\n", trim: true) |> length()
        detail = "#{count} uncommitted change(s). Commit or stash before publishing."
        if opts[:allow_dirty], do: {:warn, detail}, else: {:fail, detail}

      :error ->
        {:warn, "git unavailable — skipped."}
    end
  end

  defp check_git_branch(opts) do
    case git(["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, "main"} ->
        {:pass, "On main"}

      {:ok, branch} ->
        detail = "On #{branch}, not main. Releases are cut from main."
        if opts[:allow_branch], do: {:warn, detail}, else: {:fail, detail}

      :error ->
        {:warn, "git unavailable — skipped."}
    end
  end

  defp check_tag_collision(version) do
    tag = "v#{version}"

    case git(["tag", "-l", tag]) do
      {:ok, ""} ->
        {:pass, "#{tag} does not exist yet"}

      {:ok, _} ->
        {:fail, "Tag #{tag} already exists — this version looks already released."}

      :error ->
        {:warn, "git unavailable — skipped."}
    end
  end

  # ── CHANGELOG parsing ──────────────────────────────────────────────

  # Matches "## 1.7.138 - 2026-06-09", "## [1.7.138]", "## v1.7.138", etc.
  @heading_re ~r/^##\s+\[?v?(?<ver>\d+\.\d+\.\d+)/

  defp top_changelog_version do
    case File.read(changelog_path()) do
      {:ok, contents} ->
        heading = first_heading(contents) || ""

        cond do
          Regex.match?(~r/^##\s+\[?unreleased/im, heading) ->
            :unreleased

          match = Regex.named_captures(@heading_re, heading) ->
            {:ok, match["ver"]}

          true ->
            :error
        end

      _ ->
        :error
    end
  end

  # The first line starting with "## " — the latest entry.
  defp first_heading(contents) do
    contents
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "## "))
  end

  defp changelog_body(version) do
    case File.read(changelog_path()) do
      {:ok, contents} ->
        lines = String.split(contents, "\n")
        target = ~r/^##\s+\[?v?#{Regex.escape(version)}\b/

        case Enum.find_index(lines, &Regex.match?(target, &1)) do
          nil ->
            :error

          idx ->
            body =
              lines
              |> Enum.drop(idx + 1)
              |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
              |> Enum.join("\n")

            {:ok, body}
        end

      _ ->
        :error
    end
  end

  defp changelog_path, do: Path.join(File.cwd!(), "CHANGELOG.md")

  # ── Migration file discovery ───────────────────────────────────────

  defp postgres_migrations_dir, do: "lib/phoenix_kit/migrations/postgres"

  defp postgres_migrations_glob, do: Path.join(postgres_migrations_dir(), "v*.ex")

  # One wildcard scan (not one per sub-check) so every sub-check reasons
  # about the exact same on-disk snapshot.
  defp migration_file_versions do
    postgres_migrations_glob()
    |> Path.wildcard()
    |> Enum.map(&extract_migration_number/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp extract_migration_number(path) do
    case Regex.run(~r/v(\d+)\.ex$/, Path.basename(path)) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  # ── Git ────────────────────────────────────────────────────────────

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ── Output (mirrors mix phoenix_kit.doctor) ────────────────────────

  defp header(title) do
    IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.cyan()}#{title}#{IO.ANSI.reset()}")
    IO.puts(String.duplicate("─", 60))
  end

  defp run_check(name, fun) do
    result =
      try do
        fun.()
      rescue
        e -> {:fail, "Exception: #{Exception.message(e)}"}
      end

    display_check(name, result)
    {name, result}
  end

  defp display_check(name, {:pass, detail}) do
    IO.puts("  #{IO.ANSI.green()}PASS#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.faint()}#{detail}#{IO.ANSI.reset()}")
  end

  defp display_check(name, {:warn, detail}) do
    IO.puts("  #{IO.ANSI.yellow()}WARN#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.yellow()}#{detail}#{IO.ANSI.reset()}")
  end

  defp display_check(name, {:fail, detail}) do
    IO.puts("  #{IO.ANSI.red()}FAIL#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.red()}#{detail}#{IO.ANSI.reset()}")
  end

  defp summary(results) do
    pass = Enum.count(results, fn {_, {status, _}} -> status == :pass end)
    warn = Enum.count(results, fn {_, {status, _}} -> status == :warn end)
    fail = Enum.count(results, fn {_, {status, _}} -> status == :fail end)
    total = length(results)

    IO.puts(
      "#{IO.ANSI.bright()}Summary#{IO.ANSI.reset()}: #{pass}/#{total} passed, #{warn} warnings, #{fail} failures"
    )

    if fail > 0 do
      IO.puts(
        "#{IO.ANSI.red()}Release blocked — fix the FAIL items above before publishing.#{IO.ANSI.reset()}"
      )

      exit({:shutdown, 1})
    end
  end
end
