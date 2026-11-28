defmodule PhoenixKit.Console.Boot do
  @moduledoc false
  # The Repo-only boot of `mix phoenix_kit.settings` / `mix phoenix_kit.modules`: the host's
  # code and config are loaded, its application is NOT started (no endpoint, no Oban, no
  # pollers or bots), and only what the console functions need runs: the database drivers,
  # the host's repo with a pool of two, the kit's PubSub, cache registry, settings cache and
  # module registry.

  @doc false
  @spec start!() :: :ok
  def start! do
    Mix.Task.run("app.start", ["--no-start"])

    for app <- [:ssl, :postgrex, :ecto_sql] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    # `:phoenix_kit`'s own application callback only warms the Gettext catalogue.
    {:ok, _} = Application.ensure_all_started(:phoenix_kit)

    repo = PhoenixKit.RepoHelper.repo()
    started(repo.start_link(pool_size: 2))

    children = [
      PhoenixKit.PubSub.Manager,
      {PhoenixKit.Cache.Registry, []},
      Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache),
      PhoenixKit.ModuleRegistry
    ]

    for child <- children, do: started(start_child(child))
    :ok
  end

  defp start_child(child) do
    %{start: {module, function, args}} = Supervisor.child_spec(child, [])
    apply(module, function, args)
  end

  defp started({:ok, _pid}), do: :ok
  defp started({:error, {:already_started, _pid}}), do: :ok
  defp started(:ignore), do: :ok

  defp started(other),
    do: Mix.raise("PhoenixKit: could not start what the console needs: #{inspect(other)}")
end
