defmodule PhoenixKitWeb.Live.Modules.Maintenance.Settings do
  @moduledoc """
  Settings page for the Maintenance module.

  Allows admins to:
  - Toggle maintenance mode on/off manually
  - Customize the maintenance page header and subtext
  - Schedule a maintenance window (start/end UTC datetimes)
  - Preview the maintenance page in real time
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: DateUtils
  alias PhoenixKit.Utils.Routes

  # Interval between "current time" display refreshes
  @current_time_tick_ms 30_000

  # How long the "Saved!" button label persists before reverting to "Save Changes"
  @saved_flash_timeout_ms 2_000

  def mount(_params, _session, socket) do
    current_path =
      Routes.path("/admin/settings/maintenance", locale: socket.assigns.current_locale_base)

    config = Maintenance.get_config()

    # Subscribe to PubSub for real-time status updates (e.g. scheduled window activating)
    # and start a ticker to keep the displayed current time fresh
    if connected?(socket) do
      Maintenance.subscribe()
      Process.send_after(self(), :tick_current_time, @current_time_tick_ms)
    end

    # Get the system timezone offset for display and conversion
    tz_offset = Settings.get_setting_cached("time_zone", "0")
    tz_label = Settings.get_timezone_label(tz_offset, Settings.get_setting_options())

    # Format datetimes for datetime-local inputs (converted to system timezone)
    scheduled_start_str = format_datetime_for_input(config.scheduled_start, tz_offset)
    scheduled_end_str = format_datetime_for_input(config.scheduled_end, tz_offset)

    socket =
      socket
      |> assign(:page_title, "Maintenance Mode Settings")
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_path, current_path)
      |> assign(:header, config.header)
      |> assign(:subtext, config.subtext)
      |> assign(:enabled, config.enabled)
      |> assign(:active, config.active)
      |> assign(:scheduled_start, scheduled_start_str)
      |> assign(:scheduled_end, scheduled_end_str)
      |> assign(:scheduled_active, config.scheduled_active)
      |> assign(:tz_offset, tz_offset)
      |> assign(:tz_label, tz_label)
      |> assign(:current_time, format_current_time(tz_offset))
      |> assign(:min_datetime, format_current_datetime_local(tz_offset))
      |> assign(:saved, false)

    {:ok, socket}
  end

  def handle_event("update_content", %{"header" => header, "subtext" => subtext}, socket) do
    {:noreply,
     socket
     |> assign(:header, header)
     |> assign(:subtext, subtext)}
  end

  def handle_event("save", _params, socket) do
    Maintenance.update_header(socket.assigns.header)
    Maintenance.update_subtext(socket.assigns.subtext)

    # Broadcast so other admin tabs and active maintenance pages pick up the new content
    Maintenance.broadcast_status_change()

    log_activity(socket, "maintenance.content_updated", %{
      "header" => socket.assigns.header,
      "subtext" => socket.assigns.subtext
    })

    socket =
      socket
      |> assign(:saved, true)
      |> put_flash(:info, gettext("Maintenance mode settings saved successfully"))

    Process.send_after(self(), :reset_saved, @saved_flash_timeout_ms)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    config = Maintenance.get_config()

    socket =
      socket
      |> assign(:header, config.header)
      |> assign(:subtext, config.subtext)
      |> put_flash(:info, gettext("Changes discarded"))

    {:noreply, socket}
  end

  def handle_event("toggle_maintenance_mode", _params, socket) do
    new_enabled = !socket.assigns.enabled

    result =
      if new_enabled do
        Maintenance.enable_system()
      else
        Maintenance.disable_system()
      end

    case result do
      {:ok, _setting} ->
        action = if new_enabled, do: "maintenance.enabled", else: "maintenance.disabled"
        log_activity(socket, action, %{"state" => new_enabled})

        # disable_system clears the scheduled start, so update the UI too
        socket =
          socket
          |> assign(:enabled, new_enabled)
          |> assign(:active, Maintenance.active?())
          |> then(fn s -> if new_enabled, do: s, else: assign(s, :scheduled_start, "") end)
          |> assign(:scheduled_active, Maintenance.within_scheduled_window?())
          |> put_flash(
            :info,
            if(new_enabled,
              do:
                gettext(
                  "Maintenance mode activated — non-admin users will see the maintenance page"
                ),
              else: gettext("Maintenance mode deactivated — site is now accessible to all users")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to toggle maintenance mode"))
        {:noreply, socket}
    end
  end

  def handle_event("save_schedule", %{"start" => start_str, "end" => end_str}, socket) do
    tz_offset = socket.assigns.tz_offset

    # Allow partial schedules — either or both fields can be filled
    start_dt = parse_input_datetime_or_nil(start_str, tz_offset)
    end_dt = parse_input_datetime_or_nil(end_str, tz_offset)

    case Maintenance.update_schedule(start_dt, end_dt) do
      :ok ->
        log_activity(socket, "maintenance.schedule_set", %{
          "start" => if(start_dt, do: DateTime.to_iso8601(start_dt)),
          "end" => if(end_dt, do: DateTime.to_iso8601(end_dt))
        })

        socket =
          socket
          |> assign(:scheduled_start, start_str)
          |> assign(:scheduled_end, end_str)
          |> assign(:enabled, Maintenance.manually_enabled?())
          |> assign(:scheduled_active, Maintenance.within_scheduled_window?())
          |> assign(:active, Maintenance.active?())
          |> put_flash(:info, gettext("Maintenance schedule saved"))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, schedule_error_message(reason))}
    end
  end

  def handle_event("clear_schedule", _params, socket) do
    log_activity(socket, "maintenance.schedule_cleared", %{})
    Maintenance.clear_schedule()

    socket =
      socket
      |> assign(:scheduled_start, "")
      |> assign(:scheduled_end, "")
      |> assign(:scheduled_active, false)
      |> assign(:active, Maintenance.active?())
      |> put_flash(:info, gettext("Maintenance schedule cleared"))

    {:noreply, socket}
  end

  # PubSub: maintenance status changed (e.g. toggle or scheduled window)
  # Refresh all maintenance-related assigns so the UI reflects the current DB state.
  def handle_info({:maintenance_status_changed, _payload}, socket) do
    tz_offset = socket.assigns.tz_offset

    # Re-read content fields too so multi-admin editing stays in sync
    {:noreply,
     socket
     |> assign(:active, Maintenance.active?())
     |> assign(:enabled, Maintenance.manually_enabled?())
     |> assign(:scheduled_active, Maintenance.within_scheduled_window?())
     |> assign(:header, Maintenance.get_header())
     |> assign(:subtext, Maintenance.get_subtext())
     |> assign(
       :scheduled_start,
       format_datetime_for_input(Maintenance.get_scheduled_start(), tz_offset)
     )
     |> assign(
       :scheduled_end,
       format_datetime_for_input(Maintenance.get_scheduled_end(), tz_offset)
     )}
  end

  def handle_info(:reset_saved, socket) do
    {:noreply, assign(socket, :saved, false)}
  end

  def handle_info(:tick_current_time, socket) do
    Process.send_after(self(), :tick_current_time, 30_000)
    tz = socket.assigns.tz_offset

    {:noreply,
     socket
     |> assign(:current_time, format_current_time(tz))
     |> assign(:min_datetime, format_current_datetime_local(tz))}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Maintenance Mode Settings"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={PhoenixKit.Utils.Routes.path("/admin/modules")}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">
              {gettext("Maintenance Mode Settings")}
            </h1>
            <p class="text-lg text-base-content/70">
              {gettext("Customize the maintenance page and schedule")}
            </p>
          </div>
        </header>

        <%!-- Overall Status --%>
        <%= if @active do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <p class="font-semibold">{gettext("Maintenance is active")}</p>
              <p class="text-sm">
                <%= cond do %>
                  <% @enabled and @scheduled_active -> %>
                    {gettext("Enabled manually AND within scheduled window.")}
                  <% @enabled -> %>
                    {gettext("Enabled manually via toggle.")}
                  <% @scheduled_active -> %>
                    {gettext("Active due to scheduled window.")}
                  <% true -> %>
                    {gettext("Maintenance is active.")}
                <% end %>
                {gettext("Non-admin users are seeing the maintenance page.")}
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Manual Toggle --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div class="flex-1">
                <h2 class="card-title mb-2">
                  <.icon name="hero-power" class="w-5 h-5" /> {gettext("Manual Toggle")}
                </h2>
                <p class="text-sm text-base-content/70">
                  {if @enabled,
                    do: gettext("Maintenance mode is manually enabled"),
                    else: gettext("Maintenance mode is off (can still activate via schedule)")}
                </p>
              </div>
              <div class="flex-shrink-0 ml-4">
                <input
                  type="checkbox"
                  class="toggle toggle-lg toggle-warning"
                  checked={@enabled}
                  phx-click="toggle_maintenance_mode"
                />
              </div>
            </div>
          </div>
        </div>

        <%!-- Scheduled Maintenance --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title mb-4">
              <.icon name="hero-clock" class="w-5 h-5" /> {gettext("Scheduled Maintenance")}
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              {gettext("Set a time window for automatic maintenance activation.")}
              {gettext("Current time")} ({@tz_label}): <span class="font-mono">{@current_time}</span>
            </p>

            <form phx-submit="save_schedule" class="space-y-4">
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">
                      {gettext("Start Time")} ({@tz_label})
                    </span>
                  </label>
                  <input
                    type="datetime-local"
                    name="start"
                    value={@scheduled_start}
                    min={@min_datetime}
                    class="input input-bordered w-full"
                  />
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">{gettext("End Time")} ({@tz_label})</span>
                  </label>
                  <input
                    type="datetime-local"
                    name="end"
                    value={@scheduled_end}
                    min={@min_datetime}
                    class="input input-bordered w-full"
                  />
                </div>
              </div>

              <%= if @scheduled_active do %>
                <div class="alert alert-warning">
                  <.icon name="hero-clock" class="w-5 h-5" />
                  <span>{gettext("Scheduled window is currently active")}</span>
                </div>
              <% end %>

              <div class="flex gap-2">
                <button type="submit" class="btn btn-primary">
                  <.icon name="hero-clock" class="w-5 h-5" /> {gettext("Save Schedule")}
                </button>
                <%= if @scheduled_start != "" or @scheduled_end != "" do %>
                  <button type="button" phx-click="clear_schedule" class="btn btn-outline btn-error">
                    <.icon name="hero-x-mark" class="w-5 h-5" /> {gettext("Clear Schedule")}
                  </button>
                <% end %>
              </div>
            </form>
          </div>
        </div>

        <%!-- Two Column Layout: Content Settings + Preview --%>
        <div class="grid gap-6 lg:grid-cols-2">
          <%!-- Content Settings (Left Column) --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title mb-4">
                <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> {gettext("Page Content")}
              </h2>
              <form phx-change="update_content" phx-submit="save" class="space-y-4">
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">{gettext("Header Text")}</span>
                  </label>
                  <input
                    type="text"
                    name="header"
                    value={@header}
                    phx-debounce="150"
                    class="input input-bordered w-full"
                    placeholder={gettext("Maintenance Mode")}
                    required
                  />
                  <label class="label">
                    <span class="label-text-alt">
                      {gettext("Main heading shown on maintenance page")}
                    </span>
                  </label>
                </div>

                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">{gettext("Message Text")}</span>
                  </label>
                  <textarea
                    name="subtext"
                    phx-debounce="150"
                    class="textarea textarea-bordered w-full h-32"
                    placeholder={gettext("We'll be back soon...")}
                    required
                  >{@subtext}</textarea>
                  <label class="label">
                    <span class="label-text-alt">
                      {gettext("Detailed message shown below the header")}
                    </span>
                  </label>
                </div>

                <div class="alert alert-info">
                  <.icon name="hero-information-circle" class="w-5 h-5" />
                  <div class="text-sm">
                    {gettext(
                      "Changes to header and message text take effect immediately after saving."
                    )}
                  </div>
                </div>

                <div class="flex gap-2">
                  <button
                    type="submit"
                    class={"btn btn-primary flex-1 #{if @saved, do: "btn-success"}"}
                  >
                    <.icon
                      name={if @saved, do: "hero-check", else: "hero-arrow-down-tray"}
                      class="w-5 h-5"
                    />
                    {if @saved, do: gettext("Saved!"), else: gettext("Save Changes")}
                  </button>
                  <button
                    type="button"
                    phx-click="cancel"
                    class="btn btn-outline"
                    disabled={@saved}
                  >
                    <.icon name="hero-x-mark" class="w-5 h-5" /> {gettext("Cancel")}
                  </button>
                </div>
              </form>
            </div>
          </div>

          <%!-- Live Preview (Right Column) --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title mb-4">
                <.icon name="hero-eye" class="w-5 h-5" /> {gettext("Live Preview")}
              </h2>
              <div class="bg-base-200 rounded-lg p-8 min-h-[400px] flex items-center justify-center">
                <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300 w-full">
                  <div class="card-body text-center py-8">
                    <div class="text-6xl mb-4 opacity-70">
                      🚧
                    </div>
                    <h1 class="text-3xl font-bold text-base-content mb-3">
                      {@header}
                    </h1>
                    <p class="text-base text-base-content/70 mb-6">
                      {@subtext}
                    </p>
                  </div>
                </div>
              </div>
              <div class="alert alert-info mt-4">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span class="text-sm">
                  {gettext("This is how non-admin users will see the maintenance page")}
                </span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # Returns a DateTime or nil (for empty/invalid input). Used for partial schedules.
  defp parse_input_datetime_or_nil("", _tz_offset), do: nil
  defp parse_input_datetime_or_nil(nil, _tz_offset), do: nil

  defp parse_input_datetime_or_nil(str, tz_offset) do
    case parse_input_datetime(str, tz_offset) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  # Thin wrappers around PhoenixKit.Utils.Date helpers
  defp parse_input_datetime(str, tz_offset), do: DateUtils.parse_datetime_local(str, tz_offset)

  defp format_datetime_for_input(dt, tz_offset),
    do: DateUtils.format_datetime_local(dt, tz_offset)

  # Format the current time in the system timezone for display.
  defp format_current_time(tz_offset) do
    DateTime.utc_now()
    |> DateUtils.shift_to_offset(tz_offset)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  # Format for datetime-local min attribute (T separator)
  defp format_current_datetime_local(tz_offset) do
    DateUtils.format_datetime_local(DateTime.utc_now(), tz_offset)
  end

  # User-facing error messages for schedule validation failures
  defp schedule_error_message(:empty),
    do: gettext("Please enter at least a start or end time")

  defp schedule_error_message(:start_in_past),
    do: gettext("Start time must be in the future")

  defp schedule_error_message(:end_in_past),
    do: gettext("End time must be in the future")

  defp schedule_error_message(:end_before_start),
    do: gettext("End time must be after start time")

  defp schedule_error_message(:too_far_future),
    do: gettext("Schedule cannot be more than a year in the future")

  defp schedule_error_message(unknown) do
    # Log so new validation atoms surface instead of being silently swallowed
    require Logger
    Logger.warning("Unknown maintenance schedule error atom: #{inspect(unknown)}")
    gettext("Failed to save schedule")
  end

  # Convert a timezone offset string (e.g., "2", "-5", "5.5") to seconds.

  # Activity logging helper — guarded so logging failures never crash the primary operation
  defp log_activity(socket, action, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      admin = socket.assigns[:phoenix_kit_current_user]

      PhoenixKit.Activity.log(%{
        action: action,
        module: "maintenance",
        mode: "manual",
        actor_uuid: admin && admin.uuid,
        resource_type: "maintenance",
        resource_uuid: nil,
        metadata: Map.merge(metadata, %{"actor_role" => "admin"})
      })
    end
  rescue
    _ -> :ok
  end
end
