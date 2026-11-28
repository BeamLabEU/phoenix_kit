defmodule Mix.Tasks.PhoenixKit.Settings do
  @moduledoc """
  Reads and writes PhoenixKit settings from the console, through the same validation as
  the admin settings pages (`PhoenixKit.Console`).

      $ mix phoenix_kit.settings list
      $ mix phoenix_kit.settings get project_title
      $ mix phoenix_kit.settings set project_title "Acme Print"
      $ mix phoenix_kit.settings set oauth_github_client_secret --stdin < secret.txt

  Only the keys the settings forms own are known (`PhoenixKit.Settings.form_setting_keys/0`);
  any other key is refused. A secret is never printed. `--stdin` reads the value from the
  first line of standard input, so it stays out of the shell history.

  ## Options

    * `--stdin` - `set` reads the value from standard input instead of the command line.
    * `--yes` - required for `set` when `MIX_ENV=prod`.

  ## How it runs

  It starts the host's repo (pool of two) and the few kit processes the settings need, not
  the host application: no endpoint, Oban, pollers or bots. A running node sees the change
  when its cached value expires or it restarts. In a release (no `mix`), call
  `PhoenixKit.Console` inside the running node instead, which takes effect at once:

      $ bin/my_app rpc 'PhoenixKit.Console.settings_set("project_title", "Acme") |> IO.inspect()'

  Each change is recorded in the settings history with source `"console"`. Exits 0 on
  success, 1 on any refusal or error.
  """

  use Mix.Task

  alias PhoenixKit.Console
  alias PhoenixKit.Console.Boot

  @shortdoc "Lists, reads and writes PhoenixKit settings"

  @switches [stdin: :boolean, yes: :boolean]

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

      ["get", key] ->
        {:ok, {:get, key}}

      ["set" | rest] ->
        with :ok <- confirm(prod?, opts),
             {:ok, key, value} <- set_value(rest, opts, env) do
          {:ok, {:set, key, value}}
        end

      _ ->
        {:error, usage()}
    end
  end

  defp confirm(true, opts),
    do:
      if(opts[:yes],
        do: :ok,
        else: {:error, "MIX_ENV=prod: pass --yes to change a setting of this install."}
      )

  defp confirm(false, _opts), do: :ok

  defp set_value([key], opts, env) do
    if opts[:stdin] do
      reader = Keyword.get(env, :read_line, fn -> IO.read(:stdio, :line) end)

      case reader.() do
        line when is_binary(line) -> {:ok, key, String.trim_trailing(line, "\n")}
        _ -> {:error, "--stdin: nothing was read from standard input."}
      end
    else
      {:error, usage()}
    end
  end

  defp set_value([key, value], opts, _env) do
    if opts[:stdin],
      do: {:error, "Pass the value either on the command line or with --stdin, not both."},
      else: {:ok, key, value}
  end

  defp set_value(_rest, _opts, _env), do: {:error, usage()}

  defp usage do
    "Usage: mix phoenix_kit.settings list | get KEY | set KEY VALUE | set KEY --stdin [--yes]"
  end

  @doc false
  # The work after the boot; separate so the tests run it against the sandboxed repo.
  @spec execute(tuple() | atom()) :: :ok
  def execute(:list) do
    for %{key: key, value: value} <- Console.settings_list() do
      Mix.shell().info("#{key} = #{format(value)}")
    end

    :ok
  end

  def execute({:get, key}) do
    case Console.settings_get(key) do
      {:ok, value} -> Mix.shell().info(format(value))
      {:error, :unknown_key} -> unknown(key)
    end
  end

  def execute({:set, key, value}) do
    case Console.settings_set(key, value) do
      {:ok, stored} ->
        Mix.shell().info("#{key} = #{format(stored)}")

      {:error, :unknown_key} ->
        unknown(key)

      {:error, %Ecto.Changeset{} = changeset} ->
        halt_with_error("#{key} was not saved: " <> errors(changeset))
    end
  end

  defp unknown(key) do
    halt_with_error(
      "Unknown setting #{inspect(key)}. `mix phoenix_kit.settings list` shows the known keys."
    )
  end

  defp format(:secret), do: "(secret, not shown)"
  defp format(nil), do: "(not set)"
  defp format(value), do: inspect(value)

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp halt_with_error(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
