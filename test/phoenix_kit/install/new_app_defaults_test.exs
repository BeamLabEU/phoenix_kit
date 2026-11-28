defmodule PhoenixKit.Install.NewAppDefaultsTest do
  @moduledoc """
  `BasicConfiguration.add_new_app_defaults/1`: what `mix phoenix_kit.install` writes for a
  new application only. `mix phoenix_kit.update` never calls it, so an upgraded host keeps
  today's behaviour.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixKit.Install.BasicConfiguration

  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  test "a new application gets hide_disabled_routes: true" do
    igniter =
      test_project(app_name: :my_app)
      |> BasicConfiguration.add_new_app_defaults()
      |> apply_igniter!()

    assert content(igniter, "config/config.exs") =~ "hide_disabled_routes: true"
  end

  test "a value the host already chose is kept" do
    igniter =
      test_project(
        app_name: :my_app,
        files: %{
          "config/config.exs" =>
            "import Config\nconfig :phoenix_kit, hide_disabled_routes: false\n"
        }
      )
      |> BasicConfiguration.add_new_app_defaults()
      |> apply_igniter!()

    config = content(igniter, "config/config.exs")
    assert config =~ "hide_disabled_routes: false"
    refute config =~ "hide_disabled_routes: true"
  end

  test "the updater never writes it" do
    source = File.read!(Path.expand("../../../lib/mix/tasks/phoenix_kit.update.ex", __DIR__))
    refute source =~ "add_new_app_defaults"
    refute source =~ "hide_disabled_routes"
  end
end
