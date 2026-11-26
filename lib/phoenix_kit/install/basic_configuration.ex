# Igniter-only helper: every caller is a `mix phoenix_kit.*` igniter task,
# which is itself guarded the same way. Igniter is an OPTIONAL dependency
# (see mix.exs), so a host that scopes it to `only: [:dev, :test]` compiles
# :prod without it — unguarded, this module emitted a wall of
# "Igniter.X is undefined" warnings on every production build.
if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixKit.Install.BasicConfiguration do
    @moduledoc """
    Installation helper for adding PhoenixKit supervisor to parent application.
    Used by `mix phoenix_kit.install` task.
    """
    alias Igniter.Project.Config

    alias PhoenixKit.Install.IgniterHelpers

    @doc """
    Adds basic PhoenixKit configuration to the parent application.

    Configures the parent app name and module in config.exs for PhoenixKit integration.
    """
    def add_basic_config(igniter) do
      parent_app_name = IgniterHelpers.get_parent_app_name(igniter)
      parent_module = Igniter.Project.Module.module_name_prefix(igniter)

      igniter
      |> Config.configure_new(
        "config.exs",
        :phoenix_kit,
        [:parent_app_name],
        parent_app_name
      )
      |> Config.configure_new(
        "config.exs",
        :phoenix_kit,
        [:parent_module],
        parent_module
      )
      |> Config.configure_new(
        "config.exs",
        :phoenix_kit,
        [:url_prefix],
        "/phoenix_kit"
      )
    end

    @doc """
    The defaults a NEW application gets that an upgraded one does not: `mix phoenix_kit.install`
    calls this, `mix phoenix_kit.update` never does (an existing host keeps today's behaviour
    unless it opts in).

      * `hide_disabled_routes: true` - the root files of a switched-off module answer `404`
        (`PhoenixKit.Config.hide_disabled_routes?/0`).
    """
    def add_new_app_defaults(igniter) do
      Config.configure_new(igniter, "config.exs", :phoenix_kit, [:hide_disabled_routes], true)
    end
  end
end
