defmodule Mix.Tasks.PhoenixKit.Status do
  @moduledoc """
  Shows comprehensive status of PhoenixKit installation.

  This task provides a detailed overview of your PhoenixKit installation status,
  including version information, database connectivity, assets status, and
  suggested next actions.

  ## Usage

      $ mix phoenix_kit.status
      $ mix phoenix_kit.status --prefix=myapp

  ## Options

    * `--prefix` - Database schema prefix. When omitted, resolves from
      `config :phoenix_kit, :prefix`, then defaults to "public".
    * `--verbose` - Show detailed diagnostic information
    * `--exit-code` - Exit non-zero unless `Next` is `Ready`. For deploy scripts
      and CI, which otherwise cannot tell a clean install from a module sitting
      four versions behind — the report is identical on stdout either way.
      Off by default so existing deploys that run this for its log line keep
      passing.

  ## Examples

      # Show status for default installation
      mix phoenix_kit.status

      # Show status for custom schema prefix
      mix phoenix_kit.status --prefix=auth

      # Show detailed diagnostic information
      mix phoenix_kit.status --verbose

      # Fail a deploy when core or any module schema is behind
      mix phoenix_kit.status --exit-code

  ## Sample Output

      PhoenixKit v1.7.216
      ├── Installed: V159 ✅
      ├── Database: Connected ✅
      ├── Modules: 2 modules, all up to date ✅
      │   ├── Boards: V01 ✅
      │   └── Inbox: V01 ✅
      └── Next: Ready

  The `Modules` row covers PhoenixKit modules that own their migrations
  (`c:PhoenixKit.Module.migration_module/0`) — each reports the schema version
  installed in *your* database against the version its code expects. When one
  is behind, the report says so and `Next` points at the fix and the reason:

      PhoenixKit v1.7.230
      ├── Installed: V159 ✅
      ├── Database: Connected ✅
      ├── Modules: 2 modules, 1 behind ⚠
      │   ├── Boards: V01 ✅
      │   └── Inbox: V01 ⚠ (code expects V02)
      └── Next: mix phoenix_kit.update — module schema behind: Inbox

  The row is omitted entirely when no installed module owns migrations, so a
  core-only install keeps the compact tree.

  The `Oban schema` row is the version on `oban_jobs` against the one the
  installed Oban library expects. Oban's schema follows the Oban library, not
  PhoenixKit's chain, and a schema left behind fails every unique insert — so
  a behind schema turns `Next` into `mix phoenix_kit.update`, which steps it up:

      ├── Installed: V208 ✅
      ├── Database: Connected ✅
      ├── Oban schema: v13 ⚠ (Oban expects v14)
      └── Next: mix phoenix_kit.update — Oban schema at public is v13, Oban expects v14

  ## "code expects", not "update available"

  Everything reported here is measured against the version compiled into the
  **running release** — this task never asks Hex what exists, so it cannot and
  does not tell you a newer PhoenixKit is out. A version gap is therefore not
  an optional upgrade being offered; it means the schema disagrees with the
  code already querying it, which surfaces as runtime errors on whatever the
  newer version added. The wording is deliberate:

      ├── Installed: V159 ⚠ (code expects V160)
      └── Next: mix phoenix_kit.update — database is V159, code expects V160

  When core and a module are both behind, one command fixes both and both
  reasons are listed, so re-running does not turn up a second finding that was
  already knowable:

      └── Next: mix phoenix_kit.update — database is V159, code expects V160; module schema behind: Inbox

  """

  use Mix.Task
  alias Ecto.Adapters.SQL

  alias PhoenixKit.Config
  alias PhoenixKit.Install.Common
  alias PhoenixKit.Install.PrefixConfig
  alias PhoenixKit.Install.StatusReport
  alias PhoenixKit.Install.StatusTree
  alias PhoenixKit.Migrations.Modules, as: MigrationModules
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.ObanSchema

  @impl Mix.Task
  @spec run([String.t()]) :: :ok

  @shortdoc "Shows comprehensive PhoenixKit installation status"

  @switches [
    prefix: :string,
    verbose: :boolean,
    exit_code: :boolean
  ]

  @aliases [
    p: :prefix,
    v: :verbose
  ]

  def run(argv) do
    # Load configuration and compile without starting the full application.
    # Using --no-start avoids port conflicts when the app is already running.
    Mix.Task.run("app.start", ["--no-start"])

    # Start only the dependencies needed for database queries
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_kit)

    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    # --prefix option → config :phoenix_kit, :prefix → "public", so a
    # prefixed install doesn't report "Not installed" when the flag is
    # omitted.
    prefix = PrefixConfig.resolve_prefix(opts)
    verbose = opts[:verbose] || false

    {next_action, modules} = show_comprehensive_status(prefix, verbose)
    maybe_exit_non_zero(next_action, modules, opts[:exit_code] || false)
  end

  @doc """
  The process exit status `--exit-code` should produce: `0` only when the
  install is verifiably ready, `1` otherwise.

  Public because `run/1` is not a unit-test seam (it starts the app and needs a
  real database) — this is the pure decision behind the flag, in the same shape
  as `Mix.Tasks.PhoenixKit.Repair.exit_code/1`.

  `modules` is a `PhoenixKit.Migrations.Modules.list/1` result, or `:not_queried`
  when the database never answered.
  """
  @spec exit_code(tuple(), [map()] | :not_queried) :: 0 | 1
  # Fail closed when the module list was never queried. `next_action/3` maps
  # {:up_to_date, _} + :not_queried to {:ready, "Ready"}, which is right for a
  # human reading the tree — the Database row above already says it could not
  # look — but as a deploy gate it is the exact silent pass this flag exists to
  # remove. The two reads are independent, so a connection that drops between
  # them yields a readable core marker and unqueried modules in one run.
  def exit_code({:ready, _message}, :not_queried), do: 1
  def exit_code({:ready, _message}, _modules), do: 0
  def exit_code(_next_action, _modules), do: 1

  # Reporting a gap on stdout and then exiting 0 makes this task unusable as a
  # deploy gate: a script that restarts the app after it cannot tell "Ready"
  # from "a module is four versions behind". `--exit-code` is opt-in because
  # the default is load-bearing the other way — deploys that run this purely
  # for its log line must not start failing on an upgrade.
  defp maybe_exit_non_zero(_next_action, _modules, false), do: :ok

  defp maybe_exit_non_zero(next_action, modules, true) do
    case exit_code(next_action, modules) do
      0 -> :ok
      1 -> Mix.raise(exit_message(next_action, modules))
    end
  end

  defp exit_message({:ready, _message}, :not_queried) do
    """
    PhoenixKit is not verifiably up to date (--exit-code).

      Core reports Ready, but the database did not answer when module schema
      versions were queried, so a module may be behind and nothing can tell.
      Re-run mix phoenix_kit.status once the database is reachable.
    """
  end

  defp exit_message(next_action, _modules) do
    """
    PhoenixKit is not up to date (--exit-code).

      #{strip_ansi(format_next_action(next_action))}
    """
  end

  defp strip_ansi(string), do: String.replace(string, ~r/\e\[[0-9;]*m/, "")

  # Main status display function
  defp show_comprehensive_status(prefix, verbose) do
    # Get all status information
    phoenix_kit_version = get_phoenix_kit_version()
    installation_status = get_installation_status(prefix)
    database_status = get_database_status(prefix)

    # Modules that own their migrations report their own schema version. Only
    # queried when the database answered — otherwise every coordinator would
    # time out one after another producing a wall of identical errors.
    modules = module_entries(database_status, prefix)
    oban = oban_schema_entries(database_status, prefix)

    next_action =
      installation_status
      |> determine_next_action(modules, prefix)
      |> StatusReport.with_oban_schema(oban, prefix)

    # Display header
    IO.puts("\n#{IO.ANSI.bright()}PhoenixKit v#{phoenix_kit_version}#{IO.ANSI.reset()}")

    # Display status tree
    display_status_tree(
      [
        {"Installed", format_installation_status(installation_status)},
        {"Database", format_database_status(database_status)}
      ] ++
        module_tree_rows(modules) ++
        oban_schema_rows(oban, prefix) ++
        [{"Next", format_next_action(next_action)}]
    )

    # Show verbose information if requested
    if verbose do
      show_verbose_diagnostics(prefix, installation_status, database_status, modules)
    end

    maybe_hint_no_start(installation_status)

    IO.puts("")

    # `modules` rides along for the `--exit-code` decision: whether the list was
    # queried at all is not recoverable from `next_action` alone.
    {next_action, modules}
  end

  # A core version gap means the compiled schema modules are already selecting
  # columns the database has not got, so the very app `phoenix_kit.update`
  # starts may not boot — a host child that queries at init takes the whole
  # tree down with "column p0.<new_column> does not exist", and the updater
  # that would add the column never gets to run. The plain
  # "Next: mix phoenix_kit.update" walks straight into that, so name the way
  # out beside it. Only for a CORE gap: a module-only gap leaves
  # `phoenix_kit_users` (what every host queries at boot) intact.
  defp maybe_hint_no_start({:needs_update, _current, _target}) do
    IO.puts(
      "\n#{IO.ANSI.faint()}   If the app will not boot (\"column ... does not exist\"), " <>
        "migrate without starting it:#{IO.ANSI.reset()}\n" <>
        "#{IO.ANSI.cyan()}   mix phoenix_kit.update --no-start#{IO.ANSI.reset()}"
    )
  end

  defp maybe_hint_no_start(_), do: :ok

  # ── Oban schema ─────────────────────────────────────────────────────────────

  # Oban's schema follows the Oban library, not PhoenixKit's chain (see
  # PhoenixKit.ObanSchema). Asked only when the database answered, same as the
  # module versions; at core's prefix and at the Oban config's when it differs.
  defp oban_schema_entries({:connected_with_tables, _version}, prefix) do
    case get_repo_with_fallback() do
      nil ->
        :not_queried

      repo ->
        oban_config = Application.get_env(Mix.Project.config()[:app], Oban)
        ObanSchema.check_all(repo, ObanSchema.targets(repo, prefix, oban_config))
    end
  end

  defp oban_schema_entries(_database_status, _prefix), do: :not_queried

  #   ├── Oban schema: v14 ✅
  #
  # Omitted when nothing was asked, or no checked prefix has an `oban_jobs`
  # table. The prefix is named only when it is not simply core's own.
  defp oban_schema_rows(:not_queried, _prefix), do: []

  defp oban_schema_rows(entries, prefix) do
    case Enum.reject(entries, fn {_prefix, status} -> status == :no_table end) do
      [] ->
        []

      [{^prefix, status}] ->
        [{"Oban schema", format_oban_schema(status)}]

      reported ->
        [
          {"Oban schema",
           Enum.map_join(reported, ", ", fn {p, status} ->
             "#{p}: #{format_oban_schema(status)}"
           end)}
        ]
    end
  end

  defp format_oban_schema({:current, :infinity}),
    do: "#{IO.ANSI.green()}v∞ ✅#{IO.ANSI.reset()}"

  defp format_oban_schema({:current, version}),
    do: "#{IO.ANSI.green()}v#{version} ✅#{IO.ANSI.reset()}"

  defp format_oban_schema({:behind, migrated, expected}),
    do: "#{IO.ANSI.yellow()}v#{migrated} ⚠ (Oban expects v#{expected})#{IO.ANSI.reset()}"

  defp format_oban_schema({:ahead, migrated, expected}),
    do: "#{IO.ANSI.yellow()}v#{migrated} (newer than this Oban, v#{expected})#{IO.ANSI.reset()}"

  defp format_oban_schema(status),
    do: "#{IO.ANSI.red()}#{ObanSchema.describe(status)}#{IO.ANSI.reset()}"

  # ── Module schema versions ──────────────────────────────────────────────────

  # `:not_queried` is deliberately distinct from `[]`. Both used to collapse to
  # an empty list, so a host with modules installed but an unreachable database
  # was told "No installed module owns migrations" — a flat falsehood that
  # sends whoever is debugging a missing table down the wrong path.
  defp module_entries({:connected_with_tables, _version}, prefix),
    do: MigrationModules.list(prefix: prefix)

  defp module_entries(_database_status, _prefix), do: :not_queried

  # Renders as a labelled row with one child line per module:
  #
  #   ├── Modules: 2 installed, 1 update available
  #   │   ├── Boards: V01 ✅
  #   │   └── Inbox: V01 → V02 ⬆
  #
  # Omitted entirely when no module owns migrations, so the common
  # core-only install keeps the compact three-line tree it had before — and
  # when the database never answered, since "we couldn't look" is already
  # covered by the Database row above.
  defp module_tree_rows(:not_queried), do: []
  defp module_tree_rows([]), do: []

  defp module_tree_rows(modules) do
    [{"Modules", format_modules_summary(modules), Enum.map(modules, &format_module_entry/1)}]
  end

  defp format_modules_summary(modules) do
    pending = MigrationModules.pending(modules)
    failed = MigrationModules.failed(modules)
    ahead = MigrationModules.ahead_of_code(modules)
    count = "#{length(modules)} #{pluralize(length(modules), "module", "modules")}"

    cond do
      failed != [] ->
        "#{IO.ANSI.red()}#{count}, #{length(failed)} unreadable ❌#{IO.ANSI.reset()}"

      # Pending and ahead-of-code are not alternatives — one run can hold
      # both, and each needs to say so: a pending module doesn't excuse an
      # ahead-of-code one from being reported, and an ahead-of-code module
      # must not push this into "all up to date" (a rollback or a
      # backwards-pinned dependency reporting healthy is exactly the defect
      # this status distinction exists to surface).
      pending != [] or ahead != [] ->
        color = if ahead != [], do: IO.ANSI.red(), else: IO.ANSI.yellow()
        "#{color}#{count}, #{module_status_summary_parts(pending, ahead)}#{IO.ANSI.reset()}"

      true ->
        "#{IO.ANSI.green()}#{count}, all up to date ✅#{IO.ANSI.reset()}"
    end
  end

  # "behind", not "updates available" — same reasoning as the core version
  # line: this is measured against the installed code, not against Hex, so
  # nothing here is an optional upgrade being offered.
  defp module_status_summary_parts(pending, ahead) do
    [
      if(pending != [], do: "#{length(pending)} behind ⚠"),
      if(ahead != [], do: "#{length(ahead)} ahead of code ⚠")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp format_module_entry(%{status: :up_to_date} = entry) do
    "#{entry.name}: #{IO.ANSI.green()}V#{pad_version(entry.installed)} ✅#{IO.ANSI.reset()}"
  end

  defp format_module_entry(%{status: :needs_update} = entry) do
    "#{entry.name}: #{IO.ANSI.yellow()}V#{pad_version(entry.installed)} ⚠ (code expects V#{pad_version(entry.target)})#{IO.ANSI.reset()}"
  end

  defp format_module_entry(%{status: :not_installed} = entry) do
    "#{entry.name}: #{IO.ANSI.yellow()}tables not created ⚠ (code expects V#{pad_version(entry.target)})#{IO.ANSI.reset()}"
  end

  defp format_module_entry(%{status: :ahead_of_code} = entry) do
    "#{entry.name}: #{IO.ANSI.red()}V#{pad_version(entry.installed)} ⚠ ahead of code (code expects V#{pad_version(entry.target)}) — rollback?#{IO.ANSI.reset()}"
  end

  defp format_module_entry(%{status: :error} = entry) do
    "#{entry.name}: #{IO.ANSI.red()}unreadable ❌#{IO.ANSI.reset()} (#{entry.error})"
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  # Get PhoenixKit module version
  defp get_phoenix_kit_version do
    case :application.get_key(:phoenix_kit, :vsn) do
      {:ok, vsn} when is_list(vsn) -> List.to_string(vsn)
      {:ok, vsn} -> to_string(vsn)
      :undefined -> "unknown"
    end
  end

  # Get installation status, with self-healing for version comment bugs
  defp get_installation_status(prefix) do
    case Common.check_installation_status(prefix) do
      {:not_installed} ->
        {:not_installed}

      {:unreachable, reason} ->
        {:unreachable, reason}

      # `status` is the task an operator runs precisely because something looks
      # wrong, so it must report this state rather than raise on it.
      {:unknown_version} ->
        {:unknown_version}

      {:current_version, version} ->
        target_version = Postgres.current_version()

        if version >= target_version do
          {:up_to_date, version}
        else
          maybe_heal_and_check(version, target_version, prefix)
        end
    end
  end

  # Attempt to heal version comment if migrations ran but comment was not updated
  defp maybe_heal_and_check(version, target_version, prefix) do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}

    case Postgres.heal_version_comment(version, opts) do
      {:healed, healed_version} ->
        IO.puts(
          "#{IO.ANSI.yellow()}[healed] Version comment corrected from V#{pad_version(version)} to V#{pad_version(healed_version)}#{IO.ANSI.reset()}"
        )

        compare_versions(healed_version, target_version)

      :ok ->
        {:needs_update, version, target_version}
    end
  end

  defp compare_versions(version, target_version) do
    if version >= target_version do
      {:up_to_date, version}
    else
      {:needs_update, version, target_version}
    end
  end

  # Get database connectivity status with hybrid repo detection
  defp get_database_status(prefix) do
    case get_repo_with_fallback() do
      nil ->
        {:no_repo_configured}

      repo ->
        test_repo_and_tables(repo, prefix)
    end
  rescue
    error -> {:error, error}
  end

  # Test repository connection and check for PhoenixKit tables
  defp test_repo_and_tables(repo, prefix) do
    case ensure_repo_started(repo) do
      :ok ->
        test_database_connection(repo, prefix)

      {:error, reason} ->
        {:connection_error, reason}
    end
  end

  # Test database connection and check tables
  defp test_database_connection(repo, prefix) do
    case SQL.query(repo, "SELECT 1", []) do
      {:ok, _result} ->
        check_phoenix_kit_tables(prefix)

      {:error, reason} ->
        {:connection_error, reason}
    end
  end

  # Helper function to check if PhoenixKit tables exist
  defp check_phoenix_kit_tables(prefix) do
    opts = %{prefix: prefix, escaped_prefix: String.replace(prefix, "'", "\\'")}
    version = Postgres.migrated_version_runtime(opts)

    if version > 0 do
      {:connected_with_tables, version}
    else
      {:connected_no_tables}
    end
  end

  # Decision lives in PhoenixKit.Install.StatusReport so it can be unit tested
  # across all five states without pointing the task at a live database.
  defp determine_next_action(installation_status, modules, prefix) do
    StatusReport.next_action(installation_status, modules, prefix)
  end

  # Format installation status for display
  defp format_installation_status({:not_installed}) do
    "#{IO.ANSI.red()}Not installed#{IO.ANSI.reset()}"
  end

  defp format_installation_status({:unreachable, _reason}) do
    "#{IO.ANSI.yellow()}Unknown — database unreachable#{IO.ANSI.reset()}"
  end

  # Installed, but the version comment is missing or unreadable. Red rather than
  # yellow: unlike an unreachable database this will not fix itself, and no other
  # task can act safely until it is restamped.
  defp format_installation_status({:unknown_version}) do
    "#{IO.ANSI.red()}Installed, version comment unreadable#{IO.ANSI.reset()}"
  end

  defp format_installation_status({:up_to_date, version}) do
    "#{IO.ANSI.green()}V#{pad_version(version)} ✅#{IO.ANSI.reset()}"
  end

  # "code expects V160", not "update available to V160". This task compares the
  # database against the version compiled into the RUNNING release — it never
  # asks Hex what exists. A gap here is therefore not an optional upgrade on
  # offer; it is the schema disagreeing with the code already querying it,
  # which surfaces as runtime errors on whatever the newer version added.
  defp format_installation_status({:needs_update, current, target}) do
    "#{IO.ANSI.yellow()}V#{pad_version(current)} ⚠ (code expects V#{pad_version(target)})#{IO.ANSI.reset()}"
  end

  # Format database status for display
  defp format_database_status({:connected_with_tables, _version}) do
    "#{IO.ANSI.green()}Connected ✅#{IO.ANSI.reset()}"
  end

  defp format_database_status({:connected_no_tables}) do
    "#{IO.ANSI.yellow()}Connected (no tables)#{IO.ANSI.reset()}"
  end

  defp format_database_status({:connection_error, _reason}) do
    "#{IO.ANSI.red()}Connection failed ❌#{IO.ANSI.reset()}"
  end

  defp format_database_status({:no_repo_configured}) do
    "#{IO.ANSI.red()}No repo configured ❌#{IO.ANSI.reset()}"
  end

  defp format_database_status({:error, _error}) do
    "#{IO.ANSI.red()}Error ❌#{IO.ANSI.reset()}"
  end

  # Format next action for display
  defp format_next_action({:install, command}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()}"
  end

  # The command alone reads like housekeeping ("there's an update, run it").
  # Stating WHY makes it what it actually is: a mismatch between the schema and
  # the code running against it. Wording comes from StatusReport.describe/1;
  # this only adds colour — the command in cyan, the reason dimmed after it.
  defp format_next_action({:update, command, []}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:update, command, reasons}) do
    "#{IO.ANSI.cyan()}#{command}#{IO.ANSI.reset()} " <>
      "#{IO.ANSI.faint()}— #{Enum.join(reasons, "; ")}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:check_modules, _names} = action) do
    "#{IO.ANSI.red()}#{StatusReport.describe(action)}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:check_oban_schema, _labels} = action) do
    "#{IO.ANSI.red()}#{StatusReport.describe(action)}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:modules_ahead_of_code, _names} = action) do
    "#{IO.ANSI.red()}#{StatusReport.describe(action)}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:ready, message}) do
    "#{IO.ANSI.green()}#{message}#{IO.ANSI.reset()}"
  end

  defp format_next_action({:fix_connection, message}) do
    "#{IO.ANSI.yellow()}#{message}#{IO.ANSI.reset()}"
  end

  # Same shape as :fix_connection — a state nothing else can act around until an
  # operator resolves it by hand.
  defp format_next_action({:fix_version_comment, message}) do
    "#{IO.ANSI.red()}#{message}#{IO.ANSI.reset()}"
  end

  # Layout lives in PhoenixKit.Install.StatusTree so it can be unit tested
  # without a database; this only supplies the ANSI label styling and prints.
  defp display_status_tree(items) do
    items
    |> StatusTree.render(label_format: &"#{IO.ANSI.bright()}#{&1}#{IO.ANSI.reset()}")
    |> IO.puts()
  end

  # Show detailed diagnostic information
  defp show_verbose_diagnostics(prefix, installation_status, database_status, modules) do
    IO.puts("\n#{IO.ANSI.bright()}═══ Detailed Diagnostics ═══#{IO.ANSI.reset()}")

    show_installation_diagnostics(installation_status, prefix)
    show_module_diagnostics(modules)
    show_database_diagnostics(database_status, prefix)
    show_configuration_diagnostics()
  end

  # Per-module detail: which coordinator reports the version, and the exact
  # numbers behind the summary line.
  defp show_module_diagnostics(:not_queried) do
    IO.puts("\n#{IO.ANSI.bright()}Modules:#{IO.ANSI.reset()}")
    IO.puts("  Not queried — the database did not answer, so module schema")
    IO.puts("  versions are unknown. This is not the same as having none.")
  end

  defp show_module_diagnostics([]) do
    IO.puts("\n#{IO.ANSI.bright()}Modules:#{IO.ANSI.reset()}")
    IO.puts("  No installed module owns migrations.")
  end

  defp show_module_diagnostics(modules) do
    IO.puts("\n#{IO.ANSI.bright()}Modules:#{IO.ANSI.reset()}")

    Enum.each(modules, fn entry ->
      IO.puts("  #{entry.name} (#{inspect(entry.module)})")
      IO.puts("    Coordinator: #{inspect(entry.migration_module)}")

      case entry.status do
        :error ->
          IO.puts("    Version: unreadable — #{entry.error}")

        _ ->
          IO.puts("    Installed: V#{pad_version(entry.installed)}")
          IO.puts("    Target: V#{pad_version(entry.target)}")
      end
    end)
  end

  # Show installation diagnostics
  defp show_installation_diagnostics(status, prefix) do
    IO.puts("\n#{IO.ANSI.bright()}Installation:#{IO.ANSI.reset()}")
    IO.puts("  Schema prefix: #{prefix}")

    case status do
      {:not_installed} ->
        IO.puts("  Migration files: #{inspect(Common.find_existing_phoenix_kit_migrations())}")

      {:unreachable, reason} ->
        IO.puts("  Database unreachable: #{inspect(reason)}")

      # The non-verbose path reports this state; without a clause here the
      # SAME run crashed with CaseClauseError the moment `--verbose` was added
      # to it — after printing a correct tree, which is the worst place to die.
      {:unknown_version} ->
        IO.puts("  Current version: unreadable — the table exists but its")
        IO.puts("  version comment is missing or is not a plain integer.")
        IO.puts("  Establish the real state and restamp it by hand:")
        IO.puts("    mix phoenix_kit.doctor")
        IO.puts("    COMMENT ON TABLE #{prefix}.phoenix_kit IS '<version>';")

      {:up_to_date, version} ->
        IO.puts("  Current version: V#{pad_version(version)}")
        IO.puts("  Target version: V#{pad_version(Postgres.current_version())}")

      {:needs_update, current, target} ->
        IO.puts("  Current version: V#{pad_version(current)}")
        IO.puts("  Target version: V#{pad_version(target)}")
        changes = Common.describe_version_changes(current, target)
        IO.puts("  Available changes:")
        String.split(changes, "\n") |> Enum.each(&IO.puts("    #{&1}"))
    end
  end

  # Show database diagnostics
  defp show_database_diagnostics(status, _prefix) do
    IO.puts("\n#{IO.ANSI.bright()}Database:#{IO.ANSI.reset()}")

    # Show how repo was detected
    show_repo_detection_info()

    case status do
      {:connected_with_tables, version} ->
        IO.puts("  Connection: OK")
        IO.puts("  PhoenixKit tables: Present (V#{pad_version(version)})")

      {:connected_no_tables} ->
        IO.puts("  Connection: OK")
        IO.puts("  PhoenixKit tables: Missing")

      {:connection_error, reason} ->
        IO.puts("  Connection: Failed")
        IO.puts("  Error: #{inspect(reason)}")

      {:no_repo_configured} ->
        IO.puts("  Connection: No repo configured")
        show_repo_fallback_attempts()

      {:error, error} ->
        IO.puts("  Connection: Error")
        IO.puts("  Details: #{inspect(error)}")
    end
  end

  # Show detailed repo detection information
  defp show_repo_detection_info do
    phoenix_kit_repo = Config.get(:repo, nil)

    IO.puts("  PhoenixKit repo config: #{inspect(phoenix_kit_repo)}")

    if phoenix_kit_repo do
      show_configured_repo_info(phoenix_kit_repo)
    else
      show_fallback_repo_info()
    end
  end

  # Show information about configured repo
  defp show_configured_repo_info(repo) do
    IO.puts("  Detection method: PhoenixKit application config")
    IO.puts("  Testing repo connection...")

    test_and_report_repo_connection(repo)
  end

  # Show information about fallback repo detection
  defp show_fallback_repo_info do
    started_repo = ensure_phoenix_kit_started()
    IO.puts("  After starting PhoenixKit app: #{inspect(started_repo)}")

    detected_repo = detect_repo_from_project()

    if detected_repo do
      show_detected_repo_info(detected_repo)
    else
      IO.puts("  No repo detected via fallback methods")
    end
  end

  # Show information about detected repo
  defp show_detected_repo_info(repo) do
    parent_app_name = Mix.Project.config()[:app]

    IO.puts("  Fallback repo detected: #{inspect(repo)}")

    # Show which method worked
    if try_ecto_repos_config(parent_app_name) do
      IO.puts("  Detection method: :ecto_repos config")
    else
      IO.puts("  Detection method: Naming pattern")
    end

    IO.puts("  Testing repo connection...")
    test_and_report_repo_connection(repo)
  end

  # Test repo connection and report results
  defp test_and_report_repo_connection(repo) do
    case test_repo_connection(repo) do
      :ok -> IO.puts("  Repo connection test: PASSED")
      {:error, reason} -> IO.puts("  Repo connection test: FAILED - #{inspect(reason)}")
    end
  end

  # Test repo connection
  defp test_repo_connection(repo) do
    # Ensure repo is started first
    case ensure_repo_started(repo) do
      :ok ->
        case SQL.query(repo, "SELECT 1", []) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  # Show fallback attempts when repo is not configured
  defp show_repo_fallback_attempts do
    parent_app_name = Mix.Project.config()[:app]

    IO.puts("  Fallback attempts:")
    IO.puts("    - PhoenixKit config: #{inspect(Config.get(:repo, nil))}")

    IO.puts(
      "    - App :ecto_repos: #{inspect(Application.get_env(parent_app_name, :ecto_repos, []))}"
    )

    if parent_app_name do
      expected_repo = Module.concat([Macro.camelize(to_string(parent_app_name)), "Repo"])
      IO.puts("    - Naming pattern (#{expected_repo}): #{ensure_repo_loaded?(expected_repo)}")
    end
  end

  # Show configuration diagnostics
  defp show_configuration_diagnostics do
    IO.puts("\n#{IO.ANSI.bright()}Configuration:#{IO.ANSI.reset()}")

    # Check layout configuration
    layout_config = PhoenixKit.Config.get(:layout)

    IO.puts(
      "  Layout integration: #{if layout_config != :not_found, do: "Configured", else: "Using defaults"}"
    )

    # Check mailer configuration
    mailer_config = PhoenixKit.Config.get(PhoenixKit.Mailer)

    IO.puts(
      "  Mailer: #{if mailer_config != :not_found, do: "Configured", else: "Not configured"}"
    )
  end

  # Hybrid repo detection with fallback strategies
  defp get_repo_with_fallback do
    # Strategy 1: Try to get from PhoenixKit application config
    case Config.get(:repo, nil) do
      nil ->
        # Strategy 2: Try to ensure PhoenixKit application is started
        case ensure_phoenix_kit_started() do
          repo when not is_nil(repo) ->
            repo

          nil ->
            # Strategy 3: Auto-detect from project configuration
            detect_repo_from_project()
        end

      repo ->
        repo
    end
  end

  # Try to start PhoenixKit application and get repo config
  defp ensure_phoenix_kit_started do
    Application.ensure_all_started(:phoenix_kit)
    Config.get(:repo, nil)
  rescue
    _ -> nil
  end

  # Auto-detect repository from project configuration (similar to RepoDetection)
  defp detect_repo_from_project do
    parent_app_name = Mix.Project.config()[:app]

    # Try :ecto_repos config first
    case try_ecto_repos_config(parent_app_name) do
      nil -> try_naming_patterns(parent_app_name)
      repo -> repo
    end
  end

  # Try to get repo from :ecto_repos application config
  defp try_ecto_repos_config(nil), do: nil

  defp try_ecto_repos_config(app_name) do
    case Application.get_env(app_name, :ecto_repos, []) do
      [repo | _] when is_atom(repo) ->
        if ensure_repo_loaded?(repo), do: repo, else: nil

      [] ->
        nil
    end
  rescue
    _ -> nil
  end

  # Try common naming patterns
  defp try_naming_patterns(nil), do: nil

  defp try_naming_patterns(app_name) do
    # Try most common pattern: AppName.Repo
    repo_module = Module.concat([Macro.camelize(to_string(app_name)), "Repo"])

    if ensure_repo_loaded?(repo_module) do
      repo_module
    else
      nil
    end
  end

  # Check if repo module exists and is loaded
  defp ensure_repo_loaded?(repo) when is_atom(repo) and not is_nil(repo) do
    Code.ensure_loaded?(repo) && function_exported?(repo, :__adapter__, 0)
  rescue
    _ -> false
  end

  defp ensure_repo_loaded?(_), do: false

  # Ensure repo is properly started for database operations.
  # Since we use --no-start, the repo may not be running yet.
  # We start repo with its application config so it gets the connection params.
  defp ensure_repo_started(repo) do
    if repo_available?(repo) do
      :ok
    else
      parent_app = Mix.Project.config()[:app]
      config = Application.get_env(parent_app, repo, [])

      case repo.start_link(config) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, "Failed to start #{inspect(repo)}: #{inspect(reason)}"}
      end
    end
  end

  # Check if repo module is available and started
  defp repo_available?(repo) do
    Code.ensure_loaded?(repo) &&
      function_exported?(repo, :__adapter__, 0) &&
      Process.whereis(repo) != nil
  rescue
    _ -> false
  end

  # Pad version number for consistent display
  defp pad_version(version) when version < 10, do: "0#{version}"
  defp pad_version(version), do: to_string(version)
end
