defmodule PhoenixKit.API.ExecutorTelegramLinkTest do
  @moduledoc """
  `PhoenixKit.API.Executor.visible_for/3` and `execute_as/5` on behalf of a linked
  Telegram chat: the reference `{:telegram_link, user_uuid, connection_uuid, chat_id}`.
  The link (`PhoenixKit.Integrations.Telegram.Linking`) and the account gate
  (`PhoenixKit.Users.Auth.SessionRef.scope_for_user/2`) are checked on every call; the
  rest of the flow is the live session's: read tools only, the tool's permission, the
  user's rate-limit bucket.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.API.KeyTestSupport, only: [wait_for_window_room: 0]
  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ApiSessionTools
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Roles

  @read_items "testkit.read_items"
  @write_item "testkit.write_item"
  @chat 428_897_538

  defmodule InviteOnly do
    @moduledoc false
    def module_key, do: "referrals"
    def get_config, do: %{enabled: true, required: true}
  end

  setup do
    setup_api()
    :ok = ModuleRegistry.register(ApiSessionTools)
    on_exit(fn -> ModuleRegistry.unregister(ApiSessionTools) end)
    %{connection: UUIDv7.generate()}
  end

  defp user_with_roles(permission_lists) do
    user = KeyTestSupport.register_user!()

    for permissions <- permission_lists do
      {role, _} = KeyTestSupport.role_with(permissions)
      {:ok, _} = Roles.assign_role(user, role.name)
    end

    user
  end

  defp linked!(%User{} = user, connection, chat \\ @chat) do
    {:ok, _} = Linking.link_chat(user, connection, chat)
    {:telegram_link, user.uuid, connection, chat}
  end

  defp session!(%User{} = user) do
    token = Auth.generate_user_session_token(user)
    %UserToken{uuid: uuid} = Auth.get_session_token_record(token)
    {uuid, user.uuid}
  end

  defp run(ref, tool, input \\ %{}, opts \\ []),
    do: Executor.execute_as(ref, :admin, tool, input, opts)

  defp visible_names(ref) do
    assert {:ok, tools, _headers} = Executor.visible_for(ref, :admin, [])
    tools |> Enum.map(& &1.name) |> Enum.sort()
  end

  defp set_user(user, fields),
    do: Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: fields)

  describe "execute_as/5 with a linked chat" do
    test "a linked user holding the permission gets the result", %{connection: connection} do
      ref = linked!(user_with_roles([["dashboard"]]), connection)

      assert {:ok, %{result: %{"limit" => 10}}, _headers} = run(ref, @read_items)
      assert_received {:read_items, _input, _ctx}
    end

    test "the chat id may be given as a string", %{connection: connection} do
      user = user_with_roles([["dashboard"]])
      linked!(user, connection)

      assert {:ok, _, _} =
               run({:telegram_link, user.uuid, connection, Integer.to_string(@chat)}, @read_items)
    end

    test "unlinking takes effect on the very next call", %{connection: connection} do
      user = user_with_roles([["dashboard"]])
      ref = linked!(user, connection)
      assert {:ok, _, _} = run(ref, @read_items)
      assert_received {:read_items, _, _}

      :ok = Linking.unlink(Auth.get_user!(user.uuid))

      assert {:error, :unauthorized, _detail, %{reason: :unlinked}, []} = run(ref, @read_items)

      assert {:error, :unauthorized, _, %{reason: :unlinked}, []} =
               Executor.visible_for(ref, :admin, [])

      refute_received {:read_items, _, _}
    end

    test "a blocked user is refused", %{connection: connection} do
      user = user_with_roles([["dashboard"]])
      ref = linked!(user, connection)
      set_user(user, is_active: false)

      capture_log(fn ->
        assert {:error, :unauthorized, _, %{reason: :inactive}, []} = run(ref, @read_items)
      end)

      refute_received {:read_items, _, _}
    end

    test "another chat, another bot or another user is refused", %{connection: connection} do
      user = user_with_roles([["dashboard"]])
      other = user_with_roles([["dashboard"]])
      linked!(user, connection)

      for ref <- [
            {:telegram_link, user.uuid, connection, @chat + 1},
            {:telegram_link, user.uuid, UUIDv7.generate(), @chat},
            {:telegram_link, other.uuid, connection, @chat}
          ] do
        assert {:error, :unauthorized, _, %{reason: :unlinked}, []} = run(ref, @read_items)
      end

      refute_received {:read_items, _, _}
    end

    test "a chat two accounts linked acts for neither", %{connection: connection} do
      a = user_with_roles([["dashboard"]])
      b = user_with_roles([["dashboard"]])
      ref = linked!(a, connection)
      linked!(b, connection)

      assert {:error, :unauthorized, _, %{reason: :unlinked}, []} = run(ref, @read_items)
    end

    test "a malformed link is refused, never an exception" do
      for ref <- [
            {:telegram_link, nil, nil, nil},
            {:telegram_link, "x", "y", %{}},
            {:telegram_link, 1, 2, 3},
            {:telegram_link, "x", "y"}
          ] do
        assert {:error, :unauthorized, _, %{reason: reason}, []} = run(ref, @read_items)
        assert reason in [:unlinked, :session_gone]

        assert {:error, :unauthorized, _, _, []} = Executor.visible_for(ref, :admin, [])
      end
    end

    test "a write tool is refused before validation, with no audit entry",
         %{connection: connection} do
      user = user_with_roles([["settings"]])
      ref = linked!(user, connection)

      assert {:error, :forbidden, detail, %{tool: @write_item}, _} =
               run(ref, @write_item, %{"name" => "x"})

      assert detail =~ "reads only"

      # Not even a schema error: the write is refused before the input is looked at.
      assert {:error, :forbidden, _, _, _} = run(ref, @write_item, %{"junk" => 1})
      refute_received {:write_item, _}

      assert_raise ArgumentError, fn -> run(ref, @write_item, %{"name" => "x"}, allow: :all) end

      # Nor listed, held or confirmed with the write tools: a chat reads only.
      assert_raise ArgumentError, fn -> Executor.visible_for(ref, :admin, allow: :all) end

      assert_raise ArgumentError, fn ->
        Executor.redeem_as(ref, :admin, Ecto.UUID.generate(), @write_item, %{"name" => "x"})
      end

      assert Repo.aggregate(
               from(e in Entry, where: e.action == "api.request" and e.actor_uuid == ^user.uuid),
               :count
             ) == 0
    end

    test "a system tool is not callable", %{connection: connection} do
      ref = linked!(user_with_roles([["dashboard"]]), connection)
      assert {:error, :forbidden, _, _, _} = run(ref, "system.get_identity")
    end

    test "the handler sees a :user actor marked as coming from Telegram, with the full scope",
         %{connection: connection} do
      user = user_with_roles([["dashboard"]])
      ref = linked!(user, connection)

      assert {:ok, _, _} = run(ref, @read_items, %{}, request_context: [request_id: "tg-1"])
      assert_received {:read_items, _input, ctx}

      assert %Actor{kind: :user, key_uuid: nil, source: "telegram", user_uuid: user_uuid} =
               ctx.actor

      assert user_uuid == user.uuid
      assert ctx.request_id == "tg-1"
      assert %Scope{} = ctx.scope
      assert Scope.active_role(ctx.scope) == nil

      # A live session's actor carries no source.
      assert {:ok, _, _} = run(session!(user), @read_items)
      assert_received {:read_items, _input, %{actor: %Actor{source: nil}}}
    end
  end

  describe "the account gate" do
    # The same user, the same refusal, through a live session and through a linked chat.
    defp both_refusals(user, connection) do
      session = run(session!(user), @read_items)
      link = run(linked!(user, connection), @read_items)
      {session, link}
    end

    test "refuses alike through a session and through a linked chat", %{connection: connection} do
      blocked = user_with_roles([["dashboard"]])
      session = session!(blocked)
      link = linked!(blocked, connection)
      set_user(blocked, is_active: false)

      capture_log(fn ->
        assert {:error, :unauthorized, _, %{reason: :inactive}, []} =
                 outcome = run(session, @read_items)

        assert run(link, @read_items) == outcome
      end)

      unconfirmed = user_with_roles([["dashboard"]])
      set_user(unconfirmed, confirmed_at: nil)
      {session_outcome, link_outcome} = both_refusals(unconfirmed, UUIDv7.generate())
      assert {:error, :unauthorized, _, %{reason: :unconfirmed}, []} = session_outcome
      assert link_outcome == session_outcome

      parked = user_with_roles([["dashboard"]])
      ModuleRegistry.register(InviteOnly)
      on_exit(fn -> ModuleRegistry.unregister(InviteOnly) end)

      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("referral_codes_required", true)
        {:ok, _} = Settings.update_boolean_setting("referral_grandfather_existing", false)
      end)

      {session_outcome, link_outcome} = both_refusals(parked, UUIDv7.generate())
      assert {:error, :unauthorized, _, %{reason: :referral_required}, []} = session_outcome
      assert link_outcome == session_outcome

      refute_received {:read_items, _, _}
    end
  end

  describe "visible_for/3 with a linked chat" do
    test "lists what a session of the same user lists", %{connection: connection} do
      user = user_with_roles([["dashboard", "users"]])
      names = visible_names(linked!(user, connection))

      assert @read_items in names
      assert "sessiontest.read_a" in names
      refute @write_item in names
      refute Enum.any?(names, &String.starts_with?(&1, "system."))
      assert names == visible_names(session!(user))
    end

    test "is the union of the user's roles, never narrowed to one", %{connection: connection} do
      capture_log(fn ->
        {:ok, _} = Settings.update_boolean_setting("role_switcher_enabled", true)
      end)

      user = user_with_roles([["dashboard"], ["users"]])
      names = visible_names(linked!(user, connection))

      assert @read_items in names
      assert "sessiontest.read_a" in names
    end
  end

  describe "rate limit" do
    setup do
      wait_for_window_room()
      put_setting("api_admin_rate_per_min", 2)
      :ok
    end

    test "a linked chat pays into the user's own bucket, shared with the user's sessions",
         %{connection: connection} do
      user = user_with_roles([["dashboard"]])

      assert {:ok, _, _} = run(linked!(user, connection), @read_items)
      assert {:ok, _, _} = run(session!(user), @read_items)

      assert {:error, :rate_limited, _, %{retry_after: _}, _} =
               run(linked!(user, connection), @read_items)
    end
  end
end
