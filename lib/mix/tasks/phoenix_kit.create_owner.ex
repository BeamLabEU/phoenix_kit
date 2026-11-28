defmodule Mix.Tasks.PhoenixKit.CreateOwner do
  @moduledoc """
  Creates the first Owner of a PhoenixKit install — or makes an existing
  account the Owner — from the command line.

  A fresh install has no Owner, and public sign-up no longer makes the first
  registrant one (see `PhoenixKit.Users.Setup`). This task is the console way
  in: it creates a confirmed, active account holding the Owner role, through
  the repo the host configured (`config :phoenix_kit, repo:`).

  ## Usage

      $ mix phoenix_kit.create_owner you@example.com
      $ mix phoenix_kit.create_owner you@example.com --password-stdin < secret.txt
      $ mix phoenix_kit.create_owner second@example.com --force

  When an account with the address already exists, it is promoted: confirmed,
  activated and given the Owner role; its password stays as it is unless one
  is passed.

  ## The password

  By default a random password is generated and printed **once**, so it never
  lands in the shell history. Sign in with it and change it. Alternatives:

    * `--password-stdin` — read the password from the first line of standard
      input (a pipe or a file; nothing in the history).
    * `--password PASSWORD` — on the command line. Works, but the password is
      then in your shell history and visible to `ps` while the task runs.

  ## Options

    * `--force` — also when an active Owner already exists (adds another).
      Without it the task refuses and exits 1.
    * `--password-stdin`, `--password` — see above.

  ## In a release

  A release has no `mix`. Call the function the task uses, inside the running
  node (`rpc`, so the repo is already started):

      $ bin/my_app rpc 'PhoenixKit.Users.Setup.create_owner("you@example.com") |> IO.inspect()'

  The result carries the generated password. Options are the same keywords:
  `PhoenixKit.Users.Setup.create_owner("you@example.com", force: true)`.

  Exits 0 on success, 1 on any refusal or error.
  """

  use Mix.Task

  alias PhoenixKit.Users.Setup
  alias PhoenixKit.Utils.Routes

  @shortdoc "Creates the first PhoenixKit Owner (or promotes an account to Owner)"

  @switches [force: :boolean, password: :string, password_stdin: :boolean]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [email], []} ->
        case read_password(opts) do
          {:ok, password} ->
            Mix.Task.run("app.start")
            create(email, Keyword.put(opts, :password, password))

          {:error, message} ->
            halt_with_error(message)
        end

      {_opts, _args, [_ | _] = errors} ->
        halt_with_error(
          "Invalid options: " <> Enum.map_join(errors, ", ", fn {switch, _} -> switch end)
        )

      {_opts, _args, []} ->
        halt_with_error("Usage: mix phoenix_kit.create_owner EMAIL [--password-stdin] [--force]")
    end
  end

  defp read_password(opts) do
    cond do
      opts[:password_stdin] && opts[:password] ->
        {:error, "Pass either --password or --password-stdin, not both."}

      opts[:password_stdin] ->
        case IO.read(:stdio, :line) do
          line when is_binary(line) and line != "" -> {:ok, String.trim_trailing(line, "\n")}
          _ -> {:error, "--password-stdin: nothing was read from standard input."}
        end

      is_binary(opts[:password]) ->
        Mix.shell().info(
          "Note: a password given with --password stays in your shell history. " <>
            "Consider --password-stdin or the generated password next time."
        )

        {:ok, opts[:password]}

      true ->
        {:ok, nil}
    end
  end

  @doc false
  # The work after `app.start`; separate so the tests run it against the
  # sandboxed repo without starting a host application.
  @spec create(String.t(), keyword()) :: :ok
  def create(email, opts) do
    case Setup.create_owner(email, Keyword.take(opts, [:password, :force])) do
      {:ok, %{user: user, created: created?, password: password}} ->
        Mix.shell().info(success_message(user, created?, password, opts[:password]))

      {:error, :owner_exists} ->
        halt_with_error(
          "An active Owner already exists. Nothing was changed. " <>
            "Pass --force to make #{email} an Owner as well."
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        halt_with_error("Could not create the Owner: " <> changeset_errors(changeset))

      {:error, reason} ->
        halt_with_error("Could not create the Owner: #{inspect(reason)}")
    end
  end

  defp success_message(user, created?, password, given_password) do
    what = if created?, do: "Created Owner account", else: "Made Owner"
    login = safe_url("/users/log-in")

    password_line =
      cond do
        created? and is_nil(given_password) ->
          "\n  Password: #{password}\n  (shown once — sign in and change it)"

        is_binary(given_password) ->
          "\n  Password: the one you passed"

        true ->
          "\n  Password: unchanged"
      end

    "#{what}: #{user.email}#{password_line}\n  Sign in: #{login}"
  end

  # The URL comes from the `site_url` setting or the endpoint; a console
  # without either still gets the prefixed path.
  defp safe_url(path) do
    Routes.url(path, locale: :none)
  rescue
    _ -> Routes.path(path, locale: :none)
  end

  defp changeset_errors(changeset) do
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
