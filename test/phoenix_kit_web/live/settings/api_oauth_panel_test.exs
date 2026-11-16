defmodule PhoenixKitWeb.Live.Settings.ApiOauthPanelTest do
  @moduledoc """
  The "Sign-in (OAuth)" tab of Settings -> API: the two switches, the status and addresses, the
  settings form, the clients added by hand and removed, the connections of everyone for an Owner,
  forged input for every event, and the `api` right lost in the middle of the session.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import PhoenixKit.API.OAuthTestSupport

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.API.OAuthConfig
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api?tab=oauth")
  @panel "#api-oauth"

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()

    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")
    for key <- ["api", "media"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp switch(setting, on?),
    do: KeyTestSupport.write_setting(fn -> Settings.update_boolean_setting(setting, on?) end)

  defp fire(view, event, params \\ %{}),
    do: view |> with_target(@panel) |> render_hook(event, params)

  defp drop_api_silently! do
    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  defp changed_settings(admin) do
    Activity.list(action: "setting.changed", actor_uuid: admin.uuid).entries
    |> Enum.map(& &1.metadata["key"])
    |> Enum.sort()
  end

  defp settings_form(view, overrides) do
    params = Map.merge(OAuthConfig.current(), overrides)
    view |> form("#api-oauth-settings-form", %{"oauth" => params}) |> render_submit()
  end

  defp client_form(view, params) do
    view |> form("#api-oauth-client-form", %{"client" => params}) |> render_submit()
  end

  describe "the tab" do
    test "opens on ?tab=oauth with the switches, the status, the form and the clients", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @path)

      for id <-
            ~w(api-oauth-switches api-oauth-status api-oauth-settings-card api-oauth-clients-card) do
        assert has_element?(view, "##{id}")
      end

      refute has_element?(view, "#api-tab-oauth.hidden")
      assert has_element?(view, "#api-tab-access.hidden")
    end

    test "the panel is not mounted while another tab is open", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/api"))
      refute has_element?(view, "#api-oauth")
    end

    test "names the addresses a client fetches, the warning of the admin API, and DCR off", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-oauth-warning-admin_api_off")

      for id <- ~w(resource protected_resource_metadata authorization_server_metadata
                   authorization token revocation registration) do
        assert has_element?(view, "#api-oauth-url-#{id}")
      end

      assert render(element(view, "#api-oauth-url-token")) =~ "/oauth/token"
    end

    test "the warnings follow the switches", %{conn: conn} do
      switch("api_admin_enabled", true)
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#api-oauth-warning-admin_api_off")
    end
  end

  describe "the switches" do
    test "OAuth cannot be switched on while the admin API is off", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)

      assert fire(view, "set_oauth", %{"state" => "on"}) =~ "Switch the admin API on first."
      refute Config.oauth_enabled?()
      refute "api_oauth_enabled" in changed_settings(admin)
    end

    test "switches OAuth on and off, each a setting.changed entry by this admin", %{
      conn: conn,
      admin: admin
    } do
      switch("api_admin_enabled", true)
      {:ok, view, _html} = live(conn, @path)

      view |> element("#api-oauth-switch") |> render_click()
      assert Config.oauth_enabled?()
      assert "api_oauth_enabled" in changed_settings(admin)
      assert has_element?(view, "#api-oauth-switch[checked]")

      view |> element("#api-oauth-switch") |> render_click()
      refute Config.oauth_enabled?()
      refute has_element?(view, "#api-oauth-switch[checked]")
    end

    test "Dynamic Client Registration needs OAuth first", %{conn: conn} do
      switch("api_admin_enabled", true)
      {:ok, view, _html} = live(conn, @path)

      assert fire(view, "set_dcr", %{"state" => "on"}) =~ "Switch OAuth on first."
      refute Settings.get_boolean_setting("api_oauth_dcr_enabled", false)

      fire(view, "set_oauth", %{"state" => "on"})
      fire(view, "set_dcr", %{"state" => "on"})
      assert Config.oauth_dcr_enabled?()

      fire(view, "set_dcr", %{"state" => "off"})
      refute Config.oauth_dcr_enabled?()
    end

    test "a state that is neither on nor off is not an action", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert fire(view, "set_oauth", %{"state" => "maybe"}) =~ "That action is not available."
      assert fire(view, "set_dcr", %{}) =~ "That action is not available."
    end
  end

  describe "the settings form" do
    test "saves what changed, each with this admin as the actor", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)

      html =
        settings_form(view, %{
          "access_ttl_seconds" => "1800",
          "client_policy" => "allow_list",
          "allow_hosts" => "claude.ai\nchatgpt.com"
        })

      assert html =~ "The settings were saved."
      assert Config.oauth_access_ttl_seconds() == 1800
      assert Config.oauth_client_policy() == :allow_list
      assert {:ok, ["claude.ai", "chatgpt.com"]} = Config.fetch_oauth_allow_hosts()

      assert changed_settings(admin) ==
               Enum.sort([
                 "api_oauth_access_ttl_seconds",
                 "api_oauth_client_allow_hosts",
                 "api_oauth_client_policy"
               ])
    end

    test "a value outside its ceiling saves nothing and says so", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, @path)

      html = settings_form(view, %{"access_ttl_seconds" => "90000", "grants_per_person" => "7"})

      assert html =~ "whole number inside its range"
      assert has_element?(view, "#api-oauth-settings-errors")
      assert Config.oauth_access_ttl_seconds() == 3600
      assert Config.oauth_grants_per_person() == 10
      assert changed_settings(admin) == []
    end

    test "forged params: fields the form never offers are ignored, wrong types read as empty", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, @path)

      html =
        fire(view, "save_settings", %{
          "oauth" =>
            Map.merge(OAuthConfig.current(), %{
              "api_oauth_enabled" => "true",
              "access_ttl_seconds" => %{"x" => "1"},
              "token_per_min" => ["5"]
            })
        })

      assert html =~ "whole number inside its range"
      refute Config.oauth_enabled?()
      assert changed_settings(admin) == []
    end

    test "hosts that are not plain host names are refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert settings_form(view, %{"allow_hosts" => "https://claude.ai/x"}) =~ "plain host names"
      assert {:ok, []} = Config.fetch_oauth_allow_hosts()
    end
  end

  describe "adding a client by hand" do
    test "adds it, writes oauth.client_registered by this admin and clears the form", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, @path)

      html =
        client_form(view, %{
          "client_id" => "my-assistant",
          "client_name" => "My assistant",
          "redirect_uris" => "https://assistant.example/callback"
        })

      assert html =~ "The client was added."

      assert %Client{kind: "preregistered", client_name: "My assistant"} =
               Repo.get_by(Client, client_id: "my-assistant")

      assert has_element?(view, "#api-oauth-clients-table", "my-assistant")

      assert %{entries: [entry | _]} =
               Activity.list(action: "oauth.client_registered", actor_uuid: admin.uuid)

      assert entry.metadata["kind"] == "preregistered"
    end

    test "a taken client ID and a bad redirect address are explained", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      taken = client!()

      html =
        client_form(view, %{
          "client_id" => taken.client_id,
          "client_name" => "",
          "redirect_uris" => "https://assistant.example/callback"
        })

      assert html =~ "already registered"

      html =
        client_form(view, %{
          "client_id" => "other",
          "client_name" => "",
          "redirect_uris" => "cursor://callback"
        })

      assert html =~ "must be https"
      assert Repo.get_by(Client, client_id: "other") == nil
    end

    test "no redirect address, or more than ten, is refused before the database", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert client_form(view, %{"client_id" => "a", "client_name" => "", "redirect_uris" => ""}) =~
               "from 1 to 10"

      many = Enum.map_join(1..11, "\n", &"https://c#{&1}.example/cb")

      assert client_form(view, %{"client_id" => "b", "client_name" => "", "redirect_uris" => many}) =~
               "from 1 to 10"

      assert Repo.get_by(Client, client_id: "b") == nil
    end

    test "a client ID with a NUL byte is a form error, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      html =
        fire(view, "add_client", %{
          "client" => %{
            "client_id" => "a\0b",
            "client_name" => "x\0",
            "redirect_uris" => "https://assistant.example/cb"
          }
        })

      assert html =~ "client ID is required"
    end
  end

  describe "removing a client" do
    setup %{conn: conn} do
      {user, _role, scope} = oauth_holder(["media"])
      client = client!(%{client_name: "Doomed"})
      seeded = seed_grant!(scope, client: client)
      {:ok, view, _html} = live(conn, @path)
      %{view: view, client: client, seeded: seeded, user: user}
    end

    test "asks first, then ends every connection of the client and removes it", ctx do
      ctx.view |> element("#api-oauth-client-remove-#{ctx.client.uuid}") |> render_click()
      assert has_element?(ctx.view, "#api-oauth-client-delete-confirm")
      assert Repo.get(Client, ctx.client.uuid)

      ctx.view |> element("#api-oauth-client-delete-confirm") |> render_click()

      assert Repo.get(Client, ctx.client.uuid) == nil
      assert Repo.get(Grant, ctx.seeded.grant.uuid) == nil
      assert %DateTime{} = Repo.get!(Key, ctx.seeded.key.uuid).revoked_at
      assert {:error, _} = Tokens.verify(ctx.seeded.access, "203.0.113.9")
    end

    test "the confirming event takes no uuid from its params", ctx do
      other = client!()
      ctx.view |> element("#api-oauth-client-remove-#{ctx.client.uuid}") |> render_click()
      fire(ctx.view, "confirm_delete_client", %{"uuid" => other.uuid})

      assert Repo.get(Client, ctx.client.uuid) == nil
      assert Repo.get(Client, other.uuid)
    end

    test "cancelling removes nothing, and a forged or unknown uuid is not found", ctx do
      ctx.view |> element("#api-oauth-client-remove-#{ctx.client.uuid}") |> render_click()
      fire(ctx.view, "cancel_delete_client")
      fire(ctx.view, "confirm_delete_client")
      assert Repo.get(Client, ctx.client.uuid)

      assert fire(ctx.view, "request_delete_client", %{"uuid" => "nope"}) =~
               "That client was not found."

      refute has_element?(ctx.view, "#api-oauth-client-delete-confirm")
    end
  end

  describe "a right lost in the middle of the session" do
    test "every event is refused and writes nothing", %{conn: conn, admin: admin} do
      switch("api_admin_enabled", true)
      client = client!()
      {:ok, view, _html} = live(conn, @path)
      drop_api_silently!()

      events = [
        {"set_oauth", %{"state" => "on"}},
        {"set_dcr", %{"state" => "on"}},
        {"save_settings", %{"oauth" => Map.put(OAuthConfig.current(), "token_per_min", "5")}},
        {"add_client",
         %{
           "client" => %{
             "client_id" => "late",
             "client_name" => "",
             "redirect_uris" => "https://late.example/cb"
           }
         }},
        {"request_delete_client", %{"uuid" => client.uuid}},
        {"confirm_delete_client", %{}}
      ]

      for {event, params} <- events do
        assert fire(view, event, params) =~ "You are not allowed to do that.", event
      end

      refute Config.oauth_enabled?()
      assert Config.oauth_token_per_min() == 60
      assert Repo.get_by(Client, client_id: "late") == nil
      assert Repo.get(Client, client.uuid)
      assert changed_settings(admin) == []
    end
  end

  describe "every connection, for an Owner" do
    setup do
      {user, role, scope} = oauth_holder(["media"])
      %{holder: user, holder_role: role, holder_scope: scope}
    end

    test "an Owner sees everyone's connections and ends one", %{conn: _conn, holder_scope: scope} do
      seeded = seed_grant!(scope)
      conn = log_in_user(Phoenix.ConnTest.build_conn(), KeyTestSupport.owner_user())
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-oauth-connected-apps-grant-#{seeded.grant.uuid}")

      view |> element("#api-oauth-connected-apps-revoke-#{seeded.grant.uuid}") |> render_click()
      view |> element("#api-oauth-connected-apps-revoke-confirm") |> render_click()

      assert %DateTime{} = Repo.get!(Grant, seeded.grant.uuid).revoked_at
    end

    test "a connection whose owner lost the right is listed as not working", ctx do
      seed_grant!(ctx.holder_scope)

      {1, _} =
        Repo.delete_all(
          from(rp in RolePermission,
            where: rp.role_uuid == ^ctx.holder_role.uuid and rp.module_key == "api_personal_keys"
          )
        )

      conn = log_in_user(Phoenix.ConnTest.build_conn(), KeyTestSupport.owner_user())
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "[id^=api-oauth-connected-apps-no-permission-]")
    end

    test "an Admin who holds api but is not an Owner does not see the list of everyone", %{
      conn: conn,
      holder_scope: scope
    } do
      seeded = seed_grant!(scope)
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#api-oauth-connected-apps")
      refute has_element?(view, "#api-oauth-connected-apps-grant-#{seeded.grant.uuid}")
    end
  end
end
