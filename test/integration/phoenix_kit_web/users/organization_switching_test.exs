defmodule PhoenixKitWeb.Users.OrganizationSwitchingTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.ManagedOrganizations.Sessions, as: OrganizationSessions
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Components.Core.OrganizationSwitcher
  alias PhoenixKitWeb.Endpoint
  alias PhoenixKitWeb.Live.Users.ProfileSettings
  alias PhoenixKitWeb.Users.MultiSession

  @remember "_phoenix_kit_web_user_remember_me"
  @mirror "_phoenix_kit_web_session_accounts"

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    Settings.update_setting("multi_session_enabled", "false")
    person = F.person(%{first_name: "Dmitri", last_name: "Don"})
    org = F.organization()
    grant = F.manager(org, person)
    {token, root} = F.session(person)
    conn = init_test_session(build_conn(), %{user_token: token, pk_session_accounts: [token]})
    %{person: person, org: org, grant: grant, token: token, root: root, conn: conn}
  end

  test "entry binds provenance, renews the session and emits activity without a login alert", s do
    assert {:ok, conn, user} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    assert user.acting_user_uuid == s.person.uuid
    assert user.acting_session_uuid == s.root.uuid
    assert user.organization_manager_uuid == s.grant.uuid
    assert conn.private.plug_session_info == :renew
    assert get_session(conn, :pk_organization_token) == get_session(conn, :user_token)
    assert MultiSession.impersonated?(get_session(conn))
    assert [account] = MultiSession.list_accounts(get_session(conn))
    assert account.user.uuid == s.person.uuid

    assert [entry] =
             Activity.list(resource_type: "organization", resource_uuid: s.org.uuid).entries

    assert entry.action == "organization.entered"
    assert entry.actor_uuid == s.org.uuid
    assert entry.target_uuid == nil
    assert entry.metadata["acting_user_uuid"] == s.person.uuid

    refute Repo.exists?(
             from(e in Entry,
               where: e.action == "session.created" and e.actor_uuid == ^s.org.uuid
             )
           )
  end

  test "same-organization entry is a no-op; replacing it revokes and disconnects its old token",
       s do
    {:ok, conn, _} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    old = get_session(conn, :user_token)
    Endpoint.subscribe(Sessions.live_socket_id(old))
    assert {:ok, same, _} = MultiSession.act_as_organization(conn, s.org.uuid)
    assert get_session(same, :user_token) == old

    assert Repo.aggregate(
             from(e in Entry,
               where: e.action == "organization.entered" and e.resource_uuid == ^s.org.uuid
             ),
             :count
           ) == 1

    other = F.organization(%{organization_name: "Beta"})
    F.manager(other, s.person)
    assert {:ok, next, user} = MultiSession.act_as_organization(same, other.uuid)
    assert user.uuid == other.uuid
    assert length(get_session(next, :pk_session_accounts)) == 2
    refute Auth.get_user_by_session_token(old)
    assert_disconnect(old)
  end

  test "entry fits outside a full ordinary stack; adding and impersonation are refused while acting",
       s do
    # Ordinary account addition is a separate feature, enabled just for this setup.
    Settings.update_setting("multi_session_enabled", "true")

    conn =
      Enum.reduce(1..4, s.conn, fn _, conn ->
        {:ok, conn} = MultiSession.add_authenticated_user(conn, F.person())
        conn
      end)

    assert {:ok, conn, _} = MultiSession.act_as_organization(conn, s.org.uuid)
    assert length(get_session(conn, :pk_session_accounts)) == 6
    assert length(MultiSession.list_accounts(get_session(conn))) == 5

    assert {:error, :acting_organization} =
             MultiSession.add_account(conn, "unused@example.com", "bad")

    assert {:error, :acting_organization} = MultiSession.add_authenticated_user(conn, F.person())
    assert {:error, :acting_organization} = MultiSession.impersonate(conn, F.person())
    refute MultiSession.may_impersonate?(get_session(conn))
    refute MultiSession.impersonation_actor(get_session(conn))
  end

  test "OAuth add-account entry refuses before starting a provider flow while acting", s do
    entered = post(s.conn, Routes.path("/users/session/organizations/#{s.org.uuid}"))
    refused = get(entered, Routes.path("/users/auth/google"), %{add_account: "1"})
    assert Phoenix.Flash.get(refused.assigns.flash, :error) =~ "Return to your own account"
    assert get_session(refused, :user_token) == get_session(entered, :user_token)
    refute get_session(refused, :oauth_add_account_intent)
  end

  test "the root decides; an added person or acting organization cannot lend its grant", s do
    other = F.person()
    organization = F.organization()
    F.manager(organization, other)
    {:ok, conn} = MultiSession.add_authenticated_user(s.conn, other)
    assert {:error, :forbidden} = MultiSession.act_as_organization(conn, organization.uuid)
    {:ok, conn, _} = MultiSession.act_as_organization(s.conn, s.org.uuid)

    Repo.insert!(%OrganizationManager{
      organization_uuid: organization.uuid,
      user_uuid: s.org.uuid
    })

    assert {:error, :forbidden} = MultiSession.act_as_organization(conn, organization.uuid)
  end

  test "inactive, independent, unconfirmed-root and invalid targets refuse entry", s do
    for org <- [F.organization(%{is_active: false}), F.organization(%{managed_by_members: false})] do
      assert {:error, :forbidden} = MultiSession.act_as_organization(s.conn, org.uuid)
    end

    assert {:error, :forbidden} = MultiSession.act_as_organization(s.conn, "not-a-uuid")
    s.person |> Ecto.Changeset.change(confirmed_at: nil) |> Repo.update!()
    assert {:error, :forbidden} = MultiSession.act_as_organization(s.conn, s.org.uuid)
  end

  test "entry is rate limited on the root, including refused targets and no-ops", s do
    previous = Application.get_env(:phoenix_kit, PhoenixKit.Users.RateLimiter)
    Application.put_env(:phoenix_kit, PhoenixKit.Users.RateLimiter, organization_enter_limit: 1)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, PhoenixKit.Users.RateLimiter, previous),
        else: Application.delete_env(:phoenix_kit, PhoenixKit.Users.RateLimiter)
    end)

    assert {:error, :forbidden} = MultiSession.act_as_organization(s.conn, UUIDv7.generate())
    assert {:error, :rate_limit_exceeded} = MultiSession.act_as_organization(s.conn, s.org.uuid)
  end

  test "leave still works with the master switch off and ends the organization socket", s do
    {:ok, conn, _} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    org_token = get_session(conn, :user_token)
    Endpoint.subscribe(Sessions.live_socket_id(org_token))
    Settings.update_setting("enable_organization_accounts", "false")
    assert {:error, :forbidden} = MultiSession.act_as_organization(conn, s.org.uuid)
    assert {:ok, conn, user} = MultiSession.leave_organization(conn)
    assert user.uuid == s.person.uuid
    assert get_session(conn, :user_token) == s.token
    refute get_session(conn, :pk_organization_token)
    refute Auth.get_user_by_session_token(org_token)
    assert_disconnect(org_token)
  end

  test "switching to an ordinary account removes the organization instead of parking it", s do
    other = F.person()
    {:ok, conn} = MultiSession.add_authenticated_user(s.conn, other)
    [_, other_token] = get_session(conn, :pk_session_accounts)
    ref = Auth.get_session_token_record(other_token).uuid
    {:ok, conn, _} = MultiSession.act_as_organization(conn, s.org.uuid)
    org_token = get_session(conn, :user_token)
    assert {:ok, conn, user} = MultiSession.switch_to(conn, ref)
    assert user.uuid == other.uuid
    refute get_session(conn, :pk_organization_token)
    refute Auth.get_user_by_session_token(org_token)
    assert get_session(conn, :pk_session_accounts) == [s.token, other_token]
  end

  test "logout helper leaves; the logout controller ends the whole browser session", s do
    {:ok, conn, _} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    assert {:switched, left, user} = MultiSession.log_out_active(conn)
    assert user.uuid == s.person.uuid
    assert get_session(left, :user_token) == s.token
    {:ok, conn, _} = MultiSession.act_as_organization(left, s.org.uuid)
    org_token = get_session(conn, :user_token)
    logged_out = delete(conn, Routes.path("/users/log-out"))
    refute get_session(logged_out, :user_token)
    refute Auth.get_user_by_session_token(s.token)
    refute Auth.get_user_by_session_token(org_token)
  end

  test "both route scopes enter and leave independently of multi-session", s do
    enter_path = Routes.path("/users/session/organizations/#{s.org.uuid}")
    leave_path = Routes.path("/users/session/organization")

    for {method, path, action} <- [
          {"POST", enter_path, :enter_organization},
          {"DELETE", leave_path, :leave_organization}
        ],
        scoped <- [
          path,
          String.replace(path, "/users/session/", "/en/users/session/", global: false)
        ] do
      assert %{plug: PhoenixKitWeb.Users.Session, plug_opts: ^action} =
               Phoenix.Router.route_info(PhoenixKitWeb.Router, method, scoped, "www.example.com")
    end

    for locale <- [nil, "en"] do
      entered =
        post(s.conn, Routes.path("/users/session/organizations/#{s.org.uuid}", locale: locale))

      assert redirected_to(entered) == Routes.post_auth_path()
      assert Auth.get_user_by_session_token(get_session(entered, :user_token)).uuid == s.org.uuid

      left =
        delete(entered, Routes.path("/users/session/organization", locale: locale), %{
          return_to: "//evil.example"
        })

      refute redirected_to(left) =~ "evil.example"
      assert get_session(left, :user_token) == s.token
    end
  end

  test "scope, switcher, activity attribution and the source-browser session list agree", s do
    {:ok, conn, user} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    scope = MultiSession.populate_scope(Scope.for_user(user), get_session(conn))
    assert [%{uuid: uuid}] = scope.acting_organizations
    assert uuid == s.org.uuid
    assert Scope.session_display_name(scope) == "Acme · via Dmitri Don"

    html =
      render_component(&OrganizationSwitcher.organization_switcher/1,
        id: "test-org",
        scope: scope
      )

    assert html =~ "Back to my account"
    assert html =~ s.org.organization_name
    refute html =~ s.org.email

    assert {:ok, entry} =
             Activity.log(
               "users",
               "organization.changed",
               Actor.opts(scope) ++ [metadata: %{"kept" => true}]
             )

    assert entry.actor_uuid == s.org.uuid
    assert entry.metadata == %{"acting_user_uuid" => s.person.uuid, "kept" => true}
    assert Activity.actor_label(Activity.get_entry!(entry.uuid)) == "Acme · via Dmitri Don"
    assert [device] = Sessions.list_user_device_sessions(s.person, s.token)
    assert [%{name: "Acme"}] = device.acting_organizations

    assert Sessions.list_user_sessions(user) |> hd() |> Map.fetch!(:user_email) ==
             s.org.contact_email
  end

  test "an org-only mirror resumes while multi-session is off", s do
    login = remembered_login(s.person)
    entered = post(login, Routes.path("/users/session/organizations/#{s.org.uuid}"))
    org_token = get_session(entered, :user_token)

    recovered =
      restart(%{@remember => cookie(login, @remember), @mirror => cookie(entered, @mirror)})

    assert get_session(recovered, :user_token) == org_token
    assert get_session(recovered, :pk_organization_token) == org_token
    assert [root, ^org_token] = get_session(recovered, :pk_session_accounts)
    assert root == get_session(login, :user_token)
  end

  test "recovery drops ordinary additions with multi-session off but preserves the org slot", s do
    Settings.update_setting("multi_session_enabled", "true")
    login = remembered_login(s.person)
    other = F.person()

    added =
      post(login, Routes.path("/users/session/accounts"), %{
        user: %{email: other.email, password: "ValidPassword123!"}
      })

    entered = post(added, Routes.path("/users/session/organizations/#{s.org.uuid}"))
    org_token = get_session(entered, :user_token)
    Settings.update_setting("multi_session_enabled", "false")

    recovered =
      restart(%{@remember => cookie(login, @remember), @mirror => cookie(entered, @mirror)})

    assert get_session(recovered, :pk_session_accounts) == [
             get_session(login, :user_token),
             org_token
           ]
  end

  test "revoked grants and mirrors belonging to another root never recover an organization", s do
    login = remembered_login(s.person)
    entered = post(login, Routes.path("/users/session/organizations/#{s.org.uuid}"))
    mirror = cookie(entered, @mirror)
    other_login = remembered_login(F.person())
    recovered = restart(%{@remember => cookie(other_login, @remember), @mirror => mirror})
    assert get_session(recovered, :user_token) == get_session(other_login, :user_token)
    Repo.delete!(s.grant)
    recovered = restart(%{@remember => cookie(login, @remember), @mirror => mirror})
    assert get_session(recovered, :user_token) == get_session(login, :user_token)
    refute get_session(recovered, :pk_organization_token)
  end

  test "the My account row clears a remembered ordinary-account active marker", s do
    Settings.update_setting("multi_session_enabled", "true")
    login = remembered_login(s.person)
    other = F.person()

    added =
      post(login, Routes.path("/users/session/accounts"), %{
        user: %{email: other.email, password: "ValidPassword123!"}
      })

    returned = delete(added, Routes.path("/users/session/organization"))
    assert get_session(returned, :user_token) == get_session(login, :user_token)

    recovered =
      restart(%{@remember => cookie(login, @remember), @mirror => cookie(returned, @mirror)})

    assert get_session(recovered, :user_token) == get_session(login, :user_token)
    assert length(get_session(recovered, :pk_session_accounts)) == 2
  end

  test "a session-only login never writes a durable organization cookie", s do
    {:ok, conn, _} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    refute conn.resp_cookies[@mirror]
  end

  test "a revoked organization slot falls back to the live root on the next request", s do
    entered = post(s.conn, Routes.path("/users/session/organizations/#{s.org.uuid}"))
    Repo.delete!(s.grant)
    recovered = get(entered, Routes.path("/users/log-in"))
    assert get_session(recovered, :user_token) == s.token
    refute get_session(recovered, :pk_organization_token)
    assert recovered.assigns.phoenix_kit_current_user.uuid == s.person.uuid
  end

  test "profile/custom-field saves preserve this session's person and never broadcast it to another session",
       s do
    {:ok, conn, user} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    Events.subscribe_to_users()

    assert {:ok, updated} =
             Auth.merge_user_custom_fields(user, %{"switch_test" => true},
               ensure_definitions: false
             )

    assert updated.acting_user_uuid == s.person.uuid
    assert_receive {:user_updated, shared}
    assert shared.acting_user_uuid == nil
    assert shared.active_role_uuid == nil

    scope = MultiSession.populate_scope(Scope.for_user(user), get_session(conn))

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_session_token: get_session(conn, :user_token),
        phoenix_kit_current_scope: scope,
        phoenix_kit_current_user: user
      }
    }

    someone_else = %{updated | acting_user_uuid: UUIDv7.generate()}

    assert {:noreply, refreshed} =
             ProfileSettings.handle_info(
               {:phoenix_kit_user_updated, someone_else},
               socket
             )

    assert refreshed.assigns.phoenix_kit_current_user.acting_user_uuid == s.person.uuid
    assert Actor.opts(refreshed)[:acting_user_uuid] == s.person.uuid
  end

  test "a managed token cannot become a multi-session root even if it holds a corrupt staff assignment",
       s do
    Settings.update_setting("multi_session_enabled", "true")
    {:ok, entered, user} = MultiSession.act_as_organization(s.conn, s.org.uuid)
    owner = Roles.get_role_by_name("Owner")

    %RoleAssignment{}
    |> RoleAssignment.changeset(%{user_uuid: user.uuid, role_uuid: owner.uuid})
    |> Repo.insert!()

    token = get_session(entered, :user_token)

    malformed =
      init_test_session(build_conn(), %{user_token: token, pk_session_accounts: [token]})

    refute MultiSession.gate_allowed?(get_session(malformed))
    refute MultiSession.may_impersonate?(get_session(malformed))
    assert {:error, :not_allowed} = MultiSession.impersonate(malformed, F.person())
  end

  test "enter/replacement/leave never put raw tokens into debug SQL logs", s do
    secret = String.duplicate("organization-root-secret-", 3)
    s.root |> Ecto.Changeset.change(token: secret) |> Repo.update!()
    beta = F.organization()
    F.manager(beta, s.person)

    log =
      PhoenixKit.DataCase.capture_debug_log(fn ->
        assert {:ok, first} = OrganizationSessions.enter(secret, s.org.uuid)
        assert {:ok, second} = OrganizationSessions.enter(secret, beta.uuid)
        send(self(), {:minted, [first.token, second.token]})
        assert {:ok, :ok} = OrganizationSessions.leave(secret, nil)
        Repo.query!("SELECT 1")
      end)

    assert log =~ "SELECT 1"
    refute log =~ secret
    assert_received {:minted, minted}
    Enum.each(minted, fn token -> refute log =~ inspect(token) end)
    refute Repo.exists?(from(t in UserToken, where: t.acting_session_uuid == ^s.root.uuid))
  end

  test "admin lists and details render a managed organization without a contact address" do
    {_actor, admin} = F.admin_actor()
    org = F.organization(%{contact_email: nil, organization_name: "No inbox company"})
    conn = log_in_user(build_conn(), admin)
    {:ok, _view, html} = live(conn, Routes.path("/admin/users"))
    assert html =~ "Managed organization"
    refute html =~ org.email
    {:ok, _view, html} = live(conn, Routes.path("/admin/users/view/#{org.uuid}"))
    assert html =~ org.organization_name
    refute html =~ org.email
  end

  defp remembered_login(person) do
    conn = %{
      build_conn()
      | remote_ip:
          {10, 91, div(System.unique_integer([:positive]), 250) |> rem(250),
           rem(System.unique_integer([:positive]), 250)}
    }

    post(conn, Routes.path("/users/log-in"), %{
      user: %{email: person.email, password: "ValidPassword123!", remember_me: "true"}
    })
  end

  defp cookie(conn, key), do: get_in(conn.resp_cookies, [key, :value])

  defp restart(cookies) do
    Enum.reduce(cookies, build_conn(), fn {key, value}, conn ->
      put_req_cookie(conn, key, value)
    end)
    |> get(Routes.path("/users/log-in"))
  end

  defp assert_disconnect(token) do
    topic = Sessions.live_socket_id(token)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end
end
