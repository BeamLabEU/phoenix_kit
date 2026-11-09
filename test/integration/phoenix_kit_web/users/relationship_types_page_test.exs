defmodule PhoenixKitWeb.Users.RelationshipTypesPageTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Dashboard.AdminTabs
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.ManagedOrganizationFixtures, as: F
  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  setup do
    Settings.update_setting("enable_organization_accounts", "true")
    {_actor, admin} = F.admin_actor()
    %{conn: log_in_user(build_conn(), admin), admin: admin}
  end

  defp index, do: Routes.path("/admin/users/relationship-types")
  defp new, do: Routes.path("/admin/users/relationship-types/new")
  defp edit(type), do: Routes.path("/admin/users/relationship-types/#{type.uuid}/edit")

  defp type!(attrs \\ %{}) do
    {:ok, type} =
      RelationshipTypes.create_type(
        Map.merge(
          %{
            key: "t#{System.unique_integer([:positive])}",
            name: "Driver",
            from_kind: "person",
            to_kind: "organization",
            can_act: true
          },
          attrs
        )
      )

    type
  end

  describe "the list" do
    test "says what each type allows, and how many people have it", %{conn: conn} do
      organization = F.organization()
      F.manager(organization, F.person())

      {:ok, _view, html} = live(conn, index())

      assert html =~ "Manager"
      assert html =~ "Staff"
      assert html =~ "Act for an organization and manage its people and profile"
      assert html =~ "Act for an organization, but not manage it"
      assert html =~ "1 person"
    end

    test "needs the users permission" do
      assert {:error, {:redirect, _}} =
               build_conn() |> log_in_user(F.person()) |> live(index())
    end

    test "offers archive and delete only where they work", %{conn: conn} do
      unused = type!()
      manager = RelationshipTypes.manager_type()
      staff = RelationshipTypes.get_type_by_key("staff")

      {:ok, view, _} = live(conn, index())

      refute has_element?(view, "button[phx-click=archive][phx-value-uuid='#{manager.uuid}']")
      refute has_element?(view, "button[phx-click=delete][phx-value-uuid='#{manager.uuid}']")
      assert has_element?(view, "button[phx-click=archive][phx-value-uuid='#{staff.uuid}']")
      refute has_element?(view, "button[phx-click=delete][phx-value-uuid='#{staff.uuid}']")
      assert has_element?(view, "button[phx-click=delete][phx-value-uuid='#{unused.uuid}']")
    end

    test "archives, restores and deletes", %{conn: conn} do
      type = type!()
      {:ok, view, _} = live(conn, index())

      html = render_click(view, "archive", %{uuid: type.uuid})
      assert html =~ "Archived"
      assert RelationshipTypes.get_type(type.uuid).status == "archived"

      render_click(view, "restore", %{uuid: type.uuid})
      assert RelationshipTypes.get_type(type.uuid).status == "active"

      render_click(view, "delete", %{uuid: type.uuid})
      refute RelationshipTypes.get_type(type.uuid)
    end

    test "a forged delete of a type in use says why", %{conn: conn} do
      staff = RelationshipTypes.get_type_by_key("staff")
      {:ok, view, _} = live(conn, index())

      assert render_click(view, "delete", %{uuid: staff.uuid}) =~
               "A built-in type cannot be deleted"

      assert RelationshipTypes.get_type(staff.uuid)
    end

    test "moves a type up and down", %{conn: conn} do
      first = type!()
      second = type!()
      {:ok, view, _} = live(conn, index())

      render_click(view, "move", %{uuid: second.uuid, direction: "up"})

      ids = Enum.map(RelationshipTypes.list_types(), & &1.uuid)

      assert Enum.find_index(ids, &(&1 == second.uuid)) <
               Enum.find_index(ids, &(&1 == first.uuid))
    end
  end

  describe "the form" do
    test "makes a type from a name alone, with the key derived", %{conn: conn, admin: admin} do
      {:ok, view, _} = live(conn, new())

      view
      |> form("#relationship-type-form", %{relationship_type: %{name: "Sales Rep"}})
      |> render_change()

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#relationship-type-form", %{relationship_type: %{name: "Sales Rep"}})
               |> render_submit()

      assert to == index()

      assert %RelationshipType{
               can_act: true,
               can_manage: false,
               from_kind: "person",
               to_kind: "organization"
             } = type = RelationshipTypes.get_type_by_key("sales_rep")

      assert RelationshipTypes.name(type) == "Sales Rep"
      assert admin.uuid
    end

    test "can make a managing type", %{conn: conn} do
      {:ok, view, _} = live(conn, new())

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#relationship-type-form", %{
                 relationship_type: %{name: "Director", can_manage: "true"}
               })
               |> render_submit()

      assert %{can_manage: true} = RelationshipTypes.get_type_by_key("director")
    end

    test "asks for a key only when the name cannot give one", %{conn: conn} do
      {:ok, view, _html} = live(conn, new())
      refute has_element?(view, "#relationship-type-form details[open]")

      view
      |> form("#relationship-type-form", %{relationship_type: %{name: "Работник"}})
      |> render_submit()

      assert has_element?(view, "#relationship-type-form details[open]")

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#relationship-type-form", %{
                 relationship_type: %{name: "Работник", key: "worker"}
               })
               |> render_submit()

      assert RelationshipTypes.get_type_by_key("worker")
    end

    test "needs a name", %{conn: conn} do
      {:ok, view, _} = live(conn, new())

      assert view
             |> form("#relationship-type-form", %{relationship_type: %{name: ""}})
             |> render_submit() =~ "can&#39;t be blank"
    end

    test "edits the names and shows what is fixed as text", %{conn: conn} do
      type = type!()
      {:ok, view, html} = live(conn, edit(type))

      assert html =~ "This can&#39;t be changed."
      refute html =~ "relationship_type[can_manage]"

      assert {:error, {:live_redirect, _}} =
               view
               |> form("#relationship-type-form", %{relationship_type: %{name: "Courier"}})
               |> render_submit()

      assert RelationshipTypes.name(RelationshipTypes.get_type(type.uuid)) == "Courier"
    end

    test "a forged edit cannot change the key or a flag", %{conn: conn} do
      type = type!()
      {:ok, view, _} = live(conn, edit(type))

      render_submit(element(view, "#relationship-type-form"), %{
        relationship_type: %{
          name: "Still fine",
          key: "other",
          can_manage: "true",
          can_act: "false",
          builtin: "true"
        }
      })

      assert %{key: key, can_manage: false, can_act: true, builtin: false} =
               RelationshipTypes.get_type(type.uuid)

      assert key == type.key
    end

    test "a forged create can only make an acting type", %{conn: conn} do
      {:ok, view, _} = live(conn, new())

      render_submit(element(view, "#relationship-type-form"), %{
        relationship_type: %{
          name: "Sneaky",
          can_act: "false",
          from_kind: "organization",
          builtin: "true"
        }
      })

      assert %{can_act: true, from_kind: "person", builtin: false} =
               RelationshipTypes.get_type_by_key("sneaky")
    end

    test "a type that does not exist goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, edit(%{uuid: UUIDv7.generate()}))

      assert to == index()
    end
  end

  describe "the tab" do
    test "is there only while organizations are on" do
      assert %{visible: visible} =
               Enum.find(AdminTabs.default_tabs(), &(&1.id == :admin_users_relationship_types))

      assert visible.(nil)

      Settings.update_setting("enable_organization_accounts", "false")
      refute visible.(nil)
    end
  end

  describe "translating a role on the Roles page" do
    defp role! do
      {:ok, role} = Roles.create_role(%{name: "Buyer #{System.unique_integer([:positive])}"})
      role
    end

    test "edits the shown name and leaves the key alone", %{conn: conn} do
      role = role!()
      {:ok, view, _} = live(conn, Routes.path("/admin/users/roles"))

      html = render_click(view, "show_edit_role", %{role_uuid: role.uuid})
      assert html =~ "Name used by code: #{role.name}"

      view
      |> form("#edit-role-form", %{role: %{label: "Purchasing", description: "Buys things"}})
      |> render_submit()

      updated = Roles.get_role_by_name(role.name)
      assert Roles.display_name(updated) == "Purchasing"
      assert updated.description == "Buys things"
    end

    test "a forged rename changes nothing", %{conn: conn} do
      role = role!()
      {:ok, view, _} = live(conn, Routes.path("/admin/users/roles"))
      render_click(view, "show_edit_role", %{role_uuid: role.uuid})

      render_submit(element(view, "#edit-role-form"), %{role: %{name: "Renamed", label: "Shown"}})

      assert Roles.get_role_by_name(role.name)
      refute Roles.get_role_by_name("Renamed")
    end
  end
end
