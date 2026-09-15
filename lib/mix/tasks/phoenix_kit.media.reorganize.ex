defmodule Mix.Tasks.PhoenixKit.Media.Reorganize do
  @moduledoc """
  Moves every module's legacy media folders to where the host's
  `attachments_parent_folder` / `attachments_folder_name` hooks now put new
  ones.

  Dry-run by default — prints the report and writes nothing. `--apply` runs
  it for real, each action in its own transaction; nothing is ever
  hard-deleted and the run never halts on a single failure.

  ## Usage

      $ mix phoenix_kit.media.reorganize
      $ mix phoenix_kit.media.reorganize --apply
      $ mix phoenix_kit.media.reorganize --source catalogue --source crm
      $ mix phoenix_kit.media.reorganize --pending-days 14

  ## Options

    * `--apply` - Apply the planned actions (default: dry-run)
    * `--source` - Only plan this module key (repeatable; default: all
      enabled modules)
    * `--pending-days` - Age threshold for stale pending folders (default: 7)

  Exits `1` when `--apply` leaves any action `:failed` or `:conflict`.
  """

  use Mix.Task

  alias PhoenixKit.Modules.Storage.Reorganizer
  alias PhoenixKit.Users.Roles

  @shortdoc "Move legacy media folders to where the host's hooks now put new ones"

  @switches [apply: :boolean, source: [:string, :keep], pending_days: :integer]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)
    apply? = opts[:apply] || false
    source_keys = Keyword.get_values(opts, :source)
    sources = if source_keys == [], do: :all, else: source_keys
    pending_days = opts[:pending_days] || 7

    actor_uuid = first_owner_uuid()

    {:ok, report} =
      Reorganizer.run(actor_uuid, apply?: apply?, sources: sources, pending_days: pending_days)

    Mix.shell().info("\n" <> Reorganizer.format_report(report))

    maybe_halt(report, apply?)
  end

  defp first_owner_uuid do
    case Roles.users_with_role("Owner") do
      [%{uuid: uuid} | _] -> uuid
      _ -> nil
    end
  end

  defp maybe_halt(_report, false), do: :ok

  defp maybe_halt(%{actions: actions}, true) do
    if Enum.any?(actions, &(Map.get(&1, :outcome) in [:failed, :conflict])) do
      exit({:shutdown, 1})
    else
      :ok
    end
  end
end
