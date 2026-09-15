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

    {opts, _argv, errors} = OptionParser.parse(argv, strict: @switches)

    case List.keyfind(errors, "--pending-days", 0) do
      {_switch, value} ->
        Mix.raise("--pending-days must be a positive integer, got: #{inspect(value)}")

      nil ->
        :ok
    end

    Enum.each(errors, fn {switch, value} ->
      Mix.shell().error(
        "Ignoring unrecognized/invalid option #{switch}#{format_bad_value(value)}"
      )
    end)

    apply? = opts[:apply] || false
    source_keys = Keyword.get_values(opts, :source)
    sources = if source_keys == [], do: :all, else: source_keys
    pending_days = validate_pending_days!(opts[:pending_days])

    actor_uuid = first_owner_uuid()

    {:ok, report} =
      Reorganizer.run(actor_uuid, apply?: apply?, sources: sources, pending_days: pending_days)

    Mix.shell().info("\n" <> Reorganizer.format_report(report))

    halt_with(exit_code(report, apply?))
  end

  defp format_bad_value(nil), do: ""
  defp format_bad_value(value), do: " #{inspect(value)}"

  defp validate_pending_days!(nil), do: 7

  defp validate_pending_days!(days) when is_integer(days) and days >= 1, do: days

  defp validate_pending_days!(days) do
    Mix.raise("--pending-days must be a positive integer, got: #{inspect(days)}")
  end

  defp first_owner_uuid do
    case Roles.users_with_role("Owner") do
      [%{uuid: uuid} | _] -> uuid
      _ -> nil
    end
  end

  @doc false
  # 0 on a dry-run (nothing was ever going to be written) or a clean
  # `--apply`; 1 once `--apply` leaves anything `:failed`/`:conflict`.
  @spec exit_code(%{actions: [map()]}, boolean()) :: 0 | 1
  def exit_code(_report, false), do: 0

  def exit_code(%{actions: actions}, true) do
    if Enum.any?(actions, &(Map.get(&1, :outcome) in [:failed, :conflict])) do
      1
    else
      0
    end
  end

  defp halt_with(0), do: :ok
  defp halt_with(code), do: exit({:shutdown, code})
end
