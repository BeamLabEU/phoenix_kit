defmodule PhoenixKit.EmailSystem.Metrics do
  @moduledoc """
  AWS CloudWatch metrics integration for PhoenixKit email tracking.

  This module provides comprehensive metrics collection and analysis capabilities
  for email performance, deliverability, and engagement tracking through AWS CloudWatch.

  ## Features

  - **AWS SES Metrics**: Direct integration with SES CloudWatch metrics
  - **Custom Metrics**: Application-specific metrics publishing
  - **Reputation Tracking**: Sender reputation and deliverability scores  
  - **Engagement Analysis**: Open rates, click rates, and engagement trends
  - **Geographic Analytics**: Performance by region and country
  - **Provider Analysis**: Deliverability by email provider (Gmail, Outlook, etc.)
  - **Real-time Dashboards**: Data for live monitoring dashboards

  ## Configuration

  Configure AWS credentials and region:

      config :ex_aws,
        access_key_id: {:system, "AWS_ACCESS_KEY_ID"},
        secret_access_key: {:system, "AWS_SECRET_ACCESS_KEY"},
        region: {:system, "AWS_REGION"}

      # Enable CloudWatch metrics in email tracking
      config :phoenix_kit,
        email_cloudwatch_metrics: true

  ## Usage Examples

      # Get basic SES metrics
      {:ok, metrics} = PhoenixKit.EmailSystem.Metrics.get_ses_metrics(:last_24_hours)

      # Get engagement metrics
      engagement = PhoenixKit.EmailSystem.Metrics.get_engagement_metrics(:last_7_days)

      # Publish custom metric
      PhoenixKit.EmailSystem.Metrics.put_custom_metric("EmailOpen", 1, "Count")

      # Get dashboard data
      dashboard = PhoenixKit.EmailSystem.Metrics.get_dashboard_data(:last_30_days)
  """

  require Logger

  alias PhoenixKit.EmailSystem.{EmailEvent, EmailLog}

  ## --- AWS SES Metrics ---

  @deprecated "CloudWatch integration has been discontinued. Use local email system metrics instead."
  @doc """
  Retrieves comprehensive SES metrics from CloudWatch.

  **DEPRECATED**: CloudWatch integration has been discontinued. Use local email system metrics instead.

  ## Parameters

  - `period` - Time period (:last_hour, :last_24_hours, :last_7_days, :last_30_days)
  - `options` - Additional options for filtering and grouping

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.get_ses_metrics(:last_24_hours)
      {:error, :cloudwatch_discontinued}
  """
  def get_ses_metrics(_period \\ :last_24_hours, _options \\ []) do
    {:error, :cloudwatch_discontinued}
  end

  @deprecated "CloudWatch integration has been discontinued. Use local email system metrics instead."
  @doc """
  Gets detailed reputation metrics from AWS SES.

  **DEPRECATED**: CloudWatch integration has been discontinued. Use local email system metrics instead.

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.get_reputation_metrics()
      {:error, :cloudwatch_discontinued}
  """
  def get_reputation_metrics(_period \\ :last_24_hours) do
    {:error, :cloudwatch_discontinued}
  end

  @doc """
  Gets engagement metrics with trend analysis.

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.get_engagement_metrics(:last_7_days)
      %{
        open_rate: 24.5,
        click_rate: 4.2,
        engagement_score: 28.7,
        trend: :improving,
        daily_breakdown: [...]
      }
  """
  def get_engagement_metrics(period \\ :last_7_days) do
    # Use local database engagement data only (CloudWatch integration discontinued)
    local_data = get_local_engagement_data(period)

    # Add trend analysis
    Map.put(local_data, :trend, calculate_engagement_trend(local_data))
  end

  @doc """
  Gets geographic distribution of email engagement.

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.get_geographic_metrics("open", :last_30_days)
      %{
        "US" => %{count: 500, percentage: 45.5},
        "CA" => %{count: 200, percentage: 18.2},
        "UK" => %{count: 150, percentage: 13.6}
      }
  """
  def get_geographic_metrics(event_type, period \\ :last_30_days) do
    {start_time, end_time} = get_time_range(period)

    # Get geo data from local events (CloudWatch doesn't provide geo breakdown)
    geo_data = EmailEvent.get_geo_distribution(event_type, start_time, end_time)

    total_count = Enum.reduce(geo_data, 0, fn {_country, count}, acc -> acc + count end)

    # Add percentages
    geo_data
    |> Enum.into(%{}, fn {country, count} ->
      percentage =
        if total_count > 0, do: (count / total_count * 100) |> Float.round(1), else: 0.0

      {country, %{count: count, percentage: percentage}}
    end)
  end

  ## --- Custom Metrics Publishing ---

  @deprecated "CloudWatch integration has been discontinued. Custom metrics are no longer published."
  @doc """
  Publishes a custom metric to CloudWatch.

  **DEPRECATED**: CloudWatch integration has been discontinued.

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.put_custom_metric("EmailOpen", 1, "Count")
      {:error, :cloudwatch_discontinued}
  """
  def put_custom_metric(_metric_name, _value, _unit \\ "Count", _dimensions \\ []) do
    {:error, :cloudwatch_discontinued}
  end

  @deprecated "CloudWatch integration has been discontinued. Custom metrics are no longer published."
  @doc """
  Publishes multiple custom metrics at once for efficiency.

  **DEPRECATED**: CloudWatch integration has been discontinued.

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.put_custom_metrics(metrics)
      {:error, :cloudwatch_discontinued}
  """
  def put_custom_metrics(metrics) when is_list(metrics) do
    _ = metrics
    {:error, :cloudwatch_discontinued}
  end

  ## --- Dashboard Data ---

  @doc """
  Gets comprehensive dashboard data combining multiple metric sources.

  Returns data optimized for dashboard visualization with time series,
  percentages, trends, and alerts.

  ## Examples

      iex> PhoenixKit.EmailSystem.Metrics.get_dashboard_data(:last_7_days)
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

      iex> PhoenixKit.EmailSystem.Metrics.get_metric_alerts(:last_24_hours)
      [
        %{type: :high_bounce_rate, severity: :warning, value: 5.2, threshold: 5.0},
        %{type: :low_open_rate, severity: :info, value: 15.1, threshold: 20.0}
      ]
  """
  def get_metric_alerts(period \\ :last_24_hours) do
    # Get current metrics - CloudWatch discontinued, return error
    case get_ses_metrics(period) do
      {:error, _reason} ->
        [%{type: :metrics_unavailable, severity: :error, message: "Unable to retrieve metrics"}]
    end
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
    EmailLog.get_engagement_metrics(period)
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
    if length(daily_stats) > 0 do
      total_opened = Enum.sum(Enum.map(daily_stats, & &1.opened))
      total_delivered = Enum.sum(Enum.map(daily_stats, & &1.delivered))
      calculate_percentage(total_opened, total_delivered)
    else
      0.0
    end
  end

  # Get overview metrics
  defp get_overview_metrics(period) do
    case get_ses_metrics(period) do
      {:error, _} -> PhoenixKit.EmailSystem.get_system_stats(period)
    end
  end

  # Get time series data for charts
  defp get_time_series_data(period) do
    {_start_time, _end_time} = get_time_range(period)
    # Placeholder: This would need to be implemented based on your specific needs
    # EmailLog.get_daily_engagement_stats(start_time, end_time)
    []
  end

  # Get top performing campaigns/templates
  defp get_top_performers(period) do
    {_start_time, _end_time} = get_time_range(period)

    # Get top campaigns by open rate
    # This would need to be implemented based on your specific needs
    []
  end

  # Get provider performance
  defp get_provider_performance(period) do
    EmailLog.get_provider_performance(period)
  end
end
