defmodule PhoenixKit.Integration.Languages.StartupMigrationTest do
  @moduledoc """
  Executes the language startup task taken from the real supervisor child list.
  The full tree is not started: the suite already owns its registry and repo.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings

  test "normal boot copies the legacy URL setting while multiple languages are off" do
    {:ok, _} = Settings.update_setting("languages_enabled", "false")
    {:ok, _} = Settings.update_setting("publishing_default_language_no_prefix", "true")

    {:ok, {_flags, children}} = PhoenixKit.Supervisor.init([])
    child = Enum.find(children, &(&1.id == :normalize_languages))
    assert %{start: {Task, :start_link, [callback]}} = child

    callback |> Task.async() |> Task.await()

    assert Settings.get_setting("default_language_no_prefix") == "true"
    refute Languages.enabled?()

    # A later boot preserves an explicit choice over the legacy setting.
    {:ok, _} = Languages.set_default_language_no_prefix(false)
    callback |> Task.async() |> Task.await()
    refute Languages.default_language_no_prefix?()
  end
end
