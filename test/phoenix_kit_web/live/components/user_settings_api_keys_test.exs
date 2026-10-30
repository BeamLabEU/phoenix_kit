defmodule PhoenixKitWeb.Live.Components.UserSettingsApiKeysTest do
  @moduledoc """
  The opt-in `:api_keys` section of `UserSettings`: the same component as the profile page,
  with the session's context handed in by the host. Without it the section only explains;
  with a borrowed session, a lost right or a forged uuid every event is refused.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKitWeb.Live.Components.UserSettings
  alias PhoenixKitWeb.Test.UserSettingsApiKeysHostLive, as: Host

  @right "api_personal_keys"
  @read KeyTestSupport.read_scope()
  @component "#user-settings-api-keys"

  setup do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()
    KeyTestSupport.put_setting("api_admin_enabled", "true")

    {user, role} = KeyTestSupport.user_without_api([@right, "media"])
    scope = KeyTestSupport.scope_of(user)

    {:ok, key, _token} =
      Keys.create_personal_key(
        scope,
        %{
          name: "Mine",
          scopes: [@read],
          expires_at: DateTime.new!(Date.add(Date.utc_today(), 30), ~T[23:59:59], "Etc/UTC")
        },
        impersonated: false
      )

    %{user: user, role: role, key: key}
  end

  defp host(conn, user, session \\ %{}) do
    live_isolated(conn, Host, session: Map.put(session, "user_uuid", user.uuid))
  end

  defp fire(view, event, params),
    do: view |> with_target(@component) |> render_hook(event, params)

  # Every event that opens a dialog or changes something, with the params a real page sends.
  defp changing_events(key) do
    [
      {"open_create", %{}},
      {"create_key",
       %{"key" => %{"name" => "Late", "scopes" => [], "expires_on" => "2999-01-01"}}},
      {"request_revoke", %{"uuid" => key.uuid}},
      {"confirm_revoke", %{}},
      {"request_rotate", %{"uuid" => key.uuid}},
      {"confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}}},
      {"request_edit_scopes", %{"uuid" => key.uuid}},
      {"save_key_scopes", %{"key_scopes" => %{"present" => "1", "scopes" => []}}}
    ]
  end

  defp keys_of(user), do: Repo.all(from(k in Key, where: k.user_uuid == ^user.uuid))

  test ":api_keys is opt-in, never in the default sections" do
    refute :api_keys in UserSettings.default_sections()
  end

  describe "without the session's context" do
    test "scope and impersonated both missing: only the explanation, no list", %{
      conn: conn,
      user: user,
      key: key
    } do
      {:ok, view, html} = host(conn, user)

      assert html =~ "added without the session&#39;s context"
      refute has_element?(view, "#user-settings-api-keys-table")
      refute html =~ key.name
      refute has_element?(view, "#user-settings-api-keys-new-key")
    end

    test "scope given, impersonated missing", %{conn: conn, user: user, key: key} do
      {:ok, view, html} = host(conn, user, %{"impersonated" => nil})

      assert html =~ "added without the session&#39;s context"
      refute has_element?(view, "#user-settings-api-keys-key-#{key.uuid}")
    end

    test "impersonated given, scope missing", %{conn: conn, user: user, key: key} do
      {:ok, view, html} = host(conn, user, %{"scope" => false, "impersonated" => false})

      assert html =~ "added without the session&#39;s context"
      refute has_element?(view, "#user-settings-api-keys-key-#{key.uuid}")
    end

    test "every event is refused", %{conn: conn, user: user, key: key} do
      {:ok, view, _html} = host(conn, user)

      for {event, params} <- [
            {"open_create", %{}},
            {"create_key", %{"key" => %{"name" => "x", "scopes" => [], "expires_on" => ""}}},
            {"request_revoke", %{"uuid" => key.uuid}},
            {"confirm_revoke", %{}},
            {"request_rotate", %{"uuid" => key.uuid}},
            {"confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}}},
            {"request_edit_scopes", %{"uuid" => key.uuid}},
            {"save_key_scopes", %{"key_scopes" => %{"present" => "1", "scopes" => []}}}
          ] do
        assert fire(view, event, params) =~ "You are not allowed to do that.", event
      end

      assert [only] = keys_of(user)
      assert only.revoked_at == nil
    end
  end

  describe "with the context" do
    test "an explicit nil scope clears the previously supplied context", %{
      conn: conn,
      user: user,
      key: key
    } do
      {:ok, view, _html} = host(conn, user, %{"impersonated" => false})
      assert has_element?(view, "#user-settings-api-keys-key-#{key.uuid}")

      render_click(view, "clear_scope", %{})

      refute has_element?(view, "#user-settings-api-keys-table")
      assert render(view) =~ "added without the session&#39;s context"
      assert fire(view, "open_create", %{}) =~ "You are not allowed to do that."
      assert [only] = keys_of(user)
      assert only.revoked_at == nil
    end

    test "lists the keys and creates one", %{conn: conn, user: user, key: key} do
      {:ok, view, _html} = host(conn, user, %{"impersonated" => false})
      assert has_element?(view, "#user-settings-api-keys-key-#{key.uuid}", "Mine")

      view |> element("#user-settings-api-keys-new-key") |> render_click()

      html =
        fire(view, "create_key", %{
          "key" => %{
            "name" => "From the section",
            "scopes" => [@read],
            "allowed_ips" => "",
            "expires_on" => Date.to_iso8601(Date.add(Date.utc_today(), 10))
          }
        })

      assert html =~ "Copy your new key now"
      assert length(keys_of(user)) == 2
    end

    test "a scope of someone else is handed on as absent", %{conn: conn, user: user, key: key} do
      {stranger, _} = KeyTestSupport.user_without_api([@right, "media"])

      {:ok, view, html} =
        live_isolated(conn, Host,
          session: %{
            "user_uuid" => user.uuid,
            "impersonated" => false,
            "scope_of" => stranger.uuid
          }
        )

      assert html =~ "added without the session&#39;s context"
      refute has_element?(view, "#user-settings-api-keys-key-#{key.uuid}")
      refute has_element?(view, "#user-settings-api-keys-new-key")
    end

    test "a borrowed session lists and refuses every event", %{conn: conn, user: user, key: key} do
      {:ok, view, html} = host(conn, user, %{"impersonated" => true})

      assert html =~ "You are acting in another account"
      assert has_element?(view, "#user-settings-api-keys-key-#{key.uuid}")
      refute has_element?(view, "#user-settings-api-keys-new-key")

      for {event, params} <- changing_events(key) do
        assert fire(view, event, params) =~ "cannot be changed while you act in another account",
               event
      end

      assert [only] = keys_of(user)
      assert only.revoked_at == nil
    end

    test "a right lost silently: nothing changes", %{conn: conn, user: user, role: role, key: key} do
      {:ok, view, _html} = host(conn, user, %{"impersonated" => false})
      view |> element("#user-settings-api-keys-new-key") |> render_click()

      {1, _} =
        Repo.delete_all(
          from(rp in RolePermission,
            where: rp.role_uuid == ^role.uuid and rp.module_key == @right
          )
        )

      for {event, params} <- changing_events(key) do
        assert fire(view, event, params) =~ "You are not allowed to do that.", event
      end

      assert [only] = keys_of(user)
      assert only.revoked_at == nil
    end

    test "the API switch is read again for each event, not taken from the last render", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = host(conn, user, %{"impersonated" => false})
      view |> element("#user-settings-api-keys-new-key") |> render_click()
      KeyTestSupport.put_setting("api_admin_enabled", "false")

      html =
        fire(view, "create_key", %{
          "key" => %{
            "name" => "Too late",
            "scopes" => [@read],
            "allowed_ips" => "",
            "expires_on" => Date.to_iso8601(Date.add(Date.utc_today(), 10))
          }
        })

      assert html =~ "That action is not available."
      assert length(keys_of(user)) == 1
    end

    test "a forged uuid of another person's key finds nothing", %{conn: conn, user: user} do
      {stranger, _} = KeyTestSupport.user_without_api([@right, "media"])

      {:ok, theirs, _} =
        Keys.create_personal_key(
          KeyTestSupport.scope_of(stranger),
          %{
            name: "Theirs",
            scopes: [@read],
            expires_at: DateTime.new!(Date.add(Date.utc_today(), 30), ~T[23:59:59], "Etc/UTC")
          },
          impersonated: false
        )

      {:ok, view, _html} = host(conn, user, %{"impersonated" => false})

      for event <- ["request_revoke", "request_rotate", "request_edit_scopes"] do
        assert fire(view, event, %{"uuid" => theirs.uuid}) =~ "That key was not found."
      end

      fire(view, "confirm_revoke", %{"uuid" => theirs.uuid})
      assert Keys.get_key(theirs.uuid).revoked_at == nil
    end
  end
end
