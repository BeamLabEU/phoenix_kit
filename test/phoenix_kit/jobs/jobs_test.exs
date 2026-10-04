defmodule PhoenixKit.JobsTest do
  @moduledoc """
  The public API of job runs: who may start and control one (checked against the
  scope's active role, not an actor uuid), the trusted door for the system, reading
  runs, and running one inline.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Jobs.{Engine, History, Run}
  alias PhoenixKit.Test.JobKinds.{Counter, Guarded}
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.{Scope, User}

  setup do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    :ok
  end

  defp user_with(keys) do
    {:ok, role} = Roles.create_role(%{name: "Jobs #{System.unique_integer([:positive])}"})
    Enum.each(keys, fn key -> {:ok, _} = Permissions.grant_permission(role.uuid, key) end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "jobs-api-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, role.name)
    {Repo.get!(User, user.uuid), role}
  end

  defp scope_with(keys) do
    {user, _role} = user_with(keys)
    Scope.for_user(user)
  end

  defp reload(run), do: Repo.get!(Run, run.uuid)
  defp drain, do: Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)

  describe "starting" do
    test "needs jobs.manage; viewing jobs is not enough" do
      viewer = scope_with(["jobs"])
      assert {:error, :unauthorized} = Jobs.start(viewer, Counter)
      assert Repo.aggregate(Run, :count) == 0
    end

    test "starts a run for someone who may manage jobs, attributed to them, as manual" do
      scope = scope_with(["jobs.manage"])

      assert {:ok, run, :started} = Jobs.start(scope, Counter, :site, args: %{steps: 2})
      assert run.started_by_uuid == Scope.user_uuid(scope)
      assert run.mode == "manual"
      assert [%{actor_uuid: actor}] = History.for_run(run.uuid)
      assert actor == Scope.user_uuid(scope)
    end

    test "a kind may name a permission of its own on top" do
      only_jobs = scope_with(["jobs.manage"])
      both = scope_with(["jobs.manage", "media.manage"])

      assert {:error, :unauthorized} = Jobs.start(only_jobs, Guarded)
      assert {:ok, _run, :started} = Jobs.start(both, Guarded)
    end

    test "a kind can be given by name, and an unknown one is refused" do
      scope = scope_with(["jobs.manage"])

      assert {:ok, _run, :started} = Jobs.start(scope, "test.counter")
      assert {:error, :unknown_kind} = Jobs.start(scope, "nope.nope")
      assert {:error, :unknown_kind} = Jobs.start(scope, NotAKind)
    end

    test "nobody who is not signed in may" do
      assert {:error, :unauthorized} = Jobs.start(Scope.for_user(nil), Counter)
    end

    test "someone acting through a restricted active role may not: the scope is the active role's" do
      admin_role = Roles.get_role_by_name("Admin")
      {:ok, _} = Permissions.grant_permission(admin_role.uuid, "jobs.manage")

      {user, restricted} = user_with(["dashboard"])
      {:ok, _} = Roles.assign_role(user, "Admin")
      user = Repo.get!(User, user.uuid)
      {:ok, _} = PhoenixKit.Settings.update_boolean_setting("role_switcher_enabled", true)

      # acting as everything they hold, they may
      full = Scope.for_user(user)
      assert Scope.can?(full, "jobs.manage")
      assert {:ok, run, :started} = Jobs.start(full, Counter)

      # acting as the restricted role, they may not — whatever else they hold
      narrowed = Scope.for_user(%{user | active_role_uuid: restricted.uuid})
      refute Scope.can?(narrowed, "jobs.manage")
      assert {:error, :unauthorized} = Jobs.pause(narrowed, run)
      assert {:error, :unauthorized} = Jobs.cancel(narrowed, run)

      assert {:error, :unauthorized} =
               Jobs.start(narrowed, Counter, {"library", Ecto.UUID.generate()})

      assert reload(run).state == "queued"
    end
  end

  describe "the Owner, acting through a restricted active role" do
    test "holds every control as themselves, and none while acting as the narrower role" do
      owner = Repo.get!(User, Auth.get_user_by_email("seed-owner@phoenixkit.test").uuid)
      {:ok, role} = Roles.create_role(%{name: "Narrow #{System.unique_integer([:positive])}"})
      {:ok, _} = Permissions.grant_permission(role.uuid, "dashboard")
      {:ok, _} = Roles.assign_role(owner, role.name)
      {:ok, _} = PhoenixKit.Settings.update_boolean_setting("role_switcher_enabled", true)
      owner = Repo.get!(User, owner.uuid)

      full = Scope.for_user(owner)
      assert Scope.owner?(full)
      assert {:ok, run, :started} = Jobs.start(full, Counter)
      assert {:ok, %{state: "paused"}} = Jobs.pause(full, run)

      narrowed = Scope.for_user(%{owner | active_role_uuid: role.uuid})
      refute Scope.owner?(narrowed), "acting as the narrower role, they are not the Owner"
      assert "Owner" in Scope.held_roles(narrowed), "the roles they hold are unchanged"
      refute Scope.can?(narrowed, "jobs.manage")

      assert {:error, :unauthorized} = Jobs.resume(narrowed, run)
      assert {:error, :unauthorized} = Jobs.cancel(narrowed, run)

      assert {:error, :unauthorized} =
               Jobs.start(narrowed, Counter, {"library", Ecto.UUID.generate()})

      assert [] = Jobs.controls_for(narrowed, reload(run))
      assert %{state: "paused"} = reload(run)
    end
  end

  describe "controls" do
    setup do
      scope = scope_with(["jobs.manage"])
      {:ok, run, :started} = Jobs.start(scope, Counter, :site, args: %{steps: 2})
      %{scope: scope, run: run}
    end

    test "pause, resume and cancel, attributed to the person", %{scope: scope, run: run} do
      actor = Scope.user_uuid(scope)

      assert {:ok, %{state: "paused", paused_by_uuid: ^actor}} = Jobs.pause(scope, run)
      assert {:ok, %{state: "queued"}} = Jobs.resume(scope, run.uuid)
      assert {:ok, %{state: "cancelled", cancelled_by_uuid: ^actor}} = Jobs.cancel(scope, run)

      assert History.for_run(run.uuid) |> Enum.map(& &1.action) ==
               ["job.started", "job.paused", "job.resumed", "job.cancelled"]
    end

    test "viewing is not controlling", %{run: run} do
      viewer = scope_with(["jobs"])

      for fun <- [&Jobs.pause/2, &Jobs.resume/2, &Jobs.cancel/2, &Jobs.retry/2] do
        assert {:error, :unauthorized} = fun.(viewer, run)
      end

      assert reload(run).state == "queued"
    end

    test "a run that is not there", %{scope: scope} do
      assert {:error, :not_found} = Jobs.pause(scope, Ecto.UUID.generate())
      assert {:error, :not_found} = Jobs.pause(scope, "not a uuid")
    end

    test "says why the state does not allow it", %{scope: scope, run: run} do
      assert {:error, :not_paused} = Jobs.resume(scope, run)
      {:ok, _} = Jobs.cancel(scope, run)
      assert {:error, :finished} = Jobs.cancel(scope, run)
      assert {:error, :finished} = Jobs.pause(scope, run)
    end

    test "resume is refused while the batch is draining", %{scope: scope, run: run} do
      {:ok, _, _token} = Engine.claim(run.uuid, 1)
      assert {:ok, %{state: "pausing"}} = Jobs.pause(scope, run)
      assert {:error, :draining} = Jobs.resume(scope, run)
    end

    test "a kind offers only the controls it names" do
      scope = scope_with(["jobs.manage", "media.manage"])
      {:ok, run, :started} = Jobs.start(scope, Guarded)
      {:ok, _} = Jobs.pause(scope, run)

      assert {:error, :control_not_offered} = Jobs.resume(scope, run)
      assert {:ok, %{state: "cancelled"}} = Jobs.cancel(scope, run)
      assert {:error, :control_not_offered} = Jobs.retry(scope, run)
    end

    test "a kind's own permission applies to its controls too" do
      scope = scope_with(["jobs.manage", "media.manage"])
      {:ok, run, :started} = Jobs.start(scope, Guarded)
      jobs_only = scope_with(["jobs.manage"])

      assert {:error, :unauthorized} = Jobs.pause(jobs_only, run)
      assert {:ok, %{state: "paused"}} = Jobs.pause(scope, run)
    end
  end

  describe "retry" do
    test "starts a new run like a failed or cancelled one, and never changes the old", %{} do
      scope = scope_with(["jobs.manage"])
      {:ok, run, :started} = Jobs.start(scope, Counter, :site, args: %{steps: 2, raise_at: 0})
      drain()
      assert %{state: "failed"} = reload(run)

      assert {:ok, again, :started} = Jobs.retry(scope, run)
      assert again.uuid != run.uuid
      assert again.args["retry_of"] == run.uuid
      assert again.args["steps"] == 2
      assert reload(run).state == "failed"
    end

    test "only a failed or cancelled run" do
      scope = scope_with(["jobs.manage"])
      {:ok, run, :started} = Jobs.start(scope, Counter)

      assert {:error, :not_retryable} = Jobs.retry(scope, run)
    end
  end

  describe "the system door" do
    test "starts a run with no actor, as auto by default, and says where it came from" do
      assert {:ok, run, :started} = Jobs.System.start(Counter, :site, source: "profile revision")

      assert %{mode: "auto", started_by_uuid: nil} = run
      assert run.args["source"] == "profile revision"
      assert [%{actor_uuid: nil, mode: "auto"}] = History.for_run(run.uuid)
    end

    test "takes cron and script modes, and refuses any other" do
      assert {:ok, %{mode: "cron"}, :started} = Jobs.System.start(Counter, :site, mode: :cron)

      assert {:ok, %{mode: "script"}, :started} =
               Jobs.System.start(Counter, {"library", Ecto.UUID.generate()}, mode: :script)

      assert {:error, :invalid_mode} = Jobs.System.start(Counter, :site, mode: :manual)
      assert {:error, :invalid_mode} = Jobs.System.start(Counter, :site, mode: "auto")
    end
  end

  describe "reading" do
    setup do
      library = Ecto.UUID.generate()
      {:ok, a, _} = Jobs.System.start(Counter, :site)
      {:ok, b, _} = Jobs.System.start(Counter, {"library", library}, args: %{steps: 1})
      {:ok, c, _} = Jobs.System.start(PhoenixKit.Test.JobKinds.Restarting, :site)
      %{a: a, b: b, c: c, library: library}
    end

    test "lists newest first, filtered", %{a: a, b: b, c: c, library: library} do
      assert Jobs.list_runs() |> Enum.map(& &1.uuid) == [c.uuid, b.uuid, a.uuid]
      assert Jobs.list_runs(kind: "test.counter") |> Enum.map(& &1.uuid) == [b.uuid, a.uuid]
      assert Jobs.list_runs(scope: :site) |> Enum.map(& &1.uuid) == [c.uuid, a.uuid]
      assert Jobs.list_runs(scope: {"library", library}) |> Enum.map(& &1.uuid) == [b.uuid]
      assert Jobs.list_runs(module: "test") |> length() == 3
      assert Jobs.list_runs(module: "other") == []
    end

    test "filters by state and counts and pages", %{a: a} do
      {:ok, _} = Engine.transition(a.uuid, {:cancel, nil})

      assert Jobs.count_runs() == 3
      assert Jobs.count_runs(state: :active) == 2
      assert Jobs.count_runs(state: "cancelled") == 1
      assert Jobs.count_runs(state: ["cancelled", "queued"]) == 3
      assert length(Jobs.list_runs(limit: 2)) == 2
      assert length(Jobs.list_runs(limit: 2, offset: 2)) == 1
    end

    test "finds one run, the active run of a kind, and a run's history", %{a: a} do
      assert Jobs.get_run(a.uuid).uuid == a.uuid
      assert Jobs.get_run("nope") == nil
      assert Jobs.active_run(Counter, :site).uuid == a.uuid
      assert Jobs.active_run("test.counter", :site).uuid == a.uuid
      assert Jobs.active_run(Counter, {"library", Ecto.UUID.generate()}) == nil
      assert [%{action: "job.started"}] = Jobs.history(a)
    end
  end

  describe "run_inline/3" do
    test "runs to the end in the calling process, in script mode, without an Oban job" do
      assert {:ok, %Run{state: "completed", done: 30, mode: "script", claim_token: nil} = run} =
               Jobs.run_inline(Counter, :site, args: %{steps: 3})

      assert Repo.aggregate(
               from(j in Oban.Job, where: j.worker == "PhoenixKit.Jobs.RunWorker"),
               :count
             ) == 0

      assert [%{mode: "script"}, %{action: "job.completed", mode: "script"}] =
               History.for_run(run.uuid)
    end

    test "fails the run on an error: there is no Oban to retry it" do
      assert {:ok, %Run{state: "failed", error: error}} =
               Jobs.run_inline(Counter, :site, args: %{steps: 3, error_at: 1})

      assert error =~ "no luck at step 1"
    end

    test "a raise is an error too" do
      assert {:ok, %Run{state: "failed", error: error}} =
               Jobs.run_inline(Counter, :site, args: %{raise_at: 0})

      assert error =~ "boom"
    end

    test "refuses a run a batch holds" do
      {:ok, run, _} = Jobs.System.start(Counter, :site)
      {:ok, _, _token} = Engine.claim(run.uuid, 1)

      assert {:error, :claimed} = Jobs.run_inline(Counter, :site)
    end

    test "stops where someone else paused it" do
      {:ok, run, _} = Jobs.System.start(Counter, :site)
      {:ok, _} = Engine.transition(run.uuid, {:pause, nil})

      assert {:ok, %Run{state: "paused"}} = Jobs.run_inline(Counter, :site)
    end
  end

  test "Jobs is always on" do
    # the deprecated functions of the module this used to be still answer
    assert Jobs.enabled?()
    assert {:ok, :always_on} = Jobs.disable_system()
    assert Jobs.enabled?()
    assert %{enabled: true, stats: %{available: _}} = Jobs.get_config()
  end
end
