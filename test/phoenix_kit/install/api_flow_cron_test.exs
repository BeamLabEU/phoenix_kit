defmodule PhoenixKit.Install.ApiFlowCronTest do
  @moduledoc """
  The three cron workers of the dangerous-operation flow reach a host that installed
  core before they existed, once, without touching a schedule the host wrote, and never
  when the host commented the entry out.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PhoenixKit.Install.ObanConfig

  @workers [
    {"35 4 * * *", "PhoenixKit.API.Idempotency.PruneWorker"},
    {"*/5 * * * *", "PhoenixKit.API.Confirm.ExpiryWorker"},
    {"40 4 * * *", "PhoenixKit.API.Confirm.PruneWorker"},
    {"50 4 * * *", "PhoenixKit.API.OAuth.PruneWorker"}
  ]

  @host """
  config :my_app, Oban,
    repo: MyApp.Repo,
    plugins: [
      {Oban.Plugins.Cron,
       crontab: [
         {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
       ]}
    ]
  """

  defp quiet(fun) do
    capture_io(:stderr, fn -> capture_io(fn -> send(self(), {:result, fun.()}) end) end)

    receive do
      {:result, result} -> result
    end
  end

  defp backfill(content),
    do: quiet(fn -> ObanConfig.ensure_worker_cron_entries(content, "my_app") end)

  test "an existing host gains the three entries" do
    updated = backfill(@host)

    for {cron, worker} <- @workers do
      assert updated =~ ~s({"#{cron}", #{worker}}), worker
    end

    assert {:ok, _} = Code.string_to_quoted(updated)
  end

  test "running it again changes nothing" do
    once = backfill(@host)
    assert backfill(once) == once
  end

  test "a schedule the host wrote is kept" do
    host =
      String.replace(
        @host,
        "{\"* * * * *\"",
        "{\"15 5 * * *\", PhoenixKit.API.Confirm.ExpiryWorker},\n         {\"* * * * *\""
      )

    updated = backfill(host)

    assert updated =~ ~s({"15 5 * * *", PhoenixKit.API.Confirm.ExpiryWorker})
    refute updated =~ ~s({"*/5 * * * *", PhoenixKit.API.Confirm.ExpiryWorker})
  end

  test "an entry the host commented out stays out" do
    host =
      String.replace(
        @host,
        "crontab: [",
        "crontab: [\n         # {\"35 4 * * *\", PhoenixKit.API.Idempotency.PruneWorker},"
      )

    updated = backfill(host)

    refute updated =~ ~r/^\s*\{"35 4 \* \* \*", PhoenixKit.API.Idempotency.PruneWorker\}/m
    assert updated =~ "PhoenixKit.API.Confirm.ExpiryWorker"
  end

  test "every schedule parses as an Oban cron expression" do
    for {cron, _worker} <- @workers, do: assert({:ok, _} = Oban.Cron.parse(cron))
  end

  test "every worker is a loaded Oban worker" do
    for {_cron, worker} <- @workers do
      module = Module.concat([worker])
      assert Code.ensure_loaded?(module), worker
      assert function_exported?(module, :perform, 1), worker
    end
  end
end
