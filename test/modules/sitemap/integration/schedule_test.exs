defmodule PhoenixKit.Modules.Sitemap.ScheduleTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Sitemap.SchedulerWorker
  alias PhoenixKit.Settings

  test "one pending recurrence is shared by scheduling requests and independent of manual jobs" do
    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [], plugins: []})
    {:ok, _} = Settings.update_boolean_setting("sitemap_schedule_enabled", true)

    assert {:ok, manual} = SchedulerWorker.regenerate_now()
    assert {:ok, first} = SchedulerWorker.ensure_scheduled()
    assert {:ok, duplicate} = SchedulerWorker.schedule()
    assert duplicate.id == first.id
    assert :already_scheduled = SchedulerWorker.ensure_scheduled()
    assert %{pending_jobs: 1} = SchedulerWorker.status()

    assert {:ok, 1} = SchedulerWorker.cancel_scheduled()
    assert Repo.get!(Oban.Job, manual.id).state == "available"
    assert %{pending_jobs: 0} = SchedulerWorker.status()
  end
end
