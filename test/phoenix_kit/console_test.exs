defmodule PhoenixKit.ConsoleTest do
  @moduledoc """
  `PhoenixKit.Console` and the two mix tasks over it (`mix phoenix_kit.settings`,
  `mix phoenix_kit.modules`): known keys only, the settings form's validation, a history
  entry with source "console", secrets never printed, modules switched through their own
  `enable_system/0`, and `--yes` in prod.
  """
  use PhoenixKit.DataCase, async: false

  alias Mix.Tasks.PhoenixKit.Modules, as: ModulesTask
  alias Mix.Tasks.PhoenixKit.Settings, as: SettingsTask
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Console
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings

  defmodule Switchable do
    @moduledoc false
    @key {__MODULE__, :on}
    def module_key, do: "console_test_switchable"
    def module_name, do: "Console test module"
    def enabled?, do: :persistent_term.get(@key, false)
    def get_config, do: %{enabled: enabled?()}

    def enable_system do
      send(:persistent_term.get({__MODULE__, :owner}), :enabled_called)
      :persistent_term.put(@key, true)
      :ok
    end

    def disable_system do
      :persistent_term.put(@key, false)
      {:ok, :done}
    end
  end

  defmodule Refusing do
    @moduledoc false
    def module_key, do: "console_test_refusing"
    def module_name, do: "Refusing"
    def enabled?, do: false
    def enable_system, do: {:error, :publishing_required}
    def disable_system, do: :ok
  end

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!(Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings))

    :persistent_term.put({Switchable, :owner}, self())
    :ok = ModuleRegistry.register(Switchable)
    :ok = ModuleRegistry.register(Refusing)

    on_exit(fn ->
      ModuleRegistry.unregister(Switchable)
      ModuleRegistry.unregister(Refusing)
      :persistent_term.erase({Switchable, :on})
      :persistent_term.erase({Switchable, :owner})
    end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  describe "settings" do
    test "list holds the form keys only, with secrets masked" do
      Settings.update_setting("oauth_github_client_secret", "very-secret-value")
      rows = Console.settings_list()
      keys = Enum.map(rows, & &1.key)

      assert Enum.sort(keys) == Enum.sort(Settings.form_setting_keys())
      assert %{value: :secret} = Enum.find(rows, &(&1.key == "oauth_github_client_secret"))
      refute inspect(rows) =~ "very-secret-value"
    end

    test "get answers a known key and refuses an unknown one" do
      Settings.update_setting("project_title", "Console Shop")
      assert Console.settings_get("project_title") == {:ok, "Console Shop"}
      assert Console.settings_get("no_such_key") == {:error, :unknown_key}
      assert Console.settings_get("api_admin_enabled") == {:error, :unknown_key}
    end

    test "set writes through the form's validation and records source console" do
      assert {:ok, "From the console"} = Console.settings_set("project_title", "From the console")
      assert Settings.get_setting("project_title") == "From the console"

      [entry | _] = Settings.history("project_title")
      assert entry.metadata["source"] == "console"
    end

    test "set refuses a value the form refuses, and writes nothing" do
      Settings.update_setting("project_title", "Kept")
      assert {:error, %Ecto.Changeset{}} = Console.settings_set("project_title", "")
      assert Settings.get_setting("project_title") == "Kept"
    end

    test "set refuses an unknown key" do
      assert Console.settings_set("api_admin_enabled", "true") == {:error, :unknown_key}
    end
  end

  describe "modules" do
    test "list shows each registered module with its state" do
      assert %{name: "Console test module", enabled: false} =
               Enum.find(Console.modules_list(), &(&1.key == "console_test_switchable"))
    end

    test "enable and disable go through the module's own functions and are logged" do
      assert Console.module_enable("console_test_switchable") == {:ok, :enabled}
      assert_received :enabled_called
      assert Switchable.enabled?()

      # Already on: nothing is called again.
      assert Console.module_enable("console_test_switchable") == {:ok, :enabled}
      refute_received :enabled_called

      assert Console.module_disable("console_test_switchable") == {:ok, :disabled}
      refute Switchable.enabled?()

      actions =
        Repo.all(
          from(a in Entry,
            where: a.module == "modules" and a.mode == "console",
            select: {a.action, a.metadata}
          )
        )

      assert {"module.enabled", %{"module" => "console_test_switchable", "source" => "console"}} in actions

      assert {"module.disabled", %{"module" => "console_test_switchable", "source" => "console"}} in actions
    end

    test "an unknown key and a module's own refusal come back as errors" do
      assert Console.module_enable("no_such_module") == {:error, :unknown_module}
      assert Console.module_enable("console_test_refusing") == {:error, :publishing_required}
    end
  end

  describe "mix phoenix_kit.settings" do
    test "parses the commands" do
      assert SettingsTask.command(["list"], []) == {:ok, :list}
      assert SettingsTask.command(["get", "k"], []) == {:ok, {:get, "k"}}
      assert SettingsTask.command(["set", "k", "v"], []) == {:ok, {:set, "k", "v"}}

      assert SettingsTask.command(["set", "k"], [stdin: true],
               read_line: fn -> "from stdin\n" end
             ) ==
               {:ok, {:set, "k", "from stdin"}}

      assert {:error, _} = SettingsTask.command(["set", "k", "v"], stdin: true)
      assert {:error, _} = SettingsTask.command(["set", "k"], [])
      assert {:error, _} = SettingsTask.command(["nope"], [])
    end

    test "a write needs --yes in prod; a read does not" do
      prod = [mix_env: :prod]
      assert {:error, message} = SettingsTask.command(["set", "k", "v"], [], prod)
      assert message =~ "--yes"
      assert {:ok, _} = SettingsTask.command(["set", "k", "v"], [yes: true], prod)
      assert {:ok, :list} = SettingsTask.command(["list"], [], prod)
    end

    test "prints a value, never a secret, and exits 1 on an unknown key" do
      Settings.update_setting("oauth_github_client_secret", "printed-never")

      SettingsTask.execute({:get, "oauth_github_client_secret"})
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "secret, not shown"

      assert catch_exit(SettingsTask.execute({:get, "nope"})) == {:shutdown, 1}
      assert_received {:mix_shell, :error, [message]}
      assert message =~ "Unknown setting"
    end

    test "set prints the stored value" do
      SettingsTask.execute({:set, "project_title", "Via task"})
      assert_received {:mix_shell, :info, ["project_title = \"Via task\""]}
    end
  end

  describe "mix phoenix_kit.modules" do
    test "parses the commands and wants --yes in prod" do
      assert ModulesTask.command(["list"], []) == {:ok, :list}
      assert ModulesTask.command(["enable", "x"], []) == {:ok, {:enable, "x"}}
      assert ModulesTask.command(["disable", "x"], []) == {:ok, {:disable, "x"}}
      assert {:error, _} = ModulesTask.command(["toggle", "x"], [])
      assert {:error, message} = ModulesTask.command(["enable", "x"], [], mix_env: :prod)
      assert message =~ "--yes"
      assert {:ok, _} = ModulesTask.command(["enable", "x"], [yes: true], mix_env: :prod)
    end

    test "switches and reports, and exits 1 on a refusal" do
      ModulesTask.execute({:enable, "console_test_switchable"})
      assert_received {:mix_shell, :info, ["console_test_switchable: enabled"]}

      assert catch_exit(ModulesTask.execute({:enable, "console_test_refusing"})) == {:shutdown, 1}
      assert_received {:mix_shell, :error, [message]}
      assert message =~ "publishing_required"
    end
  end
end
