defmodule PhoenixKit.Install.StatusReport do
  @moduledoc """
  Decides what `mix phoenix_kit.status` should tell the operator to do next.

  Extracted from the status task for the same reason `PhoenixKit.Install.StatusTree`
  was: it is pure decision logic that could otherwise only be observed by
  pointing the task at a live database in each of five states, so in practice
  it went unverified.

  The task keeps the ANSI styling; this module returns plain data.

  ## Why the wording matters

  `status` compares the schema in the database against the version compiled
  into the **running release** (`PhoenixKit.Migrations.Postgres.current_version/0`).
  It never asks Hex what exists. So it can never report "a newer PhoenixKit is
  available" — it can only report that the database disagrees with the code
  already querying it, which surfaces as runtime errors on whatever the newer
  version added.

  That is why nothing here says "update available": there is no optional
  upgrade being offered, only a mismatch to reconcile.
  """

  alias PhoenixKit.Migrations.Modules, as: MigrationModules

  @typedoc """
  What the operator should do.

    * `{:install, command}` — PhoenixKit has never been installed
    * `{:fix_connection, message}` — the database could not be reached
    * `{:fix_version_comment, message}` — installed, but the version comment is
      missing or unreadable; the fix is a restamp by hand, not an update
    * `{:update, command, reasons}` — schema behind the code; `reasons` says how
    * `{:check_modules, names}` — a module's version could not be read
    * `{:modules_ahead_of_code, names}` — a module's database schema is newer
      than the code now running (a rollback, or a dependency pinned backwards)
    * `{:ready, message}` — database and code agree
  """
  @type action ::
          {:install, String.t()}
          | {:fix_connection, String.t()}
          | {:fix_version_comment, String.t()}
          | {:update, String.t(), [String.t()]}
          | {:check_modules, [String.t()]}
          | {:modules_ahead_of_code, [String.t()]}
          | {:ready, String.t()}

  @doc """
  Picks the action for a given installation status and module list.

  `modules` is a `PhoenixKit.Migrations.Modules.list/1` result, or
  `:not_queried` when the database was unreachable and nothing was asked.

  ## Examples

      iex> alias PhoenixKit.Install.StatusReport
      iex> StatusReport.next_action({:up_to_date, 159}, [], "public")
      {:ready, "Ready"}

      iex> alias PhoenixKit.Install.StatusReport
      iex> StatusReport.next_action({:needs_update, 159, 160}, [], "public")
      {:update, "mix phoenix_kit.update", ["database is V159, code expects V160"]}
  """
  @spec next_action(tuple(), [map()] | :not_queried, String.t()) :: action()
  def next_action(installation_status, modules, prefix)

  def next_action({:not_installed}, _modules, _prefix) do
    {:install, "mix igniter.install phoenix_kit"}
  end

  def next_action({:unreachable, _reason}, _modules, _prefix) do
    {:fix_connection, "Fix the database connection, then re-run mix phoenix_kit.status"}
  end

  # Installed, but the version comment is missing or not a plain integer. The
  # action is a restamp, not an update: every other task reads that comment, so
  # until it says something true none of them can act safely. `doctor` first,
  # because it is what establishes the real version to stamp.
  def next_action({:unknown_version}, _modules, prefix) do
    {:fix_version_comment,
     "mix phoenix_kit.doctor — then COMMENT ON TABLE #{prefix}.phoenix_kit IS '<version>'"}
  end

  # Core behind. Modules fold into the SAME action rather than being ignored:
  # one `mix phoenix_kit.update` fixes both, and an operator told only
  # "database is behind" would fix core, re-run, and meet a second finding that
  # was already knowable here.
  def next_action({:needs_update, current, target}, modules, prefix) do
    {:update, update_command(prefix), [core_reason(current, target) | module_reasons(modules)]}
  end

  def next_action({:up_to_date, _version}, :not_queried, _prefix) do
    {:ready, "Ready"}
  end

  def next_action({:up_to_date, _version}, modules, prefix) do
    failed = MigrationModules.failed(modules)
    ahead = MigrationModules.ahead_of_code(modules)
    pending = MigrationModules.pending(modules)

    cond do
      # An unreadable module is NOT pending — migrating a module whose version
      # we cannot read would be worse than leaving it. But it must not report
      # "Ready" either: its tables may well be behind, and "1 unreadable ❌"
      # one line above "Next: Ready" tells the operator there is nothing to do.
      failed != [] ->
        {:check_modules, Enum.map(failed, & &1.name)}

      # `pending` takes priority over `ahead`: an ahead-of-code module does
      # not stop `mix phoenix_kit.update` from fixing a *different* module
      # that is genuinely behind, so this must still point at that command —
      # `module_reasons/1` (full list, not the already-filtered `pending`)
      # folds the ahead module in as an extra reason rather than dropping it.
      pending != [] ->
        {:update, update_command(prefix), module_reasons(modules)}

      # Not pending — there is nothing for `mix phoenix_kit.update` to run —
      # but it is exactly the failure this whole distinction exists to
      # surface: folding it into "Ready" would hide a rollback behind the
      # same message a healthy install gets.
      ahead != [] ->
        {:modules_ahead_of_code, Enum.map(ahead, & &1.name)}

      true ->
        {:ready, "Ready"}
    end
  end

  @doc """
  The command an action asks for, or `nil` when it isn't a command.

      iex> PhoenixKit.Install.StatusReport.command({:update, "mix phoenix_kit.update", []})
      "mix phoenix_kit.update"
  """
  @spec command(action()) :: String.t() | nil
  def command({:install, command}), do: command
  def command({:update, command, _reasons}), do: command
  def command(_action), do: nil

  @doc """
  Plain-text rendering, no ANSI — what the task colours and prints.

      iex> PhoenixKit.Install.StatusReport.describe({:ready, "Ready"})
      "Ready"

      iex> PhoenixKit.Install.StatusReport.describe(
      ...>   {:update, "mix phoenix_kit.update", ["database is V159, code expects V160"]}
      ...> )
      "mix phoenix_kit.update — database is V159, code expects V160"
  """
  @spec describe(action()) :: String.t()
  def describe({:install, command}), do: command
  def describe({:fix_connection, message}), do: message
  def describe({:ready, message}), do: message
  def describe({:update, command, []}), do: command
  def describe({:update, command, reasons}), do: command <> " — " <> Enum.join(reasons, "; ")

  def describe({:check_modules, names}) do
    "Check the unreadable module(s): " <>
      Enum.join(names, ", ") <> " (schema version unknown — run with --verbose)"
  end

  def describe({:modules_ahead_of_code, names}) do
    "Module(s) ahead of code: " <>
      Enum.join(names, ", ") <>
      " (database schema is newer than the running code — rollback or a backwards-pinned dependency?)"
  end

  @doc """
  Folds an Oban schema that is behind its library into `action`.

  `oban` is a list of `{prefix, PhoenixKit.ObanSchema.status()}`, or
  `:not_queried`. Oban's schema is not part of PhoenixKit's chain, but
  `mix phoenix_kit.update` is what steps it up — so a host whose core is
  current and whose Oban schema is behind is not "Ready": every unique insert
  fails. States that need a person first (install, connection, an unreadable
  version) keep their action.

      iex> alias PhoenixKit.Install.StatusReport
      iex> StatusReport.with_oban_schema({:ready, "Ready"}, [{"public", {:behind, 13, 14}}], "public")
      {:update, "mix phoenix_kit.update", ["Oban schema at public is v13, Oban expects v14"]}

      iex> alias PhoenixKit.Install.StatusReport
      iex> StatusReport.with_oban_schema({:ready, "Ready"}, [{"public", {:current, 14}}], "public")
      {:ready, "Ready"}
  """
  @spec with_oban_schema(action(), [{String.t(), term()}] | :not_queried, String.t()) :: action()
  def with_oban_schema(action, :not_queried, _prefix), do: action

  def with_oban_schema(action, oban, prefix) when is_list(oban) do
    behind =
      for {oban_prefix, {:behind, from, to}} <- oban,
          do: "Oban schema at #{oban_prefix} is v#{from}, Oban expects v#{to}"

    case {action, behind} do
      {_action, []} -> action
      {{:update, command, reasons}, _} -> {:update, command, reasons ++ behind}
      {{:ready, _message}, _} -> {:update, update_command(prefix), behind}
      _ -> action
    end
  end

  @doc "The `mix phoenix_kit.update` invocation for a prefix."
  @spec update_command(String.t()) :: String.t()
  def update_command("public"), do: "mix phoenix_kit.update"
  def update_command(prefix), do: "mix phoenix_kit.update --prefix=#{prefix}"

  defp core_reason(current, target) do
    "database is V#{pad(current)}, code expects V#{pad(target)}"
  end

  # Accepts a raw module list, an already-filtered pending list, or
  # `:not_queried` (database unreachable, so nothing was asked).
  defp module_reasons(:not_queried), do: []

  defp module_reasons(modules) when is_list(modules) do
    pending_reason =
      case MigrationModules.pending(modules) do
        [] -> []
        pending -> ["module schema behind: " <> Enum.map_join(pending, ", ", & &1.name)]
      end

    ahead_reason =
      case MigrationModules.ahead_of_code(modules) do
        [] -> []
        ahead -> ["module schema ahead of code: " <> Enum.map_join(ahead, ", ", & &1.name)]
      end

    pending_reason ++ ahead_reason
  end

  defp pad(version) when is_integer(version) and version < 10, do: "0#{version}"
  defp pad(version), do: to_string(version)
end
