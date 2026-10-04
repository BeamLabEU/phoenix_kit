defmodule PhoenixKit.Jobs.System do
  @moduledoc """
  The trusted door into job runs, for callers that are **not a person**: the boot
  sequence, a cron entry, a Mix task, a trigger such as a profile's revision
  changing.

  A separate module from `PhoenixKit.Jobs` on purpose. `Jobs.start/4` takes a
  `Scope`, checks `jobs.manage` against the active role and attributes the run to
  that person; here there is no one to check and no one to blame, and the mode is
  stated by the caller — `:auto` (code reacting to something), `:cron` (a
  schedule) or `:script` (a Mix task or console). A missing actor in the user door
  can never be read as "the system", because the two are different functions.

  Only call this from code that is itself trusted; never pass user input as the
  kind or the mode. It is public API on purpose: code already running in the VM
  can call anything, so hiding it would not make an authorization boundary — the
  boundary is that user-facing paths pass a `Scope` to `PhoenixKit.Jobs`, which
  checks it. The same holds for `PhoenixKit.Jobs.run_inline/3`.
  """

  alias PhoenixKit.Jobs.Engine

  @modes ~w(auto cron script)a

  @doc """
  Starts a run of `kind`, or returns the one already active. Options: `:args`,
  `:mode` (`:auto` by default), `:source` (a short phrase for the history, kept
  in the run's args as `"source"`).

  `{:error, :raced}` means the trigger was not recorded (the active run finished
  as this one arrived, three times over): try again. `{:error, :in_transaction}`
  means it was called inside the caller's own transaction: call it after the commit.
  """
  @spec start(module(), PhoenixKit.Jobs.run_scope(), keyword()) ::
          {:ok, PhoenixKit.Jobs.Run.t(), :started | :existing} | {:error, term()}
  def start(kind, run_scope \\ :site, opts \\ []) do
    mode = Keyword.get(opts, :mode, :auto)

    if mode in @modes do
      args =
        opts
        |> Keyword.get(:args, %{})
        |> then(fn args ->
          if source = opts[:source], do: Map.put(args, "source", source), else: args
        end)

      Engine.start(
        kind,
        normalize(run_scope),
        args: args,
        mode: Atom.to_string(mode),
        actor_uuid: nil
      )
    else
      {:error, :invalid_mode}
    end
  end

  defp normalize(:site), do: :site
  defp normalize({type, uuid}), do: {to_string(type), to_string(uuid)}
end
