defmodule PhoenixKit.Integration.MaintenanceTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings

  # Helpers
  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp past(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  setup do
    # Reset all maintenance state before each test
    Settings.update_boolean_setting("maintenance_enabled", false)
    Settings.update_setting("maintenance_scheduled_start", "")
    Settings.update_setting("maintenance_scheduled_end", "")
    :ok
  end

  describe "active?/0" do
    test "returns false when nothing is set" do
      refute Maintenance.active?()
    end

    test "returns true when manual toggle is on" do
      Maintenance.enable_system()
      assert Maintenance.active?()
    end

    test "returns false when manual toggle is off" do
      Maintenance.disable_system()
      refute Maintenance.active?()
    end

    test "returns true during scheduled window" do
      Maintenance.update_schedule(past(60), future(3600))
      assert Maintenance.active?()
    end

    test "returns false before scheduled start" do
      Maintenance.update_schedule(future(3600), future(7200))
      refute Maintenance.active?()
    end

    test "returns false after scheduled end (overrides manual toggle)" do
      Maintenance.enable_system()
      # Directly write an expired end time, bypassing validation
      Settings.update_setting("maintenance_scheduled_end", DateTime.to_iso8601(past(60)))
      refute Maintenance.active?()
    end

    test "start-only schedule stays on after start time" do
      Maintenance.update_schedule(past(60), nil)
      assert Maintenance.active?()
    end
  end

  describe "enable_system/0" do
    test "sets the manual toggle" do
      assert {:ok, _} = Maintenance.enable_system()
      assert Maintenance.manually_enabled?()
    end

    test "clears expired schedule on enable" do
      # Set an expired schedule directly
      Settings.update_setting("maintenance_scheduled_end", DateTime.to_iso8601(past(60)))
      assert Maintenance.past_scheduled_end?()

      Maintenance.enable_system()

      # Expired schedule should be cleared so toggle is effective
      refute Maintenance.past_scheduled_end?()
      assert Maintenance.active?()
    end
  end

  describe "disable_system/0" do
    test "clears the manual toggle" do
      Maintenance.enable_system()
      assert {:ok, _} = Maintenance.disable_system()
      refute Maintenance.manually_enabled?()
    end

    test "clears the scheduled start to prevent re-activation" do
      Maintenance.update_schedule(past(60), future(3600))
      Maintenance.disable_system()
      assert Maintenance.get_scheduled_start() == nil
    end
  end

  describe "update_schedule/2" do
    test "saves a valid schedule" do
      start_dt = future(3600)
      end_dt = future(7200)
      assert :ok = Maintenance.update_schedule(start_dt, end_dt)

      assert %DateTime{} = Maintenance.get_scheduled_start()
      assert %DateTime{} = Maintenance.get_scheduled_end()
    end

    test "accepts start-only schedule" do
      assert :ok = Maintenance.update_schedule(future(3600), nil)
      assert %DateTime{} = Maintenance.get_scheduled_start()
      assert Maintenance.get_scheduled_end() == nil
    end

    test "accepts end-only schedule" do
      assert :ok = Maintenance.update_schedule(nil, future(3600))
      assert Maintenance.get_scheduled_start() == nil
      assert %DateTime{} = Maintenance.get_scheduled_end()
    end

    test "rejects invalid schedules" do
      assert {:error, :empty} = Maintenance.update_schedule(nil, nil)
      assert {:error, :start_in_past} = Maintenance.update_schedule(past(3600), nil)
      assert {:error, :end_in_past} = Maintenance.update_schedule(nil, past(3600))

      assert {:error, :end_before_start} =
               Maintenance.update_schedule(future(7200), future(3600))
    end

    test "does not save anything when validation fails" do
      Maintenance.update_schedule(past(3600), nil)
      assert Maintenance.get_scheduled_start() == nil
    end
  end

  describe "clear_schedule/0" do
    test "clears both start and end" do
      Maintenance.update_schedule(future(3600), future(7200))
      Maintenance.clear_schedule()

      assert Maintenance.get_scheduled_start() == nil
      assert Maintenance.get_scheduled_end() == nil
    end
  end

  describe "cleanup_expired_schedule/0" do
    test "returns false when nothing is stale" do
      refute Maintenance.cleanup_expired_schedule()
    end

    test "cleans up when end has passed and toggle is on" do
      Maintenance.enable_system()
      Settings.update_setting("maintenance_scheduled_end", DateTime.to_iso8601(past(60)))

      assert Maintenance.cleanup_expired_schedule()

      refute Maintenance.manually_enabled?()
      assert Maintenance.get_scheduled_end() == nil
    end

    test "cleans up when end has passed and schedule exists" do
      Settings.update_setting("maintenance_scheduled_start", DateTime.to_iso8601(past(3600)))
      Settings.update_setting("maintenance_scheduled_end", DateTime.to_iso8601(past(60)))

      assert Maintenance.cleanup_expired_schedule()

      assert Maintenance.get_scheduled_start() == nil
      assert Maintenance.get_scheduled_end() == nil
    end

    test "broadcasts status change on cleanup" do
      Maintenance.subscribe()
      Maintenance.enable_system()

      # Drain enable_system's broadcast
      assert_receive {:maintenance_status_changed, _}

      Settings.update_setting("maintenance_scheduled_end", DateTime.to_iso8601(past(60)))
      Maintenance.cleanup_expired_schedule()

      assert_receive {:maintenance_status_changed, %{active: false}}
    end
  end

  describe "seconds_until_end/0" do
    test "returns nil when no schedule" do
      assert Maintenance.seconds_until_end() == nil
    end

    test "returns positive seconds during scheduled window" do
      Maintenance.update_schedule(past(60), future(3600))
      seconds = Maintenance.seconds_until_end()
      assert is_integer(seconds)
      assert seconds > 0
      assert seconds <= 3600
    end
  end

  describe "get_config/0" do
    test "returns a map with all expected keys" do
      config = Maintenance.get_config()

      assert Map.has_key?(config, :module_enabled)
      assert Map.has_key?(config, :enabled)
      assert Map.has_key?(config, :active)
      assert Map.has_key?(config, :header)
      assert Map.has_key?(config, :subtext)
      assert Map.has_key?(config, :scheduled_start)
      assert Map.has_key?(config, :scheduled_end)
      assert Map.has_key?(config, :scheduled_active)
    end
  end

  describe "content settings" do
    test "update_header stores the value" do
      Maintenance.update_header("Custom Header")
      assert Maintenance.get_header() == "Custom Header"
    end

    test "update_subtext stores the value" do
      Maintenance.update_subtext("Custom subtext")
      assert Maintenance.get_subtext() == "Custom subtext"
    end
  end
end
