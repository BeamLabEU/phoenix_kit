defmodule Mix.Tasks.PhoenixKit.Modules do
  @moduledoc """
  Lists PhoenixKit modules and switches them on and off from the console, the way the
  admin Modules page does (`PhoenixKit.Console`).

      $ mix phoenix_kit.modules list
      $ mix phoenix_kit.modules enable crawlers
      $ mix phoenix_kit.modules disable sitemap

  ## Options

    * `--yes` - required for `enable` and `disable` when `MIX_ENV=prod`.

  ## How it runs

  It starts the host's repo (pool of two) and the few kit processes the switch needs, not
  the host application: no endpoint, Oban, pollers or bots. A running node sees the change
  when its cached value expires or it restarts. In a release (no `mix`), call
  `PhoenixKit.Console` inside the running node instead, which takes effect at once:

      $ bin/my_app rpc 'PhoenixKit.Console.module_enable("crawlers") |> IO.inspect()'

  Each switch is a permanent `module.enabled` / `module.disabled` activity entry (mode
  `"console"`). Exits 0 on success, 1 on any refusal or error.
  """

  use Mix.Task

  alias PhoenixKit.Console
  alias PhoenixKit.Console.Boot

  @shortdoc "Lists PhoenixKit modules and enables or disables one"

  @switches [yes: :boolean]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {_opts, _args, [_ | _] = errors} ->
        halt_with_error(
          "Invalid options: " <> Enum.map_join(errors, ", ", fn {switch, _} -> switch end)
        )

      {opts, args, []} ->
        case command(args, opts) do
          {:ok, command} ->
            Boot.start!()
            execute(command)

          {:error, message} ->
            halt_with_error(message)
        end
    end
  end

  @doc false
  # The parsed command, checked before anything is started. Public for the tests.
  @spec command([String.t()], keyword(), keyword()) :: {:ok, tuple()} | {:error, String.t()}
  def command(args, opts, env \\ []) do
    prod? = Keyword.get(env, :mix_env, Mix.env()) == :prod

    case args do
      ["list"] ->
        {:ok, :list}

      [action, key] when action in ["enable", "disable"] ->
        if prod? and not Keyword.get(opts, :yes, false),
          do: {:error, "MIX_ENV=prod: pass --yes to #{action} a module of this install."},
          else: {:ok, {String.to_existing_atom(action), key}}

      _ ->
        {:error, "Usage: mix phoenix_kit.modules list | enable KEY | disable KEY [--yes]"}
    end
  end

  @doc false
  # The work after the boot; separate so the tests run it against the sandboxed repo.
  @spec execute(tuple() | atom()) :: :ok
  def execute(:list) do
    for %{key: key, name: name, enabled: enabled} <- Console.modules_list() do
      Mix.shell().info("#{if enabled, do: "on ", else: "off"}  #{key}  (#{name})")
    end

    :ok
  end

  def execute({:enable, key}), do: report(key, Console.module_enable(key))
  def execute({:disable, key}), do: report(key, Console.module_disable(key))

  defp report(key, {:ok, state}), do: Mix.shell().info("#{key}: #{state}")

  defp report(key, {:error, :unknown_module}),
    do:
      halt_with_error(
        "Unknown module #{inspect(key)}. `mix phoenix_kit.modules list` shows the known keys."
      )

  defp report(key, {:error, {:requires, other}}),
    do: halt_with_error("#{key} needs the #{other} module; enable #{other} first.")

  defp report(key, {:error, reason}),
    do: halt_with_error("#{key} was not switched: #{inspect(reason)}")

  defp halt_with_error(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
