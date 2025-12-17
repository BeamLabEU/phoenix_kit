defmodule PhoenixKit.Emails.Metrics do
  @moduledoc """
  Local metrics and analytics for PhoenixKit email tracking.

  This module provides comprehensive metrics collection and analysis capabilities
  for email performance, deliverability, and engagement tracking using the local database.

  ## Features

  - **Engagement Analysis**: Open rates, click rates, and engagement trends
  - **Geographic Analytics**: Performance by region and country
  - **Provider Analysis**: Deliverability by email provider (Gmail, Outlook, etc.)
  - **Campaign Performance**: Top performing campaigns and templates
  - **Real-time Dashboards**: Data for live monitoring dashboards
  - **Time Series Data**: Historical trends and patterns

  ## Usage Examples

      # Get engagement metrics
      engagement = PhoenixKit.Emails.Metrics.get_engagement_metrics(:last_7_days)

      # Get geographic distribution
      geo = PhoenixKit.Emails.Metrics.get_geographic_metrics(:last_30_days)

      # Get dashboard data
      dashboard = PhoenixKit.Emails.Metrics.get_dashboard_data(:last_30_days)
  """

  require Logger

  alias PhoenixKit.Emails.{Event, Log}

  # Get the configured repo
  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  @doc """
  Gets engagement metrics with trend analysis.

  ## Examples

      iex> PhoenixKit.Emails.Metrics.get_engagement_metrics(:last_7_days)
      %{
        open_rate: 24.5,
        click_rate: 4.2,
        engagement_score: 28.7,
        trend: :improving,
        daily_breakdown: [...]
      }
  """
  def get_engagement_metrics(period \\ :last_7_days) do
    # Get engagement data from local database
    local_data = get_local_engagement_data(period)

    # Add trend analysis
    Map.put(local_data, :trend, calculate_engagement_trend(local_data))
  end

  @doc """
  Gets geographic distribution of email engagement.

  ## Examples

      iex> PhoenixKit.Emails.Metrics.get_geographic_metrics("open", :last_30_days)
      %{
        "US" => %{count: 500, percentage: 45.5},
        "CA" => %{count: 200, percentage: 18.2},
        "UK" => %{count: 150, percentage: 13.6}
      }
  """
  def get_geographic_metrics(event_type, period \\ :last_30_days) do
    {start_time, end_time} = get_time_range(period)

    # Get geo data from local events database
    geo_data = Event.get_geo_distribution(event_type, start_time, end_time)

    total_count = Enum.reduce(geo_data, 0, fn {_country, count}, acc -> acc + count end)

    # Add percentages
    geo_data
    |> Enum.into(%{}, fn {country, count} ->
      percentage =
        if total_count > 0, do: (count / total_count * 100) |> Float.round(1), else: 0.0

      {country, %{count: count, percentage: percentage}}
    end)
  end

  ## --- Dashboard Data ---

  @doc """
  Gets comprehensive dashboard data combining multiple metric sources.

  Returns data optimized for dashboard visualization with time series,
  percentages, trends, and alerts.

  ## Examples

      iex> PhoenixKit.Emails.Metrics.get_dashboard_data(:last_7_days)
      %{
        overview: %{
          total_sent: 5000,
          delivery_rate: 98.2,
          bounce_rate: 1.8,
          open_rate: 24.5,
          click_rate: 4.2
        },
        time_series: [...],
        alerts: [...],
        top_performers: [...]
      }
  """
  def get_dashboard_data(period \\ :last_7_days) do
    # Get overview metrics
    overview_task = Task.async(fn -> get_overview_metrics(period) end)

    # Get time series data
    time_series_task = Task.async(fn -> get_time_series_data(period) end)

    # Get geographic data
    geo_task = Task.async(fn -> get_geographic_metrics("open", period) end)

    # Get alerts and issues
    alerts_task = Task.async(fn -> get_metric_alerts(period) end)

    # Get top performing campaigns/templates
    top_performers_task = Task.async(fn -> get_top_performers(period) end)

    # Get provider performance
    provider_task = Task.async(fn -> get_provider_performance(period) end)

    # Wait for all results
    [overview, time_series, geographic, alerts, top_performers, provider_performance] =
      Task.await_many(
        [
          overview_task,
          time_series_task,
          geo_task,
          alerts_task,
          top_performers_task,
          provider_task
        ],
        30_000
      )

    %{
      overview: overview,
      time_series: time_series,
      geographic: geographic,
      alerts: alerts,
      top_performers: top_performers,
      provider_performance: provider_performance,
      generated_at: DateTime.utc_now()
    }
  end

  ## --- Alerting ---

  @doc """
  Checks metrics against thresholds and returns alerts.

  ## Examples

      iex> PhoenixKit.Emails.Metrics.get_metric_alerts(:last_24_hours)
      [
        %{type: :high_bounce_rate, severity: :warning, value: 5.2, threshold: 5.0},
        %{type: :low_open_rate, severity: :info, value: 15.1, threshold: 20.0}
      ]
  """
  def get_metric_alerts(period \\ :last_24_hours) do
    # Get metrics from local database
    stats = PhoenixKit.Emails.get_system_stats(period)

    alerts = []

    # Check for high bounce rate
    alerts =
      if stats.bounce_rate > 5.0 do
        [
          %{
            type: :high_bounce_rate,
            severity: :warning,
            value: stats.bounce_rate,
            threshold: 5.0,
            message: "Bounce rate exceeds recommended threshold"
          }
          | alerts
        ]
      else
        alerts
      end

    # Check for low delivery rate
    alerts =
      if stats.delivery_rate < 95.0 do
        [
          %{
            type: :low_delivery_rate,
            severity: :warning,
            value: stats.delivery_rate,
            threshold: 95.0,
            message: "Delivery rate below recommended threshold"
          }
          | alerts
        ]
      else
        alerts
      end

    alerts
  end

  ## --- Private Helper Functions ---

  # Get time range for period
  defp get_time_range(period) do
    end_time = DateTime.utc_now()

    start_time =
      case period do
        :last_hour -> DateTime.add(end_time, -1, :hour)
        :last_24_hours -> DateTime.add(end_time, -1, :day)
        :last_7_days -> DateTime.add(end_time, -7, :day)
        :last_30_days -> DateTime.add(end_time, -30, :day)
        :last_90_days -> DateTime.add(end_time, -90, :day)
      end

    {start_time, end_time}
  end

  # Calculate percentage safely
  defp calculate_percentage(numerator, denominator) when denominator > 0 do
    (numerator / denominator * 100) |> Float.round(1)
  end

  defp calculate_percentage(_, _), do: 0.0

  # Get local engagement data from database
  defp get_local_engagement_data(period) do
    {_start_time, _end_time} = get_time_range(period)
    Log.get_engagement_metrics(period)
  end

  # Calculate engagement trend
  defp calculate_engagement_trend(%{daily_stats: daily_stats})
       when is_list(daily_stats) and length(daily_stats) > 3 do
    # Simple trend calculation
    recent_avg = daily_stats |> Enum.take(-3) |> calculate_avg_engagement()
    earlier_avg = daily_stats |> Enum.take(3) |> calculate_avg_engagement()

    cond do
      recent_avg > earlier_avg + 2 -> :improving
      recent_avg < earlier_avg - 2 -> :declining
      true -> :stable
    end
  end

  defp calculate_engagement_trend(_), do: :stable

  # Calculate average engagement from daily stats
  defp calculate_avg_engagement(daily_stats) do
    if Enum.empty?(daily_stats) do
      0.0
    else
      total_opened = Enum.sum(Enum.map(daily_stats, & &1.opened))
      total_delivered = Enum.sum(Enum.map(daily_stats, & &1.delivered))
      calculate_percentage(total_opened, total_delivered)
    end
  end

  # Get overview metrics
  defp get_overview_metrics(period) do
    PhoenixKit.Emails.get_system_stats(period)
  end

  # Get time series data for charts
  defp get_time_series_data(period) do
    # Use the existing daily delivery trends function from Log module
    trends = Log.get_daily_delivery_trends(period)

    # Transform the data into chart-compatible format
    Enum.zip([trends.labels, trends.delivered, trends.bounced, trends.total_sent])
    |> Enum.map(fn {date, delivered, bounced, total} ->
      %{
        date: date,
        sent: total,
        delivered: delivered,
        bounced: bounced,
        # Calculate rates
        delivery_rate: if(total > 0, do: Float.round(delivered / total * 100, 2), else: 0),
        bounce_rate: if(total > 0, do: Float.round(bounced / total * 100, 2), else: 0)
      }
    end)
  end

  # Get top performing campaigns/templates
  defp get_top_performers(period) do
    {start_date, end_date} = get_time_range(period)

    # Get top campaigns by engagement score
    top_campaigns = get_top_campaigns(start_date, end_date, 10)

    # Get top templates by usage and performance
    top_templates = get_top_templates(start_date, end_date, 10)

    %{
      campaigns: top_campaigns,
      templates: top_templates
    }
  end

  defp get_top_campaigns(start_date, end_date, limit) do
    import Ecto.Query

    # Query for campaigns with calculated engagement metrics
    query =
      from l in Log,
        where: l.sent_at >= ^start_date and l.sent_at <= ^end_date,
        where: not is_nil(l.campaign_id),
        group_by: l.campaign_id,
        select: %{
          campaign_id: l.campaign_id,
          total_sent: count(l.id),
          delivered:
            sum(
              fragment(
                "CASE WHEN ? IN ('delivered', 'opened', 'clicked') THEN 1 ELSE 0 END",
                l.status
              )
            ),
          opened:
            sum(fragment("CASE WHEN ? IN ('opened', 'clicked') THEN 1 ELSE 0 END", l.status)),
          clicked: sum(fragment("CASE WHEN ? = 'clicked' THEN 1 ELSE 0 END", l.status))
        },
        having: count(l.id) > 0,
        limit: ^limit

    repo().all(query)
    |> Enum.map(fn stats ->
      delivered = stats.delivered || 0
      opened = stats.opened || 0
      clicked = stats.clicked || 0
      total = stats.total_sent || 1

      # Calculate engagement score (30% open rate + 70% click rate)
      open_rate = if delivered > 0, do: opened / delivered, else: 0
      click_rate = if opened > 0, do: clicked / opened, else: 0
      engagement_score = (open_rate * 0.3 + click_rate * 0.7) * 100

      %{
        campaign_id: stats.campaign_id,
        total_sent: total,
        delivered: delivered,
        opened: opened,
        clicked: clicked,
        open_rate: Float.round(open_rate * 100, 2),
        click_rate: Float.round(click_rate * 100, 2),
        engagement_score: Float.round(engagement_score, 2)
      }
    end)
    |> Enum.sort_by(& &1.engagement_score, :desc)
    |> Enum.take(limit)
  end

  defp get_top_templates(start_date, end_date, limit) do
    import Ecto.Query

    # Query for templates with usage and performance metrics
    query =
      from l in Log,
        where: l.sent_at >= ^start_date and l.sent_at <= ^end_date,
        where: not is_nil(l.template_name),
        group_by: l.template_name,
        select: %{
          template_name: l.template_name,
          usage_count: count(l.id),
          delivered:
            sum(
              fragment(
                "CASE WHEN ? IN ('delivered', 'opened', 'clicked') THEN 1 ELSE 0 END",
                l.status
              )
            ),
          opened:
            sum(fragment("CASE WHEN ? IN ('opened', 'clicked') THEN 1 ELSE 0 END", l.status)),
          clicked: sum(fragment("CASE WHEN ? = 'clicked' THEN 1 ELSE 0 END", l.status))
        },
        having: count(l.id) > 0,
        order_by: [desc: count(l.id)],
        limit: ^limit

    repo().all(query)
    |> Enum.map(fn stats ->
      delivered = stats.delivered || 0
      opened = stats.opened || 0
      clicked = stats.clicked || 0

      # Calculate performance metrics
      open_rate = if delivered > 0, do: Float.round(opened / delivered * 100, 2), else: 0
      click_rate = if opened > 0, do: Float.round(clicked / opened * 100, 2), else: 0

      %{
        template_name: stats.template_name,
        usage_count: stats.usage_count,
        delivered: delivered,
        opened: opened,
        clicked: clicked,
        open_rate: open_rate,
        click_rate: click_rate
      }
    end)
  end

  # Get provider performance
  defp get_provider_performance(period) do
    Log.get_provider_performance(period)
  end
end
