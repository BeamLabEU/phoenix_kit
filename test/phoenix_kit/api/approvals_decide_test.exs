defmodule PhoenixKit.API.ApprovalsDecideTest do
  @moduledoc """
  Approving and rejecting: authority, double decisions, and the checks an approval
  repeats at decision time (rights, tool, input, values). In every refusal nothing is
  written; the store of the `flowkit` test tools and the handler messages prove it.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.Test.ApiFlowHarness

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuthTestSupport
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Test.ApiFlowStore
  alias PhoenixKit.Test.ApiFlowTools
  alias PhoenixKit.Test.ApiHarness
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions

  @delete "flowkit.delete_items"
  @all_items %{"a" => 100, "b" => 200, "c" => 300}

  setup do
    setup_flow()
    owner = KeyTestSupport.owner_user()
    %{agent: agent(), owner: owner, owner_scope: KeyTestSupport.scope_of(owner)}
  end

  defp pending!(agent, tool \\ @delete, input \\ %{"ids" => ["a", "b"]}) do
    {:ok, row, :created} = queue(agent, tool, input)
    row
  end

  defp reload(row), do: Repo.get!(Confirmation, row.uuid)
  defp error_code(row), do: get_in(reload(row).result, ["error", "code"])

  defp assert_nothing_written(row) do
    assert ApiFlowStore.items() == @all_items
    refute_received {:flow, _tool, _input, %{dry_run?: false}}
    assert reload(row).input == nil
  end

  describe "approve/3" do
    test "credentials in progress never reach the row or a failed result", %{
      agent: agent,
      owner_scope: scope
    } do
      ApiFlowStore.set_gate(self())

      row =
        pending!(agent, "flowkit.progress_write", %{
          "hold" => true,
          "fail" => true,
          "credentials" => true
        })

      caller = Task.async(fn -> Approvals.approve(row.uuid, scope) end)
      assert_receive {:held, worker}, 5_000

      assert get_in(reload(row).result, ["partial", "rows"]) == [
               %{"Access_Token" => "[REDACTED]"}
             ]

      send(worker, :release)
      assert {:ok, done} = Task.await(caller, 5_000)
      assert done.status == "failed"
      assert done.result["partial"]["done"] == 1
      refute JSON.encode!(reload(row).result) =~ "private-progress-token"
    end

    test "credential-bearing results are redacted before storage and polling", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent, "flowkit.misbehave", %{"mode" => "leak"})
      assert {:ok, done} = Approvals.approve(row.uuid, scope)
      assert done.status == "executed"
      assert done.result == %{"session_token" => "[REDACTED]"}
      assert reload(row).result == done.result

      view = row.uuid |> Approvals.get_for_key(agent.key.uuid) |> Approvals.status_view()
      refute JSON.encode!(view) =~ "leaked-session-token"
      assert ApiFlowStore.calls() == 1
    end

    test "a field the tool declares in its credentials is redacted from the stored result", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent, "flowkit.misbehave", %{"mode" => "leak_link"})
      assert {:ok, done} = Approvals.approve(row.uuid, scope)
      assert done.status == "executed"
      assert done.result == %{"link" => "[REDACTED]", "ok" => true}
      refute JSON.encode!(reload(row).result) =~ "example.test/open"
    end

    test "runs the tool for the key's owner, with the original request's context", %{
      agent: agent,
      owner: owner,
      owner_scope: scope
    } do
      row = pending!(agent)

      assert {:ok, done} = Approvals.approve(row.uuid, scope)

      assert done.status == "executed"
      assert done.result == %{"deleted" => 2}
      assert done.input == nil
      assert done.decided_by_uuid == owner.uuid
      assert %DateTime{} = done.decided_at
      assert ApiFlowStore.items() == %{"c" => 300}

      assert_received {:flow, @delete, %{"ids" => ["a", "b"]}, %{dry_run?: false} = ctx}
      assert ctx.actor.user_uuid == agent.owner.uuid
      assert ctx.actor.key_uuid == agent.key.uuid
      assert ctx.approved_by_uuid == owner.uuid
      assert ctx.confirmation_uuid == row.uuid
      assert ctx.audience == :admin
      assert ctx.language == "en"
      assert ctx.base_url == "https://shop.example"
      assert ctx.request_id == "req-test"
      assert is_function(ctx.progress, 1)
      assert Enum.sort(ctx.scopes) == Enum.sort(scopes())
    end

    test "the effects of the tool are kept with the result", %{agent: agent, owner_scope: scope} do
      row =
        pending!(agent, "flowkit.set_values", %{"changes" => [%{"id" => "a", "value" => 110}]})

      assert {:ok, done} = Approvals.approve(row.uuid, scope)

      assert done.status == "executed"
      assert done.result == %{"updated" => 1, "effects" => [%{"code" => "reindex_queued"}]}
      assert ApiFlowStore.items()["a"] == 110
    end

    test "the creator of the key may approve it", %{agent: agent} do
      row = pending!(agent)
      assert {:ok, %{status: "executed"}} = Approvals.approve(row.uuid, agent.scope)
    end

    test "writes a permanent decision entry and an outcome entry", %{
      agent: agent,
      owner: owner,
      owner_scope: scope
    } do
      row = pending!(agent)
      {:ok, _done} = Approvals.approve(row.uuid, scope)

      entries =
        Repo.all(
          from(e in Entry,
            where: e.resource_uuid == ^row.uuid and e.module == "api",
            order_by: e.inserted_at
          )
        )

      by_action = Map.new(entries, &{&1.action, &1})

      decided = by_action["api.approval_decided"]
      assert decided.permanent
      assert decided.actor_uuid == owner.uuid
      assert decided.metadata["decision"] == "approved"
      assert decided.metadata["tool"] == @delete
      assert decided.metadata["key_prefix"] == agent.key.prefix

      finished = by_action["api.approval_finished"]
      assert finished.metadata["status"] == "executed"
      assert finished.metadata["approved_by_uuid"] == owner.uuid
    end

    test "announces the decision and the outcome", %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      PubSub.subscribe("phoenix_kit:api:approvals")
      uuid = row.uuid

      {:ok, _done} = Approvals.approve(uuid, scope)

      assert_receive {:api_approval_changed, ^uuid}
      assert_receive {:api_approval_changed, ^uuid}
    end

    test "the finished approval reads back through the agent's view", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      {:ok, _done} = Approvals.approve(row.uuid, scope)

      view = row.uuid |> Approvals.get_for_key(agent.key.uuid) |> Approvals.status_view()
      assert %{"status" => "executed", "result" => %{"deleted" => 2}} = view
    end
  end

  describe "approve/3 refusals" do
    test "an unknown id, a malformed id and a confirmation code are not_found", %{
      agent: agent,
      owner_scope: scope
    } do
      {:ok, issued} =
        Confirm.issue_token(
          agent.actor,
          @delete,
          String.duplicate("1", 64),
          %{},
          String.duplicate("f", 64)
        )

      assert {:error, :not_found} = Approvals.approve(UUIDv7.generate(), scope)
      assert {:error, :not_found} = Approvals.approve("nope", scope)
      assert {:error, :not_found} = Approvals.approve(nil, scope)
      assert {:error, :not_found} = Approvals.approve(issued.row.uuid, scope)
    end

    test "someone who may not decide is forbidden and nothing happens", %{agent: agent} do
      row = pending!(agent)
      {other, _role} = ApiHarness.user_with(["settings", "dashboard"])
      stranger = KeyTestSupport.register_user!()

      assert :ok = Permissions.revoke_permission(agent.role.uuid, "settings")

      for person <- [other, stranger, agent.owner] do
        assert {:error, :forbidden} = Approvals.approve(row.uuid, KeyTestSupport.scope_of(person))
      end

      assert reload(row).status == "pending"
      assert reload(row).input == %{"ids" => ["a", "b"]}
      assert ApiFlowStore.items() == @all_items
      refute_received {:flow, _tool, _input, %{dry_run?: false}}
    end

    test "a decided approval is not_pending, and a double approve runs once", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)

      assert {:ok, %{status: "executed"}} = Approvals.approve(row.uuid, scope)
      assert {:error, :not_pending} = Approvals.approve(row.uuid, scope)

      assert_received {:flow, @delete, _input, %{dry_run?: false}}
      refute_received {:flow, @delete, _input, %{dry_run?: false}}
    end

    test "simultaneous approvals run the tool once", %{agent: agent, owner_scope: scope} do
      row = pending!(agent, "flowkit.touch_item", %{"name" => "x"})

      results =
        1..6
        |> Task.async_stream(fn _ -> Approvals.approve(row.uuid, scope) end,
          max_concurrency: 6,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %Confirmation{status: "executed"}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_pending})) == 5
      assert ApiFlowStore.calls() == 1
    end

    test "an approval past its time is expired and does not run", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid),
        set: [expires_at: past]
      )

      assert {:error, :expired} = Approvals.approve(row.uuid, scope)

      assert reload(row).status == "expired"
      assert_nothing_written(row)
    end
  end

  describe "approve/3 checks the world again" do
    test "a revoked key: failed, nothing written", %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      {:ok, _} = Keys.revoke(Keys.get_key(agent.key.uuid), nil)

      assert {:ok, done} = Approvals.approve(row.uuid, scope)

      assert done.status == "failed"
      assert error_code(row) == "unauthorized"
      assert_nothing_written(row)
    end

    test "a connection that waits for approval: failed with unauthorized, nothing written", %{
      owner_scope: scope
    } do
      {_holder, _role, holder_scope} =
        OAuthTestSupport.oauth_holder(["settings", "dashboard"])

      seeded = OAuthTestSupport.seed_grant!(holder_scope, scopes: scopes())
      {:ok, actor} = Confirm.live_actor(seeded.key.uuid)
      row = pending!(%{actor: actor})

      # Back to waiting, as a code-only rollback followed by a roll-forward could leave it.
      {1, _} =
        Repo.update_all(from(g in Grant, where: g.uuid == ^seeded.grant.uuid),
          set: [approved_at: nil]
        )

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "unauthorized"
      assert_nothing_written(row)
    end

    test "an expired key: failed", %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      past = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(k in Key, where: k.uuid == ^agent.key.uuid), set: [expires_at: past])

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "unauthorized"
      assert_nothing_written(row)
    end

    test "a blocked owner: failed", %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      {:ok, _} = Auth.update_user_status(agent.owner, %{is_active: false})

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "unauthorized"
      assert_nothing_written(row)
    end

    test "an owner who lost the tool's permission: failed with forbidden", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      assert :ok = Permissions.revoke_permission(agent.role.uuid, "settings")

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "forbidden"
      assert_nothing_written(row)
    end

    test "a scope taken off the key: failed with forbidden and the scope named", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)

      Repo.update_all(from(k in Key, where: k.uuid == ^agent.key.uuid),
        set: [scopes: ["flowkit.items:read"]]
      )

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "forbidden"

      assert get_in(reload(row).result, ["error", "context", "required_scope"]) ==
               "flowkit.items:delete"

      assert_nothing_written(row)
    end

    test "a disabled module: failed with module_disabled", %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      ApiFlowTools.set_enabled(false)

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "module_disabled"
      assert_nothing_written(row)
    end

    test "the admin API switched off since the request: failed with not_found, nothing written",
         %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      :ok = ApiHarness.put_setting("api_admin_enabled", "false")

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "not_found"
      assert_nothing_written(row)
    end

    test "a tool hidden by api_disabled_tools: failed with not_found", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      :ok = ApiHarness.put_setting("api_disabled_tools", @delete)

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "not_found"
      assert_nothing_written(row)
    end

    test "the tool's module switched off in api_disabled_modules since the request: failed with not_found, nothing written",
         %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      :ok = ApiHarness.put_setting("api_disabled_modules", "api_flow_tools")

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "not_found"
      assert_nothing_written(row)
    end

    test "an input that no longer passes the schema: failed with validation_failed", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)

      Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid),
        set: [input: %{"ids" => "not a list"}]
      )

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "validation_failed"
      assert_nothing_written(row)
    end

    test "an input over the tool's max_items: failed with validation_failed, nothing written", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      too_many = Enum.map(1..501, &"x#{&1}")

      Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid),
        set: [input: %{"ids" => too_many}]
      )

      assert {:ok, %{status: "failed"}} = Approvals.approve(row.uuid, scope)
      assert error_code(row) == "validation_failed"
      assert_nothing_written(row)
    end

    test "the operation runs with the context shape the executor defines", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)

      assert {:ok, %{status: "executed"}} = Approvals.approve(row.uuid, scope)

      assert_received {:flow, @delete, _input, %{dry_run?: false} = ctx}
      assert Enum.sort(Map.keys(ctx)) == Enum.sort(Executor.context_keys())
      assert ctx.confirmation_uuid == row.uuid
      assert ctx.audience == :admin
    end

    test "values that changed since the request: stale, nothing written", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      ApiFlowStore.put("a", 999)

      assert {:ok, done} = Approvals.approve(row.uuid, scope)

      assert done.status == "stale"
      assert error_code(row) == "stale"
      assert ApiFlowStore.items() == Map.put(@all_items, "a", 999)
      refute_received {:flow, _tool, _input, %{dry_run?: false}}
      assert reload(row).input == nil
    end

    test "values that changed and changed back are not stale", %{agent: agent, owner_scope: scope} do
      row = pending!(agent)
      ApiFlowStore.put("a", 999)
      ApiFlowStore.put("a", 100)

      assert {:ok, %{status: "executed"}} = Approvals.approve(row.uuid, scope)
    end
  end

  describe "approve/3 when the tool fails" do
    test "an error answer: failed, with the code, the context and the partial results", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent, "flowkit.progress_write", %{"fail" => true})

      assert {:ok, done} = Approvals.approve(row.uuid, scope)

      assert done.status == "failed"
      assert get_in(done.result, ["error", "code"]) == "insufficient_stock"
      assert get_in(done.result, ["error", "detail"]) == "Two lines are short."
      assert done.result["partial"] == %{"done" => 1}
      assert done.input == nil
    end

    test "a crash: failed with a generic message, the partial results, and approve/3 does not raise",
         %{agent: agent, owner_scope: scope} do
      row = pending!(agent, "flowkit.progress_write", %{"crash" => true})

      log =
        capture_log(fn -> assert {:ok, %Confirmation{}} = Approvals.approve(row.uuid, scope) end)

      done = reload(row)
      assert done.status == "failed"
      assert get_in(done.result, ["error", "code"]) == "internal_error"
      refute inspect(done.result) =~ "secret-detail"
      assert done.result["partial"] == %{"done" => 1}
      refute log =~ "secret-detail"
      assert log =~ "RuntimeError"
    end

    test "an executed approval has no partial results left over", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent, "flowkit.progress_write", %{})

      assert {:ok, done} = Approvals.approve(row.uuid, scope)

      assert done.status == "executed"
      assert done.result == %{"done" => 2}
    end

    test "the view of a failed approval carries the error and the partial results", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent, "flowkit.progress_write", %{"fail" => true})
      {:ok, _done} = Approvals.approve(row.uuid, scope)

      view = row.uuid |> Approvals.get_for_key(agent.key.uuid) |> Approvals.status_view()

      assert view["status"] == "failed"
      assert view["error"]["code"] == "insufficient_stock"
      assert view["partial"] == %{"done" => 1}
    end
  end

  describe "approve/3 when the stuck sweep fails a running approval" do
    test "a handler that still succeeds ends executed, with a note, and runs once", %{
      agent: agent,
      owner_scope: scope
    } do
      ApiFlowStore.set_gate(self())
      row = pending!(agent, "flowkit.progress_write", %{"hold" => true})
      caller = Task.async(fn -> Approvals.approve(row.uuid, scope) end)

      assert_receive {:held, worker}, 5_000
      assert reload(row).status == "executing"

      old = DateTime.utc_now() |> DateTime.add(-1800, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid), set: [updated_at: old])
      assert Confirm.sweep_stuck() == 1
      assert reload(row).status == "failed"
      assert error_code(row) == "interrupted"

      send(worker, :release)
      assert {:ok, done} = Task.await(caller, 5_000)

      assert done.status == "executed"
      assert done.result["done"] == 2
      assert done.result["note"] =~ "interrupted"
      refute Map.has_key?(done.result, "error")
      assert reload(row).status == "executed"

      # Nothing starts a finished row again, and the sweep finds nothing to fail.
      assert Confirm.sweep_stuck() == 0
      assert {:error, :not_pending} = Approvals.approve(row.uuid, scope)
      refute_received {:held, _worker}
    end

    test "a key deleted while the handler runs does not make approve/3 raise", %{
      agent: agent,
      owner_scope: scope
    } do
      ApiFlowStore.set_gate(self())
      row = pending!(agent, "flowkit.progress_write", %{"hold" => true})
      caller = Task.async(fn -> Approvals.approve(row.uuid, scope) end)

      assert_receive {:held, worker}, 5_000

      # The confirmation row goes with its key (ON DELETE CASCADE).
      Repo.delete_all(from(k in Key, where: k.uuid == ^agent.key.uuid))
      assert Repo.get(Confirmation, row.uuid) == nil

      send(worker, :release)

      assert {:ok, done} = Task.await(caller, 5_000)
      assert done.status == "executed"
      assert done.uuid == row.uuid
    end

    test "a sweep landing between the finish's read and its write still ends executed", %{
      agent: agent,
      owner_scope: scope
    } do
      ApiFlowStore.set_gate(self())
      row = pending!(agent, "flowkit.progress_write", %{"hold" => true})
      caller = Task.async(fn -> Approvals.approve(row.uuid, scope) end)
      caller_pid = caller.pid

      assert_receive {:held, worker}, 5_000
      assert reload(row).status == "executing"

      # The sweep runs in the finishing process, right after its read of the row.
      fired = :counters.new(1, [])
      handler = "approvals-sweep-between-#{System.unique_integer([:positive])}"
      old = DateTime.utc_now() |> DateTime.add(-1800, :second) |> DateTime.truncate(:second)

      :telemetry.attach(
        handler,
        [:phoenix_kit, :test, :repo, :query],
        fn _event, _measurements, %{source: source}, _config ->
          if self() == caller_pid and source == "phoenix_kit_api_confirmations" and
               :counters.get(fired, 1) == 0 do
            :counters.add(fired, 1, 1)

            Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid),
              set: [updated_at: old]
            )

            1 = Confirm.sweep_stuck()
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      send(worker, :release)
      assert {:ok, done} = Task.await(caller, 5_000)

      assert :counters.get(fired, 1) == 1
      assert done.status == "executed"
      assert done.result["done"] == 2
      assert done.result["note"] =~ "interrupted"
      refute Map.has_key?(done.result, "error")
      assert reload(row).status == "executed"
      refute_received {:held, _worker}
    end

    test "a handler that fails after the sweep stays failed with the sweep's error", %{
      agent: agent,
      owner_scope: scope
    } do
      ApiFlowStore.set_gate(self())
      row = pending!(agent, "flowkit.progress_write", %{"hold" => true, "fail" => true})
      caller = Task.async(fn -> Approvals.approve(row.uuid, scope) end)

      assert_receive {:held, worker}, 5_000
      old = DateTime.utc_now() |> DateTime.add(-1800, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid), set: [updated_at: old])
      assert Confirm.sweep_stuck() == 1

      send(worker, :release)
      assert {:ok, done} = Task.await(caller, 5_000)

      assert done.status == "failed"
      assert error_code(row) == "interrupted"
    end
  end

  describe "reject/3" do
    test "discards the approval: nothing runs, the input is gone, the decision is logged", %{
      agent: agent,
      owner: owner,
      owner_scope: scope
    } do
      row = pending!(agent)

      assert {:ok, rejected} = Approvals.reject(row.uuid, scope)

      assert rejected.status == "rejected"
      assert rejected.input == nil
      assert rejected.decided_by_uuid == owner.uuid
      assert_nothing_written(row)

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where: e.action == "api.approval_decided" and e.resource_uuid == ^row.uuid
                 )
               )

      assert entry.permanent
      assert entry.metadata["decision"] == "rejected"
    end

    test "the creator of the key may reject it, a stranger may not", %{agent: agent} do
      row = pending!(agent)
      stranger = KeyTestSupport.register_user!()

      assert {:error, :forbidden} = Approvals.reject(row.uuid, KeyTestSupport.scope_of(stranger))
      assert {:ok, %{status: "rejected"}} = Approvals.reject(row.uuid, agent.scope)
    end

    test "a rejected approval cannot be approved or rejected again", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      {:ok, _} = Approvals.reject(row.uuid, scope)

      assert {:error, :not_pending} = Approvals.approve(row.uuid, scope)
      assert {:error, :not_pending} = Approvals.reject(row.uuid, scope)
      assert_nothing_written(row)
    end

    test "an unknown id and an expired approval are refused like in approve/3", %{
      agent: agent,
      owner_scope: scope
    } do
      row = pending!(agent)
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid),
        set: [expires_at: past]
      )

      assert {:error, :not_found} = Approvals.reject("nope", scope)
      assert {:error, :expired} = Approvals.reject(row.uuid, scope)
    end
  end
end
