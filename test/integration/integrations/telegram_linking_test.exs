defmodule PhoenixKit.Integration.Integrations.TelegramLinkingTest do
  @moduledoc """
  Linking a Telegram chat to an account through the site bot: a one-time
  `/start <token>` deep link, read from the bot's pending updates.

  Telegram is stubbed with `Req.Test` (`:telegram_req_options`); nothing here
  opens a socket.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.UserToken

  @stub __MODULE__.Telegram

  setup do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, flags} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(@stub, fn conn ->
      method = conn.request_path |> String.split("/") |> List.last()
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      send(test_pid, {:telegram, method, body})

      flags = Agent.get(flags, & &1)

      # A getUpdates with an offset is the confirmation; without one, the read.
      failing? =
        method == "getUpdates" and
          ((Map.has_key?(body, "offset") and flags[:confirm_fails] == true) or
             (not Map.has_key?(body, "offset") and flags[:read_fails] == true))

      if failing? do
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"ok" => false, "description" => "Unauthorized"})
      else
        result =
          case method do
            "getUpdates" -> Agent.get(agent, & &1)
            "sendMessage" -> %{"message_id" => 1}
            _ -> true
          end

        Req.Test.json(conn, %{"ok" => true, "result" => result})
      end
    end)

    {:ok, %{uuid: connection_uuid}} = Integrations.add_connection("telegram", "site bot")
    {:ok, _} = Integrations.save_setup(connection_uuid, %{"bot_token" => "123:ABC"})

    %{connection: connection_uuid, updates: agent, flags: flags}
  end

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        email: "linker_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp start_update(update_id, chat_id, token, type \\ "private") do
    %{
      "update_id" => update_id,
      "message" => %{
        "chat" => %{"id" => chat_id, "type" => type},
        "text" => "/start " <> token
      }
    }
  end

  defp put_updates(agent, updates), do: Agent.update(agent, fn _ -> updates end)

  defp fail(flags, what), do: Agent.update(flags, &Map.put(&1, what, true))

  defp activity(action, user_uuid) do
    RepoHelper.repo().all(
      from e in Entry, where: e.action == ^action and e.actor_uuid == ^user_uuid
    )
  end

  defp linked(user_uuid) do
    user = Auth.get_user!(user_uuid)
    ChannelConfig.for_channel(user, "telegram")
  end

  describe "create_token/2" do
    test "returns a token that fits Telegram's 64-character start parameter", %{
      connection: connection
    } do
      assert {:ok, token} = Linking.create_token(user(), connection)

      assert byte_size(token) <= 64
      assert token =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "stores only a hash, never the token", %{connection: connection} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      stored = RepoHelper.repo().all(from t in UserToken, where: t.context == "telegram_link")

      assert [%{user_uuid: uuid}] = Enum.filter(stored, &(&1.user_uuid == u.uuid))
      assert uuid == u.uuid
      refute Enum.any?(stored, &(&1.token == token))
    end

    test "a new token replaces the user's earlier one", %{connection: connection} do
      u = user()
      {:ok, first} = Linking.create_token(u, connection)
      {:ok, second} = Linking.create_token(u, connection)

      assert :error = Linking.consume_token(first, connection)
      assert {:ok, _} = Linking.consume_token(second, connection)
    end
  end

  describe "consume_token/1" do
    test "gives back who the token belongs to, once", %{connection: connection} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      assert {:ok, %{user_uuid: user_uuid, connection_uuid: ^connection}} =
               Linking.consume_token(token, connection)

      assert user_uuid == u.uuid
      assert :error = Linking.consume_token(token, connection)
    end

    test "refuses an expired token", %{connection: connection} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      old = DateTime.utc_now() |> DateTime.add(-16 * 60, :second) |> DateTime.truncate(:second)

      RepoHelper.repo().update_all(
        from(t in UserToken, where: t.context == "telegram_link" and t.user_uuid == ^u.uuid),
        set: [inserted_at: old]
      )

      assert :error = Linking.consume_token(token, connection)
    end

    test "refuses junk without raising" do
      for junk <- ["", "nope", "!!!", String.duplicate("a", 200)] do
        assert :error = Linking.consume_token(junk, "any")
      end
    end

    test "a token of another kind is not accepted", %{connection: connection} do
      u = user()
      {token, row} = UserToken.build_email_token(u, "magic_link")
      {:ok, _} = RepoHelper.repo().insert(%{row | sent_to: connection})

      assert :error = Linking.consume_token(token, connection)
    end
  end

  describe "poll/1" do
    test "links the chat that sent /start with the owner's token", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(10, 5_550_001, token)])

      assert {:ok, %{linked: 1}} = Linking.poll(connection)

      assert %{"site_chat_id" => "5550001", "site_connection_uuid" => ^connection} =
               linked(u.uuid)
    end

    test "each token links its own owner, whatever the order of the messages", %{
      connection: connection,
      updates: updates
    } do
      a = user()
      b = user()
      c = user()
      {:ok, ta} = Linking.create_token(a, connection)
      {:ok, tb} = Linking.create_token(b, connection)

      # C writes last, with no token at all; B before A.
      put_updates(updates, [
        start_update(1, 222, tb),
        start_update(2, 111, ta),
        %{
          "update_id" => 3,
          "message" => %{"chat" => %{"id" => 333, "type" => "private"}, "text" => "/start"}
        }
      ])

      assert {:ok, %{linked: 2}} = Linking.poll(connection)

      assert linked(a.uuid)["site_chat_id"] == "111"
      assert linked(b.uuid)["site_chat_id"] == "222"
      assert linked(c.uuid) == %{}
    end

    test "a token used twice links only the first chat", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      put_updates(updates, [start_update(1, 111, token), start_update(2, 999, token)])

      assert {:ok, %{linked: 1}} = Linking.poll(connection)
      assert linked(u.uuid)["site_chat_id"] == "111"
    end

    test "ignores a token sent from a group", %{connection: connection, updates: updates} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, -100_500, token, "supergroup")])

      assert {:ok, %{linked: 0}} = Linking.poll(connection)
      assert linked(u.uuid) == %{}
      # …and the token is still good for the owner's own chat.
      assert {:ok, _} = Linking.consume_token(token, connection)
    end

    test "a token minted for another bot is not honoured here", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, other} = Integrations.add_connection("telegram", "other bot")
      {:ok, token} = Linking.create_token(u, other.uuid)
      put_updates(updates, [start_update(1, 111, token)])

      assert {:ok, %{linked: 0}} = Linking.poll(connection)
      assert linked(u.uuid) == %{}
    end

    test "a token minted for another bot is not spent by this one", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, other} = Integrations.add_connection("telegram", "other bot")
      {:ok, token} = Linking.create_token(u, other.uuid)
      put_updates(updates, [start_update(1, 111, token)])

      assert {:ok, %{linked: 0}} = Linking.poll(connection)

      # Still good for the bot it was made for.
      assert {:ok, %{user_uuid: uuid}} = Linking.consume_token(token, other.uuid)
      assert uuid == u.uuid
    end

    test "answers /start@bot and refuses lookalike commands", %{
      connection: connection,
      updates: updates
    } do
      a = user()
      b = user()
      {:ok, ta} = Linking.create_token(a, connection)
      {:ok, tb} = Linking.create_token(b, connection)

      put_updates(updates, [
        %{
          "update_id" => 1,
          "message" => %{
            "chat" => %{"id" => 111, "type" => "private"},
            "text" => "/start@shop_bot " <> ta
          }
        },
        %{
          "update_id" => 2,
          "message" => %{
            "chat" => %{"id" => 222, "type" => "private"},
            "text" => "/startx " <> tb
          }
        }
      ])

      assert {:ok, %{linked: 1}} = Linking.poll(connection)
      assert linked(a.uuid)["site_chat_id"] == "111"
      assert linked(b.uuid) == %{}
      assert {:ok, _} = Linking.consume_token(tb, connection)
    end

    test "a chat that writes many times is answered once and looked up once", %{
      connection: connection,
      updates: updates
    } do
      junk = for n <- 1..100, do: start_update(n, 777, String.duplicate("A", 43))
      put_updates(updates, junk)

      handler = "linking-lookups-#{System.unique_integer([:positive])}"
      me = self()

      :telemetry.attach(
        handler,
        [:phoenix_kit, :test, :repo, :query],
        fn _event, _measure, %{query: query}, _config ->
          if self() == me and query =~ "site_chat_id", do: send(me, :chat_lookup)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{linked: 0}} = Linking.poll(connection)

      assert_received {:telegram, "sendMessage", %{"chat_id" => 777}}
      refute_received {:telegram, "sendMessage", _}
      assert_received :chat_lookup
      refute_received :chat_lookup
    end

    test "a valid token among a chat's junk still links it, with one answer", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      junk = fn n -> start_update(n, 777, String.duplicate("A", 43)) end
      put_updates(updates, [junk.(1), start_update(2, 777, token), junk.(3)])

      assert {:ok, %{linked: 1}} = Linking.poll(connection)

      assert linked(u.uuid)["site_chat_id"] == "777"
      assert_received {:telegram, "sendMessage", %{"chat_id" => 777, "text" => text}}
      assert text =~ "Connected"
      refute_received {:telegram, "sendMessage", _}
    end

    test "/start@other_bot is refused once the bot's name is known", %{
      connection: connection,
      updates: updates
    } do
      Integrations.record_validation(connection, {:ok, %{fact: "Connected as @shop_bot"}},
        owner: :system
      )

      a = user()
      b = user()
      {:ok, ta} = Linking.create_token(a, connection)
      {:ok, tb} = Linking.create_token(b, connection)

      put_updates(updates, [
        %{
          "update_id" => 1,
          "message" => %{
            "chat" => %{"id" => 111, "type" => "private"},
            "text" => "/start@Shop_Bot " <> ta
          }
        },
        %{
          "update_id" => 2,
          "message" => %{
            "chat" => %{"id" => 222, "type" => "private"},
            "text" => "/start@other_bot " <> tb
          }
        }
      ])

      assert {:ok, %{linked: 1}} = Linking.poll(connection)
      assert linked(a.uuid)["site_chat_id"] == "111"
      assert linked(b.uuid) == %{}
      assert {:ok, _} = Linking.consume_token(tb, connection)
    end

    test "a failed read links nothing, spends nothing and confirms nothing", %{
      connection: connection,
      updates: updates,
      flags: flags
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])
      fail(flags, :read_fails)

      assert {:error, "Unauthorized"} = Linking.poll(connection)

      assert linked(u.uuid) == %{}
      refute_received {:telegram, "sendMessage", _}
      assert Linking.pending?(u, connection)
    end

    test "another node holding the bot's lock makes it busy and changes nothing", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])

      opts =
        Keyword.take(RepoHelper.repo().config(), [
          :hostname,
          :port,
          :username,
          :password,
          :database
        ])

      # Its own connection: the test's sandbox connection would share the lock.
      {:ok, holder} = Postgrex.start_link(opts)

      Postgrex.query!(holder, "SELECT pg_advisory_lock(hashtext($1))", [
        "phoenix_kit_telegram_link:" <> connection
      ])

      assert :busy = Linking.poll(connection)

      assert linked(u.uuid) == %{}
      assert Linking.pending?(u, connection)
      refute_received {:telegram, "sendMessage", _}
      refute_received {:telegram, "getUpdates", %{"offset" => _}}

      Postgrex.query!(holder, "SELECT pg_advisory_unlock(hashtext($1))", [
        "phoenix_kit_telegram_link:" <> connection
      ])

      assert {:ok, %{linked: 1}} = Linking.poll(connection)
    end

    test "when the confirmation fails the links stand and the batch read again is silent", %{
      connection: connection,
      updates: updates,
      flags: flags
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      put_updates(updates, [
        start_update(1, 111, token),
        start_update(2, 999, "Z" |> String.duplicate(43))
      ])

      fail(flags, :confirm_fails)

      assert {:ok, %{linked: 1}} = Linking.poll(connection)
      assert linked(u.uuid)["site_chat_id"] == "111"

      # The linked chat is told; the stranger's "expired" waits for a poll that
      # can confirm, or it would be said twice.
      assert_received {:telegram, "sendMessage", %{"chat_id" => 111, "text" => connected}}
      assert connected =~ "Connected"
      refute_received {:telegram, "sendMessage", %{"chat_id" => 999}}

      # Same batch again, this time confirmed: the linked chat hears nothing.
      Agent.update(flags, &Map.delete(&1, :confirm_fails))
      assert {:ok, %{linked: 0}} = Linking.poll(connection)

      refute_received {:telegram, "sendMessage", %{"chat_id" => 111}}
      assert_received {:telegram, "sendMessage", %{"chat_id" => 999, "text" => expired}}
      assert expired =~ "expired"
      assert linked(u.uuid)["site_chat_id"] == "111"
    end

    test "Start pressed twice from the linked chat is not answered 'expired'", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])
      {:ok, %{linked: 1}} = Linking.poll(connection)
      assert_received {:telegram, "sendMessage", %{"chat_id" => 111}}

      put_updates(updates, [start_update(2, 111, token)])
      assert {:ok, %{linked: 0}} = Linking.poll(connection)

      refute_received {:telegram, "sendMessage", _}
    end

    test "records who linked in the activity feed, without the chat", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 5_550_001, token)])

      {:ok, _} = Linking.poll(connection)

      assert [entry] = activity("telegram.linked", u.uuid)
      assert entry.module == "notifications"
      refute inspect(entry.metadata) =~ "5550001"
    end

    test "pending?/2 is about one bot", %{connection: connection} do
      u = user()
      {:ok, other} = Integrations.add_connection("telegram", "other bot")
      {:ok, _} = Linking.create_token(u, connection)

      assert Linking.pending?(u, connection)
      refute Linking.pending?(u, other.uuid)
    end

    test "confirms what it read, so the next poll does not see it again", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(41, 111, token), start_update(42, 5, "zzz")])

      {:ok, _} = Linking.poll(connection)

      assert_received {:telegram, "getUpdates", %{"offset" => 43}}
    end

    test "tells the chat it was linked, without naming the account", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])

      {:ok, _} = Linking.poll(connection)

      assert_received {:telegram, "sendMessage", %{"chat_id" => 111, "text" => text}}
      refute text =~ u.email
      refute text =~ "linker_"
    end

    test "tells a stranger whose link has expired how to get a new one", %{
      connection: connection,
      updates: updates
    } do
      put_updates(updates, [start_update(1, 777, String.duplicate("A", 64))])

      assert {:ok, %{linked: 0}} = Linking.poll(connection)

      assert_received {:telegram, "sendMessage", %{"chat_id" => 777, "text" => text}}
      assert text =~ "expired"
    end

    test "does not answer a /start that carries no token", %{
      connection: connection,
      updates: updates
    } do
      put_updates(updates, [
        %{
          "update_id" => 1,
          "message" => %{"chat" => %{"id" => 5, "type" => "private"}, "text" => "/start"}
        },
        %{
          "update_id" => 2,
          "message" => %{"chat" => %{"id" => 5, "type" => "private"}, "text" => "hello"}
        }
      ])

      {:ok, _} = Linking.poll(connection)

      refute_received {:telegram, "sendMessage", _}
    end

    test "an empty queue links nothing and confirms nothing", %{connection: connection} do
      assert {:ok, %{linked: 0}} = Linking.poll(connection)
      refute_received {:telegram, "getUpdates", %{"offset" => _}}
    end
  end

  describe "linking" do
    test "the first link switches on the types the user already gets in the app", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])

      {:ok, _} = Linking.poll(connection)

      config = linked(u.uuid)
      types = config["types"]
      assert is_map(types)

      for type <- Types.list() do
        assert types[type.key] == Prefs.user_wants_type?(u, type.key)
      end
    end

    test "relinking keeps the types the user chose", %{connection: connection, updates: updates} do
      u = user()
      {:ok, _} = ChannelConfig.put(u, "telegram", %{"types" => %{"orders" => false}})
      {:ok, token} = Linking.create_token(Auth.get_user!(u.uuid), connection)
      put_updates(updates, [start_update(1, 111, token)])

      {:ok, _} = Linking.poll(connection)

      assert linked(u.uuid)["types"] == %{"orders" => false}
    end

    test "linking again switches a channel the delivery worker had disabled back on", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])
      {:ok, _} = Linking.poll(connection)

      # What DeliveryWorker.soft_disable/3 writes after a blocked chat.
      {:ok, _} =
        ChannelConfig.update(Auth.get_user!(u.uuid), "telegram", fn config ->
          config
          |> Map.put("enabled", false)
          |> Map.put("status", "disabled")
          |> Map.put("disabled_reason", "Forbidden: bot was blocked by the user")
        end)

      refute ChannelConfig.enabled?(linked(u.uuid))

      {:ok, again} = Linking.create_token(Auth.get_user!(u.uuid), connection)
      put_updates(updates, [start_update(2, 111, again)])
      assert {:ok, %{linked: 1}} = Linking.poll(connection)

      config = linked(u.uuid)
      assert ChannelConfig.enabled?(config)
      refute Map.has_key?(config, "status")
      refute Map.has_key?(config, "disabled_reason")
    end

    test "unlink records itself in the activity feed", %{connection: connection, updates: updates} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])
      {:ok, _} = Linking.poll(connection)

      :ok = Linking.unlink(Auth.get_user!(u.uuid))

      assert [_] = activity("telegram.unlinked", u.uuid)
    end

    test "unlink removes the chat but keeps the routing choices", %{
      connection: connection,
      updates: updates
    } do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(updates, [start_update(1, 111, token)])
      {:ok, _} = Linking.poll(connection)

      assert :ok = Linking.unlink(Auth.get_user!(u.uuid))

      config = linked(u.uuid)
      refute Map.has_key?(config, "site_chat_id")
      refute Map.has_key?(config, "site_connection_uuid")
      assert is_map(config["types"])
    end
  end

  describe "linked_user/2" do
    test "the user whose link is this chat of this bot, read now", %{connection: connection} do
      u = user()
      {:ok, _} = Linking.link_chat(u, connection, 4242)

      assert %Auth.User{uuid: uuid} = Linking.linked_user(connection, 4242)
      assert uuid == u.uuid
      assert Linking.linked_user(connection, "4242").uuid == u.uuid

      assert Linking.linked_user(connection, 4343) == nil
      assert Linking.linked_user(Ecto.UUID.generate(), 4242) == nil

      :ok = Linking.unlink(Auth.get_user!(u.uuid))
      assert Linking.linked_user(connection, 4242) == nil
    end

    test "a chat two accounts linked names nobody", %{connection: connection} do
      {:ok, _} = Linking.link_chat(user(), connection, 777)
      {:ok, _} = Linking.link_chat(user(), connection, 777)

      assert Linking.linked_user(connection, 777) == nil
    end

    test "a service user is nobody's link", %{connection: connection} do
      u = user()
      {:ok, _} = Linking.link_chat(u, connection, 555)

      RepoHelper.repo().update_all(from(x in Auth.User, where: x.uuid == ^u.uuid),
        set: [api_only: true]
      )

      assert Linking.linked_user(connection, 555) == nil
    end

    test "a malformed argument is nil, never an exception" do
      assert Linking.linked_user(nil, 1) == nil
      assert Linking.linked_user("x", nil) == nil
      assert Linking.linked_user("x", %{}) == nil
    end
  end

  describe "handle_updates/3 (a resident reader's batch)" do
    test "links from the given batch without reading Telegram", %{connection: connection} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      updates = [
        %{"update_id" => 5, "callback_query" => %{"id" => "cb", "data" => "x"}},
        start_update(6, 4242, token)
      ]

      assert {:ok, %{linked: 1}} =
               Linking.handle_updates(connection, updates, confirm: fn _ -> :ok end)

      assert linked(u.uuid)["site_chat_id"] == "4242"
      refute_received {:telegram, "getUpdates", _}
      assert_received {:telegram, "sendMessage", %{"chat_id" => 4242}}
    end

    test "the default confirmation moves the offset past the batch", %{connection: connection} do
      u = user()
      {:ok, token} = Linking.create_token(u, connection)

      assert {:ok, %{linked: 1}} =
               Linking.handle_updates(connection, [start_update(9, 77, token)])

      assert_received {:telegram, "getUpdates", %{"offset" => 10}}
    end

    test "a batch without /start links nothing and takes no lock", %{connection: connection} do
      confirm = fn updates -> send(self(), {:confirmed, length(updates)}) && :ok end

      assert {:ok, %{linked: 0}} =
               Linking.handle_updates(
                 connection,
                 [%{"update_id" => 1, "callback_query" => %{"id" => "cb"}}],
                 confirm: confirm
               )

      assert_received {:confirmed, 1}
    end
  end

  describe "poll/1 with a resident reader" do
    setup do
      on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_updates_reader) end)
      :ok
    end

    def holds?(answer, _connection_uuid), do: answer

    test "reads nothing while the reader holds the bot", %{connection: connection, updates: agent} do
      Application.put_env(:phoenix_kit, :telegram_updates_reader, {__MODULE__, :holds?, [true]})
      u = user()
      {:ok, token} = Linking.create_token(u, connection)
      put_updates(agent, [start_update(1, 55, token)])

      assert Linking.poll(connection) == {:ok, %{linked: 0}}
      refute_received {:telegram, "getUpdates", _}
      assert linked(u.uuid)["site_chat_id"] == nil
    end

    test "reads as before when the reader does not hold it, or cannot answer", %{
      connection: connection,
      updates: agent
    } do
      for reader <- [{__MODULE__, :holds?, [false]}, {__MODULE__, :no_such_function, []}] do
        Application.put_env(:phoenix_kit, :telegram_updates_reader, reader)
        put_updates(agent, [])
        assert Linking.poll(connection) == {:ok, %{linked: 0}}
        assert_received {:telegram, "getUpdates", _}
      end
    end
  end

  describe "Telegram.answer_callback_query/3" do
    test "answers the press with an optional notice", %{connection: connection} do
      assert {:ok, true} =
               PhoenixKit.Integrations.Telegram.answer_callback_query(connection, "cb-1",
                 text: "Готовлю карточку",
                 owner: :system
               )

      assert_received {:telegram, "answerCallbackQuery",
                       %{"callback_query_id" => "cb-1", "text" => "Готовлю карточку"}}
    end
  end

  describe "Telegram.edit_message_text/5" do
    test "edits the message text", %{connection: connection} do
      assert {:ok, true} =
               PhoenixKit.Integrations.Telegram.edit_message_text(
                 connection,
                 55,
                 7,
                 "Карточка готова"
               )

      assert_received {:telegram, "editMessageText", body}
      assert body == %{"chat_id" => 55, "message_id" => 7, "text" => "Карточка готова"}
    end

    test "passes parse_mode, reply_markup and the link-preview switch", %{connection: connection} do
      markup = %{"inline_keyboard" => [[%{"text" => "Ещё", "callback_data" => "more"}]]}

      assert {:ok, true} =
               PhoenixKit.Integrations.Telegram.edit_message_text(connection, 55, 7, "<b>Hi</b>",
                 parse_mode: "HTML",
                 reply_markup: markup,
                 disable_web_page_preview: true,
                 owner: :system
               )

      assert_received {:telegram, "editMessageText", body}

      assert body == %{
               "chat_id" => 55,
               "message_id" => 7,
               "text" => "<b>Hi</b>",
               "parse_mode" => "HTML",
               "reply_markup" => markup,
               "link_preview_options" => %{"is_disabled" => true}
             }
    end

    test "surfaces the Bot API description on an error", %{connection: connection} do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "ok" => false,
          "description" => "Bad Request: message is not modified"
        })
      end)

      assert {:error, "Bad Request: message is not modified"} =
               PhoenixKit.Integrations.Telegram.edit_message_text(connection, 55, 7, "same")
    end

    test "is not configured without a bot token" do
      {:ok, %{uuid: empty}} = Integrations.add_connection("telegram", "no token")

      assert {:error, _} = PhoenixKit.Integrations.Telegram.edit_message_text(empty, 55, 7, "x")
      refute_received {:telegram, "editMessageText", _}
    end
  end

  describe "Telegram.send_chat_action/4" do
    test "defaults to typing", %{connection: connection} do
      assert {:ok, true} = PhoenixKit.Integrations.Telegram.send_chat_action(connection, 55)

      assert_received {:telegram, "sendChatAction", body}
      assert body == %{"chat_id" => 55, "action" => "typing"}
    end

    test "sends the given action", %{connection: connection} do
      assert {:ok, true} =
               PhoenixKit.Integrations.Telegram.send_chat_action(
                 connection,
                 55,
                 "upload_document",
                 owner: :system
               )

      assert_received {:telegram, "sendChatAction", %{"action" => "upload_document"}}
    end
  end
end
