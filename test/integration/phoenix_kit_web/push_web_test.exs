defmodule PhoenixKitWeb.PushWebTest do
  @moduledoc """
  The web side of browser push: the service worker and manifest, the
  resubscribe call, where a notification's click lands (the account in use,
  another account this browser may switch to, anything else), and the
  Browser card of the notification settings.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.MultiSession

  setup do
    Application.put_env(:phoenix_kit, :push_resolve_endpoints, false)
    on_exit(fn -> Application.delete_env(:phoenix_kit, :push_resolve_endpoints) end)

    # The first account of a fresh database becomes Owner; these must not.
    _seed = user!()
    :ok
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "pushweb_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  defp with_peer(conn) do
    ip = {10, 9, rem(System.unique_integer([:positive]), 250), 1}
    {adapter, payload} = conn.adapter

    %{
      conn
      | adapter: {adapter, Map.put(payload, :peer_data, %{address: ip, port: 1, ssl_cert: nil})},
        remote_ip: ip
    }
  end

  defp login(conn, user) do
    token = Auth.generate_user_session_token(user)

    conn
    |> with_peer()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  defp subscription do
    {pub, _priv} = :crypto.generate_key(:ecdh, :prime256v1)
    b64 = &Base.url_encode64(&1, padding: false)

    %{
      "endpoint" => "https://fcm.googleapis.com/fcm/send/#{b64.(:crypto.strong_rand_bytes(12))}",
      "keys" => %{"p256dh" => b64.(pub), "auth" => b64.(:crypto.strong_rand_bytes(16))}
    }
  end

  defp handle(user_uuid, link \\ "/admin/projects", summary? \\ false) do
    Push.open_url(user_uuid, link, summary?)
    |> String.split("/notifications/open/")
    |> List.last()
  end

  defp open_path(handle), do: Routes.path("/notifications/open/" <> handle)

  describe "the service worker and the manifest" do
    test "the worker carries the site's public key and is never cached", %{conn: conn} do
      conn = get(conn, Routes.path("/push/sw.js"))
      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert conn.resp_body =~ "self.PK_PUSH = "
      assert conn.resp_body =~ Push.WebPush.public_key_b64()
      assert conn.resp_body =~ "addEventListener(\"push\""
      assert conn.resp_body =~ "lastIndexOf(\"/push/\")"
    end

    test "the manifest names the site; the install page links it", %{conn: conn} do
      manifest = conn |> get(Routes.path("/push/manifest.webmanifest")) |> json_response(200)
      assert manifest["display"] == "standalone"

      assert manifest["start_url"] ==
               Routes.path("/profile/settings/notifications", locale: :none)

      assert manifest["scope"] == Routes.path("/", locale: :none)
      assert String.starts_with?(manifest["id"], String.trim_trailing(manifest["scope"], "/"))

      page = build_conn() |> get(Routes.path("/push/install")) |> html_response(200)
      assert page =~ ~s(rel="manifest")
      assert page =~ "Add to Home Screen"
    end

    test "a rotated subscription needs the old one's secret", %{conn: conn} do
      user = user!()
      old = subscription()
      {:ok, _} = Push.subscribe(user, old, impersonated: false)
      new = subscription()

      bad =
        post(conn, Routes.path("/push/resubscribe"), %{
          "old_endpoint" => old["endpoint"],
          "old_auth" => "nope",
          "subscription" => new
        })

      assert bad.status == 404

      good =
        post(build_conn(), Routes.path("/push/resubscribe"), %{
          "old_endpoint" => old["endpoint"],
          "old_auth" => old["keys"]["auth"],
          "subscription" => new
        })

      assert good.status == 204
      assert Push.installation_for(new["endpoint"])
    end
  end

  describe "where a click lands" do
    test "the account in use goes straight to the notification", %{conn: conn} do
      user = user!()
      conn = conn |> login(user) |> get(open_path(handle(user.uuid, "/admin/projects?x=1")))
      assert redirected_to(conn) == "/admin/projects?x=1"
    end

    test "anyone else gets one page that names no one", %{conn: conn} do
      owner = user!()
      stranger = user!()

      for conn <- [conn, login(build_conn(), stranger)] do
        page = conn |> get(open_path(handle(owner.uuid))) |> html_response(200)
        assert page =~ "can&#39;t be opened here"
        refute page =~ owner.email
      end

      forged = conn |> get(open_path("not-a-handle")) |> html_response(200)
      assert forged =~ "can&#39;t be opened here"
    end

    test "an account this browser may switch to: ask, then switch and open", %{conn: conn} do
      Settings.update_boolean_setting("multi_session_enabled", true)
      on_exit(fn -> Settings.update_boolean_setting("multi_session_enabled", false) end)

      owner = user!()
      anna = user!()
      conn = login(conn, owner)
      {:ok, conn} = MultiSession.add_account(conn, anna.email, "ValidPassword123!")
      assert Auth.get_user_by_session_token(get_session(conn)["user_token"]).uuid == anna.uuid

      h = handle(owner.uuid, "/admin/projects?for=owner")
      page = conn |> get(open_path(h)) |> html_response(200)
      assert page =~ "This notification is for another account"
      assert page =~ owner.email
      assert page =~ "Switch and open"
      assert page =~ ~s(href="#{Routes.path("/")}")

      switched = post(conn, open_path(h))
      assert redirected_to(switched) == "/admin/projects?for=owner"

      assert Auth.get_user_by_session_token(get_session(switched)["user_token"]).uuid ==
               owner.uuid
    end

    test "without switching on, the other account is not offered", %{conn: conn} do
      Settings.update_boolean_setting("multi_session_enabled", true)
      owner = user!()
      anna = user!()
      conn = login(conn, owner)
      {:ok, conn} = MultiSession.add_account(conn, anna.email, "ValidPassword123!")
      Settings.update_boolean_setting("multi_session_enabled", false)

      page = conn |> get(open_path(handle(owner.uuid))) |> html_response(200)
      refute page =~ owner.email
      assert page =~ "can&#39;t be opened here"
    end
  end

  describe "the Browser card" do
    test "turning push on in this browser lists the device; removing it drops it", %{conn: conn} do
      user = user!()

      {:ok, view, _html} =
        conn |> login(user) |> live(Routes.path("/profile/settings/notifications"))

      assert has_element?(view, "#push-notifications-card[phx-hook=PkPush]")

      view
      |> with_target("#push-notifications-card")
      |> render_hook("push_state", %{"state" => "default"})

      assert has_element?(view, "#push-notifications-card [data-push-enable]")

      sub = subscription()
      other = user!()
      {:ok, _} = Push.subscribe(other, sub, impersonated: false)

      view
      |> with_target("#push-notifications-card")
      |> render_hook("push_subscribe", %{
        "subscription" => sub,
        "browser_id" => "browser-id-0123456789",
        "label" => "Chrome on Mac"
      })

      assert has_element?(view, "#push-notifications-card", "Chrome on Mac")
      assert has_element?(view, "#push-notifications-card", "This device")
      assert [%{uuid: uuid}] = Push.devices(user.uuid)
      type = Types.shown() |> hd()

      view
      |> form("#push-notifications-card-types", %{"types" => %{type.key => "true"}})
      |> render_submit()

      config =
        ChannelConfig.for_channel(Auth.get_user(user.uuid), "push")

      assert config["types"][type.key]

      view
      |> element("#push-notifications-card button[phx-value-uuid='#{uuid}']")
      |> render_click()

      assert Push.devices(user.uuid) == []
      assert [%{uuid: ^uuid}] = Push.devices(other.uuid)
      refute_push_event(view, "pk-push-unsubscribe", _)
    end

    test "forged events: another account's device stays; a service user is refused", %{
      conn: conn
    } do
      owner = user!()
      {:ok, other} = Push.subscribe(owner, subscription(), impersonated: false)
      user = user!()

      {:ok, view, _html} =
        conn |> login(user) |> live(Routes.path("/profile/settings/notifications"))

      view
      |> with_target("#push-notifications-card")
      |> render_hook("push_remove", %{"uuid" => other.uuid})

      assert [_] = Push.devices(owner.uuid)

      service = %{user!() | api_only: true}
      assert {:error, :not_allowed} = Push.subscribe(service, subscription(), impersonated: false)
    end
  end
end
