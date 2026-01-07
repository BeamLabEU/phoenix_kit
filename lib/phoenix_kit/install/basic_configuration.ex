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
end
