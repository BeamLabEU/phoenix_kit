defmodule PhoenixKit.Integration.Notifications.MessagePartsTest do
  @moduledoc """
  A notification made of parts (the boss's item 20, decided with Max on
  2026-11-20): a title, the line, the quoted comment, a button and the
  setting line that sent it, laid out by each channel.

    * Telegram: plain text with an "Open" button, no preview card, held to
      4,096 UTF-16 units with the quote cut first; a button Telegram refuses
      is sent again without it.
    * Email: the title on one line as the subject, the module's button
      label, the setting line with a "Change" link.
  """

  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels.Email
  alias PhoenixKit.Notifications.Channels.Telegram, as: Channel
  alias PhoenixKit.Notifications.Messages
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User

  @stub __MODULE__.Telegram

  defp user do
    {:ok, user} =
      Auth.register_user(%{
        email: "parts_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  defp envelope(user, extra) do
    Map.merge(
      %{
        recipient_uuid: user.uuid,
        title: "ACME-12 can be started",
        text: "Fit the doors (ACME-12) can be started",
        quote: "Max: Please measure wall A again.",
        url: "https://site.example.test/projects/ACME/tasks?task=ACME-12",
        action_label: "Open task",
        reason: "You get this because “A task of yours can be started” is on.",
        reason_url: "https://site.example.test/settings#notif-projects"
      },
      extra
    )
  end

  describe "Telegram" do
    setup do
      Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
      on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

      {:ok, %{uuid: site}} = Integrations.add_connection("telegram", "site bot")
      {:ok, _} = Integrations.save_setup(site, %{"bot_token" => "111:SITE"})
      :ok = SiteBot.select(site)

      user = user()
      {:ok, _} = Linking.link_chat(user, site, 4242)
      config = ChannelConfig.for_channel(Auth.get_user!(user.uuid), "telegram")

      %{user: user, config: config}
    end

    defp telegram_answers(fun) do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:telegram, body})
        fun.(conn, body)
      end)
    end

    defp ok(conn), do: Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 1}})

    test "the title, the line, the quote and the setting line; the link is a button",
         %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      assert :ok = Channel.deliver(envelope(user, %{}), config)
      assert_received {:telegram, body}

      assert body["text"] ==
               Enum.join(
                 [
                   "ACME-12 can be started",
                   "Fit the doors (ACME-12) can be started",
                   "Max: Please measure wall A again.",
                   "You get this because “A task of yours can be started” is on.\n" <>
                     "https://site.example.test/settings#notif-projects"
                 ],
                 "\n\n"
               )

      refute body["text"] =~ "task=ACME-12"
      refute Map.has_key?(body, "parse_mode")
      assert body["link_preview_options"] == %{"is_disabled" => true}

      assert body["reply_markup"] == %{
               "inline_keyboard" => [
                 [
                   %{
                     "text" => "Open task",
                     "url" => "https://site.example.test/projects/ACME/tasks?task=ACME-12"
                   }
                 ]
               ]
             }
    end

    test "a button Telegram refuses is sent again without it, the link in the text",
         %{user: user, config: config} do
      telegram_answers(fn conn, body ->
        if Map.has_key?(body, "reply_markup") do
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"ok" => false, "description" => "Bad Request: BUTTON_URL_INVALID"})
        else
          ok(conn)
        end
      end)

      assert :ok = Channel.deliver(envelope(user, %{}), config)

      assert_received {:telegram, %{"reply_markup" => _}}
      assert_received {:telegram, second}
      refute Map.has_key?(second, "reply_markup")
      assert second["text"] =~ "https://site.example.test/projects/ACME/tasks?task=ACME-12"
    end

    test "a long quote is cut to fit, counting an emoji as two", %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      quote = String.duplicate("👍", 3_000)
      assert :ok = Channel.deliver(envelope(user, %{quote: quote}), config)
      assert_received {:telegram, body}

      assert Channel.utf16_length(body["text"]) <= 4_096
      assert body["text"] =~ "(open it to read the rest)"
      assert body["text"] =~ "Fit the doors (ACME-12) can be started"
      assert body["text"] =~ "You get this because"
      assert String.valid?(body["text"])
    end

    test "saved wording is the text; values go in once, as written", %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      owner = %Scope{
        user: %User{uuid: Ecto.UUID.generate()},
        authenticated?: true,
        cached_roles: ["Owner"],
        cached_permissions: MapSet.new()
      }

      {:ok, _} =
        Messages.save(owner, "*", "telegram", "en", %{
          "text" => "{{text}}\n\n{{quote}}\n\n— {{title}}"
        })

      env = envelope(user, %{locale: "en", type_key: nil, quote: "says {{title}} literally"})
      assert :ok = Channel.deliver(env, config)
      assert_received {:telegram, body}

      assert body["text"] ==
               "Fit the doors (ACME-12) can be started\n\nsays {{title}} literally\n\n— ACME-12 can be started"

      # The button stays the renderer's.
      assert body["reply_markup"]["inline_keyboard"]
    end

    test "a line at the limit never takes the message over 4,096, and the link survives",
         %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      long = String.duplicate("a", 4_096)

      env = envelope(user, %{title: nil, text: long, quote: "q", reason: nil, reason_url: nil})
      assert :ok = Channel.deliver(env, config)
      assert_received {:telegram, body}
      assert Channel.utf16_length(body["text"]) <= 4_096

      # With no button (refused), the link is kept and the line cut instead.
      telegram_answers(fn conn, body ->
        if Map.has_key?(body, "reply_markup") do
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"ok" => false, "description" => "Bad Request: BUTTON_URL_INVALID"})
        else
          ok(conn)
        end
      end)

      assert :ok = Channel.deliver(%{env | quote: nil}, config)
      assert_received {:telegram, %{"reply_markup" => _}}
      assert_received {:telegram, second}
      assert Channel.utf16_length(second["text"]) <= 4_096
      assert second["text"] =~ "https://site.example.test/projects/ACME/tasks?task=ACME-12"
    end

    test "a rate limit that mentions a URL is not taken for a refused button",
         %{user: user, config: config} do
      telegram_answers(fn conn, _body ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "ok" => false,
          "description" => "Too Many Requests: retry after 5 (URL requests)",
          "parameters" => %{"retry_after" => 5}
        })
      end)

      refute :ok == Channel.deliver(envelope(user, %{}), config)
      assert_received {:telegram, %{"reply_markup" => _}}
      refute_received {:telegram, _}
    end

    test "a saved text that comes out empty sends the default layout",
         %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      owner = %Scope{
        user: %User{uuid: Ecto.UUID.generate()},
        authenticated?: true,
        cached_roles: ["Owner"],
        cached_permissions: MapSet.new()
      }

      {:ok, _} =
        Messages.save(owner, "*", "telegram", "en", %{
          "text" => "{{quote}}"
        })

      assert :ok =
               Channel.deliver(envelope(user, %{locale: "en", type_key: nil, quote: nil}), config)

      assert_received {:telegram, body}
      assert body["text"] =~ "Fit the doors (ACME-12) can be started"
    end

    test "a reason longer than the message is cut too",
         %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      env =
        envelope(user, %{
          title: "T",
          text: "x",
          quote: nil,
          url: nil,
          reason: String.duplicate("r", 5_000)
        })

      assert :ok = Channel.deliver(env, config)
      assert_received {:telegram, body}
      assert Channel.utf16_length(body["text"]) <= 4_096
    end

    test "a rate limit that mentions buttons is not taken for a refused button",
         %{user: user, config: config} do
      telegram_answers(fn conn, _body ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "ok" => false,
          "description" => "Too Many Requests: retry after 30 for messages with buttons"
        })
      end)

      refute :ok == Channel.deliver(envelope(user, %{}), config)
      assert_received {:telegram, %{"reply_markup" => _}}
      refute_received {:telegram, _}
    end

    test "with no link there is no button", %{user: user, config: config} do
      telegram_answers(fn conn, _body -> ok(conn) end)

      assert :ok = Channel.deliver(envelope(user, %{url: nil}), config)
      assert_received {:telegram, body}
      refute Map.has_key?(body, "reply_markup")
    end
  end

  describe "email" do
    test "the title on one line is the subject; the button and the setting line" do
      user = user()

      assert :ok =
               Email.deliver(envelope(user, %{title: "ACME-12\ncan be started\r\nBcc: x"}), %{})

      assert_email_sent(fn email ->
        assert email.subject == "ACME-12 can be started Bcc: x"

        assert email.text_body =~ "Max: Please measure wall A again."
        assert email.text_body =~ "Open task: https://site.example.test/projects/ACME/tasks"
        assert email.text_body =~ "Change: https://site.example.test/settings#notif-projects"

        assert email.html_body =~
                 ~r{<a[^>]*href="https://site.example.test/projects/ACME/tasks\?task=ACME-12"[^>]*>\s*Open task\s*</a>}
      end)
    end

    test "a quoted comment is shown as written, never as markup" do
      user = user()

      assert :ok =
               Email.deliver(
                 envelope(user, %{
                   quote: "**bold** <img src=x onerror=alert(1)> [x](javascript:1)"
                 }),
                 %{}
               )

      assert_email_sent(fn email ->
        refute email.html_body =~ "<img src=x"
        refute email.html_body =~ "<strong>bold</strong>"
        # Shown as the writer typed it, never as a link.
        refute email.html_body =~ ~s(href="javascript:)
        assert email.html_body =~ "**bold**"
      end)
    end
  end

  describe "the type's visibility check" do
    test "a type without one is visible; an unknown type too" do
      assert Types.still_visible?("no.such.type", %{}, %{})
      assert Types.still_visible?(nil, %{}, %{})
    end
  end
end
