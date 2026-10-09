defmodule PhoenixKitWeb.Live.Users.UserLibrariesUITest do
  @moduledoc """
  The pages of user libraries (V203): `/admin/libraries` (own and shared
  libraries, an Owner/Admin opening one with an audit entry), the media
  browser refusing an event that names another library's file, the
  profile's Media tab, and the User libraries card in Settings → Media.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.AuditLog.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, VariantSets}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Live.Components.LibrarySettings

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Library users #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")

    %{role: role}
  end

  defp user!(role \\ nil) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "ul-ui-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, user} = Auth.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  defp library!(user, name) do
    {:ok, library} = Libraries.create_user_library(scope(user), %{"name" => name})
    library
  end

  defp media_role! do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Media holders #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "media")
    # Seeing the site's files is `media.view_all`; a holder of `media` alone sees
    # only their own (`own_media_test.exs`). This role is the site editor.
    {:ok, _} = Permissions.grant_permission(role.uuid, "media.view_all")
    {:ok, _} = Permissions.grant_permission(role.uuid, "media.manage")
    role
  end

  defp stored!(user, name, library_uuid) do
    n = System.unique_integer([:positive])

    attrs = %{
      original_file_name: name,
      file_name: "f-#{n}.png",
      file_path: "x/#{n}.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: Ecto.UUID.generate(),
      user_file_checksum: Ecto.UUID.generate(),
      size: 1,
      status: "active",
      user_uuid: user.uuid
    }

    attrs = if library_uuid, do: Map.put(attrs, :library_uuid, library_uuid), else: attrs
    {:ok, file} = Storage.create_file(attrs)
    file
  end

  describe "/admin/libraries" do
    test "lists the user's own and shared libraries", %{conn: conn, role: role} do
      owner = user!(role)
      mine = library!(owner, "My Photos")
      other = user!(role)
      shared = library!(other, "Family")
      {:ok, _} = Libraries.add_member(scope(other), shared, owner.email, "viewer")

      {:ok, _view, html} = live(log_in_user(conn, owner), Routes.path("/admin/libraries"))

      assert html =~ "My Photos"
      assert html =~ "Family"
      assert html =~ ~s(href="#{Routes.path("/admin/libraries/#{mine.slug}")}")
      assert html =~ ~s(href="#{Routes.path("/admin/libraries/#{shared.uuid}")}")
    end

    test "opens one's own library by slug; someone else's is not found", %{conn: conn, role: role} do
      owner = user!(role)
      library = library!(owner, "Holiday")

      {:ok, _view, html} =
        live(log_in_user(conn, owner), Routes.path("/admin/libraries/#{library.slug}"))

      assert html =~ "library-browser"

      stranger = user!(role)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 log_in_user(build_conn(), stranger),
                 Routes.path("/admin/libraries/#{library.uuid}")
               )

      assert to == Routes.path("/admin/libraries")
    end

    test "an open library is named in the header, with a switcher over the viewer's libraries",
         %{conn: conn, role: role} do
      owner = user!(role)
      one = library!(owner, "Holiday")
      two = library!(owner, "Work")

      {:ok, view, html} =
        live(log_in_user(conn, owner), Routes.path("/admin/libraries/#{one.slug}"))

      assert html =~ "pk-title-switcher"
      refute html =~ "library-switcher-select"

      view |> element("#pk-title-switcher-list a", "Work") |> render_click()
      assert_patch(view, Routes.path("/admin/libraries/#{two.slug}"))
    end

    test "with a single library the header offers no switcher", %{conn: conn, role: role} do
      owner = user!(role)
      only = library!(owner, "Solo")

      {:ok, _view, html} =
        live(log_in_user(conn, owner), Routes.path("/admin/libraries/#{only.slug}"))

      refute html =~ "pk-title-switcher"
    end

    test "nothing while user libraries are off", %{conn: conn, role: role} do
      user = user!(role)
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", false)

      assert {:error, {_kind, %{to: to}}} =
               live(log_in_user(conn, user), Routes.path("/admin/libraries"))

      assert to == Routes.path("/profile/settings")
    end

    test "an Admin sees other users' libraries below their own; a user does not",
         %{conn: conn, role: role} do
      owner = user!(role)
      library = library!(owner, "Someone Elses")
      {admin, _token} = create_admin_user()

      {:ok, _view, html} = live(log_in_user(conn, admin), Routes.path("/admin/libraries"))

      assert html =~ "libraries-others"
      assert html =~ "Someone Elses"
      assert html =~ owner.email
      assert html =~ ~s(href="#{Routes.path("/admin/libraries/#{library.uuid}")}")

      {:ok, _view, html} =
        live(log_in_user(build_conn(), user!(role)), Routes.path("/admin/libraries"))

      refute html =~ "Someone Elses"
    end

    test "an Admin opening a user's library is written to the audit log", %{
      conn: conn,
      role: role
    } do
      owner = user!(role)
      library = library!(owner, "Private")
      {admin, _token} = create_admin_user()

      {:ok, _view, html} =
        live(log_in_user(conn, admin), Routes.path("/admin/libraries/#{library.uuid}"))

      assert html =~ "library-browser"

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where:
                     e.action == "storage.library_opened" and e.admin_user_uuid == ^admin.uuid
                 )
               )

      assert entry.target_user_uuid == owner.uuid
      assert entry.metadata["library_uuid"] == library.uuid
    end
  end

  describe "the media browser inside a library" do
    test "an event naming a file of another library is refused", %{role: role} do
      owner = user!(role)
      library = library!(owner, "Guarded")

      {:ok, media_file} =
        Storage.create_file(%{
          original_file_name: "a.png",
          file_name: "a.png",
          file_path: "x/a.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: Ecto.UUID.generate(),
          user_file_checksum: Ecto.UUID.generate(),
          size: 1,
          status: "active",
          user_uuid: owner.uuid
        })

      assert MediaBrowser.foreign_reference?(%{"file_uuid" => media_file.uuid}, library.uuid)

      assert MediaBrowser.foreign_reference?(
               %{"uuids" => ["not-a-uuid", media_file.uuid]},
               library.uuid
             )

      refute MediaBrowser.foreign_reference?(
               %{"file_uuid" => media_file.uuid},
               media_file.library_uuid
             )

      refute MediaBrowser.foreign_reference?(%{"name" => "x"}, library.uuid)
    end
  end

  describe "the profile's Media tab" do
    test "the libraries card needs storage and user libraries; the tab is for everyone", %{
      conn: conn,
      role: role
    } do
      user = user!(role)
      {:ok, _view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))
      assert html =~ "My libraries"

      # The tab itself stopped being the gate when the annotation-tools
      # section moved onto it (that section applies to anyone who can open
      # the media viewer) — the card inside carries the gate now.
      plain = user!()

      {:ok, _view, html} =
        live(log_in_user(build_conn(), plain), Routes.path("/profile/settings/media"))

      assert html =~ "Annotation tools"
      refute html =~ "My libraries"
      refute html =~ "profile-library-settings-create"
    end

    test "creates a library and adds a member", %{conn: conn, role: role} do
      user = user!(role)
      member = user!(role)

      {:ok, view, _html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      view
      |> form("#profile-library-settings-create", %{library: %{name: "From The Tab"}})
      |> render_submit()

      assert [%{library: library}] = Libraries.list_user_libraries(user.uuid)
      assert library.name == "From The Tab"

      view
      |> element("#library-row-#{library.uuid} button", "Members")
      |> render_click()

      html =
        view
        |> form("#profile-library-settings-add-member-#{library.uuid}", %{
          member: %{email: member.email, role: "contributor"}
        })
        |> render_submit()

      assert html =~ "Member added"
      assert html =~ member.email
      assert Libraries.role(library, member.uuid) == :contributor
    end

    test "the owner picks a selectable variant set; others are not offered", %{
      conn: conn,
      role: role
    } do
      user = user!(role)
      library = library!(user, "Sized")
      n = System.unique_integer([:positive])
      {:ok, open} = VariantSets.create_variant_set(%{name: "Open #{n}", selectable: true})
      {:ok, hidden} = VariantSets.create_variant_set(%{name: "Hidden #{n}"})

      {:ok, view, html} = live(log_in_user(conn, user), Routes.path("/profile/settings/media"))

      assert html =~ open.name
      refute html =~ hidden.name

      view
      |> form("#profile-library-settings-sizes-#{library.uuid}", %{set: open.uuid})
      |> render_change()

      assert Libraries.get_library(library.uuid).variant_set_uuid == open.uuid
    end

    test "a viewer cannot open the member list", %{role: role} do
      owner = user!(role)
      library = library!(owner, "Shared")
      viewer = user!(role)
      other = user!(role)
      {:ok, _} = Libraries.add_member(scope(owner), library, viewer.email, "viewer")
      {:ok, _} = Libraries.add_member(scope(owner), library, other.email, "contributor")

      {:ok, socket} =
        LibrarySettings.update(
          %{id: "profile-library-settings", scope: scope(viewer)},
          %Phoenix.LiveView.Socket{}
        )

      {:noreply, socket} =
        LibrarySettings.handle_event("toggle_members", %{"uuid" => library.uuid}, socket)

      assert socket.assigns.open_members == nil
      assert socket.assigns.members == []
    end
  end

  describe "site media" do
    test "a media holder does not see or open another user's library", %{conn: conn, role: role} do
      owner = user!(role)
      library = library!(owner, "Hidden")
      private = stored!(owner, "PRIVATE-LIBRARY-FILE", library.uuid)
      site = stored!(owner, "SITE-MEDIA-FILE", nil)

      media_role = media_role!()
      holder = user!(media_role)

      {:ok, _view, html} = live(log_in_user(conn, holder), Routes.path("/admin/media?view=all"))

      # The grid card does not print the filename; the file uuid is in the
      # card. The site file is there, the user-library file is not.
      assert html =~ site.uuid
      refute html =~ private.uuid

      {:ok, _view, html} =
        live(
          log_in_user(build_conn(), holder),
          Routes.path("/admin/media/#{private.uuid}/storage")
        )

      assert html =~ "File not found"
      refute html =~ "PRIVATE-LIBRARY-FILE"

      {admin, _token} = create_admin_user()

      {:ok, _view, html} =
        live(
          log_in_user(build_conn(), admin),
          Routes.path("/admin/media/#{private.uuid}/storage")
        )

      assert html =~ "PRIVATE-LIBRARY-FILE"
      refute html =~ "File not found"

      # The site file is still a normal storage page.
      {:ok, _view, html} =
        live(log_in_user(build_conn(), holder), Routes.path("/admin/media/#{site.uuid}/storage"))

      assert html =~ "SITE-MEDIA-FILE"
    end
  end

  describe "an Admin opening a user-library file's storage page" do
    test "is written to the audit log, once", %{conn: conn, role: role} do
      owner = user!(role)
      library = library!(owner, "Detail Audited")
      private = stored!(owner, "AUDITED-FILE", library.uuid)
      {admin, _token} = create_admin_user()

      {:ok, view, _html} =
        live(log_in_user(conn, admin), Routes.path("/admin/media/#{private.uuid}/storage"))

      _ = render(view)

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where:
                     e.action == "storage.library_opened" and e.admin_user_uuid == ^admin.uuid
                 )
               )

      assert entry.metadata["file_uuid"] == private.uuid
      assert entry.target_user_uuid == owner.uuid
    end
  end

  describe "Settings → Media → Libraries" do
    test "turns user libraries off and lists them as metadata", %{conn: conn, role: role} do
      owner = user!(role)
      library!(owner, "Listed For Admins")
      {admin, _token} = create_admin_user()

      {:ok, view, html} = live(log_in_user(conn, admin), Routes.path("/admin/settings/media"))
      assert html =~ "Listed For Admins"
      assert html =~ owner.email

      view
      |> form("#media-libraries-user-settings", %{
        user_libraries: %{enabled: "false", limit: "4", window_hours: "6"}
      })
      |> render_submit()

      refute Libraries.user_libraries_enabled?()
      assert Libraries.user_library_limit() == 4
    end
  end
end
