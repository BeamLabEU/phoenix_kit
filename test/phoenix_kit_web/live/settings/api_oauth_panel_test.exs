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
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.API.OAuthConfig
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth, as: AuthCtx
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

  defp row_ids(html), do: Regex.scan(~r/id="(api-oauth-(?:switch|dcr)-row-\d+)"/, html)

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

      assert Enum.count(changed_settings(admin), &(&1 == "api_oauth_enabled")) == 2
    end

    test "the label follows the stored switch, not the effective state", %{conn: conn} do
      # The admin API is off, so OAuth is stored on but does not work: the effective state
      # (Status.oauth_enabled) says off, the stored switch says on.
      switch("api_oauth_enabled", true)
      refute Config.oauth_enabled?()

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-oauth-switch[checked]")
      assert has_element?(view, "#api-oauth-switch-row-0", "Enabled")
      refute has_element?(view, "#api-oauth-switch-row-0", "Disabled")
    end

    test "a refused click makes the browser draw the stored state again", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      before = view |> element("#api-oauth-switches") |> render() |> row_ids()

      assert fire(view, "set_oauth", %{"state" => "on"}) =~ "Switch the admin API on first."

      refute view |> element("#api-oauth-switches") |> render() |> row_ids() == before
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

    test "an error after a save does not leave the green banner behind", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert settings_form(view, %{"access_ttl_seconds" => "1800"}) =~ "The settings were saved."
      assert has_element?(view, "#api-oauth-message")

      settings_form(view, %{"access_ttl_seconds" => "90000"})
      assert has_element?(view, "#api-oauth-settings-errors")
      refute has_element?(view, "#api-oauth-message")
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
      taken = client!(%{client_id: "taken-by-hand"})

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

    test "an error after an addition does not leave the green banner behind", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert client_form(view, %{
               "client_id" => "fine",
               "client_name" => "",
               "redirect_uris" => "https://assistant.example/cb"
             }) =~ "The client was added."

      client_form(view, %{"client_id" => "bad", "client_name" => "", "redirect_uris" => ""})
      assert has_element?(view, "#api-oauth-client-errors")
      refute has_element?(view, "#api-oauth-message")
    end

    test "a localhost redirect is accepted, and the guidance says so", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)
      assert html =~ "http to localhost, 127.0.0.1 or [::1]"

      client_form(view, %{
        "client_id" => "local-tool",
        "client_name" => "",
        "redirect_uris" => "http://localhost:8123/cb"
      })

      assert %Client{redirect_uris: ["http://localhost:8123/cb"]} =
               Repo.get_by(Client, client_id: "local-tool")

      assert client_form(view, %{
               "client_id" => "ftp-tool",
               "client_name" => "",
               "redirect_uris" => "ftp://elsewhere.example/cb"
             }) =~ "http to localhost, 127.0.0.1 or [::1]"
    end

    test "the address of a metadata document is not accepted as a client ID", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      url = "https://claude.ai/oauth/mcp-oauth-client-metadata"

      html =
        client_form(view, %{
          "client_id" => url,
          "client_name" => "Claude",
          "redirect_uris" => "https://elsewhere.example/cb"
        })

      assert html =~ "names itself by a metadata document"
      assert has_element?(view, "#api-oauth-client-errors")
      assert Repo.get_by(Client, client_id: url) == nil
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

  describe "a long list of clients" do
    test "says that only the newest are shown", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#api-oauth-clients-truncated")

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rows =
        for n <- 1..Clients.list_limit() do
          %{
            uuid: UUIDv7.generate(),
            client_id: "https://bulk.example/#{n}",
            kind: "preregistered",
            redirect_uris: [],
            inserted_at: now,
            updated_at: now
          }
        end

      {_count, _} = Repo.insert_all(Client, rows)
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#api-oauth-clients-truncated")
    end
  end

  describe "the allowed hosts hint" do
    test "says that an issued access token outlives its host's removal, and what to do", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @path)

      hint = view |> element("#api-oauth-settings-card") |> render()
      assert hint =~ "access token already issued works until it expires"
      assert hint =~ "remove it below"
    end
  end

  describe "removing a client, as an Owner" do
    setup do
      {user, _role, scope} = oauth_holder(["media"])
      client = client!(%{client_name: "Doomed"})
      seeded = seed_grant!(scope, client: client)
      owner = KeyTestSupport.owner_user()
      conn = log_in_user(Phoenix.ConnTest.build_conn(), owner)
      {:ok, view, _html} = live(conn, @path)
      %{view: view, client: client, seeded: seeded, user: user, owner: owner}
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

      assert [entry] =
               Activity.list(action: "oauth.client_removed", actor_uuid: ctx.owner.uuid).entries

      assert entry.resource_uuid == ctx.client.uuid
      assert entry.metadata["connections_ended"] == 1
    end

    test "the list of every connection on the same tab drops the removed client's connections",
         ctx do
      row = "#api-oauth-connected-apps-grant-#{ctx.seeded.grant.uuid}"
      assert has_element?(ctx.view, row)

      ctx.view |> element("#api-oauth-client-remove-#{ctx.client.uuid}") |> render_click()
      ctx.view |> element("#api-oauth-client-delete-confirm") |> render_click()

      refute has_element?(ctx.view, "#api-oauth-client-#{ctx.client.uuid}")
      refute has_element?(ctx.view, row)
    end

    test "ending a connection in the list of everyone updates the count of its client", ctx do
      count = "#api-oauth-client-grants-#{ctx.client.uuid}"
      assert has_element?(ctx.view, count, "1")

      ctx.view
      |> element("#api-oauth-connected-apps-revoke-#{ctx.seeded.grant.uuid}")
      |> render_click()

      ctx.view |> element("#api-oauth-connected-apps-revoke-confirm") |> render_click()

      assert has_element?(ctx.view, count, "0")
      assert has_element?(ctx.view, "#api-oauth-client-remove-#{ctx.client.uuid}")
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

    test "a confirm with no dialog open is ignored, with no message", ctx do
      fire(ctx.view, "confirm_delete_client")
      refute has_element?(ctx.view, "#api-oauth-message")
      assert Repo.get(Client, ctx.client.uuid)
    end

    test "a person demoted from Owner to Admin before confirming ends nobody's connection",
         ctx do
      ctx.view |> element("#api-oauth-client-remove-#{ctx.client.uuid}") |> render_click()
      {:ok, _} = Roles.remove_role(ctx.owner, "Owner", broadcast: false)
      {:ok, _} = Roles.assign_role(ctx.owner, "Admin", nil, broadcast: false)

      assert fire(ctx.view, "confirm_delete_client") =~
               "Only an Owner can remove an application that has connections."

      assert Repo.get(Client, ctx.client.uuid)
      assert Repo.get!(Key, ctx.seeded.key.uuid).revoked_at == nil
    end
  end

  describe "removing a client, as an Admin who is not an Owner" do
    setup %{conn: conn} do
      {_user, _role, scope} = oauth_holder(["media"])
      busy = client!(%{client_name: "Busy"})
      idle = client!(%{client_name: "Idle"})
      seeded = seed_grant!(scope, client: busy)
      {:ok, view, _html} = live(conn, @path)
      %{view: view, busy: busy, idle: idle, seeded: seeded}
    end

    test "has no Remove button for a client somebody is connected through", ctx do
      refute has_element?(ctx.view, "#api-oauth-client-remove-#{ctx.busy.uuid}")
      assert has_element?(ctx.view, "#api-oauth-client-owner-only-#{ctx.busy.uuid}")
      assert has_element?(ctx.view, "#api-oauth-client-remove-#{ctx.idle.uuid}")
    end

    test "a forged request for that client is refused and opens no dialog", ctx do
      html = fire(ctx.view, "request_delete_client", %{"uuid" => ctx.busy.uuid})

      assert html =~ "Only an Owner can remove an application that has connections."
      refute has_element?(ctx.view, "#api-oauth-client-delete-confirm")
      assert Repo.get(Client, ctx.busy.uuid)
    end

    test "a forged confirm cannot end another person's connection", ctx do
      fire(ctx.view, "request_delete_client", %{"uuid" => ctx.busy.uuid})
      fire(ctx.view, "confirm_delete_client")

      assert Repo.get(Client, ctx.busy.uuid)
      assert Repo.get(Grant, ctx.seeded.grant.uuid)
      assert Repo.get!(Key, ctx.seeded.key.uuid).revoked_at == nil
      assert {:ok, _} = Tokens.verify(ctx.seeded.access, "203.0.113.9")
    end

    test "a connection made after the dialog opened is not ended by the confirm", ctx do
      ctx.view |> element("#api-oauth-client-remove-#{ctx.idle.uuid}") |> render_click()
      {_user, _role, scope} = oauth_holder(["media"])
      late = seed_grant!(scope, client: ctx.idle)

      html = ctx.view |> element("#api-oauth-client-delete-confirm") |> render_click()

      assert html =~ "Only an Owner can remove an application that has connections."
      assert Repo.get(Client, ctx.idle.uuid)
      assert Repo.get!(Key, late.key.uuid).revoked_at == nil
    end

    test "removes a client nobody is connected through, and the entry says who", ctx do
      ctx.view |> element("#api-oauth-client-remove-#{ctx.idle.uuid}") |> render_click()
      ctx.view |> element("#api-oauth-client-delete-confirm") |> render_click()

      assert Repo.get(Client, ctx.idle.uuid) == nil
      assert [entry] = Activity.list(action: "oauth.client_removed").entries
      assert entry.resource_uuid == ctx.idle.uuid
      assert entry.metadata["connections_ended"] == 0
    end
  end

  describe "a borrowed session" do
    setup %{conn: conn} do
      {root, _role} = KeyTestSupport.user_without_api(["api"])
      root_token = AuthCtx.generate_user_session_token(root)
      active_token = Plug.Conn.get_session(conn, :user_token)
      borrowed = Plug.Conn.put_session(conn, :pk_session_accounts, [root_token, active_token])
      %{borrowed: borrowed}
    end

    test "says so and refuses every event, writing nothing", %{borrowed: conn, admin: admin} do
      switch("api_admin_enabled", true)
      client = client!()
      {:ok, view, html} = live(conn, @path)

      assert html =~ "Nothing here can be changed while you act in another account."
      assert has_element?(view, "#api-oauth-impersonated")

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
        assert fire(view, event, params) =~ "while you act in another account", event
      end

      refute Config.oauth_enabled?()
      assert Config.oauth_token_per_min() == 60
      assert Repo.get_by(Client, client_id: "late") == nil
      assert Repo.get(Client, client.uuid)
      assert changed_settings(admin) == []
    end

    test "an ordinary session shows no such notice", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      refute has_element?(view, "#api-oauth-impersonated")
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

    test "a connection whose owner is blocked is listed as inactive", ctx do
      seeded = seed_grant!(ctx.holder_scope)
      {:ok, _} = AuthCtx.update_user_status(ctx.holder, %{is_active: false})

      conn = log_in_user(Phoenix.ConnTest.build_conn(), KeyTestSupport.owner_user())
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(
               view,
               "#api-oauth-connected-apps-status-#{seeded.grant.uuid}[data-status=owner_inactive]"
             )

      assert has_element?(
               view,
               "#api-oauth-connected-apps-grant-#{seeded.grant.uuid}",
               "Owner inactive"
             )
    end

    test "an Owner downgraded to Admin during the session ends nobody's connection", ctx do
      seeded = seed_grant!(ctx.holder_scope)
      owner = KeyTestSupport.owner_user()
      conn = log_in_user(Phoenix.ConnTest.build_conn(), owner)
      {:ok, view, _html} = live(conn, @path)

      {:ok, _} = Roles.remove_role(owner, "Owner", broadcast: false)
      {:ok, _} = Roles.assign_role(owner, "Admin", nil, broadcast: false)

      target = with_target(view, "#api-oauth-connected-apps")

      assert render_hook(target, "request_revoke", %{"uuid" => seeded.grant.uuid}) =~
               "not allowed"

      refute has_element?(view, "#api-oauth-connected-apps-revoke-confirm")
      assert render_hook(target, "confirm_revoke", %{}) =~ "not allowed"
      assert Repo.get!(Grant, seeded.grant.uuid).revoked_at == nil
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
