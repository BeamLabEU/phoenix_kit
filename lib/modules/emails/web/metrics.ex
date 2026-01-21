defmodule PhoenixKit.Modules.Emails.Web.Metrics do
  @moduledoc """
  LiveView for email metrics and analytics dashboard.

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

  This LiveView is mounted at `{prefix}/admin/emails/dashboard` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-metrics", PhoenixKitWeb.Live.Modules.Emails.EmailMetricsLive, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Emails
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Number, as: UtilsNumber
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  # Auto-refresh every 30 seconds
  @refresh_interval 30_000

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Check if email is enabled
    if Emails.enabled?() do
      # Get project title from settings
      project_title = Settings.get_project_title()

      # Schedule periodic refresh
      if connected?(socket) do
        Process.send_after(self(), :refresh_metrics, @refresh_interval)
        # Also send initial chart data after a short delay to ensure JS is ready
        Process.send_after(self(), :initial_chart_push, 500)
      end

      socket =
        socket
        |> assign(:project_title, project_title)
        |> assign(:loading, true)
        |> assign(:period, :last_7_days)
        |> assign(:custom_range, false)
        |> assign(:start_date, nil)
        |> assign(:end_date, nil)
        |> assign(:metrics, %{})
        |> assign(:charts_data, %{
          delivery_trend: %{labels: [], datasets: []},
          engagement: %{labels: [], datasets: []}
        })
        |> assign(:last_updated, DateTime.utc_now())
        |> load_metrics_data()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Email is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
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

  @impl true
  def handle_info(:initial_chart_push, socket) do
    # Push current chart data to ensure charts are properly initialized
    socket =
      if connected?(socket) and socket.assigns.charts_data do
        Logger.debug("Sent initial chart push event")
        push_event(socket, "email-charts-update", %{charts: socket.assigns.charts_data})
      else
        socket
      end

    {:noreply, socket}
  end

  defp load_metrics_data(socket) do
    period = determine_period(socket.assigns)

    metrics =
      Emails.get_system_stats(period)
      |> Map.merge(load_additional_metrics(period))

    charts_data = prepare_charts_data(metrics, period)

    socket =
      socket
      |> assign(:metrics, metrics)
      |> assign(:charts_data, charts_data)
      |> assign(:loading, false)

    # Push chart data to JavaScript if the socket is connected
    if connected?(socket) do
      socket |> push_event("email-charts-update", %{charts: charts_data})
    else
      socket
    end
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
      by_provider: Emails.get_provider_performance(period),
      today_count: get_today_count()
    }
  end

  defp get_today_count do
    today_start = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
    now = DateTime.utc_now()

    case Emails.get_system_stats(
           {:date_range, DateTime.to_date(today_start), DateTime.to_date(now)}
         ) do
      %{total_sent: count} -> count
      _ -> 0
    end
  end

  defp prepare_charts_data(metrics, period) do
    # Get daily delivery trends for the chart
    daily_trends = Emails.get_daily_delivery_trends(period)

    charts_data = %{
      delivery_trend: %{
        labels: Map.get(daily_trends, :labels, []),
        datasets: [
          %{
            label: "Delivered",
            data: Map.get(daily_trends, :delivered, []),
            borderColor: "rgb(34, 197, 94)",
            backgroundColor: "rgba(34, 197, 94, 0.1)",
            tension: 0.1,
            fill: true
          },
          %{
            label: "Bounced",
            data: Map.get(daily_trends, :bounced, []),
            borderColor: "rgb(239, 68, 68)",
            backgroundColor: "rgba(239, 68, 68, 0.1)",
            tension: 0.1,
            fill: true
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

    charts_data
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
end
