defmodule PhoenixKit.Integration.Notifications.PushTest do
  @moduledoc """
  Browser push (`PhoenixKit.Notifications.Push`): devices and accounts, the
  grouping, what a push says, the click handle, and the sends — against a
  fake push service that decrypts what it receives with the subscription's
  private key, so the payload is checked end to end.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels.Push, as: PushChannel
  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Push.{Binding, GroupWorker, Installation, SendWorker, WebPush}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @stub __MODULE__.PushService

  setup do
    Application.put_env(:phoenix_kit, :push_resolve_endpoints, false)
    Application.put_env(:phoenix_kit, :push_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :push_resolve_endpoints)
      Application.delete_env(:phoenix_kit, :push_req_options)
    end)

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    # The first account of a fresh database becomes Owner; these must not.
    _seed = user!()
    :ok
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "push_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    user
  end

  # A browser's subscription, with the private key kept to decrypt.
  defp browser do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    b64 = &Base.url_encode64(&1, padding: false)

    %{
      json: %{
        "endpoint" =>
          "https://fcm.googleapis.com/fcm/send/#{b64.(:crypto.strong_rand_bytes(12))}",
        "keys" => %{"p256dh" => b64.(pub), "auth" => b64.(auth)}
      },
      private: priv,
      public: pub,
      auth: auth
    }
  end

  defp decrypt(body, %{private: priv, public: pub, auth: auth}) do
    <<salt::binary-16, _rs::32, 65::8, as_public::binary-65, rest::binary>> = body
    hmac = &:crypto.mac(:hmac, :sha256, &1, &2)
    shared = :crypto.compute_key(:ecdh, as_public, priv, :prime256v1)
    prk_key = hmac.(auth, shared)

    ikm =
      binary_part(hmac.(prk_key, "WebPush: info" <> <<0>> <> pub <> as_public <> <<1>>), 0, 32)

    prk = hmac.(salt, ikm)
    cek = binary_part(hmac.(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac.(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)
    size = byte_size(rest) - 16
    <<ciphertext::binary-size(size), tag::binary-16>> = rest

    plain = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, "", tag, false)
    plain |> binary_part(0, byte_size(plain) - 1) |> Jason.decode!()
  end

  defp subscribe!(user, b, opts \\ []) do
    {:ok, installation} =
      Push.subscribe(
        user,
        b.json,
        Keyword.merge([impersonated: false, browser_id: "browser-id-0123456789"], opts)
      )

    installation
  end

  defp jobs(worker) do
    worker = inspect(worker) |> String.replace_prefix("", "")

    Repo.all(from(j in Oban.Job, where: j.worker == ^worker, order_by: j.id))
  end

  defp envelope(user, extra \\ %{}) do
    Map.merge(
      %{
        recipient_uuid: user.uuid,
        type_key: "comments",
        title: "ACME-12 · Fit the doors",
        text: "Anna marked “Fit the doors” done",
        url: Routes.url("/admin/projects/ACME"),
        notification_uuid: Ecto.UUID.generate()
      },
      extra
    )
  end

  describe "devices and accounts" do
    test "turning push on: refused in a borrowed session, for a bad or foreign endpoint" do
      user = user!()
      b = browser()

      assert {:error, :impersonated} = Push.subscribe(user, b.json, [])
      assert {:error, :impersonated} = Push.subscribe(user, b.json, impersonated: true)

      assert {:error, :bad_subscription} =
               Push.subscribe(user, %{"endpoint" => "x"}, impersonated: false)

      foreign = Map.put(b.json, "endpoint", "https://evil.example/push")
      assert {:error, :endpoint_refused} = Push.subscribe(user, foreign, impersonated: false)

      Settings.update_boolean_setting("push_enabled", false)
      assert {:error, :not_enabled} = Push.subscribe(user, b.json, impersonated: false)
      Settings.update_boolean_setting("push_enabled", true)
    end

    test "one browser is one installation; each account its own binding; email types pre-ticked" do
      a = user!()
      b_user = user!()

      ChannelConfig.update(a, "email", fn c -> Map.put(c, "types", %{"comments" => true}) end)

      b = browser()
      i1 = subscribe!(a, b)
      i2 = subscribe!(b_user, b)

      assert i1.uuid == i2.uuid
      assert Repo.aggregate(Binding, :count) == 2
      assert Push.any_device?(a.uuid)

      a = Auth.get_user(a.uuid)
      assert ChannelConfig.for_channel(a, "push")["types"] == %{"comments" => true}
      assert [%{label: _}] = Push.devices(a.uuid)
    end

    test "logging out in a browser drops that account there; the last account takes the device" do
      a = user!()
      c = user!()
      b = browser()
      installation = subscribe!(a, b)
      subscribe!(c, b)

      Push.forget_browser(a.uuid, "browser-id-0123456789")
      refute Push.any_device?(a.uuid)
      assert Repo.get(Installation, installation.uuid)

      Push.forget_browser(c.uuid, "browser-id-0123456789")
      refute Repo.get(Installation, installation.uuid)
    end

    test "a known endpoint is joined only with its own keys, never re-keyed by another" do
      victim = user!()
      attacker = user!()
      b = browser()
      installation = subscribe!(victim, b)

      other = browser()
      forged = Map.put(other.json, "endpoint", b.json["endpoint"])

      assert {:error, :bad_subscription} =
               Push.subscribe(attacker, forged, impersonated: false)

      kept = Repo.get(Installation, installation.uuid)
      assert kept.auth == b.json["keys"]["auth"]
      assert kept.p256dh == b.json["keys"]["p256dh"]
      refute Push.any_device?(attacker.uuid)

      # Nor can the attacker now pass the resubscribe proof.
      assert {:error, :not_found} =
               Push.resubscribe(b.json["endpoint"], other.json["keys"]["auth"], browser().json)
    end

    test "a rotated subscription is taken only with the old one's secret" do
      a = user!()
      old = browser()
      subscribe!(a, old)
      new = browser()

      assert {:error, :not_found} =
               Push.resubscribe(old.json["endpoint"], "wrong-secret", new.json)

      assert :ok =
               Push.resubscribe(old.json["endpoint"], old.json["keys"]["auth"], new.json)

      assert Push.installation_for(new.json["endpoint"])
      refute Push.installation_for(old.json["endpoint"])
    end
  end

  describe "what a push says" do
    test "one notice: the site and New notification; several: N notifications pending" do
      a = user!()

      {:ok, one} = Push.queue(envelope(a)) |> then(fn :ok -> Push.take_pending(a.uuid) end)
      assert one["body"] == "New notification"
      refute one["body"] =~ "Fit the doors"
      assert one["tag"] == "pk-" <> String.replace(a.uuid, "-", "")

      for _ <- 1..3, do: :ok = Push.queue(envelope(a))
      {:ok, three} = Push.take_pending(a.uuid)
      assert three["body"] == "3 notifications pending"
      assert three["count"] == 3
      assert Push.take_pending(a.uuid) == :none
    end

    test "with the site's setting, the line" do
      Settings.update_boolean_setting("push_show_line", true)
      on_exit(fn -> Settings.update_boolean_setting("push_show_line", false) end)

      a = user!()
      :ok = Push.queue(envelope(a))
      {:ok, payload} = Push.take_pending(a.uuid)
      assert payload["title"] == "ACME-12 · Fit the doors"
      assert payload["body"] == "Anna marked “Fit the doors” done"
    end

    test "the click handle is opaque, round-trips, and refuses anything altered or foreign" do
      a = user!()
      url = Push.open_url(a.uuid, Routes.url("/admin/projects/ACME"), false)
      handle = url |> String.split("/notifications/open/") |> List.last()

      refute handle =~ a.uuid
      assert {:ok, %{user_uuid: uuid, link: link, summary?: false}} = Push.read_handle(handle)
      assert uuid == a.uuid
      assert link =~ "/admin/projects/ACME"

      assert :error = Push.read_handle(String.slice(handle, 0..-3//1) <> "AA")
      assert :error = Push.read_handle("not-a-handle")

      # A link to another site is never kept.
      assert Push.same_site_link("https://evil.example/steal") == nil
      assert Push.same_site_link("//evil.example/steal") == nil
      assert Push.same_site_link("/admin/x?y=1") == "/admin/x?y=1"
      assert Push.same_site_link("/\\evil.example/steal") == nil
      assert Push.same_site_link("/\t/evil.example") == nil
      assert Push.same_site_link("javascript:alert(1)") == nil
      assert Push.same_site_link("/" <> String.duplicate("a", 1_100)) == nil
    end
  end

  describe "limits and clean-up" do
    test "text is cut by bytes at a character boundary" do
      assert Push.cut_bytes("short", 10) == "short"
      cut = Push.cut_bytes(String.duplicate("👨‍👩‍👧‍👦", 20), 100)
      assert byte_size(cut) <= 100
      assert String.valid?(cut)
      assert String.ends_with?(cut, "…")
    end

    test "a tiny limit gives nothing rather than more than asked" do
      assert Push.cut_bytes("abcdef", 2) == ""
    end

    test "a long emoji label fits its column" do
      a = user!()
      b = browser()

      assert {:ok, _} =
               Push.subscribe(a, b.json,
                 impersonated: false,
                 label: String.duplicate("👨‍👩‍👧‍👦", 40)
               )
    end

    test "a push stays within the service's size in any script" do
      Settings.update_boolean_setting("push_show_line", true)
      on_exit(fn -> Settings.update_boolean_setting("push_show_line", false) end)

      a = user!()

      long =
        String.duplicate("👨‍👩‍👧‍👦", 400) <> String.duplicate(<<1>>, 600) <> String.duplicate("\"", 600)

      :ok =
        Push.queue(
          envelope(a, %{title: long, text: long, url: "/" <> String.duplicate("a", 1_000)})
        )

      {:ok, payload} = Push.take_pending(a.uuid)
      assert byte_size(Jason.encode!(payload)) <= 3_993
    end

    test "deleting an account takes the devices only it used" do
      a = user!()
      c = user!()
      shared = browser()
      own = browser()
      s = subscribe!(a, shared)
      subscribe!(c, shared)
      o = subscribe!(a, own)

      :ok = Push.forget_account(a.uuid)
      refute Repo.get(Installation, o.uuid)
      assert Repo.get(Installation, s.uuid)
      assert Push.any_device?(c.uuid)
    end
  end

  describe "sending" do
    setup do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:pushed, conn.request_path, conn.req_headers, body})
        status = Process.get(:push_status, 201)
        Plug.Conn.send_resp(conn, status, "")
      end)

      :ok
    end

    test "a burst becomes one push per device, encrypted for it, with TTL and topic" do
      a = user!()
      b = browser()
      subscribe!(a, b)

      for _ <- 1..2, do: :ok = Push.queue(envelope(a))

      # One grouping job however many notices.
      assert [%{args: %{"user_uuid" => user_uuid}}] = jobs(GroupWorker)
      assert user_uuid == a.uuid

      :ok = GroupWorker.perform(%Oban.Job{args: %{"user_uuid" => a.uuid}})
      assert [send_job] = jobs(SendWorker)
      :ok = SendWorker.perform(%Oban.Job{args: send_job.args})

      assert_received {:pushed, _path, headers, body}
      headers = Map.new(headers)
      # (Req's test adapter drops `content-encoding`; `request_headers/3` has it.)
      assert {"content-encoding", "aes128gcm"} in WebPush.request_headers(
               b.json["endpoint"],
               elem(WebPush.vapid_key(), 1),
               []
             )

      assert headers["ttl"] == "604800"
      assert headers["topic"] == String.replace(a.uuid, "-", "")
      assert headers["authorization"] =~ ~r/\Avapid t=[^,]+, k=/

      payload = decrypt(body, b)
      assert payload["body"] == "2 notifications pending"
      assert payload["url"] =~ "/notifications/open/"

      assert Repo.get_by(Installation, endpoint_hash: Push.hash(b.json["endpoint"])).last_success_at
    end

    test "a device the service says is gone is removed; a busy service is retried" do
      a = user!()
      b = browser()
      installation = subscribe!(a, b)
      args = %{"installation_uuid" => installation.uuid, "user_uuid" => a.uuid, "payload" => "{}"}

      Process.put(:push_status, 429)
      assert {:error, :push_service_busy} = SendWorker.perform(%Oban.Job{args: args})
      assert Repo.get(Installation, installation.uuid)

      Process.put(:push_status, 410)
      assert :ok = SendWorker.perform(%Oban.Job{args: args})
      refute Repo.get(Installation, installation.uuid)
    end

    test "a 410 for a subscription rotated mid-send keeps the new one" do
      a = user!()
      b = browser()
      installation = subscribe!(a, b)
      stale = Repo.get(Installation, installation.uuid)
      new = browser()
      :ok = Push.resubscribe(b.json["endpoint"], b.json["keys"]["auth"], new.json)

      Process.put(:push_status, 410)
      assert :ok = SendWorker.send_to(stale, "{}", nil)
      assert Repo.get(Installation, installation.uuid)
    end

    test "a device whose account logged out there gets nothing" do
      a = user!()
      b = browser()
      installation = subscribe!(a, b)
      Push.forget_browser(a.uuid, "browser-id-0123456789")

      args = %{"installation_uuid" => installation.uuid, "user_uuid" => a.uuid, "payload" => "{}"}
      assert :ok = SendWorker.perform(%Oban.Job{args: args})
      refute_received {:pushed, _, _, _}
    end

    test "a notice the reader may no longer see is not queued at all" do
      a = user!()

      assert :ok =
               PushChannel.deliver(
                 Map.put(envelope(a), :visible, false),
                 %{}
               )

      assert Push.take_pending(a.uuid) == :none
    end
  end
end
