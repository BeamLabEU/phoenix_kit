defmodule PhoenixKit.Install.ObanCronBackfillSyncTest do
  # A worker added to the generated crontab but not to the backfill list never
  # reaches a host that installed earlier: `ensure_cron_plugin/2` stops once
  # `ProcessScheduledJobsWorker` is present. That is how `PruneTrashJob` and
  # `Notifications.PruneWorker` went unscheduled on older hosts, and how
  # `Activity.PruneWorker` ended up in no crontab at all.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PhoenixKit.Install.ObanConfig

  @source File.read!(Path.expand("../../../lib/phoenix_kit/install/oban_config.ex", __DIR__))

  # Entries that are not plain `{cron, Worker}` tuples, each with its own
  # backfill (`ensure_cron_plugin/2`, `ensure_digest_cron_entries/2`).
  @not_in_worker_list [
    "PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker",
    "PhoenixKit.Notifications.DigestWorker"
  ]

  # `{"cron", PhoenixKit.Some.Worker}` as written in the two crontab texts
  # (the generated config and the manual instructions): the module is bare.
  defp crontab_modules(text),
    do:
      ~r/\{"[^"]+",\s+(PhoenixKit(?:\.\w+)+)[,}]/
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

  # The backfill list names its modules as strings.
  defp backfilled_modules do
    [_, list] = Regex.run(~r/@worker_cron_entries \[(.*?)\n    \]/s, @source)

    ~r/\{"[^"]+",\s+"(PhoenixKit(?:\.\w+)+)"\}/
    |> Regex.scan(list, capture: :all_but_first)
    |> List.flatten()
    |> Enum.sort()
  end

  # The two texts that carry a crontab: the generated config, then the manual
  # instructions shown when Oban could not be configured.
  defp templates do
    [generated, manual] = Regex.scan(~r/\{Oban\.Plugins\.Cron,\s+crontab: \[.*?\]\}/s, @source)
    [List.first(generated), List.first(manual)]
  end

  describe "the generated crontab and the backfill list" do
    test "every worker in the generated crontab is backfilled to existing hosts" do
      [generated, _manual] = templates()

      wanted = crontab_modules(generated) -- @not_in_worker_list
      missing = wanted -- backfilled_modules()

      assert missing == [],
             "in the generated crontab but not in @worker_cron_entries (an existing host " <>
               "never gains them): #{Enum.join(missing, ", ")}"
    end

    test "every worker whose docs say it runs on a schedule is in the generated crontab" do
      [generated, _manual] = templates()

      # `Activity.PruneWorker` said "Runs daily" for months while no crontab
      # scheduled it, so a list-against-list check alone cannot see it.
      claims_a_schedule =
        ~r/runs (daily|hourly|every)|daily, by cron|via cron|^\s*Cron, every|from Oban's cron|by cron/im

      scheduled =
        for file <- Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__)),
            source = File.read!(file),
            source =~ "use Oban.Worker",
            source =~ claims_a_schedule,
            [_, module] = Regex.run(~r/^defmodule ([\w.]+)/m, source),
            do: module

      assert scheduled != []
      assert scheduled -- crontab_modules(generated) == []
    end

    test "the manual instructions list the same entries as the generated config" do
      [generated, manual] = templates()

      assert crontab_modules(manual) == crontab_modules(generated)
    end

    test "every backfilled worker is in the generated crontab" do
      [generated, _manual] = templates()

      assert backfilled_modules() -- crontab_modules(generated) == []
    end
  end

  describe "a host that installed before these workers existed" do
    @old_host """
    import Config

    config :my_app, Oban,
      repo: MyApp.Repo,
      plugins: [
        {Oban.Plugins.Cron,
         crontab: [
           {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
         ]}
      ]
    """

    @scheduled_since_install [
      "PhoenixKit.Modules.Storage.Workers.PruneTrashJob",
      "PhoenixKit.Notifications.PruneWorker",
      "PhoenixKit.Activity.PruneWorker"
    ]

    test "gains the trash/reconcile driver, the notification prune and the activity prune" do
      updated = backfill(@old_host)

      for mod <- @scheduled_since_install do
        assert updated =~ mod, "#{mod} was not added"
      end

      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "a second run changes nothing" do
      once = backfill(@old_host)

      assert backfill(once) == once
    end

    test "an entry the host commented out is declined, not put back" do
      content =
        String.replace(
          @old_host,
          ~s|ProcessScheduledJobsWorker}\n|,
          ~s|ProcessScheduledJobsWorker},\n       # {"10 4 * * *", PhoenixKit.Activity.PruneWorker}\n|
        )

      updated = backfill(content)

      refute updated =~ ~r/^\s*\{"10 4 \* \* \*", PhoenixKit\.Activity\.PruneWorker\}/m
      assert updated =~ "PhoenixKit.Modules.Storage.Workers.PruneTrashJob"
    end
  end

  defp backfill(content) do
    capture_io(fn ->
      send(self(), {:out, ObanConfig.ensure_worker_cron_entries(content, "my_app")})
    end)

    receive do
      {:out, updated} -> updated
    end
  end
end
