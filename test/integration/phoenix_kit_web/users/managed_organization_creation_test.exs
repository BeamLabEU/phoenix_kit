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
    pick(view, manager)

    view
    |> form("#managed-organization-create", %{
      organization: %{
        organization_name: "Creation UI company",
        contact_email: "shared@example.com"
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

  test "the first manager is found by any of the things a person would type", %{conn: conn} do
    person =
      F.person(%{
        first_name: "Mari",
        last_name: "Tamm",
        username: "mtamm-#{System.unique_integer([:positive])}",
        email: "mari-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))

    for query <- ["Mari", "Tamm", "mari tamm", person.username, person.email] do
      assert [%{uuid: uuid, label: "Mari Tamm", sublabel: email}] = search(view, query)
      assert uuid == person.uuid
      assert email == person.email
    end
  end

  test "opening the picker lists people before anything is typed", %{conn: conn} do
    person = F.person()
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))

    assert Enum.any?(search(view, ""), &(&1.uuid == person.uuid))
  end

  test "a search that finds nobody answers with an empty list", %{conn: conn} do
    {:ok, view, html} = live(conn, Routes.path("/admin/users/new/managed"))

    assert search(view, "nobody-by-this-name") == []
    assert html =~ "No active person with that name, username or email"
  end

  test "the chosen person is shown and can be cleared", %{conn: conn} do
    person = F.person()
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))

    html = pick(view, person)
    assert html =~ person.email
    assert has_element?(view, "input[name='organization[person_uuid]'][value='#{person.uuid}']")

    view |> element("#managed-organization-manager button") |> render_click()
    assert has_element?(view, "input#managed-organization-manager")
    refute has_element?(view, "input[name='organization[person_uuid]'][value='#{person.uuid}']")
  end

  test "a refused search still answers the picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))
    Settings.update_setting("enable_organization_accounts", "false")

    assert search(view, "anyone") == []
    assert render(view) =~ "This change is not available"
  end

  test "a person the search did not offer cannot be picked", %{conn: conn} do
    person = F.person(%{api_only: true})
    {:ok, view, _html} = live(conn, Routes.path("/admin/users/new/managed"))

    render_hook(view, "picker_pick", %{"uuid" => person.uuid})

    assert has_element?(view, "input#managed-organization-manager")
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

  test "searching for a manager that finds nobody says so", %{conn: conn} do
    org = F.person(%{account_type: "organization", organization_name: "Independent"})
    {:ok, view, html} = live(conn, Routes.path("/admin/users/view/#{org.uuid}"))
    refute html =~ "No active person with that name, username or email"

    html =
      view
      |> form("#organization-managers-search", %{query: "nobody-by-this-name"})
      |> render_submit()

    assert html =~ "No active person with that name, username or email"
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

  defp search(view, query) do
    view |> element("#managed-organization-manager") |> render_hook("picker_search", %{q: query})
    assert_push_event(view, "picker_results", %{q: ^query, results: results})
    results
  end

  defp pick(view, person) do
    search(view, person.email)

    view
    |> element("#managed-organization-manager")
    |> render_hook("picker_pick", %{uuid: person.uuid})
  end
end
