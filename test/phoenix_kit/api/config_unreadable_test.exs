defmodule PhoenixKit.API.ConfigUnreadableTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Registry

  defmodule UnreadableRepo do
    def get_by(_schema, key: "api_disabled_tools") do
      Process.put(:settings_queries, Process.get(:settings_queries, 0) + 1)

      case Process.get(:settings_read) do
        :missing -> nil
        {:value, value} -> %PhoenixKit.Settings.Setting{value: value}
        :exit -> exit(:database_unavailable)
        _ -> raise DBConnection.ConnectionError, message: "database unavailable"
      end
    end

    def get_by(_schema, key: "api_disabled_modules") do
      case Process.get(:modules_read) do
        :exit -> exit(:database_unavailable)
        :raise -> raise DBConnection.ConnectionError, message: "database unavailable"
        _ -> nil
      end
    end

    def get_by(_schema, key: "api_session_write_modules") do
      case Process.get(:session_writes_read) do
        :exit -> exit(:database_unavailable)
        :raise -> raise DBConnection.ConnectionError, message: "database unavailable"
        {:value, value} -> %PhoenixKit.Settings.Setting{value: value}
        _ -> nil
      end
    end

    def get_by(_schema, key: "api_pw_change_revokes") do
      case Process.get(:revokes_read) do
        :exit -> exit(:database_unavailable)
        {:value, value} -> %PhoenixKit.Settings.Setting{value: value}
        _ -> raise DBConnection.ConnectionError, message: "database unavailable"
      end
    end

    def get_by(_schema, _clauses), do: nil
  end

  setup do
    previous_repo = Application.get_env(:phoenix_kit, :repo)
    previous_mode = Application.get_env(:phoenix_kit, :update_mode, false)
    Process.register(self(), UnreadableRepo)
    start_supervised!(PhoenixKit.Cache.Registry)
    start_supervised!({PhoenixKit.Cache, name: :settings})
    Application.put_env(:phoenix_kit, :repo, UnreadableRepo)
    Application.put_env(:phoenix_kit, :update_mode, false)

    on_exit(fn ->
      Application.put_env(:phoenix_kit, :repo, previous_repo)
      Application.put_env(:phoenix_kit, :update_mode, previous_mode)
    end)

    :ok
  end

  @tag capture_log: true
  test "a cold settings read that raises never re-enables hidden tools" do
    assert Config.fetch_disabled_tools() == :unreadable
    assert Registry.all_tools() == []
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}
    refute Config.admin_enabled?()
    refute Config.public_enabled?()
  end

  @tag capture_log: true
  test "a cold settings read that exits never re-enables hidden tools" do
    Process.put(:settings_read, :exit)
    assert Config.fetch_disabled_tools() == :unreadable
    assert Registry.all_tools() == []
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}
  end

  test "an explicitly empty cached list is readable even during a DB outage" do
    PhoenixKit.Cache.put(:settings, "api_disabled_tools", "")
    assert Config.fetch_disabled_tools() == {:ok, []}
    assert {:ok, _tool} = Registry.find("system.get_identity", :admin)
  end

  test "a missing row is readable and negatively cached" do
    Process.put(:settings_read, :missing)
    assert Config.fetch_disabled_tools() == {:ok, []}
    assert Config.fetch_disabled_tools() == {:ok, []}
    assert Process.get(:settings_queries) == 1
  end

  test "a failed read is not cached and recovery restores the hidden list" do
    assert Config.fetch_disabled_tools() == :unreadable
    Process.put(:settings_read, {:value, "system.get_identity"})
    assert Config.fetch_disabled_tools() == {:ok, ["system.get_identity"]}
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}
    assert Process.get(:settings_queries) == 2
  end

  @tag capture_log: true
  test "a list of hidden modules that cannot be read hides everything, it never re-enables a module" do
    PhoenixKit.Cache.put(:settings, "api_disabled_tools", "")
    Process.put(:modules_read, :raise)

    assert Config.fetch_disabled_modules() == :unreadable
    assert Config.disabled_modules() == []
    assert Registry.all_tools() == []
    assert Registry.find("system.get_identity", :admin) == {:error, :not_found}

    Process.put(:modules_read, :exit)
    assert Config.fetch_disabled_modules() == :unreadable
    assert Registry.all_tools() == []
  end

  @tag capture_log: true
  test "a list of the modules a session may write in that cannot be read opens none" do
    Process.put(:session_writes_read, {:value, "api_session_tools"})
    assert Config.fetch_session_write_modules() == {:ok, ["api_session_tools"]}

    for failure <- [:raise, :exit] do
      PhoenixKit.Cache.clear(:settings)
      Process.put(:session_writes_read, failure)

      assert Config.fetch_session_write_modules() == :unreadable
      assert Config.session_write_modules() == []
    end
  end

  @tag capture_log: true
  test "a hidden list that cannot be read shows every tool closed as :api_off" do
    :ok = PhoenixKit.ModuleRegistry.register(PhoenixKit.Test.ApiTools)
    on_exit(fn -> PhoenixKit.ModuleRegistry.unregister(PhoenixKit.Test.ApiTools) end)

    assert [_ | _] = cold = Executor.tool_availability()
    assert Enum.all?(cold, &match?({:closed, [:api_off | _]}, &1.status))

    PhoenixKit.Cache.put(:settings, "api_disabled_tools", "")
    Process.put(:modules_read, :raise)

    assert [_ | _] = modules_unreadable = Executor.tool_availability()
    assert Enum.all?(modules_unreadable, &match?({:closed, [:api_off | _]}, &1.status))
  end

  test "an explicitly empty cached list of hidden modules is readable during a DB outage" do
    PhoenixKit.Cache.put(:settings, "api_disabled_tools", "")
    PhoenixKit.Cache.put(:settings, "api_disabled_modules", "")

    assert Config.fetch_disabled_modules() == {:ok, []}
    assert {:ok, _tool} = Registry.find("system.get_identity", :admin)
  end

  describe "the password setting" do
    test "that cannot be read is off, and says so once in the log" do
      log = capture_log(fn -> refute Config.password_change_revokes?() end)

      assert log =~ "api_pw_change_revokes could not be read"
      assert log =~ "a password change ends no key or connection"
      assert length(Regex.scan(~r/api_pw_change_revokes could not be read/, log)) == 1
      refute log =~ "database unavailable"
    end

    test "whose read exits is off and says so too" do
      Process.put(:revokes_read, :exit)

      log = capture_log(fn -> refute Config.password_change_revokes?() end)

      assert log =~ "api_pw_change_revokes could not be read"
    end

    test "that is readable says nothing, on or off" do
      Process.put(:revokes_read, {:value, "true"})
      assert capture_log(fn -> assert Config.password_change_revokes?() end) == ""

      PhoenixKit.Cache.clear(:settings)
      Process.put(:revokes_read, {:value, "false"})
      assert capture_log(fn -> refute Config.password_change_revokes?() end) == ""
    end
  end
end
