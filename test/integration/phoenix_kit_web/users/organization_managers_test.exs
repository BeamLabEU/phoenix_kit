defmodule PhoenixKitWeb.Users.OrganizationManagersTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Invitations
  alias PhoenixKit.Users.OrganizationInvitation
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Users.OrganizationManagers
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.OrganizationSwitcher

  setup do
    previous = Application.get_env(:swoosh, :shared_test_process)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:swoosh, :shared_test_process, previous),
        else: Application.delete_env(:swoosh, :shared_test_process)
    end)

    Settings.update_setting("enable_organization_accounts", "true")
    s = F.acting_session()
    actor = F.acting_actor(s)

    conn =
      init_test_session(build_conn(), %{
        user_token: s.token,
        pk_session_accounts: [s.root_token, s.token],
        pk_organization_token: s.token
      })

    %{s: s, actor: actor, conn: conn}
  end

  test "acting settings expose managers without users permission or credential controls", %{
    conn: conn,
    s: s
  } do
    {:ok, _view, html} = live(conn, Routes.path("/profile/settings/managers"))
    assert html =~ "Managers use their own accounts"
    assert html =~ s.person.email
    assert html =~ "Invite a manager by email"
    refute html =~ "Find an active person"
    refute html =~ "Allow this organization"
    refute html =~ "Convert to independent"
    refute html =~ s.organization.email
  end

  test "self-service invitations have one response for new, existing and manager addresses", %{
    conn: conn,
    s: s
  } do
    {:ok, view, _} = live(conn, Routes.path("/profile/settings/managers"))

    for email <- [
          F.person().email,
          "new-#{UUIDv7.generate()}@example.com",
          s.person.email,
          s.person.email
        ] do
      html =
        view
        |> form("#profile-user-settings-managers-managers-invite", %{email: email})
        |> render_submit()

      assert html =~ "If this address can receive invitations"
    end

    assert length(Invitations.list_invitations(s.organization.uuid, kind: :manager)) == 3
  end

  test "a manager cannot remove the last manager even with a forged override", %{conn: conn, s: s} do
    {:ok, view, _} = live(conn, Routes.path("/profile/settings/managers"))

    html =
      render_submit(
        element(view, "#profile-user-settings-managers-managers-remove-#{s.manager.uuid}"),
        %{person_uuid: s.person.uuid, allow_managerless: "true"}
      )

    assert html =~ "Add another active manager first"
    assert Repo.get(OrganizationManager, s.manager.uuid)
  end

  test "forged search, direct add and conversion events from manager controls fail closed", %{
    conn: conn,
    s: s
  } do
    target = F.person()
    {:ok, view, _} = live(conn, Routes.path("/profile/settings/managers"))

    for {event, params} <- [
          {"search", %{query: ""}},
          {"add", %{person_uuid: target.uuid}},
          {"convert_to_managed", %{person_uuid: target.uuid}},
          {"convert_to_independent", %{email: "bad@example.com", password: "ValidPassword123!"}}
        ] do
      render_click(with_target(view, "#profile-user-settings-managers-managers"), event, params)
    end

    refute Repo.get_by(OrganizationManager,
             organization_uuid: s.organization.uuid,
             user_uuid: target.uuid
           )

    assert Repo.get!(User, s.organization.uuid).managed_by_members
  end

  test "forged cancellation cannot affect a different organization", %{
    conn: conn,
    s: s,
    actor: actor
  } do
    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, "new@example.com", actor, kind: :manager)

    beta = F.organization()
    {admin, _user} = F.admin_actor()

    {:ok, other, _} =
      Invitations.create_invitation(beta, "other@example.com", admin, kind: :manager)

    {:ok, view, _} = live(conn, Routes.path("/profile/settings/managers"))

    render_click(with_target(view, "#profile-user-settings-managers-managers"), "cancel", %{
      uuid: other.uuid
    })

    assert Repo.get!(OrganizationInvitation, other.uuid).status == :pending
    render_click(element(view, "button[phx-click=cancel][phx-value-uuid='#{invitation.uuid}']"))
    assert Repo.get!(OrganizationInvitation, invitation.uuid).status == :cancelled
  end

  test "contact edits are allowed while acting and reject placeholder mailboxes", %{
    conn: conn,
    s: s
  } do
    {:ok, view, _} = live(conn, Routes.path("/profile/settings/managers"))

    view
    |> form("#profile-user-settings-managers-managers-contact", %{
      contact_email: "shared-new@example.com"
    })
    |> render_submit()

    assert Repo.get!(User, s.organization.uuid).contact_email == "shared-new@example.com"
    render(view)
    current = :sys.get_state(view.pid).socket.assigns.phoenix_kit_current_user
    assert current.contact_email == "shared-new@example.com"
    assert current.acting_user_uuid == s.person.uuid

    view
    |> form("#profile-user-settings-managers-managers-contact", %{
      contact_email: "bad@service.invalid"
    })
    |> render_submit()

    assert Repo.get!(User, s.organization.uuid).contact_email == "shared-new@example.com"
  end

  test "own account receives a manager banner and accepting refreshes the switcher", %{
    s: s,
    actor: actor
  } do
    invitee = F.person()

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, invitee.email, actor, kind: :manager)

    conn = log_in_user(build_conn(), invitee)
    {:ok, view, html} = live(conn, Routes.path("/profile/settings/account"))
    assert html =~ "invited you to manage their organization"
    refute html =~ "organizations/#{s.organization.uuid}"

    html =
      render_click(
        element(view, "button[phx-click=accept_invitation][phx-value-uuid='#{invitation.uuid}']")
      )

    assert html =~ "You can now act for the organization"
    scope = :sys.get_state(view.pid).socket.assigns.phoenix_kit_current_scope

    switcher =
      render_component(&OrganizationSwitcher.organization_switcher/1,
        scope: scope,
        id: "after-accept"
      )

    assert switcher =~ "organizations/#{s.organization.uuid}"

    assert Repo.get_by!(OrganizationManager,
             user_uuid: invitee.uuid,
             organization_uuid: s.organization.uuid
           )

    refute Repo.get!(User, invitee.uuid).organization_uuid
  end

  test "person's invitations are hidden while acting and on borrowed accounts", %{
    conn: conn,
    s: s,
    actor: actor
  } do
    {:ok, _, _} =
      Invitations.create_invitation(s.organization, s.person.email, actor, kind: :manager)

    {:ok, _view, html} = live(conn, Routes.path("/profile/settings/account"))
    refute html =~ "invited you to manage their organization"
    Settings.update_setting("multi_session_enabled", "true")
    own = F.person()
    {root_token, _} = F.session(own)

    borrowed =
      init_test_session(build_conn(), %{
        user_token: s.root_token,
        pk_session_accounts: [root_token, s.root_token]
      })

    {:ok, _view, html} = live(borrowed, Routes.path("/profile/settings/account"))
    refute html =~ "invited you to manage their organization"
  end

  test "admin manager controls require explicit override for the last manager", %{s: s} do
    {_actor, admin} = F.admin_actor()

    {:ok, view, html} =
      live(
        log_in_user(build_conn(), admin),
        Routes.path("/admin/users/view/#{s.organization.uuid}")
      )

    assert html =~ "Find an active person"
    assert html =~ "Give this organization its own login"
    form = "#organization-managers-remove-#{s.manager.uuid}"
    render_submit(element(view, form), %{person_uuid: s.person.uuid, allow_managerless: "false"})
    assert Repo.get(OrganizationManager, s.manager.uuid)
    render_submit(element(view, form), %{person_uuid: s.person.uuid, allow_managerless: "true"})
    refute Repo.get(OrganizationManager, s.manager.uuid)
    refute Auth.get_user_by_session_token(s.token)
  end

  test "ordinary accounts are not offered the managers tab", %{s: s} do
    conn = log_in_user(build_conn(), s.person)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, Routes.path("/profile/settings/managers"))

    assert to == Routes.path("/profile/settings/account")
  end

  test "revoked manager events cannot invite even from a mounted component", %{conn: conn, s: s} do
    {:ok, view, _html} = live(conn, Routes.path("/profile/settings/managers"))
    {admin, _} = F.admin_actor()

    {:ok, :ok} =
      OrganizationManagers.remove(admin, s.organization.uuid, s.person.uuid,
        allow_managerless: true
      )

    render_click(with_target(view, "#profile-user-settings-managers-managers"), "invite", %{
      email: "stale@example.com"
    })

    assert Invitations.list_invitations(s.organization.uuid, kind: :manager) == []
  end

  test "registration without confirmation automatically accepts the manager kind", %{
    s: s,
    actor: actor
  } do
    Settings.update_setting("require_email_confirmation", "false")
    email = "registration-#{UUIDv7.generate()}@example.com"

    {:ok, invitation, token} =
      Invitations.create_invitation(s.organization, email, actor, kind: :manager)

    conn = %{build_conn() | remote_ip: {10, 98, 4, 3}}
    {:ok, view, html} = live(conn, Routes.path("/users/register") <> "?invitation=#{token}")
    assert html =~ "invited to manage"

    render_submit(view, "save", %{
      user: %{
        email: email,
        password: "NewPassword123!",
        account_type: "organization",
        organization_name: "Forged"
      }
    })

    person = Auth.get_user_by_email(email)
    assert person.account_type == "person"
    refute person.organization_uuid
    assert Repo.get!(OrganizationInvitation, invitation.uuid).status == :accepted

    assert Repo.get_by!(OrganizationManager,
             organization_uuid: s.organization.uuid,
             user_uuid: person.uuid
           )
  end

  test "email confirmation automatically accepts a stored manager invitation", %{
    s: s,
    actor: actor
  } do
    person = F.person(%{confirmed_at: nil})

    {:ok, invitation, _} =
      Invitations.create_invitation(s.organization, person.email, actor, kind: :manager)

    person =
      Repo.update!(
        Ecto.Changeset.change(person,
          custom_fields: %{"pending_invitation_uuid" => invitation.uuid}
        )
      )

    token = F.email_token(person, "confirm")
    {:ok, view, _html} = live(build_conn(), Routes.path("/users/confirm/#{token}"))
    render_submit(view, "confirm_account", %{user: %{token: token}})
    assert Repo.get!(OrganizationInvitation, invitation.uuid).status == :accepted

    assert Repo.get_by!(OrganizationManager,
             organization_uuid: s.organization.uuid,
             user_uuid: person.uuid
           )

    refute Repo.get!(User, person.uuid).organization_uuid
  end

  test "person deactivation requires a checked administrator override when they are the last manager",
       %{s: s} do
    {_actor, admin} = F.admin_actor()

    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), Routes.path("/admin/users/view/#{s.person.uuid}"))

    render_click(view, "request_status_toggle", %{is_active: "true"})

    view
    |> form("#user-status-with-manager-check", %{allow_managerless: "false"})
    |> render_submit()

    assert Repo.get!(User, s.person.uuid).is_active
    render_click(view, "request_status_toggle", %{is_active: "true"})

    view
    |> form("#user-status-with-manager-check", %{allow_managerless: "true"})
    |> render_submit()

    refute Repo.get!(User, s.person.uuid).is_active
    refute Auth.get_user_by_session_token(s.token)
  end

  test "person deletion requires a checked administrator override when they are the last manager",
       %{s: s} do
    {_actor, admin} = F.admin_actor()

    {:ok, view, _html} =
      live(log_in_user(build_conn(), admin), Routes.path("/admin/users/view/#{s.person.uuid}"))

    render_click(view, "show_delete_modal")

    view
    |> form("#delete-user-with-manager-check", %{allow_managerless: "false"})
    |> render_submit()

    assert Repo.get(User, s.person.uuid)
    render_click(view, "show_delete_modal")

    view
    |> form("#delete-user-with-manager-check", %{allow_managerless: "true"})
    |> render_submit()

    refute Repo.get(User, s.person.uuid)
    refute Repo.get(OrganizationManager, s.manager.uuid)
  end
end
