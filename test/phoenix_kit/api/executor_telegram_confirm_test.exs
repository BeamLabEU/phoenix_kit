defmodule PhoenixKit.API.ExecutorTelegramConfirmTest do
  @moduledoc """
  Writes from a linked Telegram chat (`{:telegram_link, user_uuid, connection_uuid, chat_id}`):
  the chat proposes a write (`execute_as/5` with `allow: :all`), which is held for confirmation
  and bound to that chat (`context` of the row); the same chat confirms it (`redeem_as/6`),
  reads it (`Confirm.get_for_user/3`) or turns it down (`Confirm.reject_for_user/3`), and no
  other chat, and no row made on the site, can be confirmed or turned down from a chat. A live
  site session of the same person may act on a row of a chat. Real links, roles, rows and the
  tools of `PhoenixKit.Test.ApiSessionTools`.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Settings.Setting
  alias PhoenixKit.Test.ApiSessionTools
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  @set "sessiontest.set_note"
  @module "api_session_tools"
  @input %{"id" => "n1", "text" => "new"}
  @chat 428_897_538

  setup do
    setup_api()
    :ok = ModuleRegistry.register(ApiSessionTools)
    ApiSessionTools.reset_notes()
    put_setting("api_session_write_modules", @module)

    on_exit(fn ->
      ModuleRegistry.unregister(ApiSessionTools)
      ApiSessionTools.reset_notes()
    end)

    {user, role} = person(["settings"])
    connection = UUIDv7.generate()
    {:ok, _} = Linking.link_chat(user, connection, @chat)

    %{
      user: user,
      role: role,
      connection: connection,
      chat: {:telegram_link, user.uuid, connection, @chat},
      site: session!(user)
    }
  end

  defp person(permissions) do
    user = KeyTestSupport.register_user!()
    {role, _} = KeyTestSupport.role_with(permissions)
    {:ok, _} = Roles.assign_role(user, role.name)
    {user, role}
  end

  defp session!(%User{} = user) do
    token = Auth.generate_user_session_token(user)
    %UserToken{uuid: uuid} = Auth.get_session_token_record(token)
    {uuid, user.uuid}
  end

  defp ask(ref, opts \\ []),
    do: Executor.execute_as(ref, :admin, @set, @input, Keyword.put_new(opts, :allow, :all))

  defp confirm(ref, id, opts \\ []),
    do: Executor.redeem_as(ref, :admin, id, @set, @input, opts)

  defp held!(ref) do
    assert {:ok, %{result: %{"status" => "confirmation_required", "confirmation_id" => id}}, _} =
             ask(ref)

    id
  end

  defp row(id), do: Repo.get!(Confirmation, id)

  defp entries(user) do
    Repo.all(
      from(e in Entry,
        where: e.action == "api.request" and e.actor_uuid == ^user.uuid,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp no_write! do
    assert ApiSessionTools.notes() == %{"n1" => "old"}
    refute_received {:session_write, _, _, _}
  end

  test "Executor.link_writes?/0 says a linked chat may write" do
    assert Executor.link_writes?() == true
  end

  describe "a chat proposes a write" do
    test "visible_for/3 with allow: :all lists the write tools of an open module", %{chat: chat} do
      assert {:ok, tools, _} = Executor.visible_for(chat, :admin, allow: :all)
      assert @set in Enum.map(tools, & &1.name)

      assert {:ok, tools, _} = Executor.visible_for(chat, :admin, [])
      refute @set in Enum.map(tools, & &1.name)
    end

    test "is held for confirmation, not run, and the row is bound to the chat", %{
      chat: chat,
      user: user,
      connection: connection
    } do
      assert {:ok, %{result: result}, _} = ask(chat)

      assert %{
               "executed" => false,
               "status" => "confirmation_required",
               "confirmation_id" => id
             } = result

      no_write!()

      assert %Confirmation{status: "unused", actor_user_uuid: user_uuid, context: context} =
               row(id)

      assert user_uuid == user.uuid

      assert context == %{
               "origin" => "telegram",
               "connection_uuid" => connection,
               "chat_id" => Integer.to_string(@chat)
             }
    end

    test "a chat id given as a string is stored as the same string", %{
      user: user,
      connection: connection
    } do
      id = held!({:telegram_link, user.uuid, connection, Integer.to_string(@chat)})
      assert row(id).context["chat_id"] == Integer.to_string(@chat)
    end

    test "a write of a module that is not open is refused", %{chat: chat} do
      Repo.delete_all(from(s in Setting, where: s.key == "api_session_write_modules"))

      assert {:error, :module_write_disabled, _, %{tool: @set}, _} = ask(chat)
      assert Repo.aggregate(Confirmation, :count) == 0
    end

    test "allow: :read still refuses a write, before validation, with no row", %{chat: chat} do
      assert {:error, :forbidden, detail, %{tool: @set}, _} = ask(chat, allow: :read)
      assert detail =~ "reads only"
      assert {:error, :forbidden, _, _, _} = Executor.execute_as(chat, :admin, @set, %{})
      assert Repo.aggregate(Confirmation, :count) == 0
    end

    test "a chat that is not linked proposes nothing", %{user: user} do
      stranger = {:telegram_link, user.uuid, UUIDv7.generate(), @chat}

      assert {:error, :unauthorized, _, %{reason: :unlinked}, _} = ask(stranger)
      assert Repo.aggregate(Confirmation, :count) == 0
    end

    test "a site session's write carries no origin", %{site: site} do
      assert row(held!(site)).context == %{}
    end

    test "the audit entry says telegram", %{chat: chat, user: user} do
      id = held!(chat)
      assert {:ok, _, _} = confirm(chat, id)

      assert [held, done] = entries(user)
      assert %{"via" => "telegram", "outcome" => "confirmation_required"} = held.metadata
      assert %{"via" => "telegram", "outcome" => "ok", "confirmation_uuid" => ^id} = done.metadata
    end
  end

  describe "the chat confirms its own row" do
    test "runs the write once, as the chat, and spends the row", %{chat: chat} do
      id = held!(chat)
      assert_received {:session_preview, @set, _}

      assert {:ok, %{result: %{"id" => "n1", "updated" => true}}, _} = confirm(chat, id)

      assert ApiSessionTools.notes() == %{"n1" => "new"}
      assert_received {:session_write, @set, @input, ctx}
      assert ctx.confirmation_uuid == id
      assert ctx.via == "telegram"
      assert ctx.actor.source == "telegram"
      assert row(id).status == "used"
    end

    test "the chat id may be an integer on one side and a string on the other", %{
      chat: _chat,
      user: user,
      connection: connection
    } do
      id = held!({:telegram_link, user.uuid, connection, Integer.to_string(@chat)})

      assert {:ok, %{result: %{"updated" => true}}, _} =
               confirm({:telegram_link, user.uuid, connection, @chat}, id)
    end

    test "a second confirmation is used and the handler ran once", %{chat: chat} do
      id = held!(chat)
      assert {:ok, _, _} = confirm(chat, id)
      assert_received {:session_write, _, _, _}

      assert {:error, :confirm_token_invalid, _, %{reason: "used"}, _} = confirm(chat, id)
      refute_received {:session_write, _, _, _}
    end

    test "unlinked between the proposal and the press: unauthorized, the row waits", %{
      chat: chat,
      user: user
    } do
      id = held!(chat)
      :ok = Linking.unlink(Auth.get_user!(user.uuid))

      assert {:error, :unauthorized, _, %{reason: :unlinked}, _} = confirm(chat, id)
      assert row(id).status == "unused"
      no_write!()
    end

    test "the right to the tool lost between the proposal and the press: forbidden, the row waits",
         %{chat: chat, role: role} do
      id = held!(chat)
      :ok = Permissions.revoke_permission(role.uuid, "settings")

      assert {:error, :forbidden, _, _, _} = confirm(chat, id)
      assert row(id).status == "unused"
      no_write!()
    end

    test "the box taken off between the proposal and the press: module_write_disabled", %{
      chat: chat
    } do
      id = held!(chat)
      Repo.delete_all(from(s in Setting, where: s.key == "api_session_write_modules"))

      assert {:error, :module_write_disabled, _, _, _} = confirm(chat, id)
      assert row(id).status == "unused"
      no_write!()
    end

    test "changed values give a new row with the same context, and nothing runs", %{
      chat: chat
    } do
      id = held!(chat)
      ApiSessionTools.put_note("n1", "edited meanwhile")

      assert {:ok, %{result: %{"reason" => "changed", "confirmation_id" => new_id}}, _} =
               confirm(chat, id)

      assert new_id != id
      assert row(id).status == "expired"
      assert %Confirmation{status: "unused"} = new_row = row(new_id)
      assert new_row.context == row(id).context
      assert new_row.context["origin"] == "telegram"
      refute_received {:session_write, _, _, _}

      # The new row is the chat's too.
      assert {:ok, %{result: %{"updated" => true}}, _} = confirm(chat, new_id)
    end
  end

  describe "a chat cannot act on a row that is not its own" do
    test "a row made on the site: other_origin, the row waits, nothing runs", %{
      chat: chat,
      site: site
    } do
      id = held!(site)

      assert {:error, :confirm_token_invalid, _, %{reason: "other_origin"}, _} = confirm(chat, id)
      assert row(id).status == "unused"
      no_write!()
    end

    test "a row without any context (made before this existed) is not a chat's", %{chat: chat} do
      id = held!(chat)
      Repo.update_all(from(c in Confirmation, where: c.uuid == ^id), set: [context: %{}])

      assert {:error, :confirm_token_invalid, _, %{reason: "other_origin"}, _} = confirm(chat, id)
      assert row(id).status == "unused"
    end

    test "a row of the chat the person had before: other_origin", %{
      chat: chat,
      user: user,
      connection: connection
    } do
      id = held!(chat)
      new_chat = @chat + 1
      {:ok, _} = Linking.link_chat(user, connection, new_chat)

      assert {:error, :confirm_token_invalid, _, %{reason: "other_origin"}, _} =
               confirm({:telegram_link, user.uuid, connection, new_chat}, id)

      # Another bot of the same chat id is another origin as well.
      other_bot = UUIDv7.generate()
      {:ok, _} = Linking.link_chat(user, other_bot, @chat)

      assert {:error, :confirm_token_invalid, _, %{reason: "other_origin"}, _} =
               confirm({:telegram_link, user.uuid, other_bot, @chat}, id)

      assert row(id).status == "unused"
      no_write!()
    end

    test "somebody else's row is the same invalid answer as an unknown one", %{chat: chat} do
      {stranger, _} = person(["settings"])
      stranger_chat = {:telegram_link, stranger.uuid, UUIDv7.generate(), @chat + 7}
      {:ok, _} = Linking.link_chat(stranger, elem(stranger_chat, 2), @chat + 7)
      id = held!(stranger_chat)

      assert {:error, :confirm_token_invalid, _, %{reason: "invalid"}, _} = confirm(chat, id)

      assert {:error, :confirm_token_invalid, _, %{reason: "invalid"}, _} =
               confirm(chat, UUIDv7.generate())

      assert row(id).status == "unused"
      no_write!()
    end
  end

  describe "the site and the chat" do
    test "a site session of the same person confirms a row of the chat", %{
      chat: chat,
      site: site
    } do
      id = held!(chat)

      assert {:ok, %{result: %{"updated" => true}}, _} = confirm(site, id)
      assert ApiSessionTools.notes() == %{"n1" => "new"}
      assert_received {:session_write, @set, _, %{via: "session", confirmation_uuid: ^id}}
      assert row(id).status == "used"
    end

    test "changed values under a chat's row confirmed on the site: the new row is the chat's",
         %{chat: chat, site: site} do
      id = held!(chat)
      ApiSessionTools.put_note("n1", "edited meanwhile")

      assert {:ok, %{result: %{"reason" => "changed", "confirmation_id" => new_id}}, _} =
               confirm(site, id)

      assert row(new_id).context == row(id).context
      assert row(new_id).context["origin"] == "telegram"
    end

    test "a site session turns a chat's row down", %{chat: chat, site: site} do
      id = held!(chat)
      assert :ok = Confirm.reject_for_user(id, site)
      assert row(id).status == "rejected"
    end
  end

  describe "Confirm.get_for_user/3 with a chat" do
    test "reads the chat's own row for the card", %{chat: chat} do
      id = held!(chat)

      assert {:ok, %{uuid: ^id, tool: @set, status: "unused", preview: %{"rows" => [_]}}} =
               Confirm.get_for_user(id, chat)
    end

    test "a row of the site, or of another chat, is :foreign, without the preview", %{
      chat: chat,
      site: site
    } do
      assert Confirm.get_for_user(held!(site), chat) == {:error, :foreign}

      own = held!(chat)
      Repo.update_all(from(c in Confirmation, where: c.uuid == ^own), set: [context: %{}])
      assert Confirm.get_for_user(own, chat) == {:error, :foreign}
    end

    test "somebody else's row and an unknown uuid are :unknown", %{chat: chat} do
      {stranger, _} = person(["settings"])
      id = held!(session!(stranger))

      assert Confirm.get_for_user(id, chat) == {:error, :unknown}
      assert Confirm.get_for_user(UUIDv7.generate(), chat) == {:error, :unknown}
      assert Confirm.get_for_user("garbage", chat) == {:error, :unknown}
    end

    test "an unlinked chat, a malformed one and an inactive user get :unauthorized", %{
      chat: chat,
      user: user
    } do
      id = held!(chat)

      for ref <- [
            {:telegram_link, user.uuid, UUIDv7.generate(), @chat},
            {:telegram_link, user.uuid, "x", %{}},
            {:telegram_link, nil, nil, nil}
          ] do
        assert Confirm.get_for_user(id, ref) == {:error, :unauthorized}
      end

      Repo.update_all(from(u in User, where: u.uuid == ^user.uuid), set: [is_active: false])

      capture_log(fn ->
        assert Confirm.get_for_user(id, chat) == {:error, :unauthorized}
      end)
    end

    test "without the right to the tool: :forbidden", %{chat: chat, role: role} do
      id = held!(chat)
      :ok = Permissions.revoke_permission(role.uuid, "settings")

      assert Confirm.get_for_user(id, chat) == {:error, :forbidden}
    end
  end

  describe "Confirm.reject_for_user/3 with a chat" do
    test "turns the chat's own row down, one way", %{chat: chat} do
      id = held!(chat)

      assert :ok = Confirm.reject_for_user(id, chat)
      assert row(id).status == "rejected"
      assert Confirm.reject_for_user(id, chat) == {:error, :rejected}
      assert {:error, :confirm_token_invalid, _, %{reason: "rejected"}, _} = confirm(chat, id)
    end

    test "works after the right to the tool is lost", %{chat: chat, role: role} do
      id = held!(chat)
      :ok = Permissions.revoke_permission(role.uuid, "settings")

      assert :ok = Confirm.reject_for_user(id, chat)
    end

    test "does not turn down a row of the site or of another chat: :foreign", %{
      chat: chat,
      site: site
    } do
      id = held!(site)
      assert Confirm.reject_for_user(id, chat) == {:error, :foreign}
      assert row(id).status == "unused"

      other = held!(chat)
      Repo.update_all(from(c in Confirmation, where: c.uuid == ^other), set: [context: %{}])
      assert Confirm.reject_for_user(other, chat) == {:error, :foreign}
      assert row(other).status == "unused"
    end

    test "somebody else's row and an unknown uuid are :unknown", %{chat: chat} do
      {stranger, _} = person(["settings"])
      id = held!(session!(stranger))

      assert Confirm.reject_for_user(id, chat) == {:error, :unknown}
      assert Confirm.reject_for_user(UUIDv7.generate(), chat) == {:error, :unknown}
      assert row(id).status == "unused"
    end

    test "an unlinked chat is :unauthorized and the row waits", %{chat: chat, user: user} do
      id = held!(chat)
      :ok = Linking.unlink(Auth.get_user!(user.uuid))

      assert Confirm.reject_for_user(id, chat) == {:error, :unauthorized}
      assert row(id).status == "unused"
    end
  end

  describe "Confirm.issue_for_user/7 and reissue_for_user/8 context" do
    test "the context option defaults to an empty map", %{user: user} do
      actor = %PhoenixKit.API.Actor{kind: :user, user_uuid: user.uuid}

      assert {:ok, %Confirmation{context: %{}}} =
               Confirm.issue_for_user(actor, @set, "hash", %{}, "fp")

      assert {:ok, %Confirmation{context: %{"origin" => "x"}}} =
               Confirm.issue_for_user(actor, @set, "hash", %{}, "fp", DateTime.utc_now(),
                 context: %{"origin" => "x"}
               )
    end

    test "a reissued row keeps the context of the old one unless told otherwise", %{user: user} do
      actor = %PhoenixKit.API.Actor{kind: :user, user_uuid: user.uuid}

      {:ok, old} =
        Confirm.issue_for_user(actor, @set, "hash", %{}, "fp", DateTime.utc_now(),
          context: %{"origin" => "telegram"}
        )

      assert {:ok, %Confirmation{context: %{"origin" => "telegram"}}} =
               Confirm.reissue_for_user(old, actor, @set, "hash", %{}, "fp2")

      {:ok, old} =
        Confirm.issue_for_user(actor, @set, "hash", %{}, "fp", DateTime.utc_now(),
          context: %{"origin" => "telegram"}
        )

      assert {:ok, %Confirmation{context: %{"origin" => "y"}}} =
               Confirm.reissue_for_user(old, actor, @set, "hash", %{}, "fp2", DateTime.utc_now(),
                 context: %{"origin" => "y"}
               )
    end
  end
end
