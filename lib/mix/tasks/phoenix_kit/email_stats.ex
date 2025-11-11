defmodule Mix.Tasks.PhoenixKit.Email.Stats do
  @shortdoc "Display email system statistics"

  @moduledoc """
  Mix task to display comprehensive email system statistics.

  ## Usage

      # Show default stats (last 30 days)
      mix phoenix_kit.email.stats

      # Show stats for specific date range
      mix phoenix_kit.email.stats --from 2025-01-01 --to 2025-01-31

      # Show stats for specific campaign
      mix phoenix_kit.email.stats --campaign welcome-series

      # Show detailed breakdown
      mix phoenix_kit.email.stats --detailed

  ## Options

      --from DATE           Start date (YYYY-MM-DD format)
      --to DATE             End date (YYYY-MM-DD format)  
      --campaign ID         Show stats for specific campaign
      --detailed            Show detailed breakdown by provider/template
      --format FORMAT       Output format: table (default), csv, json

  ## Examples

      # Last 7 days summary
      mix phoenix_kit.email.stats --from $(date -d '7 days ago' '+%Y-%m-%d')

      # Export campaign stats to CSV
      mix phoenix_kit.email.stats --campaign newsletter --format csv > campaign_stats.csv

      # Detailed breakdown with provider performance
      mix phoenix_kit.email.stats --detailed
  """

  use Mix.Task
  alias PhoenixKit.Emails

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {options, _remaining} = parse_options(args)

    unless Emails.enabled?() do
      Mix.shell().error("Email is not enabled. Enable it first with:")
      Mix.shell().info("  PhoenixKit.Emails.enable_system()")
      exit({:shutdown, 1})
    end

    case options[:format] do
      "csv" -> show_csv_stats(options)
      "json" -> show_json_stats(options)
      _ -> show_table_stats(options)
    end
  end

  defp parse_options(args) do
    {options, remaining, _errors} =
      OptionParser.parse(args,
        strict: [
          from: :string,
          to: :string,
          campaign: :string,
          detailed: :boolean,
          format: :string
        ]
      )

    # Set defaults
    options =
      options
      |> Keyword.put_new(:format, "table")
      |> Keyword.put_new(:detailed, false)

    {options, remaining}
  end

  defp show_table_stats(options) do
    stats = get_stats_data(options)

    Mix.shell().info(IO.ANSI.cyan() <> "\n📧 Email Statistics" <> IO.ANSI.reset())
    Mix.shell().info(String.duplicate("=", 50))

    # General stats
    Mix.shell().info("\n📊 Overview:")
    Mix.shell().info("  Total Sent:     #{format_number(stats.total_sent)}")

    Mix.shell().info(
      "  Delivered:      #{format_number(stats.delivered)} (#{format_percentage(stats.delivery_rate)})"
    )

    Mix.shell().info(
      "  Bounced:        #{format_number(stats.bounced)} (#{format_percentage(stats.bounce_rate)})"
    )

    Mix.shell().info(
      "  Complaints:     #{format_number(stats.complaints)} (#{format_percentage(stats.complaint_rate)})"
    )

    if stats.total_opened > 0 do
      Mix.shell().info(
        "  Opened:         #{format_number(stats.total_opened)} (#{format_percentage(stats.open_rate)})"
      )
    end

    if stats.total_clicked > 0 do
      Mix.shell().info(
        "  Clicked:        #{format_number(stats.total_clicked)} (#{format_percentage(stats.click_rate)})"
      )
    end

    if options[:detailed] do
      show_detailed_breakdown(stats)
    end

    if options[:campaign] do
      Mix.shell().info("\n📈 Campaign: #{options[:campaign]}")
    end

    Mix.shell().info("\n✅ Statistics generated successfully")
  end

  defp show_detailed_breakdown(stats) do
    if Map.has_key?(stats, :by_provider) and stats.by_provider != [] do
      Mix.shell().info("\n🔧 By Provider:")

      for {provider, provider_stats} <- stats.by_provider do
        Mix.shell().info(
          "  #{String.pad_trailing(provider, 15)} #{format_number(provider_stats.sent)} sent, #{format_percentage(provider_stats.delivery_rate)} delivery"
        )
      end
    end

    if Map.has_key?(stats, :by_template) and stats.by_template != [] do
      Mix.shell().info("\n📝 Top Templates:")

      stats.by_template
      |> Enum.take(5)
      |> Enum.each(fn {template, template_stats} ->
        Mix.shell().info(
          "  #{String.pad_trailing(template || "unknown", 20)} #{format_number(template_stats.sent)} sent"
        )
      end)
    end
  end

  defp show_csv_stats(options) do
    stats = get_stats_data(options)

    # CSV Header
    Mix.shell().info("metric,value,percentage")

    # CSV Data
    Mix.shell().info("total_sent,#{stats.total_sent},")
    Mix.shell().info("delivered,#{stats.delivered},#{stats.delivery_rate}")
    Mix.shell().info("bounced,#{stats.bounced},#{stats.bounce_rate}")
    Mix.shell().info("complaints,#{stats.complaints},#{stats.complaint_rate}")
    Mix.shell().info("opened,#{stats.total_opened || 0},#{stats.open_rate || 0}")
    Mix.shell().info("clicked,#{stats.total_clicked || 0},#{stats.click_rate || 0}")
  end

  defp show_json_stats(options) do
    stats = get_stats_data(options)

    json_output = Jason.encode!(stats, pretty: true)
    Mix.shell().info(json_output)
  end

  defp get_stats_data(options) do
    period = determine_period(options)

    base_stats = Emails.get_system_stats(period)

    stats =
      if options[:detailed] do
        Map.merge(base_stats, %{
          by_provider: Emails.get_provider_performance(period),
          by_template: get_template_stats(period)
        })
      else
        base_stats
      end

    if options[:campaign] do
      Emails.get_campaign_stats(options[:campaign])
    else
      stats
    end
  end

  defp determine_period(options) do
    cond do
      options[:from] && options[:to] ->
        {:date_range, Date.from_iso8601!(options[:from]), Date.from_iso8601!(options[:to])}

      options[:from] ->
        {:date_range, Date.from_iso8601!(options[:from]), Date.utc_today()}

      true ->
        :last_30_days
    end
  end

  defp get_template_stats(period) do
    PhoenixKit.Emails.get_template_stats(period)
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
