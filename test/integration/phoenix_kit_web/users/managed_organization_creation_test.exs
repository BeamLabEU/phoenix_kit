defmodule PhoenixKitWeb.Users.ManagedOrganizationCreationTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.OrganizationManager
  alias PhoenixKit.Utils.Routes

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    {_actor, admin} = F.admin_actor()
    %{conn: log_in_user(build_conn(), admin), admin: admin}
  end

  test "admin creates from name, optional contact and explicit first manager", %{conn: conn} do
    manager = F.person()
    {:ok, view, html} = live(conn, Routes.path("/admin/users/new/managed"))
    refute html =~ "Password"
    view |> form("#managed-organization-search", %{query: manager.email}) |> render_submit()

    view
    |> form("#managed-organization-create", %{
      organization: %{
        organization_name: "Creation UI company",
        contact_email: "shared@example.com",
        person_uuid: manager.uuid
      }
    })
    |> render_submit()

    org = Repo.get_by!(User, organization_name: "Creation UI company")
    assert org.managed_by_members
    assert org.contact_email == "shared@example.com"
    assert org.confirmed_at
    assert Repo.get_by!(OrganizationManager, organization_uuid: org.uuid, user_uuid: manager.uuid)
    assert_redirect(view, Routes.path("/admin/users/view/#{org.uuid}"))
  end

  test "missing or ineligible first manager does not create an organization", %{conn: conn} do
    person = F.person(%{api_only: true})
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))

    for uuid <- ["", person.uuid, "forged"] do
      render_submit(view, "create", %{
        organization: %{organization_name: "Must not exist", person_uuid: uuid}
      })
    end

    refute Repo.get_by(User, organization_name: "Must not exist")
  end

  test "master switch off refuses an already mounted create form", %{conn: conn} do
    person = F.person()
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))
    Settings.update_setting("enable_organization_accounts", "false")

    render_submit(view, "create", %{
      organization: %{organization_name: "Disabled creation", person_uuid: person.uuid}
    })

    refute Repo.get_by(User, organization_name: "Disabled creation")
  end

  test "new-user page links to the dedicated creation flow", %{conn: conn} do
    {:ok, _view, html} = live(conn, Routes.path("/admin/users/new"))
    assert html =~ "#{Routes.path("/admin/users/new/managed")}"
  end

  test "borrowed admin account cannot create a managed organization", %{admin: admin} do
    root = F.person()
    {root_token, _} = F.session(root)
    {admin_token, _} = F.session(admin)

    conn =
      init_test_session(build_conn(), %{
        user_token: admin_token,
        pk_session_accounts: [root_token, admin_token]
      })

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, Routes.path("/admin/users/new/managed"))

    assert to == Routes.path("/admin/users")
  end

  test "admin converts an independent organization and back with new credentials", %{conn: conn} do
    previous = Application.get_env(:swoosh, :shared_test_process)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:swoosh, :shared_test_process, previous),
        else: Application.delete_env(:swoosh, :shared_test_process)
    end)

    org = F.person(%{account_type: "organization", organization_name: "Independent"})
    manager = F.person()
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/view/#{org.uuid}"))
    view |> form("#organization-managers-search", %{query: manager.email}) |> render_submit()

    render_click(
      element(
        view,
        "button[phx-click=convert_to_managed][phx-value-person_uuid='#{manager.uuid}']"
      )
    )

    assert Repo.get!(User, org.uuid).managed_by_members

    view
    |> form("#organization-managers-independent", %{
      email: "independent-#{UUIDv7.generate()}@example.com",
      password: "NewPassword123!"
    })
    |> render_submit()

    refute Repo.get!(User, org.uuid).managed_by_members
    refute Repo.exists?(from(m in OrganizationManager, where: m.organization_uuid == ^org.uuid))
    assert_received {:email, email}
    assert email.subject =~ "Confirm"
    assert email.text_body =~ "/users/confirm/"
  end
end
