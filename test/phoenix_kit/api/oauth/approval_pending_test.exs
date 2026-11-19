defmodule PhoenixKit.API.OAuth.ApprovalPendingTest do
  @moduledoc """
  What an OAuth connection that waits for approval can and cannot do on the admin MCP endpoint:
  it signs in and sees the tool list, but every call of a tool, reading or writing, a known name
  or not, is refused with `approval_pending` and advice for the agent, before any lookup, cost
  or side effect; the same token works the moment the connection is approved.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.API.KeyTestSupport, only: [wait_for_window_room: 0]
  import PhoenixKit.API.OAuthTestSupport
  import PhoenixKit.Test.ApiHarness
  import PhoenixKit.Test.McpHarness

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Idempotency.Record
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.MCP.Shape
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.API.Problem
  alias PhoenixKit.Test.Repo

  @read "testkit.items:read"
  @write "testkit.items:write"

  setup do
    setup_api()
    enable_oauth!()
    {_holder, _role, scope} = oauth_holder(["dashboard", "settings"])
    waiting = seed_grant!(scope, scopes: [@read, @write], approved?: false)
    working = seed_grant!(scope, scopes: [@read, @write])
    %{scope: scope, waiting: waiting, working: working}
  end

  defp approve!(%{grant: grant}) do
    {1, _} =
      Repo.update_all(from(g in Grant, where: g.uuid == ^grant.uuid),
        set: [approved_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )
  end

  defp error_text(conn) do
    assert %{"isError" => true, "content" => [%{"text" => first}, %{"text" => problem}]} =
             result(conn)

    {first, JSON.decode!(problem)}
  end

  defp audit(key) do
    Repo.all(from(e in Entry, where: e.action == "api.request" and e.resource_uuid == ^key.uuid))
  end

  describe "the actor" do
    test "of a token whose grant waits is marked, and of one that works is not", ctx do
      assert {:ok, %{awaiting_approval: true, kind: :key}} =
               Tokens.verify(ctx.waiting.access, nil)

      assert {:ok, %{awaiting_approval: false}} = Tokens.verify(ctx.working.access, nil)
    end

    test "is not marked by default (an anonymous caller, a key of a person)" do
      refute %PhoenixKit.API.Actor{}.awaiting_approval
    end

    test "rebuilt from the hidden key without a token is marked while the grant waits", ctx do
      assert {:ok, %{awaiting_approval: true}} = Confirm.live_actor(ctx.waiting.key.uuid)
      assert {:ok, %{awaiting_approval: false}} = Confirm.live_actor(ctx.working.key.uuid)

      approve!(ctx.waiting)
      assert {:ok, %{awaiting_approval: false}} = Confirm.live_actor(ctx.waiting.key.uuid)
    end

    test "a grant written with no approval at all reads as waiting", ctx do
      {1, _} =
        Repo.update_all(from(g in Grant, where: g.uuid == ^ctx.working.grant.uuid),
          set: [approved_at: nil]
        )

      assert {:ok, %{awaiting_approval: true}} = Tokens.verify(ctx.working.access, nil)
      assert {:ok, %{awaiting_approval: true}} = Confirm.live_actor(ctx.working.key.uuid)
    end

    test "a hidden key whose grant cannot be found is waiting too", ctx do
      {1, _} =
        Repo.update_all(
          from(k in Key, where: k.uuid == ^ctx.working.key.uuid),
          set: [oauth_grant_uuid: Ecto.UUID.generate()]
        )

      assert {:ok, %{awaiting_approval: true}} = Confirm.live_actor(ctx.working.key.uuid)
    end

    test "an ordinary key of a person is not marked", %{scope: scope} do
      {:ok, key, _token} =
        Keys.create_personal_key(
          scope,
          %{
            name: "mine",
            scopes: [@read],
            expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)
          },
          impersonated: false
        )

      assert {:ok, %{awaiting_approval: false}} = Confirm.live_actor(key.uuid)
    end
  end

  describe "on the MCP endpoint, while the connection waits" do
    test "initialize answers, and its instructions name approval_pending before the first call",
         %{waiting: waiting} do
      conn =
        post_rpc(
          :admin,
          message("initialize", %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "t", "version" => "1"}
          }),
          token: waiting.access
        )

      assert conn.status == 200
      instructions = result(conn)["instructions"]

      assert instructions =~ "approval_pending"
      assert instructions == Shape.instructions(:admin)

      {at, _} = :binary.match(instructions, "approval_pending")
      {first_call, _} = :binary.match(instructions, "Call system_get_identity first")
      assert at < first_call
    end

    test "tools/list is the one of a working connection, so a client does not cache an empty one",
         ctx do
      waiting = post_rpc(:admin, message("tools/list"), token: ctx.waiting.access)
      working = post_rpc(:admin, message("tools/list"), token: ctx.working.access)

      assert waiting.status == 200
      assert "testkit_read_items" in tool_names(waiting)
      assert tool_names(waiting) == tool_names(working)
    end

    test "a read, a write, an unknown name: approval_pending with advice, nothing runs", ctx do
      for {name, args} <- [
            {"testkit.read_items", %{}},
            {"testkit.write_item", %{"name" => "x"}},
            {"testkit.no_such_tool", %{}},
            {"testkit.write_item", %{"name" => "x", "dry_run" => true}}
          ] do
        conn = post_rpc(:admin, call_message(name, args), token: ctx.waiting.access)

        assert conn.status == 200, name
        {first, problem} = error_text(conn)

        assert first =~ "[approval_pending]"
        assert first =~ Shape.advice(:approval_pending)
        assert first =~ "waiting for approval by an Owner"
        assert problem["code"] == "approval_pending"
        assert problem["status"] == 403
        assert problem["title"] == "Approval pending"
      end

      refute_received {:read_items, _, _}
      refute_received {:write_item, _}
      assert audit(ctx.waiting.key) == []
    end

    test "creates no confirmation, approval or idempotency record", ctx do
      conn =
        post_rpc(
          :admin,
          call_message("testkit.write_item", %{"name" => "x", "idempotency_key" => "k-1"}),
          token: ctx.waiting.access
        )

      assert {_first, %{"code" => "approval_pending"}} = error_text(conn)

      assert Repo.aggregate(Confirmation, :count) == 0
      assert Repo.aggregate(Record, :count) == 0
    end

    test "costs one unit of the key's rate limit, like any other refusal", ctx do
      put_setting("api_admin_rate_per_min", 3)
      wait_for_window_room()

      statuses =
        for _ <- 1..4 do
          conn =
            post_rpc(:admin, call_message("testkit.read_items", %{}), token: ctx.waiting.access)

          conn.status
        end

      assert statuses == [200, 200, 200, 429]
    end

    test "the same access token works as soon as the connection is approved", ctx do
      call = fn ->
        post_rpc(:admin, call_message("testkit.read_items", %{}), token: ctx.waiting.access)
      end

      assert {_first, %{"code" => "approval_pending"}} = error_text(call.())

      approve!(ctx.waiting)

      conn = call.()
      assert conn.status == 200
      refute result(conn)["isError"]
      assert_received {:read_items, _, _}
    end

    test "a write of an approved connection runs, its refresh and tools/list are unchanged",
         ctx do
      conn =
        post_rpc(:admin, call_message("testkit.write_item", %{"name" => "x"}),
          token: ctx.working.access
        )

      refute result(conn)["isError"]
    end

    test "a working connection never sees approval_pending", ctx do
      conn =
        post_rpc(:admin, call_message("testkit.no_such_tool", %{}), token: ctx.working.access)

      # An unknown tool name is a JSON-RPC error of the protocol, as it always was.
      assert error(conn)["code"] == -32_602
    end
  end

  describe "the executor" do
    test "refuses before anything else: a missing tool name is approval_pending too", ctx do
      conn =
        :post
        |> api_conn("/", token: ctx.waiting.access)
        |> Auth.call(Auth.init(audience: :admin, oauth: true))

      assert {:error, :approval_pending, detail, %{}, _headers} =
               Executor.execute(conn, :admin, "testkit.nothing_like_it", %{})

      assert detail =~ "approval"
    end

    test "the code is a problem of core, with a status and a title" do
      assert Problem.status(:approval_pending) == 403
      assert Problem.core_code?(:approval_pending)
      assert Problem.statuses()[:approval_pending] == 403
    end

    test "every code of core has advice for an agent" do
      assert Shape.advice(:approval_pending) =~ "waiting for approval"
      assert Shape.advice(:approval_pending) =~ "no need to connect again"
    end
  end

  describe "granting" do
    test "a waiting grant is refreshed like any other", ctx do
      assert {:ok, _access, _row} =
               Tokens.issue(Repo.get!(Grant, ctx.waiting.grant.uuid), :access)

      assert Grants.awaiting?(Repo.get!(Grant, ctx.waiting.grant.uuid))
    end
  end
end
