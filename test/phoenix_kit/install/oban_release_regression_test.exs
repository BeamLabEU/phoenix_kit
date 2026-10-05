defmodule PhoenixKit.Install.ObanReleaseRegressionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PhoenixKit.Install.ConfigVerify
  alias PhoenixKit.Install.ObanConfig

  defp backfill(content, fun) do
    capture_io(fn ->
      capture_io(:stderr, fn -> send(self(), {:updated, fun.(content, "myapp")}) end)
    end)

    assert_received {:updated, updated}
    updated
  end

  defp scheduled?(content, module) do
    {:ok, ast} = Code.string_to_quoted(content)

    ConfigVerify.app_config_satisfies?(ast, :myapp, Oban, :crontab, fn list ->
      Enum.any?(list, &ConfigVerify.tuple_names_module?(&1, module))
    end)
  end

  test "an aliased digest cadence leaves room to backfill the other cadences" do
    content = """
    import Config
    alias PhoenixKit.Notifications.DigestWorker, as: D
    config :myapp, Oban,
      plugins: [{Oban.Plugins.Cron, crontab: [
        {"0 * * * *", D, args: %{cadence: "hourly"}}
      ]}]
    """

    updated = backfill(content, &ObanConfig.ensure_digest_cron_entries/2)

    for cadence <- ~w(12h daily weekly), do: assert(updated =~ ~s(cadence: "#{cadence}"))
    assert length(Regex.scan(~r/cadence: "hourly"/, updated)) == 1
    assert ObanConfig.take_manual_steps() == []
    assert backfill(updated, &ObanConfig.ensure_digest_cron_entries/2) == updated
  end

  test "a digest worker in another job's arguments does not schedule a digest" do
    content = """
    config :myapp, Oban,
      plugins: [{Oban.Plugins.Cron, crontab: [
        {"* * * * *", MyApp.Other, args: %{handler: PhoenixKit.Notifications.DigestWorker, next_args: %{cadence: "daily"}}}
      ]}]
    """

    updated = backfill(content, &ObanConfig.ensure_digest_cron_entries/2)
    assert updated =~ ~s({"0 6 * * *", PhoenixKit.Notifications.DigestWorker)
  end

  for {name, worker, args} <- [
        {"a module in job arguments", "MyApp.Other",
         ", args: %{handler: PhoenixKit.Jobs.SweepWorker}"},
        {"a longer module name", "PhoenixKit.Jobs.SweepWorkerExtra", ""},
        {"an aliased module in job arguments", "MyApp.Other", ", args: %{handler: SweepWorker}"}
      ] do
    test "#{name} does not stand in for scheduling the sweeper" do
      content = """
      alias PhoenixKit.Jobs.SweepWorker
      config :myapp, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: [
          {"* * * * *", #{unquote(worker)}#{unquote(args)}}
        ]}]
      """

      updated = backfill(content, &ObanConfig.ensure_worker_cron_entries/2)
      assert scheduled?(updated, PhoenixKit.Jobs.SweepWorker)
      assert backfill(updated, &ObanConfig.ensure_worker_cron_entries/2) == updated
    end
  end
end
