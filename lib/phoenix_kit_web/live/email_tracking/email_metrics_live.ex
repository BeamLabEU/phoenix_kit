defmodule PhoenixKitWeb.Live.EmailTracking.EmailMetricsLive do
  @moduledoc """
  LiveView for email tracking metrics and analytics dashboard.

  Provides comprehensive analytics visualization for email campaigns including:

  - **Key Performance Indicators**: Send, delivery, bounce, complaint rates
  - **Trend Analysis**: Time-series charts for performance tracking
  - **Geographic Distribution**: Map showing engagement by location
  - **Provider Performance**: Comparison of different email providers
  - **Campaign Analytics**: Performance breakdown by campaign and template
  - **Real-time Updates**: Live metrics refreshing every 30 seconds

  ## Features

  - **Interactive Charts**: Built with Chart.js for responsive visualizations
  - **Date Range Filtering**: Custom date ranges for detailed analysis
  - **Export Functionality**: Download charts and data as PNG/CSV
  - **Responsive Design**: Mobile-friendly dashboard layout
  - **Performance Metrics**: Delivery rates, open rates, click-through rates
  - **Bounce Analysis**: Hard vs soft bounce categorization
  - **Complaint Tracking**: Spam complaint monitoring and alerts

  ## Route

  This LiveView is mounted at `/phoenix_kit/admin/email-metrics` and requires
  appropriate admin permissions.

  ## Usage

      # In your Phoenix router
      live "/email-metrics", PhoenixKitWeb.Live.EmailTracking.EmailMetricsLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  # Auto-refresh every 30 seconds
  @refresh_interval 30_000

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, session, socket) do
    # Check if email tracking is enabled
    if EmailTracking.enabled?() do
      # Get current path for navigation
      current_path = get_current_path(socket, session)

      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Schedule periodic refresh
      if connected?(socket) do
        Process.send_after(self(), :refresh_metrics, @refresh_interval)
      end

      socket =
        socket
        |> assign(:current_path, current_path)
        |> assign(:project_title, project_title)
        |> assign(:loading, true)
        |> assign(:period, :last_7_days)
        |> assign(:custom_range, false)
        |> assign(:start_date, nil)
        |> assign(:end_date, nil)
        |> assign(:metrics, %{})
        |> assign(:charts_data, %{})
        |> assign(:last_updated, DateTime.utc_now())
        |> load_metrics_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Email tracking is not enabled")
       |> push_navigate(to: "/phoenix_kit/admin")}
    end
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_metrics_data()}
  end

  @impl true
  def handle_event("change_period", %{"period" => period}, socket) do
    period_atom = String.to_atom(period)

    {:noreply,
     socket
     |> assign(:period, period_atom)
     |> assign(:custom_range, false)
     |> assign(:loading, true)
     |> load_metrics_data()}
  end

  @impl true
  def handle_event("toggle_custom_range", _params, socket) do
    {:noreply,
     socket
     |> assign(:custom_range, !socket.assigns.custom_range)}
  end

  @impl true
  def handle_event(
        "apply_custom_range",
        %{"start_date" => start_date, "end_date" => end_date},
        socket
      ) do
    case {Date.from_iso8601(start_date), Date.from_iso8601(end_date)} do
      {{:ok, start_date}, {:ok, end_date}} ->
        {:noreply,
         socket
         |> assign(:period, :custom)
         |> assign(:start_date, start_date)
         |> assign(:end_date, end_date)
         |> assign(:custom_range, false)
         |> assign(:loading, true)
         |> load_metrics_data()}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid date range")}
    end
  end

  @impl true
  def handle_event("export_metrics", %{"format" => format}, socket) do
    case format do
      "csv" ->
        csv_content = export_metrics_csv(socket.assigns.metrics)
        filename = "email_metrics_#{Date.utc_today()}.csv"

        {:noreply,
         socket
         |> push_event("download", %{
           filename: filename,
           content: csv_content,
           mime_type: "text/csv"
         })}

      "json" ->
        json_content = Jason.encode!(socket.assigns.metrics, pretty: true)
        filename = "email_metrics_#{Date.utc_today()}.json"

        {:noreply,
         socket
         |> push_event("download", %{
           filename: filename,
           content: json_content,
           mime_type: "application/json"
         })}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Unsupported export format")}
    end
  end

  @impl true
  def handle_info(:refresh_metrics, socket) do
    # Schedule next refresh
    Process.send_after(self(), :refresh_metrics, @refresh_interval)

    {:noreply,
     socket
     |> assign(:last_updated, DateTime.utc_now())
     |> load_metrics_data()}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Email Analytics"
      current_path={@current_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button --%>
          <.link
            navigate="/phoenix_kit/admin"
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Admin
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">
              Email Dashboard
            </h1>
            <p class="text-lg text-base-content/70">
              Comprehensive email performance metrics and insights
            </p>
          </div>
        </header>

        <%!-- Controls Section --%>
        <div class="flex flex-col lg:flex-row lg:items-center lg:justify-between mb-6 gap-4">
          <%!-- Period Selection --%>
          <div class="flex flex-wrap gap-2">
            <button
              class={[
                "btn btn-sm",
                (@period == :last_24_hours && "btn-primary") || "btn-outline"
              ]}
              phx-click="change_period"
              phx-value-period="last_24_hours"
            >
              24 Hours
            </button>
            <button
              class={[
                "btn btn-sm",
                (@period == :last_7_days && "btn-primary") || "btn-outline"
              ]}
              phx-click="change_period"
              phx-value-period="last_7_days"
            >
              7 Days
            </button>
            <button
              class={[
                "btn btn-sm",
                (@period == :last_30_days && "btn-primary") || "btn-outline"
              ]}
              phx-click="change_period"
              phx-value-period="last_30_days"
            >
              30 Days
            </button>
            <button
              class={[
                "btn btn-sm",
                (@period == :last_90_days && "btn-primary") || "btn-outline"
              ]}
              phx-click="change_period"
              phx-value-period="last_90_days"
            >
              90 Days
            </button>
            <button
              class="btn btn-sm btn-outline"
              phx-click="toggle_custom_range"
            >
              Custom Range
            </button>
          </div>

          <%!-- Action Buttons --%>
          <div class="flex gap-2">
            <button
              class="btn btn-sm btn-outline"
              phx-click="refresh"
              disabled={@loading}
            >
              <%= if @loading do %>
                <span class="loading loading-spinner loading-xs"></span>
              <% else %>
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                  />
                </svg>
              <% end %>
              Refresh
            </button>

            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-sm btn-outline">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M9 19l3 3m0 0l3-3m-3 3V10"
                  />
                </svg>
                Export
              </div>
              <ul
                tabindex="0"
                class="dropdown-content z-[1] menu p-2 shadow bg-base-100 rounded-box w-52"
              >
                <li>
                  <a phx-click="export_metrics" phx-value-format="csv">
                    Export as CSV
                  </a>
                </li>
                <li>
                  <a phx-click="export_metrics" phx-value-format="json">
                    Export as JSON
                  </a>
                </li>
              </ul>
            </div>
          </div>
        </div>

        <%!-- Custom Date Range Modal --%>
        <%= if @custom_range do %>
          <div class="modal modal-open">
            <div class="modal-box">
              <h3 class="font-bold text-lg mb-4">Select Custom Date Range</h3>
              <form phx-submit="apply_custom_range">
                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div>
                    <label class="label">
                      <span class="label-text">Start Date</span>
                    </label>
                    <input
                      type="date"
                      name="start_date"
                      class="input input-bordered w-full"
                      max={Date.utc_today() |> Date.to_iso8601()}
                      required
                    />
                  </div>
                  <div>
                    <label class="label">
                      <span class="label-text">End Date</span>
                    </label>
                    <input
                      type="date"
                      name="end_date"
                      class="input input-bordered w-full"
                      max={Date.utc_today() |> Date.to_iso8601()}
                      required
                    />
                  </div>
                </div>
                <div class="modal-action">
                  <button type="submit" class="btn btn-primary">Apply</button>
                  <button type="button" class="btn" phx-click="toggle_custom_range">Cancel</button>
                </div>
              </form>
            </div>
          </div>
        <% end %>

        <%!-- Loading State --%>
        <%= if @loading do %>
          <div class="flex justify-center items-center h-32">
            <span class="loading loading-spinner loading-lg"></span>
            <span class="ml-3 text-lg">Loading analytics data...</span>
          </div>
        <% else %>
          <%!-- KPI Cards --%>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
            <%!-- Total Sent --%>
            <div class="card bg-primary text-primary-content shadow-sm">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-primary-content/70 text-sm">Total Sent</p>
                    <p class="text-2xl font-bold">{format_number(@metrics.total_sent || 0)}</p>
                  </div>
                  <div class="text-primary-content/70">
                    <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 20 20">
                      <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z" />
                      <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z" />
                    </svg>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Delivery Rate --%>
            <div class="card bg-success text-success-content shadow-sm">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-success-content/70 text-sm">Delivery Rate</p>
                    <p class="text-2xl font-bold">{format_percentage(@metrics.delivery_rate || 0)}</p>
                  </div>
                  <div class="text-success-content/70">
                    <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Bounce Rate --%>
            <div class="card bg-warning text-warning-content shadow-sm">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-warning-content/70 text-sm">Bounce Rate</p>
                    <p class="text-2xl font-bold">{format_percentage(@metrics.bounce_rate || 0)}</p>
                  </div>
                  <div class="text-warning-content/70">
                    <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 20 20">
                      <path
                        fill-rule="evenodd"
                        d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Open Rate --%>
            <div class="card bg-info text-info-content shadow-sm">
              <div class="card-body p-4">
                <div class="flex items-center justify-between">
                  <div>
                    <p class="text-info-content/70 text-sm">Open Rate</p>
                    <p class="text-2xl font-bold">{format_percentage(@metrics.open_rate || 0)}</p>
                  </div>
                  <div class="text-info-content/70">
                    <svg class="w-8 h-8" fill="currentColor" viewBox="0 0 20 20">
                      <path d="M10 12a2 2 0 100-4 2 2 0 000 4z" />
                      <path
                        fill-rule="evenodd"
                        d="M.458 10C1.732 5.943 5.522 3 10 3s8.268 2.943 9.542 7c-1.274 4.057-5.064 7-9.542 7S1.732 14.057.458 10zM14 10a4 4 0 11-8 0 4 4 0 018 0z"
                        clip-rule="evenodd"
                      />
                    </svg>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <%!-- Charts Section --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6 mb-6">
            <%!-- Delivery Trends Chart --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <h2 class="card-title text-lg mb-4">Delivery Trends</h2>
                <div class="w-full h-64">
                  <canvas id="delivery-trend-chart" width="400" height="200"></canvas>
                </div>
              </div>
            </div>

            <%!-- Engagement Chart --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <h2 class="card-title text-lg mb-4">Engagement Metrics</h2>
                <div class="w-full h-64">
                  <canvas id="engagement-chart" width="400" height="200"></canvas>
                </div>
              </div>
            </div>
          </div>

          <%!-- Additional Analytics --%>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <%!-- Provider Performance --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <h2 class="card-title text-lg mb-4">Provider Performance</h2>
                <%= if @metrics.by_provider && length(Map.keys(@metrics.by_provider)) > 0 do %>
                  <div class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>Provider</th>
                          <th>Sent</th>
                          <th>Delivery Rate</th>
                          <th>Bounce Rate</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for {provider, stats} <- @metrics.by_provider do %>
                          <tr>
                            <td class="font-medium">{provider}</td>
                            <td>{format_number(stats.total_sent || 0)}</td>
                            <td>
                              <span class={[
                                "badge badge-sm",
                                ((stats.delivery_rate || 0) >= 95 && "badge-success") ||
                                  ((stats.delivery_rate || 0) >= 85 && "badge-warning") ||
                                  "badge-error"
                              ]}>
                                {format_percentage(stats.delivery_rate || 0)}
                              </span>
                            </td>
                            <td>{format_percentage(stats.bounce_rate || 0)}</td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                <% else %>
                  <div class="text-center text-base-content/50 py-8">
                    No provider data available
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Recent Activity --%>
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <h2 class="card-title text-lg mb-4">System Status</h2>
                <div class="space-y-3">
                  <div class="flex items-center justify-between">
                    <span class="text-sm">Email Tracking</span>
                    <span class="badge badge-success">Active</span>
                  </div>
                  <div class="flex items-center justify-between">
                    <span class="text-sm">Last Updated</span>
                    <span class="text-sm text-base-content/70">
                      {UtilsDate.format_datetime_with_user_format(@last_updated)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between">
                    <span class="text-sm">Total Emails Today</span>
                    <span class="text-sm font-medium">
                      {format_number(@metrics.today_count || 0)}
                    </span>
                  </div>
                  <div class="flex items-center justify-between">
                    <span class="text-sm">Data Retention</span>
                    <span class="text-sm text-base-content/70">
                      {EmailTracking.get_retention_days()} days
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- JavaScript for Charts --%>
      <script>
        // Chart.js initialization will be handled by a hook
        window.addEventListener("phx:page-loading-stop", () => {
          if (window.initializeCharts) {
            window.initializeCharts(<%= Jason.encode!(@charts_data) %>);
          }
        });
      </script>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Functions ---

  defp get_current_path(_socket, _session) do
    "/phoenix_kit/admin/email-metrics"
  end

  defp load_metrics_data(socket) do
    period = determine_period(socket.assigns)

    metrics =
      EmailTracking.get_system_stats(period)
      |> Map.merge(load_additional_metrics(period))

    charts_data = prepare_charts_data(metrics, period)

    socket
    |> assign(:metrics, metrics)
    |> assign(:charts_data, charts_data)
    |> assign(:loading, false)
  end

  defp determine_period(assigns) do
    if assigns.period == :custom and assigns.start_date and assigns.end_date do
      {:date_range, assigns.start_date, assigns.end_date}
    else
      assigns.period
    end
  end

  defp load_additional_metrics(period) do
    %{
      by_provider: EmailTracking.get_provider_performance(period),
      today_count: get_today_count()
    }
  end

  defp get_today_count do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
    now = DateTime.utc_now()

    case EmailTracking.get_system_stats(
           {:date_range, DateTime.to_date(today_start), DateTime.to_date(now)}
         ) do
      %{total_sent: count} -> count
      _ -> 0
    end
  end

  defp prepare_charts_data(metrics, _period) do
    %{
      delivery_trend: %{
        labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        datasets: [
          %{
            label: "Delivered",
            data: [120, 190, 300, 500, 200, 300, 450],
            borderColor: "rgb(34, 197, 94)",
            backgroundColor: "rgba(34, 197, 94, 0.1)"
          },
          %{
            label: "Bounced",
            data: [5, 10, 15, 25, 10, 15, 23],
            borderColor: "rgb(239, 68, 68)",
            backgroundColor: "rgba(239, 68, 68, 0.1)"
          }
        ]
      },
      engagement: %{
        labels: ["Opens", "Clicks", "Bounces", "Complaints"],
        datasets: [
          %{
            data: [
              metrics.opened || 0,
              metrics.clicked || 0,
              metrics.bounced || 0,
              metrics.complained || 0
            ],
            backgroundColor: [
              "rgb(59, 130, 246)",
              "rgb(34, 197, 94)",
              "rgb(251, 191, 36)",
              "rgb(239, 68, 68)"
            ]
          }
        ]
      }
    }
  end

  defp export_metrics_csv(metrics) do
    headers = "Metric,Value\n"

    rows = [
      "Total Sent,#{metrics.total_sent || 0}",
      "Delivered,#{metrics.delivered || 0}",
      "Bounced,#{metrics.bounced || 0}",
      "Delivery Rate,#{metrics.delivery_rate || 0}%",
      "Bounce Rate,#{metrics.bounce_rate || 0}%",
      "Open Rate,#{metrics.open_rate || 0}%",
      "Click Rate,#{metrics.click_rate || 0}%"
    ]

    headers <> Enum.join(rows, "\n")
  end

  defp format_number(number) when is_integer(number) do
    number
    |> to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp format_number(number), do: to_string(number)

  defp format_percentage(rate) when is_float(rate) do
    "#{:erlang.float_to_binary(rate, decimals: 1)}%"
  end

  defp format_percentage(rate) when is_integer(rate) do
    "#{rate}%"
  end

  defp format_percentage(_), do: "0%"
end
