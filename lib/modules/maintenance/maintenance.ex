defmodule PhoenixKit.Modules.Maintenance do
  @moduledoc """
  Maintenance Mode module for PhoenixKit.

  This module provides a system-wide maintenance mode that shows a
  maintenance page to all non-admin users while allowing
  admins and owners to access the site normally.

  Maintenance can be activated in two ways:
  - **Manual toggle**: Immediately enables/disables maintenance mode
  - **Scheduled window**: Set a start and end time for automatic activation

  `active?/0` returns true when either the manual toggle is on OR the current
  time falls within a scheduled window.

  ## Settings

  The module uses the following settings stored in the database:
  - `maintenance_module_enabled` - Boolean to enable/disable the module settings page (default: false)
  - `maintenance_enabled` - Boolean to enable/disable maintenance mode manually (default: false)
  - `maintenance_header` - Main heading text (default: "Maintenance Mode")
  - `maintenance_subtext` - Descriptive subtext (default: "We'll be back soon")
  - `maintenance_scheduled_start` - ISO 8601 UTC datetime for scheduled start (default: nil)
  - `maintenance_scheduled_end` - ISO 8601 UTC datetime for scheduled end (default: nil)

  ## Usage

      # Check if maintenance mode is currently active (manual OR scheduled)
      if PhoenixKit.Modules.Maintenance.active?() do
        # Show maintenance page to non-admin users
      end

      # Enable/disable manually
      PhoenixKit.Modules.Maintenance.enable_system()
      PhoenixKit.Modules.Maintenance.disable_system()

      # Schedule a maintenance window
      PhoenixKit.Modules.Maintenance.update_schedule(
        ~U[2026-04-14 17:00:00Z],
        ~U[2026-04-14 18:00:00Z]
      )

      # Get module configuration
      config = PhoenixKit.Modules.Maintenance.get_config()
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings

  @default_header "Maintenance Mode"
  @default_subtext "We'll be back soon. Our team is working hard to bring you something amazing!"
  @pubsub_topic "phoenix_kit:maintenance"

  # ============================================================================
  # Module Status
  # ============================================================================

  @doc """
  Checks if the Maintenance module is enabled (settings page accessible).
  """
  def module_enabled? do
    Settings.get_boolean_setting("maintenance_module_enabled", false)
  end

  @doc """
  Enables the Maintenance module (makes settings page accessible).
  """
  def enable_module do
    Settings.update_boolean_setting("maintenance_module_enabled", true)
  end

  @doc """
  Disables the Maintenance module (hides settings page).

  Also automatically disables maintenance mode and clears any schedule
  to prevent users from being locked out.
  """
  def disable_module do
    disable_system()
    clear_schedule()
    Settings.update_boolean_setting("maintenance_module_enabled", false)
  end

  @impl PhoenixKit.Module
  @doc """
  Checks if the Maintenance module is enabled (PhoenixKit.Module callback).
  """
  def enabled? do
    Settings.get_boolean_setting("maintenance_module_enabled", false)
  end

  # ============================================================================
  # Manual Toggle
  # ============================================================================

  @impl PhoenixKit.Module
  @doc """
  Enables maintenance mode manually.

  When enabled, all non-admin users will see the maintenance page.
  Broadcasts a PubSub event so LiveViews can react in real time.
  """
  def enable_system do
    # Clear any expired schedule so it doesn't suppress the toggle
    if past_scheduled_end?() do
      Settings.update_setting("maintenance_scheduled_start", "")
      Settings.update_setting("maintenance_scheduled_end", "")
    end

    result = Settings.update_boolean_setting("maintenance_enabled", true)

    case result do
      {:ok, _} -> broadcast_status_change()
      _ -> :ok
    end

    result
  end

  @impl PhoenixKit.Module
  @doc """
  Disables maintenance mode manually.

  When disabled, all users can access the site normally.
  Also clears the scheduled start time so it doesn't re-trigger.
  Broadcasts a PubSub event so the maintenance layout is removed.
  """
  def disable_system do
    # Clear scheduled start so past_scheduled_start? doesn't re-activate maintenance
    Settings.update_setting("maintenance_scheduled_start", "")

    result = Settings.update_boolean_setting("maintenance_enabled", false)

    case result do
      {:ok, _} -> broadcast_status_change()
      _ -> :ok
    end

    result
  end

  @doc """
  Returns whether the manual maintenance toggle is on.
  """
  def manually_enabled? do
    Settings.get_boolean_setting("maintenance_enabled", false)
  end

  # ============================================================================
  # Scheduled Maintenance
  # ============================================================================

  @doc """
  Returns the scheduled start time as a DateTime, or nil.
  """
  def get_scheduled_start do
    case Settings.get_setting_cached("maintenance_scheduled_start", nil) do
      nil -> nil
      "" -> nil
      iso_string -> parse_datetime(iso_string)
    end
  end

  @doc """
  Returns the scheduled end time as a DateTime, or nil.
  """
  def get_scheduled_end do
    case Settings.get_setting_cached("maintenance_scheduled_end", nil) do
      nil -> nil
      "" -> nil
      iso_string -> parse_datetime(iso_string)
    end
  end

  @doc """
  Validates a proposed maintenance schedule.

  Rules:
  - At least one of start or end must be provided
  - Start (if set) must be in the future
  - End (if set) must be in the future
  - If both are set, end must be strictly after start

  A small tolerance (60 seconds) is applied to "in the future" checks
  to handle datetime-local inputs which only have minute precision and
  minor clock drift between client and server.

  Returns `:ok` or `{:error, atom}` where atom is one of:
  - `:empty` — neither start nor end provided
  - `:start_in_past`
  - `:end_in_past`
  - `:end_before_start` — end is before or equal to start
  - `:too_far_future` — date is more than one year in the future
  """
  def validate_schedule(start_dt, end_dt) do
    with :ok <- validate_presence(start_dt, end_dt),
         :ok <- validate_not_past(start_dt, :start_in_past),
         :ok <- validate_not_past(end_dt, :end_in_past),
         :ok <- validate_order(start_dt, end_dt),
         :ok <- validate_not_too_far(start_dt) do
      validate_not_too_far(end_dt)
    end
  end

  defp validate_presence(nil, nil), do: {:error, :empty}
  defp validate_presence(_, _), do: :ok

  # 60-second tolerance for minute-precision inputs and clock drift
  defp validate_not_past(nil, _), do: :ok

  defp validate_not_past(%DateTime{} = dt, error) do
    if DateTime.diff(dt, DateTime.utc_now()) < -60, do: {:error, error}, else: :ok
  end

  defp validate_order(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    if DateTime.compare(end_dt, start_dt) == :gt, do: :ok, else: {:error, :end_before_start}
  end

  defp validate_order(_, _), do: :ok

  # Reject dates more than one year in the future
  defp validate_not_too_far(nil), do: :ok

  defp validate_not_too_far(%DateTime{} = dt) do
    max_future_seconds = 365 * 24 * 60 * 60

    if DateTime.diff(dt, DateTime.utc_now()) > max_future_seconds,
      do: {:error, :too_far_future},
      else: :ok
  end

  @doc """
  Sets a scheduled maintenance window.

  Either or both times can be provided:
  - **Start only**: maintenance activates at start, stays on until manually disabled
  - **End only**: maintenance auto-disables at end time
  - **Both**: maintenance is active between start and end

  Validates the schedule via `validate_schedule/2` before writing.
  Times are stored as ISO 8601 UTC strings. Pass `nil` to clear a field.
  Broadcasts a PubSub event on success.

  Returns `:ok` on success or `{:error, atom}` on validation/DB failure.
  """
  def update_schedule(start_dt, end_dt) do
    with :ok <- validate_schedule(start_dt, end_dt),
         start_val = if(start_dt, do: DateTime.to_iso8601(start_dt), else: ""),
         end_val = if(end_dt, do: DateTime.to_iso8601(end_dt), else: ""),
         {:ok, _} <- Settings.update_setting("maintenance_scheduled_start", start_val),
         {:ok, _} <- Settings.update_setting("maintenance_scheduled_end", end_val) do
      broadcast_status_change()
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears the scheduled maintenance window.
  Broadcasts a PubSub event.
  """
  def clear_schedule do
    Settings.update_setting("maintenance_scheduled_start", "")
    Settings.update_setting("maintenance_scheduled_end", "")
    broadcast_status_change()
    :ok
  end

  @doc """
  Returns true if the current time is past the scheduled start time.

  Used for start-only schedules (no end time) or as the "on" condition
  in a start+end window.
  """
  def past_scheduled_start? do
    case get_scheduled_start() do
      %DateTime{} = dt -> DateTime.compare(DateTime.utc_now(), dt) in [:gt, :eq]
      _ -> false
    end
  end

  @doc """
  Returns true if the current time is past the scheduled end time.

  When true, maintenance is forced off regardless of other settings.
  Used as an auto-turn-off mechanism.
  """
  def past_scheduled_end? do
    case get_scheduled_end() do
      %DateTime{} = dt -> DateTime.compare(DateTime.utc_now(), dt) in [:gt, :eq]
      _ -> false
    end
  end

  @doc """
  Returns true if a scheduled maintenance window is currently active.

  Handles three schedule configurations:
  - **Start + End**: active between start and end times
  - **Start only**: active once past start, stays on indefinitely
  - **End only**: returns false (end-only acts as auto-off for the manual toggle)
  """
  def within_scheduled_window? do
    start_dt = get_scheduled_start()
    end_dt = get_scheduled_end()

    case {start_dt, end_dt} do
      {nil, _} -> false
      {_, nil} -> past_scheduled_start?()
      {_, _} -> past_scheduled_start?() and not past_scheduled_end?()
    end
  end

  # ============================================================================
  # Active Check (the main entry point)
  # ============================================================================

  @doc """
  Returns true if maintenance mode is currently active.

  The main function used to check maintenance status. Logic:

  1. If a scheduled end time is set and has passed → **off** (auto-turn-off)
  2. If the manual toggle is on → **on**
  3. If a scheduled start time is set and has passed → **on** (auto-turn-on)
  4. Otherwise → **off**

  Schedule configurations:
  - **Start only**: activates at start time, stays on until manually disabled
  - **End only**: manual toggle works, but auto-disables at end time
  - **Start + End**: active during the window
  - **Neither**: just the manual toggle

  ## Examples

      iex> PhoenixKit.Modules.Maintenance.active?()
      false
  """
  def active? do
    cond do
      # End time has passed — maintenance is off regardless of toggle or start
      past_scheduled_end?() -> false
      manually_enabled?() -> true
      past_scheduled_start?() -> true
      true -> false
    end
  rescue
    error ->
      # If settings DB is unavailable, fail open (don't block the site)
      # but log so the issue is visible in production.
      require Logger
      Logger.error("Maintenance.active? failed: #{Exception.message(error)}")
      false
  end

  @doc """
  Cleans up stale state when the scheduled end time has passed.

  Disables the manual toggle and clears the schedule, then broadcasts
  so any connected users get their layout restored.

  Returns `true` if cleanup was performed, `false` if nothing needed cleaning.
  Safe to call repeatedly — it's a no-op when there's nothing stale.
  """
  def cleanup_expired_schedule do
    if past_scheduled_end?() and
         (manually_enabled?() or get_scheduled_start() != nil or get_scheduled_end() != nil) do
      Settings.update_boolean_setting("maintenance_enabled", false)
      Settings.update_setting("maintenance_scheduled_start", "")
      Settings.update_setting("maintenance_scheduled_end", "")
      broadcast_status_change()
      true
    else
      false
    end
  rescue
    error ->
      require Logger
      Logger.error("Maintenance.cleanup_expired_schedule failed: #{Exception.message(error)}")
      false
  end

  @doc """
  Returns the number of seconds until maintenance ends, or nil if unknown.

  Used for the Retry-After HTTP header and countdown timer.
  Returns nil if maintenance is manually enabled without a scheduled end,
  or if maintenance is not active.
  """
  def seconds_until_end do
    cond do
      # Scheduled window is active — use the end time
      within_scheduled_window?() ->
        case get_scheduled_end() do
          %DateTime{} = end_dt -> DateTime.diff(end_dt, DateTime.utc_now())
          _ -> nil
        end

      # Manual mode with a scheduled end in the future — use it as estimate
      manually_enabled?() ->
        case get_scheduled_end() do
          %DateTime{} = end_dt ->
            diff = DateTime.diff(end_dt, DateTime.utc_now())
            if diff > 0, do: diff, else: nil

          nil ->
            nil
        end

      true ->
        nil
    end
  end

  # ============================================================================
  # Content Settings
  # ============================================================================

  @doc """
  Gets the header text for the maintenance page.
  """
  def get_header do
    Settings.get_setting_cached("maintenance_header", @default_header)
  end

  @doc """
  Updates the header text for the maintenance page.
  """
  def update_header(header) when is_binary(header) do
    Settings.update_setting("maintenance_header", header)
  end

  @doc """
  Gets the subtext for the maintenance page.
  """
  def get_subtext do
    Settings.get_setting_cached("maintenance_subtext", @default_subtext)
  end

  @doc """
  Updates the subtext for the maintenance page.
  """
  def update_subtext(subtext) when is_binary(subtext) do
    Settings.update_setting("maintenance_subtext", subtext)
  end

  @impl PhoenixKit.Module
  @doc """
  Gets the full configuration for the Maintenance module.
  """
  def get_config do
    %{
      module_enabled: module_enabled?(),
      enabled: manually_enabled?(),
      active: active?(),
      header: get_header(),
      subtext: get_subtext(),
      scheduled_start: get_scheduled_start(),
      scheduled_end: get_scheduled_end(),
      scheduled_active: within_scheduled_window?()
    }
  end

  # ============================================================================
  # PubSub
  # ============================================================================

  @doc """
  Returns the PubSub topic for maintenance status changes.
  """
  def pubsub_topic, do: @pubsub_topic

  @doc """
  Subscribes the calling process to maintenance status change events.
  """
  def subscribe do
    PubSubManager.subscribe(@pubsub_topic)
  end

  @doc """
  Broadcasts the current maintenance status.

  Sends `{:maintenance_status_changed, %{active: boolean}}` to all subscribers.
  """
  def broadcast_status_change do
    PubSubManager.broadcast(@pubsub_topic, {:maintenance_status_changed, %{active: active?()}})
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "maintenance"

  @impl PhoenixKit.Module
  def module_name, do: "Maintenance"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "maintenance",
      label: "Maintenance",
      icon: "hero-wrench-screwdriver",
      description: "Maintenance mode and under-construction pages"
    }
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_maintenance,
        label: "Maintenance",
        icon: "hero-wrench-screwdriver",
        path: "maintenance",
        priority: 932,
        level: :admin,
        parent: :admin_settings,
        permission: "maintenance"
      )
    ]
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
