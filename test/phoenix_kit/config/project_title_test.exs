defmodule PhoenixKit.Config.ProjectTitleTest do
  # Global application env.
  use ExUnit.Case, async: false

  import Igniter.Test

  alias PhoenixKit.Config
  alias PhoenixKit.Install.InstallDefaults

  setup do
    previous = Application.fetch_env(:phoenix_kit, :project_title)
    previous_app = Application.fetch_env(:phoenix_kit, :parent_app_name)

    on_exit(fn ->
      restore(:project_title, previous)
      restore(:parent_app_name, previous_app)
    end)

    :ok
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:phoenix_kit, key, value)
  defp restore(key, :error), do: Application.delete_env(:phoenix_kit, key)

  describe "project_title/0" do
    # An upgraded host that never set the key keeps the old name.
    test "unset stays \"PhoenixKit\"" do
      Application.delete_env(:phoenix_kit, :project_title)
      assert Config.project_title() == "PhoenixKit"
    end

    test "a configured string is used as is" do
      Application.put_env(:phoenix_kit, :project_title, "Acme Rentals")
      assert Config.project_title() == "Acme Rentals"
    end

    test ":host_app derives the humanized OTP app name at runtime" do
      Application.put_env(:phoenix_kit, :project_title, :host_app)
      Application.put_env(:phoenix_kit, :parent_app_name, :acme_rentals)
      assert Config.project_title() == "Acme Rentals"
    end

    test "an empty or odd value falls back to the default" do
      for value <- ["", 42, :something_else] do
        Application.put_env(:phoenix_kit, :project_title, value)
        assert Config.project_title() == "PhoenixKit"
      end
    end

    test "Settings.get_project_title/0 reads through it when no row is stored" do
      Application.put_env(:phoenix_kit, :project_title, :host_app)
      Application.put_env(:phoenix_kit, :parent_app_name, :my_shop)

      # Database-less unit runs answer nil for every setting.
      assert PhoenixKit.Settings.get_project_title() in ["My Shop", "PhoenixKit"]
      assert PhoenixKit.Settings.get_defaults()["project_title"] == "My Shop"
    end
  end

  test "humanize_app_name/1" do
    assert Config.humanize_app_name(:my_shop) == "My Shop"
    assert Config.humanize_app_name("acme_web") == "Acme Web"
    assert Config.humanize_app_name(:app) == "App"
  end

  describe "the installer" do
    test "writes the humanized app name for a new install" do
      igniter =
        test_project(app_name: :acme_rentals, files: %{"config/config.exs" => "import Config\n"})
        |> InstallDefaults.add_project_title()

      config =
        igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)

      assert config =~ ~s|project_title: "Acme Rentals"|
    end

    test "keeps a title the host already configured" do
      existing = ~s|import Config\nconfig :phoenix_kit, project_title: "Mine"\n|

      igniter =
        test_project(app_name: :acme_rentals, files: %{"config/config.exs" => existing})
        |> InstallDefaults.add_project_title()

      config =
        igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)

      assert config =~ ~s|"Mine"|
      refute config =~ "Acme Rentals"
    end

    test "the updater never writes it" do
      refute File.read!("lib/mix/tasks/phoenix_kit.update.ex") =~ "add_project_title"
    end
  end
end
